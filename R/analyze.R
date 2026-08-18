# Orchestrate exact + near clustering and persist groups to the store.

#' Build duplicate groups from the photos table and write the `groups` table.
#'
#' Exact groups (shared decoded-pixel hash) take precedence; near groups are
#' formed only among photos not already placed in an exact group.
#'
#' @param con A DBIConnection.
#' @param cfg A config list (thresholds, bands, fingerprint geometry).
#' @param quiet Logical; suppress sub-step and progress feedback.
#' @return A data.frame of the written group membership, invisibly.
#' @export
dd_analyze <- function(con, cfg, quiet = FALSE) {
  photos <- DBI::dbGetQuery(
    con, "SELECT photo_id, pixel_hash, fingerprint FROM photos"
  )
  dd_step(sprintf("loaded %d photo(s)", nrow(photos)), quiet = quiet)
  nbits <- cfg$fingerprint_grid * cfg$fingerprint_grid

  dd_step("building exact-duplicate groups", quiet = quiet)
  exact <- dd_cluster_exact(photos)
  exact_groups <- if (nrow(exact)) {
    data.frame(photo_id = exact$photo_id, tier = "exact",
               key = exact$group_key, stringsAsFactors = FALSE)
  } else {
    data.frame(photo_id = integer(0), tier = character(0),
               key = character(0))
  }

  remaining <- photos[!photos$photo_id %in% exact$photo_id, , drop = FALSE]
  dd_step(sprintf("near-duplicate clustering over %d remaining photo(s)",
                  nrow(remaining)), quiet = quiet)
  near <- dd_cluster_near(remaining, threshold = cfg$hamming_threshold,
                          bands = cfg$lsh_bands, nbits = nbits, quiet = quiet)
  near_groups <- if (nrow(near)) {
    data.frame(photo_id = near$photo_id, tier = "near",
               key = near$group_key, stringsAsFactors = FALSE)
  } else {
    data.frame(photo_id = integer(0), tier = character(0),
               key = character(0))
  }

  combined <- rbind(exact_groups, near_groups)
  if (nrow(combined) == 0L) {
    DBI::dbExecute(con, "DELETE FROM groups;")
    return(invisible(combined))
  }
  # group_id must be STABLE across analyze runs, because decisions rows carry
  # the id they were recorded under. A positional id (match() over row order)
  # silently re-points an old decision at a different group as soon as a later
  # import creates a group ahead of it, and the bulk pass then skips that group
  # as "already decided". The smallest member photo_id is unique per group (a
  # photo belongs to at most one group) and does not move as photos are added.
  key <- paste(combined$tier, combined$key)
  combined$group_id <- as.integer(tapply(combined$photo_id, key, min)[key])
  out <- data.frame(
    group_id = combined$group_id,
    photo_id = combined$photo_id,
    tier = combined$tier,
    stringsAsFactors = FALSE
  )
  DBI::dbWithTransaction(con, {
    DBI::dbExecute(con, "DELETE FROM groups;")
    DBI::dbAppendTable(con, "groups", out)
    # Re-point existing decisions at the group their photo is in now, so the
    # two tables can never disagree about which group a decision belongs to.
    DBI::dbExecute(con, "UPDATE decisions
                            SET group_id = (SELECT g.group_id FROM groups g
                                             WHERE g.photo_id = decisions.photo_id)
                          WHERE photo_id IN (SELECT photo_id FROM groups)")
  })
  invisible(out)
}
