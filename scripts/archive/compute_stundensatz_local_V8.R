# compute_stundensatz_local.R – rev. 31-Jul-2025 (HEU fix + programme via lpc_id) + DEDUP FIX
# --------------------------------------------------------------------
library(tidyverse)
library(lubridate)
library(janitor)
library(stringr)
library(readxl)
library(stringdist)
library(fuzzyjoin)

# --- 0. Paths -------------------------------------------------
dir_db    <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/datev-data"
dir_fte   <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/fte-liste"

# --- 1. Utils -------------------------------------------------
read_db  <- \(f) read_csv(file.path(dir_db, f), show_col_types = FALSE)
read_pay <- \(p){
  hdr  <- read_lines(p, n_max = 30)
  skip <- which(str_detect(hdr, regex("Pers\\.?-?Nr\\.", TRUE)))[1] - 1L
  read_csv2(p, skip = skip,
            locale = locale(decimal_mark = ",", grouping_mark = "."),
            show_col_types = FALSE) |>
    clean_names()
}
normalize <- function(x){
  x |> str_to_lower() |> stringi::stri_trans_general("Latin-ASCII") |>
    str_replace_all("[^a-z ]","") |> str_squish()
}

# --- 2. DB tables ---------------------------------------------
d_user_all <- read_csv(file.path(dir_db, "d_user.csv"),
                       col_types = cols(du_hr_numbers = col_character()),
                       show_col_types = FALSE) |> clean_names()
d_user <- d_user_all |> filter(is.na(du_inactive) | du_inactive == FALSE)
d_wt   <- read_db("d_worktime.csv") |> clean_names()
n_w2wp <- read_db("n_worktime2workpackage.csv") |> clean_names()
d_wp   <- read_db("d_workpackage.csv") |> clean_names()
d_pr   <- read_db("d_project.csv")     |> clean_names()   # <- has dpr_id, dpr_title, lpc_id
d_cc   <- read_db("d_costcenter.csv")  |> clean_names()

# --- 3. Payroll (DATEV) ---------------------------------------
datev_files <- list.files(dir_datev, pattern = "_Personalkosten_.*\\.csv$", full.names = TRUE) |> sort()
if (length(datev_files)==0) stop("⚠️ No Datev files found in: ", dir_datev)

payroll_raw <- map_dfr(datev_files, \(f) read_pay(f) |> mutate(src_file = basename(f)))
datev_gk_col <- names(payroll_raw) |> str_subset("^gesamtkosten") |> (\(v) v[1])()

datev_all_export <- payroll_raw |>
  mutate(
    entity_code = str_extract(src_file, "^\\d{5}") |> str_sub(-4L),
    month_str   = str_extract(src_file, "\\d{2}[-_]\\d{4}"),
    month       = month_str |> str_replace("_","-") |> parse_date_time("my") |> floor_date("month")
  ) |>
  transmute(
    entity_code, month,
    pers_nr, surname = nachname, givenname = vorname,
    gesamtkosten = .data[[datev_gk_col]]
  ) |>
  arrange(entity_code, month, surname, givenname)

# normalisation pers_nr + purge lignes non numériques (ex: "Summen:")
datev_all_export <- datev_all_export |>
  mutate(pers_nr_clean = str_remove_all(as.character(pers_nr), "^0+"))

persnr_mode <- datev_all_export |>
  filter(!is.na(pers_nr_clean), !is.na(surname), !is.na(givenname)) |>
  count(entity_code, surname, givenname, pers_nr_clean, name="n") |>
  group_by(entity_code, surname, givenname) |>
  slice_max(order_by = n, n = 1, with_ties = FALSE) |>
  ungroup() |>
  transmute(entity_code, surname, givenname, pers_nr_ref = pers_nr_clean)

datev_all_export <- datev_all_export |>
  left_join(persnr_mode, by = c("entity_code","surname","givenname")) |>
  mutate(pers_nr = coalesce(pers_nr_ref, pers_nr_clean) |> as.character() |> str_remove("^0+")) |>
  select(-pers_nr_clean, -pers_nr_ref) |>
  mutate(pers_nr = as.character(pers_nr)) |>
  filter(str_detect(pers_nr, "^[0-9]+$"))

payroll <- datev_all_export |>
  group_by(entity_code, month, pers_nr, surname, givenname) |>
  summarise(
    pers_nr_short = as.integer(pers_nr),
    surname_pay   = str_to_lower(surname),
    given_pay     = str_to_lower(givenname),
    gesamtkosten  = sum(gesamtkosten, na.rm=TRUE),
    .groups="drop"
  )

