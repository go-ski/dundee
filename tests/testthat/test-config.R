# Config loading under the work-dir-as-project layout.

# Helper: build an initialised work directory without invoking an editor.
new_work <- function(..., lib = NULL) {
  wd <- tempfile("work-")
  dir.create(wd)
  kv <- list(...)
  lines <- c(if (!is.null(lib)) sprintf("library_root: %s", lib),
             vapply(names(kv), function(k) sprintf("%s: %s", k, kv[[k]]),
                    character(1)))
  writeLines(lines, file.path(wd, "config.yml"))
  wd
}

test_that("a work directory is a valid config handle", {
  wd <- new_work(db_path = "e2e.sqlite")
  cfg <- dd_config(wd)
  expect_equal(cfg$work_dir, dd_resolve_path(wd))
  expect_equal(cfg$config_file, file.path(dd_resolve_path(wd), "config.yml"))
  expect_equal(cfg$db_path, file.path(cfg$work_dir, "e2e.sqlite"))
  expect_equal(cfg$temp_dir, file.path(cfg$work_dir, "tmp"))
  expect_equal(cfg$staging_dir, file.path(cfg$work_dir, "staging"))
  expect_equal(cfg$thumb_dir, file.path(cfg$work_dir, "thumbs"))
})

test_that("passing <work_dir>/config.yml is equivalent and silent", {
  wd <- new_work()
  expect_silent(cfg <- dd_config(file.path(wd, "config.yml")))
  expect_equal(cfg$work_dir, dd_resolve_path(wd))
})

test_that("an absolute db_path is reduced to its basename under work_dir", {
  wd <- new_work(db_path = "/elsewhere/custom.sqlite")
  cfg <- dd_config(wd)
  expect_equal(cfg$db_path, file.path(cfg$work_dir, "custom.sqlite"))
})

test_that("the work directory is the config's own directory, always", {
  # A project is a directory, so there is nothing to configure and nothing to
  # keep in step. Any work_dir: in the file is inert.
  wd <- tempfile("work-"); dir.create(wd)
  writeLines(sprintf("work_dir: %s", tempfile("elsewhere-")),
             file.path(wd, "config.yml"))
  expect_silent(cfg <- dd_config(wd))
  expect_equal(cfg$work_dir, dd_resolve_path(wd))
  expect_equal(cfg$temp_dir, file.path(cfg$work_dir, "tmp"))
})


test_that("work_dir nested inside library_root is rejected", {
  root <- tempfile("lib-"); dir.create(root)
  wd <- file.path(root, "work"); dir.create(wd)
  writeLines(sprintf("library_root: %s", root), file.path(wd, "config.yml"))
  expect_error(dd_config(wd), "work_dir must not be")
})

test_that("library_root nested inside work_dir is rejected", {
  wd <- tempfile("work-"); dir.create(wd)
  dir.create(file.path(wd, "lib"))
  writeLines(sprintf("library_root: %s", file.path(wd, "lib")),
             file.path(wd, "config.yml"))
  expect_error(dd_config(wd), "work_dir must not be")
})

test_that("disjoint library_root and work_dir resolve, and a missing library errors", {
  root <- tempfile("lib-"); dir.create(root)
  wd <- new_work(lib = root)
  cfg <- dd_config(wd, require_library = TRUE)
  expect_equal(cfg$library_root, dd_resolve_path(root))

  gone <- new_work(lib = file.path(tempdir(), "definitely-not-mounted"))
  expect_error(dd_config(gone, require_library = TRUE), "does not exist")
})

test_that("unknown keys warn with a suggestion, and are not silently used", {
  wd <- new_work(hamming_thresold = 12)
  expect_warning(cfg <- dd_config(wd), "hamming_thresold.*did you mean")
  expect_equal(cfg$hamming_threshold,
               dd_config_defaults()$hamming_threshold)   # default, not 12
})

test_that("out-of-range and inconsistent tuning values are rejected together", {
  wd <- new_work(parallel = 0, lsh_bands = 7)
  err <- expect_error(dd_config(wd))
  expect_match(conditionMessage(err), "parallel")
  expect_match(conditionMessage(err), "lsh_bands")

  bad <- new_work(preference_rules = "[biggest_file]")
  expect_error(dd_config(bad), "unknown preference_rules")

  huge <- new_work(hamming_threshold = 999)
  expect_error(dd_config(huge), "hamming_threshold")
})

test_that("an empty value falls back to the default rather than emptying a field", {
  wd <- tempfile("work-"); dir.create(wd)
  writeLines(c("extensions:", "db_path: x.sqlite"), file.path(wd, "config.yml"))
  cfg <- dd_config(wd)
  expect_true(length(cfg$extensions) > 0L)
  expect_true("jpg" %in% cfg$extensions)
})

