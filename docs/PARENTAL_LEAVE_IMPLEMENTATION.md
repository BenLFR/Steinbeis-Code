# Parental Leave (Elternzeit) Implementation

## Overview

This document describes how parental leave is handled in the HEU daily rate calculation according to Horizon Europe rules.

## HEU Rule

According to Horizon Europe guidelines, parental leave days must be **deducted from the maximum declarable day-equivalents** when calculating personnel costs.

### Formula

```
Maximum Declarable Day-Equivalents =
  {((215/12) × months_employed × FTE) - parental_leave_days}

Then round to nearest 0.5 day-equivalent
```

### Example (from HEU Guidelines)

**Scenario:**
- Reporting period: 01/12/2021 to 31/01/2023 (14 months)
- Employee: Full-time (FTE = 1.0)
- Parental leave taken: 72 day-equivalents (i.e., 72 days × 1 day/1 day)

**Calculation:**
```
Base calculation: (215/12) × 14 months × 1 = 251.67 days
Parental leave deduction: 251.67 - 72 = 179.67 days
Rounded: 179.5 maximum declarable day-equivalents
```

**Daily rate calculation:**
```
Daily rate = Actual personnel costs during RP / 179.5
```

## Implementation in V9

### Data Source

The script reads parental leave data from `elternurlaub24-251027.csv` which contains:
- Employee name (Nachname, Vorname)
- Personnel number(s) (Personalnummer)
- Absence type (Abwesenheitsart - "Elternzeit")
- Start date (Von)
- End date (Bis)
- Duration in hours (Dauer Std)

### Processing Steps

1. **Load parental leave file** (section 12.b.1)
   - Parse semicolon-delimited CSV
   - Convert German date format (DD.MM.YYYY)
   - Filter for reporting period only

2. **Parse personnel numbers**
   - Split comma-separated personnel numbers (e.g., "2016016,2017516")
   - Extract entity_code (first 4 digits: "2016")
   - Extract pers_nr_short (remaining digits: "16")

3. **Convert hours to day-equivalents**
   - Formula: `day_equivalents = hours / 8`
   - Standard working day = 8 hours

4. **Link to employees**
   - Match via entity_code + pers_nr_short → du_id
   - Sum total parental leave days per person during RP

5. **Deduct from HEU cap** (section 12.c)
   ```r
   day_equiv_base = (215/12) × FTE × coverage_30
   day_equiv_max = round_to_half(day_equiv_base - parental_leave_days)
   ```

### Outputs

The implementation creates an additional export file:
- **parental_leave_deductions.csv**: Lists all employees with parental leave during the reporting period, showing:
  - du_id, du_login, du_name, du_surname
  - parental_leave_days (total day-equivalents deducted)

The deduction is also visible in:
- **heu_daily_rate_by_person.csv**: Shows day_equiv_base, parental_leave_days, and final day_equiv_max
- **heu_daily_rate_control.csv**: Validates that declared days don't exceed capped maximum

## Error Handling

If `elternurlaub24-251027.csv` is not found:
- Script logs a warning: "⚠ Parental leave file not found - proceeding without deduction"
- Continues with parental_leave_days = 0 for all employees
- No calculation errors occur

## Data Quality Notes

### Edge Cases Handled

1. **Multiple personnel numbers**:
   - Employees with multiple cost centers (e.g., "2016016,2017516")
   - Script processes each entity separately, then links to du_id

2. **Partial month leave**:
   - Leave periods are filtered to only include dates within the reporting period
   - Hours are summed across all leave periods

3. **Decimal hours**:
   - The CSV uses comma as decimal separator (German format)
   - Script converts "492,8" → 492.8 hours → 61.6 day-equivalents

### Known Employees in Sample Data

From `elternurlaub24-251027.csv`:
- **Sarah Mortimer** (2016016, 2017516): ~105 days (Jan-Sep 2024)
- **Isabell Sachs** (2016024, 2017025): ~148 days (Jan-Feb 2025)
- **Regina Hüttner** (2016088, 2017026): ~437 days (Jan 2024 - Oct 2025)
- **Bettina Remmele** (2016042, 2017041): ~123 days (Nov 2024 - Aug 2025)
- **Sebastian Große-Puppendahl** (2136003): 84 days (May-Sep 2024)
- **Vanessa Mertens** (2017061): 112 days (May-Oct 2025)
- **Chrispin Sanga** (2017606, 2016120): 39 days (Dec 2024 - Feb 2025)
- **Clara Duffner** (2016114, 2017601): 123 days (Mar-Oct 2025)
- **Martina Deufel** (2016113, 2017603): 173 days (Feb-Oct 2025)
- **Katharina Böhm** (2016112, 2017605): ~61.6 days (Jul-Oct 2025)

## Validation

To verify the implementation:

1. Check `heu_daily_rate_by_person.csv`:
   - Look for `day_equiv_base` (before deduction)
   - Check `parental_leave_days` (deduction amount)
   - Verify `day_equiv_max = round_half(day_equiv_base - parental_leave_days)`

2. Check `parental_leave_deductions.csv`:
   - All employees with leave should be listed
   - Day-equivalent totals should match hours/8 from source file

3. Check `heu_daily_rate_control.csv`:
   - No employee should have `declared_day_equiv > day_equiv_max`
   - If over_cap = TRUE, investigation needed

## References

- **HEU Annotated Grant Agreement**: Section on personnel cost calculation
- **Email thread**: Stela Djurovic, Oct 2025, "HEU Calculation of the personnel costs - daily rate"
- **Source file**: `elternurlaub24-251027.csv` (from TKS export, Oct 27, 2025)
