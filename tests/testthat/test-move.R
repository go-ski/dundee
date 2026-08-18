test_that("path translation maps SMB root to NAS root", {
  cfg <- dd_config_defaults()
  cfg$library_root <- "/Volumes/photo"
  cfg$nas_root <- "/volume1/photo"
  expect_equal(dd_translate_path("/Volumes/photo/2020/a.jpg", cfg),
               "/volume1/photo/2020/a.jpg")
  # Vectorised, and tolerant of trailing slashes in config.
  cfg$nas_root <- "/volume1/photo/"
  expect_equal(dd_translate_path(c("/Volumes/photo/x y/b.jpg"), cfg),
               "/volume1/photo/x y/b.jpg")
})

test_that("translation rejects paths outside the library root", {
  cfg <- dd_config_defaults()
  cfg$library_root <- "/Volumes/photo"
  cfg$nas_root <- "/volume1/photo"
  expect_error(dd_translate_path("/elsewhere/a.jpg", cfg),
               "not under library_root")
})

test_that("dest mapping routes preferred and non-preferred correctly", {
  cfg <- dd_config_defaults()
  cfg$preferred_root <- "/v/pref"
  cfg$nonpreferred_root <- "/v/non"
  expect_equal(dd_map_dest("2020/a.jpg", TRUE, cfg), "/v/pref/2020/a.jpg")
  expect_equal(dd_map_dest("2020/a.jpg", FALSE, cfg), "/v/non/2020/a.jpg")
})

# --- the local half of phase 3 ---------------------------------------------
#
# 70-execute-moves.sh used to own the dry run and the ssh handoff. Both are R
# now, so both are reachable from here.

move_cfg <- function() {
  cfg <- dd_config_defaults()
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  cfg$ssh_user <- "tester"
  cfg$ssh_host <- "nas.local"
  cfg$nas_root <- "/volume1/photo"
  cfg$preferred_root <- "/volume1/pref"
  cfg$nonpreferred_root <- "/volume1/non"
  cfg
}

write_moves <- function(cfg, lines) {
  script <- file.path(cfg$work_dir, "moves.sh")
  writeLines(c("#!/usr/bin/env bash", "set -euo pipefail", lines), script,
             useBytes = TRUE)
  script
}

test_that("a dry run counts the move commands and never contacts the server", {
  cfg <- move_cfg()
  write_moves(cfg, c("if [ -e '/a' ]; then mv -n '/a' '/b'; fi",
                     "if [ -e '/c' ]; then mv -n '/c' '/d'; fi"))
  msgs <- capture_messages(dd_run_move(cfg, quiet = TRUE))
  expect_match(msgs, "DRY RUN. Would stream 2 move command\\(s\\)", all = FALSE)
  expect_no_match(msgs, "executing moves server-side", all = TRUE)
})

test_that("moving without a plan names the step that was skipped", {
  cfg <- move_cfg()
  expect_error(dd_run_move(cfg, quiet = TRUE), "Run dd_run_plan\\(\\) first")
})

test_that("a dry run leaves the moves table alone", {
  cfg <- move_cfg()
  write_moves(cfg, "if [ -e '/a' ]; then mv -n '/a' '/b'; fi")
  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  dd_db_init(con)
  DBI::dbExecute(con, "INSERT INTO photos(path, rel_path, size, width, height,
                                          meta_count, pixel_hash, fingerprint)
                       VALUES('/a', 'a', 1, 1, 1, 0, 'h', '0f0f0f0f0f0f0f0f')")
  dd_upsert(con, "moves",
            data.frame(photo_id = 1L, src = "/a", dest = "/b",
                       state = "planned", moved_at = NA_character_,
                       stringsAsFactors = FALSE),
            key_cols = "photo_id")
  suppressMessages(dd_run_move(cfg, quiet = TRUE))
  expect_equal(DBI::dbGetQuery(con, "SELECT state FROM moves")$state, "planned")
})

test_that("the preview prints non-ASCII paths as themselves", {
  # dd_plan_moves() writes the script with useBytes = TRUE precisely so the
  # bytes survive a C locale; reading it back without marking UTF-8 and writing
  # it out without useBytes would re-encode and print <c3><a9> escapes.
  script <- tempfile(fileext = ".sh")
  writeLines(c("#!/usr/bin/env bash",
               "if [ -e '/l/café.jpg' ]; then mv -n '/l/café.jpg' '/p/café.jpg'; fi"),
             script, useBytes = TRUE)
  out <- suppressMessages(capture.output(dd_move_preview(script, "u@h")))
  expect_true(any(grepl("café", out, fixed = TRUE)))
  expect_false(any(grepl("<c3>", out, fixed = TRUE)))
})

test_that("execute streams the script to ssh and marks the batch done", {
  skip_on_os("windows")
  # A stub ssh that records how it was called and what it was fed. The shell
  # script this replaced ran `ssh "$target" 'bash -s' < "$script"`; the port has
  # to reproduce both the argv and the byte-exact stdin.
  bin <- tempfile("bin-"); dir.create(bin)
  rec <- tempfile("ssh-")
  writeLines(c("#!/usr/bin/env bash",
               'printf "%s\\n" "$@" > "$DD_TEST_REC.argv"',
               'cat > "$DD_TEST_REC.stdin"'),
             file.path(bin, "ssh"))
  Sys.chmod(file.path(bin, "ssh"), "0755")

  old_path <- Sys.getenv("PATH")
  Sys.setenv(PATH = paste(bin, old_path, sep = .Platform$path.sep),
             DD_TEST_REC = rec)
  on.exit({ Sys.setenv(PATH = old_path); Sys.unsetenv("DD_TEST_REC") },
          add = TRUE)

  cfg <- move_cfg()
  line <- "if [ -e '/l/café.jpg' ]; then mv -n '/l/café.jpg' '/p/café.jpg'; fi"
  script <- write_moves(cfg, line)

  con <- dd_db_connect(cfg)
  dd_db_init(con)
  DBI::dbExecute(con, "INSERT INTO photos(path, rel_path, size, width, height,
                                          meta_count, pixel_hash, fingerprint)
                       VALUES('/l/café.jpg', 'café.jpg', 1, 1, 1, 0, 'h',
                              '0f0f0f0f0f0f0f0f')")
  dd_upsert(con, "moves",
            data.frame(photo_id = 1L, src = "/l/café.jpg", dest = "/p/café.jpg",
                       state = "planned", moved_at = NA_character_,
                       stringsAsFactors = FALSE),
            key_cols = "photo_id")
  DBI::dbDisconnect(con)

  suppressMessages(dd_run_move(cfg, execute = TRUE, quiet = TRUE))

  expect_equal(readLines(paste0(rec, ".argv")), c("tester@nas.local", "bash -s"))
  # Byte-exact: the script reaches ssh as the file, never re-encoded through R.
  expect_equal(readBin(paste0(rec, ".stdin"), "raw", file.size(script)),
               readBin(script, "raw", file.size(script)))

  con <- dd_db_connect(cfg); on.exit(DBI::dbDisconnect(con), add = TRUE)
  done <- DBI::dbGetQuery(con, "SELECT state, moved_at FROM moves")
  expect_equal(done$state, "done")
  expect_true(nzchar(done$moved_at))
})