test_that("dd_config does not create directories when create = FALSE", {
  wd <- file.path(tempfile("outer-"), "never-made")
  dir.create(dirname(wd), recursive = TRUE)
  dir.create(wd)
  writeLines("db_path: a.sqlite", file.path(wd, "config.yml"))
  cfg <- dd_config(wd, create = FALSE)
  expect_false(dir.exists(cfg$temp_dir))   # derived dirs are stage-created
})

test_that("dd_resolve_path is absolute, symlink-resolved, and non-mutating", {
  p <- file.path(tempfile("nope-"), "deeper", "still")
  r <- dd_resolve_path(p)
  expect_true(startsWith(r, "/"))
  expect_false(dir.exists(r))
  expect_equal(dd_resolve_path(r), r)      # idempotent
})

test_that("dd_use sets the session default and dd_work_dir finds it", {
  wd <- new_work()
  old <- getOption("dundee.work_dir")
  on.exit(options(dundee.work_dir = old), add = TRUE)
  expect_message(dd_use(wd), "using")
  expect_equal(dd_work_dir(), dd_resolve_path(wd))
  expect_equal(dd_config()$work_dir, dd_resolve_path(wd))
  expect_error(dd_use(tempfile("absent-")), "no config.yml")
})

test_that("dd_init writes a template that loads cleanly", {
  skip_if(inherits(try(dd_template_lines(), silent = TRUE), "try-error"),
          "config template not reachable in this run mode")
  root <- tempfile("lib-"); dir.create(root)
  wd <- tempfile("work-")
  cfg <- dd_init(wd, library_root = root)
  expect_true(file.exists(file.path(wd, "config.yml")))
  expect_equal(cfg$library_root, dd_resolve_path(root))
  expect_false(any(grepl("^work_dir:", readLines(file.path(wd, "config.yml")))))

  # second call leaves the edited file alone (edit in place: appending a key
  # that the template already defines is a YAML duplicate-key error)
  f <- file.path(wd, "config.yml")
  writeLines(sub("^hamming_threshold:.*$", "hamming_threshold: 2",
                 readLines(f)), f)
  expect_message(cfg2 <- dd_init(wd), "already exists")
  expect_equal(cfg2$hamming_threshold, 2L)

  # overwrite = TRUE resets the file but archives what was there. Compared
  # against the template dd_init() actually reached, not against the defaults:
  # dd_template_lines() prefers the installed copy, so asserting the default
  # here would fail on a stale install rather than on a real disagreement.
  # That the template and the defaults agree is its own test, below.
  tmpl_thr <- as.integer(sub("^hamming_threshold:\\s*", "",
    grep("^hamming_threshold:", dd_template_lines(), value = TRUE)[[1]]))
  cfg3 <- dd_init(wd, library_root = root, overwrite = TRUE)
  expect_equal(cfg3$hamming_threshold, tmpl_thr)
  expect_true(length(list.files(file.path(wd, "config.history"))) >= 1L)
})

test_that("the resolved snapshot round-trips without warnings", {
  wd <- new_work(db_path = "s.sqlite")
  cfg <- dd_config(wd)
  out <- dd_config_snapshot(cfg)
  expect_true(file.exists(out))
  expect_silent(back <- dd_config(out))
  expect_equal(back$work_dir, cfg$work_dir)
  expect_equal(back$db_path, cfg$db_path)
})

test_that("the store guard catches a changed fingerprint grid or library root", {
  root <- tempfile("lib-"); dir.create(root)
  wd <- new_work(lib = root, fingerprint_grid = 8)
  cfg <- dd_config(wd)
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  expect_true(dd_config_guard(con, cfg))
  expect_true(dd_config_guard(con, cfg))          # idempotent

  cfg2 <- cfg; cfg2$fingerprint_grid <- 16L
  expect_error(dd_config_guard(con, cfg2), "fingerprint_grid")

  root2 <- tempfile("lib2-"); dir.create(root2)
  cfg3 <- cfg; cfg3$library_root <- dd_resolve_path(root2)
  expect_error(dd_config_guard(con, cfg3), "library_root")
  expect_true(dd_config_guard(con, cfg3, rebase = TRUE))
})

test_that("the case probe writes nothing into the directory it tests", {
  # library_root is mounted read-only, and probing it must not move its mtime,
  # so the probe may not create a scratch file even a self-deleting one.
  d <- tempfile("probe-"); dir.create(d)
  file.create(file.path(d, "Photo.jpg"))
  before <- list.files(d, all.files = TRUE, no.. = TRUE)
  mtime_before <- file.mtime(d)

  rm(list = ls(dd_case_cache), envir = dd_case_cache)   # defeat memoisation
  res <- dd_fs_case_insensitive(d)

  expect_type(res, "logical")
  expect_equal(list.files(d, all.files = TRUE, no.. = TRUE), before)
  expect_equal(file.mtime(d), mtime_before)
})

