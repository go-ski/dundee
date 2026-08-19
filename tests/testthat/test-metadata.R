# The fingerprint worker sorts exiftool's output before hashing it. That sort
# read from a pipe, and macOS sort aborts with "Illegal byte sequence" (exit 2)
# the moment a pipe carries bytes that are not valid UTF-8 in the ambient
# locale -- which any EXIF Artist/Model holding Latin-1 or Shift-JIS does.
# pipefail turned that into a failed pipeline and `|| meta_lines=""` swallowed
# it, so the photo was stored with meta_count 0 and the hash of the empty
# string. max_meta then ranked a 14-tag photo below its metadata-poorer twin.

# Prefer the source tree, so `Rscript dev-test.R` exercises the file being
# edited rather than whatever is installed; fall back to the installed copy,
# which is all R CMD check has.
dd_test_script <- function(name) {
  src <- file.path("..", "..", "inst", "bin", name)
  if (file.exists(src)) return(normalizePath(src))
  system.file("bin", name, package = "dundee")
}

# "Artist: Fran<e7>ois" -- 0xe7 is c-cedilla in Latin-1 and invalid UTF-8 alone.
bad_meta_bytes <- function() {
  as.raw(c(0x41, 0x72, 0x74, 0x69, 0x73, 0x74, 0x3a, 0x20,       # "Artist: "
           0x46, 0x72, 0x61, 0x6e, 0xe7, 0x6f, 0x69, 0x73, 0x0a, # "Fran.ois\n"
           0x4d, 0x6f, 0x64, 0x65, 0x6c, 0x3a, 0x20, 0x58, 0x0a, # "Model: X\n"
           0x49, 0x53, 0x4f, 0x3a, 0x20, 0x32, 0x30, 0x30, 0x0a))# "ISO: 200\n"
}

test_that("sorting metadata through a pipe survives invalid UTF-8", {
  skip_on_os("windows")
  skip_if(!nzchar(Sys.which("bash")), "no bash on PATH")

  data <- tempfile("meta-"); writeBin(bad_meta_bytes(), data)
  script <- tempfile("srt-", fileext = ".sh")
  # The shape the worker uses: a pipe into sort, with the collation locale
  # pinned. Without LC_ALL=C this exits 2 on macOS and prints to stderr.
  writeLines(c("#!/usr/bin/env bash", "set -euo pipefail",
               'cat "$1" | LC_ALL=C sort'), script)

  err <- tempfile("err-")
  out <- system2("bash", c(script, shQuote(data)), stdout = TRUE, stderr = err)
  expect_equal(attr(out, "status"), NULL)          # non-zero would set it
  expect_length(out, 3L)
  expect_equal(readLines(err, warn = FALSE), character(0))
})

test_that("every sort in the shell layer pins the collation locale", {
  # A drift guard, like the usage/option-table check in test-cli.R: this is
  # what fails if the LC_ALL=C prefix is ever dropped again.
  dir <- dirname(dd_test_script("lib.sh"))
  skip_if(!nzchar(dir) || !dir.exists(dir), "shell layer not found")

  for (f in list.files(dir, pattern = "\\.sh$", full.names = TRUE)) {
    lines <- readLines(f, warn = FALSE)
    lines <- lines[!grepl("^\\s*#", lines)]        # comments may say "sort"
    used <- grep("\\bsort\\b", lines, value = TRUE)
    for (ln in used) {
      expect_match(ln, "LC_ALL=C\\s+sort",
                   info = paste(basename(f), "->", trimws(ln)))
    }
  }
})

test_that("the sorted order does not depend on the ambient locale", {
  # Byte order is all a hash needs, and it is the only order that is the same
  # on every machine. Under a UTF-8 collation the same photo hashed
  # differently than under C, so stores were not comparable.
  skip_on_os("windows")
  skip_if(!nzchar(Sys.which("bash")), "no bash on PATH")

  data <- tempfile("meta-")
  writeLines(c("ISO: 200", "artist: bob", "ApertureValue: 2.8", "_C: x"), data)
  script <- tempfile("srt-", fileext = ".sh")
  writeLines(c("#!/usr/bin/env bash", "set -euo pipefail",
               'cat "$1" | LC_ALL=C sort'), script)

  run <- function(loc) {
    system2("bash", c(script, shQuote(data)), stdout = TRUE,
            env = paste0("LC_ALL=", loc))
  }
  locales <- c("C", "en_US.UTF-8")
  results <- lapply(locales, run)
  expect_equal(results[[2]], results[[1]])
})

