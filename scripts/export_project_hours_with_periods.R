# export_project_hours_with_periods.R
# Export project hours with period breakdown (like Stella's Excel)
#
# Usage:
   project_name <- "ROBIN"
   start_date <- "2024-01-01"
   end_date <- "2024-12-31"
   period_split <- "semester"  # Options: "semester", "quarter", "month", or custom dates
   source("scripts/export_project_hours_with_periods.R")

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
  period_split <- if (length(args) >= 4) args[4] else "semester"
} else if (exists("project_name") && exists("start_date") && exists("end_date")) {
  start_date <- as.Date(start_date)
  end_date <- as.Date(end_date)
  if (!exists("period_split")) period_split <- "semester"
} else {
  stop("Usage: Set variables project_name, start_date, end_date, period_split before sourcing")
}

cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  PROJECT HOURS EXPORT WITH PERIODS (TKS-based)\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")
cat("Project:", project_name, "\n")
cat("Period:", format(start_date, "%Y-%m-%d"), "to", format(end_date, "%Y-%m-%d"), "\n")
cat("Split by:", period_split, "\n\n")

# Paths
db_dir <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database/ben"
output_dir <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database/ben/qa"

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

cat(sprintf("✓ Found %d project(s)\n", nrow(target_projects)))

# Get work packages
target_wps <- d_wp %>%
  filter(dpr_id %in% target_projects$dpr_id) %>%
  select(dwp_id, wp_title = dwp_title, dpr_id)

cat(sprintf("✓ Found %d work packages\n\n", nrow(target_wps)))

# Unit detection
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
unit_mult <- if (abs(median_ratio - 1) < 0.2) 1 else if (abs(median_ratio - 60) < 10) 60 else if (abs(median_ratio - 3600) < 500) 3600 else 1

cat(sprintf("✓ Unit multiplier: %d\n\n", unit_mult))

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
  filter(!is.na(dwt_date), dwt_date >= start_date, dwt_date <= end_date) %>%
  left_join(target_wps %>% select(dwp_id, wp_title), by = "dwp_id") %>%
  mutate(alloc_raw = as.numeric(coalesce(nww_worktime_seconds, 0)))

cat(sprintf("✓ Found %d time entries\n", nrow(target_alloc)))

# Apply rescaling
cat("Applying allocation rescaling...\n")
n_per_dwt <- target_alloc %>% count(dwt_id, name = "n_wp")

