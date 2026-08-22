# High-level entry points. One exported function per pipeline stage so dundee
# can be driven from an installed package (or devtools::load_all) rather than
# from a source checkout. Shell stages are located with system.file(), which
# pkgload shims during load_all, so both modes work unchanged.

# --- internal helpers -------------------------------------------------------

# Locate a helper script shipped in inst/bin.
dd_script <- function(name) {
  path <- system.file("bin", name, package = "dundee")
  if (!nzchar(path)) {
    stop("dundee: helper script '", name, "' not found. ",
         "Reinstall the package (devtools::install()).", call. = FALSE)
  }
  path
}

# Run a shell stage, streaming its output; error on non-zero exit. When quiet,
# stdout is discarded and DD_PROGRESS=0 disables the shell progress helpers
# (which write to stderr and would otherwise leak past the stdout redirect).
dd_sh <- function(name, args = character(), quiet = FALSE) {
  args <- shQuote(as.character(args))
  status <- system2("bash", c(shQuote(dd_script(name)), args),
                    stdout = if (quiet) FALSE else "",
                    env = if (quiet) "DD_PROGRESS=0" else character())
  if (!identical(as.integer(status), 0L)) {
    stop(sprintf("dundee: %s exited with status %s", name, status),
         call. = FALSE)
  }
  invisible(TRUE)
}

# Accept either a path to a YAML config or an already-resolved config list.
dd_as_config <- function(config = NULL, require_library = FALSE) {
  if (is.list(config)) return(config)
  dd_config(config, require_library = require_library)
}

# Open the store, ensure the schema, run `f(con)`, always disconnect.
dd_with_con <- function(cfg, f, rebase = FALSE) {
  con <- dd_db_connect(cfg)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  dd_config_guard(con, cfg, rebase = rebase)   # <- store/config invariants
  f(con)
}

# --- preflight --------------------------------------------------------------

# One report line: "ok  ", "warn" or "MISS", the name, then a note. MISS is the
# only status that survives quiet -- a caller that suppressed the report still
# needs to learn why the check failed.
dd_pf_line <- function(status, name, note = "", quiet = FALSE) {
  txt <- sprintf("%-4s %-14s %s", status, name, note)
  if (identical(status, "MISS") || !quiet) message(txt)
  invisible(NULL)
}

# Absent means dundee cannot run at all. `bash` belongs on the list because
# dd_sh() invokes it directly: a checker written in bash could never report its
# own interpreter missing, which is exactly why this one is R.
dd_pf_required <- c(
  bash       = "the shell stages run under bash",
  vips       = "install libvips (brew install vips)",
  vipsheader = "part of libvips",
  exiftool   = "brew install exiftool",
  od         = "coreutils / ships with macOS",
  awk        = "",
  find       = "",
  xargs      = "",
  base64     = ""
)

# Needed by one phase only. Worth saying, but a machine that can run inventory
# and analyze must not be told it is missing requirements.
dd_pf_optional <- c(
  vipsthumbnail = "part of libvips; needed only by the review app"
)

# Report whether vips can decode HEIC/HEIF. Informational: a library with no
# HEIC in it does not care. The shell version had to avoid piping into `grep -q`
# (it SIGPIPEs vips under `pipefail`, giving a false negative); with no pipeline
# involved that hazard simply does not exist here.
dd_pf_heif <- function() {
  run <- function(...) tryCatch(suppressWarnings(
    system2("vips", c(...), stdout = TRUE, stderr = FALSE)),
    error = function(e) character())
  fields <- trimws(unlist(strsplit(run("--vips-config"), ",")))
  hit <- grep("libheif:\\s*true", fields, value = TRUE, ignore.case = TRUE)
  if (length(hit)) {
    message("ok   HEIC/HEIF support present (", hit[[1]], ")")
  } else if (any(grepl("heifload", run("-l"), ignore.case = TRUE))) {
    message("ok   HEIC/HEIF loader present (heifload)")
  } else {
    message("warn HEIC/HEIF support not detected; ",
            "'brew install vips libheif' if needed")
  }
}

