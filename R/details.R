# Rich per-photo metadata for the review app, read on demand for the group being
# reviewed rather than during inventory.
#
# The reviewer decides on image quality, location and capture date. Only two of
# those reach the store: the fingerprint worker keeps capture_time and camera and
# hashes everything else away, and there is no GPS column at all. Adding them to
# the pipeline would mean re-fingerprinting the whole library; groups are small
# and a human is waiting, so reading the group's own originals is cheaper and
# gives the full metadata surface instead of a fixed handful of columns.
#
# The read follows the same discipline as inst/bin/_fingerprint-one.sh: copy the
# original off the library exactly ONCE, then derive the metadata, the thumbnail
# and the viewer's cached copy from that local file.

# Fields in the order dd_detail_tags requests them. Kept parallel deliberately:
# exiftool -T emits one field per requested tag, so the two vectors zip.
dd_detail_fields <- c(
  "megapixels", "jpeg_quality", "chroma", "encoding", "bits", "icc",
  "capture", "create_date", "modify_date", "model", "lens", "software",
  "gps_alt", "city", "state", "country",
  "description", "caption", "keywords", "rating", "artist", "copyright",
  "title"
)

dd_detail_tags <- c(
  "-Megapixels", "-JPEGQualityEstimate", "-YCbCrSubSampling",
  "-EncodingProcess", "-BitsPerSample", "-ProfileDescription",
  "-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-Model", "-LensModel",
  "-Software",
  "-GPSAltitude", "-City", "-State", "-Country",
  "-ImageDescription", "-Caption-Abstract", "-Keywords", "-Rating", "-Artist",
  "-Copyright", "-Title"
)

# Coordinates in decimal, which is what the review app shows and what a map link
# needs. These cannot join the list above: -n is a global switch, and it would
# also strip the units from GPSAltitude and turn YCbCrSubSampling into "2 1".
dd_detail_n_fields <- c("gps_lat", "gps_lon")
dd_detail_n_tags <- c("-GPSLatitude", "-GPSLongitude")

# Bumped whenever the set of fields read above changes. A cached row written by
# an older version decodes with the new fields as NA, which is indistinguishable
# from a photo that genuinely lacks them -- so the version is compared, not just
# size and mtime.
dd_details_version <- 2L

# Every field a cached row can hold, in one place so the encoder, the decoder
# and dd_member_table() cannot drift apart.
dd_detail_all_fields <- function() {
  c(dd_detail_fields, dd_detail_n_fields, "makernotes")
}

# Read every field from one local file. Three exiftool calls, all against the
# local copy, so none of them touches the library:
#   1. the fixed tag list, as a single tab-separated line (-T also flattens
#      embedded tabs and newlines, so the field count is always stable)
#   2. the same again under -n, for decimal coordinates
#   3. MakerNotes, which is a GROUP name and expands to one line per maker-note
#      tag -- it cannot go in the fixed list without shifting every column after
#      it. Presence is the signal: a camera original keeps them, a re-export
#      strips them.
dd_read_details <- function(path) {
  # One -T line back into a named vector; "-" is how -T reports a tag the file
  # does not carry.
  tabbed <- function(args, fields) {
    out <- stats::setNames(rep(NA_character_, length(fields)), fields)
    line <- tryCatch(
      system2("exiftool", c(args, shQuote(path)), stdout = TRUE,
              stderr = FALSE),
      error = function(e) character(0))
    if (!length(line)) return(out)
    v <- strsplit(line[[1]], "\t", fixed = TRUE)[[1]]
    v[v == "-"] <- NA_character_
    n <- min(length(v), length(out))
    if (n > 0L) out[seq_len(n)] <- v[seq_len(n)]
    out
  }

  out <- tabbed(c("-m", "-q", "-T", dd_detail_tags), dd_detail_fields)
  dec <- tabbed(c("-m", "-q", "-T", "-n", dd_detail_n_tags),
                dd_detail_n_fields)
  mk <- tryCatch(
    system2("exiftool", c("-m", "-q", "-MakerNotes", shQuote(path)),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0))
  c(out, dec, makernotes = if (any(nzchar(mk))) "yes" else NA_character_)
}

# Flat key<TAB>value lines, one per field. Not YAML or JSON: this is a cache of
# short scalars, and a flat format needs no parser and no new dependency.
dd_details_encode <- function(v) {
  keep <- !is.na(v)
  paste(sprintf("%s\t%s", names(v)[keep], v[keep]), collapse = "\n")
}

