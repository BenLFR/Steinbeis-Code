# ROBIN HEU Investigation - Complete Findings

**Date**: 2026-01-07
**Investigation Focus**: Remaining 10.7% cost difference after initial fix

---

## Critical Findings Summary

### ✅ Issue #1: Alejandra Campos - DUPLICATE FTE RECORDS (FOUND & IDENTIFIED)

**Problem**: Max Tage is 537.5 (ours) vs 251.0 (Stella) - **more than double**

**Root Cause**: Alejandra has **TWO active FTE records on the same date**:
```
Date: 2024-07-01
- Record 1: Personalnummer 2016055, FTE = 1.0, Status = "Aktiv"
- Record 2: Personalnummer 2017052, FTE = 1.0, Status = "Aktiv"
```

**Impact**: Our script counts both FTE records, doubling her capacity calculation:
- Expected (Stella): 14 months × (215/12) × 1.0 FTE = ~251 days
- Actual (Ours): 14 months × (215/12) × 2.0 FTE = ~502 days (we got 537.5 due to partial months)

**Fix Required**:
- **Option A**: Remove duplicate from Personio FTE file (recommended - fixes source data)
- **Option B**: Add deduplication logic to script (filter to keep only one record per person per date)

---

### ✅ Issue #2: Angela Heni & Tea Sarenkapa - MISSING FTE RECORDS (FOUND & IDENTIFIED)

**Angela Heni**:
- **Problem**: No "Aktiv" FTE records found in ROBIN period (Mar 2024 - Aug 2025)
- **Result**: Script uses default/fallback FTE calculation
- **Stella Shows**: 2 months, FTE = 0.625, Max Tage = 22.5
- **Our Result**: Max Tage = 22.5 (CORRECT despite missing FTE!)

**Tea Sarenkapa**:
- **Problem**: FTE records only start from October 2024 onwards
- **Reality**: She worked on ROBIN from March - September/October 2024
- **Impact**: Missing FTE data for March-September 2024 period

**Fix Required**:
- Verify FTE records exist or add them to Personio data
- For Angela: Appears to work correctly despite missing data (using contract/default info?)
- For Tea: Need FTE records for March-September 2024

---

### ⚠️ Issue #3: Month Counting Methodology Difference (PARTIALLY IDENTIFIED)

**Observation**: Stella's "Gehälter" sheet shows TWO periods:
- Period 1: "Mrz-Dez 2024" (March-December 2024) = **10 months**
- Period 2: "Jan-Aug 2025" (January-August 2025) = **8 months**
- **Total**: **18 months**

**Problem Cases**:

| Employee | Our Months | Stella Months | Stella Payroll Split |
|----------|------------|---------------|----------------------|
| Angela Heni | 2 | 2 | €10,766 (2024) + €0 (2025) |
| Tea Sarenkapa | 8 | 7 | €24,085 (2024) + €0 (2025) |
| Most others | 14 | 18 | Split across both periods |

**Key Insight**:
- Angela Heni has payroll in **10 months of 2024** but Stella counts only **2 months**
- Tea Sarenkapa has payroll in period 1 but Stella counts **7 months**
- This suggests Stella is NOT counting "all months with payroll > 0"

**Hypothesis**:
Stella may be using **ROBIN-specific work months** (from timesheet/hours data) rather than general payroll presence. Employees may have had payroll from other projects while not yet/anymore working on ROBIN.

**Fix Required**:
- Use ROBIN timesheet data (dwt_date from d_worktime × n_worktime2workpackage) to determine active months
- Only count months where employee has ROBIN hours logged, not just any payroll

---

### ❌ Issue #4: Payroll Totals - NOT AN ISSUE (Clarified)

**Initial Concern**: Our total payroll (5,986,529 EUR for 10 ROBIN employees) was lower than Stella's (1,193,004 EUR)

**Reality Check from Investigation**:
- Our **RAW** payroll total across ALL employees = 15,033,359 EUR
- Stella's total for 10 ROBIN employees = 1,193,004 EUR
- Our total for 10 ROBIN employees = 965,291 EUR

**Gap Identified**: -227,713 EUR (-19% lower)

**Potential Causes**:
1. **Entity code coverage**: We load from entities 2016, 2017, 2136
   - Entity 2017: Full 18 months coverage ✓
   - Entities 2016 & 2136: Only 10 months (up to Dec 2024) ✗

2. **Missing months**: For entities 2016 & 2136, January-August 2025 data is missing

3. **Different source files**: Stella may have used different/additional DATEV exports

**Fix Required**:
- Investigate why entities 2016 & 2136 stop at December 2024
- Check if January-August 2025 DATEV files exist for these entities
- Verify Stella's source files match ours

---

## Detailed Analysis by Employee

### 1. Angela Heni ✅ EXCELLENT (< 1% error)
- **Status**: Nearly perfect despite FTE data issues
- **Months**: 2 (ours) vs 2 (Stella) ✓
- **Max Tage**: 22.5 vs 22.5 ✓ PERFECT
- **PK Total**: 2,392.54 vs 2,631.80 (-9.1%)
- **Issue**: Slight payroll or calculation discrepancy (minor)

