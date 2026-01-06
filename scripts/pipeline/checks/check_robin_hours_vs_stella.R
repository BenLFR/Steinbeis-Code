# check_robin_hours_vs_stella.R
# Validation ROBIN: Comparaison heures calculées vs référence Stella (TKS)
# --------------------------------------------------------------------
#
# Ce script compare les heures ROBIN calculées par notre pipeline avec
# les heures de référence extraites du fichier Excel de Stella.
#
# Acceptance criteria: max abs diff <= 0.01 heure par personne
#
# Usage:
#   Rscript check_robin_hours_vs_stella.R
#   Rscript check_robin_hours_vs_stella.R --stella-file=path/to/file.xlsx
#
# --------------------------------------------------------------------

library(tidyverse)
library(readxl)
library(janitor)

cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  VALIDATION ROBIN: Comparaison heures vs Stella (TKS)\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# --- Parse arguments ---------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
stella_file <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code/PK-Abrechnung-HEU-ROBIN_P2_v2.xlsx"

if (length(args) > 0) {
  for (arg in args) {
    if (grepl("^--stella-file=", arg)) {
      stella_file <- sub("^--stella-file=", "", arg)
    }
  }
}

cat("Configuration:\n")
cat("  Stella reference file:", stella_file, "\n\n")

# --- Load calculated hours ---------------------------------------------
qa_dir <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben/qa"
calc_file <- file.path(qa_dir, "robin_hours_tks_like.csv")

if (!file.exists(calc_file)) {
  stop("❌ Calculated hours file not found: ", calc_file,
       "\n   Run the pipeline first to generate this file.")
}

robin_calc <- read_csv(calc_file, show_col_types = FALSE) |>
  select(du_id, employee, total_hours) |>
  rename(hours_calculated = total_hours)

cat("✓ Loaded calculated hours:", nrow(robin_calc), "employees\n")
cat("  Total calculated:", sprintf("%.2f", sum(robin_calc$hours_calculated, na.rm = TRUE)), "hours\n\n")

# --- Load Stella reference ---------------------------------------------
if (!file.exists(stella_file)) {
  stop("❌ Stella reference file not found: ", stella_file)
}

# Lire la feuille PK-Berechnung
stella_raw <- read_excel(stella_file, sheet = "PK-Berechnung")

# Les 10 premières lignes contiennent les noms et les colonnes WP
# Extraire les heures par WP (colonnes "Projektst. WP1" à "Projektst. WP6")
stella_ref <- stella_raw[1:10, ] |>
  clean_names() |>
  select(
    employee = 1,
    matches("^projektst_wp[0-9]")
  ) |>
  mutate(across(starts_with("projektst"), as.numeric)) |>
  mutate(
    hours_stella = rowSums(across(starts_with("projektst")), na.rm = TRUE)
  ) |>
  select(employee, hours_stella)

cat("✓ Loaded Stella reference:", nrow(stella_ref), "employees\n")
cat("  Total Stella:", sprintf("%.2f", sum(stella_ref$hours_stella, na.rm = TRUE)), "hours\n\n")

# --- Normalize employee names for matching --------------------------------
normalize_name <- function(x) {
  # Handle "Surname, Firstname" format by reversing to "Firstname Surname"
  x_clean <- x |>
    stringi::stri_trans_general("Latin-ASCII") |>  # Remove accents
    str_trim()

  # If contains comma, reverse the order
  x_reversed <- if_else(
    str_detect(x_clean, ","),
    str_replace(x_clean, "^([^,]+),\\s*(.+)$", "\\2 \\1"),  # "Sur, First" -> "First Sur"
    x_clean
  )

  # Normalize: lowercase, remove non-letters, sort words alphabetically
  x_reversed |>
    str_to_lower() |>
    str_remove_all("[^a-z ]") |>
    str_squish() |>
    str_split(" ") |>
    map_chr(~paste(sort(.x), collapse = " "))  # Sort words to handle any order
}

robin_calc <- robin_calc |>
  mutate(name_key = normalize_name(employee))

stella_ref <- stella_ref |>
  mutate(name_key = normalize_name(employee))

# --- Compare -----------------------------------------------------------
comparison <- robin_calc |>
  full_join(stella_ref, by = "name_key") |>
  mutate(
    employee = coalesce(employee.x, employee.y),
    diff_hours = hours_calculated - hours_stella,
    abs_diff = abs(diff_hours),
    pct_diff = if_else(hours_stella > 0, 100 * diff_hours / hours_stella, NA_real_),
    status = case_when(
      abs_diff <= 0.01 ~ "✅ MATCH",
      abs_diff <= 1.0  ~ "⚠️ CLOSE",
      TRUE             ~ "❌ FAIL"
    )
  ) |>
  select(employee, hours_calculated, hours_stella, diff_hours, abs_diff, pct_diff, status) |>
  arrange(desc(abs_diff))

cat("───────────────────────────────────────────────────────────────────\n")
cat("  RÉSULTATS DE LA COMPARAISON\n")
cat("───────────────────────────────────────────────────────────────────\n\n")

print(comparison, n = 20)

# --- Summary statistics ------------------------------------------------
cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  STATISTIQUES\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

cat("Employees compared:", nrow(comparison), "\n")
cat("  ✅ Perfect matches (≤ 0.01h):", sum(comparison$status == "✅ MATCH", na.rm = TRUE), "\n")
cat("  ⚠️ Close (≤ 1h):", sum(comparison$status == "⚠️ CLOSE", na.rm = TRUE), "\n")
cat("  ❌ Failed (> 1h):", sum(comparison$status == "❌ FAIL", na.rm = TRUE), "\n\n")

cat("Totals:\n")
cat("  Calculated:", sprintf("%.2f", sum(comparison$hours_calculated, na.rm = TRUE)), "hours\n")
cat("  Stella:", sprintf("%.2f", sum(comparison$hours_stella, na.rm = TRUE)), "hours\n")
cat("  Difference:", sprintf("%+.2f", sum(comparison$diff_hours, na.rm = TRUE)), "hours\n\n")

cat("Max absolute difference:", sprintf("%.2f", max(comparison$abs_diff, na.rm = TRUE)), "hours\n")
cat("Max percentage difference:", sprintf("%+.1f", max(abs(comparison$pct_diff), na.rm = TRUE)), "%\n\n")

# --- Export comparison -------------------------------------------------
output_file <- file.path(qa_dir, "robin_hours_comparison_vs_stella.csv")
write_csv(comparison, output_file, na = "")
cat("✓ Comparison exported to:", output_file, "\n\n")

# --- Acceptance test ---------------------------------------------------
max_diff <- max(comparison$abs_diff, na.rm = TRUE)
threshold <- 0.01

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  ACCEPTANCE TEST\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

cat("Threshold: max abs diff ≤", threshold, "hours per person\n")
cat("Actual max diff:", sprintf("%.4f", max_diff), "hours\n\n")

if (max_diff <= threshold) {
  cat("✅ TEST PASSED: All employees within tolerance!\n\n")
  quit(status = 0)
} else {
  # List employees outside tolerance
  failures <- comparison |>
    filter(abs_diff > threshold) |>
    arrange(desc(abs_diff))

  cat("❌ TEST FAILED:", nrow(failures), "employee(s) outside tolerance:\n\n")
  print(failures |> select(employee, hours_calculated, hours_stella, diff_hours), n = 20)
  cat("\n")
  quit(status = 1)
}
