# The reviewer decides on image quality, location and capture date, and only
# two of those reach the store: the fingerprint worker keeps capture_time and
# camera and hashes the rest away. Rather than re-fingerprint the library to add
# columns, the review app reads the group's own originals -- once each, deriving
# the metadata, the thumbnail and the viewer's copy from that single read.

need_tools <- function() {
  skip_on_os("windows")
  for (t in c("exiftool", "vips", "vipsthumbnail")) {
    skip_if(!nzchar(Sys.which(t)), paste("no", t, "on PATH"))
  }
}

detail_store <- function(review_cache = 10L) {
  cfg <- dd_config_defaults()
  cfg$review_cache <- review_cache
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  cfg$temp_dir <- file.path(cfg$work_dir, "tmp")
  cfg$thumb_dir <- file.path(cfg$work_dir, "thumbs")
  cfg$orig_dir <- file.path(cfg$work_dir, "originals")
  cfg$lib <- file.path(cfg$work_dir, "lib"); dir.create(cfg$lib)
  con <- dd_db_connect(cfg); dd_db_init(con)
  list(cfg = cfg, con = con)
}

# A real image, with the tags the display actually leans on.
make_photo <- function(s, name, ext = "jpg", tags = character(0)) {
  path <- file.path(s$cfg$lib, paste0(name, ".", ext))
  system2("vips", c("black", shQuote(path), "64", "48", "--bands", "3"),
          stdout = FALSE, stderr = FALSE)
  if (!file.exists(path)) return(NULL)
  if (length(tags)) {
    # system2 builds a command line without quoting, so a tag value containing
    # a space (a date, say) would arrive as two arguments.
    system2("exiftool", c("-overwrite_original", "-q", "-m", shQuote(tags),
                          shQuote(path)), stdout = FALSE, stderr = FALSE)
  }
  fi <- file.info(path)
  DBI::dbExecute(s$con,
    "INSERT INTO photos(path, rel_path, size, mtime) VALUES(?, ?, ?, ?)",
    params = list(path, basename(path), as.integer(fi$size),
                  as.integer(fi$mtime)))
  DBI::dbGetQuery(s$con, "SELECT photo_id, path, size, mtime FROM photos
                           WHERE path = ?", params = list(path))
}

test_that("one read yields metadata, a thumbnail and a viewer copy", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "a", tags = c("-Artist=Ann", "-Model=TestCam",
                                   "-DateTimeOriginal=2019:07:04 10:00:00"))
  skip_if(is.null(p), "vips could not write a fixture image")

  d <- dd_group_details(s$con, p, s$cfg)
  expect_equal(nrow(d), 1L)
  expect_equal(d$model, "TestCam")
  expect_equal(d$artist, "Ann")
  expect_equal(d$capture, "2019:07:04 10:00:00")

  expect_true(file.exists(file.path(s$cfg$thumb_dir,
                                    paste0(p$photo_id, ".jpg"))))
  expect_false(is.na(d$viewer))
  expect_true(file.exists(d$viewer))
  # The original is left in the cache, not in scratch.
  expect_length(list.files(s$cfg$temp_dir), 0L)
})

test_that("a second look re-reads nothing", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "b")
  skip_if(is.null(p), "vips could not write a fixture image")

  dd_group_details(s$con, p, s$cfg)
  first <- DBI::dbGetQuery(s$con, "SELECT read_at FROM details")$read_at
  Sys.sleep(1.1)                       # read_at has one-second resolution
  d <- dd_group_details(s$con, p, s$cfg)
  again <- DBI::dbGetQuery(s$con, "SELECT read_at FROM details")$read_at

  expect_equal(again, first)
  expect_false(is.na(d$viewer))
})

test_that("an original that changed is read again", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "c")
  skip_if(is.null(p), "vips could not write a fixture image")

  dd_group_details(s$con, p, s$cfg)
  first <- DBI::dbGetQuery(s$con, "SELECT read_at FROM details")$read_at
  Sys.sleep(1.1)
  # The store now disagrees with the cache about mtime, which is exactly what
  # an edited original looks like.
  p$mtime <- as.integer(p$mtime) + 1000L
  dd_group_details(s$con, p, s$cfg)
  again <- DBI::dbGetQuery(s$con, "SELECT read_at FROM details")$read_at

  expect_false(identical(again, first))
})