# --- 4. Clés d_user ↔ HR --------------------------------------
users_key <- d_user |>
  mutate(hr_list = str_split(du_hr_numbers, ",")) |>
  unnest(hr_list) |>
  mutate(
    hr_list       = str_trim(hr_list),
    entity_code   = str_sub(hr_list, 1, 4),
    pers_nr_full  = str_sub(hr_list, 5),
    pers_nr_short = as.integer(pers_nr_full)
  ) |>
  transmute(du_id, entity_code, pers_nr_short,
            surname_user = str_to_lower(du_surname),
            given_user   = str_to_lower(du_name)) |>
  distinct()

# --- 4bis. Auto-fix users_key using DATEV (fill missing HR numbers) ----------
# Build current unmatched (in DATEV but not in users_key)
payroll_unmatched <- payroll %>%
  anti_join(users_key %>% select(entity_code, pers_nr_short),
            by = c("entity_code","pers_nr_short"))

# Deterministic name key (ASCII, lower, squished)
normalize_name <- function(x){
  x |>
    stringr::str_to_lower() |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_replace_all("[^a-z ]","") |>
    str_squish()
}

# Unique mapping: name -> du_id (avoid ambiguous duplicates)
duser_names <- d_user %>%
  transmute(du_id,
            name_key = paste(normalize_name(coalesce(du_surname,"")),
                             normalize_name(coalesce(du_name,""))))

unique_name_to_du <- duser_names %>%
  filter(name_key != " ") %>%
  count(name_key, name = "n") %>%
  filter(n == 1) %>%
  select(name_key) %>%
  inner_join(duser_names, by = "name_key") %>%
  select(name_key, du_id)

# Name keys for unmatched DATEV rows
datev_names_unmatched <- payroll_unmatched %>%
  transmute(entity_code,
            pers_nr_short,
            name_key = paste(normalize_name(coalesce(surname,"")),
                             normalize_name(coalesce(givenname,"")))) %>%
  distinct()

# Infer du_id by unique name match; drop links already present
inferred_links <- datev_names_unmatched %>%
  inner_join(unique_name_to_du, by = "name_key") %>%
  anti_join(users_key %>% select(du_id, entity_code, pers_nr_short),
            by = c("du_id","entity_code","pers_nr_short")) %>%
  select(du_id, entity_code, pers_nr_short) %>%
  distinct() %>%
  mutate(source_fix = "from_DATEV_unique_name")

# Extend users_key in-place
if (nrow(inferred_links) > 0) {
  users_key <- users_key %>%
    bind_rows(
      inferred_links %>%
        left_join(d_user %>%
                    transmute(du_id,
                              surname_user = str_to_lower(du_surname),
                              given_user   = str_to_lower(du_name)),
                  by = "du_id")
    ) %>%
    distinct(du_id, entity_code, pers_nr_short, .keep_all = TRUE)
  
  # optional audit file
  readr::write_csv(
    inferred_links %>%
      left_join(d_user %>% select(du_id, du_login, du_name, du_surname), by = "du_id") %>%
      arrange(du_id, entity_code, pers_nr_short),
    file.path(dir_db, "inferred_hr_numbers_from_DATEV.csv"), na = ""
  )
  message("✓ users_key enriched with ", nrow(inferred_links), " HR number(s) inferred from DATEV by unique name.")
} else {
  message("✓ users_key: no missing HR numbers inferable from DATEV by unique name.")
}


# --- 5. Mapping payroll → du_id --------------------------------
payroll_linked <- payroll |>
  left_join(users_key |> select(du_id, entity_code, pers_nr_short),
            by = c("entity_code","pers_nr_short")) |>
  filter(!is.na(du_id))

# multi-CC
multi_cc_full <- users_key |> count(du_id, name="n_cc") |> filter(n_cc > 1)
multi_cc_detail <- users_key |>
  semi_join(multi_cc_full, by="du_id") |>
  left_join(d_user |> select(du_id, du_login, du_name, du_surname, du_inactive), by="du_id") |>
  select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
         surname_user, given_user, du_inactive) |>
  arrange(du_id, entity_code)

# master personnes (référentiel)
master_personnes <- d_user |>
  left_join(users_key |> select(du_id, entity_code, pers_nr_short), by="du_id") |>
  left_join(payroll_linked |> select(entity_code, pers_nr_short, du_id, surname_pay, given_pay) |> distinct(),
            by = c("du_id","entity_code","pers_nr_short")) |>
  mutate(multi_costcenter = du_id %in% multi_cc_full$du_id) |>
  select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
         surname_pay, given_pay, du_inactive, multi_costcenter) |>
  arrange(du_id, entity_code)

