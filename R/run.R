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
dd_as_config <- function(config = "config.yml", require_library = FALSE) {
  if (is.list(config)) return(config)
  dd_config(config, require_library = require_library)
}

# Open the store, ensure the schema, run `f(con)`, always disconnect.
dd_with_con <- function(cfg, f) {
  con <- dd_db_connect(cfg)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  f(con)
}

# Write a fully-resolved config to a temp file so a child context (e.g. Shiny,
# which changes the working directory) sees absolute paths.
dd_config_tempfile <- function(cfg) {
  path <- tempfile("dundee-config-", fileext = ".yml")
  writeLines(yaml::as.yaml(cfg), path)
  path
}

# --- preflight --------------------------------------------------------------

#' Check that external tools and R dependencies are available.
#'
#' Runs the shell preflight (libvips, exiftool, a hashing tool, sqlite3, ssh)
#' and additionally verifies the R packages dundee needs at run time.
#'
#' @param quiet Logical; suppress the per-tool report.
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

  status <- system2("bash", shQuote(dd_script("00-preflight.sh")),
                    stdout = if (quiet) FALSE else "")
  if (!identical(as.integer(status), 0L)) ok <- FALSE

  required <- c("DBI", "RSQLite", "base64enc", "yaml")
  suggested <- c("shiny", "bslib")
  have <- function(p) requireNamespace(p, quietly = TRUE)

  if (!quiet) message("== R packages ==")
  for (p in required) {
    if (have(p)) {
      if (!quiet) message(sprintf("ok   %-14s", p))
    } else {
      message(sprintf("MISS %-14s install.packages('%s')", p, p))
      ok <- FALSE
    }
  }
  for (p in suggested) {
    if (have(p)) {
      if (!quiet) message(sprintf("ok   %-14s", p))
    } else if (!quiet) {
      message(sprintf("warn %-14s needed only for the review app", p))
    }
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
#' @param config Path to a YAML config, or a config list from [dd_config()].
#' @param parallel Optional integer overriding `parallel` from the config.
#' @param quiet Logical; suppress stage output from the shell workers.
#' @return A list with `enumerated`, `todo`, `photos` and `errors` counts,
#'   invisibly.
#' @examples
#' \dontrun{
#' dd_run_inventory("config.yml")
#' }
#' @export
dd_run_inventory <- function(config = "config.yml", parallel = NULL,
                             quiet = FALSE) {
  cfg <- dd_as_config(config, require_library = TRUE)
  if (!is.null(parallel)) cfg$parallel <- as.integer(parallel)

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
  n_todo <- dd_with_con(cfg, function(con) {
    dd_resume_todo(con, enum, todo)
  })
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
  res <- dd_with_con(cfg, function(con) dd_import_staging(con, cfg, quiet = quiet))
  message(sprintf("inventory: merged %d photo row(s), %d error row(s)",
                  res$photos, res$errors))

  invisible(list(enumerated = n_enum, todo = n_todo,
                 photos = res$photos, errors = res$errors))
}

# --- phase 2: analyze + review ---------------------------------------------

#' Run the analyze phase.
#'
#' Builds exact groups (shared decoded-pixel hash) and near groups (Hamming
#' distance under `hamming_threshold`, blocked by LSH) and rewrites the
#' `groups` table.
#'
#' @param config Path to a YAML config, or a config list from [dd_config()].
#' @param quiet Logical; suppress phase/progress feedback.
#' @return The group membership data frame, invisibly.
#' @examples
#' \dontrun{
#' dd_run_analyze("config.yml")
#' }
#' @export
dd_run_analyze <- function(config = "config.yml", quiet = FALSE) {
  cfg <- dd_as_config(config)
  dd_phase("analyze", quiet = quiet)
  out <- dd_with_con(cfg, function(con) dd_analyze(con, cfg, quiet = quiet))
  ngroups <- if (nrow(out)) length(unique(out$group_id)) else 0L
  message(sprintf("analyze: %d group(s) covering %d photo(s)",
                  ngroups, nrow(out)))
  invisible(out)
}

#' Launch the Shiny review app.
#'
#' The config is resolved to absolute paths before launching, because
#' [shiny::runApp()] changes the working directory to the app folder.
#'
#' @param config Path to a YAML config, or a config list from [dd_config()].
#' @param port Port to serve on.
#' @param launch_browser Logical; open a browser window.
#' @return The value of [shiny::runApp()], invisibly.
#' @examples
#' \dontrun{
#' dd_app("config.yml", port = 7654)
#' }
#' @export
dd_app <- function(config = "config.yml", port = 7654L,
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
  resolved <- dd_config_tempfile(cfg)
  old <- Sys.getenv("DUNDEE_CONFIG", unset = NA)
  Sys.setenv(DUNDEE_CONFIG = resolved)
  on.exit({
    if (is.na(old)) Sys.unsetenv("DUNDEE_CONFIG") else Sys.setenv(DUNDEE_CONFIG = old)
    unlink(resolved)
  }, add = TRUE)

  message(sprintf("review app: http://127.0.0.1:%d", as.integer(port)))
  invisible(shiny::runApp(app_dir, port = as.integer(port),
                          launch.browser = isTRUE(launch_browser)))
}

# --- phase 3: plan + move ---------------------------------------------------

#' Plan the Phase 3 moves.
#'
#' Optionally applies the bulk preference rules to any still-undecided group,
#' then writes `moves.tsv` and a reviewable `moves.sh` under `work_dir`.
#' Nothing is executed and nothing is written on the server.
#'
#' @param config Path to a YAML config, or a config list from [dd_config()].
#' @param bulk Logical; apply [dd_apply_bulk_decisions()] before planning.
#' @param quiet Logical; suppress phase/progress feedback.
#' @return The move plan, invisibly.
#' @examples
#' \dontrun{
#' dd_run_plan("config.yml", bulk = TRUE)
#' }
#' @export
dd_run_plan <- function(config = "config.yml", bulk = FALSE, quiet = FALSE) {
  cfg <- dd_as_config(config)
  dd_require_move_config(cfg)
  dd_phase("plan", quiet = quiet)
  out <- dd_with_con(cfg, function(con) {
    if (isTRUE(bulk)) {
      dd_step("applying bulk preference decisions", quiet = quiet)
      n <- dd_apply_bulk_decisions(con, cfg, quiet = quiet)
      message(sprintf("applied bulk decisions to %d undecided photo(s)", n))
    }
    dd_step("planning moves", quiet = quiet)
    dd_plan_moves(con, cfg, quiet = quiet)
  })
  invisible(out)
}

#' Execute the planned moves server-side over SSH.
#'
#' Dry run by default: prints what would be streamed to the server. Pass
#' `execute = TRUE` to perform the on-volume renames. The generated script is
#' idempotent, so an interrupted run can simply be repeated.
#'
#' @param config Path to a YAML config, or a config list from [dd_config()].
#' @param execute Logical; perform the moves instead of describing them.
#' @return `TRUE`, invisibly.
#' @examples
#' \dontrun{
#' dd_run_move("config.yml")                  # dry run
#' dd_run_move("config.yml", execute = TRUE)  # for real
#' }
#' @export
dd_run_move <- function(config = "config.yml", execute = FALSE) {
  cfg <- dd_as_config(config)
  dd_require_move_config(cfg)
  dd_phase("move")
  script <- file.path(cfg$work_dir, "moves.sh")
  if (!file.exists(script)) {
    stop("dundee: no move script at ", script,
         ". Run dd_run_plan() first.", call. = FALSE)
  }
  target <- paste0(cfg$ssh_user, "@", cfg$ssh_host)
  dd_sh("70-execute-moves.sh",
        c(script, target, if (isTRUE(execute)) "--execute" else ""))
  invisible(TRUE)
}

# Fail early, with one clear message, if Phase 3 config is incomplete.
dd_require_move_config <- function(cfg) {
  need <- c("ssh_user", "ssh_host", "nas_root", "preferred_root",
            "nonpreferred_root")
  missing <- need[vapply(need, function(k) {
    v <- cfg[[k]]
    is.null(v) || !nzchar(as.character(v)[1])
  }, logical(1))]
  if (length(missing)) {
    stop("dundee: config field(s) required for the move phase are unset: ",
         paste(missing, collapse = ", "), call. = FALSE)
  }
  invisible(TRUE)
}

# --- command line dispatch --------------------------------------------------

#' Dispatch a dundee command from the command line.
#'
#' Backs the `run.sh` wrapper. Not normally called interactively.
#'
#' @param args Character vector of arguments, e.g. `commandArgs(TRUE)`.
#' @return Invisibly, the value of the dispatched stage.
#' @examples
#' \dontrun{
#' dd_cli(c("analyze", "config.yml"))
#' }
#' @export
dd_cli <- function(args = commandArgs(trailingOnly = TRUE)) {
  usage <- paste(
    "usage: run.sh <command> [config.yml] [options]",
    "  preflight                      check external tools and R packages",
    "  inventory [config] [--parallel=N] [--quiet]",
    "  analyze   [config] [--quiet]",
    "  app       [config] [--port=N]",
    "  plan      [config] [--bulk] [--quiet]",
    "  move      [config] [--execute]",
    "  (--quiet suppresses phase banners and progress output)",
    sep = "\n"
  )
  if (!length(args) || args[[1]] %in% c("help", "-h", "--help")) {
    cat(usage, "\n", sep = "")
    return(invisible(NULL))
  }

  cmd <- args[[1]]
  rest <- args[-1]
  flags <- grepl("^--", rest)
  cfg_path <- if (any(!flags)) rest[!flags][[1]] else "config.yml"
  quiet <- "--quiet" %in% rest
  opt <- function(name, default = NULL) {
    hit <- grep(paste0("^--", name, "="), rest, value = TRUE)
    if (length(hit)) sub(paste0("^--", name, "="), "", hit[[1]]) else default
  }

  out <- switch(
    cmd,
    preflight = dd_preflight(quiet = quiet),
    inventory = dd_run_inventory(cfg_path,
                                 parallel = opt("parallel"), quiet = quiet),
    analyze   = dd_run_analyze(cfg_path, quiet = quiet),
    app       = dd_app(cfg_path,
                       port = as.integer(opt("port", 7654L)),
                       launch_browser = TRUE),
    plan      = dd_run_plan(cfg_path, bulk = "--bulk" %in% rest, quiet = quiet),
    move      = dd_run_move(cfg_path, execute = "--execute" %in% rest),
    stop("dundee: unknown command '", cmd, "'.\n", usage, call. = FALSE)
  )
  invisible(out)
}
