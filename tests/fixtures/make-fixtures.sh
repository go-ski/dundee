#!/usr/bin/env bash
# Build a tiny fixture photo library exercising every duplicate relationship:
#   img1.jpg            base lossy image
#   sub a/img1 dup.jpg  byte-identical copy (filename with spaces)
#   img1_copy.png       lossless copy of the source pixels (different container)
#   img1_copy.tif       second lossless copy (same decoded pixels as the png)
#   img2.jpg            a distinct image
#   @eaDir/...          Synology cruft that must be ignored
#
# Usage: make-fixtures.sh OUTDIR
set -euo pipefail
out="${1:?output dir required}"
rm -rf "$out"
mkdir -p "$out/sub a" "$out/@eaDir"

vips gaussnoise "$out/_s1.v" 96 72 >/dev/null 2>&1
vips copy "$out/_s1.v" "$out/img1.jpg"      >/dev/null 2>&1
vips copy "$out/_s1.v" "$out/img1_copy.png" >/dev/null 2>&1
vips copy "$out/img1_copy.png" "$out/img1_copy.tif" >/dev/null 2>&1
cp "$out/img1.jpg" "$out/sub a/img1 dup.jpg"

vips gaussnoise "$out/_s2.v" 96 72 >/dev/null 2>&1
vips copy "$out/_s2.v" "$out/img2.jpg" >/dev/null 2>&1

echo "synology thumb cruft" > "$out/@eaDir/SYNOPHOTO_THUMB.jpg"
rm -f "$out"/_s*.v
echo "fixtures created in $out"
