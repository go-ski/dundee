Replace everything from "## Usage" / "### Usage From an R console" through the
end of "## Key configuration" with the following. (The "How it works" section
above it also needs one edit: "The single source of truth is a **SQLite** store
under `work/`" becomes "under your work directory".)

---

## Usage

A dundee **project is a directory**. It holds the config and everything dundee
writes for one library; the library itself is only ever read.

```
~/dundee/family-photos/
  config.yml            the only file you edit
  config.resolved.yml   what the last run actually used
  config.history/       previous versions of config.yml
  dundee.sqlite         the store
  tmp/ staging/ thumbs/ enum.tsv todo.nul moves.tsv moves.sh
```

Mount the library read-only first:

```sh
mkdir -p "$HOME/photo-ro"
mount_smbfs -o rdonly //<user>@<nas>.local/photo "$HOME/photo-ro"
```

### From an R console

```r
library(dundee)                      # or devtools::load_all() from source

dd_preflight()                       # external tools + R packages

# One-time setup: writes an annotated config.yml and opens it in your editor
dd_init("~/dundee/family-photos", library_root = "~/photo-ro")
dd_use("~/dundee/family-photos")     # session default; stages need no argument

dd_status()                          # where am I, what is next

# Phase 1 — inventory (enumerate -> resume-filter -> fingerprint -> merge)
dd_run_inventory()

# Phase 2 — analyze, then review
dd_run_analyze()
dd_app()                             # Shiny review app

# Phase 3 — plan (dry run), review work/moves.sh, then execute server-side
dd_run_plan(bulk = TRUE)
dd_run_move()                        # dry run
dd_run_move(execute = TRUE)          # performs on-volume mv over SSH

dd_edit_config()                     # change thresholds later, safely
```

Any stage also accepts an explicit project: `dd_run_analyze("~/dundee/other")`.
That may be a work directory, a path to a `config.yml`, or a resolved list from
`dd_config()`. A second library is just a second directory — there is no shared
state between them. Add `quiet = TRUE` to suppress banners and progress.

### From the terminal (shell)

```sh
./run.sh preflight
./run.sh init ~/dundee/family-photos --library=~/photo-ro
export DUNDEE_WORK=~/dundee/family-photos     # or pass the dir to each command

./run.sh status
./run.sh inventory
./run.sh analyze
./run.sh app                                  # review UI
./run.sh plan --bulk                          # writes moves.tsv + moves.sh
./run.sh move                                 # DRY RUN
./run.sh move --execute
```

Every stage is idempotent and resumable: re-running inventory reads nothing for
unchanged files, and the move script skips sources already relocated.

## Key configuration

`config.yml` is annotated — see `config.example.yml` for the same text. The
**only path you set** is `library_root`, the read-only root of the library. The
work directory is not configured: it is the directory the config file is in,
and everything dundee writes goes under it (`db_path` is a filename within it,
not a path; scratch is always `tmp/`). dundee refuses to run if the work
directory is the same as, inside, or containing `library_root`.

Everything else is tuning:

- `hamming_threshold` — near-duplicate cutoff. Free to change; analyze recomputes
  grouping from stored fingerprints.
- `lsh_bands` — candidate blocking; must divide `fingerprint_grid^2`. More bands
  means higher recall and a slower analyze.
- `fingerprint_grid` — **fixed once inventory has run.** Fingerprints of
  different geometries are not comparable, so changing it is an error; start a
  new work directory instead.
- `library_root` — also recorded in the store. Changing it is an error unless
  the library was genuinely re-mounted elsewhere (`rebase = TRUE`).
- `preference_rules`, `folder_priority` — bulk preferred-copy ordering.
- `parallel`, `extensions`, `cruft` — inventory scope and fan-out.
- `ssh_user`, `ssh_host`, `nas_root`, `preferred_root`, `nonpreferred_root` —
  needed only for `plan` and `move`.

Unknown keys and out-of-range values are reported when the config is loaded,
not three stages later.

### Migrating from the earlier layout

If you have a `config.yml` outside its work directory with a `work_dir:` key,
it still works, with a message. To move it:

```r
dd_migrate("config.yml")   # copies it into work_dir, drops work_dir:/temp_dir:
```
