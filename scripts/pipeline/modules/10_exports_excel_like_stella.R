# 10_exports_excel_like_stella.R
# ------------------------------------------------------------------
# Génère un classeur Excel multi-feuilles "style Stella"
# à partir des exports pipeline (CSV) dans Database/ben (ou fallback parent).
# ------------------------------------------------------------------

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(janitor)
  library(openxlsx)
  library(readxl)
})

# --- CONFIG ------------------------------------------------------
dir_db <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database/ben"

# Période demandée par Stella
rp_start <- as.Date("2024-03-01")
rp_end   <- as.Date("2025-08-31")

# Nom projet cible
project_regex <- "\\bROBIN\\b"

# Entity label affiché dans l'en-tête du tableau Stella
entity_label <- "S2i"

# Output
out_dir  <- file.path(dir_db, "qa")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

out_xlsx <- file.path(
  out_dir,
  sprintf("PK-Abrechnung-HEU-ROBIN_%s_to_%s.xlsx",
          format(rp_start, "%Y%m%d"), format(rp_end, "%Y%m%d"))
)

# --- HELPERS -----------------------------------------------------
read_csv_clean <- function(p) readr::read_csv(p, show_col_types = FALSE) %>% clean_names()

pick_existing <- function(preferred, fallback) {
  if (file.exists(preferred)) return(preferred)
  if (file.exists(fallback))  return(fallback)
  stop("Missing file:\n- ", preferred, "\n- ", fallback)
}

# Arrondi "half-up" au pas de 0,5 (évite le bankers rounding de round())
round_half_up <- function(x) {
  x <- as.numeric(x)
  ifelse(is.na(x), NA_real_, floor(x * 2 + 0.5) / 2)
}

# Pour éviter de sommer plusieurs fois le même gesamtkosten si master_final est multi-entité:
# prend une valeur unique par (du_id, month) si possible, sinon max() et flag possible.
collapse_unique_or_max <- function(df, value_col) {
  vc <- rlang::ensym(value_col)
  df %>%
    summarise(
      n_vals = n_distinct(!!vc, na.rm = TRUE),
      val = {
        vals <- unique(na.omit(pull(cur_data(), !!vc)))
        if (length(vals) == 0) NA_real_
        else if (length(vals) == 1) as.numeric(vals[1])
        else as.numeric(max(vals))
      },
      .groups = "drop"
    )
}

fmt_person_comma <- function(surname, name) {
  surname <- str_squish(as.character(surname))
  name    <- str_squish(as.character(name))
  str_squish(paste0(surname, ", ", name))
}

# --- INPUT PATHS -------------------------------------------------
# Exports pipeline (normalement dans Database/ben). Fallback sur Database/.
parent_db <- dirname(dir_db)

p_cost   <- pick_existing(file.path(dir_db,    "cost_by_pr_with_programme.csv"),
                          file.path(parent_db, "cost_by_pr_with_programme.csv"))

p_master <- pick_existing(file.path(dir_db,    "master_personnes_enriched.csv"),
                          file.path(parent_db, "master_personnes_enriched.csv"))

p_heu    <- pick_existing(file.path(dir_db,    "heu_daily_rate_by_person.csv"),
                          file.path(parent_db, "heu_daily_rate_by_person.csv"))

p_ctrl   <- pick_existing(file.path(dir_db,    "heu_daily_rate_control.csv"),
                          file.path(parent_db, "heu_daily_rate_control.csv"))

p_d_user <- pick_existing(file.path(dir_db,    "d_user.csv"),
                          file.path(parent_db, "d_user.csv"))

# --- LOAD --------------------------------------------------------
cost   <- read_csv_clean(p_cost)   %>% mutate(month = as.Date(month))
master <- read_csv_clean(p_master) %>% mutate(month = as.Date(month))
heu    <- read_csv_clean(p_heu)
ctrl   <- read_csv_clean(p_ctrl)
d_user <- read_csv_clean(p_d_user)

# Harmonise noms comme dans le fichier Stella: "Nom, Prénom"
d_user2 <- d_user %>%
  transmute(
    du_id      = as.integer(du_id),
    du_name    = as.character(du_name),
    du_surname = as.character(du_surname),
    person     = fmt_person_comma(du_surname, du_name)
  )

# Fenêtre mois
rp_month_min <- floor_date(rp_start, "month")
rp_month_max <- floor_date(rp_end,   "month")

# --- FILTER WINDOW + PROJECT ------------------------------------
cost_rp <- cost %>%
  filter(!is.na(month),
         month >= rp_month_min, month <= rp_month_max) %>%
  filter(str_detect(coalesce(project, ""), regex(project_regex, ignore_case = TRUE)))

