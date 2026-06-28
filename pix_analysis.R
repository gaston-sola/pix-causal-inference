# =============================================================================
# Causal Inference Final Project
#
# Title: Instant payments and labor formalization:
#        Evidence from PIX in Brazil
#
# Module: UCL Causal Inference 2026
# Date:   April 2026
#
# This script reproduces the full empirical analysis presented in the video.
# Pipeline (executed sequentially):
#   1. Setup and configuration
#   2. Data download from basedosdados.org (RAIS, ANATEL, IBGE)
#   3. Panel construction (municipality x sector x year)
#   4. Descriptive statistics and figures
#   5. Main analysis: triple-difference and event study
#   6. Robustness and sensitivity checks
#   7. Tables and final outputs
#
# Required user action: set GCP_PROJECT_ID below to your Google Cloud
# =============================================================================

rm(list = ls())

# -----------------------------------------------------------------------------
# 1. SETUP AND CONFIGURATION
# -----------------------------------------------------------------------------

required_pkgs <- c(
  "tidyverse", "basedosdados", "bigrquery",
  "fixest", "modelsummary",
  "ggplot2", "broom",
  "geobr", "sf"
)
new_pkgs <- required_pkgs[!(required_pkgs %in% installed.packages()[, "Package"])]
if (length(new_pkgs) > 0) install.packages(new_pkgs, dependencies = TRUE)

library(tidyverse)
library(basedosdados)
library(fixest)
library(modelsummary)
library(broom)

# ---- USER CONFIGURATION ----
GCP_PROJECT_ID <- "pix-rais-analysis"  
DATA_DIR  <- "data"
OUT_DIR   <- "output"
FIG_DIR   <- "figures"
TAB_DIR   <- "tables"

START_YEAR <- 2017
END_YEAR   <- 2023
PIX_YEAR   <- 2021                    # PIX launched Nov 2020 -> 2021 is first full year

# Cash-intensive sectors (CNAE 2-digit sections).
# Following Burga (2024). Includes consumer-facing activities where
# cash transactions are common pre-PIX.
CASH_INTENSIVE_SECTORS <- c(
  "45",  # Wholesale and retail trade of motor vehicles
  "46",  # Wholesale trade
  "47",  # Retail trade
  "49",  # Land transport (taxis, ride-share)
  "53",  # Postal and courier
  "55",  # Accommodation
  "56",  # Food services
  "79",  # Travel agencies
  "93",  # Sports and recreation
  "95",  # Repair of personal goods
  "96"   # Other personal services
)

