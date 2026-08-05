#!/usr/bin/env bash
# Remaining one- and two-line corrections, applied from the repo root.
# Run after dropping in the corrected project.R, test-config.R, e2e.sh,
# run-cli.R (into R/run.R), NEWS.md and the README sections.
set -euo pipefail

# 1. work_dir is no longer a config field: drop it from the defaults and fix
#    the stale comment that still calls it user-settable.
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("R/config.R"); s = p.read_text()
s = s.replace(
"""    # Read-only SMB mount root of the photo library on the Mac. This and
    # work_dir are the only two directories dundee expects a user to set.
    library_root = NULL,
    # Local working area: store, staging, temp scratch, caches, manifests.
    # Everything dundee writes locally lives under here.
    work_dir = "work",
    # SQLite store filename (always resolved under work_dir; see dd_config()).""",
"""    # Read-only root of the photo library. The ONLY directory a user sets:
    # the work directory is wherever config.yml lives (see R/project.R).
    library_root = NULL,
    # SQLite store filename, always resolved under the work directory.""")
p.write_text(s)
PY

# 2. config.example.yml is the template, verbatim -- one file to keep current.
cp inst/templates/config.yml config.example.yml

# 3. Ship the template but keep the root copy out of the build.
grep -q '^\^config\\\.example\\\.yml\$$' .Rbuildignore || \
  echo '^config\.example\.yml$' >> .Rbuildignore

# 4. Ignore per-project artifacts wherever a work directory is created.
cat >> .gitignore <<'EOF'

# dundee work directories (config.yml inside one is yours to keep or ignore)
config.resolved.yml
config.history/
enum.tsv
todo.nul
moves.tsv
moves.sh
EOF

# 5. The app now reads a durable snapshot in work_dir, not a tempfile.
python3 - <<'PY'
import pathlib
p = pathlib.Path("inst/shiny/app.R"); s = p.read_text()
s = s.replace(
"""# dd_app() writes a fully-resolved config (absolute paths) and points
# DUNDEE_CONFIG at it, because runApp() has already changed the working
# directory to this folder.
cfg_path <- Sys.getenv("DUNDEE_CONFIG", "config.yml")""",
"""# dd_app() writes <work_dir>/config.resolved.yml (absolute paths) and points
# DUNDEE_CONFIG at it, because runApp() has already changed the working
# directory to this folder. The file persists after the session, as provenance.
cfg_path <- Sys.getenv("DUNDEE_CONFIG", "config.resolved.yml")""")
p.write_text(s)
PY

# 6. run.sh: pass the source tree through so dd_template_lines() and the
#    fixture e2e run work before installation.
grep -q 'DUNDEE_SRC' run.sh || echo 'run.sh: expected DUNDEE_SRC export' >&2

# 7. Roxygen @param text in R/run.R still says "Path to a YAML config".
sed -i.bak \
  "s|#' @param config Path to a YAML config, or a config list from \[dd_config()\].|#' @param config A work directory, a config path, or a list from [dd_config()].|" \
  R/run.R && rm -f R/run.R.bak

echo "Now run: Rscript -e 'roxygen2::roxygenise()' && Rscript dev-test.R"