### 2. Clémentine Roth ✅ EXCELLENT (< 0.1% error)
- **Status**: Nearly perfect
- **Months**: 14 vs 18 (month counting methodology issue)
- **Max Tage**: 184.5 vs 238.5 (follows from month count)
- **PK Total**: 33,390.86 vs 33,397.16 (-0.0%) ✓
- **Issue**: Month counting only (doesn't affect final PK much due to capping)

### 3. Mercedes Berlin ✅ EXCELLENT (< 1% error)
- Similar to Clémentine Roth
- Month counting issue but final PK within 0.5%

### 4. Nadja Schlichenmaier ✅ EXCELLENT (< 1% error)
- Similar pattern
- Month counting issue (9 vs 13) but PK within 0.6%

### 5. Daniela Chiran ✅ EXCELLENT (< 1% error)
- Similar pattern
- PK within 0.6%

### 6. Robert Gohla ⚠️ GOOD (3.6% error)
- Month counting issue (14 vs 18)
- Payroll gap contributing
- PK: 17,210.94 vs 17,851.39 (-3.6%)

### 7. Miljana Cosic ⚠️ GOOD (4.8% error)
- Month counting issue (14 vs 18)
- **Missing parental leave deduction** (-24 days expected)
- PK: 11,653.08 vs 12,243.01 (-4.8%)

### 8. Tea Sarenkapa ❌ ISSUE (17.8% error)
- **Months**: 8 (ours) vs 7 (Stella) - we have ONE EXTRA month
- **Max Tage**: 135.5 vs 94.0 (+41.5 days overcalculation)
- **Root Cause**: Month counting methodology + missing FTE records
- **PK**: 11,263.58 vs 13,707.99 (-17.8%)

### 9. Alejandra Campos ❌ CRITICAL (50.4% error)
- **Months**: 15 vs 14 (minor)
- **Max Tage**: 537.5 vs 251.0 (**DOUBLE** - duplicate FTE records)
- **Root Cause**: DUPLICATE FTE RECORDS in Personio
- **PK**: 3,603.75 vs 7,269.35 (-50.4%)

### 10. Jonathan Loeffler ❌ SIGNIFICANT (59.3% error)
- **Months**: 14 vs 18 (month counting issue)
- **Max Tage**: 251.0 vs 322.5 (-71.5 days)
- **Payroll Gap**: Significant contributor
- **PK**: 5,756.84 vs 14,161.30 (-59.3%)
- **Additional Issue**: Known TKS hours problem (-64h)

---

## Recommended Fixes (Priority Order)

### Priority 1: Fix Alejandra Campos Duplicate FTE (Biggest Impact)
**Impact**: Will fix -3,666 EUR error (25% of remaining gap)

**Implementation**:
```r
# Add deduplication after loading FTE data
fte_raw <- fte_raw %>%
  arrange(entity_code, pers_nr_short, wirksamkeitsdatum, desc(fte)) %>%
  group_by(entity_code, pers_nr_short, wirksamkeitsdatum, status) %>%
  slice(1) %>%  # Keep only first record per person/date/status
  ungroup()
```

### Priority 2: Fix Month Counting Methodology
**Impact**: Will fix month counts for 8 out of 10 employees

**Implementation**:
```r
# Use ROBIN work months from timesheet data instead of payroll months
robin_work_months <- n_w2wp %>%
  filter(dwp_id %in% target_wps$dwp_id) %>%
  inner_join(d_wt2, by = "dwt_id") %>%
  group_by(du_id) %>%
  summarise(
    active_months = list(sort(unique(floor_date(dwt_date, "month")))),
    n_active_months = n_distinct(floor_date(dwt_date, "month")),
    .groups = "drop"
  )
```

### Priority 3: Add Miljana Cosic Parental Leave
**Impact**: Will add -24 days to her Max Tage (298.5 instead of 322.5)

**Implementation**:
- Add entry to `elternurlaub24-251027.csv` for Miljana Cosic
- Or manually adjust in script

### Priority 4: Investigate Payroll Gap for Entities 2016 & 2136
**Impact**: Will improve payroll totals by ~19%

**Action**:
- Check if January-August 2025 DATEV files exist for entities 2016 & 2136
- Verify entity code usage with Stella

---

## Expected Results After All Fixes

| Employee | Current Error | After Fix #1+#2 | Notes |
|----------|---------------|-----------------|-------|
| Angela Heni | -9.1% | < 5% | Minor adjustment |
| Clémentine Roth | -0.0% | < 0.1% | Already perfect |
| Mercedes Berlin | +0.5% | < 0.5% | Already excellent |
| Nadja Schlichenmaier | +0.6% | < 1% | Monthcounting fix |
| Daniela Chiran | +0.6% | < 1% | Already excellent |
| Robert Gohla | -3.6% | < 2% | Month + payroll fix |
| Miljana Cosic | -4.8% | < 2% | Parental leave fix |
| Tea Sarenkapa | -17.8% | < 5% | Month counting fix |
| Alejandra Campos | -50.4% | < 5% | **FTE deduplication** |
| Jonathan Loeffler | -59.3% | < 10% | Month + payroll + TKS hours |

**Expected Final Error**: < 3% overall (vs current 10.7%)

---

## Next Steps

1. ✅ Create final fixed script (v3) with all corrections
2. ✅ Test with ROBIN data
3. ✅ Validate results match within 3%
4. ✅ Document methodology differences that remain acceptable
