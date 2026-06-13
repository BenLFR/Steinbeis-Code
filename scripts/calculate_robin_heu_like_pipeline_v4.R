# calculate_robin_heu_like_pipeline_v2.R
# Calculate ROBIN HEU costs using pipeline methodology
# FIXED VERSION: Uses payroll-based month filtering per employee
# Based on modules: 02_load_data, 09_heu_daily_rate, 06b_payroll_hybrid
# Period: 01.03.2024 - 31.08.2025

suppressPackageStartupMessages({
  library(tidyverse)
  library(janitor)
  library(lubridate)
  library(writexl)
})

# Source utils for round_half function
source("scripts/pipeline/modules/01_utils.R")

cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  ROBIN HEU COSTS (Pipeline Methodology) - FIXED VERSION\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# ═══════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════

# Period (HEU reporting period)
rp_start <- as.Date("2024-03-01")
rp_end <- as.Date("2025-08-31")
rp_months <- seq(floor_date(rp_start, "month"), floor_date(rp_end, "month"), by = "month")

# Paths (matching pipeline config)
repo_root <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/Steinbeis-Code"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/datev-data"
dir_fte <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/fte-liste"
dir_db <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database/ben"
output_dir <- file.path(dir_db, "qa")

# ROBIN hours file
robin_hours_file <- file.path(output_dir, "robin_hours_by_period_20240301_20250831.csv")

cat("Period:", format(rp_start, "%d.%m.%Y"), "to", format(rp_end, "%d.%m.%Y"), "\n")
cat("Months:", length(rp_months), "\n\n")

# ═══════════════════════════════════════════════════════════════════
# 1. LOAD ROBIN HOURS
# ═══════════════════════════════════════════════════════════════════

cat("Loading ROBIN hours...\n")
robin_hours <- read_csv(robin_hours_file, show_col_types = FALSE)

# Aggregate by person and WP
robin_by_person_wp <- robin_hours %>%
  group_by(du_id, employee, dwp_id, wp_title) %>%
  summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop")

robin_by_person <- robin_by_person_wp %>%
  group_by(du_id, employee) %>%
  summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop")

cat(sprintf("✓ %d employees, %.2f total hours\n\n", nrow(robin_by_person), sum(robin_by_person$total_hours)))

# ═══════════════════════════════════════════════════════════════════
# 2. LOAD PAYROLL (DATEV)
# ═══════════════════════════════════════════════════════════════════

cat("Loading DATEV payroll...\n")

# Simple CSV reader for DATEV files (matching pipeline's read_pay)
read_datev_file <- function(f) {
  read_delim(f, delim = ";",
             locale = locale(decimal_mark = ",", grouping_mark = "."),
             show_col_types = FALSE,
             skip = 8) %>%  # DATEV files have 8 header lines
    clean_names()
}

datev_files <- list.files(dir_datev, pattern = "_Personalkosten_.*\\.csv$", full.names = TRUE) %>% sort()
payroll_raw <- map_dfr(datev_files, ~read_datev_file(.x) %>% mutate(src_file = basename(.x)))

# Find gesamtkosten column (flexible - could be gesamtkosten, gesamtkosten_1, etc.)
datev_gk_col <- names(payroll_raw) %>% str_subset("^gesamtkosten") %>% .[1]

# Extract month and entity
payroll <- payroll_raw %>%
  mutate(
    entity_code = str_extract(src_file, "^\\d{5}") %>% str_sub(-4L),
    month_str = str_extract(src_file, "\\d{2}[-_]\\d{4}"),
    month = month_str %>% str_replace("_", "-") %>% parse_date_time("my") %>% floor_date("month") %>% as.Date(),
    pers_nr = as.character(pers_nr),
    gesamtkosten = .data[[datev_gk_col]]
  ) %>%
  filter(month >= rp_start, month <= rp_end,
         !is.na(pers_nr), str_detect(pers_nr, "^[0-9]+$")) %>%
  mutate(pers_nr_short = as.integer(str_remove(pers_nr, "^0+"))) %>%
  select(entity_code, month, pers_nr_short, nachname, vorname, gesamtkosten)

cat(sprintf("✓ %d payroll rows loaded\n", nrow(payroll)))
cat(sprintf("  Total payroll (raw): %.2f EUR\n\n", sum(payroll$gesamtkosten, na.rm = TRUE)))

# ═══════════════════════════════════════════════════════════════════
# 3. LOAD FTE DATA (Personio)
# ═══════════════════════════════════════════════════════════════════

cat("Loading FTE data...\n")

