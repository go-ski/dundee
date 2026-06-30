#!/usr/bin/env bash
# End-to-end smoke test of the inventory -> analyze -> plan pipeline on the
# fixture library. Asserts the two expected exact groups are formed and that
# moves translate to server-side paths. Run from the repo root.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

FX="$(mktemp -d)/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$FX" "$WORK"' EXIT

bash tests/fixtures/make-fixtures.sh "$FX"

cfg="$WORK/config.yml"
cat > "$cfg" <<YML
library_root: $FX
work_dir: $WORK
db_path: e2e.sqlite
nas_root: /volume1/photo
preferred_root: /volume1/photo/_dedup/preferred
nonpreferred_root: /volume1/photo/_dedup/non-preferred
ssh_user: tester
ssh_host: nas.local
YML

bash inst/bin/10-enumerate.sh "$FX" "$WORK/enum.tsv"
Rscript inst/bin/25-resume.R "$WORK/enum.tsv" "$WORK/todo.nul" "$cfg"
bash inst/bin/20-fingerprint.sh "$WORK/todo.nul" "$WORK/staging" "$WORK/tmp" "$FX" 4 8
Rscript inst/bin/30-merge.R "$cfg"
Rscript inst/bin/40-analyze.R "$cfg"
Rscript inst/bin/60-plan-moves.R "$cfg" --bulk

# --- assertions ---
ngroups=$(sqlite3 "$WORK/e2e.sqlite" "SELECT COUNT(DISTINCT group_id) FROM groups;")
nmoves=$(grep -c '^if ' "$WORK/moves.sh" || true)
echo "groups=$ngroups moves=$nmoves"

fail=0
[ "$ngroups" -eq 2 ] || { echo "FAIL: expected 2 groups, got $ngroups"; fail=1; }
[ "$nmoves" -eq 4 ] || { echo "FAIL: expected 4 planned moves, got $nmoves"; fail=1; }
grep -q '/volume1/photo/_dedup/' "$WORK/moves.sh" || { echo "FAIL: dest not server-side"; fail=1; }
grep -q "sub a/img1 dup.jpg" "$WORK/moves.sh" || { echo "FAIL: spaced path missing"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "e2e: PASS"; else echo "e2e: FAIL"; exit 1; fi
