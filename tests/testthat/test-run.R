test_that("run() executes the installed binary from the activated environment", {
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  create_env(packages = "xz", env_name = "rt-test-run", verbose = "silent")

  res <- run("xz", "--version", env_name = "rt-test-run", verbose = "silent")

  expect_identical(res$status, 0L)
  expect_match(res$stdout, "xz", fixed = TRUE)
})

test_that("run() errors when the environment does not exist", {
  skip_on_cran()
  local_rattlerthis_root()
  expect_error(
    run("xz", "--version", env_name = "does-not-exist"),
    class = "rattlerthis_run_missing_env"
  )
})
