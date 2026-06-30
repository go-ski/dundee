#!/usr/bin/env bash
# dundee top-level orchestrator. Drives the three phases via the stage scripts.
#
# Usage:
#   ./run.sh preflight
#   ./run.sh inventory [config.yml]   # enumerate -> resume -> fingerprint -> merge
#   ./run.sh analyze   [config.yml]
#   ./run.sh app       [config.yml] [port]
#   ./run.sh plan      [config.yml] [--bulk]
#   ./run.sh move      [config.yml] [--execute]
#
# Config values are read with a tiny yaml shim (yq not required): we ask R for
# the resolved paths so shell and R agree on work_dir/db_path/etc.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/inst/bin"

cmd="${1:-help}"; shift || true

# Resolve a single config field via R (keeps one source of truth).
cfg_get() {
  local field="$1" cfgpath="$2"
  Rscript -e "here <- '$bin'; source(file.path(here, '_boot.R'));
    c <- dd_config('$cfgpath', require_library = FALSE); cat(c[['$field']])"
}

case "$cmd" in
  preflight)
    bash "$bin/00-preflight.sh"
    ;;

  inventory)
    cfgpath="${1:-config.yml}"
    root="$(cfg_get library_root "$cfgpath")"
    work="$(cfg_get work_dir "$cfgpath")"
    staging="$(cfg_get staging_dir "$cfgpath")"
    tmp="$(cfg_get temp_dir "$cfgpath")"
    par="$(cfg_get parallel "$cfgpath")"
    grid="$(cfg_get fingerprint_grid "$cfgpath")"
    mkdir -p "$work"
    enum="$work/enum.tsv"; todo="$work/todo.nul"
    bash "$bin/10-enumerate.sh" "$root" "$enum"
    Rscript "$bin/25-resume.R" "$enum" "$todo" "$cfgpath"
    bash "$bin/20-fingerprint.sh" "$todo" "$staging" "$tmp" "$root" "$par" "$grid"
    Rscript "$bin/30-merge.R" "$cfgpath"
    ;;

  analyze)
    Rscript "$bin/40-analyze.R" "${1:-config.yml}"
    ;;

  app)
    Rscript "$bin/50-app.R" "${1:-config.yml}" "${2:-7654}"
    ;;

  plan)
    Rscript "$bin/60-plan-moves.R" "$@"
    ;;

  move)
    cfgpath="${1:-config.yml}"
    mode="${2:-}"
    work="$(cfg_get work_dir "$cfgpath")"
    user="$(cfg_get ssh_user "$cfgpath")"
    host="$(cfg_get ssh_host "$cfgpath")"
    bash "$bin/70-execute-moves.sh" "$work/moves.sh" "${user}@${host}" "$mode"
    ;;

  *)
    sed -n '2,12p' "$0"
    ;;
esac
