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
dir_db    <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/datev-data"
dir_fte   <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/fte-liste"

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
      # Wochenstunden is already numeric-ish but may come in as "40,00"
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

# normalize helper: strip accents/punct, lowercase, collapse spaces
normalize <- function(x){
  x |>
    str_to_lower() |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_replace_all("[^a-z ]","") |>
    str_squish()
}

# --- 2. Read Steinbeis (TKS) tables ----------------------------

d_user_all  <- read_db("d_user.csv") |> clean_names()

d_user <- d_user_all %>%
  filter(is.na(du_inactive) | du_inactive == FALSE)

cat("✔️  Nombre de personnes actives dans d_user :", nrow(d_user), "\n")
cat("❌  Nombre de personnes inactives supprimées :", sum(d_user_all$du_inactive == TRUE, na.rm=TRUE), "\n")

d_wt    <- read_db("d_worktime.csv")      |> clean_names()
n_w2wp  <- read_db("n_worktime2workpackage.csv") |> clean_names()
d_wp    <- read_db("d_workpackage.csv")    |> clean_names()
d_pr    <- read_db("d_project.csv")        |> clean_names()

# ── 3.  Paie DATEV (lecture brute) ──────────────────────────

# 3a) Grab & sort every Personalkosten CSV in the folder
datev_files <- list.files(
  dir_datev,
  pattern    = "_Personalkosten_.*\\.csv$",
  full.names = TRUE
) |> sort()

if (length(datev_files)==0) {
  stop("⚠️ No Datev files found in: ", dir_datev)
}

payroll_raw <- map_dfr(datev_files, function(f){
  read_pay(f) |>
    mutate(src_file = basename(f))
})

# 3b) Find the right “gesamtkosten…” column
datev_ag_col <- names(payroll_raw) |>
  str_subset("^gesamtkosten") |>
  (\(v) if ("gesamtkosten" %in% v) "gesamtkosten" else v[1])()

# 3c) Re-create entity_code + month (handles MM-YYYY or MM_YYYY),
#     and export the full raw dump for inspection
datev_all_export <- payroll_raw |>
  mutate(
    entity_code = str_extract(src_file, "^\\d{5}") |> str_sub(-4L),
    month_str   = str_extract(src_file, "\\d{2}[-_]\\d{4}"),
    month       = month_str
    |> str_replace("_","-")
    |> parse_date_time("my")
    |> floor_date("month")
  ) |>
  transmute(
    entity_code,
    month,
    pers_nr   = pers_nr,
    surname   = nachname,
    givenname = vorname,
    ag_brutto = .data[[datev_ag_col]]
  ) |>
  arrange(entity_code, month, surname, givenname)

# write out the raw-by-month-and-entity for quick checking:
write_csv(
  datev_all_export,
  file.path(dir_db, "datev_all_months_by_entity.csv"),
  na = ""
)
message(
  "✅ Export DATEV brut (all files) written to: ",
  file.path(dir_db, "datev_all_months_by_entity.csv")
)

# --- 3c-bis. NORMALISER LE NUMERO PERSONNEL POUR CHAQUE PERSONNE ------------------------------------

# 1. Nettoyer pers_nr : enlever zéros en trop, forcer en character
datev_all_export <- datev_all_export %>%
  mutate(
    pers_nr_clean = str_remove_all(as.character(pers_nr), "^0+")
  )

# 2. Identifier la valeur majoritaire par personne
persnr_mode <- datev_all_export %>%
  filter(!is.na(pers_nr_clean), !is.na(surname), !is.na(givenname)) %>%
  group_by(entity_code, surname, givenname, pers_nr_clean) %>%
  summarise(n = n(), .groups="drop") %>%
  group_by(entity_code, surname, givenname) %>%
  slice_max(order_by = n, n = 1, with_ties = FALSE) %>% # le pers_nr majoritaire
  ungroup() %>%
  select(entity_code, surname, givenname, pers_nr_ref = pers_nr_clean)

# 3. Réinjecter ce numéro unique à toutes les lignes (pour tous les mois de la personne)
datev_all_export <- datev_all_export %>%
  left_join(persnr_mode, by = c("entity_code", "surname", "givenname")) %>%
  mutate(
    pers_nr_final = coalesce(pers_nr_ref, pers_nr_clean), # prioritaire : le plus fréquent
    pers_nr_final = str_remove_all(as.character(pers_nr_final), "^0+")
  ) %>%
  select(-pers_nr_clean, -pers_nr_ref)

