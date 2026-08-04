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
    # Read-only SMB mount root of the photo library on the Mac. This and
    # work_dir are the only two directories dundee expects a user to set.
    library_root = NULL,
    # Local working area: store, staging, temp scratch, caches, manifests.
    # Everything dundee writes locally lives under here.
    work_dir = "work",
    # SQLite store filename (always resolved under work_dir; see dd_config()).
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
