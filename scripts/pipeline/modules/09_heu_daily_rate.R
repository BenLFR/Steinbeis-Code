# 09_heu_daily_rate.R
# Calcul du daily rate HEU avec prorata jour-calendaire
# Hypothèses HEU:
# - "mois" = 30 jours (prorata coverage_30)
# - cap = somme_mois ( (215/12) * FTE_m * coverage_30 ), arrondi au 0,5
# --------------------------------------------------------------------

message("Computing HEU daily rate...")

rp_start <- rp_month_floor; rp_end <- rp_month_ceiling
rp_months <- seq(floor_date(rp_start, "month"), floor_date(rp_end, "month"), by = "month")

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

# --- Helper: compute HEU base for a given entity scope ----------------------
project_entity_scope <- if (exists("project_entity_scope")) project_entity_scope else list()

get_project_entities <- function(project_name) {
  if (!is.null(project_entity_scope) && project_name %in% names(project_entity_scope)) {
    return(project_entity_scope[[project_name]])
  }
  target_entities
}

compute_heu_base <- function(scope_entities, label) {
  scope_entities <- as.character(scope_entities)

  # 0) Payroll scoped to project entities (numerator)
  payroll_scoped_raw <- payroll %>%
    filter(entity_code %in% scope_entities) %>%
    mutate(month = as.Date(month))

  payroll_scoped_mapped <- payroll_linked %>%
    filter(entity_code %in% scope_entities) %>%
    mutate(month = as.Date(month))

  payroll_unmapped <- payroll_scoped_raw %>%
    left_join(users_key %>% select(entity_code, pers_nr_short, du_id),
              by = c("entity_code", "pers_nr_short")) %>%
    filter(is.na(du_id))

  if (nrow(payroll_unmapped) > 0) {
    message("⚠ Payroll rows unmapped to du_id in scope (", label, "): ", nrow(payroll_unmapped))
    readr::write_csv(payroll_unmapped,
                     file.path(qa_dir, paste0("payroll_unmapped_", label, ".csv")),
                     na = "")
  }

  # 1) Define scope people by payroll (mapped)
  du_scope <- payroll_scoped_mapped %>%
    filter(month >= rp_start, month <= rp_end,
           !is.na(gesamtkosten), gesamtkosten > 0) %>%
    distinct(du_id)

  # 2) FTE: map to du_id across all entities, then collapse to du_id-level
  users_key_unique_all <- users_key %>%
    select(du_id, entity_code, pers_nr_short) %>%
    distinct(du_id, entity_code, pers_nr_short, .keep_all = TRUE)

  fte_du <- fte_raw %>%
    inner_join(users_key_unique_all, by = c("entity_code", "pers_nr_short")) %>%
    semi_join(du_scope, by = "du_id") %>%
    group_by(du_id, wirksamkeitsdatum) %>%
    summarise(fte = max(fte, na.rm = TRUE), .groups = "drop") %>%
    arrange(du_id, wirksamkeitsdatum)

  # 3) Build FTE periods at du_id level
  fte_periods_du <- fte_du %>%
    group_by(du_id) %>%
    mutate(start = wirksamkeitsdatum,
           end   = lead(wirksamkeitsdatum, default = rp_end + 1) - 1) %>%
    ungroup() %>%
    mutate(start = pmax(start, rp_start),
           end   = pmin(end,   rp_end)) %>%
    filter(start <= end)

  # 4) Active months per employee (months with payroll > 0), scoped by entity
  employee_active_months <- payroll_scoped_mapped %>%
    filter(month >= rp_start, month <= rp_end,
           !is.na(gesamtkosten), gesamtkosten > 0) %>%
    group_by(du_id) %>%
    summarise(
      active_months = list(sort(unique(month))),
      n_active_months = n_distinct(month),
      .groups = "drop"
    )

  # Build grid using only active months per employee (entity-scoped)
  grid_raw <- fte_periods_du %>%
    left_join(employee_active_months %>% select(du_id, active_months),
              by = "du_id") %>%
    filter(!is.na(active_months)) %>%
    tidyr::unnest(active_months) %>%
    rename(month = active_months) %>%
    mutate(m_start   = month,
           m_end     = month + lubridate::days(29),      # 30 jours
           ov_start  = pmax(start, m_start),
           ov_end    = pmin(end,   m_end),
           days_overlap = pmax(0L, as.integer(ov_end - ov_start + 1L)),
           coverage_30  = days_overlap / 30,
           eff_fte_raw  = fte * coverage_30) %>%
    filter(coverage_30 > 0)

  # Deduplicate per (du_id, month) and cap eff_fte <= 1
  grid <- grid_raw %>%
    group_by(du_id, month) %>%
    summarise(
      eff_fte = sum(eff_fte_raw, na.rm = TRUE),
      fte_rows = n(),
      .groups = "drop"
    ) %>%
    mutate(eff_fte = pmin(1, eff_fte))

  message("✓ Active months filtering applied (", label, "): ",
          nrow(employee_active_months), " employees with payroll data")
  message("✓ FTE grid deduped (", label, "): ", nrow(grid), " person-months")

  # 12.c Cap HEU par personne, arrondi au 0,5 (AVEC déduction Elternzeit)
  heu_cap <- grid %>%
    group_by(du_id) %>%
    summarise(day_equiv_base = sum((215/12) * eff_fte, na.rm = TRUE),
              .groups = "drop") %>%
    left_join(parental_leave_days, by = "du_id") %>%
    mutate(
      parental_leave_days = coalesce(parental_leave_days, 0),
      day_equiv_max = round_half(day_equiv_base - parental_leave_days)
    )

  # 12.d Daily rate OFFICIEL = coûts RÉELS (DATEV) sur la période / cap
  perso_costs_RP <- payroll_scoped_mapped %>%
    filter(month >= rp_start, month <= rp_end) %>%
    group_by(du_id) %>%
    summarise(perso_costs_RP = sum(gesamtkosten, na.rm = TRUE), .groups = "drop")

  heu_base <- heu_cap %>%
    left_join(perso_costs_RP, by = "du_id") %>%
    left_join(d_user %>% select(du_id, du_name, du_surname), by = "du_id") %>%
    mutate(heu_daily_rate = if_else(day_equiv_max > 0,
                                    perso_costs_RP / day_equiv_max, NA_real_))

  # Missing DATEV months per entity
  datev_months <- payroll_scoped_mapped %>%
    group_by(entity_code) %>%
    summarise(months = list(sort(unique(month))), .groups = "drop")

  missing_months <- datev_months %>%
    rowwise() %>%
    mutate(missing = list(setdiff(rp_months, months))) %>%
    ungroup() %>%
    select(entity_code, missing)

  # Missing DATEV months per person (mapped)
  missing_person_months <- payroll_scoped_mapped %>%
    group_by(du_id) %>%
    summarise(months = list(sort(unique(month))), .groups = "drop") %>%
    rowwise() %>%
    mutate(missing = list(setdiff(rp_months, months))) %>%
    ungroup()

  list(
    heu_base = heu_base,
    heu_cap = heu_cap,
    perso_costs_RP = perso_costs_RP,
    grid_raw = grid_raw,
    grid = grid,
    employee_active_months = employee_active_months,
    missing_months = missing_months,
    missing_person_months = missing_person_months
  )
}

