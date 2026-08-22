# dundee Phase 2 review app: browse duplicate groups, compare the copies, and
# choose the preferred one. Decisions persist to the SQLite store immediately,
# so review is resumable.
#
# The reviewer's problem is not reading values, it is spotting which of them
# differ: in the reference store 24 of 30 groups agree on every stored field and
# differ in exactly one. So this file renders a *difference*, and the deciding
# logic lives in R/compare.R and R/details.R where R CMD check can reach it.

library(shiny)
library(bslib)
library(DBI)

if (!requireNamespace("dundee", quietly = TRUE)) {
  stop("dundee is not installed. Launch the app with dundee::dd_app().")
}
library(dundee)

# dd_app() writes <work_dir>/config.resolved.yml (absolute paths) and points
# DUNDEE_CONFIG at it, because runApp() has already changed the working
# directory to this folder. The file persists after the session, as provenance.
cfg_path <- Sys.getenv("DUNDEE_CONFIG", "config.resolved.yml")
cfg <- dd_config(cfg_path, require_library = FALSE)
con <- dd_db_connect(cfg)
dd_db_init(con)
onStop(function() DBI::dbDisconnect(con))

# Serve cached thumbnails and the full-size originals the viewer compares.
for (d in c(cfg$thumb_dir, cfg$orig_dir)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}
addResourcePath("thumbs", normalizePath(cfg$thumb_dir))
addResourcePath("originals", normalizePath(cfg$orig_dir))

