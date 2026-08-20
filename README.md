# dundee
a set of codes for getting **dee**duplication of photo collections **done**

Targets Synology Photos SMB mounted to a Mac
directory, but should work for other kinds of collections under a read-only `library_root`
directory. Has three phases: inventory, analyze, and move.

## **inventory**

generates a full list of photo paths, each  with several properties of a photo, such as file size, a couple of different hash numbers (one for pixels and one for metadata), a small grayscale fingerprint grid,  and other photo properties

## **analyze**

works with this list to produce duplicate groups using smart cluster analysis techniques in R, with a Shiny app that provides a visual and data examination of the grouped results along with bulk and individual ways to specify preferred copies

## **move**

moves the preferred and non-preferred copies into separate folders that can later be moved elsewhere or deleted

---

## How it works

Built in **R and POSIX/bash only** (no Python). Heavy lifting is done by
purpose-built CLI tools driven from shell — `vips`/`vipsheader`/`vipsthumbnail`,
`exiftool`, `b3sum`, `find`/`stat`/`awk`/`xargs`, `ssh` — with R
(an installable package) for assembly, clustering, the review UI, and move
planning. The single source of truth is a **SQLite** store inside the work
directory.

Per photo, the inventory worker reads each original's **pixels across SMB
exactly once** (copy to local temp, then derive everything locally) and records
four signals:

| Signal | Catches | Used to form groups? |
|---|---|---|
| whole-file content hash (`b3sum`) | byte-identical copies | no — recorded only |
| decoded-pixel hash (`vips`) | same pixels re-saved in a different container/metadata | **yes** — the *exact* tier |
| metadata hash (`exiftool`) | identical embedded metadata | no — recorded only |
| perceptual fingerprint (dHash grid) | near-duplicates, via Hamming distance | **yes** — the *near* tier |

Only the decoded-pixel hash and the fingerprint determine group membership. The
file hash and metadata hash are stored for inspection and provenance; the
metadata *line count* feeds the `max_meta` preference rule.

The metadata lines are sorted under `LC_ALL=C` before hashing. Byte order is
the only order that is the same on every machine, and it is the only one that
cannot fail: a UTF-8 collation makes `sort` abort on an EXIF tag holding
Latin-1 or Shift-JIS bytes, which is common in `Artist` and `Model`.

Analyze forms **exact** groups by decoded-pixel hash, then **near** groups by
Hamming distance with LSH blocking (tunable threshold) over whatever is left —
a photo already placed in an exact group is not considered for the near tier.
The Shiny app compares the copies in a group and records the preferred one.
Move translates Mac SMB paths to Synology server-side paths and performs
on-volume `mv` over SSH — marking first, moving second, deleting never.

### Reviewing a group

Opening a group reads each of its originals **once** and derives everything from
that read — the thumbnail, the full metadata, and a full-size local copy for the
comparison viewer. Nothing is added to the fingerprint pipeline, so none of this
requires re-inventorying.

The display is a *difference*, not a list of values: attributes every copy
agrees on collapse into one `identical:` line, and only what differs is shown,
with the better value marked where there is a defensible direction. It reports
which preference rule actually decided the group and by what margin, and says so
plainly when no rule separated them and the winner came from the `photo_id`
tie-break.

Location and capture date are the exception — they are shown under every
thumbnail whether or not they differ, since they are what decisions turn on.
The capture date is `DateTimeOriginal`, falling back to `CreateDate` with the
fallback labelled. Coordinates are decimal, with a `[map]` link; that link is
the only outbound request the app can make, and only if you click it.

"Compare full size" opens a movable, resizable viewer with synchronised pan and
zoom and an A/B flip for spotting compression differences. TIFF, HEIC and RAW
are converted to a lossless PNG first, since no browser will display them;
JPEG, PNG and the other web formats are served byte for byte, because judging
compression artifacts against a re-encode would be judging the re-encode.

## Requirements

```sh
brew install vips exiftool b3sum     # ssh ships with macOS
```

`b3sum` is optional: if it is absent, `shasum -a 256` is used for every hash
instead. Hashes are not comparable between the two, so don't change hashing
tools partway through a library.

R packages: `DBI`, `RSQLite`, `base64enc`, `yaml`; plus `shiny` and `bslib` for
the review app, and `pkgload` if you want to run `exec/dundee` against an
uninstalled source tree. Install the package once with `R CMD INSTALL .`, or run
directly from the source tree (the launcher falls back to `pkgload::load_all()`).

The shell launcher installs with the package, so once dundee is installed you
can put it on your PATH and drop the `./` prefix used below:

