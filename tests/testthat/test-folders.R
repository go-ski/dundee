# The directory view exists because group counts are unreviewable and directory
# counts are not: a library gains duplicates by being copied wholesale, so the
# tree, not the file, usually says which copy to keep. These tests fix the
# collapsing rule, and fix that the audit reports what the bulk pass would
# really do -- a preview that can drift from dd_apply_bulk_decisions() is worse
# than none.

# rel_path is all the summary reads, so the fixture inserts rows rather than
# writing files. size/meta_count exist to give preference_rules something to
# disagree about.
folders_store <- function(rows) {
  cfg <- dd_config_defaults()
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  cfg$library_root <- cfg$work_dir
  con <- dd_db_connect(cfg); dd_db_init(con)
  for (i in seq_len(nrow(rows))) {
    DBI::dbExecute(con,
      "INSERT INTO photos(path, rel_path, size, width, height, meta_count)
       VALUES(?, ?, ?, 100, 100, ?)",
      params = list(file.path(cfg$library_root, rows$rel_path[i]),
                    rows$rel_path[i], rows$size[i], rows$meta[i]))
    pid <- DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id
    DBI::dbExecute(con, "INSERT INTO groups(group_id, photo_id, tier)
                         VALUES(?, ?, ?)",
                   params = list(rows$gid[i], pid, rows$tier[i]))
  }
  list(cfg = cfg, con = con)
}

photo_rows <- function(gid, rel_path, size = 100L, meta = 5L, tier = "exact") {
  n <- length(rel_path)
  data.frame(gid = rep_len(gid, n), rel_path = rel_path,
             size = rep_len(size, n), meta = rep_len(meta, n),
             tier = rep_len(tier, n), stringsAsFactors = FALSE)
}

no_rows <- function() photo_rows(integer(0), character(0))

# --- the pattern table ------------------------------------------------------

test_that("groups collapse to the set of directories they span", {
  s <- folders_store(rbind(
    photo_rows(1L, c("Aperture/originals/u1.jpg", "Named/2019/a.jpg")),
    photo_rows(2L, c("Aperture/originals/u2.jpg", "Named/2019/b.jpg")),
    photo_rows(3L, c("Scan/x.jpg", "Named/2020/c.jpg"), tier = "near")))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  pat <- dd_folder_patterns(s$con)
  expect_equal(nrow(pat), 2L)
  expect_equal(pat$pattern[1], "Aperture + Named")   # ordered by n_groups
  expect_equal(pat$n_groups[1], 2L)
  expect_equal(pat$n_photos[1], 4L)
  expect_equal(pat$spans[1], 2L)
  expect_equal(pat$n_exact[1], 2L)
  expect_equal(pat$n_near[1], 0L)
  expect_equal(pat$pattern[2], "Named + Scan")
  expect_equal(pat$n_near[2], 1L)
})

test_that("copies in one directory span it once, which is the undecidable case", {
  s <- folders_store(photo_rows(1L, c("Camera/a.jpg", "Camera/sub/b.jpg")))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  pat <- dd_folder_patterns(s$con)
  expect_equal(pat$pattern, "Camera")
  expect_equal(pat$spans, 1L)          # folder_priority has nothing to say
  expect_equal(pat$n_photos, 2L)
})

test_that("depth looks inside a pattern that depth 1 collapses", {
  s <- folders_store(photo_rows(1L, c("Camera/raw/a.jpg", "Camera/export/a.jpg")))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  expect_equal(dd_folder_patterns(s$con, depth = 1L)$spans, 1L)
  deep <- dd_folder_patterns(s$con, depth = 2L)
  expect_equal(deep$pattern, "Camera/export + Camera/raw")
  expect_equal(deep$spans, 2L)
})

test_that("photos at the library root share one pattern, not one each", {
  # The leaf name is dropped before truncating, so a root photo has no
  # directory left. Keeping the file name instead would give every root photo
  # a pattern of its own -- the summary would be longer than the group list.
  s <- folders_store(rbind(
    photo_rows(1L, c("loose.jpg", "Camera/a.jpg")),
    photo_rows(2L, c("other.jpg", "Camera/b.jpg"))))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  pat <- dd_folder_patterns(s$con, depth = 3L)
  expect_equal(nrow(pat), 1L)
  expect_equal(pat$pattern, "(root) + Camera")
  expect_equal(pat$n_groups, 2L)
})

