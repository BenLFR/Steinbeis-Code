# create_robin_excel.R
# Create Excel file with ROBIN results for Stella
suppressPackageStartupMessages({
  library(tidyverse)
  library(writexl)
})

cat("Creating Excel file for Stella...\n")

# Load data (CORRECTED period: March 2024 - August 2025)
robin_costs <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/robin_project_costs_2024-03_to_2025-08.csv",
                        show_col_types = FALSE)

comparison <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/robin_comparison_vs_plan.csv",
                      show_col_types = FALSE)

# Load detailed cost breakdown for work package details
cost_by_pr <- read_csv("C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/cost_by_pr_with_programme.csv",
                       show_col_types = FALSE)

# Prepare summary sheet
summary <- robin_costs %>%
  transmute(
    Employee = employee,
    `Hours Worked` = round(total_hours, 2),
    `Total Cost (EUR)` = round(total_cost, 2),
    `Avg Rate (EUR/h)` = round(total_cost / total_hours, 2),
    Entity = first_entity
  )

# Add total row
summary_with_total <- summary %>%
  bind_rows(
    tibble(
      Employee = "TOTAL",
      `Hours Worked` = sum(summary$`Hours Worked`),
      `Total Cost (EUR)` = sum(summary$`Total Cost (EUR)`),
      `Avg Rate (EUR/h)` = sum(summary$`Total Cost (EUR)`) / sum(summary$`Hours Worked`),
      Entity = NA
    )
  )

# Prepare comparison sheet
comparison_clean <- comparison %>%
  transmute(
    Employee = employee,
    `Calculated Hours` = round(calculated_hours, 2),
    `Planned Hours` = round(planned_hours, 2),
    `Difference (h)` = round(diff_hours, 2),
    `Difference (%)` = round(diff_pct, 1),
    `Total Cost (EUR)` = round(total_cost, 2),
    Status = status
  )

# Prepare work package breakdown sheet (CORRECTED period)
wp_breakdown <- cost_by_pr %>%
  filter(month >= as.Date("2024-03-01"),
         month <= as.Date("2025-08-01"),
         str_detect(str_to_upper(project), "ROBIN")) %>%
  mutate(year = year(month)) %>%
  group_by(du_id, pers_given, pers_surname, workpackage, wp_title, year) %>%
  summarise(
    hours = sum(hours, na.rm = TRUE),
    cost = sum(cost, na.rm = TRUE),
    start_period = min(month, na.rm = TRUE),
    end_period = max(month, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    employee = paste(str_to_title(pers_given), str_to_title(pers_surname)),
    # Start period: first day of the first month
    start_period = format(start_period, "%d.%m.%Y"),
    # End period: last day of the last month
    end_period = format(ceiling_date(end_period, "month") - days(1), "%d.%m.%Y")
  ) %>%
  select(
    Employee = employee,
    Year = year,
    `Work Package ID` = workpackage,
    `Work Package` = wp_title,
    `Start Period` = start_period,
    `End Period` = end_period,
    `Hours` = hours,
    `Cost (EUR)` = cost
  ) %>%
  arrange(Employee, Year, `Work Package ID`) %>%
  mutate(
    Hours = round(Hours, 2),
    `Cost (EUR)` = round(`Cost (EUR)`, 2)
  )

# Prepare methodology sheet
methodology <- tibble(
  Step = c(
    "1. Data Source",
    "2. Monthly Cost",
    "3. Hourly Rate",
    "4. Project Hours",
    "5. Project Cost",
    "6. Period",
    "7. Total"
  ),
  Description = c(
    "DATEV payroll files (2016*.csv, 2017*.csv) - actual paid salaries",
    "Sum of DATEV gesamtkosten for each person-month",
    "Monthly Cost / Total Hours Worked in that month",
    "CORRECTED: Uses dwt_worktime + nww_worktime_seconds (actual TKS booked hours)",
    "Hourly Rate × Project Hours (summed across all months)",
    "March 2024 to August 2025 (18 months) - Stella's reporting period",
    "Sum of all employees' project costs"
  ),
  Formula = c(
    "From DATEV exports",
    "SUM(gesamtkosten)",
    "gesamtkosten / hours_worked",
    "Uses per-WP allocation (not equal split)",
    "Hourly_Rate × Project_Hours",
    "2024-03-01 to 2025-08-31",
    sprintf("%.2f EUR", sum(robin_costs$total_cost, na.rm = TRUE))
  )
)

# Create Excel file with multiple sheets
output_file <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ROBIN_2025_Results_for_Stella.xlsx"

sheets <- list(
  "Summary" = summary_with_total,
  "Work Package Details" = wp_breakdown,
  "Comparison vs Plan" = comparison_clean,
  "Methodology" = methodology
)

write_xlsx(sheets, output_file)

cat(sprintf("\n✓ Excel file created: %s\n", output_file))
cat("\nSheets included:\n")
cat(sprintf("  1. Summary - Final results (%d employees + total)\n", nrow(robin_costs)))
cat(sprintf("  2. Work Package Details - Hours and costs by work package (%d entries)\n", nrow(wp_breakdown)))
cat("  3. Comparison vs Plan - Calculated vs planned hours\n")
cat("  4. Methodology - How calculations were done\n\n")