master_rp <- master %>%
  filter(!is.na(month),
         month >= rp_month_min, month <= rp_month_max)

# --- STUNDENZETTEL (heures TKS par personne × WP × mois) ---------
stunden_long <- cost_rp %>%
  mutate(du_id = as.integer(du_id),
         wp = paste0("WP", as.integer(workpackage)),
         month_lab = format(month, "%Y-%m")) %>%
  left_join(d_user2, by = "du_id") %>%
  group_by(person, du_id, wp, month_lab) %>%
  summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop") %>%
  arrange(person, wp, month_lab)

# Version large (heures par WP et mois)
stunden_wide <- stunden_long %>%
  pivot_wider(names_from = month_lab, values_from = hours, values_fill = 0) %>%
  arrange(person, wp)

# --- GEHÄLTER (DATEV) par personne × mois (éviter surcomptage) ----
# master_final peut contenir plusieurs lignes par (du_id, month).
# On reconstruit un "gesamtkosten" unique par (du_id, month) via unique/max.
gehalt_long <- master_rp %>%
  mutate(du_id = as.integer(du_id),
         month_lab = format(month, "%Y-%m")) %>%
  group_by(du_id, month_lab) %>%
  group_modify(~ collapse_unique_or_max(.x, gesamtkosten)) %>%
  ungroup() %>%
  left_join(d_user2, by = "du_id") %>%
  transmute(person, du_id, month_lab, gesamtkosten = val) %>%
  arrange(person, month_lab)

gehalt_wide <- gehalt_long %>%
  select(person, month_lab, gesamtkosten) %>%
  pivot_wider(names_from = month_lab, values_from = gesamtkosten, values_fill = 0) %>%
  arrange(person)

# --- FTE + mois actifs + Max Tage --------------------------------
# On s'appuie sur master_final: colonne fte (cf 05_master_table.R).
# On agrège au niveau (du_id, month) en prenant une valeur unique/max.
fte_month <- master_rp %>%
  mutate(du_id = as.integer(du_id)) %>%
  group_by(du_id, month) %>%
  summarise(
    fte = {
      vals <- unique(na.omit(fte))
      if (length(vals) == 0) NA_real_
      else if (length(vals) == 1) as.numeric(vals[1])
      else as.numeric(max(vals))
    },
    # indicateur d'activité sur le mois: si coût existe (unique/max) ou fte>0
    gesamtkosten_m = {
      vals <- unique(na.omit(gesamtkosten))
      if (length(vals) == 0) NA_real_
      else if (length(vals) == 1) as.numeric(vals[1])
      else as.numeric(max(vals))
    },
    .groups = "drop"
  )