#' Check that external tools and R dependencies are available.
#'
#' Verifies the command-line tools the shell stages need and the R packages
#' dundee needs at run time, in one report. Tools that only one phase needs --
#' `vipsthumbnail` and shiny/bslib for the review app -- are reported as
#' warnings and do not make the check fail.
#'
#' @param quiet Logical; suppress the per-tool report. Missing requirements are
#'   still reported.
#' @return `TRUE` if everything needed is present, otherwise `FALSE`,
#'   invisibly.
#' @examples
#' \dontrun{
#' dd_preflight()
#' }
#' @export
dd_preflight <- function(quiet = FALSE) {
  ok <- TRUE
  dd_phase("preflight", quiet = quiet)

  if (!quiet) message("== required tools ==")
  for (tool in names(dd_pf_required)) {
    where <- Sys.which(tool)
    if (nzchar(where)) {
      dd_pf_line("ok", tool, where, quiet = quiet)
    } else {
      dd_pf_line("MISS", tool, dd_pf_required[[tool]])
      ok <- FALSE
    }
  }

  if (!quiet) message("== phase-specific tools (optional) ==")
  for (tool in names(dd_pf_optional)) {
    where <- Sys.which(tool)
    dd_pf_line(if (nzchar(where)) "ok" else "warn", tool,
               if (nzchar(where)) where else dd_pf_optional[[tool]],
               quiet = quiet)
  }

  # Mirrors lib.sh's dd_filehash(): b3sum when present, else shasum.
  if (!quiet) message("== hashing tool (need one) ==")
  hasher <- Filter(function(h) nzchar(Sys.which(h)), c("b3sum", "shasum"))
  if (length(hasher)) {
    dd_pf_line("ok", hasher[[1]],
               paste0(Sys.which(hasher[[1]]),
                      if (identical(hasher[[1]], "shasum")) " (fallback)"
                      else ""),
               quiet = quiet)
  } else {
    dd_pf_line("MISS", "b3sum/shasum", "need one of them")
    ok <- FALSE
  }

  if (!quiet) {
    # lib.sh picks stat flags by this same probe; report which branch it will
    # take so a portability surprise is visible here rather than mid-inventory.
    message("== stat flavor ==")
    gnu <- tryCatch(
      identical(as.integer(system2("stat", "--version", stdout = FALSE,
                                   stderr = FALSE)), 0L),
      warning = function(w) FALSE, error = function(e) FALSE)
    message(if (gnu) "STAT=gnu" else "STAT=bsd (macOS default; using stat -f)")

    if (nzchar(Sys.which("vips"))) {
      message("== vips format support ==")
      dd_pf_heif()
    }
  }

  required <- c("DBI", "RSQLite", "base64enc", "yaml")
  suggested <- c("shiny", "bslib")
  have <- function(p) requireNamespace(p, quietly = TRUE)

  if (!quiet) message("== R packages ==")
  for (p in required) {
    if (have(p)) {
      dd_pf_line("ok", p, quiet = quiet)
    } else {
      dd_pf_line("MISS", p, sprintf("install.packages('%s')", p))
      ok <- FALSE
    }
  }
  for (p in suggested) {
    dd_pf_line(if (have(p)) "ok" else "warn", p,
               if (have(p)) "" else "needed only for the review app",
               quiet = quiet)
  }

  if (!quiet) {
    message(if (ok) "preflight: ready." else "preflight: missing requirements.")
  }
  invisible(ok)
}

# --- phase 1: inventory -----------------------------------------------------

