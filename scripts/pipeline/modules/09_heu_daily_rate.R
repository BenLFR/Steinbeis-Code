# 09_heu_daily_rate.R
# Calcul du daily rate HEU avec prorata jour-calendaire
# Hypothèses HEU:
# - "mois" = 30 jours (prorata coverage_30)
# - cap = somme_mois ( (215/12) * FTE_m * coverage_30 ), arrondi au 0,5
# --------------------------------------------------------------------

message("Computing HEU daily rate...")

rp_start <- rp_month_floor; rp_end <- rp_month_ceiling
rp_months <- seq(floor_date(rp_start, "month"), floor_date(rp_end, "month"), by = "month")

# 12.a Construire des périodes d'emploi/FTE depuis Personio
# fte_raw provient de la section 7, déjà filtré sur status == "Aktiv"
fte_periods <- fte_raw %>%
  arrange(entity_code, pers_nr_short, wirksamkeitsdatum) %>%
  group_by(entity_code, pers_nr_short) %>%
  mutate(start = wirksamkeitsdatum,
         end   = lead(wirksamkeitsdatum, default = rp_end + 1) - 1) %>%
  ungroup() %>%
  select(entity_code, pers_nr_short, start, end, fte)

# Lier aux personnes internes (du_id) puis borner à la RP
# Deduplicate users_key to avoid many-to-many (multi-CC persons)
users_key_unique <- users_key %>%
  select(du_id, entity_code, pers_nr_short) %>%
  distinct(entity_code, pers_nr_short, .keep_all = TRUE)

fte_periods_du <- fte_periods %>%
  inner_join(users_key_unique,
             by = c("entity_code","pers_nr_short")) %>%
  mutate(start = pmax(start, rp_start),
         end   = pmin(end,   rp_end)) %>%
  filter(start <= end)

# 12.b Proratiser par mois HEU (30 jours)
grid <- tidyr::crossing(fte_periods_du, month = rp_months) %>%
  mutate(m_start   = month,
         m_end     = month + lubridate::days(29),      # 30 jours
         ov_start  = pmax(start, m_start),
         ov_end    = pmin(end,   m_end),
         days_overlap = pmax(0L, as.integer(ov_end - ov_start + 1L)),
         coverage_30  = days_overlap / 30) %>%
  filter(coverage_30 > 0)

# 12.b.1 Load and process parental leave (Elternzeit) data
# Parental leave days must be deducted from max declarable day-equivalents (HEU rule)
parental_leave_file <- file.path(repo_root, "elternurlaub24-251027.csv")

if (file.exists(parental_leave_file)) {
  message("✓ Loading parental leave data from: ", parental_leave_file)

  parental_leave_raw <- read_delim(parental_leave_file,
                                   delim = ";",
                                   locale = locale(decimal_mark = ",", grouping_mark = "."),
                                   show_col_types = FALSE) %>%
    clean_names()

  # Parse personnel numbers and convert to entity_code + pers_nr_short
  parental_leave_parsed <- parental_leave_raw %>%
    mutate(
      von_date = dmy(von),
      bis_date = dmy(bis),
      dauer_std = as.numeric(str_replace(dauer_std, ",", "."))
    ) %>%
    filter(von_date <= rp_end, bis_date >= rp_start) %>%  # only RP period
    separate_rows(personalnummer_n, sep = ",") %>%
    mutate(
      personalnummer_n = str_trim(personalnummer_n),
      entity_code = str_sub(personalnummer_n, 1, 4),
      pers_nr_short = as.integer(str_remove(str_sub(personalnummer_n, 5), "^0+"))
    ) %>%
    filter(!is.na(entity_code), !is.na(pers_nr_short))

  # Link to du_id and sum day-equivalents (1 day = 8 hours)
  parental_leave_days <- parental_leave_parsed %>%
    left_join(users_key %>% select(du_id, entity_code, pers_nr_short),
              by = c("entity_code", "pers_nr_short")) %>%
    filter(!is.na(du_id)) %>%
    group_by(du_id) %>%
    summarise(parental_leave_days = sum(dauer_std / 8, na.rm = TRUE),
              .groups = "drop")

  message("✓ Parental leave processed: ", nrow(parental_leave_days), " person(s) with leave during RP")
} else {
  message("⚠ Parental leave file not found: ", parental_leave_file, " - proceeding without deduction")
  parental_leave_days <- tibble(du_id = integer(), parental_leave_days = numeric())
}

