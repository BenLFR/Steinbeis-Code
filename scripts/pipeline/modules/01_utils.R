# 01_utils.R
# Fonctions utilitaires pour le pipeline Stundensatz V9
# --------------------------------------------------------------------

# --- Fonctions de lecture de données ---------------------------------
read_db  <- \(f) read_csv(file.path(db_root, f), show_col_types = FALSE)
read_db_ben <- \(f) read_csv(file.path(dir_db_ben, f), show_col_types = FALSE)

read_pay <- \(p){
  hdr  <- read_lines(p, n_max = 30)
  skip <- which(str_detect(hdr, regex("Pers\\.?-?Nr\\.", TRUE)))[1] - 1L
  read_csv2(p, skip = skip,
            locale = locale(decimal_mark = ",", grouping_mark = "."),
            show_col_types = FALSE) |>
    clean_names()
}

# --- Fonctions de normalisation ---------------------------------------
normalize <- function(x){
  x |> str_to_lower() |> stringi::stri_trans_general("Latin-ASCII") |>
    str_replace_all("[^a-z ]","") |> str_squish()
}

normalize_name <- function(x){
  x |>
    stringr::str_to_lower() |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_replace_all("[^a-z ]","") |>
    str_squish()
}

# --- Fonctions de calcul ----------------------------------------------
round_half <- function(x) round(x * 2) / 2

# --- Worktime unit detection ----------------------------------------
as_work_seconds <- function(x){
  x_num <- suppressWarnings(as.numeric(x))
  x_pos <- x_num[!is.na(x_num) & x_num > 0]
  if (length(x_pos) == 0) {
    message("as_work_seconds: no positive values, defaulting to seconds")
    return(coalesce(x_num, 0))
  }
  med <- median(x_pos, na.rm = TRUE)
  frac <- mean(abs(x_pos - round(x_pos)) > 1e-6, na.rm = TRUE)
  unit <- "seconds"
  mult <- 1
  if (med <= 24 && frac >= 0.2) {
    unit <- "hours"
    mult <- 3600
  } else if (med <= 1440) {
    unit <- "minutes"
    mult <- 60
  }
  message(sprintf("as_work_seconds: median=%.4f, frac_decimal=%.2f -> %s", med, frac, unit))
  coalesce(x_num, 0) * mult
}

# --- Fonctions de période de reporting --------------------------------
rng_from <- function(df, col="month"){
  if (is.null(df) || nrow(df)==0 || all(is.na(df[[col]]))) return(c(NA, NA))
  x <- as.Date(df[[col]])
  c(suppressWarnings(min(x, na.rm=TRUE)),
    suppressWarnings(max(x, na.rm=TRUE)))
}

derive_months <- function(mode=c("datev","union","manual"),
                          payroll_data, fte_data, worktime_data){
  mode <- match.arg(mode)
  if (mode == "manual") {
    start <- floor_date(manual_start, "month"); end <- floor_date(manual_end, "month")
  } else if (mode == "datev") {
    r <- rng_from(payroll_data, "month")
    start <- floor_date(r[1], "month"); end <- floor_date(r[2], "month")
  } else { # union of available sources
    r1 <- rng_from(payroll_data, "month")
    r2 <- rng_from(fte_data,      "month")
    r3 <- rng_from(worktime_data, "month")
    start <- floor_date(min(r1[1], r2[1], r3[1], na.rm=TRUE), "month")
    end   <- floor_date(max(r1[2], r2[2], r3[2], na.rm=TRUE), "month")
  }
  seq(start, end, by="month")
}

# --- Fonctions de détection de colonnes -------------------------------
pick_first_col <- function(df, candidates, label_for_error){
  have <- intersect(candidates, names(df))
  if (length(have) == 0)
    stop(sprintf("Aucune colonne trouvée pour %s. Colonnes dispo: %s",
                 label_for_error, paste(names(df), collapse=", ")))
  have[1]
}

message("✓ Utils loaded")