# 4. Pour la suite du pipeline, utiliser “pers_nr_final” à la place de l’ancien “pers_nr”
datev_all_export <- datev_all_export %>%
  mutate(pers_nr = pers_nr_final) %>%
  select(-pers_nr_final)

# ── 3d.  Aggregate for the main pipeline ─────────────────────
payroll <- datev_all_export |>
  group_by(entity_code, month, pers_nr, surname, givenname) |>
  summarise(
    pers_nr_short = as.integer(pers_nr),
    surname_pay   = str_to_lower(surname),
    given_pay     = str_to_lower(givenname),
    ag_brutto     = sum(ag_brutto, na.rm=TRUE),
    .groups="drop"
  )

# Now downstream “master” will have exactly one row per
# entity × each of the 12 months of 2024 (assuming you have
# 12 files named …_01-2024.csv through …_12-2024.csv).

# --- 4. Build Steinbeis ↔ d_user linking keys -------------------
# Extraction robuste entity_code et pers_nr_short (3 derniers chiffres, sans zéro de tête si besoin)

users_key <- d_user %>%
  mutate(full = as.character(du_hr_numbers)) %>%
  # Corrige le format scientific éventuel (ex: 2.016060e+13 → 2016060001234)
  mutate(full = ifelse(grepl("e\\+", full),
                       format(as.numeric(full), scientific=FALSE, trim=TRUE),
                       full)) %>%
  replace_na(list(full = "")) %>%
  separate_rows(full, sep = "\\s*,\\s*") %>%
  filter(full != "") %>%
  mutate(
    full = str_trim(full),
    entity_code   = str_sub(full, 1, 4),
    pers_nr_full  = str_sub(full, 5)
  ) %>%
  mutate(
    # Conversion en entier pour éviter les notations scientifiques
    pers_nr_full_num = as.integer(pers_nr_full),
    # On récupère les 3 derniers chiffres en string
    pers_nr_short_str = str_sub(as.character(pers_nr_full_num), -3, -1),
    # Si ça commence par un 0, on enlève le zéro (ex: "011" → "11")
    pers_nr_short = if_else(
      str_sub(pers_nr_short_str, 1, 1) == "0",
      as.integer(str_sub(pers_nr_short_str, 2, 3)),
      as.integer(pers_nr_short_str)
    )
  ) %>%
  transmute(
    du_id,
    entity_code,
    pers_nr_short,
    surname_user  = str_to_lower(du_surname),
    given_user    = str_to_lower(du_name)
  )
users_by_name <- users_key %>%
  transmute(
    du_id,
    surname_norm = normalize(surname_user),
    given_norm   = normalize(given_user)
  ) %>% distinct()

# --- 5. Exact + fuzzy join payroll → du_id ---------------------
# 5a) exact on number
pl_exact <- payroll |>
  mutate(
    .row = row_number(),
    surname_norm = normalize(surname_pay),
    given_norm   = normalize(given_pay)
  ) |>
  left_join(users_key, by=c("entity_code","pers_nr_short")) |>
  rename(du_id_exact = du_id)

# 5b) fuzzy for the ones still NA
need_fuzzy <- filter(pl_exact, is.na(du_id_exact))
if(nrow(need_fuzzy)>0){
  fused <- stringdist_left_join(
    need_fuzzy, users_by_name,
    by=c("surname_norm","given_norm"),
    method="jw", max_dist=0.1, distance_col="dist"
  ) |>
    group_by(.row) |> slice_min(dist,n=1) |> ungroup() |>
    select(.row, du_id_fuzzy=du_id)
  pl_exact <- left_join(pl_exact, fused, by=".row")
} else {
  pl_exact <- mutate(pl_exact, du_id_fuzzy=NA_integer_)
}

payroll_linked <- pl_exact |>
  mutate(du_id = coalesce(du_id_exact, du_id_fuzzy)) |>
  filter(!is.na(du_id)) |>   # drop unmapped
  select(-.row, -du_id_exact, -du_id_fuzzy, -surname_norm, -given_norm)