test_that("the case probe detects a case-sensitive filesystem", {
  d <- tempfile("probe-"); dir.create(d)
  # Two entries differing only in case can only coexist when case matters.
  ok <- file.create(file.path(d, "Photo.jpg")) &&
    isTRUE(suppressWarnings(file.create(file.path(d, "photo.jpg")))) &&
    length(list.files(d)) == 2L
  skip_if_not(ok, "this filesystem is case-insensitive")
  rm(list = ls(dd_case_cache), envir = dd_case_cache)
  expect_false(dd_fs_case_insensitive(d))
})

test_that("rebase rewrites stored paths onto the new library root", {
  old <- tempfile("lib-old-"); dir.create(old)
  new <- tempfile("lib-new-"); dir.create(new)
  wd <- new_work(lib = old)
  cfg <- dd_config(wd)
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  expect_true(dd_config_guard(con, cfg))

  DBI::dbExecute(con, "INSERT INTO photos(path, rel_path) VALUES(?, 'a.jpg')",
                 params = list(file.path(cfg$library_root, "a.jpg")))
  DBI::dbExecute(con, "INSERT INTO errors(path, reason) VALUES(?, 'x')",
                 params = list(file.path(cfg$library_root, "b.jpg")))

  moved <- cfg; moved$library_root <- dd_resolve_path(new)
  expect_error(dd_config_guard(con, moved), "library_root")
  expect_message(dd_config_guard(con, moved, rebase = TRUE), "rebased 2")

  expect_equal(DBI::dbGetQuery(con, "SELECT path FROM photos")$path,
               file.path(moved$library_root, "a.jpg"))
  expect_equal(DBI::dbGetQuery(con, "SELECT path FROM errors")$path,
               file.path(moved$library_root, "b.jpg"))
  # and the guard is satisfied from now on
  expect_true(dd_config_guard(con, moved))
})

test_that("the shipped template agrees with the built-in defaults", {
  # dd_init() hands a new project the template; a config that omits a key gets
  # the default. They drifted once -- R/config.R moved to grid 16 / threshold 3
  # / bands 16 while the template still said 8 / 5 / 8 -- so the two kinds of
  # user got different near-duplicate behaviour and nothing noticed.
  #
  # Source tree first, installed copy second: under dev-test.R the repo is what
  # matters, under R CMD check the installed template is the one that ships.
  # (dd_template_lines() prefers the installed copy, which is why this does not
  # use it -- a stale install would make the check meaningless.)
  path <- NULL
  for (p in c("../../inst/templates/config.yml",
              system.file("templates", "config.yml", package = "dundee"))) {
    if (nzchar(p) && file.exists(p)) { path <- p; break }
  }
  skip_if(is.null(path), "config template not reachable in this run mode")

  tmpl <- yaml::read_yaml(path)
  defaults <- dd_config_defaults()
  # The template fills these in as examples; the defaults leave them NULL, so
  # they are the one place the two are meant to disagree.
  placeholders <- c("library_root", "preferred_root", "nonpreferred_root")

  # Compared as character: it makes `folder_priority: []` (NULL from YAML) and
  # character(0) the same empty vector, and sidesteps YAML integer-vs-double.
  flat <- function(x) as.character(unlist(x))
  # cruft is the one key that legitimately differs: the template's phase 3
  # destinations live under `_dedup`, and unless enumeration prunes it the next
  # inventory files every moved photo as a new one. The built-in default stays
  # as it was -- widening it would report drift against every existing store --
  # so assert the exact relationship rather than excusing the key entirely.
  expect_equal(flat(tmpl$cruft), c(flat(defaults$cruft), "_dedup"))
  for (key in setdiff(names(tmpl), c(placeholders, "cruft"))) {
    expect_equal(flat(tmpl[[key]]), flat(defaults[[key]]),
                 info = paste("template key:", key))
  }
  # And the template's own destinations must be prunable by its own cruft, or
  # the advice it gives is wrong on the file that gives it.
  expect_true(any(vapply(c(tmpl$preferred_root, tmpl$nonpreferred_root),
                         function(p) any(strsplit(p, "/", fixed = TRUE)[[1]]
                                         %in% tmpl$cruft), logical(1))))
})

test_that("dd_status reports an empty project and names the next step", {
  wd <- new_work()
  expect_message(dd_status(wd), "store not created yet")
  cfg <- dd_config(wd)
  con <- dd_db_connect(cfg); dd_db_init(con); DBI::dbDisconnect(con)
  out <- dd_status(wd)
  expect_equal(out$photos, 0L)
})
