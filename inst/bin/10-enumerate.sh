#!/usr/bin/env bash
# Enumerate inventory candidates under the library root, pruning cruft and
# filtering by extension. Emits a newline-delimited TSV (base64 path is line
# safe for any filename):
#   b64path <TAB> size <TAB> mtime <TAB> inode
#
# Usage: 10-enumerate.sh LIBRARY_ROOT OUT_TSV [ext1 ext2 ...]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

root="${1:?library root required}"
out="${2:?output tsv required}"
shift 2
exts=("$@")
if [ "${#exts[@]}" -eq 0 ]; then
  exts=(jpg jpeg jpe png gif bmp tif tiff webp heic heif avif \
        cr2 cr3 nef nrw arw sr2 srf raf rw2 orf dng pef raw x3f 3fr erf \
        kdc mef mos iiq)
fi

# Build the cruft prune expression.
cruft=(@eaDir '#recycle' '#snapshot' @tmp .@__thumb @sharebin .DS_Store \
       Thumbs.db .Spotlight-V100 .TemporaryItems .Trashes .fseventsd)
prune=()
for c in "${cruft[@]}"; do prune+=(-name "$c" -o); done
unset 'prune[${#prune[@]}-1]'   # drop trailing -o

# Build the extension match expression (case-insensitive).
extmatch=()
for e in "${exts[@]}"; do extmatch+=(-iname "*.${e}" -o); done
unset 'extmatch[${#extmatch[@]}-1]'

: > "$out"
# Prune cruft dirs, then match files by extension; NUL-delimited for safety.
find "$root" \( "${prune[@]}" \) -prune -o \
     -type f \( "${extmatch[@]}" \) -print0 |
while IFS= read -r -d '' f; do
  printf '%s\t%s\t%s\t%s\n' \
    "$(dd_b64 "$f")" "$(dd_size "$f")" "$(dd_mtime "$f")" "$(dd_inode "$f")"
done >> "$out"

echo "enumerated $(wc -l < "$out") files -> $out"
