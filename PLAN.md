# dundee — photo deduplication build plan

A three-phase pipeline to deduplicate ~1M photos in a Synology Photos library,
accessed **read-only over SMB** from a Mac. Built in **R + POSIX/bash only**
(no Python anywhere); heavy lifting done by purpose-built CLI tools driven from
shell, with R for assembly, clustering, and the review UI.

## Confirmed decisions

| Decision | Choice |
|---|---|
| Per-photo store | **SQLite** as system of record; parallel workers write sharded staging files merged via upsert |
| Phase 3 writes | **SSH to the Synology, server-side `mv`**; dry-run manifest + reviewable script first, explicit flag to execute |
| Media scope | **All still images** incl. HEIC/HEIF + camera RAW (video deferred to a later, separate capability) |
| Code structure | **R package** (`R/` functions, `inst/` CLI scripts, `inst/shiny/` app, `tests/testthat/`) |
| Hashes per photo | **All four**: whole-file content hash, decoded-pixel hash, metadata hash, perceptual fingerprint grid |
| Exact grouping | By **decoded-pixel hash** |
| Near grouping | **Hamming distance** on fingerprint with **blocking/bucketing**; thresholds adjustable in the Shiny app |

## Guiding constraints (apply to every stage)

- **Minimize SMB reads.** Each original is streamed across the network **at most
  once per run**: copy to a local temp, then run every hasher/decoder on the
  local copy. Re-runs skip files already inventoried (matched on
  path + size + mtime), so resumed runs read nothing new.
- **No Python.** Tools used: `vips`/`vipsheader`/`vipsthumbnail`, `exiftool`,
  `b3sum` (fallback `shasum`), `sqlite3`, `find`/`stat`/`awk`/`sort`/`xargs`,
  `ssh`. R packages: `DBI`, `RSQLite`, `yaml`, `shiny`, `bslib`, `base64enc`.
  These are CLI tools and R packages, consistent with the brief; any further
  dependency will be called out and justified, not introduced silently.
- **Filename safety.** All enumeration is NUL-delimited (`find -print0`,
  `xargs -0`); free-text fields (paths, captions) are **base64-encoded** in
  staging files so the intermediate format stays line-safe regardless of
  spaces, tabs, or newlines in names. Decoded on import into SQLite.
- **Cruft exclusion.** Prune Synology/macOS artifacts during enumeration:
  `@eaDir`, `#recycle`, `#snapshot`, `@tmp`, `.@__thumb`, `@sharebin`,
  `.DS_Store`, AppleDouble `._*`, `Thumbs.db`, `.Spotlight-V100`,
  `.TemporaryItems`, `.Trashes`, `.fseventsd`. Pattern list lives in config.
- **Idempotent + resumable.** Every stage records progress in SQLite and can be
  re-run safely; partial work is detected and skipped, not repeated.

## Repository / package layout

```
dundee/
  DESCRIPTION, NAMESPACE
  R/                      # package functions (testable)
    config.R             # load/validate config (paths, ssh, thresholds, cruft)
    db.R                 # SQLite schema, connect, upsert, migrations
    inventory.R          # staging-file import, dedup-of-rows, resume logic
    fingerprint.R        # parse fingerprint bits, Hamming distance helpers
    cluster.R            # exact + near grouping, LSH blocking, union-find components
    analyze.R            # orchestrate exact + near clustering -> write groups table
    thumbnails.R         # lazy review-thumbnail cache for grouped photos
    decide.R             # preferred-copy heuristics + decision persistence
    move.R               # dest-path mapping, manifest + script generation
  inst/
    bin/
      _boot.R            # shared bootstrap: locate package or source R/ directly
      lib.sh             # shared shell helpers (HASHER, STAT flavor, logging)
      _fingerprint-one.sh# single-file worker called by 20-fingerprint.sh via xargs
      00-preflight.sh    # verify tools/versions (vips, exiftool, b3sum, ...)
      10-enumerate.sh    # find -> NUL list + stat, cruft-pruned, resumable
      20-fingerprint.sh  # fan-out: xargs -P -> _fingerprint-one.sh -> staging shards
      25-resume.R        # diff enum list against photos table; emit todo.nul
      30-merge.R         # load shard staging -> SQLite (upsert)
      40-analyze.R       # build groups, write group/decision tables
      50-app.R           # launch Shiny review app
      60-plan-moves.R    # emit move manifest + reviewable shell script
      70-execute-moves.sh# run server-side mv over ssh (guarded by --execute)
    shiny/
      app.R              # bslib review app
  tests/
    fixtures/            # tiny committed image library (exact, near-dup, HEIC, RAW, cruft)
    testthat/            # unit tests
  config.example.yml     # user copies to config.yml (gitignored)
```

