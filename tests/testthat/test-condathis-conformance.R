# Conformance with condathis's backend contract
# =============================================
#
# These tests check that a backend package meets the backend contract
# (version 2) documented in `?condathis::register_backend`. They use
# condathis's public API only, the way a condathis user reaches the
# backend: every call is `condathis::<fn>(..., method = conformance_backend)`,
# or `method = "auto"` where the test is about backend resolution.
# test-hooks.R calls the backend functions directly; this file checks what
# condathis does with them. It is also the real-world check of condathis's
# backend layer, so a failure here can be a condathis bug as well as a
# backend bug.
#
# Using this file for another backend
# -----------------------------------
# The file is written as a template. To check another backend package:
#
# 1. Copy this file, setup.R, and from helper.R `local_condathis_sandbox()`
#    (with `rt_test_state` and `remember_runner_micromamba()`),
#    `defer_remove_env()`, `condathis_polyglot_channel()`,
#    `polyglot_first_line()`, `channel_url()` (or any local channel with a
#    package `foo`), the `rscript_*()` helpers, `parse_env_output()`,
#    `path_is_within()`, `expect_env_not_found()` and
#    `expect_backend_failure()`.
# 2. Set the three values of the configuration block below.
# 3. The sandbox moves only the home, data and cache directories: they move
#    condathis's root, and every backend root below it
#    (`condathis::backend_root_dir(<name>)`). A backend whose root is
#    elsewhere must move it there too, and leave it uncreated: the
#    fresh-root test checks that queries do not create it.
# 4. Adapt the places marked "Backend-specific": what your mutations
#    report as `cmd` and `stdout` (rattler runs no command line), which
#    requests your backend cannot honor (rattler refuses wheels and source
#    archives listed as Conda packages), and where your caches are.
#
# Requirements
# ------------
# * condathis (>= 0.2.0), contract version 2.
# * Local channels for everything but the last test: condathis's own
#   (`polyglot`, noarch, no dependencies) and the test channels of
#   fixtures/channels. The last test uses conda-forge.
# * No micromamba. A workflow that uses only this backend must never
#   install it, and the tests check that.
# * The process sandbox of setup.R: temporary home, data and cache
#   directories, no CONDA_* or MAMBA_* variables, and condathis's default
#   backend priority (micromamba first). Tests that assert on a fresh,
#   empty root, or on every environment there is, make a sandbox of their
#   own; the others use distinct environment names.
#
# Sections, in the order of ?register_backend
# -------------------------------------------
# 1. The backend object: formals, dispatch and registration.
# 2. Queries on a fresh root: nothing is created or installed.
# 3. Backend priority, roots and ownership.
# 4. The lifecycle of one environment, and the return values.
# 5. overwrite: an existing environment is kept, refused or replaced; what
#    a failed or interrupted create leaves.
# 6. Missing environments: one policy, condathis's classes.
# 7. Errors: condathis's backend classes, the backend's error as parent;
#    environment files and channel priorities.
# 8. Child processes: the activation reaches them, other roots do not.
# 9. A conda-forge workflow, end to end.

# --- Configuration ----------------------------------------------------------

# The name the backend package registers, as users pass it to `method`.
conformance_backend <- "rattler"

# The backend object the package registers.
conformance_new_backend <- function() {
  return(new_backend_rattler())
}

# A class of the backend's own error when a solve fails. condathis keeps it
# as the parent of the error it raises.
conformance_solve_error_class <- "rattlerthis_rattler_error"

# --- Helpers ----------------------------------------------------------------

# The backend's root, as condathis reports it.
conformance_root <- function() {
  return(condathis::get_install_dir(method = conformance_backend)$path)
}

# Create `env_name` with `polyglot` from the local channel.
create_polyglot_env <- function(env_name, ...) {
  return(condathis::create_env(
    "polyglot",
    env_name = env_name,
    channels = condathis_polyglot_channel(),
    method = conformance_backend,
    verbose = "silent",
    ...
  ))
}

# The entries of the backend's trash directory (condathis's
# `<root>/envs/#trash`), which must be empty after every operation.
conformance_trash <- function() {
  trash_dir <- fs::path(conformance_root(), "envs", "#trash")
  return(list.files(trash_dir, all.files = TRUE, no.. = TRUE))
}

# The six columns `list_packages()` has for every backend, with their types.
contract_package_columns <- c(
  name = "character",
  version = "character",
  build_number = "integer",
  build_string = "character",
  channel = "character",
  platform = "character"
)

# --- 1. The backend object --------------------------------------------------

test_that("the backend object matches condathis's generics and registers", {
  condathis_ns <- asNamespace("condathis")
  backend <- conformance_new_backend()
  # "What condathis passes": every argument by name, so the formals must be
  # the generic's. Same names, order and default expressions.
  for (generic_name in names(backend)) {
    generic <- get(generic_name, envir = condathis_ns, inherits = FALSE)
    expect_identical(
      formals(backend[[generic_name]]),
      formals(generic),
      info = generic_name
    )
    # condathis dispatches the generic to exactly this function.
    expect_identical(
      utils::getS3method(
        generic_name,
        class(backend)[[1L]],
        envir = condathis_ns
      ),
      backend[[generic_name]],
      info = generic_name
    )
  }
  expect_true(
    conformance_backend %in% condathis::list_registered_backend_names()
  )
  # register_backend() checks the name, the class and every function's
  # formals. Registering the same object again passes those checks.
  expect_identical(
    condathis::register_backend(conformance_backend, conformance_new_backend()),
    conformance_backend
  )
})

# --- 2. Queries on a fresh root ---------------------------------------------

