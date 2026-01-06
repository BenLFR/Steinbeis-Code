# 00_config.R
# Configuration et chemins pour le pipeline Stundensatz V9
# --------------------------------------------------------------------

# --- Chemins des répertoires de données ------------------------------
repo_root <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code"
dir_db    <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database"
dir_db_ben <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/datev-data"
dir_fte   <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/fte-liste"

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

# TEMPORARY BYPASS (to continue the pipeline while HR investigates)
# TODO(HR): Verify why these users have HEU hours but no payroll/FTE in the RP.
allow_incoherent <- TRUE  # set back to FALSE once HR has fixed the data

message("✓ Configuration loaded")
