#!/usr/bin/env Rscript
# Plan Phase 3 moves: optionally apply bulk decisions for any undecided groups,
# then emit a manifest + reviewable shell script (dry-run; writes nothing on the
# server). Usage: Rscript 60-plan-moves.R [config.yml] [--bulk]
args0 <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", args0[grep("^--file=", args0)])))
source(file.path(here, "_boot.R"))

args <- commandArgs(trailingOnly = TRUE)
do_bulk <- "--bulk" %in% args
cfg_arg <- args[!args %in% "--bulk"]
cfg <- dd_config(if (length(cfg_arg) >= 1) cfg_arg[[1]] else "config.yml")

con <- dd_db_connect(cfg)
dd_db_init(con)
if (do_bulk) {
  n <- dd_apply_bulk_decisions(con, cfg)
  message(sprintf("applied bulk decisions to %d undecided photos", n))
}
dd_plan_moves(con, cfg)
DBI::dbDisconnect(con)
