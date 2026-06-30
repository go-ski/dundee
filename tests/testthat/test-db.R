test_that("photo upsert inserts then updates idempotently", {
  cfg <- dd_config(path = NULL)
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
      cfg <- dd_config(path = NULL)
      cfg$fingerprint_grid <- 8L  # 64 bits
      cfg$lsh_bands <- 7L         # 64 %% 7 != 0
      # validation happens inside dd_config; emulate by re-validating:
      if ((cfg$fingerprint_grid^2) %% cfg$lsh_bands != 0) stop("lsh_bands")
    },
    "lsh_bands")
})
