# 04b_robin_tks_export.R
# Export ROBIN hours TKS-like (sans filtre entity) pour comparaison avec Stella
# --------------------------------------------------------------------

message("Exporting ROBIN hours (TKS-based, no entity filter)...")

# ---- Filtrer ROBIN project --------------------------------------------
robin_projects <- d_pr |>
  filter(str_detect(str_to_lower(dpr_title), "\\brobin\\b")) |>
  select(dpr_id, dpr_title)

if (nrow(robin_projects) == 0) {
  warning("⚠️ No ROBIN project found in d_project!")
  robin_hours_tks_like <- tibble(
    du_id = integer(),
    employee = character(),
    dwp_id = integer(),
    wp_title = character(),
    hours = numeric(),
    total_hours = numeric()
  )
} else {
  message(sprintf("✓ Found %d ROBIN project(s): %s",
                  nrow(robin_projects),
                  paste(robin_projects$dpr_title, collapse = ", ")))

  # Récupérer work packages ROBIN
  robin_wps <- d_wp |>
    filter(dpr_id %in% robin_projects$dpr_id) |>
    select(dwp_id, wp_title = dwp_title, dpr_id)

  message(sprintf("✓ Found %d ROBIN work packages", nrow(robin_wps)))

  # ---- Filtrer d2wp_all pour ROBIN + période ----------------------------
  robin_alloc <- d2wp_all |>
    filter(dwp_id %in% robin_wps$dwp_id,
           month >= as.Date("2024-03-01"),
           month <= as.Date("2025-08-01")) |>
    left_join(robin_wps |> select(dwp_id, wp_title), by = "dwp_id") |>
    mutate(hours = work_secs_alloc / 3600)

  # ---- Agrégation par personne + WP -------------------------------------
  robin_hours_by_wp <- robin_alloc |>
    group_by(du_id, dwp_id, wp_title) |>
    summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop")

  # ---- Agrégation par personne (total) ----------------------------------
  robin_hours_by_person <- robin_alloc |>
    group_by(du_id) |>
    summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop")

  # ---- Joindre avec d_user pour noms ------------------------------------
  robin_hours_tks_like <- robin_hours_by_person |>
    left_join(d_user |> select(du_id, du_surname, du_name), by = "du_id") |>
    mutate(employee = paste(str_to_title(du_name), str_to_title(du_surname))) |>
    select(du_id, employee, total_hours) |>
    arrange(desc(total_hours))

  # Version avec détail par WP
  robin_hours_tks_detailed <- robin_hours_by_wp |>
    left_join(d_user |> select(du_id, du_surname, du_name), by = "du_id") |>
    mutate(employee = paste(str_to_title(du_name), str_to_title(du_surname))) |>
    select(du_id, employee, dwp_id, wp_title, hours) |>
    arrange(employee, dwp_id)

  # ---- Export CSV -------------------------------------------------------
  if (!dir.exists(qa_dir)) dir.create(qa_dir, recursive = TRUE)

  write_csv(robin_hours_tks_like,
            file.path(qa_dir, "robin_hours_tks_like.csv"),
            na = "")

  write_csv(robin_hours_tks_detailed,
            file.path(qa_dir, "robin_hours_tks_detailed.csv"),
            na = "")

  message(sprintf("✓ ROBIN hours exported: %d employees, %.2f total hours",
                  nrow(robin_hours_tks_like),
                  sum(robin_hours_tks_like$total_hours, na.rm = TRUE)))

  # ---- Check période -----------------------------------------------------
  robin_outside_period <- robin_alloc |>
    filter(month < as.Date("2024-03-01") | month > as.Date("2025-08-01"))

  if (nrow(robin_outside_period) > 0) {
    warning(sprintf("⚠️ %d ROBIN entries outside reporting period!", nrow(robin_outside_period)))
  } else {
    message("✓ Period check OK: all ROBIN entries within 2024-03-01 to 2025-08-31")
  }
}
