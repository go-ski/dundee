# Configuration loading and validation.

# Default cruft directory/file names to prune during enumeration. These are
# Synology and macOS artifacts that must never be inventoried.
dd_default_cruft <- c(
  "@eaDir", "#recycle", "#snapshot", "@tmp", ".@__thumb", "@sharebin",
  ".DS_Store", "Thumbs.db", ".Spotlight-V100", ".TemporaryItems",
  ".Trashes", ".fseventsd"
)

# Image extensions to inventory (lowercased, no dot). All still images,
# including HEIC/HEIF and common camera RAW formats.
dd_default_extensions <- c(
  "jpg", "jpeg", "jpe", "png", "gif", "bmp", "tif", "tiff", "webp",
  "heic", "heif", "avif",
  "cr2", "cr3", "nef", "nrw", "arw", "sr2", "srf", "raf", "rw2", "orf",
  "dng", "pef", "raw", "x3f", "3fr", "erf", "kdc", "mef", "mos", "iiq"
)

dd_config_defaults <- function() {
  list(
    # Read-only SMB mount root of the photo library on the Mac.
    library_root = NULL,
    # Local working area (store, staging, caches, manifests).
    work_dir = "work",
    # SQLite store path (relative to work_dir unless absolute).
    db_path = "dundee.sqlite",
    # Local temp directory for the single-read copy in the worker.
    temp_dir = NULL,
    # Number of parallel fingerprint workers.
    parallel = 4L,
    # File extensions to include.
    extensions = dd_default_extensions,
    # Names to prune during enumeration.
    cruft = dd_default_cruft,
    # Perceptual fingerprint geometry. dHash on a (grid x grid) grayscale image
    # yields grid*grid bits.
    fingerprint_grid = 8L,
    # Default near-duplicate Hamming distance threshold (inclusive).
    hamming_threshold = 5L,
    # Number of LSH bands used to block near-duplicate candidates.
    lsh_bands = 8L,
    # Ordered list of bulk preference rules (first match wins as tie-breakers
    # are applied in order). Supported: max_pixels, max_filesize, max_meta,
    # oldest_capture, folder_priority.
    preference_rules = c("max_pixels", "max_filesize", "max_meta",
                         "oldest_capture"),
    # Folders (relative to library_root) that win when folder_priority is used,
    # most-preferred first.
    folder_priority = character(0),
    # Phase 3: SSH target and path translation.
    ssh_host = NULL,
    ssh_user = NULL,
    # Map the Mac SMB mount root to the Synology server-side absolute path.
    # e.g. smb_root "/Volumes/photo" -> nas_root "/volume1/photo".
    nas_root = NULL,
    # Destination roots (server-side, absolute) for the two output trees.
    preferred_root = NULL,
    nonpreferred_root = NULL
  )
}

#' Load and validate a dundee configuration.
#'
#' @param path Path to a YAML config file. If NULL, only defaults are used.
#' @param require_library Logical; require `library_root` to be set and exist.
#' @return A validated config list with absolute, resolved paths.
#' @export
dd_config <- function(path = "config.yml", require_library = FALSE) {
  cfg <- dd_config_defaults()
  if (!is.null(path) && file.exists(path)) {
    user <- yaml::read_yaml(path)
    for (nm in names(user)) cfg[[nm]] <- user[[nm]]
  }

  cfg$parallel <- as.integer(cfg$parallel)
  cfg$fingerprint_grid <- as.integer(cfg$fingerprint_grid)
  cfg$hamming_threshold <- as.integer(cfg$hamming_threshold)
  cfg$lsh_bands <- as.integer(cfg$lsh_bands)
  cfg$extensions <- tolower(cfg$extensions)

  if ((cfg$fingerprint_grid * cfg$fingerprint_grid) %% cfg$lsh_bands != 0L) {
    stop("lsh_bands must divide fingerprint_grid^2 (the bit length).")
  }

  if (require_library) {
    if (is.null(cfg$library_root) || !nzchar(cfg$library_root)) {
      stop("config: library_root must be set.")
    }
    if (!dir.exists(cfg$library_root)) {
      stop("config: library_root does not exist: ", cfg$library_root)
    }
    cfg$library_root <- normalizePath(cfg$library_root, mustWork = TRUE)
  }

  # Resolve work_dir and the paths nested under it.
  cfg$work_dir <- normalizePath(cfg$work_dir, mustWork = FALSE)
  if (!dir.exists(cfg$work_dir)) {
    dir.create(cfg$work_dir, recursive = TRUE, showWarnings = FALSE)
  }
  if (!startsWith(cfg$db_path, "/")) {
    cfg$db_path <- file.path(cfg$work_dir, cfg$db_path)
  }
  if (is.null(cfg$temp_dir)) {
    cfg$temp_dir <- file.path(cfg$work_dir, "tmp")
  }
  cfg$staging_dir <- file.path(cfg$work_dir, "staging")
  cfg$thumb_dir <- file.path(cfg$work_dir, "thumbs")

  cfg
}

#' Write an example configuration file.
#'
#' @param path Destination path for the example YAML.
#' @return `path`, invisibly.
#' @export
dd_config_example <- function(path = "config.example.yml") {
  cfg <- dd_config_defaults()
  cfg$library_root <- "/Volumes/photo"
  cfg$temp_dir <- "/tmp/dundee"
  cfg$ssh_host <- "synology.local"
  cfg$ssh_user <- "admin"
  cfg$nas_root <- "/volume1/photo"
  cfg$preferred_root <- "/volume1/photo/_dedup/preferred"
  cfg$nonpreferred_root <- "/volume1/photo/_dedup/non-preferred"
  writeLines(yaml::as.yaml(cfg), path)
  invisible(path)
}