#' Run the inventory phase.
#'
#' Enumerates candidate photos under `library_root`, filters out files already
#' fingerprinted and unchanged, fingerprints the remainder in parallel, and
#' merges the staged results into the SQLite store. Every step is idempotent,
#' so the function may be re-run after an interruption.
#'
#' @param config A work directory, a config path, or a list from [dd_config()].
#' @param parallel Optional integer overriding `parallel` from the config.
#' @param quiet Logical; suppress stage output from the shell workers.
#' @param rebase Logical; accept a `library_root` that differs from the one the
#'   store was built against. Only correct when the *same* library has been
#'   re-mounted at a new path -- every stored path is rewritten to match.
#' @return A list with `enumerated`, `todo`, `photos` and `errors` counts,
#'   invisibly.
#' @examples
#' \dontrun{
#' dd_run_inventory("config.yml")
#' }
#' @export
dd_run_inventory <- function(config = NULL, parallel = NULL,
                             quiet = FALSE, rebase = FALSE) {
  cfg <- dd_as_config(config, require_library = TRUE)
  if (!is.null(parallel)) cfg$parallel <- as.integer(parallel)
  dd_config_snapshot(cfg)                      # <- provenance

  dd_phase("inventory", quiet = quiet)
  dir.create(cfg$work_dir, recursive = TRUE, showWarnings = FALSE)
  enum <- file.path(cfg$work_dir, "enum.tsv")
  todo <- file.path(cfg$work_dir, "todo.nul")

  dd_step("enumerating candidate photos", quiet = quiet)
  dd_sh("10-enumerate.sh",
        c(cfg$library_root, enum, cfg$extensions, "--", cfg$cruft),
        quiet = quiet)
  n_enum <- length(readLines(enum, warn = FALSE))

  dd_step("resume-filtering against the store", quiet = quiet)
  n_repair <- 0L
  n_todo <- dd_with_con(cfg, function(con) {
    # A fingerprint stored under an older algorithm is stale even though the
    # file has not changed, and the resume key cannot see that. Probe for the
    # photos the bump actually affects and force just those.
    force <- character(0)
    was <- dd_meta_get(con, "fingerprint_version")
    # An empty store has nothing computed under the old algorithm, so a first
    # run records the version and says nothing -- announcing a repair to
    # someone who has never fingerprinted anything is just noise.
    stored <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM photos")$n
    if (stored > 0L &&
        (is.null(was) || as.integer(was) < dd_fingerprint_version)) {
      dd_step(sprintf("fingerprint algorithm changed (v%s -> v%d)",
                      if (is.null(was)) "1" else was,
                      dd_fingerprint_version), quiet = quiet)
      force <- dd_alpha_photos(con, quiet = quiet)
      n_repair <<- length(force)
      dd_step(sprintf("%d photo(s) need re-fingerprinting", n_repair),
              quiet = quiet)
    }
    dd_resume_todo(con, enum, todo, force = force)
  }, rebase = rebase)
  message(sprintf("resume: %d of %d file(s) need fingerprinting",
                  n_todo, n_enum))

  if (n_todo > 0L) {
    dd_step(sprintf("fingerprinting %d file(s) on %s worker(s)",
                    n_todo, cfg$parallel), quiet = quiet)
    dd_sh("20-fingerprint.sh",
          c(todo, cfg$staging_dir, cfg$temp_dir, cfg$library_root,
            cfg$parallel, cfg$fingerprint_grid, n_todo),
          quiet = quiet)
  }

  dd_step("merging staging results into the store", quiet = quiet)
  res <- dd_with_con(cfg, function(con) {
    out <- dd_import_staging(con, cfg, quiet = quiet)
    dd_stage_stamp(con, "inventory", cfg)      # <- what dd_status() compares
    # Only once the new fingerprints are actually in the store. Recording it
    # earlier would let an interrupted repair look finished and never retry.
    dd_meta_set(con, "fingerprint_version", dd_fingerprint_version)
    out
  })
  message(sprintf("inventory: merged %d photo row(s), %d error row(s)",
                  res$photos, res$errors))
  if (n_repair > 0L) {
    message(sprintf(
      "%d photo(s) re-fingerprinted; run dd_run_analyze() to rebuild groups",
      n_repair))
  }

  invisible(list(enumerated = n_enum, todo = n_todo, repaired = n_repair,
                 photos = res$photos, errors = res$errors))
}

# --- phase 2: analyze + review ---------------------------------------------

#' Run the analyze phase.
#'
#' Builds exact groups (shared decoded-pixel hash) and near groups (Hamming
#' distance under `hamming_threshold`, blocked by LSH) and rewrites the
#' `groups` table.
#'
#' @param config A work directory, a config path, or a list from [dd_config()].
#' @param quiet Logical; suppress phase/progress feedback.
#' @return The group membership data frame, invisibly.
#' @examples
#' \dontrun{
#' dd_run_analyze("config.yml")
#' }
#' @export
dd_run_analyze <- function(config = NULL, quiet = FALSE) {
  cfg <- dd_as_config(config)
  dd_config_snapshot(cfg)                      # <- provenance
  dd_phase("analyze", quiet = quiet)
  out <- dd_with_con(cfg, function(con) {
    res <- dd_analyze(con, cfg, quiet = quiet)
    dd_stage_stamp(con, "analyze", cfg)        # <- what dd_status() compares
    res
  })
  ngroups <- if (nrow(out)) length(unique(out$group_id)) else 0L
  message(sprintf("analyze: %d group(s) covering %d photo(s)",
                  ngroups, nrow(out)))
  invisible(out)
}

