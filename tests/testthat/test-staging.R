# Staging shards must merge oldest-run-first and be removed once merged, so a
# stale row from an earlier run can never overwrite a fresh one.

stage_cfg <- function() {
  cfg <- dd_config_defaults()
  cfg$db_path <- tempfile(fileext = ".sqlite")
  cfg$staging_dir <- tempfile("staging-")
  dir.create(cfg$staging_dir)
  cfg
}

stage_row <- function(path, size, pixel_hash) {
  b64 <- function(x) base64enc::base64encode(charToRaw(x))
  paste(b64(path), b64(basename(path)), size, size, 1L, "jpegload",
        10L, 10L, "fh", pixel_hash, "mh", "ff", b64(""), b64(""), 3L,
        sep = "\t")
}

test_that("shard ordering is chronological, not lexicographic", {
  d <- tempfile("stage-"); dir.create(d)
  # Legacy pid-only names: lexicographically "shard.10000" precedes
  # "shard.999", but 999 was written first. mtime must decide.
  old_f <- file.path(d, "shard.999.tsv")
  new_f <- file.path(d, "shard.10000.tsv")
  file.create(old_f, new_f)
  Sys.setFileTime(old_f, Sys.time() - 3600)
  Sys.setFileTime(new_f, Sys.time())
  expect_equal(basename(list.files(d)), c("shard.10000.tsv", "shard.999.tsv"))
  expect_equal(basename(dd_staging_files(d, "\\.tsv$")),
               c("shard.999.tsv", "shard.10000.tsv"))
})

test_that("a run stamp orders shards even when mtimes are equal", {
  d <- tempfile("stage-"); dir.create(d)
  f <- file.path(d, c("shard.20260102T000000Z.10000.tsv",
                      "shard.20260101T000000Z.999.tsv"))
  file.create(f)
  Sys.setFileTime(f, Sys.time())          # identical mtimes
  expect_equal(basename(dd_staging_files(d, "\\.tsv$")),
               c("shard.20260101T000000Z.999.tsv",
                 "shard.20260102T000000Z.10000.tsv"))
})

test_that("a legacy pid-only shard sorts before stamped ones", {
  d <- tempfile("stage-"); dir.create(d)
  file.create(file.path(d, c("shard.20260101T000000Z.2.tsv", "shard.7.tsv")))
  expect_equal(basename(dd_staging_files(d, "\\.tsv$"))[1], "shard.7.tsv")
})

test_that("the newest shard wins and shards are pruned after merge", {
  cfg <- stage_cfg()
  writeLines(stage_row("/lib/x.jpg", 10768L, "old"),
             file.path(cfg$staging_dir, "shard.20260101T000000Z.999.tsv"))
  writeLines(stage_row("/lib/x.jpg", 54461L, "new"),
             file.path(cfg$staging_dir, "shard.20260102T000000Z.10000.tsv"))

  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  res <- dd_import_staging(con, cfg, quiet = TRUE)

  row <- DBI::dbGetQuery(con, "SELECT size, pixel_hash FROM photos")
  expect_equal(nrow(row), 1L)
  expect_equal(row$size, 54461L)          # the later run wins
  expect_equal(row$pixel_hash, "new")
  expect_equal(res$photos, 2L)
  expect_length(list.files(cfg$staging_dir, pattern = "\\.tsv$"), 0L)

  # a second merge with nothing staged is a no-op, not a replay of the old row
  res2 <- dd_import_staging(con, cfg, quiet = TRUE)
  expect_equal(res2$photos, 0L)
  expect_equal(DBI::dbGetQuery(con, "SELECT size FROM photos")$size, 54461L)
})

test_that("prune = FALSE keeps the shards", {
  cfg <- stage_cfg()
  writeLines(stage_row("/lib/y.jpg", 1L, "h"),
             file.path(cfg$staging_dir, "shard.20260101T000000Z.1.tsv"))
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  dd_import_staging(con, cfg, quiet = TRUE, prune = FALSE)
  expect_length(list.files(cfg$staging_dir, pattern = "\\.tsv$"), 1L)
})
