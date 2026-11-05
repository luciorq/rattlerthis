# Parity of channel priority (spec section 3.3 and 6.2, row
# test-parity-priority.R): the six-case grid on the channels `[chA, chB]`
# (strict, flexible and disabled priority; specs `foo` and `bar`), for
# `create_env()`, `backend_can_solve()` and `install_packages()`, with
# `method = "micromamba"` and `method = "rattler"`. chA has foo 1.0; chB
# has foo 2.0 and bar 1.0, which needs foo >=2.
#
# Environments are in the process sandbox (setup.R), named
# `rt-pprio-<case>-mm` and `rt-pprio-<case>-rt`.

# The grid: priority, spec, and the packages both backends install from
# `[chA, chB]` (`NA` for a request that does not solve).
priority_grid <- data.frame(
  priority = rep(c("strict", "flexible", "disabled"), each = 2L),
  spec = rep(c("foo", "bar"), times = 3L),
  expected = c(
    "foo 1.0 chA",
    NA,
    "foo 1.0 chA",
    "bar 1.0 chB|foo 2.0 chB",
    "foo 2.0 chB",
    "bar 1.0 chB|foo 2.0 chB"
  ),
  stringsAsFactors = FALSE
)

# Creates `env_name` with `spec` and returns `"name version channel"` of
# its packages joined with `|`, or the error.
priority_create <- function(env_name, spec, channels, priority, method) {
  captured <- psolve_capture(condathis::create_env(
    spec,
    env_name = env_name,
    channels = channels,
    channel_priority = priority,
    method = method,
    verbose = "silent"
  ))
  if (isFALSE(is.null(captured$error))) {
    return(list(packages = NA_character_, error = captured$error))
  }
  return(list(
    packages = paste(psolve_summary(env_name, method), collapse = "|"),
    error = NULL
  ))
}

test_that("create_env() solves the priority grid on [chA, chB] alike", {
  local_parity_micromamba()
  channels <- c(channel_url("chA"), channel_url("chB"))
  for (i in seq_len(nrow(priority_grid))) {
    case <- priority_grid[i, ]
    label <- paste(case$priority, case$spec)
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(
        paste0("rt-pprio-", case$priority, "-", case$spec),
        method
      )
      defer_remove_env(env_name, method = method)
      seen[[method]] <- priority_create(
        env_name,
        spec = case$spec,
        channels = channels,
        priority = case$priority,
        method = method
      )
      seen[[method]]$exists <- condathis::env_exists(env_name, method = method)
    }
    expect_identical(seen$micromamba$packages, case$expected, label = label)
    expect_identical(seen$rattler$packages, case$expected, label = label)
    if (is.na(case$expected)) {
      psolve_expect_same_failure(
        seen$micromamba$error,
        seen$rattler$error,
        rattler_kind = "solve"
      )
      expect_s3_class(seen$rattler$error, "condathis_create_env_failed")
    }
    expect_identical(seen$micromamba$exists, isFALSE(is.na(case$expected)))
    expect_identical(seen$rattler$exists, isFALSE(is.na(case$expected)))
  }
})

test_that("backend_can_solve() answers the priority grid alike", {
  local_parity_micromamba()
  channels <- c(channel_url("chA"), channel_url("chB"))
  for (i in seq_len(nrow(priority_grid))) {
    case <- priority_grid[i, ]
    answers <- vapply(
      psolve_methods,
      function(method) {
        return(psolve_can_solve(
          method,
          packages = case$spec,
          channels = channels,
          channel_priority = case$priority,
          platform = r_build_platform()
        ))
      },
      logical(1L)
    )
    expect_identical(
      unname(answers),
      rep(isFALSE(is.na(case$expected)), 2L),
      label = paste(case$priority, case$spec)
    )
  }
})

