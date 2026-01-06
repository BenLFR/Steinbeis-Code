# 08_heu_gatekeeper.R
# Contrôle de cohérence RH vs HEU
# Objectif : bloquer si une personne déclare des heures HEU pendant la RP
#            sans avoir FTE>0 ou des coûts DATEV sur la RP.
# --------------------------------------------------------------------

message("Running HEU gatekeeper checks...")

rp_start <- rp_month_floor; rp_end <- rp_month_ceiling
rp_months <- seq(floor_date(rp_start, "month"), floor_date(rp_end, "month"), by = "month")

# Heures HEU par personne sur la RP
heu_hours_by_person <- cost_by_pr %>%
  filter(is_heu, month >= floor_date(rp_start, "month"), month <= floor_date(rp_end, "month")) %>%
  group_by(du_id) %>%
  summarise(heu_hours = sum(replace_na(hours, 0), na.rm = TRUE), .groups = "drop")

# Emploi côté RH (FTE>0 ou coûts>0) sur la RP
emp_by_person <- master_final %>%
  mutate(month_date = as.Date(month)) %>%
  filter(month_date %in% rp_months) %>%
  group_by(du_id) %>%
  summarise(
    months_with_fte   = sum(replace_na(fte, 0) > 0),
    months_with_cost  = sum(replace_na(gesamtkosten, 0) > 0),
    months_with_work  = sum(replace_na(hours_worked, 0) > 0),
    employed_any      = (months_with_fte > 0) | (months_with_cost > 0),
    .groups = "drop"
  )

# Cas incohérents : heures HEU > 0 mais aucun mois RH actif
incoherent <- heu_hours_by_person %>%
  left_join(emp_by_person, by = "du_id") %>%
  mutate(across(everything(), ~ replace_na(.x, 0))) %>%
  filter(heu_hours > 0 & !employed_any) %>%
  arrange(desc(heu_hours))

if (nrow(incoherent) > 0) {
  incoh_path <- file.path(dir_db, "heu_data_incoherences.csv")
  write_csv(incoherent, incoh_path, na = "")
  ids <- paste(incoherent$du_id, collapse = ", ")

  if (!allow_incoherent) {
    stop(sprintf(
      "RH incohérent pour %d personne(s) : heures HEU mais FTE/coûts nuls sur la RP. Corriger Personio/DATEV. Détails : %s",
      nrow(incoherent), incoh_path
    ))
  } else {
    warning(sprintf(
      "TEMP BYPASS: %d incoherent user(s) allowed to pass gatekeeper (du_id: %s). CSV: %s\nTODO(HR): investigate & fix, then set allow_incoherent <- FALSE.",
      nrow(incoherent), ids, incoh_path
    ))
  }
} else {
  message("✓ HEU gatekeeper: No incoherences detected")
}
