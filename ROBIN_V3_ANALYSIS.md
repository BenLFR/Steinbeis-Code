# ROBIN HEU v3 Results Analysis

**Date**: 2026-01-07
**Critical Finding**: Month counting methodology issue identified

---

## Results Comparison

| Version | Total PK | vs Stella | Error % | Status |
|---------|----------|-----------|---------|--------|
| v1 (original) | 88,447 EUR | -58,343 EUR | -39.7% | ❌ Major undercalculation |
| v2 (payroll months) | 131,076 EUR | -15,714 EUR | -10.7% | ✅ **BEST** |
| v3 (timesheet months) | 256,129 EUR | +109,338 EUR | **+74.5%** | ❌ Major OVERcalculation |
| **Stella** | **146,790 EUR** | - | - | Target |

---

## Critical Finding: Month Counting Methodology

### What Happened in v3

**v3 used ROBIN timesheet months** (months where employee logged ROBIN hours):

| Employee | v2 (Payroll) | v3 (Timesheet) | Stella | Issue |
|----------|--------------|----------------|--------|-------|
| Alejandra Campos | 15 months | **1 month** | 14 months | Only logged hours in July! |
| Miljana Cosic | 14 months | **5 months** | 18 months | Sporadic logging |
| Robert Gohla | 14 months | **6 months** | 18 months | Sporadic logging |
| Daniela Chiran | 14 months | **7 months** | 18 months | Sporadic logging |
| Jonathan Loeffler | 14 months | **8 months** | 18 months | Sporadic logging |
| Mercedes Berlin | 14 months | **7 months** | 18 months | Sporadic logging |
| Nadja Schlichenmaier | 9 months | **10 months** | 13 months | Similar |
| Tea Sarenkapa | 8 months | **7 months** | 7 months | ✓ Match |
| Angela Heni | 2 months | **2 months** | 2 months | ✓ Match |
| Clémentine Roth | 14 months | **18 months** | 18 months | ✓ Match |

### Why This Breaks the Calculation

When Max Tage is TOO LOW (because we count too few months):
1. Max Tage becomes very small (e.g., Alejandra: 36 days vs expected 251 days)
2. Daily rate becomes VERY HIGH (payroll ÷ small Max Tage)
3. Even with capping, costs explode because daily rate is inflated

**Example - Alejandra Campos**:
- **Payroll**: 121,063 EUR (correct)
- **v2 Max Tage**: 537.5 days (15 months, had duplicate FTE issue)
- **v3 Max Tage**: 36 days (1 month from timesheet)
- **v3 Daily Rate**: 3,363 EUR/day (121,063 ÷ 36) ← EXTREMELY HIGH!
- **v3 PK Total**: 53,806 EUR vs Stella 7,269 EUR ← 7.4x too high!

---

## Root Cause Analysis

### Stella's Month Counting Methodology

Stella does **NOT** use:
- ❌ Payroll months (would give 14-18 months for everyone)
- ❌ Timesheet months (would give 1-18 months, very variable)

Stella likely uses:
- ✅ **Contract/Allocation months** - months employee was ALLOCATED to ROBIN project
- ✅ **Fixed periods** based on project phases or deliverables
- ✅ **HR/contract data** indicating project assignment dates

### Evidence

1. **Alejandra Campos**: Logged hours only in July 2024, but Stella counts 14 months
   - Suggests she was allocated/contracted for 14 months
   - May have worked on ROBIN without logging all hours
   - Or worked on other tasks under ROBIN allocation

2. **Most employees**: Stella shows 18 months (full project period)
   - Suggests full-time ROBIN allocation regardless of timesheet regularity
   - Professional staff often allocated to projects without daily time tracking

3. **Part-time employees** (Angela: 2 months, Tea: 7 months, Nadja: 13 months):
   - These match better with timesheet data
   - Suggests they had LIMITED allocation periods
   - Not allocated for full 18 months

---

## Recommended Solution

### Option A: Use Payroll Months with Max Cap (RECOMMENDED)

**v2 performed best** (10.7% error) using payroll months. The remaining issues were:
1. ✅ Alejandra FTE duplicate (fixed in v3 deduplication)
2. ✅ Miljana parental leave (fixed in v3)
3. ⚠️ Month counts still 14-18 vs Stella's 18

**Proposed v4**:
- Use payroll months (v2 approach)
- Apply FTE deduplication (v3 fix #1)
- Apply parental leave fixes (v3 fix #3)
- **Cap months at 18** (full project period) for employees with continuous employment

### Option B: Contact Stella for Methodology Clarification

Ask Stella:
1. How do you determine "Anzahl der Monate" (number of months)?
2. Is it from contract/allocation data or timesheet data?
3. Can you provide the source data for month counting?

### Option C: Use Fixed 18 Months for Full-Time Allocation

For employees showing continuous payroll through most of period:
- Default to 18 months (full project period)
- Only reduce for part-time/limited allocations (Angela, Tea, Nadja)

---

## Recommendation

**Use v2 with FTE fixes (create v4)**:

```
v4 = v2 approach (payroll months)
    + FTE deduplication (v3 fix)
    + Miljana parental leave (v3 fix)
    + Cap months at 18 for continuous employees
```

This should give us:
- Total PK: ~130-140k EUR (vs Stella 146,790 EUR)
- Error: < 10%
- Much better than v3's 74.5% error

---

## Key Learnings

1. **Timesheet months ≠ Project allocation months**
   - Timesheets show when hours were logged
   - Allocation shows when employee was assigned to project

2. **Professional staff may not log hours regularly**
   - Senior staff, management may have allocation without detailed time tracking
   - ROBIN hours file may be incomplete for some employees

3. **Payroll months are better proxy for allocation**
   - If employee has payroll, they were employed
   - If employed + worked on ROBIN at some point = likely allocated

4. **HEU methodology is sensitive to month count**
   - Small changes in months dramatically affect daily rates
   - Must get month counting correct for accurate results
