# Orchestrate exact + near clustering and persist groups to the store.

#' Build duplicate groups from the photos table and write the `groups` table.
#'
#' Exact groups (shared decoded-pixel hash) take precedence; near groups are
#' formed only among photos not already placed in an exact group.
#'
#' @param con A DBIConnection.
#' @param cfg A config list (thresholds, bands, fingerprint geometry).
#' @return A data.frame of the written group membership, invisibly.
#' @export
dd_analyze <- function(con, cfg) {
  photos <- DBI::dbGetQuery(
    con, "SELECT photo_id, pixel_hash, fingerprint FROM photos"
  )
  nbits <- cfg$fingerprint_grid * cfg$fingerprint_grid

  exact <- dd_cluster_exact(photos)
  exact_groups <- if (nrow(exact)) {
    data.frame(photo_id = exact$photo_id, tier = "exact",
               key = exact$group_key, stringsAsFactors = FALSE)
  } else {
    data.frame(photo_id = integer(0), tier = character(0),
               key = character(0))
  }

  remaining <- photos[!photos$photo_id %in% exact$photo_id, , drop = FALSE]
  near <- dd_cluster_near(remaining, threshold = cfg$hamming_threshold,
                          bands = cfg$lsh_bands, nbits = nbits)
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
  # Assign stable integer group ids from the (tier, key) pairs.
  combined$group_id <- match(
    paste(combined$tier, combined$key),
    unique(paste(combined$tier, combined$key))
  )
  out <- data.frame(
    group_id = combined$group_id,
    photo_id = combined$photo_id,
    tier = combined$tier,
    stringsAsFactors = FALSE
  )
  DBI::dbWithTransaction(con, {
    DBI::dbExecute(con, "DELETE FROM groups;")
    DBI::dbAppendTable(con, "groups", out)
  })
  invisible(out)
}
