test_that("choose_preferred follows the rule order", {
  cfg <- dd_config_defaults()
  cfg$preference_rules <- c("max_pixels", "max_filesize")
  g <- data.frame(
    photo_id = c(10L, 11L, 12L),
    width = c(100L, 200L, 200L),
    height = c(100L, 100L, 100L),
    size = c(999L, 50L, 80L),
    meta_count = c(0L, 0L, 0L),
    capture_time = c("", "", ""),
    rel_path = c("a", "b", "c"),
    stringsAsFactors = FALSE)
  # 11 and 12 tie on pixels (20000) but 12 has larger filesize.
  expect_equal(dd_choose_preferred(g, cfg), 12L)
})

test_that("oldest_capture prefers the earliest timestamp", {
  cfg <- dd_config_defaults()
  cfg$preference_rules <- c("oldest_capture")
  g <- data.frame(
    photo_id = c(1L, 2L),
    width = c(10L, 10L), height = c(10L, 10L),
    size = c(1L, 1L), meta_count = c(0L, 0L),
    capture_time = c("2020:01:01 00:00:00", "2010:01:01 00:00:00"),
    rel_path = c("a", "b"), stringsAsFactors = FALSE)
  expect_equal(dd_choose_preferred(g, cfg), 2L)
})

test_that("ties fall back to lowest photo_id deterministically", {
  cfg <- dd_config_defaults()
  cfg$preference_rules <- character(0)
  g <- data.frame(
    photo_id = c(7L, 3L, 9L),
    width = c(1L, 1L, 1L), height = c(1L, 1L, 1L),
    size = c(1L, 1L, 1L), meta_count = c(0L, 0L, 0L),
    capture_time = c("", "", ""), rel_path = c("a", "b", "c"),
    stringsAsFactors = FALSE)
  expect_equal(dd_choose_preferred(g, cfg), 3L)
})

# --- group identity across analyze runs ------------------------------------
#
# group_id used to be positional, so a later import that created a group ahead
# of an existing one shifted every id after it. Decisions carry the id they were
# recorded under, so the bulk pass then skipped a *different* group and its
# photos never reached the move plan.

decide_store <- function() {
  cfg <- dd_config_defaults()
  cfg$work_dir <- tempfile("work-"); dir.create(cfg$work_dir)
  cfg$db_path <- file.path(cfg$work_dir, "d.sqlite")
  cfg$preference_rules <- "max_pixels"
  con <- dd_db_connect(cfg); dd_db_init(con)
  list(cfg = cfg, con = con)
}

add_photo <- function(con, path, pixel_hash, width = 10L) {
  DBI::dbExecute(con,
    "INSERT INTO photos(path, rel_path, size, width, height, meta_count,
                        pixel_hash, fingerprint)
     VALUES(?, ?, 100, ?, 10, 5, ?, '0f0f0f0f0f0f0f0f')",
    params = list(path, basename(path), width, pixel_hash))
}

test_that("a group keeps its id when an earlier photo gains a duplicate", {
  s <- decide_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_photo(s$con, "/l/lonely.jpg", "ZZZZ")     # unique for now
  add_photo(s$con, "/l/b1.jpg", "BBBB")
  add_photo(s$con, "/l/b2.jpg", "BBBB")

  g1 <- dd_analyze(s$con, s$cfg, quiet = TRUE)
  b_gid <- unique(g1$group_id[g1$photo_id %in% c(2L, 3L)])
  expect_length(b_gid, 1L)

  # A later import turns the previously-unique photo into a duplicate. Its
  # group sorts ahead of the b1/b2 group, which used to renumber the latter.
  add_photo(s$con, "/l/lonely_copy.jpg", "ZZZZ")
  g2 <- dd_analyze(s$con, s$cfg, quiet = TRUE)

  expect_equal(unique(g2$group_id[g2$photo_id %in% c(2L, 3L)]), b_gid)
  expect_length(unique(g2$group_id), 2L)
})

test_that("a re-analyze re-points existing decisions at their photo's group", {
  s <- decide_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_photo(s$con, "/l/lonely.jpg", "ZZZZ")
  add_photo(s$con, "/l/b1.jpg", "BBBB")
  add_photo(s$con, "/l/b2.jpg", "BBBB")
  g1 <- dd_analyze(s$con, s$cfg, quiet = TRUE)

  b_gid <- unique(g1$group_id[g1$photo_id %in% c(2L, 3L)])
  dd_record_decision(s$con, data.frame(
    photo_id = c(2L, 3L), group_id = b_gid, preferred = c(1L, 0L),
    decided_by = "manual"))

  add_photo(s$con, "/l/lonely_copy.jpg", "ZZZZ")
  g2 <- dd_analyze(s$con, s$cfg, quiet = TRUE)

  dec <- DBI::dbGetQuery(s$con, "SELECT photo_id, group_id FROM decisions")
  now <- g2$group_id[match(dec$photo_id, g2$photo_id)]
  expect_equal(dec$group_id, now)
})

