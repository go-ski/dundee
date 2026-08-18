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

#' The built-in configuration defaults.
#'
#' A plain list of every user-settable field and its default, with no file
#' read, no validation, and no derived paths. Useful for inspecting what is
#' configurable, and for unit tests of functions that take a config.
#'
#' @return A named list.
#' @export
dd_config_defaults <- function() {
  list(
    # Read-only root of the photo library. The ONLY directory a user sets:
    # the work directory is wherever config.yml lives (see R/project.R).
    library_root = NULL,
    # SQLite store filename, always resolved under the work directory.
    db_path = "dundee.sqlite",
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
    # Ordered list of bulk preference rules. All of them are applied, in
    # sequence, as lexicographic tie-breakers; photo_id breaks any tie left
    # over. Supported: max_pixels, max_filesize, max_meta, oldest_capture,
    # folder_priority.
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