# 12.c Cap HEU par personne, arrondi au 0,5 (AVEC déduction Elternzeit)
heu_cap <- grid %>%
  group_by(du_id) %>%
  summarise(day_equiv_base = sum((215/12) * fte * coverage_30, na.rm = TRUE),
            .groups = "drop") %>%
  left_join(parental_leave_days, by = "du_id") %>%
  mutate(
    parental_leave_days = coalesce(parental_leave_days, 0),
    day_equiv_max = round_half(day_equiv_base - parental_leave_days)
  )

# 12.d Daily rate OFFICIEL = coûts RÉELS (DATEV) sur la période / cap
perso_costs_RP <- payroll_linked %>%
  mutate(month = as.Date(month)) %>%
  filter(month >= rp_start, month <= rp_end) %>%
  group_by(du_id) %>%
  summarise(perso_costs_RP = sum(gesamtkosten, na.rm = TRUE), .groups = "drop")

heu_base <- heu_cap %>%
  left_join(perso_costs_RP, by = "du_id") %>%
  left_join(d_user %>% select(du_id, du_name, du_surname), by = "du_id") %>%
  mutate(heu_daily_rate = if_else(day_equiv_max > 0,
                                  perso_costs_RP / day_equiv_max, NA_real_))

# 12.e Déclaration d'heures HEU sans double comptage pour contrôle
# Heures totales par du_id×mois (toutes entités, déjà dédupliquées)
mf_uniq <- wt_full %>%
  mutate(month = as.Date(month)) %>%
  transmute(du_id, month, hours_worked = sec_any / 3600)

# Part HEU dans les heures mensuelles déclarées par WP
wp_share <- cost_by_pr %>%
  mutate(month = as.Date(month)) %>%
  filter(month >= floor_date(rp_start, "month"),
         month <= floor_date(rp_end,   "month")) %>%
  group_by(du_id, month) %>%
  summarise(hours_all = sum(hours, na.rm = TRUE), .groups = "drop") %>%
  left_join(
    cost_by_pr %>%
      mutate(month = as.Date(month)) %>%
      filter(is_heu,
             month >= floor_date(rp_start, "month"),
             month <= floor_date(rp_end,   "month")) %>%
      group_by(du_id, month) %>%
      summarise(hours_heu = sum(hours, na.rm = TRUE), .groups = "drop"),
    by = c("du_id","month")
  ) %>%
  mutate(hours_heu = coalesce(hours_heu, 0),
         hours_all = coalesce(hours_all, 0),
         heu_share = if_else(hours_all > 0, pmin(1, hours_heu / hours_all), 0)) %>%
  left_join(mf_uniq, by = c("du_id","month")) %>%
  mutate(hours_declared_heu_nodup = heu_share * coalesce(hours_worked, 0))

declared_heu_days <- wp_share %>%
  group_by(du_id) %>%
  summarise(declared_day_equiv = sum(hours_declared_heu_nodup / 8, na.rm = TRUE),
            .groups = "drop")

# 12.f Contrôle cap vs jours déclarés
heu_control <- heu_base %>%
  select(du_id, day_equiv_max) %>%
  left_join(declared_heu_days, by = "du_id") %>%
  mutate(declared_day_equiv = replace_na(declared_day_equiv, 0),
         over_cap = declared_day_equiv > day_equiv_max)

message("✓ HEU daily rate calculated for ", nrow(heu_base), " persons")

# --- 12bis. Tableau final : daily rate + répartition par projet (RP) --------
# Daily rate par personne (unique pour la RP)
rates <- heu_base %>% select(du_id, du_name, du_surname, heu_daily_rate)

# Jours HEU par personne×projet, sans double comptage (allocation mensuelle)
heu_proj_days <- cost_by_pr %>%
  filter(is_heu, month >= rp_month_floor, month <= rp_month_ceiling) %>%
  group_by(du_id, month) %>%
  mutate(hours_heu_m = sum(hours, na.rm = TRUE)) %>%
  ungroup() %>%
  left_join(mf_uniq %>% select(du_id, month, hours_worked), by = c("du_id","month")) %>%
  mutate(
    heu_hours_nodup_m = pmin(coalesce(hours_heu_m, 0), coalesce(hours_worked, 0)),
    share_wp_in_heu_m = if_else(coalesce(hours_heu_m, 0) > 0, hours / hours_heu_m, 0),
    day_equiv_wp_m    = (heu_hours_nodup_m * share_wp_in_heu_m) / 8
  ) %>%
  group_by(du_id, project_id, project) %>%
  summarise(declared_day_equiv = sum(day_equiv_wp_m, na.rm = TRUE), .groups = "drop")

