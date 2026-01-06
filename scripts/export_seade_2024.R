# export_seade_2024.R
# Export SEADE project hours for year 2024
#
# Usage from RStudio:
#   source("scripts/export_seade_2024.R")

# Set parameters
project_name <- "SEADE"
start_date <- "2024-01-01"
end_date <- "2024-12-31"

# Run export
source("scripts/export_project_hours.R")
