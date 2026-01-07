# calculate_robin_heu_costs.R
# Reproduce Stella's HEU methodology for ROBIN project
# Period: 01.03.2024 - 31.08.2025

suppressPackageStartupMessages({
  library(tidyverse)
  library(readxl)
  library(writexl)
  library(lubridate)
})

cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  ROBIN HEU COST CALCULATION (Stella's Methodology)\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# ═══════════════════════════════════════════════════════════════════
# 1. CONFIGURATION
# ═══════════════════════════════════════════════════════════════════

# Period
period_start <- as.Date("2024-03-01")
period_end <- as.Date("2025-08-31")

# HEU constants
DAYS_PER_MONTH_HEU <- 215/12  # ~17.917 days/month
HOURS_PER_DAY <- 8

# Paths
robin_hours_file <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben/qa/robin_hours_by_period_20240301_20250831.csv"
stella_ref_file <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code/PK-Abrechnung-HEU-ROBIN_P2_v2.xlsx"
output_file <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben/qa/robin_heu_calculation_results.xlsx"

cat("Period:", format(period_start, "%d.%m.%Y"), "to", format(period_end, "%d.%m.%Y"), "\n")
cat("HEU days/month:", round(DAYS_PER_MONTH_HEU, 3), "\n\n")

# ═══════════════════════════════════════════════════════════════════
# 2. LOAD HOURS DATA
# ═══════════════════════════════════════════════════════════════════

cat("Loading ROBIN hours data...\n")
robin_hours <- read_csv(robin_hours_file, show_col_types = FALSE)

# Aggregate by person and WP
hours_by_person_wp <- robin_hours %>%
  group_by(du_id, employee, dwp_id, wp_title) %>%
  summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop")

# Total hours by person
hours_by_person <- hours_by_person_wp %>%
  group_by(du_id, employee) %>%
  summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop")

cat(sprintf("✓ Loaded hours for %d employees\n", nrow(hours_by_person)))
cat(sprintf("  Total hours: %.2f\n\n", sum(hours_by_person$total_hours)))

# ═══════════════════════════════════════════════════════════════════
# 3. EMPLOYEE MASTER DATA (FTE, months, payroll)
# ═══════════════════════════════════════════════════════════════════

cat("Setting up employee master data...\n")

# This should ideally come from your HR/payroll system or Stella's Gehälter sheet
# For now, I'll create a template structure based on Stella's Excel

employee_master <- tribble(
  ~employee,                ~fte,  ~months, ~ag_brutto_total, ~parental_leave_days,
  "Mercedes Berlin",        0.75,  18,      NULL,             0,    # To be filled from payroll
  "Alejandra Campos",       1.0,   14,      NULL,             0,
  "Daniela Chiran",         0.75,  18,      NULL,             0,
  "Miljana Cosic",          1.0,   18,      NULL,             0,    # Has parental leave adjustment
  "Robert Gohla",           1.0,   18,      NULL,             0,
  "Angela Heni",            0.625, 2,       NULL,             0,
  "Jonathan Loeffler",      1.0,   18,      NULL,             0,
  "Clémentine Roth",        0.70,  18,      NULL,             0,    # 0.70 & 0.80 periods
  "Tea Sarenkapa",          0.75,  7,       NULL,             0,
  "Nadja Schlichenmaier",   1.0,   13,      NULL,             0
)

cat("⚠️  Employee master data created (AG Brutto needs to be filled)\n")
cat("   You need to either:\n")
cat("   1. Load from Stella's Gehälter sheet\n")
cat("   2. Load from your payroll system\n")
cat("   3. Manually fill the ag_brutto_total column\n\n")

# ═══════════════════════════════════════════════════════════════════
# 4. TRY TO LOAD PAYROLL FROM STELLA'S EXCEL
# ═══════════════════════════════════════════════════════════════════

if (file.exists(stella_ref_file)) {
  cat("Attempting to load payroll from Stella's Excel (Gehälter sheet)...\n")

  tryCatch({
    gehaelter <- read_excel(stella_ref_file, sheet = "Gehälter", skip = 2)

    # Try to extract employee names and TOTAL column
    # This depends on the exact structure of the Gehälter sheet
    cat("⚠️  Manual mapping needed - Gehälter sheet structure varies\n\n")

  }, error = function(e) {
    cat("❌ Could not load Gehälter sheet:", e$message, "\n\n")
  })
}

# ═══════════════════════════════════════════════════════════════════
# 5. HEU CALCULATIONS
# ═══════════════════════════════════════════════════════════════════

cat("Calculating HEU metrics...\n")

# Join hours with master data
heu_calc <- hours_by_person %>%
  left_join(employee_master, by = "employee") %>%
  mutate(
    # 1. Max days (HEU ceiling)
    max_days_raw = DAYS_PER_MONTH_HEU * months * fte,
    max_days_rounded = ceiling(max_days_raw),  # Round up as per HEU rules

    # Adjust for parental leave if applicable
    max_days_adjusted = max_days_rounded - parental_leave_days,

    # 2. Day equivalents from hours (round to 0.5 day increments)
    day_equiv_raw = total_hours / HOURS_PER_DAY,
    day_equiv_rounded = round(day_equiv_raw * 2) / 2,  # Round to 0.5

    # 3. Capped day equivalents (cannot exceed max days)
    day_equiv_capped = pmin(day_equiv_rounded, max_days_adjusted),

    # 4. Daily rate (will be calculated once we have payroll data)
    daily_rate = if_else(!is.na(ag_brutto_total) & max_days_adjusted > 0,
                         ag_brutto_total / max_days_adjusted,
                         NA_real_),

    # 5. Personnel costs
    pk_total = day_equiv_capped * daily_rate
  )

cat("✓ HEU calculations completed\n\n")

# ═══════════════════════════════════════════════════════════════════
# 6. BREAKDOWN BY WORK PACKAGE
# ═══════════════════════════════════════════════════════════════════

cat("Calculating costs by work package...\n")

# Calculate day equivalents per WP proportionally
pk_by_wp <- hours_by_person_wp %>%
  left_join(heu_calc %>% select(du_id, employee, total_hours, day_equiv_capped, daily_rate, pk_total),
            by = c("du_id", "employee")) %>%
  mutate(
    # Proportional allocation
    hours_pct = if_else(total_hours > 0, hours / total_hours, 0),
    day_equiv_wp = day_equiv_capped * hours_pct,
    day_equiv_wp_rounded = round(day_equiv_wp * 2) / 2,  # Round to 0.5
    pk_wp = day_equiv_wp_rounded * daily_rate
  )

cat("✓ Work package allocation completed\n\n")

# ═══════════════════════════════════════════════════════════════════
# 7. SUMMARY TABLES (matching Stella's format)
# ═══════════════════════════════════════════════════════════════════

cat("Creating summary tables...\n")

# Main calculation table (like PK-Berechnung sheet)
pk_berechnung <- heu_calc %>%
  select(
    S2i = employee,
    Vollzeit_Teilzeit = fte,
    Anzahl_Monate = months,
    Max_Tage = max_days_raw,
    Max_Tage_aufrunden = max_days_rounded,
    Projektstunden_Total = total_hours,
    Tagesaequiv_Total = day_equiv_rounded,
    Tagesaequiv_aufgerundet = day_equiv_capped,
    Tagessatz = daily_rate,
    PK_Total = pk_total,
    AG_Brutto_Total = ag_brutto_total
  ) %>%
  arrange(desc(Projektstunden_Total))

# Add totals row
pk_berechnung_totals <- pk_berechnung %>%
  summarise(
    S2i = "TOTAL",
    Vollzeit_Teilzeit = NA,
    Anzahl_Monate = NA,
    Max_Tage = sum(Max_Tage, na.rm = TRUE),
    Max_Tage_aufrunden = sum(Max_Tage_aufrunden, na.rm = TRUE),
    Projektstunden_Total = sum(Projektstunden_Total, na.rm = TRUE),
    Tagesaequiv_Total = sum(Tagesaequiv_Total, na.rm = TRUE),
    Tagesaequiv_aufgerundet = sum(Tagesaequiv_aufgerundet, na.rm = TRUE),
    Tagessatz = NA,
    PK_Total = sum(PK_Total, na.rm = TRUE),
    AG_Brutto_Total = sum(AG_Brutto_Total, na.rm = TRUE)
  )

pk_berechnung_final <- bind_rows(pk_berechnung, pk_berechnung_totals)

# WP breakdown pivot table
pk_by_wp_pivot <- pk_by_wp %>%
  mutate(wp_short = str_extract(wp_title, "WP\\d+")) %>%
  select(employee, wp_short, hours, day_equiv_wp_rounded, pk_wp) %>%
  pivot_wider(
    names_from = wp_short,
    values_from = c(hours, day_equiv_wp_rounded, pk_wp),
    values_fill = 0,
    names_sep = "_"
  )

cat("✓ Summary tables created\n\n")

# ═══════════════════════════════════════════════════════════════════
# 8. EXPORT RESULTS
# ═══════════════════════════════════════════════════════════════════

cat("Exporting results...\n")

# Create workbook with multiple sheets
export_data <- list(
  "PK_Berechnung" = pk_berechnung_final,
  "PK_by_WP_Detail" = pk_by_wp,
  "PK_by_WP_Pivot" = pk_by_wp_pivot,
  "Employee_Master" = employee_master,
  "Hours_Summary" = hours_by_person
)

write_xlsx(export_data, output_file)

cat("✓ Results exported to:\n")
cat("  ", output_file, "\n\n")

# ═══════════════════════════════════════════════════════════════════
# 9. DISPLAY SUMMARY
# ═══════════════════════════════════════════════════════════════════

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  SUMMARY\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

cat("Total hours:", sprintf("%.2f", sum(heu_calc$total_hours, na.rm = TRUE)), "\n")
cat("Total day equivalents (capped):", sprintf("%.2f", sum(heu_calc$day_equiv_capped, na.rm = TRUE)), "\n")

if (any(!is.na(heu_calc$pk_total))) {
  cat("Total personnel costs:", sprintf("%.2f EUR", sum(heu_calc$pk_total, na.rm = TRUE)), "\n")
} else {
  cat("\n⚠️  Personnel costs not calculated (missing AG Brutto data)\n")
  cat("   Please fill the ag_brutto_total column in employee_master\n")
  cat("   Or load from Stella's Gehälter sheet\n")
}

cat("\n")
cat("Next steps:\n")
cat("1. Fill AG Brutto Total values in Employee_Master sheet\n")
cat("2. Re-run this script to calculate personnel costs\n")
cat("3. Compare with Stella's PK-Berechnung sheet\n")
cat("4. Investigate any discrepancies (FTE, months, parental leave)\n\n")

# Display calculation table
cat("Calculation table (first 5 rows):\n")
print(head(pk_berechnung_final, 5), n = Inf)

cat("\n")
