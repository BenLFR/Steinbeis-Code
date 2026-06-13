# check_project_hours_vs_reference.R
# Generic validation script to compare calculated project hours against reference data
#
# Usage:
#   1. Set parameters below
#   2. Source this file: source("scripts/pipeline/checks/check_project_hours_vs_reference.R")

suppressPackageStartupMessages({
  library(tidyverse)
  library(readxl)
  library(janitor)
  library(stringi)
})

# ═══════════════════════════════════════════════════════════════════
# CONFIGURATION - MODIFY THESE PARAMETERS
# ═══════════════════════════════════════════════════════════════════

# Project to validate
PROJECT_NAME <- "SEADE"  # Change to ROBIN, SEADE, etc.

# Your calculated hours file (CSV exported by export_project_hours.R)
calculated_file <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database/ben/qa/seade_hours_summary_20240101_20241231.csv"

# Stella's reference file (Excel)
reference_file <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/SEADE_Reference_from_Stella.xlsx"
reference_sheet <- "Sheet1"  # Adjust sheet name

# Excel column mapping (adjust to match Stella's Excel structure)
# Which column has employee names?
excel_name_col <- 1  # First column
# Which columns have hours? (can be single column or multiple WP columns)
excel_hours_cols <- 2  # Second column, OR use 2:10 for multiple columns

# Tolerance threshold in hours
TOLERANCE <- 0.01

# ═══════════════════════════════════════════════════════════════════
# VALIDATION LOGIC
# ═══════════════════════════════════════════════════════════════════

cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  VALIDATION:", PROJECT_NAME, "- Comparaison heures vs Reference\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# Check if files exist
if (!file.exists(calculated_file)) {
  stop("❌ Calculated file not found: ", calculated_file, "\n",
       "   Run export_project_hours.R first!")
}

if (!file.exists(reference_file)) {
  stop("❌ Reference file not found: ", reference_file, "\n",
       "   Ask Stella to provide the reference Excel file!")
}

# Load calculated hours
cat("Loading calculated hours...\n")
calculated <- read_csv(calculated_file, show_col_types = FALSE)
cat(sprintf("✓ Loaded calculated hours: %d employees\n", nrow(calculated)))
cat(sprintf("  Total calculated: %.2f hours\n\n", sum(calculated$total_hours, na.rm = TRUE)))

# Load reference hours
cat("Loading reference from Excel...\n")
reference_raw <- read_excel(reference_file, sheet = reference_sheet)

# Process reference data based on structure
# If multiple hour columns, sum them; if single column, use it
if (length(excel_hours_cols) > 1) {
  reference <- reference_raw %>%
    select(employee = excel_name_col, all_of(excel_hours_cols)) %>%
    mutate(across(-employee, as.numeric)) %>%
    mutate(hours_reference = rowSums(across(-employee), na.rm = TRUE))
} else {
  reference <- reference_raw %>%
    select(employee = excel_name_col, hours_reference = excel_hours_cols) %>%
    mutate(hours_reference = as.numeric(hours_reference))
}

reference <- reference %>%
  filter(!is.na(employee), hours_reference > 0)

cat(sprintf("✓ Loaded reference: %d employees\n", nrow(reference)))
cat(sprintf("  Total reference: %.2f hours\n\n", sum(reference$hours_reference, na.rm = TRUE)))

# Normalize names for matching
normalize_name <- function(x) {
  x_clean <- x %>%
    stringi::stri_trans_general("Latin-ASCII") %>%
    str_trim()

  # Handle "Surname, Firstname" format (reverse to "Firstname Surname")
  x_reversed <- if_else(
    str_detect(x_clean, ","),
    str_replace(x_clean, "^([^,]+),\\s*(.+)$", "\\2 \\1"),
    x_clean
  )

  # Normalize: lowercase, remove non-letters, sort words alphabetically
  x_reversed %>%
    str_to_lower() %>%
    str_remove_all("[^a-z ]") %>%
    str_squish() %>%
    str_split(" ") %>%
    map_chr(~paste(sort(.x), collapse = " "))
}

# Apply normalization
calculated_normalized <- calculated %>%
  mutate(name_key = normalize_name(employee)) %>%
  rename(hours_calculated = total_hours)

reference_normalized <- reference %>%
  mutate(name_key = normalize_name(employee))

# Join and compare
cat("───────────────────────────────────────────────────────────────────\n")
cat("  RÉSULTATS DE LA COMPARAISON\n")
cat("───────────────────────────────────────────────────────────────────\n\n")

comparison <- calculated_normalized %>%
  full_join(reference_normalized, by = "name_key") %>%
  mutate(
    employee = coalesce(employee.x, employee.y),
    hours_calculated = coalesce(hours_calculated, 0),
    hours_reference = coalesce(hours_reference, 0),
    diff_hours = hours_calculated - hours_reference,
    abs_diff = abs(diff_hours),
    pct_diff = if_else(hours_reference > 0,
                       100 * diff_hours / hours_reference,
                       NA_real_),
    status = case_when(
      abs_diff <= TOLERANCE ~ "✅ MATCH",
      abs_diff <= 1 ~ "⚠️ CLOSE",
      TRUE ~ "❌ FAIL"
    )
  ) %>%
  select(employee, hours_calculated, hours_reference, diff_hours, abs_diff, pct_diff, status) %>%
  arrange(desc(abs_diff))

print(comparison, n = Inf)

# Summary statistics
n_total <- nrow(comparison)
n_match <- sum(comparison$status == "✅ MATCH", na.rm = TRUE)
n_close <- sum(comparison$status == "⚠️ CLOSE", na.rm = TRUE)
n_fail <- sum(comparison$status == "❌ FAIL", na.rm = TRUE)

cat("\n")
cat(sprintf("Employees compared: %d \n", n_total))
cat(sprintf("  ✅ Perfect matches (≤ %.2fh): %d \n", TOLERANCE, n_match))
cat(sprintf("  ⚠️ Close (≤ 1h): %d \n", n_close))
cat(sprintf("  ❌ Failed (> 1h): %d \n", n_fail))

total_calc <- sum(comparison$hours_calculated, na.rm = TRUE)
total_ref <- sum(comparison$hours_reference, na.rm = TRUE)
total_diff <- total_calc - total_ref

cat("\n")
cat(sprintf("Total Calculated: %.2f hours\n", total_calc))
cat(sprintf("Total Reference: %.2f hours\n", total_ref))
cat(sprintf("Difference: %.2f hours\n", total_diff))

# Export comparison
output_file <- str_replace(calculated_file, "_summary_", "_comparison_")
write_csv(comparison, output_file, na = "")
cat("\n✓ Comparison exported to:", output_file, "\n")

# Final verdict
cat("\n")
if (n_fail == 0 && n_close == 0) {
  cat("✅ TEST PASSED: All employees match perfectly!\n")
  quit(status = 0)
} else if (n_fail == 0) {
  cat("⚠️ TEST WARNING: Some employees have small differences (< 1h)\n")
  quit(status = 0)
} else {
  cat("❌ TEST FAILED:", n_fail, "employee(s) outside tolerance:\n")
  failures <- comparison %>% filter(status == "❌ FAIL")
  for (i in 1:nrow(failures)) {
    cat(sprintf("  %s: %.0fh calculated vs %.0fh expected (%.0fh)\n",
                failures$employee[i],
                failures$hours_calculated[i],
                failures$hours_reference[i],
                failures$diff_hours[i]))
  }
  quit(status = 1)
}