# Right-align a numeric column under its header, so the eye can compare counts
# down the column rather than reading each one.
dd_col <- function(x, head) {
  x <- as.character(x)
  w <- max(nchar(head), nchar(x))
  list(head = formatC(head, width = w), body = formatC(x, width = w))
}

#' Report duplicate groups summarised by the directories they span.
#'
#' Prints the [dd_folder_patterns()] table, and with `effect = TRUE` the
#' [dd_folder_effect()] audit of the config's `folder_priority`. Reads only.
#'
#' @param config A work directory, a config path, or a list from [dd_config()].
#' @param depth Path segments to keep from each `rel_path`.
#' @param effect Logical; also audit `folder_priority` against the current
#'   `preference_rules`.
#' @param quiet Logical; suppress the printed report. Unlike the other
#'   `dd_run_*()` stages, whose `quiet` drops only banners and progress, here
#'   the report *is* the output -- so this silences everything and leaves the
#'   return value to work with. Errors are still raised.
#' @return Invisibly, a list with `patterns` and (when asked) `effect`.
#' @examples
#' \dontrun{
#' dd_run_folders()                       # groups summarised by directory
#' dd_run_folders(depth = 2)              # look inside single-directory patterns
#' dd_run_folders(effect = TRUE)          # audit folder_priority before applying
#'
#' pat <- dd_run_folders(quiet = TRUE)$patterns   # the table, nothing printed
#' }
#' @export
dd_run_folders <- function(config = NULL, depth = 1L, effect = FALSE,
                           quiet = FALSE) {
  cfg <- dd_as_config(config)
  say <- function(...) if (!isTRUE(quiet)) message(...)
  dd_with_con(cfg, function(con) {
    pat <- dd_folder_patterns(con, depth)
    if (nrow(pat) == 0L) {
      # Unconditional: quiet suppresses output, not failure.
      stop("dundee: nothing is grouped yet; run analyze first.", call. = FALSE)
    }
    ng <- dd_col(pat$n_groups, "groups")
    np <- dd_col(pat$n_photos, "photos")
    sp <- dd_col(pat$spans, "dirs")
    say(sprintf("%s %s %s  %s", ng$head, np$head, sp$head, "pattern"))
    for (i in seq_len(nrow(pat))) {
      say(sprintf("%s %s %s  %s", ng$body[i], np$body[i], sp$body[i],
                  pat$pattern[i]))
    }
    one <- pat$spans == 1L
    say(sprintf("  %d pattern(s) over %d group(s)",
                nrow(pat), sum(pat$n_groups)))
    if (any(one)) {
      # Phrased without a flag spelling: this runs from R and from the shell,
      # where the same knob is depth = 2 and --depth=2.
      say(sprintf(
        "  %d of them, %d group(s), span one directory: folder_priority cannot%s",
        sum(one), sum(pat$n_groups[one]),
        if (depth < 3L) sprintf(" decide those (try depth %d)", depth + 1L)
        else " decide those"))
    }

    eff <- NULL
    if (isTRUE(effect)) {
      if (!length(cfg$folder_priority)) {
        say("\n  the audit needs folder_priority set in config.yml ",
            "(most-preferred folder first).")
      } else {
        eff <- dd_folder_effect(con, cfg, depth = depth, quiet = quiet)
        say(sprintf(
          "\n  folder_priority decides %d of %d group(s); %d fall through to %s",
          eff$by_folder, eff$n_groups, eff$tied,
          paste(cfg$preference_rules, collapse = ", ")))
        nd <- nrow(eff$differs)
        say(sprintf("  %d group(s) would be decided DIFFERENTLY than %s",
                    nd, "preference_rules decides them today"))
        if (nd > 0L) {
          say("  the first few, folder winner then current winner:")
          for (i in seq_len(min(5L, nd))) {
            say("    + ", eff$differs$folder_winner[i])
            say("    - ", eff$differs$rules_winner[i])
          }
          say("  to apply: put folder_priority first in preference_rules, ",
              "then\n    dd_apply_bulk_decisions(con, cfg, overwrite = TRUE)")
        }
      }
    }
    invisible(list(patterns = pat, effect = eff))
  })
}

