# Parity of environment files (spec sections 3.5 and 6.2, row
# test-parity-envfile.R): `create_env(env_file = )` with
# `method = "micromamba"` and `method = "rattler"`, on the fixtures of
# fixtures/envfiles (see `envfile_fixture()`): YAML files (e1 to e4, e12),
# a plain spec list (e5), an explicit file (e6), a conda-lock file (e7), a
# mambajs lock file (e10), pip packages without pip or python (e8, e9; the
# pip steps themselves are in test-parity-pip.R), plus an explicit file
# with a wrong hash (e11). Both
# backends must build the same environments: command-line channels first,
# selectors for the machine, no solve for explicit and lock files. YAML
# `variables:` are used by neither backend (condathis runs micromamba with
# `--no-env`).
#
# Environments are in the process sandbox (setup.R), named
# `rt-penv-<fixture>-mm` and `rt-penv-<fixture>-rt`.

# Creates an environment from a fixture with `method`; returns the error
# (or `NULL`), the packages (`"name version channel"`) and whether the
# environment and its directory exist afterwards.
envfile_create <- function(env_name, fixture, method, ...) {
  captured <- psolve_capture(condathis::create_env(
    env_file = envfile_fixture(fixture),
    env_name = env_name,
    method = method,
    verbose = "silent",
    ...
  ))
  exists <- isTRUE(condathis::env_exists(env_name, method = method))
  return(list(
    error = captured$error,
    warnings = captured$warnings,
    packages = if (isTRUE(exists)) psolve_summary(env_name, method),
    exists = exists,
    dir = fs::dir_exists(condathis::get_env_dir(env_name, method = method))
  ))
}

# The packages e3.yml gives on this machine: its selectors follow the
# machine's platform (micromamba 2.10.0 does so also with `--platform`).
envfile_e3_packages <- function() {
  if (isTRUE(is_windows())) {
    return("baz 1.0 chC")
  }
  if (isTRUE(is_macos())) {
    return(c("baz 1.0 chC", "devtool 1.0 chD"))
  }
  return(c("baz 1.0 chC", "foo 1.0 chA"))
}

# The packages e7-lock.yml gives for a platform: baz everywhere, foo on
# linux-64 only.
envfile_e7_packages <- function(platform) {
  if (identical(platform, "linux-64")) {
    return(c("baz 1.0 chC", "foo 1.0 chA"))
  }
  return("baz 1.0 chC")
}

test_that("environment files build the same environments on both backends", {
  local_parity_micromamba()
  withr::local_envvar(ENVFILE_CHANNEL_DIR = channel_url())
  channels <- c(channel_url("chA"), channel_url("chC"))
  # The fixture and the packages both backends install from it with
  # `channels = c(chA, chC)`.
  cases <- list(
    # `name:` is ignored; the command-line chA comes before the file's chB.
    e1.yml = "foo 1.0 chA",
    # `nodefaults` is dropped.
    e2.yml = "foo 1.0 chA",
    e3.yml = envfile_e3_packages(),
    e4.yml = "foo 1.0 chA",
    e5.txt = c("baz 1.0 chC", "foo 1.0 chA"),
    # No solve: the URLs of the file, whatever the channels.
    e6.txt = c("baz 1.0 chC", "foo 1.0 chA"),
    # The packages of the platform micromamba and rattler solve for here.
    `e7-lock.yml` = envfile_e7_packages(r_build_platform()),
    # `${ENVFILE_CHANNEL_DIR}/chC`, expanded from the environment.
    `e12-envvar.yml` = "baz 1.0 chC"
  )
  for (fixture in names(cases)) {
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(
        paste0("rt-penv-", sub("[.].*$", "", fixture)),
        method
      )
      defer_remove_env(env_name, method = method)
      seen[[method]] <- envfile_create(
        env_name,
        fixture,
        method,
        channels = channels
      )
    }
    for (method in psolve_methods) {
      label <- paste(method, fixture)
      expect_null(seen[[method]]$error, label = label)
      expect_identical(seen[[method]]$warnings, list(), label = label)
      expect_identical(seen[[method]]$packages, cases[[fixture]], label = label)
    }
  }
})

