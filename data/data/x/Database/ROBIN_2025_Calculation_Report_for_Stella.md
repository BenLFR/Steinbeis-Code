# ROBIN Project - Personnel Costs Calculation Report
## Period: January - August 2025

---

## 1. SUMMARY RESULTS

### Total Personnel Costs: **36,082.39 EUR**

| Employee | Hours | Cost (EUR) | Entity | Avg Rate (EUR/h) |
|----------|-------|------------|--------|------------------|
| Clémentine Roth | 295.5 h | 13,564.16 | 2017 | 45.90 |
| Robert Gohla | 113.4 h | 9,157.28 | 2017 | 80.79 |
| Daniela Chiran | 121.7 h | 5,945.38 | 2017 | 48.84 |
| Mercedes Berlin | 82.1 h | 4,259.09 | 2017 | 51.88 |
| Miljana Cosic | 64.6 h | 3,156.48 | 2017 | 48.85 |
| **TOTAL** | **677 h** | **36,082.39 EUR** | | |

---

## 2. METHODOLOGY

### Data Sources

1. **DATEV Payroll Files** (2016*.csv, 2017*.csv)
   - Monthly personnel costs (gesamtkosten)
   - Period: 01.2024 - 08.2025
   - Entities: 2016, 2017, 2136

2. **Time Tracking Database** (d_worktime.csv)
   - Individual time entries with start/end timestamps
   - Allocated to work packages via n_worktime2workpackage.csv

3. **Personio FTE Data** (Wochenarbeitszeit.csv)
   - Full-time equivalent percentages
   - Contract hours per month

4. **Parental Leave Data** (parental_leave_deductions.csv)
   - Calendar days of parental leave
   - Used for HEU day-equivalent deductions

### Calculation Method

#### Step 1: Monthly Cost per Person
- Source: DATEV payroll (actual paid amounts)
- Aggregated by: `du_id` (person) + `entity_code` + `month`
- **Formula**: Sum of all payroll entries for that person-month

#### Step 2: Hourly Rate Calculation
```
Hourly Rate = Monthly Costs / Hours Worked in Month
```

Where:
- **Monthly Costs**: From DATEV payroll (gesamtkosten)
- **Hours Worked**: Sum of time tracking entries for that month

#### Step 3: Prorata Multi-Work Package Allocation

When a person works on multiple work packages simultaneously:

```
Allocated Hours per WP = Total Hours × (1 / Number of WPs)
```

Example:
- Entry: 8 hours allocated to WP1, WP2, WP3 (3 work packages)
- Each WP receives: 8h × (1/3) = 2.67h

#### Step 4: Cost Allocation to Projects

```
Cost for Project = (Monthly Costs / Total Hours Worked) × Project Hours
```

For each person-month-project:
1. Calculate hourly rate from DATEV costs and total hours
2. Multiply by hours allocated to that specific project
3. Sum across all months (Jan-Aug 2025)

---

## 3. EXAMPLE CALCULATION (Clémentine Roth, January 2025)

### Input Data:
- DATEV costs (Jan 2025): 4,669.34 EUR
- Total hours worked: 100 h
- ROBIN hours: 21.93 h

### Calculation:
```
Hourly Rate = 4,669.34 EUR / 100 h = 46.69 EUR/h
ROBIN Cost = 46.69 EUR/h × 21.93 h = 1,024.14 EUR
```

### Repeat for all 8 months → Total: 13,564.16 EUR

---

## 4. KEY FEATURES OF THIS APPROACH

### ✓ DATEV-Based (Actual Costs)
- Uses real payroll data from DATEV exports
- Reflects actual salaries paid
- Includes bonuses, raises, adjustments

### ✓ Prorata Multi-WP Allocation
- Fair distribution when time is split across multiple projects
- Avoids over-allocating hours
- Each time entry's hours sum correctly across all WPs

### ✓ Entity-Specific Costs
- Maintains separate costs for different entities (2016, 2017, 2136)
- Avoids averaging across entities (which would dilute rates)

### ✓ HEU Compliance
- Parental leave days are deducted from day-equivalents
- Coverage_30 formula for mid-month start/end dates
- Day-equivalent cap: round((215/12) × months × FTE - parental_leave_days)

---

## 5. IMPORTANT NOTES

### Parental Leave Handling

Miljana Cosic has parental leave in Jul-Aug 2025:
- July: 10 days (starting 21.07.2025)
- August: Full month (31 days)
- **Total**: 42 calendar days

This is deducted from her HEU day-equivalent cap.

### Multi-Project Workers

