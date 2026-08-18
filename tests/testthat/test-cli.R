# The CLI's argument handling is where dundee has actually drifted: --rebase sat
# in the allow-list unwired to any stage, and `move --quiet` was accepted and
# ignored. Nothing in R CMD check reached it -- only tests/e2e.sh did, and that
# is a shell script check never runs. These tests close that gap.

test_that("the usage text and the per-command option table agree", {
  usage <- strsplit(dd_cli_usage(), "\n", fixed = TRUE)[[1]]
  for (cmd in names(dd_cli_opts)) {
    line <- grep(paste0("^  ", cmd, "\\b"), usage, value = TRUE)
    expect_length(line, 1L)
    shown <- as.character(
      unlist(regmatches(line, gregexpr("--[a-z][a-z-]*", line))))
    expect_setequal(shown, dd_cli_opts[[cmd]])
  }
})

test_that("an unknown command is rejected", {
  expect_error(dd_parse_args("frobnicate"), "unknown command")
})

test_that("options are rejected per command, not globally", {
  # --bulk is a real dundee option, just not one `status` takes. Under a single
  # global allow-list this validated cleanly and was then dropped on the floor.
  expect_error(dd_parse_args(c("status", "~/w", "--bulk")),
               "status does not accept")
  expect_error(dd_parse_args(c("analyze", "--execute")),
               "analyze does not accept")
  expect_error(dd_parse_args(c("inventory", "--quiot")), "does not accept")
  expect_no_error(dd_parse_args(c("plan", "~/w", "--bulk", "--quiet")))
})

test_that("the work directory is the first non-flag argument", {
  expect_equal(dd_parse_args(c("analyze", "~/w"))$work, "~/w")
  expect_equal(dd_parse_args(c("analyze", "--quiet", "~/w"))$work, "~/w")
  expect_null(dd_parse_args(c("analyze", "--quiet"))$work)
})

test_that("flags and valued options are read back", {
  p <- dd_parse_args(c("inventory", "~/w", "--rebase", "--parallel=8"))
  expect_true(dd_has_flag(p$flags, "rebase"))
  expect_false(dd_has_flag(p$flags, "quiet"))
  expect_equal(dd_flag_value(p$flags, "parallel"), "8")
  expect_equal(dd_flag_value(p$flags, "port", 7654L), 7654L)
})

test_that("help takes no work directory and dispatches nowhere", {
  expect_equal(dd_parse_args(character())$cmd, "help")
  expect_equal(dd_parse_args("--help")$cmd, "help")
  expect_output(dd_cli("help"), "usage: dundee")
})

test_that("init insists on both a work directory and --library", {
  expect_error(dd_cli("init"), "needs a work directory")
  expect_error(dd_cli(c("init", tempfile("nowhere-"))), "needs --library")
})
