test_that("fingerprint bits expand correctly", {
  # 0xF0 -> 1111 0000
  expect_equal(dd_fingerprint_bits("f0"), c(1L, 1L, 1L, 1L, 0L, 0L, 0L, 0L))
  expect_equal(dd_fingerprint_bits("00"), rep(0L, 8))
  expect_equal(sum(dd_fingerprint_bits("ff")), 8L)
})

test_that("hamming distance is symmetric and correct", {
  expect_equal(dd_hamming("f0", "f0"), 0L)
  # 0xF0 vs 0x00 differ in 4 bits
  expect_equal(dd_hamming("f0", "00"), 4L)
  expect_equal(dd_hamming("f0", "ff"), dd_hamming("ff", "f0"))
})

test_that("empty fingerprints yield NA distance", {
  expect_true(is.na(dd_hamming("", "ff")))
})

# --- alpha channel: the bug that put 67 unrelated photos in one group -------

# `vips colourspace ... b-w` greys the colour but KEEPS the alpha band, so an
# image with alpha leaves rawsave writing an interleaved [grey, alpha, ...]
# stream -- twice the bytes the worker's dHash assumes. It then compares grey
# against alpha, which alternates forever, so every such image hashed to the
# same checkerboard and they all sat at Hamming distance 0 from each other.

fp_script <- function() {
  for (p in c("../../inst/bin/_fingerprint-one.sh",
              system.file("bin", "_fingerprint-one.sh", package = "dundee"))) {
    if (nzchar(p) && file.exists(p)) return(normalizePath(p))
  }
  NULL
}

# Run the real worker over one file and return its staged row.
fp_run <- function(path, root, grid = 16L) {
  sh <- fp_script()
  skip_if(is.null(sh), "_fingerprint-one.sh not reachable")
  wd <- tempfile("fp-"); dir.create(file.path(wd, "tmp"), recursive = TRUE)
  stage <- file.path(wd, "s")
  status <- system2("bash", c(shQuote(sh), shQuote(path)),
                    stdout = FALSE, stderr = FALSE,
                    env = c(paste0("DD_TMP=", file.path(wd, "tmp")),
                            paste0("DD_STAGE=", stage),
                            paste0("DD_GRID=", as.integer(grid)),
                            paste0("DD_ROOT=", root)))
  tsv <- list.files(wd, pattern = "^s\\..*\\.tsv$", full.names = TRUE)
  err <- list.files(wd, pattern = "^s\\..*\\.err$", full.names = TRUE)
  row <- if (length(tsv)) strsplit(readLines(tsv[[1L]], warn = FALSE)[[1L]],
                                   "\t", fixed = TRUE)[[1L]] else character(0)
  list(status = status,
       fingerprint = if (length(row) >= 12L) row[[12L]] else NA_character_,
       error = length(err) > 0L && length(readLines(err[[1L]], warn = FALSE)) > 0L)
}

# Noise generated small and scaled up, so the structure survives the 17x16
# thumbnail. Plain gaussnoise at full size averages to flat grey and hashes to
# all zeros, which would make "the two agree" true for the wrong reason.
alpha_pair <- function() {
  skip_on_os("windows")
  skip_if(!nzchar(Sys.which("vips")), "no vips on PATH")
  d <- tempfile("alpha-"); dir.create(d)
  ok <- system2("vips", c("gaussnoise", shQuote(file.path(d, "t.v")), "24", "18"),
                stdout = FALSE, stderr = FALSE)
  system2("vips", c("resize", shQuote(file.path(d, "t.v")),
                    shQuote(file.path(d, "none.png")), "4"),
          stdout = FALSE, stderr = FALSE)
  system2("vips", c("addalpha", shQuote(file.path(d, "none.png")),
                    shQuote(file.path(d, "rgba.png"))),
          stdout = FALSE, stderr = FALSE)
  skip_if(!all(file.exists(file.path(d, c("none.png", "rgba.png")))),
          "vips could not write the fixtures")
  d
}

test_that("an added opaque alpha band does not change the fingerprint", {
  d <- alpha_pair()
  none <- fp_run(file.path(d, "none.png"), d)
  rgba <- fp_run(file.path(d, "rgba.png"), d)

  expect_false(none$error); expect_false(rgba$error)
  expect_equal(nchar(none$fingerprint), 64L)     # 16x16 grid -> 256 bits
  expect_equal(rgba$fingerprint, none$fingerprint)
})

test_that("the fingerprint is not the alpha checkerboard", {
  # The exact value 53 photos in a real library carried. Asserting the two
  # agree is not enough on its own: under the bug BOTH could be degenerate.
  d <- alpha_pair()
  rgba <- fp_run(file.path(d, "rgba.png"), d)
  checker <- strrep("5555aaaa", 8L)
  expect_false(identical(rgba$fingerprint, checker))
  expect_gt(length(unique(strsplit(rgba$fingerprint, "")[[1L]])), 4L)
})

test_that("a photo with alpha still fingerprints, rather than erroring out", {
  # The byte-count guard must not fire on a correct run -- it is there to catch
  # an unexpected band count, and extract_band means there is not one.
  d <- alpha_pair()
  expect_false(fp_run(file.path(d, "rgba.png"), d)$error)
})

# --- which photos a version bump has to re-read -----------------------------

test_that("the libvips hasalpha rule reads band count against interpretation", {
  # Band count alone is ambiguous: CMYK has 4 bands and no alpha, RGBA has 4
  # and does. Getting this wrong re-fingerprints every CMYK TIFF for nothing.
  expect_false(dd_has_alpha(1L, "b-w"))
  expect_true( dd_has_alpha(2L, "b-w"))       # grey + alpha
  expect_false(dd_has_alpha(3L, "srgb"))
  expect_true( dd_has_alpha(4L, "srgb"))      # RGBA
  expect_false(dd_has_alpha(4L, "cmyk"))      # not alpha
  expect_true( dd_has_alpha(5L, "cmyk"))      # CMYK + alpha
  expect_false(dd_has_alpha(NA_integer_, "srgb"))
})

test_that("the vipsheader line is parsed from the right", {
  # A path may itself contain ", " or ": ", so the leading path is not a safe
  # anchor; the trailing three fields always are.
  h <- dd_parse_vipsheader("/l/a.png: 1800x1200 uchar, 4 bands, srgb, pngload")
  expect_equal(h$bands, 4L)
  expect_equal(h$interp, "srgb")

  odd <- dd_parse_vipsheader(
    "/l/Trip: Rome, Italy/x.tif: 640x480 uchar, 4 bands, cmyk, tiffload")
  expect_equal(odd$bands, 4L)
  expect_equal(odd$interp, "cmyk")
  expect_false(dd_has_alpha(odd$bands, odd$interp))

  expect_true(is.na(dd_parse_vipsheader("garbage")$bands))
  expect_true(is.na(dd_parse_vipsheader(character(0))$bands))
})
