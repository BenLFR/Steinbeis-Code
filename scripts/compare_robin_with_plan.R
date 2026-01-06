# compare_robin_with_plan.R
# -----------------------------------------------------------------------------
# Compare our calculated ROBIN hours (Mar 2024 - Aug 2025, CORRECTED) with planned/booked hours
# from the work package planning table
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
})

cat("\n═══════════════════════════════════════════════════════════════════════════\n")
cat("  ROBIN 2024-2025 Comparison: Our Calculations vs Planning Table\n")
cat("═══════════════════════════════════════════════════════════════════════════\n\n")

# ---- Read our calculated ROBIN data -----------------------------------------
cat("Loading our calculated ROBIN data...\n")
robin_calculated <- read_csv(
  "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/robin_project_costs_2024-03_to_2025-08.csv",
  show_col_types = FALSE
)

cat(sprintf("✓ Loaded %d employees\n\n", nrow(robin_calculated)))

# ---- Manual entry from planning table (from screenshot) --------------------
cat("Entering data from planning table...\n")

# Data extracted from the screenshot
plan_data <- tribble(
  ~employee,           ~work_package,                  ~time_booked,
  "Mercedes Berlin",   "WP4 Evaluation 2025",          80.00,
  "Daniela Chiran",    "WP4 Evaluation 2025",          50.00,
  "Daniela Chiran",    "WP5 Diss, Expl, Comm 2025",    65.00,
  "Miljana Cosic",     "WP5 Diss, Expl, Comm 2025",    75.00,
  "Robert Gohla",      "WP3 Set up 2025",              155.00,
  "Clémentine Roth",   "WP3 Set up 2025",              105.00,
  "Clémentine Roth",   "WP4 Evaluation 2025",          107.00,
  "Clémentine Roth",   "WP5 Diss, Expl, Comm 2025",    42.00,
  "Clémentine Roth",   "WP6 Management 2025",          19.30
)

# Aggregate by employee
plan_totals <- plan_data %>%
  group_by(employee) %>%
  summarise(
    planned_hours = sum(time_booked, na.rm = TRUE),
    work_packages = paste(work_package, collapse = "; "),
    .groups = "drop"
  )

cat(sprintf("✓ Entered %d employees from planning table\n\n", nrow(plan_totals)))

# ---- Comparison -------------------------------------------------------------
cat("┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ OUR CALCULATIONS (from database)                                       │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

print(robin_calculated %>%
        select(employee, total_hours, total_cost, first_entity),
      n = Inf)

cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ PLANNING TABLE (from screenshot)                                       │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

print(plan_totals, n = Inf)

# ---- Detailed comparison ----------------------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ COMPARISON: Our Hours vs Planned Hours                                 │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

# Normalize names for matching (remove accents, lowercase)
normalize_name <- function(x) {
  x %>%
    stringi::stri_trans_general("Latin-ASCII") %>%
    str_to_lower() %>%
    str_replace_all("[^a-z ]", "") %>%
    str_squish()
}

robin_normalized <- robin_calculated %>%
  mutate(name_key = normalize_name(employee))

plan_normalized <- plan_totals %>%
  mutate(name_key = normalize_name(employee))

comparison <- robin_normalized %>%
  select(employee_calc = employee, name_key, calculated_hours = total_hours, total_cost) %>%
  full_join(
    plan_normalized %>% select(employee_plan = employee, name_key, planned_hours),
    by = "name_key"
  ) %>%
  mutate(
    employee = coalesce(employee_calc, employee_plan),
    calculated_hours = coalesce(calculated_hours, 0),
    planned_hours = coalesce(planned_hours, 0),
    diff_hours = calculated_hours - planned_hours,
    diff_pct = if_else(planned_hours > 0,
                      100 * diff_hours / planned_hours,
                      NA_real_),
    status = case_when(
      abs(diff_hours) < 1 ~ "✓ MATCH",
      diff_hours > 0 ~ "⚠ OVER",
      diff_hours < 0 ~ "⚠ UNDER",
      TRUE ~ "?"
    )
  ) %>%
  select(employee, calculated_hours, planned_hours, diff_hours, diff_pct, total_cost, status) %>%
  arrange(desc(abs(diff_hours)))

print(comparison, n = Inf)

# ---- Summary statistics -----------------------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ SUMMARY                                                                 │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

total_calculated <- sum(comparison$calculated_hours, na.rm = TRUE)
total_planned <- sum(comparison$planned_hours, na.rm = TRUE)
total_diff <- total_calculated - total_planned
total_diff_pct <- 100 * total_diff / total_planned

cat(sprintf("Total hours calculated:  %.2f h\n", total_calculated))
cat(sprintf("Total hours planned:     %.2f h\n", total_planned))
cat(sprintf("Difference:              %+.2f h (%+.1f%%)\n\n", total_diff, total_diff_pct))

# Count matches vs mismatches
n_matches <- sum(abs(comparison$diff_hours) < 1, na.rm = TRUE)
n_total <- nrow(comparison)

cat(sprintf("Employees matching:      %d / %d (%.0f%%)\n",
            n_matches, n_total, 100 * n_matches / n_total))

# ---- Work package breakdown -------------------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ WORK PACKAGE BREAKDOWN (from planning table)                           │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

wp_summary <- plan_data %>%
  group_by(work_package) %>%
  summarise(
    employees = n(),
    total_hours = sum(time_booked, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(total_hours))

print(wp_summary, n = Inf)

# ---- Export comparison ------------------------------------------------------
output_file <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/robin_comparison_vs_plan.csv"
write_csv(comparison, output_file)

cat(sprintf("\n\n✓ Comparison exported to:\n  %s\n", output_file))

cat("\n═══════════════════════════════════════════════════════════════════════════\n\n")
