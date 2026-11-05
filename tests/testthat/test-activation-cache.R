# The activation cache of the rattler backend (R-19): condathis caches
# micromamba's activation per environment, so an `activate.d` script does
# not run for every command, and rattler's `backend_resolve_run()` does the
# same (`rattler_activation()`). The cache is used until the environment
# changes (conda-meta, the activation's own files) or the environment the
# command starts from does (`base_env`, but for the per-call `TMPDIR`);
# condathis's cache of micromamba's activation follows the same changes
# (the last test).
#
# Environments are in the process sandbox (setup.R), named `rt-acache-*`.

# Writes an activate.d script into an environment that appends a line to
# `counter` every time it runs, and sets `RT_ACACHE_V` to `value` (and,
# with `tmp = TRUE`, `RT_ACACHE_TMP` to a path below the activation's
# TMPDIR).
acache_write_script <- function(prefix, counter, value, tmp = FALSE) {
  activate_dir <- file.path(prefix, "etc", "conda", "activate.d")
  dir.create(activate_dir, recursive = TRUE, showWarnings = FALSE)
  if (isTRUE(is_windows())) {
    lines <- c(
      paste0("@echo ran>> \"", normalizePath(counter, mustWork = FALSE), "\""),
      paste0("@set \"RT_ACACHE_V=", value, "\""),
      if (isTRUE(tmp)) "@set \"RT_ACACHE_TMP=%TMPDIR%\\rt-acache\""
    )
    writeLines(lines, file.path(activate_dir, "rt-acache.bat"))
  } else {
    lines <- c(
      paste0("echo ran >> '", counter, "'"),
      paste0("export RT_ACACHE_V='", value, "'"),
      if (isTRUE(tmp)) "export RT_ACACHE_TMP=\"$TMPDIR/rt-acache\""
    )
    writeLines(lines, file.path(activate_dir, "rt-acache.sh"))
  }
  return(invisible(NULL))
}

# How often the script of `acache_write_script()` ran.
acache_runs <- function(counter) {
  if (isFALSE(file.exists(counter))) {
    return(0L)
  }
  return(length(readLines(counter)))
}

# Prints the values of variables in the activated environment, with `fn`
# ("run", "run_bin" or "run_pipeline"), separated by `|`.
acache_values <- function(fn, env_name, vars, method = "rattler") {
  args <- c(
    "-e",
    paste0(
      "cat(Sys.getenv(c('",
      paste(vars, collapse = "', '"),
      "'), 'unset'), sep = '|')"
    )
  )
  res <- switch(
    fn,
    run = condathis::run(
      rscript_path(),
      args,
      env_name = env_name,
      method = method,
      verbose = "silent"
    ),
    run_bin = condathis::run_bin(
      rscript_path(),
      args,
      env_name = env_name,
      method = method,
      verbose = "silent"
    ),
    run_pipeline = condathis::run_pipeline(
      condathis::run_step(rscript_path(), args),
      condathis::run_step(rscript_path(), rscript_cat_args()),
      env_name = env_name,
      method = method,
      verbose = "silent"
    )
  )
  return(strsplit(condathis::parse_output(res)[[1L]], "|", fixed = TRUE)[[1L]])
}

