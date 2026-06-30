# Load dundee: use the installed package if present, otherwise source R/ from
# the package source tree (so scripts work before `R CMD INSTALL`). Expects the
# caller to have defined `here` (the directory of the running script).
if (requireNamespace("dundee", quietly = TRUE)) {
  library(dundee)
} else {
  pkg_root <- normalizePath(file.path(here, "..", ".."))
  suppressPackageStartupMessages({
    library(DBI); library(RSQLite); library(base64enc); library(yaml)
  })
  for (f in list.files(file.path(pkg_root, "R"), pattern = "\\.R$",
                       full.names = TRUE)) {
    source(f)
  }
}