test_that("queries on a fresh root create nothing and install nothing", {
  # Decision D3 of condathis: every query works before any environment
  # exists, without creating one. Neither the queries nor get_env_dir()
  # create anything, not even the backend's root.
  paths <- local_condathis_sandbox()
  env_name <- "rt-conf-fresh"
  expect_false(fs::dir_exists(paths$rattler))

  expect_false(condathis::env_exists(env_name, method = conformance_backend))
  expect_false(condathis::env_exists(env_name))
  envs <- condathis::list_envs(method = conformance_backend)
  expect_s3_class(envs, "data.frame")
  expect_identical(names(envs), c("backend", "env_name", "path"))
  expect_identical(nrow(envs), 0L)
  expect_identical(nrow(condathis::list_envs()), 0L)
  res <- condathis::validate_env(
    env_name = env_name,
    method = conformance_backend,
    error = "continue"
  )
  expect_false(res)
  expect_identical(attr(res, "reason"), "env_not_found")
  expect_env_not_found(
    condathis::validate_env(env_name = env_name, method = conformance_backend),
    class = "condathis_validate_env_env_not_found"
  )
  expect_env_not_found(
    condathis::list_packages(env_name, method = conformance_backend),
    class = "condathis_list_packages_env_not_found"
  )
  # backend_get_env_dir() returns the path of an environment that does not
  # exist yet, and creates nothing.
  env_dir <- condathis::get_env_dir(env_name, method = conformance_backend)
  expect_s3_class(env_dir, "fs_path")
  expect_true(fs::is_absolute_path(env_dir))
  expect_false(fs::dir_exists(env_dir))
  # Read only, so far: not even the backend's root exists.
  expect_false(fs::dir_exists(paths$rattler))

  # backend_get_install_dir() returns an existing, real directory: creating
  # the root is allowed; creating the environment's directory is not.
  root <- condathis::get_install_dir(method = conformance_backend)
  expect_identical(names(root), c("backend", "path"))
  expect_identical(root$backend, conformance_backend)
  expect_true(fs::dir_exists(root$path))
  expect_identical(root$path, as.character(fs::path_real(root$path)))
  expect_identical(root$path, as.character(fs::path_real(paths$rattler)))
  expect_identical(
    as.character(env_dir),
    as.character(fs::path(root$path, "envs", env_name))
  )
  expect_false(fs::dir_exists(env_dir))

  # Still no environment anywhere, and micromamba was never installed.
  expect_identical(nrow(condathis::list_envs()), 0L)
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})

# --- 3. Backend priority, roots and ownership -------------------------------

test_that("the backend's root is inside micromamba's, its envs and caches are not", {
  # C-A, decision Q21: every backend but micromamba has the root
  # `<condathis root>/<name>`, and micromamba's root is condathis's root.
  # What stays apart is every backend's envs/ and package caches.
  local_condathis_sandbox()
  micromamba_root <- condathis::get_install_dir(method = "micromamba")$path
  backend_root <- conformance_root()
  expect_identical(
    backend_root,
    as.character(fs::path(micromamba_root, conformance_backend))
  )
  expect_identical(
    backend_root,
    as.character(condathis::backend_root_dir(conformance_backend))
  )
  # Backend-specific: rattler's package and repodata caches, the cache of
  # the pip steps of its creates (`cache`, as micromamba's), and the
  # package cache of the conda tools run in its environments (condathis's
  # `conda-pkgs`).
  backend_dirs <- fs::path(
    backend_root,
    c("envs", "pkgs", "repodata_cache", "cache", "conda-pkgs")
  )
  micromamba_dirs <- fs::path(micromamba_root, c("envs", "pkgs", "cache"))
  for (backend_dir in backend_dirs) {
    for (micromamba_dir in micromamba_dirs) {
      expect_false(
        path_is_within(backend_dir, micromamba_dir),
        info = paste(backend_dir, "in", micromamba_dir)
      )
      expect_false(
        path_is_within(micromamba_dir, backend_dir),
        info = paste(micromamba_dir, "in", backend_dir)
      )
    }
  }
  # Each backend's environments are in its own envs/.
  expect_identical(
    as.character(fs::path_dir(
      condathis::get_env_dir("rt-conf-x", method = "micromamba")
    )),
    as.character(fs::path(micromamba_root, "envs"))
  )
  expect_identical(
    as.character(fs::path_dir(
      condathis::get_env_dir("rt-conf-x", method = conformance_backend)
    )),
    as.character(fs::path(backend_root, "envs"))
  )
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})

test_that("new environments go to micromamba unless the user opts in", {
  local_condathis_sandbox()
  micromamba_root <- condathis::get_install_dir(method = "micromamba")$path
  backend_root <- conformance_root()

  # The default of options(condathis.backend_priority) is "micromamba".
  # get_install_dir() lists every registered backend, in that order.
  dirs <- condathis::get_install_dir()
  expect_identical(dirs$backend[[1L]], "micromamba")
  expect_true(conformance_backend %in% dirs$backend)
  expect_identical(attr(dirs, "row.names"), seq_len(nrow(dirs)))
  # A name that no backend owns resolves to the first backend.
  new_dir <- condathis::get_env_dir("rt-conf-new")
  expect_true(path_is_within(new_dir, fs::path(micromamba_root, "envs")))
  expect_false(path_is_within(new_dir, backend_root))

  # Opting in puts this backend first, also for method = "auto".
  withr::local_options(condathis.backend_priority = conformance_backend)
  expect_identical(
    condathis::get_install_dir()$backend[[1L]],
    conformance_backend
  )
  expect_true(path_is_within(
    condathis::get_env_dir("rt-conf-new"),
    backend_root
  ))
  env_name <- "rt-conf-auto"
  condathis::create_env(
    "polyglot",
    env_name = env_name,
    channels = condathis_polyglot_channel(),
    verbose = "silent"
  )
  expect_true(condathis::env_exists(env_name, method = conformance_backend))
  expect_false(condathis::env_exists(env_name, method = "micromamba"))
  expect_identical(condathis::list_envs()$backend, conformance_backend)
  res <- condathis::run("polyglot", env_name = env_name, verbose = "silent")
  expect_identical(condathis::parse_output(res)[[1L]], polyglot_first_line())
  condathis::remove_env(env_name, verbose = "silent")
  expect_false(condathis::env_exists(env_name))
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})

