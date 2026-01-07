# 10_exports_excel_like_stella.R
# ------------------------------------------------------------------
# Génère un classeur Excel multi-feuilles "style Stella"
# à partir des exports pipeline (CSV) dans Database/.
# ------------------------------------------------------------------

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(janitor)
  library(openxlsx)
})

# --- CONFIG ------------------------------------------------------
dir_db <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben"

# Période demandée par Stella
rp_start <- as.Date("2024-03-01")
rp_end   <- as.Date("2025-08-31")

# Nom projet cible
project_regex <- "\\bROBIN\\b"

# Output
out_dir  <- file.path(dir_db, "qa")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_xlsx <- file.path(
  out_dir,
  sprintf("PK-Abrechnung-HEU-ROBIN_%s_to_%s.xlsx",
          format(rp_start, "%Y%m%d"), format(rp_end, "%Y%m%d"))
)

# --- INPUT PATHS -------------------------------------------------
# Les fichiers CSV sont dans Database/ (parent de ben/)
dir_pipeline_output <- dirname(dir_db)
p_cost   <- file.path(dir_pipeline_output, "cost_by_pr_with_programme.csv")
p_master <- file.path(dir_pipeline_output, "master_personnes_enriched.csv")
p_heu    <- file.path(dir_pipeline_output, "heu_daily_rate_by_person.csv")
p_ctrl   <- file.path(dir_pipeline_output, "heu_daily_rate_control.csv")

# d_user est parfois dans Database/ (parent), parfois dans ben/
cand_d_user <- c(file.path(dir_db, "d_user.csv"),
                 file.path(dirname(dir_db), "d_user.csv"))
p_d_user <- cand_d_user[file.exists(cand_d_user)][1]

# --- CHECKS ------------------------------------------------------
need <- c(p_cost, p_master, p_heu, p_ctrl, p_d_user)
missing <- need[!file.exists(need)]
if (length(missing)) {
  stop("Missing input files:\n", paste("-", missing, collapse = "\n"))
}

read_csv_clean <- function(p) {
  readr::read_csv(p, show_col_types = FALSE) %>% clean_names()
}

# --- LOAD --------------------------------------------------------
cost   <- read_csv_clean(p_cost) %>% mutate(month = as.Date(month))
master <- read_csv_clean(p_master) %>% mutate(month = as.Date(month))
heu    <- read_csv_clean(p_heu)
ctrl   <- read_csv_clean(p_ctrl)
d_user <- read_csv_clean(p_d_user)

# Harmonise noms
d_user <- d_user %>%
  transmute(
    du_id = as.integer(du_id),
    du_name = as.character(du_name),
    du_surname = as.character(du_surname),
    person = str_squish(paste0(du_surname, " ", du_name))
  )

# --- FILTER WINDOW + PROJECT ------------------------------------
rp_month_min <- floor_date(rp_start, "month")
rp_month_max <- floor_date(rp_end,   "month")

cost_rp <- cost %>%
  filter(!is.na(month),
         month >= rp_month_min, month <= rp_month_max) %>%
  filter(str_detect(coalesce(project, ""), regex(project_regex, ignore_case = TRUE)))

master_rp <- master %>%
  filter(!is.na(month),
         month >= rp_month_min, month <= rp_month_max)

# --- STUNDENZETTEL (heures TKS par personne × WP × mois) ---------
stunden_long <- cost_rp %>%
  mutate(du_id = as.integer(du_id)) %>%
  left_join(d_user, by = "du_id") %>%
  mutate(
    month_lab = format(month, "%Y-%m"),
    wp_title  = coalesce(wp_title, paste0("WP_", workpackage))
  ) %>%
  group_by(person, du_id, wp_title, month_lab) %>%
  summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop") %>%
  arrange(person, wp_title, month_lab)

# Version large (pratique pour comparaison)
stunden_wide <- stunden_long %>%
  select(person, wp_title, month_lab, hours) %>%
  pivot_wider(names_from = month_lab, values_from = hours, values_fill = 0) %>%
  arrange(person, wp_title)

# --- GEHÄLTER (DATEV: coûts mensuels par personne) ---------------
gehalt_long <- master_rp %>%
  mutate(du_id = as.integer(du_id)) %>%
  left_join(d_user, by = "du_id") %>%
  mutate(month_lab = format(month, "%Y-%m")) %>%
  group_by(person, du_id, month_lab) %>%
  summarise(gesamtkosten = sum(gesamtkosten, na.rm = TRUE), .groups = "drop") %>%
  arrange(person, month_lab)

gehalt_wide <- gehalt_long %>%
  select(person, month_lab, gesamtkosten) %>%
  pivot_wider(names_from = month_lab, values_from = gesamtkosten, values_fill = 0) %>%
  arrange(person)

# --- PK-BERECHNUNG (cap HEU + daily rate + jours/heures ROBIN) ---
# Heures ROBIN par personne × WP (sur la période)
hours_by_wp <- stunden_long %>%
  group_by(du_id, person, wp_title) %>%
  summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop") %>%
  mutate(days_raw = hours / 8)

