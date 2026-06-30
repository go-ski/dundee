# Perceptual fingerprint helpers.
#
# The worker stores the fingerprint as a lowercase hex string (dHash bits packed
# MSB-first). For a grid of side `g`, dHash produces g*g bits; the hex string has
# ceil(g*g / 4) characters.

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
