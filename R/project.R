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
dd_derived_keys <- c("temp_dir", "staging_dir", "thumb_dir", "orig_dir",
                     "config_file")

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

dd_flip_case <- function(x) {
  chartr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
         "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", x)
}

# Read-only by construction: this runs on library_root, which is mounted
# read-only and whose mtime must not move. Never probe by writing a test file.
# Instead take an existing entry whose name changes under a case flip and ask
# whether the flipped name still resolves.
dd_fs_case_insensitive <- function(path = tempdir()) {
  dir <- path
  while (!dir.exists(dir) && dirname(dir) != dir) dir <- dirname(dir)
  key <- dir
  hit <- dd_case_cache[[key]]
  if (!is.null(hit)) return(hit)

  entries <- tryCatch(list.files(dir, all.files = TRUE, no.. = TRUE),
                      error = function(e) character(0))
  flipped <- dd_flip_case(entries)
  cased <- flipped != entries
  res <- if (any(cased & flipped %in% entries)) {
    # Two entries differing only in case coexist: definitively case-sensitive.
    FALSE
  } else if (any(cased)) {
    file.exists(file.path(dir, flipped[cased][[1]]))
  } else {
    # Empty directory, or no entry carries a letter: fall back to the platform
    # default (APFS/HFS+ are case-insensitive unless deliberately formatted).
    identical(Sys.info()[["sysname"]], "Darwin")
  }
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

# The directional half of the same question: is `child` at or below `parent`?
# dd_paths_overlap() answers "does either contain the other", which is what
# work_dir vs library_root needs; the phase 3 destination roots need the
# asymmetric form, and need the same case folding -- on an SMB or APFS mount
# /Volumes/Photo and /Volumes/photo are one directory, so a plain startsWith()
# would reject a destination that is genuinely inside the library.
dd_path_under <- function(child, parent) {
  if (is.null(child) || is.null(parent) || !length(child) || !length(parent) ||
      !nzchar(child) || !nzchar(parent)) return(FALSE)
  if (dd_fs_case_insensitive(child) || dd_fs_case_insensitive(parent)) {
    child <- tolower(child); parent <- tolower(parent)
  }
  identical(child, parent) ||
    startsWith(paste0(child, "/"), paste0(parent, "/"))
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
#' @param ... Further scalar config fields, e.g. `parallel = 4`.
#' @param overwrite Replace an existing `config.yml`, archiving the previous
#'   version to `config.history/` first. Without it an existing config is left
#'   untouched and nothing is archived.
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

# config.yml is hand-edited, so a typo (hamming_thresold:) is the likeliest
# error there is, and the silent version of it -- run completes, default value
# used -- is the most expensive. Name it, and guess what was meant.
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
  # 0 disables the review app's original cache entirely (every view re-reads).
  cfg$review_cache     <- num("review_cache", 0L, 100000L)
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

  # A project is a directory: the one holding config.yml is the work directory.
  # There is nothing to configure here, which is what makes a second library a
  # second directory rather than a second set of paths to keep in step.
  cfg$work_dir <- src$work_dir

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
  # Phase 3 destinations are local paths now, so they need the same treatment:
  # ~ expanded and symlinks resolved, or the containment check in
  # dd_require_move_config() would compare an unexpanded string against a real
  # path and reject a destination that is in fact inside the library.
  cfg$preferred_root <- dd_resolve_path(cfg$preferred_root)
  cfg$nonpreferred_root <- dd_resolve_path(cfg$nonpreferred_root)

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
  cfg$orig_dir    <- file.path(cfg$work_dir, "originals")
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
    sprintf("# derived: db=%s tmp=%s staging=%s thumbs=%s originals=%s",
            cfg$db_path, cfg$temp_dir, cfg$staging_dir, cfg$thumb_dir,
            cfg$orig_dir),
    yaml::as.yaml(body)
  ), out)
  invisible(out)
}

