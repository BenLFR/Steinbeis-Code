# compute_stundensatz_local.R – rev. 15-Jul-2025
# -------------------------------------------------------------
library(tidyverse)
library(lubridate)
library(janitor)
library(stringr)
library(readxl)
library(stringdist)
library(fuzzyjoin)

# --- 0. Paths -------------------------------------------------
dir_db    <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/datev-data"
dir_fte   <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/fte-liste"

# --- 1. Utility functions -------------------------------------
read_db  <- \(f) read_csv(file.path(dir_db, f), show_col_types = FALSE)
read_pay <- \(p){
  hdr  <- read_lines(p, n_max = 30)
  skip <- which(str_detect(hdr, regex("Pers\\.?-?Nr\\.", TRUE)))[1] - 1L
  read_csv2(p, skip = skip,
            locale = locale(decimal_mark = ",", grouping_mark = "."),
            show_col_types = FALSE) |>
    clean_names()
}
read_fte <- \(p){
  readr::read_delim(
    p,
    delim = ";",
    locale = locale(decimal_mark = ",", grouping_mark = "."),
    show_col_types = FALSE
  ) |>
    clean_names() |>
    mutate(
      wirksamkeitsdatum = dmy(wirksamkeitsdatum),
      wochenstunden = coalesce(
        wochenstunden,
        suppressWarnings(as.numeric(str_replace(wochentliche_arbeitszeit, ",", ".")))
      ),
      fte = str_replace_na(fte, "1") |> str_replace(",", ".") |> as.numeric(),
      surname_personio = str_to_lower(nachname_burgerlich %||% surname),
      given_personio   = str_to_lower(vorname_burgerlich   %||% givenname)
    ) |>
    filter(status == "Aktiv") |>
    transmute(
      pers_nr        = personalnummer,
      entity_code    = str_sub(personalnummer, 1, 4),
      wirksamkeitsdatum,
      surname_personio, given_personio,
      wochenstunden, fte
    )
}

normalize <- function(x){
  x |>
    str_to_lower() |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_replace_all("[^a-z ]","") |>
    str_squish()
}

# --- 2. Read Steinbeis (TKS) tables ----------------------------
d_user_all  <- read_csv(file.path(dir_db, "d_user.csv"),
                        col_types = cols(du_hr_numbers = col_character()),
                        show_col_types = FALSE) %>%
  clean_names()

d_user <- d_user_all %>% filter(is.na(du_inactive) | du_inactive == FALSE)
cat("✔️  Nombre de personnes actives dans d_user :", nrow(d_user), "\n")
cat("❌  Nombre de personnes inactives supprimées :", sum(d_user_all$du_inactive == TRUE, na.rm=TRUE), "\n")
d_wt    <- read_db("d_worktime.csv")      |> clean_names()
n_w2wp  <- read_db("n_worktime2workpackage.csv") |> clean_names()
d_wp    <- read_db("d_workpackage.csv")    |> clean_names()
d_pr    <- read_db("d_project.csv")        |> clean_names()

# --- 3.  Paie DATEV (lecture brute) ---
datev_files <- list.files(
  dir_datev,
  pattern    = "_Personalkosten_.*\\.csv$",
  full.names = TRUE
) |> sort()
if (length(datev_files)==0) stop("⚠️ No Datev files found in: ", dir_datev)

payroll_raw <- map_dfr(datev_files, function(f){
  read_pay(f) |>
    mutate(src_file = basename(f))
})

# Sélectionne la colonne qui commence par 'gesamtkosten'
datev_gk_col <- names(payroll_raw) |> str_subset("^gesamtkosten") |> (\(v) v[1])()

# Nettoyage et sélection des colonnes utiles, tout en gardant le nom 'gesamtkosten'
datev_all_export <- payroll_raw |>
  mutate(
    entity_code = str_extract(src_file, "^\\d{5}") |> str_sub(-4L),
    month_str   = str_extract(src_file, "\\d{2}[-_]\\d{4}"),
    month       = month_str |> str_replace("_","-") |> parse_date_time("my") |> floor_date("month")
  ) |>
  transmute(
    entity_code,
    month,
    pers_nr      = pers_nr,
    surname      = nachname,
    givenname    = vorname,
    gesamtkosten = .data[[datev_gk_col]]
  ) |>
  arrange(entity_code, month, surname, givenname)

write_csv(datev_all_export, file.path(dir_db, "datev_all_months_by_entity.csv"), na = "")
message("✅ Export DATEV clean (colonne coût = gesamtkosten) écrite dans : ",
        file.path(dir_db, "datev_all_months_by_entity.csv"))

