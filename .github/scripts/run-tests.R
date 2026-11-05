# Run the testthat suite against the rattlerthis that `R CMD check` installed
# into <check dir>/rattlerthis.Rcheck, and fail unless there is no failure,
# no error and exactly the expected number of skips: the 2 tests of
# test-wheel.R, which skip because the `wheels` Cargo feature is off. Any
# other skip is a test that did not run, so it fails the job too.
#
# usage (from the package root): Rscript .github/scripts/run-tests.R <check dir> [expected skips]
`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
check_dir <- if (length(args) >= 1L) args[[1L]] else "check"
expected_skips <- if (length(args) >= 2L) as.integer(args[[2L]]) else 2L

lib <- Sys.glob(file.path(check_dir, "*.Rcheck"))
if (
  isFALSE(identical(length(lib), 1L)) ||
    isFALSE(dir.exists(file.path(lib, "rattlerthis")))
) {
  stop(
    "No installed rattlerthis under ",
    check_dir,
    "/*.Rcheck.",
    call. = FALSE
  )
}
.libPaths(c(normalizePath(lib, winslash = "/"), .libPaths()))
# Child R processes (callr, Rscript) must find the same packages.
Sys.setenv(
  NOT_CRAN = "true",
  R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)
)

cat(
  "rattlerthis",
  format(utils::packageVersion("rattlerthis")),
  "from",
  find.package("rattlerthis"),
  "\n"
)
cat(
  "condathis",
  format(utils::packageVersion("condathis")),
  "from",
  find.package("condathis"),
  "\n"
)
cat(
  "CONDATHIS_MICROMAMBA_PATH:",
  Sys.getenv("CONDATHIS_MICROMAMBA_PATH"),
  "\n\n"
)

# Every failure in full, not only the first 10. The reporter is kept: it
# also sees what happens outside `test_that()` (a skip or a failed
# expectation at the top of a test file), which the returned results drop.
reporter <- testthat::SummaryReporter$new(
  show_praise = FALSE,
  max_reports = Inf
)
res <- testthat::test_local(
  ".",
  reporter = reporter,
  load_package = "installed",
  stop_on_failure = FALSE,
  stop_on_warning = FALSE
)
df <- as.data.frame(res)
df$error <- as.integer(df$error)
df$skipped <- as.integer(df$skipped)

by_file <- stats::aggregate(
  cbind(nb, failed, error, skipped) ~ file,
  data = df,
  FUN = sum
)
cat("\n")
print(by_file, row.names = FALSE)

skips <- vapply(
  reporter$skips$as_list(),
  function(skip) {
    test <- skip$test %||% "(outside test_that())"
    return(sprintf("%s: %s", test, conditionMessage(skip)))
  },
  character(1L)
)
if (isTRUE(length(skips) > 0L)) {
  cat("\nSkipped:\n", paste0("  ", skips, "\n"), sep = "")
}

# Failures and errors, and skips, as the results count them, or as the
# reporter saw them where it saw more (the top level of a file).
n_broken_results <- sum(df$failed) + sum(df$error)
n_broken <- max(n_broken_results, reporter$failures$size())
n_skipped <- max(sum(df$skipped), reporter$skips$size())
cat(
  "\nTOTAL expectations:",
  sum(df$nb),
  " failed:",
  sum(df$failed),
  " errors:",
  sum(df$error),
  " outside tests:",
  n_broken - n_broken_results,
  " skipped:",
  n_skipped,
  " (expected ",
  expected_skips,
  ")\n",
  sep = ""
)

if (
  isTRUE(n_broken > 0L) ||
    isFALSE(identical(as.integer(n_skipped), as.integer(expected_skips)))
) {
  cat(
    "Test run failed: needs 0 failures, 0 errors and exactly ",
    expected_skips,
    " skips.\n",
    sep = ""
  )
  quit(save = "no", status = 1L)
}
