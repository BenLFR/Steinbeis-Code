# calculate_robin_heu_like_pipeline_v4.R
# ROBIN HEU costs using pipeline methodology (Stella-like robust)
# Period: 01.03.2024 - 31.08.2025
#
# v4 fixes:
#   - Use PAYROLL months as primary source for month counting
#   - Hybrid-safe override: use TIMESHEET months only if it agrees with payroll (diff <= 1 month)
#   - Deduplicate FTE at DU_ID level (fix Alejandra duplicate personalnummer issue)
#   - Keep Miljana Cosic parental leave (24 days) override
#   - Audit DATEV month coverage (detect missing entity/month exports)

suppressPackageStartupMessages({
  library(tidyverse)
  library(janitor)
  library(lubridate)
  library(writexl)
})

source("scripts/pipeline/modules/01_utils.R")  # provides round_half(), normalize_name()

cat("\n═══════════════════════════════════════════════════════════════════\n")
cat("  ROBIN HEU COSTS (Pipeline Methodology) - v4 (Stella-like robust)\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# ═══════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════
rp_start <- as.Date("2024-03-01")
rp_end   <- as.Date("2025-08-31")
rp_months <- seq(floor_date(rp_start, "month"), floor_date(rp_end, "month"), by = "month")

# Month source strategy:
#  - "payroll"       : payroll months only (best baseline)
#  - "timesheet"     : timesheet months only (DO NOT use for this case; v3 blew up)
#  - "hybrid_safe"   : payroll months, but if |n_payroll - n_timesheet| <= 1, use timesheet months
MONTH_SOURCE <- "hybrid_safe"

repo_root <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/datev-data"
dir_fte   <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/fte-liste"
dir_db    <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben"
output_dir <- file.path(dir_db, "qa")

robin_hours_file <- file.path(output_dir, "robin_hours_by_period_20240301_20250831.csv")

cat("Period:", format(rp_start, "%d.%m.%Y"), "to", format(rp_end, "%d.%m.%Y"), "\n")
cat("Months:", length(rp_months), "\n")
cat("Month source:", MONTH_SOURCE, "\n\n")

# ═══════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════

audit_datev_coverage <- function(payroll_tbl, rp_months) {
  
  cov <- payroll_tbl %>%
    distinct(entity_code, month) %>%
    count(entity_code, name = "n_months") %>%
    arrange(entity_code)
  
  expected_n <- length(rp_months)
  cat("DATEV coverage by entity_code:\n")
  print(cov, n = Inf)
  cat("\nExpected months:", expected_n, "\n\n")
  
  # Missing months per entity (IMPORTANT: force class Date after setdiff)
  miss <- payroll_tbl %>%
    distinct(entity_code, month) %>%
    group_by(entity_code) %>%
    summarise(
      missing_months = list({
        mm <- setdiff(rp_months, month)
        # setdiff() can drop Date class -> coerce back safely
        if (!inherits(mm, "Date")) mm <- as.Date(mm, origin = "1970-01-01")
        sort(mm)
      }),
      .groups = "drop"
    ) %>%
    mutate(
      n_missing = purrr::map_int(missing_months, length)
    ) %>%
    filter(n_missing > 0)
  
  if (nrow(miss) > 0) {
    cat("⚠ Missing DATEV months detected (entity_code):\n")
    miss %>%
      mutate(
        missing_months = purrr::map_chr(
          missing_months,
          ~ paste(format(.x, "%Y-%m"), collapse = ", ")
        )
      ) %>%
      select(entity_code, n_missing, missing_months) %>%
      print(n = Inf)
    cat("\n")
  }
  
  invisible(list(coverage = cov, missing = miss))
}


# ═══════════════════════════════════════════════════════════════════
# 1) LOAD ROBIN HOURS (already aggregated)
# ═══════════════════════════════════════════════════════════════════
cat("Loading ROBIN hours...\n")
robin_hours <- read_csv(robin_hours_file, show_col_types = FALSE)

robin_by_person_wp <- robin_hours %>%
  group_by(du_id, employee, dwp_id, wp_title) %>%
  summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop")

robin_by_person <- robin_by_person_wp %>%
  group_by(du_id, employee) %>%
  summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop")

cat(sprintf("✓ %d employees, %.2f total hours\n\n",
            nrow(robin_by_person), sum(robin_by_person$total_hours)))

# ═══════════════════════════════════════════════════════════════════
# 2) LOAD PAYROLL (DATEV)
# ═══════════════════════════════════════════════════════════════════
cat("Loading DATEV payroll...\n")

read_datev_file <- function(f) {
  read_delim(f, delim = ";",
             locale = locale(decimal_mark = ",", grouping_mark = "."),
             show_col_types = FALSE,
             skip = 8) %>%
    clean_names()
}

datev_files <- list.files(dir_datev, pattern = "_Personalkosten_.*\\.csv$", full.names = TRUE, recursive = TRUE) %>%
  sort()

payroll_raw <- map_dfr(datev_files, ~read_datev_file(.x) %>% mutate(src_file = basename(.x)))

datev_gk_col <- names(payroll_raw) %>% str_subset("^gesamtkosten") %>% .[1]
if (is.na(datev_gk_col)) stop("Could not find a 'gesamtkosten*' column in DATEV input files.")

payroll <- payroll_raw %>%
  mutate(
    entity_code = str_extract(src_file, "^\\d{5}") %>% str_sub(-4L),
    month_str   = str_extract(src_file, "\\d{2}[-_]\\d{4}"),
    month       = month_str %>% str_replace("_", "-") %>% parse_date_time("my") %>% floor_date("month") %>% as.Date(),
    pers_nr     = as.character(pers_nr),
    gesamtkosten = .data[[datev_gk_col]]
  ) %>%
  filter(month >= floor_date(rp_start, "month"),
         month <= floor_date(rp_end, "month"),
         !is.na(pers_nr),
         str_detect(pers_nr, "^[0-9]+$")) %>%
  mutate(pers_nr_short = as.integer(str_remove(pers_nr, "^0+"))) %>%
  select(entity_code, month, pers_nr_short, nachname, vorname, gesamtkosten)

cat(sprintf("✓ %d payroll rows loaded\n", nrow(payroll)))
cat(sprintf("  Total payroll (raw): %.2f EUR\n\n", sum(payroll$gesamtkosten, na.rm = TRUE)))

# Audit month coverage (key remark: missing entity/month exports cause payroll gaps)
audit_datev_coverage(payroll, rp_months)

# ═══════════════════════════════════════════════════════════════════
# 3) LOAD FTE (Personio)
# ═══════════════════════════════════════════════════════════════════
cat("Loading FTE data...\n")

fte_raw <- read_delim(file.path(dir_fte, "Wochenarbeitszeit.csv"),
                      delim = ";",
                      locale = locale(decimal_mark = ",", grouping_mark = "."),
                      show_col_types = FALSE) %>%
  clean_names() %>%
  mutate(
    wirksamkeitsdatum = dmy(wirksamkeitsdatum),
    entity_code = str_sub(as.character(personalnummer), 1, 4),
    pers_nr_short = as.integer(str_remove(str_sub(as.character(personalnummer), 5), "^0+"))
  ) %>%
  filter(status == "Aktiv", !is.na(wirksamkeitsdatum)) %>%
  arrange(entity_code, pers_nr_short, wirksamkeitsdatum, desc(fte)) %>%
  group_by(entity_code, pers_nr_short, wirksamkeitsdatum) %>%
  slice(1) %>%   # de-dup within same personalnummer/date
  ungroup()

cat(sprintf("✓ %d FTE records loaded (after within-personalnummer dedup)\n\n", nrow(fte_raw)))

# ═══════════════════════════════════════════════════════════════════
# 4) LINK PERSONS (du_id <-> entity_code + pers_nr_short)
# ═══════════════════════════════════════════════════════════════════
cat("Linking persons...\n")

d_user <- read_csv(file.path(dir_db, "..", "d_user.csv"), show_col_types = FALSE) %>%
  clean_names() %>%
  mutate(du_hr_numbers = as.character(du_hr_numbers))

# Primary mapping: name-based (kept from your pipeline)
users_key <- payroll %>%
  mutate(
    surname_norm = normalize_name(nachname),
    given_norm   = normalize_name(vorname)
  ) %>%
  distinct(entity_code, pers_nr_short, surname_norm, given_norm) %>%
  left_join(
    d_user %>%
      mutate(
        surname_norm = normalize_name(du_surname),
        given_norm   = normalize_name(du_name)
      ) %>%
      select(du_id, surname_norm, given_norm),
    by = c("surname_norm", "given_norm"),
    relationship = "many-to-many"
  ) %>%
  filter(!is.na(du_id)) %>%
  select(du_id, entity_code, pers_nr_short) %>%
  distinct()

# Fuzzy fallback for compound names (kept)
payroll_unmatched <- payroll %>%
  anti_join(users_key, by = c("entity_code", "pers_nr_short")) %>%
  mutate(
    surname_norm = normalize_name(nachname),
    given_norm   = normalize_name(vorname),
    surname_first = word(surname_norm, 1),
    surname_last  = word(surname_norm, -1),
    given_last    = word(given_norm, -1)
  ) %>%
  distinct(entity_code, pers_nr_short, surname_first, surname_last, given_last)

users_fuzzy_match <- payroll_unmatched %>%
  left_join(
    d_user %>%
      mutate(
        surname_norm = normalize_name(du_surname),
        given_norm   = normalize_name(du_name)
      ) %>%
      select(du_id, surname_norm, given_norm),
    by = c("surname_first" = "surname_norm", "given_last" = "given_norm")
  ) %>%
  filter(!is.na(du_id)) %>%
  select(du_id, entity_code, pers_nr_short)

users_fuzzy_match2 <- payroll_unmatched %>%
  anti_join(users_fuzzy_match, by = c("entity_code", "pers_nr_short")) %>%
  left_join(
    d_user %>%
      mutate(
        surname_norm = normalize_name(du_surname),
        given_norm   = normalize_name(du_name)
      ) %>%
      select(du_id, surname_norm, given_norm),
    by = c("surname_last" = "surname_norm", "given_last" = "given_norm")
  ) %>%
  filter(!is.na(du_id)) %>%
  select(du_id, entity_code, pers_nr_short)

users_key <- bind_rows(users_key, users_fuzzy_match, users_fuzzy_match2) %>%
  distinct()

cat(sprintf("✓ %d person-keys linked (fuzzy adds: %d)\n\n",
            nrow(users_key), nrow(users_fuzzy_match) + nrow(users_fuzzy_match2)))

# ═══════════════════════════════════════════════════════════════════
# 4a) MONTHS PER EMPLOYEE (Payroll primary + hybrid-safe)
# ═══════════════════════════════════════════════════════════════════
cat("Determining months per employee...\n")

payroll_with_ids <- payroll %>%
  inner_join(users_key, by = c("entity_code", "pers_nr_short")) %>%
  filter(!is.na(du_id))

employee_payroll_months <- payroll_with_ids %>%
  filter(!is.na(gesamtkosten), gesamtkosten > 0) %>%
  group_by(du_id) %>%
  summarise(
    payroll_months = list(sort(unique(month))),
    n_payroll_months = n_distinct(month),
    .groups = "drop"
  )

# Timesheet months (ONLY used when safe)
d_pr <- read_csv(file.path(dir_db, "d_project.csv"), show_col_types = FALSE) %>% clean_names()
d_wp <- read_csv(file.path(dir_db, "d_workpackage.csv"), show_col_types = FALSE) %>% clean_names()
d_wt <- read_csv(file.path(dir_db, "d_worktime.csv"), show_col_types = FALSE) %>% clean_names()
n_w2wp <- read_csv(file.path(dir_db, "n_worktime2workpackage.csv"), show_col_types = FALSE) %>% clean_names()

robin_pr <- d_pr %>% filter(str_detect(str_to_upper(dpr_title), "ROBIN"))
robin_wps <- d_wp %>% filter(dpr_id %in% robin_pr$dpr_id)

d_wt_robin <- d_wt %>%
  mutate(dwt_date = as_date(dwt_date)) %>%
  filter(dwt_date >= rp_start, dwt_date <= rp_end)

robin_timesheet <- n_w2wp %>%
  filter(dwp_id %in% robin_wps$dwp_id) %>%
  inner_join(d_wt_robin, by = "dwt_id")

employee_timesheet_months <- robin_timesheet %>%
  mutate(month = floor_date(dwt_date, "month")) %>%
  group_by(du_id) %>%
  summarise(
    timesheet_months = list(sort(unique(month))),
    n_timesheet_months = n_distinct(month),
    .groups = "drop"
  )

# Merge and choose per employee
employee_months <- robin_by_person %>%
  select(du_id, employee) %>%
  left_join(employee_payroll_months, by = "du_id") %>%
  left_join(employee_timesheet_months, by = "du_id") %>%
  mutate(
    payroll_months  = map(payroll_months,  ~ if (is.null(.x)) as.Date(character()) else .x),
    timesheet_months = map(timesheet_months, ~ if (is.null(.x)) as.Date(character()) else .x),
    n_payroll_months  = replace_na(n_payroll_months, 0L),
    n_timesheet_months = replace_na(n_timesheet_months, 0L)
  ) %>%
  rowwise() %>%
  mutate(
    chosen = list(choose_employee_months(payroll_months, timesheet_months, method = MONTH_SOURCE)),
    active_months = list(chosen$months),
    month_source  = chosen$source,
    n_active_months = length(active_months)
  ) %>%
  ungroup() %>%
  select(du_id, employee, active_months, n_active_months, month_source,
         n_payroll_months, n_timesheet_months)

cat("Month selection summary:\n")
employee_months %>%
  count(month_source) %>%
  print(n = Inf)
cat("\n")

# ═══════════════════════════════════════════════════════════════════
# 5) FTE PERIODS (DU_ID-level dedup)
# ═══════════════════════════════════════════════════════════════════
cat("Building DU_ID-level FTE periods (dedup across personalnummer)...\n")

# Link FTE to du_id then dedup by (du_id, wirksamkeitsdatum)
fte_du <- fte_raw %>%
  inner_join(users_key, by = c("entity_code", "pers_nr_short")) %>%
  filter(!is.na(du_id)) %>%
  group_by(du_id, wirksamkeitsdatum) %>%
  summarise(
    fte = max(fte, na.rm = TRUE),     # critical: prevents Alejandra double-counting
    .groups = "drop"
  ) %>%
  arrange(du_id, wirksamkeitsdatum)

# Fallback: ensure every ROBIN employee has at least one FTE record at rp_start
missing_fte_ids <- setdiff(employee_months$du_id, unique(fte_du$du_id))
if (length(missing_fte_ids) > 0) {
  cat(sprintf("⚠ %d employee(s) missing FTE in Personio; applying fallback fte=1.0 at rp_start\n", length(missing_fte_ids)))
  fte_du <- bind_rows(
    fte_du,
    tibble(du_id = missing_fte_ids, wirksamkeitsdatum = rp_start, fte = 1.0)
  ) %>% arrange(du_id, wirksamkeitsdatum)
}

fte_periods_du <- fte_du %>%
  group_by(du_id) %>%
  mutate(
    start = pmax(wirksamkeitsdatum, rp_start),
    end   = pmin(lead(wirksamkeitsdatum, default = rp_end + 1) - 1, rp_end)
  ) %>%
  ungroup() %>%
  filter(start <= end) %>%
  select(du_id, start, end, fte)

# ═══════════════════════════════════════════════════════════════════
# 6) HEU CAP (months filtered by employee_months)
# ═══════════════════════════════════════════════════════════════════
cat("Calculating HEU cap...\n")

grid <- fte_periods_du %>%
  left_join(employee_months %>% select(du_id, active_months), by = "du_id") %>%
  filter(!is.na(active_months)) %>%
  unnest(active_months) %>%
  rename(month = active_months) %>%
  mutate(
    m_start = month,
    m_end   = month + days(29),  # HEU 30-day convention
    ov_start = pmax(start, m_start),
    ov_end   = pmin(end, m_end),
    days_overlap = pmax(0L, as.integer(ov_end - ov_start + 1L)),
    coverage_30  = days_overlap / 30
  ) %>%
  filter(coverage_30 > 0)

heu_cap_base <- grid %>%
  group_by(du_id) %>%
  summarise(
    day_equiv_base = sum((215 / 12) * fte * coverage_30, na.rm = TRUE),
    n_months_calculated = n_distinct(month),
    .groups = "drop"
  )

# Parental leave
parental_leave_file <- file.path(repo_root, "elternurlaub24-251027.csv")
if (file.exists(parental_leave_file)) {
  parental_leave_raw <- read_delim(parental_leave_file, delim = ";",
                                   locale = locale(decimal_mark = ",", grouping_mark = "."),
                                   show_col_types = FALSE) %>% clean_names()
  
  parental_leave_days <- parental_leave_raw %>%
    mutate(
      von_date  = dmy(von),
      bis_date  = dmy(bis),
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
} else {
  parental_leave_days <- tibble(du_id = integer(), parental_leave_days = numeric())
  cat("⚠ No parental leave file found\n")
}

# Miljana override (24 days)
miljana_id <- d_user %>%
  filter(str_detect(du_surname, "Cosic"), str_detect(du_name, "Miljana")) %>%
  pull(du_id)

if (length(miljana_id) > 0 && !miljana_id %in% parental_leave_days$du_id) {
  cat(sprintf("⚠ Adding missing parental leave for Miljana Cosic (du_id: %d): 24 days\n", miljana_id))
  parental_leave_days <- bind_rows(parental_leave_days, tibble(du_id = miljana_id, parental_leave_days = 24))
}

heu_cap <- heu_cap_base %>%
  left_join(parental_leave_days, by = "du_id") %>%
  mutate(
    parental_leave_days = coalesce(parental_leave_days, 0),
    day_equiv_max = round_half(day_equiv_base - parental_leave_days)
  ) %>%
  left_join(employee_months %>% select(du_id, n_active_months, month_source), by = "du_id")

cat(sprintf("✓ HEU cap calculated for %d persons\n\n", nrow(heu_cap)))

# ═══════════════════════════════════════════════════════════════════
# 7) PAYROLL COSTS IN RP (by du_id)
# ═══════════════════════════════════════════════════════════════════
cat("Calculating payroll costs...\n")

perso_costs_RP <- payroll_with_ids %>%
  group_by(du_id) %>%
  summarise(perso_costs_RP = sum(gesamtkosten, na.rm = TRUE), .groups = "drop")

cat(sprintf("✓ Total payroll (linked): %.2f EUR\n\n", sum(perso_costs_RP$perso_costs_RP, na.rm = TRUE)))

# ═══════════════════════════════════════════════════════════════════
# 8) HEU DAILY RATE & PK TOTAL
# ═══════════════════════════════════════════════════════════════════
cat("Calculating HEU daily rate and costs...\n")

heu_calc <- robin_by_person %>%
  left_join(heu_cap, by = "du_id") %>%
  left_join(perso_costs_RP, by = "du_id") %>%
  mutate(
    heu_daily_rate = if_else(day_equiv_max > 0, perso_costs_RP / day_equiv_max, NA_real_),
    day_equiv_declared = total_hours / 8,
    day_equiv_declared_rounded = round_half(day_equiv_declared),
    day_equiv_capped = pmin(day_equiv_declared_rounded, day_equiv_max),
    pk_total = day_equiv_capped * heu_daily_rate
  )

cat(sprintf("✓ HEU calculations completed\n"))
cat(sprintf("  Total day-equiv (capped): %.2f\n", sum(heu_calc$day_equiv_capped, na.rm = TRUE)))
cat(sprintf("  Total PK: %.2f EUR\n\n", sum(heu_calc$pk_total, na.rm = TRUE)))

# ═══════════════════════════════════════════════════════════════════
# 9) WP BREAKDOWN
# ═══════════════════════════════════════════════════════════════════
cat("Calculating WP breakdown...\n")

pk_by_wp <- robin_by_person_wp %>%
  left_join(heu_calc %>% select(du_id, employee, total_hours, day_equiv_capped, heu_daily_rate, pk_total),
            by = c("du_id", "employee")) %>%
  mutate(
    hours_pct = if_else(total_hours > 0, hours / total_hours, 0),
    day_equiv_wp = day_equiv_capped * hours_pct,
    day_equiv_wp_rounded = round_half(day_equiv_wp),
    pk_wp = day_equiv_wp_rounded * heu_daily_rate
  )

cat(sprintf("✓ WP breakdown completed (%d rows)\n\n", nrow(pk_by_wp)))

# ═══════════════════════════════════════════════════════════════════
# 10) EXPORT
# ═══════════════════════════════════════════════════════════════════
cat("Exporting results...\n")

heu_summary <- heu_calc %>%
  arrange(desc(pk_total)) %>%
  select(
    employee,
    n_active_months, month_source,
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

wp_detail <- pk_by_wp %>%
  select(employee, wp_title, hours, day_equiv_wp_rounded, pk_wp) %>%
  arrange(employee, wp_title)

output_file <- file.path(output_dir, "robin_heu_pipeline_method_v4.xlsx")
write_xlsx(list(
  "HEU_Summary"       = heu_summary,
  "WP_Detail"         = wp_detail,
  "HEU_Cap_Details"   = heu_cap,
  "Employee_Months"   = employee_months
), output_file)

cat("✓ Results exported to:\n  ", output_file, "\n\n")

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  SUMMARY\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

print(heu_summary, n = Inf)
cat("\nTotal PK:", sprintf("%.2f EUR", sum(heu_summary$pk_total, na.rm = TRUE)), "\n\n")
