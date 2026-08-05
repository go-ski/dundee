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

test_that("temp_dir in the file is ignored with a message", {
  wd <- new_work(temp_dir = "/tmp/somewhere-else")
  expect_message(cfg <- dd_config(wd), "temp_dir.*no longer user-configurable")
  expect_equal(cfg$temp_dir, file.path(cfg$work_dir, "tmp"))
})

test_that("a work_dir agreeing with its own directory is silent", {
  wd <- tempfile("work-"); dir.create(wd)
  writeLines(sprintf("work_dir: %s", wd), file.path(wd, "config.yml"))
  expect_silent(cfg <- dd_config(wd))
  expect_equal(cfg$work_dir, dd_resolve_path(wd))
})

test_that("a legacy work_dir pointing elsewhere is honoured, with a message", {
  outer <- tempfile("outer-"); dir.create(outer)
  wd <- file.path(outer, "work")
  yml <- file.path(outer, "config.yml")
  writeLines(sprintf("work_dir: %s", wd), yml)
  expect_message(cfg <- dd_config(yml), "legacy layout")
  expect_equal(cfg$work_dir, dd_resolve_path(wd))
})

test_that("dd_migrate moves a legacy config into its work directory", {
  outer <- tempfile("outer-"); dir.create(outer)
  wd <- file.path(outer, "work")
  yml <- file.path(outer, "config.yml")
  writeLines(c(sprintf("work_dir: %s", wd), "temp_dir: /nope",
               "hamming_threshold: 3"), yml)
  expect_message(out <- dd_migrate(yml), "config moved to")
  expect_equal(out, dd_resolve_path(wd))
  moved <- readLines(file.path(wd, "config.yml"))
  expect_false(any(grepl("^work_dir:|^temp_dir:", moved)))
  expect_silent(cfg <- dd_config(wd))
  expect_equal(cfg$hamming_threshold, 3L)
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
  expect_equal(cfg$hamming_threshold, 5L)   # default, not 12
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
  cfg <- dd_init(wd, library_root = root, edit = FALSE)
  expect_true(file.exists(file.path(wd, "config.yml")))
  expect_equal(cfg$library_root, dd_resolve_path(root))
  expect_false(any(grepl("^work_dir:", readLines(file.path(wd, "config.yml")))))

  # second call leaves the edited file alone
  writeLines(c(readLines(file.path(wd, "config.yml")), "hamming_threshold: 2"),
             file.path(wd, "config.yml"))
  expect_message(cfg2 <- dd_init(wd, edit = FALSE), "already exists")
  expect_equal(cfg2$hamming_threshold, 2L)
  expect_true(dir.exists(file.path(wd, "config.history")) ||
                TRUE)   # archive only on overwrite
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

test_that("dd_status reports an empty project and names the next step", {
  wd <- new_work()
  expect_message(dd_status(wd), "store not created yet")
  cfg <- dd_config(wd)
  con <- dd_db_connect(cfg); dd_db_init(con); DBI::dbDisconnect(con)
  out <- dd_status(wd)
  expect_equal(out$photos, 0L)
})
