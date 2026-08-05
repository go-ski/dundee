# R/project.R -- work directory as the project handle.
#
#   <work_dir>/config.yml            live, user-edited (the only file to edit)
#   <work_dir>/config.resolved.yml   snapshot written by every stage (provenance)
#   <work_dir>/config.history/       timestamped copies of prior config.yml
#   <work_dir>/dundee.sqlite, tmp/, staging/, thumbs/, enum.tsv, moves.{tsv,sh}
#
# `work_dir` is not a field in config.yml: it is where config.yml is. One
# directory per read-only library; the pipeline is never told twice.

`%||%` <- function(a, b) if (is.null(a)) b else a
na_if_empty <- function(x) if (length(x) && nzchar(x)) x else NULL

# packageVersion() errors when R/ has been source()d rather than installed
# (dev-test.R, tests/testthat/setup.R). Never let provenance break a dev run.
dd_pkg_version <- function() {
  tryCatch(as.character(utils::packageVersion("dundee")),
           error = function(e) "source")
}

# Derived, non-user-settable fields. Named here so the resolved snapshot can be
# re-read without every one of them tripping the unknown-key warning.
dd_derived_keys <- c("temp_dir", "staging_dir", "thumb_dir", "config_file")

# ---------------------------------------------------------------------------
# path utilities
# ---------------------------------------------------------------------------

# normalizePath() that resolves symlinks in whatever prefix already exists,
# without creating anything -- config loading must not mutate the filesystem.
dd_resolve_path <- function(p) {
  if (is.null(p) || !length(p) || !nzchar(p)) return(p)
  p <- path.expand(p)
  if (!grepl("^(/|[A-Za-z]:)", p)) p <- file.path(getwd(), p)
  tail <- character(0)
  cur <- p
  while (!file.exists(cur)) {
    parent <- dirname(cur)
    if (identical(parent, cur)) break
    tail <- c(basename(cur), tail)
    cur <- parent
  }
  cur <- normalizePath(cur, mustWork = FALSE)
  if (length(tail)) cur <- do.call(file.path, c(list(cur), as.list(tail)))
  sub("(?<=.)/+$", "", cur, perl = TRUE)
}

# Case-insensitive filesystems (APFS/HFS+ on macOS, SMB mounts) defeat a plain
# prefix test: /Volumes/Photo and /Volumes/photo are one directory. Probe the
# filesystem the paths actually live on -- tempdir() is often a different one --
# and cache per directory, since dd_config() is called on every stage.
dd_case_cache <- new.env(parent = emptyenv())

dd_fs_case_insensitive <- function(path = tempdir()) {
  dir <- path
  while (!dir.exists(dir) && dirname(dir) != dir) dir <- dirname(dir)
  key <- dir
  hit <- dd_case_cache[[key]]
  if (!is.null(hit)) return(hit)
  stem <- paste0(".dundee-Case-", Sys.getpid())
  probe <- file.path(dir, stem)
  on.exit(unlink(probe), add = TRUE)
  ok <- isTRUE(suppressWarnings(file.create(probe, showWarnings = FALSE)))
  res <- if (!ok) identical(Sys.info()[["sysname"]], "Darwin") else
    file.exists(file.path(dir, toupper(stem)))
  assign(key, res, envir = dd_case_cache)
  res
}

dd_paths_overlap <- function(a, b) {
  if (is.null(a) || is.null(b) || !length(a) || !length(b) ||
      !nzchar(a) || !nzchar(b)) return(FALSE)
  if (dd_fs_case_insensitive(a) || dd_fs_case_insensitive(b)) {
    a <- tolower(a); b <- tolower(b)
  }
  identical(a, b) ||
    startsWith(paste0(a, "/"), paste0(b, "/")) ||
    startsWith(paste0(b, "/"), paste0(a, "/"))
}

# ---------------------------------------------------------------------------
# which project am I working on?
# ---------------------------------------------------------------------------

