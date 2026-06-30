#!/usr/bin/env bash
# Execute the planned moves SERVER-SIDE over SSH (renames stay on-volume; no
# bytes traverse SMB). Dry-run by default: prints what would run. Pass --execute
# to actually perform the moves. Idempotent/resumable via `mv -n` and the
# `[ -e source ]` guards baked into the generated script.
#
# Usage: 70-execute-moves.sh SCRIPT_SH SSH_TARGET [--execute]
#   SCRIPT_SH   path to the moves.sh produced by 60-plan-moves.R
#   SSH_TARGET  e.g. admin@synology.local
set -euo pipefail

script="${1:?moves script required}"
target="${2:?ssh target (user@host) required}"
mode="${3:-}"

if [ ! -f "$script" ]; then
  echo "move script not found: $script" >&2
  exit 1
fi

if [ "$mode" != "--execute" ]; then
  echo "DRY RUN. Would stream the following script to: ssh $target bash -s"
  echo "Pass --execute as the third argument to perform the moves."
  echo "---- $script ($(grep -c '^if ' "$script") move commands) ----"
  head -n 20 "$script"
  echo "..."
  exit 0
fi

echo "executing moves server-side on $target ..."
ssh "$target" 'bash -s' < "$script"
echo "server-side moves complete."