fte_raw <- read_delim(file.path(dir_fte, "Wochenarbeitszeit.csv"),
                      delim = ";",
                      locale = locale(decimal_mark = ",", grouping_mark = "."),
                      show_col_types = FALSE) %>%
  clean_names() %>%
  mutate(
    wirksamkeitsdatum = dmy(wirksamkeitsdatum),
    entity_code = str_sub(personalnummer, 1, 4),
    pers_nr_short = as.integer(str_remove(str_sub(personalnummer, 5), "^0+"))
  ) %>%
  filter(status == "Aktiv", !is.na(wirksamkeitsdatum))

cat(sprintf("✓ %d FTE records loaded\n\n", nrow(fte_raw)))

# ═══════════════════════════════════════════════════════════════════
# 4. LINK ROBIN PERSONS TO PAYROLL/FTE
# ═══════════════════════════════════════════════════════════════════

cat("Linking persons...\n")

# Load d_user for entity_code and HR numbers
d_user <- read_csv(file.path(dir_db, "..", "d_user.csv"), show_col_types = FALSE) %>%
  clean_names() %>%
  mutate(du_hr_numbers = as.character(du_hr_numbers))

# Create users_key (du_id → entity_code + pers_nr_short)
# Use normalized names to handle accents and compound names
users_key <- payroll %>%
  mutate(
    surname_norm = normalize_name(nachname),
    given_norm = normalize_name(vorname),
    # Also try matching on just first word of given name for compound names
    given_first = word(given_norm, 1)
  ) %>%
  distinct(entity_code, pers_nr_short, surname_norm, given_norm, given_first) %>%
  left_join(
    d_user %>%
      mutate(
        surname_norm = normalize_name(du_surname),
        given_norm = normalize_name(du_name)
      ) %>%
      select(du_id, surname_norm, given_norm),
    by = c("surname_norm", "given_norm"),
    relationship = "many-to-many"
  ) %>%
  filter(!is.na(du_id)) %>%
  select(du_id, entity_code, pers_nr_short) %>%
  distinct()

# Secondary matching pass for compound names (e.g., "Campos Cuellar" → "Campos")
# Try matching unmatched payroll records using first/last word of surname and last word of given name
payroll_unmatched <- payroll %>%
  anti_join(users_key, by = c("entity_code", "pers_nr_short")) %>%
  mutate(
    surname_norm = normalize_name(nachname),
    given_norm = normalize_name(vorname),
    surname_first = word(surname_norm, 1),
    surname_last = word(surname_norm, -1),
    given_last = word(given_norm, -1)
  ) %>%
  distinct(entity_code, pers_nr_short, surname_first, surname_last, given_last)

# Try fuzzy matching: match on surname_first + given_last
users_fuzzy_match <- payroll_unmatched %>%
  left_join(
    d_user %>%
      mutate(surname_norm = normalize_name(du_surname),
             given_norm = normalize_name(du_name)) %>%
      select(du_id, surname_norm, given_norm),
    by = c("surname_first" = "surname_norm", "given_last" = "given_norm")
  ) %>%
  filter(!is.na(du_id)) %>%
  select(du_id, entity_code, pers_nr_short)

# Also try matching on surname_last + given_last
users_fuzzy_match2 <- payroll_unmatched %>%
  anti_join(users_fuzzy_match, by = c("entity_code", "pers_nr_short")) %>%
  left_join(
    d_user %>%
      mutate(surname_norm = normalize_name(du_surname),
             given_norm = normalize_name(du_name)) %>%
      select(du_id, surname_norm, given_norm),
    by = c("surname_last" = "surname_norm", "given_last" = "given_norm")
  ) %>%
  filter(!is.na(du_id)) %>%
  select(du_id, entity_code, pers_nr_short)

# Combine all matches
users_key <- bind_rows(users_key, users_fuzzy_match, users_fuzzy_match2) %>%
  distinct()

cat(sprintf("✓ %d persons linked (%d from fuzzy matching)\n\n",
            nrow(users_key), nrow(users_fuzzy_match) + nrow(users_fuzzy_match2)))

# ═══════════════════════════════════════════════════════════════════
# 4a. DETERMINE ACTIVE MONTHS PER EMPLOYEE (from payroll)
# ═══════════════════════════════════════════════════════════════════
# FIX #1: Calculate which months each employee had payroll
# This ensures Max Tage is only calculated for months actually worked

cat("Determining active months per employee (payroll-based)...\n")

# Link payroll to du_id
payroll_with_ids <- payroll %>%
  inner_join(users_key, by = c("entity_code", "pers_nr_short"))