# --- 6. Worktime & CC (AVEC PRORATA MULTI-WP) -----------------
wp_entity_map <- d_wp |>
  left_join(d_cc |> transmute(dcc_id, entity_code = as.character(dcc_number)), by="dcc_id") |>
  transmute(dwp_id, entity_code, dpr_id)

d_wt2 <- d_wt |>
  mutate(
    dwt_date  = as_date(dwt_date),
    month     = floor_date(dwt_date, "month"),
    dwt_start = as_datetime(dwt_start),
    dwt_end   = as_datetime(dwt_end),
    work_secs = case_when(
      !is.na(dwt_start) & !is.na(dwt_end) ~ as.numeric(dwt_end - dwt_start, "secs") - coalesce(dwt_break, 0),
      TRUE ~ 0
    )
  )

# Nb de WPs par pointage
n_per_dwt <- n_w2wp |>
  count(dwt_id, name = "n_wp")

# Liaisons pointage↔WP avec prorata d'heures
d2wp_all <- n_w2wp |>
  select(dwt_id, dwp_id) |>
  left_join(n_per_dwt, by = "dwt_id") |>
  left_join(d_wt2 |> select(dwt_id, du_id, month, work_secs), by = "dwt_id") |>
  mutate(work_secs_alloc = work_secs / pmax(n_wp, 1))

# Heures par entité (proratisées)
wt_by_entity <- d2wp_all |>
  inner_join(wp_entity_map |> select(dwp_id, entity_code), by="dwp_id") |>
  group_by(du_id, entity_code, month) |>
  summarise(sec_entity = sum(work_secs_alloc, na.rm=TRUE), .groups="drop")

# Heures totales toutes entités
wt_full <- d_wt2 |>
  group_by(du_id, month) |>
  summarise(sec_any = sum(work_secs, na.rm=TRUE), .groups="drop")

# --- 7. Personio contractual hours -----------------------------------------
fte_file_csv <- file.path(dir_fte, "Wochenarbeitszeit.csv")
if (!file.exists(fte_file_csv)) stop("⚠️ Fichier Wochenarbeitszeit.csv introuvable : ", fte_file_csv)

fte_raw <- read_delim(fte_file_csv, delim=";", locale = locale(decimal_mark=",", grouping_mark="."),
                      show_col_types = FALSE) |>
  clean_names() |>
  mutate(
    wirksamkeitsdatum = dmy(wirksamkeitsdatum),
    wochenstunden     = as.numeric(wochenstunden),
    fte               = as.numeric(fte),
    entity_code       = str_sub(personalnummer, 1, 4),
    pers_nr_short     = as.integer(str_remove(str_sub(personalnummer, 5), "^0+"))
  ) |>
  filter(status == "Aktiv")

fte_month <- fte_raw |>
  mutate(month = floor_date(wirksamkeitsdatum, "month")) |>
  group_by(entity_code, pers_nr_short) |>
  arrange(month) |>
  complete(month = seq(min(month), max(floor_date(Sys.Date(), "month")), by = "month")) |>
  fill(wochenstunden, fte, .direction="down") |>
  ungroup() |>
  mutate(
    contract_hours_month = wochenstunden * fte * (days_in_month(month) / 7),
    full_contract_week   = wochenstunden * fte
  ) |>
  select(entity_code, pers_nr_short, personalnummer, month,
         fte, wochenstunden, full_contract_week, contract_hours_month)

# garder uniquement les CC cibles
target_entities <- c("2016","2017","2136")
fte_month      <- fte_month      |> filter(entity_code %in% target_entities)
payroll_linked <- payroll_linked |> filter(entity_code %in% target_entities)
wt_by_entity   <- wt_by_entity   |> filter(entity_code %in% target_entities)

# --- 8. Master enrichi ------------------------------------------------------
mois_2024 <- seq.Date(as.Date("2024-01-01"), as.Date("2024-12-01"), by="month")