# --- 5c. Analyse multi-cost-center : désambigüisation du_id/pers_nr_short/nom/prénom ------------

# 1. Repérer pour chaque combinaison "personne unique" (du_id, surname_pay, given_pay) le nombre de cost centers
multi_cc_full <- payroll_linked %>%
  group_by(du_id, surname_pay, given_pay) %>%
  summarise(n_cc = n_distinct(entity_code), .groups="drop") %>%
  filter(n_cc > 1)

cat("➡️ Nombre de personnes (du_id, nom, prénom) multi-cost center :", nrow(multi_cc_full), "\n")

# 2. Liste détaillée des personnes concernées (tous les cost centers associés)
multi_cc_detail <- payroll_linked %>%
  mutate(nom_complet = paste(surname_pay, given_pay)) %>%
  semi_join(multi_cc_full, by = c("du_id", "surname_pay", "given_pay")) %>%
  select(du_id, entity_code, pers_nr_short, surname_pay, given_pay) %>%
  distinct() %>%
  arrange(du_id, surname_pay, given_pay, entity_code)

# 3. Export pour audit
write_csv(multi_cc_detail, file.path(dir_db, "personnes_multi_costcenter_final.csv"), na = "")

# 4. Afficher un aperçu
print(multi_cc_detail, n = 20)

# --- 5d. Construction d'une master table personne complète ---------------------
# Rassemble toutes les infos disponibles pour chaque personne (d_user + users_key + paie)

master_personnes <- d_user %>%
  left_join(
    users_key %>% 
      select(du_id, entity_code, pers_nr_short), 
    by = "du_id"
  ) %>%
  left_join(
    payroll_linked %>%
      select(entity_code, pers_nr_short, du_id, surname_pay, given_pay) %>%
      distinct(), 
    by = c("du_id", "entity_code", "pers_nr_short")
  ) %>%
  # Ajoute une info multi-CC
  mutate(
    multi_costcenter = du_id %in% multi_cc_full$du_id
  ) %>%
  # Colonnes bien lisibles
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

# Optionnel : export pour inspection manuelle
write_csv(master_personnes, file.path(dir_db, "master_personnes.csv"), na = "")

cat("✅ Table master_personnes créée et exportée.\n")
print(master_personnes, n = 15)


# --- 6. Map work‐packages to cost-centers, compute work‐seconds  ----

# Charger d_costcenter (si pas déjà en mémoire)
d_cc <- read_db("d_costcenter.csv") %>% clean_names()

# 6a) Build a dwp_id → entity_code lookup (wp_entity_map)
wp_entity_map <- d_wp %>%
  left_join(
    d_cc %>%
      transmute(
        dcc_id,
        entity_code = as.character(dcc_number)
      ),
    by = "dcc_id"
  ) %>%
  transmute(dwp_id, entity_code)

# 6b) Compute raw work‐seconds per time entry
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

# 6c) Attach each time‐entry to its WP(s)
d2wp_all <- d_wt2 %>%
  inner_join(n_w2wp %>% select(dwt_id, dwp_id), by="dwt_id")

# 6d) Sum seconds by cost-center (wt_by_entity)
wt_by_entity <- d2wp_all %>%
  inner_join(wp_entity_map, by="dwp_id") %>%
  group_by(du_id, entity_code, month) %>%
  summarise(
    sec_entity = sum(work_secs, na.rm=TRUE),
    .groups     = "drop"
  )

# 6e) Sum total seconds (all WP) per user×month (wt_full)
wt_full <- d_wt2 %>%
  group_by(du_id, month) %>%
  summarise(
    sec_any = sum(work_secs, na.rm=TRUE),
    .groups = "drop"
  )

# --- 7. Expand Personio contractual hours (CSV only) ------------
fte_file_csv <- file.path(dir_fte, "Wochenarbeitszeit.csv")
if (!file.exists(fte_file_csv)) {
  stop("⚠️ FTE CSV not found at: ", fte_file_csv)
}

