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

test_that("an error row is cleared once the file reads successfully", {
  cfg <- stage_cfg()
  b64 <- function(x) base64enc::base64encode(charToRaw(x))
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)

  # Run 1: vips cannot decode it.
  writeLines(paste(b64("/lib/x.heic"), b64("decode failed"), sep = "\t"),
             file.path(cfg$staging_dir, "shard.20260101T000000Z.1.err"))
  r1 <- dd_import_staging(con, cfg, quiet = TRUE)
  expect_equal(r1$errors, 1L)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM errors")$n, 1L)

  # Run 2: libheif is installed and the same file fingerprints fine.
  writeLines(stage_row("/lib/x.heic", 100L, "px"),
             file.path(cfg$staging_dir, "shard.20260102T000000Z.1.tsv"))
  r2 <- dd_import_staging(con, cfg, quiet = TRUE)
  expect_equal(r2$photos, 1L)
  expect_equal(r2$cleared, 1L)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM errors")$n, 0L)
})

test_that("a still-failing file keeps its error row", {
  cfg <- stage_cfg()
  b64 <- function(x) base64enc::base64encode(charToRaw(x))
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  writeLines(paste(b64("/lib/broken.jpg"), b64("decode failed"), sep = "\t"),
             file.path(cfg$staging_dir, "shard.20260101T000000Z.1.err"))
  res <- dd_import_staging(con, cfg, quiet = TRUE)
  expect_equal(res$cleared, 0L)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM errors")$n, 1L)
})

test_that("non-ASCII paths round-trip whatever the locale marks them", {
  # dd_b64dec() must mark UTF-8; leaving the encoding "unknown" made a C-locale
  # run store the path escaped, so the resume filter never matched it again.
  cfg <- stage_cfg()
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  p <- "/lib/café-señor.jpg"
  writeLines(stage_row(p, 42L, "px"),
             file.path(cfg$staging_dir, "shard.20260101T000000Z.1.tsv"))
  dd_import_staging(con, cfg, quiet = TRUE)

  got <- DBI::dbGetQuery(con, "SELECT path FROM photos")$path
  expect_equal(charToRaw(got), charToRaw(p))
  expect_false(grepl("<", got, fixed = TRUE))
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
