#!/usr/bin/env bash
# Thin wrapper: all logic lives in the R package. Uses the installed dundee if
# present, otherwise load_all()s this source tree.
set -euo pipefail
export DUNDEE_SRC="$(cd "$(dirname "$0")" && pwd)"
exec Rscript -e '
  if (requireNamespace("dundee", quietly = TRUE)) {
    library(dundee)
  } else if (requireNamespace("pkgload", quietly = TRUE)) {
    pkgload::load_all(Sys.getenv("DUNDEE_SRC"), quiet = TRUE)
  } else {
    stop("Install dundee (devtools::install()) or the pkgload package.")
  }
  dd_cli(commandArgs(trailingOnly = TRUE))
' "$@"
