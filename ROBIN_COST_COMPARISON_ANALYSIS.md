# ROBIN Cost Comparison Analysis: Stella vs Our Calculations
**Date**: 2026-01-07
**Period**: P1 (01.03.2024 - 31.08.2025)

## Executive Summary

**Total Cost Difference**: 58,343 EUR (39.7% underestimation in our calculations)
- **Stella Total**: 146,790.46 EUR
- **Our Total**: 88,447.22 EUR

## Root Causes Identified

### 1. Payroll Costs Discrepancy (Primary Issue)
**Impact**: -227,713 EUR difference in total payroll

Our script is using lower payroll totals than Stella's calculations:
- **Stella Total AG Brutto**: 1,193,004.35 EUR
- **Our Total AG Brutto**: 965,291.41 EUR
- **Missing**: 227,712.94 EUR (19%)

**Per-Employee Payroll Differences**:
| Employee | Stella (EUR) | Ours (EUR) | Diff (EUR) | Diff (%) |
|----------|--------------|------------|------------|----------|
| Berlin, Mercedes | 99,290.96 | 77,543.38 | +21,747.58 | +21.9% |
| Campos, Alejandra | 110,582.29 | 121,063.48 | **-10,481.19** | **-9.5%** |
| Chiran, Daniela | 106,025.85 | 82,835.40 | +23,190.45 | +21.9% |
| Cosic, Miljana | 130,519.21 | 104,461.54 | +26,057.67 | +20.0% |
| Gohla, Robert | 221,425.86 | 169,409.69 | +52,016.17 | +23.5% |
| Heni, Angela | 10,766.44 | 10,766.44 | 0.00 | 0.0% ✓ |
| Loeffler, Jonathan | 314,966.90 | 240,827.90 | +74,139.00 | +23.5% |
| Roth, Clémentine | 91,031.11 | 70,811.66 | +20,219.45 | +22.2% |
| Sarenkapa, Tea | 24,085.07 | 28,527.38 | **-4,442.31** | **-18.4%** |
| Schlichenmaier, Nadja | 84,310.66 | 59,044.54 | +25,266.12 | +30.0% |

**Observation**: Most employees show 20-30% lower payroll in our calculations. Two employees (Campos, Sarenkapa) show HIGHER values, suggesting inconsistent data sources.

**Likely Causes**:
1. Using different DATEV files or periods than Stella
2. Missing monthly payroll data for some months
3. Different entity codes (we use 22xx codes, Stella might use different codes)

---

### 2. FTE / Max Tage Calculation Issues (Secondary Issue)

**Impact**: Affects 5 out of 10 employees

Our script calculates Max Tage for the **full 18-month period**, but employees worked different numbers of months on ROBIN:

| Employee | Stella Months | Our Months | Stella Max Tage | Our Max Tage | Issue |
|----------|---------------|------------|-----------------|--------------|-------|
| Angela Heni | **2** | 18 | 22.5 | 203.0 | **9x overcalculation** |
| Tea Sarenkapa | **7** | 18 | 94.0 | 377.0 | **4x overcalculation** |
| Nadja Schlichenmaier | **13** | 18 | 233.0 | 322.5 | **38% overcalculation** |
| Alejandra Campos | **14** | 18 | 251.0 | 645.0 | **2.5x overcalculation** |
| Miljana Cosic | 18* | 18 | 298.5 | 322.5 | **Parental leave issue** |

*Miljana worked 18 months but has parental leave deduction: 322.5 - 24 = 298.5

**Root Cause**:
- Our script uses **Personio FTE data for the full period** without limiting to months where employees actually worked on ROBIN
- Stella calculates Max Tage based on **ROBIN-specific work months only**