group_list <- function() {
  DBI::dbGetQuery(con, "
    SELECT g.group_id, MIN(g.tier) AS tier, COUNT(*) AS n,
           SUM(COALESCE(d.preferred, -1) >= 0) AS decided
      FROM groups g LEFT JOIN decisions d USING (photo_id)
     GROUP BY g.group_id ORDER BY g.group_id")
}

group_members <- function(gid) {
  DBI::dbGetQuery(con, sprintf("
    SELECT p.photo_id, p.path, p.rel_path, p.width, p.height, p.size, p.mtime,
           p.format, p.meta_count, p.capture_time, p.camera,
           d.preferred, d.decided_by
      FROM groups g JOIN photos p USING (photo_id)
      LEFT JOIN decisions d USING (photo_id)
     WHERE g.group_id = %d
     ORDER BY p.photo_id", as.integer(gid)))
}

# Sections in the order that puts the discriminating one first. An exact group
# has byte-identical decoded pixels, so its quality rows always collapse and the
# decision rests on metadata, location and where the file lives.
section_order <- function(tier) {
  if (identical(tier, "near")) {
    c("quality", "capture", "location", "content", "file")
  } else {
    c("location", "content", "capture", "file", "quality")
  }
}

section_label <- c(quality = "Image quality", capture = "Capture",
                   location = "Location", content = "Added by a person",
                   file = "File")

# Location and capture date are shown for every copy whether or not they differ,
# because they are what the decision turns on. Absent is itself information, so
# it is stated rather than left blank.
card_location <- function(tbl, i) {
  co <- if ("coords" %in% names(tbl)) tbl$coords[i] else NA_character_
  if (is.na(co)) return(tags$div(tags$span(class = "dd-none", "no location")))
  tags$div(
    co, " ",
    # The only outbound request this app can make, and only if clicked.
    tags$a(href = sprintf("https://www.openstreetmap.org/?mlat=%s&mlon=%s#map=15/%s/%s",
                          tbl$gps_lat[i], tbl$gps_lon[i],
                          tbl$gps_lat[i], tbl$gps_lon[i]),
           target = "_blank", rel = "noopener noreferrer", "[map]"))
}

card_date <- function(tbl, i) {
  got <- dd_capture_date(if ("capture" %in% names(tbl)) tbl$capture[i] else NA,
                         if ("create_date" %in% names(tbl)) tbl$create_date[i]
                         else NA)
  if (is.na(got$value)) return(tags$div(tags$span(class = "dd-none", "no date")))
  tags$div(dd_fmt_field("capture", got$value),
           # Say which tag it came from only when it is not the usual one, so a
           # reviewer can see the two copies are not being read the same way.
           if (!identical(got$source, "DateTimeOriginal"))
             tags$span(class = "dd-none", sprintf(" (%s)", got$source)))
}

viewer_css <- "
.dd-viewer { position: relative; resize: both; overflow: hidden;
  min-width: 340px; min-height: 260px; width: 900px; height: 560px;
  background: var(--bs-body-bg); border: 1px solid var(--bs-border-color);
  border-radius: .5rem; box-shadow: 0 8px 28px rgba(0,0,0,.35); z-index: 1050;
  display: flex; flex-direction: column; }
.dd-head { cursor: move; padding: .35rem .6rem; border-bottom: 1px solid
  var(--bs-border-color); display: flex; gap: .4rem; align-items: center;
  flex-wrap: wrap; }
.dd-panes { display: flex; gap: 3px; flex: 1 1 auto; min-height: 0; }
.dd-pane { overflow: auto; flex: 1 1 0; min-width: 0; position: relative; }
.dd-pane img { display: block; max-width: none; }
.dd-cap { position: sticky; left: 0; top: 0; font-size: .75rem;
  background: rgba(0,0,0,.6); color: #fff; padding: 0 .35rem; display: inline-block; }
.dd-viewer.dd-blink .dd-pane { display: none; }
.dd-viewer.dd-blink .dd-pane.dd-on { display: block; }
.dd-tbl { width: 100%; border-collapse: collapse; }
.dd-tbl th, .dd-tbl td { padding: .25rem .5rem; border-top: 1px solid
  var(--bs-border-color); vertical-align: top; font-size: .9rem; }
.dd-tbl th.dd-lab { width: 12rem; font-weight: 500; color: var(--bs-secondary-color); }
.dd-tbl td.dd-best { font-weight: 600; }
.dd-mark { color: var(--bs-success); font-weight: 600; }
.dd-same { color: var(--bs-secondary-color); font-size: .85rem; }
.dd-sec { font-size: .8rem; text-transform: uppercase; letter-spacing: .04em;
  color: var(--bs-secondary-color); padding-top: .6rem; }
/* Set only by the Quit button, so a deliberate stop does not look like a
   crash. A real disconnect -- server died, network dropped -- never sets it
   and still raises the overlay it exists to signal. */
body.dd-quit #shiny-disconnected-overlay { display: none; }
.dd-side { display: flex; flex-direction: column; height: 100%; min-height: 0; }
/* The list takes whatever height is left, so the window decides how many
   groups are visible and the rest scroll. */
.dd-glist { flex: 1 1 auto; min-height: 6rem; overflow-y: auto;
  border-top: 1px solid var(--bs-border-color); }
.dd-g { display: flex; gap: .4rem; align-items: baseline; cursor: pointer;
  padding: .2rem .45rem; border-bottom: 1px solid var(--bs-border-color);
  font-size: .85rem; }
.dd-g:hover { background: var(--bs-tertiary-bg); }
.dd-g-on { background: var(--bs-primary-bg-subtle); font-weight: 600;
  box-shadow: inset 3px 0 0 var(--bs-primary); }
.dd-gid { min-width: 6.5rem; }
.dd-gmeta { color: var(--bs-secondary-color); font-size: .8rem; }
.dd-gok { margin-left: auto; color: var(--bs-success); }
.dd-card-meta { display: block; line-height: 1.35; }
.dd-card-meta .dd-none { color: var(--bs-secondary-color); font-style: italic; }
"

# Synchronised pan, shared zoom and an A/B flip. Delegated from `document` so it
# keeps working for panels Shiny inserts after load, and written against the
# DOM directly rather than pulling in a library.
viewer_js <- "
(function(){
  function panes(r){ return Array.prototype.slice.call(r.querySelectorAll('.dd-pane')); }
  function setZoom(r, z){
    z = Math.min(8, Math.max(0.02, z)); r.dataset.zoom = z;
    r.querySelectorAll('.dd-pane img').forEach(function(im){
      if (im.naturalWidth) im.style.width = (im.naturalWidth * z) + 'px';
    });
    var l = r.querySelector('.dd-zoomlab');
    if (l) l.textContent = Math.round(z * 100) + '%';
  }
  function fit(r){
    var p = r.querySelector('.dd-pane'), im = p && p.querySelector('img');
    if (im && im.naturalWidth && p.clientWidth) setZoom(r, p.clientWidth / im.naturalWidth);
  }
  // scroll does not bubble, hence capture.
  document.addEventListener('scroll', function(e){
    var el = e.target;
    if (!el.classList || !el.classList.contains('dd-pane')) return;
    var r = el.closest('.dd-viewer'); if (!r) return;
    panes(r).forEach(function(o){
      if (o !== el) { o.scrollTop = el.scrollTop; o.scrollLeft = el.scrollLeft; }
    });
  }, true);
  document.addEventListener('click', function(e){
    var b = e.target.closest('[data-dd]'); if (!b) return;
    var r = b.closest('.dd-viewer'); if (!r) return;
    var act = b.getAttribute('data-dd'), z = parseFloat(r.dataset.zoom || '1');
    if (act === 'in') setZoom(r, z * 1.5);
    else if (act === 'out') setZoom(r, z / 1.5);
    else if (act === 'one') setZoom(r, 1);
    else if (act === 'fit') fit(r);
    else if (act === 'blink') {
      r.classList.toggle('dd-blink');
      if (r.classList.contains('dd-blink')) {
        panes(r).forEach(function(x, i){ x.classList.toggle('dd-on', i === 0); });
      }
    } else if (act === 'flip') {
      var ps = panes(r), i = -1;
      ps.forEach(function(x, k){ if (x.classList.contains('dd-on')) i = k; });
      ps.forEach(function(x){ x.classList.remove('dd-on'); });
      ps[(i + 1) % ps.length].classList.add('dd-on');
    }
    if (act) e.preventDefault();
  });
  document.addEventListener('load', function(e){
    var im = e.target;
    if (im.tagName !== 'IMG' || !im.closest || !im.closest('.dd-pane')) return;
    var r = im.closest('.dd-viewer');
    if (r && !r.dataset.zoom) fit(r);
  }, true);

  // Moving the highlight from the client means the group list is rendered once
  // and not rebuilt on every selection, which is what keeps a long list usable.
  $(document).on('shiny:connected', function(){
    Shiny.addCustomMessageHandler('dd_current', function(gid){
      document.querySelectorAll('.dd-g-on').forEach(function(e){
        e.classList.remove('dd-g-on');
      });
      var el = document.getElementById('dd-g-' + gid);
      if (el) { el.classList.add('dd-g-on'); el.scrollIntoView({block: 'nearest'}); }
    });
    Shiny.addCustomMessageHandler('dd_quit', function(m){
      document.body.classList.add('dd-quit');
    });
  });
})();
"

ui <- page_sidebar(
  title = "dundee — duplicate review",
  tags$head(tags$style(HTML(viewer_css)), tags$script(HTML(viewer_js))),
  sidebar = sidebar(
    width = 320,
    div(
      class = "dd-side",
      actionButton("bulk", "Apply bulk heuristic to all", class = "btn-primary"),
      helpText("Bulk rules:", paste(cfg$preference_rules, collapse = " > ")),
      div(class = "my-1", textOutput("progress")),
      uiOutput("group_list", class = "dd-glist"),
      # After the flexing list, so it pins to the bottom of the sidebar and
      # stays reachable however long the list grows. Outline, not primary: it
      # must not compete with the bulk button above.
      div(class = "mt-2 pt-2 border-top",
          actionButton("quit", "Quit", class = "btn-sm btn-outline-secondary"))
    )
  ),
  card(
    card_header(textOutput("group_header")),
    uiOutput("members")
  ),
  uiOutput("viewer")
)

server <- function(input, output, session) {
  rv <- reactiveValues(groups = group_list(), current = NULL, tick = 0,
                       viewing = FALSE)

  observe({
    g <- rv$groups
    if (is.null(rv$current) && nrow(g) > 0) rv$current <- g$group_id[1]
  })

  # Deliberately does NOT depend on rv$current: the highlight is moved on the
  # client, so choosing a group never rebuilds the list.
  output$group_list <- renderUI({
    rv$tick
    g <- rv$groups
    if (nrow(g) == 0) return(p(class = "p-2", "No groups. Run analyze first."))
    rows <- lapply(seq_len(nrow(g)), function(i) {
      gid <- g$group_id[i]
      div(
        id = paste0("dd-g-", gid),
        class = paste("dd-g", if (identical(gid, rv$current)) "dd-g-on"),
        # One handler for the whole list, however many groups there are.
        onclick = sprintf(
          "Shiny.setInputValue('group_pick', %d, {priority: 'event'})", gid),
        span(class = "dd-gid", sprintf("Group %d", gid)),
        span(class = "dd-gmeta", sprintf("%s  n=%d", g$tier[i], g$n[i])),
        if (g$decided[i] > 0) span(class = "dd-gok", "✓")
      )
    })
    div(rows)
  })

  observeEvent(input$group_pick, {
    rv$current <- as.integer(input$group_pick)
    rv$viewing <- FALSE
  })

  observeEvent(rv$current, {
    session$sendCustomMessage("dd_current", rv$current)
  }, ignoreNULL = TRUE)

  observeEvent(input$quit, {
    # Everything here is inline and `p` is a plain local. Nothing may be
    # deferred into a callback: session$onFlushed() and friends run outside a
    # reactive context, where reading rv$... raises "Can't access reactive
    # value outside of reactive consumer". Shiny flushes both messages below
    # before it shuts down, so stopping here loses neither.
    p <- dd_review_progress(con)
    session$sendCustomMessage("dd_quit", TRUE)
    showModal(modalDialog(
      sprintf("Review app stopped -- %d of %d group(s) decided.",
              p$decided, p$groups),
      "Your decisions are saved. You can close this tab.",
      footer = NULL, easyClose = FALSE))
    stopApp(p)
  })

  observeEvent(input$bulk, {
    n <- dd_apply_bulk_decisions(con, cfg, overwrite = FALSE)
    rv$groups <- group_list(); rv$tick <- rv$tick + 1
    showNotification(sprintf("Applied bulk decisions to %d photos.", n))
  })

  output$progress <- renderText({
    rv$tick
    p <- dd_review_progress(con)
    sprintf("%d / %d groups decided", p$decided, p$groups)
  })

  output$group_header <- renderText({
    if (is.null(rv$current)) "" else paste("Group", rv$current)
  })

  # One read of each original per group, cached: metadata, thumbnail and the
  # full-size copy the viewer shows all come from it.
  detail_of <- reactive({
    gid <- rv$current
    if (is.null(gid)) return(NULL)
    rv$tick
    m <- group_members(gid)
    d <- withProgress(
      message = sprintf("Reading %d original(s)", nrow(m)), value = 0.5,
      dd_group_details(con, m, cfg))
    list(members = m, details = d, tbl = dd_member_table(m, d),
         tier = rv$groups$tier[match(gid, rv$groups$group_id)])
  })

  output$members <- renderUI({
    st <- detail_of()
    if (is.null(st)) return(NULL)
    m <- st$members; n <- nrow(m)
    cmp <- dd_compare_fields(st$tbl)
    ex <- dd_explain_preference(m, cfg)

    banner <- if (identical(st$tier, "near")) {
      div(class = "alert alert-info py-2",
          strong("near duplicate. "),
          "The pixels differ, so compare the images themselves.")
    } else {
      div(class = "alert alert-secondary py-2",
          strong("exact duplicate. "),
          "Decoded pixels are identical, so the images are the same picture. ",
          "Choose on metadata, location and where the file lives.")
    }

    thumbs <- layout_column_wrap(
      width = if (n <= 1) 1 else 1 / min(n, 3),
      !!!lapply(seq_len(n), function(i) {
        pid <- m$photo_id[i]
        is_pref <- !is.na(m$preferred[i]) && m$preferred[i] == 1
        card(
          class = if (is_pref) "border-success border-3" else "",
          card_header(
            actionButton(paste0("pref_", pid),
                         if (is_pref) "✓ Preferred" else "Mark preferred",
                         class = if (is_pref) "btn-success btn-sm"
                                 else "btn-outline-secondary btn-sm"),
            tags$small(class = "ms-2 text-muted", LETTERS[i])
          ),
          tags$img(src = sprintf("thumbs/%d.jpg", pid),
                   style = "max-width:100%;height:auto;"),
          tags$small(class = "text-muted dd-card-meta",
                     tags$div(m$rel_path[i]),
                     card_location(st$tbl, i),
                     card_date(st$tbl, i))
        )
      })
    )

    verdict <- if (any(!is.na(m$decided_by) & m$decided_by == "manual")) {
      div(class = "dd-same", "Chosen by you.")
    } else if (is.na(ex$rule)) {
      div(class = "alert alert-warning py-1 my-2",
          "⚠ No rule separated these copies — the preferred one was ",
          "picked by lowest photo_id. This choice is arbitrary.")
    } else {
      div(class = "dd-same",
          sprintf("Bulk chose %s on %s (%s).",
                  LETTERS[match(ex$winner, m$photo_id)], ex$rule, ex$detail))
    }

    # Each of these is on its own a reason to keep one copy, so they are lifted
    # out of the table rather than left as another row to notice.
    callout <- function(fld, msg) {
      r <- cmp[cmp$field == fld, , drop = FALSE]
      if (!nrow(r) || !r$differs || is.na(r$best)) return(NULL)
      div(class = "alert alert-success py-1 my-1",
          sprintf(msg, LETTERS[r$best]))
    }

    # Fields already under every thumbnail are not repeated here.
    on_card <- dd_compare_spec()$field[dd_compare_spec()$card]
    same <- cmp[!cmp$differs & !is.na(cmp$shared) &
                  !cmp$field %in% on_card, , drop = FALSE]
    same_txt <- if (nrow(same)) {
      paste(sprintf("%s %s", same$label,
                    mapply(dd_fmt_field, same$field, same$shared)),
            collapse = " · ")
    } else NULL

    diffs <- cmp[cmp$differs, , drop = FALSE]
    rows <- list()
    for (sec in section_order(st$tier)) {
      sub <- diffs[diffs$section == sec, , drop = FALSE]
      if (!nrow(sub)) next
      rows[[length(rows) + 1L]] <- tags$tr(
        tags$th(class = "dd-sec", colspan = n + 1, section_label[[sec]]))
      for (k in seq_len(nrow(sub))) {
        v <- sub$values[[k]]
        best <- sub$best[k]
        rows[[length(rows) + 1L]] <- tags$tr(
          tags$th(class = "dd-lab", sub$label[k]),
          lapply(seq_len(n), function(j) {
            tags$td(class = if (!is.na(best) && best == j) "dd-best" else NULL,
                    dd_fmt_field(sub$field[k], v[j]),
                    if (!is.na(best) && best == j)
                      tags$span(class = "dd-mark", " ◀"))
          })
        )
      }
    }

    tagList(
      banner,
      thumbs,
      div(class = "my-2",
          actionButton("compare", "Compare full size", class = "btn-sm btn-outline-primary"),
          span(class = "ms-2 dd-same",
               "Opens a movable, resizable viewer; the images are already local.")),
      verdict,
      callout("coords", "Only copy %s carries location data."),
      callout("makernotes",
              "Only copy %s keeps the camera's maker notes — it is the original, not a re-export."),
      if (!is.null(same_txt))
        div(class = "dd-same my-2", strong("Identical: "), same_txt),
      if (length(rows))
        tags$table(class = "dd-tbl",
                   tags$thead(tags$tr(tags$th(""),
                                      lapply(seq_len(n), function(j)
                                        tags$th(LETTERS[j])))),
                   tags$tbody(rows))
      else div(class = "dd-same my-2",
               "These copies are identical in every field dundee can read.")
    )
  })

  observeEvent(input$compare, { rv$viewing <- TRUE })
  observeEvent(input$viewer_close, { rv$viewing <- FALSE })

  output$viewer <- renderUI({
    if (!isTRUE(rv$viewing)) return(NULL)
    st <- detail_of()
    if (is.null(st)) return(NULL)
    d <- st$details
    have <- !is.na(d$viewer)
    if (!any(have)) {
      return(absolutePanel(
        top = 80, left = 60, draggable = TRUE, class = "dd-viewer",
        div(class = "dd-head", strong("Full-size comparison"),
            actionButton("viewer_close", "Close", class = "btn-sm btn-light ms-auto")),
        div(class = "p-3",
            "No full-size copies are available. Either review_cache is 0, or ",
            "the originals could not be read or converted for display.")))
    }
    absolutePanel(
      top = 80, left = 60, draggable = TRUE, class = "dd-viewer",
      div(class = "dd-head",
          strong("Full-size comparison"),
          tags$button("-", class = "btn btn-sm btn-outline-secondary", `data-dd` = "out"),
          tags$span(class = "dd-zoomlab dd-same", "100%"),
          tags$button("+", class = "btn btn-sm btn-outline-secondary", `data-dd` = "in"),
          tags$button("1:1", class = "btn btn-sm btn-outline-secondary", `data-dd` = "one"),
          tags$button("Fit", class = "btn btn-sm btn-outline-secondary", `data-dd` = "fit"),
          tags$button("A/B", class = "btn btn-sm btn-outline-primary", `data-dd` = "blink",
                      title = "Show one at a time, in the same spot"),
          tags$button("Flip", class = "btn btn-sm btn-outline-primary", `data-dd` = "flip"),
          actionButton("viewer_close", "Close", class = "btn-sm btn-light ms-auto")),
      div(class = "dd-panes",
          lapply(which(have), function(i) {
            div(class = paste("dd-pane", if (i == which(have)[1]) "dd-on" else ""),
                span(class = "dd-cap", LETTERS[i]),
                tags$img(src = paste0("originals/", basename(d$viewer[i]))))
          }))
    )
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
