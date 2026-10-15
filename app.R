library(shiny)
library(readxl)
library(dplyr)
library(httr)
library(writexl)
library(DT)
library(xml2)
library(jsonlite)
library(openxlsx)

# ── Configuration ─────────────────────────────────────────────────────────────
# Load credentials from environment variables — never hardcode tokens here.
# Set GITHUB_PAT in your .Renviron file (see README for instructions).
rose_red_hex <- "#C21E56"
github_url   <- "https://raw.githubusercontent.com/mhajihos/CVC_ICD_Rep/main/backupfile.xlsx"
my_token     <- Sys.getenv("GITHUB_PAT")   # ← reads from .Renviron, not hardcoded

# ── UI ────────────────────────────────────────────────────────────────────────
ui <- navbarPage(
  title = div(
    class = "navbar-title-wrap",
    div("CVC Explorer", class = "navbar-main-title"),
    div("Under Development", class = "navbar-subtitle")
  ),
  header = tagList(
    tags$head(
      tags$style(HTML(paste0("
        .shiny-output-error { visibility: hidden; }
        .shiny-output-error:before { visibility: hidden; }
        .navbar.navbar-default { background-color: #0d2f45 !important; border-color: #0d2f45 !important; }
        .navbar-default .navbar-brand { color: white !important; font-weight: 700; font-size: 18px; }
        .navbar-default .navbar-nav > li > a { color: rgba(255,255,255,0.80) !important; font-weight: 600; }
        .navbar-default .navbar-nav > .active > a,
        .navbar-default .navbar-nav > .active > a:hover,
        .navbar-default .navbar-nav > .active > a:focus {
          color: white !important;
          background-color: rgba(194,30,86,0.25) !important;
          border-bottom: 3px solid ", rose_red_hex, " !important;
        }
        .cvc-header { background-color: ", rose_red_hex, "; color: white; padding: 30px 50px; margin-top: -20px; margin-bottom: 25px; border-bottom: 6px solid #007C41; }
        .cvc-title { font-size: 28px; font-weight: 700; margin: 0; }
        .cvc-subtitle { font-size: 13px; text-transform: uppercase; opacity: 0.9; }
        .well { background-color: #f8f9fa; border-top: 3px solid ", rose_red_hex, "; }
        .navbar-title-wrap { display: flex; flex-direction: column; justify-content: center; line-height: 1.1; }
        .navbar-main-title { font-weight: 700; font-size: 18px; color: white; }
        .navbar-subtitle { font-size: 11px; color: rgba(255,255,255,0.75); margin-top: 2px; }
        .navbar-brand { display: flex !important; align-items: center !important; }
        #pubmed_results table.dataTable thead th { background-color: ", rose_red_hex, " !important; color: white !important; font-weight: 600; }
        #pubmed_results .dataTables_paginate .paginate_button.current { background: ", rose_red_hex, " !important; color: white !important; }
        #pubmed_results a { color: white; background-color: ", rose_red_hex, "; text-decoration: none; font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 12px; }
        .pubmed-status { color: #555; font-size: 13px; font-style: italic; margin-bottom: 8px; }
      ")))
    ),
    div(
      class = "cvc-header",
      p(class = "cvc-subtitle", "Canadian VIGOUR Centre"),
      p(class = "cvc-title", "Medical Case Definition & PubMed Explorer")
    )
  ),

  # ── Tab 1: Database Filter ──────────────────────────────────────────────────
  tabPanel(
    "Explore Medical Case Definitions",
    sidebarLayout(
      sidebarPanel(
        h4("Explore Medical Case Definition"),
        uiOutput("filter_ui_type"),
        uiOutput("filter_ui_cond"),
        textInput("filter_icd", "Search ICD Codes:", ""),
        hr(),
        h4("Output Options"),
        checkboxInput("show_ref", "Include Reference or Project ID", value = FALSE),
        hr(),
        downloadButton("download_data", "Download Excel File", class = "btn-success", style = "width:100%")
      ),
      mainPanel(
        conditionalPanel(
          condition = "output.data_loaded == false",
          tags$div(style = "color:red; font-weight:bold;", textOutput("error_message"))
        ),
        h4("Database Preview (first 50 matches)"),
        tableOutput("preview_table")
      )
    )
  ),

  # ── Tab 2: PubMed Search ────────────────────────────────────────────────────
  tabPanel(
    "PubMed Search",
    sidebarLayout(
      sidebarPanel(
        h4("Literature Search"),
        uiOutput("pubmed_ui_filters"),
        actionButton("run_pubmed", "Search PubMed", class = "btn-primary", style = "width:100%;"),
        hr(),
        downloadButton("download_pubmed_excel", "Download Excel", class = "btn-success", style = "width:100%;"),
        hr(),
        helpText("Searches PubMed Title/Abstract fields (TIAB) for the selected condition within the chosen year window. Returns up to 50 results, fully sortable.")
      ),
      mainPanel(
        h4("PubMed Results"),
        div(class = "pubmed-status", textOutput("pubmed_status")),
        tags$hr(),
        DT::dataTableOutput("pubmed_results")
      )
    )
  )
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  `%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[1])) a else b

  data_status <- reactiveValues(loaded = FALSE, msg = "Connecting to GitHub...")

  raw_data <- reactive({
    tf <- tempfile(fileext = ".xlsx")
    tryCatch({
      req <- GET(
        github_url,
        add_headers(Authorization = paste("token", my_token)),
        write_disk(tf, overwrite = TRUE)
      )
      if (http_error(req)) {
        data_status$loaded <- FALSE
        data_status$msg <- "GitHub Token Error: Check GITHUB_PAT in .Renviron"
        return(NULL)
      }
      df <- read_excel(tf)
      data_status$loaded <- TRUE
      df
    }, error = function(e) {
      data_status$loaded <- FALSE
      data_status$msg <- paste("Error:", e$message)
      NULL
    })
  })

  output$data_loaded <- reactive({ data_status$loaded })
  outputOptions(output, "data_loaded", suspendWhenHidden = FALSE)
  output$error_message <- renderText({ data_status$msg })

  output$filter_ui_type <- renderUI({
    df <- raw_data(); req(df)
    selectInput("filter_type", "Condition Type:",
                choices = sort(unique(df$`Condition Type`)),
                multiple = TRUE)
  })

  output$filter_ui_cond <- renderUI({
    df <- raw_data(); req(df)
    choices <- if (!is.null(input$filter_type) && length(input$filter_type) > 0) {
      df %>% filter(`Condition Type` %in% input$filter_type) %>% pull(Condition) %>% unique() %>% sort()
    } else {
      sort(unique(df$Condition))
    }
    selectInput("filter_cond", "Condition:", choices = choices, multiple = TRUE)
  })

  filtered_df <- reactive({
    res <- raw_data(); req(res)
    if (!is.null(input$filter_type) && length(input$filter_type) > 0)
      res <- res %>% filter(`Condition Type` %in% input$filter_type)
    if (!is.null(input$filter_cond) && length(input$filter_cond) > 0)
      res <- res %>% filter(Condition %in% input$filter_cond)
    if (nzchar(input$filter_icd))
      res <- res %>% filter(
        grepl(input$filter_icd, `ICD-10`, ignore.case = TRUE) |
        grepl(input$filter_icd, `ICD-9`, ignore.case = TRUE)
      )
    res
  })

  output$preview_table <- renderTable({
    req(filtered_df())
    cols <- c("Condition", "Case Definition", "ICD-10", "ICD-9", "CCI", "ATC Codes", "Labs")
    if (input$show_ref) cols <- c(cols, "Reference or Project ID")
    filtered_df() %>% select(any_of(cols)) %>% head(50)
  })

  output$download_data <- downloadHandler(
    filename = function() paste0("CVC_Data_", Sys.Date(), ".xlsx"),
    content = function(file) {
      cols <- c("Condition", "Case Definition", "ICD-10", "ICD-9", "CCI", "ATC Codes", "Labs")
      if (input$show_ref) cols <- c(cols, "Reference or Project ID")
      write_xlsx(filtered_df() %>% select(any_of(cols)), file)
    }
  )

  output$pubmed_ui_filters <- renderUI({
    df <- raw_data(); req(df)
    tagList(
      selectInput("pubmed_cond_select", "Select Condition:", choices = sort(unique(df$Condition))),
      sliderInput("pubmed_year_range", "Year Window:",
                  min = 2000, max = as.numeric(format(Sys.Date(), "%Y")),
                  value = c(2020, as.numeric(format(Sys.Date(), "%Y"))), sep = "")
    )
  })

  search_status <- reactiveVal("")

  ncbi_esearch <- function(query, retmax = 50) {
    resp <- GET("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi",
                query = list(db = "pubmed", term = query, retmax = retmax, retmode = "json", usehistory = "y"))
    stop_for_status(resp)
    parsed <- fromJSON(content(resp, as = "text", encoding = "UTF-8"))
    list(count = as.integer(parsed$esearchresult$count),
         ids   = parsed$esearchresult$idlist,
         webenv = parsed$esearchresult$webenv,
         query_key = parsed$esearchresult$querykey)
  }

  ncbi_esummary <- function(ids) {
    resp <- GET("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi",
                query = list(db = "pubmed", id = paste(ids, collapse = ","), retmode = "json"))
    stop_for_status(resp)
    fromJSON(content(resp, as = "text", encoding = "UTF-8"))
  }

  pubmed_data <- eventReactive(input$run_pubmed, {
    req(input$pubmed_cond_select, input$pubmed_year_range)
    search_status("Searching PubMed title & abstract fields...")
    withProgress(message = "Fetching articles from PubMed...", value = 0.1, {
      clean_cond <- trimws(gsub("[[:punct:]]", " ", input$pubmed_cond_select))
      clean_cond <- gsub("\\s+", " ", clean_cond)
      y1 <- input$pubmed_year_range[1]; y2 <- input$pubmed_year_range[2]
      make_query <- function(quoted) {
        term <- if (quoted) paste0('"', clean_cond, '"[TIAB]') else paste0(clean_cond, "[TIAB]")
        paste0(term, " AND ", y1, ":", y2, "[PDAT]")
      }
      tryCatch({
        sr <- ncbi_esearch(make_query(TRUE))
        if (sr$count == 0) { search_status("Quoted search 0 results; retrying..."); sr <- ncbi_esearch(make_query(FALSE)) }
        if (sr$count == 0 || length(sr$ids) == 0) {
          search_status(paste0('No results for "', input$pubmed_cond_select, '" (', y1, '\u2013', y2, ').'))
          return(NULL)
        }
        search_status(paste0("Found ", sr$count, " result(s). Loading ", length(sr$ids), "..."))
        incProgress(0.5)
        summ <- ncbi_esummary(sr$ids)
        result_map <- summ$result; uid_list <- summ$result$uids
        rows <- lapply(uid_list, function(uid) {
          tryCatch({
            art <- result_map[[uid]]
            authors <- art$authors
            first_author <- if (!is.null(authors) && length(authors) > 0) authors$name[1] else NA_character_
            pub_year <- as.integer(substr(art$pubdate %||% "", 1, 4))
            data.frame(Year = pub_year, Author = as.character(first_author %||% ""),
                       Title = as.character(art$title %||% ""), PMID = uid, stringsAsFactors = FALSE)
          }, error = function(e) NULL)
        })
        tbl <- do.call(rbind, Filter(Negate(is.null), rows))
        if (is.null(tbl) || nrow(tbl) == 0) { search_status("Could not parse metadata."); return(NULL) }
        tbl$URL  <- paste0("https://pubmed.ncbi.nlm.nih.gov/", tbl$PMID, "/")
        tbl$Link <- paste0('<a href="', tbl$URL, '" target="_blank">View \u2197</a>')
        tbl$PMID <- NULL
        tbl <- tbl[order(-tbl$Year, na.last = TRUE), ]
        search_status(paste0("Showing ", nrow(tbl), " of ", sr$count, ' result(s) for "', input$pubmed_cond_select, '" (', y1, '\u2013', y2, ').'))
        tbl
      }, error = function(e) {
        search_status(paste("PubMed API error:", conditionMessage(e))); NULL
      })
    })
  })

  output$pubmed_status <- renderText({ search_status() })

  output$pubmed_results <- DT::renderDataTable({
    req(pubmed_data())
    display_tbl <- pubmed_data()[, c("Year", "Author", "Title", "Link")]
    DT::datatable(display_tbl, escape = FALSE, rownames = FALSE, selection = "none",
                  filter = "top",
                  options = list(pageLength = 10, order = list(list(0, "desc")),
                                 columnDefs = list(list(width = "60px", targets = 0),
                                                   list(width = "150px", targets = 1),
                                                   list(width = "auto", targets = 2),
                                                   list(width = "70px", targets = 3, orderable = FALSE))),
                  colnames = c("Year", "First Author", "Title", "Link"))
  })

  output$download_pubmed_excel <- downloadHandler(
    filename = function() paste0("PubMed_", gsub(" ", "_", input$pubmed_cond_select), "_", Sys.Date(), ".xlsx"),
    content = function(file) {
      tbl <- pubmed_data(); req(tbl)
      export_df <- tbl[, c("Year", "Author", "Title", "URL")]
      names(export_df)[4] <- "PubMed Link"
      wb <- createWorkbook()
      addWorksheet(wb, "PubMed Results")
      hs <- createStyle(fontName = "Calibri", fontSize = 11, fontColour = "white",
                        fgFill = "#C21E56", halign = "CENTER", textDecoration = "bold")
      writeData(wb, sheet = 1, x = export_df[, 1:3], startRow = 1, startCol = 1, headerStyle = hs)
      writeData(wb, sheet = 1, x = data.frame(`PubMed Link` = "PubMed Link"), startRow = 1, startCol = 4, colNames = TRUE, headerStyle = hs)
      link_style <- createStyle(fontColour = "#C21E56", textDecoration = "underline", halign = "CENTER")
      for (i in seq_len(nrow(export_df))) {
        url <- export_df$`PubMed Link`[i]
        writeFormula(wb, sheet = 1, x = paste0('HYPERLINK("', url, '","View \u2197")'), startRow = i + 1, startCol = 4)
        addStyle(wb, sheet = 1, style = link_style, rows = i + 1, cols = 4)
      }
      setColWidths(wb, sheet = 1, cols = 1:4, widths = c(8, 22, 80, 14))
      freezePane(wb, sheet = 1, firstRow = TRUE)
      saveWorkbook(wb, file, overwrite = TRUE)
    }
  )
}

shinyApp(ui, server)
