# global.R
# Load libraries and data for the Steinbeis Data Explorer

library(shiny)
library(bslib)
library(dplyr)
library(readr)
library(DT)
library(plotly)
library(lubridate)
library(tidyr)
library(data.table)

# --- Configuration & Paths ---

# Attempt to locate the 'data' directory relative to script location
# If running from scripts/pipeline/shiny-app, data should be in ../../../data/data/x/Database
# But we need to handle different working directories

find_data_file <- function(filename) {
    candidates <- c(
        file.path("../../../data/data/x/Database", filename), # Relative from shiny-app
        file.path("../../../data/x/Database", filename), # Alternative
        file.path("C:/Users/loeff/OneDrive/Documents/04_Stages/SEZ/SEZ/2025/Steinbeis-Code/data/data/x/Database", filename), # Absolute fallback
        file.path("./data", filename) # Local cached copy
    )

    for (path in candidates) {
        if (file.exists(path)) {
            return(normalizePath(path))
        }
    }
    return(NULL)
}

path_cost <- find_data_file("cost_by_pr_with_programme.csv")
path_master <- find_data_file("master_personnes_enriched.csv")

if (is.null(path_cost) || is.null(path_master)) {
    stop("CRITICAL ERROR: Could not locate required data files. Please ensure 'cost_by_pr_with_programme.csv' and 'master_personnes_enriched.csv' are in the data directory.")
}

message("Loading data from:\n", "  Cost: ", path_cost, "\n  Master: ", path_master)

# --- Load Data ---

# Load Transaction Data (Cost by Project)
df_cost <- fread(path_cost) %>%
    mutate(
        month = as.Date(month),
        project_label = paste0(project_id, " - ", project)
    )

# Load Master Data (FTEs, etc.)
df_master <- fread(path_master) %>%
    mutate(month = as.Date(month))

# --- Pre-calculate Global KPIs ---

kpi_total_cost <- sum(df_cost$cost, na.rm = TRUE)
kpi_total_hours <- sum(df_cost$hours, na.rm = TRUE)
kpi_n_projects <- n_distinct(df_cost$project_id)
kpi_n_people <- n_distinct(df_master$du_id)

# --- Valid Options for Inputs ---
opts_projects <- df_cost %>%
    distinct(project_id, project_label) %>%
    arrange(project_id) %>%
    pull(project_label, name = project_id)

opts_people <- df_master %>%
    distinct(du_id, du_surname, du_name) %>%
    mutate(label = paste0(du_surname, " ", du_name)) %>%
    arrange(du_surname) %>%
    pull(du_id, name = label)
