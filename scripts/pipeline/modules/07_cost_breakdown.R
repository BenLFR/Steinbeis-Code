# 07_cost_breakdown.R
# Répartition des coûts par projet avec prorata
# --------------------------------------------------------------------

message("Computing cost breakdown by project...")

# Ensure QA directory exists
if (!dir.exists(qa_dir)) dir.create(qa_dir, recursive = TRUE)

# --- Reporting window filter ---------------------------------------
rp_start <- floor_date(period_start, "month")
rp_end   <- floor_date(period_end, "month")

# --- Cost breakdown + programme (PRORATA, robust) -------------------------

# détecter la colonne "projet" dans d_wp
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
  filter(month >= rp_start, month <= rp_end) %>%
  group_by(du_id, dpr_id, project, programme, is_heu, dwp_id, wp_title, month, entity_code) %>%
  summarise(sec_pr = sum(work_secs_alloc, na.rm = TRUE), .groups = "drop")

# --- QA: ROBIN hours reconciliation -----------------------------------
robin_ids <- d_pr %>%
  filter(str_detect(str_to_lower(dpr_title), "\\brobin\\b")) %>%
  select(dpr_id)

robin_hours <- cost_by_pr_raw %>%
  semi_join(robin_ids, by = "dpr_id") %>%
  group_by(du_id, dwp_id, wp_title) %>%
  summarise(hours = sum(sec_pr, na.rm = TRUE) / 3600, .groups = "drop")

robin_totals <- robin_hours %>%
  group_by(du_id) %>%
  summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop")

readr::write_csv(robin_hours, file.path(qa_dir, "qa_robin_hours_by_wp.csv"), na = "")
readr::write_csv(robin_totals, file.path(qa_dir, "qa_robin_hours_total.csv"), na = "")

if (nrow(cost_by_pr_raw %>% semi_join(robin_ids, by = "dpr_id") %>% filter(month < rp_start)) > 0) {
  warning("ROBIN reconciliation includes rows earlier than 2024-03-01")
} else {
  message("ROBIN reconciliation period OK: no rows before 2024-03-01")
}

# Transform cost_by_pr_raw into cost_by_pr with required columns
# First deduplicate master_final to avoid many-to-many joins
master_final_unique <- master_final %>%
  group_by(du_id, entity_code, month) %>%
  summarise(
    gesamtkosten = sum(gesamtkosten, na.rm = TRUE),
    hours_worked = sum(hours_worked, na.rm = TRUE),
    du_name = first(du_name),
    du_surname = first(du_surname),
    .groups = "drop"
  )

cost_by_pr <- cost_by_pr_raw %>%
  mutate(hours = sec_pr / 3600) %>%
  # Join with deduplicated master_final to get costs
  left_join(
    master_final_unique,
    by = c("du_id", "entity_code", "month")
  ) %>%
  # Calculate allocated cost proportionally to hours worked
  mutate(
    total_hours_month = coalesce(hours_worked, hours),
    cost = if_else(
      total_hours_month > 0,
      (gesamtkosten / total_hours_month) * hours,
      0
    ),
    # Rename columns to match expected names
    project_id = dpr_id,
    workpackage = dwp_id,
    pers_surname = du_surname,
    pers_given = du_name
  ) %>%
  select(du_id, entity_code, month, project_id, project, workpackage, wp_title,
         programme, is_heu, hours, cost, pers_surname, pers_given, sec_pr)

message("✓ Cost breakdown completed (", nrow(cost_by_pr), " project allocations)")
