# dundee executes nothing in phase 3, which is what makes it testable: with no
# server side and no ssh to stub, the generated script can simply be run against
# a temp library and checked against what actually moved.

move_store <- function(rel = c("a.jpg", "sub b/c.jpg", "café.jpg"),
                       preferred = c(TRUE, FALSE, TRUE)) {
  cfg <- dd_config_defaults()
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  cfg$library_root <- tempfile("lib-"); dir.create(cfg$library_root)
  cfg$preferred_root <- file.path(cfg$library_root, "_dedup", "preferred")
  cfg$nonpreferred_root <- file.path(cfg$library_root, "_dedup",
                                     "non-preferred")
  cfg$cruft <- c(cfg$cruft, "_dedup")

  con <- dd_db_connect(cfg); dd_db_init(con)
  for (i in seq_along(rel)) {
    p <- file.path(cfg$library_root, rel[i])
    dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    writeLines(rel[i], p)
    DBI::dbExecute(con,
      "INSERT INTO photos(path, rel_path, size, width, height, meta_count,
                          pixel_hash, fingerprint)
       VALUES(?, ?, 10, 10, 10, 1, 'h', '0f0f0f0f0f0f0f0f')",
      params = list(p, rel[i]))
    # Group membership too, not just the decision: dd_status() reads both, and
    # a decided photo that belongs to no group cannot happen in a real store.
    DBI::dbExecute(con,
      "INSERT INTO groups(group_id, photo_id, tier) VALUES(1, ?, 'exact')",
      params = list(i))
    DBI::dbExecute(con,
      "INSERT INTO decisions(photo_id, group_id, preferred, decided_by)
       VALUES(?, 1, ?, 'test')",
      params = list(i, as.integer(preferred[i])))
  }
  list(cfg = cfg, con = con, rel = rel, preferred = preferred)
}

script_of <- function(s) file.path(s$cfg$work_dir, "moves.sh")

run_script <- function(s, args = character(0)) {
  out <- suppressWarnings(system2("bash", c(script_of(s), args),
                                  stdout = TRUE, stderr = TRUE))
  list(out = paste(out, collapse = "\n"),
       status = as.integer(attr(out, "status") %||% 0L))
}

`%||%` <- function(a, b) if (is.null(a)) b else a

plan_quietly <- function(s) {
  suppressMessages(dd_plan_moves(s$con, s$cfg, quiet = TRUE))
}

test_that("dest mapping routes preferred and non-preferred correctly", {
  cfg <- dd_config_defaults()
  cfg$preferred_root <- "/v/pref"
  cfg$nonpreferred_root <- "/v/non"
  expect_equal(dd_map_dest("2020/a.jpg", TRUE, cfg), "/v/pref/2020/a.jpg")
  expect_equal(dd_map_dest("2020/a.jpg", FALSE, cfg), "/v/non/2020/a.jpg")
})

# --- what the plan refuses to do -------------------------------------------

test_that("a destination outside library_root is rejected by name", {
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  # A server-side path is not a slower destination on this machine but a
  # nonexistent one, so unchecked the plan names 3 moves into a tree that
  # cannot be created.
  s$cfg$preferred_root <- "/volume1/photo/_dedup/preferred"
  err <- expect_error(dd_require_move_config(s$cfg), "under library_root")
  expect_match(conditionMessage(err), "preferred_root", fixed = TRUE)
  expect_false(grepl("nonpreferred_root", conditionMessage(err), fixed = TRUE))
  expect_match(conditionMessage(err), s$cfg$library_root, fixed = TRUE)
})

test_that("a sibling of library_root is not under it", {
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  # The prefix test has to compare path components: "<lib>-dedup" starts with
  # the library root as a string but is a different directory.
  s$cfg$nonpreferred_root <- paste0(s$cfg$library_root, "-dedup")
  expect_error(dd_require_move_config(s$cfg), "nonpreferred_root")

  s$cfg$nonpreferred_root <- s$cfg$library_root      # the root itself is under
  expect_true(dd_require_move_config(s$cfg))
})

test_that("an unset destination root is named before anything else", {
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  s$cfg$nonpreferred_root <- NULL
  expect_error(dd_require_move_config(s$cfg), "nonpreferred_root")
})

