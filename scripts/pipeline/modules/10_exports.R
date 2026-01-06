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
