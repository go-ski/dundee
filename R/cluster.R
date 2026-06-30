# Exact and near-duplicate clustering.
#
# Connected components are computed with a small base-R union-find so the package
# carries no graph dependency.

#' Union-find / disjoint-set over integer ids 1..n.
#'
#' @param n Number of elements.
#' @param edges A two-column matrix/data.frame of pairs to union, or NULL.
#' @return Integer vector of component labels (one per element).
#' @export
dd_union_find <- function(n, edges = NULL) {
  parent <- seq_len(n)
  find <- function(x) {
    root <- x
    while (parent[root] != root) root <- parent[root]
    while (parent[x] != root) {
      nxt <- parent[x]
      parent[x] <<- root
      x <- nxt
    }
    root
  }
  union <- function(a, b) {
    ra <- find(a); rb <- find(b)
    if (ra != rb) parent[ra] <<- rb
  }
  if (!is.null(edges) && length(edges) > 0L) {
    edges <- matrix(as.integer(as.matrix(edges)), ncol = 2L)
    for (i in seq_len(nrow(edges))) union(edges[i, 1L], edges[i, 2L])
  }
  roots <- vapply(seq_len(n), find, numeric(1))
  match(roots, unique(roots))
}

#' Exact-duplicate groups by decoded-pixel hash.
#'
#' @param photos A data.frame with `photo_id` and `pixel_hash`.
#' @return A data.frame `photo_id`, `group_key` for hashes shared by >= 2 photos.
#' @export
dd_cluster_exact <- function(photos) {
  ph <- photos[!is.na(photos$pixel_hash) & nzchar(photos$pixel_hash), ,
               drop = FALSE]
  if (nrow(ph) == 0L) {
    return(data.frame(photo_id = integer(0), group_key = character(0)))
  }
  counts <- table(ph$pixel_hash)
  dup_hashes <- names(counts)[counts >= 2L]
  keep <- ph[ph$pixel_hash %in% dup_hashes, , drop = FALSE]
  data.frame(photo_id = keep$photo_id, group_key = keep$pixel_hash,
             stringsAsFactors = FALSE)
}

# Internal: candidate pairs via LSH banding on the fingerprint bits. Two photos
# are candidates if they share any band's exact sub-bit-pattern. Returns a
# two-column matrix of row indices (into `df`).
dd_lsh_candidates <- function(df, nbits, bands) {
  band_size <- nbits %/% bands
  bitlist <- dd_fingerprint_bits(df$fingerprint, nbits = nbits)
  pairs <- list()
  for (b in seq_len(bands)) {
    idx <- ((b - 1L) * band_size + 1L):(b * band_size)
    keys <- vapply(bitlist, function(bits) {
      paste0(bits[idx], collapse = "")
    }, character(1))
    by_key <- split(seq_along(keys), keys)
    for (grp in by_key) {
      if (length(grp) >= 2L) {
        pairs[[length(pairs) + 1L]] <- t(utils::combn(grp, 2L))
      }
    }
  }
  if (length(pairs) == 0L) return(matrix(integer(0), ncol = 2L))
  unique(do.call(rbind, pairs))
}

#' Near-duplicate groups via LSH blocking + Hamming threshold.
#'
#' @param photos A data.frame with `photo_id` and `fingerprint` (hex).
#' @param threshold Inclusive Hamming distance threshold.
#' @param bands Number of LSH bands.
#' @param nbits Fingerprint length in bits.
#' @return A data.frame `photo_id`, `group_key` (component id, prefixed "near").
#' @export
dd_cluster_near <- function(photos, threshold = 5L, bands = 8L, nbits = 64L) {
  df <- photos[!is.na(photos$fingerprint) & nzchar(photos$fingerprint), ,
               drop = FALSE]
  n <- nrow(df)
  if (n < 2L) {
    return(data.frame(photo_id = integer(0), group_key = character(0)))
  }
  cand <- dd_lsh_candidates(df, nbits = nbits, bands = bands)
  if (nrow(cand) == 0L) {
    return(data.frame(photo_id = integer(0), group_key = character(0)))
  }
  dist <- vapply(seq_len(nrow(cand)), function(i) {
    dd_hamming(df$fingerprint[cand[i, 1L]], df$fingerprint[cand[i, 2L]])
  }, integer(1))
  edges <- cand[!is.na(dist) & dist <= threshold, , drop = FALSE]
  if (nrow(edges) == 0L) {
    return(data.frame(photo_id = integer(0), group_key = character(0)))
  }
  comp <- dd_union_find(n, edges)
  # Keep only components with >= 2 members.
  tab <- table(comp)
  big <- names(tab)[tab >= 2L]
  keep <- comp %in% as.integer(big)
  data.frame(
    photo_id = df$photo_id[keep],
    group_key = paste0("near:", comp[keep]),
    stringsAsFactors = FALSE
  )
}
