# export_project_hours_stella_format_v2.R
# Export project hours in Stella's exact format with periods
# Fixed version that correctly calculates hours from TKS data

suppressPackageStartupMessages({
  library(tidyverse)
  library(janitor)
  library(lubridate)
  library(writexl)
})

# Parse arguments
args <- commandArgs(trailingOnly = TRUE)

if (length(args) >= 3) {
  project_name <- args[1]
  start_date <- as.Date(args[2])
  end_date <- as.Date(args[3])
} else if (exists("project_name") && exists("start_date") && exists("end_date")) {
  start_date <- as.Date(start_date)
  end_date <- as.Date(end_date)
} else {
  stop("Usage: Set variables project_name, start_date, end_date before sourcing")
}

cat("\n═══════════════════════════════════════════════════════════════════\n")
cat("  PROJECT HOURS EXPORT (Stella Format)\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")
cat("Project:", project_name, "\n")
cat("Period:", format(start_date, "%d.%m.%Y"), "to", format(end_date, "%d.%m.%Y"), "\n\n")

# Paths
db_dir <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben"
output_dir <- file.path(db_dir, "qa")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# Load database tables
cat("Loading database tables...\n")
d_pr <- read_csv(file.path(db_dir, "d_project.csv"), show_col_types = FALSE) %>% clean_names()
d_wp <- read_csv(file.path(db_dir, "d_workpackage.csv"), show_col_types = FALSE) %>% clean_names()
d_wt <- read_csv(file.path(db_dir, "d_worktime.csv"), show_col_types = FALSE) %>% clean_names()
n_w2wp <- read_csv(file.path(db_dir, "n_worktime2workpackage.csv"), show_col_types = FALSE) %>% clean_names()
d_user <- read_csv(file.path(dirname(db_dir), "d_user.csv"), show_col_types = FALSE) %>% clean_names()

# Find project
target_projects <- d_pr %>%
  filter(str_detect(str_to_upper(dpr_title), str_to_upper(project_name)))

if (nrow(target_projects) == 0) stop("Project not found: ", project_name)

cat(sprintf("✓ Found project: %s\n", target_projects$dpr_title[1]))

# Get work packages
target_wps <- d_wp %>%
  filter(dpr_id %in% target_projects$dpr_id) %>%
  select(dwp_id, wp_title = dwp_title)

cat(sprintf("✓ Found %d work packages\n\n", nrow(target_wps)))

# Prepare worktime data
d_wt2 <- d_wt %>%
  mutate(
    dwt_date = as_date(dwt_date),
    dwt_worktime_secs = as.numeric(coalesce(dwt_worktime, 0))
  ) %>%
  filter(dwt_date >= start_date, dwt_date <= end_date)

# Get allocations with TKS data
cat("Loading time allocations (TKS methodology)...\n")
target_alloc <- n_w2wp %>%
  filter(dwp_id %in% target_wps$dwp_id) %>%
  inner_join(d_wt2, by = "dwt_id") %>%
  left_join(target_wps, by = "dwp_id") %>%
  mutate(
    # TKS: use nww_worktime_seconds directly (already in seconds)
    alloc_secs = as.numeric(coalesce(nww_worktime_seconds, 0))
  )

cat(sprintf("✓ Found %d time entries\n", nrow(target_alloc)))

if (nrow(target_alloc) == 0) {
  stop("No data found for project ", project_name, " in period")
}

# Apply rescaling to ensure consistency
cat("Applying TKS rescaling...\n")

# For each dwt_id, ensure sum of allocations equals total work time
rescaled <- target_alloc %>%
  group_by(dwt_id) %>%
  mutate(
    total_alloc = sum(alloc_secs, na.rm = TRUE),
    # Use dwt_worktime if available, otherwise use sum of allocations
    work_secs_actual = if_else(dwt_worktime_secs > 0, dwt_worktime_secs, total_alloc),
    # Scale factor to match actual work time
    scale_factor = if_else(total_alloc > 0, work_secs_actual / total_alloc, 1),
    # Final allocated seconds (rescaled)
    work_secs_final = alloc_secs * scale_factor,
    # Convert to hours
    hours = work_secs_final / 3600
  ) %>%
  ungroup()

