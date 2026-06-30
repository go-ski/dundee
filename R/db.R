# SQLite store: schema, connection, and idempotent upserts.

#' Connect to the dundee SQLite store.
#'
#' @param cfg A config list (see [dd_config()]).
#' @param create Logical; create parent directory if missing.
#' @return A DBIConnection. Caller is responsible for `DBI::dbDisconnect()`.
#' @export
dd_db_connect <- function(cfg, create = TRUE) {
  if (create) {
    dir.create(dirname(cfg$db_path), recursive = TRUE, showWarnings = FALSE)
  }
  con <- DBI::dbConnect(RSQLite::SQLite(), cfg$db_path)
  DBI::dbExecute(con, "PRAGMA journal_mode = WAL;")
  DBI::dbExecute(con, "PRAGMA foreign_keys = ON;")
  con
}

#' Initialise (or migrate to) the dundee schema. Idempotent.
#'
#' @param con A DBIConnection from [dd_db_connect()].
#' @return `con`, invisibly.
#' @export
dd_db_init <- function(con) {
  stmts <- c(
    "CREATE TABLE IF NOT EXISTS photos (
       photo_id      INTEGER PRIMARY KEY AUTOINCREMENT,
       path          TEXT NOT NULL UNIQUE,
       rel_path      TEXT,
       size          INTEGER,
       mtime         INTEGER,
       inode         INTEGER,
       format        TEXT,
       width         INTEGER,
       height        INTEGER,
       file_hash     TEXT,
       pixel_hash    TEXT,
       meta_hash     TEXT,
       fingerprint   TEXT,
       capture_time  TEXT,
       camera        TEXT,
       meta_count    INTEGER,
       inventoried_at TEXT
     );",
    "CREATE INDEX IF NOT EXISTS idx_photos_pixel ON photos(pixel_hash);",
    "CREATE INDEX IF NOT EXISTS idx_photos_file  ON photos(file_hash);",
    "CREATE TABLE IF NOT EXISTS errors (
       path        TEXT NOT NULL UNIQUE,
       reason      TEXT,
       logged_at   TEXT
     );",
    "CREATE TABLE IF NOT EXISTS groups (
       group_id    INTEGER NOT NULL,
       photo_id    INTEGER NOT NULL REFERENCES photos(photo_id),
       tier        TEXT NOT NULL,
       PRIMARY KEY (group_id, photo_id)
     );",
    "CREATE INDEX IF NOT EXISTS idx_groups_photo ON groups(photo_id);",
    "CREATE TABLE IF NOT EXISTS decisions (
       photo_id    INTEGER PRIMARY KEY REFERENCES photos(photo_id),
       group_id    INTEGER,
       preferred   INTEGER NOT NULL,
       decided_by  TEXT,
       decided_at  TEXT
     );",
    "CREATE TABLE IF NOT EXISTS moves (
       photo_id    INTEGER PRIMARY KEY REFERENCES photos(photo_id),
       src         TEXT NOT NULL,
       dest        TEXT NOT NULL,
       state       TEXT NOT NULL DEFAULT 'planned',
       moved_at    TEXT
     );"
  )
  for (s in stmts) DBI::dbExecute(con, s)
  invisible(con)
}

# Internal: upsert a data.frame of rows into `tbl` keyed on `key_cols`,
# using a temporary staging table + INSERT .. ON CONFLICT. Idempotent.
dd_upsert <- function(con, tbl, df, key_cols) {
  if (nrow(df) == 0L) return(invisible(0L))
  cols <- names(df)
  tmp <- paste0("_stage_", tbl)
  DBI::dbWriteTable(con, tmp, df, overwrite = TRUE, temporary = TRUE)
  on.exit(DBI::dbRemoveTable(con, tmp), add = TRUE)

  set_cols <- setdiff(cols, key_cols)
  set_clause <- paste(sprintf("%s = excluded.%s", set_cols, set_cols),
                      collapse = ", ")
  collist <- paste(cols, collapse = ", ")
  conflict <- paste(key_cols, collapse = ", ")
  sql <- sprintf(
    "INSERT INTO %s (%s) SELECT %s FROM %s
       WHERE true
     ON CONFLICT(%s) DO UPDATE SET %s;",
    tbl, collist, collist, tmp, conflict, set_clause
  )
  n <- DBI::dbExecute(con, sql)
  invisible(n)
}

#' Upsert photo rows into the store (keyed on `path`).
#'
#' @param con A DBIConnection.
#' @param df A data.frame of photo columns including `path`.
#' @return Number of rows affected, invisibly.
#' @export
dd_db_upsert_photos <- function(con, df) {
  dd_upsert(con, "photos", df, key_cols = "path")
}