# Compute default HEU base (all target entities)
base_all <- compute_heu_base(target_entities, "ALL")
heu_base <- base_all$heu_base
heu_cap <- base_all$heu_cap
perso_costs_RP <- base_all$perso_costs_RP

# Compute ROBIN-scoped HEU base (if configured)
robin_entities <- get_project_entities("ROBIN")
base_robin <- NULL
if (!is.null(robin_entities)) {
  base_robin <- compute_heu_base(robin_entities, "ROBIN")
}

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

# --- Diagnostics + audit (ROBIN scoped) -------------------------------------
audit_du_id <- 182
audit_project <- "ROBIN"

if (!dir.exists(qa_dir)) dir.create(qa_dir, recursive = TRUE)

if (!is.null(base_robin)) {
  # Payroll by entity + month for audit user
  audit_payroll <- payroll_linked %>%
    mutate(month = as.Date(month)) %>%
    filter(du_id == audit_du_id, month >= rp_start, month <= rp_end) %>%
    group_by(entity_code, month) %>%
    summarise(perso_costs = sum(gesamtkosten, na.rm = TRUE), .groups = "drop") %>%
    arrange(entity_code, month)

  # FTE grid diagnostics (pre/post dedup)
  audit_grid_raw <- base_robin$grid_raw %>%
    filter(du_id == audit_du_id) %>%
    group_by(month) %>%
    summarise(
      raw_rows = n(),
      eff_fte_raw = sum(eff_fte_raw, na.rm = TRUE),
      .groups = "drop"
    )

  audit_grid <- base_robin$grid %>%
    filter(du_id == audit_du_id) %>%
    select(month, eff_fte, fte_rows)

  audit_monthly <- audit_payroll %>%
    left_join(audit_grid_raw, by = "month") %>%
    left_join(audit_grid, by = "month") %>%
    arrange(month, entity_code)

  readr::write_csv(audit_monthly,
                   file.path(qa_dir, sprintf("robin_heu_audit_du_%s.csv", audit_du_id)),
                   na = "")

  # Missing DATEV months for scope entities
  format_months <- function(x) {
    if (length(x) == 0 || all(is.na(x))) {
      return("")
    }
    x <- as.Date(x)
    paste(format(x, "%Y-%m"), collapse = ",")
  }

  readr::write_csv(
    base_robin$missing_months %>%
      mutate(missing_months = map_chr(missing, format_months)) %>%
      select(entity_code, missing_months),
    file.path(qa_dir, "robin_missing_datev_months.csv"),
    na = ""
  )

  readr::write_csv(
    base_robin$missing_person_months %>%
      mutate(missing_months = map_chr(missing, format_months)) %>%
      select(du_id, missing_months),
    file.path(qa_dir, "robin_missing_datev_months_by_person.csv"),
    na = ""
  )

  missing_msg <- base_robin$missing_months %>%
    mutate(missing_months = map_chr(missing, format_months)) %>%
    mutate(msg = paste0(entity_code, ":[", missing_months, "]")) %>%
    pull(msg)
  message("Missing DATEV months (ROBIN scope): ", paste(missing_msg, collapse = " | "))

  payroll_months_by_person <- payroll_linked %>%
    filter(entity_code %in% robin_entities) %>%
    mutate(month = as.Date(month)) %>%
    filter(month >= rp_start, month <= rp_end) %>%
    group_by(du_id, entity_code) %>%
    summarise(months = paste(format(sort(unique(month)), "%Y-%m"), collapse = ","),
              .groups = "drop") %>%
    left_join(d_user %>% select(du_id, du_name, du_surname), by = "du_id") %>%
    select(du_id, du_name, du_surname, entity_code, months)

  readr::write_csv(
    payroll_months_by_person,
    file.path(qa_dir, "robin_payroll_months_by_person.csv"),
    na = ""
  )

  # Summary (ALL vs ROBIN scope)
  audit_all <- heu_base %>% filter(du_id == audit_du_id) %>%
    select(du_id, day_equiv_max, perso_costs_RP, heu_daily_rate) %>%
    rename(day_equiv_max_all = day_equiv_max,
           perso_costs_all = perso_costs_RP,
           heu_daily_rate_all = heu_daily_rate)

  audit_robin <- base_robin$heu_base %>% filter(du_id == audit_du_id) %>%
    select(du_id, day_equiv_max, perso_costs_RP, heu_daily_rate) %>%
    rename(day_equiv_max_robin = day_equiv_max,
           perso_costs_robin = perso_costs_RP,
           heu_daily_rate_robin = heu_daily_rate)

  audit_summary <- audit_all %>%
    full_join(audit_robin, by = "du_id")

  readr::write_csv(audit_summary,
                   file.path(qa_dir, sprintf("robin_heu_audit_summary_du_%s.csv", audit_du_id)),
                   na = "")

  # Console run summary
  audit_grid_stats <- audit_grid_raw %>%
    summarise(
      max_raw_rows = if_else(n() > 0, max(raw_rows, na.rm = TRUE), NA_real_),
      max_eff_fte_raw = if_else(n() > 0, max(eff_fte_raw, na.rm = TRUE), NA_real_)
    )
  audit_grid_post <- audit_grid %>%
    summarise(max_eff_fte = if_else(n() > 0, max(eff_fte, na.rm = TRUE), NA_real_))

  message("RUN SUMMARY (", audit_project, "): du_id=", audit_du_id,
          " day_equiv_max_all=", audit_all$day_equiv_max_all,
          " day_equiv_max_robin=", audit_robin$day_equiv_max_robin,
          " eff_fte_max_raw=", round(audit_grid_stats$max_eff_fte_raw, 2),
          " eff_fte_max_post=", round(audit_grid_post$max_eff_fte, 2),
          " perso_costs_all=", round(audit_all$perso_costs_all, 2),
          " perso_costs_robin=", round(audit_robin$perso_costs_robin, 2),
          " daily_rate_robin=", round(audit_robin$heu_daily_rate_robin, 2))
}