# Calculate active months (months with payroll > 0)
employee_active_months <- payroll_with_ids %>%
  filter(!is.na(gesamtkosten), gesamtkosten > 0) %>%
  group_by(du_id) %>%
  summarise(
    active_months = list(sort(unique(month))),
    n_active_months = n_distinct(month),
    first_active_month = min(month),
    last_active_month = max(month),
    .groups = "drop"
  )

# Display active months for ROBIN employees
cat(sprintf("✓ Active months calculated for %d employees\n\n", nrow(employee_active_months)))
cat("ROBIN employee active months:\n")
robin_active <- employee_active_months %>%
  inner_join(robin_by_person %>% select(du_id, employee), by = "du_id") %>%
  arrange(employee) %>%
  select(employee, n_active_months, first_active_month, last_active_month)

print(robin_active, n = Inf)
cat("\n")

# ═══════════════════════════════════════════════════════════════════
# 5. HEU CAP CALCULATION (215/12 days/month × FTE × coverage)
# ═══════════════════════════════════════════════════════════════════
# FIX #2: Use employee-specific months instead of global rp_months

cat("Calculating HEU cap (with employee-specific month filtering)...\n")

# Create FTE periods
fte_periods <- fte_raw %>%
  arrange(entity_code, pers_nr_short, wirksamkeitsdatum) %>%
  group_by(entity_code, pers_nr_short) %>%
  mutate(
    start = wirksamkeitsdatum,
    end = lead(wirksamkeitsdatum, default = rp_end + 1) - 1
  ) %>%
  ungroup() %>%
  select(entity_code, pers_nr_short, start, end, fte)

# Link to du_id
fte_periods_du <- fte_periods %>%
  inner_join(users_key, by = c("entity_code", "pers_nr_short")) %>%
  mutate(
    start = pmax(start, rp_start),
    end = pmin(end, rp_end)
  ) %>%
  filter(start <= end)

# **KEY FIX**: Instead of crossing with all rp_months, use employee-specific active months
# Expand FTE periods to only the months where employee had payroll
grid <- fte_periods_du %>%
  left_join(employee_active_months %>% select(du_id, active_months), by = "du_id") %>%
  filter(!is.na(active_months)) %>%
  unnest(active_months) %>%
  rename(month = active_months) %>%
  mutate(
    m_start = month,
    m_end = month + days(29),  # 30 days HEU convention
    ov_start = pmax(start, m_start),
    ov_end = pmin(end, m_end),
    days_overlap = pmax(0L, as.integer(ov_end - ov_start + 1L)),
    coverage_30 = days_overlap / 30
  ) %>%
  filter(coverage_30 > 0)

# Sum cap per person
heu_cap_base <- grid %>%
  group_by(du_id) %>%
  summarise(
    day_equiv_base = sum((215 / 12) * fte * coverage_30, na.rm = TRUE),
    n_months_calculated = n_distinct(month),
    .groups = "drop"
  )

cat(sprintf("✓ HEU cap base calculated for %d persons\n", nrow(heu_cap_base)))

# Display comparison
cat("\nMonth count verification (should match active months from payroll):\n")
heu_cap_base %>%
  inner_join(robin_by_person %>% select(du_id, employee), by = "du_id") %>%
  left_join(employee_active_months %>% select(du_id, n_active_months), by = "du_id") %>%
  select(employee, n_months_calculated, n_active_months) %>%
  mutate(match = n_months_calculated == n_active_months) %>%
  arrange(employee) %>%
  print(n = Inf)

cat("\n")

# Load parental leave
parental_leave_file <- file.path(repo_root, "elternurlaub24-251027.csv")
if (file.exists(parental_leave_file)) {
  parental_leave_raw <- read_delim(parental_leave_file, delim = ";",
                                    locale = locale(decimal_mark = ",", grouping_mark = "."),
                                    show_col_types = FALSE) %>% clean_names()

  parental_leave_days <- parental_leave_raw %>%
    mutate(
      von_date = dmy(von),
      bis_date = dmy(bis),
      dauer_std = as.numeric(str_replace(dauer_std, ",", "."))
    ) %>%
    filter(von_date <= rp_end, bis_date >= rp_start) %>%
    separate_rows(personalnummer_n, sep = ",") %>%
    mutate(
      personalnummer_n = str_trim(personalnummer_n),
      entity_code = str_sub(personalnummer_n, 1, 4),
      pers_nr_short = as.integer(str_remove(str_sub(personalnummer_n, 5), "^0+"))
    ) %>%
    left_join(users_key, by = c("entity_code", "pers_nr_short")) %>%
    filter(!is.na(du_id)) %>%
    group_by(du_id) %>%
    summarise(parental_leave_days = sum(dauer_std / 8, na.rm = TRUE), .groups = "drop")

  cat(sprintf("✓ Parental leave loaded: %d person(s)\n", nrow(parental_leave_days)))
  parental_leave_days %>%
    left_join(d_user %>% select(du_id, du_name, du_surname), by = "du_id") %>%
    mutate(employee = paste(du_name, du_surname)) %>%
    select(employee, parental_leave_days) %>%
    print(n = Inf)
  cat("\n")
} else {
  parental_leave_days <- tibble(du_id = integer(), parental_leave_days = numeric())
  cat("⚠ No parental leave file found\n\n")
}

