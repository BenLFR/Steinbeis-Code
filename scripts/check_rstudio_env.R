# Check RStudio Environment
# Run this in RStudio to diagnose issues

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  RStudio Environment Diagnostic\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# 1. Working Directory
cat("1. Working Directory:\n")
cat("   Current:", getwd(), "\n")
cat("   Expected: C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code\n")
cat("   Match:", getwd() == "C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code", "\n\n")

# 2. Environment Variables
cat("2. Environment Variables:\n")
env_vars <- c(
  "STEINBEIS_REPO_ROOT",
  "STEINBEIS_DATEV_DIR",
  "STEINBEIS_DB_DIR",
  "STEINBEIS_OUTPUT_DIR"
)

for (var in env_vars) {
  val <- Sys.getenv(var)
  cat(sprintf("   %s: %s\n", var, ifelse(val == "", "❌ NOT SET", paste0("✓ ", val))))
}

cat("\n3. Key Files Check:\n")
files_to_check <- c(
  "scripts/pipeline/run_pipeline.R",
  "scripts/pipeline/modules/00_config.R",
  "data/data/x/Database/ben/d_worktime.csv"
)

for (f in files_to_check) {
  exists <- file.exists(f)
  cat(sprintf("   %s: %s\n", f, ifelse(exists, "✓ EXISTS", "❌ MISSING")))
}

cat("\n4. R Version & Libraries:\n")
cat("   R Version:", R.version.string, "\n")

libs <- c("tidyverse", "lubridate", "janitor", "readxl", "writexl")
for (lib in libs) {
  installed <- requireNamespace(lib, quietly = TRUE)
  cat(sprintf("   %s: %s\n", lib, ifelse(installed, "✓ INSTALLED", "❌ MISSING")))
}

cat("\n5. Recommended Fix:\n")
if (getwd() != "C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code") {
  cat("   Run this first: setwd('C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code')\n")
}

if (Sys.getenv("STEINBEIS_DB_DIR") == "") {
  cat("   Environment variables not set. Add to your ~/.Renviron file:\n")
  cat("   STEINBEIS_REPO_ROOT=\"C:/Users/loeff/OneDrive/Documents/SEZ/2025/Steinbeis-Code\"\n")
  cat("   STEINBEIS_DATEV_DIR=\"C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/datev-data\"\n")
  cat("   STEINBEIS_DB_DIR=\"C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database/ben\"\n")
  cat("   STEINBEIS_OUTPUT_DIR=\"C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database\"\n")
  cat("\n   Then restart RStudio.\n")
}

cat("\n═══════════════════════════════════════════════════════════════════\n")
