# report_robin_costs.R
# -----------------------------------------------------------------------------
# Utility script to compute company costs per person for the ROBIN project
# across its RP1 reporting window (01-Mar-2024 to 31-Aug-2025).
#
# The script expects the following input directories (customise via environment
# variables if your data lives elsewhere):
#   - DATEV payroll exports:    STEINBEIS_DATEV_DIR (default: data/personalkosten)
#   - Project database exports: STEINBEIS_DB_DIR    (default: data/database)
#
# Required CSV exports inside the database directory:
#   d_user.csv, d_worktime.csv, n_worktime2workpackage.csv,
#   d_workpackage.csv, d_project.csv, d_costcenter.csv,
#   l_project_category (2).csv
#
# The resulting per-person totals are printed to the console and written to
# `data/outputs/robin_project_costs_2024-03_to_2025-08.csv` (customisable via
# STEINBEIS_OUTPUT_DIR).
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(janitor)
  library(stringi)
})

# ---- Configuration ----------------------------------------------------------
# Direct paths (simplified for this installation)
dir_datev   <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/datev-data"
dir_db      <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database"
dir_outputs <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database"

required_dirs <- c(dir_datev, dir_db)
missing_dirs <- required_dirs[!dir.exists(required_dirs)]
if (length(missing_dirs) > 0) {
  stop("Input directory not found: ", paste(missing_dirs, collapse = ", "),
       "\nSet STEINBEIS_DATEV_DIR / STEINBEIS_DB_DIR or create the directories.")
}

if (!dir.exists(dir_outputs)) {
  dir.create(dir_outputs, recursive = TRUE, showWarnings = FALSE)
}

period_start <- as.Date("2024-03-01")  # Changed to match Stella's reporting period
period_end   <- as.Date("2025-08-31")
target_project_keyword <- Sys.getenv("STEINBEIS_PROJECT_KEYWORD", unset = "ROBIN")
target_entities <- strsplit(Sys.getenv("STEINBEIS_ENTITY_CODES", unset = "2016,2017,2136"),
                            "[,;]", perl = TRUE)[[1]] |>
  trimws() |>
  discard(~ .x == "")
if (length(target_entities) == 0) target_entities <- c("2016", "2017", "2136")

# ---- Helper functions -------------------------------------------------------
read_db <- function(filename, ...) {
  path <- file.path(dir_db, filename)
  if (!file.exists(path)) {
    stop("Missing database export: ", path)
  }
  read_csv(path, show_col_types = FALSE, ...)
}

read_db_ben <- function(filename, ...) {
  path <- file.path(dir_db, "ben", filename)
  if (!file.exists(path)) {
    stop("Missing database export: ", path)
  }
  read_csv(path, show_col_types = FALSE, ...)
}

read_datev <- function(path) {
  header <- read_lines(path, n_max = 30)
  skip <- which(str_detect(header, regex("Pers\\.?-?Nr\\.", ignore_case = TRUE)))[1] - 1L
  read_csv2(path, skip = skip,
            locale = locale(decimal_mark = ",", grouping_mark = "."),
            show_col_types = FALSE) |>
    clean_names()
}

normalize_name <- function(x) {
  x |>
    str_to_lower() |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_replace_all("[^a-z ]", "") |>
    str_squish()
}

# ---- Load database tables ---------------------------------------------------
d_user  <- read_db("d_user.csv",
                   col_types = cols(du_hr_numbers = col_character())) |>
  clean_names()
d_wt    <- read_db_ben("d_worktime.csv")     |> clean_names()
n_w2wp  <- read_db_ben("n_worktime2workpackage.csv") |> clean_names()
d_wp    <- read_db_ben("d_workpackage.csv")  |> clean_names()
d_pr    <- read_db_ben("d_project.csv")      |> clean_names()
d_cc    <- read_db("d_costcenter.csv")   |> clean_names()
proj_cat_raw <- read_db("l_project_category (2).csv") |> clean_names()

# ---- Load payroll and standardise ------------------------------------------
datev_files <- list.files(dir_datev, pattern = "_Personalkosten_.*\\.csv$",
                          full.names = TRUE)
if (length(datev_files) == 0) {
  stop("No DATEV payroll exports were found in ", dir_datev)
}

payroll_raw <- map_dfr(datev_files, ~ read_datev(.x) |> mutate(src_file = basename(.x)))
datev_gk_col <- names(payroll_raw) |>
  keep(~ str_detect(.x, "^gesamtkosten")) |>
  first()
if (is.null(datev_gk_col)) {
  stop("Could not detect the Gesamtkosten column in the DATEV exports.")
}