# --- Stela comparison (optional) -------------------------------------------
stela_candidates <- c(
  "/mnt/data/PK-Abrechnung-HEU-ROBIN_P2_v2.xlsx",
  file.path(repo_root, "PK-Abrechnung-HEU-ROBIN_P2_v2.xlsx")
)
stela_file <- stela_candidates[file.exists(stela_candidates)][1]

if (length(stela_file) == 1 && !is.na(stela_file)) {
  stela_sheets <- readxl::excel_sheets(stela_file)
  stela_tables <- list()
  for (sheet_name in stela_sheets) {
    raw <- readxl::read_excel(stela_file, sheet = sheet_name, col_names = FALSE)
    header_row <- which(apply(raw, 1, function(r) {
      any(grepl("tagessatz|max.*tage|nachname|vorname|personal|employee|name",
                r, ignore.case = TRUE), na.rm = TRUE)
    }))[1]
    if (is.na(header_row)) {
      next
    }
    stela_tables[[sheet_name]] <- readxl::read_excel(stela_file,
                                                     sheet = sheet_name,
                                                     skip = header_row - 1) %>%
      janitor::clean_names()
  }

  pick_col <- function(cols, pattern) {
    hit <- cols[str_detect(cols, pattern)]
    if (length(hit) == 0) return(NA_character_)
    hit[1]
  }

  stela_pick <- NULL
  stela_sheet <- NA_character_
  for (sheet_name in names(stela_tables)) {
    cols <- names(stela_tables[[sheet_name]])
    rate_col <- pick_col(cols, "tagessatz|daily_rate|heu_daily_rate|rate")
    max_col <- pick_col(cols, "max.*tage|max.*day")
    if (!is.na(rate_col) && !is.na(max_col)) {
      stela_pick <- stela_tables[[sheet_name]]
      stela_sheet <- sheet_name
      break
    }
  }

  if (!is.null(stela_pick)) {
    cols <- names(stela_pick)
    name_col <- pick_col(cols, "employee|name|mitarbeiter|person")
    given_col <- pick_col(cols, "given|vorname")
    surname_col <- pick_col(cols, "surname|nachname")
    rate_col <- pick_col(cols, "tagessatz|daily_rate|heu_daily_rate|rate")
    max_col <- pick_col(cols, "max.*tage|max.*day")
    cost_col <- pick_col(cols, "perso_cost|personalkosten|gesamtkosten|pk_total|total_cost")

    if (is.na(name_col) && (is.na(given_col) || is.na(surname_col))) {
      message("⚠ Stela comparison skipped: no employee name columns found in ", stela_sheet)
    } else {
      stela_comp <- stela_pick %>%
        mutate(
          employee = case_when(
            !is.na(name_col) ~ as.character(.data[[name_col]]),
            !is.na(given_col) & !is.na(surname_col) ~ paste(.data[[given_col]], .data[[surname_col]]),
            TRUE ~ NA_character_
          ),
          employee_key = str_to_lower(str_trim(employee)),
          stela_day_equiv_max = if (!is.na(max_col)) as.numeric(.data[[max_col]]) else NA_real_,
          stela_daily_rate = if (!is.na(rate_col)) as.numeric(.data[[rate_col]]) else NA_real_,
          stela_perso_costs = if (!is.na(cost_col)) as.numeric(.data[[cost_col]]) else NA_real_
        ) %>%
        select(employee, employee_key, stela_day_equiv_max, stela_daily_rate, stela_perso_costs) %>%
        filter(!is.na(employee_key))

      ours_robin <- if (!is.null(base_robin)) {
        base_robin$heu_base %>%
          mutate(
            employee = paste(du_name, du_surname),
            employee_key = str_to_lower(str_trim(employee))
          ) %>%
          select(du_id, employee, employee_key,
                 day_equiv_max, perso_costs_RP, heu_daily_rate) %>%
          rename(
            ours_day_equiv_max = day_equiv_max,
            ours_perso_costs = perso_costs_RP,
            ours_daily_rate = heu_daily_rate
          )
      } else {
        tibble()
      }

      stela_vs_ours <- stela_comp %>%
        left_join(ours_robin, by = "employee_key") %>%
        arrange(employee)

      readr::write_csv(stela_vs_ours,
                       file.path(qa_dir, "robin_stela_comparison.csv"),
                       na = "")
      message("✓ Stela comparison exported from sheet: ", stela_sheet)
    }
  } else {
    message("⚠ Stela comparison skipped: no sheet with rate + max days found in ", stela_file)
  }
} else {
  message("⚠ Stela comparison skipped: file not found")
}

