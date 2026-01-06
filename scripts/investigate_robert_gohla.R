# investigate_robert_gohla.R
# -----------------------------------------------------------------------------
# Detailed investigation of Robert Gohla's ROBIN hours discrepancy
# Expected: 155h (planning)
# Calculated: 113.4h (our system)
# Difference: -41.6h (-26.9%)
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
})

cat("\n═══════════════════════════════════════════════════════════════════════════\n")
cat("  Robert Gohla - ROBIN Project Investigation\n")
cat("  Period: 2025-01 to 2025-08\n")
cat("═══════════════════════════════════════════════════════════════════════════\n\n")

# Get Robert's du_id
robert_id <- 27

# ---- 1. Time entries breakdown ----------------------------------------------
cat("┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ 1. ROBERT'S TIME ENTRIES (All Projects, Jan-Aug 2025)                  │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

master <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/master_personnes_enriched.csv",
                   show_col_types = FALSE)

robert_months <- master %>%
  filter(du_id == robert_id,
         entity_code == "2017",
         month >= as.Date("2025-01-01"),
         month <= as.Date("2025-08-01")) %>%
  select(month, gesamtkosten, fte, hours_worked) %>%
  mutate(month = format(month, "%Y-%m"))

cat("Monthly overview:\n")
print(robert_months, n = Inf)

total_hours <- sum(robert_months$hours_worked, na.rm = TRUE)
total_cost <- sum(robert_months$gesamtkosten, na.rm = TRUE)
avg_rate <- total_cost / total_hours

cat(sprintf("\nTotal hours worked: %.2f h\n", total_hours))
cat(sprintf("Total costs (DATEV): %.2f EUR\n", total_cost))
cat(sprintf("Average hourly rate: %.2f EUR/h\n", avg_rate))

# ---- 2. ROBIN-specific time entries -----------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ 2. ROBIN PROJECT ALLOCATIONS (by month and work package)               │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

cost_by_pr <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/cost_by_pr_with_programme.csv",
                       show_col_types = FALSE)

robert_robin <- cost_by_pr %>%
  filter(du_id == robert_id,
         month >= as.Date("2025-01-01"),
         month <= as.Date("2025-08-01"),
         str_detect(str_to_upper(project), "ROBIN")) %>%
  mutate(month_str = format(month, "%Y-%m")) %>%
  select(month_str, workpackage, wp_title, hours, cost) %>%
  arrange(month_str, workpackage)

cat("ROBIN time entries:\n")
print(robert_robin, n = Inf)

robin_total_hours <- sum(robert_robin$hours, na.rm = TRUE)
robin_total_cost <- sum(robert_robin$cost, na.rm = TRUE)

cat(sprintf("\nROBIN total hours: %.2f h\n", robin_total_hours))
cat(sprintf("ROBIN total cost: %.2f EUR\n", robin_total_cost))

# ---- 3. All projects breakdown ----------------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ 3. ALL PROJECTS (where did the other hours go?)                        │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

robert_all_projects <- cost_by_pr %>%
  filter(du_id == robert_id,
         month >= as.Date("2025-01-01"),
         month <= as.Date("2025-08-01")) %>%
  group_by(project, programme, is_heu) %>%
  summarise(
    total_hours = sum(hours, na.rm = TRUE),
    total_cost = sum(cost, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(total_hours))

cat("Project distribution:\n")
print(robert_all_projects, n = Inf)

cat(sprintf("\nTotal across all projects: %.2f h (should match monthly total)\n",
            sum(robert_all_projects$total_hours)))

# ---- 4. Multi-WP analysis ---------------------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ 4. MULTI-WORK PACKAGE ANALYSIS                                         │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

# Load raw worktime to work package data
d_wt2 <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben/d_worktime.csv",
                  show_col_types = FALSE)
n_wt2wp <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben/n_worktime2workpackage.csv",
                    show_col_types = FALSE)
d_wp <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben/d_workpackage.csv",
                 show_col_types = FALSE)

