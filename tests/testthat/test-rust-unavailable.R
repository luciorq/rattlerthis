# A build without the Rust library, as on WebAssembly (webR), where
# tools/config.R compiles only src/wasm/init.c: the package still loads and
# registers a "rattler" backend, which is never available and fails with a
# condathis error that says why. The backend object is tested here in
# process (registering it replaces the methods of the real one, so each test
# registers the real backend again), and tools/config.R in a new R process
# that reports the webR platform.

test_that("the backend of a build without Rust keeps condathis's contract", {
  backend <- new_backend_rattler(rust_available = FALSE)
  required <- c("backend_create_env", "backend_install", "backend_resolve_run")
  expect_identical(names(backend), c(required, "backend_available"))
  expect_s3_class(backend, c("condathis_backend_rattler", "condathis_backend"))
  condathis_ns <- asNamespace("condathis")
  for (generic_name in required) {
    expect_identical(
      formals(backend[[generic_name]]),
      formals(get(generic_name, envir = condathis_ns, inherits = FALSE)),
      info = generic_name
    )
  }
  expect_false(backend$backend_available(backend))
  # The real build has the Rust routines, and so the real backend.
  expect_true(rattler_rust_available())
  expect_identical(names(new_backend_rattler()), names(new_backend_rattler(TRUE)))
})

test_that("without Rust, method = 'rattler' fails with a condathis error and 'auto' never picks it", {
  withr::defer(register_condathis_backend())
  expect_identical(
    condathis::register_backend(
      "rattler",
      new_backend_rattler(rust_available = FALSE)
    ),
    "rattler"
  )

  err <- expect_error(
    condathis::create_env(
      env_name = "rt-no-rust",
      method = "rattler",
      verbose = "silent"
    ),
    class = "condathis_create_env_failed"
  )
  expect_s3_class(err, "condathis_backend_unsupported")
  expect_s3_class(err$parent, "rattlerthis_rust_unavailable")
  expect_s3_class(err$parent, "condathis_backend_unsupported")
  expect_identical(err$parent$platform, R.version$platform)
  expect_match(
    conditionMessage(err$parent),
    "built without its Rust library",
    fixed = TRUE
  )
  expect_false(condathis::env_exists("rt-no-rust", method = "rattler"))

  # The option asks for rattler first, but an unavailable backend never gets
  # a new environment.
  withr::local_options(condathis.backend_priority = c("rattler", "micromamba"))
  resolved <- get(
    "resolve_backend_by_priority",
    envir = asNamespace("condathis")
  )("auto")
  expect_identical(resolved$name, "micromamba")
})

test_that("tools/config.R builds without Rust on WebAssembly", {
  config <- testthat::test_path("..", "..", "tools", "config.R")
  skip_if_not(file.exists(config), "needs the package source tree")
  src_root <- normalizePath(file.path(dirname(config), ".."))
  pkg <- withr::local_tempdir(pattern = "rt-wasm-config-")
  dir.create(file.path(pkg, "tools"))
  dir.create(file.path(pkg, "src"))
  file.copy(config, file.path(pkg, "tools", "config.R"))
  file.copy(file.path(src_root, "DESCRIPTION"), pkg)
  # webR's R reports this platform. The other checks of config.R (OpenSSL,
  # the Rust toolchain) must not run: PATH has no cargo or rustc here.
  res <- processx::run(
    file.path(R.home("bin"), "Rscript"),
    c(
      "-e",
      paste(
        "R.version <- list(platform = 'wasm32-unknown-emscripten')",
        "source('tools/config.R', local = TRUE)",
        sep = "; "
      )
    ),
    wd = pkg,
    env = c("current", PATH = R.home("bin")),
    error_on_status = FALSE
  )
  expect_identical(res$status, 0L, info = res$stderr)
  expect_match(res$stderr, "does not support WebAssembly", fixed = TRUE)
  makevars <- readLines(file.path(pkg, "src", "Makevars"))
  expect_true("OBJECTS = wasm/init.o" %in% makevars)
  expect_false(any(grepl("cargo", makevars, fixed = TRUE)))
  expect_true(file.exists(file.path(src_root, "src", "wasm", "init.c")))
})
