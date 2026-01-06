# 03_user_mapping.R
# Mapping entre utilisateurs d_user et numéros HR (DATEV/Personio)
# --------------------------------------------------------------------

message("Building user mapping...")

# --- Clés d_user ↔ HR -------------------------------------------------
users_key <- d_user |>
  mutate(hr_list = str_split(du_hr_numbers, ",")) |>
  unnest(hr_list) |>
  mutate(
    hr_list       = str_trim(hr_list),
    entity_code   = str_sub(hr_list, 1, 4),
    pers_nr_full  = str_sub(hr_list, 5),
    pers_nr_short = as.integer(pers_nr_full)
  ) |>
  transmute(du_id, entity_code, pers_nr_short,
            surname_user = str_to_lower(du_surname),
            given_user   = str_to_lower(du_name)) |>
  distinct()

# --- Auto-fix users_key using DATEV (fill missing HR numbers) --------
# Build current unmatched (in DATEV but not in users_key)
payroll_unmatched <- payroll %>%
  anti_join(users_key %>% select(entity_code, pers_nr_short),
            by = c("entity_code","pers_nr_short"))

# Unique mapping: name -> du_id (avoid ambiguous duplicates)
duser_names <- d_user %>%
  transmute(du_id,
            name_key = paste(normalize_name(coalesce(du_surname,"")),
                             normalize_name(coalesce(du_name,""))))

unique_name_to_du <- duser_names %>%
  filter(name_key != " ") %>%
  count(name_key, name = "n") %>%
  filter(n == 1) %>%
  select(name_key) %>%
  inner_join(duser_names, by = "name_key") %>%
  select(name_key, du_id)

# Name keys for unmatched DATEV rows
datev_names_unmatched <- payroll_unmatched %>%
  transmute(entity_code,
            pers_nr_short,
            name_key = paste(normalize_name(coalesce(surname,"")),
                             normalize_name(coalesce(givenname,"")))) %>%
  distinct()

# Infer du_id by unique name match; drop links already present
inferred_links <- datev_names_unmatched %>%
  inner_join(unique_name_to_du, by = "name_key") %>%
  anti_join(users_key %>% select(du_id, entity_code, pers_nr_short),
            by = c("du_id","entity_code","pers_nr_short")) %>%
  select(du_id, entity_code, pers_nr_short) %>%
  distinct() %>%
  mutate(source_fix = "from_DATEV_unique_name")

# Extend users_key in-place
if (nrow(inferred_links) > 0) {
  users_key <- users_key %>%
    bind_rows(
      inferred_links %>%
        left_join(d_user %>%
                    transmute(du_id,
                              surname_user = str_to_lower(du_surname),
                              given_user   = str_to_lower(du_name)),
                  by = "du_id")
    ) %>%
    distinct(du_id, entity_code, pers_nr_short, .keep_all = TRUE)

  # optional audit file
  readr::write_csv(
    inferred_links %>%
      left_join(d_user %>% select(du_id, du_login, du_name, du_surname), by = "du_id") %>%
      arrange(du_id, entity_code, pers_nr_short),
    file.path(dir_db, "inferred_hr_numbers_from_DATEV.csv"), na = ""
  )
  message("✓ users_key enriched with ", nrow(inferred_links), " HR number(s) inferred from DATEV by unique name.")
} else {
  message("✓ users_key: no missing HR numbers inferable from DATEV by unique name.")
}

# --- Mapping payroll → du_id ------------------------------------------
payroll_linked <- payroll |>
  left_join(users_key |> select(du_id, entity_code, pers_nr_short),
            by = c("entity_code","pers_nr_short")) |>
  filter(!is.na(du_id))

# Filter to target entities
payroll_linked <- payroll_linked |> filter(entity_code %in% target_entities)

# multi-CC
multi_cc_full <- users_key |> count(du_id, name="n_cc") |> filter(n_cc > 1)
multi_cc_detail <- users_key |>
  semi_join(multi_cc_full, by="du_id") |>
  left_join(d_user |> select(du_id, du_login, du_name, du_surname, du_inactive), by="du_id") |>
  select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
         surname_user, given_user, du_inactive) |>
  arrange(du_id, entity_code)

# master personnes (référentiel)
master_personnes <- d_user |>
  left_join(users_key |> select(du_id, entity_code, pers_nr_short), by="du_id") |>
  left_join(payroll_linked |> select(entity_code, pers_nr_short, du_id, surname_pay, given_pay) |> distinct(),
            by = c("du_id","entity_code","pers_nr_short")) |>
  mutate(multi_costcenter = du_id %in% multi_cc_full$du_id) |>
  select(du_id, du_login, du_name, du_surname, entity_code, pers_nr_short,
         surname_pay, given_pay, du_inactive, multi_costcenter) |>
  arrange(du_id, entity_code)

message("✓ User mapping completed (", nrow(payroll_linked), " payroll rows linked)")