days_tot <- hours_by_wp %>%
  group_by(du_id) %>%
  summarise(days_total_raw = sum(days_raw, na.rm = TRUE), .groups = "drop")

heu2 <- heu %>%
  transmute(
    du_id = as.integer(du_id),
    day_equiv_max = as.numeric(day_equiv_max),
    heu_daily_rate = as.numeric(heu_daily_rate),
    perso_costs_rp = as.numeric(perso_costs_rp)
  )

pk_long <- hours_by_wp %>%
  left_join(days_tot, by = "du_id") %>%
  left_join(heu2, by = "du_id") %>%
  mutate(
    scale = case_when(
      is.na(day_equiv_max) ~ 1,
      day_equiv_max <= 0   ~ 1,
      is.na(days_total_raw) | days_total_raw <= 0 ~ 1,
      TRUE ~ pmin(1, day_equiv_max / days_total_raw)
    ),
    days_capped    = days_raw * scale,
    cost_claimable = days_capped * heu_daily_rate
  ) %>%
  arrange(person, wp_title)

# Résumé 1 ligne par personne (utile pour onglet PK-Berechnung)
pk_summary <- pk_long %>%
  group_by(du_id, person) %>%
  summarise(
    perso_costs_rp    = first(perso_costs_rp),
    day_equiv_max     = first(day_equiv_max),
    heu_daily_rate    = first(heu_daily_rate),
    hours_total       = sum(hours, na.rm = TRUE),
    days_total_raw    = sum(days_raw, na.rm = TRUE),
    days_total_capped = sum(days_capped, na.rm = TRUE),
    cost_total        = sum(cost_claimable, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(person)

# Onglet "Tage_PM_pro_WP" (jours par WP)
tage_pm_pro_wp <- pk_long %>%
  select(person, du_id, wp_title, hours, days_raw, days_capped, cost_claimable) %>%
  arrange(person, wp_title)

# --- GuV (résumé mensuel simple, utile pour sanity check) --------
# Coûts DATEV totaux par mois
guv_costs <- gehalt_long %>%
  group_by(month_lab) %>%
  summarise(datev_costs_total = sum(gesamtkosten, na.rm = TRUE), .groups = "drop")

# Heures ROBIN totales par mois
guv_hours <- stunden_long %>%
  group_by(month_lab) %>%
  summarise(robin_hours_total = sum(hours, na.rm = TRUE), .groups = "drop")

# Coûts claimables ROBIN par mois (allocation proportionnelle par mois)
# On applique le cap au niveau personne (scale), puis on distribue par mois selon les jours bruts/mois.
days_by_person_month <- stunden_long %>%
  mutate(days_raw_m = hours / 8) %>%
  group_by(du_id, person, month_lab) %>%
  summarise(days_raw_m = sum(days_raw_m, na.rm = TRUE), .groups = "drop")

scales_person <- pk_long %>%
  distinct(du_id, person, scale, heu_daily_rate)

guv_claimable <- days_by_person_month %>%
  left_join(scales_person, by = c("du_id", "person")) %>%
  mutate(days_capped_m = days_raw_m * coalesce(scale, 1),
         cost_claimable_m = days_capped_m * heu_daily_rate) %>%
  group_by(month_lab) %>%
  summarise(robin_claimable_cost = sum(cost_claimable_m, na.rm = TRUE), .groups = "drop")

guv <- guv_costs %>%
  full_join(guv_hours, by = "month_lab") %>%
  full_join(guv_claimable, by = "month_lab") %>%
  arrange(month_lab)

# --- HEU CONTROL ------------------------------------------------
ctrl2 <- ctrl %>%
  mutate(du_id = as.integer(du_id)) %>%
  left_join(d_user, by = "du_id") %>%
  relocate(person, .after = du_id)

# --- WRITE WORKBOOK ---------------------------------------------
wb <- createWorkbook()

addWorksheet(wb, "PK-Berechnung")
writeDataTable(wb, "PK-Berechnung", pk_summary)

addWorksheet(wb, "Tage_PM_pro_WP")
writeDataTable(wb, "Tage_PM_pro_WP", tage_pm_pro_wp)

addWorksheet(wb, "Gehälter")
writeDataTable(wb, "Gehälter", gehalt_wide)

addWorksheet(wb, "Stundenzettel")
writeDataTable(wb, "Stundenzettel", stunden_wide)

addWorksheet(wb, "GuV")
writeDataTable(wb, "GuV", guv)

addWorksheet(wb, "HEU_Control")
writeDataTable(wb, "HEU_Control", ctrl2)

# Mise en forme rapide
for (sh in names(wb)) {
  setColWidths(wb, sh, cols = 1:200, widths = "auto")
}

# Important: si le fichier est ouvert dans Excel, saveWorkbook peut échouer silencieusement.
saveWorkbook(wb, out_xlsx, overwrite = TRUE)

message("✓ Excel written: ", out_xlsx)
