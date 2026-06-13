# compute_stundensatz_local.R  – rev. 14-Jul-2025
# -------------------------------------------------------------
library(tidyverse)
library(lubridate)
library(janitor)
library(stringr)
library(readxl)

# ── 0.  Dossiers racine ──────────────────────────────────────
dir_db    <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/datev-data"
dir_fte   <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/fte-liste"

# ── 1.  Fonctions utilitaires ───────────────────────────────
read_db  <- \(n) read_csv(file.path(dir_db, n), show_col_types = FALSE)
read_pay <- \(p){
  hdr  <- read_lines(p, n_max = 30)
  skip <- which(str_detect(hdr, regex("Pers\\.?-?Nr\\.", TRUE)))[1] - 1L
  read_csv2(p,
            skip   = skip,
            locale = locale(decimal_mark = ",", grouping_mark = "."),
            show_col_types = FALSE) |>
    clean_names()
}
read_fte <- \(p){
  read_excel(p, sheet = 1, skip = 0) |>
    clean_names() |>
    mutate(
      wirksamkeitsdatum = as_date(wirksamkeitsdatum),
      wochenstunden     = coalesce(
        wochenstunden,
        suppressWarnings(as.numeric(wöchentliche_arbeitszeit))
      ),
      fte = str_replace_na(fte, "1") |> str_replace(",", ".") |> as.numeric()
    ) |>
    filter(status == "Aktiv") |>
    transmute(
      pers_nr     = personalnummer,
      entity_code = str_sub(personalnummer, 1, 4),
      wirksamkeitsdatum,
      wochenstunden,
      fte
    )
}

# ── 2.  Données Steinbeis ───────────────────────────────────
d_user                 <- read_db("d_user.csv")
d_worktime             <- read_db("d_worktime.csv")
d_workpackage          <- read_db("d_workpackage.csv")
n_worktime2workpackage <- read_db("n_worktime2workpackage.csv")

# ── 3.  Paie DATEV (lecture brute) ──────────────────────────
payroll_raw <- list.files(
  dir_datev,
  pattern   = "_Personalkosten_.*\\.csv$",
  full.names= TRUE
) |>
  map_dfr(\(f) read_pay(f) |> mutate(src_file = basename(f)))

# ── 3a. Export complet DATEV (brut) trié par entité & mois ───
# 1) on repère la colonne “gesamtkosten…”
datev_ag_col <- names(payroll_raw) |>
  str_subset("^gesamtkosten") |>
  (\(v) if ("gesamtkosten" %in% v) "gesamtkosten" else v[1])()

