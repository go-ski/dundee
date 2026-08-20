# The review app used to show absolutes side by side, so the reviewer had to
# diff "3024x4032 8472913 bytes meta:38" against its twin by eye. In the
# reference store 24 of 30 groups agree on every displayed field and differ in
# exactly one that was not displayed at all, so what matters is the difference.

two <- function(...) {
  d <- list(...)
  as.data.frame(d, stringsAsFactors = FALSE)
}

field <- function(cmp, name) cmp[cmp$field == name, , drop = FALSE]

test_that("fields that agree collapse, fields that differ are marked", {
  m <- two(size = c(100L, 100L), jpeg_quality = c("95", "80"))
  cmp <- dd_compare_fields(m)

  expect_false(field(cmp, "size")$differs)
  expect_equal(field(cmp, "size")$shared, "100")
  expect_true(field(cmp, "jpeg_quality")$differs)
  expect_true(is.na(field(cmp, "jpeg_quality")$shared))
})

test_that("the better copy is identified only where there is a direction", {
  m <- two(jpeg_quality = c("80", "95"),   # high -> second
           encoding = c("Baseline", "Progressive"))  # no direction
  cmp <- dd_compare_fields(m)
  expect_equal(field(cmp, "jpeg_quality")$best, 2L)
  expect_true(is.na(field(cmp, "encoding")$best))
})

test_that("having a field at all beats not having it", {
  # One copy carrying GPS or a caption the other lacks is on its own a reason
  # to keep it -- the case the old display could not show.
  m <- two(coords = c(NA_character_, "51.50000, -0.11670"),
           description = c("Ben at the lake", NA_character_))
  cmp <- dd_compare_fields(m)
  expect_equal(field(cmp, "coords")$best, 2L)
  expect_equal(field(cmp, "description")$best, 1L)
})

test_that("a field absent from every copy is not a difference", {
  m <- two(coords = c(NA_character_, NA_character_))
  cmp <- dd_compare_fields(m)
  expect_false(field(cmp, "coords")$differs)
  expect_true(is.na(field(cmp, "coords")$best))
})

test_that("an empty string counts as absent, not as a distinct value", {
  # exiftool reports a present-but-empty ImageDescription; treating "" as a
  # value would report a difference where there is none to act on.
  m <- two(description = c("", ""))
  expect_false(field(dd_compare_fields(m), "description")$differs)

  m2 <- two(description = c("", "Ben at the lake"))
  cmp <- dd_compare_fields(m2)
  expect_true(field(cmp, "description")$differs)
  expect_equal(field(cmp, "description")$best, 2L)
})

test_that("a tie on a directional field picks no winner", {
  m <- two(jpeg_quality = c("95", "95"), coords = c("1.0, 2.0", "3.0, 4.0"))
  cmp <- dd_compare_fields(m)
  expect_false(field(cmp, "jpeg_quality")$differs)
  # Both have a location, so "present" separates nobody even though they differ.
  expect_true(field(cmp, "coords")$differs)
  expect_true(is.na(field(cmp, "coords")$best))
})

test_that("chroma subsampling ranks by how much colour survives", {
  m <- two(chroma = c("YCbCr4:2:0 (2 2)", "YCbCr4:2:2 (2 1)"))
  expect_equal(field(dd_compare_fields(m), "chroma")$best, 2L)
  m2 <- two(chroma = c("YCbCr4:4:4 (1 1)", "YCbCr4:2:2 (2 1)"))
  expect_equal(field(dd_compare_fields(m2), "chroma")$best, 1L)
})

test_that("the older capture wins, and unparseable dates pick nobody", {
  m <- two(capture = c("2019:07:04 10:00:00", "2021:03:04 10:00:00"))
  expect_equal(field(dd_compare_fields(m), "capture")$best, 1L)
  m2 <- two(capture = c("not a date", "also not"))
  expect_true(is.na(field(dd_compare_fields(m2), "capture")$best))
})

test_that("only fields actually supplied are compared", {
  cmp <- dd_compare_fields(two(size = c(1L, 2L)))
  expect_equal(cmp$field, "size")
})

test_that("NA metadata is not mistaken for zero metadata", {
  # meta_count is NULL when the metadata could not be read at all; 0 means it
  # was read and there was none. The first must not win a max_meta comparison.
  m <- two(meta_count = c(NA_integer_, 0L))
  cmp <- dd_compare_fields(m)
  expect_true(cmp$differs)
  expect_equal(cmp$best, 2L)
})

# --- which rule actually decided -------------------------------------------

pref_cfg <- function(rules = c("max_pixels", "max_filesize", "max_meta",
                               "oldest_capture")) {
  cfg <- dd_config_defaults()
  cfg$preference_rules <- rules
  cfg
}

group <- function(size = c(100L, 100L), w = c(10L, 10L), h = c(10L, 10L),
                  meta = c(5L, 5L), cap = c("", ""), rel = c("a.jpg", "b.jpg")) {
  data.frame(photo_id = seq_along(size), width = w, height = h, size = size,
             meta_count = meta, capture_time = cap, rel_path = rel,
             stringsAsFactors = FALSE)
}