Some employees work on many projects simultaneously:
- **Robert Gohla**: 19 different projects in Jan-Aug 2025
  - ROBIN received only 113h (9.6% of his time)
  - INVERSE: 209h, EEN: 167h, others: 691h

This explains why actual hours may differ from planning.

### Time Booking Periods

Robert Gohla's ROBIN work:
- January 2025: 47.8 h
- February 2025: 65.6 h
- March-August: 0 h (switched to other projects)

---

## 6. COMPARISON WITH PLANNING

| Employee | Calculated | Planned | Difference | % Diff |
|----------|------------|---------|------------|--------|
| Robert Gohla | 113.4 h | 155 h | -41.6 h | -26.9% |
| Clémentine Roth | 295.5 h | 273 h | +21.2 h | +7.8% |
| Miljana Cosic | 64.6 h | 75 h | -10.4 h | -13.8% |
| Daniela Chiran | 121.7 h | 115 h | +6.7 h | +5.9% |
| Mercedes Berlin | 82.1 h | 80 h | +2.1 h | +2.6% |
| **TOTAL** | **677 h** | **698 h** | **-21.9 h** | **-3.1%** |

**Overall alignment**: -3.1% → Excellent

---

## 7. DIFFERENCES FROM TRACEY'S APPROACH

### Our Approach (DATEV-Based):
```
Monthly Cost = Actual DATEV payroll for that month
```

### Tracey's Approach (Contract-Based):
```
Monthly Cost = (Annual Salary × FTE) / 12
```

### When Results Differ:
1. **Late salary payments**: DATEV shows 2× in one month, 0× in another
   - Contract: stable each month ✓
   - DATEV: matches reality of when paid

2. **Salary adjustments**: Corrections appear 1-2 months late
   - Contract: stable ✓
   - DATEV: shows actual payment timing

3. **Mid-year raises**: Salary increases during period
   - Contract: requires manual updates
   - DATEV: automatically reflects new amount ✓

### For ROBIN Jan-Aug 2025:
- ✅ All employees have complete DATEV data
- ✅ No late payments or corrections
- ✅ Results would be nearly identical with contract approach

---

## 8. FILES AVAILABLE

### Result Files:
1. **robin_project_costs_2025-01_to_2025-08.csv**
   - Clean summary: Employee, Hours, Cost, Entity

2. **robin_comparison_vs_plan.csv**
   - Comparison with planning table
   - Shows differences and percentages

3. **cost_by_pr_with_programme.csv**
   - Detailed breakdown by month, work package, project
   - All projects (not just ROBIN)

### Documentation:
4. **ROBERT_GOHLA_ANALYSIS.md**
   - Detailed investigation of Robert's multi-project allocation

5. **HYBRID_APPROACH_README.md**
   - Explanation of alternative calculation method (DATEV + estimates)

---

## 9. VALIDATION

### Cross-Checks Performed:

✓ Sum of project hours = Total hours worked (no over-allocation)
✓ All months have DATEV payroll data (no gaps)
✓ Entity codes match between payroll and time tracking
✓ Parental leave days correctly deducted from HEU caps
✓ Prorata allocation sums to 100% across work packages

### Known Issues:

⚠️ Robert Gohla: -26.9% vs plan (he worked on other projects)
⚠️ Name consistency: "Clémentine" vs "Clementine" (accents)

---

## 10. CONTACT & QUESTIONS

If you have questions about:
- **Methodology**: See sections 2-4 above
- **Specific calculations**: Check example in section 3
- **Data sources**: Refer to file paths in section 8
- **Discrepancies**: See comparison in section 6

**Calculation period**: 2025-01-01 to 2025-08-31
**Generated**: December 2025
**Tool**: R (tidyverse pipeline)
**Approach**: DATEV-based with prorata multi-WP allocation

---

## APPENDIX: Data File Locations

```
Database/
├── ben/
│   ├── d_worktime.csv           # Time tracking entries
│   ├── n_worktime2workpackage.csv  # WP allocations
│   ├── d_workpackage.csv        # Work package definitions
│   └── d_project.csv            # Project definitions
├── robin_project_costs_2025-01_to_2025-08.csv  # Results
├── parental_leave_deductions.csv  # Leave data
└── master_personnes_enriched.csv  # Combined person-month data

datev-data/
├── 2016*_*.csv                  # Entity 2016 payroll
├── 2017*_*.csv                  # Entity 2017 payroll
└── 2136*_*.csv                  # Entity 2136 payroll

fte-liste/
└── Wochenarbeitszeit.csv        # Personio FTE data
```

---

**END OF REPORT**