# Move every stored absolute path from one library root to another. Only the
# root prefix changes; the relative tree below it is what identifies a photo, so
# rel_path is untouched. Returns the number of rows rewritten.
dd_rebase_paths <- function(con, old_root, new_root) {
  old <- paste0(sub("/+$", "", old_root), "/")
  new <- paste0(sub("/+$", "", new_root), "/")
  n <- 0L
  for (tbl in c("photos", "errors")) {
    n <- n + DBI::dbExecute(
      con, sprintf("UPDATE %s SET path = ? || substr(path, ?)
                     WHERE substr(path, 1, ?) = ?", tbl),
      params = list(new, nchar(old) + 1L, nchar(old), old))
  }
  n
}

# The meta table (created by dd_db_init) holds store-level provenance: config
# invariants, the writing version, and the per-stage config stamps below.
dd_meta_get <- function(con, k) {
  v <- DBI::dbGetQuery(con, "SELECT value FROM meta WHERE key = ?",
                       params = list(k))
  if (nrow(v)) v$value[[1]] else NULL
}

dd_meta_set <- function(con, k, v) {
  DBI::dbExecute(con, "INSERT INTO meta(key, value) VALUES(?, ?)
                       ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                 params = list(k, as.character(v)))
}

# fingerprint_grid and library_root are baked into stored rows: changing the
# grid makes old and new fingerprints incomparable; changing library_root
# invalidates every stored absolute path. Both were silent corruptions.
dd_config_guard <- function(con, cfg, rebase = FALSE) {
  get1 <- function(k) dd_meta_get(con, k)
  set1 <- function(k, v) dd_meta_set(con, k, v)
  grid <- get1("fingerprint_grid")
  if (!is.null(grid) && !identical(as.integer(grid), cfg$fingerprint_grid)) {
    stop("dundee: this store was built with fingerprint_grid = ", grid,
         " but config.yml says ", cfg$fingerprint_grid,
         ".\n  Fingerprints of different geometries are not comparable. ",
         "Restore the old value, or start a new work directory.",
         call. = FALSE)
  }
  root <- get1("library_root")
  moved <- !is.null(root) && !is.null(cfg$library_root) &&
    nzchar(cfg$library_root) && !identical(root, cfg$library_root)
  if (moved && !isTRUE(rebase)) {
    stop("dundee: this store was built against library_root\n    ", root,
         "\n  but config.yml now says\n    ", cfg$library_root,
         "\n  Re-run with rebase = TRUE only if the same library was ",
         "re-mounted at a new path.", call. = FALSE)
  }
  if (moved) {
    # Recording the new root is not enough: every stored path is absolute under
    # the old one, so without rewriting them the resume filter matches nothing
    # and the move plan would name sources that are no longer there.
    n <- dd_rebase_paths(con, root, cfg$library_root)
    message(sprintf("dundee: rebased %d stored path(s)\n    %s\n  ->  %s",
                    n, root, cfg$library_root))
  }
  set1("fingerprint_grid", cfg$fingerprint_grid)
  if (!is.null(cfg$library_root) && nzchar(cfg$library_root)) {
    set1("library_root", cfg$library_root)
  }
  set1("dundee_version", dd_pkg_version())
  invisible(TRUE)
}

# ---------------------------------------------------------------------------
# config drift: what a config.yml edit invalidates
# ---------------------------------------------------------------------------

# Config keys each stage consumes. Editing one of these invalidates what that
# stage wrote; editing anything else (parallel, review_cache, db_path) does not.
# In pipeline order, which is also the order drift is reported and resolved.
dd_stage_keys <- list(
  inventory = c("library_root", "extensions", "cruft", "fingerprint_grid"),
  analyze   = c("fingerprint_grid", "hamming_threshold", "lsh_bands"),
  decide    = c("preference_rules", "folder_priority"),
  plan      = c("library_root", "preferred_root", "nonpreferred_root")
)

# What to re-run for each stage. `decide` names dd_apply_bulk_decisions()
# rather than dd_run_plan(bulk = TRUE) because that is the truth: dd_run_plan()
# does not pass overwrite, so a bulk pass skips every photo that already has a
# decision and would not re-apply the edited rules.
dd_stage_cmd <- c(
  inventory = "dd_run_inventory()",
  analyze   = "dd_run_analyze()",
  decide    = "dd_apply_bulk_decisions(con, cfg, overwrite = TRUE)",
  plan      = "dd_run_plan()"
)

# Flatten one config value to a comparable string. Deliberately not YAML: a
# round-trip through as.yaml()/yaml.load() turns character(0) into list() and
# blurs integer against character, which would report drift that is not there.
dd_key_string <- function(v) {
  if (is.null(v) || !length(v)) return("<unset>")
  paste(as.character(v), collapse = ",")
}

# A stage's stamp: one key=value line per config key it consumes.
dd_stamp_text <- function(cfg, keys) {
  paste(sprintf("%s=%s", keys, vapply(keys, function(k) dd_key_string(cfg[[k]]),
                                      character(1))),
        collapse = "\n")
}

dd_stamp_parse <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(character(0))
  parts <- strsplit(strsplit(txt, "\n", fixed = TRUE)[[1]], "=", fixed = TRUE)
  stats::setNames(
    vapply(parts, function(p) paste(p[-1], collapse = "="), character(1)),
    vapply(parts, `[[`, character(1), 1L))
}