`run.sh` wires the stages: `preflight -> enumerate -> resume -> fingerprint ->
merge -> analyze -> app -> plan-moves -> execute-moves`.

## Cross-cutting infrastructure (build first)

1. **Config** (`config.yml`, validated in `config.R`): SMB library root (Mac
   mount), Synology volume root + SSH host/user (for path translation in Phase
   3), destination roots (`preferred/`, `non-preferred/`), cruft patterns,
   parallelism (`-P`), near-dup Hamming threshold + fingerprint size, temp dir.
2. **SQLite schema** (`db.R`):
   - `photos` — one row per file: `path` (unique key), `size`, `mtime`, `inode`,
     `format`, `width`, `height`, `file_hash`, `pixel_hash`, `meta_hash`,
     `fingerprint` (hex bits), plus selected EXIF (capture time, camera, etc.),
     `inventoried_at`.
   - `errors` — files that failed to decode/hash, with reason (for triage).
   - `groups` — `group_id`, `tier` (`exact`/`near`), members via `photo_id`.
   - `decisions` — `photo_id`, `group_id`, `preferred` (bool), `decided_by`
     (`bulk`/`manual`), `decided_at`.
   - `moves` — `photo_id`, `src`, `dest`, `state` (`planned`/`done`/`skipped`),
     `moved_at`.
   - Indexes on `pixel_hash`, `file_hash`, and `groups(photo_id)`. LSH blocking is computed in-memory in R, not via a DB index.
3. **Preflight** (`00-preflight.sh`): check each tool exists and meets minimum
   capability (e.g. `vips` HEIC/RAW support, `b3sum` present else `shasum`),
   detect **BSD vs GNU** `find`/`stat` (macOS ships BSD; code paths differ for
   `stat -f` vs `stat -c` and `find -printf`). Recommend installing GNU
   coreutils/findutils + libvips + exiftool via Homebrew; fail fast with a clear
   message listing anything missing.

## Phase 1 — inventory

1. **Enumerate** (`10-enumerate.sh`): `find <root> -print0` with cruft dirs
   pruned, capturing `path`, `size`, `mtime`, `inode` per file (BSD `stat -f`
   or GNU `stat -c`, batched via `xargs -0`). Emit a NUL/base64-safe worklist.
2. **Resume filter**: diff the worklist against `photos` on
   `path + size + mtime`; keep only new/changed files. Unchanged files are never
   re-read from SMB.
3. **Shard + fan out** (`20-fingerprint.sh` via `xargs -0 -P N`): per file —
   - copy the original to local temp (**the single SMB read**);
   - `file_hash` = `b3sum` of the temp file (byte-identical detection);
   - `vips` decode the temp once -> (a) raw pixel stream hashed for `pixel_hash`,
     (b) small grayscale grid -> `fingerprint` bits;
   - `exiftool` on the temp -> `meta_hash` + selected EXIF fields;
   - `vipsheader` for `width`/`height`/`format`;
   - append one base64-safe line to the worker's shard staging file; delete temp.
   - Decode failures (corrupt/unsupported) are logged to a shard error file, not
     fatal.
4. **Merge** (`30-merge.R`): read all shard staging + error files, base64-decode
   text fields, **upsert** into `photos`/`errors`. Re-running merge is
   idempotent (keyed on `path`).