# 2) on re-crée entity_code + month, on extrait brut
datev_all_export <- payroll_raw |>
  mutate(
    entity_code = str_extract(src_file, "^\\d{5}") |> str_sub(-4L),
    month       = str_extract(src_file, "\\d{2}_\\d{4}") |>
      parse_date_time("my") |> floor_date("month")
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

write_csv(
  datev_all_export,
  file.path(dir_db, "datev_all_months_by_entity.csv"),
  na = ""
)
message("✅ Export DATEV brut écrit dans: ",
        file.path(dir_db, "datev_all_months_by_entity.csv"))

# ── 4.  Paie DATEV (agrégation + clé secours par nom) ───────
# on agrège ensuite les coûts par (entity, month, pers_nr_short, nom, prénom)
payroll <- payroll_raw |>
  transmute(
    entity_code   = str_extract(src_file, "^\\d{5}") |> str_sub(-4L),
    month         = str_extract(src_file, "\\d{2}_\\d{4}") |>
      parse_date_time("my") |> floor_date("month"),
    pers_nr_short = as.integer(pers_nr),           # distingue mêmes noms sur entités diverses
    surname_pay   = str_to_lower(nachname),
    given_pay     = str_to_lower(vorname),
    ag_brutto     = .data[[datev_ag_col]]
  ) |>
  group_by(month, entity_code, pers_nr_short, surname_pay, given_pay) |>
  summarise(ag_brutto = sum(ag_brutto), .groups = "drop")

# ── 5.  Utilisateurs : clés numéro & nom ───────────────────
users_key <- d_user |>
  mutate(full = as.character(du_hr_numbers)) |>
  replace_na(list(full = "")) |>
  separate_rows(full, sep = "\\s*,\\s*") |>
  filter(full != "") |>
  mutate(
    entity_code    = str_sub(full, 1, 4),
    pers_nr_short  = as.integer(str_sub(full, 5)),
    surname_user   = str_to_lower(du_surname),
    given_user     = str_to_lower(du_name)
  ) |>
  select(du_id, entity_code, pers_nr_short, surname_user, given_user)

users_by_name <- d_user |>
  mutate(
    surname_user = str_to_lower(du_surname),
    given_user   = str_to_lower(du_name)
  ) |>
  select(du_id, surname_user, given_user) |>
  distinct()

# ── 6.  Entité par work-package ─────────────────────────────
dwp_entity <- (function(){
  cols <- names(d_workpackage)
  if ("dwp_costcenter" %in% cols) {
    d_workpackage |> mutate(entity_code = str_extract(dwp_costcenter, "^\\d{4}"))
  } else if (file.exists(file.path(dir_db, "d_costcenter.csv"))) {
    cc <- read_db("d_costcenter.csv")
    code_col <- intersect(c("dcc_code","dcc_number","costcenter_code"), names(cc))[1]
    d_workpackage |>
      left_join(
        cc |> transmute(
          dcc_id,
          entity_code = str_extract(.data[[code_col]], "^\\d{4}")
        ),
        by = "dcc_id"
      )
  } else {
    cc_map <- c(`8`="2016", `9`="2017", `10`="2136")
    d_workpackage |> mutate(
      entity_code = recode(as.character(dcc_id), !!!cc_map)
    )
  }
})() |>
  select(dwp_id, entity_code)
# ── 7.  Secondes travaillées corrigées avec start/end/break ──────────────────────────
#
# On calcule d’abord, pour chaque pointage, le vrai nombre de secondes travaillées :
#   • (dwt_end – dwt_start) – dwt_break (pause midi)
#   • on passe à 0 si la ligne n’a pas de début/fin (cas congé : dwt_leave)
d_worktime_durations <- d_worktime %>%
  mutate(
    # 1) mettre dwt_date au format Date, extraire le mois
    dwt_date      = as_date(dwt_date),
    month         = floor_date(dwt_date, "month"),
    # 2) calculer work_seconds
    work_seconds = case_when(
      !is.na(dwt_start) & !is.na(dwt_end) ~
        (dwt_end - dwt_start - coalesce(dwt_break, 0)),
      TRUE                                ~ 0L
    )
  )

# 7b) Total global de secondes travaillées par utilisateur × mois
wt_full <- n_worktime2workpackage %>%
  inner_join(
    d_worktime_durations %>% select(dwt_id, du_id, month, work_seconds),
    by = "dwt_id"
  ) %>%
  group_by(du_id, month) %>%
  summarise(
    sec_any = sum(work_seconds, na.rm = TRUE),
    .groups = "drop"
  )

# 7c) Total de secondes travaillées par utilisateur × entité × mois
wt_by_entity <- n_worktime2workpackage %>%
  inner_join(dwp_entity, by = "dwp_id") %>%
  inner_join(
    d_worktime_durations %>% select(dwt_id, du_id, month, work_seconds),
    by = "dwt_id"
  ) %>%
  group_by(du_id, entity_code, month) %>%
  summarise(
    sec_entity = sum(work_seconds, na.rm = TRUE),
    .groups    = "drop"
  )

# ── 8.  FTE (capacités contractuelles) ──────────────────────
fte_file <- file.path(dir_fte, "Wochenarbeitszeit.xlsx")
fte_raw  <- if (file.exists(fte_file)) {
  tryCatch(read_fte(fte_file),
           error = \(e) {
             warning("⚠️ FTE : ", e$message)
             tibble()
           })
} else {
  warning("⚠️ Wochenarbeitszeit.xlsx introuvable – colonnes contractuelles vides.")
  tibble()
}

fte_month <- if (nrow(fte_raw) > 0) {
  fte_raw |>
    mutate(month = floor_date(wirksamkeitsdatum, "month")) |>
    group_by(pers_nr, entity_code) |>
    arrange(month) |>
    tidyr::complete(
      month = seq(min(month), max(floor_date(Sys.Date(), "month")), by = "month")
    ) |>
    fill(wochenstunden, fte, .direction = "down") |>
    ungroup() |>
    mutate(
      contract_hours_month = wochenstunden * fte * (days_in_month(month) / 7)
    ) |>
    transmute(
      month,
      entity_code,
      pers_nr_short        = as.integer(pers_nr),
      contract_hours_month
    )
} else {
  tibble(
    month                = as.Date(character()),
    entity_code          = character(),
    pers_nr_short        = integer(),
    contract_hours_month = numeric()
  )
}

# ── 9.  Construction de la table maître ──────────────────────
master <- payroll |>
  # 1️⃣ jointure numéro
  left_join(users_key,
            by = c("entity_code", "pers_nr_short")) |>
  # 2️⃣ jointure secours par nom
  left_join(users_by_name,
            by = c("surname_pay" = "surname_user",
                   "given_pay"   = "given_user"),
            na_matches = "never") |>
  mutate(
    du_id     = coalesce(du_id.x, du_id.y),
    surname   = coalesce(surname_pay, surname_user),
    givenname = coalesce(given_pay,  given_user)
  ) |>
  select(-ends_with(".x"), -ends_with(".y"),
         -surname_pay, -given_pay, -surname_user, -given_user) |>
  # 3️⃣ secondes
  left_join(wt_by_entity,
            by = c("du_id", "entity_code", "month")) |>
  left_join(wt_full,
            by = c("du_id", "month")) |>
  mutate(seconds_worked = coalesce(sec_entity, sec_any)) |>
  select(-sec_entity, -sec_any) |>
  # 4️⃣ capacité contractuelle
  left_join(fte_month,
            by = c("entity_code", "pers_nr_short", "month")) |>
  # 5️⃣ métriques finales
  mutate(
    hours_worked             = seconds_worked / 3600,
    stundensatz_worked_h     = if_else(
      hours_worked > 0,
      round(ag_brutto / hours_worked, 2),
      NA_real_
    ),
    stundensatz_contract_h   = if_else(
      contract_hours_month > 0,
      round(ag_brutto / contract_hours_month, 2),
      NA_real_
    )
  ) |>
  arrange(month, entity_code, surname, givenname)

# ── 10. Export final ────────────────────────────────────────
out <- file.path(dir_db, "master_stundensatz_all_months.csv")
write_csv(master, out)
message("✅ Master table écrit dans : ", out)