test_that("an existing environment is found and owned by this backend", {
  # condathis probes every registered backend on every call that names an
  # environment, so method = "auto" finds this backend's environments with
  # the default priority, and another method is refused or redirected.
  local_condathis_sandbox()
  env_name <- "rt-conf-owner"
  channel <- condathis_polyglot_channel()
  create_polyglot_env(env_name)

  expect_true(condathis::env_exists(env_name))
  expect_identical(condathis::list_envs()$backend, conformance_backend)
  expect_true(path_is_within(
    condathis::get_env_dir(env_name),
    conformance_root()
  ))
  expect_identical(condathis::list_packages(env_name)$name, "polyglot")
  expect_true(condathis::validate_env("polyglot", env_name = env_name))
  res <- condathis::run("polyglot", env_name = env_name, verbose = "silent")
  expect_identical(condathis::parse_output(res)[[1L]], polyglot_first_line())

  # The positional-env_name check of create_env() and install_packages()
  # asks every backend whether the last spec names an environment.
  expect_error(
    condathis::create_env("polyglot", env_name),
    class = "condathis_create_env_positional_env_name"
  )
  expect_error(
    condathis::install_packages("polyglot", env_name),
    class = "condathis_install_packages_positional_env_name"
  )

  # Changing it with another backend aborts; reading it warns and uses the
  # owner (R-17).
  expect_error(
    condathis::install_packages(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = "micromamba",
      verbose = "silent"
    ),
    class = "condathis_backend_mismatch"
  )
  expect_error(
    condathis::create_env(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = "micromamba",
      verbose = "silent"
    ),
    class = "condathis_backend_mismatch"
  )
  expect_warning(
    res <- condathis::run(
      "polyglot",
      env_name = env_name,
      method = "micromamba",
      verbose = "silent"
    ),
    class = "condathis_backend_mismatch_warning"
  )
  expect_identical(condathis::parse_output(res)[[1L]], polyglot_first_line())

  # None of this needed micromamba.
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})

# --- 4. The lifecycle of one environment ------------------------------------

