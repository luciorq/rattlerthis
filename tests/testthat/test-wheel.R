test_that("create_env() installs a wheel package from the conda-pypi channel", {
  # `rattler::install::Installer`/`rattler_cache::package_cache` don't know
  # how to fetch or link raw `.whl` files themselves (only the type system
  # in rattler_conda_types models them) — rattlerthis implements that in
  # src/rust/src/wheel.rs. This exercises the whole path: download, extract
  # into site-packages, and generate the console-script entry point.
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  res <- create_env(
    packages = c("python", "conda-pypi::cowsay"),
    channels = c("conda-forge", "conda-pypi"),
    env_name = "rt-test-wheel",
    verbose = "silent"
  )

  expect_true("cowsay" %in% res$packages$name)
  pkgs <- list_packages("rt-test-wheel")
  expect_true("cowsay" %in% pkgs$name)

  import_res <- run(
    "python",
    "-c",
    "import cowsay; print(cowsay.__file__)",
    env_name = "rt-test-wheel",
    verbose = "silent"
  )
  expect_identical(import_res$status, 0L)
  expect_match(
    import_res$stdout,
    "site-packages/cowsay/__init__.py",
    fixed = TRUE
  )

  script_res <- run(
    "cowsay",
    "-t",
    "hello",
    env_name = "rt-test-wheel",
    verbose = "silent"
  )
  expect_identical(script_res$status, 0L)
  expect_match(script_res$stdout, "hello", fixed = TRUE)
})

test_that("install() after a wheel package does not drop it or fail to solve", {
  # Regression test: install() defaults to channels = "conda-forge", which
  # doesn't include "conda-pypi". Re-solving with a bare-name "keep" spec for
  # the already-installed wheel package used to be unsolvable (its channel
  # was never queried), and even once that was fixed, a second
  # `Installer::install()` into the same prefix panicked inside rattler
  # 0.46.0's ClobberRegistry. See PLAN.md ("Wheel packages") and
  # src/rust/src/install.rs's `install_after_wheel_does_not_panic` test.
  skip_on_cran()
  skip_if_offline()

  local_rattlerthis_root()
  create_env(
    packages = c("python", "conda-pypi::cowsay"),
    channels = c("conda-forge", "conda-pypi"),
    env_name = "rt-test-wheel-keep",
    verbose = "silent"
  )

  install(packages = "xz", env_name = "rt-test-wheel-keep", verbose = "silent")

  pkgs <- list_packages("rt-test-wheel-keep")$name
  expect_true("cowsay" %in% pkgs)
  expect_true("xz" %in% pkgs)

  script_res <- run(
    "cowsay",
    "-t",
    "still here",
    env_name = "rt-test-wheel-keep",
    verbose = "silent"
  )
  expect_identical(script_res$status, 0L)
})
