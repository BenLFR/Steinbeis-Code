# run_pipeline_rstudio.R
# RStudio-friendly pipeline runner
# Source this file from RStudio Console: source("run_pipeline_rstudio.R")

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  PIPELINE RUNNER FOR RSTUDIO\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# 1. Set working directory to repo root
repo_root <- "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/Steinbeis-Code"
if (getwd() != repo_root) {
  cat("Setting working directory to:", repo_root, "\n")
  setwd(repo_root)
} else {
  cat("✓ Working directory already correct:", getwd(), "\n")
}

# 2. Set environment variables (if not already set)
env_vars <- list(
  STEINBEIS_REPO_ROOT = "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/Steinbeis-Code",
  STEINBEIS_DATEV_DIR = "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/datev-data",
  STEINBEIS_DB_DIR = "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database/ben",
  STEINBEIS_OUTPUT_DIR = "C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database"
)

cat("\nSetting environment variables:\n")
for (var_name in names(env_vars)) {
  if (Sys.getenv(var_name) == "") {
    Sys.setenv(!!var_name := env_vars[[var_name]])
    cat(sprintf("  %s: SET\n", var_name))
  } else {
    cat(sprintf("  %s: ✓ already set\n", var_name))
  }
}

# 3. Verify key files exist
cat("\nVerifying key files:\n")
key_files <- c(
  "scripts/pipeline/run_pipeline.R",
  "scripts/pipeline/modules/00_config.R"
)

all_exist <- TRUE
for (f in key_files) {
  if (!file.exists(f)) {
    cat(sprintf("  ❌ MISSING: %s\n", f))
    all_exist <- FALSE
  } else {
    cat(sprintf("  ✓ %s\n", f))
  }
}

if (!all_exist) {
  stop("\n❌ Missing required files! Check your working directory.")
}

# 4. Run the pipeline
cat("\n═══════════════════════════════════════════════════════════════════\n")
cat("  RUNNING PIPELINE...\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# Change to pipeline directory so relative paths work correctly
original_wd <- getwd()
setwd("scripts/pipeline")

# Run pipeline
tryCatch({
  source("run_pipeline.R")
}, finally = {
  # Always restore original working directory
  setwd(original_wd)
})

cat("\n═══════════════════════════════════════════════════════════════════\n")
cat("  ✅ PIPELINE COMPLETED\n")
cat("═══════════════════════════════════════════════════════════════════\n")
