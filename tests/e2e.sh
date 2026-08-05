#!/usr/bin/env bash
# End-to-end smoke test of inventory -> analyze -> plan on the fixture library.
# Drives the package entry points (dd_run_*), not the individual stage scripts:
# the R stages that used to live in inst/bin (25-resume.R, 30-merge.R,
# 40-analyze.R, 60-plan-moves.R) are now functions and those files no longer
# exist. Run from the repo root.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"
export DUNDEE_SRC="$root"

TOP="$(mktemp -d)"
FX="$TOP/lib"
WORK="$TOP/work"          # sibling of the library, never nested inside it
trap 'rm -rf "$TOP"' EXIT

bash tests/fixtures/make-fixtures.sh "$FX"
mkdir -p "$WORK"

# The work directory is the handle; config.yml lives in it and carries no
# work_dir: key.
cat > "$WORK/config.yml" <<YML
library_root: $FX
db_path: e2e.sqlite
parallel: 4
nas_root: /volume1/photo
preferred_root: /volume1/photo/_dedup/preferred
nonpreferred_root: /volume1/photo/_dedup/non-preferred
ssh_user: tester
ssh_host: nas.local
YML

./run.sh inventory "$WORK" --quiet
./run.sh analyze   "$WORK" --quiet
./run.sh plan      "$WORK" --bulk --quiet
./run.sh status    "$WORK"

# --- assertions ---
db="$WORK/e2e.sqlite"
ngroups=$(sqlite3 "$db" "SELECT COUNT(DISTINCT group_id) FROM groups;")
nmoves=$(grep -c '^if ' "$WORK/moves.sh" || true)
echo "groups=$ngroups moves=$nmoves"

fail=0
chk() { if [ "$1" != "$2" ]; then echo "FAIL: $3 (expected $2, got $1)"; fail=1; fi; }

chk "$ngroups" 2 "group count"
chk "$nmoves"  4 "planned move count"
grep -q '/volume1/photo/_dedup/' "$WORK/moves.sh" || { echo "FAIL: dest not server-side"; fail=1; }
grep -q "sub a/img1 dup.jpg" "$WORK/moves.sh" || { echo "FAIL: spaced path missing"; fail=1; }

# Everything dundee wrote must be inside the work directory, and nothing at all
# inside the read-only library.
[ -f "$WORK/config.resolved.yml" ] || { echo "FAIL: no resolved snapshot"; fail=1; }
[ -d "$WORK/tmp" ] && [ -d "$WORK/staging" ] || { echo "FAIL: scratch not under work_dir"; fail=1; }
if [ -n "$(find "$FX" -newer "$WORK/config.yml" -print -quit 2>/dev/null)" ]; then
  echo "FAIL: library was written to"; fail=1
fi

# The store must refuse a changed fingerprint geometry.
sed -i.bak 's/^db_path:/fingerprint_grid: 16\ndb_path:/' "$WORK/config.yml"
if ./run.sh analyze "$WORK" --quiet 2>/dev/null; then
  echo "FAIL: grid change was not rejected"; fail=1
fi
mv "$WORK/config.yml.bak" "$WORK/config.yml"

if [ "$fail" -eq 0 ]; then echo "e2e: PASS"; else echo "e2e: FAIL"; exit 1; fi
