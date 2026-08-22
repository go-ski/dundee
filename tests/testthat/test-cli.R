# Argument handling is reachable by nothing in R CMD check -- only tests/e2e.sh
# exercises the CLI, and that is a shell script check never runs. So an option
# in the allow-list that no stage reads, or one a command silently ignores,
# survives indefinitely. These tests hold the table and the usage text together.

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
  # --bulk is a real dundee option, just not one `status` takes -- the case a
  # single global allow-list accepts and then drops on the floor.
  expect_error(dd_parse_args(c("status", "~/w", "--bulk")),
               "status does not accept")
  expect_error(dd_parse_args(c("analyze", "--rebase")),
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
