# test_robin_hybrid.R
# -----------------------------------------------------------------------------
# Test script to compare ROBIN project costs using:
# 1. DATEV-only approach (original)
# 2. Hybrid approach (DATEV + FTE estimates)
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(janitor)
  library(stringi)
})

cat("\n═══════════════════════════════════════════════════════════════════════════\n")
cat("  ROBIN Project Cost Comparison: DATEV vs HYBRID Approach\n")
cat("═══════════════════════════════════════════════════════════════════════════\n\n")

# ---- Load pipeline modules --------------------------------------------------
modules_dir <- "scripts/pipeline/modules"

cat("Loading pipeline modules...\n")
source(file.path(modules_dir, "00_config.R"), encoding = "UTF-8")
source(file.path(modules_dir, "01_utils.R"), encoding = "UTF-8")
source(file.path(modules_dir, "02_load_data.R"), encoding = "UTF-8")
source(file.path(modules_dir, "03_user_mapping.R"), encoding = "UTF-8")
source(file.path(modules_dir, "04_worktime_analysis.R"), encoding = "UTF-8")
source(file.path(modules_dir, "05_master_table.R"), encoding = "UTF-8")

# ---- Load DATEV-only cost breakdown -----------------------------------------
cat("\n[1/2] Running DATEV-only approach...\n")
cat("────────────────────────────────────────────────────────────────────────\n")
source(file.path(modules_dir, "06_project_classification.R"), encoding = "UTF-8")
source(file.path(modules_dir, "07_cost_breakdown.R"), encoding = "UTF-8")

# Save DATEV results
cost_by_pr_datev <- cost_by_pr

# ---- Load HYBRID cost breakdown ---------------------------------------------
cat("\n[2/2] Running HYBRID approach (DATEV + FTE estimates)...\n")
cat("────────────────────────────────────────────────────────────────────────\n")
source(file.path(modules_dir, "06b_payroll_hybrid.R"), encoding = "UTF-8")
source(file.path(modules_dir, "07b_cost_breakdown_hybrid.R"), encoding = "UTF-8")

# Save HYBRID results
cost_by_pr_hybrid_full <- cost_by_pr_hybrid

# ---- Filter ROBIN project ---------------------------------------------------
cat("\n\n═══════════════════════════════════════════════════════════════════════════\n")
cat("  ROBIN Project Analysis\n")
cat("═══════════════════════════════════════════════════════════════════════════\n\n")

period_start <- as.Date("2025-01-01")
period_end   <- as.Date("2025-08-31")
project_filter <- "ROBIN"

# DATEV-only ROBIN costs
robin_datev <- cost_by_pr_datev %>%
  filter(month >= floor_date(period_start, "month"),
         month <= floor_date(period_end, "month")) %>%
  filter(str_detect(str_to_upper(project), project_filter)) %>%
  group_by(du_id) %>%
  summarise(
    employee = first(str_c(str_to_title(pers_given), " ", str_to_title(pers_surname))),
    first_entity = first(entity_code),
    total_hours = sum(hours, na.rm = TRUE),
    total_cost  = round(sum(cost, na.rm = TRUE), 2),
    .groups = "drop"
  ) %>%
  arrange(desc(total_cost))

# HYBRID ROBIN costs
robin_hybrid <- cost_by_pr_hybrid_full %>%
  filter(month >= floor_date(period_start, "month"),
         month <= floor_date(period_end, "month")) %>%
  filter(str_detect(str_to_upper(project), project_filter)) %>%
  group_by(du_id) %>%
  summarise(
    employee = first(str_c(str_to_title(pers_given), " ", str_to_title(pers_surname))),
    first_entity = first(entity_code),
    total_hours = sum(hours, na.rm = TRUE),
    total_cost  = round(sum(cost, na.rm = TRUE), 2),
    # Track how much came from estimates vs actual
    hours_from_actual = sum(if_else(cost_source == "DATEV_actual", hours, 0), na.rm = TRUE),
    hours_from_estimate = sum(if_else(cost_source == "FTE_estimated", hours, 0), na.rm = TRUE),
    cost_from_actual = round(sum(if_else(cost_source == "DATEV_actual", cost, 0), na.rm = TRUE), 2),
    cost_from_estimate = round(sum(if_else(cost_source == "FTE_estimated", cost, 0), na.rm = TRUE), 2),
    .groups = "drop"
  ) %>%
  arrange(desc(total_cost))

