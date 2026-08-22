# Comparing the copies in one group, as pure functions.
#
# This lives in R/ rather than in inst/shiny/app.R on purpose: R CMD check never
# sources the app, so everything with a decision in it is here, and app.R only
# renders what these return. Anything here that app.R calls must be exported --
# runApp() sources it with only library(dundee) attached. test-app.R enforces
# both halves of that.
#
# The reviewer's problem is not reading values, it is spotting which of them
# differ. In the reference store 24 of 30 groups differ in exactly one attribute
# and agree on every other, so the useful display is the difference, not the
# values.

# What a larger/smaller value means per field:
#   high    larger is the better copy      low     smaller is
#   old     earlier timestamp wins         present having it at all wins
#   chroma  less chroma subsampling wins   ""      no defensible direction

#' The field spec the comparison helpers and the review app share.
#'
#' Exported because `inst/shiny/app.R` calls it, and `shiny::runApp()` sources
#' the app with only `library(dundee)` attached: an internal function is
#' invisible there however cleanly it resolves under `R CMD check`, whose tests
#' run inside the package namespace.
#'
#' `card = TRUE` marks the fields shown under every thumbnail whether or not the
#' copies agree: location and capture date are what decisions turn on, so they
#' are never folded away. They are excluded from the collapsed "identical" line
#' so nothing appears twice, but still show as a table row when they differ.
#'
#' @return A data.frame with one row per comparable field: `section`, `field`,
#'   `label`, `better` (the direction, or `""` where there is none) and `card`.
#' @export
dd_compare_spec <- function() {
  s <- function(section, field, label, better = "", card = FALSE) {
    data.frame(section = section, field = field, label = label,
               better = better, card = card, stringsAsFactors = FALSE)
  }
  rbind(
    s("quality", "pixels",       "pixels",             "high"),
    s("quality", "megapixels",   "megapixels",         "high"),
    s("quality", "size",         "file size",          "high"),
    s("quality", "bpp",          "bytes/pixel",        "high"),
    s("quality", "jpeg_quality", "JPEG quality",       "high"),
    s("quality", "chroma",       "chroma subsampling", "chroma"),
    s("quality", "encoding",     "encoding"),
    s("quality", "bits",         "bit depth",          "high"),
    s("quality", "icc",          "ICC profile"),

    s("capture", "capture",      "captured",           "old", card = TRUE),
    s("capture", "create_date",  "EXIF created",       "old"),
    s("capture", "modify_date",  "EXIF modified"),
    s("capture", "model",        "camera"),
    s("capture", "lens",         "lens"),
    s("capture", "software",     "software"),
    s("capture", "makernotes",   "camera maker notes", "present"),

    s("location", "coords",      "location",           "present", card = TRUE),
    s("location", "gps_alt",     "GPS altitude",       "present"),
    s("location", "city",        "city",               "present"),
    s("location", "state",       "state",              "present"),
    s("location", "country",     "country",            "present"),

    s("content", "description",  "description",        "present"),
    s("content", "caption",      "caption",            "present"),
    s("content", "keywords",     "keywords",           "present"),
    s("content", "rating",       "rating",             "high"),
    s("content", "artist",       "artist",             "present"),
    s("content", "copyright",    "copyright",          "present"),
    s("content", "title",        "title",              "present"),

    s("file", "format",          "format"),
    s("file", "folder",          "folder"),
    s("file", "mtime",           "file modified",      "old"),
    s("file", "meta_count",      "metadata tags",      "high")
  )
}

# Bytes as a human reads them. R CMD check rejects non-ASCII in R/, so no
# multiplication sign or ellipsis anywhere in this file.
dd_fmt_bytes <- function(n) {
  n <- suppressWarnings(as.numeric(n))
  if (is.na(n)) return(NA_character_)
  u <- c("B", "kB", "MB", "GB", "TB")
  i <- if (n <= 0) 1L else min(length(u), 1L + floor(log(n, 1024)))
  v <- n / 1024^(i - 1L)
  sprintf(if (i == 1L || v >= 100) "%.0f %s" else "%.1f %s", v, u[[i]])
}