# --- 12bis. Tableau final : daily rate + répartition par projet (RP) --------
# Daily rate par personne (unique pour la RP)
rates <- heu_base %>% select(du_id, du_name, du_surname, heu_daily_rate)
rates_robin <- if (!is.null(base_robin)) {
  base_robin$heu_base %>%
    select(du_id, heu_daily_rate) %>%
    rename(heu_daily_rate_robin = heu_daily_rate)
} else {
  tibble(du_id = integer(), heu_daily_rate_robin = numeric())
}

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
  left_join(rates_robin, by = "du_id") %>%
  mutate(
    heu_daily_rate = if_else(project == "ROBIN" & !is.na(heu_daily_rate_robin),
                             heu_daily_rate_robin,
                             heu_daily_rate),
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
heu_caps_robin <- if (!is.null(base_robin)) {
  base_robin$heu_base %>%
    select(du_id, day_equiv_max, heu_daily_rate) %>%
    rename(day_equiv_max_robin = day_equiv_max,
           heu_daily_rate_robin = heu_daily_rate)
} else {
  tibble(du_id = integer(), day_equiv_max_robin = numeric(), heu_daily_rate_robin = numeric())
}

heu_days_capped <- heu_days_by_du_pr %>%
  left_join(heu_days_by_du, by = "du_id") %>%
  left_join(heu_caps, by = "du_id") %>%
  left_join(heu_caps_robin, by = "du_id") %>%
  mutate(
    day_equiv_max = if_else(project == "ROBIN" & !is.na(day_equiv_max_robin),
                            day_equiv_max_robin,
                            day_equiv_max),
    heu_daily_rate = if_else(project == "ROBIN" & !is.na(heu_daily_rate_robin),
                             heu_daily_rate_robin,
                             heu_daily_rate),
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
