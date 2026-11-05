# Parity of libmamba's pins and solver rules on installs (spec 6.2, row
# test-parity-pins.R, P-A3, and R-13's "one conflict case per solver
# rule"), with `method = "micromamba"` and `method = "rattler"`:
# * the python minor pin: with python installed, an install that needs
#   another python minor version fails, and an explicit `python=3.x`
#   request moves python;
# * `conda-meta/pinned`: a pin holds a package;
# * libmamba's pip rules: python brings pip, and pip brings python;
# * an installed package is kept when the request allows it, upgraded or
#   downgraded when the request needs it, and removed when no version of
#   it fits.
#
# The packages come from the channel `pyc` that helper-parity-solve.R
# generates (python 3.11.0 and 3.12.0 with a program micromamba can start,
# pip, needs312, lib 1.0 and 2.0, libuser, needslib2, libold). The
# packages of an environment are read from its records
# (`env_records()`): `micromamba list` starts python (see
# `psolve_python_files()`).
#
# Environments are in the process sandbox (setup.R), named
# `rt-ppin-<test>-mm` and `rt-ppin-<test>-rt`.

# `"name version"` of the package records of an environment.
pins_records <- function(env_name, method) {
  records <- env_records(psolve_env_dir(env_name, method))
  return(paste(records$name, records$version))
}

# Creates an environment of `specs` from the `pyc` channel.
pins_create <- function(env_name, method, ...) {
  condathis::create_env(
    ...,
    env_name = env_name,
    channels = psolve_channel("pyc"),
    method = method,
    verbose = "silent"
  )
  return(invisible(env_name))
}

# Installs into an environment from the `pyc` channel; returns the error
# (or `NULL`) and the packages afterwards.
pins_install <- function(env_name, method, ...) {
  captured <- psolve_capture(condathis::install_packages(
    ...,
    env_name = env_name,
    channels = psolve_channel("pyc"),
    method = method,
    verbose = "silent"
  ))
  return(list(
    error = captured$error,
    warnings = captured$warnings,
    packages = pins_records(env_name, method)
  ))
}

# Asserts the same outcome of one step on both backends: both fail (with
# condathis's classes, and rattler's solve error) or both succeed, and the
# environments have the same packages, `expected`.
pins_expect_same <- function(seen, step, expected, fails = FALSE) {
  mm <- seen$micromamba[[step]]
  rt <- seen$rattler[[step]]
  expect_identical(mm$packages, expected, label = paste("micromamba", step))
  expect_identical(rt$packages, expected, label = paste("rattler", step))
  if (isTRUE(fails)) {
    expect_s3_class(rt$error, "condathis_install_packages_failed")
    psolve_expect_same_failure(mm$error, rt$error, rattler_kind = "solve")
  } else {
    expect_null(mm$error, label = paste("micromamba", step))
    expect_null(rt$error, label = paste("rattler", step))
  }
  expect_identical(mm$warnings, list(), label = paste("micromamba", step))
  expect_identical(rt$warnings, list(), label = paste("rattler", step))
  return(invisible(NULL))
}

test_that("the installed python's minor version is pinned, and an explicit request moves it", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-ppin-python", method)
    defer_remove_env(env_name, method = method)
    pins_create(env_name, method, "python=3.11")
    steps <- list(created = list(packages = pins_records(env_name, method)))
    # needs312 needs python >=3.12: the pin `python 3.11.*` refuses it.
    steps$pinned <- pins_install(env_name, method, "needs312")
    # Asked for by name, python moves (and pip is requested with it).
    steps$moved <- pins_install(env_name, method, "python=3.12")
    steps$after <- pins_install(env_name, method, "needs312")
    seen[[method]] <- steps
    seen[[method]]$history <- psolve_history(env_name, method)
  }
  expect_identical(
    seen$micromamba$created$packages,
    c("pip 24.0", "python 3.11.0")
  )
  expect_identical(
    seen$rattler$created$packages,
    c("pip 24.0", "python 3.11.0")
  )
  pins_expect_same(
    seen,
    "pinned",
    c("pip 24.0", "python 3.11.0"),
    fails = TRUE
  )
  pins_expect_same(seen, "moved", c("pip 24.0", "python 3.12.0"))
  pins_expect_same(
    seen,
    "after",
    c("needs312 1.0", "pip 24.0", "python 3.12.0")
  )
  # The requested specs as libmamba writes them, pip included.
  specs_lines <- function(revisions) {
    return(vapply(
      revisions,
      function(lines) lines[[length(lines)]],
      character(1L)
    ))
  }
  expect_identical(
    specs_lines(seen$rattler$history),
    c(
      "# update specs: [\"python=3.11\", \"pip\"]",
      "# update specs: [\"python=3.12\", \"pip\"]",
      "# update specs: [\"needs312\"]"
    )
  )
  expect_identical(seen$rattler$history, seen$micromamba$history)
})

