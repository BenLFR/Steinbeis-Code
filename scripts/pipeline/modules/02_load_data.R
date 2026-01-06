# 02_load_data.R
# Chargement des données depuis la base de données, DATEV et Personio
# --------------------------------------------------------------------

message("Loading database tables...")

# --- DB tables --------------------------------------------------------
d_user_all <- read_db("d_user.csv") |>
  mutate(du_hr_numbers = as.character(du_hr_numbers)) |>
  clean_names()
d_user <- d_user_all |> filter(is.na(du_inactive) | du_inactive == FALSE)
d_wt   <- read_db("d_worktime.csv") |> clean_names()
n_w2wp <- read_db("n_worktime2workpackage.csv") |> clean_names()
d_wp   <- read_db("d_workpackage.csv") |> clean_names()
d_pr   <- read_db("d_project.csv")     |> clean_names()   # <- has dpr_id, dpr_title, lpc_id
d_cc   <- read_db("d_costcenter.csv") |> clean_names()

message("✓ Database tables loaded")

# --- Payroll (DATEV) --------------------------------------------------
message("Loading DATEV payroll data...")

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

message("✓ DATEV payroll loaded (", nrow(payroll), " rows)")

# --- Personio contractual hours ---------------------------------------
message("Loading Personio FTE data...")

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

# Filter to target entities
fte_month <- fte_month |> filter(entity_code %in% target_entities)

message("✓ Personio FTE data loaded (", nrow(fte_month), " rows)")