test_that("an environment round-trips through condathis's public API", {
  local_condathis_sandbox()
  channel <- condathis_polyglot_channel()
  env_name <- "rt-conf-life"

  # backend_create_env() with no packages: an empty environment.
  res <- condathis::create_env(
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_s3_class(res, "condathis_result")
  expect_identical(res$status, 0L)
  expect_identical(res$env_name, env_name)
  expect_false(res$timeout)
  # Backend-specific: rattler solves in-process and reports no command
  # line, so `cmd`, `stderr` and `pid` are NA (R-2), and `stdout` holds the
  # transaction lines: none for an empty environment (R-30). A backend that
  # runs a command reports its exact command line in `cmd`.
  expect_identical(res$cmd, NA_character_)
  expect_identical(res$stderr, NA_character_)
  expect_identical(res$pid, NA_integer_)
  expect_identical(res$stdout, "")
  expect_true(condathis::env_exists(env_name, method = conformance_backend))

  # An empty environment: zero rows, the same columns.
  pkgs <- condathis::list_packages(env_name, method = conformance_backend)
  expect_s3_class(pkgs, "data.frame")
  expect_identical(nrow(pkgs), 0L)
  expect_true(all(names(contract_package_columns) %in% names(pkgs)))

  # backend_install() into the existing environment.
  res <- condathis::install_packages(
    "polyglot",
    env_name = env_name,
    channels = channel,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_s3_class(res, "condathis_result")
  expect_identical(res$status, 0L)
  expect_identical(res$cmd, NA_character_)
  # Backend-specific: one transaction line per package.
  expect_match(
    res$stdout,
    "^[+] polyglot 0[.]1[.]0 h4616a5c_0 [^\n]*polyglot-channel/noarch\n$"
  )

  # list_packages(): the six columns, with their types.
  pkgs <- condathis::list_packages(env_name, method = conformance_backend)
  expect_s3_class(pkgs, "tbl_df")
  for (column in names(contract_package_columns)) {
    expect_type(pkgs[[column]], contract_package_columns[[column]])
  }
  expect_identical(attr(pkgs, "row.names"), 1L)
  expect_identical(pkgs$name, "polyglot")
  expect_identical(pkgs$version, "0.1.0")
  expect_identical(pkgs$build_number, 0L)
  expect_identical(pkgs$build_string, "h4616a5c_0")
  expect_identical(pkgs$platform, "noarch")
  expect_match(pkgs$channel, "polyglot-channel", fixed = TRUE)

  # validate_env() reads the same listing as create_env().
  expect_true(condathis::validate_env(
    "polyglot",
    env_name = env_name,
    method = conformance_backend
  ))
  # noarch packages match any platform.
  expect_true(condathis::validate_env(
    "polyglot",
    env_name = env_name,
    method = conformance_backend,
    platform = "linux-64"
  ))
  res <- condathis::validate_env(
    "polyglot>=2",
    env_name = env_name,
    method = conformance_backend,
    error = "continue"
  )
  expect_false(res)
  expect_identical(attr(res, "reason"), "unsatisfied")
  expect_identical(attr(res, "unsatisfied"), "polyglot>=2")
  expect_error(
    condathis::validate_env(
      "polyglot>=2",
      env_name = env_name,
      method = conformance_backend
    ),
    class = "condathis_validate_env_unsatisfied"
  )

  # The directories: get_env_dir() is under get_install_dir(), and is the
  # directory the backend manages.
  root <- conformance_root()
  env_dir <- condathis::get_env_dir(env_name, method = conformance_backend)
  expect_identical(
    as.character(env_dir),
    as.character(fs::path(root, "envs", env_name))
  )
  expect_identical(condathis::get_env_dir(env_name), env_dir)
  # Backend-specific: the prefix rattler installed into.
  expect_identical(
    fs::path_real(env_dir),
    fs::path_real(rattler_env_dir(env_name))
  )
  # condathis writes its backend marker after backend_create_env().
  marker <- jsonlite::fromJSON(fs::path(env_dir, ".condathis", "backend.json"))
  expect_identical(marker$backend, conformance_backend)

  # list_envs().
  envs <- condathis::list_envs(method = conformance_backend)
  expect_identical(envs$backend, conformance_backend)
  expect_identical(envs$env_name, env_name)
  expect_identical(envs$path, as.character(env_dir))
  expect_identical(attr(envs, "row.names"), 1L)

  # backend_resolve_run(), through the three run functions.
  run_res <- condathis::run(
    "polyglot",
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_s3_class(run_res, "condathis_result")
  expect_identical(run_res$status, 0L)
  expect_identical(run_res$env_name, env_name)
  expect_identical(
    condathis::parse_output(run_res)[[1L]],
    polyglot_first_line()
  )
  bin_res <- condathis::run_bin(
    "polyglot",
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_s3_class(bin_res, "condathis_result")
  expect_identical(bin_res$status, 0L)
  expect_identical(
    condathis::parse_output(bin_res)[[1L]],
    polyglot_first_line()
  )
  pipe_res <- condathis::run_pipeline(
    condathis::run_step("polyglot"),
    condathis::run_step("polyglot"),
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_s3_class(pipe_res, "condathis_pipeline")
  expect_identical(pipe_res$status, 0L)
  expect_identical(pipe_res$statuses, c(0L, 0L))
  expect_length(pipe_res$processes, 2L)
  expect_identical(pipe_res$processes[[2L]]$env_name, env_name)
  expect_identical(
    condathis::parse_output(pipe_res)[[1L]],
    polyglot_first_line()
  )

  # condathis's default backend_remove_env().
  rm_res <- condathis::remove_env(
    env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_s3_class(rm_res, "condathis_result")
  expect_identical(rm_res$status, 0L)
  expect_identical(rm_res$cmd, NA_character_)
  expect_false(condathis::env_exists(env_name, method = conformance_backend))
  expect_false(fs::dir_exists(env_dir))
  expect_identical(nrow(condathis::list_envs(method = conformance_backend)), 0L)
  expect_identical(conformance_trash(), character(0L))
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})

test_that("each message is printed once, by condathis", {
  # condathis prints its own messages, and the backend must not repeat
  # them.
  channel <- condathis_polyglot_channel()
  env_name <- "rt-conf-msgs"
  defer_remove_env(env_name)

  msgs <- testthat::capture_messages(
    condathis::create_env(
      env_name = env_name,
      method = conformance_backend,
      verbose = "output"
    )
  )
  expect_length(grep("created", msgs, fixed = TRUE), 1L)
  msgs <- testthat::capture_messages(
    condathis::install_packages(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = conformance_backend,
      verbose = "output"
    )
  )
  expect_length(grep("installed", msgs, fixed = TRUE), 1L)
  msgs <- testthat::capture_messages(
    condathis::remove_env(
      env_name,
      method = conformance_backend,
      verbose = "output"
    )
  )
  expect_length(grep("removed", msgs, fixed = TRUE), 1L)
})

# --- 5. overwrite -----------------------------------------------------------

test_that("an existing environment is kept or refused, and replaced only with overwrite = TRUE", {
  # condathis calls backend_create_env() only for a missing environment
  # directory: it moves an existing environment aside for overwrite = TRUE
  # and deletes a directory that is not an environment.
  channel <- condathis_polyglot_channel()
  env_name <- "rt-conf-overwrite"
  defer_remove_env(env_name)
  create_polyglot_env(env_name)

  # No packages requested: kept, nothing runs.
  res <- condathis::create_env(
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(res$status, 0L)
  expect_identical(res$cmd, NA_character_)
  expect_identical(
    condathis::list_packages(env_name, method = conformance_backend)$name,
    "polyglot"
  )
  # The request is satisfied: kept, with one message and no warning.
  expect_no_warning(
    msgs <- testthat::capture_messages(
      res <- condathis::create_env(
        "polyglot",
        env_name = env_name,
        channels = channel,
        method = conformance_backend,
        verbose = "output"
      )
    )
  )
  expect_identical(res$status, 0L)
  expect_length(
    grep("already has the requested packages", msgs, fixed = TRUE),
    1L
  )
  expect_length(grep("created", msgs, fixed = TRUE), 0L)
  # Not satisfied: refused, and the environment is unchanged.
  expect_error(
    condathis::create_env(
      "polyglot>=2",
      env_name = env_name,
      channels = channel,
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_create_env_exists"
  )
  expect_identical(
    condathis::list_packages(env_name, method = conformance_backend)$name,
    "polyglot"
  )

  # overwrite = TRUE builds exactly the request: an empty environment keeps
  # none of the old packages.
  res <- condathis::create_env(
    env_name = env_name,
    method = conformance_backend,
    overwrite = TRUE,
    verbose = "silent"
  )
  expect_identical(res$status, 0L)
  expect_true(condathis::env_exists(env_name, method = conformance_backend))
  expect_identical(
    nrow(condathis::list_packages(env_name, method = conformance_backend)),
    0L
  )
  create_polyglot_env(env_name, overwrite = TRUE)
  expect_identical(
    condathis::list_packages(env_name, method = conformance_backend)$name,
    "polyglot"
  )
  expect_identical(conformance_trash(), character(0L))

  # A leftover directory that is not an environment is "missing" for the
  # backend; creating the environment replaces it.
  stale_name <- "rt-conf-stale"
  defer_remove_env(stale_name)
  stale_dir <- condathis::get_env_dir(stale_name, method = conformance_backend)
  fs::dir_create(stale_dir)
  writeLines("leftover", fs::path(stale_dir, "leftover.txt"))
  expect_false(condathis::env_exists(stale_name, method = conformance_backend))
  create_polyglot_env(stale_name)
  expect_true(condathis::env_exists(stale_name, method = conformance_backend))
  expect_false(fs::file_exists(fs::path(stale_dir, "leftover.txt")))
  expect_identical(
    condathis::list_packages(stale_name, method = conformance_backend)$name,
    "polyglot"
  )
  expect_identical(conformance_trash(), character(0L))
})

test_that("a failed create leaves nothing behind", {
  env_name <- "rt-conf-create-fail"
  env_dir <- condathis::get_env_dir(env_name, method = conformance_backend)
  expect_backend_failure(
    condathis::create_env(
      "rt-conf-no-such-package",
      env_name = env_name,
      channels = condathis_polyglot_channel(),
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_create_env_failed",
    parent_class = conformance_solve_error_class
  )
  expect_false(condathis::env_exists(env_name, method = conformance_backend))
  expect_false(fs::dir_exists(env_dir))
  expect_identical(conformance_trash(), character(0L))
})

test_that("an interrupt during a create leaves no environment, or the old one", {
  # Backend-specific: rattler works in the R process, so an interrupt
  # (Ctrl-C) reaches it while it polls its job. It cancels the job, waits
  # until the job is idle, and the interrupt goes on to condathis, which
  # deletes the new directory or moves the old environment back. The
  # interrupt is signaled by the poll of the create's job (the second one),
  # wherever the job is then (a real Ctrl-C is in test-interrupt.R).
  channel <- channel_url("chA")
  old_name <- "rt-conf-interrupt-old"
  defer_remove_env(old_name)
  create_polyglot_env(old_name)
  old_dir <- condathis::get_env_dir(old_name, method = conformance_backend)
  writeLines("kept", fs::path(old_dir, "kept.txt"))

  real_poll <- rt_job_poll
  real_start <- rattler_start_install
  armed <- FALSE
  polls <- 0L
  testthat::local_mocked_bindings(
    rattler_start_install = function(...) {
      armed <<- TRUE
      return(real_start(...))
    },
    rt_job_poll = function(job) {
      if (isTRUE(armed)) {
        polls <<- polls + 1L
        if (identical(polls, 2L)) {
          armed <<- FALSE
          polls <<- 0L
          rlang::interrupt()
        }
      }
      return(real_poll(job))
    }
  )

  env_name <- "rt-conf-interrupt-new"
  env_dir <- condathis::get_env_dir(env_name, method = conformance_backend)
  res <- tryCatch(
    condathis::create_env(
      "foo",
      env_name = env_name,
      channels = channel,
      method = conformance_backend,
      verbose = "silent"
    ),
    interrupt = function(cnd) "interrupted"
  )
  expect_identical(res, "interrupted")
  expect_false(condathis::env_exists(env_name, method = conformance_backend))
  expect_false(fs::dir_exists(env_dir))
  expect_identical(rt_live_jobs(), 0L)

  res <- tryCatch(
    condathis::create_env(
      "foo",
      env_name = old_name,
      channels = channel,
      method = conformance_backend,
      overwrite = TRUE,
      verbose = "silent"
    ),
    interrupt = function(cnd) "interrupted"
  )
  expect_identical(res, "interrupted")
  expect_true(condathis::env_exists(old_name, method = conformance_backend))
  expect_true(fs::file_exists(fs::path(old_dir, "kept.txt")))
  expect_identical(
    condathis::list_packages(old_name, method = conformance_backend)$name,
    "polyglot"
  )
  expect_identical(rt_live_jobs(), 0L)
  expect_identical(conformance_trash(), character(0L))
})

# --- 6. Missing environments ------------------------------------------------

test_that("a missing environment aborts with condathis's classes and nothing is created", {
  local_condathis_sandbox()
  channel <- condathis_polyglot_channel()
  env_name <- "rt-conf-missing"

  expect_env_not_found(
    condathis::run(
      "polyglot",
      env_name = env_name,
      method = conformance_backend
    ),
    class = "condathis_run_env_not_found"
  )
  res <- condathis::run(
    "polyglot",
    env_name = env_name,
    method = conformance_backend,
    error = "continue",
    verbose = "silent"
  )
  expect_identical(res$status, 127L)
  # run_bin() never falls back to a program on PATH.
  expect_env_not_found(
    condathis::run_bin(
      rscript_path(),
      "--version",
      env_name = env_name,
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_run_bin_env_not_found"
  )
  res <- condathis::run_bin(
    rscript_path(),
    "--version",
    env_name = env_name,
    method = conformance_backend,
    error = "continue",
    verbose = "silent"
  )
  expect_identical(res$status, 127L)
  expect_env_not_found(
    condathis::run_pipeline(
      condathis::run_step("polyglot"),
      condathis::run_step("polyglot"),
      env_name = env_name,
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_run_pipeline_env_not_found"
  )
  expect_env_not_found(
    condathis::list_packages(env_name, method = conformance_backend),
    class = "condathis_list_packages_env_not_found"
  )
  expect_env_not_found(
    condathis::validate_env(env_name = env_name, method = conformance_backend),
    class = "condathis_validate_env_env_not_found"
  )
  expect_env_not_found(
    condathis::remove_env(env_name, method = conformance_backend),
    class = "condathis_remove_env_env_not_found"
  )
  # Without a method, a name that no backend owns resolves to micromamba,
  # whose probe answers without a process: the same classes.
  expect_env_not_found(
    condathis::remove_env(env_name),
    class = "condathis_remove_env_env_not_found"
  )
  # install_packages() creates only condathis-env.
  expect_env_not_found(
    condathis::install_packages(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_install_packages_env_not_found"
  )

  # Nothing was created, and micromamba was never installed.
  expect_identical(nrow(condathis::list_envs()), 0L)
  expect_false(fs::dir_exists(
    condathis::get_env_dir(env_name, method = conformance_backend)
  ))
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})

test_that("only the default environment is created, under the backend that method names", {
  # run(), run_bin(), run_pipeline() and install_packages() create a
  # missing condathis-env, empty, with the backend the call resolved.
  local_condathis_sandbox()
  channel <- condathis_polyglot_channel()
  default_env <- "condathis-env"
  expect_default_env_created <- function() {
    expect_true(condathis::env_exists(
      default_env,
      method = conformance_backend
    ))
    expect_false(condathis::env_exists(default_env, method = "micromamba"))
    condathis::remove_env(
      default_env,
      method = conformance_backend,
      verbose = "silent"
    )
  }

  res <- condathis::run(
    rscript_path(),
    "-e",
    "cat('ok')",
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(condathis::parse_output(res), "ok")
  expect_identical(
    nrow(condathis::list_packages(default_env, method = conformance_backend)),
    0L
  )
  expect_default_env_created()

  res <- condathis::run_bin(
    rscript_path(),
    "-e",
    "cat('ok')",
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(condathis::parse_output(res), "ok")
  expect_default_env_created()

  res <- condathis::run_pipeline(
    condathis::run_step(rscript_path(), "-e", "cat('ok\\n')"),
    condathis::run_step(rscript_path(), rscript_cat_args()),
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(condathis::parse_output(res), "ok")
  expect_default_env_created()

  res <- condathis::install_packages(
    "polyglot",
    channels = channel,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(res$env_name, default_env)
  expect_identical(
    condathis::list_packages(default_env, method = conformance_backend)$name,
    "polyglot"
  )
  expect_default_env_created()
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})

# --- 7. Errors --------------------------------------------------------------

test_that("a failed operation has condathis's backend classes", {
  # The backend signals an error of any class; condathis re-raises it as
  # condathis_<function>_failed and condathis_backend_error, with the
  # backend's error as the parent (R-3: the micromamba status classes are
  # micromamba's only).
  channel <- condathis_polyglot_channel()
  env_name <- "rt-conf-fail"
  defer_remove_env(env_name)

  cnd <- expect_backend_failure(
    condathis::create_env(
      "rt-conf-no-such-package",
      env_name = env_name,
      channels = channel,
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_create_env_failed",
    parent_class = conformance_solve_error_class
  )
  # Backend-specific: the kind of the rattler error.
  expect_true(rlang::cnd_inherits(cnd, "rattlerthis_rattler_solve"))
  expect_false(rlang::cnd_inherits(cnd, "condathis_micromamba_status_error"))
  expect_false(condathis::env_exists(env_name, method = conformance_backend))

  create_polyglot_env(env_name)
  expect_backend_failure(
    condathis::install_packages(
      "rt-conf-no-such-package",
      env_name = env_name,
      channels = channel,
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_install_packages_failed",
    parent_class = conformance_solve_error_class
  )
  expect_identical(
    condathis::list_packages(env_name, method = conformance_backend)$name,
    "polyglot"
  )

  # A failed `overwrite = TRUE` leaves the existing environment as it was
  # (?register_backend), and it is back before the error reaches a calling
  # handler of the caller.
  env_dir <- condathis::get_env_dir(env_name, method = conformance_backend)
  writeLines("kept", fs::path(env_dir, "kept.txt"))
  seen_in_handler <- NA
  expect_backend_failure(
    withCallingHandlers(
      condathis::create_env(
        "rt-conf-no-such-package",
        env_name = env_name,
        channels = channel,
        method = conformance_backend,
        overwrite = TRUE,
        verbose = "silent"
      ),
      condathis_create_env_failed = function(cnd) {
        seen_in_handler <<- condathis::env_exists(
          env_name,
          method = conformance_backend
        )
      }
    ),
    class = "condathis_create_env_failed",
    parent_class = conformance_solve_error_class
  )
  expect_true(seen_in_handler)
  expect_true(condathis::env_exists(env_name, method = conformance_backend))
  expect_true(fs::file_exists(fs::path(env_dir, "kept.txt")))
  expect_identical(
    condathis::list_packages(env_name, method = conformance_backend)$name,
    "polyglot"
  )
  expect_identical(conformance_trash(), character(0L))
})

test_that("environment files and every channel priority work", {
  # Backend-specific: rattler reads YAML, plain, explicit and conda-lock
  # files, and solves with strict, flexible and disabled priority.
  channel <- condathis_polyglot_channel()

  env_file <- withr::local_tempfile(fileext = ".yml")
  writeLines(
    c("channels:", paste0("  - ", channel), "dependencies:", "  - polyglot"),
    env_file
  )
  env_name <- "rt-conf-env-file"
  defer_remove_env(env_name)
  res <- condathis::create_env(
    env_name = env_name,
    env_file = env_file,
    channels = channel,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(res$status, 0L)
  expect_identical(
    condathis::list_packages(env_name, method = conformance_backend)$name,
    "polyglot"
  )

  for (priority in c("flexible", "disabled")) {
    env_name <- paste0("rt-conf-", priority)
    defer_remove_env(env_name)
    res <- condathis::create_env(
      env_name = env_name,
      channels = channel,
      channel_priority = priority,
      method = conformance_backend,
      verbose = "silent"
    )
    expect_identical(res$status, 0L, info = priority)
    res <- condathis::install_packages(
      "polyglot",
      env_name = env_name,
      channels = channel,
      channel_priority = priority,
      method = conformance_backend,
      verbose = "silent"
    )
    expect_identical(res$status, 0L, info = priority)
    expect_identical(
      condathis::list_packages(env_name, method = conformance_backend)$name,
      "polyglot",
      info = priority
    )
  }
})

test_that("requests the backend cannot honor fail with condathis_backend_unsupported", {
  # Backend-specific: rattler refuses Python wheels and source archives
  # listed as Conda packages (of an explicit or lock file).
  channel <- condathis_polyglot_channel()
  wheel_file <- withr::local_tempfile(fileext = ".txt")
  writeLines(
    c(
      "@EXPLICIT",
      file_url(fixtures_path("pip", "rtwheel-1.0-py3-none-any.whl"))
    ),
    wheel_file
  )
  sdist_file <- withr::local_tempfile(fileext = ".txt")
  writeLines(
    c("@EXPLICIT", "https://example.invalid/rtwheel-1.0.tar.gz"),
    sdist_file
  )
  for (env_file in c(wheel_file, sdist_file)) {
    env_name <- "rt-conf-unsupported"
    cnd <- expect_backend_failure(
      condathis::create_env(
        env_name = env_name,
        env_file = env_file,
        channels = channel,
        method = conformance_backend,
        verbose = "silent"
      ),
      class = "condathis_create_env_failed",
      parent_class = "rattlerthis_rattler_unsupported"
    )
    expect_s3_class(cnd, "condathis_backend_unsupported")
    expect_false(condathis::env_exists(env_name, method = conformance_backend))
    expect_false(fs::dir_exists(
      condathis::get_env_dir(env_name, method = conformance_backend)
    ))
  }
})

# --- 8. Child processes -----------------------------------------------------

test_that("child processes get the activation, not the micromamba backend's directories", {
  # A child started for an environment of this backend must see its
  # activation (CONDA_PREFIX), and must not be pointed at the micromamba
  # backend's package cache or envs directory, nor at the caller's own
  # values: a conda/mamba call inside it would read and write another
  # backend's environments and caches.
  env_name <- "rt-conf-child-env"
  defer_remove_env(env_name)
  create_polyglot_env(env_name)
  env_dir <- condathis::get_env_dir(env_name, method = conformance_backend)
  micromamba_root <- condathis::get_install_dir(method = "micromamba")$path
  micromamba_dirs <- fs::path(micromamba_root, c("envs", "pkgs"))
  leaked_vars <- c("CONDA_PKGS_DIRS", "MAMBA_PKGS_DIRS", "CONDA_ENVS_PATH")
  caller_dir <- fs::path(tempdir(), "rt-conf-caller")
  withr::local_envvar(c(
    CONDA_PKGS_DIRS = fs::path(caller_dir, "pkgs"),
    MAMBA_PKGS_DIRS = fs::path(caller_dir, "pkgs"),
    CONDA_ENVS_PATH = fs::path(caller_dir, "envs")
  ))
  rscript <- rscript_path()
  same_path <- function(a, b) {
    return(path_is_within(a, b) && path_is_within(b, a))
  }

  child_results <- list(
    run = condathis::run(
      rscript,
      rscript_print_env_args(),
      env_name = env_name,
      method = conformance_backend,
      verbose = "silent"
    ),
    run_bin = condathis::run_bin(
      rscript,
      rscript_print_env_args(),
      env_name = env_name,
      method = conformance_backend,
      verbose = "silent"
    ),
    run_pipeline = condathis::run_pipeline(
      condathis::run_step(rscript, rscript_print_env_args()),
      condathis::run_step(rscript, rscript_cat_args()),
      env_name = env_name,
      method = conformance_backend,
      verbose = "silent"
    )
  )
  for (fn_name in names(child_results)) {
    child_env <- parse_env_output(
      condathis::parse_output(child_results[[fn_name]])
    )
    expect_true("CONDA_PREFIX" %in% names(child_env), info = fn_name)
    expect_identical(
      fs::path_real(child_env[["CONDA_PREFIX"]]),
      fs::path_real(env_dir),
      info = fn_name
    )
    for (var in leaked_vars) {
      value <- child_env[[var]] %||% ""
      for (micromamba_dir in micromamba_dirs) {
        expect_false(
          path_is_within(value, micromamba_dir),
          info = paste0(fn_name, ": ", var, "=", value)
        )
      }
      expect_false(
        path_is_within(value, caller_dir),
        info = paste0(fn_name, ": ", var, "=", value)
      )
    }
    # ?register_backend, "Child processes": for a backend other than
    # micromamba, CONDA_ENVS_PATH is the parent of the environment
    # directory, and the package-cache variables are `<root>/conda-pkgs`,
    # a directory condathis owns and clean_cache() empties.
    expect_true(
      same_path(child_env[["CONDA_ENVS_PATH"]], fs::path_dir(env_dir)),
      info = paste0(fn_name, ": ", child_env[["CONDA_ENVS_PATH"]])
    )
    conda_pkgs <- fs::path(conformance_root(), "conda-pkgs")
    for (var in c("CONDA_PKGS_DIRS", "MAMBA_PKGS_DIRS")) {
      expect_true(
        same_path(child_env[[var]] %||% "", conda_pkgs),
        info = paste0(fn_name, ": ", var, "=", child_env[[var]])
      )
    }
  }
})

test_that("an environment given by env_path() runs with the backend's activation", {
  # A backend whose object has `backend_resolve_run_in_dir()` runs
  # commands in an environment given by its directory, with method = the
  # backend (with "auto", micromamba comes first, and this workflow never
  # installs it). The environment is only read: here an environment of
  # this backend, given by its directory.
  expect_true(
    "backend_resolve_run_in_dir" %in% names(conformance_new_backend())
  )
  env_name <- "rt-conf-env-path"
  defer_remove_env(env_name)
  create_polyglot_env(env_name)
  env_dir <- condathis::get_env_dir(env_name, method = conformance_backend)
  ep <- condathis::env_path(env_dir)
  files_before <- list.files(env_dir, recursive = TRUE, all.files = TRUE)
  for (fn in c("run", "run_bin")) {
    res <- getExportedValue("condathis", fn)(
      "polyglot",
      env_name = ep,
      method = conformance_backend,
      verbose = "silent"
    )
    expect_identical(res$status, 0L, info = fn)
    expect_identical(
      condathis::parse_output(res)[[1L]],
      polyglot_first_line(),
      info = fn
    )
  }
  rscript <- rscript_path()
  results <- list(
    run = condathis::run(
      rscript,
      rscript_print_env_args(),
      env_name = ep,
      method = conformance_backend,
      verbose = "silent"
    ),
    run_bin = condathis::run_bin(
      rscript,
      rscript_print_env_args(),
      env_name = ep,
      method = conformance_backend,
      verbose = "silent"
    ),
    run_pipeline = condathis::run_pipeline(
      condathis::run_step(rscript, rscript_print_env_args()),
      condathis::run_step(rscript, rscript_cat_args()),
      env_name = ep,
      method = conformance_backend,
      verbose = "silent"
    )
  )
  for (fn in names(results)) {
    child_env <- parse_env_output(condathis::parse_output(results[[fn]]))
    expect_identical(
      fs::path_real(child_env[["CONDA_PREFIX"]]),
      fs::path_real(env_dir),
      info = fn
    )
    # The environment is named as micromamba names a directory: by its own
    # name, as its parent directory is named `envs`.
    expect_identical(child_env[["CONDA_DEFAULT_ENV"]], env_name, info = fn)
    # The backend's own directories, as for its environments by name.
    expect_true(
      path_is_within(child_env[["CONDA_ENVS_PATH"]], fs::path_dir(env_dir)) &&
        path_is_within(fs::path_dir(env_dir), child_env[["CONDA_ENVS_PATH"]]),
      info = fn
    )
  }
  expect_identical(
    list.files(env_dir, recursive = TRUE, all.files = TRUE),
    files_before
  )
  expect_false(file.exists(condathis::micromamba_bin_path()))
})

# --- 9. conda-forge, end to end ---------------------------------------------

test_that("a conda-forge workflow runs end to end", {
  # The only test here that uses the network. It runs on every test
  # machine (the zero-skip rule).
  env_name <- "rt-conf-forge"
  defer_remove_env(env_name)

  res <- condathis::create_env(
    "xz",
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(res$status, 0L)
  expect_true(condathis::env_exists(env_name, method = conformance_backend))

  res <- condathis::install_packages(
    "ripgrep",
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(res$status, 0L)

  pkgs <- condathis::list_packages(env_name, method = conformance_backend)
  expect_true(all(c("xz", "ripgrep") %in% pkgs$name))
  # The channel is the name, as micromamba lists it (D09).
  expect_identical(pkgs$channel[pkgs$name == "xz"], "conda-forge")
  expect_true(condathis::validate_env(
    "xz",
    "conda-forge::ripgrep",
    env_name = env_name,
    method = conformance_backend
  ))

  # A request the environment already satisfies needs no solve: the
  # channel URL that the backend reports matches "conda-forge".
  expect_no_warning(
    res <- condathis::create_env(
      "xz",
      env_name = env_name,
      method = conformance_backend,
      verbose = "silent"
    )
  )
  expect_identical(res$cmd, NA_character_)

  # The platform of the packages, from list_packages()$platform: another
  # platform is refused, and validate_env() reports it.
  env_platforms <- setdiff(unique(pkgs$platform), "noarch")
  expect_identical(env_platforms, r_build_platform())
  other_platform <- setdiff(c("linux-64", "win-64"), env_platforms)[[1L]]
  expect_error(
    condathis::create_env(
      "xz",
      env_name = env_name,
      platform = other_platform,
      method = conformance_backend,
      verbose = "silent"
    ),
    class = "condathis_create_env_platform_mismatch"
  )
  res <- condathis::validate_env(
    "xz",
    env_name = env_name,
    platform = other_platform,
    method = conformance_backend,
    error = "continue"
  )
  expect_identical(attr(res, "reason"), "platform_mismatch")

  xz_res <- condathis::run(
    "xz",
    "--version",
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(xz_res$status, 0L)
  expect_match(
    condathis::parse_output(xz_res)[[1L]],
    "xz (XZ Utils)",
    fixed = TRUE
  )
  rg_res <- condathis::run_bin(
    "rg",
    "--version",
    env_name = env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(rg_res$status, 0L)
  expect_match(condathis::parse_output(rg_res)[[1L]], "^ripgrep ")

  # Writable stdin through a two-step pipeline in one environment.
  pipe_res <- condathis::run_pipeline(
    condathis::run_step("xz", "-c"),
    condathis::run_step("xz", "-dc"),
    env_name = env_name,
    method = conformance_backend,
    stdin = "|",
    input = "hello from rattler\n",
    verbose = "silent"
  )
  expect_identical(pipe_res$statuses, c(0L, 0L))
  expect_identical(condathis::parse_output(pipe_res), "hello from rattler")

  # Steps in two different environments of this backend.
  polyglot_name <- "rt-conf-forge-polyglot"
  defer_remove_env(polyglot_name)
  create_polyglot_env(polyglot_name)
  cross_res <- condathis::run_pipeline(
    condathis::run_step("polyglot", env_name = polyglot_name),
    condathis::run_step("rg", "^System detected", env_name = env_name),
    method = conformance_backend,
    verbose = "silent"
  )
  expect_identical(condathis::parse_output(cross_res), polyglot_first_line())

  condathis::remove_env(
    polyglot_name,
    method = conformance_backend,
    verbose = "silent"
  )
  condathis::remove_env(
    env_name,
    method = conformance_backend,
    verbose = "silent"
  )
  expect_false(condathis::env_exists(env_name, method = conformance_backend))
  expect_false(condathis::env_exists(
    polyglot_name,
    method = conformance_backend
  ))
  expect_false(fs::file_exists(condathis::micromamba_bin_path()))
})
