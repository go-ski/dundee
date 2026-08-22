#!/usr/bin/env bash
# End-to-end smoke test of inventory -> analyze -> plan -> move on the fixture
# library.
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
preferred_root: $FX/_dedup/preferred
nonpreferred_root: $FX/_dedup/non-preferred
cruft: ['@eaDir', .DS_Store, _dedup]
YML

# Keep inventory's stderr: the fingerprint workers write there, and a photo with
# non-UTF-8 EXIF is what makes their `sort` abort noisily if it regresses.
inv_err="$TOP/inventory.err"
./exec/dundee inventory "$WORK" --quiet 2>"$inv_err"
cat "$inv_err" >&2
./exec/dundee analyze   "$WORK" --quiet
# dd_run_folders() prints through message(), and this is the only place its
# formatting runs at all -- R CMD check never reaches the CLI.
./exec/dundee folders   "$WORK" > "$TOP/folders.out" 2>&1
./exec/dundee folders   "$WORK" --depth=2 --effect >> "$TOP/folders.out" 2>&1
./exec/dundee plan      "$WORK" --bulk --quiet
./exec/dundee status    "$WORK"

# --- assertions ---
db="$WORK/e2e.sqlite"
ngroups=$(sqlite3 "$db" "SELECT COUNT(DISTINCT group_id) FROM groups;")
nmoves=$(grep -cE '^move_(non)?preferred +[0-9]' "$WORK/moves.sh" || true)
echo "groups=$ngroups moves=$nmoves"

fail=0
chk() { if [ "$1" != "$2" ]; then echo "FAIL: $3 (expected $2, got $1)"; fail=1; fi; }

chk "$ngroups" 2 "group count"
chk "$nmoves"  4 "planned move count"
grep -q "$FX/_dedup/" "$WORK/moves.sh" || { echo "FAIL: dest not under the library"; fail=1; }
grep -q "sub a/img1 dup.jpg" "$WORK/moves.sh" || { echo "FAIL: spaced path missing"; fail=1; }

# One fixture group straddles the library root and "sub a"; the other is two
# copies at the root. Both rows must appear, and the root-only one must span a
# single directory -- the case folder_priority cannot decide.
grep -q '(root) + sub a' "$TOP/folders.out" ||
  { echo "FAIL: folders did not report the root/sub a pattern"; fail=1; }
grep -qE '^ +1 +2 +1 +\(root\)$' "$TOP/folders.out" ||
  { echo "FAIL: folders miscounted the root-only pattern"; cat "$TOP/folders.out"; fail=1; }
grep -q 'span one directory' "$TOP/folders.out" ||
  { echo "FAIL: folders did not flag the undecidable pattern"; fail=1; }
# With folder_priority unset, --effect must say so rather than print zeros.
grep -q 'audit needs folder_priority' "$TOP/folders.out" ||
  { echo "FAIL: --effect did not report an unset folder_priority"; fail=1; }

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

# --- phase 3 for real -------------------------------------------------------
# dundee executes nothing, so this runs the script the way a user would. It has
# to come after the "library was written to" check above: the
# library IS written to here, by this script, which is exactly the distinction
# that assertion exists to draw.
# Both tiers are represented (2 groups, one winner each), which is what makes
# the default -- move the rejects, leave the winners -- worth testing here.
nnon=$(grep -c '^move_nonpreferred ' "$WORK/moves.sh" || true)
npref=$(grep -c '^move_preferred ' "$WORK/moves.sh" || true)
chk "$((nnon + npref))" "$nmoves" "tiered rows cover the plan"
[ "$nnon" -gt 0 ] && [ "$npref" -gt 0 ] ||
  { echo "FAIL: fixture does not exercise both tiers"; fail=1; }

"$WORK/moves.sh" --dry-run > "$TOP/dry.out" 2>&1 ||
  { echo "FAIL: dry run exited non-zero"; cat "$TOP/dry.out"; fail=1; }