```sh
ln -s "$(Rscript -e 'cat(system.file("exec", "dundee", package = "dundee"))')" ~/bin/dundee
```

`dd_preflight()` fails only on tools every run needs. `ssh` (Phase 3) and
`vipsthumbnail` (the review app) are reported as warnings, so a machine that can
run inventory and analyze reports `preflight: ready.`

> `exec/dundee` prefers an **installed** dundee over the source tree it sits in.
> When you are changing the package, either re-run `R CMD INSTALL .` or point
> `R_LIBS` at a scratch library first, or you will be running the last version
> you installed. `Rscript dev-test.R` always uses the source tree, and
> `tests/e2e.sh` installs to a throwaway library of its own.

## If using for Synology Photos

Mount the shared Synology photos directory read-only at `photo-ro`:

```sh
mkdir "$HOME/photo-ro"
mount_smbfs -o rdonly "//<username>@<yourphotoserver>.local/photos" "$HOME/photo-ro"
```

## Quick start

A dundee project is a **directory**, one per library. `dd_init()` creates it,
writes an annotated `config.yml` into it, and validates the result.

```r
library(dundee)

dd_preflight()

dd_init("~/dundee/family-photos", library_root = "~/photo-ro")
dd_use("~/dundee/family-photos")   # session default: later calls need no argument
dd_status()                        # what is done, and what is next
```

or from a shell:

```sh
./exec/dundee preflight
./exec/dundee init ~/dundee/family-photos --library=~/photo-ro
./exec/dundee status ~/dundee/family-photos
```

`dd_status()` is safe to run at any point and always names the next step.

### Usage From an R console

dundee is an installable R package, so every stage can be driven directly from
R, e.g. from Positron/RStudio:

```r
library(dundee)                      # or devtools::load_all() from source
dd_use("~/dundee/family-photos")

# Phase 1 — inventory (enumerate -> resume-filter -> fingerprint -> merge)
dd_run_inventory()

# Phase 2 — analyze, then review
dd_run_analyze()
dd_app()                             # opens the Shiny review app

# Phase 3 — plan (dry run), review the script, then execute server-side
dd_run_plan(bulk = TRUE)
dd_run_move()                        # dry run
dd_run_move(execute = TRUE)
```

Every stage takes an optional first argument naming the project: a work
directory, or an already-resolved list from `dd_config()`. With `dd_use()` set
(or `$DUNDEE_WORK`, or a `config.yml` in the working directory) it can be
omitted. Add `quiet = TRUE` to any `dd_run_*()` call to suppress phase banners
and progress bars.

Passing a path to a `config.yml` also works, but the directory *containing* that
file then becomes the work directory — so don't point it at the dundee checkout
unless you want the store, `staging/`, `thumbs/` and `tmp/` created there.

### Usage From the terminal (shell)

`exec/dundee` is a thin wrapper around the same package; use it when you'd
rather stay in a shell than an R session. It is shown here as run from a source
checkout; installed and symlinked (see Requirements) it is just `dundee`:

```sh
./exec/dundee preflight                   # verify external tools and R packages

./exec/dundee init   ~/dundee/family-photos --library=~/photo-ro
./exec/dundee config ~/dundee/family-photos
./exec/dundee status ~/dundee/family-photos

# Phase 1 — inventory (enumerate -> resume-filter -> fingerprint -> merge)
./exec/dundee inventory ~/dundee/family-photos [--parallel=N] [--rebase] [--quiet]

# Phase 2 — analyze, then review
./exec/dundee analyze ~/dundee/family-photos [--quiet]
./exec/dundee app     ~/dundee/family-photos [--port=N] [--no-browser]

# Phase 3 — plan (dry run), review the script, then execute server-side
./exec/dundee plan ~/dundee/family-photos --bulk   # writes moves.tsv + moves.sh
./exec/dundee move ~/dundee/family-photos          # DRY RUN: prints what would run
./exec/dundee move ~/dundee/family-photos --execute
```

The positional argument is a work directory. With none, dundee resolves, in
order: `options(dundee.work_dir)` (set by `dd_use()`), `$DUNDEE_WORK`,
`$DUNDEE_CONFIG`, `./config.yml`, `./work/config.yml`. Options are validated
per command, so an option that is real but wrong for the command you typed
(`status --bulk`) is rejected rather than silently ignored.

Each stage prints a phase banner plus progress as it runs (a live count during
fingerprinting, progress bars for merge/analyze/plan) whether run from R or the
shell. `--quiet` / `quiet = TRUE` suppresses banners and progress; a few
one-line summaries are still printed.

