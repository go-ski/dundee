# dundee 0.1.0

## dundee 0.1.0 Correctness fixes

* **Group ids are now stable across analyze runs.** They were assigned by
  position, so a later import that created a group ahead of an existing one
  shifted every id after it. Because `dd_apply_bulk_decisions()` keyed
  "already decided" off `group_id`, a stale decision then shadowed a *different*
  group, whose photos were silently left undecided and never reached
  `moves.tsv`. Ids are now derived from the group's smallest member `photo_id`,
  the bulk pass asks per photo rather than per group, and `dd_analyze()`
  re-points existing decisions at the group their photo is in now.

* **Non-ASCII filenames survive a non-UTF-8 locale.** `dd_b64dec()` left decoded
  paths marked `"unknown"`, so under `C`/`POSIX` they were stored escaped
  (`caf<c3><a9>-...`): the resume filter missed those files on every run and the
  generated move script pointed at paths that did not exist. They are now marked
  UTF-8, and `moves.tsv`/`moves.sh` are written without re-encoding. A store
  built under `C` by an earlier version still holds mangled paths and needs
  rebuilding.

* **`dd_config()` no longer writes into `library_root`.** The case-sensitivity
  probe created and deleted a file in every directory it tested, including the
  read-only library, moving its mtime. It now flips the case of an existing
  entry and asks whether the result resolves. This was the sole cause of
  `tests/e2e.sh` reporting `FAIL: library was written to`.

* **`move --execute` marks its rows done.** Nothing ever set a move's state, so
  `dd_status()` reported "0 done" forever and kept recommending the move that
  had just run.

* **Error rows are cleared once a file reads successfully.** A file that failed
  to decode and was later fixed (say by installing a vips loader) stayed in the
  `errors` table, so `dd_status()`'s "unreadable" count only ever grew.

* `rebase = TRUE` is reachable at last, as `dd_run_inventory(rebase = TRUE)` and
  `dundee inventory --rebase`. It now also rewrites the stored paths, which the
  guard never did — recording the new root alone left every absolute path
  pointing at the old mount.

* `dd_run_move()` gained `quiet`, so `quiet = TRUE` / `--quiet` really does work
  on every stage. `dundee init` now requires `--library=DIR` instead of quietly
  keeping the template's `~/photo-ro` placeholder. The review app uses the
  stored `photos.path` rather than rebuilding it from `library_root`.

* `dd_plan_moves()` drops still-planned rows whose decision has been withdrawn,
  instead of leaving them to inflate `dd_status()`.

* Preflight no longer requires `sqlite3`, which the package never calls (all
  store access is RSQLite; only `tests/e2e.sh` uses the CLI). `ssh` and
  `vipsthumbnail` are reported as warnings rather than failures, since they are
  needed only by the move phase and the review app respectively.

## The launcher ships, and less of dundee is shell

* **The command-line launcher installs with the package.** `run.sh` was in
  `.Rbuildignore`, so `dd_cli()` reached installed users without an entry point
  and the CLI worked only from a source checkout. It now lives in `exec/dundee`,
  the subdirectory R documents for exactly this and installs mode 755. Symlink
  it onto your PATH with
  `ln -s "$(Rscript -e 'cat(system.file("exec", "dundee", package = "dundee"))')" ~/bin/dundee`.

* **Options are validated per command.** A single global allow-list accepted
  `status --bulk --execute --port=9` and discarded it, and was how `--rebase`
  came to sit in the list for a stage that never read it. Each command now
  declares the options it takes, argument parsing is separated from dispatch,
  and a test asserts the usage text and that table still agree.

* **`dd_preflight()` is one report, not a shell script plus an R block.**
  `inst/bin/00-preflight.sh` did nothing that needed a shell and is gone;
  `Sys.which()` does the work. `bash` joins the required tools — it was always
  needed, but a bash script cannot report its own interpreter missing.

* **Phase 3 talks to the server from R.** `inst/bin/70-execute-moves.sh` is gone
  too; `dd_run_move()` prints the dry run and streams `moves.sh` over `ssh`
  itself, handing ssh the file so the UTF-8 bytes reach the server unconverted.

* `tests/e2e.sh` installs the package into a throwaway library and points
  `R_LIBS` at it, the way `R CMD check` does. It used to export `DUNDEE_SRC` to
  say "test this tree" while the launcher preferred whatever was installed last.

