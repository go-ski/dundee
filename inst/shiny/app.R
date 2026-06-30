# dundee Phase 2 review app: browse duplicate groups, view thumbnails + metadata,
# and choose the preferred copy per group (bulk heuristic + manual override).
# Decisions persist to the SQLite store immediately, so review is resumable.

library(shiny)
library(bslib)
library(DBI)

# --- load dundee (installed package, else source the dev tree) ---
if (requireNamespace("dundee", quietly = TRUE)) {
  library(dundee)
} else {
  here <- normalizePath(file.path("..", ".."))
  for (f in list.files(file.path(here, "R"), pattern = "\\.R$",
                       full.names = TRUE)) source(f)
}

cfg_path <- Sys.getenv("DUNDEE_CONFIG", "config.yml")
cfg <- dd_config(cfg_path, require_library = FALSE)

con <- dd_db_connect(cfg)
dd_db_init(con)
onStop(function() DBI::dbDisconnect(con))

# Serve cached thumbnails as static resources.
dir.create(cfg$thumb_dir, recursive = TRUE, showWarnings = FALSE)
addResourcePath("thumbs", normalizePath(cfg$thumb_dir))

group_list <- function() {
  DBI::dbGetQuery(con, "
    SELECT g.group_id, MIN(g.tier) AS tier, COUNT(*) AS n,
           SUM(COALESCE(d.preferred, -1) >= 0) AS decided
      FROM groups g LEFT JOIN decisions d USING (photo_id)
     GROUP BY g.group_id ORDER BY g.group_id")
}

group_members <- function(gid) {
  DBI::dbGetQuery(con, sprintf("
    SELECT p.photo_id, p.rel_path, p.width, p.height, p.size, p.format,
           p.meta_count, p.capture_time, p.file_hash, p.pixel_hash,
           d.preferred
      FROM groups g JOIN photos p USING (photo_id)
      LEFT JOIN decisions d USING (photo_id)
     WHERE g.group_id = %d
     ORDER BY p.photo_id", as.integer(gid)))
}

ui <- page_sidebar(
  title = "dundee — duplicate review",
  sidebar = sidebar(
    width = 320,
    actionButton("bulk", "Apply bulk heuristic to all", class = "btn-primary"),
    helpText("Bulk rules:", paste(cfg$preference_rules, collapse = " > ")),
    hr(),
    uiOutput("group_picker"),
    hr(),
    textOutput("progress")
  ),
  card(
    card_header(textOutput("group_header")),
    uiOutput("members")
  )
)

server <- function(input, output, session) {
  rv <- reactiveValues(groups = group_list(), current = NULL, tick = 0)

  observe({
    g <- rv$groups
    if (is.null(rv$current) && nrow(g) > 0) rv$current <- g$group_id[1]
  })

  output$group_picker <- renderUI({
    g <- rv$groups
    if (nrow(g) == 0) return(p("No groups. Run analyze first."))
    labels <- sprintf("Group %d  [%s, n=%d]%s", g$group_id, g$tier, g$n,
                      ifelse(g$decided > 0, "  \u2713", ""))
    selectInput("group", "Group", setNames(g$group_id, labels),
                selected = rv$current)
  })

  observeEvent(input$group, { rv$current <- as.integer(input$group) })

  observeEvent(input$bulk, {
    n <- dd_apply_bulk_decisions(con, cfg, overwrite = FALSE)
    rv$groups <- group_list(); rv$tick <- rv$tick + 1
    showNotification(sprintf("Applied bulk decisions to %d photos.", n))
  })

  output$progress <- renderText({
    rv$tick
    g <- rv$groups
    sprintf("%d / %d groups decided", sum(g$decided > 0), nrow(g))
  })

  output$group_header <- renderText({
    if (is.null(rv$current)) "" else paste("Group", rv$current)
  })

  output$members <- renderUI({
    rv$tick
    gid <- rv$current
    if (is.null(gid)) return(NULL)
    m <- group_members(gid)
    # Ensure thumbnails for this group's members (lazy, cached).
    dd_ensure_thumbs(
      data.frame(photo_id = m$photo_id,
                 path = file.path(cfg$library_root, m$rel_path)),
      cfg)
    cards <- lapply(seq_len(nrow(m)), function(i) {
      pid <- m$photo_id[i]
      is_pref <- !is.na(m$preferred[i]) && m$preferred[i] == 1
      thumb <- sprintf("thumbs/%d.jpg", pid)
      card(
        class = if (is_pref) "border-success border-3" else "",
        card_header(
          actionButton(paste0("pref_", pid),
                       if (is_pref) "\u2713 Preferred" else "Mark preferred",
                       class = if (is_pref) "btn-success btn-sm" else "btn-outline-secondary btn-sm")
        ),
        tags$img(src = thumb, style = "max-width:100%;height:auto;"),
        tags$small(
          tags$div(m$rel_path[i]),
          tags$div(sprintf("%s  %sx%s  %s bytes  meta:%d",
                           m$format[i], m$width[i], m$height[i],
                           m$size[i], m$meta_count[i])),
          tags$div(sprintf("capture: %s", ifelse(nzchar(m$capture_time[i]),
                                                  m$capture_time[i], "-")))
        )
      )
    })
    layout_column_wrap(width = 1/3, !!!cards)
  })

  # Wire per-member "mark preferred" buttons.
  observe({
    gid <- rv$current
    if (is.null(gid)) return()
    m <- group_members(gid)
    lapply(m$photo_id, function(pid) {
      observeEvent(input[[paste0("pref_", pid)]], {
        mm <- group_members(gid)
        dd_record_decision(con, data.frame(
          photo_id = mm$photo_id, group_id = gid,
          preferred = as.integer(mm$photo_id == pid),
          decided_by = "manual"))
        rv$groups <- group_list(); rv$tick <- rv$tick + 1
      }, ignoreInit = TRUE)
    })
  })
}

shinyApp(ui, server)
