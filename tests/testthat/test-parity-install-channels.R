# Parity of the channels of an install (spec sections 3.2 and 3.4, and
# 6.2, row test-parity-install-channels.R): `install_packages()` solves
# against only the channels of the call (micromamba's
# `--override-channels`) and keeps the installed packages, whatever their
# channel (D19); a channel named in a spec counts as given (N1); both
# backends write `conda-meta/history`, which condathis reads into channel
# URLs without a trailing slash; and both warn when an earlier channel is
# missing from the call (condathis's warning, now for every backend).
#
# Environments are in the process sandbox (setup.R), named
# `rt-pich-<test>-mm` and `rt-pich-<test>-rt`.

# Runs an install with `method` and returns what condathis reports: the
# error, the warnings, and the packages afterwards.
install_channels_step <- function(env_name, method, ...) {
  captured <- psolve_capture(condathis::install_packages(
    ...,
    env_name = env_name,
    method = method,
    verbose = "silent"
  ))
  return(list(
    error = captured$error,
    warning_classes = psolve_warning_classes(captured),
    warning_messages = vapply(
      captured$warnings,
      function(cnd) psolve_mask(conditionMessage(cnd), env = env_name),
      character(1L)
    ),
    packages = psolve_summary(env_name, method)
  ))
}

test_that("an install uses only the channels of the call and keeps installed packages (D19)", {
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  chan_b <- channel_url("chB")
  chan_c <- channel_url("chC")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-pich-d19", method)
    defer_remove_env(env_name, method = method)
    condathis::create_env(
      "bar",
      env_name = env_name,
      channels = chan_b,
      method = method,
      verbose = "silent"
    )
    steps <- list()
    # baz from chC only: foo and bar of chB stay.
    steps$baz <- install_channels_step(
      env_name,
      method,
      "baz",
      channels = chan_c
    )
    # foo from chA only: the installed foo 2.0 of chB satisfies the
    # request, and bar needs it.
    steps$foo <- install_channels_step(
      env_name,
      method,
      "foo",
      channels = chan_a
    )
    # foo <2 from chA: foo 1.0 replaces 2.0, and bar, which needs foo >=2
    # and has no other build, is removed.
    steps$downgrade <- install_channels_step(
      env_name,
      method,
      "foo<2",
      channels = chan_a
    )
    # With the earlier channels given, nothing is missing: no warning.
    steps$all <- install_channels_step(
      env_name,
      method,
      "bar",
      channels = c(chan_b, chan_a, chan_c),
      channel_priority = "disabled"
    )
    seen[[method]] <- steps
  }
  expect_identical(seen$rattler, seen$micromamba)
  rt <- seen$rattler
  for (step in names(rt)) {
    expect_null(rt[[step]]$error, label = step)
  }
  expect_identical(
    rt$baz$packages,
    c("bar 1.0 chB", "baz 1.0 chC", "foo 2.0 chB")
  )
  expect_identical(rt$foo$packages, rt$baz$packages)
  expect_identical(rt$downgrade$packages, c("baz 1.0 chC", "foo 1.0 chA"))
  expect_identical(
    rt$all$packages,
    c("bar 1.0 chB", "baz 1.0 chC", "foo 2.0 chB")
  )
  # The channels the environment had and the call does not name.
  for (step in c("baz", "foo", "downgrade")) {
    expect_identical(
      rt[[step]]$warning_classes[[1L]],
      "condathis_install_packages_missing_previous_channels",
      label = step
    )
  }
  expect_match(
    rt$baz$warning_messages,
    "Environment <env> was previously installed using channel",
    fixed = TRUE
  )
  expect_match(rt$baz$warning_messages, chan_b, fixed = TRUE)
  expect_false(grepl(chan_c, rt$baz$warning_messages, fixed = TRUE))
  expect_match(rt$foo$warning_messages, chan_b, fixed = TRUE)
  expect_match(rt$foo$warning_messages, chan_c, fixed = TRUE)
  expect_identical(rt$all$warning_classes, NULL)
})