test_that("the first rule that separates the winner is the one reported", {
  # Pixels tie, file size does not: max_filesize decided, not max_pixels.
  g <- group(size = c(2853248L, 1168990L))
  ex <- dd_explain_preference(g, pref_cfg())
  expect_equal(ex$winner, 1L)
  expect_equal(ex$rule, "max_filesize")
  expect_equal(ex$detail, "2.7 MB vs 1.1 MB")
})

test_that("a later rule is reported when the earlier ones tie", {
  g <- group(meta = c(65L, 105L))
  ex <- dd_explain_preference(g, pref_cfg())
  expect_equal(ex$winner, 2L)
  expect_equal(ex$rule, "max_meta")
  expect_equal(ex$detail, "105 tags vs 65 tags")
})

test_that("when nothing separates them the rule is NA, not a guess", {
  # 24 of the 30 groups in the reference store land here: every rule ties and
  # the winner comes from the photo_id tie-break. Presenting that as a decision
  # is what the app used to do.
  ex <- dd_explain_preference(group(), pref_cfg())
  expect_true(is.na(ex$rule))
  expect_true(is.na(ex$detail))
  expect_equal(ex$winner, 1L)
})

test_that("a rule that separates nobody is skipped, not reported", {
  g <- group(w = c(10L, 10L), h = c(10L, 10L), meta = c(7L, 7L),
             size = c(50L, 900L))
  ex <- dd_explain_preference(g, pref_cfg())
  expect_equal(ex$rule, "max_filesize")
  expect_equal(ex$winner, 2L)
})

test_that("the explanation agrees with the decision that gets recorded", {
  # dd_explain_preference() must never name a winner other than the one
  # dd_choose_preferred() picks, or the app would explain a decision that was
  # not taken.
  set.seed(42)
  cfg <- pref_cfg()
  for (i in 1:25) {
    g <- group(size = sample(1:5, 2, TRUE) * 100L,
               w = sample(1:3, 2, TRUE) * 10L,
               meta = sample(1:4, 2, TRUE))
    expect_equal(dd_explain_preference(g, cfg)$winner,
                 dd_choose_preferred(g, cfg))
  }
})

test_that("a margin too small to show still says what the gap was", {
  # Real case from the reference store: 2679207 vs 2677837 bytes both render as
  # "2.6 MB", so the verdict read as "A on max_filesize (2.6 MB vs 2.6 MB)".
  g <- group(size = c(2679207L, 2677837L))
  ex <- dd_explain_preference(g, pref_cfg())
  expect_equal(ex$rule, "max_filesize")
  expect_equal(ex$detail, "2.6 MB vs 2.6 MB, larger by 1.3 kB")
})

test_that("an older capture is described as earlier, not larger", {
  cfg <- pref_cfg("oldest_capture")
  g <- group(cap = c("2019:07:04 10:00:00", "2019:07:04 10:00:30"))
  ex <- dd_explain_preference(g, cfg)
  expect_equal(ex$winner, 1L)
  # Same day, so both format identically and the gap has to be spelled out.
  expect_match(ex$detail, "earlier by 30 s", fixed = TRUE)
})

test_that("folder_priority is explained like any other rule", {
  cfg <- pref_cfg(c("folder_priority", "max_filesize"))
  cfg$folder_priority <- c("Originals", "Exports")
  g <- group(rel = c("Exports/a.jpg", "Originals/b.jpg"))
  ex <- dd_explain_preference(g, cfg)
  expect_equal(ex$rule, "folder_priority")
  expect_equal(ex$winner, 2L)
})

# --- formatters -------------------------------------------------------------

test_that("the member table derives what only matters as a comparison", {
  p <- data.frame(photo_id = 1:2, width = c(2816L, 2816L),
                  height = c(2112L, 2112L), size = c(2853248, 1168990),
                  format = c("jpegload", "jpegload"), meta_count = c(59L, 78L),
                  rel_path = c("jpeg02/a.jpeg", "jpeg03/b.jpeg"),
                  mtime = c(1L, 2L), stringsAsFactors = FALSE)
  t <- dd_member_table(p)
  expect_equal(t$folder, c("jpeg02", "jpeg03"))
  expect_equal(t$bpp, c("0.480", "0.197"))
  # Same picture, so pixels tie and only compression separates them.
  cmp <- dd_compare_fields(t)
  expect_false(field(cmp, "pixels")$differs)
  expect_equal(field(cmp, "bpp")$best, 1L)
})

test_that("freshly read details win over the columns the store duplicates", {
  p <- data.frame(photo_id = 1:2, width = 10L, height = 10L, size = 1L,
                  format = "jpegload", meta_count = 1L,
                  rel_path = c("a.jpg", "b.jpg"), mtime = 1L,
                  stringsAsFactors = FALSE)
  d <- data.frame(photo_id = 2:1, model = c("B", "A"),
                  city = c(NA_character_, "Oxford"),
                  stringsAsFactors = FALSE)
  t <- dd_member_table(p, d)
  # Matched on photo_id, not on row order.
  expect_equal(t$model, c("A", "B"))
  expect_equal(t$city, c("Oxford", NA))
})