# --- Nettoyage du numéro de personnel et dédoublonnage ---
datev_all_export <- datev_all_export %>%
  mutate(pers_nr_clean = str_remove_all(as.character(pers_nr), "^0+"))

persnr_mode <- datev_all_export %>%
  filter(!is.na(pers_nr_clean), !is.na(surname), !is.na(givenname)) %>%
  group_by(entity_code, surname, givenname, pers_nr_clean) %>%
  summarise(n = n(), .groups="drop") %>%
  group_by(entity_code, surname, givenname) %>%
  slice_max(order_by = n, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  select(entity_code, surname, givenname, pers_nr_ref = pers_nr_clean)

datev_all_export <- datev_all_export %>%
  left_join(persnr_mode, by = c("entity_code", "surname", "givenname")) %>%
  mutate(
    pers_nr_final = coalesce(pers_nr_ref, pers_nr_clean),
    pers_nr_final = str_remove_all(as.character(pers_nr_final), "^0+")
  ) %>%
  select(-pers_nr_clean, -pers_nr_ref)

datev_all_export <- datev_all_export %>%
  mutate(pers_nr = pers_nr_final) %>%
  select(-pers_nr_final)

# --- Agrégation par personne/mois/CC ---
payroll <- datev_all_export |>
  group_by(entity_code, month, pers_nr, surname, givenname) |>
  summarise(
    pers_nr_short = as.integer(pers_nr),
    surname_pay   = str_to_lower(surname),
    given_pay     = str_to_lower(givenname),
    gesamtkosten  = sum(gesamtkosten, na.rm=TRUE),
    .groups="drop"
  )


# ---------------------------------------------------------------------------
# 4. Build Steinbeis ↔ d_user linking keys  ---------------------------------
# ---------------------------------------------------------------------------
users_key <- d_user %>%                         # table RH « d_user »
  mutate(hr_list = str_split(du_hr_numbers, ",")) %>%
  unnest(hr_list) %>%
  mutate(
    hr_list       = str_trim(hr_list),
    entity_code   = str_sub(hr_list, 1, 4),                 # 4 premiers chiffres
    pers_nr_full  = str_sub(hr_list, 5),                    # reste du matricule
    pers_nr_short = as.integer(pers_nr_full)                # version « short »
  ) %>%
  transmute(
    du_id,
    entity_code,
    pers_nr_short,
    surname_user  = str_to_lower(du_surname),
    given_user    = str_to_lower(du_name)
  ) %>%
  distinct()

# ---------------------------------------------------------------------------
# 5. Mapping payroll → du_id (EXACT MATCH ONLY)  -----------------------------
# ---------------------------------------------------------------------------
payroll_linked <- payroll %>%                    # paie agrégée (voir §3)
  left_join(                                     # jointure exacte
    users_key %>% select(du_id, entity_code, pers_nr_short),
    by = c("entity_code", "pers_nr_short")
  ) %>%
  filter(!is.na(du_id))                          # on garde uniquement les lignes appariées

cat("✔️  Paie appariée : ", nrow(payroll_linked), " lignes sur ",
    nrow(payroll), " (", round(100 * nrow(payroll_linked) / nrow(payroll), 1), "%)\n")


# --- 5c. Analyse multi-cost-center (NOUVELLE VERSION ROBUSTE) --------------------

# 5c.1 – Identifier les personnes multi-cost-center (plusieurs entity_code pour le même du_id)
multi_cc_full <- users_key %>%
  group_by(du_id) %>%
  summarise(n_cc = n_distinct(entity_code), .groups = "drop") %>%
  filter(n_cc > 1)

# 5c.2 – Générer la table détaillée multi-costcenter, une ligne par CC/personne
multi_cc_detail <- users_key %>%
  semi_join(multi_cc_full, by = "du_id") %>%
  left_join(
    d_user %>% select(du_id, du_login, du_name, du_surname, du_inactive),
    by = "du_id"
  ) %>%
  select(
    du_id, du_login, du_name, du_surname,
    entity_code, pers_nr_short,
    surname_user, given_user,
    du_inactive
  ) %>%
  arrange(du_id, entity_code)

write_csv(multi_cc_detail, file.path(dir_db, "personnes_multi_costcenter_final.csv"), na = "")
cat("✅ Table multi_cc_detail corrigée créée et exportée.\n")
print(multi_cc_detail, n = 20)

# --- 5d. Master personnes ---
master_personnes <- d_user %>%
  left_join(
    users_key %>% select(du_id, entity_code, pers_nr_short), 
    by = "du_id"
  ) %>%
  left_join(
    payroll_linked %>%
      select(entity_code, pers_nr_short, du_id, surname_pay, given_pay) %>%
      distinct(), 
    by = c("du_id", "entity_code", "pers_nr_short")
  ) %>%
  mutate(
    multi_costcenter = du_id %in% multi_cc_full$du_id
  ) %>%
  select(
    du_id,
    du_login,
    du_name,
    du_surname,
    entity_code,
    pers_nr_short,
    surname_pay,
    given_pay,
    du_inactive,
    multi_costcenter
  ) %>%
  arrange(du_id, entity_code)
write_csv(master_personnes, file.path(dir_db, "master_personnes.csv"), na = "")
cat("✅ Table master_personnes créée et exportée.\n")
print(master_personnes, n = 15)

# --- 6. Map work‐packages to cost-centers, compute work‐seconds  ----
d_cc <- read_db("d_costcenter.csv") %>% clean_names()
wp_entity_map <- d_wp %>%
  left_join(
    d_cc %>% transmute(dcc_id, entity_code = as.character(dcc_number)),
    by = "dcc_id"
  ) %>%
  transmute(dwp_id, entity_code)
d_wt2 <- d_wt %>%
  mutate(
    dwt_date  = as_date(dwt_date),
    month     = floor_date(dwt_date, "month"),
    dwt_start = as_datetime(dwt_start),
    dwt_end   = as_datetime(dwt_end),
    work_secs = case_when(
      !is.na(dwt_start) & !is.na(dwt_end) ~
        as.numeric(dwt_end - dwt_start, "secs") - coalesce(dwt_break, 0),
      TRUE ~ 0
    )
  )
d2wp_all <- d_wt2 %>%
  inner_join(n_w2wp %>% select(dwt_id, dwp_id), by="dwt_id")
wt_by_entity <- d2wp_all %>%
  inner_join(wp_entity_map, by="dwp_id") %>%
  group_by(du_id, entity_code, month) %>%
  summarise(
    sec_entity = sum(work_secs, na.rm=TRUE),
    .groups     = "drop"
  )
wt_full <- d_wt2 %>%
  group_by(du_id, month) %>%
  summarise(
    sec_any = sum(work_secs, na.rm=TRUE),
    .groups = "drop"
  )

# --- 7. Import & expand Personio contractual hours --------------------------
fte_file_csv <- file.path(dir_fte, "Wochenarbeitszeit.csv")
if (!file.exists(fte_file_csv))
  stop("⚠️ Fichier Wochenarbeitszeit.csv introuvable : ", fte_file_csv)

fte_raw <- read_delim(
  fte_file_csv, delim = ";",
  locale = locale(decimal_mark = ",", grouping_mark = "."),
  show_col_types = FALSE
) %>%
  clean_names() %>%
  mutate(
    wirksamkeitsdatum = dmy(wirksamkeitsdatum),
    wochenstunden     = as.numeric(wochenstunden),
    fte               = as.numeric(fte),
    entity_code       = str_sub(personalnummer, 1, 4),
    pers_nr_short     = as.integer(str_remove(str_sub(personalnummer, 5), "^0+"))
  ) %>%
  filter(status == "Aktiv")

# ▶︎ FTE par cost-center et mois
fte_month <- fte_raw %>%
  mutate(month = floor_date(wirksamkeitsdatum, "month")) %>%
  group_by(entity_code, pers_nr_short) %>%
  arrange(month) %>%
  complete(month = seq(min(month),
                       max(floor_date(Sys.Date(), "month")),
                       by = "month")) %>%
  fill(wochenstunden, fte, .direction = "down") %>%
  ungroup() %>%
  mutate(
    contract_hours_month = wochenstunden * fte * (days_in_month(month) / 7),
    full_contract_week   = wochenstunden * fte
  ) %>%
  select(entity_code, pers_nr_short, personalnummer, month,
         fte, wochenstunden, full_contract_week, contract_hours_month)

# ▶︎ Restreindre dès maintenant aux cost-centers cibles
target_entities <- c("2016", "2017", "2136")
fte_month      <- fte_month      %>% filter(entity_code %in% target_entities)
payroll_linked <- payroll_linked %>% filter(entity_code %in% target_entities)
wt_by_entity   <- wt_by_entity   %>% filter(entity_code %in% target_entities)

# Générer la grille exhaustive (du_id × entity_code × month) --------
mois_2024 <- seq.Date(as.Date("2024-01-01"), as.Date("2024-12-01"), by = "month")

all_links <- master_personnes %>%
  select(du_id, du_login, du_name, du_surname,
         entity_code, pers_nr_short,
         surname_pay, given_pay,
         du_inactive, multi_costcenter) %>%
  
  # + lignes supplémentaires multi-CC
  bind_rows(
    multi_cc_detail %>%
      select(du_id, entity_code, pers_nr_short,
             surname_user, given_user) %>%
      distinct() %>%
      left_join(d_user %>%
                  select(du_id, du_login, du_name, du_surname, du_inactive),
                by = "du_id") %>%
      mutate(multi_costcenter = TRUE,
             surname_pay      = surname_user,
             given_pay        = given_user) %>%
      select(du_id, du_login, du_name, du_surname,
             entity_code, pers_nr_short,
             surname_pay, given_pay,
             du_inactive, multi_costcenter)
  ) %>%
  
  # ⬇️  garder UNE seule ligne par personne × CC
  distinct(du_id, entity_code, pers_nr_short, .keep_all = TRUE)

base_grid <- crossing(all_links, month = mois_2024)
cat("✔️  base_grid (sans doublons) : ", nrow(base_grid), " lignes\n")

# --- 8. Build enriched master_personnes (FTE + heures réelles) -------------
# 8.1 – Coût employeur agrégé par personne × CC × mois
payroll_agg <- payroll_linked %>%
  group_by(du_id, entity_code, pers_nr_short, month) %>%
  summarise(
    gesamtkosten = sum(gesamtkosten, na.rm = TRUE),
    pay_surname  = first(surname_pay),
    pay_given    = first(given_pay),
    .groups = "drop"
  )

# 8.2 – Jointure exhaustive + indicateurs
master_final <- base_grid %>%
  left_join(payroll_agg,
            by = c("du_id","entity_code","pers_nr_short","month")) %>%
  left_join(fte_month,
            by = c("entity_code","pers_nr_short","month")) %>%
  left_join(wt_by_entity,
            by = c("du_id","entity_code","month")) %>%
  left_join(wt_full,
            by = c("du_id","month")) %>%
  mutate(
    surname_pay = coalesce(pay_surname, du_surname),
    given_pay   = coalesce(pay_given,   du_name),
    hours_worked = coalesce(sec_entity, sec_any) / 3600,
    stundensatz_worked_h = if_else(hours_worked > 0,
                                   round(gesamtkosten / hours_worked, 2), NA_real_),
    stundensatz_contract_h = if_else(contract_hours_month > 0,
                                     round(gesamtkosten / contract_hours_month, 2), NA_real_)
  ) %>%
  select(du_id, du_login, du_name, du_surname,
         entity_code, pers_nr_short, month,
         gesamtkosten,
         fte, wochenstunden, contract_hours_month, hours_worked,
         stundensatz_worked_h, stundensatz_contract_h,
         multi_costcenter, du_inactive) %>%
  arrange(du_id, entity_code, month)

write_csv(master_final,
          file.path(dir_db, "master_personnes_enriched.csv"), na = "")
cat("✅ master_personnes_enriched.csv mis à jour.\n")

# --- 9. Cost breakdown by project & work-package (corrigé) -------

# 1.1 Détermine la plage des mois couverts
min_month <- min(master_final$month[!is.na(master_final$gesamtkosten)])
max_month <- max(master_final$month[!is.na(master_final$gesamtkosten)])
print(c(min_month, max_month))

# 1.2 Filtre cost_by_pr AVANT la jointure
cost_by_pr_recent <- cost_by_pr %>%
  filter(month >= min_month, month <= max_month)

target_entities <- c("2016", "2017", "2136")

# 1. Jointure worktime avec cost-center du WP
cost_by_pr_raw <- d2wp_all %>%
  inner_join(wp_entity_map, by = "dwp_id") %>%                   # Ajoute entity_code
  filter(entity_code %in% target_entities) %>%
  inner_join(d_wp %>% select(dwp_id, wp_title = dwp_title, dpr_id), by = "dwp_id") %>%
  inner_join(d_pr %>% select(dpr_id, project = dpr_title), by = "dpr_id") %>%
  group_by(du_id, dpr_id, project, dwp_id, wp_title, month, entity_code) %>%
  summarise(sec_pr = sum(work_secs, na.rm = TRUE), .groups = "drop")

# 2. Limiter la période à la période réellement couverte par master_final
min_month <- min(master_final$month[!is.na(master_final$gesamtkosten)])
max_month <- max(master_final$month[!is.na(master_final$gesamtkosten)])
cat("Période master_final :", as.character(min_month), "-", as.character(max_month), "\n")

cost_by_pr <- cost_by_pr_raw %>%
  filter(month >= min_month, month <= max_month) %>%
  left_join(
    master_final %>%
      select(du_id, month, entity_code, gesamtkosten, hours_worked, du_name, du_surname),
    by = c("du_id", "month", "entity_code")
  ) %>%
  mutate(
    hours_wp   = sec_pr / 3600,
    pct_time   = hours_wp / hours_worked,
    cost_wp    = gesamtkosten * pct_time,
    pers_surname = du_surname,
    pers_given   = du_name
  ) %>%
  select(
    du_id,
    entity_code,
    pers_surname,
    pers_given,
    month,
    project_id  = dpr_id,
    project,
    workpackage = dwp_id,
    wp_title,
    hours       = hours_wp,
    cost        = cost_wp,
    pct_time
  ) %>%
  arrange(entity_code, project, wp_title, du_id, month)

# --- 9. Cost breakdown by project & work-package ---------------------------

target_entities <- c("2016", "2017", "2136")

# 9.1  Work-time ↔ cost-center ↔ projet / WP
cost_by_pr_raw <- d2wp_all %>%
  inner_join(wp_entity_map, by = "dwp_id") %>%                 # ajoute entity_code
  filter(entity_code %in% target_entities) %>%                 # garde 2016/17/2136
  inner_join(d_wp  %>% select(dwp_id, wp_title = dwp_title, dpr_id), by = "dwp_id") %>%
  inner_join(d_pr  %>% select(dpr_id, project   = dpr_title),  by = "dpr_id") %>%
  group_by(du_id, dpr_id, project,
           dwp_id, wp_title,
           month, entity_code) %>%
  summarise(sec_pr = sum(work_secs, na.rm = TRUE), .groups = "drop")

# 9.2  Restreindre la période à celle réellement couverte par master_final
min_month <- min(master_final$month[!is.na(master_final$gesamtkosten)])
max_month <- max(master_final$month[!is.na(master_final$gesamtkosten)])
cat("Période master_final :", as.character(min_month), "-", as.character(max_month), "\n")

# 9.3  Jointure avec les coûts et calculs finaux
cost_by_pr <- cost_by_pr_raw %>%
  filter(month >= min_month, month <= max_month) %>%           # <-- filtre ici
  left_join(
    master_final %>%
      select(du_id, month, entity_code,
             gesamtkosten, hours_worked,
             du_name, du_surname),
    by = c("du_id", "month", "entity_code")
  ) %>%
  mutate(
    hours_wp   = sec_pr / 3600,
    pct_time   = hours_wp / hours_worked,
    cost_wp    = gesamtkosten * pct_time,
    pers_surname = du_surname,
    pers_given   = du_name
  ) %>%
  select(
    du_id, entity_code,
    pers_surname, pers_given,
    month,
    project_id  = dpr_id,
    project,
    workpackage = dwp_id,
    wp_title,
    hours       = hours_wp,
    cost        = cost_wp,
    pct_time
  ) %>%
  arrange(entity_code, project, wp_title, du_id, month)

cat("✔️  cost_by_pr construit :", nrow(cost_by_pr), "lignes\n")
library(dplyr)
library(readr)

# 1. Extraction du tableau mensuel (identique à ta capture)
mensuel_seuls <- cost_by_pr_recent %>%
  filter(project_id  == 645,
         workpackage == 4034,
         du_id %in% c(278, 314),
         year(month) == 2024) %>%
  arrange(du_id, month)

# 2. Création de la ligne TOTAL avec toutes les colonnes identiques (sauf fields résumés)
totaux_allcol <- mensuel_seuls %>%
  group_by(du_id, entity_code, pers_surname, pers_given, project_id, project, workpackage, wp_title) %>%
  summarise(
    month = "TOTAL",
    hours = sum(hours, na.rm = TRUE),
    cost  = sum(cost, na.rm = TRUE),
    pct_time = NA_real_,
    .groups = "drop"
  )

# 3. Ajout des totaux à la suite du tableau, format conservé
export <- bind_rows(
  mensuel_seuls %>% mutate(month = as.character(month)),
  totaux_allcol
) %>%
  arrange(du_id, match(month, c(format(mensuel_seuls$month, "%Y-%m-%d"), "TOTAL")))

# 4. Export CSV
write_csv(export, "wp4034_stela_alena_2024_mensuel_et_totaux_allcol.csv", na = "")
