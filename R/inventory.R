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

# Paths arrive as raw UTF-8 bytes. rawToChar() leaves the result marked
# "unknown", so R and RSQLite reinterpret it in the native encoding: under a
# C/POSIX locale a non-ASCII path is then stored escaped (caf<c3><a9>-...),
# which breaks the resume filter for that file and puts a non-existent path in
# the generated move script. Marking UTF-8 makes the round-trip byte-exact
# whatever the locale.
dd_b64dec <- function(x) {
  out <- vapply(x, function(s) {
    if (is.na(s) || !nzchar(s)) return("")
    rawToChar(base64enc::base64decode(s))
  }, character(1), USE.NAMES = FALSE)
  Encoding(out) <- "UTF-8"
  out
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
#' @param force Paths to fingerprint even when size and mtime still match, for
#'   when the stored value is stale because the *algorithm* changed rather than
#'   the file. See [dd_alpha_photos()].
#' @return Number of files written to the todo list, invisibly.
#' @export
dd_resume_todo <- function(con, enum_tsv, todo_path,
                           force = character(0)) {
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
  # `force` overrides the size/mtime match: the file is unchanged, but what we
  # stored about it is not what the current code would compute. Nothing else
  # can express that, since the resume key only knows whether the FILE moved on.
  keep <- !key(enum$path, enum$size, enum$mtime) %in% done_keys |
    enum$path %in% force
  todo <- enum[keep, , drop = FALSE]

  con_out <- file(todo_path, "wb")
  on.exit(close(con_out))
  if (nrow(todo)) {
    nul <- as.raw(0L)
    bytes <- unlist(lapply(todo$path, function(p) c(charToRaw(p), nul)))
    writeBin(bytes, con_out)
  }
  invisible(nrow(todo))
}

# Staging shards, ordered oldest-run-first.
#
# Order matters and lexicographic order will not do it: the shard name carries a
# pid, and pids are neither chronological across runs nor numerically ordered as
# strings ("shard.999" sorts after "shard.10000"), so the stale row could win the
# upsert. The UTC run stamp in the name is the only chronological part, hence
# stamp first, then mtime, then name.
dd_staging_files <- function(dir, pattern) {
  f <- list.files(dir, pattern = pattern, full.names = TRUE)
  if (length(f) < 2L) return(f)
  base <- basename(f)
  stamp <- sub("^shard\\.([0-9]{8}T[0-9]{6}Z)\\..*$", "\\1", base)
  f[order(stamp, file.mtime(f), base)]
}

#' Import all staging + error files from the staging dir into the store.
#'
#' Shards are merged oldest-run-first, so a path that appears in more than one
#' shard -- a file that changed between inventory runs -- ends up with its most
#' recent row. Each shard is removed as soon as it has merged, so no later run
#' can re-apply a stale row and the returned counts are rows merged *this* run
#' rather than every row ever staged. Pass `prune = FALSE` to keep the shards
#' for debugging; an interrupted merge leaves exactly the not-yet-merged shards
#' behind, and re-running is safe because the upsert is idempotent.
#'
#' A file that failed to decode on an earlier run and fingerprints successfully
#' now has its `errors` row dropped, so `dd_status()`'s "unreadable" count
#' reflects the current state of the library rather than every failure ever
#' seen.
#'
#' @param con A DBIConnection.
#' @param cfg A config list (uses `cfg$staging_dir`).
#' @param quiet Logical; suppress the merge progress bar.
#' @param prune Logical; delete each shard once it has merged successfully.
#' @return A list with counts `photos`, `errors` and `cleared` (stale error
#'   rows removed), invisibly.
#' @export
dd_import_staging <- function(con, cfg, quiet = FALSE, prune = TRUE) {
  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")

  data_files <- dd_staging_files(cfg$staging_dir, "\\.tsv$")
  n_photos <- 0L
  pb <- dd_progress(length(data_files), "merge", quiet = quiet)
  for (f in data_files) {
    if (file.size(f) > 0L) {
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
      # Commit the shard before it is removed: on an error the transaction
      # rolls back, the loop aborts, and the shard is still on disk.
      DBI::dbWithTransaction(con, dd_db_upsert_photos(con, df))
      n_photos <- n_photos + nrow(df)
    }
    if (isTRUE(prune)) unlink(f)
    pb$tick()
  }
  pb$done()

  err_files <- dd_staging_files(cfg$staging_dir, "\\.err$")
  n_err <- 0L
  for (f in err_files) {
    if (file.size(f) > 0L) {
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
      DBI::dbWithTransaction(con, dd_upsert(con, "errors", edf,
                                            key_cols = "path"))
      n_err <- n_err + nrow(edf)
    }
    if (isTRUE(prune)) unlink(f)
  }

  # A path that now has a photos row was read successfully, so any errors row
  # left over from a previous run is stale. Without this the "unreadable" count
  # only ever grows, and a file fixed by installing a missing vips loader is
  # reported broken forever.
  n_cleared <- DBI::dbExecute(
    con, "DELETE FROM errors WHERE path IN (SELECT path FROM photos)")

  invisible(list(photos = n_photos, errors = n_err, cleared = n_cleared))
}