all_links <- master_personnes |>
  select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
         surname_pay, given_pay, du_inactive, multi_costcenter) |>
  bind_rows(
    multi_cc_detail |>
      select(du_id, entity_code, pers_nr_short, surname_user, given_user) |>
      distinct() |>
      left_join(d_user |> select(du_id, du_login, du_name, du_surname, du_inactive), by="du_id") |>
      mutate(multi_costcenter = TRUE,
             surname_pay = surname_user, given_pay = given_user) |>
      select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
             surname_pay, given_pay, du_inactive, multi_costcenter)
  ) |>
  distinct(du_id, entity_code, pers_nr_short, .keep_all = TRUE)

base_grid <- crossing(all_links, month = mois_2024)

payroll_agg <- payroll_linked |>
  group_by(du_id, entity_code, pers_nr_short, month) |>
  summarise(
    gesamtkosten = sum(gesamtkosten, na.rm=TRUE),
    pay_surname  = first(surname_pay),
    pay_given    = first(given_pay),
    .groups="drop"
  )

master_final <- base_grid |>
  left_join(payroll_agg, by = c("du_id","entity_code","pers_nr_short","month")) |>
  left_join(fte_month,    by = c("entity_code","pers_nr_short","month")) |>
  left_join(wt_by_entity, by = c("du_id","entity_code","month")) |>
  left_join(wt_full,      by = c("du_id","month")) |>
  mutate(
    surname_pay = coalesce(pay_surname, du_surname),
    given_pay   = coalesce(pay_given,   du_name),
    hours_worked = coalesce(sec_entity, sec_any) / 3600,
    stundensatz_worked_h   = if_else(hours_worked > 0, round(gesamtkosten / hours_worked, 2), NA_real_),
    stundensatz_contract_h = if_else(contract_hours_month > 0, round(gesamtkosten / contract_hours_month, 2), NA_real_)
  ) |>
  select(du_id, du_login, du_name, du_surname,
         entity_code, pers_nr_short, month, gesamtkosten,
         fte, wochenstunden, contract_hours_month, hours_worked,
         stundensatz_worked_h, stundensatz_contract_h,
         multi_costcenter, du_inactive) |>
  arrange(du_id, entity_code, month)

# --- 9. Typologie projets (HEU / autres) via lpc_id ------------------------
pc_path <- file.path(dir_db, "l_project_category (2).csv")
proj_cat_raw <- read_csv(pc_path, show_col_types = FALSE) |> clean_names()

pick_first_col <- function(df, candidates, label_for_error){
  have <- intersect(candidates, names(df))
  if (length(have) == 0)
    stop(sprintf("Aucune colonne trouvée pour %s. Colonnes dispo: %s",
                 label_for_error, paste(names(df), collapse=", ")))
  have[1]
}

id_candidates  <- c("lpc_id","project_category_id","id")
lab_candidates <- c("lpc_project_category","project_category","programme","program",
                    "programme_name","funding_programme","category","type","name")

id_col  <- pick_first_col(proj_cat_raw, id_candidates,  "lpc_id")
lab_col <- pick_first_col(proj_cat_raw, lab_candidates, "label/libellé programme")

proj_cat <- proj_cat_raw |>
  transmute(
    lpc_id    = .data[[id_col]],
    label_raw = .data[[lab_col]]
  ) |>
  filter(!is.na(lpc_id)) |>
  distinct() |>
  mutate(
    prog_norm = str_to_lower(label_raw),
    programme = case_when(
      str_detect(prog_norm, "\\bhorizon europe\\b|\\bheu\\b") ~ "HEU",
      str_detect(prog_norm, "\\bh2020\\b|\\bhorizon 2020\\b") ~ "H2020",
      str_detect(prog_norm, "\\binterreg\\b")                 ~ "INTERREG",
      TRUE ~ toupper(as.character(label_raw))
    ),
    is_heu = programme == "HEU"
  ) |>
  select(lpc_id, programme, is_heu)

dpr_prog <- d_pr |>
  select(dpr_id, project = dpr_title, lpc_id) |>
  left_join(proj_cat, by = "lpc_id")

# --- 10. Cost breakdown + programme (PRORATA, robust) -----------------------
min_month <- min(master_final$month[!is.na(master_final$gesamtkosten)])
max_month <- max(master_final$month[!is.na(master_final$gesamtkosten)])

target_entities <- c("2016","2017","2136")

# détecter la colonne "projet" dans d_wp
pick_first_col <- function(df, candidates, label_for_error){
  have <- intersect(candidates, names(df))
  if (length(have) == 0)
    stop(sprintf("Aucune colonne trouvée pour %s. Colonnes dispo: %s",
                 label_for_error, paste(names(df), collapse=", ")))
  have[1]
}
wp_proj_id_col <- pick_first_col(d_wp,
                                 c("dpr_id","project_id","dwp_project_id"), "clé projet dans d_wp")
