# Bounded local cache of full-size originals, for the review app's comparison
# viewer. The metadata fetch in R/details.R already copies each original off the
# library once; this keeps that copy around while the reviewer is looking at the
# group instead of deleting it, so opening the viewer costs no further reads.
#
# Deliberately separate from the `details` table and from thumbs/: those are
# small and permanent, these are full-size files and must be capped.

# Formats a browser will render from raw bytes. Anything else -- TIFF, HEIC and
# every RAW -- has to be converted before it can be displayed at all.
dd_web_formats <- c("jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "avif")

# Lowercased extension with no dot; "" when there is none.
dd_ext <- function(path) {
  e <- sub(".*\\.", "", basename(path))
  if (identical(e, basename(path))) "" else tolower(e)
}

dd_is_web_format <- function(path) dd_ext(path) %in% dd_web_formats

# Evict least-recently-used entries until at most `keep` remain. Recency is the
# file's mtime, which dd_cache_get() touches on every hit -- the filesystem is
# the only index, so there is no second source of truth to drift out of step.
# Returns the number of files removed.
dd_cache_evict <- function(dir, keep) {
  keep <- max(0L, as.integer(keep))
  files <- list.files(dir, full.names = TRUE)
  if (length(files) <= keep) return(invisible(0L))
  info <- file.info(files)
  # Newest first; ties broken by name so eviction is deterministic in tests and
  # on filesystems with coarse timestamps.
  ord <- order(info$mtime, basename(files), decreasing = c(TRUE, FALSE),
               method = "radix")
  doomed <- files[ord][seq.int(keep + 1L, length(files))]
  unlink(doomed)
  invisible(length(doomed))
}

# The cached file for a photo, or NA if it is not cached. A hit is touched, so
# the group being reviewed right now is the last thing to be evicted.
dd_cache_get <- function(photo_id, cfg) {
  hit <- list.files(cfg$orig_dir, pattern = paste0("^", photo_id, "\\."),
                    full.names = TRUE)
  if (!length(hit)) return(NA_character_)
  Sys.setFileTime(hit[[1]], Sys.time())
  hit[[1]]
}

# Put a local copy of `src` into the cache under `photo_id`, converting it first
# when a browser could not display it. `src` is the local temp copy made by
# dd_group_details(), never the original on the library.
#
# Returns the cached path, or NA when the conversion failed (a RAW format vips
# has no loader for, say) -- the caller still has metadata and a thumbnail, so a
# missing viewer image is a degraded view, not an error.
dd_cache_put <- function(photo_id, src, cfg, orig_path = src) {
  if (as.integer(cfg$review_cache) <= 0L) return(NA_character_)
  dir.create(cfg$orig_dir, recursive = TRUE, showWarnings = FALSE)
  dest_dir <- normalizePath(cfg$orig_dir, mustWork = TRUE)

  if (dd_is_web_format(orig_path)) {
    # Byte-for-byte, because judging JPEG artifacts against a re-encode would be
    # judging the re-encode.
    dest <- file.path(dest_dir, paste0(photo_id, ".", dd_ext(orig_path)))
    if (!file.copy(src, dest, overwrite = TRUE)) return(NA_character_)
  } else {
    # Lossless PNG so the conversion adds no artifacts of its own, capped on the
    # long edge because a full-resolution TIFF or RAW render is enormous.
    dest <- file.path(dest_dir, paste0(photo_id, ".png"))
    status <- tryCatch(
      system2("vipsthumbnail",
              c(shQuote(src), "--size", "4096x4096", "-o", shQuote(dest)),
              stdout = FALSE, stderr = FALSE),
      error = function(e) 1L)
    if (!identical(as.integer(status), 0L) || !file.exists(dest)) {
      return(NA_character_)
    }
  }
  dd_cache_evict(dest_dir, cfg$review_cache)
  if (file.exists(dest)) dest else NA_character_
}

#' Remove the review app's cached originals.
#'
#' The cache is rebuilt on demand from the library, so this only costs future
#' re-reads. Thumbnails and the `details` metadata cache are left alone.
#'
#' @param config A work directory, config path, or config list.
#' @return Number of files removed, invisibly.
#' @export
dd_cache_clear <- function(config = NULL) {
  cfg <- dd_as_config(config)
  n <- length(list.files(cfg$orig_dir))
  unlink(cfg$orig_dir, recursive = TRUE)
  message(sprintf("dundee: removed %d cached original(s)", n))
  invisible(n)
}
