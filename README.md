# Instant Payments and Labor Formalization: Evidence from PIX in Brazil

UCL Causal Inference module — Final Project — April 2026

---

## Overview

This repository contains the full empirical analysis behind the video
presentation. The research question is whether Brazil's instant payment
system PIX (launched November 2020) expanded or substituted formal
employment, particularly in cash-intensive sectors.

The analysis uses a triple-difference (DDD) design on a panel of 5,570
Brazilian municipalities, 88 CNAE 2-digit sectors, and 7 years (2017-2023).

The main finding is that PIX produced a transitory negative effect on
formal employment in cash-intensive sectors of municipalities with high
pre-PIX mobile penetration. The effect peaks in 2021, attenuates in 2022,
and reverts by 2023.

---

## Files in this submission

```
pix_analysis.R              -- Full analysis script (the only R file you need)
pix_presentation.pptx       -- Slide deck shown in the video
pix_presentation.pdf        -- PDF version of the slides
README.md                   -- This file
```

After execution, the script generates:

```
data/
  rais_panel.rds              -- Aggregated RAIS panel (downloaded)
  mobile_penetration.rds      -- ANATEL 2019 (downloaded)
  population.rds              -- Population by municipality-year
  pib.rds                     -- Municipal GDP
  cash_classification.rds     -- Sector classification
  panel_final.rds             -- Final analysis panel
output/
  main_models.rds             -- Saved fitted models (baseline, event study)
  robustness_models.rds       -- Saved robustness models
figures/
  01_raw_trends.png           -- Raw trends by sector and mobile quartile
  02_treatment_map.png        -- Map of mobile penetration in 2019
  04_event_study.png          -- Event study coefficients
tables/
  table1_main.html            -- Main results
  table2_identification.html  -- Placebo and dynamic effects
  table3_event_study.csv      -- Event study coefficients (CSV)
  summary_stats.csv           -- Sample summary statistics
```

---

## How to reproduce

### Prerequisites

1. R version 4.5+ installed.
2. A Google Cloud account with a project (free tier is sufficient).
3. The BigQuery API enabled in that project.
4. Around 30 minutes of total wall-clock time.
5. Approximately 20 GB of BigQuery free-tier query usage (well within
   the 1 TB monthly free allowance).

### Step-by-step

**1. Set up Google Cloud (one-time, ~10 min).**

   - Go to https://console.cloud.google.com/ and create a new project.
   - Note the **Project ID** (e.g., "my-project-12345").
   - Enable the BigQuery API for that project.

**2. Configure the script.**

   Open `pix_analysis.R` and edit one line near the top:

   ```r
   GCP_PROJECT_ID <- "your-project-id"   # <-- replace with your ID
   ```

**3. Run the script.**

   In R or RStudio, set the working directory to the folder where
   `pix_analysis.R` is located and run:

   ```r
   source("pix_analysis.R")
   ```

   The first time you run it, R will open a browser window asking you
   to authorize Google Cloud access. Accept the authorization. The
   script will then proceed automatically.

**4. Expected runtime by section.**

   - Section 2 (data download): 10-15 minutes
   - Section 3 (panel construction): under 1 minute
   - Section 4 (descriptives): 1-2 minutes
   - Section 5 (main analysis): 2-3 minutes
   - Section 6 (robustness): 3-5 minutes
   - Section 7 (output tables): under 1 minute

   Total: approximately 20-30 minutes end-to-end.

**5. Resumability.**

   The RAIS download is the slowest step. The script caches each year
   separately under `data/rais_by_year/`. If interrupted, simply re-run
   the script: it will skip years already downloaded.

---

## Methodology summary

### Specification

```
Y_(m,s,t) = beta * (Mobile_m * Cash_s * Post_t)
            + alpha_(m,t) + gamma_(s,t) + delta_(m,s)
            + epsilon_(m,s,t)
```

where:

- `Y_(m,s,t)`: log of formal employment relationships in municipality m,
  sector s, year t
- `Mobile_m`: standardized mobile access per capita in 2019 (z-score),
  pre-PIX
- `Cash_s`: indicator for cash-intensive CNAE 2-digit sectors
- `Post_t`: indicator equal to 1 for years 2021 onward
- `alpha_(m,t)`: municipality-by-year fixed effects (absorb COVID,
  Auxilio Emergencial, local shocks)
- `gamma_(s,t)`: sector-by-year fixed effects
- `delta_(m,s)`: municipality-by-sector fixed effects
- Standard errors clustered by municipality

### Identification

The triple-difference design exploits three sources of variation
combined: geographic (mobile penetration), sectoral (cash-intensity),
and temporal (post-PIX). The municipality-by-year fixed effects absorb
any shock that affects all sectors uniformly within a municipality,
including the pandemic. The treatment effect beta is identified from
differential responses across sectors within the same municipality and
year.

The placebo test (fake post = 2018) yields a null effect, validating
the identification strategy.

---

## Data sources

All data are public and accessed through basedosdados.org, a curated
data lake of Brazilian government datasets hosted on Google BigQuery.

| Variable | Source | Description |
|---|---|---|
| Formal employment | RAIS (Ministry of Economy) | Administrative record of formal jobs |
| Mobile access | ANATEL | Telecom regulator, 4G+ accesses by municipality |
| Population | IBGE | Annual municipal population estimates |
| GDP | IBGE | Municipal gross domestic product |
| Cash-intensive sectors | Manual classification following Burga (2024) | 11 CNAE 2-digit sections |

---

## Key results

| Specification | Coefficient | Std. Error | p-value |
|---|---|---|---|
| Baseline (5 cash sectors)        | -0.001  | 0.001 | 0.072 |
| State-level FE (broader, 11 sectors) | -0.005  | 0.002 | 0.005 |
| Drop pandemic 2020-21            | -0.002  | 0.001 | 0.036 |
| Two-way clustering               | -0.003  | 0.002 | 0.167 |
| Placebo (fake post = 2018)       | -0.0004 | 0.0004 | 0.363 |

Dynamic effects:

| Year | Coefficient | p-value |
|---|---|---|
| 2021 | -0.005 | 0.001 |
| 2022 | -0.003 | 0.008 |
| 2023 | +0.000 | 0.764 |

---

## Key references

- Burga, C. (2024). Financial Technologies, Labor Markets, and Wage
  Inequality: Evidence from Instant Payment Systems. IDB Working Paper.
- Ulyssea, G. (2018). Firms, Informality, and Development: Theory and
  Evidence from Brazil. American Economic Review, 108(8): 2015-2047.
- Sarkisyan, S. (2024). Instant Payment Systems and Bank Competition.
  Working paper.
- Leal, R., & Haase, B. (2025). Instant Payments and Banks. Economia
  Ensaios.
- Ponczek, V., & Ulyssea, G. (2022). Enforcement of Labour Regulation
  and the Labour Market Effects of Trade. The Economic Journal,
  132(641): 361-390.
- IMF (2023). Pix: Brazil's Successful Instant Payment System. IMF
  Country Report 2023/289.

---

## Contact

Gastón Sola
UCL — MSc Data Science and Public Policy
gaston.sola.25@ucl.ac.uk
April 2026