# "jpegload" is the vips loader, which is what the store holds; the reviewer
# wants the format.
dd_fmt_format <- function(loader) {
  if (is.na(loader) || !nzchar(loader)) return(NA_character_)
  toupper(sub("(load|load_buffer|load_source).*$", "", loader))
}

#' Format a coordinate pair the way the review app shows it.
#'
#' Five decimals is about a metre, which is far finer than anything a
#' duplicate decision turns on and short enough to sit under a thumbnail.
#'
#' @param lat,lon Decimal degrees, as `exiftool -n` reports them.
#' @return `"36.01651, -84.26122"`, or `NA` if either is missing.
#' @export
dd_fmt_coords <- function(lat, lon) {
  la <- suppressWarnings(as.numeric(lat))
  lo <- suppressWarnings(as.numeric(lon))
  if (length(la) != 1L || length(lo) != 1L || is.na(la) || is.na(lo)) {
    return(NA_character_)
  }
  sprintf("%.5f, %.5f", la, lo)
}

#' The date a photo was taken, and which tag it came from.
#'
#' Prefers `DateTimeOriginal`, the moment the shutter fired. A quarter of the
#' reference library carries no such tag, so `CreateDate` is the fallback --
#' reported alongside the value, because a reviewer comparing two copies should
#' be able to see that they are not reading the same tag.
#'
#' @param capture `DateTimeOriginal`, or `NA`.
#' @param create_date `CreateDate`, or `NA`.
#' @return A list with `value` (or `NA`) and `source`, one of
#'   `"DateTimeOriginal"`, `"CreateDate"` or `NA`.
#' @export
dd_capture_date <- function(capture, create_date = NA_character_) {
  ok <- function(x) length(x) == 1L && !is.na(x) && nzchar(as.character(x))
  if (ok(capture)) {
    return(list(value = as.character(capture), source = "DateTimeOriginal"))
  }
  if (ok(create_date)) {
    return(list(value = as.character(create_date), source = "CreateDate"))
  }
  list(value = NA_character_, source = NA_character_)
}

dd_fmt_time <- function(x) {
  v <- suppressWarnings(as.numeric(x))
  if (is.na(v)) return(NA_character_)
  format(as.POSIXct(v, origin = "1970-01-01", tz = ""), "%Y-%m-%d %H:%M")
}

# Larger index = more chroma detail retained. 4:4:4 keeps full colour
# resolution, 4:2:0 discards three quarters of it.
dd_chroma_rank <- function(x) {
  if (is.na(x)) return(NA_real_)
  if (grepl("4:4:4", x, fixed = TRUE)) return(3)
  if (grepl("4:2:2", x, fixed = TRUE) || grepl("4:4:0", x, fixed = TRUE)) return(2)
  if (grepl("4:2:0", x, fixed = TRUE) || grepl("4:1:1", x, fixed = TRUE)) return(1)
  NA_real_
}

# Which copy is better on this field, or NA when none is defensibly better.
# Returns an index into `v`, and only when the winner is unique.
dd_best_index <- function(v, better) {
  if (!nzchar(better)) return(NA_integer_)
  score <- switch(
    better,
    high   = suppressWarnings(as.numeric(v)),
    low    = -suppressWarnings(as.numeric(v)),
    old    = -suppressWarnings(as.numeric(as.POSIXct(
               v, format = "%Y:%m:%d %H:%M:%S", tz = "UTC"))),
    # Having the field at all is the signal: one copy carrying GPS or a caption
    # the other lacks is on its own a reason to keep it.
    present = as.numeric(!is.na(v) & nzchar(v)),
    chroma  = vapply(v, dd_chroma_rank, numeric(1), USE.NAMES = FALSE),
    rep(NA_real_, length(v))
  )
  if (all(is.na(score))) return(NA_integer_)
  best <- max(score, na.rm = TRUE)
  hit <- which(!is.na(score) & score == best)
  # A tie is not a winner, and neither is "everyone has it".
  if (length(hit) != 1L) return(NA_integer_)
  if (identical(better, "present") && best == 0) return(NA_integer_)
  hit[[1]]
}