# Create directories
for (d in c(DATA_DIR, OUT_DIR, FIG_DIR, TAB_DIR)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

basedosdados::set_billing_id(GCP_PROJECT_ID)


# -----------------------------------------------------------------------------
# 2. DATA DOWNLOAD
# -----------------------------------------------------------------------------
# Strategy: download RAIS year-by-year (memory-friendly), then merge.


# ---- 2.A. RAIS: formal employment by municipality x CNAE x year ----
# RAIS (Relacao Anual de Informacoes Sociais) is the Brazilian


rais_cache_dir <- file.path(DATA_DIR, "rais_by_year")
dir.create(rais_cache_dir, recursive = TRUE, showWarnings = FALSE)

for (yr in START_YEAR:END_YEAR) {

  cache_file <- file.path(rais_cache_dir, sprintf("rais_%d.rds", yr))
  if (file.exists(cache_file)) next   # skip years already downloaded

  rais_query <- sprintf("
    SELECT
      ano,
      id_municipio,
      SUBSTR(cnae_2, 1, 2) AS cnae_secao,
      COUNT(*) AS n_vinculos,
      AVG(CAST(valor_remuneracao_media AS FLOAT64)) AS salario_medio
    FROM `basedosdados.br_me_rais.microdados_vinculos`
    WHERE ano = %d
      AND id_municipio IS NOT NULL
      AND cnae_2 IS NOT NULL
    GROUP BY ano, id_municipio, cnae_secao
  ", yr)

  message(sprintf("Downloading RAIS year %d...", yr))
  rais_year <- read_sql(rais_query)
  saveRDS(rais_year, cache_file)
  rm(rais_year); gc()
  Sys.sleep(2)   # avoid saturating BigQuery
}

# Combine all years
rais_panel <- list.files(rais_cache_dir, pattern = "^rais_\\d+\\.rds$",
                         full.names = TRUE) %>%
  map_dfr(readRDS)

saveRDS(rais_panel, file.path(DATA_DIR, "rais_panel.rds"))
rm(rais_panel); gc()

# ---- 2.B. ANATEL: mobile access in 2019 (treatment exposure) ----
# Pre-PIX mobile penetration determines a municipality's exposure to PIX.
# We use 4G+ accesses (LTE, 5G/NR) following Burga (2024).

anatel_query <- "
  SELECT
    id_municipio,
    SUM(acessos) AS total_acessos_movel
  FROM `basedosdados.br_anatel_telefonia_movel.microdados`
  WHERE ano = 2019
    AND tecnologia IN ('LTE', '5G', 'NR')
    AND id_municipio IS NOT NULL
  GROUP BY id_municipio
"
mobile_data <- read_sql(anatel_query) %>%
  mutate(ano = 2019)

saveRDS(mobile_data, file.path(DATA_DIR, "mobile_penetration.rds"))

# ---- 2.C. Controls: population and GDP ----

pop_query <- sprintf("
  SELECT id_municipio, ano, populacao
  FROM `basedosdados.br_ibge_populacao.municipio`
  WHERE ano BETWEEN %d AND %d
", START_YEAR, END_YEAR)

pop_data <- read_sql(pop_query)
saveRDS(pop_data, file.path(DATA_DIR, "population.rds"))

# Municipal GDP (1-2 year lag, so up to END_YEAR - 1)
pib_query <- sprintf("
  SELECT id_municipio, ano, pib
  FROM `basedosdados.br_ibge_pib.municipio`
  WHERE ano BETWEEN %d AND %d
", START_YEAR, END_YEAR - 1)

pib_data <- read_sql(pib_query)
saveRDS(pib_data, file.path(DATA_DIR, "pib.rds"))

# ---- 2.D. Cash-intensity classification ----
# Based on CASH_INTENSIVE_SECTORS defined in setup.

cash_classification <- tibble(
  cnae_secao = sprintf("%02d", 1:99),
  cash_intensive = as.integer(sprintf("%02d", 1:99) %in% CASH_INTENSIVE_SECTORS)
)
saveRDS(cash_classification, file.path(DATA_DIR, "cash_classification.rds"))


# -----------------------------------------------------------------------------
# 3. PANEL CONSTRUCTION
# -----------------------------------------------------------------------------

rais     <- readRDS(file.path(DATA_DIR, "rais_panel.rds"))
mobile   <- readRDS(file.path(DATA_DIR, "mobile_penetration.rds"))
pop      <- readRDS(file.path(DATA_DIR, "population.rds"))
pib      <- readRDS(file.path(DATA_DIR, "pib.rds"))
cash_cls <- readRDS(file.path(DATA_DIR, "cash_classification.rds"))

# Standardize mobile penetration (z-score)
mobile <- mobile %>%
  mutate(mobile_z = as.numeric(scale(total_acessos_movel))) %>%
  select(id_municipio, mobile_penetration_2019 = total_acessos_movel, mobile_z)

# Log population
pop <- pop %>%
  mutate(log_pop = log(populacao + 1)) %>%
  select(id_municipio, ano, log_pop)

# GDP per capita (computed from PIB total / population)
pib <- pib %>%
  left_join(pop %>% select(id_municipio, ano, log_pop_pib = log_pop),
            by = c("id_municipio", "ano")) %>%
  mutate(pib_per_capita = pib / exp(log_pop_pib)) %>%
  group_by(id_municipio) %>%
  summarise(log_pib_pc = log(mean(pib_per_capita, na.rm = TRUE) + 1),
            .groups = "drop")

# Build the analysis panel
panel <- rais %>%
  mutate(
    log_n_vinculos = log(n_vinculos + 1),
    post = as.integer(ano >= PIX_YEAR)
  ) %>%
  left_join(mobile,   by = "id_municipio") %>%
  left_join(pop,      by = c("id_municipio", "ano")) %>%
  left_join(pib,      by = "id_municipio") %>%
  left_join(cash_cls, by = "cnae_secao") %>%
  filter(
    !is.na(mobile_z),
    !is.na(cash_intensive),
    n_vinculos > 0
  ) %>%
  mutate(
    mobile_quartile = ntile(mobile_z, 4),
    high_mobile     = as.integer(mobile_quartile == 4)
  )

saveRDS(panel, file.path(DATA_DIR, "panel_final.rds"))

message(sprintf("Panel built: %d obs, %d municipalities, %d sectors, %d years",
                nrow(panel),
                n_distinct(panel$id_municipio),
                n_distinct(panel$cnae_secao),
                n_distinct(panel$ano)))


# -----------------------------------------------------------------------------
# 4. DESCRIPTIVE STATISTICS AND FIGURES
# -----------------------------------------------------------------------------

panel <- readRDS(file.path(DATA_DIR, "panel_final.rds"))

theme_paper <- theme_minimal(base_size = 11) +
  theme(panel.grid.minor = element_blank(),
        plot.title = element_text(face = "bold"))

# ---- 4.A. Summary statistics ----
sumstats <- panel %>%
  summarise(
    n_obs              = n(),
    n_municipalities   = n_distinct(id_municipio),
    n_sectors          = n_distinct(cnae_secao),
    n_years            = n_distinct(ano),
    mean_log_employ    = mean(log_n_vinculos, na.rm = TRUE),
    sd_mobile_pen      = sd(mobile_z, na.rm = TRUE),
    pct_cash_intensive = mean(cash_intensive)
  )

write_csv(sumstats, file.path(TAB_DIR, "summary_stats.csv"))

# ---- 4.B. Raw trends: cash-intensive vs others, by mobile quartile ----
trend_data <- panel %>%
  group_by(ano, mobile_quartile, cash_intensive) %>%
  summarise(mean_log_employ = mean(log_n_vinculos, na.rm = TRUE),
            .groups = "drop") %>%
  mutate(
    mobile_label = paste0("Q", mobile_quartile, " mobile"),
    cash_label   = if_else(cash_intensive == 1,
                           "Cash-intensive sectors",
                           "Other sectors")
  )

p_trends <- trend_data %>%
  ggplot(aes(x = ano, y = mean_log_employ,
             color = cash_label, linetype = cash_label)) +
  geom_vline(xintercept = 2020.5, linetype = "dotted", color = "#F96167") +
  geom_line(size = 1) +
  geom_point(size = 2) +
  facet_wrap(~mobile_label, nrow = 1) +
  scale_color_manual(values = c("Cash-intensive sectors" = "#1E2761",
                                "Other sectors"          = "#999999")) +
  labs(
    title    = "Log formal employment by sector type and mobile penetration quartile",
    x        = "Year", y = "Mean log(formal employment)",
    color    = NULL, linetype = NULL,
    caption  = "Source: RAIS via basedosdados. PIX launched Nov 2020."
  ) +
  theme_paper +
  theme(legend.position = "bottom")

ggsave(file.path(FIG_DIR, "01_raw_trends.png"), p_trends,
       width = 10, height = 4.5, dpi = 300)



# -----------------------------------------------------------------------------
# 5. MAIN ANALYSIS: TRIPLE-DIFFERENCE AND EVENT STUDY
# -----------------------------------------------------------------------------
#
# Specification:
#   log(employment_mst) = beta * (Mobile_m * Cash_s * Post_t)
#                         + alpha_(m,t) + gamma_(s,t) + delta_(m,s)
#                         + epsilon_(m,s,t)
#
# - alpha_(m,t): municipality-by-year FE (absorbs COVID, Auxilio, etc.)
# - gamma_(s,t): sector-by-year FE
# - delta_(m,s): municipality-by-sector FE
# - SEs clustered by municipality

# ---- 5.A. Baseline triple-DiD ----
m_baseline <- feols(
  log_n_vinculos ~ mobile_z : cash_intensive : post
  | id_municipio^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = panel,
  cluster = ~id_municipio
)

# ---- 5.B. Saturated triple-DiD (all lower-order interactions) ----
# Note: lower-order interactions are absorbed by the fixed effects;
# fixest reports them as removed for collinearity. This is expected
# and confirms the FE structure is fully saturated.
m_saturated <- feols(
  log_n_vinculos ~ mobile_z : post + cash_intensive : post
                 + mobile_z : cash_intensive
                 + mobile_z : cash_intensive : post
  | id_municipio^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = panel,
  cluster = ~id_municipio
)

# ---- 5.C. Event study (year-by-year coefficients, ref = 2019) ----
m_event <- feols(
  log_n_vinculos ~ i(ano, mobile_z * cash_intensive, ref = 2019)
  | id_municipio^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = panel,
  cluster = ~id_municipio
)

# Event-study plot (ggplot)
es_data <- broom::tidy(m_event, conf.int = TRUE) %>%
  filter(str_detect(term, "ano"))

p_event <- es_data %>%
  mutate(year = as.integer(str_extract(term, "\\d{4}"))) %>%
  bind_rows(tibble(year = 2019, estimate = 0,
                   conf.low = 0, conf.high = 0)) %>%
  arrange(year) %>%
  ggplot(aes(x = year, y = estimate)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "grey40") +
  geom_vline(xintercept = 2020.5, linetype = "dotted", color = "#F96167") +
  geom_pointrange(aes(ymin = conf.low, ymax = conf.high),
                  color = "#1E2761", size = 0.8) +
  geom_line(color = "#1E2761", alpha = 0.5) +
  annotate("text", x = 2020.6, y = max(es_data$conf.high, na.rm = TRUE) * 0.9,
           label = "PIX launch", hjust = 0, color = "#F96167", size = 3.5) +
  labs(
    title    = "Event study: differential employment growth in cash-intensive sectors",
    subtitle = "Triple interaction (mobile x cash x year), reference: 2019",
    x = "Year", y = "Coefficient (log employment)"
  ) +
  theme_paper

ggsave(file.path(FIG_DIR, "04_event_study.png"), p_event,
       width = 8, height = 5, dpi = 300)

# Save main models
saveRDS(list(baseline  = m_baseline,
             saturated = m_saturated,
             event     = m_event,
             es_data   = es_data),
        file.path(OUT_DIR, "main_models.rds"))


# -----------------------------------------------------------------------------
# 6. ROBUSTNESS AND SENSITIVITY CHECKS
# -----------------------------------------------------------------------------

# ---- 6.A. Drop pandemic years (2020, 2021) ----
m_no_pandemic <- feols(
  log_n_vinculos ~ mobile_z : cash_intensive : post
  | id_municipio^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = filter(panel, !ano %in% c(2020, 2021)),
  cluster = ~id_municipio
)

# ---- 6.B. Placebo test: fake post = 2018 (pre-PIX) ----
panel_placebo <- panel %>%
  filter(ano <= 2019) %>%
  mutate(post_fake = as.integer(ano >= 2018))

m_placebo <- feols(
  log_n_vinculos ~ mobile_z : cash_intensive : post_fake
  | id_municipio^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = panel_placebo,
  cluster = ~id_municipio
)

# ---- 6.C. Two-way clustering (municipality + sector) ----
m_2way_cluster <- feols(
  log_n_vinculos ~ mobile_z : cash_intensive : post
  | id_municipio^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = panel,
  cluster = ~id_municipio + cnae_secao
)

# ---- 6.D. State-level FE (absorbs only state x year shocks) ----
panel_state <- panel %>%
  mutate(id_estado = substr(as.character(id_municipio), 1, 2))

m_state_fe <- feols(
  log_n_vinculos ~ mobile_z : cash_intensive : post
  | id_estado^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = panel_state,
  cluster = ~id_municipio
)

# ---- 6.E. Dynamic effects (year-by-year post-PIX) ----
panel_dyn <- panel %>%
  mutate(
    post_y1 = as.integer(ano == 2021),
    post_y2 = as.integer(ano == 2022),
    post_y3 = as.integer(ano == 2023)
  )

m_dynamic <- feols(
  log_n_vinculos ~ mobile_z : cash_intensive : post_y1
                 + mobile_z : cash_intensive : post_y2
                 + mobile_z : cash_intensive : post_y3
  | id_municipio^ano + cnae_secao^ano + id_municipio^cnae_secao,
  data    = panel_dyn,
  cluster = ~id_municipio
)

# Save robustness models
saveRDS(list(no_pandemic = m_no_pandemic,
             placebo     = m_placebo,
             twoway_cl   = m_2way_cluster,
             state_fe    = m_state_fe,
             dynamic     = m_dynamic),
        file.path(OUT_DIR, "robustness_models.rds"))


# -----------------------------------------------------------------------------
# 7. TABLES AND FINAL OUTPUTS
# -----------------------------------------------------------------------------

main <- readRDS(file.path(OUT_DIR, "main_models.rds"))
rob  <- readRDS(file.path(OUT_DIR, "robustness_models.rds"))

# ---- 7.A. Table 1: Main results ----
modelsummary(
  list(
    "(1) Baseline"        = main$baseline,
    "(2) State-level FE"  = rob$state_fe,
    "(3) Drop 2020-21"    = rob$no_pandemic,
    "(4) Two-way cluster" = rob$twoway_cl
  ),
  stars       = c("*" = 0.1, "**" = 0.05, "***" = 0.01),
  gof_omit    = "AIC|BIC|Log.Lik|RMSE|R2 Within|R2 Pseudo",
  coef_rename = c("mobile_z:cash_intensive:post" = "Mobile (z) x Cash x Post"),
  notes       = c(
    "Outcome: log(formal employment relationships).",
    "All specifications include municipality-year (or state-year), sector-year,",
    "and municipality-sector fixed effects.",
    "Standard errors clustered by municipality unless noted."
  ),
  output      = file.path(TAB_DIR, "table1_main.html")
)

modelsummary(
  list(
    "(1) Baseline"        = main$baseline,
    "(2) State-level FE"  = rob$state_fe,
    "(3) Drop 2020-21"    = rob$no_pandemic,
    "(4) Two-way cluster" = rob$twoway_cl
  ),
  stars    = c("*" = 0.1, "**" = 0.05, "***" = 0.01),
  gof_omit = "AIC|BIC|Log.Lik|RMSE|R2 Within|R2 Pseudo",
  output   = file.path(TAB_DIR, "table1_main.tex")
)

# ---- 7.B. Table 2: Identification (placebo and dynamic effects) ----
modelsummary(
  list(
    "Main"           = main$baseline,
    "Placebo (2018)" = rob$placebo,
    "Dynamic effect" = rob$dynamic
  ),
  stars       = c("*" = 0.1, "**" = 0.05, "***" = 0.01),
  gof_omit    = "AIC|BIC|Log.Lik|RMSE|R2 Within|R2 Pseudo",
  coef_rename = c(
    "mobile_z:cash_intensive:post"      = "Mobile x Cash x Post (real)",
    "mobile_z:cash_intensive:post_fake" = "Mobile x Cash x Post (placebo 2018)",
    "mobile_z:cash_intensive:post_y1"   = "Effect 2021",
    "mobile_z:cash_intensive:post_y2"   = "Effect 2022",
    "mobile_z:cash_intensive:post_y3"   = "Effect 2023"
  ),
  notes = c(
    "Placebo: fake treatment in 2018 (pre-PIX). Should yield null effect.",
    "Dynamic: separate coefficient for each post-PIX year."
  ),
  output = file.path(TAB_DIR, "table2_identification.html")
)

# ---- 7.C. Table 3: Event study coefficients ----
es_summary <- broom::tidy(main$event, conf.int = TRUE) %>%
  filter(str_detect(term, "ano")) %>%
  mutate(
    year         = as.integer(str_extract(term, "\\d{4}")),
    Estimate     = round(estimate, 5),
    `Std. Error` = round(std.error, 5),
    `p-value`    = round(p.value, 4),
    `95% CI`     = sprintf("[%.4f, %.4f]", conf.low, conf.high)
  ) %>%
  select(year, Estimate, `Std. Error`, `p-value`, `95% CI`) %>%
  arrange(year)

write_csv(es_summary, file.path(TAB_DIR, "table3_event_study.csv"))

message("\n========== ANALYSIS COMPLETE ==========")
message("Tables: ", TAB_DIR)
message("Figures: ", FIG_DIR)
message("Models: ", OUT_DIR)