test_that("unreadable metadata is stored as unknown, not as none", {
  # The distinction the old code destroyed: 0 means "read it, found no tags";
  # NA/NULL means "could not read it at all". Only the first is a real signal
  # for max_meta.
  skip_on_os("windows")
  worker <- dd_test_script("_fingerprint-one.sh")
  skip_if(!nzchar(worker) || !file.exists(worker), "worker script not found")
  for (tool in c("bash", "vips", "vipsheader", "exiftool", "od")) {
    skip_if(!nzchar(Sys.which(tool)), paste("no", tool, "on PATH"))
  }
  skip_if(!nzchar(Sys.which("b3sum")) && !nzchar(Sys.which("shasum")),
          "no hashing tool on PATH")

  top <- tempfile("meta-e2e-"); dir.create(top)
  lib <- file.path(top, "lib"); dir.create(lib)
  stage <- file.path(top, "stage"); dir.create(stage)
  tmp <- file.path(top, "tmp"); dir.create(tmp)

  # A stub exiftool that fails the -All dump but answers the -s3 probes, so the
  # failure branch is exercised without depending on any real file's metadata.
  bin <- file.path(top, "bin"); dir.create(bin)
  stub <- file.path(bin, "exiftool")
  writeLines(c("#!/usr/bin/env bash",
               'for a in "$@"; do [ "$a" = "-All" ] && exit 3; done',
               "exit 0"), stub)
  Sys.chmod(stub, "0755")

  img <- file.path(lib, "x.jpg")
  system2("vips", c("black", shQuote(img), "64", "48", "--bands", "3"),
          stdout = FALSE, stderr = FALSE)
  skip_if(!file.exists(img), "vips could not write a fixture image")

  old_path <- Sys.getenv("PATH")
  on.exit(Sys.setenv(PATH = old_path), add = TRUE)
  Sys.setenv(PATH = paste(bin, old_path, sep = .Platform$path.sep))

  status <- system2("bash", c(shQuote(worker), shQuote(img)),
                    stdout = FALSE, stderr = FALSE,
                    env = c(paste0("DD_TMP=", tmp),
                            paste0("DD_STAGE=", file.path(stage, "shard")),
                            "DD_GRID=8", paste0("DD_ROOT=", lib)))
  expect_equal(as.integer(status), 0L)

  tsv <- list.files(stage, pattern = "\\.tsv$", full.names = TRUE)
  expect_length(tsv, 1L)
  # Parse it exactly as dd_import_staging() does, so this also pins that the
  # empty fields survive the merge as NA rather than as 0 or "".
  raw <- utils::read.table(
    tsv, sep = "\t", quote = "", comment.char = "", header = FALSE,
    col.names = dd_staging_cols, colClasses = "character",
    stringsAsFactors = FALSE, na.strings = c("", "NA"))
  # The row must still carry every column, or the merge would misalign.
  expect_equal(ncol(raw), 15L)
  expect_true(is.na(raw$meta_hash))
  expect_true(is.na(as.integer(raw$meta_count)))
  # The fingerprint is unaffected: a metadata failure must not cost the photo
  # its perceptual hash.
  expect_true(nzchar(raw$fingerprint))
})

test_that("max_meta ranks unknown metadata last without silencing later rules", {
  cfg <- dd_config_defaults()
  cfg$preference_rules <- c("max_meta", "max_filesize")

  g <- data.frame(
    photo_id = c(1L, 2L),
    width = c(10L, 10L), height = c(10L, 10L), size = c(100L, 100L),
    meta_count = c(NA_integer_, 5L),
    capture_time = c("", ""), rel_path = c("a.jpg", "b.jpg"),
    stringsAsFactors = FALSE
  )
  # A known count beats an unknown one.
  expect_equal(dd_choose_preferred(g, cfg), 2L)

  # When nothing is known, max_meta must not decide -- max_filesize does.
  g2 <- g
  g2$meta_count <- c(NA_integer_, NA_integer_)
  g2$size <- c(100L, 900L)
  expect_equal(dd_choose_preferred(g2, cfg), 2L)

  # And 0 is a real reading, so it still outranks unknown.
  g3 <- g
  g3$meta_count <- c(NA_integer_, 0L)
  expect_equal(dd_choose_preferred(g3, cfg), 2L)
})
