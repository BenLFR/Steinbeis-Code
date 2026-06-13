# ui.R
# User Interface for Steinbeis Data Explorer

ui <- page_navbar(
    title = "Steinbeis Pipeline Explorer",
    theme = bs_theme(version = 5, bootswatch = "flatly", primary = "#2c3e50"),

    # --- Sidebar Global Filters (Optional, can be specific per page) ---
    # sidebar = sidebar(
    #   selectInput("global_year", "Period", choices = 2024:2025, selected = 2024)
    # ),

    # ============================================================================
    # TAB 1: DASHBOARD
    # ============================================================================
    nav_panel(
        "Dashboard",
        layout_columns(
            fill = FALSE,
            value_box(
                title = "Total Cost",
                value = textOutput("kpi_cost_txt"),
                showcase = bsicons::bs_icon("currency-euro"),
                theme = "primary"
            ),
            value_box(
                title = "Total Hours",
                value = textOutput("kpi_hours_txt"),
                showcase = bsicons::bs_icon("clock"),
                theme = "secondary"
            ),
            value_box(
                title = "Active Projects",
                value = kpi_n_projects,
                showcase = bsicons::bs_icon("briefcase"),
                theme = "info"
            ),
            value_box(
                title = "Active Personnel",
                value = kpi_n_people,
                showcase = bsicons::bs_icon("people"),
                theme = "light"
            )
        ),
        layout_columns(
            col_widths = c(8, 4),
            card(
                card_header("Cost Evolution over Time"),
                plotlyOutput("plot_cost_time", height = "400px"),
                full_screen = TRUE
            ),
            card(
                card_header("HEU vs Non-HEU Cost"),
                plotlyOutput("plot_heu_split", height = "400px")
            )
        ),
        card(
            card_header("Top 10 Projects by Cost"),
            plotlyOutput("plot_top_projects", height = "400px")
        )
    ),

    # ============================================================================
    # TAB 2: PROJECT EXPLORER
    # ============================================================================
    nav_panel(
        "Project Explorer",
        layout_sidebar(
            sidebar = sidebar(
                selectizeInput("proj_select", "Select Project", choices = NULL, options = list(placeholder = "Type to search..."))
            ),
            layout_columns(
                value_box(title = "Project Cost", value = textOutput("proj_kpi_cost"), theme = "primary"),
                value_box(title = "Project Hours", value = textOutput("proj_kpi_hours"), theme = "secondary"),
                value_box(title = "Employees", value = textOutput("proj_kpi_ppl"), theme = "info")
            ),
            card(
                card_header("Monthly Cost"),
                plotlyOutput("proj_plot_time", height = "300px")
            ),
            card(
                card_header("Team Details (Breakdown)"),
                DTOutput("proj_tbl_team")
            )
        )
    ),

    # ============================================================================
    # TAB 3: PERSONNEL EXPLORER
    # ============================================================================
    nav_panel(
        "Personnel Explorer",
        layout_sidebar(
            sidebar = sidebar(
                selectizeInput("pers_select", "Select Person", choices = NULL, options = list(placeholder = "Search name..."))
            ),
            layout_columns(
                value_box(title = "Total Cost Generated", value = textOutput("pers_kpi_cost"), theme = "primary"),
                value_box(title = "Total Hours Worked", value = textOutput("pers_kpi_hours"), theme = "secondary")
            ),
            card(
                card_header("Activity by Project"),
                DTOutput("pers_tbl_activity")
            )
        )
    ),

    # ============================================================================
    # TAB 4: DATA BROWSER (EXCEL REPLACEMENT)
    # ============================================================================
    nav_panel(
        "Data Browser",
        card(
            card_header("Full Results (Filterable)"),
            height = "800px",
            DTOutput("tbl_full")
        )
    )
)
