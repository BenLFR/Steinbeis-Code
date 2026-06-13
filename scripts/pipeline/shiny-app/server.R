# server.R
# Server Logic for Steinbeis Data Explorer

server <- function(input, output, session) {
    # --- INIT CHOICES ---
    updateSelectizeInput(session, "proj_select", choices = opts_projects, server = TRUE)
    updateSelectizeInput(session, "pers_select", choices = opts_people, server = TRUE)

    # ============================================================================
    # 1. DASHBOARD LOGIC
    # ============================================================================

    output$kpi_cost_txt <- renderText({
        paste0("€", formatC(kpi_total_cost, format = "f", digits = 0, big.mark = ","))
    })

    output$kpi_hours_txt <- renderText({
        formatC(kpi_total_hours, format = "f", digits = 0, big.mark = ",")
    })

    # Plot: Cost Evolution
    output$plot_cost_time <- renderPlotly({
        agg <- df_cost %>%
            group_by(month) %>%
            summarise(cost = sum(cost, na.rm = TRUE)) %>%
            arrange(month)

        p <- ggplot(agg, aes(x = month, y = cost)) +
            geom_col(fill = "#2c3e50") +
            theme_minimal() +
            labs(x = "", y = "Cost (€)")

        ggplotly(p)
    })

    # Plot: HEU Split
    output$plot_heu_split <- renderPlotly({
        agg <- df_cost %>%
            group_by(is_heu) %>%
            summarise(cost = sum(cost, na.rm = TRUE))

        plot_ly(agg,
            labels = ~is_heu, values = ~cost, type = "pie",
            textinfo = "label+percent",
            marker = list(colors = c("#95a5a6", "#f39c12"))
        ) %>%
            layout(showlegend = TRUE)
    })

    # Plot: Top Projects
    output$plot_top_projects <- renderPlotly({
        agg <- df_cost %>%
            group_by(project_label) %>%
            summarise(cost = sum(cost, na.rm = TRUE)) %>%
            arrange(desc(cost)) %>%
            head(10)

        p <- ggplot(agg, aes(x = reorder(project_label, cost), y = cost)) +
            geom_col(fill = "#3498db") +
            coord_flip() +
            theme_minimal() +
            labs(x = "", y = "Total Cost (€)")

        ggplotly(p)
    })

    # ============================================================================
    # 2. PROJECT EXPLORER LOGIC
    # ============================================================================

    # Reactive Project Data
    proj_data <- reactive({
        req(input$proj_select)
        # Extract ID from label if needed, or filter by label directly if unique
        # Here we used project_label as choice, so we can filter match
        df_cost %>% filter(project_label == input$proj_select)
    })

    output$proj_kpi_cost <- renderText({
        sum_val <- sum(proj_data()$cost, na.rm = TRUE)
        paste0("€", formatC(sum_val, format = "f", digits = 0, big.mark = ","))
    })

    output$proj_kpi_hours <- renderText({
        sum_val <- sum(proj_data()$hours, na.rm = TRUE)
        formatC(sum_val, format = "f", digits = 0, big.mark = ",")
    })

    output$proj_kpi_ppl <- renderText({
        n_distinct(proj_data()$du_id)
    })

    output$proj_plot_time <- renderPlotly({
        agg <- proj_data() %>%
            group_by(month) %>%
            summarise(cost = sum(cost, na.rm = TRUE))

        p <- ggplot(agg, aes(x = month, y = cost)) +
            geom_line(color = "#e74c3c", size = 1) +
            geom_point(color = "#e74c3c") +
            theme_minimal() +
            labs(x = "", y = "Cost (€)")
        ggplotly(p)
    })

    output$proj_tbl_team <- renderDT({
        proj_data() %>%
            group_by(pers_surname, pers_given, wp_title) %>%
            summarise(
                Hours = sum(hours, na.rm = TRUE),
                Cost = sum(cost, na.rm = TRUE),
                .groups = "drop"
            ) %>%
            arrange(desc(Cost)) %>%
            datatable(options = list(pageLength = 10)) %>%
            formatCurrency("Cost", "€") %>%
            formatRound("Hours", 1)
    })

    # ============================================================================
    # 3. PERSONNEL EXPLORER LOGIC
    # ============================================================================

    pers_data <- reactive({
        req(input$pers_select)
        # input$pers_select is the du_id (value)
        # The choices were named by label, but value is ID
        # But wait, we define server side: pull(label, name=id). Selectize returns value (ID).
        # But often names match depending on config. Let's make sure we filter by du_id if it's numeric, or we rely on string.
        # Actually opts_people is named vector: name=du_id, value=label.
        # Wait: pull(label, name=du_id) creates c("101"="Smith")? No. c("Smith"=101).
        # names(v) are the keys.
        # Shiny select expects choices = c("Label" = "Value").
        # So we want named vector where Names are Labels, Values are IDs.
        # global.R: pull(label, name=du_id). This gives a vector of labels, with NAMES as IDs.
        # In Shiny, choices=c(Name=Val). So we need to invert or use it correctly.
        # Let's check global.R Logic again.

        # Actually simpler: standard filter.
        # Just to be safe, filtering by ID string match.
        df_cost %>% filter(as.character(du_id) == as.character(input$pers_select))
    })

    output$pers_kpi_cost <- renderText({
        sum_val <- sum(pers_data()$cost, na.rm = TRUE)
        paste0("€", formatC(sum_val, format = "f", digits = 0, big.mark = ","))
    })

    output$pers_kpi_hours <- renderText({
        sum_val <- sum(pers_data()$hours, na.rm = TRUE)
        formatC(sum_val, format = "f", digits = 1, big.mark = ",")
    })

    output$pers_tbl_activity <- renderDT({
        pers_data() %>%
            group_by(project, wp_title) %>%
            summarise(
                Hours = sum(hours, na.rm = TRUE),
                Cost = sum(cost, na.rm = TRUE),
                .groups = "drop"
            ) %>%
            arrange(desc(Cost)) %>%
            datatable() %>%
            formatCurrency("Cost", "€") %>%
            formatRound("Hours", 1)
    })

    # ============================================================================
    # 4. DATA BROWSER
    # ============================================================================

    output$tbl_full <- renderDT({
        # Return full data table with Top filters
        datatable(df_cost %>% select(month, project, programme, wp_title, pers_surname, pers_given, hours, cost),
            filter = "top",
            extensions = "Buttons",
            options = list(
                dom = "Bfrtip",
                buttons = c("copy", "csv", "excel"),
                pageLength = 20
            )
        ) %>%
            formatCurrency("cost", "€") %>%
            formatRound("hours", 2)
    })
}