#' Set the work directory for this R session.
#'
#' After `dd_use("~/dundee/family-photos")` every `dd_run_*()` call may be made
#' with no arguments at all.
#'
#' @param work_dir Path to an initialised dundee work directory.
#' @return The resolved work directory, invisibly.
#' @export
dd_use <- function(work_dir) {
  wd <- dd_resolve_path(work_dir)
  cfg_file <- file.path(wd, "config.yml")
  if (!file.exists(cfg_file)) {
    stop("dundee: no config.yml in ", wd,
         ". Run dd_init(\"", work_dir, "\") first.", call. = FALSE)
  }
  options(dundee.work_dir = wd)
  message("dundee: using ", wd)
  invisible(wd)
}

#' The active work directory.
#'
#' Resolution order: explicit argument, `options(dundee.work_dir)`,
#' `$DUNDEE_WORK`, `$DUNDEE_CONFIG`, `./config.yml`, `./work/config.yml`.
#'
#' @param work_dir Optional explicit path.
#' @return A resolved directory path.
#' @export
dd_work_dir <- function(work_dir = NULL) {
  cand <- c(work_dir,
            getOption("dundee.work_dir"),
            na_if_empty(Sys.getenv("DUNDEE_WORK")),
            na_if_empty(dirname(Sys.getenv("DUNDEE_CONFIG", ""))),
            if (file.exists("config.yml")) getwd(),
            if (file.exists(file.path("work", "config.yml"))) "work")
  cand <- cand[nzchar(cand) & cand != "."]
  if (!length(cand)) {
    stop("dundee: no work directory. Use dd_init(<dir>) to create one, ",
         "dd_use(<dir>) to select one, or set DUNDEE_WORK.", call. = FALSE)
  }
  dd_resolve_path(cand[[1]])
}

# ---------------------------------------------------------------------------
# creating and editing a project config
# ---------------------------------------------------------------------------

#' Initialise a dundee work directory for one read-only photo library.
#'
#' Copies the annotated template to `<work_dir>/config.yml` and fills in the
#' fields supplied here. Nothing is written outside `work_dir`; the library is
#' never touched. Edit `<work_dir>/config.yml` directly (with any text editor)
#' to change settings, then call [dd_config()] to re-validate.
#'
#' @param work_dir Directory to create/use. Everything dundee writes for this
#'   library lives here.
#' @param library_root Read-only root of the photo library.
#' @param ... Further scalar config fields, e.g. `ssh_host = "nas.local"`.
#' @param overwrite Replace an existing `config.yml` (the previous version is
#'   archived to `config.history/` either way).
#' @return The validated config list, invisibly.
#' @export
dd_init <- function(work_dir, library_root = NULL, ..., overwrite = FALSE) {
  wd <- dd_resolve_path(work_dir)
  if (!is.null(library_root)) {
    lr <- dd_resolve_path(library_root)
    if (dd_paths_overlap(lr, wd)) {
      stop("dundee: work_dir must not be the same as, inside, or containing ",
           "library_root.\n  library_root: ", lr, "\n  work_dir:     ", wd,
           call. = FALSE)
    }
    if (!dir.exists(lr)) {
      warning("dundee: library_root does not exist yet: ", lr, call. = FALSE)
    }
  }
  dir.create(wd, recursive = TRUE, showWarnings = FALSE)
  cfg_file <- file.path(wd, "config.yml")

  if (file.exists(cfg_file) && !isTRUE(overwrite)) {
    message("dundee: ", cfg_file, " already exists; leaving it in place ",
            "(pass overwrite = TRUE to reset it).")
    return(invisible(dd_config(wd)))
  }
  if (file.exists(cfg_file)) dd_archive_config(wd)

  tmpl <- dd_template_lines()
  fills <- c(list(library_root = library_root), list(...))
  fills <- fills[!vapply(fills, is.null, logical(1))]
  for (k in names(fills)) tmpl <- dd_template_set(tmpl, k, fills[[k]])
  writeLines(tmpl, cfg_file)
  message("dundee: wrote ", cfg_file,
          "\n  edit it directly if you need to change settings, then re-run.")

  invisible(dd_config(wd))
}

