#!/usr/bin/env bash
# End-to-end smoke test of inventory -> analyze -> plan on the fixture library.
# Drives the package entry points (dd_run_*) through exec/dundee rather than the
# individual stage scripts. Run from the repo root.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

TOP="$(mktemp -d)"
FX="$TOP/lib"
WORK="$TOP/work"          # sibling of the library, never nested inside it
LIB="$TOP/lib-R"
trap 'rm -rf "$TOP"' EXIT

# Install to a throwaway library and run against that, the way R CMD check does.
# exec/dundee prefers an installed dundee over the surrounding source tree, so
# without this the run would silently exercise whatever was installed last.
mkdir -p "$LIB"
R CMD INSTALL --library="$LIB" "$root" >/dev/null
export R_LIBS="$LIB"

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

# Keep inventory's stderr: the fingerprint workers write there, and a photo
# with non-UTF-8 EXIF used to make their `sort` abort noisily.
inv_err="$TOP/inventory.err"
./exec/dundee inventory "$WORK" --quiet 2>"$inv_err"
cat "$inv_err" >&2
./exec/dundee analyze   "$WORK" --quiet
./exec/dundee plan      "$WORK" --bulk --quiet
./exec/dundee status    "$WORK"

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

# Non-UTF-8 bytes in an EXIF tag must not derail the metadata hash. The worker
# sorts exiftool's output before hashing it, and under a UTF-8 locale that sort
# aborted on such bytes, storing the photo with meta_count 0 -- which inverts
# the max_meta preference rule.
if grep -q 'Illegal byte sequence' "$inv_err"; then
  echo "FAIL: sort choked on non-UTF-8 metadata"; fail=1
fi
mc=$(sqlite3 "$db" "SELECT COALESCE(meta_count, -1) FROM photos
                     WHERE rel_path = 'latin1-exif.jpg';")
if [ -z "$mc" ] || [ "$mc" -le 0 ]; then
  echo "FAIL: latin1-exif.jpg metadata not counted (meta_count=${mc:-<no row>})"
  fail=1
fi

# Everything dundee wrote must be inside the work directory, and nothing at all
# inside the read-only library.
[ -f "$WORK/config.resolved.yml" ] || { echo "FAIL: no resolved snapshot"; fail=1; }
[ -d "$WORK/tmp" ] && [ -d "$WORK/staging" ] || { echo "FAIL: scratch not under work_dir"; fail=1; }
if [ -n "$(find "$FX" -newer "$WORK/config.yml" -print -quit 2>/dev/null)" ]; then
  echo "FAIL: library was written to"; fail=1
fi

# An edit to config.yml must be noticed, attributed to the stage it invalidates,
# and turned into the right next step. The values are read from the package
# rather than written here: a literal becomes the default sooner or later, and
# then the "edit" edits nothing and every assertion below quietly stops testing.
def_thr="$(Rscript -e 'cat(dundee::dd_config_defaults()$hamming_threshold)')"
new_thr="$((def_thr + 4))"
sed -i.bak "s/^db_path:/hamming_threshold: ${new_thr}\ndb_path:/" "$WORK/config.yml"
drift="$(./exec/dundee status "$WORK" 2>&1)"
grep -q 'config changed since analyze ran' <<<"$drift" ||
  { echo "FAIL: config drift not reported"; fail=1; }
grep -q "hamming_threshold: ${def_thr} -> ${new_thr}" <<<"$drift" ||
  { echo "FAIL: drift did not name the change"; fail=1; }
grep -q 'next: dd_run_analyze()' <<<"$drift" ||
  { echo "FAIL: drift did not redirect the next step"; fail=1; }
mv "$WORK/config.yml.bak" "$WORK/config.yml"

# The store must refuse a changed fingerprint geometry. lsh_bands must divide
# grid^2 (R/project.R), and the default 16 divides both 16^2 and 8^2, so
# flipping between them stays a valid config -- which is the point: the store
# has to reject it on geometry, not on validation.
def_grid="$(Rscript -e 'cat(dundee::dd_config_defaults()$fingerprint_grid)')"
if [[ "$def_grid" -eq 8 ]]; then new_grid=16; else new_grid=8; fi
sed -i.bak "s/^db_path:/fingerprint_grid: ${new_grid}\ndb_path:/" "$WORK/config.yml"
if ./exec/dundee analyze "$WORK" --quiet 2>/dev/null; then
  echo "FAIL: grid change was not rejected"; fail=1
fi
mv "$WORK/config.yml.bak" "$WORK/config.yml"

if [ "$fail" -eq 0 ]; then echo "e2e: PASS"; else echo "e2e: FAIL"; exit 1; fi
