test_that("create_env() solves and links a real package from conda-forge", {
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  res <- create_env(
    packages = "xz",
    env_name = "rt-test-xz",
    verbose = "silent"
  )

  expect_s3_class(res, "rattlerthis_result")
  expect_identical(res$env_name, "rt-test-xz")
  expect_true(fs::dir_exists(res$prefix))
  expect_true("xz" %in% res$packages$name)
  expect_true(env_exists("rt-test-xz"))
  expect_identical(list_envs(), "rt-test-xz")

  pkgs <- list_packages("rt-test-xz")
  expect_true("xz" %in% pkgs$name)

  remove_env("rt-test-xz", verbose = "silent")
  expect_false(env_exists("rt-test-xz"))
})

test_that("create_env(packages = NULL) makes an empty environment", {
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  res <- create_env(env_name = "rt-test-empty", verbose = "silent")

  expect_true(env_exists("rt-test-empty"))
  expect_identical(nrow(res$packages), 0L)
})
