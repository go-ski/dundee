test_that("choose_preferred follows the rule order", {
  cfg <- dd_config(path = NULL)
  cfg$preference_rules <- c("max_pixels", "max_filesize")
  g <- data.frame(
    photo_id = c(10L, 11L, 12L),
    width = c(100L, 200L, 200L),
    height = c(100L, 100L, 100L),
    size = c(999L, 50L, 80L),
    meta_count = c(0L, 0L, 0L),
    capture_time = c("", "", ""),
    rel_path = c("a", "b", "c"),
    stringsAsFactors = FALSE)
  # 11 and 12 tie on pixels (20000) but 12 has larger filesize.
  expect_equal(dd_choose_preferred(g, cfg), 12L)
})

test_that("oldest_capture prefers the earliest timestamp", {
  cfg <- dd_config(path = NULL)
  cfg$preference_rules <- c("oldest_capture")
  g <- data.frame(
    photo_id = c(1L, 2L),
    width = c(10L, 10L), height = c(10L, 10L),
    size = c(1L, 1L), meta_count = c(0L, 0L),
    capture_time = c("2020:01:01 00:00:00", "2010:01:01 00:00:00"),
    rel_path = c("a", "b"), stringsAsFactors = FALSE)
  expect_equal(dd_choose_preferred(g, cfg), 2L)
})

test_that("ties fall back to lowest photo_id deterministically", {
  cfg <- dd_config(path = NULL)
  cfg$preference_rules <- character(0)
  g <- data.frame(
    photo_id = c(7L, 3L, 9L),
    width = c(1L, 1L, 1L), height = c(1L, 1L, 1L),
    size = c(1L, 1L, 1L), meta_count = c(0L, 0L, 0L),
    capture_time = c("", "", ""), rel_path = c("a", "b", "c"),
    stringsAsFactors = FALSE)
  expect_equal(dd_choose_preferred(g, cfg), 3L)
})
