# Perceptual fingerprint helpers.
#
# The worker stores the fingerprint as a lowercase hex string (dHash bits packed
# MSB-first). For a grid of side `g`, dHash produces g*g bits; the hex string has
# ceil(g*g / 4) characters.

# Version of the fingerprinting algorithm in _fingerprint-one.sh. Bump when a
# change makes new fingerprints incomparable with stored ones; inventory then
# re-fingerprints the photos the change affects (see dd_alpha_photos()).
#
#   1  dHash over a raw stream that kept the alpha band, so every image with
#      alpha hashed to the same alternating checkerboard and they all grouped
#      together regardless of content.
#   2  band 0 extracted before the dHash, and the raw byte count checked.
dd_fingerprint_version <- 2L

#' Expand a hex fingerprint string to an integer bit vector (0/1).
#'
#' @param hex A single hex string, or a character vector of them.
#' @param nbits Optional expected number of bits; result is trimmed/padded.
#' @return If `hex` is length 1, an integer vector of bits. If longer, a list.
#' @export
dd_fingerprint_bits <- function(hex, nbits = NULL) {
  one <- function(h) {
    if (is.na(h) || !nzchar(h)) return(integer(0))
    nyb <- utf8ToInt(tolower(h))
    val <- ifelse(nyb >= utf8ToInt("a"), nyb - utf8ToInt("a") + 10L,
                  nyb - utf8ToInt("0"))
    bits <- unlist(lapply(val, function(v) as.integer(intToBits(v))[4:1]))
    if (!is.null(nbits)) length(bits) <- nbits
    bits[is.na(bits)] <- 0L
    bits
  }
  if (length(hex) == 1L) one(hex) else lapply(hex, one)
}

#' Hamming distance between two equal-length hex fingerprints.
#'
#' @param a,b Hex fingerprint strings (scalars).
#' @return Integer Hamming distance, or NA if either is empty.
#' @export
dd_hamming <- function(a, b) {
  ba <- dd_fingerprint_bits(a)
  bb <- dd_fingerprint_bits(b)
  if (length(ba) == 0L || length(bb) == 0L) return(NA_integer_)
  n <- max(length(ba), length(bb))
  length(ba) <- n; length(bb) <- n
  ba[is.na(ba)] <- 0L; bb[is.na(bb)] <- 0L
  sum(ba != bb)
}

# libvips' own hasalpha rule (vips_image_hasalpha): the band count alone is
# ambiguous, since a CMYK image has 4 bands and no alpha while an RGBA one has
# 4 bands and does. `interp` is vipsheader's interpretation field.
dd_has_alpha <- function(bands, interp) {
  interp <- tolower(as.character(interp))
  limit <- ifelse(interp %in% c("b-w", "grey16"), 1L,
                  ifelse(interp == "cmyk", 4L, 3L))
  !is.na(bands) & bands > limit
}

# Parse one `vipsheader <path>` summary line. The format is
#   <path>: <W>x<H> <fmt>, <n> bands, <interpretation>, <loader>
# Read the trailing fields FROM THE RIGHT: a path may itself contain ", " or
# ": ", so anchoring on the leading path would mis-split those.
dd_parse_vipsheader <- function(line) {
  na <- list(bands = NA_integer_, interp = NA_character_)
  if (length(line) != 1L || is.na(line) || !nzchar(line)) return(na)
  f <- strsplit(line, ", ", fixed = TRUE)[[1L]]
  if (length(f) < 3L) return(na)
  n <- length(f)
  bands <- suppressWarnings(as.integer(sub("[^0-9].*$", "",
                                           trimws(f[[n - 2L]]))))
  list(bands = bands, interp = trimws(f[[n - 1L]]))
}

#' Photos whose stored fingerprint predates the alpha fix.
#'
#' Finds the photos an algorithm bump actually affects, so a repair re-reads
#' those and not the whole library. Two stages, cheapest first: JPEG carries no
#' alpha channel at all, so `jpegload` rows are excluded without touching the
#' filesystem; every other row is then settled by reading its *header* only, at
#' no cost in transferred pixels.
#'
#' Photos whose file has gone are skipped -- a missing file is inventory's
#' business, not this function's.
#'
#' @param con A DBIConnection.
#' @param quiet Logical; suppress the progress bar.
#' @return Character vector of paths needing a fresh fingerprint.
#' @examples
#' \dontrun{
#' cfg <- dd_config("~/dundee/family-photos")
#' con <- dd_db_connect(cfg)
#' on.exit(DBI::dbDisconnect(con))
#'
#' length(dd_alpha_photos(con))
#' }
#' @export
dd_alpha_photos <- function(con, quiet = FALSE) {
  cand <- DBI::dbGetQuery(con, "
    SELECT path FROM photos
     WHERE format IS NULL OR format <> 'jpegload'")$path
  if (!length(cand)) return(character(0))
  cand <- cand[file.exists(cand)]
  if (!length(cand)) return(character(0))

  pb <- dd_progress(length(cand), "alpha probe", quiet = quiet)
  hit <- vapply(cand, function(p) {
    pb$tick()
    line <- suppressWarnings(tryCatch(
      system2("vipsheader", shQuote(p), stdout = TRUE, stderr = FALSE),
      error = function(e) character()))
    if (!length(line)) return(FALSE)
    h <- dd_parse_vipsheader(line[[1L]])
    isTRUE(dd_has_alpha(h$bands, h$interp))
  }, logical(1), USE.NAMES = FALSE)
  pb$done()
  cand[hit]
}