Caveat to surface: a decoded-pixel hash matches **re-encodes of the same
rendered image**; a RAW and a JPEG "of the same shot" will not share a
pixel_hash (different rendering) — those are caught in the near tier.

## Phase 2 — analyze + review

1. **Exact tier** (`40-analyze.R`): group `photos` by `pixel_hash`; any hash with
   >=2 members is an exact-duplicate group. (Whole-file `file_hash` collisions are
   a strict subset, surfaced as "byte-identical" within the group.)
2. **Near tier**: avoid the ~10^12 all-pairs blowup via **blocking/LSH** on the
   fingerprint — split the bit vector into bands, hash each band, and only
   compare photos that collide in at least one band. Compute Hamming distance
   within candidate buckets, keep pairs below threshold, then take **connected
   components** (base-R union-find; no graph package dependency) as near-dup groups. Threshold + band parameters are
   config-driven and adjustable live in the app.
3. **Review thumbnails** (`thumbnails.R`): the stored fingerprint is for matching,
   not viewing. Generate and **cache a small color thumbnail only for photos that
   belong to a group** (far fewer than 1M) — one targeted SMB read each, cached
   locally so the app never re-reads originals.
4. **Shiny review app** (`inst/shiny/`, bslib): browse groups; view member
   thumbnails side by side with size/dimensions/format/EXIF; adjust near-dup
   threshold to tighten/loosen grouping; **bulk heuristics** to auto-pick the
   preferred copy (e.g. largest dimensions -> largest file size -> richest
   metadata -> oldest capture time -> preferred-folder priority) with **manual
   per-group override**. Decisions persist to the `decisions` table immediately,
   so review is resumable.

## Phase 3 — move (mark, then move; never delete)

1. **Plan** (`60-plan-moves.R`): from `decisions`, compute destinations under two
   roots preserving the relative tree from the library root —
   `preferred/<relpath>` and `non-preferred/<relpath>`. Translate Mac SMB paths
   to **Synology server-side absolute paths** using the volume mapping in config.
   Write a `moves` manifest plus a **reviewable, NUL-safe shell script** of
   `mkdir -p` + `mv` commands. **Dry-run by default.**
2. **Execute** (`70-execute-moves.sh`, requires `--execute`): run the moves
   **server-side over `ssh`** so renames stay on-volume (instant, no bytes over
   SMB). Idempotent/resumable: skip rows whose source is already gone and
   destination exists; mark each row `done`/`skipped` in `moves`. Relative paths
   are unique per original, so no destination collisions across the two roots.
3. **Safety**: only moves, never deletes; originals end up under
   `non-preferred/` for later human review/deletion as a separate step.

## Testing

- **testthat** unit tests for pure R logic: Hamming distance + LSH banding,
  exact/near grouping and component assembly, preferred-copy heuristics,
  path->dest mapping, SMB->NAS path translation, config validation, SQLite upsert.
- **Shell-level tests** against a tiny committed **fixture library** (a handful
  of images: exact copies, a re-encoded copy, a near-dup, a stripped-EXIF copy,
  a HEIC, a RAW, plus a cruft dir) to exercise enumerate -> fingerprint -> merge
  end to end and assert the expected groups.

## Open items to confirm during build (non-blocking)

- **SMB->NAS path mapping + SSH target** for Phase 3 (filled into `config.yml`).
- **Fingerprint geometry** (grid size / bit length) and default Hamming
  threshold — I'll pick sensible defaults (e.g. 8x8 dHash -> 64 bits, threshold
  ~5) and expose them as tunables.
- **Bulk-preference default ordering** — I'll implement the heuristic above and
  let you reorder rules in config.

## Build order (milestones)

1. Package skeleton + config + SQLite schema + preflight.
2. Enumerate + fingerprint worker + merge -> populated `photos` store (tested on
   fixtures, then a sample subtree of the real library).
3. Analyze: exact + near clustering with LSH blocking -> `groups`.
4. Shiny review app + decision persistence + lazy thumbnails.
5. Move planner (dry-run manifest/script) -> server-side execute over SSH.
6. Tests + docs (README usage, runbook).