test_that("depth truncates the directory, never past what a path has", {
  s <- folders_store(photo_rows(1L, c("A/b/c/deep.jpg", "A/shallow.jpg")))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  expect_equal(dd_folder_patterns(s$con, depth = 1L)$pattern, "A")
  expect_equal(dd_folder_patterns(s$con, depth = 9L)$pattern, "A + A/b/c")
})

test_that("an ungrouped store yields the empty table, not an error", {
  s <- folders_store(no_rows())
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  pat <- dd_folder_patterns(s$con)
  expect_equal(nrow(pat), 0L)
  expect_true(all(c("pattern", "spans", "n_groups") %in% names(pat)))
})

# --- folder ranking ---------------------------------------------------------

test_that("folder_priority matches whole path segments, not prefixes", {
  # G_EOS/G_EOS6D, Sugar/Sugar2, ScanGeorge/ScanGeorge2 are all real pairs in
  # a library this was built against. startsWith() alone ranks a G_EOS6D photo
  # as G_EOS.
  expect_equal(dd_folder_rank("G_EOS6D/x.jpg", "G_EOS"), 2L)   # unranked
  expect_equal(dd_folder_rank("G_EOS/x.jpg", "G_EOS"), 1L)
})

test_that("a longer folder name can be ranked below a shorter one", {
  # The old prefix match made this direction impossible: G_EOS6D matched both
  # entries and took the min(), so it tied with G_EOS and never lost to it.
  r <- dd_folder_rank(c("G_EOS/x.jpg", "G_EOS6D/y.jpg"), c("G_EOS", "G_EOS6D"))
  expect_equal(r, c(1L, 2L))
})

test_that("a folder matches itself, with or without a trailing slash", {
  expect_equal(dd_folder_rank("Camera", "Camera"), 1L)
  expect_equal(dd_folder_rank("Camera/a.jpg", "Camera/"), 1L)
})

test_that("an empty folder_priority ranks every photo equal", {
  # dd_choose_preferred() must be unchanged for every project that never sets
  # the key, which is the shipped default.
  expect_equal(dd_folder_rank(c("A/x.jpg", "B/y.jpg"), character(0)), c(1L, 1L))
})

test_that("dd_choose_preferred() honours the segment match", {
  cfg <- dd_config_defaults()
  cfg$preference_rules <- "folder_priority"
  cfg$folder_priority <- c("G_EOS", "G_EOS6D")
  g <- data.frame(photo_id = 1:2, width = 100L, height = 100L, size = 100L,
                  meta_count = 5L, capture_time = NA_character_,
                  rel_path = c("G_EOS6D/y.jpg", "G_EOS/x.jpg"),
                  stringsAsFactors = FALSE)
  expect_equal(dd_choose_preferred(g, cfg), 2L)      # the G_EOS copy
})

# --- the audit --------------------------------------------------------------

effect_cfg <- function(s, rules = "max_filesize") {
  cfg <- s$cfg
  cfg$preference_rules <- rules
  cfg
}

test_that("a ranking that separates every group decides all of them", {
  s <- folders_store(rbind(
    photo_rows(1L, c("Aperture/u1.jpg", "Named/a.jpg")),
    photo_rows(2L, c("Aperture/u2.jpg", "Named/b.jpg"))))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  eff <- dd_folder_effect(s$con, effect_cfg(s), c("Named", "Aperture"),
                          quiet = TRUE)
  expect_equal(eff$n_groups, 2L)
  expect_equal(eff$by_folder, 2L)
  expect_equal(eff$tied, 0L)
  expect_equal(eff$patterns$winner, "Named")
})

test_that("copies in one directory are tied, not decided by folder", {
  s <- folders_store(photo_rows(1L, c("Camera/a.jpg", "Camera/b.jpg"),
                                size = c(200L, 100L)))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  eff <- dd_folder_effect(s$con, effect_cfg(s), "Camera", quiet = TRUE)
  expect_equal(eff$by_folder, 0L)
  expect_equal(eff$tied, 1L)
  # The tie falls through to preference_rules, so the bigger file still wins.
  expect_equal(nrow(eff$differs), 0L)
})