grep -q "DRY RUN" "$TOP/dry.out" || { echo "FAIL: dry run not announced"; fail=1; }
grep -q "^${nnon} to move" "$TOP/dry.out" ||
  { echo "FAIL: dry run miscounted"; cat "$TOP/dry.out"; fail=1; }
[ -e "$FX/_dedup" ] && { echo "FAIL: dry run created the destination"; fail=1; }

# Default run: the rejects leave, the winners stay exactly where they were.
"$WORK/moves.sh" > "$TOP/move.out" 2>&1 ||
  { echo "FAIL: move script exited non-zero"; cat "$TOP/move.out"; fail=1; }
grep -q "^${nnon} moved" "$TOP/move.out" ||
  { echo "FAIL: move miscounted"; cat "$TOP/move.out"; fail=1; }
grep -q "^${npref} preferred copy(ies) left in place" "$TOP/move.out" ||
  { echo "FAIL: kept count not reported"; cat "$TOP/move.out"; fail=1; }
[ -d "$FX/_dedup/preferred" ] &&
  { echo "FAIL: default run touched the preferred copies"; fail=1; }
[ -f "$WORK/moves.done.tsv" ] || { echo "FAIL: no receipt written"; fail=1; }
nreceipt=$(wc -l < "$WORK/moves.done.tsv" | tr -d ' ')
chk "$nreceipt" "$nnon" "receipt row count"
chk "$(wc -l < "$WORK/moves.kept.tsv" | tr -d ' ')" "$npref" "kept row count"
nleft=$(sqlite3 "$db" "SELECT COUNT(*) FROM moves WHERE state = 'planned';")

# Reconcile: dundee reads the receipts and checks the library, writing to
# neither.
./exec/dundee move "$WORK" --quiet > "$TOP/recon.out" 2>&1 ||
  { echo "FAIL: move reconcile failed"; cat "$TOP/recon.out"; fail=1; }
chk "$nleft" "$nmoves" "planned before reconcile"
chk "$(sqlite3 "$db" "SELECT COUNT(*) FROM moves WHERE state = 'done';")" \
    "$nnon"  "moves marked done"
chk "$(sqlite3 "$db" "SELECT COUNT(*) FROM moves WHERE state = 'kept';")" \
    "$npref" "winners marked kept"
chk "$(sqlite3 "$db" "SELECT COUNT(*) FROM moves WHERE state = 'planned';")" \
    0        "moves left planned"
# dd_status() reports through message(), so stderr is where it lands.
./exec/dundee status "$WORK" 2>&1 | grep -q "next: nothing" ||
  { echo "FAIL: status still recommends work"; fail=1; }

# kept must not be a dead end: relocating the winners later resolves them.
"$WORK/moves.sh" --include-preferred > "$TOP/move2.out" 2>&1 ||
  { echo "FAIL: --include-preferred exited non-zero"; cat "$TOP/move2.out"; fail=1; }
./exec/dundee move "$WORK" --quiet > "$TOP/recon2.out" 2>&1 ||
  { echo "FAIL: second reconcile failed"; cat "$TOP/recon2.out"; fail=1; }
chk "$(sqlite3 "$db" "SELECT COUNT(*) FROM moves WHERE state = 'done';")" \
    "$nmoves" "all moves done after --include-preferred"
chk "$(sqlite3 "$db" "SELECT COUNT(*) FROM moves WHERE state = 'kept';")" \
    0         "no kept rows left"
# The spaced path is the one most likely to have been split by the shell. Its
# tier is whatever the preference rules chose, so check it only now that both
# have run.
[ -f "$FX/_dedup/preferred/sub a/img1 dup.jpg" ] ||
  [ -f "$FX/_dedup/non-preferred/sub a/img1 dup.jpg" ] ||
  { echo "FAIL: spaced path did not land"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "e2e: PASS"; else echo "e2e: FAIL"; exit 1; fi