fte_stats <- fte_month %>%
  mutate(active = coalesce(gesamtkosten_m, 0) > 0 | coalesce(fte, 0) > 0) %>%
  filter(active) %>%
  group_by(du_id) %>%
  summarise(
    months_n = n_distinct(month),
    fte_values = {
      vals <- sort(unique(round(coalesce(fte, NA_real_), 3)))
      vals <- vals[!is.na(vals)]
      if (length(vals) == 0) NA_character_
      else paste(vals, collapse = " & ")
    },
    max_days_raw = sum((215/12) * coalesce(fte, 0), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(d_user2, by = "du_id") %>%
  mutate(
    vollzeit = if_else(fte_values == "1", "1", ""),
    teilzeit = if_else(fte_values == "1", "", fte_values)
  )

# --- Std.Satz 2024 (coût/h travaillé 2024) ------------------------
# Utilise hours_worked + gesamtkosten, mais on agrège au niveau (du_id, month)
# avec un gesamtkosten unique/max pour éviter duplication.
m2024 <- master %>%
  filter(!is.na(month),
         year(month) == 2024,
         month >= rp_month_min, month <= as.Date("2024-12-01")) %>%
  mutate(du_id = as.integer(du_id)) %>%
  group_by(du_id, month) %>%
  summarise(
    hours_worked_m = sum(coalesce(hours_worked, 0), na.rm = TRUE),
    gesamtkosten_m = {
      vals <- unique(na.omit(gesamtkosten))
      if (length(vals) == 0) NA_real_
      else if (length(vals) == 1) as.numeric(vals[1])
      else as.numeric(max(vals))
    },
    .groups = "drop"
  ) %>%
  filter(hours_worked_m > 0, !is.na(gesamtkosten_m))

stdsatz_2024 <- m2024 %>%
  group_by(du_id) %>%
  summarise(
    std_satz_2024 = sum(gesamtkosten_m, na.rm = TRUE) / sum(hours_worked_m, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(d_user2, by = "du_id")

# --- HEU (cap + daily rate + coûts période) -----------------------
heu2 <- heu %>%
  transmute(
    du_id          = as.integer(du_id),
    day_equiv_max  = as.numeric(day_equiv_max),     # = "Max. Tage auf-abrunden" côté pipeline
    heu_daily_rate = as.numeric(heu_daily_rate),    # = Tagessatz
    perso_costs_rp = as.numeric(perso_costs_rp)     # = total AGBrutto période
  )

# --- PROJEKTSTUNDEN par WP (WP1..WP7) -----------------------------
wp_hours <- stunden_long %>%
  group_by(du_id, person, wp) %>%
  summarise(proj_hours = sum(hours, na.rm = TRUE), .groups = "drop") %>%
  mutate(wp = factor(wp, levels = paste0("WP", 1:7)))

wp_hours_wide <- wp_hours %>%
  complete(du_id, wp = factor(paste0("WP", 1:7), levels = paste0("WP", 1:7)), fill = list(proj_hours = 0)) %>%
  left_join(d_user2, by = "du_id") %>%
  group_by(du_id, person, wp) %>%
  summarise(proj_hours = sum(proj_hours, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = wp, values_from = proj_hours, values_fill = 0) %>%
  arrange(person)

# --- PK-BERECHNUNG (table wide comme Stella) ----------------------
pk <- wp_hours_wide %>%
  left_join(fte_stats %>% select(du_id, vollzeit, teilzeit, months_n, max_days_raw), by = "du_id") %>%
  left_join(heu2, by = "du_id") %>%
  left_join(stdsatz_2024 %>% select(du_id, std_satz_2024), by = "du_id") %>%
  mutate(
    # Max Tage arrondi (pipeline) si dispo sinon calculé
    max_days_round = coalesce(day_equiv_max, round_half_up(max_days_raw)),
    
    # Jours par WP (arrondis à 0,5)
    across(paste0("WP", 1:7), ~ as.numeric(.x), .names = "{.col}"),
    tage_WP1 = round_half_up(WP1 / 8),
    tage_WP2 = round_half_up(WP2 / 8),
    tage_WP3 = round_half_up(WP3 / 8),
    tage_WP4 = round_half_up(WP4 / 8),
    tage_WP5 = round_half_up(WP5 / 8),
    tage_WP6 = round_half_up(WP6 / 8),
    tage_WP7 = round_half_up(WP7 / 8),
    
    tage_total_raw = rowSums(across(starts_with("tage_WP")), na.rm = TRUE),
    
    # Cap HEU: si dépassement, on scale au niveau personne
    scale = case_when(
      is.na(max_days_round) ~ 1,
      max_days_round <= 0   ~ 1,
      is.na(tage_total_raw) | tage_total_raw <= 0 ~ 1,
      TRUE ~ pmin(1, max_days_round / tage_total_raw)
    ),
    
    tage_cap_WP1 = tage_WP1 * scale,
    tage_cap_WP2 = tage_WP2 * scale,
    tage_cap_WP3 = tage_WP3 * scale,
    tage_cap_WP4 = tage_WP4 * scale,
    tage_cap_WP5 = tage_WP5 * scale,
    tage_cap_WP6 = tage_WP6 * scale,
    tage_cap_WP7 = tage_WP7 * scale,
    
    # Tagessatz: si heu_daily_rate absent, le recalculer via perso_costs/max_days_round
    tagessatz = coalesce(heu_daily_rate,
                         if_else(!is.na(perso_costs_rp) & !is.na(max_days_round) & max_days_round > 0,
                                 perso_costs_rp / max_days_round, NA_real_)),
    
    pk_total = rowSums(across(starts_with("tage_cap_WP")), na.rm = TRUE) * tagessatz,
    
    total_pk_WP1 = tage_cap_WP1 * tagessatz,
    total_pk_WP2 = tage_cap_WP2 * tagessatz,
    total_pk_WP3 = tage_cap_WP3 * tagessatz,
    total_pk_WP4 = tage_cap_WP4 * tagessatz,
    total_pk_WP5 = tage_cap_WP5 * tagessatz,
    total_pk_WP6 = tage_cap_WP6 * tagessatz,
    total_pk_WP7 = tage_cap_WP7 * tagessatz,
    
    total_pk = rowSums(across(starts_with("total_pk_WP")), na.rm = TRUE),
    
    # HEU "hourly equivalent"
    heu_hourly = tagessatz / 8,
    
    # H2020 costs: Std.Satz 2024 * Projetstunden total
    projektstunden_total = rowSums(across(paste0("WP", 1:7)), na.rm = TRUE),
    projektkosten_h2020  = if_else(!is.na(std_satz_2024),
                                   projektstunden_total * std_satz_2024, NA_real_),
    diff_heu_h2020       = total_pk - projektkosten_h2020,
    diff_hourly          = heu_hourly - std_satz_2024
  ) %>%
  # ordre des colonnes "comme Stella"
  transmute(
    person,
    Vollzeit  = vollzeit,
    Teilzeit  = teilzeit,
    `Anzahl der Monate` = months_n,
    `Max.Tage` = max_days_raw,
    `Max. Tage auf-abrunden` = max_days_round,
    
    `Projektst. WP1` = WP1,
    `Projektst. WP2` = WP2,
    `Projektst. WP3` = WP3,
    `Projektst. WP4` = WP4,
    `Projektst. WP5` = WP5,
    `Projektst. WP6` = WP6,
    `Projektst. WP7` = WP7,
    
    `Tagesäquiv. Ab und-Aufrund. WP1` = tage_WP1,
    `Tagesäquiv. Ab und-Aufrund. WP2` = tage_WP2,
    `Tagesäquiv. Ab und-Aufrund. WP3` = tage_WP3,
    `Tagesäquiv. Ab und-Aufrund. WP4` = tage_WP4,
    `Tagesäquiv. Ab und-Aufrund. WP5` = tage_WP5,
    `Tagesäquiv. Ab und-Aufrund. WP6` = tage_WP6,
    `Tagesäquiv. Ab und-Aufrund. WP7` = tage_WP7,
    
    `Tagessatz=AGBrutto/Max T.` = tagessatz,
    `PK=Tagesäquiv.*Tagessatz`  = pk_total,
    
    `TOTAL PK - WP1` = total_pk_WP1,
    `TOTAL PK - WP2` = total_pk_WP2,
    `TOTAL PK - WP3` = total_pk_WP3,
    `TOTAL PK - WP4` = total_pk_WP4,
    `TOTAL PK - WP5` = total_pk_WP5,
    `TOTAL PK - WP6` = total_pk_WP6,
    `TOTAL PK - WP7` = total_pk_WP7,
    `TOTAL PK`       = total_pk,
    
    `Ingeni costs` = NA_real_,  # si tu as une source Ingeni, remplace ici
    `Projektkosten H2020=St.Satz*Projektst.` = projektkosten_h2020,
    `Differenz HEU:H2020` = diff_heu_h2020,
    `HEU Tagessatz als St.satz` = heu_hourly,
    `Std.Satz von 2024 inkl. indiv. SVg.` = std_satz_2024,
    `Differenz` = diff_hourly
  ) %>%
  arrange(person)

# Header A1 comme Stella
colnames(pk)[1] <- sprintf("P1: %s-%s\n%s",
                           format(rp_start, "%d.%m.%Y"),
                           format(rp_end,   "%d.%m.%Y"),
                           entity_label)

# TOTAL row
num_cols <- setdiff(names(pk), colnames(pk)[1])
pk_total_row <- pk %>%
  summarise(across(all_of(num_cols), ~ sum(as.numeric(.x), na.rm = TRUE))) %>%
  mutate(!!colnames(pk)[1] := "TOTAL") %>%
  select(all_of(names(pk)))

pk_out <- bind_rows(pk, pk_total_row)

# --- GuV (simple sanity check) -----------------------------------
guv_costs <- gehalt_long %>%
  group_by(month_lab) %>%
  summarise(datev_costs_total = sum(gesamtkosten, na.rm = TRUE), .groups = "drop")

guv_hours <- stunden_long %>%
  group_by(month_lab) %>%
  summarise(robin_hours_total = sum(hours, na.rm = TRUE), .groups = "drop")

# claimable par mois: distribue pk_total au prorata des jours bruts/mois
days_by_person_month <- stunden_long %>%
  mutate(days_raw_m = hours / 8) %>%
  group_by(du_id, person, month_lab) %>%
  summarise(days_raw_m = sum(days_raw_m, na.rm = TRUE), .groups = "drop")

# récupère scale + tagessatz depuis pk (avant TOTAL)
pk_scales <- pk %>%
  rename(person = !!colnames(pk)[1]) %>%
  mutate(du_id = as.integer(d_user2$du_id[match(person, d_user2$person)])) %>%
  select(person) %>%
  distinct()

# plus robuste: recalculer scale/tagessatz depuis pk (on le refait direct)
pk_scales2 <- wp_hours_wide %>%
  left_join(fte_stats %>% select(du_id, max_days_raw), by = "du_id") %>%
  left_join(heu2, by = "du_id") %>%
  mutate(
    max_days_round = coalesce(day_equiv_max, round_half_up(max_days_raw)),
    tage_total_raw = round_half_up(WP1/8) + round_half_up(WP2/8) + round_half_up(WP3/8) +
      round_half_up(WP4/8) + round_half_up(WP5/8) + round_half_up(WP6/8) + round_half_up(WP7/8),
    scale = case_when(
      is.na(max_days_round) ~ 1,
      max_days_round <= 0   ~ 1,
      is.na(tage_total_raw) | tage_total_raw <= 0 ~ 1,
      TRUE ~ pmin(1, max_days_round / tage_total_raw)
    ),
    tagessatz = coalesce(heu_daily_rate,
                         if_else(!is.na(perso_costs_rp) & !is.na(max_days_round) & max_days_round > 0,
                                 perso_costs_rp / max_days_round, NA_real_))
  ) %>%
  select(du_id, tagessatz, scale)

guv_claimable <- days_by_person_month %>%
  left_join(pk_scales2, by = "du_id") %>%
  mutate(days_capped_m = days_raw_m * coalesce(scale, 1),
         cost_claimable_m = days_capped_m * tagessatz) %>%
  group_by(month_lab) %>%
  summarise(robin_claimable_cost = sum(cost_claimable_m, na.rm = TRUE), .groups = "drop")

guv <- guv_costs %>%
  full_join(guv_hours, by = "month_lab") %>%
  full_join(guv_claimable, by = "month_lab") %>%
  arrange(month_lab)

# --- HEU CONTROL --------------------------------------------------
ctrl2 <- ctrl %>%
  mutate(du_id = as.integer(du_id)) %>%
  left_join(d_user2, by = "du_id") %>%
  relocate(person, .after = du_id)

# --- WRITE WORKBOOK ----------------------------------------------
wb <- createWorkbook()

addWorksheet(wb, "PK-Berechnung")
writeDataTable(wb, "PK-Berechnung", pk_out)

addWorksheet(wb, "Tage_PM_pro_WP")
# Table détaillée jours/heures par WP (long)
tage_pm_pro_wp <- wp_hours %>%
  mutate(days_raw = proj_hours / 8,
         days_round = round_half_up(days_raw)) %>%
  arrange(person, wp)
writeDataTable(wb, "Tage_PM_pro_WP", tage_pm_pro_wp)

addWorksheet(wb, "Gehälter")
writeDataTable(wb, "Gehälter", gehalt_wide)

addWorksheet(wb, "Stundenzettel")
writeDataTable(wb, "Stundenzettel", stunden_wide)

addWorksheet(wb, "GuV")
writeDataTable(wb, "GuV", guv)

addWorksheet(wb, "HEU_Control")
writeDataTable(wb, "HEU_Control", ctrl2)

# --- Formatting ---------------------------------------------------
currency_cols <- c("Tagessatz=AGBrutto/Max T.", "PK=Tagesäquiv.*Tagessatz",
                   paste0("TOTAL PK - WP", 1:7), "TOTAL PK",
                   "Projektkosten H2020=St.Satz*Projektst.", "Differenz HEU:H2020")
num2_cols <- c("Max.Tage", "Max. Tage auf-abrunden",
               paste0("Projektst. WP", 1:7),
               paste0("Tagesäquiv. Ab und-Aufrund. WP", 1:7),
               "HEU Tagessatz als St.satz", "Std.Satz von 2024 inkl. indiv. SVg.", "Differenz")

for (sh in names(wb)) setColWidths(wb, sh, cols = 1:200, widths = "auto")

# Styles sur PK-Berechnung (optionnel mais utile)
sh <- "PK-Berechnung"
hdr_style <- createStyle(textDecoration = "bold")
addStyle(wb, sh, hdr_style, rows = 1, cols = 1:ncol(pk_out), gridExpand = TRUE)

style_num2 <- createStyle(numFmt = "0.00")
style_eur  <- createStyle(numFmt = '#,##0.00" €"')

# map colnames -> indices
pk_cols <- names(pk_out)
idx <- function(nm) which(pk_cols %in% nm)

addStyle(wb, sh, style_num2, rows = 2:(nrow(pk_out)+1), cols = idx(num2_cols), gridExpand = TRUE, stack = TRUE)
addStyle(wb, sh, style_eur,  rows = 2:(nrow(pk_out)+1), cols = idx(currency_cols), gridExpand = TRUE, stack = TRUE)

# Sauvegarde
saveWorkbook(wb, out_xlsx, overwrite = TRUE)
message("✓ Excel written: ", out_xlsx)
