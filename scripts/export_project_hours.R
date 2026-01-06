# export_project_hours.R
# Generic script to export TKS hours for any project
#
# Usage:
#   Rscript scripts/export_project_hours.R SEADE 2024-01-01 2024-12-31
#   Rscript scripts/export_project_hours.R ROBIN 2024-03-01 2025-08-31
#
# Or source from RStudio after setting parameters:
#   project_name <- "SEADE"
#   start_date <- "2024-01-01"
#   end_date <- "2024-12-31"
#   source("scripts/export_project_hours.R")

suppressPackageStartupMessages({
  library(tidyverse)
  library(janitor)
  library(lubridate)
})

# Parse command line arguments or use predefined variables
args <- commandArgs(trailingOnly = TRUE)

if (length(args) >= 3) {
  project_name <- args[1]
  start_date <- as.Date(args[2])
  end_date <- as.Date(args[3])
} else if (exists("project_name") && exists("start_date") && exists("end_date")) {
  # Variables already set (sourced from RStudio)
  start_date <- as.Date(start_date)
  end_date <- as.Date(end_date)
} else {
  stop("Usage: Rscript export_project_hours.R <project_name> <start_date> <end_date>\n",
       "   Or set variables: project_name, start_date, end_date before sourcing")
}

cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  PROJECT HOURS EXPORT (TKS-based)\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")
cat("Project:", project_name, "\n")
cat("Period:", format(start_date, "%Y-%m-%d"), "to", format(end_date, "%Y-%m-%d"), "\n\n")

# Paths
db_dir <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben"
output_dir <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben/qa"

if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
}

# Load data
cat("Loading database tables...\n")
d_pr <- read_csv(file.path(db_dir, "d_project.csv"), show_col_types = FALSE) %>% clean_names()
d_wp <- read_csv(file.path(db_dir, "d_workpackage.csv"), show_col_types = FALSE) %>% clean_names()
d_wt <- read_csv(file.path(db_dir, "d_worktime.csv"), show_col_types = FALSE) %>% clean_names()
n_w2wp <- read_csv(file.path(db_dir, "n_worktime2workpackage.csv"), show_col_types = FALSE) %>% clean_names()
d_user <- read_csv(file.path(db_dir, "..", "d_user.csv"), show_col_types = FALSE) %>% clean_names()
cat("✓ Database tables loaded\n\n")

# Find project
target_projects <- d_pr %>%
  filter(str_detect(str_to_upper(dpr_title), str_to_upper(project_name))) %>%
  select(dpr_id, dpr_title)

if (nrow(target_projects) == 0) {
  stop("❌ No projects found matching: ", project_name)
}

cat(sprintf("✓ Found %d project(s) matching '%s':\n", nrow(target_projects), project_name))
for (i in 1:nrow(target_projects)) {
  cat(sprintf("  - %s (ID: %d)\n", target_projects$dpr_title[i], target_projects$dpr_id[i]))
}
cat("\n")

# Get work packages for these projects
target_wps <- d_wp %>%
  filter(dpr_id %in% target_projects$dpr_id) %>%
  select(dwp_id, wp_title = dwp_title, dpr_id)

cat(sprintf("✓ Found %d work packages\n\n", nrow(target_wps)))

# Unit detection for dwt_worktime
cat("Detecting dwt_worktime unit...\n")
sample_dwt <- d_wt %>%
  filter(!is.na(dwt_worktime), dwt_worktime > 0) %>%
  select(dwt_id, dwt_worktime) %>%
  slice_head(n = 10000)

sample_nww <- n_w2wp %>%
  semi_join(sample_dwt, by = "dwt_id") %>%
  group_by(dwt_id) %>%
  summarise(sum_nww = sum(as.numeric(nww_worktime_seconds), na.rm = TRUE), .groups = "drop")

unit_check <- sample_dwt %>%
  inner_join(sample_nww, by = "dwt_id") %>%
  filter(sum_nww > 0, dwt_worktime > 0) %>%
  mutate(ratio = sum_nww / as.numeric(dwt_worktime))

median_ratio <- median(unit_check$ratio, na.rm = TRUE)

unit_mult <- if (abs(median_ratio - 1) < 0.2) {
  1
} else if (abs(median_ratio - 60) < 10) {
  60
} else if (abs(median_ratio - 3600) < 500) {
  3600
} else {
  1
}

