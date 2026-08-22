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

# Replace the cached metadata with a value the file itself cannot produce, so
# the next call says where its answer came from: the sentinel survives only if
# the cache was trusted. Asking that instead of "did read_at move" tests the
# data the app receives -- and read_at is written by nothing that reads it.
poison <- function(con) {
  DBI::dbExecute(con, "UPDATE details SET tags = ?",
                 params = list("model\tSENTINEL"))
}

test_that("one read yields metadata, coordinates, a thumbnail and a viewer copy", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "a", tags = c("-Artist=Ann", "-Model=TestCam",
                                   "-DateTimeOriginal=2019:07:04 10:00:00",
                                   "-GPSLatitude=36.0165055555556",
                                   "-GPSLatitudeRef=N",
                                   "-GPSLongitude=84.2612222222222",
                                   "-GPSLongitudeRef=W"))
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

  skip_if(is.na(d$gps_lat), "exiftool did not store GPS on this fixture")
  # -n gives decimal degrees; the west longitude must come back negative or the
  # map link would point at the wrong hemisphere.
  expect_equal(round(as.numeric(d$gps_lat), 5), 36.01651)
  expect_equal(round(as.numeric(d$gps_lon), 5), -84.26122)

  # dd_member_table() takes the full stored row, as group_members() returns it.
  full <- DBI::dbGetQuery(s$con,
    "SELECT photo_id, rel_path, width, height, size, mtime, format, meta_count
       FROM photos WHERE photo_id = ?", params = list(p$photo_id))
  expect_equal(dd_member_table(full, d)$coords, "36.01651, -84.26122")
})

test_that("a cached row is trusted, and is what comes back", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "b", tags = "-Model=TestCam")
  skip_if(is.null(p), "vips could not write a fixture image")

  dd_group_details(s$con, p, s$cfg)
  poison(s$con)
  d <- dd_group_details(s$con, p, s$cfg)

  expect_equal(d$model, "SENTINEL")
  expect_false(is.na(d$viewer))
})

test_that("a changed original, or an older version, forces a re-read", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  p <- make_photo(s, "c", tags = "-Model=TestCam")
  skip_if(is.null(p), "vips could not write a fixture image")

  dd_group_details(s$con, p, s$cfg)

  # The store now disagrees with the cache about mtime, which is exactly what
  # an edited original looks like.
  poison(s$con)
  p$mtime <- as.integer(p$mtime) + 1000L
  expect_equal(dd_group_details(s$con, p, s$cfg)$model, "TestCam")

  # Adding gps_lat to the fetched fields makes every older row decode it as NA,
  # which is indistinguishable from a photo that has no location. The re-read
  # above left the row fresh at the bumped mtime, so only the version is stale.
  poison(s$con)
  DBI::dbExecute(s$con, "UPDATE details SET version = version - 1")
  expect_equal(dd_group_details(s$con, p, s$cfg)$model, "TestCam")
  expect_equal(as.integer(DBI::dbGetQuery(s$con,
                 "SELECT version FROM details")$version), dd_details_version)
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

test_that("the viewer keeps a web format and converts what a browser cannot show", {
  need_tools()
  s <- detail_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  pj <- make_photo(s, "e")
  pt <- make_photo(s, "f", ext = "tif")
  skip_if(is.null(pj) || is.null(pt), "vips could not write the fixtures")

  # One call for the pair, which is the shape dd_group_details() is built for.
  d <- dd_group_details(s$con, rbind(pj, pt), s$cfg)
  expect_equal(nrow(d), 2L)

  n <- file.size(pj$path)
  expect_equal(readBin(d$viewer[1], "raw", n), readBin(pj$path, "raw", n))
  expect_equal(dd_ext(d$viewer[2]), "png")
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

# --- review progress --------------------------------------------------------

# The sidebar and the exit summary both report "N / M groups decided", so the
# count is a package function rather than an app-local one. The unit is the
# GROUP: a group is reviewed once its preferred copy is chosen, however many
# copies it holds. dd_status()'s `decided` counts photo rows and is a different
# number on the same store.

progress_store <- function(groups) {
  cfg <- dd_config_defaults()
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  con <- dd_db_connect(cfg); dd_db_init(con)
  for (gid in seq_along(groups)) {
    for (k in seq_len(groups[[gid]])) {
      DBI::dbExecute(con,
        "INSERT INTO photos(path, rel_path, size) VALUES(?, ?, 100)",
        params = list(sprintf("/l/g%d-%d.jpg", gid, k),
                      sprintf("g%d-%d.jpg", gid, k)))
      pid <- DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id
      DBI::dbExecute(con, "INSERT INTO groups(group_id, photo_id, tier)
                           VALUES(?, ?, 'exact')", params = list(gid, pid))
    }
  }
  con
}

decide_photo <- function(con, gid, k, preferred = 1L) {
  pid <- DBI::dbGetQuery(con, sprintf(
    "SELECT photo_id FROM photos WHERE rel_path = 'g%d-%d.jpg'", gid, k))$photo_id
  dd_record_decision(con, data.frame(photo_id = pid, group_id = gid,
                                     preferred = preferred))
}

test_that("an untouched store has decided nothing", {
  con <- progress_store(c(2L, 2L, 3L)); on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_equal(dd_review_progress(con), list(decided = 0L, groups = 3L))
})

test_that("deciding one photo marks its whole group reviewed", {
  # The distinction that matters: choosing the winner writes a row per member
  # in the app, but even a single row means the reviewer has answered for that
  # group. Counting `decisions` rows instead would report 1 of 3 here as 1
  # group and then overshoot as soon as a group has both members recorded.
  con <- progress_store(c(2L, 2L, 3L)); on.exit(DBI::dbDisconnect(con), add = TRUE)
  decide_photo(con, 1L, 1L)
  expect_equal(dd_review_progress(con)$decided, 1L)
})

test_that("a fully decided group still counts once", {
  con <- progress_store(c(2L, 2L)); on.exit(DBI::dbDisconnect(con), add = TRUE)
  decide_photo(con, 1L, 1L, preferred = 1L)
  decide_photo(con, 1L, 2L, preferred = 0L)
  p <- dd_review_progress(con)
  expect_equal(p$decided, 1L)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) c FROM decisions")$c, 2L)
  expect_equal(p$groups, 2L)
})

test_that("every group decided reports all of them", {
  con <- progress_store(c(2L, 2L)); on.exit(DBI::dbDisconnect(con), add = TRUE)
  decide_photo(con, 1L, 1L); decide_photo(con, 2L, 1L)
  expect_equal(dd_review_progress(con), list(decided = 2L, groups = 2L))
})

test_that("an empty store reports zeros rather than erroring", {
  con <- progress_store(integer(0)); on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_equal(dd_review_progress(con), list(decided = 0L, groups = 0L))
})
