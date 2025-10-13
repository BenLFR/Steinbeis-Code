# Steinbeis Code Repository

This repository organizes the project assets into dedicated directories:

- `data/personalkosten/` – Source payroll CSV exports grouped by organization and month.
- `scripts/` – R scripts for computing hourly rates across multiple script revisions (`compute_stundensatz_local_V*.R`) and ad-hoc project reporting utilities.
- `docs/` – Documentation on required inputs and data availability for the pipeline.

## Project-specific reports

Run `scripts/report_robin_costs.R` to list everyone who recorded time on project ROBIN and the corresponding company cost over the RP1 window (01 Mar 2024–31 Aug 2025). The script expects the following inputs:

- DATEV payroll exports stored under `data/personalkosten/` (override with `STEINBEIS_DATEV_DIR`).
- Database snapshots exported as CSV files inside `data/database/` (override with `STEINBEIS_DB_DIR`). The script relies on `d_user.csv`, `d_worktime.csv`, `n_worktime2workpackage.csv`, `d_workpackage.csv`, `d_project.csv`, `d_costcenter.csv`, and `l_project_category (2).csv`.

Outputs are written to `data/outputs/` by default (override with `STEINBEIS_OUTPUT_DIR`).

See `docs/data_sources.md` for a detailed inventory of which Personio and DATEV files are currently tracked and which are still missing. The Personio contractual-hours export (`Wochenarbeitszeit.csv`) is already committed and currently lives at the repository root; consider relocating it to a `data/personio/` directory alongside future HR exports.
