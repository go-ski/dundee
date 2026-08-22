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

test_that("quitting stops the app, and only after the modal is flushed", {
  # Ordering is the whole point: stopApp() called directly drops the websocket
  # mid-flush and the reviewer gets Shiny's grey disconnect overlay instead of
  # the modal -- a deliberate quit that reads as a crash.
  app <- app_file(); skip_if(is.null(app), "app.R not reachable")
  body <- observer_body(app, "quit")
  expect_false(is.null(body))
  used <- calls_in(body)
  expect_true("showModal" %in% used)
  expect_true("onFlushed" %in% used)
  # stopApp is reached through onFlushed's callback, never at observer level.
  expect_true("stopApp" %in% used)
  direct <- Filter(function(e) {
    is.call(e) && is.name(e[[1]]) && identical(as.character(e[[1]]), "stopApp")
  }, as.list(body))
  expect_length(direct, 0L)
})

test_that("quitting hands back the review summary", {
  s <- app_store()
  old <- Sys.getenv("DUNDEE_CONFIG", unset = NA)
  on.exit({
    if (is.na(old)) Sys.unsetenv("DUNDEE_CONFIG") else
      Sys.setenv(DUNDEE_CONFIG = old)
  }, add = TRUE)
  Sys.setenv(DUNDEE_CONFIG = s$resolved)

  shiny::testServer(dirname(app_file()), {
    session$setInputs(quit = 1)
    # The fixture builds two groups (one per tier) and decides neither.
    expect_equal(rv$exit, list(decided = 0L, groups = 2L))
    expect_silent(session$flushReact())       # the onFlushed callback runs
  })
})