fte_raw <- readr::read_delim(
  fte_file_csv,
  delim = ";",
  locale = locale(decimal_mark = ",", grouping_mark = "."),
  show_col_types = FALSE
) %>%
  clean_names() %>%
  mutate(
    wirksamkeitsdatum = lubridate::dmy(wirksamkeitsdatum),
    wochenstunden = as.numeric(wochenstunden),
    fte           = as.numeric(fte)
  ) %>%
  filter(status == "Aktiv") %>%
  transmute(
    pers_nr        = personalnummer,
    entity_code    = str_sub(personalnummer, 1, 4),
    wirksamkeitsdatum,
    wochenstunden,
    fte
  )

# Expand to one row per month per person
fte_month <- fte_raw %>%
  mutate(month = floor_date(wirksamkeitsdatum, "month")) %>%
  group_by(pers_nr, entity_code) %>%
  arrange(month) %>%
  tidyr::complete(
    month = seq(min(month), max(floor_date(Sys.Date(), "month")), by = "month")
  ) %>%
  fill(wochenstunden, fte, .direction = "down") %>%
  ungroup() %>%
  mutate(
    full_contract_week   = wochenstunden * fte,
    contract_hours_month = full_contract_week * (days_in_month(month) / 7)
  ) %>%
  transmute(
    month,
    entity_code,
    pers_nr_short        = as.integer(pers_nr),
    wochenstunden,
    fte,
    full_contract_week,
    contract_hours_month
  )

# --- 7b. Harmoniser & filtrer entités valides (avant jointure) -----------
target_entities <- c("2016", "2017", "2136")

payroll_linked <- payroll_linked %>%
  mutate(
    entity_code = str_pad(entity_code, 4, pad = "0"),
    pers_nr_short = as.integer(pers_nr_short),
    month = as.Date(month)
  ) %>%
  filter(entity_code %in% target_entities)

fte_month <- fte_month %>%
  mutate(
    entity_code = str_pad(entity_code, 4, pad = "0"),
    pers_nr_short = as.integer(pers_nr_short),
    month = as.Date(month)
  ) %>%
  filter(entity_code %in% target_entities)

if (exists("wt_by_entity")) {
  wt_by_entity <- wt_by_entity %>%
    mutate(entity_code = str_pad(entity_code, 4, pad = "0")) %>%
    filter(entity_code %in% target_entities)
}

if (exists("wt_full")) {
  wt_full <- wt_full %>% mutate(month = as.Date(month))
}
# --- 7c. Générer la grille exhaustive (du_id × entity_code × mois) --------

# Créer le vecteur des 12 mois de 2024
mois_2024 <- seq.Date(as.Date("2024-01-01"), as.Date("2024-12-01"), by = "month")

# Générer la grille : chaque du_id × entity_code × pers_nr_short pour chaque mois
base_grid <- master_personnes %>%
  select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
         surname_pay, given_pay, du_inactive, multi_costcenter) %>%
  distinct() %>%
  tidyr::crossing(month = mois_2024)

cat("✔️  Grille de base complète générée : lignes attendues = ",
    nrow(base_grid), "\n")

# --- 8. Build enriched master_personnes including all computed data --------

# 8.1) Agréger la paie pour n'avoir qu'une ligne par du_id/entity_code/pers_nr_short/month
payroll_agg <- payroll_linked %>%
  group_by(du_id, entity_code, pers_nr_short, month) %>%
  summarise(
    ag_brutto   = sum(ag_brutto, na.rm = TRUE),
    pay_surname = first(surname_pay),
    pay_given   = first(given_pay),
    .groups     = "drop"
  )

# 8.2) Enrichir base_grid (la grille exhaustive) avec toutes les données calculées
master_final <- base_grid %>%
  left_join(payroll_agg,
            by = c("du_id", "entity_code", "pers_nr_short", "month")) %>%
  left_join(fte_month,
            by = c("entity_code", "pers_nr_short", "month")) %>%
  left_join(wt_by_entity,
            by = c("du_id", "entity_code", "month")) %>%
  left_join(wt_full,
            by = c("du_id", "month")) %>%
  mutate(
    # remettre à du_surname/du_name si pas de correspondance paie
    surname_pay = coalesce(pay_surname, du_surname),
    given_pay   = coalesce(pay_given,   du_name),
    # calculs heures & taux
    total_secs                = coalesce(sec_entity, sec_any),
    hours_worked              = total_secs / 3600,
    stundensatz_worked_h      = if_else(
      hours_worked > 0,
      round(ag_brutto / hours_worked, 2),
      NA_real_
    ),
    stundensatz_contract_h    = if_else(
      contract_hours_month > 0,
      round(ag_brutto / contract_hours_month, 2),
      NA_real_
    ),
    stundensatz_fullcontract  = if_else(
      full_contract_week > 0,
      round(
        ag_brutto /
          (full_contract_week * (days_in_month(month) / 7)),
        2
      ),
      NA_real_
    )
  ) %>%
  select(
    du_id, du_login, du_name, du_surname,
    entity_code, pers_nr_short,
    surname_pay, given_pay,
    du_inactive, multi_costcenter,
    month,
    ag_brutto, wochenstunden, fte,
    full_contract_week, contract_hours_month,
    hours_worked,
    stundensatz_worked_h,
    stundensatz_contract_h,
    stundensatz_fullcontract
  ) %>%
  arrange(du_id, entity_code, month)

