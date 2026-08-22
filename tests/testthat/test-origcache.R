# The review app keeps each group's originals on local disk so the comparison
# viewer opens without going back to the library. They are full-size files, so
# unlike the thumbnail and metadata caches this one has to be bounded.

seed_cache <- function(names, times) {
  dir <- tempfile("orig-"); dir.create(dir)
  for (i in seq_along(names)) {
    f <- file.path(dir, names[i])
    writeLines("x", f)
    Sys.setFileTime(f, times[i])
  }
  dir
}

base_t <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")

test_that("eviction keeps exactly the newest entries", {
  dir <- seed_cache(paste0(1:5, ".jpg"), base_t + (1:5) * 60)
  expect_equal(dd_cache_evict(dir, 3L), 2L)
  expect_setequal(list.files(dir), c("3.jpg", "4.jpg", "5.jpg"))
})

test_that("recency of access decides, not creation order", {
  # dd_cache_get() touches on every hit, so the group being reviewed right now
  # must be the last thing evicted even though it was cached first.
  dir <- seed_cache(paste0(1:4, ".jpg"), base_t + (1:4) * 60)
  Sys.setFileTime(file.path(dir, "1.jpg"), base_t + 3600)   # just accessed
  dd_cache_evict(dir, 2L)
  expect_setequal(list.files(dir), c("1.jpg", "4.jpg"))
})

test_that("a cache under its limit loses nothing", {
  dir <- seed_cache(paste0(1:3, ".jpg"), base_t + (1:3) * 60)
  expect_equal(dd_cache_evict(dir, 3L), 0L)
  expect_equal(dd_cache_evict(dir, 100L), 0L)
  expect_length(list.files(dir), 3L)
})

test_that("a limit of zero empties the cache", {
  dir <- seed_cache(paste0(1:3, ".jpg"), base_t + (1:3) * 60)
  expect_equal(dd_cache_evict(dir, 0L), 3L)
  expect_length(list.files(dir), 0L)
})

test_that("eviction is deterministic when timestamps collide", {
  # Coarse filesystem timestamps must not make eviction a coin toss.
  dir <- seed_cache(paste0("p", 1:4, ".jpg"), rep(base_t, 4))
  dd_cache_evict(dir, 2L)
  expect_length(list.files(dir), 2L)
  expect_setequal(list.files(dir), c("p1.jpg", "p2.jpg"))
})

test_that("an empty or missing cache directory is harmless", {
  dir <- tempfile("orig-"); dir.create(dir)
  expect_equal(dd_cache_evict(dir, 10L), 0L)
  expect_equal(dd_cache_evict(file.path(dir, "nope"), 10L), 0L)
})

test_that("a hit is touched so it survives the next eviction", {
  dir <- seed_cache(c("7.jpg", "8.jpg"), c(base_t, base_t + 600))
  cfg <- list(orig_dir = dir)
  hit <- dd_cache_get(7L, cfg)
  expect_equal(basename(hit), "7.jpg")
  dd_cache_evict(dir, 1L)
  expect_equal(list.files(dir), "7.jpg")

  expect_true(is.na(dd_cache_get(99L, cfg)))
})

test_that("only browser-renderable formats are served as themselves", {
  # A browser cannot display TIFF, HEIC or any RAW, so those must be converted
  # or the viewer shows nothing at all. The reference library is a quarter TIFF.
  expect_true(dd_is_web_format("a.jpg"))
  expect_true(dd_is_web_format("a.JPEG"))
  expect_true(dd_is_web_format("a.png"))
  expect_false(dd_is_web_format("a.tiff"))
  expect_false(dd_is_web_format("a.heic"))
  expect_false(dd_is_web_format("a.cr2"))
  expect_false(dd_is_web_format("noext"))

  expect_equal(dd_ext("/x/y/a.TIF"), "tif")
  expect_equal(dd_ext("noext"), "")
})

test_that("a cache size of zero disables caching without erroring", {
  dir <- tempfile("orig-")
  cfg <- list(orig_dir = dir, review_cache = 0L)
  src <- tempfile(fileext = ".jpg"); writeLines("x", src)
  expect_true(is.na(dd_cache_put(1L, src, cfg)))
  expect_false(dir.exists(dir))
})

test_that("a web-format original is cached byte for byte", {
  # Judging JPEG artifacts against a re-encode would be judging the re-encode.
  dir <- tempfile("orig-")
  cfg <- list(orig_dir = dir, review_cache = 10L)
  src <- tempfile(fileext = ".jpg")
  writeBin(as.raw(c(0xff, 0xd8, 0xff, 0xe0, 1:20)), src)

  dest <- dd_cache_put(5L, src, cfg)
  expect_equal(basename(dest), "5.jpg")
  expect_equal(readBin(dest, "raw", file.size(src)),
               readBin(src, "raw", file.size(src)))
})

test_that("caching honours the limit as it fills", {
  dir <- tempfile("orig-")
  cfg <- list(orig_dir = dir, review_cache = 3L)
  for (i in 1:6) {
    src <- tempfile(fileext = ".jpg"); writeLines(as.character(i), src)
    dd_cache_put(i, src, cfg)
    Sys.setFileTime(file.path(dir, paste0(i, ".jpg")), base_t + i * 60)
  }
  expect_length(list.files(dir), 3L)
})
