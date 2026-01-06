# 06b_payroll_hybrid.R
# -----------------------------------------------------------------------------
# HYBRID PAYROLL APPROACH
#
# This module implements a hybrid approach to address gaps in DATEV payroll:
# 1. Calculate average monthly cost per person from DATEV (where available)
# 2. Use actual DATEV costs where they exist
# 3. For months with missing DATEV but FTE data shows work → estimate cost
#    using: average_monthly_cost × FTE_that_month
#
# This addresses Tracey's concern about late salary payments creating gaps
# while still using actual costs where available.
# -----------------------------------------------------------------------------

cat("→ Building hybrid payroll (DATEV + FTE estimates)...\n")

# ---- Step 1: Get FTE timeline for each person ------------------------------
# Parse Personio FTE data
fte_raw <- read_csv2(file.path(dir_fte, "Wochenarbeitszeit.csv"),
                     locale = locale(decimal_mark = ",", grouping_mark = "."),
                     show_col_types = FALSE) %>%
  clean_names()

# Prepare FTE timeline
fte_timeline <- fte_raw %>%
  filter(!is.na(personalnummer), status %in% c("Aktiv", "Auszeit")) %>%
  mutate(
    effective_date = dmy(wirksamkeitsdatum),
    entity_code = str_sub(personalnummer, 1, 4),
    pers_nr_short = as.integer(str_remove(str_sub(personalnummer, 5), "^0+"))
  ) %>%
  filter(!is.na(effective_date), !is.na(fte)) %>%
  arrange(entity_code, pers_nr_short, effective_date) %>%
  select(entity_code, pers_nr_short, effective_date, fte, status)

# ---- Step 2: Create payroll_month from payroll_linked ----------------------
# Aggregate payroll by person-month (needed if not already created by pipeline)
if (!exists("payroll_month")) {
  payroll_month <- payroll_linked %>%
    group_by(du_id, entity_code, pers_nr_short, month) %>%
    summarise(
      monat_kosten = sum(gesamtkosten, na.rm = TRUE),
      surname_pay  = first(surname_pay),
      given_pay    = first(given_pay),
      .groups = "drop"
    )
}

# ---- Step 3: Calculate average monthly cost from DATEV ---------------------
# For each person, calculate their average monthly cost from actual DATEV data
person_avg_cost <- payroll_month %>%
  group_by(du_id, entity_code) %>%
  summarise(
    avg_monthly_cost = mean(monat_kosten, na.rm = TRUE),
    months_with_data = n(),
    surname_pay = first(surname_pay),
    given_pay = first(given_pay),
    .groups = "drop"
  ) %>%
  filter(avg_monthly_cost > 0, months_with_data > 0)

# ---- Step 3: Create complete month grid ------------------------------------
# Generate all months in the period for all active employees
month_grid <- expand_grid(
  month = seq.Date(
    from = floor_date(period_start, "month"),
    to = floor_date(period_end, "month"),
    by = "month"
  ),
  du_id = unique(person_avg_cost$du_id)
) %>%
  left_join(person_avg_cost %>% select(du_id, entity_code, avg_monthly_cost,
                                        surname_pay, given_pay),
            by = "du_id")

# ---- Step 4: Get FTE for each person-month ---------------------------------
# Join with users_key to get personnel numbers
users_fte <- users_key %>%
  select(du_id, entity_code, pers_nr_short) %>%
  distinct()

# For each person-month, get the FTE in effect
person_month_fte <- month_grid %>%
  left_join(users_fte, by = c("du_id", "entity_code")) %>%
  filter(!is.na(pers_nr_short)) %>%
  left_join(
    fte_timeline %>%
      mutate(fte_month = floor_date(effective_date, "month")),
    by = c("entity_code", "pers_nr_short"),
    relationship = "many-to-many"
  ) %>%
  # Keep only FTE changes that are effective on or before this month
  filter(effective_date <= month) %>%
  # For each person-month, take the most recent FTE change
  group_by(du_id, entity_code, month) %>%
  arrange(desc(effective_date)) %>%
  slice(1) %>%
  ungroup() %>%
  select(du_id, entity_code, month, fte, status, avg_monthly_cost,
         surname_pay, given_pay)

# ---- Step 5: Combine actual DATEV with estimates ---------------------------
payroll_month_hybrid <- person_month_fte %>%
  left_join(
    payroll_month %>% select(du_id, entity_code, month, monat_kosten),
    by = c("du_id", "entity_code", "month")
  ) %>%
  mutate(
    # Use actual DATEV where available, otherwise estimate
    cost_source = case_when(
      !is.na(monat_kosten) & monat_kosten > 0 ~ "DATEV_actual",
      status == "Aktiv" & !is.na(avg_monthly_cost) ~ "FTE_estimated",
      TRUE ~ "no_data"
    ),
    monat_kosten_hybrid = case_when(
      cost_source == "DATEV_actual" ~ monat_kosten,
      cost_source == "FTE_estimated" ~ avg_monthly_cost * fte,
      TRUE ~ NA_real_
    )
  ) %>%
  filter(!is.na(monat_kosten_hybrid), monat_kosten_hybrid > 0)

# ---- Summary statistics -----------------------------------------------------
hybrid_summary <- payroll_month_hybrid %>%
  count(cost_source) %>%
  mutate(pct = scales::percent(n / sum(n)))

cat("Hybrid payroll summary:\n")
print(hybrid_summary, n = Inf)

# Compare with original DATEV-only
cat(sprintf("\nOriginal DATEV-only: %d person-months\n", nrow(payroll_month)))
cat(sprintf("Hybrid approach:     %d person-months\n", nrow(payroll_month_hybrid)))
cat(sprintf("Additional coverage: %+d person-months (%.1f%%)\n",
            nrow(payroll_month_hybrid) - nrow(payroll_month),
            100 * (nrow(payroll_month_hybrid) - nrow(payroll_month)) / nrow(payroll_month)))

cat("✓ Hybrid payroll complete\n\n")