dd_details_decode <- function(txt) {
  fields <- dd_detail_all_fields()
  out <- stats::setNames(rep(NA_character_, length(fields)), fields)
  if (is.na(txt) || !nzchar(txt)) return(out)
  parts <- strsplit(strsplit(txt, "\n", fixed = TRUE)[[1]], "\t", fixed = TRUE)
  for (p in parts) {
    if (length(p) >= 2L && p[[1]] %in% fields) {
      out[[p[[1]]]] <- paste(p[-1], collapse = "\t")
    }
  }
  out
}

#' Metadata, thumbnail and viewer copy for one group's photos.
#'
#' Reads each original exactly once and derives everything from that read: the
#' full metadata (cached in the store), the review thumbnail, and the
#' full-size copy the comparison viewer displays (cached on disk, bounded by
#' `review_cache`). A photo whose metadata is cached and whose viewer copy is
#' still present is not read at all.
#'
#' @param con A DBIConnection.
#' @param photos A data.frame with `photo_id`, `path`, `size` and `mtime`.
#' @param cfg A config list.
#' @return A data.frame with one row per photo: `photo_id`, every field in
#'   `dd_detail_fields`, `makernotes`, and `viewer` (the cached full-size path,
#'   or `NA` when it could not be produced).
#' @export
dd_group_details <- function(con, photos, cfg) {
  dir.create(cfg$temp_dir, recursive = TRUE, showWarnings = FALSE)
  fields <- dd_detail_all_fields()
  rows <- vector("list", nrow(photos))

  for (i in seq_len(nrow(photos))) {
    pid <- as.integer(photos$photo_id[i])
    cached <- DBI::dbGetQuery(
      con, "SELECT size, mtime, version, tags FROM details WHERE photo_id = ?",
      params = list(pid))
    # Stale if the original changed under us -- size and mtime are the same pair
    # the inventory resume filter trusts (R/inventory.R) -- or if the row was
    # written before this version read the fields it now reads. Without the
    # version check a row predating gps_lat would decode it as NA, which is
    # indistinguishable from a photo that has no location.
    fresh <- nrow(cached) == 1L &&
      identical(as.integer(cached$size[[1]]), as.integer(photos$size[i])) &&
      identical(as.integer(cached$mtime[[1]]), as.integer(photos$mtime[i])) &&
      identical(as.integer(cached$version[[1]]), dd_details_version)

    viewer <- dd_cache_get(pid, cfg)
    want_viewer <- as.integer(cfg$review_cache) > 0L
    thumb <- file.path(cfg$thumb_dir, paste0(pid, ".jpg"))

    if (fresh && (!want_viewer || !is.na(viewer)) && file.exists(thumb)) {
      rows[[i]] <- c(photo_id = as.character(pid),
                     dd_details_decode(cached$tags[[1]]),
                     viewer = viewer)
      next
    }

    # One read off the library, then everything from the local copy.
    vals <- stats::setNames(rep(NA_character_, length(fields)), fields)
    if (file.exists(photos$path[i])) {
      local <- file.path(cfg$temp_dir,
                         paste0("review-", pid, ".", dd_ext(photos$path[i])))
      on_local <- file.copy(photos$path[i], local, overwrite = TRUE)
      if (on_local) {
        vals <- dd_read_details(local)
        dir.create(cfg$thumb_dir, recursive = TRUE, showWarnings = FALSE)
        if (!file.exists(thumb)) dd_thumb_render(local, thumb)
        viewer <- if (want_viewer) {
          dd_cache_put(pid, local, cfg, orig_path = photos$path[i])
        } else NA_character_
        unlink(local)
        DBI::dbExecute(
          con, "INSERT INTO details(photo_id, size, mtime, version, tags, read_at)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(photo_id) DO UPDATE SET
                  size = excluded.size, mtime = excluded.mtime,
                  version = excluded.version, tags = excluded.tags,
                  read_at = excluded.read_at",
          params = list(pid, as.integer(photos$size[i]),
                        as.integer(photos$mtime[i]), dd_details_version,
                        dd_details_encode(vals),
                        format(Sys.time(), "%Y-%m-%dT%H:%M:%S")))
      }
    }
    rows[[i]] <- c(photo_id = as.character(pid), vals, viewer = viewer)
  }

  out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  out$photo_id <- as.integer(out$photo_id)
  rownames(out) <- NULL
  out
}
