# 04_worktime_analysis.R
# Analyse du temps de travail - TKS-based (dwt_worktime + nww_worktime_seconds)
# --------------------------------------------------------------------

message("Analyzing worktime data...")

# ---- Pré-requis ------------------------------------------------------
stopifnot(all(c("dwt_id","du_id","dwt_date","dwt_worktime") %in% names(d_wt)))
stopifnot(all(c("dwt_id","dwp_id","nww_worktime_seconds") %in% names(n_w2wp)))
stopifnot(all(c("dwp_id","dcc_id","dpr_id") %in% names(d_wp)))
stopifnot(all(c("dcc_id","dcc_number") %in% names(d_cc)))

# ---- 1) Map WP -> entity_code + project -------------------------------
wp_entity_map <- d_wp |>
  left_join(d_cc |> transmute(dcc_id, entity_code = as.character(dcc_number)), by = "dcc_id") |>
  transmute(dwp_id, entity_code, dpr_id)

# ---- 2) Worktime total (TKS booked time) ------------------------------
# dwt_worktime doit être en secondes. On valide l'unité en comparant
# avec sum(nww_worktime_seconds) sur un échantillon.

# Échantillon pour détection d'unité
sample_dwt <- d_wt |>
  filter(!is.na(dwt_worktime), dwt_worktime > 0) |>
  select(dwt_id, dwt_worktime) |>
  slice_head(n = 10000)

sample_nww <- n_w2wp |>
  semi_join(sample_dwt, by = "dwt_id") |>
  group_by(dwt_id) |>
  summarise(sum_nww = sum(as.numeric(nww_worktime_seconds), na.rm = TRUE), .groups = "drop")

unit_check <- sample_dwt |>
  inner_join(sample_nww, by = "dwt_id") |>
  filter(sum_nww > 0, dwt_worktime > 0) |>
  mutate(ratio = sum_nww / as.numeric(dwt_worktime))

median_ratio <- median(unit_check$ratio, na.rm = TRUE)

# Interpréter le ratio médian
unit_mult <- if (abs(median_ratio - 1) < 0.2) {
  1  # déjà en secondes
} else if (abs(median_ratio - 60) < 10) {
  60  # en minutes
} else if (abs(median_ratio - 3600) < 500) {
  3600  # en heures
} else {
  1  # fallback: supposer secondes
}

message(sprintf("✓ dwt_worktime unit detection: median_ratio=%.2f => multiplier=%d (=> seconds)",
                median_ratio, unit_mult))

# Construire d_wt2 avec work_secs en secondes
d_wt2 <- d_wt |>
  mutate(
    dwt_date = as_date(dwt_date),
    month = floor_date(dwt_date, "month"),
    work_secs = as.numeric(coalesce(dwt_worktime, 0)) * unit_mult
  )

# ---- 3) Allocation par WP (avec fallback equal-split) -----------------
# Règles:
# - Si nww_worktime_seconds existe et > 0 => utiliser
# - Sinon => fallback equal split: work_secs / n_wp
# - Puis rescale pour garantir sum(work_secs_alloc) == work_secs

# Nombre de WP par dwt_id
n_per_dwt <- n_w2wp |>
  count(dwt_id, name = "n_wp")

# Construire allocation avec fallback
d2wp_all <- n_w2wp |>
  left_join(n_per_dwt, by = "dwt_id") |>
  left_join(d_wt2 |> select(dwt_id, du_id, month, work_secs), by = "dwt_id") |>
  mutate(
    # Allocation raw depuis TKS
    alloc_raw = as.numeric(coalesce(nww_worktime_seconds, 0)),
    # Fallback equal split si alloc_raw manquant ou zero
    alloc_fallback = if_else(!is.na(work_secs) & work_secs > 0 & n_wp > 0,
                             work_secs / n_wp,
                             0),
    # Choisir alloc_raw si > 0, sinon fallback
    alloc_pre = if_else(alloc_raw > 0, alloc_raw, alloc_fallback)
  )

# Rescale pour que sum(alloc) == work_secs par dwt_id
d2wp_all <- d2wp_all |>
  group_by(dwt_id) |>
  mutate(
    sum_pre = sum(alloc_pre, na.rm = TRUE),
    # Rescale si total cohérent
    work_secs_alloc = case_when(
      !is.na(work_secs) & work_secs > 0 & sum_pre > 0 ~ alloc_pre * (work_secs / sum_pre),
      TRUE ~ alloc_pre
    )
  ) |>
  ungroup() |>
  select(dwt_id, dwp_id, du_id, month, work_secs, work_secs_alloc)

# ---- 4) Audit: sum(alloc) vs work_secs par dwt_id ---------------------
audit_dwt <- d2wp_all |>
  group_by(dwt_id, du_id, month, work_secs) |>
  summarise(sum_alloc = sum(work_secs_alloc, na.rm = TRUE), .groups = "drop") |>
  mutate(
    diff = work_secs - sum_alloc,
    abs_diff = abs(diff),
    ratio = if_else(work_secs > 0, sum_alloc / work_secs, NA_real_)
  )

# Outliers: |diff| > 1 seconde OU ratio hors [0.99, 1.01]
audit_outliers <- audit_dwt |>
  filter(abs_diff > 1 | (!is.na(ratio) & (ratio < 0.99 | ratio > 1.01)))

# Export audit
if (!dir.exists(qa_dir)) dir.create(qa_dir, recursive = TRUE)
write_csv(audit_outliers, file.path(qa_dir, "audit_dwt_allocation_outliers.csv"), na = "")

message(sprintf("✓ Audit dwt_id: %d outliers (|diff| > 1s or ratio out [0.99,1.01])",
                nrow(audit_outliers)))
if (nrow(audit_outliers) > 0) {
  message(sprintf("  Max abs diff: %.2f s | Max ratio deviation: %.3f",
                  max(audit_outliers$abs_diff, na.rm = TRUE),
                  max(abs(audit_outliers$ratio - 1), na.rm = TRUE)))
}

# ---- 5) Agrégation par entité (pour pipeline habituel) ---------------
wt_by_entity <- d2wp_all |>
  inner_join(wp_entity_map |> select(dwp_id, entity_code), by = "dwp_id") |>
  group_by(du_id, entity_code, month) |>
  summarise(sec_entity = sum(work_secs_alloc, na.rm = TRUE), .groups = "drop")

# NE PAS FILTRER target_entities ici pour diagnostics
# wt_by_entity <- wt_by_entity |> filter(entity_code %in% target_entities)

# ---- 6) Total toutes entités ------------------------------------------
wt_full <- d_wt2 |>
  group_by(du_id, month) |>
  summarise(sec_any = sum(work_secs, na.rm = TRUE), .groups = "drop")

# ---- 7) Diagnostics entity_code ---------------------------------------
diag_entity <- d2wp_all |>
  left_join(wp_entity_map |> select(dwp_id, entity_code), by = "dwp_id") |>
  summarise(
    rows_total = n(),
    rows_missing_entity = sum(is.na(entity_code)),
    secs_total = sum(work_secs_alloc, na.rm = TRUE),
    secs_missing_entity = sum(if_else(is.na(entity_code), work_secs_alloc, 0), na.rm = TRUE)
  )

message(sprintf("✓ Entity mapping: %d/%d rows missing entity_code (%.2f h lost)",
                diag_entity$rows_missing_entity,
                diag_entity$rows_total,
                diag_entity$secs_missing_entity / 3600))

message(sprintf("✓ Worktime analysis completed: wt_by_entity=%d rows, wt_full=%d rows",
                nrow(wt_by_entity), nrow(wt_full)))
