#!/usr/bin/env Rscript
# Launch the Shiny review app. Usage: Rscript 50-app.R [config.yml] [port]
args0 <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", args0[grep("^--file=", args0)])))
source(file.path(here, "_boot.R"))

args <- commandArgs(trailingOnly = TRUE)
cfg_path <- if (length(args) >= 1) args[[1]] else "config.yml"
port <- if (length(args) >= 2) as.integer(args[[2]]) else 7654L

app_dir <- system.file("shiny", package = "dundee")
if (!nzchar(app_dir)) app_dir <- file.path("inst", "shiny")  # dev fallback

Sys.setenv(DUNDEE_CONFIG = cfg_path)
shiny::runApp(app_dir, port = port, launch.browser = TRUE)