* First tests for `dd_cli()`, `dd_preflight()` and the move launcher. Together
  with the two ported scripts, this moves the CLI, preflight and the phase-3
  handoff inside the surface `R CMD check` can reach.

## Work directory as the project handle

* A dundee project is now a **directory**, and its `config.yml` lives inside
  it. `work_dir` is no longer a config field: the work directory is wherever
  `config.yml` is. One directory per read-only library, containing the config,
  the SQLite store, `tmp/`, `staging/`, `thumbs/`, the manifests, and the
  generated move script.

* New `dd_init()` creates a work directory from an annotated template and
  fills in the fields passed to it. Edit `config.yml` directly with any text
  editor to change settings afterward; [dd_config()] re-validates it on the
  next call and reports all problems at once if the edit is invalid.

* New `dd_use()` sets a session default, so every stage can then be called with
  no arguments: `dd_use("~/dundee/family-photos"); dd_run_inventory()`.
  Resolution order is the explicit argument, `options(dundee.work_dir)`,
  `$DUNDEE_WORK`, `$DUNDEE_CONFIG`, `./config.yml`, `./work/config.yml`.

* New `dd_status()` reports photo, group, decision and move counts for a work
  directory and names the next step. Also available as `dundee status`.

* `dd_config()` accepts a work directory, a YAML path, or a resolved list.
  A `work_dir:` key that disagrees with the file's own location is still
  honoured, with a message pointing at the new `dd_migrate()`, which moves a
  legacy config into its work directory.

* The annotated template now ships in `inst/templates/config.yml`, so it is
  present in an installed package; `config.example.yml` at the repo root is a
  copy of it, kept in step by the test suite. Previously `dd_config_example()`
  regenerated the file from defaults through `yaml::as.yaml()`, which stripped
  every comment.

## Validation and provenance

* Staging shards are now deleted once merged, and any that remain are merged
  oldest-run-first. Previously `staging/` grew without bound and was
  re-merged in `list.files()` order; because shard names carried a pid, that
  order was neither chronological nor numeric, so a file that changed between
  inventory runs could end up with the *earlier* run's row in the store.
  `dd_import_staging(prune = FALSE)` keeps the old behaviour for debugging.

* Unknown config keys now warn, with a nearest-match suggestion. A typo such as
  `hamming_thresold:` used to be accepted and ignored, so the run completed with
  the default value.

* Tuning values are type- and range-checked, and all problems are reported in
  one message rather than surfacing as an unrelated error several stages later.
  A key written with no value (`extensions:`) now falls back to its default
  instead of emptying the field.

* Every `dd_run_*()` stage writes `config.resolved.yml` into the work
  directory: fully resolved, absolute, and re-readable. This replaces the
  temporary file `dd_app()` used to create, so the review app and the shell
  stages read the same file and the parameters behind a store are recoverable.

* The store now records `fingerprint_grid` and `library_root` in a `meta`
  table. Changing the grid after inventory made stored fingerprints
  incomparable, and changing the library root invalidated every stored path;
  both were silent. They are now errors, with `rebase = TRUE` for the
  legitimate case of the same library re-mounted elsewhere.

* Config loading no longer creates directories as a side effect of resolving
  symlinks, and the `work_dir`/`library_root` overlap check is now correct on
  case-insensitive filesystems (APFS/HFS+, SMB), where `/Volumes/Photo` and
  `/Volumes/photo` are one directory.

## Command line

* `run.sh` gains `init`, `config`, and `status`; the positional argument is a
  work directory; `--no-browser` is available for `app`; and unknown options
  are rejected rather than silently ignored. `config.yml` is always edited
  directly (with any text editor) rather than through the CLI or R API.

## Earlier in this cycle

* `temp_dir` is no longer a config field — scratch space is always
  `<work_dir>/tmp`; a legacy entry is ignored with a message. `db_path` remains
  configurable as a filename but cannot point outside the work directory.

* Each stage prints a phase banner and sub-step announcements; fingerprinting
  shows a live `N/TOTAL` counter and the merge, clustering, planning and bulk
  decision loops show progress bars. Output animates in a terminal and falls
  back to periodic milestone lines in a log. `--quiet` (or `quiet = TRUE`)
  suppresses it.
