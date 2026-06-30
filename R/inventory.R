# Import sharded staging files (produced by the shell worker) into SQLite.
#
# Staging line format (tab-delimited; text fields base64-encoded so the format
# stays line-safe for any filename):
#   b64path  b64relpath  size  mtime  inode  format  width  height
#   file_hash  pixel_hash  meta_hash  fingerprint  b64capture  b64camera
#   meta_count
#
# Error line format (tab-delimited):
#   b64path  b64reason

dd_b64dec <- function(x) {
  vapply(x, function(s) {
    if (is.na(s) || !nzchar(s)) return("")
    rawToChar(base64enc::base64decode(s))
  }, character(1), USE.NAMES = FALSE)
}

dd_staging_cols <- c(
  "b64path", "b64relpath", "size", "mtime", "inode", "format", "width",
  "height", "file_hash", "pixel_hash", "meta_hash", "fingerprint",
  "b64capture", "b64camera", "meta_count"
)

#' Resume filter: from an enumeration TSV, write the NUL-delimited list of paths
#' that still need fingerprinting (new or changed since last inventory).
#'
#' A file is skipped only when an existing `photos` row matches on path, size,
#' and mtime -- so resumed runs read nothing new over SMB.
#'
#' @param con A DBIConnection.
#' @param enum_tsv Path to the enumeration TSV (b64path, size, mtime, inode).
#' @param todo_path Output path for the NUL-delimited todo list.
#' @return Number of files written to the todo list, invisibly.
#' @export
dd_resume_todo <- function(con, enum_tsv, todo_path) {
  if (!file.exists(enum_tsv) || file.size(enum_tsv) == 0L) {
    file.create(todo_path)
    return(invisible(0L))
  }
  enum <- utils::read.table(
    enum_tsv, sep = "\t", quote = "", comment.char = "", header = FALSE,
    col.names = c("b64path", "size", "mtime", "inode"),
    colClasses = "character", stringsAsFactors = FALSE
  )
  enum$path <- dd_b64dec(enum$b64path)
  enum$size <- as.integer(enum$size)
  enum$mtime <- as.integer(enum$mtime)

  have <- DBI::dbGetQuery(con, "SELECT path, size, mtime FROM photos")
  key <- function(p, s, m) paste(p, s, m, sep = "\x1f")
  done_keys <- if (nrow(have)) key(have$path, have$size, have$mtime) else
    character(0)
  todo <- enum[!key(enum$path, enum$size, enum$mtime) %in% done_keys, ,
               drop = FALSE]

  con_out <- file(todo_path, "wb")
  on.exit(close(con_out))
  if (nrow(todo)) {
    nul <- as.raw(0L)
    bytes <- unlist(lapply(todo$path, function(p) c(charToRaw(p), nul)))
    writeBin(bytes, con_out)
  }
  invisible(nrow(todo))
}

#' Import all staging + error files from the staging dir into the store.
#'
#' @param con A DBIConnection.
#' @param cfg A config list (uses `cfg$staging_dir`).
#' @return A list with counts `photos` and `errors`, invisibly.
#' @export
dd_import_staging <- function(con, cfg) {
  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")

  data_files <- list.files(cfg$staging_dir, pattern = "\\.tsv$",
                           full.names = TRUE)
  n_photos <- 0L
  for (f in data_files) {
    if (file.size(f) == 0L) next
    raw <- utils::read.table(
      f, sep = "\t", quote = "", comment.char = "", header = FALSE,
      col.names = dd_staging_cols, colClasses = "character",
      stringsAsFactors = FALSE, na.strings = c("", "NA")
    )
    df <- data.frame(
      path = dd_b64dec(raw$b64path),
      rel_path = dd_b64dec(raw$b64relpath),
      size = as.integer(raw$size),
      mtime = as.integer(raw$mtime),
      inode = as.integer(raw$inode),
      format = raw$format,
      width = as.integer(raw$width),
      height = as.integer(raw$height),
      file_hash = raw$file_hash,
      pixel_hash = raw$pixel_hash,
      meta_hash = raw$meta_hash,
      fingerprint = raw$fingerprint,
      capture_time = dd_b64dec(raw$b64capture),
      camera = dd_b64dec(raw$b64camera),
      meta_count = as.integer(raw$meta_count),
      inventoried_at = now,
      stringsAsFactors = FALSE
    )
    # Drop within-batch duplicate paths, keeping the last occurrence.
    df <- df[!duplicated(df$path, fromLast = TRUE), , drop = FALSE]
    n_photos <- n_photos + nrow(df)
    dd_db_upsert_photos(con, df)
  }

  err_files <- list.files(cfg$staging_dir, pattern = "\\.err$",
                          full.names = TRUE)
  n_err <- 0L
  for (f in err_files) {
    if (file.size(f) == 0L) next
    raw <- utils::read.table(
      f, sep = "\t", quote = "", comment.char = "", header = FALSE,
      col.names = c("b64path", "b64reason"), colClasses = "character",
      stringsAsFactors = FALSE
    )
    edf <- data.frame(
      path = dd_b64dec(raw$b64path),
      reason = dd_b64dec(raw$b64reason),
      logged_at = now,
      stringsAsFactors = FALSE
    )
    edf <- edf[!duplicated(edf$path, fromLast = TRUE), , drop = FALSE]
    n_err <- n_err + nrow(edf)
    dd_upsert(con, "errors", edf, key_cols = "path")
  }

  invisible(list(photos = n_photos, errors = n_err))
}