test_that("a channel named in a spec counts as a channel of the call (N1)", {
  local_parity_micromamba()
  chan_b <- channel_url("chB")
  chan_c <- channel_url("chC")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-pich-spec", method)
    defer_remove_env(env_name, method = method)
    condathis::create_env(
      "bar",
      env_name = env_name,
      channels = chan_b,
      method = method,
      verbose = "silent"
    )
    steps <- list()
    # chC comes from the spec: baz is found, and chB is given.
    steps$qualified <- install_channels_step(
      env_name,
      method,
      paste0(chan_c, "::baz"),
      channels = chan_b
    )
    # Now both chB and chC are earlier channels; a spec of chC alone
    # leaves chB out.
    steps$only_spec <- install_channels_step(
      env_name,
      method,
      paste0(chan_c, "::baz"),
      channels = channel_url("chA")
    )
    seen[[method]] <- steps
  }
  expect_identical(seen$rattler, seen$micromamba)
  rt <- seen$rattler
  expect_null(rt$qualified$error)
  expect_identical(rt$qualified$warning_classes, NULL)
  expect_identical(
    rt$qualified$packages,
    c("bar 1.0 chB", "baz 1.0 chC", "foo 2.0 chB")
  )
  expect_null(rt$only_spec$error)
  expect_identical(
    rt$only_spec$warning_classes[[1L]],
    "condathis_install_packages_missing_previous_channels"
  )
  expect_match(rt$only_spec$warning_messages, chan_b, fixed = TRUE)
  expect_false(grepl(chan_c, rt$only_spec$warning_messages, fixed = TRUE))
})

test_that("both backends write the history condathis reads the channels from", {
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  chan_b <- channel_url("chB")
  chan_c <- channel_url("chC")
  history_channels <- psolve_condathis("get_env_history_channels")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-pich-history", method)
    defer_remove_env(env_name, method = method)
    condathis::create_env(
      "foo",
      env_name = env_name,
      channels = chan_a,
      method = method,
      verbose = "silent"
    )
    suppressWarnings(condathis::install_packages(
      "bar",
      env_name = env_name,
      channels = c(chan_b, chan_c),
      method = method,
      verbose = "silent"
    ))
    # Nothing to do: a revision with only the requested specs.
    suppressWarnings(condathis::install_packages(
      "foo",
      env_name = env_name,
      channels = chan_b,
      method = method,
      verbose = "silent"
    ))
    env_dir <- psolve_env_dir(env_name, method)
    raw <- read_history(env_dir)
    seen[[method]] <- list(
      revisions = psolve_history(env_name, method),
      channels = history_channels(env_dir),
      crlf = raw$crlf,
      headers = grep("^==> ", raw$lines, value = TRUE),
      cmd_lines = grep("^# (cmd|conda version):", raw$lines, value = TRUE)
    )
  }
  mm <- seen$micromamba
  rt <- seen$rattler
  # The same `+`/`-` lines and requested specs in every revision. Within a
  # revision the lines are compared sorted: rattler orders unrelated
  # packages otherwise than libsolv (a difference RT-1 flagged; proposed
  # R-row "history line order").
  expect_identical(rt$revisions, mm$revisions)
  expect_identical(
    rt$revisions,
    list(
      c(
        paste0("+", chan_a, "/noarch::foo-1.0-0"),
        "# update specs: [\"foo\"]"
      ),
      c(
        paste0("+", chan_b, "/noarch::bar-1.0-0"),
        paste0("+", chan_b, "/noarch::foo-2.0-0"),
        paste0("-", chan_a, "/noarch::foo-1.0-0"),
        "# update specs: [\"bar\"]"
      ),
      "# update specs: [\"foo\"]"
    )
  )
  # Read by condathis into the channel URLs, without a trailing slash.
  expect_identical(rt$channels, mm$channels)
  expect_identical(sort(rt$channels), sort(c(chan_a, chan_b)))
  expect_false(any(endsWith(rt$channels, "/")))
  # One header per revision, `==> <local time> <==`; CRLF line ends on
  # Windows, as micromamba writes them.
  expect_length(rt$headers, 3L)
  expect_length(mm$headers, 3L)
  expect_match(
    rt$headers,
    "^==> [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} <==$"
  )
  expect_identical(rt$crlf, is_windows())
  expect_identical(mm$crlf, is_windows())
  # rattler writes no `# cmd:` and no `# conda version:` lines (R-18).
  expect_identical(rt$cmd_lines, character(0L))
  expect_length(grep("^# cmd: ", mm$cmd_lines), 3L)
  expect_length(grep("^# conda version: ", mm$cmd_lines), 3L)
})

