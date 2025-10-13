# Data Source Inventory

This repository currently contains the following inputs for the personnel cost pipeline:

## Payroll exports (DATEV)
- Location: `data/personalkosten/`
- Contents: Monthly payroll CSV exports for Steinbeis cost centers 2016, 2017, and 2136 covering 2024 and partial 2025.
- Usage: Joined to Personio staffing data in the `compute_stundensatz_local_V*.R` scripts to compute personnel costs and daily rates.

## Personio contractual hours
- Location: `Wochenarbeitszeit.csv` (currently stored at the repository root).
- Usage in code: All maintained R scripts expect the Personio export of contractual hours at `Wochenarbeitszeit.csv` (see Section 7 in `scripts/compute_stundensatz_local_V9.R`).
- Recommended next step: Move this CSV under a dedicated Personio directory (e.g., `data/personio/`) so payroll and HR exports live in separate folders.

## Absence / parental leave data (missing)
- Requested by stakeholders to calculate HEU parental leave adjustments.
- Current status: **Not included** in this repository. No CSV or Excel export with parental leave periods (start/end dates, leave type, part-time factor) is available.
- Next steps: Obtain the absence export from Personio (or TKS) that lists parental leave entries, then store it under a dedicated directory (e.g., `data/absences/`) for future processing.

## Additional notes
- Tracey’s “purple table” referenced in project correspondence is not part of this repo; calculations rely on DATEV payroll unless that table is provided.
- Update this inventory whenever new datasets are added so the team can easily verify whether mandatory inputs (payroll, Personio FTE, leave data) are available.