#' Launch the Shiny review app.
#'
#' The config is resolved to absolute paths before launching, because
#' [shiny::runApp()] changes the working directory to the app folder.
#'
#' Blocks until the app stops. The app's Quit button stops it cleanly and
#' reports how far the review got; Ctrl-C still works and simply returns no
#' summary.
#'
#' @param config A work directory, a config path, or a list from [dd_config()].
#' @param port Port to serve on.
#' @param launch_browser Logical; open a browser window.
#' @return Invisibly, the value [shiny::runApp()] returned: after the Quit
#'   button, a [dd_review_progress()] list of `decided` and `groups`; after any
#'   other exit, whatever stopped it.
#' @examples
#' \dontrun{
#' dd_app("config.yml", port = 7654)
#'
#' p <- dd_app()          # quit from the browser, then:
#' p$decided              # groups reviewed this session and before
#' }
#' @export
dd_app <- function(config = NULL, port = 7654L,
                   launch_browser = interactive()) {
  if (!requireNamespace("shiny", quietly = TRUE) ||
      !requireNamespace("bslib", quietly = TRUE)) {
    stop("dundee: the review app needs the 'shiny' and 'bslib' packages.",
         call. = FALSE)
  }
  app_dir <- system.file("shiny", package = "dundee")
  if (!nzchar(app_dir)) {
    stop("dundee: review app not found. Reinstall the package.", call. = FALSE)
  }

  dd_phase("app")
  cfg <- dd_as_config(config)
  # The resolved snapshot lives in work_dir, so it survives the app session and
  # is the same file the shell stages read. runApp() chdirs, hence absolute.
  resolved <- dd_config_snapshot(cfg)
  old <- Sys.getenv("DUNDEE_CONFIG", unset = NA)
  Sys.setenv(DUNDEE_CONFIG = resolved)
  on.exit({
    if (is.na(old)) Sys.unsetenv("DUNDEE_CONFIG") else Sys.setenv(DUNDEE_CONFIG = old)
  }, add = TRUE)

  message(sprintf("review app: http://127.0.0.1:%d", as.integer(port)))
  out <- shiny::runApp(app_dir, port = as.integer(port),
                       launch.browser = isTRUE(launch_browser))
  # The Quit button stops the app with dd_review_progress()'s summary, so a
  # clean exit can report where the review got to. Every other way out --
  # Ctrl-C, a stopApp() elsewhere -- returns something else entirely, which
  # must not be formatted as one.
  if (is.list(out) && all(c("decided", "groups") %in% names(out))) {
    message(sprintf("review app: %d of %d group(s) decided",
                    out$decided, out$groups))
  }
  invisible(out)
}

# --- phase 3: plan + move ---------------------------------------------------

#' Plan the Phase 3 moves.
#'
#' Optionally applies the bulk preference rules to any still-undecided group,
#' then writes `moves.tsv` and a reviewable `moves.sh` under `work_dir`.
#' Nothing is executed and nothing in the library is touched: running the
#' script is yours to do, and [dd_run_move()] reconciles the store afterwards.
#'
#' @param config A work directory, a config path, or a list from [dd_config()].
#' @param bulk Logical; apply [dd_apply_bulk_decisions()] before planning.
#' @param quiet Logical; suppress phase/progress feedback.
#' @return The move plan, invisibly.
#' @examples
#' \dontrun{
#' dd_run_plan("config.yml", bulk = TRUE)
#' }
#' @export
dd_run_plan <- function(config = NULL, bulk = FALSE, quiet = FALSE) {
  cfg <- dd_as_config(config)
  dd_require_move_config(cfg)
  dd_config_snapshot(cfg)                      # <- provenance
  dd_phase("plan", quiet = quiet)
  out <- dd_with_con(cfg, function(con) {
    if (isTRUE(bulk)) {
      dd_step("applying bulk preference decisions", quiet = quiet)
      n <- dd_apply_bulk_decisions(con, cfg, quiet = quiet)
      message(sprintf("applied bulk decisions to %d undecided photo(s)", n))
      # Only the bulk pass consumes the preference rules; a manual choice from
      # the review app is not governed by them, so it stamps nothing.
      dd_stage_stamp(con, "decide", cfg)
    }
    dd_step("planning moves", quiet = quiet)
    res <- dd_plan_moves(con, cfg, quiet = quiet)
    dd_stage_stamp(con, "plan", cfg)           # <- what dd_status() compares
    res
  })
  invisible(out)
}