test_that("destinations the enumerator would re-scan raise a warning", {
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  s$cfg$cruft <- setdiff(s$cfg$cruft, "_dedup")
  # The trees live inside library_root, so without pruning them the next
  # inventory files every moved photo as a brand new one.
  expect_warning(suppressMessages(dd_plan_moves(s$con, s$cfg, quiet = TRUE)),
                 "cruft")

  s$cfg$cruft <- c(s$cfg$cruft, "_dedup")
  expect_no_warning(suppressMessages(dd_plan_moves(s$con, s$cfg, quiet = TRUE)))
})

# --- the script dundee writes ----------------------------------------------

test_that("the script is one do_move row per planned photo, executable", {
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  m <- plan_quietly(s)
  expect_equal(nrow(m), 3L)

  lines <- readLines(script_of(s), warn = FALSE, encoding = "UTF-8")
  # Every row names its tier, so reading the script tells you what it will do.
  expect_equal(sum(grepl("^move_preferred ", lines)), 2L)
  expect_equal(sum(grepl("^move_nonpreferred ", lines)), 1L)
  expect_equal(as.character(file.mode(script_of(s))), "755")
  # The header must name where things are going: this file is meant to be read
  # before it is run.
  expect_true(any(grepl(s$cfg$preferred_root, lines, fixed = TRUE)))
  expect_true(any(grepl(s$cfg$nonpreferred_root, lines, fixed = TRUE)))
})

test_that("awkward paths survive into the script as themselves", {
  # dd_plan_moves() writes with useBytes = TRUE precisely so the bytes survive
  # a C locale; re-encoding would put <c3><a9> in the script and mv would then
  # fail to find a file that is sitting right there.
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  raw <- readLines(script_of(s), warn = FALSE, encoding = "UTF-8")
  expect_true(any(grepl("café.jpg", raw, fixed = TRUE)))
  expect_false(any(grepl("<c3>", raw, fixed = TRUE)))
  # The space is inside a single-quoted argument, so the shell sees one path.
  expect_true(any(grepl("sub b/c.jpg'", raw, fixed = TRUE)))
})

test_that("re-planning discards the receipt of the plan it replaces", {
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  logs <- file.path(s$cfg$work_dir,
                    c("moves.done.tsv", "moves.failed.tsv", "moves.kept.tsv"))
  for (f in logs) writeLines("1\t/old\t/older\t2020-01-01T00:00:00", f)
  plan_quietly(s)
  # Left in place they would re-credit a photo that has since been moved back.
  expect_false(any(file.exists(logs)))
})

# --- running it -------------------------------------------------------------

test_that("a dry run reports the work and touches nothing", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)

  r <- run_script(s, c("--dry-run", "--include-preferred"))
  expect_equal(r$status, 0L)
  expect_match(r$out, "DRY RUN")
  expect_match(r$out, "3 to move, 0 already at destination")
  expect_true(all(file.exists(file.path(s$cfg$library_root, s$rel))))
  expect_false(dir.exists(s$cfg$preferred_root))
  expect_false(file.exists(file.path(s$cfg$work_dir, "moves.done.tsv")))
  expect_false(file.exists(file.path(s$cfg$work_dir, "moves.kept.tsv")))
})

test_that("a dry run writes no failure log either", {
  skip_on_os("windows")
  # The conflict branch is the one that has something to say before any move is
  # attempted, so it is the one that can write during a rehearsal.
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  dir.create(s$cfg$preferred_root, recursive = TRUE)
  file.create(file.path(s$cfg$preferred_root, "a.jpg"))

  r <- run_script(s, c("--dry-run", "--include-preferred"))
  expect_equal(r$status, 0L)
  expect_match(r$out, "1 blocked")
  expect_false(file.exists(file.path(s$cfg$work_dir, "moves.failed.tsv")))
})

