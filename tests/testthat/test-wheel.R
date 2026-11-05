test_that("create_env() installs a wheel package from the conda-pypi channel", {
  # `rattler::install::Installer`/`rattler_cache::package_cache` don't know
  # how to fetch or link raw `.whl` files themselves (only the type system
  # in rattler_conda_types models them) - rattlerthis implements that in
  # src/rust/src/wheel.rs. This exercises the whole path: download, extract
  # into site-packages, and generate the console-script entry point.
  # These are the only tests that may skip: the `wheels` Cargo feature is
  # off by default.
  skip_if_no_wheel_support()
  env_name <- "rt-wheel-create"
  defer_remove_env(env_name)

  condathis::create_env(
    "python",
    "conda-pypi::cowsay",
    channels = c("conda-forge", "conda-pypi"),
    env_name = env_name,
    method = "rattler",
    verbose = "silent"
  )
  pkgs <- condathis::list_packages(env_name, method = "rattler")
  expect_true("cowsay" %in% pkgs$name)

  import_res <- condathis::run(
    "python",
    "-c",
    "import cowsay; print(cowsay.__file__)",
    env_name = env_name,
    method = "rattler",
    verbose = "silent"
  )
  expect_identical(import_res$status, 0L)
  expect_match(import_res$stdout, "cowsay", fixed = TRUE)

  script_res <- condathis::run(
    "cowsay",
    "-t",
    "hello",
    env_name = env_name,
    method = "rattler",
    verbose = "silent"
  )
  expect_identical(script_res$status, 0L)
  expect_match(script_res$stdout, "hello", fixed = TRUE)
})

test_that("an install after a wheel package does not drop it or fail to solve", {
  # Regression test: install_packages() defaults to channels =
  # "conda-forge", which doesn't include "conda-pypi". Re-solving with a
  # bare-name "keep" spec for the already-installed wheel package used to
  # be unsolvable (its channel was never queried), and even once that was
  # fixed, a second `Installer::install()` into the same prefix panicked
  # inside rattler 0.46.0's ClobberRegistry. See src/rust/src/install.rs's
  # `install_after_wheel_does_not_panic` test.
  skip_if_no_wheel_support()
  env_name <- "rt-wheel-keep"
  defer_remove_env(env_name)

  condathis::create_env(
    "python",
    "conda-pypi::cowsay",
    channels = c("conda-forge", "conda-pypi"),
    env_name = env_name,
    method = "rattler",
    verbose = "silent"
  )
  condathis::install_packages(
    "xz",
    env_name = env_name,
    method = "rattler",
    verbose = "silent"
  )

  pkgs <- condathis::list_packages(env_name, method = "rattler")$name
  expect_true("cowsay" %in% pkgs)
  expect_true("xz" %in% pkgs)

  script_res <- condathis::run(
    "cowsay",
    "-t",
    "still here",
    env_name = env_name,
    method = "rattler",
    verbose = "silent"
  )
  expect_identical(script_res$status, 0L)
})
