# dundee (development version)

* Only two directories are user-configurable now: `library_root` (read-only)
  and `work_dir` (everything written locally). `temp_dir` is no longer a
  config field — scratch space is always `<work_dir>/tmp`; a legacy
  `temp_dir:` entry is ignored with an explanatory message. `db_path` remains
  configurable as a filename but can no longer point outside `work_dir` (an
  absolute value is reduced to its basename). `dd_config()` now errors if
  `work_dir` overlaps `library_root` in any way.

* The pipeline now reports the current phase and shows within-phase progress.
  Each `dd_run_*()` stage prints a phase banner and sub-step announcements, the
  parallel fingerprinting stage shows a live `N/TOTAL` counter, and the merge,
  clustering, planning, and bulk-decision loops show progress bars. Output
  animates in a terminal and falls back to periodic milestone lines when
  redirected to a log. Pass `--quiet` (or `quiet = TRUE`) to suppress it.

* Initial CRAN submission.
