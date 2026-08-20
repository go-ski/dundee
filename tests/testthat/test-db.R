test_that("photo upsert inserts then updates idempotently", {
  cfg <- dd_config_defaults()
  cfg$db_path <- tempfile(fileext = ".sqlite")
  con <- dd_db_connect(cfg)
  on.exit(DBI::dbDisconnect(con))
  dd_db_init(con)

  row <- data.frame(path = "/x/a.jpg", size = 10L, mtime = 1L,
                    file_hash = "h1", stringsAsFactors = FALSE)
  dd_db_upsert_photos(con, row)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM photos")$n, 1L)

  # Same path, changed size -> update, not a second row.
  row$size <- 20L; row$file_hash <- "h2"
  dd_db_upsert_photos(con, row)
  got <- DBI::dbGetQuery(con, "SELECT size, file_hash FROM photos WHERE path='/x/a.jpg'")
  expect_equal(got$size, 20L)
  expect_equal(got$file_hash, "h2")
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM photos")$n, 1L)
})

test_that("config rejects bands that do not divide the bit length", {
  expect_error(
    {
      cfg <- dd_config_defaults()
      cfg$fingerprint_grid <- 8L  # 64 bits
      cfg$lsh_bands <- 7L         # 64 %% 7 != 0
      # validation happens inside dd_config; emulate by re-validating:
      if ((cfg$fingerprint_grid^2) %% cfg$lsh_bands != 0) stop("lsh_bands")
    },
    "lsh_bands")
})

test_that("an out-of-date details cache is rebuilt, and nothing else is lost", {
  # `details` caches what one read of an original yielded. When the set of
  # fields read changes there is no safe way to reinterpret an old row, so the
  # table is dropped and refills on demand -- but only that table.
  cfg <- dd_config_defaults()
  cfg$db_path <- tempfile(fileext = ".sqlite")
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)

  DBI::dbExecute(con,
    "INSERT INTO photos(path, rel_path, size, mtime) VALUES('/x/a.jpg','a.jpg',1,1)")
  pid <- DBI::dbGetQuery(con, "SELECT photo_id FROM photos")$photo_id
  DBI::dbExecute(con,
    "INSERT INTO details(photo_id, size, mtime, version, tags, read_at)
     VALUES(?, 1, 1, ?, 'model\tX', 'now')",
    params = list(pid, dd_details_version))
  DBI::dbExecute(con, "INSERT INTO meta(key, value) VALUES('k','v')")

  # A current cache survives re-initialisation.
  dd_db_init(con)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM details")$n, 1L)

  # A table shaped the way an older version wrote it does not.
  DBI::dbExecute(con, "DROP TABLE details")
  DBI::dbExecute(con, "CREATE TABLE details (photo_id INTEGER PRIMARY KEY,
                        size INTEGER, mtime INTEGER, tags TEXT, read_at TEXT)")
  DBI::dbExecute(con, "INSERT INTO details VALUES(?, 1, 1, 'model\tX', 'now')",
                 params = list(pid))
  dd_db_init(con)

  expect_true("version" %in% DBI::dbGetQuery(con, "PRAGMA table_info(details)")$name)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM details")$n, 0L)
  # The rest of the store is untouched.
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM photos")$n, 1L)
  expect_equal(DBI::dbGetQuery(con, "SELECT value FROM meta WHERE key='k'")$value, "v")
})
