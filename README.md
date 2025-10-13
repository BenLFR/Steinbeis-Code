# Steinbeis Code Repository

This repository organizes the project assets into dedicated directories:

- `data/personalkosten/` – Source payroll CSV exports grouped by organization and month.
- `scripts/` – R scripts for computing hourly rates across multiple script revisions (`compute_stundensatz_local_V*.R`).
- `docs/` – Documentation on required inputs and data availability for the pipeline.

See `docs/data_sources.md` for a detailed inventory of which Personio and DATEV files are currently tracked and which are still missing. The Personio contractual-hours export (`Wochenarbeitszeit.csv`) is already committed and currently lives at the repository root; consider relocating it to a `data/personio/` directory alongside future HR exports.