cat(sprintf("✓ Unit detection: median_ratio=%.2f => multiplier=%d (seconds)\n\n", median_ratio, unit_mult))

# Prepare worktime data
d_wt2 <- d_wt %>%
  mutate(
    dwt_date = as_date(dwt_date),
    month = floor_date(dwt_date, "month"),
    work_secs = as.numeric(coalesce(dwt_worktime, 0)) * unit_mult
  )

# Filter by project and period
cat("Filtering by project and period...\n")
target_alloc <- n_w2wp %>%
  filter(dwp_id %in% target_wps$dwp_id) %>%
  left_join(d_wt2 %>% select(dwt_id, du_id, dwt_date, month, work_secs), by = "dwt_id") %>%
  filter(
    !is.na(dwt_date),
    dwt_date >= start_date,
    dwt_date <= end_date
  ) %>%
  left_join(target_wps %>% select(dwp_id, wp_title), by = "dwp_id") %>%
  mutate(
    alloc_raw = as.numeric(coalesce(nww_worktime_seconds, 0))
  )

cat(sprintf("✓ Found %d time entries in period\n", nrow(target_alloc)))

# Apply rescaling logic (same as 04_worktime_analysis.R)
cat("Applying allocation rescaling...\n")

n_per_dwt <- target_alloc %>%
  count(dwt_id, name = "n_wp")

target_alloc <- target_alloc %>%
  left_join(n_per_dwt, by = "dwt_id") %>%
  mutate(
    alloc_fallback = if_else(!is.na(work_secs) & work_secs > 0 & n_wp > 0,
                             work_secs / n_wp, 0),
    alloc_pre = if_else(alloc_raw > 0, alloc_raw, alloc_fallback)
  ) %>%
  group_by(dwt_id) %>%
  mutate(
    sum_pre = sum(alloc_pre, na.rm = TRUE),
    work_secs_alloc = case_when(
      !is.na(work_secs) & work_secs > 0 & sum_pre > 0 ~ alloc_pre * (work_secs / sum_pre),
      TRUE ~ alloc_pre
    ),
    hours = work_secs_alloc / 3600
  ) %>%
  ungroup()

cat("✓ Allocation rescaling completed\n\n")

# Aggregate by person
cat("Aggregating hours by person...\n")
hours_by_person <- target_alloc %>%
  group_by(du_id) %>%
  summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop")

# Enrich with user names
hours_summary <- hours_by_person %>%
  left_join(d_user %>% select(du_id, du_surname, du_name), by = "du_id") %>%
  mutate(employee = paste(str_to_title(du_name), str_to_title(du_surname))) %>%
  select(du_id, employee, total_hours) %>%
  arrange(desc(total_hours))

cat(sprintf("✓ Aggregated: %d employees, %.2f total hours\n\n",
            nrow(hours_summary), sum(hours_summary$total_hours, na.rm = TRUE)))

# Detailed export (by person and WP)
hours_detailed <- target_alloc %>%
  group_by(du_id, dwp_id, wp_title) %>%
  summarise(hours = sum(hours, na.rm = TRUE), .groups = "drop") %>%
  left_join(d_user %>% select(du_id, du_surname, du_name), by = "du_id") %>%
  mutate(employee = paste(str_to_title(du_name), str_to_title(du_surname))) %>%
  select(du_id, employee, dwp_id, wp_title, hours) %>%
  arrange(employee, dwp_id)

# Export files
project_slug <- str_to_lower(str_replace_all(project_name, "[^a-zA-Z0-9]", "_"))
date_slug <- format(start_date, "%Y%m%d")
date_slug_end <- format(end_date, "%Y%m%d")

file_summary <- file.path(output_dir, sprintf("%s_hours_summary_%s_%s.csv",
                                               project_slug, date_slug, date_slug_end))
file_detailed <- file.path(output_dir, sprintf("%s_hours_detailed_%s_%s.csv",
                                                project_slug, date_slug, date_slug_end))

write_csv(hours_summary, file_summary, na = "")
write_csv(hours_detailed, file_detailed, na = "")

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  EXPORT COMPLETED\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")
cat("Files exported:\n")
cat("  ", file_summary, "\n")
cat("  ", file_detailed, "\n\n")

# Display summary
cat("Summary:\n")
print(hours_summary, n = Inf)

cat("\n")
