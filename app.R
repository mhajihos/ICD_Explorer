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
rose_red_hex <- "#C21E56"
navy_hex     <- "#0d2f45"
green_hex    <- "#007C41"
github_url   <- "https://raw.githubusercontent.com/mhajihos/ICD_Explorer/main/backupfile.xlsx"
my_token     <- Sys.getenv("GITHUB_PAT")
who_id       <- Sys.getenv("WHO_CLIENT_ID")
who_secret   <- Sys.getenv("WHO_CLIENT_SECRET")

# ── WHO ICD-11 API helpers ──────────────────────────────────────────────────────
# OAuth2 token cache (environment acts as mutable storage across reactive calls)
.who_token_cache <- new.env(parent = emptyenv())
.who_token_cache$access_token <- NULL
.who_token_cache$expires_at   <- 0

who_get_token <- function() {
  # Return cached token if still valid
  if (!is.null(.who_token_cache$access_token) &&
      as.numeric(Sys.time()) < .who_token_cache$expires_at) {
    return(.who_token_cache$access_token)
  }
  if (!nzchar(who_id) || !nzchar(who_secret)) {
    stop("WHO credentials not configured (set WHO_CLIENT_ID and WHO_CLIENT_SECRET).")
  }
  resp <- POST(
    "https://icdaccessmanagement.who.int/connect/token",
    body = list(
      client_id     = who_id,
      client_secret = who_secret,
      grant_type    = "client_credentials",
      scope         = "icdapi_access"
    ),
    encode = "form"
  )
  stop_for_status(resp)
  parsed <- fromJSON(content(resp, as = "text", encoding = "UTF-8"))
  .who_token_cache$access_token <- parsed$access_token
  # refresh 60s before actual expiry
  .who_token_cache$expires_at <- as.numeric(Sys.time()) +
    as.numeric(parsed$expires_in %||% 3600) - 60
  .who_token_cache$access_token
}

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[1]) && nzchar(as.character(a[1]))) a else b

# Split a search box value into a list of search terms.
#   - If commas / semicolons / newlines are present, split on those
#     (so "heart failure, diabetes" -> c("heart failure", "diabetes")).
#   - Otherwise treat the whole string as a single phrase
#     (so "myocardial infarction" stays as one term, not two).
# Returns a character vector of trimmed, non-empty, de-duplicated terms.
split_terms <- function(query) {
  if (is.null(query) || !nzchar(trimws(query))) return(character(0))
  if (grepl("[,;\n]", query)) {
    parts <- strsplit(query, "[,;\n]+")[[1]]
  } else {
    parts <- query
  }
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]
  unique(parts)
}

# Strip <em> highlight tags that WHO returns in titles
.clean_who <- function(x) {
  if (is.null(x)) return("")
  gsub("<[^>]+>", "", as.character(x))
}

