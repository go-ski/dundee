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

Per photo, the inventory worker reads each original across SMB **exactly once**
(copy to local temp, then derive everything locally) and records four signals:

| Signal | Catches | Used to form groups? |
|---|---|---|
| whole-file content hash (`b3sum`) | byte-identical copies | no — recorded only |
| decoded-pixel hash (`vips`) | same pixels re-saved in a different container/metadata | **yes** — the *exact* tier |
| metadata hash (`exiftool`) | identical embedded metadata | no — recorded only |
| perceptual fingerprint (dHash grid) | near-duplicates, via Hamming distance | **yes** — the *near* tier |

Only the decoded-pixel hash and the fingerprint determine group membership. The
file hash and metadata hash are stored for inspection and provenance; the
metadata *line count* feeds the `max_meta` preference rule.

Analyze forms **exact** groups by decoded-pixel hash, then **near** groups by
Hamming distance with LSH blocking (tunable threshold) over whatever is left —
a photo already placed in an exact group is not considered for the near tier.
The Shiny app shows each group's thumbnails + metadata and records the preferred
copy. Move translates Mac SMB paths to Synology server-side paths and performs
on-volume `mv` over SSH — marking first, moving second, deleting never.

## Requirements

```sh
brew install vips exiftool b3sum     # ssh ships with macOS
```

`b3sum` is optional: if it is absent, `shasum -a 256` is used for every hash
instead. Hashes are not comparable between the two, so don't change hashing
tools partway through a library.

R packages: `DBI`, `RSQLite`, `base64enc`, `yaml`; plus `shiny` and `bslib` for
the review app, and `pkgload` if you want to run `run.sh` against an
uninstalled source tree. Install the package once with `R CMD INSTALL .`, or run
directly from the source tree (the scripts fall back to `pkgload::load_all()`).

Two notes on `dd_preflight()`:

- it checks for `ssh`, which is needed only for Phase 3, so it will report
  "missing requirements" on a machine that can nonetheless run inventory and
  analyze perfectly well;
- it checks for the `sqlite3` command-line tool, which the package itself never
  calls — all store access goes through RSQLite. Only `tests/e2e.sh` uses the
  CLI.

**Run under a UTF-8 locale** (`en_US.UTF-8`, `C.UTF-8`, …). Under `C`/`POSIX`,
filenames containing non-ASCII characters are stored in escaped form, which
breaks the resume filter for those files (they are re-read on every run) and
makes their entries in the generated move script point at paths that do not
exist. This matters mostly for non-interactive contexts — `cron`, `launchd`,
`ssh` without a TTY — which commonly default to `C`.

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
./run.sh preflight
./run.sh init ~/dundee/family-photos --library=~/photo-ro
./run.sh status ~/dundee/family-photos
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
omitted. Add `quiet = TRUE` to any call to suppress phase banners and progress
bars.

Passing a path to a `config.yml` also works, but the directory *containing* that
file then becomes the work directory — so don't point it at the dundee checkout
unless you want the store, `staging/`, `thumbs/` and `tmp/` created there.

### Usage From the terminal (shell)

`run.sh` is a thin wrapper around the same package; use it when you'd rather
stay in a shell than an R session:

```sh
./run.sh preflight                   # verify external tools and R packages

./run.sh init   ~/dundee/family-photos --library=~/photo-ro [--no-edit]
./run.sh config ~/dundee/family-photos [--edit]
./run.sh status ~/dundee/family-photos

# Phase 1 — inventory (enumerate -> resume-filter -> fingerprint -> merge)
./run.sh inventory ~/dundee/family-photos [--parallel=N] [--quiet]

# Phase 2 — analyze, then review
./run.sh analyze ~/dundee/family-photos [--quiet]
./run.sh app     ~/dundee/family-photos [--port=N] [--no-browser]

# Phase 3 — plan (dry run), review the script, then execute server-side
./run.sh plan ~/dundee/family-photos --bulk   # writes moves.tsv + moves.sh
./run.sh move ~/dundee/family-photos          # DRY RUN: prints what would run
./run.sh move ~/dundee/family-photos --execute
```

The positional argument is a work directory. With none, dundee resolves, in
order: `options(dundee.work_dir)` (set by `dd_use()`), `$DUNDEE_WORK`,
`$DUNDEE_CONFIG`, `./config.yml`, `./work/config.yml`. Unknown options are
rejected rather than silently ignored.

Each stage prints a phase banner plus progress as it runs (a live count during
fingerprinting, progress bars for merge/analyze/plan) whether run from R or the
shell. `--quiet` / `quiet = TRUE` suppresses banners and progress; a few
one-line summaries are still printed.

### Resumability

Every stage is idempotent and re-runnable.

- Re-running **inventory** re-reads only files that are new, whose size or
  mtime has changed, or that previously failed to decode — rows in the `errors`
  table are not in `photos`, so they are retried on every run in case the file
  has become readable.
- `staging/` accumulates shards across runs and is re-merged in full each time,
  so the "merged N photo row(s)" line counts staged rows, not new ones. It is
  safe to delete `staging/` after a successful inventory.
