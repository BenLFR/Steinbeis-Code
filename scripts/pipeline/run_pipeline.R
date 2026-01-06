# run_pipeline.R
# Pipeline Stundensatz V9 - Script principal
#
# Ce script orchestre l'exécution complète du pipeline de calcul des
# taux horaires (Stundensatz) et des daily rates HEU.
#
# Usage:
#   Rscript run_pipeline.R                    # Exécute tout le pipeline
#   Rscript run_pipeline.R --from=05          # Commence à partir du module 05
#   Rscript run_pipeline.R --only=09          # Exécute uniquement le module 09
#
# Structure du pipeline:
#   00_config.R               - Configuration et chemins
#   01_utils.R                - Fonctions utilitaires
#   02_load_data.R            - Chargement des données (DB, DATEV, Personio)
#   03_user_mapping.R         - Mapping utilisateurs ↔ HR numbers
#   04_worktime_analysis.R    - Analyse du temps de travail
#   05_master_table.R         - Construction de la table master enrichie
#   06_project_classification.R - Classification des projets (HEU/non-HEU)
#   07_cost_breakdown.R       - Répartition des coûts par projet
#   08_heu_gatekeeper.R       - Contrôle de cohérence RH vs HEU
#   09_heu_daily_rate.R       - Calcul du daily rate HEU
#   10_exports.R              - Exports des résultats finaux
#
# --------------------------------------------------------------------

# Capture du temps de début
pipeline_start <- Sys.time()

cat("\n")
cat("═══════════════════════════════════════════════════════════════════\n")
cat("  PIPELINE STUNDENSATZ V9\n")
cat("  Démarré à:", format(pipeline_start, "%Y-%m-%d %H:%M:%S"), "\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# --- Parse command line arguments -----------------------------------------
args <- commandArgs(trailingOnly = TRUE)
start_from <- 0
only_module <- NULL

if (length(args) > 0) {
  for (arg in args) {
    if (grepl("^--from=", arg)) {
      start_from <- as.integer(sub("^--from=", "", arg))
      cat("▶ Mode: Exécution à partir du module", sprintf("%02d", start_from), "\n\n")
    } else if (grepl("^--only=", arg)) {
      only_module <- as.integer(sub("^--only=", "", arg))
      cat("▶ Mode: Exécution uniquement du module", sprintf("%02d", only_module), "\n\n")
    }
  }
}

# --- Load required libraries ----------------------------------------------
cat("📦 Chargement des librairies...\n")
suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(janitor)
  library(stringr)
  library(readxl)
  library(stringdist)
  library(fuzzyjoin)
  library(scales)
})
cat("✓ Librairies chargées\n\n")

# --- Define module execution order ----------------------------------------
modules <- c(
  "00_config.R",
  "01_utils.R",
  "02_load_data.R",
  "03_user_mapping.R",
  "04_worktime_analysis.R",
  "04b_robin_tks_export.R",
  "05_master_table.R",
  "06_project_classification.R",
  "07_cost_breakdown.R",
  "08_heu_gatekeeper.R",
  "09_heu_daily_rate.R",
  "10_exports.R"
)

# Get the directory where this script is located
script_path <- commandArgs(trailingOnly = FALSE)
script_path <- sub("^--file=", "", script_path[grep("^--file=", script_path)])
if (length(script_path) == 0) {
  # Fallback to current directory if running interactively
  script_path <- getwd()
  modules_dir <- file.path(script_path, "modules")
} else {
  modules_dir <- file.path(dirname(script_path), "modules")
}

# --- Execute modules ------------------------------------------------------
for (i in seq_along(modules)) {
  module_num <- i - 1  # 0-indexed
  module_name <- modules[i]
  module_path <- file.path(modules_dir, module_name)

  # Skip if starting from a later module
  if (module_num < start_from) {
    next
  }

  # Skip if only executing a specific module
  if (!is.null(only_module) && module_num != only_module) {
    next
  }

  # Always execute config and utils
  if (module_num > 1 && !is.null(only_module)) {
    if (only_module > 1) {
      if (i == 1) {
        # Execute config
        cat("───────────────────────────────────────────────────────────────────\n")
        cat("📋 Module 00: Configuration (prerequisite)\n")
        cat("───────────────────────────────────────────────────────────────────\n")
        source(file.path(modules_dir, "00_config.R"), encoding = "UTF-8")
        cat("\n")
      }
      if (i == 2) {
        # Execute utils
        cat("───────────────────────────────────────────────────────────────────\n")
        cat("🔧 Module 01: Utils (prerequisite)\n")
        cat("───────────────────────────────────────────────────────────────────\n")
        source(file.path(modules_dir, "01_utils.R"), encoding = "UTF-8")
        cat("\n")
      }
    }
  }

  module_start <- Sys.time()

  cat("───────────────────────────────────────────────────────────────────\n")
  cat(sprintf("🔄 Module %02d: %s\n", module_num, gsub("\\.R$", "", module_name)))
  cat("───────────────────────────────────────────────────────────────────\n")

  tryCatch({
    source(module_path, encoding = "UTF-8")
    module_duration <- as.numeric(difftime(Sys.time(), module_start, units = "secs"))
    cat(sprintf("✅ Module %02d terminé en %.1f secondes\n\n", module_num, module_duration))
  }, error = function(e) {
    cat(sprintf("\n❌ ERREUR dans le module %02d:\n", module_num))
    cat("   ", conditionMessage(e), "\n\n")
    stop(sprintf("Pipeline arrêté au module %02d", module_num))
  })
}

# --- Pipeline completion --------------------------------------------------
pipeline_duration <- as.numeric(difftime(Sys.time(), pipeline_start, units = "secs"))

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  ✅ PIPELINE TERMINÉ AVEC SUCCÈS\n")
cat(sprintf("  Durée totale: %.1f secondes (%.1f minutes)\n",
            pipeline_duration, pipeline_duration/60))
cat("  Terminé à:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")
