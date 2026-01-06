# 06_project_classification.R
# Classification des projets (HEU / H2020 / INTERREG / autres)
# --------------------------------------------------------------------

message("Classifying projects by funding programme...")

# --- Typologie projets (HEU / autres) via lpc_id -------------------------
pc_path <- file.path(db_root, "l_project_category (2).csv")
proj_cat_raw <- read_csv(pc_path, show_col_types = FALSE) |> clean_names()

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

message("✓ Projects classified: ", sum(dpr_prog$is_heu, na.rm = TRUE), " HEU projects, ",
        nrow(dpr_prog) - sum(dpr_prog$is_heu, na.rm = TRUE), " non-HEU")