test_that("command-line channels come first, and explicit files ignore them", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    steps <- list()
    # Without foo on the command line, e1's own chB gives foo 2.0.
    name_e1 <- psolve_env_name("rt-penv-e1-chc", method)
    defer_remove_env(name_e1, method = method)
    steps$e1 <- envfile_create(
      name_e1,
      "e1.yml",
      method,
      channels = channel_url("chC")
    )
    # A plain list is solved against the command-line channels only: baz
    # is not in chA.
    name_e5 <- psolve_env_name("rt-penv-e5-cha", method)
    defer_remove_env(name_e5, method = method)
    steps$e5 <- envfile_create(
      name_e5,
      "e5.txt",
      method,
      channels = channel_url("chA")
    )
    # An explicit file needs no channel: conda-forge is never read.
    name_e6 <- psolve_env_name("rt-penv-e6-cf", method)
    defer_remove_env(name_e6, method = method)
    steps$e6 <- envfile_create(
      name_e6,
      "e6.txt",
      method,
      channels = "conda-forge"
    )
    seen[[method]] <- steps
  }
  for (method in psolve_methods) {
    expect_null(seen[[method]]$e1$error, label = method)
    expect_identical(seen[[method]]$e1$packages, "foo 2.0 chB", label = method)
    expect_false(seen[[method]]$e5$exists, label = method)
    expect_false(seen[[method]]$e5$dir, label = method)
    expect_null(seen[[method]]$e6$error, label = method)
    expect_identical(
      seen[[method]]$e6$packages,
      c("baz 1.0 chC", "foo 1.0 chA"),
      label = method
    )
  }
  psolve_expect_same_failure(
    seen$micromamba$e5$error,
    seen$rattler$e5$error,
    rattler_kind = "solve"
  )
  expect_s3_class(seen$rattler$e5$error, "condathis_create_env_failed")
})

test_that("a lock file gives the packages of the target platform", {
  local_parity_micromamba()
  get_marker_platform <- psolve_condathis("read_backend_marker_platform")
  for (platform in c("linux-64", "win-64", "osx-arm64")) {
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-penv-e7-", platform), method)
      defer_remove_env(env_name, method = method)
      seen[[method]] <- envfile_create(
        env_name,
        "e7-lock.yml",
        method,
        channels = channel_url("chA"),
        platform = platform
      )
      seen[[method]]$marker <- get_marker_platform(
        psolve_env_dir(env_name, method)
      )
    }
    for (method in psolve_methods) {
      label <- paste(method, platform)
      expect_null(seen[[method]]$error, label = label)
      expect_identical(
        seen[[method]]$packages,
        envfile_e7_packages(platform),
        label = label
      )
      expect_identical(seen[[method]]$marker, platform, label = label)
    }
  }
})

test_that("YAML selectors follow the machine, also for another platform", {
  local_parity_micromamba()
  # micromamba 2.10.0 evaluates `sel()` for its own platform, also with
  # `--platform`; rattler does the same. The packages are noarch, so the
  # environment builds for any platform.
  other_platform <- if (isTRUE(is_windows())) "linux-64" else "win-64"
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-penv-e3-other", method)
    defer_remove_env(env_name, method = method)
    seen[[method]] <- envfile_create(
      env_name,
      "e3.yml",
      method,
      channels = channel_url("chA"),
      platform = other_platform
    )
    seen[[method]]$marker <- psolve_condathis("read_backend_marker_platform")(
      psolve_env_dir(env_name, method)
    )
  }
  for (method in psolve_methods) {
    expect_null(seen[[method]]$error, label = method)
    expect_identical(
      seen[[method]]$packages,
      envfile_e3_packages(),
      label = method
    )
    expect_identical(seen[[method]]$marker, other_platform, label = method)
  }
})

test_that("YAML variables are used by neither backend", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-penv-e4-vars", method)
    defer_remove_env(env_name, method = method)
    created <- envfile_create(
      env_name,
      "e4.yml",
      method,
      channels = channel_url("chA")
    )
    ran <- condathis::run(
      rscript_path(),
      "-e",
      "cat(Sys.getenv(c('MY_VAR', 'LOWER_VAR', 'NUM', 'EMPTY'), 'unset'))",
      env_name = env_name,
      method = method,
      verbose = "silent"
    )
    seen[[method]] <- list(
      created = created,
      state = file.exists(file.path(
        psolve_env_dir(env_name, method),
        "conda-meta",
        "state"
      )),
      output = condathis::parse_output(ran)
    )
  }
  for (method in psolve_methods) {
    expect_null(seen[[method]]$created$error, label = method)
    expect_false(seen[[method]]$state, label = method)
    expect_identical(
      seen[[method]]$output,
      "unset unset unset unset",
      label = method
    )
  }
})

