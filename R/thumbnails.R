# Lazy review-thumbnail cache. The stored fingerprint is for matching, not
# viewing, so the review app needs real thumbnails. We generate them only for
# photos that belong to a group (far fewer than the full library), one targeted
# SMB read each, cached locally and reused on subsequent launches.

#' Ensure a cached JPEG thumbnail exists for each given photo.
#'
#' @param photos A data.frame with `photo_id` and `path`.
#' @param cfg A config list (uses `thumb_dir`).
#' @param size Longest-edge pixel size for the thumbnail.
#' @return A character vector of thumbnail paths (named by photo_id).
#' @export
dd_ensure_thumbs <- function(photos, cfg, size = 320L) {
  dir.create(cfg$thumb_dir, recursive = TRUE, showWarnings = FALSE)
  # vipsthumbnail resolves a relative -o path against the INPUT image's
  # directory, so the destination must be absolute.
  thumb_dir <- normalizePath(cfg$thumb_dir, mustWork = TRUE)
  out <- character(nrow(photos))
  for (i in seq_len(nrow(photos))) {
    dest <- file.path(thumb_dir, paste0(photos$photo_id[i], ".jpg"))
    if (!file.exists(dest) && file.exists(photos$path[i])) {
      # vipsthumbnail reads the original once and writes a small sRGB JPEG.
      # system2 builds a shell command line without quoting, so shQuote each
      # argument to keep spaces/awkward characters in filenames safe.
      status <- tryCatch(
        system2("vipsthumbnail",
                c(shQuote(photos$path[i]), "--size", paste0(size, "x", size),
                  "-o", shQuote(paste0(dest, "[Q=82]"))),
                stdout = FALSE, stderr = FALSE),
        error = function(e) 1L)
      if (!identical(status, 0L)) dest <- NA_character_
    } else if (!file.exists(dest)) {
      dest <- NA_character_
    }
    out[i] <- dest
  }
  stats::setNames(out, photos$photo_id)
}

#' Thumbnails for all grouped photos (convenience wrapper around the store).
#'
#' @param con A DBIConnection.
#' @param cfg A config list.
#' @param size Longest-edge pixel size.
#' @return A character vector of thumbnail paths named by photo_id.
#' @export
dd_thumbs_for_groups <- function(con, cfg, size = 320L) {
  photos <- DBI::dbGetQuery(con, "
    SELECT DISTINCT p.photo_id, p.path
      FROM photos p JOIN groups g USING (photo_id)")
  if (nrow(photos) == 0L) return(stats::setNames(character(0), character(0)))
  dd_ensure_thumbs(photos, cfg, size = size)
}
