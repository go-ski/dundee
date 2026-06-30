#!/usr/bin/env Rscript
# Build the resume-filtered NUL todo list from an enumeration TSV.
# Usage: Rscript 25-resume.R ENUM_TSV TODO_NUL [config.yml]
args0 <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", args0[grep("^--file=", args0)])))
source(file.path(here, "_boot.R"))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: 25-resume.R ENUM_TSV TODO_NUL [config.yml]")
enum_tsv <- args[[1]]; todo_nul <- args[[2]]
cfg <- dd_config(if (length(args) >= 3) args[[3]] else "config.yml")

con <- dd_db_connect(cfg)
dd_db_init(con)
n <- dd_resume_todo(con, enum_tsv, todo_nul)
DBI::dbDisconnect(con)
message(sprintf("resume: %d file(s) to fingerprint -> %s", n, todo_nul))