### Resumability

Every stage is idempotent and re-runnable.

- Re-running **inventory** re-reads only files that are new, whose size or
  mtime has changed, or that previously failed to decode — a path in the
  `errors` table has no `photos` row, so it is retried on every run in case the
  file has become readable (and its error row is dropped once it is).
- `staging/` holds one shard per fingerprint worker. Shards are merged
  oldest-run-first and removed as soon as they merge, so "merged N photo
  row(s)" is the number of rows written by *this* run. If a merge is
  interrupted, the unmerged shards are still there and the next run picks
  them up.
- Re-running **analyze** recomputes grouping from stored fingerprints; nothing
  is re-read from the library. A group's id is derived from its members, not
  from the order they happen to come out of the store, so decisions you have
  already recorded keep pointing at the same photos as the library grows.
  A photo that ends up in *no* group — because you tightened
  `hamming_threshold`, say — loses its decision and any move still only
  planned, so dundee stops relocating photos it no longer calls duplicates.
  That discards a manual choice too, since the group it described is gone;
  moves already marked done are history and are kept.
- The generated **move** script guards every command with `[ -e source ]` and
  uses `mv -n`, so an interrupted run can simply be repeated.

## What lives where

```
<work_dir>/
  config.yml            the only file you edit
  config.resolved.yml   snapshot written by every stage (provenance; do not edit)
  config.history/       prior config.yml, saved by dd_init(overwrite = TRUE)
  dundee.sqlite         the store (plus -wal/-shm while it is open)
  enum.tsv  todo.nul    inventory intermediates
  staging/              per-worker fingerprint shards
  tmp/                  fingerprint worker scratch space
  thumbs/               review-app thumbnail cache
  originals/            review-app full-size cache (bounded by review_cache)
  moves.tsv  moves.sh   Phase 3 plan
```

## Key configuration

See `inst/templates/config.yml`, the annotated template `dd_init()` installs.
(From an installed dundee, `dd_config_example("somewhere.yml")` writes the same
file wherever you want to read it.)

A dundee project is a **directory**, and `config.yml` lives inside it. There is
no `work_dir:` key — the work directory *is* the directory the config is in.
Everything dundee writes for one library sits beside the config; to work on a
second library, make a second work directory. There is no `temp_dir:` key
either: scratch is always `<work_dir>/tmp`. (A legacy `work_dir:` entry is still
honoured, with a message pointing at `dd_migrate()`, which relocates an old-style
config into its work directory.)

The **only path you must set** is:

- `library_root` — the read-only SMB mount of the library on the Mac. Never
  written to. `dd_init()` and `dd_config()` refuse to run if the work directory
  is the same as, nested inside, or contains `library_root`; the check is
  case-insensitive-aware, since `/Volumes/Photo` and `/Volumes/photo` are one
  directory on APFS/HFS+ and SMB.

Everything else is tuning, not paths:

- `db_path` — the store's *filename* under `work_dir`, not a separate path.
- `parallel`, `extensions`, `cruft` — enumeration and fingerprinting.
- `hamming_threshold`, `fingerprint_grid`, `lsh_bands` — near-duplicate tuning.
- `preference_rules` — an ordered list applied as lexicographic tie-breakers
  (all rules, in sequence; `photo_id` breaks any remaining tie). One of
  `max_pixels`, `max_filesize`, `max_meta`, `oldest_capture`, `folder_priority`.
  `max_meta` distinguishes a photo whose metadata could not be read (stored as
  NULL, ranked last, and counted by `dd_status()`) from one that genuinely
  carries none (stored as 0); ties among unreadable photos still fall through
  to the remaining rules.
- `folder_priority` — folders relative to `library_root`, most-preferred first;
  consulted only when `folder_priority` appears in `preference_rules`.
- `review_cache` — how many full-size originals the review app keeps in
  `originals/` for its comparison viewer, least-recently-used evicted first
  (default 100). Budget for it: 100 JPEGs is roughly 300 MB, but 100 TIFF or RAW
  copies can approach 1 GB. `0` disables the viewer's cache; nothing else
  depends on it, and `dd_cache_clear()` empties it at any time.
- `nas_root` — the Synology server-side path the SMB mount corresponds to
  (e.g. `~/photo-ro` ↔ `/volume1/photo`).
- `preferred_root` / `nonpreferred_root` — server-side output trees.
- `ssh_user` / `ssh_host` — SSH target for server-side moves.

Those last five (`nas_root`, `preferred_root`, `nonpreferred_root`, `ssh_user`,
`ssh_host`) are needed only for `plan` and `move`; inventory and analyze ignore
them.