test_that("--include-preferred moves both tiers, and repeats cleanly", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)

  r <- run_script(s, "--include-preferred")
  expect_equal(r$status, 0L)
  expect_match(r$out, "3 moved, 0 already at destination")
  expect_false(file.exists(file.path(s$cfg$work_dir, "moves.kept.tsv")))

  expect_false(any(file.exists(file.path(s$cfg$library_root, s$rel))))
  expect_true(file.exists(file.path(s$cfg$preferred_root, "a.jpg")))
  expect_true(file.exists(file.path(s$cfg$preferred_root, "café.jpg")))
  expect_true(file.exists(file.path(s$cfg$nonpreferred_root, "sub b/c.jpg")))

  done <- file.path(s$cfg$work_dir, "moves.done.tsv")
  rows <- readLines(done, warn = FALSE, encoding = "UTF-8")
  expect_length(rows, 3L)
  expect_setequal(vapply(strsplit(rows, "\t", fixed = TRUE), `[`,
                         character(1), 1L), c("1", "2", "3"))

  # Idempotent: sources gone, destinations there, nothing left to do.
  r2 <- run_script(s, "--include-preferred")
  expect_equal(r2$status, 0L)
  expect_match(r2$out, "0 moved, 3 already at destination")
  expect_length(readLines(done, warn = FALSE), 3L)
})

test_that("one failure is recorded and the rest of the batch still moves", {
  skip_on_os("windows")
  # do_move captures each failure, records it and returns 0, which is what keeps
  # the batch going. Let a failure propagate out of it instead and `set -e` ends
  # the run with two photos unaccounted for.
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)

  # A plain file where the preferred tree needs a directory: mkdir -p fails
  # deterministically, for anyone, root included.
  dir.create(dirname(s$cfg$preferred_root), recursive = TRUE)
  writeLines("not a directory", s$cfg$preferred_root)

  r <- run_script(s, "--include-preferred")
  expect_equal(r$status, 1L)
  expect_match(r$out, "2 failed")

  failed <- file.path(s$cfg$work_dir, "moves.failed.tsv")
  expect_length(readLines(failed, warn = FALSE), 2L)
  # The non-preferred photo moved anyway.
  expect_true(file.exists(file.path(s$cfg$nonpreferred_root, "sub b/c.jpg")))
  expect_length(readLines(file.path(s$cfg$work_dir, "moves.done.tsv"),
                          warn = FALSE), 1L)
})

test_that("the script refuses a library that is not mounted", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  # An empty mount point is the dangerous case: every source is "missing", the
  # run reports success, and the destinations get made on the local disk.
  unlink(file.path(s$cfg$library_root, s$rel))
  unlink(file.path(s$cfg$library_root, "sub b"), recursive = TRUE)

  r <- run_script(s, "--include-preferred")
  expect_equal(r$status, 1L)
  expect_match(r$out, "not mounted")
  expect_false(dir.exists(s$cfg$preferred_root))
})

test_that("the script refuses a read-only library, but rehearses on one", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  Sys.chmod(s$cfg$library_root, "0555")
  on.exit(Sys.chmod(s$cfg$library_root, "0755"), add = TRUE)
  skip_if(file.access(s$cfg$library_root, 2L) == 0L,
          "the library cannot be made read-only here")

  r <- run_script(s, "--include-preferred")
  expect_equal(r$status, 1L)
  expect_match(r$out, "read-only")
  expect_match(r$out, "remount")

  # The rehearsal is the whole point of being able to run it before remounting.
  expect_equal(run_script(s, "--dry-run")$status, 0L)
})

test_that("the generated script is shellcheck clean", {
  skip_if(!nzchar(Sys.which("shellcheck")), "no shellcheck on PATH")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  out <- suppressWarnings(system2("shellcheck", c("-s", "bash",
                                                 script_of(s)),
                                  stdout = TRUE, stderr = TRUE))
  expect_equal(as.integer(attr(out, "status") %||% 0L), 0L,
               info = paste(out, collapse = "\n"))
})

# --- reconciling ------------------------------------------------------------

test_that("moving without a plan names the step that was skipped", {
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  expect_error(dd_run_move(s$cfg, quiet = TRUE), "Run dd_run_plan\\(\\) first")
})

test_that("the receipt is read by photo_id, not by parsing paths", {
  # A filename may legally contain a tab, and read.table()'s quote and
  # comment.char defaults mangle ordinary ones. Field 1 is all that is needed.
  f <- tempfile()
  writeLines(c("7\t/a\tb\"c#d\t2020-01-01T00:00:00",
               "9\t/x\t/y\t2020-01-01T00:00:00",
               ""), f, useBytes = TRUE)
  expect_equal(dd_move_receipt(f), c(7L, 9L))
  expect_equal(dd_move_receipt(tempfile()), integer(0))
})

