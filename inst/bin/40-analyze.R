#!/usr/bin/env Rscript
# Build exact + near duplicate groups and write the `groups` table.
# Usage: Rscript 40-analyze.R [config.yml]
args0 <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", args0[grep("^--file=", args0)])))
source(file.path(here, "_boot.R"))

args <- commandArgs(trailingOnly = TRUE)
cfg <- dd_config(if (length(args) >= 1) args[[1]] else "config.yml")

con <- dd_db_connect(cfg)
dd_db_init(con)
out <- dd_analyze(con, cfg)
ngroups <- if (nrow(out)) length(unique(out$group_id)) else 0L
DBI::dbDisconnect(con)
message(sprintf("analyze: %d groups covering %d photos", ngroups, nrow(out)))