**Correct Formula** (Stella's approach):
```
Max Tage = (Months_on_ROBIN × 215/12) × FTE - parental_leave_days
```

**Example - Angela Heni**:
- **Stella**: 2 months × 17.92 × 0.625 = 22.4 days ✓
- **Ours**: 18 months × 17.92 × 0.625 = 201.6 days ✗

---

## Detailed Cost Impact by Employee

### Critical Cases (>50% difference):

**1. Alejandra Campos**:
- PK Total: 7,269 EUR (Stella) vs 3,003 EUR (Ours) = **+4,266 EUR (58.7%)**
- Issues: Max Tage wrong (251 vs 645) AND payroll inconsistency

**2. Jonathan Loeffler**:
- PK Total: 14,161 EUR (Stella) vs 4,481 EUR (Ours) = **+9,681 EUR (68.4%)**
- Issues: Payroll missing 74,139 EUR (23.5% gap), combined with TKS hours issue

**3. Tea Sarenkapa**:
- PK Total: 13,708 EUR (Stella) vs 4,048 EUR (Ours) = **+9,660 EUR (70.5%)**
- Issues: Max Tage wrong (94 vs 377) despite HIGHER payroll in our data

**4. Angela Heni**:
- PK Total: 2,632 EUR (Stella) vs 265 EUR (Ours) = **+2,367 EUR (89.9%)**
- Issues: Max Tage catastrophically wrong (22.5 vs 203)

**5. Nadja Schlichenmaier**:
- PK Total: 25,872 EUR (Stella) vs 12,999 EUR (Ours) = **+12,873 EUR (49.8%)**
- Issues: Both Max Tage (233 vs 322.5) and payroll (30% gap)

---

## Required Fixes

### Fix 1: Payroll Data Source Alignment
**Priority**: HIGH
**File**: `calculate_robin_heu_like_pipeline.R`, lines 50-90

**Action**:
1. Investigate which DATEV files Stella used (check entity codes, time periods)
2. Verify we're loading payroll for March 2024 - August 2025 consistently
3. Compare month-by-month payroll totals with Stella's "Gehälter" sheet
4. Identify missing months or entity codes

**Expected Result**: Total payroll should match 1,193,004.35 EUR

---

### Fix 2: Month-Limited FTE Calculation
**Priority**: HIGH
**File**: `calculate_robin_heu_like_pipeline.R`, lines 140-180

**Action**:
1. Determine ROBIN work months per employee from `d_worktime` + `n_worktime2workpackage` tables
2. Filter FTE periods to only months where employee has ROBIN time entries
3. Calculate Max Tage based on ROBIN months only, not full period
4. Apply parental leave deduction correctly (Miljana: 24 days)

**Implementation Approach**:
```r
# For each employee, find months with ROBIN work
robin_months_per_employee <- target_alloc %>%
  group_by(du_id) %>%
  summarise(
    first_robin_month = floor_date(min(dwt_date), "month"),
    last_robin_month = floor_date(max(dwt_date), "month"),
    robin_months = interval(first_robin_month, last_robin_month) / months(1) + 1
  )

# Filter FTE grid to only ROBIN months
fte_grid_robin_only <- fte_periods_du %>%
  inner_join(robin_months_per_employee, by = "du_id") %>%
  filter(
    month >= first_robin_month,
    month <= last_robin_month
  )
```

**Expected Results**:
- Angela Heni: 22.5 days (2 months)
- Tea Sarenkapa: 94.0 days (7 months)
- Nadja Schlichenmaier: 233.0 days (13 months)
- Alejandra Campos: 251.0 days (14 months)
- Miljana Cosic: 298.5 days (18 months - 24 parental leave)

---

### Fix 3: Parental Leave Data Verification
**Priority**: MEDIUM
**File**: Check `parental_leave_cleaned.xlsx`

**Action**:
1. Verify Miljana Cosic has 24 days parental leave recorded
2. Check if other employees have parental leave in the period

---

## Validation Checklist

After fixes, verify:
- [ ] Total payroll matches: 1,193,004.35 EUR
- [ ] Max Tage matches for all 10 employees
- [ ] Daily rates match (should follow automatically from above)
- [ ] Total PK matches: 146,790.46 EUR
- [ ] All percentage differences < 1%

---

## Additional Notes

**Note on Clémentine Roth FTE**:
Stella shows "0,70 & 0,80" indicating variable FTE (70% and 80% in different months). Our script should handle this via Personio FTE periods.

**Note on Hours**:
9 out of 10 employees have perfect hour matching. Jonathan Loeffler has -64h difference due to known TKS data issue (separate problem).
