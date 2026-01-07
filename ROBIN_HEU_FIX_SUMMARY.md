# ROBIN HEU Calculation Fix Summary

## Issue Identified

The `calculate_robin_heu_like_pipeline.R` script calculates HEU capacity (`day_equiv_base`) for the **full 18-month ROBIN period** for all employees, regardless of when they actually worked on the project.

### Current Code (Line 225):
```r
grid <- crossing(fte_periods_du, month = rp_months) %>%
  # ... calculates coverage for ALL 18 months ...
```

This causes Max Tage to be grossly overcalculated for employees who:
- Joined ROBIN mid-project (e.g., Alejandra Campos: only 14 months)
- Left ROBIN early (e.g., Tea Sarenkapa: only 7 months, Angela Heni: only 2 months)
- Reduced their allocation partway through (e.g., Nadja Schlichenmaier: 13 months)

##Solution Approach

Based on Stella's Geh älter sheet analysis, months worked should be determined by **months with payroll costs**.

### Fix Strategy:

1. **After loading payroll data** (around line 100), count months with payroll > 0 per employee
2. **Create employee-specific month lists** instead of using global `rp_months` for everyone
3. **Filter FTE grid** to only include months where employee had payroll

### Implementation Outline:

```r
# After payroll loading (~line 200), add:

# Determine active months per employee based on payroll
employee_active_months <- payroll_with_ids %>%
  filter(gesamtkosten > 0) %>%
  group_by(du_id) %>%
  summarise(
    active_months = list(unique(month)),
    n_months = n_distinct(month),
    .groups = "drop"
  )

# Modify grid creation to use employee-specific months:
grid <- fte_periods_du %>%
  left_join(employee_active_months, by = "du_id") %>%
  unnest(active_months) %>%
  rename(month = active_months) %>%
  mutate(
    m_start = month,
    m_end = month + days(29),
    ov_start = pmax(start, m_start),
    ov_end = pmin(end, m_end),
    days_overlap = pmax(0L, as.integer(ov_end - ov_start + 1L)),
    coverage_30 = days_overlap / 30
  ) %>%
  filter(coverage_30 > 0)
```

This ensures:
- Angela Heni: Only March-April 2024 counted (2 months) → ~22.5 days
- Tea Sarenkapa: Only March-September 2024 (7 months) → ~94 days
- Nadja Schlichenmaier: Only months with payroll (13 months) → ~233 days
- Alejandra Campos: Only months with payroll (14 months) → ~251 days

## Additional Payroll Fix Required

Even with correct month filtering, payroll totals are still ~19% lower than Stella's. Need to investigate:
1. Which DATEV entity codes Stella used
2. Whether certain monthly files are missing from our data sources
3. Whether Stella applied any payroll adjustments

