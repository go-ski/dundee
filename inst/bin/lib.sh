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

# Render progress from a stream of completion ticks on stdin (one line each).
# The ticks are consumed (not re-emitted). Args: TOTAL [LABEL]. Writes to
# stderr; animates with a carriage return only when stderr is a terminal,
# otherwise prints a milestone line at each ~10% boundary. Disabled (drains
# stdin silently) when DD_PROGRESS=0.
dd_progress_counter() {
  local total="${1:-0}" label="${2:-progress}" n=0 last=-1 pct step
  if [ "${DD_PROGRESS:-1}" = "0" ]; then cat >/dev/null; return 0; fi
  while IFS= read -r _; do
    n=$((n + 1))
    if [ "$total" -gt 0 ]; then pct=$((100 * n / total)); else pct=0; fi
    if [ -t 2 ]; then
      printf '\r   %s: %d/%d (%d%%)   ' "$label" "$n" "$total" "$pct" >&2
    else
      step=$(((pct / 10) * 10))
      if [ "$step" -gt "$last" ] && [ "$step" -ge 10 ]; then
        last=$step
        printf '   %s: %d%% (%d/%d)\n' "$label" "$step" "$n" "$total" >&2
      fi
    fi
  done
  if [ -t 2 ]; then
    printf '\r   %s: %d/%d (100%%)\n' "$label" "$n" "$total" >&2
  fi
}

# Running count for a stream of unknown total. Passes every line through
# unchanged on stdout while emitting a running count to stderr every EVERY
# lines. Args: [LABEL] [EVERY]. Progress suppressed when DD_PROGRESS=0.
dd_progress_spin() {
  local label="${1:-progress}" every="${2:-500}" n=0 quiet=0
  [ "${DD_PROGRESS:-1}" = "0" ] && quiet=1
  while IFS= read -r line; do
    printf '%s\n' "$line"
    n=$((n + 1))
    if [ "$quiet" -eq 0 ] && [ $((n % every)) -eq 0 ]; then
      if [ -t 2 ]; then
        printf '\r   %s: %d' "$label" "$n" >&2
      else
        printf '   %s: %d\n' "$label" "$n" >&2
      fi
    fi
  done
  if [ "$quiet" -eq 0 ] && [ -t 2 ]; then
    printf '\r   %s: %d\n' "$label" "$n" >&2
  fi
}