test_that("an evicted viewer copy is refetched but the metadata is not", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "d")
  skip_if(is.null(p), "vips could not write a fixture image")

  d1 <- dd_group_details(s$con, p, s$cfg)
  unlink(d1$viewer)                    # as eviction would
  d2 <- dd_group_details(s$con, p, s$cfg)
  expect_false(is.na(d2$viewer))
  expect_true(file.exists(d2$viewer))
  expect_equal(DBI::dbGetQuery(s$con, "SELECT COUNT(*) n FROM details")$n, 1L)
})

test_that("a TIFF becomes something a browser can actually display", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "e", ext = "tif")
  skip_if(is.null(p), "vips could not write a fixture TIFF")

  d <- dd_group_details(s$con, p, s$cfg)
  expect_false(is.na(d$viewer))
  expect_equal(dd_ext(d$viewer), "png")
})

test_that("a JPEG reaches the viewer byte for byte", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "f")
  skip_if(is.null(p), "vips could not write a fixture image")

  d <- dd_group_details(s$con, p, s$cfg)
  n <- file.size(p$path)
  expect_equal(readBin(d$viewer, "raw", n), readBin(p$path, "raw", n))
})

test_that("review_cache = 0 still yields metadata and a thumbnail", {
  need_tools()
  s <- detail_store(review_cache = 0L); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "g", tags = "-Model=TestCam")
  skip_if(is.null(p), "vips could not write a fixture image")

  d <- dd_group_details(s$con, p, s$cfg)
  expect_equal(d$model, "TestCam")
  expect_true(is.na(d$viewer))
  expect_true(file.exists(file.path(s$cfg$thumb_dir,
                                    paste0(p$photo_id, ".jpg"))))
})

test_that("a missing original degrades instead of erroring", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "h")
  skip_if(is.null(p), "vips could not write a fixture image")
  unlink(p$path)                       # library offline, or file moved

  d <- expect_no_error(dd_group_details(s$con, p, s$cfg))
  expect_equal(nrow(d), 1L)
  expect_true(is.na(d$model))
  expect_true(is.na(d$viewer))
})

test_that("coordinates come back in decimal, ready for a map link", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "i", tags = c("-GPSLatitude=36.0165055555556",
                                   "-GPSLatitudeRef=N",
                                   "-GPSLongitude=84.2612222222222",
                                   "-GPSLongitudeRef=W"))
  skip_if(is.null(p), "vips could not write a fixture image")

  d <- dd_group_details(s$con, p, s$cfg)
  skip_if(is.na(d$gps_lat), "exiftool did not store GPS on this fixture")
  # -n gives decimal degrees; the west longitude must come back negative or the
  # map link would point at the wrong hemisphere.
  expect_equal(round(as.numeric(d$gps_lat), 5), 36.01651)
  expect_equal(round(as.numeric(d$gps_lon), 5), -84.26122)

  # dd_member_table() takes the full stored row, as group_members() returns it.
  full <- DBI::dbGetQuery(s$con,
    "SELECT photo_id, rel_path, width, height, size, mtime, format, meta_count
       FROM photos WHERE photo_id = ?", params = list(p$photo_id))
  tbl <- dd_member_table(full, d)
  expect_equal(tbl$coords, "36.01651, -84.26122")
})

test_that("a row cached by an older version is re-read, not trusted", {
  # Adding gps_lat to the fetched fields makes every older row decode it as NA,
  # which is indistinguishable from a photo that has no location.
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "j", tags = "-Model=TestCam")
  skip_if(is.null(p), "vips could not write a fixture image")

  dd_group_details(s$con, p, s$cfg)
  first <- DBI::dbGetQuery(s$con, "SELECT read_at FROM details")$read_at
  DBI::dbExecute(s$con, "UPDATE details SET version = version - 1")
  Sys.sleep(1.1)
  dd_group_details(s$con, p, s$cfg)

  again <- DBI::dbGetQuery(s$con, "SELECT read_at, version FROM details")
  expect_false(identical(again$read_at, first))
  expect_equal(as.integer(again$version), dd_details_version)
})

test_that("the encoded cache round-trips, including awkward values", {
  v <- c(model = "TestCam", description = "has  spaces",
         gps_lat = NA_character_)
  back <- dd_details_decode(dd_details_encode(v))
  expect_equal(back[["model"]], "TestCam")
  expect_equal(back[["description"]], "has  spaces")
  expect_true(is.na(back[["gps_lat"]]))
  # Every field is present in the decoded vector, whether it was stored or not.
  expect_setequal(names(back), dd_detail_all_fields())
})
