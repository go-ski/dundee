# A dundee work directory is meant to be hand-edited -- dd_init() says so. But
# nothing recorded what a stage had run under, so dd_status() reported a next
# step computed entirely from row counts: change hamming_threshold and it still
# recommended dd_run_move() against groups built at the old value.

drift_store <- function() {
  cfg <- dd_config_defaults()
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  cfg$library_root <- cfg$work_dir           # never read; only stamped
  con <- dd_db_connect(cfg); dd_db_init(con)
  list(cfg = cfg, con = con)
}

test_that("a stamp records the keys its stage consumes, and nothing else", {
  s <- drift_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  dd_stage_stamp(s$con, "analyze", s$cfg)

  was <- dd_stamp_parse(dd_meta_get(s$con, "stamp_analyze"))
  expect_setequal(names(was), dd_stage_keys$analyze)
  expect_equal(was[["hamming_threshold"]],
               as.character(s$cfg$hamming_threshold))
  expect_false("parallel" %in% names(was))
})

test_that("an unchanged config drifts not at all", {
  s <- drift_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  for (stage in names(dd_stage_keys)) dd_stage_stamp(s$con, stage, s$cfg)
  expect_equal(nrow(dd_config_drift(s$con, s$cfg)), 0L)
})

test_that("editing a key names it, the stage, and both values", {
  s <- drift_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  dd_stage_stamp(s$con, "analyze", s$cfg)

  # Derived, not hardcoded: any literal here becomes the default sooner or later
  # and then edits nothing.
  was_thr <- s$cfg$hamming_threshold
  s$cfg$hamming_threshold <- was_thr + 4L
  dr <- dd_config_drift(s$con, s$cfg)
  expect_equal(nrow(dr), 1L)
  expect_equal(dr$stage, "analyze")
  expect_equal(dr$key, "hamming_threshold")
  expect_equal(dr$was, as.character(was_thr))
  expect_equal(dr$now, as.character(was_thr + 4L))
})

test_that("a stage that never ran reports no drift", {
  # An absent stamp means "never run under a recorded config", which is not the
  # same as "changed" -- claiming drift there would nag about work never done.
  s <- drift_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  dd_stage_stamp(s$con, "analyze", s$cfg)
  s$cfg$hamming_threshold <- s$cfg$hamming_threshold + 4L
  s$cfg$preference_rules <- "max_meta"       # decide never ran
  dr <- dd_config_drift(s$con, s$cfg)
  expect_equal(dr$stage, "analyze")
})

test_that("keys no stage consumes never count as drift", {
  s <- drift_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  for (stage in names(dd_stage_keys)) dd_stage_stamp(s$con, stage, s$cfg)
  s$cfg$parallel <- 16L
  s$cfg$review_cache <- 0L
  s$cfg$db_path <- file.path(s$cfg$work_dir, "other.sqlite")
  expect_equal(nrow(dd_config_drift(s$con, s$cfg)), 0L)
})

test_that("vector-valued keys compare by content, not by identity", {
  s <- drift_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  dd_stage_stamp(s$con, "inventory", s$cfg)
  s$cfg$extensions <- rev(rev(s$cfg$extensions))     # same content
  expect_equal(nrow(dd_config_drift(s$con, s$cfg)), 0L)

  s$cfg$extensions <- setdiff(s$cfg$extensions, "png")
  dr <- dd_config_drift(s$con, s$cfg)
  expect_equal(dr$key, "extensions")
})

test_that("an empty vector round-trips without inventing drift", {
  # folder_priority defaults to character(0). Stamping it as YAML would read
  # back as list(), which compares unequal to character(0) every single time.
  s <- drift_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  expect_equal(s$cfg$folder_priority, character(0))
  dd_stage_stamp(s$con, "decide", s$cfg)
  expect_equal(nrow(dd_config_drift(s$con, s$cfg)), 0L)
})

test_that("a stamp lives in the store, not the session", {
  s <- drift_store()
  dd_stage_stamp(s$con, "analyze", s$cfg)
  DBI::dbDisconnect(s$con)

  con <- dd_db_connect(s$cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  s$cfg$lsh_bands <- 4L
  expect_equal(dd_config_drift(con, s$cfg)$key, "lsh_bands")
})

# --- what dd_status() does with it ------------------------------------------

status_cfg <- function() {
  cfg <- dd_config_defaults()
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  cfg
}

seed_pipeline <- function(cfg) {
  con <- dd_db_connect(cfg); dd_db_init(con)
  for (i in 1:2) {
    DBI::dbExecute(con,
      "INSERT INTO photos(path, rel_path, size, width, height, meta_count,
                          pixel_hash, fingerprint)
       VALUES(?, ?, 100, 10, 10, 5, 'SAME', '0f0f0f0f0f0f0f0f')",
      params = list(sprintf("/l/p%d.jpg", i), sprintf("p%d.jpg", i)))
  }
  dd_analyze(con, cfg, quiet = TRUE)
  dd_apply_bulk_decisions(con, cfg, quiet = TRUE)
  for (stage in names(dd_stage_keys)) dd_stage_stamp(con, stage, cfg)
  DBI::dbDisconnect(con)
  invisible(cfg)
}

test_that("dd_status() reports zero drift on an untouched config", {
  cfg <- status_cfg(); seed_pipeline(cfg)
  out <- suppressMessages(dd_status(cfg))
  expect_equal(out$drift, 0L)
})

test_that("dd_status() names the changed key and redirects the next step", {
  cfg <- status_cfg(); seed_pipeline(cfg)
  was_thr <- cfg$hamming_threshold
  cfg$hamming_threshold <- was_thr + 4L

  msgs <- capture_messages(out <- dd_status(cfg))
  expect_equal(out$drift, 1L)
  expect_match(msgs, "config changed since analyze ran", all = FALSE)
  expect_match(msgs, sprintf("hamming_threshold: %d -> %d", was_thr, was_thr + 4L),
               all = FALSE, fixed = TRUE)
  expect_match(msgs, "next: dd_run_analyze\\(\\)   # config changed",
               all = FALSE)
})

test_that("the earliest drifted stage wins, since re-running implies the rest", {
  cfg <- status_cfg(); seed_pipeline(cfg)
  cfg$hamming_threshold <- cfg$hamming_threshold + 4L   # analyze
  cfg$extensions <- setdiff(cfg$extensions, "png")  # inventory, earlier

  msgs <- capture_messages(out <- dd_status(cfg))
  expect_equal(out$drift, 2L)
  expect_match(msgs, "next: dd_run_inventory\\(\\)", all = FALSE)
})

test_that("drift in decide points at the function that can actually undo it", {
  # dd_run_plan() does not pass overwrite, so bulk = TRUE would skip every
  # already-decided photo and quietly not apply the edited rules.
  cfg <- status_cfg(); seed_pipeline(cfg)
  cfg$preference_rules <- c("max_meta", "max_pixels")

  msgs <- capture_messages(dd_status(cfg))
  expect_match(msgs, "config changed since decide ran", all = FALSE)
  expect_match(msgs, "dd_apply_bulk_decisions(con, cfg, overwrite = TRUE)",
               all = FALSE, fixed = TRUE)
})

test_that("without drift the count-based next step is untouched", {
  cfg <- status_cfg(); seed_pipeline(cfg)
  msgs <- capture_messages(dd_status(cfg))
  expect_match(msgs, "next: dd_run_plan\\(bulk = TRUE\\)", all = FALSE)
})