test_that("additional channels come after the call's channels and before a file's", {
  # condathis passes `additional_channels` to the backend apart from
  # `channels`; both backends solve against `channels`, then
  # `additional_channels`, then the channels of a YAML file.
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  chan_b <- channel_url("chB")
  chan_c <- channel_url("chC")
  yaml_file <- file.path(withr::local_tempdir(pattern = "rt-pich-"), "add.yml")
  writeLines(
    c("channels:", paste0("  - ", chan_b), "dependencies:", "  - foo"),
    yaml_file
  )
  create_step <- function(env_name, method, ...) {
    captured <- psolve_capture(condathis::create_env(
      ...,
      env_name = env_name,
      method = method,
      verbose = "silent"
    ))
    exists <- isTRUE(condathis::env_exists(env_name, method = method))
    return(list(
      error = captured$error,
      warning_classes = psolve_warning_classes(captured),
      packages = if (isTRUE(exists)) psolve_summary(env_name, method)
    ))
  }
  seen <- list()
  for (method in psolve_methods) {
    env_names <- vapply(
      c("disabled", "strict", "install", "yaml"),
      function(step) psolve_env_name(paste0("rt-pich-add-", step), method),
      character(1L)
    )
    for (env_name in env_names) {
      defer_remove_env(env_name, method = method)
    }
    steps <- list()
    # bar is only in the additional channel chB; it needs foo >=2, which
    # only chB has.
    steps$disabled <- create_step(
      env_names[["disabled"]],
      method,
      "bar",
      channels = chan_a,
      additional_channels = chan_b,
      channel_priority = "disabled"
    )
    # Strict priority: chA, the first channel with foo, is the only one
    # for foo, so bar cannot be met.
    steps$strict <- create_step(
      env_names[["strict"]],
      method,
      "bar",
      channels = chan_a,
      additional_channels = chan_b,
      channel_priority = "strict"
    )
    condathis::create_env(
      "baz",
      env_name = env_names[["install"]],
      channels = chan_c,
      method = method,
      verbose = "silent"
    )
    steps$install <- install_channels_step(
      env_names[["install"]],
      method,
      "foo",
      channels = chan_c,
      additional_channels = chan_a
    )
    # chC (the call's), chA (additional), chB (the file's): strict
    # priority takes foo from chA.
    steps$yaml <- create_step(
      env_names[["yaml"]],
      method,
      env_file = yaml_file,
      channels = chan_c,
      additional_channels = chan_a
    )
    seen[[method]] <- steps
  }
  for (method in psolve_methods) {
    steps <- seen[[method]]
    expect_null(steps$disabled$error, label = method)
    expect_identical(
      steps$disabled$packages,
      c("bar 1.0 chB", "foo 2.0 chB"),
      label = method
    )
    expect_s3_class(steps$strict$error, "condathis_create_env_failed")
    expect_null(steps$strict$packages, label = method)
    expect_null(steps$install$error, label = method)
    expect_identical(
      steps$install$packages,
      c("baz 1.0 chC", "foo 1.0 chA"),
      label = method
    )
    expect_null(steps$yaml$error, label = method)
    expect_identical(steps$yaml$packages, "foo 1.0 chA", label = method)
  }
  psolve_expect_same_failure(
    seen$micromamba$strict$error,
    seen$rattler$strict$error,
    rattler_kind = "solve"
  )
  for (step in c("disabled", "install", "yaml")) {
    expect_identical(
      seen$rattler[[step]]$warning_classes,
      seen$micromamba[[step]]$warning_classes,
      label = step
    )
  }
})

test_that("a local channel in a directory with a space works with both backends (R-36)", {
  # micromamba 2.10.0 cannot read a local channel whose path has a space,
  # given as a path or as a file:// URL ("Failed to parse URL"). condathis
  # gives micromamba another path to the same directory (a link below its
  # root on Linux and macOS, the 8.3 short path on Windows) and lists the
  # channel as the URL of the directory, with `%20`, as rattler gives it.
  # On a Windows volume without short names micromamba still fails.
  local_parity_micromamba()
  parent <- file.path(withr::local_tempdir(pattern = "rt-pich-"), "with space")
  dir.create(parent)
  file.copy(file.path(test_channels_dir(), "chA"), parent, recursive = TRUE)
  path <- normalizePath(file.path(parent, "chA"), winslash = "/")
  forms <- list(path = path, url = file_url(path))
  listed_channel <- gsub(" ", "%20", file_url(path), fixed = TRUE)
  micromamba_works <- isFALSE(is_windows()) ||
    isFALSE(grepl(" ", utils::shortPathName(path), fixed = TRUE))
  for (form in names(forms)) {
    pkgs <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(paste0("rt-pich-space-", form), method)
      defer_remove_env(env_name, method = method)
      captured <- psolve_capture(condathis::create_env(
        "foo",
        env_name = env_name,
        channels = forms[[form]],
        method = method,
        verbose = "silent"
      ))
      info <- paste(form, method)
      if (identical(method, "micromamba") && isFALSE(micromamba_works)) {
        expect_s3_class(captured$error, "condathis_create_env_failed")
        expect_match(
          conditionMessage(captured$error),
          "Failed to parse URL",
          fixed = TRUE,
          info = info
        )
        expect_false(condathis::env_exists(env_name, method = method))
        next
      }
      expect_null(captured$error, info = info)
      pkgs[[method]] <- psolve_packages(env_name, method)
      expect_identical(pkgs[[method]]$name, "foo", info = info)
      expect_identical(pkgs[[method]]$channel, listed_channel, info = info)
    }
    if (isTRUE(micromamba_works)) {
      expect_identical(pkgs$rattler, pkgs$micromamba, info = form)
    }
  }
})
