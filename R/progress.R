# Lightweight, base-R progress + phase feedback shared across the pipeline.
# Everything writes to stderr (via message() or a txtProgressBar on stderr), so
# captured stdout and stage return values are unaffected. All helpers honour a
# `quiet` flag, and animation is used only when stderr is an interactive
# terminal; redirected output falls back to periodic milestone lines.

# TRUE when stderr is a terminal (animate); FALSE in logs/pipes.
dd_is_tty <- function() {
  isTRUE(tryCatch(isatty(stderr()), error = function(e) FALSE))
}

# Static pipeline ordinals, purely informational (commands run one at a time).
dd_phase_ordinal <- c(preflight = 0L, inventory = 1L, analyze = 2L,
                      plan = 3L, move = 3L)

# Phase banner, e.g. "== Phase: inventory (1 of 3) =============".
dd_phase <- function(label, quiet = FALSE) {
  if (isTRUE(quiet)) return(invisible(NULL))
  ord <- dd_phase_ordinal[[label]]
  head <- if (!is.null(ord) && ord >= 1L) {
    sprintf("Phase: %s (%d of 3)", label, ord)
  } else {
    sprintf("Phase: %s", label)
  }
  rule <- strrep("=", max(3L, 60L - nchar(head) - 4L))
  message(sprintf("== %s %s", head, rule))
  invisible(NULL)
}

# Indented sub-step announcement.
dd_step <- function(msg, quiet = FALSE) {
  if (isTRUE(quiet)) return(invisible(NULL))
  message(sprintf("   -> %s", msg))
  invisible(NULL)
}

# Progress reporter over a known total. Returns a list of closures:
#   $tick(n = 1) advance by n; $set(i) set absolute position; $done() finish.
# TTY -> live txtProgressBar; non-TTY -> milestone lines every ~10%;
# quiet or non-positive total -> no-ops.
dd_progress <- function(total, label = "", quiet = FALSE) {
  total <- suppressWarnings(as.integer(total))
  noop <- list(tick = function(n = 1L) invisible(NULL),
               set  = function(i) invisible(NULL),
               done = function() invisible(NULL))
  if (isTRUE(quiet) || is.na(total) || total <= 0L) return(noop)

  cur <- 0L
  if (dd_is_tty()) {
    if (nzchar(label)) message(sprintf("   -> %s (%d)", label, total))
    bar <- utils::txtProgressBar(min = 0L, max = total, style = 3L,
                                 file = stderr())
    set <- function(i) {
      cur <<- i
      utils::setTxtProgressBar(bar, min(as.integer(i), total))
    }
    list(
      tick = function(n = 1L) set(cur + as.integer(n)),
      set  = set,
      done = function() { utils::setTxtProgressBar(bar, total); close(bar) }
    )
  } else {
    lbl <- if (nzchar(label)) label else "progress"
    last <- -1L
    report <- function(i) {
      cur <<- i
      step <- (as.integer(100 * i / total) %/% 10L) * 10L
      if (step > last && step >= 10L) {
        last <<- step
        message(sprintf("   %s: %d%% (%d/%d)", lbl, step,
                        min(as.integer(i), total), total))
      }
    }
    list(
      tick = function(n = 1L) report(cur + as.integer(n)),
      set  = report,
      done = function() invisible(NULL)
    )
  }
}
