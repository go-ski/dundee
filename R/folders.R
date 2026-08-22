# Summarise duplicate groups by the directories their members occupy, and
# audit a candidate folder_priority before it is applied.
#
# A library accumulates duplicates by being copied wholesale -- an old app's
# managed library, a scanner's output, a backup folder -- so which copy to keep
# is usually a property of the tree, not of the file. Two dozen directories
# describe tens of thousands of groups, and that ratio is the whole point:
# reviewing patterns is tractable where reviewing groups is not.

# The directory a photo sits in, truncated to `depth` segments. The leaf name
# is dropped first and always: it is what makes every group look unique, so
# keeping it would give each photo at the library root a pattern of its own and
# defeat the whole summary.
dd_path_prefix <- function(rel_path, depth = 1L) {
  depth <- max(1L, as.integer(depth))
  vapply(strsplit(rel_path, "/", fixed = TRUE), function(parts) {
    dir <- parts[seq_len(length(parts) - 1L)]      # drop the file name
    if (!length(dir)) return("(root)")
    paste(dir[seq_len(min(depth, length(dir)))], collapse = "/")
  }, character(1), USE.NAMES = FALSE)
}

# Rank each path against `priority`, 1 being most preferred and
# length(priority) + 1 meaning "named no listed folder". Shared by
# dd_choose_preferred() (R/decide.R) and dd_rule_score() (R/compare.R) so the
# ranking the audit previews is the ranking the bulk pass applies.
#
# Matching is by whole path segment, not by prefix: startsWith() alone lets
# "G_EOS" match "G_EOS6D/x.jpg", and the failure is directional and silent --
# the longer name matches both entries and takes the min(), so it can be ranked
# above the shorter one but never below it.
dd_folder_rank <- function(rel_path, priority) {
  n <- length(priority)
  if (!n) return(rep(1L, length(rel_path)))
  folders <- sub("/+$", "", as.character(priority))
  rank <- rep(n + 1L, length(rel_path))
  # Reverse order so an earlier (better) entry overwrites a later one, which
  # keeps the min() semantics without a per-path loop.
  for (i in rev(seq_len(n))) {
    f <- folders[[i]]
    hit <- rel_path == f | startsWith(rel_path, paste0(f, "/"))
    rank[hit] <- i
  }
  rank
}

# group_id, photo_id, rel_path, tier for every grouped photo.
dd_group_paths <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT g.group_id, g.photo_id, g.tier, p.rel_path
      FROM groups g JOIN photos p USING (photo_id)
     ORDER BY g.group_id, p.rel_path")
}