# ---- Comparison -------------------------------------------------------------
cat("┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ APPROACH 1: DATEV-only (original)                                      │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")
print(robin_datev, n = Inf)
cat(sprintf("\nTotal: %.2f EUR across %d employees\n",
            sum(robin_datev$total_cost), nrow(robin_datev)))

cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ APPROACH 2: HYBRID (DATEV + FTE estimates)                             │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")
print(robin_hybrid, n = Inf)
cat(sprintf("\nTotal: %.2f EUR across %d employees\n",
            sum(robin_hybrid$total_cost), nrow(robin_hybrid)))

# ---- Detailed comparison ----------------------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ COMPARISON: Impact of Hybrid Approach                                  │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

comparison <- robin_datev %>%
  select(du_id, employee_datev = employee, datev_hours = total_hours, datev_cost = total_cost) %>%
  full_join(
    robin_hybrid %>%
      select(du_id, employee_hybrid = employee, hybrid_hours = total_hours, hybrid_cost = total_cost,
             hours_from_estimate, cost_from_estimate),
    by = "du_id"
  ) %>%
  mutate(
    employee = coalesce(employee_datev, employee_hybrid),
    diff_hours = hybrid_hours - datev_hours,
    diff_cost = hybrid_cost - datev_cost,
    pct_cost_change = 100 * diff_cost / datev_cost,
    pct_estimated = 100 * hours_from_estimate / hybrid_hours
  ) %>%
  select(employee, datev_hours, hybrid_hours, diff_hours,
         datev_cost, hybrid_cost, diff_cost, pct_cost_change,
         hours_from_estimate, pct_estimated) %>%
  arrange(desc(abs(diff_cost)))

print(comparison, n = Inf)

cat(sprintf("\n\nSummary:\n"))
cat(sprintf("  DATEV-only total:  %.2f EUR (%d employees)\n",
            sum(robin_datev$total_cost), nrow(robin_datev)))
cat(sprintf("  HYBRID total:      %.2f EUR (%d employees)\n",
            sum(robin_hybrid$total_cost), nrow(robin_hybrid)))
cat(sprintf("  Difference:        %+.2f EUR (%+.1f%%)\n",
            sum(robin_hybrid$total_cost) - sum(robin_datev$total_cost),
            100 * (sum(robin_hybrid$total_cost) - sum(robin_datev$total_cost)) / sum(robin_datev$total_cost)))

# ---- Export results ---------------------------------------------------------
output_dir <- dir_outputs
write_csv(robin_datev,
          file.path(output_dir, "robin_costs_datev_2025-01_to_2025-08.csv"))
write_csv(robin_hybrid,
          file.path(output_dir, "robin_costs_hybrid_2025-01_to_2025-08.csv"))
write_csv(comparison,
          file.path(output_dir, "robin_costs_comparison_2025-01_to_2025-08.csv"))

cat("\n\n✓ Results exported to:\n")
cat(sprintf("  - %s\n", file.path(output_dir, "robin_costs_datev_2025-01_to_2025-08.csv")))
cat(sprintf("  - %s\n", file.path(output_dir, "robin_costs_hybrid_2025-01_to_2025-08.csv")))
cat(sprintf("  - %s\n", file.path(output_dir, "robin_costs_comparison_2025-01_to_2025-08.csv")))

cat("\n═══════════════════════════════════════════════════════════════════════════\n\n")