test_that("an activation runs once per environment until the environment changes (R-19)", {
  env_name <- "rt-acache-env"
  defer_remove_env(env_name)
  condathis::create_env(
    "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  prefix <- condathis::get_env_dir(env_name, method = "rattler")
  counter <- withr::local_tempfile(pattern = "rt-acache-counter-")
  acache_write_script(prefix, counter, "one")

  # Every run function of condathis, three commands: one activation.
  for (fn in c("run_bin", "run_bin", "run", "run_pipeline")) {
    expect_identical(
      acache_values(fn, env_name, "RT_ACACHE_V"),
      "one",
      info = fn
    )
  }
  expect_identical(acache_runs(counter), 1L)

  # An edited activate.d script (same size): activated again, once.
  acache_write_script(prefix, counter, "two")
  for (i in 1:2) {
    expect_identical(acache_values("run_bin", env_name, "RT_ACACHE_V"), "two")
  }
  expect_identical(acache_runs(counter), 2L)

  # A new env_vars.d file.
  vars_dir <- file.path(prefix, "etc", "conda", "env_vars.d")
  dir.create(vars_dir, recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    list(RT_ACACHE_D = "dee"),
    file.path(vars_dir, "rt-acache.json"),
    auto_unbox = TRUE
  )
  expect_identical(
    acache_values("run", env_name, c("RT_ACACHE_V", "RT_ACACHE_D")),
    c("two", "dee")
  )
  expect_identical(acache_runs(counter), 3L)

  # An install changes conda-meta.
  condathis::install_packages(
    "baz",
    env_name = env_name,
    channels = channel_url("chC"),
    additional_channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  expect_identical(acache_values("run_bin", env_name, "RT_ACACHE_V"), "two")
  expect_identical(acache_runs(counter), 4L)

  # A variable of the session changes what the command starts from.
  withr::local_envvar(RT_ACACHE_SESSION = "new")
  expect_identical(
    acache_values("run_bin", env_name, c("RT_ACACHE_V", "RT_ACACHE_SESSION")),
    c("two", "new")
  )
  expect_identical(acache_values("run_bin", env_name, "RT_ACACHE_V"), "two")
  expect_identical(acache_runs(counter), 5L)
})

test_that("the stamp of an environment follows the contents of the activation's files", {
  prefix <- withr::local_tempdir(pattern = "rt-acache-stamp-")
  dir.create(file.path(prefix, "conda-meta"))
  writeLines(
    "==> 2026-01-01 00:00:00 <==",
    file.path(prefix, "conda-meta", "history")
  )
  activate_dir <- file.path(prefix, "etc", "conda", "activate.d")
  dir.create(activate_dir, recursive = TRUE)
  script <- if (isTRUE(is_windows())) "rt-acache.bat" else "rt-acache.sh"
  target <- file.path(prefix, "rt-acache-target")
  writeLines("one", target)
  if (isTRUE(is_windows())) {
    # A plain file: links need a privilege on Windows.
    file.copy(target, file.path(activate_dir, script))
  } else {
    # A script that is a link counts with its target's contents.
    file.symlink(target, file.path(activate_dir, script))
  }
  first <- rattler_activation_stamp(prefix)
  expect_identical(rattler_activation_stamp(prefix), first)
  expect_true(any(startsWith(first, "script|etc/conda/activate.d/")))
  # The same size, other contents.
  writeLines("two", target)
  if (isTRUE(is_windows())) {
    file.copy(target, file.path(activate_dir, script), overwrite = TRUE)
  }
  second <- rattler_activation_stamp(prefix)
  expect_false(identical(second, first))
  # A new record in conda-meta.
  writeLines("{}", file.path(prefix, "conda-meta", "x-1.0-0.json"))
  expect_false(identical(rattler_activation_stamp(prefix), second))
})

test_that("an activation that names the command's TMPDIR is not cached", {
  env_name <- "rt-acache-tmp"
  defer_remove_env(env_name)
  condathis::create_env(
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  prefix <- condathis::get_env_dir(env_name, method = "rattler")
  counter <- withr::local_tempfile(pattern = "rt-acache-counter-")
  acache_write_script(prefix, counter, "one", tmp = TRUE)
  for (i in 1:3) {
    values <- acache_values(
      "run_bin",
      env_name,
      c("RT_ACACHE_TMP", "TMPDIR")
    )
    # The path is below the TMPDIR of this very command.
    expect_identical(
      normalizePath(dirname(values[[1L]]), winslash = "/", mustWork = FALSE),
      normalizePath(values[[2L]], winslash = "/", mustWork = FALSE)
    )
  }
  expect_identical(acache_runs(counter), 3L)
})

test_that("a replaced or recreated environment is activated again", {
  env_name <- "rt-acache-again"
  defer_remove_env(env_name)
  counter <- withr::local_tempfile(pattern = "rt-acache-counter-")
  # "first" and "third" have the same size: the script's contents count.
  for (value in c("first", "second", "third")) {
    if (identical(value, "third")) {
      condathis::remove_env(env_name, method = "rattler", verbose = "silent")
    }
    condathis::create_env(
      "foo",
      env_name = env_name,
      channels = channel_url("chA"),
      method = "rattler",
      verbose = "silent",
      overwrite = TRUE
    )
    prefix <- condathis::get_env_dir(env_name, method = "rattler")
    acache_write_script(prefix, counter, value)
    for (i in 1:2) {
      expect_identical(
        acache_values("run_bin", env_name, "RT_ACACHE_V"),
        value,
        info = value
      )
    }
  }
  expect_identical(acache_runs(counter), 3L)
})

test_that("both backends run an activate.d script once for repeated run_bin() and run() calls (R-19)", {
  local_parity_micromamba()
  # R sets TZDIR on macOS the first time it formats a time; set it now, so
  # the session stays the same for every call of this test.
  invisible(format(Sys.time(), "%Z"))
  counters <- list()
  env_names <- list()
  for (method in psolve_methods) {
    env_names[[method]] <- psolve_env_name("rt-acache-par", method)
    defer_remove_env(env_names[[method]], method = method)
    condathis::create_env(
      "foo",
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    counters[[method]] <- withr::local_tempfile(
      pattern = paste0("rt-acache-", method, "-")
    )
    acache_write_script(
      condathis::get_env_dir(env_names[[method]], method = method),
      counters[[method]],
      "on"
    )
  }
  # One activation runs the script once, with both backends on every OS
  # (condathis primes micromamba's `condabin` on Windows in an empty
  # environment of its own, not in this one).
  for (method in psolve_methods) {
    for (i in 1:3) {
      expect_identical(
        acache_values("run_bin", env_names[[method]], "RT_ACACHE_V", method),
        "on",
        info = method
      )
    }
    expect_identical(acache_runs(counters[[method]]), 1L, info = method)
  }
  # run() uses the same cached activation with both backends, on every OS
  # (condathis activates micromamba environments itself for run() too,
  # R-4): no script runs again.
  for (method in psolve_methods) {
    before <- acache_runs(counters[[method]])
    for (i in 1:2) {
      expect_identical(
        acache_values("run", env_names[[method]], "RT_ACACHE_V", method),
        "on",
        info = method
      )
    }
    expect_identical(
      acache_runs(counters[[method]]) - before,
      0L,
      info = method
    )
  }
  # Both activate again, once, when the script changes (here to a script
  # of the same size) and when a variable of the session changes, which
  # the scripts can read.
  for (method in psolve_methods) {
    before <- acache_runs(counters[[method]])
    acache_write_script(
      condathis::get_env_dir(env_names[[method]], method = method),
      counters[[method]],
      "no"
    )
    for (fn in c("run_bin", "run")) {
      expect_identical(
        acache_values(fn, env_names[[method]], "RT_ACACHE_V", method),
        "no",
        info = paste(method, fn)
      )
    }
    expect_identical(
      acache_runs(counters[[method]]) - before,
      1L,
      info = method
    )
    before <- acache_runs(counters[[method]])
    withr::with_envvar(c(RT_ACACHE_SESSION = "set"), {
      for (fn in c("run_bin", "run")) {
        acache_values(fn, env_names[[method]], "RT_ACACHE_V", method)
      }
    })
    expect_identical(
      acache_runs(counters[[method]]) - before,
      1L,
      info = method
    )
  }
})