test_that("reconciling credits the receipt, then checks the library itself", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  DBI::dbDisconnect(s$con)
  run_script(s, "--include-preferred")

  # Photo 2 is dropped from the receipt: it moved, but the script that says so
  # is not the only evidence available -- the library itself is.
  done <- file.path(s$cfg$work_dir, "moves.done.tsv")
  rows <- readLines(done, warn = FALSE, encoding = "UTF-8")
  keep <- rows[vapply(strsplit(rows, "\t", fixed = TRUE), `[`,
                      character(1), 1L) != "2"]
  writeLines(keep, done, useBytes = TRUE)

  msgs <- capture_messages(n <- dd_run_move(s$cfg, quiet = TRUE))
  expect_equal(n, c(done = 3L, kept = 0L))
  expect_match(msgs, "records 2 of 3 outstanding", all = FALSE)
  expect_match(msgs, "of the remaining 1: 1 moved", all = FALSE)

  s$con <- dd_db_connect(s$cfg)
  st <- DBI::dbGetQuery(s$con, "SELECT state, moved_at FROM moves")
  expect_equal(sort(st$state), rep("done", 3L))
  expect_true(all(nzchar(st$moved_at)))
})

test_that("a source gone with nothing at the destination stays planned", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  DBI::dbDisconnect(s$con)

  # No script run at all: one photo deleted by something else, one still there.
  unlink(file.path(s$cfg$library_root, "a.jpg"))

  msgs <- capture_messages(n <- dd_run_move(s$cfg, quiet = TRUE))
  expect_equal(unname(sum(n)), 0L)
  expect_match(msgs, "no moves.done.tsv", all = FALSE)
  expect_match(msgs, "1 source\\(s\\) gone with nothing at the destination",
               all = FALSE)

  s$con <- dd_db_connect(s$cfg)
  expect_equal(sort(DBI::dbGetQuery(s$con, "SELECT state FROM moves")$state),
               rep("planned", 3L))
})

test_that("reconciling a second time has nothing left to do", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  DBI::dbDisconnect(s$con)
  run_script(s, "--include-preferred")
  suppressMessages(dd_run_move(s$cfg, quiet = TRUE))

  msgs <- capture_messages(n <- dd_run_move(s$cfg, quiet = TRUE))
  expect_equal(unname(sum(n)), 0L)
  expect_match(msgs, "nothing outstanding", all = FALSE)
  s$con <- dd_db_connect(s$cfg)
  expect_equal(DBI::dbGetQuery(s$con,
    "SELECT COUNT(*) n FROM moves WHERE state = 'done'")$n, 3L)
})

# --- the default: only the rejects leave ------------------------------------

test_that("a plain run moves the non-preferred out and leaves the winners", {
  skip_on_os("windows")
  # Quarantining the rejects is already a library without duplicates, and the
  # folders the user knows stay as they were. The fixture is two preferred
  # copies and one non-preferred.
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)

  r <- run_script(s)
  expect_equal(r$status, 0L)
  expect_match(r$out, "1 moved")
  expect_match(r$out, "2 preferred copy\\(ies\\) left in place")
  expect_match(r$out, "--include-preferred", fixed = TRUE)

  expect_true(file.exists(file.path(s$cfg$library_root, "a.jpg")))
  expect_true(file.exists(file.path(s$cfg$library_root, "café.jpg")))
  expect_false(dir.exists(s$cfg$preferred_root))
  expect_true(file.exists(file.path(s$cfg$nonpreferred_root, "sub b/c.jpg")))

  kept <- file.path(s$cfg$work_dir, "moves.kept.tsv")
  expect_setequal(vapply(strsplit(readLines(kept, warn = FALSE,
                                            encoding = "UTF-8"),
                                  "\t", fixed = TRUE), `[`, character(1), 1L),
                  c("1", "3"))
  expect_length(readLines(file.path(s$cfg$work_dir, "moves.done.tsv"),
                          warn = FALSE), 1L)
})