- Re-running **analyze** recomputes grouping from stored fingerprints; nothing
  is re-read from the library.
- The generated **move** script guards every command with `[ -e source ]` and
  uses `mv -n`, so an interrupted run can simply be repeated.

## What lives where

```
<work_dir>/
  config.yml            the only file you edit
  config.resolved.yml   snapshot written by every stage (provenance; do not edit)
  config.history/       timestamped copies of prior config.yml
  dundee.sqlite         the store
  enum.tsv  todo.nul    inventory intermediates
  staging/              per-worker fingerprint shards
  tmp/                  fingerprint worker scratch space
  thumbs/               review-app thumbnail cache
  moves.tsv  moves.sh   Phase 3 plan
```

## Key configuration

See `config.example.yml`, which is the same annotated template `dd_init()`
installs.

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
- `folder_priority` — folders relative to `library_root`, most-preferred first;
  consulted only when `folder_priority` appears in `preference_rules`.
- `nas_root` — the Synology server-side path the SMB mount corresponds to
  (e.g. `~/photo-ro` ↔ `/volume1/photo`).
- `preferred_root` / `nonpreferred_root` — server-side output trees.
- `ssh_user` / `ssh_host` — SSH target for server-side moves.

The last four are needed only for `plan` and `move`; inventory and analyze
ignore them.

Two values are frozen by the store on first use and are errors to change
afterwards: `fingerprint_grid` (fingerprints of different geometries are not
comparable) and `library_root` (every stored path is absolute). Changing either
means starting a fresh work directory.

`hamming_threshold` is safe to change at any time — re-run analyze and grouping
is recomputed from the stored fingerprints.

> On `lsh_bands`: the collision probability quoted in `config.example.yml` is the
> standard bit-sampling LSH result, which assumes the differing bits are spread
> uniformly over positions and that bands are independent. dHash bits are
> adjacent-pixel comparisons, so they are spatially correlated, and real edits
> perturb contiguous runs of bits. In practice recall is *better* than the formula
> for localised edits (crops, re-saves, small resizes) and *worse* for global tonal
> changes that flip comparisons all over the frame. Treat the number as a guide.

## Known issues

Current as of this revision; delete entries as they are fixed.

- **The review app does not start.** `dd_app()` and `run.sh app` fail
  immediately with `subscript out of bounds` from `dd_phase()`, because `"app"`
  is missing from the internal phase-ordinal table. Bulk decisions are still
  available via `dd_run_plan(bulk = TRUE)`.
- **`dd_config()` touches `library_root`.** The case-sensitivity probe creates
  and deletes a `.dundee-Case-<pid>` file in each directory it tests, including
  the library root. On a genuinely read-only mount the write fails and dundee
  falls back to assuming case-insensitive on macOS, so behaviour is correct
  there — but the library's directory mtime does change if it happens to be
  writable, and `tests/e2e.sh` fails on a clean checkout for this reason.
- **`rebase = TRUE` is not reachable.** If `library_root` changes, the store
  guard errors and advises re-running with `rebase = TRUE`, but no exported
  function or CLI flag accepts it. Until this is wired up, the recovery is a
  fresh work directory.
- **Non-ASCII filenames under a non-UTF-8 locale** — see Requirements above.
- `dd_status()` reports a `moves ... done` count, but nothing ever sets a move
  row's state to `done`; after a successful `move --execute` the status line
  still suggests running it.

## Troubleshooting

**"this store was built with fingerprint_grid = 8 but config.yml says 16"** —
restore the original value, or start a new work directory and re-fingerprint.
Fingerprints of different geometries cannot be compared.

**"this store was built against library_root … but config.yml now says …"** —
the mount moved. See Known issues; for now, a fresh work directory.

**"unknown config key 'hamming_thresold' — did you mean 'hamming_threshold'?"** —
a typo. Unknown keys warn and are ignored, so fix it before the run matters.

**Photos with accented or non-Latin names are re-fingerprinted every run** —
your locale is `C`/`POSIX`. Set `LC_ALL` to a UTF-8 locale and start a fresh
work directory (the paths already in the store are mangled).

**`preflight: missing requirements` but only `ssh` is missing** — that is fine
for phases 1 and 2; you only need `ssh` for `move`.

**Files that vips cannot decode** are logged to the `errors` table rather than
fingerprinted, and are retried on each inventory run. `dd_status()` reports the
count as "unreadable".

## Development

```sh
Rscript dev-test.R                   # unit tests (testthat), no install needed
bash tests/e2e.sh                    # full pipeline on a generated fixture set
```

`tests/e2e.sh` currently reports `FAIL: library was written to` on a clean
checkout — see Known issues. Every other assertion passes.

> HEIC/HEIF: handled when libvips is built with libheif. Verify with
> `vips --vips-config | tr ',' '\n' | grep -i heif` (expect
> `... with libheif: true`). Files vips cannot decode are logged to the
> `errors` table rather than fingerprinted.
