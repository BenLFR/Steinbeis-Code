# 00_config.R
# Configuration et chemins pour le pipeline Stundensatz V9
# --------------------------------------------------------------------

# --- Chemins des répertoires de données ------------------------------
# Portable path resolution: works on any machine without editing this file,
# as long as the folder layout is preserved (repo and `data/x` side by side):
#
#   <base>/Steinbeis-Code   <- this git repository (repo_root)
#   <base>/data/x           <- input data (datev-data, Database, fte-liste)
#
# Override any path with an environment variable (set in ~/.Renviron) if your
# layout differs. See setup_renviron.R.

# Helper: return env var if set & non-empty, otherwise the default.
.env_or <- function(var, default) {
  val <- Sys.getenv(var, unset = "")
  if (nzchar(val)) val else default
}

# 1) Repository root: env override > walk up from working dir > working dir.
.find_repo_root <- function() {
  env_root <- Sys.getenv("STEINBEIS_REPO_ROOT", unset = "")
  if (nzchar(env_root) && dir.exists(env_root)) {
    return(normalizePath(env_root, winslash = "/", mustWork = FALSE))
  }
  cur <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
  repeat {
    is_repo <- dir.exists(file.path(cur, ".git")) ||
      file.exists(file.path(cur, "scripts/pipeline/modules/00_config.R"))
    if (is_repo) return(cur)
    parent <- dirname(cur)
    if (parent == cur) break   # reached filesystem root
    cur <- parent
  }
  normalizePath(getwd(), winslash = "/", mustWork = FALSE)
}

repo_root <- .find_repo_root()

# 2) Data root (`data/x`): defaults to a sibling of the repository.
#    Set STEINBEIS_DATA_DIR in ~/.Renviron only if your data lives elsewhere.
#    NOTE: legacy per-directory vars (STEINBEIS_DB_DIR / STEINBEIS_DATEV_DIR)
#    are intentionally NOT read here — old .Renviron files contain stale values.
data_root <- .env_or("STEINBEIS_DATA_DIR",
                     file.path(dirname(repo_root), "data", "x"))

# 3) Individual data directories, all derived from data_root.
dir_db     <- file.path(data_root, "Database")
dir_db_ben <- file.path(data_root, "Database", "ben")
dir_datev  <- file.path(data_root, "datev-data")
dir_fte    <- file.path(data_root, "fte-liste")

# Warn early (rather than failing deep in the pipeline) if inputs are missing.
for (.d in list(c("dir_datev", dir_datev), c("dir_fte", dir_fte))) {
  if (!dir.exists(.d[2])) {
    warning(sprintf("Data directory not found: %s = '%s'. ",
                    .d[1], .d[2]),
            "Set the matching STEINBEIS_* environment variable in ~/.Renviron ",
            "or place the data alongside the repo. See setup_renviron.R.",
            call. = FALSE)
  }
}

# --- Database variant (old vs ben) -----------------------------------
db_variant <- "ben"  # "ben" | "old"
db_root <- if (db_variant == "ben") dir_db_ben else dir_db
qa_dir <- file.path(db_root, "qa")

# --- Paramètres de la période de reporting ---------------------------
period_mode <- "manual"   # "datev" | "union" | "manual"

# Optional manual override (e.g., ROBIN RP1)
manual_start <- as.Date("2024-03-01")
manual_end   <- as.Date("2025-08-31")

# --- Paramètres de traitement ----------------------------------------
target_entities <- c("2016","2017","2136")

# --- Project-specific entity scope (override for HEU daily rate) -----
# Example: ROBIN uses entity 2017 (S2i) for payroll + cap calculations
project_entity_scope <- list(
  ROBIN = c("2017")
)

# TEMPORARY BYPASS (to continue the pipeline while HR investigates)
# TODO(HR): Verify why these users have HEU hours but no payroll/FTE in the RP.
allow_incoherent <- TRUE  # set back to FALSE once HR has fixed the data

message("✓ Configuration loaded")
message("  repo_root : ", repo_root)
message("  data_root : ", data_root)