test_that("folders absent from the ranking tie with each other", {
  s <- folders_store(photo_rows(1L, c("A/x.jpg", "B/y.jpg"), size = c(200L, 100L)))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  eff <- dd_folder_effect(s$con, effect_cfg(s), "Unrelated", quiet = TRUE)
  expect_equal(eff$tied, 1L)
})

test_that("the audit names every group the ranking would decide differently", {
  # The whole point: max_filesize picks the Aperture copy on encoding noise,
  # the folder rule picks the named one, and nothing else would ever say so.
  s <- folders_store(rbind(
    photo_rows(1L, c("Aperture/u1.jpg", "Named/a.jpg"), size = c(200L, 100L)),
    photo_rows(2L, c("Aperture/u2.jpg", "Named/b.jpg"), size = c(100L, 200L))))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  eff <- dd_folder_effect(s$con, effect_cfg(s), c("Named", "Aperture"),
                          quiet = TRUE)
  expect_equal(nrow(eff$differs), 1L)
  expect_equal(eff$differs$group_id, 1L)
  expect_equal(eff$differs$folder_winner, "Named/a.jpg")
  expect_equal(eff$differs$rules_winner, "Aperture/u1.jpg")
  expect_equal(eff$patterns$n_differs, 1L)
})

test_that("the audit's tie-break is the configured rules, not photo_id", {
  # Three copies, two in the winning folder: the folder rule narrows to those
  # two and preference_rules must pick between them. Ordering by photo_id
  # instead would take Named/small.jpg, which was inserted first.
  s <- folders_store(photo_rows(
    1L, c("Named/small.jpg", "Named/big.jpg", "Aperture/u.jpg"),
    size = c(100L, 300L, 200L)))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  eff <- dd_folder_effect(s$con, effect_cfg(s), c("Named", "Aperture"),
                          quiet = TRUE)
  expect_equal(eff$tied, 1L)
  expect_equal(nrow(eff$differs), 0L)   # both agree on Named/big.jpg
  expect_equal(eff$patterns$winner, "Named")
})

test_that("a pattern whose groups split gets no single winner", {
  s <- folders_store(rbind(
    photo_rows(1L, c("A/x.jpg", "B/y.jpg"), size = c(200L, 100L)),
    photo_rows(2L, c("A/p.jpg", "B/q.jpg"), size = c(100L, 200L))))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  eff <- dd_folder_effect(s$con, effect_cfg(s), character(0), quiet = TRUE)
  expect_equal(eff$patterns$winner, "(varies)")
})

test_that("the audit writes nothing", {
  # It is a preview. A caller must be able to run it before deciding whether to
  # touch the store at all.
  s <- folders_store(rbind(
    photo_rows(1L, c("Aperture/u1.jpg", "Named/a.jpg"), size = c(200L, 100L))))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  n <- function(t) DBI::dbGetQuery(s$con, paste("SELECT COUNT(*) c FROM", t))$c
  before <- c(n("decisions"), n("moves"), n("groups"), n("photos"))
  dd_folder_effect(s$con, effect_cfg(s), c("Named", "Aperture"), quiet = TRUE)
  expect_equal(c(n("decisions"), n("moves"), n("groups"), n("photos")), before)
})

test_that("the audit defaults to the config's own folder_priority", {
  s <- folders_store(photo_rows(1L, c("Aperture/u1.jpg", "Named/a.jpg"),
                                size = c(200L, 100L)))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  cfg <- effect_cfg(s)
  cfg$folder_priority <- c("Named", "Aperture")
  expect_equal(nrow(dd_folder_effect(s$con, cfg, quiet = TRUE)$differs), 1L)
})

test_that("an ungrouped store audits to zeros, not an error", {
  s <- folders_store(no_rows())
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  eff <- dd_folder_effect(s$con, effect_cfg(s), "Named", quiet = TRUE)
  expect_equal(eff$n_groups, 0L)
  expect_equal(nrow(eff$differs), 0L)
})

# --- the R entry point ------------------------------------------------------

# dd_run_folders() takes a work directory and opens its own connection, so
# these run it against the fixture's config rather than its con. Two open
# connections to one SQLite file is fine.

run_store <- function() {
  folders_store(rbind(
    photo_rows(1L, c("Aperture/u1.jpg", "Named/a.jpg"), size = c(200L, 100L)),
    photo_rows(2L, c("Camera/p.jpg", "Camera/q.jpg"), size = c(100L, 300L))))
}