test_that("bulk decisions leave no grouped photo undecided after a re-analyze", {
  s <- decide_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_photo(s$con, "/l/lonely.jpg", "ZZZZ")
  add_photo(s$con, "/l/b1.jpg", "BBBB")
  add_photo(s$con, "/l/b2.jpg", "BBBB")
  g1 <- dd_analyze(s$con, s$cfg, quiet = TRUE)

  b_gid <- unique(g1$group_id[g1$photo_id %in% c(2L, 3L)])
  dd_record_decision(s$con, data.frame(
    photo_id = c(2L, 3L), group_id = b_gid, preferred = c(1L, 0L),
    decided_by = "manual"))

  add_photo(s$con, "/l/lonely_copy.jpg", "ZZZZ")
  dd_analyze(s$con, s$cfg, quiet = TRUE)
  dd_apply_bulk_decisions(s$con, s$cfg, quiet = TRUE)

  undecided <- DBI::dbGetQuery(s$con, "
    SELECT p.path FROM groups g JOIN photos p USING (photo_id)
      LEFT JOIN decisions d USING (photo_id)
     WHERE d.photo_id IS NULL")
  expect_equal(nrow(undecided), 0L)

  # and the manual choice survived the bulk pass
  pref <- DBI::dbGetQuery(s$con,
    "SELECT preferred, decided_by FROM decisions WHERE photo_id = 2")
  expect_equal(pref$preferred, 1L)
  expect_equal(pref$decided_by, "manual")
})

test_that("a group that gained a member keeps its reviewed preferred copy", {
  s <- decide_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_photo(s$con, "/l/a1.jpg", "AAAA", width = 10L)
  add_photo(s$con, "/l/a2.jpg", "AAAA", width = 10L)
  g1 <- dd_analyze(s$con, s$cfg, quiet = TRUE)
  gid <- unique(g1$group_id)

  # The reviewer picks the *smaller* copy, which max_pixels would not have.
  dd_record_decision(s$con, data.frame(
    photo_id = c(1L, 2L), group_id = gid, preferred = c(0L, 1L),
    decided_by = "manual"))

  add_photo(s$con, "/l/a3.jpg", "AAAA", width = 9999L)   # a huge newcomer
  dd_analyze(s$con, s$cfg, quiet = TRUE)
  dd_apply_bulk_decisions(s$con, s$cfg, quiet = TRUE)

  dec <- DBI::dbGetQuery(s$con,
    "SELECT photo_id, preferred FROM decisions ORDER BY photo_id")
  expect_equal(dec$preferred, c(0L, 1L, 0L))   # newcomer is non-preferred
})

# --- photos that stop being duplicates --------------------------------------
#
# dd_plan_moves() reads `decisions`, never `groups`. So a group dissolved by a
# tightened hamming_threshold used to leave its decisions behind, and dundee
# went on relocating photos it no longer considered duplicates.

near_store <- function(threshold = 5L) {
  s <- decide_store()
  s$cfg$hamming_threshold <- threshold
  s                                   # default 8 bands over 64 bits
}

# Two fingerprints 4 bits apart: grouped at threshold 5, separate at 3.
add_near_pair <- function(con) {
  DBI::dbExecute(con,
    "INSERT INTO photos(path, rel_path, size, width, height, meta_count,
                        pixel_hash, fingerprint)
     VALUES('/l/n1.jpg', 'n1.jpg', 100, 10, 10, 5, 'AAAA',
            '0000000000000000')")
  DBI::dbExecute(con,
    "INSERT INTO photos(path, rel_path, size, width, height, meta_count,
                        pixel_hash, fingerprint)
     VALUES('/l/n2.jpg', 'n2.jpg', 100, 20, 10, 5, 'BBBB',
            '000000000000000f')")
}

test_that("tightening the threshold drops the decisions it invalidates", {
  s <- near_store(5L); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_near_pair(s$con)
  g <- dd_analyze(s$con, s$cfg, quiet = TRUE)
  expect_equal(nrow(g), 2L)                       # grouped at 5
  dd_apply_bulk_decisions(s$con, s$cfg, quiet = TRUE)
  expect_equal(DBI::dbGetQuery(s$con, "SELECT COUNT(*) n FROM decisions")$n, 2L)

  s$cfg$hamming_threshold <- 3L
  g2 <- dd_analyze(s$con, s$cfg, quiet = TRUE)
  expect_equal(nrow(g2), 0L)                      # no longer duplicates
  expect_equal(DBI::dbGetQuery(s$con, "SELECT COUNT(*) n FROM decisions")$n, 0L)

  # and so nothing reaches the move plan
  s$cfg$library_root <- "/l"; s$cfg$nas_root <- "/v"
  s$cfg$preferred_root <- "/v/p"; s$cfg$nonpreferred_root <- "/v/n"
  plan <- suppressMessages(
    dd_plan_moves(s$con, s$cfg,
                  manifest_path = file.path(s$cfg$work_dir, "m.tsv"),
                  script_path = file.path(s$cfg$work_dir, "m.sh"),
                  quiet = TRUE))
  expect_equal(nrow(plan), 0L)
})

test_that("a still-planned move for an un-grouped photo goes too", {
  s <- near_store(5L); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_near_pair(s$con)
  dd_analyze(s$con, s$cfg, quiet = TRUE)
  dd_apply_bulk_decisions(s$con, s$cfg, quiet = TRUE)
  dd_upsert(s$con, "moves",
            data.frame(photo_id = 1L, src = "/l/n1.jpg", dest = "/v/n1.jpg",
                       state = "planned", moved_at = NA_character_,
                       stringsAsFactors = FALSE),
            key_cols = "photo_id")

  s$cfg$hamming_threshold <- 3L
  dd_analyze(s$con, s$cfg, quiet = TRUE)
  expect_equal(DBI::dbGetQuery(s$con, "SELECT COUNT(*) n FROM moves")$n, 0L)
})

test_that("a move already done survives the prune", {
  # Done rows are history, not intent -- the same rule dd_plan_moves() applies.
  s <- near_store(5L); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_near_pair(s$con)
  dd_analyze(s$con, s$cfg, quiet = TRUE)
  dd_upsert(s$con, "moves",
            data.frame(photo_id = 1L, src = "/l/n1.jpg", dest = "/v/n1.jpg",
                       state = "done", moved_at = "2026-01-01T00:00:00",
                       stringsAsFactors = FALSE),
            key_cols = "photo_id")

  s$cfg$hamming_threshold <- 3L
  dd_analyze(s$con, s$cfg, quiet = TRUE)
  kept <- DBI::dbGetQuery(s$con, "SELECT state FROM moves")
  expect_equal(kept$state, "done")
})

test_that("a photo still in a group keeps its reviewed decision", {
  # The prune must key on "in no group at all", never on group membership
  # changing -- otherwise re-analyze would discard every manual choice.
  s <- decide_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_photo(s$con, "/l/a1.jpg", "AAAA")
  add_photo(s$con, "/l/a2.jpg", "AAAA")
  g <- dd_analyze(s$con, s$cfg, quiet = TRUE)
  dd_record_decision(s$con, data.frame(
    photo_id = c(1L, 2L), group_id = unique(g$group_id),
    preferred = c(0L, 1L), decided_by = "manual"))

  add_photo(s$con, "/l/a3.jpg", "AAAA")           # group grows
  dd_analyze(s$con, s$cfg, quiet = TRUE)

  dec <- DBI::dbGetQuery(s$con,
    "SELECT photo_id, preferred, decided_by FROM decisions ORDER BY photo_id")
  expect_equal(dec$photo_id, c(1L, 2L))
  expect_equal(dec$preferred, c(0L, 1L))
  expect_equal(dec$decided_by, c("manual", "manual"))
})

test_that("analyze with nothing grouped at all clears every decision", {
  s <- decide_store(); on.exit(DBI::dbDisconnect(s$con), add = TRUE)
  add_photo(s$con, "/l/a1.jpg", "AAAA")
  add_photo(s$con, "/l/a2.jpg", "AAAA")
  dd_analyze(s$con, s$cfg, quiet = TRUE)
  dd_apply_bulk_decisions(s$con, s$cfg, quiet = TRUE)

  # Make them distinct: the early-return branch of dd_analyze() must prune too.
  DBI::dbExecute(s$con, "UPDATE photos SET pixel_hash = 'ZZZZ',
                          fingerprint = 'ffffffffffffffff' WHERE photo_id = 2")
  g <- dd_analyze(s$con, s$cfg, quiet = TRUE)
  expect_equal(nrow(g), 0L)
  expect_equal(DBI::dbGetQuery(s$con, "SELECT COUNT(*) n FROM decisions")$n, 0L)
})