# Apply parental leave deduction and round to 0.5
heu_cap <- heu_cap_base %>%
  left_join(parental_leave_days, by = "du_id") %>%
  mutate(
    parental_leave_days = coalesce(parental_leave_days, 0),
    day_equiv_max = round_half(day_equiv_base - parental_leave_days)
  )

cat(sprintf("✓ HEU cap calculated for %d persons\n", nrow(heu_cap)))
cat("\nMax Tage comparison with Stella:\n")
heu_cap %>%
  inner_join(robin_by_person %>% select(du_id, employee), by = "du_id") %>%
  select(employee, day_equiv_base, parental_leave_days, day_equiv_max) %>%
  arrange(employee) %>%
  print(n = Inf)
cat("\n")

# ═══════════════════════════════════════════════════════════════════
# 6. TOTAL PAYROLL COSTS IN RP
# ═══════════════════════════════════════════════════════════════════

cat("Calculating payroll costs...\n")

perso_costs_RP <- payroll %>%
  left_join(users_key, by = c("entity_code", "pers_nr_short")) %>%
  filter(!is.na(du_id)) %>%
  group_by(du_id) %>%
  summarise(perso_costs_RP = sum(gesamtkosten, na.rm = TRUE), .groups = "drop")

cat(sprintf("✓ Total payroll: %.2f EUR\n", sum(perso_costs_RP$perso_costs_RP)))
cat("\nPayroll per ROBIN employee:\n")
perso_costs_RP %>%
  inner_join(robin_by_person %>% select(du_id, employee), by = "du_id") %>%
  arrange(employee) %>%
  print(n = Inf)
cat("\n")

# ═══════════════════════════════════════════════════════════════════
# 7. HEU DAILY RATE & DAY EQUIVALENTS
# ═══════════════════════════════════════════════════════════════════

cat("Calculating HEU daily rate and costs...\n")

heu_calc <- robin_by_person %>%
  left_join(heu_cap, by = "du_id") %>%
  left_join(perso_costs_RP, by = "du_id") %>%
  mutate(
    # Daily rate
    heu_daily_rate = if_else(day_equiv_max > 0, perso_costs_RP / day_equiv_max, NA_real_),

    # Day equivalents from hours (8h = 1 day)
    day_equiv_declared = total_hours / 8,
    day_equiv_declared_rounded = round_half(day_equiv_declared),

    # Capped day equivalents
    day_equiv_capped = pmin(day_equiv_declared_rounded, day_equiv_max),

    # Personnel costs
    pk_total = day_equiv_capped * heu_daily_rate
  )

cat(sprintf("✓ HEU calculations completed\n"))
cat(sprintf("  Total day-equiv (capped): %.2f\n", sum(heu_calc$day_equiv_capped, na.rm = TRUE)))
cat(sprintf("  Total PK: %.2f EUR\n\n", sum(heu_calc$pk_total, na.rm = TRUE)))

# ═══════════════════════════════════════════════════════════════════
# 8. BREAKDOWN BY WORK PACKAGE
# ═══════════════════════════════════════════════════════════════════

cat("Calculating WP breakdown...\n")

pk_by_wp <- robin_by_person_wp %>%
  left_join(heu_calc %>% select(du_id, employee, total_hours, day_equiv_capped, heu_daily_rate, pk_total),
            by = c("du_id", "employee")) %>%
  mutate(
    # Proportional allocation
    hours_pct = if_else(total_hours > 0, hours / total_hours, 0),
    day_equiv_wp = day_equiv_capped * hours_pct,
    day_equiv_wp_rounded = round_half(day_equiv_wp),
    pk_wp = day_equiv_wp_rounded * heu_daily_rate
  )

cat(sprintf("✓ WP breakdown completed (%d rows)\n\n", nrow(pk_by_wp)))

# ═══════════════════════════════════════════════════════════════════
# 9. EXPORT RESULTS
# ═══════════════════════════════════════════════════════════════════

cat("Exporting results...\n")