test_that("the report prints by default", {
  # The counterpart the quiet tests below are measured against: without this,
  # "prints nothing" would pass on a function that never printed at all.
  s <- run_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  msgs <- capture_messages(dd_run_folders(s$cfg))
  expect_match(msgs, "Aperture + Named", all = FALSE, fixed = TRUE)
  expect_match(msgs, "span one directory", all = FALSE)
})

test_that("quiet returns the table without printing it", {
  s <- run_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  expect_silent(out <- dd_run_folders(s$cfg, quiet = TRUE))
  expect_equal(out$patterns, dd_folder_patterns(s$con))
})

test_that("quiet silences the audit and its progress bar too", {
  s <- run_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  cfg <- effect_cfg(s)
  cfg$folder_priority <- c("Named", "Aperture")

  expect_silent(out <- dd_run_folders(cfg, effect = TRUE, quiet = TRUE))
  direct <- dd_folder_effect(s$con, cfg, quiet = TRUE)
  expect_equal(out$effect$by_folder, direct$by_folder)
  expect_equal(out$effect$tied, direct$tied)
  expect_equal(out$effect$differs, direct$differs)
})

test_that("quiet does not swallow the error on an ungrouped store", {
  # Suppressing output is not suppressing failure: a caller who asked for quiet
  # still has to learn the store has nothing to summarise.
  s <- folders_store(no_rows()); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  expect_error(dd_run_folders(s$cfg, quiet = TRUE), "run analyze first")
})

test_that("depth reaches through the entry point", {
  s <- folders_store(photo_rows(1L, c("Camera/raw/a.jpg", "Camera/exp/a.jpg")))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  out <- dd_run_folders(s$cfg, depth = 2L, quiet = TRUE)
  expect_equal(out$patterns$pattern, "Camera/exp + Camera/raw")
})

test_that("an unset folder_priority is reported, not audited as zeros", {
  s <- run_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  cfg <- effect_cfg(s)
  expect_equal(cfg$folder_priority, character(0))
  msgs <- capture_messages(out <- dd_run_folders(cfg, effect = TRUE))
  expect_match(msgs, "audit needs folder_priority", all = FALSE)
  expect_null(out$effect)
})

# --- what the audit promises about dd_apply_bulk_decisions() ----------------

test_that("the preview matches what the bulk pass actually writes", {
  # If these can disagree the audit is worthless, so assert them against each
  # other rather than against a hardcoded expectation.
  s <- folders_store(rbind(
    photo_rows(1L, c("Aperture/u1.jpg", "Named/a.jpg"), size = c(200L, 100L)),
    photo_rows(2L, c("Aperture/u2.jpg", "Named/b.jpg"), size = c(100L, 200L)),
    photo_rows(3L, c("Camera/p.jpg", "Camera/q.jpg"), size = c(100L, 300L))))
  on.exit(DBI::dbDisconnect(s$con), add = TRUE)

  cfg <- effect_cfg(s)
  eff <- dd_folder_effect(s$con, cfg, c("Named", "Aperture"), quiet = TRUE)

  winners <- function(conf) {
    dd_apply_bulk_decisions(s$con, conf, overwrite = TRUE, quiet = TRUE)
    w <- DBI::dbGetQuery(s$con, "
      SELECT d.group_id, p.rel_path FROM decisions d
        JOIN photos p USING(photo_id)
       WHERE d.preferred = 1 ORDER BY d.group_id")
    stats::setNames(w$rel_path, w$group_id)
  }
  applied <- cfg
  applied$preference_rules <- c("folder_priority", cfg$preference_rules)
  applied$folder_priority <- c("Named", "Aperture")

  as_is <- winners(cfg)          # what preference_rules picks today
  with_folders <- winners(applied)

  # The audit's claim, stated as an equivalence: the bulk pass changes its mind
  # on exactly the groups differs names, and lands on exactly the copies it
  # said it would.
  changed <- names(as_is)[as_is != with_folders]
  expect_equal(as.integer(changed), eff$differs$group_id)
  expect_equal(unname(with_folders[changed]), eff$differs$folder_winner)
  expect_equal(unname(as_is[changed]), eff$differs$rules_winner)
  expect_equal(unname(with_folders[["1"]]), "Named/a.jpg")
})
