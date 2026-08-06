# dundee (development version)

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
  directory and names the next step. Also available as `run.sh status`.

* `dd_config()` accepts a work directory, a YAML path, or a resolved list.
  A `work_dir:` key that disagrees with the file's own location is still
  honoured, with a message pointing at the new `dd_migrate()`, which moves a
  legacy config into its work directory.

* The annotated template now ships in `inst/templates/config.yml`, so it is
  present in an installed package; `config.example.yml` at the repo root is a
  copy of it, checked by the test suite. Previously `dd_config_example()`
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
