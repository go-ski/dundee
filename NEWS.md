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

* **Photo metadata survives non-UTF-8 bytes in an EXIF tag.** The fingerprint
  worker sorts exiftool's output before hashing it, and macOS `sort` aborts
  with `sort: Illegal byte sequence` when it reads from a *pipe* in a UTF-8
  locale and any line holds bytes that are not valid UTF-8 -- which an EXIF
  `Artist`, `Model` or `Copyright` written in Latin-1 or Shift-JIS does.
  `pipefail` turned that into a failed pipeline and `|| meta_lines=""` swallowed
  it, so the photo was stored with `meta_count` 0 and `meta_hash` set to the
  digest of the empty string, the same value for every affected photo. Since
  `max_meta` is third in the default `preference_rules`, a photo with a full set
  of tags scored 0 and **lost to its metadata-poorer duplicate**. The sort now
  runs under `LC_ALL=C`, which cannot fail on any byte sequence.

  That also makes the metadata hash reproducible. Sort order is locale-dependent,
  so the same photo hashed differently under `en_US.UTF-8` than under `C`; byte
  order is all a hash needs and is the same on every machine.

  Stores built by an earlier version still hold the zeroed rows. The resume
  filter keys on `(path, size, mtime)`, so re-running inventory will not revisit
  them; `UPDATE photos SET mtime = -1 WHERE meta_count = 0` before
  `dd_run_inventory()` forces a re-fingerprint in place, keeping `photo_id` and
  so leaving groups, decisions and moves intact.

* **"No metadata" and "metadata unreadable" are no longer the same value.** A
  failed read now leaves `meta_count` and `meta_hash` NULL rather than 0 and a
  constant, `dd_status()` reports the count, and `max_meta` ranks an unknown
  below a genuine 0 while still letting the later rules break ties among them.
  This is what let the bug above go unnoticed.

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

## The review app answers the question being asked

* **The group display is a difference, not a list of values.** It showed
  `rel_path`, a vips loader name, `WxH`, raw bytes, `meta:N` and capture time
  side by side, leaving the reviewer to diff them by eye. On the reference store
  that is close to useless: 24 of 30 groups agree on *every* displayed field and
  differ in exactly one that was not displayed at all. Attributes the copies
  share now collapse into one `identical:` line and only the differences are
  shown, with the better value marked where there is a defensible direction.

* **It says which rule decided the group, and admits when none did.** With
  width, height, size, meta and capture all tied, every preference rule falls
  through to the `photo_id` tie-break -- 80% of groups in the reference store.
  The app presented that as a decision. It now reports the deciding rule and its
  margin, and warns plainly when the winner was arbitrary. Margins too small to
  render distinctly say what the gap was, so `2.6 MB vs 2.6 MB` reads
  `2.6 MB vs 2.6 MB, larger by 1.3 kB`.

* **Image quality, location and the rest are read on demand.** The store keeps
  only `capture_time` and `camera`; everything else the fingerprint worker sees
  is hashed into `meta_hash` and discarded, and there is no GPS column at all.
  Rather than re-fingerprint a library to add columns, opening a group now reads
  its originals -- once each -- and derives the thumbnail, the full metadata and
  a full-size local copy from that single read. This is the same discipline
  `_fingerprint-one.sh` already applied, and it costs no more library reads than
  the thumbnail alone used to.

  It surfaces what actually separates two copies: `JPEGQualityEstimate`,
  chroma subsampling, bytes per pixel, ICC profile, and whether the camera's
  maker notes survived. In the reference store's one near pair that is 95 vs 80,
  4:2:2 vs 4:2:0, and maker notes present vs stripped -- a camera original
  against a re-export, none of which was visible before. Worth knowing:
  `max_meta` scores the re-export *higher*, because the 40-tag gap it counts is
  an embedded ICC profile.

* **Location and capture date are always on screen**, under every thumbnail,
  whether or not the copies differ, because they are what decisions turn on.
  Coordinates are decimal with a `[map]` link -- the only outbound request the
  app can make, and only when clicked. The date is `DateTimeOriginal` falling
  back to `CreateDate`, with the fallback labelled; a quarter of the reference
  library carries no `DateTimeOriginal`.

* **A full-size comparison viewer**, movable and resizable, with synchronised
  pan and zoom and an A/B flip for spotting compression differences. It opens
  instantly because the bytes are already local. TIFF, HEIC and RAW are
  converted to lossless PNG, since no browser renders them; web formats are
  served byte for byte, because judging artifacts against a re-encode would be
  judging the re-encode. The cache is bounded by the new `review_cache` setting
  (default 100, least-recently-used evicted); `dd_cache_clear()` empties it.

* **The group picker is a list, not a dropdown**, filling the sidebar and
  scrolling, with the current group highlighted and scrolled into view. It is
  rendered once and the highlight moved on the client, so selecting a group does
  not rebuild the list.

* New `details` table caching what each read yielded. It is derived data only:
  when the set of fields read changes it is dropped and refills on demand, which
  is why a row cannot silently report "no location" for a photo that has one.

## dd_status() notices a config.yml edit

* **Each stage now records the config keys it consumed**, and `dd_status()`
  compares them against the file. `config.yml` is meant to be hand-edited, but
  the next step was computed entirely from row counts: change
  `hamming_threshold` from 5 to 3 and dundee still recommended
  `dd_run_move(execute = TRUE)`, against groups built at 5. Status now reports
  `config changed since analyze ran: hamming_threshold: 5 -> 3` and points at
  `dd_run_analyze()`. With several stages drifted it names the earliest, since
  re-running that one carries the rest. `dd_status()` still never applies the
  config guard, so it keeps working when the config and store disagree; the
  returned data frame gains a `drift` count.

  Eight keys were previously unnoticed: `extensions`, `cruft`,
  `hamming_threshold`, `lsh_bands`, `preference_rules`, `folder_priority`,
  `nas_root`, and the two destination roots. `fingerprint_grid` and
  `library_root` were already guarded, and remain errors rather than drift.

  Editing `preference_rules` is reported but cannot be undone through
  `dd_run_plan()`, which does not pass `overwrite` to
  `dd_apply_bulk_decisions()`; status names that function instead of pretending
  a bulk re-run would apply the new rules.

* **Photos that stop being duplicates are no longer moved.** `dd_plan_moves()`
  reads `decisions` and never consults `groups`, so a group dissolved by a
  tightened `hamming_threshold` left its decision rows behind and dundee went on
  relocating the photos. `dd_analyze()` now drops decisions, and any move still
  only planned, for photos in no group at all. This discards a manual decision
  as well when its photo leaves every group — the group the reviewer was
  describing no longer exists. Moves already marked done are history and stay,
  and a photo still in some group keeps its decision exactly as before.

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