who_search <- function(query, limit = 50) {
  if (!nzchar(trimws(query))) return(data.frame())
  token <- tryCatch(who_get_token(), error = function(e) NULL)
  if (is.null(token)) return(data.frame())

  do_call <- function(tok) {
    GET(
      "https://id.who.int/icd/release/11/2024-01/mms/search",
      query = list(q = query, flatResults = "true", highlightingEnabled = "false"),
      add_headers(
        Authorization     = paste("Bearer", tok),
        `API-Version`     = "v2",
        Accept            = "application/json",
        `Accept-Language` = "en"
      )
    )
  }
  resp <- do_call(token)
  if (status_code(resp) == 401) {
    .who_token_cache$access_token <- NULL
    token <- who_get_token()
    resp <- do_call(token)
  }
  if (http_error(resp)) stop(paste("WHO API error:", status_code(resp)))

  parsed <- fromJSON(content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  ents <- parsed$destinationEntities
  if (is.null(ents) || length(ents) == 0) return(data.frame())

  ents <- ents[seq_len(min(limit, length(ents)))]
  rows <- lapply(ents, function(e) {
    data.frame(
      Code        = .clean_who(e$theCode %||% ""),
      Description = .clean_who(e$title %||% ""),
      Source      = "ICD-11",
      URL         = {
        id_url <- e$id %||% ""
        entity <- sub(".*/", "", id_url)
        if (nzchar(entity)) paste0("https://icd.who.int/browse/2024-01/mms/en#", entity) else ""
      },
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# ── NLM ICD-10-CM API helper (no auth) ───────────────────────────────────────────
nlm_search <- function(query, limit = 50) {
  if (!nzchar(trimws(query))) return(data.frame())
  resp <- GET(
    "https://clinicaltables.nlm.nih.gov/api/icd10cm/v3/search",
    query = list(terms = query, maxList = limit, sf = "code,name", df = "code,name")
  )
  if (http_error(resp)) stop(paste("NLM API error:", status_code(resp)))
  parsed <- fromJSON(content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  if (length(parsed) < 4) return(data.frame())
  pairs <- parsed[[4]]
  if (is.null(pairs) || length(pairs) == 0) return(data.frame())
  rows <- lapply(pairs, function(p) {
    data.frame(
      Code        = as.character(p[[1]]),
      Description = as.character(p[[2]]),
      Source      = "ICD-10-CM",
      URL         = paste0("https://www.icd10data.com/ICD10CM/Codes/", p[[1]]),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# ── Multi-term wrappers ──────────────────────────────────────────────────────────
# Run a single-term search function for each term, tag each result row with the
# matching term, combine, and de-duplicate by Code (keeping first occurrence).
# `per_term_limit` caps results per term so one broad term can't crowd out others.
.search_multi <- function(search_fn, query, per_term_limit) {
  terms <- split_terms(query)
  if (length(terms) == 0) return(data.frame())
  frames <- lapply(terms, function(term) {
    res <- search_fn(term, limit = per_term_limit)
    if (!is.null(res) && nrow(res) > 0) res$MatchedTerm <- term
    res
  })
  frames <- Filter(function(x) !is.null(x) && nrow(x) > 0, frames)
  if (length(frames) == 0) return(data.frame())
  combined <- do.call(rbind, frames)
  combined[!duplicated(combined$Code), , drop = FALSE]
}

who_search_multi <- function(query, per_term_limit = 10) {
  .search_multi(who_search, query, per_term_limit)
}

nlm_search_multi <- function(query, per_term_limit = 10) {
  .search_multi(nlm_search, query, per_term_limit)
}

# ── CVC curated dataset search (free text, multi-term) ──────────────────────────
# Accepts one or more terms (comma/semicolon/newline separated). A row matches
# if ANY term is found (case-insensitive substring) in any searchable column.
cvc_free_search <- function(df, query, limit = 50) {
  if (is.null(df) || nrow(df) == 0) return(df[0, , drop = FALSE])
  terms <- split_terms(query)
  if (length(terms) == 0) return(head(df, limit))
  cols <- intersect(c("Condition", "Case Definition", "ICD-10", "ICD-9"), names(df))
  # Pre-lowercase each column once
  col_vals <- lapply(cols, function(cc) tolower(ifelse(is.na(df[[cc]]), "", as.character(df[[cc]]))))
  # Row matches if ANY term matches ANY column
  mask <- rep(FALSE, nrow(df))
  for (term in terms) {
    tq <- tolower(trimws(term))
    term_mask <- Reduce(`|`, lapply(col_vals, function(v) grepl(tq, v, fixed = TRUE)))
    mask <- mask | term_mask
  }
  head(df[mask, , drop = FALSE], limit)
}

# ── UI ────────────────────────────────────────────────────────────────────────
ui <- navbarPage(
  title = div(
    class = "navbar-title-wrap",
    div("CVC Explorer", class = "navbar-main-title"),
    div("Medical Case Definition & ICD Explorer", class = "navbar-subtitle")
  ),
  header = tagList(
    tags$head(
      tags$style(HTML(paste0("
        .shiny-output-error { visibility: hidden; }
        .shiny-output-error:before { visibility: hidden; }
        .navbar.navbar-default { background-color: ", navy_hex, " !important; border-color: ", navy_hex, " !important; }
        .navbar-default .navbar-brand { color: white !important; font-weight: 700; font-size: 18px; }
        .navbar-default .navbar-nav > li > a { color: rgba(255,255,255,0.80) !important; font-weight: 600; }
        .navbar-default .navbar-nav > .active > a,
        .navbar-default .navbar-nav > .active > a:hover,
        .navbar-default .navbar-nav > .active > a:focus {
          color: white !important;
          background-color: rgba(194,30,86,0.25) !important;
          border-bottom: 3px solid ", rose_red_hex, " !important;
        }
        .cvc-header { background-color: ", rose_red_hex, "; color: white; padding: 30px 50px; margin-top: -20px; margin-bottom: 25px; border-bottom: 6px solid ", green_hex, "; }
        .cvc-title { font-size: 28px; font-weight: 700; margin: 0; }
        .cvc-subtitle { font-size: 13px; text-transform: uppercase; opacity: 0.9; }
        .well { background-color: #f8f9fa; border-top: 3px solid ", rose_red_hex, "; }
        .navbar-title-wrap { display: flex; flex-direction: column; justify-content: center; line-height: 1.1; }
        .navbar-main-title { font-weight: 700; font-size: 18px; color: white; }
        .navbar-subtitle { font-size: 11px; color: rgba(255,255,255,0.75); margin-top: 2px; }
        .navbar-brand { display: flex !important; align-items: center !important; }
        /* Source badges */
        .badge-cvc   { background:", rose_red_hex, "; color:white; font-size:10px; font-weight:700; padding:2px 7px; border-radius:10px; text-transform:uppercase; }
        .badge-icd11 { background:", navy_hex, "; color:white; font-size:10px; font-weight:700; padding:2px 7px; border-radius:10px; text-transform:uppercase; }
        .badge-icd10 { background:", green_hex, "; color:white; font-size:10px; font-weight:700; padding:2px 7px; border-radius:10px; text-transform:uppercase; }
        .panel-head { font-size:15px; font-weight:700; color:", navy_hex, "; margin-bottom:4px; }
        .err-banner { background:#fff8e1; border:1px solid #ffe082; border-radius:6px; padding:8px 12px; font-size:12px; color:#795548; margin-bottom:8px; }
        #pubmed_results table.dataTable thead th { background-color: ", rose_red_hex, " !important; color: white !important; font-weight: 600; }
        #icd_cvc_table table.dataTable thead th { background-color: ", rose_red_hex, " !important; color: white !important; font-weight: 600; }
        #icd_universe_table table.dataTable thead th { background-color: ", navy_hex, " !important; color: white !important; font-weight: 600; }
        .pubmed-status { color: #555; font-size: 13px; font-style: italic; margin-bottom: 8px; }
      ")))
    ),
    div(
      class = "cvc-header",
      p(class = "cvc-subtitle", "Canadian VIGOUR Centre"),
      p(class = "cvc-title", "Medical Case Definition, ICD & PubMed Explorer")
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

  # ── Tab 2: Free-Text ICD Search (NEW) ───────────────────────────────────────
  tabPanel(
    "Free-Text ICD Search",
    fluidPage(
      fluidRow(
        column(
          width = 12,
          div(style = "max-width:720px; margin: 0 auto 18px;",
            textInput("icd_query", NULL, "",
                      placeholder = "Enter one or more terms, e.g. 'myocardial infarction, atrial fibrillation, stroke'…",
                      width = "100%"),
            div(style = "display:flex; gap:10px; align-items:center;",
              actionButton("icd_search_btn", "Search", class = "btn-primary"),
              downloadButton("download_icd", "Download Results (.xlsx)", class = "btn-success"),
              span(textOutput("icd_status", inline = TRUE), style = "font-size:12px; color:#888;")
            ),
            helpText(style = "margin-top:6px;",
              "Search multiple conditions at once by separating them with commas ",
              "(e.g. ", tags$code("diabetes, heart failure, stroke"), "). ",
              "Results include any row/code matching ", tags$strong("any"), " of the terms. ",
              "A single phrase without commas (e.g. ", tags$code("heart failure"),
              ") is searched as one term.")
          )
        )
      ),
      hr(),
      fluidRow(
        # Left: CVC curated matches
        column(
          width = 6,
          div(class = "panel-head", "CVC Case Definitions ",
              span(class = "badge-cvc", "CVC Curated")),
          p(style = "font-size:12px; color:#666;",
            "Matches from the curated CVC case-definition dataset."),
          DT::dataTableOutput("icd_cvc_table")
        ),
        # Right: Full ICD universe
        column(
          width = 6,
          div(class = "panel-head", "Full ICD Universe ",
              span(class = "badge-icd11", "ICD-11"), " ",
              span(class = "badge-icd10", "ICD-10-CM")),
          p(style = "font-size:12px; color:#666;",
            "Live results from the WHO ICD-11 API and NLM ICD-10-CM API."),
          uiOutput("icd_error_banners"),
          DT::dataTableOutput("icd_universe_table")
        )
      )
    )
  ),

  # ── Tab 3: PubMed Search ────────────────────────────────────────────────────
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

  # ── Tab 1 outputs ─────────────────────────────────────────────────────────
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

  # ── Tab 2: Free-Text ICD Search ─────────────────────────────────────────────
  icd_results <- reactiveValues(
    cvc = data.frame(),
    universe = data.frame(),
    who_err = NULL,
    nlm_err = NULL,
    status = ""
  )

  run_icd_search <- function(query) {
    if (!nzchar(trimws(query))) {
      icd_results$cvc <- data.frame()
      icd_results$universe <- data.frame()
      icd_results$who_err <- NULL
      icd_results$nlm_err <- NULL
      icd_results$status <- ""
      return(invisible())
    }
    icd_results$status <- "Searching CVC dataset, WHO ICD-11, and NLM ICD-10-CM…"
    terms <- split_terms(query)
    withProgress(message = "Searching all sources…", value = 0.2, {
      # 1. CVC curated (any term matches)
      df <- raw_data()
      icd_results$cvc <- cvc_free_search(df, query)
      incProgress(0.3)

      # 2. WHO ICD-11 — one call per term, combined & de-duplicated (graceful)
      who_df <- tryCatch({ icd_results$who_err <- NULL; who_search_multi(query) },
                         error = function(e) { icd_results$who_err <- conditionMessage(e); data.frame() })
      incProgress(0.3)

      # 3. NLM ICD-10-CM — one call per term, combined & de-duplicated (graceful)
      nlm_df <- tryCatch({ icd_results$nlm_err <- NULL; nlm_search_multi(query) },
                         error = function(e) { icd_results$nlm_err <- conditionMessage(e); data.frame() })
      incProgress(0.2)

      # Align columns before rbind (multi wrappers add a MatchedTerm column)
      universe <- if (nrow(who_df) > 0 || nrow(nlm_df) > 0) {
        all_cols <- union(names(who_df), names(nlm_df))
        pad <- function(d) {
          if (nrow(d) == 0) return(d)
          for (cc in setdiff(all_cols, names(d))) d[[cc]] <- NA_character_
          d[, all_cols, drop = FALSE]
        }
        rbind(pad(who_df), pad(nlm_df))
      } else {
        data.frame()
      }
      icd_results$universe <- universe

      n_cvc <- nrow(icd_results$cvc)
      n_uni <- nrow(universe)
      term_note <- if (length(terms) > 1) sprintf("%d terms · ", length(terms)) else ""
      icd_results$status <- sprintf("%s%d CVC match%s · %d ICD result%s",
                                    term_note,
                                    n_cvc, if (n_cvc != 1) "es" else "",
                                    n_uni, if (n_uni != 1) "s" else "")
    })
  }

  observeEvent(input$icd_search_btn, { run_icd_search(input$icd_query) })

  output$icd_status <- renderText({ icd_results$status })

  output$icd_error_banners <- renderUI({
    banners <- list()
    if (!is.null(icd_results$who_err))
      banners <- c(banners, list(div(class = "err-banner",
        HTML(paste0("⚠️ <strong>WHO ICD-11 unavailable</strong> — ", icd_results$who_err)))))
    if (!is.null(icd_results$nlm_err))
      banners <- c(banners, list(div(class = "err-banner",
        HTML(paste0("⚠️ <strong>NLM ICD-10-CM unavailable</strong> — ", icd_results$nlm_err)))))
    tagList(banners)
  })

  output$icd_cvc_table <- DT::renderDataTable({
    df <- icd_results$cvc
    if (is.null(df) || nrow(df) == 0) {
      return(DT::datatable(
        data.frame(Message = "No CVC matches — try the full ICD universe on the right →"),
        rownames = FALSE, options = list(dom = "t"), colnames = ""
      ))
    }
    cols <- intersect(c("Condition Type", "Condition", "ICD-10", "ICD-9", "CCI",
                        "Case Definition", "ATC Codes", "Labs"), names(df))
    DT::datatable(
      df[, cols, drop = FALSE],
      rownames = FALSE, selection = "none", filter = "top",
      options = list(pageLength = 10, scrollX = TRUE, order = list())
    )
  })

  output$icd_universe_table <- DT::renderDataTable({
    df <- icd_results$universe
    if (is.null(df) || nrow(df) == 0) {
      return(DT::datatable(
        data.frame(Message = "No ICD codes found. Enter a query and press Search."),
        rownames = FALSE, options = list(dom = "t"), colnames = ""
      ))
    }
    disp <- df
    disp$Source <- ifelse(disp$Source == "ICD-11",
                          '<span class="badge-icd11">ICD-11</span>',
                          '<span class="badge-icd10">ICD-10-CM</span>')
    disp$Link <- ifelse(nzchar(disp$URL),
                        paste0('<a href="', disp$URL, '" target="_blank" rel="noopener noreferrer">View ↗</a>'),
                        "—")
    # Show the "Matched Term" column only when more than one term was searched
    show_term <- "MatchedTerm" %in% names(disp) &&
                 length(unique(disp$MatchedTerm[!is.na(disp$MatchedTerm)])) > 1
    if (show_term) {
      disp$`Matched Term` <- disp$MatchedTerm
      disp <- disp[, c("Source", "Code", "Description", "Matched Term", "Link")]
      col_defs <- list(list(width = "90px", targets = 0),
                       list(width = "80px", targets = 1),
                       list(width = "110px", targets = 3),
                       list(width = "60px", targets = 4, orderable = FALSE))
    } else {
      disp <- disp[, c("Source", "Code", "Description", "Link")]
      col_defs <- list(list(width = "90px", targets = 0),
                       list(width = "80px", targets = 1),
                       list(width = "60px", targets = 3, orderable = FALSE))
    }
    DT::datatable(
      disp, escape = FALSE, rownames = FALSE, selection = "none", filter = "top",
      options = list(pageLength = 15, scrollX = TRUE, columnDefs = col_defs)
    )
  })

  output$download_icd <- downloadHandler(
    filename = function() {
      q <- gsub("[^A-Za-z0-9]+", "_", substr(input$icd_query, 1, 40))
      if (!nzchar(q)) q <- "results"
      paste0("CVC_ICD_", q, "_", Sys.Date(), ".xlsx")
    },
    content = function(file) {
      wb <- createWorkbook()
      hs <- createStyle(fontName = "Calibri", fontSize = 11, fontColour = "white",
                        fgFill = rose_red_hex, halign = "CENTER", textDecoration = "bold")
      hs_navy <- createStyle(fontName = "Calibri", fontSize = 11, fontColour = "white",
                             fgFill = navy_hex, halign = "CENTER", textDecoration = "bold")

      # Sheet 1: CVC Case Definitions
      addWorksheet(wb, "CVC Case Definitions")
      cvc <- icd_results$cvc
      if (!is.null(cvc) && nrow(cvc) > 0) {
        cols <- intersect(c("Condition Type", "Condition", "Case Definition",
                            "ICD-10", "ICD-9", "CCI", "ATC Codes", "Labs",
                            "Reference or Project ID"), names(cvc))
        writeData(wb, 1, cvc[, cols, drop = FALSE], headerStyle = hs)
      } else {
        writeData(wb, 1, data.frame(Message = "No CVC matches"), headerStyle = hs)
      }

      # Sheet 2: Full ICD Universe
      addWorksheet(wb, "Full ICD Universe")
      uni <- icd_results$universe
      if (!is.null(uni) && nrow(uni) > 0) {
        has_term <- "MatchedTerm" %in% names(uni) &&
                    length(unique(uni$MatchedTerm[!is.na(uni$MatchedTerm)])) > 1
        if (has_term) {
          out <- data.frame(
            Source         = uni$Source,
            Code           = uni$Code,
            Description    = uni$Description,
            `Matched Term` = uni$MatchedTerm,
            Link           = uni$URL,
            check.names    = FALSE,
            stringsAsFactors = FALSE
          )
          link_col <- 5
        } else {
          out <- data.frame(
            Source      = uni$Source,
            Code        = uni$Code,
            Description = uni$Description,
            Link        = uni$URL,
            stringsAsFactors = FALSE
          )
          link_col <- 4
        }
        writeData(wb, 2, out, headerStyle = hs_navy)
        link_style <- createStyle(fontColour = navy_hex, textDecoration = "underline")
        for (i in seq_len(nrow(out))) {
          url_i <- out$Link[i]
          if (nzchar(url_i)) {
            writeFormula(wb, 2, x = paste0('HYPERLINK("', url_i, '","View")'),
                         startRow = i + 1, startCol = link_col)
            addStyle(wb, 2, link_style, rows = i + 1, cols = link_col)
          }
        }
        if (has_term) {
          setColWidths(wb, 2, cols = 1:5, widths = c(12, 12, 55, 20, 50))
        } else {
          setColWidths(wb, 2, cols = 1:4, widths = c(12, 12, 60, 50))
        }
      } else {
        writeData(wb, 2, data.frame(Message = "No ICD results"), headerStyle = hs_navy)
        setColWidths(wb, 2, cols = 1, widths = 40)
      }

      setColWidths(wb, 1, cols = 1:9, widths = c(16, 26, 50, 12, 10, 8, 14, 14, 22))
      freezePane(wb, 1, firstRow = TRUE); freezePane(wb, 2, firstRow = TRUE)
      saveWorkbook(wb, file, overwrite = TRUE)
    }
  )

  # ── Tab 3: PubMed Search ────────────────────────────────────────────────────
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
