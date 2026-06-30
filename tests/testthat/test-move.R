test_that("path translation maps SMB root to NAS root", {
  cfg <- dd_config(path = NULL)
  cfg$library_root <- "/Volumes/photo"
  cfg$nas_root <- "/volume1/photo"
  expect_equal(dd_translate_path("/Volumes/photo/2020/a.jpg", cfg),
               "/volume1/photo/2020/a.jpg")
  # Vectorised, and tolerant of trailing slashes in config.
  cfg$nas_root <- "/volume1/photo/"
  expect_equal(dd_translate_path(c("/Volumes/photo/x y/b.jpg"), cfg),
               "/volume1/photo/x y/b.jpg")
})

test_that("translation rejects paths outside the library root", {
  cfg <- dd_config(path = NULL)
  cfg$library_root <- "/Volumes/photo"
  cfg$nas_root <- "/volume1/photo"
  expect_error(dd_translate_path("/elsewhere/a.jpg", cfg),
               "not under library_root")
})

test_that("dest mapping routes preferred and non-preferred correctly", {
  cfg <- dd_config(path = NULL)
  cfg$preferred_root <- "/v/pref"
  cfg$nonpreferred_root <- "/v/non"
  expect_equal(dd_map_dest("2020/a.jpg", TRUE, cfg), "/v/pref/2020/a.jpg")
  expect_equal(dd_map_dest("2020/a.jpg", FALSE, cfg), "/v/non/2020/a.jpg")
})
