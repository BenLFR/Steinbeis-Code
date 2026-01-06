# 05_master_table.R
# Construction de la table master enrichie avec tous les calculs
# --------------------------------------------------------------------

message("Building master enriched table...")

# ==== Reporting period (dynamic) ======================================
period_months <- derive_months(period_mode, payroll_linked, fte_month, wt_full)
period_start  <- min(period_months, na.rm = TRUE)
period_end    <- max(period_months, na.rm = TRUE)
rp_month_floor   <- period_start
rp_month_ceiling <- period_end

message("✓ Reporting period: ", format(rp_month_floor, "%Y-%m"), " to ", format(rp_month_ceiling, "%Y-%m"))

# --- Master enrichi ---------------------------------------------------
all_links <- master_personnes |>
  select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
         surname_pay, given_pay, du_inactive, multi_costcenter) |>
  bind_rows(
    multi_cc_detail |>
      select(du_id, entity_code, pers_nr_short, surname_user, given_user) |>
      distinct() |>
      left_join(d_user |> select(du_id, du_login, du_name, du_surname, du_inactive), by="du_id") |>
      mutate(multi_costcenter = TRUE,
             surname_pay = surname_user, given_pay = given_user) |>
      select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
             surname_pay, given_pay, du_inactive, multi_costcenter)
  ) |>
  distinct(du_id, entity_code, pers_nr_short, .keep_all = TRUE)

base_grid <- tidyr::crossing(all_links, month = period_months)

payroll_agg <- payroll_linked |>
  group_by(du_id, entity_code, pers_nr_short, month) |>
  summarise(
    gesamtkosten = sum(gesamtkosten, na.rm=TRUE),
    pay_surname  = first(surname_pay),
    pay_given    = first(given_pay),
    .groups="drop"
  )

master_final <- base_grid |>
  left_join(payroll_agg, by = c("du_id","entity_code","pers_nr_short","month")) |>
  left_join(fte_month,    by = c("entity_code","pers_nr_short","month")) |>
  left_join(wt_by_entity, by = c("du_id","entity_code","month")) |>
  left_join(wt_full,      by = c("du_id","month")) |>
  mutate(
    surname_pay = coalesce(pay_surname, du_surname),
    given_pay   = coalesce(pay_given,   du_name),
    hours_worked = coalesce(sec_entity, sec_any) / 3600,
    stundensatz_worked_h   = if_else(hours_worked > 0, round(gesamtkosten / hours_worked, 2), NA_real_),
    stundensatz_contract_h = if_else(contract_hours_month > 0, round(gesamtkosten / contract_hours_month, 2), NA_real_)
  ) |>
  select(du_id, du_login, du_name, du_surname,
         entity_code, pers_nr_short, month, gesamtkosten,
         fte, wochenstunden, contract_hours_month, hours_worked,
         stundensatz_worked_h, stundensatz_contract_h,
         multi_costcenter, du_inactive) |>
  arrange(du_id, entity_code, month)

message("✓ Master table completed (", nrow(master_final), " rows)")
