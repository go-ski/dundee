test_that("temp_dir is always work_dir/tmp, even if set in the config file", {
  wd <- tempfile("work-")
  yml <- tempfile(fileext = ".yml")
  writeLines(c(
    sprintf("work_dir: %s", wd),
    "temp_dir: /tmp/somewhere-else"
  ), yml)

  expect_message(cfg <- dd_config(yml), "temp_dir.*no longer user-configurable")
  expect_equal(cfg$temp_dir, file.path(cfg$work_dir, "tmp"))
})

test_that("an absolute db_path is reduced to its basename under work_dir", {
  wd <- tempfile("work-")
  yml <- tempfile(fileext = ".yml")
  writeLines(c(
    sprintf("work_dir: %s", wd),
    "db_path: /elsewhere/custom.sqlite"
  ), yml)

  expect_message(cfg <- dd_config(yml), "db_path.*filename under work_dir")
  expect_equal(cfg$db_path, file.path(cfg$work_dir, "custom.sqlite"))
})

test_that("a relative db_path still resolves under work_dir as before", {
  wd <- tempfile("work-")
  yml <- tempfile(fileext = ".yml")
  writeLines(c(
    sprintf("work_dir: %s", wd),
    "db_path: e2e.sqlite"
  ), yml)

  cfg <- dd_config(yml)
  expect_equal(cfg$db_path, file.path(cfg$work_dir, "e2e.sqlite"))
})

test_that("work_dir nested inside library_root is rejected", {
  root <- tempfile("lib-")
  dir.create(root)
  yml <- tempfile(fileext = ".yml")
  writeLines(c(
    sprintf("library_root: %s", root),
    sprintf("work_dir: %s", file.path(root, "work"))
  ), yml)

  expect_error(dd_config(yml), "work_dir must not be")
})

test_that("library_root nested inside work_dir is rejected", {
  wd <- tempfile("work-")
  dir.create(wd)
  yml <- tempfile(fileext = ".yml")
  writeLines(c(
    sprintf("library_root: %s", file.path(wd, "lib")),
    sprintf("work_dir: %s", wd)
  ), yml)
  dir.create(file.path(wd, "lib"))

  expect_error(dd_config(yml), "work_dir must not be")
})

test_that("disjoint library_root and work_dir resolve without error", {
  root <- tempfile("lib-")
  wd <- tempfile("work-")
  dir.create(root)
  yml <- tempfile(fileext = ".yml")
  writeLines(c(
    sprintf("library_root: %s", root),
    sprintf("work_dir: %s", wd)
  ), yml)

  cfg <- dd_config(yml, require_library = TRUE)
  expect_true(dir.exists(cfg$work_dir))
  expect_equal(cfg$temp_dir, file.path(cfg$work_dir, "tmp"))
  expect_equal(cfg$staging_dir, file.path(cfg$work_dir, "staging"))
})
