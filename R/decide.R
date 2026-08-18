# Preferred-copy heuristics and decision persistence.

# Internal: score helpers return a value where LARGER means MORE preferred.
dd_pref_scorers <- list(
  max_pixels   = function(g) as.numeric(g$width) * as.numeric(g$height),
  max_filesize = function(g) as.numeric(g$size),
  max_meta     = function(g) as.numeric(g$meta_count),
  oldest_capture = function(g) {
    # Older capture preferred -> negate the numeric timestamp.
    t <- suppressWarnings(as.numeric(as.POSIXct(
      g$capture_time, format = "%Y:%m:%d %H:%M:%S", tz = "UTC")))
    -t
  }
)

#' Choose the preferred photo within a single group.
#'
#' Applies `cfg$preference_rules` in order as lexicographic tie-breakers; ties
#' remaining after all rules are broken by lowest `photo_id` (stable).
#'
#' @param group_df Rows of one group (columns: photo_id, width, height, size,
#'   meta_count, capture_time, rel_path).
#' @param cfg A config list (uses `preference_rules`, `folder_priority`).
#' @return The `photo_id` of the preferred copy.
#' @export
dd_choose_preferred <- function(group_df, cfg) {
  g <- group_df
  ord_keys <- list()
  for (rule in cfg$preference_rules) {
    if (rule == "folder_priority") {
      pri <- vapply(g$rel_path, function(p) {
        hit <- which(vapply(cfg$folder_priority,
                            function(f) startsWith(p, f), logical(1)))
        if (length(hit)) min(hit) else length(cfg$folder_priority) + 1L
      }, numeric(1))
      ord_keys[[length(ord_keys) + 1L]] <- pri        # smaller = better
    } else if (!is.null(dd_pref_scorers[[rule]])) {
      ord_keys[[length(ord_keys) + 1L]] <- -dd_pref_scorers[[rule]](g)
    }
  }
  ord_keys[[length(ord_keys) + 1L]] <- g$photo_id     # final tie-break
  ord <- do.call(order, ord_keys)
  g$photo_id[ord[1L]]
}

#' Apply the bulk preference heuristic to every group lacking a decision.
#'
#' Existing decisions (e.g. manual overrides from the Shiny app) are preserved
#' unless `overwrite = TRUE`. A group whose members are all undecided gets the
#' full heuristic; one that gained members after it was reviewed has only the
#' newcomers marked non-preferred, leaving the reviewer's choice intact.
#'
#' @param con A DBIConnection.
#' @param cfg A config list.
#' @param overwrite Logical; re-decide groups that already have decisions.
#' @param quiet Logical; suppress the per-group progress bar.
#' @return Number of decision rows written, invisibly.
#' @export
dd_apply_bulk_decisions <- function(con, cfg, overwrite = FALSE, quiet = FALSE) {
  gp <- DBI::dbGetQuery(con, "
    SELECT g.group_id, g.photo_id, p.width, p.height, p.size, p.meta_count,
           p.capture_time, p.rel_path
      FROM groups g JOIN photos p USING (photo_id)")
  if (nrow(gp) == 0L) return(invisible(0L))

  # "Already decided" is a property of the photos, not of a group_id: ids are
  # recomputed by every analyze run, so an id carried on an old decision row is
  # not a safe key. Asking per photo also lets a group that gained members after
  # it was reviewed be topped up without discarding the reviewer's choice.
  decided <- DBI::dbGetQuery(con, "SELECT photo_id FROM decisions")$photo_id
  gids <- unique(gp$group_id)
  written <- 0L
  pb <- dd_progress(length(gids), "decide", quiet = quiet)
  for (gid in gids) {
    pb$tick()
    sub <- gp[gp$group_id == gid, , drop = FALSE]
    todo <- if (isTRUE(overwrite)) sub else
      sub[!sub$photo_id %in% decided, , drop = FALSE]
    if (nrow(todo) == 0L) next

    if (nrow(todo) == nrow(sub)) {
      # Nobody here has been reviewed: apply the full heuristic.
      pref <- dd_choose_preferred(sub, cfg)
      dd_record_decision(con, data.frame(
        photo_id = sub$photo_id, group_id = gid,
        preferred = as.integer(sub$photo_id == pref), decided_by = "bulk"))
    } else {
      # The group grew after review. A preferred copy has already been chosen,
      # so the newcomers are non-preferred; the existing rows are left alone.
      dd_record_decision(con, data.frame(
        photo_id = todo$photo_id, group_id = gid,
        preferred = 0L, decided_by = "bulk"))
    }
    written <- written + nrow(todo)
  }
  pb$done()
  invisible(written)
}

#' Record preferred/non-preferred decisions for one or more groups.
#'
#' @param con A DBIConnection.
#' @param decisions A data.frame with `photo_id`, `group_id`, `preferred`
#'   (logical or 0/1), and optional `decided_by`.
#' @return Number of rows upserted, invisibly.
#' @export
dd_record_decision <- function(con, decisions) {
  df <- data.frame(
    photo_id = as.integer(decisions$photo_id),
    group_id = as.integer(decisions$group_id),
    preferred = as.integer(decisions$preferred),
    decided_by = if (!is.null(decisions$decided_by)) decisions$decided_by
                 else "bulk",
    decided_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    stringsAsFactors = FALSE
  )
  dd_upsert(con, "decisions", df, key_cols = "photo_id")
}