payroll_all <- payroll_raw |>
  mutate(
    entity_code = str_extract(src_file, "^\\d{5}") |> str_sub(-4L),
    month_str   = str_extract(src_file, "\\d{2}[-_]\\d{4}"),
    month       = month_str |>
      str_replace("_", "-") |>
      parse_date_time("my") |>
      floor_date("month")
  ) |>
  transmute(
    entity_code,
    month,
    pers_nr = as.character(pers_nr),
    surname = str_to_lower(nachname),
    given   = str_to_lower(vorname),
    gesamtkosten = .data[[datev_gk_col]]
  ) |>
  mutate(pers_nr = str_remove_all(pers_nr, "^0+")) |>
  filter(str_detect(pers_nr, "^[0-9]+$"))

payroll <- payroll_all |>
  group_by(entity_code, month, pers_nr, surname, given) |>
  summarise(
    gesamtkosten = sum(gesamtkosten, na.rm = TRUE),
    .groups = "drop"
  ) |>
  mutate(pers_nr_short = as.integer(pers_nr))

# ---- Map payroll people to d_user ------------------------------------------
users_key <- d_user |>
  mutate(hr_list = str_split(du_hr_numbers, ",")) |>
  unnest(hr_list) |>
  mutate(
    hr_list       = str_trim(hr_list),
    entity_code   = str_sub(hr_list, 1, 4),
    pers_nr_short = as.integer(str_remove(str_sub(hr_list, 5), "^0+"))
  ) |>
  transmute(du_id, entity_code, pers_nr_short,
            surname_user = str_to_lower(du_surname),
            given_user   = str_to_lower(du_name)) |>
  distinct()

payroll_unmatched <- payroll |>
  anti_join(users_key |> select(entity_code, pers_nr_short),
            by = c("entity_code", "pers_nr_short"))

unique_name_to_du <- d_user |>
  transmute(du_id,
            name_key = paste(normalize_name(du_surname),
                              normalize_name(du_name))) |>
  filter(name_key != " ") |>
  count(name_key, name = "n") |>
  filter(n == 1) |>
  select(name_key) |>
  inner_join(d_user |>
               transmute(du_id,
                         name_key = paste(normalize_name(du_surname),
                                           normalize_name(du_name))),
             by = "name_key") |>
  select(name_key, du_id)

inferred_links <- payroll_unmatched |>
  transmute(entity_code,
            pers_nr_short,
            name_key = paste(normalize_name(surname), normalize_name(given))) |>
  distinct() |>
  inner_join(unique_name_to_du, by = "name_key") |>
  anti_join(users_key |> select(du_id, entity_code, pers_nr_short),
            by = c("du_id", "entity_code", "pers_nr_short")) |>
  select(du_id, entity_code, pers_nr_short)

if (nrow(inferred_links) > 0) {
  users_key <- bind_rows(users_key, inferred_links) |>
    distinct(du_id, entity_code, pers_nr_short, .keep_all = TRUE)
}

payroll_linked <- payroll |>
  left_join(users_key, by = c("entity_code", "pers_nr_short")) |>
  filter(!is.na(du_id))

payroll_month <- payroll_linked |>
  group_by(du_id, entity_code, month) |>
  summarise(
    monat_kosten = sum(gesamtkosten, na.rm = TRUE),
    surname_pay  = first(surname),
    given_pay    = first(given),
    .groups = "drop"
  )

# ---- Time tracking allocations ---------------------------------------------
wp_entity_map <- d_wp |>
  left_join(d_cc |> transmute(dcc_id, entity_code = as.character(dcc_number)),
            by = "dcc_id") |>
  transmute(dwp_id, entity_code, dpr_id)

d_wt2 <- d_wt |>
  mutate(
    dwt_date  = as_date(dwt_date),
    month     = floor_date(dwt_date, "month"),
    # CORRECTED: Use dwt_worktime field directly (booked hours from TKS)
    # instead of deriving from timestamps (which are unreliable)
    work_secs = coalesce(dwt_worktime, 0)
  )

# CORRECTED: Use actual per-WP allocation from nww_worktime_seconds
# instead of equal splitting across WPs
d2wp_all <- n_w2wp |>
  select(dwt_id, dwp_id, nww_worktime_seconds) |>
  left_join(d_wt2 |> select(dwt_id, du_id, month), by = "dwt_id") |>
  mutate(work_secs_alloc = coalesce(nww_worktime_seconds, 0))

# ---- Project metadata -------------------------------------------------------
get_first_col <- function(df, candidates, label) {
  hit <- intersect(candidates, names(df))
  if (length(hit) == 0) {
    stop("Column for ", label, " not found. Available columns: ",
         paste(names(df), collapse = ", "))
  }
  hit[1]
}

wp_proj_id_col <- get_first_col(d_wp, c("dpr_id", "project_id", "dwp_project_id"),
                                "project identifier in d_workpackage")