Two values are frozen by the store on first use and are errors to change
afterwards: `fingerprint_grid` (fingerprints of different geometries are not
comparable) and `library_root` (every stored path is absolute). A changed grid
means starting a fresh work directory. A changed `library_root` is recoverable
**when it is the same library re-mounted elsewhere**: re-run inventory with
`rebase = TRUE` (`--rebase`) and every stored path is rewritten onto the new
root. Do not use it to point a store at a different library.

### Editing config.yml afterwards

`config.yml` is meant to be hand-edited. Every stage records the settings it ran
under, and `dd_status()` compares them against the file, so after an edit it
names what changed and what to re-run:

```
  config changed since analyze ran:
    hamming_threshold: 5 -> 3
  next: dd_run_analyze()   # config changed
```

| Edited key | Re-run |
|---|---|
| `extensions`, `cruft` | inventory |
| `hamming_threshold`, `lsh_bands` | analyze |
| `preference_rules`, `folder_priority` | see the caveat below |
| `nas_root`, `preferred_root`, `nonpreferred_root` | plan |
| `parallel`, `db_path`, `ssh_user`, `ssh_host` | nothing — no stored artifact depends on them |

When more than one stage has drifted, `dd_status()` recommends the earliest,
since re-running it carries the later ones with it.

Two caveats it cannot fix for you:

- **Narrowing `extensions` or widening `cruft`** leaves rows for files that are
  no longer candidates. Re-running inventory picks up newly-eligible files but
  never removes ineligible ones; only a fresh work directory does that.
- **`preference_rules` and `folder_priority` do not re-apply to existing
  decisions.** `dd_run_plan(bulk = TRUE)` skips every photo that already has a
  decision, so the edited rules affect only photos decided afterwards. To apply
  them to what is already decided, call
  `dd_apply_bulk_decisions(con, cfg, overwrite = TRUE)` directly — which also
  discards any manual choices made in the review app.

`hamming_threshold` is otherwise safe to change at any time — re-run analyze and
grouping is recomputed from the stored fingerprints. Note that *tightening* it
can dissolve a group, and photos left in no group at all lose their decisions
(see Resumability).

> On `lsh_bands`: the collision probability quoted in the config template is the
> standard bit-sampling LSH result, which assumes the differing bits are spread
> uniformly over positions and that bands are independent. dHash bits are
> adjacent-pixel comparisons, so they are spatially correlated, and real edits
> perturb contiguous runs of bits. In practice recall is *better* than the formula
> for localised edits (crops, re-saves, small resizes) and *worse* for global tonal
> changes that flip comparisons all over the frame. Treat the number as a guide.

## Troubleshooting

**"this store was built with fingerprint_grid = 8 but config.yml says 16"** —
restore the original value, or start a new work directory and re-fingerprint.
Fingerprints of different geometries cannot be compared.

**"this store was built against library_root … but config.yml now says …"** —
the mount moved. If it is the same library at a new path, re-run inventory with
`--rebase` (or `dd_run_inventory(rebase = TRUE)`) to rewrite the stored paths.
If it is a different library, start a fresh work directory.

**"unknown config key 'hamming_thresold' — did you mean 'hamming_threshold'?"** —
a typo. Unknown keys warn and are ignored, so fix it before the run matters.

**Photos with accented or non-Latin names are re-fingerprinted every run** —
a store built by dundee ≤ 0.0.1 under a `C`/`POSIX` locale holds those paths in
escaped form. The locale no longer matters, but the mangled paths already in the
store do: start a fresh work directory once, and it will not recur.

**Files that vips cannot decode** are logged to the `errors` table rather than
fingerprinted, and are retried on each inventory run. `dd_status()` reports the
count as "unreadable"; once a file reads successfully its error row is dropped,
so the count tracks the library rather than accumulating every failure ever
seen.

## Development

```sh
Rscript dev-test.R                   # unit tests (testthat), no install needed
bash tests/e2e.sh                    # full pipeline on a generated fixture set
```

`tests/e2e.sh` installs the package into a throwaway library and runs against
that, so it always tests the working tree rather than whatever you installed
last. It asserts, among other things, that nothing under `library_root` was
written to — so it also serves as the regression test for the read-only
guarantee.

> HEIC/HEIF: handled when libvips is built with libheif. Verify with
> `vips --vips-config | tr ',' '\n' | grep -i heif` (expect
> `... with libheif: true`). Files vips cannot decode are logged to the
> `errors` table rather than fingerprinted.
