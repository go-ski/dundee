#!/usr/bin/env Rscript
# Run the test suite without installing the package (sources R/ directly).
# Usage: Rscript dev-test.R
suppressPackageStartupMessages({
  library(testthat); library(DBI); library(RSQLite)
  library(base64enc); library(yaml)
})
for (f in list.files("R", full.names = TRUE)) source(f)
res <- test_dir("tests/testthat", reporter = "summary", stop_on_failure = TRUE)
