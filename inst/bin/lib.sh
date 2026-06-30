# Shared shell helpers for dundee scripts. Sourced, not executed.

# Portable file size: bytes. Args: path. Echoes integer.
dd_size() {
  if stat --version >/dev/null 2>&1; then
    stat -c %s -- "$1"
  else
    stat -f %z -- "$1"
  fi
}

# Portable mtime (epoch seconds).
dd_mtime() {
  if stat --version >/dev/null 2>&1; then
    stat -c %Y -- "$1"
  else
    stat -f %m -- "$1"
  fi
}

# Portable inode.
dd_inode() {
  if stat --version >/dev/null 2>&1; then
    stat -c %i -- "$1"
  else
    stat -f %i -- "$1"
  fi
}

# base64-encode a string to a single line (no newlines).
dd_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

# Whole-file content hash, printing just the hex digest.
# Uses b3sum if available, else shasum -a 256.
dd_filehash() {
  if command -v b3sum >/dev/null 2>&1; then
    b3sum --no-names -- "$1"
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

# Hash from stdin, hex digest only.
dd_hash_stdin() {
  if command -v b3sum >/dev/null 2>&1; then
    b3sum --no-names
  else
    shasum -a 256 | awk '{print $1}'
  fi
}