test_that("a dry run counts what would stay without writing the kept log", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)

  r <- run_script(s, "--dry-run")
  expect_equal(r$status, 0L)
  expect_match(r$out, "1 to move")
  expect_match(r$out, "2 preferred copy\\(ies\\) would stay in place")
  expect_false(file.exists(file.path(s$cfg$work_dir, "moves.kept.tsv")))
  expect_true(all(file.exists(file.path(s$cfg$library_root, s$rel))))
})

test_that("an unrecognised flag exits 2 and says what the default is", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)

  r <- run_script(s, "--move-everything")
  expect_equal(r$status, 2L)
  expect_match(r$out, "usage:")
  expect_match(r$out, "leave")
})

# --- kept, in the store -----------------------------------------------------

test_that("reconciling a default run marks the winners kept, not done", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  DBI::dbDisconnect(s$con)
  run_script(s)

  msgs <- capture_messages(n <- dd_run_move(s$cfg, quiet = TRUE))
  expect_equal(n, c(done = 1L, kept = 2L))
  expect_match(msgs, "moves.kept.tsv records 2 left in place", all = FALSE)

  s$con <- dd_db_connect(s$cfg)
  st <- DBI::dbGetQuery(s$con, "SELECT photo_id, state FROM moves ORDER BY photo_id")
  expect_equal(st$state, c("kept", "done", "kept"))

  # And the project is no longer outstanding work.
  out <- suppressMessages(dd_status(s$cfg))
  expect_equal(c(out$planned, out$done, out$kept), c(0L, 1L, 2L))
  expect_match(capture_messages(dd_status(s$cfg)), "next: nothing", all = FALSE)
})

test_that("a kept row becomes done once the winners are actually moved", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  DBI::dbDisconnect(s$con)
  run_script(s)
  suppressMessages(dd_run_move(s$cfg, quiet = TRUE))

  # Changed your mind: relocate the winners too. kept must not be a dead end.
  run_script(s, "--include-preferred")
  n <- suppressMessages(dd_run_move(s$cfg, quiet = TRUE))
  expect_equal(n, c(done = 2L, kept = 0L))

  s$con <- dd_db_connect(s$cfg)
  expect_equal(DBI::dbGetQuery(s$con,
    "SELECT COUNT(*) n FROM moves WHERE state = 'done'")$n, 3L)
  expect_true(file.exists(file.path(s$cfg$preferred_root, "café.jpg")))
})

test_that("a kept claim is verified against the library, not trusted", {
  skip_on_os("windows")
  # The kept log says a photo stayed put. If it is not at its source, it did
  # not -- and the normal evidence check decides, exactly as for a move.
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  DBI::dbDisconnect(s$con)
  run_script(s)

  # Photo 1 moved by hand after the script claimed it was left alone.
  dir.create(s$cfg$preferred_root, recursive = TRUE)
  file.rename(file.path(s$cfg$library_root, "a.jpg"),
              file.path(s$cfg$preferred_root, "a.jpg"))

  msgs <- capture_messages(n <- dd_run_move(s$cfg, quiet = TRUE))
  expect_equal(n, c(done = 2L, kept = 1L))
  expect_match(msgs, "1 of its rows moved after all", all = FALSE)

  s$con <- dd_db_connect(s$cfg)
  st <- DBI::dbGetQuery(s$con, "SELECT photo_id, state FROM moves ORDER BY photo_id")
  expect_equal(st$state, c("done", "done", "kept"))
})

test_that("withdrawing a decision prunes its kept row", {
  skip_on_os("windows")
  s <- move_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  plan_quietly(s)
  DBI::dbDisconnect(s$con)
  run_script(s)
  suppressMessages(dd_run_move(s$cfg, quiet = TRUE))

  # A kept row records a decision not to move, not a move that happened, so it
  # must not outlive the decision -- the same rule planned rows follow.
  s$con <- dd_db_connect(s$cfg)
  DBI::dbExecute(s$con, "DELETE FROM decisions WHERE photo_id = 1")
  plan_quietly(s)
  expect_equal(DBI::dbGetQuery(s$con,
    "SELECT COUNT(*) n FROM moves WHERE photo_id = 1")$n, 0L)
})