# Timestamped copy of the live config; returns the archive path (or NULL).
dd_archive_config <- function(work_dir) {
  cfg_file <- file.path(work_dir, "config.yml")
  if (!file.exists(cfg_file)) return(invisible(NULL))
  hist <- file.path(work_dir, "config.history")
  dir.create(hist, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(hist, format(Sys.time(), "config-%Y%m%d-%H%M%S.yml"))
  if (file.exists(dest)) return(invisible(dest))   # same second, same content
  file.copy(cfg_file, dest)
  invisible(dest)
}

# ---------------------------------------------------------------------------
# the annotated template
# ---------------------------------------------------------------------------

# Ships in inst/templates/config.yml so it survives installation. Edited
# textually rather than regenerated through yaml::as.yaml(), which would strip
# every comment. Falls back to the source tree when R/ has been source()d.
dd_template_lines <- function() {
  cands <- c(
    system.file("templates", "config.yml", package = "dundee"),
    file.path(na_if_empty(Sys.getenv("DUNDEE_SRC")) %||% ".",
              "inst", "templates", "config.yml"),
    file.path(getwd(), "inst", "templates", "config.yml"),
    file.path(getwd(), "..", "..", "inst", "templates", "config.yml")
  )
  cands <- cands[nzchar(cands) & file.exists(cands)]
  if (!length(cands)) {
    stop("dundee: config template not found; reinstall the package.",
         call. = FALSE)
  }
  readLines(cands[[1]])
}

# Replace `key: <anything>` in the template, preserving surrounding comments.
# Only scalar fields are settable this way; list fields are left to the editor.
dd_template_set <- function(lines, key, value) {
  if (length(value) != 1L) return(lines)
  hit <- grep(paste0("^\\s*", key, ":"), lines)
  scalar <- trimws(yaml::as.yaml(value, line.sep = "\n"))
  scalar <- sub("^---\\s*", "", scalar)
  repl <- sprintf("%s: %s", key, scalar)
  if (length(hit)) lines[hit[[1]]] <- repl else lines <- c(lines, repl)
  lines
}

#' Write the annotated example config somewhere for inspection.
#'
#' `dd_init()` is the normal entry point; this is for looking at the template.
#'
#' @param path Destination path.
#' @return `path`, invisibly.
#' @export
dd_config_example <- function(path = "config.example.yml") {
  writeLines(dd_template_lines(), path)
  invisible(path)
}

# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------

# `x` may be a work directory, a YAML path, a resolved config list, or NULL.
dd_config_source <- function(x = NULL) {
  if (is.list(x)) return(list(cfg = x))
  if (is.null(x)) x <- dd_work_dir()
  x <- dd_resolve_path(x)
  if (dir.exists(x)) {
    f <- file.path(x, "config.yml")
    if (!file.exists(f)) {
      stop("dundee: ", x, " is not an initialised work directory ",
           "(no config.yml). Run dd_init(\"", x, "\").", call. = FALSE)
    }
    return(list(file = f, work_dir = x))
  }
  if (!file.exists(x)) stop("dundee: no config file at ", x, call. = FALSE)
  list(file = x, work_dir = dd_resolve_path(dirname(x)))
}

# A typo (hamming_thresold:) used to be copied in and silently ignored, so the
# run completed with the default value -- the most expensive kind of failure.
dd_check_keys <- function(user, defaults) {
  known <- c(names(defaults), "work_dir", dd_derived_keys)
  bad <- setdiff(names(user), known)
  for (k in bad) {
    d <- known[which.min(utils::adist(k, known))]
    warning("dundee: unknown config key '", k, "'",
            if (utils::adist(k, d)[1, 1] <= 3)
              paste0(" -- did you mean '", d, "'?"),
            call. = FALSE)
  }
  invisible(bad)
}

# Type/range validation reported all at once, rather than as whatever error the
# first bad value happens to trigger three stages later.
dd_validate <- function(cfg) {
  err <- character(0)
  num <- function(k, lo, hi) {
    v <- suppressWarnings(as.integer(cfg[[k]])[1])
    if (is.na(v) || v < lo || v > hi) {
      err <<- c(err, sprintf("%s must be an integer in [%d, %d], got '%s'",
                             k, lo, hi, paste(cfg[[k]], collapse = " ")))
    }
    v
  }
  cfg$parallel         <- num("parallel", 1L, 256L)
  cfg$fingerprint_grid <- num("fingerprint_grid", 4L, 32L)
  cfg$lsh_bands        <- num("lsh_bands", 1L, 1024L)
  bits <- cfg$fingerprint_grid^2
  cfg$hamming_threshold <- num("hamming_threshold", 0L,
                               if (is.na(bits)) 1024L else bits)
  if (!is.na(bits) && !is.na(cfg$lsh_bands) && bits %% cfg$lsh_bands != 0L) {
    err <- c(err, sprintf("lsh_bands (%d) must divide fingerprint_grid^2 (%d)",
                          cfg$lsh_bands, bits))
  }
  if (!length(cfg$extensions)) err <- c(err, "extensions is empty")
  ok <- c("max_pixels", "max_filesize", "max_meta", "oldest_capture",
          "folder_priority")
  unk <- setdiff(cfg$preference_rules, ok)
  if (length(unk)) {
    err <- c(err, paste0("unknown preference_rules: ",
                         paste(unk, collapse = ", "),
                         " (allowed: ", paste(ok, collapse = ", "), ")"))
  }
  if (length(err)) {
    stop("dundee: invalid config:\n  - ", paste(err, collapse = "\n  - "),
         call. = FALSE)
  }
  cfg
}

#' Load and validate the config for a work directory.
#'
#' @param config A work directory, a YAML path, a config list, or `NULL` to use
#'   the active work directory (see [dd_work_dir()]).
#' @param require_library Require `library_root` to be set and to exist.
#' @param create Create the work directory if it is missing.
#' @return A validated config list with absolute paths.
#' @export
dd_config <- function(config = NULL, require_library = FALSE, create = TRUE) {
  src <- dd_config_source(config)
  if (!is.null(src$cfg)) return(src$cfg)

  defaults <- dd_config_defaults()
  user <- yaml::read_yaml(src$file)
  # An empty config.yml reads back as NULL, and a file containing a bare
  # scalar reads back as a character vector; neither is a mapping.
  if (!is.list(user)) {
    if (!is.null(user) && length(user)) {
      stop("config: ", src$file, " is not a YAML mapping (key: value).",
           call. = FALSE)
    }
    user <- list()
  }
  user <- user[!vapply(user, is.null, logical(1))]   # `key:` with no value
  dd_check_keys(user, defaults)
  cfg <- utils::modifyList(defaults,
                           user[intersect(names(user), names(defaults))])

  # The directory holding config.yml is the work directory. A `work_dir:` key
  # is honoured only when it disagrees, and only for backward compatibility.
  cfg$work_dir <- src$work_dir
  if (!is.null(user$work_dir)) {
    declared <- dd_resolve_path(user$work_dir)
    if (!identical(declared, src$work_dir)) {
      message("config: '", src$file, "' declares work_dir: ", declared,
              "\n  (legacy layout; honoured for now -- migrate with ",
              "dd_migrate(\"", src$file, "\"))")
      cfg$work_dir <- declared
    }
  }
  if (!is.null(user$temp_dir)) {
    message("config: 'temp_dir' is no longer user-configurable; scratch ",
            "space is always <work_dir>/tmp.")
  }

  cfg$extensions <- tolower(as.character(cfg$extensions))
  cfg <- dd_validate(cfg)

  if (require_library) {
    if (is.null(cfg$library_root) || !nzchar(cfg$library_root)) {
      stop("config: library_root must be set in ", src$file, call. = FALSE)
    }
    if (!dir.exists(cfg$library_root)) {
      stop("config: library_root does not exist: ", cfg$library_root,
           "\n  (is the share mounted?)", call. = FALSE)
    }
  }
  cfg$library_root <- dd_resolve_path(cfg$library_root)

  if (dd_paths_overlap(cfg$library_root, cfg$work_dir)) {
    stop("config: work_dir must not be the same as, nested inside, or ",
         "contain library_root.\n  library_root: ", cfg$library_root,
         "\n  work_dir:     ", cfg$work_dir, call. = FALSE)
  }

  if (isTRUE(create)) {
    dir.create(cfg$work_dir, recursive = TRUE, showWarnings = FALSE)
  }

  cfg$db_path     <- file.path(cfg$work_dir, basename(cfg$db_path))
  cfg$temp_dir    <- file.path(cfg$work_dir, "tmp")
  cfg$staging_dir <- file.path(cfg$work_dir, "staging")
  cfg$thumb_dir   <- file.path(cfg$work_dir, "thumbs")
  cfg$config_file <- src$file
  cfg
}

# Human-readable confirmation of what was loaded -- the fastest way to catch
# "I edited the wrong project's config".
dd_config_report <- function(cfg) {
  message("dundee project: ", basename(cfg$work_dir))
  message("  library_root : ", cfg$library_root %||% "<unset>",
          if (!is.null(cfg$library_root) && nzchar(cfg$library_root) &&
              !dir.exists(cfg$library_root)) "  (NOT MOUNTED)" else "")
  message("  work_dir     : ", cfg$work_dir)
  message("  store        : ", basename(cfg$db_path),
          if (file.exists(cfg$db_path))
            sprintf(" (%.1f MB)", file.size(cfg$db_path) / 1e6) else " (new)")
  message("  near-dup     : grid ", cfg$fingerprint_grid, ", threshold ",
          cfg$hamming_threshold, ", bands ", cfg$lsh_bands)
  invisible(cfg)
}

# ---------------------------------------------------------------------------
# provenance
# ---------------------------------------------------------------------------

# Called at the top of each dd_run_*(). Writes the resolved config beside the
# store -- provenance, and a stable absolute-path file for dd_app(), which
# chdirs. Only user-facing keys are written, so re-reading it is warning-free;
# derived paths go in the comment header.
dd_config_snapshot <- function(cfg) {
  out <- file.path(cfg$work_dir, "config.resolved.yml")
  keep <- c(names(dd_config_defaults()), "work_dir")
  body <- cfg[intersect(keep, names(cfg))]
  writeLines(c(
    sprintf("# dundee %s -- written %s. Do not edit; edit config.yml.",
            dd_pkg_version(), format(Sys.time())),
    sprintf("# derived: db=%s tmp=%s staging=%s thumbs=%s",
            cfg$db_path, cfg$temp_dir, cfg$staging_dir, cfg$thumb_dir),
    yaml::as.yaml(body)
  ), out)
  invisible(out)
}

# fingerprint_grid and library_root are baked into stored rows: changing the
# grid makes old and new fingerprints incomparable; changing library_root
# invalidates every stored absolute path. Both were silent corruptions.
dd_config_guard <- function(con, cfg, rebase = FALSE) {
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS meta (
                         key TEXT PRIMARY KEY, value TEXT)")
  get1 <- function(k) {
    v <- DBI::dbGetQuery(con, "SELECT value FROM meta WHERE key = ?",
                         params = list(k))
    if (nrow(v)) v$value[[1]] else NULL
  }
  set1 <- function(k, v) {
    DBI::dbExecute(con, "INSERT INTO meta(key, value) VALUES(?, ?)
                         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   params = list(k, as.character(v)))
  }
  grid <- get1("fingerprint_grid")
  if (!is.null(grid) && !identical(as.integer(grid), cfg$fingerprint_grid)) {
    stop("dundee: this store was built with fingerprint_grid = ", grid,
         " but config.yml says ", cfg$fingerprint_grid,
         ".\n  Fingerprints of different geometries are not comparable. ",
         "Restore the old value, or start a new work directory.",
         call. = FALSE)
  }
  root <- get1("library_root")
  if (!is.null(root) && !is.null(cfg$library_root) &&
      nzchar(cfg$library_root) && !identical(root, cfg$library_root) &&
      !isTRUE(rebase)) {
    stop("dundee: this store was built against library_root\n    ", root,
         "\n  but config.yml now says\n    ", cfg$library_root,
         "\n  Re-run with rebase = TRUE only if the same library was ",
         "re-mounted at a new path.", call. = FALSE)
  }
  set1("fingerprint_grid", cfg$fingerprint_grid)
  if (!is.null(cfg$library_root) && nzchar(cfg$library_root)) {
    set1("library_root", cfg$library_root)
  }
  set1("dundee_version", dd_pkg_version())
  invisible(TRUE)
}

# ---------------------------------------------------------------------------
# where am I?
# ---------------------------------------------------------------------------

#' Report the state of a dundee work directory.
#'
#' Read-only: it never applies the config guard, so it still works when the
#' config and the store have drifted apart.
#'
#' @param config A work directory, config path, or config list.
#' @return A one-row data frame of counts, invisibly.
#' @export
dd_status <- function(config = NULL) {
  cfg <- dd_config(config)
  dd_config_report(cfg)
  if (!file.exists(cfg$db_path)) {
    message("  store not created yet -- next: dd_run_inventory()")
    return(invisible(NULL))
  }
  con <- dd_db_connect(cfg)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  n <- function(sql) {
    v <- tryCatch(DBI::dbGetQuery(con, sql)[[1]], error = function(e) NA_integer_)
    if (length(v) != 1L || is.na(v)) 0L else as.integer(v)
  }
  out <- data.frame(
    photos  = n("SELECT COUNT(*) FROM photos"),
    errors  = n("SELECT COUNT(*) FROM errors"),
    groups  = n("SELECT COUNT(DISTINCT group_id) FROM groups"),
    grouped = n("SELECT COUNT(*) FROM groups"),
    decided = n("SELECT COUNT(*) FROM decisions"),
    planned = n("SELECT COUNT(*) FROM moves WHERE state = 'planned'"),
    done    = n("SELECT COUNT(*) FROM moves WHERE state = 'done'")
  )
  message(sprintf(
    paste("  photos %d (%d unreadable) | groups %d covering %d |",
          "decided %d | moves %d planned, %d done"),
    out$photos, out$errors, out$groups, out$grouped, out$decided,
    out$planned, out$done))
  nxt <- if (out$photos == 0L) "dd_run_inventory()" else
    if (out$groups == 0L) "dd_run_analyze()" else
      if (out$decided < out$grouped) "dd_app()  # review remaining groups" else
        if (out$planned == 0L && out$done == 0L) "dd_run_plan(bulk = TRUE)" else
          if (out$planned > 0L) "dd_run_move(execute = TRUE)" else "nothing"
  message("  next: ", nxt)
  invisible(out)
}

# ---------------------------------------------------------------------------
# migration from the old layout
# ---------------------------------------------------------------------------

#' Move a legacy `config.yml` into its work directory.
#'
#' @param path Existing config file written under the old convention.
#' @param remove Delete the original after a successful copy.
#' @return The new work directory, invisibly.
#' @export
dd_migrate <- function(path = "config.yml", remove = FALSE) {
  user <- yaml::read_yaml(path)
  wd <- dd_resolve_path(user$work_dir %||% "work")
  if (identical(wd, dd_resolve_path(dirname(path)))) {
    message("dundee: ", path, " is already inside its work directory.")
    return(invisible(wd))
  }
  dir.create(wd, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(wd, "config.yml")
  if (file.exists(dest)) {
    stop("dundee: ", dest, " already exists; move or remove it first.",
         call. = FALSE)
  }
  lines <- grep("^\\s*(work_dir|temp_dir)\\s*:", readLines(path),
                value = TRUE, invert = TRUE)
  writeLines(lines, dest)
  if (isTRUE(remove)) unlink(path)
  message("dundee: config moved to ", dest,
          if (!isTRUE(remove)) paste0("\n  the old file at ", path,
                                      " can now be deleted"),
          "\n  then: dd_use(\"", wd, "\")")
  invisible(wd)
}