wp_title_col   <- get_first_col(d_wp, c("dwp_title", "wp_title", "title", "name"),
                                "work package title")
proj_id_col    <- get_first_col(d_pr, c("dpr_id", "project_id", "id"),
                                "project identifier in d_project")
proj_title_col <- get_first_col(d_pr, c("dpr_title", "title", "name"),
                                "project title")
proj_cat_id_col <- get_first_col(proj_cat_raw,
                                 c("lpc_id", "project_category_id", "id"),
                                 "project category identifier")
proj_cat_label_col <- get_first_col(proj_cat_raw,
                                    c("lpc_project_category", "project_category", "programme",
                                      "program", "programme_name", "funding_programme",
                                      "category", "type", "name"),
                                    "project category label")

proj_cat <- proj_cat_raw |>
  transmute(
    lpc_id = .data[[proj_cat_id_col]],
    label  = .data[[proj_cat_label_col]]
  ) |>
  filter(!is.na(lpc_id)) |>
  distinct() |>
  mutate(
    programme = case_when(
      str_detect(str_to_lower(label), "\\bhorizon europe\\b|\\bheu\\b") ~ "HEU",
      str_detect(str_to_lower(label), "\\bh2020\\b|\\bhorizon 2020\\b") ~ "H2020",
      str_detect(str_to_lower(label), "\\binterreg\\b") ~ "INTERREG",
      TRUE ~ toupper(as.character(label))
    ),
    is_heu = programme == "HEU"
  ) |>
  select(lpc_id, programme, is_heu)

wp_info <- d_wp |>
  transmute(
    dwp_id,
    dpr_id = .data[[wp_proj_id_col]],
    wp_title = .data[[wp_title_col]]
  )

dpr_prog <- d_pr |>
  transmute(
    dpr_id   = .data[[proj_id_col]],
    project  = .data[[proj_title_col]],
    lpc_id   = lpc_id
  ) |>
  left_join(proj_cat, by = "lpc_id")

# ---- Build cost allocation per project -------------------------------------
cost_by_pr_raw <- d2wp_all |>
  inner_join(wp_entity_map |> select(dwp_id, entity_code), by = "dwp_id") |>
  filter(entity_code %in% target_entities) |>
  inner_join(wp_info, by = "dwp_id") |>
  inner_join(dpr_prog, by = "dpr_id") |>
  mutate(month = as.Date(month)) |>
  group_by(du_id, dpr_id, project, programme, is_heu, dwp_id, wp_title, month, entity_code) |>
  summarise(sec_pr = sum(work_secs_alloc, na.rm = TRUE), .groups = "drop")

cost_by_pr <- cost_by_pr_raw |>
  mutate(hours = sec_pr / 3600) |>
  group_by(du_id, entity_code, month) |>
  mutate(hours_month = sum(hours, na.rm = TRUE)) |>
  ungroup() |>
  left_join(payroll_month, by = c("du_id", "entity_code", "month")) |>
  mutate(
    cost_share = if_else(hours_month > 0, hours / hours_month, 0),
    cost = cost_share * coalesce(monat_kosten, 0),
    pers_surname = coalesce(surname_pay, NA_character_),
    pers_given   = coalesce(given_pay, NA_character_)
  ) |>
  select(du_id, entity_code, month, project_id = dpr_id, project, programme,
         is_heu, workpackage = dwp_id, wp_title, hours, cost,
         pers_surname, pers_given)

# ---- Filter ROBIN project and reporting window ------------------------------
project_filter <- str_to_upper(target_project_keyword)
robin_costs <- cost_by_pr |>
  filter(month >= floor_date(period_start, "month"),
         month <= floor_date(period_end, "month")) |>
  filter(str_detect(str_to_upper(project), project_filter)) |>
  group_by(du_id) |>
  summarise(
    employee = first(str_c(str_to_title(pers_given), " ", str_to_title(pers_surname))),
    first_entity = first(entity_code),
    total_hours = sum(hours, na.rm = TRUE),
    total_cost  = round(sum(cost, na.rm = TRUE), 2),
    .groups = "drop"
  ) |>
  arrange(desc(total_cost))

if (nrow(robin_costs) == 0) {
  warning("No timesheet entries matched the ROBIN filter '", project_filter,
          "' between ", period_start, " and ", period_end, ".")
}

output_path <- file.path(
  dir_outputs,
  sprintf("robin_project_costs_%s_to_%s.csv",
          format(period_start, "%Y-%m"), format(period_end, "%Y-%m"))
)
write_csv(robin_costs, output_path, na = "")

print(robin_costs)
message("\n✓ ROBIN cost breakdown saved to: ", output_path)
