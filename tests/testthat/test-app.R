# inst/shiny/app.R is the one file R CMD check never sources, and runApp()
# sources it with only library(dundee) attached -- exports and nothing else --
# while the suite itself runs inside the package namespace, where every internal
# resolves. So an app calling an unexported function passes every check and
# fails on every group render. These tests close that gap from both sides.

# Prefer the source tree, fall back to the installed copy: under dev-test.R the
# repo is what matters, under R CMD check only the installed package exists.
first_path <- function(...) {
  for (p in c(...)) if (nzchar(p) && file.exists(p)) return(p)
  NULL
}
app_file <- function() {
  first_path("../../inst/shiny/app.R", system.file("shiny", "app.R",
                                                   package = "dundee"))
}
namespace_file <- function() {
  first_path("../../NAMESPACE", system.file("NAMESPACE", package = "dundee"))
}

# Every symbol used in call position, anywhere in the file.
called_functions <- function(path) {
  acc <- new.env(parent = emptyenv())
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    if (is.name(e[[1]])) assign(as.character(e[[1]]), TRUE, envir = acc)
    for (i in seq_along(e)) {
      # A call can hold missing arguments (x[, 1]), which error on access.
      tryCatch(if (!is.null(e[[i]])) walk(e[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  for (ex in parse(path)) walk(ex)
  ls(acc)
}

test_that("every dundee function the review app calls is exported", {
  app <- app_file(); ns <- namespace_file()
  skip_if(is.null(app) || is.null(ns), "app.R or NAMESPACE not reachable")

  # Reads the NAMESPACE file rather than the loaded namespace, so this behaves
  # identically under dev-test.R (which sources R/ into globalenv) and under
  # R CMD check.
  exported <- sub("^export\\((.*)\\)$", "\\1",
                  grep("^export\\(", readLines(ns), value = TRUE))
  defined <- unlist(lapply(parse(app), function(e) {
    if (is.call(e) && length(e) >= 3L &&
        as.character(e[[1]]) %in% c("<-", "=") && is.name(e[[2]])) {
      as.character(e[[2]])
    }
  }))
  used <- setdiff(grep("^dd_", called_functions(app), value = TRUE), defined)

  expect_true(length(used) > 0L)          # the walk found something at all
  expect_equal(setdiff(used, exported), character(0))
})

# --- and that the app actually renders -------------------------------------

app_store <- function() {
  skip_on_os("windows")
  for (t in c("exiftool", "vips", "vipsthumbnail")) {
    skip_if(!nzchar(Sys.which(t)), paste("no", t, "on PATH"))
  }
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")

  wd <- tempfile("work-"); dir.create(wd)
  lib <- tempfile("lib-"); dir.create(lib)
  writeLines(c(sprintf("library_root: %s", lib), "db_path: app.sqlite"),
             file.path(wd, "config.yml"))
  cfg <- dd_config(wd, require_library = FALSE)
  con <- dd_db_connect(cfg); dd_db_init(con)

  # Two copies of one picture that differ in quality, so the comparison table
  # has rows to render rather than collapsing to nothing.
  ok <- TRUE
  for (i in 1:2) {
    p <- file.path(lib, sprintf("p%d.jpg", i))
    system2("vips", c("black", shQuote(p), "64", "48", "--bands", "3"),
            stdout = FALSE, stderr = FALSE)
    if (!file.exists(p)) { ok <- FALSE; break }
    system2("exiftool", c("-overwrite_original", "-q", "-m",
                          shQuote(c(sprintf("-Model=Cam%d", i),
                                    "-DateTimeOriginal=2019:07:04 10:00:00",
                                    "-GPSLatitude=36.0165", "-GPSLatitudeRef=N",
                                    "-GPSLongitude=84.2612", "-GPSLongitudeRef=W")),
                          shQuote(p)), stdout = FALSE, stderr = FALSE)
    fi <- file.info(p)
    DBI::dbExecute(con,
      "INSERT INTO photos(path, rel_path, size, mtime, width, height, format,
                          meta_count, capture_time)
       VALUES(?, ?, ?, ?, 64, 48, 'jpegload', ?, '2019:07:04 10:00:00')",
      params = list(p, basename(p), as.integer(fi$size), as.integer(fi$mtime),
                    10L + i))
  }
  if (!ok) { DBI::dbDisconnect(con); skip("vips could not write the fixtures") }

  ids <- DBI::dbGetQuery(con, "SELECT photo_id FROM photos ORDER BY photo_id")
  for (tier in c("exact", "near")) {
    gid <- if (identical(tier, "exact")) 1L else 2L
    for (pid in ids$photo_id) {
      DBI::dbExecute(con, "INSERT INTO groups(group_id, photo_id, tier)
                           VALUES(?, ?, ?)", params = list(gid, pid, tier))
    }
  }
  DBI::dbDisconnect(con)

  # dd_app() points DUNDEE_CONFIG at a resolved snapshot; dd_config() accepts a
  # config path just as happily, and an absolute one is all that matters here --
  # testServer(), like runApp(), has already changed the working directory.
  list(cfg = cfg, resolved = file.path(cfg$work_dir, "config.yml"))
}

test_that("a group renders through the real app server", {
  # The failure this catches is invisible under dev-test.R, where sourcing R/
  # into globalenv makes every internal reachable. Only R CMD check, which
  # installs the package first, exercises app.R's real visibility.
  s <- app_store()
  old <- Sys.getenv("DUNDEE_CONFIG", unset = NA)
  on.exit({
    if (is.na(old)) Sys.unsetenv("DUNDEE_CONFIG") else
      Sys.setenv(DUNDEE_CONFIG = old)
  }, add = TRUE)
  Sys.setenv(DUNDEE_CONFIG = s$resolved)

  shiny::testServer(dirname(app_file()), {
    # Both tiers, because section_order() orders the table differently for each.
    for (gid in c(1L, 2L)) {
      session$setInputs(group_pick = gid)
      html <- as.character(output$members$html)
      expect_true(nzchar(html))
      expect_match(html, "p1.jpg", fixed = TRUE)
      expect_match(html, "36.01650", fixed = TRUE)   # the card's coordinates
    }
    expect_match(as.character(output$group_list$html), "dd-g-1", fixed = TRUE)
  })
})

# --- the Quit button --------------------------------------------------------

# stopApp() is inert under testServer(): it fires, execution continues, and its
# value is discarded. So "the button really stops the app" cannot be asserted
# dynamically and is checked against the parse tree instead -- the same tool
# this file already uses for the visibility gap above.

# Body of the observeEvent() whose first argument is `input$<name>`.
observer_body <- function(path, name) {
  found <- NULL
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    if (is.name(e[[1]]) && identical(as.character(e[[1]]), "observeEvent") &&
        length(e) >= 3L) {
      ev <- e[[2]]
      if (is.call(ev) && identical(as.character(ev[[1]]), "$") &&
          identical(as.character(ev[[2]]), "input") &&
          identical(as.character(ev[[3]]), name)) {
        found <<- e[[3]]
      }
    }
    for (i in seq_along(e)) {
      tryCatch(if (!is.null(e[[i]])) walk(e[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  for (ex in parse(path)) walk(ex)
  found
}

# Names of everything called inside `e`, counting `session$onFlushed()` as
# "onFlushed": the callee there is a `$` call, not a symbol.
calls_in <- function(e) {
  acc <- character()
  walk <- function(x) {
    if (!is.call(x)) return(invisible(NULL))
    fn <- x[[1]]
    if (is.name(fn)) {
      acc <<- c(acc, as.character(fn))
    } else if (is.call(fn) && identical(as.character(fn[[1]]), "$")) {
      acc <<- c(acc, as.character(fn[[3]]))
    }
    for (i in seq_along(x)) {
      tryCatch(if (!is.null(x[[i]])) walk(x[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  walk(e)
  unique(acc)
}

test_that("the sidebar offers a Quit button", {
  app <- app_file(); skip_if(is.null(app), "app.R not reachable")
  ids <- unlist(lapply(parse(app), function(e) {
    out <- character()
    walk <- function(x) {
      if (!is.call(x)) return(invisible(NULL))
      if (is.name(x[[1]]) && identical(as.character(x[[1]]), "actionButton") &&
          length(x) >= 2L && is.character(x[[2]])) out <<- c(out, x[[2]])
      for (i in seq_along(x)) {
        tryCatch(if (!is.null(x[[i]])) walk(x[[i]]), error = function(...) NULL)
      }
      invisible(NULL)
    }
    walk(e); out
  }))
  expect_true("quit" %in% ids)
})

test_that("quitting stops the app inline, with no deferred callback", {
  # The shipped version deferred through session$onFlushed(), whose callback
  # runs outside a reactive context -- see the guard below. Stopping inline is
  # not merely simpler: Shiny flushes the modal and the custom message before
  # shutting down either way, measured against a real session.
  app <- app_file(); skip_if(is.null(app), "app.R not reachable")
  body <- observer_body(app, "quit")
  expect_false(is.null(body))
  used <- calls_in(body)
  expect_true(all(c("showModal", "stopApp", "sendCustomMessage") %in% used))
  expect_false("onFlushed" %in% used)
})

# The rule this file exists to enforce, in its newest shape: testServer()'s
# MockShinySession fires deferred callbacks AND allows reactive reads inside
# them, while a real ShinySession raises "Can't access reactive value outside
# of reactive consumer". So no dynamic test can catch a reactive read in a
# deferred callback, and the parse tree is the only place to forbid it.
deferred_ctors <- c("onFlushed", "onSessionEnded", "onEnded", "onStop", "later")

# Names bound from reactiveValues(...), so the guard follows a rename.
reactive_names <- function(path) {
  out <- character()
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    if (is.name(e[[1]]) && as.character(e[[1]]) %in% c("<-", "=") &&
        is.name(e[[2]]) && is.call(e[[3]]) && is.name(e[[3]][[1]]) &&
        identical(as.character(e[[3]][[1]]), "reactiveValues")) {
      out <<- c(out, as.character(e[[2]]))
    }
    for (i in seq_along(e)) {
      tryCatch(if (!is.null(e[[i]])) walk(e[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  for (ex in parse(path)) walk(ex)
  unique(out)
}

# Every function literal handed to one of deferred_ctors.
deferred_callbacks <- function(path) {
  out <- list()
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    fn <- e[[1]]
    nm <- if (is.name(fn)) as.character(fn) else
      if (is.call(fn) && identical(as.character(fn[[1]]), "$"))
        as.character(fn[[3]]) else ""
    if (nm %in% deferred_ctors) {
      for (i in seq_along(e)[-1]) {
        a <- tryCatch(e[[i]], error = function(...) NULL)
        if (is.call(a) && is.name(a[[1]]) &&
            identical(as.character(a[[1]]), "function")) {
          out[[length(out) + 1L]] <<- list(ctor = nm, body = a)
        }
      }
    }
    for (i in seq_along(e)) {
      tryCatch(if (!is.null(e[[i]])) walk(e[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  for (ex in parse(path)) walk(ex)
  out
}

symbols_in <- function(e) {
  acc <- character()
  walk <- function(x) {
    if (is.name(x)) { acc <<- c(acc, as.character(x)); return(invisible(NULL)) }
    if (!is.call(x) && !is.pairlist(x)) return(invisible(NULL))
    for (i in seq_along(x)) {
      tryCatch(if (!is.null(x[[i]])) walk(x[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  walk(e)
  unique(acc)
}

test_that("no deferred callback reads a reactive value", {
  # This is the bug that shipped: stopApp(rv$exit) inside session$onFlushed().
  app <- app_file(); skip_if(is.null(app), "app.R not reachable")
  rnames <- reactive_names(app)
  expect_true(length(rnames) > 0L)          # the walk found reactiveValues at all

  cbs <- deferred_callbacks(app)
  expect_true(length(cbs) > 0L)             # and found callbacks to check
  for (cb in cbs) {
    expect_equal(intersect(symbols_in(cb$body), rnames), character(0),
                 info = paste("reactive read inside", cb$ctor, "callback"))
  }
})
