#!/usr/bin/env Rscript
# Merge sharded staging files into the SQLite store (idempotent upsert).
# Usage: Rscript 30-merge.R [config.yml]
args0 <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", args0[grep("^--file=", args0)])))
source(file.path(here, "_boot.R"))

args <- commandArgs(trailingOnly = TRUE)
cfg <- dd_config(if (length(args) >= 1) args[[1]] else "config.yml")

con <- dd_db_connect(cfg)
dd_db_init(con)
res <- dd_import_staging(con, cfg)
DBI::dbDisconnect(con)
message(sprintf("merged: %d photo rows, %d error rows", res$photos, res$errors))
