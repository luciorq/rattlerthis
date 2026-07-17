test_that("new_backend_rattler() returns a classed marker object", {
  backend <- new_backend_rattler()
  expect_s3_class(backend, "condathis_backend_rattler")
  expect_s3_class(backend, "condathis_backend")
})

test_that("backend_create_env() rejects env_file", {
  expect_error(
    backend_create_env(new_backend_rattler(), env_file = "environment.yml"),
    class = "rattlerthis_backend_unsupported_env_file"
  )
})

test_that("backend_create_env() rejects channel_priority = 'flexible'", {
  expect_error(
    backend_create_env(new_backend_rattler(), channel_priority = "flexible"),
    class = "rattlerthis_backend_unsupported_channel_priority"
  )
})

test_that("backend_install() rejects channel_priority = 'flexible'", {
  expect_error(
    backend_install(
      new_backend_rattler(),
      packages = "xz",
      channel_priority = "flexible"
    ),
    class = "rattlerthis_backend_unsupported_channel_priority"
  )
})

test_that("backend_merge_channels() folds additional_channels in", {
  expect_identical(
    backend_merge_channels("conda-forge", "bioconda"),
    c("conda-forge", "bioconda")
  )
  expect_identical(
    backend_merge_channels("conda-forge", NULL),
    "conda-forge"
  )
})

test_that("backend_available() is trivially TRUE", {
  expect_true(backend_available(new_backend_rattler()))
})

test_that("backend_get_install_dir()/backend_get_env_dir() match the public functions", {
  local_rattlerthis_root()
  backend <- new_backend_rattler()
  expect_identical(backend_get_install_dir(backend), get_install_dir())
  expect_identical(
    backend_get_env_dir(backend, "some-env"),
    get_env_dir("some-env")
  )
})

test_that("backend_list_envs()/backend_env_exists() work on an empty root", {
  local_rattlerthis_root()
  backend <- new_backend_rattler()
  expect_identical(backend_list_envs(backend), character(0L))
  expect_false(backend_env_exists(backend, "nope"))
})

test_that("adapter round-trips create/install/resolve_run/list/remove against conda-forge", {
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  backend <- new_backend_rattler()

  res <- backend_create_env(
    backend,
    packages = "xz",
    env_name = "rt-backend-test",
    channels = "conda-forge",
    additional_channels = NULL,
    verbose = "silent"
  )
  expect_s3_class(res, "rattlerthis_result")
  expect_true(backend_env_exists(backend, "rt-backend-test"))
  expect_identical(backend_list_envs(backend), "rt-backend-test")

  res2 <- backend_install(
    backend,
    packages = "zstd",
    env_name = "rt-backend-test",
    verbose = "silent"
  )
  expect_s3_class(res2, "rattlerthis_result")

  pkgs <- backend_list_packages(backend, "rt-backend-test")
  expect_true(all(c("xz", "zstd") %in% pkgs$name))

  resolved <- backend_resolve_run(
    backend,
    cmd = "xz",
    args = "--version",
    env_name = "rt-backend-test"
  )
  expect_type(resolved, "list")
  expect_setequal(names(resolved), c("command", "args", "env", "dir"))
  expect_identical(resolved$args, "--version")
  expect_null(resolved$dir)
  expect_true(fs::file_exists(resolved$command))

  withr::local_envvar(.new = resolved$env)
  px_res <- processx::run(
    command = resolved$command,
    args = resolved$args
  )
  expect_identical(px_res$status, 0L)

  backend_remove_env(backend, "rt-backend-test", verbose = "silent")
  expect_false(backend_env_exists(backend, "rt-backend-test"))
})