# 8.3) Export pour vérification
write_csv(master_final,
          file.path(dir_db, "master_personnes_enriched.csv"),
          na = "")
cat("✅ Table master_personnes enrichie créée et exportée.\n")
print(master_final, n = 15)

# --- 9. Cost breakdown by project & work-package for ALL users + d_user names ----

cost_by_pr <- d2wp %>%
  inner_join(
    d_wp %>% select(dwp_id, wp_title = dwp_title, dpr_id),
    by = "dwp_id"
  ) %>%
  inner_join(
    d_pr %>% select(dpr_id, project = dpr_title),
    by = "dpr_id"
  ) %>%
  group_by(du_id, dpr_id, project, dwp_id, wp_title, month) %>%
  summarise(
    sec_pr = sum(work_secs, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(
    master_final %>% select(
      du_id, month,
      ag_brutto,
      hours_worked,
      du_name, du_surname
    ),
    by = c("du_id", "month")
  ) %>%
  mutate(
    hours_wp = sec_pr / 3600,
    pct_time = hours_wp / hours_worked,
    cost_wp  = ag_brutto * pct_time
  ) %>%
  select(
    du_id,
    surname    = du_surname,
    givenname  = du_name,
    month,
    project_id  = dpr_id,
    project,
    workpackage = dwp_id,
    wp_title,
    hours       = hours_wp,
    cost        = cost_wp,
    pct_time
  ) %>%
  arrange(du_id, month, project_id, workpackage)

write_csv(cost_by_pr, file.path(dir_db, "costs_by_wp_project.csv"))
message("✅ Coûts par projet & WP écrits dans costs_by_wp_project.csv")


# --- 9. Cost breakdown by project & work-package for ALL users + d_user names ----

d2wp <- n_w2wp %>%
  inner_join(
    d_wt2 %>% select(dwt_id, du_id, month, work_secs),
    by = "dwt_id"
  )

cost_by_pr <- d2wp %>%
  inner_join(
    d_wp   %>% select(dwp_id, wp_title = dwp_title, dpr_id),
    by = "dwp_id"
  ) %>%
  inner_join(
    d_pr   %>% select(dpr_id, project = dpr_title),
    by = "dpr_id"
  ) %>%
  group_by(du_id, dpr_id, project, dwp_id, wp_title, month) %>%
  summarise(
    sec_pr = sum(work_secs, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  left_join(
    master %>% select(
      du_id, month,
      ag_brutto,
      hours_worked,
      surname_d_user,
      givenname_d_user
    ),
    by = c("du_id","month"),
    relationship = "many-to-many"
  ) %>%
  mutate(
    hours_wp = sec_pr / 3600,
    pct_time = hours_wp / hours_worked,
    cost_wp  = ag_brutto * pct_time
  ) %>%
  select(
    du_id,
    surname    = surname_d_user,
    givenname  = givenname_d_user,
    month,
    project_id  = dpr_id,
    project,
    workpackage = dwp_id,
    wp_title,
    hours       = hours_wp,
    cost        = cost_wp,
    pct_time
  ) %>%
  arrange(du_id, month, project_id, workpackage)

print(cost_by_pr, n = 50)
write_csv(cost_by_pr, file.path(dir_db, "costs_by_wp_project.csv"))
message("✅ Coûts par projet & WP écrits dans costs_by_wp_project.csv")