wp_title_col   <- pick_first_col(d_wp,
                                 c("dwp_title","wp_title","title","name"), "titre WP dans d_wp")

# info WP: dwp_id, dpr_id, wp_title
wp_info <- d_wp %>%
  transmute(
    dwp_id,
    dpr_id = .data[[wp_proj_id_col]],
    wp_title = .data[[wp_title_col]]
  )

# table projets+programme (dpr_prog) doit avoir dpr_id
stopifnot("dpr_id" %in% names(dpr_prog))

# calcul coûts/temps par WP (PRORATA via work_secs_alloc)
cost_by_pr_raw <- d2wp_all %>%
  # d2wp_all contient: dwt_id, dwp_id, n_wp, du_id, month, work_secs, work_secs_alloc
  inner_join(wp_entity_map %>% select(dwp_id, entity_code), by = "dwp_id") %>%
  filter(entity_code %in% target_entities) %>%
  inner_join(wp_info, by = "dwp_id") %>%
  inner_join(dpr_prog, by = "dpr_id") %>%
  mutate(month = as.Date(month)) %>%
  group_by(du_id, dpr_id, project, programme, is_heu, dwp_id, wp_title, month, entity_code) %>%
  summarise(sec_pr = sum(work_secs_alloc, na.rm = TRUE), .groups = "drop")

# --- 11. Gatekeeper RH vs HEU (nettoyage en amont) --------------------------
# Objectif : bloquer si une personne déclare des heures HEU pendant la RP
#            sans avoir FTE>0 ou des coûts DATEV sur la RP.

round_half <- function(x) round(x * 2) / 2
rp_start <- as.Date("2024-01-01"); rp_end <- as.Date("2024-12-31")
rp_months <- seq(floor_date(rp_start, "month"), floor_date(rp_end, "month"), by = "month")

# Heures HEU par personne sur la RP
heu_hours_by_person <- cost_by_pr %>%
  filter(is_heu, month >= floor_date(rp_start, "month"), month <= floor_date(rp_end, "month")) %>%
  group_by(du_id) %>%
  summarise(heu_hours = sum(replace_na(hours, 0), na.rm = TRUE), .groups = "drop")

# Emploi côté RH (FTE>0 ou coûts>0) sur la RP
emp_by_person <- master_final %>%
  mutate(month_date = as.Date(month)) %>%
  filter(month_date %in% rp_months) %>%
  group_by(du_id) %>%
  summarise(
    months_with_fte   = sum(replace_na(fte, 0) > 0),
    months_with_cost  = sum(replace_na(gesamtkosten, 0) > 0),
    months_with_work  = sum(replace_na(hours_worked, 0) > 0),
    employed_any      = (months_with_fte > 0) | (months_with_cost > 0),
    .groups = "drop"
  )

# Cas incohérents : heures HEU > 0 mais aucun mois RH actif
incoherent <- heu_hours_by_person %>%
  left_join(emp_by_person, by = "du_id") %>%
  mutate(across(everything(), ~ replace_na(.x, 0))) %>%
  filter(heu_hours > 0 & !employed_any) %>%
  arrange(desc(heu_hours))

# ---------------------------------------------------------------------------
# TEMPORARY BYPASS (to continue the pipeline while HR investigates)
# TODO(HR): Verify why these users have HEU hours but no payroll/FTE in 2024.
#           Likely missing d_user rows or missing du_hr_numbers for a 2nd entity.
#           Quick check later:
#             d_user_all %>% filter(du_id %in% incoherent$du_id)
#             # and confirm Personio/DATEV numbers for them.
# ---------------------------------------------------------------------------
allow_incoherent <- TRUE  # set back to FALSE once HR has fixed the data

if (nrow(incoherent) > 0) {
  incoh_path <- file.path(dir_db, "heu_data_incoherences.csv")
  write_csv(incoherent, incoh_path, na = "")
  ids <- paste(incoherent$du_id, collapse = ", ")
  
  if (!allow_incoherent) {
    stop(sprintf(
      "RH incohérent pour %d personne(s) : heures HEU mais FTE/coûts nuls sur la RP. Corriger Personio/DATEV. Détails : %s",
      nrow(incoherent), incoh_path
    ))
  } else {
    warning(sprintf(
      "TEMP BYPASS: %d incoherent user(s) allowed to pass gatekeeper (du_id: %s). CSV: %s\nTODO(HR): investigate & fix, then set allow_incoherent <- FALSE.",
      nrow(incoherent), ids, incoh_path
    ))
  }
}

