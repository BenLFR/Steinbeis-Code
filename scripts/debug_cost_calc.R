# debug_cost_calc.R
# Detailed debugging of cost calculation differences
suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(janitor)
})

modules_dir <- "scripts/pipeline/modules"

source(file.path(modules_dir, "00_config.R"), encoding = "UTF-8")
source(file.path(modules_dir, "01_utils.R"), encoding = "UTF-8")
source(file.path(modules_dir, "02_load_data.R"), encoding = "UTF-8")
source(file.path(modules_dir, "03_user_mapping.R"), encoding = "UTF-8")
source(file.path(modules_dir, "04_worktime_analysis.R"), encoding = "UTF-8")
source(file.path(modules_dir, "05_master_table.R"), encoding = "UTF-8")
source(file.path(modules_dir, "06_project_classification.R"), encoding = "UTF-8")

cat("\n=== COMPARING COST CALCULATIONS ===\n\n")

# Load original cost breakdown
source(file.path(modules_dir, "07_cost_breakdown.R"), encoding = "UTF-8")
cost_datev <- cost_by_pr

# Load hybrid cost breakdown
source(file.path(modules_dir, "06b_payroll_hybrid.R"), encoding = "UTF-8")
source(file.path(modules_dir, "07b_cost_breakdown_hybrid.R"), encoding = "UTF-8")
cost_hybrid <- cost_by_pr_hybrid

# Focus on Clementine Roth (du_id=164) in January 2025
du_focus <- 164
month_focus <- as.Date("2025-01-01")

cat(sprintf("Focusing on du_id=%d in month=%s\n\n", du_focus, month_focus))

# Get Clementine's data from both approaches
cat("=== DATEV APPROACH ===\n")
datev_detail <- cost_datev %>%
  filter(du_id == du_focus, month == month_focus, str_detect(str_to_upper(project), "ROBIN"))

cat(sprintf("Number of ROBIN allocations: %d\n", nrow(datev_detail)))
cat(sprintf("Total hours: %.2f\n", sum(datev_detail$hours)))
cat(sprintf("Total cost: %.2f EUR\n\n", sum(datev_detail$cost)))

# Show master_final for this person-month
master_datev <- master_final_unique %>%
  filter(du_id == du_focus, entity_code == "2017", month == month_focus)

cat("Master table (DATEV):\n")
print(master_datev %>% select(gesamtkosten, hours_worked))

cat("\n=== HYBRID APPROACH ===\n")
hybrid_detail <- cost_hybrid %>%
  filter(du_id == du_focus, month == month_focus, str_detect(str_to_upper(project), "ROBIN"))

cat(sprintf("Number of ROBIN allocations: %d\n", nrow(hybrid_detail)))
cat(sprintf("Total hours: %.2f\n", sum(hybrid_detail$hours)))
cat(sprintf("Total cost: %.2f EUR\n\n", sum(hybrid_detail$cost)))

# Show master_hybrid for this person-month
master_hyb <- master_hybrid_unique %>%
  filter(du_id == du_focus, entity_code == "2017", month == month_focus)

cat("Master table (HYBRID):\n")
print(master_hyb %>% select(gesamtkosten, hours_worked, cost_source))

cat("\n=== DETAILED COMPARISON ===\n")
cat(sprintf("DATEV gesamtkosten: %.2f EUR\n", master_datev$gesamtkosten))
cat(sprintf("HYBRID gesamtkosten: %.2f EUR\n", master_hyb$gesamtkosten))
cat(sprintf("Difference: %.2f EUR (%.1f%%)\n\n",
            master_hyb$gesamtkosten - master_datev$gesamtkosten,
            100 * (master_hyb$gesamtkosten - master_datev$gesamtkosten) / master_datev$gesamtkosten))

cat(sprintf("DATEV hours_worked: %.2f h\n", master_datev$hours_worked))
cat(sprintf("HYBRID hours_worked: %.2f h\n", master_hyb$hours_worked))
cat(sprintf("Difference: %.2f h\n\n",
            master_hyb$hours_worked - master_datev$hours_worked))

cat(sprintf("DATEV hourly rate: %.2f EUR/h\n", master_datev$gesamtkosten / master_datev$hours_worked))
cat(sprintf("HYBRID hourly rate: %.2f EUR/h\n", master_hyb$gesamtkosten / master_hyb$hours_worked))

cat("\n=== END ===\n")
