test_that("install() adds a package without dropping what was already there", {
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  create_env(packages = "xz", env_name = "rt-test-install", verbose = "silent")
  before <- list_packages("rt-test-install")$name

  install(packages = "zstd", env_name = "rt-test-install", verbose = "silent")
  after <- list_packages("rt-test-install")$name

  expect_true(all(before %in% after))
  expect_true("zstd" %in% after)
})

test_that("install() creates the environment if it does not exist yet", {
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  expect_false(env_exists("rt-test-install-new"))
  install(packages = "xz", env_name = "rt-test-install-new", verbose = "silent")
  expect_true(env_exists("rt-test-install-new"))
})