#' Summarise duplicate groups by the directories they span.
#'
#' Collapses every group to the sorted set of distinct directories its members
#' occupy, then counts groups per distinct set. A library with a few dozen
#' top-level directories yields a few dozen rows however many groups it has.
#'
#' `spans == 1` marks a pattern whose copies all live in one directory, where
#' `folder_priority` has nothing to say and the quality rules or the review app
#' must decide. Raise `depth` to look inside those.
#'
#' @param con A DBIConnection.
#' @param depth Path segments to keep from each `rel_path`; 1 is the top-level
#'   directory.
#' @return A data.frame with `pattern`, `spans`, `n_groups`, `n_photos`,
#'   `n_exact` and `n_near`, ordered by `n_groups` descending. Zero rows when
#'   nothing is grouped.
#' @examples
#' \dontrun{
#' cfg <- dd_config("~/dundee/family-photos")
#' con <- dd_db_connect(cfg)
#' on.exit(DBI::dbDisconnect(con))
#'
#' dd_folder_patterns(con)              # top-level directories
#' dd_folder_patterns(con, depth = 2)   # inside the single-directory patterns
#' }
#' @seealso [dd_run_folders()], which does this from a work directory and prints
#'   the table.
#' @export
dd_folder_patterns <- function(con, depth = 1L) {
  gp <- dd_group_paths(con)
  empty <- data.frame(pattern = character(0), spans = integer(0),
                      n_groups = integer(0), n_photos = integer(0),
                      n_exact = integer(0), n_near = integer(0),
                      stringsAsFactors = FALSE)
  if (nrow(gp) == 0L) return(empty)

  gp$dir <- dd_path_prefix(gp$rel_path, depth)
  by_group <- split(gp$dir, gp$group_id)
  pattern <- vapply(by_group, function(d) paste(sort(unique(d)), collapse = " + "),
                    character(1))
  spans <- vapply(by_group, function(d) length(unique(d)), integer(1))
  size <- lengths(by_group)
  # A group carries one tier throughout (dd_analyze() builds exact and near
  # separately), so the first member's tier describes the group.
  tier <- vapply(split(gp$tier, gp$group_id), function(t) t[[1L]], character(1))

  agg <- data.frame(pattern = unname(pattern), spans = unname(spans),
                    size = unname(size), tier = unname(tier),
                    stringsAsFactors = FALSE)
  out <- do.call(rbind, lapply(split(agg, agg$pattern), function(s) {
    data.frame(pattern = s$pattern[[1L]], spans = s$spans[[1L]],
               n_groups = nrow(s), n_photos = sum(s$size),
               n_exact = sum(s$tier == "exact"), n_near = sum(s$tier == "near"),
               stringsAsFactors = FALSE)
  }))
  out <- out[order(-out$n_groups, out$pattern), , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' Preview what a folder ranking would decide, and where it would disagree.
#'
#' Reports how much of the library `priority` settles on its own, how much it
#' leaves to the quality rules, and -- the point of the function -- every group
#' where it would pick a different copy than `cfg$preference_rules` picks today.
#' A folder ranking is usually right where the quality rules are merely
#' arbitrary, so the disagreements are what deserve a look before
#' [dd_apply_bulk_decisions()] writes them.
#'
#' Nothing is written. To act on the result, put `folder_priority` first in
#' `preference_rules`, set `folder_priority` to `priority`, and re-run
#' `dd_apply_bulk_decisions(con, cfg, overwrite = TRUE)`.
#'
#' @param con A DBIConnection.
#' @param cfg A config list; `preference_rules` supplies the comparison and the
#'   tie-break.
#' @param priority Character vector of folders relative to `library_root`,
#'   most-preferred first. Defaults to `cfg$folder_priority`.
#' @param depth Path segments to keep when building the pattern table.
#' @param quiet Logical; suppress the per-group progress bar.
#' @return Invisibly, a list with `by_folder`, `tied`, `n_groups`, a `differs`
#'   data.frame (`group_id`, `folder_winner`, `rules_winner`) and `patterns`,
#'   the [dd_folder_patterns()] table plus `winner` and `n_differs`.
#' @examples
#' \dontrun{
#' cfg <- dd_config("~/dundee/family-photos")
#' con <- dd_db_connect(cfg)
#' on.exit(DBI::dbDisconnect(con))
#'
#' # Try a ranking without committing it to config.yml.
#' eff <- dd_folder_effect(con, cfg, c("Named", "OldAppLibrary"))
#' eff$by_folder                        # groups the tree settles on its own
#' eff$differs                          # every group this would change
#'
#' # Happy with it? Put folder_priority first in preference_rules, set
#' # folder_priority to the same ranking, then:
#' dd_apply_bulk_decisions(con, cfg, overwrite = TRUE)
#' }
#' @seealso [dd_run_folders()], which does this from a work directory and prints
#'   the summary.
#' @export
dd_folder_effect <- function(con, cfg, priority = cfg$folder_priority,
                             depth = 1L, quiet = FALSE) {
  gp <- dd_group_paths(con)
  patterns <- dd_folder_patterns(con, depth)
  out <- list(by_folder = 0L, tied = 0L, n_groups = 0L,
              differs = data.frame(group_id = integer(0),
                                   folder_winner = character(0),
                                   rules_winner = character(0),
                                   stringsAsFactors = FALSE),
              patterns = patterns)
  if (nrow(gp) == 0L) return(invisible(out))

  # Everything dd_choose_preferred() needs, fetched once rather than per group.
  meta <- DBI::dbGetQuery(con, "
    SELECT photo_id, width, height, size, meta_count, capture_time, rel_path
      FROM photos")
  gp <- merge(gp[, c("group_id", "photo_id", "rel_path")],
              meta[, setdiff(names(meta), "rel_path")], by = "photo_id")

  # Vectorised once over every grouped photo: 25 folders is 25 comparisons,
  # not 25 per group.
  gp$rank <- dd_folder_rank(gp$rel_path, priority)
  gp$dir <- dd_path_prefix(gp$rel_path, depth)

  fold_cfg <- cfg
  fold_cfg$folder_priority <- priority
  by_group <- split(gp, gp$group_id)
  gids <- names(by_group)

  folder_win <- character(length(gids))
  rules_win <- character(length(gids))
  decided <- logical(length(gids))

  pb <- dd_progress(length(gids), "folders", quiet = quiet)
  for (i in seq_along(gids)) {
    pb$tick()
    sub <- by_group[[i]]
    top <- which(sub$rank == min(sub$rank))
    decided[i] <- length(top) == 1L
    # One survivor wins outright; several means the folder rule ties and the
    # configured rules break it -- exactly what listing folder_priority first
    # in preference_rules does, computed without re-ranking every path.
    fw <- if (decided[i]) sub$photo_id[top] else
      dd_choose_preferred(sub[top, , drop = FALSE], fold_cfg)
    rw <- dd_choose_preferred(sub, cfg)
    folder_win[i] <- sub$rel_path[match(fw, sub$photo_id)]
    rules_win[i] <- sub$rel_path[match(rw, sub$photo_id)]
  }
  pb$done()

  diff_at <- which(folder_win != rules_win)
  out$n_groups <- length(gids)
  out$by_folder <- sum(decided)
  out$tied <- sum(!decided)
  out$differs <- data.frame(group_id = as.integer(gids[diff_at]),
                            folder_winner = folder_win[diff_at],
                            rules_winner = rules_win[diff_at],
                            stringsAsFactors = FALSE)

  # Per-pattern winner and disagreement count, so the table says which side of
  # each pattern the ranking lands on without reading individual groups.
  pat <- vapply(by_group, function(s) paste(sort(unique(dd_path_prefix(
    s$rel_path, depth))), collapse = " + "), character(1))
  win_dir <- dd_path_prefix(folder_win, depth)
  out$patterns$winner <- vapply(out$patterns$pattern, function(p) {
    w <- unique(win_dir[pat == p])
    if (length(w) == 1L) w else "(varies)"
  }, character(1), USE.NAMES = FALSE)
  out$patterns$n_differs <- vapply(out$patterns$pattern, function(p) {
    sum(pat[diff_at] == p)
  }, integer(1), USE.NAMES = FALSE)
  invisible(out)
}