test_that("a conda-meta/pinned line holds a package", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-ppin-file", method)
    defer_remove_env(env_name, method = method)
    pins_create(env_name, method, "lib=1.0")
    pinned <- file.path(
      psolve_env_dir(env_name, method),
      "conda-meta",
      "pinned"
    )
    # Blank lines are skipped by both.
    writeLines(c("lib 1.0.*", ""), pinned)
    steps <- list()
    # The pin refuses what needs lib 2.
    steps$direct <- pins_install(env_name, method, "lib>=2")
    steps$dependent <- pins_install(env_name, method, "needslib2")
    # libuser 2.0 needs lib >=2: the pin makes it libuser 1.0.
    steps$older <- pins_install(env_name, method, "libuser")
    # A comment line: libmamba reads it as a pin and cannot parse it, so
    # every install into the environment fails; rattler skips it, as conda
    # does, and applies the other lines (proposed R-row "comments in
    # conda-meta/pinned").
    writeLines(c("# lib stays at 1.0", "lib 1.0.*"), pinned)
    steps$comment <- pins_install(env_name, method, "libold")
    seen[[method]] <- steps
  }
  pins_expect_same(seen, "direct", "lib 1.0", fails = TRUE)
  pins_expect_same(seen, "dependent", "lib 1.0", fails = TRUE)
  pins_expect_same(seen, "older", c("lib 1.0", "libuser 1.0"))
  expect_s3_class(
    seen$micromamba$comment$error,
    "condathis_install_packages_failed"
  )
  expect_match(
    conditionMessage(seen$micromamba$comment$error),
    "lib stays at",
    fixed = TRUE
  )
  expect_identical(
    seen$micromamba$comment$packages,
    c("lib 1.0", "libuser 1.0")
  )
  expect_null(seen$rattler$comment$error)
  expect_identical(
    seen$rattler$comment$packages,
    c("lib 1.0", "libold 1.0", "libuser 1.0")
  )
})

test_that("a byte order mark in conda-meta/pinned is read as the C library reads it", {
  # As for spec files (test-parity-envfile.R): on Linux and Windows the
  # byte order mark is dropped and the pin holds; on macOS it stays part of
  # the pin, which then names no package, and the install moves lib.
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-ppin-bom", method)
    defer_remove_env(env_name, method = method)
    pins_create(env_name, method, "lib=1.0")
    writeBin(
      c(as.raw(c(0xef, 0xbb, 0xbf)), charToRaw("lib 1.0.*\n")),
      file.path(psolve_env_dir(env_name, method), "conda-meta", "pinned")
    )
    seen[[method]] <- list(bom = pins_install(env_name, method, "needslib2"))
  }
  if (isTRUE(is_macos())) {
    pins_expect_same(seen, "bom", c("lib 2.0", "needslib2 1.0"))
  } else {
    pins_expect_same(seen, "bom", "lib 1.0", fails = TRUE)
  }
})

test_that("libmamba's pip rules: python brings pip, and pip brings python", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    python_env <- psolve_env_name("rt-ppin-python-pip", method)
    pip_env <- psolve_env_name("rt-ppin-pip-python", method)
    defer_remove_env(python_env, method = method)
    defer_remove_env(pip_env, method = method)
    pins_create(python_env, method, "python")
    pins_create(pip_env, method, "pip")
    seen[[method]] <- list(
      python = pins_records(python_env, method),
      pip = pins_records(pip_env, method)
    )
  }
  # Requesting python requests pip too (libmamba's
  # `create_install_request()`), and in a channel subdir that has pip,
  # python depends on pip and pip on python (libmamba's
  # `add_pip_as_python_dependency()`).
  expect_identical(seen$micromamba$python, c("pip 24.0", "python 3.12.0"))
  expect_identical(seen$rattler$python, seen$micromamba$python)
  expect_identical(seen$micromamba$pip, c("pip 24.0", "python 3.12.0"))
  expect_identical(seen$rattler$pip, seen$micromamba$pip)
})

test_that("installed packages are kept, upgraded, downgraded or removed alike (R-13)", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    steps <- list()
    # Kept: a request that any installed version meets changes nothing,
    # also when a newer version exists.
    kept <- psolve_env_name("rt-ppin-kept", method)
    defer_remove_env(kept, method = method)
    pins_create(kept, method, "lib=1.0")
    steps$kept <- pins_install(kept, method, "lib")
    steps$kept_dependency <- pins_install(kept, method, "libold")
    # Upgraded: the request needs the newer version, directly or through
    # the newest version of what is requested.
    upgraded <- psolve_env_name("rt-ppin-upgraded", method)
    defer_remove_env(upgraded, method = method)
    pins_create(upgraded, method, "lib=1.0")
    steps$upgraded <- pins_install(upgraded, method, "libuser")
    steps$upgraded_direct <- pins_install(upgraded, method, "lib>1")
    # Downgraded: a request that needs the older version of an installed
    # package; what depends on it is downgraded with it.
    downgraded <- psolve_env_name("rt-ppin-downgraded", method)
    defer_remove_env(downgraded, method = method)
    pins_create(downgraded, method, "libuser")
    steps$downgraded_start <- list(
      packages = pins_records(downgraded, method)
    )
    steps$downgraded <- pins_install(downgraded, method, "lib<2")
    # Removed: no version of an installed package fits the request.
    removed <- psolve_env_name("rt-ppin-removed", method)
    defer_remove_env(removed, method = method)
    pins_create(removed, method, "needslib2")
    steps$removed <- pins_install(removed, method, "libold")
    seen[[method]] <- steps
    seen[[method]]$removed_history <- psolve_history(removed, method)
  }
  pins_expect_same(seen, "kept", "lib 1.0")
  pins_expect_same(seen, "kept_dependency", c("lib 1.0", "libold 1.0"))
  pins_expect_same(seen, "upgraded", c("lib 2.0", "libuser 2.0"))
  pins_expect_same(seen, "upgraded_direct", c("lib 2.0", "libuser 2.0"))
  expect_identical(
    seen$rattler$downgraded_start$packages,
    c("lib 2.0", "libuser 2.0")
  )
  expect_identical(
    seen$micromamba$downgraded_start$packages,
    c("lib 2.0", "libuser 2.0")
  )
  pins_expect_same(seen, "downgraded", c("lib 1.0", "libuser 1.0"))
  pins_expect_same(seen, "removed", c("lib 1.0", "libold 1.0"))
  expect_identical(
    seen$rattler$removed_history,
    seen$micromamba$removed_history
  )
})