target_alloc <- target_alloc %>%
  left_join(n_per_dwt, by = "dwt_id") %>%
  mutate(
    alloc_fallback = if_else(!is.na(work_secs) & work_secs > 0 & n_wp > 0, work_secs / n_wp, 0),
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

cat("✓ Allocation completed\n\n")

# Define period breaks based on period_split parameter
cat("Defining periods...\n")

get_period_label <- function(date, breaks, labels) {
  for (i in 1:(length(breaks)-1)) {
    if (date >= breaks[i] & date < breaks[i+1]) {
      return(labels[i])
    }
  }
  return(labels[length(labels)])
}

# Create period breaks based on split type
year_start <- year(start_date)
year_end <- year(end_date)

if (period_split == "semester") {
  # Split by semester (Jan-Jun, Jul-Dec)
  period_breaks <- c()
  period_labels <- c()

  for (yr in year_start:year_end) {
    period_breaks <- c(period_breaks,
                       as.Date(paste0(yr, "-01-01")),
                       as.Date(paste0(yr, "-07-01")))
    period_labels <- c(period_labels,
                       sprintf("%d-S1 (Jan-Jun)", yr),
                       sprintf("%d-S2 (Jul-Dec)", yr))
  }
  period_breaks <- c(period_breaks, as.Date(paste0(year_end+1, "-01-01")))

} else if (period_split == "quarter") {
  # Split by quarter
  period_breaks <- c()
  period_labels <- c()

  for (yr in year_start:year_end) {
    period_breaks <- c(period_breaks,
                       as.Date(paste0(yr, "-01-01")),
                       as.Date(paste0(yr, "-04-01")),
                       as.Date(paste0(yr, "-07-01")),
                       as.Date(paste0(yr, "-10-01")))
    period_labels <- c(period_labels,
                       sprintf("%d-Q1", yr), sprintf("%d-Q2", yr),
                       sprintf("%d-Q3", yr), sprintf("%d-Q4", yr))
  }
  period_breaks <- c(period_breaks, as.Date(paste0(year_end+1, "-01-01")))

} else if (period_split == "month") {
  # Split by month
  period_breaks <- seq(floor_date(start_date, "month"),
                       ceiling_date(end_date, "month"),
                       by = "month")
  period_labels <- format(period_breaks[-length(period_breaks)], "%Y-%m")

} else {
  # Default: treat as whole period
  period_breaks <- c(start_date, end_date + days(1))
  period_labels <- sprintf("%s to %s", format(start_date, "%Y-%m-%d"), format(end_date, "%Y-%m-%d"))
}

cat(sprintf("✓ Created %d period(s)\n\n", length(period_labels)))

# Assign periods to each entry
target_alloc <- target_alloc %>%
  mutate(
    period = map_chr(dwt_date, ~{
      for (i in 1:(length(period_breaks)-1)) {
        if (.x >= period_breaks[i] & .x < period_breaks[i+1]) {
          return(period_labels[i])
        }
      }
      return(period_labels[length(period_labels)])
    })
  )

# Aggregate by person, WP, and period
cat("Aggregating by person, WP, and period...\n")
hours_by_period <- target_alloc %>%
  group_by(du_id, dwp_id, wp_title, period) %>%
  summarise(
    n_entries = n(),
    total_hours = sum(hours, na.rm = TRUE),
    min_date = min(dwt_date, na.rm = TRUE),
    max_date = max(dwt_date, na.rm = TRUE),
    .groups = "drop"
  )

# Enrich with user names
hours_detailed_periods <- hours_by_period %>%
  left_join(d_user %>% select(du_id, du_surname, du_name), by = "du_id") %>%
  mutate(employee = paste(str_to_title(du_name), str_to_title(du_surname))) %>%
  select(du_id, employee, dwp_id, wp_title, period, min_date, max_date, n_entries, hours = total_hours) %>%
  arrange(employee, dwp_id, period)

cat(sprintf("✓ Aggregated: %d rows (person x WP x period)\n", nrow(hours_detailed_periods)))

# Summary by person
hours_summary <- hours_detailed_periods %>%
  group_by(du_id, employee) %>%
  summarise(total_hours = sum(hours, na.rm = TRUE), .groups = "drop") %>%
  arrange(desc(total_hours))

cat(sprintf("✓ Summary: %d employees, %.2f total hours\n\n",
            nrow(hours_summary), sum(hours_summary$total_hours, na.rm = TRUE)))

# Export files
project_slug <- str_to_lower(str_replace_all(project_name, "[^a-zA-Z0-9]", "_"))
date_slug <- format(start_date, "%Y%m%d")
date_slug_end <- format(end_date, "%Y%m%d")

file_summary <- file.path(output_dir, sprintf("%s_hours_summary_%s_%s.csv",
                                               project_slug, date_slug, date_slug_end))
file_detailed_periods <- file.path(output_dir, sprintf("%s_hours_by_period_%s_%s.csv",
                                                        project_slug, date_slug, date_slug_end))

write_csv(hours_summary, file_summary, na = "")
write_csv(hours_detailed_periods, file_detailed_periods, na = "")

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  EXPORT COMPLETED\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")
cat("Files exported:\n")
cat("  ", file_summary, "\n")
cat("  ", file_detailed_periods, "\n\n")

# Display summary
cat("Summary by employee:\n")
print(hours_summary, n = 20)

cat("\n")
