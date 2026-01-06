# export_robin_2024_by_month.R
# Export ROBIN 2024 with monthly breakdown

project_name <- "ROBIN"
start_date <- "2024-01-01"
end_date <- "2024-12-31"
period_split <- "month"

source("scripts/export_project_hours_with_periods.R")