# Final HEU : daily rate × jours déclarés (par personne×projet)
heu_final_by_project <- heu_proj_days %>%
  left_join(rates, by = "du_id") %>%
  mutate(
    heu_claimable_cost = round(heu_daily_rate * declared_day_equiv, 2),
    is_heu = TRUE
  ) %>%
  arrange(du_id, project)

# Résumé NON-HEU (heures & coûts alloués), pas de daily rate
non_heu_by_project <- cost_by_pr %>%
  filter(!is_heu, month >= rp_month_floor, month <= rp_month_ceiling) %>%
  group_by(du_id, project_id, project) %>%
  summarise(
    hours = sum(hours, na.rm = TRUE),
    cost_alloc = sum(cost, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(is_heu = FALSE) %>%
  arrange(du_id, project)

# === Reporting unifié : Non-HEU = prorata payroll ; HEU = daily-rate × jours capés ===

# 1) Non-HEU
report_non_heu <- cost_by_pr %>%
  filter(!is_heu, month >= rp_month_floor, month <= rp_month_ceiling) %>%
  transmute(
    du_id, entity_code, month, project_id, project, workpackage, wp_title,
    programme = programme, is_heu = FALSE,
    basis = "PRORATA_PAYROLL",
    hours = hours,
    declared_day_equiv = NA_real_,
    rate = NA_real_,
    reported_cost = cost
  )

# 2) HEU via daily-rate (avec cap)
heu_days_by_du_pr <- cost_by_pr %>%
  filter(is_heu, month >= rp_month_floor, month <= rp_month_ceiling) %>%
  group_by(du_id, project_id, project) %>%
  summarise(declared_day_equiv_raw = sum(replace_na(hours, 0)) / 8, .groups = "drop")

heu_days_by_du <- heu_days_by_du_pr %>%
  group_by(du_id) %>%
  summarise(declared_day_equiv_total = sum(declared_day_equiv_raw, na.rm = TRUE), .groups = "drop")

heu_caps <- heu_base %>% select(du_id, day_equiv_max, heu_daily_rate)

heu_days_capped <- heu_days_by_du_pr %>%
  left_join(heu_days_by_du, by = "du_id") %>%
  left_join(heu_caps, by = "du_id") %>%
  mutate(
    scale = if_else(declared_day_equiv_total > 0 & day_equiv_max > 0,
                    pmin(1, day_equiv_max / declared_day_equiv_total), 1),
    declared_day_equiv = declared_day_equiv_raw * coalesce(scale, 1),
    reported_cost = declared_day_equiv * heu_daily_rate
  )

report_heu <- heu_days_capped %>%
  transmute(
    du_id,
    entity_code = NA_character_,
    month = as.Date(NA),
    project_id, project,
    workpackage = NA_integer_, wp_title = NA_character_,
    programme = "HEU", is_heu = TRUE,
    basis = "HEU_DAILY_RATE",
    hours = declared_day_equiv * 8,
    declared_day_equiv,
    rate = heu_daily_rate,
    reported_cost
  )

# Harmonisation des schémas avant empilement
common_cols <- c(
  "du_id","entity_code","month","project_id","project","workpackage","wp_title",
  "programme","is_heu","basis","hours","declared_day_equiv","rate","reported_cost"
)

report_non_heu <- report_non_heu %>%
  mutate(
    entity_code = as.character(entity_code),
    project_id  = as.integer(project_id),
    workpackage = as.integer(workpackage),
    month       = as.Date(month)
  ) %>%
  select(all_of(common_cols))

report_heu <- report_heu %>%
  mutate(
    entity_code = as.character(entity_code),
    project_id  = as.integer(project_id),
    workpackage = as.integer(workpackage),
    month       = as.Date(month)
  ) %>%
  select(all_of(common_cols))

reporting_costs <- bind_rows(report_non_heu, report_heu)

# (optionnel) contrôles rapides
message("Reporting costs (sum): ", scales::comma(sum(reporting_costs$reported_cost, na.rm = TRUE)))
message("Non-HEU share: ", scales::comma(sum(report_non_heu$reported_cost, na.rm = TRUE)))
message("HEU share: ", scales::comma(sum(report_heu$reported_cost, na.rm = TRUE)))