test_that("the order of the channels decides under strict and flexible priority", {
  local_parity_micromamba()
  # `[chB, chA]`: foo is chB's first.
  channels <- c(channel_url("chB"), channel_url("chA"))
  for (priority in c("strict", "flexible", "disabled")) {
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-pprio-rev-", priority), method)
      defer_remove_env(env_name, method = method)
      seen[[method]] <- priority_create(
        env_name,
        spec = "foo",
        channels = channels,
        priority = priority,
        method = method
      )
    }
    expect_identical(seen$micromamba$packages, "foo 2.0 chB", label = priority)
    expect_identical(seen$rattler$packages, "foo 2.0 chB", label = priority)
  }

  # A channel named in a spec is added to the channels (after them); under
  # strict priority, a name is taken only from the first channel that has
  # it, so `<chB>::foo` cannot be met when chA comes first.
  qualified <- paste0(channel_url("chB"), "::foo")
  for (priority in c("strict", "disabled")) {
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-pprio-qual-", priority), method)
      defer_remove_env(env_name, method = method)
      seen[[method]] <- priority_create(
        env_name,
        spec = qualified,
        channels = channel_url("chA"),
        priority = priority,
        method = method
      )
    }
    if (identical(priority, "strict")) {
      expect_identical(seen$micromamba$packages, NA_character_)
      expect_identical(seen$rattler$packages, NA_character_)
      psolve_expect_same_failure(
        seen$micromamba$error,
        seen$rattler$error,
        rattler_kind = "solve"
      )
    } else {
      expect_identical(seen$micromamba$packages, "foo 2.0 chB")
      expect_identical(seen$rattler$packages, "foo 2.0 chB")
    }
  }
})

test_that("install_packages() follows the channel priority alike", {
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  channels <- c(chan_a, channel_url("chB"))
  for (priority in c("strict", "flexible", "disabled")) {
    seen <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-pprio-inst-", priority), method)
      defer_remove_env(env_name, method = method)
      condathis::create_env(
        "foo",
        env_name = env_name,
        channels = chan_a,
        method = method,
        verbose = "silent"
      )
      captured <- psolve_capture(condathis::install_packages(
        "bar",
        env_name = env_name,
        channels = channels,
        channel_priority = priority,
        method = method,
        verbose = "silent"
      ))
      seen[[method]] <- list(
        error = captured$error,
        warnings = captured$warnings,
        packages = paste(psolve_summary(env_name, method), collapse = "|")
      )
    }
    for (method in psolve_methods) {
      expect_identical(seen[[method]]$warnings, list(), label = method)
    }
    if (identical(priority, "strict")) {
      # Under strict priority foo comes only from chA: bar cannot be met,
      # and the environment is unchanged.
      psolve_expect_same_failure(
        seen$micromamba$error,
        seen$rattler$error,
        rattler_kind = "solve"
      )
      expect_s3_class(seen$rattler$error, "condathis_install_packages_failed")
      expect_identical(seen$micromamba$packages, "foo 1.0 chA")
      expect_identical(seen$rattler$packages, "foo 1.0 chA")
    } else {
      expect_null(seen$micromamba$error, label = priority)
      expect_null(seen$rattler$error, label = priority)
      expect_identical(
        seen$micromamba$packages,
        "bar 1.0 chB|foo 2.0 chB",
        label = priority
      )
      expect_identical(
        seen$rattler$packages,
        "bar 1.0 chB|foo 2.0 chB",
        label = priority
      )
    }
  }
})

test_that("an installed package of the requested channel is kept under strict priority alike", {
  # libsolv keeps installed packages whatever the channel priority: with
  # foo 2.0 of chB installed, `chB::foo` and [chA, chB] change nothing with
  # micromamba. rattler's check of strict priority refused it ("excluded by
  # strict channel priority"). A spec that the installed package does not
  # satisfy is still refused by both.
  local_parity_micromamba()
  chb_foo <- paste0(channel_url("chB"), "::foo")
  both <- c(channel_url("chA"), channel_url("chB"))
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-pprio-kept", method)
    defer_remove_env(env_name, method = method)
    condathis::create_env(
      chb_foo,
      env_name = env_name,
      channels = channel_url("chB"),
      method = method,
      verbose = "silent"
    )
    kept <- psolve_capture(condathis::install_packages(
      chb_foo,
      env_name = env_name,
      channels = both,
      channel_priority = "strict",
      method = method,
      verbose = "silent"
    ))
    expect_null(kept$error, label = method)
    newer <- psolve_capture(condathis::install_packages(
      paste0(chb_foo, "<2"),
      env_name = env_name,
      channels = both,
      channel_priority = "strict",
      method = method,
      verbose = "silent"
    ))
    expect_s3_class(newer$error, "condathis_install_packages_failed")
    seen[[method]] <- psolve_summary(env_name, method)
  }
  expect_identical(seen$rattler, seen$micromamba)
  expect_identical(seen$rattler, "foo 2.0 chB")
})