#' Compare the copies in one group field by field.
#'
#' @param members A data.frame, one row per copy, holding any of the fields in
#'   the field spec ([dd_compare_spec()]).
#' @return A data.frame with one row per present field: `section`, `field`,
#'   `label`, `differs`, `shared` (the common value when they agree), `best`
#'   (index of the better copy, or `NA`), and a `values` list column.
#' @export
dd_compare_fields <- function(members) {
  spec <- dd_compare_spec()
  spec <- spec[spec$field %in% names(members), , drop = FALSE]
  out <- vector("list", nrow(spec))
  for (i in seq_len(nrow(spec))) {
    v <- as.character(members[[spec$field[i]]])
    v[!is.na(v) & !nzchar(v)] <- NA_character_
    present <- v[!is.na(v)]
    # All-absent is not a difference worth showing; some-absent is.
    differs <- length(unique(present)) > 1L ||
      (length(present) > 0L && length(present) < length(v))
    out[[i]] <- data.frame(
      section = spec$section[i], field = spec$field[i], label = spec$label[i],
      differs = differs,
      shared = if (!differs && length(present)) present[[1]] else NA_character_,
      best = if (differs) dd_best_index(v, spec$better[i]) else NA_integer_,
      stringsAsFactors = FALSE
    )
    out[[i]]$values <- I(list(v))
  }
  if (!length(out)) {
    return(data.frame(section = character(0), field = character(0),
                      label = character(0), differs = logical(0),
                      shared = character(0), best = integer(0),
                      stringsAsFactors = FALSE))
  }
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

#' Merge a group's stored rows with its freshly read details for comparison.
#'
#' Derives the fields that are only interesting as a comparison -- pixel count,
#' bytes per pixel, the containing folder -- and lets the freshly read metadata
#' win over the two columns the store happens to duplicate.
#'
#' @param photos A data.frame of stored rows (`photo_id`, `width`, `height`,
#'   `size`, `format`, `meta_count`, `rel_path`, `mtime`).
#' @param details A data.frame from [dd_group_details()], or `NULL`.
#' @return A data.frame with one row per copy, ready for [dd_compare_fields()].
#' @export
dd_member_table <- function(photos, details = NULL) {
  w <- suppressWarnings(as.numeric(photos$width))
  h <- suppressWarnings(as.numeric(photos$height))
  px <- w * h
  out <- data.frame(
    photo_id = as.integer(photos$photo_id),
    pixels = ifelse(is.na(px), NA_character_, sprintf("%.0f", px)),
    size = photos$size,
    # Compression, expressed so two copies of the same picture are comparable:
    # the same image at half the bytes per pixel is the more compressed one.
    bpp = ifelse(is.na(px) | px == 0, NA_character_,
                 sprintf("%.3f", as.numeric(photos$size) / px)),
    format = photos$format,
    meta_count = photos$meta_count,
    folder = dirname(photos$rel_path),
    mtime = photos$mtime,
    stringsAsFactors = FALSE
  )
  if (!is.null(details) && nrow(details) == nrow(out)) {
    details <- details[match(out$photo_id, details$photo_id), , drop = FALSE]
    for (f in intersect(dd_detail_all_fields(), names(details))) {
      out[[f]] <- as.character(details[[f]])
    }
    # One string per copy, so the card and the comparison row agree.
    if (all(c("gps_lat", "gps_lon") %in% names(out))) {
      out$coords <- vapply(seq_len(nrow(out)),
                           function(i) dd_fmt_coords(out$gps_lat[i],
                                                     out$gps_lon[i]),
                           character(1))
    }
  }
  out
}

#' Render one field's value the way the review app shows it.
#'
#' @param field A field name from the internal field spec
#'   ([dd_compare_spec()]).
#' @param v The stored value.
#' @return A one-element character vector.
#' @export
dd_fmt_field <- function(field, v) {
  if (is.null(v) || is.na(v) || !nzchar(as.character(v))) {
    # meta_count is NULL only when the metadata could not be read at all, which
    # is worth saying rather than showing as a blank or a zero.
    return(if (identical(field, "meta_count")) "unreadable" else "-")
  }
  v <- as.character(v)
  switch(field,
         size       = dd_fmt_bytes(v),
         format     = dd_fmt_format(v),
         mtime      = dd_fmt_time(v),
         makernotes = "present",
         pixels     = sprintf("%.1f MP", as.numeric(v) / 1e6),
         capture    = sub(":", "-", sub(":", "-", v)),
         v)
}

# Score one preference rule, larger meaning more preferred, matching
# dd_choose_preferred()'s convention (R/decide.R).
dd_rule_score <- function(rule, g, cfg) {
  if (identical(rule, "folder_priority")) {
    # Negated: smaller priority index = better, and this function's contract is
    # larger = more preferred.
    return(-as.numeric(dd_folder_rank(g$rel_path, cfg$folder_priority)))
  }
  sc <- dd_pref_scorers[[rule]]
  if (is.null(sc)) return(NULL)
  suppressWarnings(as.numeric(sc(g)))
}

dd_rule_fmt <- function(rule, x) {
  if (is.na(x)) return("-")
  switch(rule,
         max_filesize   = dd_fmt_bytes(x),
         max_pixels     = sprintf("%.1f MP", x / 1e6),
         max_meta       = sprintf("%d tags", as.integer(x)),
         oldest_capture = format(as.POSIXct(-x, origin = "1970-01-01",
                                            tz = "UTC"), "%Y-%m-%d"),
         # Scored as the negated rank, so -1 is the most preferred folder.
         folder_priority = sprintf("priority %d", as.integer(-x)),
         format(x))
}

# "2.6 MB vs 2.6 MB" reads as a contradiction: it claims one copy won on size
# while showing the same number twice. Two files 1370 bytes apart really do
# round to the same string, so when that happens say what the gap actually was.
dd_rule_margin <- function(rule, best, runner) {
  a <- dd_rule_fmt(rule, best)
  b <- dd_rule_fmt(rule, runner)
  if (!identical(a, b)) return(sprintf("%s vs %s", a, b))
  d <- abs(best - runner)
  gap <- switch(rule,
                max_filesize   = dd_fmt_bytes(d),
                max_pixels     = sprintf("%.0f pixels", d),
                max_meta       = sprintf("%d tags", as.integer(round(d))),
                oldest_capture = sprintf("%.0f s", d),
                format(d))
  # oldest_capture scores negated time, so a bigger score means earlier.
  word <- if (identical(rule, "oldest_capture")) "earlier by" else "larger by"
  sprintf("%s vs %s, %s %s", a, b, word, gap)
}

#' Explain which preference rule actually decided a group.
#'
#' Walks `cfg$preference_rules` the way [dd_choose_preferred()] does, narrowing
#' the still-tied candidates at each step, and reports the first rule that
#' leaves exactly one. When no rule separates them the winner came from the
#' `photo_id` tie-break, which is arbitrary and worth saying out loud: in the
#' reference store that is 80% of groups.
#'
#' @param members A data.frame of one group's rows, as
#'   [dd_choose_preferred()] takes.
#' @param cfg A config list.
#' @return A list with `winner` (photo_id), `rule` (or `NA`), and `detail`, a
#'   human-readable margin such as `"2.9 MB vs 1.2 MB"`.
#' @export
dd_explain_preference <- function(members, cfg) {
  winner <- dd_choose_preferred(members, cfg)
  live <- seq_len(nrow(members))
  for (rule in cfg$preference_rules) {
    if (length(live) <= 1L) break
    score <- dd_rule_score(rule, members[live, , drop = FALSE], cfg)
    if (is.null(score) || all(is.na(score))) next
    best <- max(score, na.rm = TRUE)
    keep <- which(!is.na(score) & score == best)
    if (length(keep) == length(live)) next          # separated nobody
    if (length(keep) == 1L) {
      runner <- max(score[-keep], na.rm = TRUE)
      return(list(winner = winner, rule = rule,
                  detail = dd_rule_margin(rule, best, runner)))
    }
    live <- live[keep]
  }
  list(winner = winner, rule = NA_character_, detail = NA_character_)
}
