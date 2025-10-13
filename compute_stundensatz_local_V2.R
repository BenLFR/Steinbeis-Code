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
d_user  <- read_db("d_user.csv")           |> clean_names()
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
users_key <- d_user |>
  mutate(full = as.character(du_hr_numbers)) |>
  replace_na(list(full="")) |>
  separate_rows(full, sep="\\s*,\\s*") |>
  filter(full!="") |>
  transmute(
    du_id,
    entity_code   = str_sub(full,1,4),
    pers_nr_short = as.integer(str_sub(full,5)),
    surname_user  = str_to_lower(du_surname),
    given_user    = str_to_lower(du_name)
  )

users_by_name <- users_key |>
  transmute(
    du_id,
    surname_norm = normalize(surname_user),
    given_norm   = normalize(given_user)
  ) |> distinct()

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

# --- 6. Map work‐packages to cost-centers, compute work‐seconds  ----

# 6a) Build a dwp_id → entity_code lookup (wp_entity_map)
wp_entity_map <- (function(){
  # if d_wp has a cost-center column on the WP itself…
  if ("dwp_costcenter" %in% names(d_wp)) {
    d_wp %>%
      transmute(
        dwp_id,
        entity_code = str_extract(dwp_costcenter, "^\\d{4}")
      )
  } else if (file.exists(file.path(dir_db, "d_costcenter.csv"))) {
    # otherwise join via a separate cost-center table
    cc <- read_db("d_costcenter.csv") %>%
      clean_names() %>%
      transmute(
        dcc_id,
        entity_code = str_extract(
          coalesce(dcc_code, dcc_number, costcenter_code),
          "^\\d{4}"
        )
      )
    d_wp %>%
      left_join(cc, by="dcc_id") %>%
      transmute(dwp_id, entity_code)
  } else {
    # ultimate fallback if you know the mapping by hand
    d_wp %>%
      mutate(entity_code = recode(
        as.character(dcc_id),
        `8`  = "2016",
        `9`  = "2017",
        `10` = "2136"
      )) %>%
      transmute(dwp_id, entity_code)
  }
})()

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
    # parse the German date column
    wirksamkeitsdatum = lubridate::dmy(wirksamkeitsdatum),
    # Wochenstunden comes in as numeric already, just coerce if needed
    wochenstunden = as.numeric(wochenstunden),
    # FTE is numeric
    fte           = as.numeric(fte)
  ) %>%
  filter(status == "Aktiv") %>%                # only active contracts
  transmute(
    pers_nr        = personalnummer,
    entity_code    = str_sub(personalnummer, 1, 4),
    wirksamkeitsdatum,
    wochenstunden,
    fte
  )

