# The distinction that matters is required vs phase-specific: a machine that can
# run inventory and analyze must report "ready" even with no vipsthumbnail, or
# the check fails on a tool the run about to happen will never call.

test_that("optional tools may be absent but required ones may not", {
  skip_on_os("windows")
  needed <- names(dd_pf_required)
  hasher <- Filter(function(h) nzchar(Sys.which(h)), c("b3sum", "shasum"))
  skip_if(!length(hasher), "no hashing tool on PATH")
  absent <- needed[!vapply(needed, function(t) nzchar(Sys.which(t)), logical(1))]
  skip_if(length(absent), paste("not on PATH:", paste(absent, collapse = ", ")))

  # A PATH holding exactly the required tools plus one hasher -- and in
  # particular no vipsthumbnail.
  bin <- tempfile("bin-"); dir.create(bin)
  for (tool in c(needed, hasher[[1]])) {
    file.symlink(Sys.which(tool), file.path(bin, tool))
  }
  old <- Sys.getenv("PATH")
  on.exit(Sys.setenv(PATH = old), add = TRUE)
  Sys.setenv(PATH = bin)

  expect_true(dd_preflight(quiet = TRUE))

  file.remove(file.path(bin, "vips"))
  msgs <- capture_messages(expect_false(dd_preflight(quiet = TRUE)))
  expect_match(msgs, "MISS vips", all = FALSE)
})

test_that("a missing requirement is reported even when quiet", {
  skip_on_os("windows")
  bin <- tempfile("bin-"); dir.create(bin)
  old <- Sys.getenv("PATH")
  on.exit(Sys.setenv(PATH = old), add = TRUE)
  Sys.setenv(PATH = bin)                       # nothing at all on PATH
  msgs <- capture_messages(expect_false(dd_preflight(quiet = TRUE)))
  expect_match(msgs, "MISS b3sum/shasum", all = FALSE, fixed = TRUE)
  expect_match(msgs, "MISS bash", all = FALSE, fixed = TRUE)
})

test_that("bash is a stated requirement, not an implicit one", {
  # It became checkable only once the checker stopped being a bash script.
  expect_true("bash" %in% names(dd_pf_required))
})
