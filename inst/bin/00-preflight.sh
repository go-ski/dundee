#!/usr/bin/env bash
# Verify the external tools dundee needs are present and capable.
# Exits non-zero (listing what is missing) so pipelines fail fast.
set -euo pipefail

missing=0
need() {
  if command -v "$1" >/dev/null 2>&1; then
    printf 'ok   %-14s %s\n' "$1" "$(command -v "$1")"
  else
    printf 'MISS %-14s %s\n' "$1" "${2:-}"
    missing=1
  fi
}

echo "== required tools =="
need vips          "install libvips (brew install vips)"
need vipsheader    "part of libvips"
need vipsthumbnail "part of libvips"
need exiftool      "brew install exiftool"
need sqlite3       "ships with macOS"
need ssh           "needed for Phase 3 server-side moves"
need od            "coreutils / ships with macOS"
need awk
need find
need xargs
need base64

echo "== hashing tool (need one) =="
if command -v b3sum >/dev/null 2>&1; then
  printf 'ok   %-14s %s\n' b3sum "$(command -v b3sum)"
  echo "HASHER=b3sum"
elif command -v shasum >/dev/null 2>&1; then
  printf 'ok   %-14s %s (fallback)\n' shasum "$(command -v shasum)"
  echo "HASHER=shasum"
else
  echo "MISS b3sum/shasum   need one of them"
  missing=1
fi

echo "== stat flavor =="
if stat --version >/dev/null 2>&1; then
  echo "STAT=gnu"
else
  echo "STAT=bsd (macOS default; using stat -f)"
fi

echo "== vips format support =="
# Note: do NOT pipe into `grep -q` here. Under `set -o pipefail`, grep -q exits
# on the first match and SIGPIPEs the upstream `vips`, making the pipeline report
# failure (a false negative). Read to EOF instead. Prefer the authoritative
# config line, falling back to the loader listing.
heif_config="$(vips --vips-config 2>/dev/null | tr ',' '\n' | grep -i heif || true)"
if printf '%s' "$heif_config" | grep -i 'libheif: *true' >/dev/null; then
  echo "ok   HEIC/HEIF support present ($(printf '%s' "$heif_config" | sed 's/^ *//'))"
elif vips -l 2>/dev/null | grep -i heifload >/dev/null; then
  echo "ok   HEIC/HEIF loader present (heifload)"
else
  echo "warn HEIC/HEIF support not detected; 'brew install vips libheif' if needed"
fi

if [ "$missing" -ne 0 ]; then
  echo "preflight: missing required tools (see MISS above)" >&2
  exit 1
fi
echo "preflight: OK"
