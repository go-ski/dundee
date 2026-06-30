#!/usr/bin/env bash
# Fingerprint a single photo. Reads the original across SMB exactly ONCE (copy
# to local temp), then derives every hash from the local copy. Appends one
# base64-safe TSV line to this process's staging file, or an error line on
# failure. Invoked by 20-fingerprint.sh via xargs; not meant to be run directly.
#
# Required env:
#   DD_TMP    local temp dir (fast local disk)
#   DD_STAGE  staging file prefix; this process appends to ${DD_STAGE}.$$.tsv/.err
#   DD_GRID   fingerprint grid side (e.g. 8 -> 8x8 dHash, 64 bits)
#   DD_ROOT   library root, used to compute the relative path
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

src="$1"
g="${DD_GRID:-8}"
stage="${DD_STAGE}.$$.tsv"
errf="${DD_STAGE}.$$.err"

b64src="$(dd_b64 "$src")"
rel="${src#"$DD_ROOT"/}"
b64rel="$(dd_b64 "$rel")"

fail() {
  printf '%s\t%s\n' "$b64src" "$(dd_b64 "$1")" >> "$errf"
  exit 0
}

work="$DD_TMP/$$"
T="$work.in"
PXV="$work.px.v"
PXR="$work.px.raw"
THV="$work.th.v"
GRV="$work.gr.v"
RAW="$work.raw"
trap 'rm -f "$T" "$PXV" "$PXR" "$THV" "$GRV" "$RAW"' EXIT

# --- the single SMB read ---
cp -- "$src" "$T" || fail "copy failed"

size="$(dd_size "$src")"
mtime="$(dd_mtime "$src")"
inode="$(dd_inode "$src")"

file_hash="$(dd_filehash "$T")" || fail "file hash failed"

width="$(vipsheader -f width "$T" 2>/dev/null)"  || fail "decode (vipsheader) failed"
height="$(vipsheader -f height "$T" 2>/dev/null)" || height=""
loader="$(vipsheader -f vips-loader "$T" 2>/dev/null)" || loader=""

# Decoded-pixel hash: normalise to 8-bit sRGB, hash the raw pixel stream.
pixel_hash=""
if vips colourspace "$T" "$PXV" srgb >/dev/null 2>&1 &&
   vips rawsave "$PXV" "$PXR" >/dev/null 2>&1; then
  pixel_hash="$(dd_filehash "$PXR")" || pixel_hash=""
fi

# Perceptual fingerprint: dHash on a (g+1)x g grayscale grid.
fingerprint=""
if vips thumbnail "$T" "$THV" $((g + 1)) --height "$g" --size force >/dev/null 2>&1 &&
   vips colourspace "$THV" "$GRV" b-w >/dev/null 2>&1 &&
   vips rawsave "$GRV" "$RAW" >/dev/null 2>&1; then
  fingerprint="$(od -An -v -tu1 "$RAW" | awk -v W=$((g + 1)) -v H="$g" '
    { for (i = 1; i <= NF; i++) v[n++] = $i }
    END {
      bits = ""
      for (r = 0; r < H; r++)
        for (c = 0; c < W - 1; c++) {
          idx = r * W + c
          bits = bits ((v[idx] > v[idx + 1]) ? "1" : "0")
        }
      hex = ""
      for (i = 0; i < length(bits); i += 4) {
        nib = substr(bits, i + 1, 4)
        while (length(nib) < 4) nib = nib "0"
        val = 0
        for (j = 1; j <= 4; j++) val = val * 2 + substr(nib, j, 1)
        hex = hex sprintf("%x", val)
      }
      print hex
    }')"
fi

# Metadata hash: hash the sorted embedded-metadata lines (excluding volatile
# filesystem fields); count is a cheap richness proxy for preference rules.
meta_lines="$(exiftool -s -s -s -All --File:all --ExifTool:all "$T" 2>/dev/null | sort)" || meta_lines=""
meta_hash="$(printf '%s' "$meta_lines" | dd_hash_stdin)"
meta_count="$(printf '%s' "$meta_lines" | grep -c . || true)"
capture="$(exiftool -s3 -DateTimeOriginal "$T" 2>/dev/null || true)"
camera="$(exiftool -s3 -Model "$T" 2>/dev/null || true)"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$b64src" "$b64rel" "$size" "$mtime" "$inode" "${loader:-}" \
  "${width:-}" "${height:-}" "$file_hash" "$pixel_hash" "$meta_hash" \
  "$fingerprint" "$(dd_b64 "$capture")" "$(dd_b64 "$camera")" "${meta_count:-0}" \
  >> "$stage"
