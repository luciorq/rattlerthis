test_that("get_install_dir honors RATTLERTHIS_ROOT_DIR", {
  root <- local_rattlerthis_root()
  expect_identical(fs::path(get_install_dir()), fs::path(root))
})

test_that("get_install_dir honors the rattlerthis.root_dir option over the env var", {
  local_rattlerthis_root()
  opt_root <- withr::local_tempdir(pattern = "rattlerthis-opt-root")
  withr::local_options(rattlerthis.root_dir = opt_root)
  expect_identical(fs::path(get_install_dir()), fs::path(opt_root))
})

test_that("get_env_dir nests under <root>/envs/<env_name>", {
  root <- local_rattlerthis_root()
  expect_identical(
    fs::path(get_env_dir("foo-env")),
    fs::path(root, "envs", "foo-env")
  )
})

test_that("list_envs is empty when the install root does not exist yet", {
  local_rattlerthis_root()
  expect_identical(list_envs(), character(0L))
})

test_that("env_exists is FALSE for an environment that was never created", {
  local_rattlerthis_root()
  expect_false(env_exists("does-not-exist"))
})

test_that("remove_env errors on a missing environment", {
  local_rattlerthis_root()
  expect_error(
    remove_env("does-not-exist"),
    class = "rattlerthis_error_env_remove"
  )
})

test_that("list_packages errors on a missing environment", {
  local_rattlerthis_root()
  expect_error(
    list_packages("does-not-exist"),
    class = "rattlerthis_list_packages_missing_env"
  )
})