test_that("a byte order mark in a spec file is read as the C library reads it", {
  # libmamba trims the bytes around a spec that its C library does not
  # count as graphic: a UTF-8 byte order mark at the start of a file is
  # dropped on Linux and Windows and kept on macOS, where the first spec
  # then names no package. rattler does the same on each OS.
  local_parity_micromamba()
  spec_file <- file.path(withr::local_tempdir(pattern = "rt-penv-"), "bom.txt")
  writeBin(c(as.raw(c(0xef, 0xbb, 0xbf)), charToRaw("foo\n")), spec_file)
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-penv-bom", method)
    defer_remove_env(env_name, method = method)
    captured <- psolve_capture(condathis::create_env(
      env_file = spec_file,
      env_name = env_name,
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    ))
    exists <- isTRUE(condathis::env_exists(env_name, method = method))
    seen[[method]] <- list(
      error = captured$error,
      exists = exists,
      packages = if (isTRUE(exists)) psolve_summary(env_name, method)
    )
  }
  if (isTRUE(is_macos())) {
    for (method in psolve_methods) {
      expect_false(seen[[method]]$exists, label = method)
    }
    psolve_expect_same_failure(
      seen$micromamba$error,
      seen$rattler$error,
      rattler_kind = "solve"
    )
  } else {
    for (method in psolve_methods) {
      expect_null(seen[[method]]$error, label = method)
      expect_identical(seen[[method]]$packages, "foo 1.0 chA", label = method)
    }
  }
})

test_that("a mambajs lock file builds the same environment on both backends", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-penv-e10", method)
    defer_remove_env(env_name, method = method)
    seen[[method]] <- envfile_create(
      env_name,
      "e10-mambajs.json",
      method,
      channels = channel_url("chA")
    )
  }
  # The package of its channelInfo URL, without a solve; the command-line
  # channel is not used.
  for (method in psolve_methods) {
    expect_null(seen[[method]]$error, label = method)
    expect_identical(seen[[method]]$packages, "baz 1.0 chC", label = method)
  }
  # As for conda-lock files, micromamba writes no `# update specs` line.
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-penv-e10", method)
    history <- read_history(
      condathis::get_env_dir(env_name, method = method)
    )$lines
    expect_false(any(grepl("^# update specs", history)), label = method)
  }
})

test_that("pip packages of environment files without pip or python fail alike (R-8)", {
  local_parity_micromamba()
  channels <- channel_url("chA")
  seen <- list()
  for (fixture in c("e8-pip.yml", "e9-pip-lock.yml")) {
    for (method in psolve_methods) {
      env_name <- psolve_env_name(
        paste0("rt-penv-", sub("[-.].*$", "", fixture)),
        method
      )
      defer_remove_env(env_name, method = method)
      seen[[fixture]][[method]] <- envfile_create(
        env_name,
        fixture,
        method,
        channels = channels
      )
    }
  }
  # e8: the pip section adds `pip` to the specs, which chA does not have:
  # neither backend solves. e9: the lock file's Conda part installs, then
  # its pip step finds no python in the environment and fails (micromamba
  # runs an empty command word, rattler finds no program). Either way
  # condathis removes the new environment.
  kinds <- c(`e8-pip.yml` = "solve", `e9-pip-lock.yml` = "pip")
  for (fixture in names(seen)) {
    mm <- seen[[fixture]]$micromamba
    rt <- seen[[fixture]]$rattler
    psolve_expect_same_failure(mm$error, rt$error, kinds[[fixture]])
    expect_s3_class(rt$error, "condathis_create_env_failed")
    expect_false(inherits(rt$error, "condathis_backend_unsupported"))
    for (method in psolve_methods) {
      expect_false(seen[[fixture]][[method]]$exists, label = method)
      expect_false(seen[[fixture]][[method]]$dir, label = method)
    }
  }
  # rattler's pip step reports the missing program as a command that was
  # not found.
  rt_parent <- seen[["e9-pip-lock.yml"]]$rattler$error$parent
  expect_identical(rt_parent$status, 127L)
  expect_true(grepl("no python program", rt_parent$stderr, fixed = TRUE))
})

test_that("an explicit file with a wrong hash creates nothing on either backend", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-penv-e11", method)
    defer_remove_env(env_name, method = method)
    seen[[method]] <- envfile_create(
      env_name,
      "e11-badhash.txt",
      method,
      channels = channel_url("chA")
    )
  }
  for (method in psolve_methods) {
    expect_s3_class(seen[[method]]$error, "condathis_create_env_failed")
    expect_false(seen[[method]]$exists, label = method)
    expect_false(seen[[method]]$dir, label = method)
  }
  expect_true(rlang::cnd_inherits(
    seen$rattler$error,
    "rattlerthis_rattler_hash_mismatch"
  ))
  expect_identical(
    setdiff(class(seen$micromamba$error), psolve_micromamba_only_classes),
    class(seen$rattler$error)
  )
})