cat(sprintf("✓ Total hours calculated: %.2f\n\n", sum(rescaled$hours, na.rm = TRUE)))

# Join with employee names
rescaled <- rescaled %>%
  left_join(d_user %>% select(du_id, du_name, du_surname), by = "du_id") %>%
  mutate(employee = paste(du_name, du_surname))

# Aggregate by employee + WP
cat("Aggregating by employee and work package...\n")

report_data <- rescaled %>%
  group_by(du_id, employee, dwp_id, wp_title) %>%
  summarise(
    start_period = min(dwt_date),
    end_period = max(dwt_date),
    hours = sum(hours, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(year = year(start_period))

cat(sprintf("✓ Generated %d rows with %.2f total hours\n\n",
            nrow(report_data), sum(report_data$hours, na.rm = TRUE)))

# Load cost data if available
cat("Loading cost data...\n")
cost_file <- file.path(dirname(db_dir), "cost_by_pr_with_programme.csv")

if (file.exists(cost_file)) {
  cost_data <- read_csv(cost_file, show_col_types = FALSE) %>%
    clean_names() %>%
    filter(str_detect(coalesce(project, ""), regex(paste0("\\b", project_name, "\\b"), ignore_case = TRUE))) %>%
    group_by(du_id, workpackage) %>%
    summarise(total_cost = sum(cost, na.rm = TRUE), .groups = "drop")

  report_data <- report_data %>%
    left_join(cost_data, by = c("du_id", "dwp_id" = "workpackage")) %>%
    mutate(cost_eur = coalesce(total_cost, 0))

  cat("✓ Cost data loaded\n\n")
} else {
  report_data <- report_data %>% mutate(cost_eur = 0)
  cat("⚠ Cost data not available\n\n")
}

# Create Stella format output
stella_report <- report_data %>%
  select(
    Employee = employee,
    Year = year,
    `Work Package I` = dwp_id,
    `Work Package` = wp_title,
    `Start Period` = start_period,
    `End Period` = end_period,
    Hours = hours,
    `Cost (EUR)` = cost_eur
  ) %>%
  mutate(
    `Start Period` = format(`Start Period`, "%d.%m.%Y"),
    `End Period` = format(`End Period`, "%d.%m.%Y")
  ) %>%
  arrange(Employee, Year, `Work Package I`)

# Export
csv_filename <- sprintf("%s_hours_stella_format_%s_to_%s.csv",
                        tolower(project_name),
                        format(start_date, "%Y%m%d"),
                        format(end_date, "%Y%m%d"))

xlsx_filename <- sprintf("%s_hours_stella_format_%s_to_%s.xlsx",
                         tolower(project_name),
                         format(start_date, "%Y%m%d"),
                         format(end_date, "%Y%m%d"))

write_csv(stella_report, file.path(output_dir, csv_filename))
write_xlsx(list(Project = stella_report), file.path(output_dir, xlsx_filename))

# Summary
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  SUMMARY\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")
cat(sprintf("Employees: %d\n", n_distinct(stella_report$Employee)))
cat(sprintf("Work packages: %d\n", n_distinct(stella_report$`Work Package I`)))
cat(sprintf("Total hours: %.2f\n", sum(report_data$hours, na.rm = TRUE)))
cat(sprintf("Total cost: %.2f EUR\n\n", sum(report_data$cost_eur, na.rm = TRUE)))

cat("✓ Files exported:\n")
cat("  ", file.path(output_dir, csv_filename), "\n")
cat("  ", file.path(output_dir, xlsx_filename), "\n\n")

cat("Preview:\n")
print(head(stella_report, 10), n = 10)

cat("\n═══════════════════════════════════════════════════════════════════\n\n")