# Main HEU calculation table
heu_summary <- heu_calc %>%
  arrange(desc(pk_total)) %>%
  select(
    employee,
    total_hours,
    day_equiv_declared,
    day_equiv_declared_rounded,
    day_equiv_base,
    parental_leave_days,
    day_equiv_max,
    day_equiv_capped,
    perso_costs_RP,
    heu_daily_rate,
    pk_total
  )

# WP detail
wp_detail <- pk_by_wp %>%
  select(employee, wp_title, hours, day_equiv_wp_rounded, pk_wp) %>%
  arrange(employee, wp_title)

# Export
output_file <- file.path(output_dir, "robin_heu_pipeline_method_v2.xlsx")
write_xlsx(list(
  "HEU_Summary" = heu_summary,
  "WP_Detail" = wp_detail,
  "HEU_Cap_Details" = heu_cap,
  "Active_Months" = robin_active
), output_file)

cat("✓ Results exported to:\n")
cat("  ", output_file, "\n\n")

# Display summary
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  SUMMARY\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

print(heu_summary, n = Inf)

cat("\n")
cat("Total PK:", sprintf("%.2f EUR", sum(heu_summary$pk_total, na.rm = TRUE)), "\n")
cat("\n")

# ═══════════════════════════════════════════════════════════════════
# 10. COMPARISON WITH STELLA
# ═══════════════════════════════════════════════════════════════════

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  COMPARISON WITH STELLA\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# Expected values from Stella
stella_values <- tibble(
  employee = c("Mercedes Berlin", "Alejandra Campos", "Daniela Chiran", "Miljana Cosic",
               "Robert Gohla", "Angela Heni", "Jonathan Loeffler", "Clémentine Roth",
               "Tea Sarenkapa", "Nadja Schlichenmaier"),
  stella_months = c(18, 14, 18, 18, 18, 2, 18, 18, 7, 13),
  stella_max_tage = c(242.0, 251.0, 242.0, 298.5, 322.5, 22.5, 322.5, 238.5, 94.0, 233.0),
  stella_daily_rate = c(410.29, 440.57, 438.12, 437.25, 686.59, 478.51, 976.64, 381.68, 256.22, 361.85),
  stella_pk_total = c(4102.93, 7269.35, 15553.38, 12243.01, 17851.39, 2631.80, 14161.30, 33397.16, 13707.99, 25872.16)
)

comparison <- heu_summary %>%
  left_join(stella_values, by = "employee") %>%
  left_join(robin_active %>% select(employee, n_active_months), by = "employee") %>%
  mutate(
    diff_months = n_active_months - stella_months,
    diff_max_tage = day_equiv_max - stella_max_tage,
    diff_daily_rate = heu_daily_rate - stella_daily_rate,
    diff_pk_total = pk_total - stella_pk_total,
    pct_diff_pk = (diff_pk_total / stella_pk_total) * 100
  )

cat("Per-employee comparison:\n\n")
for (i in 1:nrow(comparison)) {
  row <- comparison[i,]
  cat(sprintf("%s:\n", row$employee))
  cat(sprintf("  Months:       %2d (Ours) vs %2d (Stella) | Diff: %+2d\n",
              row$n_active_months, row$stella_months, row$diff_months))
  cat(sprintf("  Max Tage:     %.1f (Ours) vs %.1f (Stella) | Diff: %+.1f\n",
              row$day_equiv_max, row$stella_max_tage, row$diff_max_tage))
  cat(sprintf("  Daily Rate:   %.2f (Ours) vs %.2f (Stella) | Diff: %+.2f\n",
              row$heu_daily_rate, row$stella_daily_rate, row$diff_daily_rate))
  cat(sprintf("  PK Total:     %.2f (Ours) vs %.2f (Stella) | Diff: %+.2f (%.1f%%)\n\n",
              row$pk_total, row$stella_pk_total, row$diff_pk_total, row$pct_diff_pk))
}

cat("═══════════════════════════════════════════════════════════════════\n")
cat(sprintf("TOTAL PK (Ours):   %.2f EUR\n", sum(heu_summary$pk_total, na.rm = TRUE)))
cat(sprintf("TOTAL PK (Stella): %.2f EUR\n", sum(stella_values$stella_pk_total)))
cat(sprintf("DIFFERENCE:        %.2f EUR (%.1f%%)\n",
            sum(heu_summary$pk_total, na.rm = TRUE) - sum(stella_values$stella_pk_total),
            100 * (sum(heu_summary$pk_total, na.rm = TRUE) - sum(stella_values$stella_pk_total)) / sum(stella_values$stella_pk_total)))
cat("═══════════════════════════════════════════════════════════════════\n\n")