# Now expand that to one row per month per person:
fte_month <- fte_raw %>%
  mutate(month = floor_date(wirksamkeitsdatum, "month")) %>%
  group_by(pers_nr, entity_code) %>%
  arrange(month) %>%
  tidyr::complete(
    month = seq(min(month),
                max(floor_date(Sys.Date(), "month")),
                by = "month")
  ) %>%
  fill(wochenstunden, fte, .direction = "down") %>%
  ungroup() %>%
  mutate(
    # convert weekly contracted hours × FTE into a monthly capacity
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

# Harmoniser et filtrer payroll_linked
payroll_linked <- payroll_linked %>%
  mutate(
    entity_code = str_pad(entity_code, 4, pad = "0"),
    pers_nr_short = as.integer(pers_nr_short),
    month = as.Date(month)
  ) %>%
  filter(entity_code %in% target_entities)

# Harmoniser et filtrer fte_month
fte_month <- fte_month %>%
  mutate(
    entity_code = str_pad(entity_code, 4, pad = "0"),
    pers_nr_short = as.integer(pers_nr_short),
    month = as.Date(month)
  ) %>%
  filter(entity_code %in% target_entities)

# Harmoniser aussi wt_by_entity et wt_full si besoin (optionnel, utile si présence de codes sur 3 chiffres)
if (exists("wt_by_entity")) {
  wt_by_entity <- wt_by_entity %>%
    mutate(entity_code = str_pad(entity_code, 4, pad = "0")) %>%
    filter(entity_code %in% target_entities)
}

if (exists("wt_full")) {
  wt_full <- wt_full %>% mutate(month = as.Date(month))
}

# --- 8. Build “master” table including contractual hours + user names from d_user -------
# On prépare la table de noms issue de d_user
user_names <- d_user %>%
  transmute(
    du_id      = as.integer(du_id),
    du_surname = du_surname,
    du_name    = du_name
  )

master <- payroll_linked %>%
  # s'assurer que du_id est integer pour la jointure
  mutate(du_id = as.integer(du_id)) %>%
  # joindre FTE et worktime
  left_join(fte_month,    by = c("entity_code","pers_nr_short","month")) %>%
  left_join(wt_by_entity, by = c("du_id","entity_code","month")) %>%
  left_join(wt_full,      by = c("du_id","month")) %>%
  # joindre les noms "officiels" depuis d_user
  left_join(user_names,   by = "du_id") %>%
  mutate(
    total_secs               = coalesce(sec_entity, sec_any),
    hours_worked             = total_secs / 3600,
    stundensatz_worked_h     = if_else(
      hours_worked > 0,
      round(ag_brutto / hours_worked, 2),
      NA_real_
    ),
    stundensatz_contract_h   = if_else(
      contract_hours_month > 0,
      round(ag_brutto / contract_hours_month, 2),
      NA_real_
    ),
    stundensatz_fullcontract = if_else(
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
    entity_code, month, du_id, pers_nr_short,
    # noms issus de d_user
    surname_d_user = du_surname,
    givenname_d_user = du_name,
    # anciennes colonnes de référence
    surname = surname_pay,
    givenname = given_pay,
    ag_brutto,
    wochenstunden, fte,
    full_contract_week, contract_hours_month,
    hours_worked,
    stundensatz_worked_h,
    stundensatz_contract_h,
    stundensatz_fullcontract
  ) %>%
  arrange(entity_code, month, du_id)

# on peut maintenant écrire le master final
write_csv(
  master,
  file.path(dir_db, "master_stundensatz_all_months.csv"),
  na = ""
)
message("✅ Master table (with contractual hours & d_user names) written.")

# --- 9. Cost breakdown by project & work-package for ALL users + d_user names ----

# 9a) Préparer d2wp : lier chaque time entry à son work-package et garder work_secs
d2wp <- n_w2wp %>%
  inner_join(
    d_wt2 %>% select(dwt_id, du_id, month, work_secs),
    by = "dwt_id"
  )

# 9b) Agréger les secondes par utilisateur × projet × WP × mois,
#     joindre les titres et les coûts, puis calculer heures/pct/€.
cost_by_pr <- d2wp %>%
  # joindre titres WP et mapping vers projet
  inner_join(
    d_wp   %>% select(dwp_id, wp_title = dwp_title, dpr_id),
    by = "dwp_id"
  ) %>%
  inner_join(
    d_pr   %>% select(dpr_id, project = dpr_title),
    by = "dpr_id"
  ) %>%
  # sommer les secondes
  group_by(du_id, dpr_id, project, dwp_id, wp_title, month) %>%
  summarise(
    sec_pr = sum(work_secs, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  # rattacher brut mensuel, heures travaillées & noms d_user depuis master
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
  # calculer heures, % temps et coût
  mutate(
    hours_wp = sec_pr / 3600,
    pct_time = hours_wp / hours_worked,
    cost_wp  = ag_brutto * pct_time
  ) %>%
  # sélectionner & renommer pour export
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

# Afficher ou exporter
print(cost_by_pr, n = 50)
write_csv(cost_by_pr, file.path(dir_db, "costs_by_wp_project.csv"))
message("✅ Coûts par projet & WP écrits dans costs_by_wp_project.csv")