test_that("values render the way the app shows them", {
  expect_equal(dd_fmt_field("size", 2853248), "2.7 MB")
  expect_equal(dd_fmt_field("format", "jpegload"), "JPEG")
  expect_equal(dd_fmt_field("makernotes", "yes"), "present")
  expect_equal(dd_fmt_field("capture", "2019:07:04 10:00:00"),
               "2019-07-04 10:00:00")
  expect_equal(dd_fmt_field("coords", NA), "-")
  # The distinction the metadata fix introduced: unreadable is not zero.
  expect_equal(dd_fmt_field("meta_count", NA), "unreadable")
  expect_equal(dd_fmt_field("meta_count", 0L), "0")
})

test_that("coordinates render compactly, or not at all", {
  expect_equal(dd_fmt_coords(36.0165055555556, -84.2612222222222),
               "36.01651, -84.26122")
  expect_equal(dd_fmt_coords("36.0165055555556", "-84.2612222222222"),
               "36.01651, -84.26122")
  expect_equal(dd_fmt_coords(0, 0), "0.00000, 0.00000")
  # A latitude without a longitude is not a location.
  expect_true(is.na(dd_fmt_coords(36.1, NA)))
  expect_true(is.na(dd_fmt_coords(NA, -84.2)))
  expect_true(is.na(dd_fmt_coords(NA, NA)))
  expect_true(is.na(dd_fmt_coords("not a number", 1)))
})

test_that("the capture date falls back, and says when it did", {
  a <- dd_capture_date("2013:12:05 14:43:02", "2013:12:05 14:43:02")
  expect_equal(a$value, "2013:12:05 14:43:02")
  expect_equal(a$source, "DateTimeOriginal")

  # A quarter of the reference library has no DateTimeOriginal at all.
  b <- dd_capture_date(NA, "2009:05:14 11:57:08")
  expect_equal(b$value, "2009:05:14 11:57:08")
  expect_equal(b$source, "CreateDate")

  # An empty string is exiftool reporting a present-but-blank tag.
  expect_equal(dd_capture_date("", "2009:05:14 11:57:08")$source, "CreateDate")

  none <- dd_capture_date(NA, NA)
  expect_true(is.na(none$value))
  expect_true(is.na(none$source))
})

test_that("coords are derived per copy from the decimal pair", {
  p <- data.frame(photo_id = 1:2, width = 10L, height = 10L, size = 1L,
                  format = "jpegload", meta_count = 1L,
                  rel_path = c("a.jpg", "b.jpg"), mtime = 1L,
                  stringsAsFactors = FALSE)
  d <- data.frame(photo_id = 1:2,
                  gps_lat = c("36.0165055555556", NA),
                  gps_lon = c("-84.2612222222222", NA),
                  stringsAsFactors = FALSE)
  t <- dd_member_table(p, d)
  expect_equal(t$coords, c("36.01651, -84.26122", NA))

  # Only one copy has a location, which is on its own a reason to keep it.
  cmp <- dd_compare_fields(t)
  expect_equal(field(cmp, "coords")$best, 1L)
})

test_that("the fields pinned to the card are real, and are the ones intended", {
  # Guard against the card and the collapsed "identical" line disagreeing: the
  # app excludes exactly the card fields from that line, so a typo here would
  # silently show a value twice or lose it entirely.
  spec <- dd_compare_spec()
  expect_true(all(c("card", "field") %in% names(spec)))
  expect_setequal(spec$field[spec$card], c("coords", "capture"))
  expect_false(any(duplicated(spec$field)))
})

test_that("create_date is comparable, not merely fetched", {
  # It was read by dd_read_details() from the start but missing from the spec,
  # so it never reached the screen.
  expect_true("create_date" %in% dd_compare_spec()$field)
  m <- two(create_date = c("2019:07:04 10:00:00", "2021:03:04 10:00:00"))
  expect_equal(field(dd_compare_fields(m), "create_date")$best, 1L)
})

test_that("sizes and formats read the way a human writes them", {
  expect_equal(dd_fmt_bytes(0), "0 B")
  expect_equal(dd_fmt_bytes(999), "999 B")
  expect_equal(dd_fmt_bytes(2853248), "2.7 MB")
  expect_equal(dd_fmt_bytes(1168990), "1.1 MB")
  expect_true(is.na(dd_fmt_bytes(NA)))

  expect_equal(dd_fmt_format("jpegload"), "JPEG")
  expect_equal(dd_fmt_format("pngload"), "PNG")
  expect_equal(dd_fmt_format("tiffload"), "TIFF")
  expect_true(is.na(dd_fmt_format(NA_character_)))
})
