# debug_hybrid.R
# Quick script to debug the hybrid payroll mismatch
suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(janitor)
})

modules_dir <- "scripts/pipeline/modules"

cat("Loading modules...\n")
source(file.path(modules_dir, "00_config.R"), encoding = "UTF-8")
source(file.path(modules_dir, "01_utils.R"), encoding = "UTF-8")
source(file.path(modules_dir, "02_load_data.R"), encoding = "UTF-8")
source(file.path(modules_dir, "03_user_mapping.R"), encoding = "UTF-8")
source(file.path(modules_dir, "04_worktime_analysis.R"), encoding = "UTF-8")
source(file.path(modules_dir, "05_master_table.R"), encoding = "UTF-8")
source(file.path(modules_dir, "06_project_classification.R"), encoding = "UTF-8")

cat("\nLoading hybrid payroll...\n")
source(file.path(modules_dir, "06b_payroll_hybrid.R"), encoding = "UTF-8")

cat("\n=== DEBUGGING INFO ===\n\n")

# Check date ranges
cat("1. Date ranges:\n")
cat(sprintf("   payroll_linked months: %s to %s\n",
            min(payroll_linked$month), max(payroll_linked$month)))
cat(sprintf("   payroll_month_hybrid months: %s to %s\n",
            min(payroll_month_hybrid$month), max(payroll_month_hybrid$month)))
cat(sprintf("   d2wp_all months: %s to %s\n",
            min(d2wp_all$month), max(d2wp_all$month)))

# Check unique du_id coverage
cat("\n2. du_id coverage:\n")
cat(sprintf("   payroll_month_hybrid: %d unique du_id\n",
            n_distinct(payroll_month_hybrid$du_id)))
cat(sprintf("   d2wp_all: %d unique du_id\n",
            n_distinct(d2wp_all$du_id)))

# Check for ROBIN project specifically
cat("\n3. ROBIN project time tracking (2025-01 to 2025-08):\n")
robin_time <- d2wp_all %>%
  inner_join(wp_entity_map %>% select(dwp_id, entity_code), by = "dwp_id") %>%
  filter(entity_code %in% target_entities) %>%
  inner_join(d_wp %>% select(dwp_id, dpr_id), by = "dwp_id") %>%
  inner_join(d_pr %>% select(dpr_id, dpr_title), by = "dpr_id") %>%
  filter(str_detect(str_to_upper(dpr_title), "ROBIN")) %>%
  filter(month >= as.Date("2025-01-01"), month <= as.Date("2025-08-31"))

cat(sprintf("   ROBIN time entries: %d rows\n", nrow(robin_time)))
cat(sprintf("   Unique du_id in ROBIN: %d\n", n_distinct(robin_time$du_id)))
cat(sprintf("   Unique months in ROBIN: %d\n", n_distinct(robin_time$month)))

# Check how many ROBIN time entries have matching payroll
robin_with_payroll <- robin_time %>%
  distinct(du_id, month) %>%
  left_join(
    payroll_month_hybrid %>% select(du_id, month, monat_kosten_hybrid, cost_source),
    by = c("du_id", "month")
  )

cat("\n4. ROBIN time tracking vs payroll matching:\n")
cat(sprintf("   Total ROBIN du_id-month combinations: %d\n", nrow(robin_with_payroll)))
cat(sprintf("   With DATEV_actual: %d\n",
            sum(!is.na(robin_with_payroll$cost_source) & robin_with_payroll$cost_source == "DATEV_actual")))
cat(sprintf("   With FTE_estimated: %d\n",
            sum(!is.na(robin_with_payroll$cost_source) & robin_with_payroll$cost_source == "FTE_estimated")))
cat(sprintf("   With NO payroll match: %d\n",
            sum(is.na(robin_with_payroll$monat_kosten_hybrid))))

# Show details of mismatches
cat("\n5. Sample of ROBIN entries with NO payroll match:\n")
robin_no_match <- robin_with_payroll %>%
  filter(is.na(monat_kosten_hybrid)) %>%
  left_join(d_user %>% select(du_id, du_name, du_surname), by = "du_id") %>%
  mutate(name = paste(du_name, du_surname)) %>%
  group_by(du_id, name) %>%
  summarise(months_no_match = paste(format(month, "%Y-%m"), collapse = ", "),
            n_months = n(),
            .groups = "drop") %>%
  arrange(desc(n_months))

print(robin_no_match, n = 20)

cat("\n=== END DEBUG ===\n")
