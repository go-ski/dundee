# dundee
a set of codes for getting **dee**duplication of photo collections **done**

Has three phases: inventory, analyze, and move

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
`exiftool`, `b3sum`, `sqlite3`, `find`/`stat`/`awk`/`xargs`, `ssh` — with R
(an installable package) for assembly, clustering, the review UI, and move
planning. The single source of truth is a **SQLite** store under `work/`.

Per photo, the inventory worker reads each original across SMB **exactly once**
(copy to local temp, then derive everything locally) and records four signals:

| Signal | Catches |
|---|---|
| whole-file content hash (`b3sum`) | byte-identical copies |
| decoded-pixel hash (`vips`) | same pixels re-saved in a different container/metadata |
| metadata hash (`exiftool`) | identical embedded metadata |
| perceptual fingerprint (dHash grid) | near-duplicates, via Hamming distance |

Analyze forms **exact** groups by decoded-pixel hash and **near** groups by
Hamming distance with LSH blocking (tunable threshold). The Shiny app shows each
group's thumbnails + metadata and records the preferred copy. Move translates
Mac SMB paths to Synology server-side paths and performs on-volume `mv` over SSH
— marking first, moving second, deleting never.

## Requirements

```sh
brew install vips exiftool b3sum     # sqlite3 and ssh ship with macOS
```

R packages: `DBI`, `RSQLite`, `base64enc`, `yaml` (plus `shiny`, `bslib` for the
review app). Install the package once with `R CMD INSTALL .`, or run directly
from the source tree (the scripts fall back to sourcing `R/`).

## Usage

```sh
cp config.example.yml config.yml     # then edit paths, ssh target, thresholds
./run.sh preflight                   # verify external tools are present

# Phase 1 — inventory (enumerate -> resume-filter -> fingerprint -> merge)
./run.sh inventory config.yml

# Phase 2 — analyze, then review
./run.sh analyze config.yml
./run.sh app config.yml              # opens the Shiny review app

# Phase 3 — plan (dry run), review the script, then execute server-side
./run.sh plan config.yml --bulk      # writes work/moves.tsv + work/moves.sh
./run.sh move config.yml             # DRY RUN: prints what would run
./run.sh move config.yml --execute   # performs on-volume mv over SSH
```

Every stage is idempotent and resumable: re-running inventory reads nothing for
unchanged files, and the move script skips sources already relocated.

## Key configuration

See `config.example.yml`. The most important fields:

- `library_root` — the read-only SMB mount of the library on the Mac.
- `nas_root` — the Synology server-side path the SMB mount corresponds to
  (e.g. `/Volumes/photo` ↔ `/volume1/photo`).
- `preferred_root` / `nonpreferred_root` — server-side output trees.
- `ssh_user` / `ssh_host` — SSH target for server-side moves.
- `hamming_threshold`, `fingerprint_grid`, `lsh_bands` — near-duplicate tuning.
- `preference_rules` — bulk preferred-copy ordering.

## Development

```sh
Rscript dev-test.R                   # unit tests (testthat), no install needed
bash tests/e2e.sh                    # full pipeline on a generated fixture set
```

> HEIC/HEIF: handled when libvips is built with libheif. Verify with
> `vips --vips-config | tr ',' '\n' | grep -i heif` (expect
> `... with libheif: true`). Files vips cannot decode are logged to the
> `errors` table rather than fingerprinted.