# Record the settings a stage just ran under. Called at the end of a successful
# stage, so one that failed partway leaves the previous stamp standing.
dd_stage_stamp <- function(con, stage, cfg) {
  dd_meta_set(con, paste0("stamp_", stage),
              dd_stamp_text(cfg, dd_stage_keys[[stage]]))
  invisible(TRUE)
}

# Compare the current config against what each stage recorded. Returns only the
# keys that changed. A stage with no stamp contributes nothing: "never run under
# a recorded config" is not the same as "changed".
dd_config_drift <- function(con, cfg) {
  none <- data.frame(stage = character(0), key = character(0),
                     was = character(0), now = character(0),
                     stringsAsFactors = FALSE)
  have <- DBI::dbExistsTable(con, "meta")
  if (!have) return(none)
  out <- none
  for (stage in names(dd_stage_keys)) {
    was <- dd_stamp_parse(dd_meta_get(con, paste0("stamp_", stage)))
    if (!length(was)) next
    for (k in dd_stage_keys[[stage]]) {
      if (!k %in% names(was)) next          # stamped by an older version
      now <- dd_key_string(cfg[[k]])
      if (!identical(was[[k]], now)) {
        out <- rbind(out, data.frame(stage = stage, key = k, was = was[[k]],
                                     now = now, stringsAsFactors = FALSE))
      }
    }
  }
  out
}

# ---------------------------------------------------------------------------
# where am I?
# ---------------------------------------------------------------------------

#' Report the state of a dundee work directory.
#'
#' Read-only: it never applies the config guard, so it still works when the
#' config and the store have drifted apart. It does report that drift: each
#' stage records the config keys it consumed, and any that have since been
#' edited in `config.yml` are listed along with the stage to re-run.
#'
#' Photos whose metadata could not be read at all are reported separately from
#' photos that carry none, and counted in `unread`.
#'
#' @param config A work directory, config path, or config list.
#' @return A one-row data frame of counts, including `unread` (photos with no
#'   readable metadata) and a `drift` count of changed config keys, invisibly.
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
    done    = n("SELECT COUNT(*) FROM moves WHERE state = 'done'"),
    # Preferred copies moves.sh deliberately left where they were. Not done --
    # nothing moved -- but not outstanding work either.
    kept    = n("SELECT COUNT(*) FROM moves WHERE state = 'kept'"),
    # NULL, not 0: the fingerprint worker leaves meta_count empty when it could
    # not read a photo's metadata at all, which is not the same as a photo that
    # carries none. Only the former is worth reporting.
    unread  = n("SELECT COUNT(*) FROM photos WHERE meta_count IS NULL")
  )
  message(sprintf(
    paste("  photos %d (%d unreadable) | groups %d covering %d |",
          "decided %d | moves %d planned, %d done, %d kept"),
    out$photos, out$errors, out$groups, out$grouped, out$decided,
    out$planned, out$done, out$kept))
  if (out$unread > 0L) {
    message(sprintf(
      "  metadata unreadable for %d photo(s); max_meta cannot rank them",
      out$unread))
  }

  dr <- dd_config_drift(con, cfg)
  out$drift <- nrow(dr)
  nxt <- if (out$photos == 0L) "dd_run_inventory()" else
    if (out$groups == 0L) "dd_run_analyze()" else
      if (out$decided < out$grouped) "dd_app()  # review remaining groups" else
        if (out$planned == 0L && out$done == 0L && out$kept == 0L)
          "dd_run_plan(bulk = TRUE)" else
          if (out$planned > 0L) "run moves.sh, then dd_run_move()" else "nothing"

  if (nrow(dr)) {
    # Report the earliest drifted stage first, and recommend it: re-running a
    # stage implies re-running the ones after it, so the earliest is the only
    # useful next step.
    short <- function(s, n = 44L) {
      if (nchar(s) > n) paste0(substr(s, 1L, n - 3L), "...") else s
    }
    for (stage in intersect(names(dd_stage_keys), dr$stage)) {
      message("  config changed since ", stage, " ran:")
      sub <- dr[dr$stage == stage, , drop = FALSE]
      for (i in seq_len(nrow(sub))) {
        message("    ", sub$key[i], ": ", short(sub$was[i]), " -> ",
                short(sub$now[i]))
      }
    }
    first <- intersect(names(dd_stage_keys), dr$stage)[[1]]
    nxt <- paste0(dd_stage_cmd[[first]], "   # config changed")
  }
  message("  next: ", nxt)
  invisible(out)
}