# Read the receipt the move script appends to as it runs. Only field 1, the
# photo_id, is taken: a filename may legally contain a tab, and the id-first
# layout means the parse never has to care. read.table() is the wrong tool here
# -- its quote and comment.char defaults mangle real paths -- so this reads
# bytes and splits them.
dd_move_receipt <- function(path) {
  if (!file.exists(path)) return(integer(0))
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(lines)]
  if (!length(lines)) return(integer(0))
  ids <- suppressWarnings(as.integer(
    vapply(strsplit(lines, "\t", fixed = TRUE), `[`, character(1), 1L)))
  unique(ids[!is.na(ids)])
}

#' Reconcile the store with the moves the script actually made.
#'
#' dundee does not move anything: [dd_run_plan()] writes `moves.sh` and you run
#' it. This reads what happened and marks the batch done -- first from
#' `moves.done.tsv`, the receipt the script appends to, then by checking the
#' library itself for any planned photo the receipt does not cover, so a script
#' you edited, interrupted or replaced with your own still reconciles.
#'
#' A photo counts as moved when its source is gone *and* its destination is
#' there. A source that has vanished with nothing at the destination is
#' reported and left planned: something other than the move script removed it,
#' and calling that done would hide it.
#'
#' By default `moves.sh` leaves each group's preferred copy where it is, and
#' records those in `moves.kept.tsv`. They are marked `kept` rather than `done`
#' -- no move happened -- but they no longer count as outstanding work. Running
#' the script again with `--include-preferred` moves them for real, and a second
#' reconcile turns `kept` into `done`.
#'
#' @param config A work directory, a config path, or a list from [dd_config()].
#' @param quiet Logical; suppress the phase banner.
#' @return Invisibly, a named integer vector: `done` and `kept` counts.
#' @examples
#' \dontrun{
#' dd_run_plan(bulk = TRUE)   # writes moves.sh
#' # ... remount the library read-write and run moves.sh ...
#' dd_run_move()
#' }
#' @export
dd_run_move <- function(config = NULL, quiet = FALSE) {
  cfg <- dd_as_config(config)
  dd_require_move_config(cfg)
  dd_config_snapshot(cfg)                      # <- provenance
  dd_phase("move", quiet = quiet)

  script <- file.path(cfg$work_dir, "moves.sh")
  if (!file.exists(script)) {
    stop("dundee: no move script at ", script,
         ". Run dd_run_plan() first.", call. = FALSE)
  }
  receipt <- file.path(cfg$work_dir, "moves.done.tsv")
  kept_log <- file.path(cfg$work_dir, "moves.kept.tsv")

  n <- dd_with_con(cfg, function(con) {
    # 'kept' rows are re-examined too: a later --include-preferred run moves
    # them for real, and that has to be able to reach the store.
    open_rows <- DBI::dbGetQuery(con, "SELECT photo_id, src, dest FROM moves
                                        WHERE state IN ('planned', 'kept')")
    if (nrow(open_rows) == 0L) {
      message("move: nothing outstanding; moves.sh has already been reconciled.")
      return(c(done = 0L, kept = 0L))
    }
    from_receipt <- intersect(dd_move_receipt(receipt), open_rows$photo_id)
    message(sprintf("move: %s", if (file.exists(receipt))
      sprintf("moves.done.tsv records %d of %d outstanding move(s)",
              length(from_receipt), nrow(open_rows))
      else "no moves.done.tsv; checking the library directly"))

    # A photo kept in one run and moved in the next appears in both logs, and
    # moved must win. The claim is then verified rather than trusted, the same
    # way a move is: a kept photo is one still sitting at its source.
    claimed_kept <- setdiff(intersect(dd_move_receipt(kept_log),
                                      open_rows$photo_id), from_receipt)
    kept_src <- open_rows$src[match(claimed_kept, open_rows$photo_id)]
    keep_ids <- claimed_kept[file.exists(kept_src)]
    if (length(claimed_kept)) {
      message(sprintf("      moves.kept.tsv records %d left in place%s",
                      length(keep_ids),
                      if (length(keep_ids) < length(claimed_kept))
                        sprintf(" (%d of its rows moved after all)",
                                length(claimed_kept) - length(keep_ids)) else ""))
    }

    rest <- open_rows[!open_rows$photo_id %in% c(from_receipt, keep_ids), ,
                      drop = FALSE]
    gone <- !file.exists(rest$src)
    landed <- file.exists(rest$dest)
    by_check <- rest$photo_id[gone & landed]
    vanished <- rest$photo_id[gone & !landed]
    if (nrow(rest)) {
      message(sprintf("      of the remaining %d: %d moved, %d still in place",
                      nrow(rest), length(by_check), sum(!gone)))
    }
    if (length(vanished)) {
      message(sprintf(paste("      %d source(s) gone with nothing at the",
                            "destination; left planned"), length(vanished)))
      for (p in utils::head(rest$src[gone & !landed], 3L)) message("        ", p)
    }

    mark <- function(ids, state) {
      if (!length(ids)) return(0L)
      DBI::dbExecute(con, sprintf(
        "UPDATE moves SET state = ?, moved_at = ?
          WHERE state IN ('planned', 'kept') AND photo_id IN (%s)",
        paste(rep("?", length(ids)), collapse = ",")),
        params = c(list(state, format(Sys.time(), "%Y-%m-%dT%H:%M:%S")),
                   as.list(as.integer(ids))))
    }
    c(done = mark(c(from_receipt, by_check), "done"),
      kept = mark(keep_ids, "kept"))
  })
  if (sum(n) > 0L) {
    message(sprintf("move: marked %d done%s", n[["done"]],
                    if (n[["kept"]] > 0L)
                      sprintf(", %d kept (preferred, left in place)",
                              n[["kept"]]) else ""))
  } else {
    message("move: nothing to mark.")
  }
  invisible(n)
}

# Fail early, with one clear message, if Phase 3 config is incomplete.
dd_require_move_config <- function(cfg) {
  need <- c("preferred_root", "nonpreferred_root")
  missing <- need[vapply(need, function(k) {
    v <- cfg[[k]]
    is.null(v) || !nzchar(as.character(v)[1])
  }, logical(1))]
  if (length(missing)) {
    stop("dundee: config field(s) required for the move phase are unset: ",
         paste(missing, collapse = ", "), call. = FALSE)
  }
  # Both destinations must be inside the library. A move within one mount is a
  # rename; a move off it copies every duplicate over the wire and deletes the
  # original. Enforcing it here also means a server-side path like /volume1/...
  # fails with one clear message rather than as N failed mkdirs.
  outside <- need[!vapply(need, function(k) {
    dd_path_under(cfg[[k]], cfg$library_root)
  }, logical(1))]
  if (length(outside)) {
    stop("dundee: move destination(s) must be under library_root:\n  ",
         paste(sprintf("%s: %s", outside, unlist(cfg[outside])),
               collapse = "\n  "),
         "\n  library_root: ", cfg$library_root,
         "\n  (these are local paths now, not server-side ones)",
         call. = FALSE)
  }
  invisible(TRUE)
}

# --- command line dispatch --------------------------------------------------

# Options each command accepts. A single global list of allowed flags let
# `status --bulk` validate cleanly, and let `--rebase` sit in the list for a
# stage that never read it. Keying by command makes "unknown options are
# rejected" true per command, and gives the usage text something to be checked
# against (see tests/testthat/test-cli.R).
dd_cli_opts <- list(
  init      = "--library",
  config    = character(),
  status    = character(),
  preflight = "--quiet",
  inventory = c("--parallel", "--rebase", "--quiet"),
  analyze   = "--quiet",
  folders   = c("--depth", "--effect"),
  app       = c("--port", "--no-browser"),
  plan      = c("--bulk", "--quiet"),
  move      = "--quiet"
)

# The command lines below are parsed by the drift test, which requires that the
# flags shown for a command are exactly the flags dd_cli_opts allows it.
dd_cli_usage <- function() {
  paste(
    "usage: dundee <command> [work_dir] [options]",
    "",
    "  init      <work_dir> --library=DIR   create a work directory + config.yml",
    "  config    [work_dir]                 show the config",
    "  status    [work_dir]                 what is done, and what is next",
    "  preflight [--quiet]                  check external tools and R packages",
    "  inventory [work_dir] [--parallel=N] [--rebase] [--quiet]",
    "  analyze   [work_dir] [--quiet]",
    "  folders   [work_dir] [--depth=N] [--effect]",
    "  app       [work_dir] [--port=N] [--no-browser]",
    "  plan      [work_dir] [--bulk] [--quiet]",
    "  move      [work_dir] [--quiet]",
    "",
    "  With no work_dir, dundee resolves in order: the dd_use() session",
    "  default, $DUNDEE_WORK, $DUNDEE_CONFIG, ./config.yml, ./work/config.yml.",
    "  --quiet suppresses phase banners and progress output.",
    "  --rebase accepts a library re-mounted at a new path (rewrites",
    "  every stored path); see 'this store was built against library_root'.",
    sep = "\n"
  )
}

# Split arguments into command, work directory and options, validating both.
# Kept free of dispatch so the parsing -- the part that has drifted -- can be
# tested without running a stage.
dd_parse_args <- function(args) {
  usage <- dd_cli_usage()
  if (!length(args) || args[[1]] %in% c("help", "-h", "--help")) {
    return(list(cmd = "help", work = NULL, flags = character(), usage = usage))
  }

  cmd <- args[[1]]
  rest <- args[-1]
  if (!cmd %in% names(dd_cli_opts)) {
    stop("dundee: unknown command '", cmd, "'.\n", usage, call. = FALSE)
  }

  is_flag <- grepl("^--", rest)
  unknown <- setdiff(sub("=.*$", "", rest[is_flag]), dd_cli_opts[[cmd]])
  if (length(unknown)) {
    stop("dundee: ", cmd, " does not accept option(s): ",
         paste(unknown, collapse = ", "), "\n", usage, call. = FALSE)
  }

  list(cmd = cmd,
       work = if (any(!is_flag)) rest[!is_flag][[1]] else NULL,
       flags = rest[is_flag],
       usage = usage)
}

dd_has_flag <- function(flags, name) paste0("--", name) %in% flags

dd_flag_value <- function(flags, name, default = NULL) {
  hit <- grep(paste0("^--", name, "="), flags, value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[[1]]) else default
}

#' Dispatch a dundee command from the command line.
#'
#' Backs the `exec/dundee` wrapper. Not normally called interactively.
#'
#' @param args Character vector of arguments, e.g. `commandArgs(TRUE)`.
#' @return Invisibly, the value of the dispatched stage.
#' @examples
#' \dontrun{
#' dd_cli(c("analyze", "~/dundee/family-photos"))
#' }
#' @export
dd_cli <- function(args = commandArgs(trailingOnly = TRUE)) {
  p <- dd_parse_args(args)
  if (identical(p$cmd, "help")) {
    cat(p$usage, "\n", sep = "")
    return(invisible(NULL))
  }

  f <- p$flags
  work <- p$work
  quiet <- dd_has_flag(f, "quiet")

  out <- switch(
    p$cmd,
    init = {
      if (is.null(work)) {
        stop("dundee: init needs a work directory.\n", p$usage, call. = FALSE)
      }
      # Without --library the template's placeholder would survive into the new
      # config, quietly pointing the project at ~/photo-ro.
      lib <- dd_flag_value(f, "library")
      if (is.null(lib)) {
        stop("dundee: init needs --library=DIR, the read-only photo library.\n",
             p$usage, call. = FALSE)
      }
      dd_init(work, library_root = lib)
    },
    config    = dd_config_report(dd_config(work)),
    status    = dd_status(work),
    preflight = dd_preflight(quiet = quiet),
    inventory = dd_run_inventory(work, parallel = dd_flag_value(f, "parallel"),
                                 quiet = quiet,
                                 rebase = dd_has_flag(f, "rebase")),
    analyze   = dd_run_analyze(work, quiet = quiet),
    folders   = dd_run_folders(work,
                               depth = as.integer(dd_flag_value(f, "depth", 1L)),
                               effect = dd_has_flag(f, "effect")),
    app       = dd_app(work, port = as.integer(dd_flag_value(f, "port", 7654L)),
                       launch_browser = !dd_has_flag(f, "no-browser")),
    plan      = dd_run_plan(work, bulk = dd_has_flag(f, "bulk"), quiet = quiet),
    move      = dd_run_move(work, quiet = quiet)
  )
  invisible(out)
}