# --- 12. HEU daily rate + contrôle AVEC PRORATA JOUR-CALENDAIRE -------------
# Hypothèses HEU:
# - "mois" = 30 jours (prorata coverage_30)
# - cap = somme_mois ( (215/12) * FTE_m * coverage_30 ), arrondi au 0,5

round_half <- function(x) round(x * 2) / 2

# Période de reporting (adapter si besoin)
rp_start <- as.Date("2024-01-01")
rp_end   <- as.Date("2024-12-31")
rp_months <- seq(lubridate::floor_date(rp_start, "month"),
                 lubridate::floor_date(rp_end,   "month"), by = "month")

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
fte_periods_du <- fte_periods %>%
  inner_join(users_key %>% select(du_id, entity_code, pers_nr_short),
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

# 12.c Cap HEU par personne, arrondi au 0,5
heu_cap <- grid %>%
  group_by(du_id) %>%
  summarise(day_equiv_max = round_half(sum((215/12) * fte * coverage_30, na.rm = TRUE)),
            .groups = "drop")

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

# (exports de contrôle, si souhaité)
# write_csv(heu_base,    file.path(dir_db, "heu_daily_rate_by_person.csv"), na = "")
# write_csv(heu_control, file.path(dir_db, "heu_daily_rate_control.csv"),   na = "")



# --- 12bis. Tableau final : daily rate + répartition par projet 2024 --------
# Daily rate par personne (unique pour la RP)
rates <- heu_base %>% select(du_id, du_name, du_surname, heu_daily_rate)

# Jours HEU par personne×projet, sans double comptage (allocation mensuelle)
heu_proj_days <- cost_by_pr %>%
  filter(is_heu, month >= as.Date("2024-01-01"), month <= as.Date("2024-12-31")) %>%
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
  filter(!is_heu, month >= as.Date("2024-01-01"), month <= as.Date("2024-12-31")) %>%
  group_by(du_id, project_id, project) %>%
  summarise(
    hours = sum(hours, na.rm = TRUE),
    cost_alloc = sum(cost, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(is_heu = FALSE) %>%
  arrange(du_id, project)

# Exports complémentaires
write_csv(heu_final_by_project, file.path(dir_db, "heu_final_by_project.csv"), na = "")
write_csv(non_heu_by_project,  file.path(dir_db, "non_heu_by_project.csv"),  na = "")

# === Reporting unifié : Non-HEU = prorata payroll ; HEU = daily-rate × jours capés ===
rp_start <- as.Date("2024-01-01"); rp_end <- as.Date("2024-12-31")
rp_month_floor <- floor_date(rp_start, "month")
rp_month_ceiling <- floor_date(rp_end, "month")

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

# Export reporting unifié
write_csv(reporting_costs, file.path(dir_db, "reporting_costs_HEU_daily_vs_nonHEU_prorata.csv"), na = "")

# --- 12. Exports utiles -----------------------------------------------------
write_csv(master_final, file.path(dir_db, "master_personnes_enriched.csv"), na = "")
write_csv(cost_by_pr,   file.path(dir_db, "cost_by_pr_with_programme.csv"), na = "")
write_csv(heu_base,     file.path(dir_db, "heu_daily_rate_by_person.csv"),   na = "")
write_csv(heu_control,  file.path(dir_db, "heu_daily_rate_control.csv"),     na = "")

# --- 13. Exemple export « photo + totaux » (WP 4034, projet 645) ------------
mensuel_seuls <- cost_by_pr |>
  filter(project_id == 645, workpackage == 4034,
         du_id %in% c(278, 314), year(month) == 2024) |>
  arrange(du_id, month)

totaux_allcol <- mensuel_seuls |>
  group_by(du_id, entity_code, pers_surname, pers_given, project_id, project, workpackage, wp_title) |>
  summarise(month = "TOTAL",
            hours = sum(hours, na.rm = TRUE),
            cost  = sum(cost,  na.rm = TRUE),
            pct_time = NA_real_, .groups = "drop")

export <- bind_rows(
  mensuel_seuls |> mutate(month = as.character(month)),
  totaux_allcol
) |>
  arrange(du_id, match(month, c(format(unique(mensuel_seuls$month), "%Y-%m-%d"), "TOTAL")))

write_csv(export, "wp4034_stela_alena_2024_mensuel_et_totaux_allcol.csv", na = "")
