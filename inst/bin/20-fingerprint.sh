#!/usr/bin/env bash
# Driver: fan out the per-file fingerprint worker across N parallel processes.
# Input is a NUL-delimited list of source paths (the resume-filtered todo list).
#
# Usage: 20-fingerprint.sh TODO_NUL STAGING_DIR TEMP_DIR LIBRARY_ROOT \
#                          [PARALLEL] [GRID]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

todo="${1:?todo NUL file required}"
stagedir="${2:?staging dir required}"
tmpdir="${3:?temp dir required}"
root="${4:?library root required}"
par="${5:-4}"
grid="${6:-8}"
total="${7:-0}"

mkdir -p "$stagedir" "$tmpdir"

export DD_TMP="$tmpdir"
export DD_STAGE="$stagedir/shard"
export DD_GRID="$grid"
export DD_ROOT="${root%/}"

# Each xargs child process owns a stable $$ and appends to its own shard files,
# so there is no cross-process interleaving of staging lines. Each child emits
# one completion tick; dd_progress_counter turns those into a live N/TOTAL.
xargs -0 -P "$par" -n 1 "$here/_fingerprint-one.sh" < "$todo" \
  | dd_progress_counter "$total" "fingerprint"

echo "fingerprinting complete; staging files in $stagedir"
