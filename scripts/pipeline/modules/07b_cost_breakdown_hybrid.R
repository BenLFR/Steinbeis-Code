# 07b_cost_breakdown_hybrid.R
# Répartition des coûts par projet avec prorata (using HYBRID payroll)
# --------------------------------------------------------------------

cat("→ Computing cost breakdown by project (HYBRID approach)...\n")

# Ensure QA directory exists
if (!dir.exists(qa_dir)) dir.create(qa_dir, recursive = TRUE)

# --- Reporting window filter ---------------------------------------
rp_start <- floor_date(period_start, "month")
rp_end   <- floor_date(period_end, "month")


# --- Cost breakdown + programme (PRORATA, using hybrid payroll) ----------

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
cost_by_pr_raw_hybrid <- d2wp_all %>%
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

robin_hours_hybrid <- cost_by_pr_raw_hybrid %>%
  semi_join(robin_ids, by = "dpr_id") %>%
  group_by(du_id, dwp_id, wp_title) %>%
  summarise(hours = sum(sec_pr, na.rm = TRUE) / 3600, .groups = "drop")

robin_totals_hybrid <- robin_hours_hybrid %>%
  group_by(du_id) %>%
  summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop")

readr::write_csv(robin_hours_hybrid, file.path(qa_dir, "qa_robin_hours_by_wp_hybrid.csv"), na = "")
readr::write_csv(robin_totals_hybrid, file.path(qa_dir, "qa_robin_hours_total_hybrid.csv"), na = "")

if (nrow(cost_by_pr_raw_hybrid %>% semi_join(robin_ids, by = "dpr_id") %>% filter(month < rp_start)) > 0) {
  warning("ROBIN reconciliation includes rows earlier than 2024-03-01 (hybrid)")
} else {
  message("ROBIN reconciliation period OK: no rows before 2024-03-01 (hybrid)")
}

# Create master table from HYBRID payroll data
# Keep entity_code to match original approach (avoids diluting hourly rates across entities)
master_hybrid <- payroll_month_hybrid %>%
  left_join(d_user %>% select(du_id, du_name, du_surname), by = "du_id") %>%
  select(du_id, entity_code, month,
         gesamtkosten = monat_kosten_hybrid,
         cost_source,
         du_name, du_surname) %>%
  # Get total hours worked from time tracking by entity (use wt_by_entity from module 04)
  # This avoids double-counting when same time is allocated to multiple work packages
  left_join(
    wt_by_entity %>%
      transmute(du_id, entity_code, month, hours_worked = sec_entity / 3600),
    by = c("du_id", "entity_code", "month")
  )

# Deduplicate to avoid many-to-many joins
master_hybrid_unique <- master_hybrid %>%
  group_by(du_id, entity_code, month) %>%
  summarise(
    gesamtkosten = sum(gesamtkosten, na.rm = TRUE),
    hours_worked = sum(hours_worked, na.rm = TRUE),
    du_name = first(du_name),
    du_surname = first(du_surname),
    cost_source = first(cost_source),
    .groups = "drop"
  )

cost_by_pr_hybrid <- cost_by_pr_raw_hybrid %>%
  mutate(hours = sec_pr / 3600) %>%
  # Join with hybrid payroll data (by du_id + entity_code + month, like original)
  left_join(
    master_hybrid_unique,
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
         programme, is_heu, hours, cost, pers_surname, pers_given, sec_pr, cost_source)

cat(sprintf("✓ Cost breakdown (HYBRID) completed: %d project allocations\n",
            nrow(cost_by_pr_hybrid)))

# Show breakdown by cost source
hybrid_cost_summary <- cost_by_pr_hybrid %>%
  group_by(cost_source) %>%
  summarise(
    allocations = n(),
    total_hours = sum(hours, na.rm = TRUE),
    total_cost = sum(cost, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(pct_cost = scales::percent(total_cost / sum(total_cost)))

cat("\nCost allocation by source:\n")
print(hybrid_cost_summary, n = Inf)
cat("\n")
