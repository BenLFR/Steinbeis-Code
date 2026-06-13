# setup_renviron.R
# Automatically configure .Renviron file for RStudio

cat("═══════════════════════════════════════════════════════════════════\n")
cat("  SETUP .Renviron FOR RSTUDIO\n")
cat("═══════════════════════════════════════════════════════════════════\n\n")

# Find .Renviron location
renviron_path <- file.path(Sys.getenv("HOME"), ".Renviron")
cat("Location:", renviron_path, "\n")

# Environment variables to add
env_vars <- c(
  'STEINBEIS_REPO_ROOT="C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/Steinbeis-Code"',
  'STEINBEIS_DATEV_DIR="C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/datev-data"',
  'STEINBEIS_DB_DIR="C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database/ben"',
  'STEINBEIS_OUTPUT_DIR="C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/data/x/Database"'
)

# Read existing .Renviron if it exists
existing_lines <- character(0)
if (file.exists(renviron_path)) {
  cat("\n✓ Existing .Renviron found\n")
  existing_lines <- readLines(renviron_path, warn = FALSE)
  cat("  Current lines:", length(existing_lines), "\n")
} else {
  cat("\n  No existing .Renviron file\n")
}

# Check which variables need to be added
vars_to_add <- character(0)
for (var in env_vars) {
  var_name <- sub('=.*', '', var)
  # Check if this variable already exists in the file
  already_exists <- any(grepl(paste0("^", var_name, "="), existing_lines))

  if (already_exists) {
    cat(sprintf("  - %s: already exists (will keep existing)\n", var_name))
  } else {
    cat(sprintf("  + %s: will add\n", var_name))
    vars_to_add <- c(vars_to_add, var)
  }
}

if (length(vars_to_add) > 0) {
  cat("\n")
  response <- readline(prompt = "Add these variables to .Renviron? (y/n): ")

  if (tolower(response) == "y") {
    # Append new variables
    new_lines <- c(
      existing_lines,
      "",
      "# Steinbeis Pipeline Configuration",
      vars_to_add
    )

    writeLines(new_lines, renviron_path)

    cat("\n✅ .Renviron updated successfully!\n\n")
    cat("═══════════════════════════════════════════════════════════════════\n")
    cat("  IMPORTANT: You must RESTART RStudio for changes to take effect\n")
    cat("═══════════════════════════════════════════════════════════════════\n\n")
    cat("After restarting:\n")
    cat("  1. Run: Sys.getenv('STEINBEIS_REPO_ROOT')\n")
    cat("  2. Should see: C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/Steinbeis-Code\n")
    cat("  3. Then run: source('scripts/pipeline/run_pipeline.R')\n\n")
  } else {
    cat("\n❌ Cancelled - no changes made\n")
  }
} else {
  cat("\n✓ All variables already configured!\n")
  cat("\nYou may need to restart RStudio if they're not working.\n")
}