# Get Robert's raw time entries
robert_time_raw <- d_wt2 %>%
  filter(du_id == robert_id,
         dwt_type == "Work",
         dwt_start >= as.Date("2025-01-01"),
         dwt_start <= as.Date("2025-08-31")) %>%
  left_join(n_wt2wp %>% select(dwt_id, dwp_id), by = "dwt_id") %>%
  left_join(d_wp %>% select(dwp_id, dpr_id, dwp_title), by = "dwp_id") %>%
  mutate(
    work_date = as.Date(dwt_start),
    month = floor_date(work_date, "month"),
    seconds = as.numeric(difftime(dwt_end, dwt_start, units = "secs")),
    hours = seconds / 3600
  )

# Count entries with multiple WPs
multi_wp_summary <- robert_time_raw %>%
  group_by(dwt_id, work_date) %>%
  summarise(
    n_workpackages = n(),
    total_seconds = first(seconds),
    total_hours = first(hours),
    .groups = "drop"
  ) %>%
  group_by(n_workpackages) %>%
  summarise(
    n_entries = n(),
    total_hours = sum(total_hours),
    .groups = "drop"
  ) %>%
  mutate(pct = 100 * n_entries / sum(n_entries))

cat("Distribution of time entries by number of work packages:\n")
print(multi_wp_summary, n = Inf)

cat("\nInterpretation:\n")
cat("- Each time entry can be allocated to 1 or more work packages\n")
cat("- Multi-WP entries are divided proportionally (prorata)\n")
cat("- This reduces hours allocated to each individual project\n")

# ---- 5. Month-by-month DATEV vs Work comparison -----------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ 5. DATEV COSTS vs WORK HOURS (month-by-month)                          │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

robert_comparison <- robert_months %>%
  left_join(
    cost_by_pr %>%
      filter(du_id == robert_id,
             month >= as.Date("2025-01-01"),
             month <= as.Date("2025-08-01")) %>%
      mutate(month_str = format(month, "%Y-%m")) %>%
      group_by(month_str) %>%
      summarise(allocated_hours = sum(hours, na.rm = TRUE),
                allocated_cost = sum(cost, na.rm = TRUE),
                .groups = "drop"),
    by = c("month" = "month_str")
  ) %>%
  mutate(
    unallocated_hours = hours_worked - coalesce(allocated_hours, 0),
    hourly_rate = gesamtkosten / hours_worked
  )

cat("Month-by-month comparison:\n")
print(robert_comparison, n = Inf)

cat("\nNotes:\n")
cat("- 'hours_worked' = total hours from time tracking\n")
cat("- 'allocated_hours' = hours assigned to projects\n")
cat("- 'unallocated_hours' = gap (should be ~0 if all time is tracked to projects)\n")

# ---- 6. Summary and recommendations -----------------------------------------
cat("\n\n┌─────────────────────────────────────────────────────────────────────────┐\n")
cat("│ 6. SUMMARY & RECOMMENDATIONS                                           │\n")
cat("└─────────────────────────────────────────────────────────────────────────┘\n\n")

cat("FINDINGS:\n")
cat(sprintf("  • Robert worked %.2f hours total in Jan-Aug 2025\n", total_hours))
cat(sprintf("  • ROBIN project received %.2f hours (%.1f%%)\n",
            robin_total_hours, 100 * robin_total_hours / total_hours))
cat(sprintf("  • Planning expected 155 hours for ROBIN\n"))
cat(sprintf("  • Difference: %.2f hours (%.1f%%)\n\n",
            robin_total_hours - 155, 100 * (robin_total_hours - 155) / 155))

cat("POSSIBLE CAUSES:\n")
cat("  1. Multi-WP prorata allocation reduces ROBIN hours\n")
cat("  2. Robert may have booked less time to ROBIN than planned\n")
cat("  3. Some ROBIN work may be booked to different work packages\n")
cat("  4. Planning vs reality mismatch (normal variation)\n\n")

cat("DATEV vs CONTRACT IMPACT:\n")
if (nrow(robert_months %>% filter(is.na(gesamtkosten) | gesamtkosten == 0)) > 0) {
  cat("  ⚠️  WARNING: Some months have missing/zero DATEV costs!\n")
  cat("  → Contract-based approach would provide stable monthly costs\n")
} else {
  cat("  ✓ All months have DATEV costs\n")
  cat("  → DATEV vs contract unlikely to cause the hour discrepancy\n")
  cat("  → The issue is TIME BOOKING, not salary calculation\n")
}

cat("\n═══════════════════════════════════════════════════════════════════════════\n\n")
