# 10_exports.R
# Exports des résultats finaux
# --------------------------------------------------------------------

message("Exporting results...")

# --- Exports principaux ---------------------------------------------------
write_csv(master_final, file.path(dir_db, "master_personnes_enriched.csv"), na = "")
write_csv(cost_by_pr,   file.path(dir_db, "cost_by_pr_with_programme.csv"), na = "")
write_csv(heu_base,     file.path(dir_db, "heu_daily_rate_by_person.csv"),   na = "")
write_csv(heu_control,  file.path(dir_db, "heu_daily_rate_control.csv"),     na = "")

message("✓ Master tables exported")

# --- Exports HEU vs Non-HEU -----------------------------------------------
write_csv(heu_final_by_project, file.path(dir_db, "heu_final_by_project.csv"), na = "")
write_csv(non_heu_by_project,  file.path(dir_db, "non_heu_by_project.csv"),  na = "")

# Export reporting unifié
write_csv(reporting_costs, file.path(dir_db, "reporting_costs_HEU_daily_vs_nonHEU_prorata.csv"), na = "")

message("✓ HEU/non-HEU reports exported")

# --- Export résumé heures par projet × personne (facile à consulter) ---------
hours_by_project_person <- cost_by_pr %>%
  filter(month >= rp_month_floor, month <= rp_month_ceiling) %>%
  group_by(project_id, project, programme, is_heu, du_id, pers_surname, pers_given) %>%
  summarise(
    total_hours = sum(hours, na.rm = TRUE),
    total_cost = sum(cost, na.rm = TRUE),
    n_months = n_distinct(month),
    .groups = "drop"
  ) %>%
  mutate(employee = paste(pers_given, pers_surname)) %>%
  select(project, programme, is_heu, employee, pers_surname, pers_given, du_id,
         total_hours, total_cost, n_months) %>%
  arrange(project, desc(total_hours))

write_csv(hours_by_project_person, file.path(dir_db, "hours_by_project_person.csv"), na = "")
message("✓ Hours by project/person summary exported: hours_by_project_person.csv")

# --- Export résumé heures par projet (totaux uniquement) ---------------------
hours_by_project <- hours_by_project_person %>%
  group_by(project_id = NA, project, programme, is_heu) %>%
  summarise(
    n_employees = n_distinct(du_id),
    total_hours = sum(total_hours, na.rm = TRUE),
    total_cost = sum(total_cost, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(total_hours))

write_csv(hours_by_project, file.path(dir_db, "hours_by_project.csv"), na = "")
message("✓ Hours by project summary exported: hours_by_project.csv")

# --- Export parental leave tracking (if data was loaded) ------------------
if (exists("parental_leave_days") && nrow(parental_leave_days) > 0) {
  parental_leave_export <- parental_leave_days %>%
    left_join(d_user %>% select(du_id, du_login, du_name, du_surname), by = "du_id") %>%
    arrange(desc(parental_leave_days))
  write_csv(parental_leave_export, file.path(dir_db, "parental_leave_deductions.csv"), na = "")
  message("✓ Parental leave export: ", file.path(dir_db, "parental_leave_deductions.csv"))
}

# --- Exemple export « photo + totaux » (WP 4034, projet 645) -------------
# Note: This is a specific example export. You can customize it as needed.
mensuel_seuls <- cost_by_pr |>
  filter(project_id == 645, workpackage == 4034,
         du_id %in% c(278, 314), month >= rp_month_floor, month <= rp_month_ceiling) |>
  arrange(du_id, month)

if (nrow(mensuel_seuls) > 0) {
  totaux_allcol <- mensuel_seuls |>
    group_by(du_id, entity_code, pers_surname, pers_given, project_id, project, workpackage, wp_title) |>
    summarise(month = "TOTAL",
              hours = sum(hours, na.rm = TRUE),
              cost  = sum(cost,  na.rm = TRUE),
              pct_time = NA_real_, .groups = "drop")

  export <- bind_rows(
    mensuel_seuls |> mutate(month = as.character(month)),
    totaux_allcol
  ) |>
    arrange(du_id, match(month, c(format(unique(mensuel_seuls$month), "%Y-%m-%d"), "TOTAL")))

  outfile <- sprintf("wp4034_stela_alena_%s_to_%s_mensuel_et_totaux_allcol.csv",
                     format(rp_month_floor, "%Y-%m"), format(rp_month_ceiling, "%Y-%m"))
  write_csv(export, file.path(dirname(dir_db), outfile), na = "")
  message("✓ Example export: ", outfile)
}

message("✓ All exports completed successfully")
