# Removing an environment while a program started from it runs (P-D9,
# R-26), with both backends: `remove_env(method = "rattler")` is
# condathis's default removal (history first, one move into
# `<root>/envs/#trash`, then the delete), and `method = "micromamba"` is
# `micromamba env remove`. The program is a package of a channel built at
# test time (`local_package_channel()`): a copy of `ping.exe` on Windows
# and a shell script that runs `sleep` elsewhere, started from the
# environment.
#
# What Windows 11 (NTFS) allows on the file of a running program, checked
# on a Windows 11 x64 machine: the file cannot be deleted, but it can be
# renamed, and so can a directory that holds it. A file that has a second
# hard link, as every package file that both backends link from their
# package caches, can be deleted too. On Linux and macOS, every file can be
# deleted.
#
# * With the package caches in place, both backends remove everything at
#   once on every system, and the program goes on running.
# * After `clean_cache()` the program's file has one link. On Windows the
#   removal still succeeds and the environment is gone from every listing,
#   but the file stays behind until the program ends:
#   * rattler: the moved environment stays in `#trash` (with its
#     `.discard` marker), and condathis deletes it on a later removal or
#     replacement, once the program has ended;
#   * micromamba: the file stays as `<name>.mamba_trash/.../<file>.mamba_trash`
#     in micromamba's `envs` directory, and nothing deletes it later
#     (R-26, new text proposed in RT-4's report).
#   On Linux and macOS, nothing stays behind with either backend.
#
# Environment names start with "rt-busy-".

# The program of the test package: its path in an environment, and the
# arguments that keep it running for two minutes. On Windows a copy of
# `ping.exe`, whose file is busy while it runs. On Linux and macOS a shell
# script, which the shell keeps open while `sleep` runs (a copy of a
# system program does not run on macOS: Apple Silicon runs `arm64e`
# programs only from the system's own directories).
busy_program <- function() {
  if (isTRUE(is_windows())) {
    return(list(
      path = "Library/bin/rt-busy.exe",
      args = c("-n", "120", "127.0.0.1")
    ))
  }
  return(list(path = "bin/rt-busy", args = "120"))
}

# A channel with the package `rtbusy`, which holds the program.
local_busy_channel <- function(env = parent.frame()) {
  program <- busy_program()
  if (isTRUE(is_windows())) {
    source <- file.path(Sys.getenv("SystemRoot"), "System32", "PING.EXE")
  } else {
    source <- file.path(
      withr::local_tempdir(pattern = "rt-busy-", .local_envir = env),
      "rt-busy"
    )
    writeLines(c("#!/bin/sh", "sleep \"$1\""), source)
  }
  channel_dir <- local_package_channel(
    "busychan",
    "rtbusy",
    stats::setNames(list(source), program$path),
    env = env
  )
  return(file_url(channel_dir))
}

# Starts the program from the environment `env_name` of backend `method`;
# it is ended when the caller ends.
start_busy_program <- function(env_name, method, env = parent.frame()) {
  program <- busy_program()
  env_dir <- condathis::get_env_dir(env_name, method = method)
  process <- processx::process$new(
    file.path(env_dir, program$path),
    program$args,
    stdout = NULL,
    stderr = NULL
  )
  withr::defer(kill_busy_program(process), envir = env)
  Sys.sleep(0.5)
  return(process)
}

# Kills a program and the processes it started (the script's `sleep`).
# `process$kill_tree()` finds no process on macOS, where the environment
# of a system program cannot be read, so the children are taken from ps.
kill_busy_program <- function(process) {
  children <- process_descendants(process$as_ps_handle())
  process$kill()
  for (child in children) {
    try(ps::ps_kill(child), silent = TRUE)
  }
  return(invisible(process))
}

# Ends a program and waits until it is gone.
stop_busy_program <- function(process) {
  kill_busy_program(process)
  wait_until(
    function() isFALSE(process$is_alive()),
    timeout = 10,
    what = "the program to end"
  )
  return(invisible(process))
}

# The entries of rattler's trash directory (condathis's `#trash`).
rattler_trash <- function() {
  trash_dir <- file.path(
    condathis::get_install_dir(method = "rattler")$path,
    "envs",
    "#trash"
  )
  return(list.files(
    trash_dir,
    recursive = TRUE,
    all.files = TRUE,
    include.dirs = TRUE
  ))
}

# The files micromamba renamed to `*.mamba_trash` in its root, relative to
# its `envs` directory.
micromamba_trash <- function() {
  envs_dir <- file.path(
    condathis::get_install_dir(method = "micromamba")$path,
    "envs"
  )
  return(list.files(
    envs_dir,
    pattern = "[.]mamba_trash$",
    recursive = TRUE,
    all.files = TRUE
  ))
}

# Removes `env_name` with `method` and asserts that it is gone from the
# listings and from the disk, whatever stays elsewhere.
expect_removed <- function(env_name, method) {
  env_dir <- condathis::get_env_dir(env_name, method = method)
  expect_no_error(
    condathis::remove_env(env_name, method = method, verbose = "silent")
  )
  expect_false(condathis::env_exists(env_name, method = method))
  expect_false(env_name %in% condathis::list_envs(method = method)$env_name)
  expect_false(dir.exists(env_dir))
  return(invisible(env_dir))
}

test_that("both backends remove an environment whose program runs", {
  local_parity_micromamba()
  local_condathis_sandbox()
  channel <- local_busy_channel()
  for (method in c("micromamba", "rattler")) {
    env_name <- paste0("rt-busy-", method)
    condathis::create_env(
      "rtbusy",
      env_name = env_name,
      channels = channel,
      method = method,
      verbose = "silent"
    )
    process <- start_busy_program(env_name, method)
    expect_true(process$is_alive())
    expect_removed(env_name, method)
    # The program goes on running from the removed file.
    expect_true(process$is_alive())
    stop_busy_program(process)
  }
  # The package caches keep a link to the program's file, so it is deleted
  # at once on every system: nothing stays behind.
  expect_identical(rattler_trash(), character(0L))
  expect_identical(micromamba_trash(), character(0L))
})

test_that("a running program's only file stays behind until a later removal", {
  local_parity_micromamba()
  local_condathis_sandbox()
  channel <- local_busy_channel()
  methods <- c("micromamba", "rattler")
  for (method in methods) {
    condathis::create_env(
      "rtbusy",
      env_name = paste0("rt-busy-only-", method),
      channels = channel,
      method = method,
      verbose = "silent"
    )
  }
  # Without the package caches, the environments hold the only link.
  condathis::clean_cache(verbose = "silent")
  processes <- list()
  for (method in methods) {
    env_name <- paste0("rt-busy-only-", method)
    processes[[method]] <- start_busy_program(env_name, method)
    expect_removed(env_name, method)
    expect_true(processes[[method]]$is_alive())
  }
  if (isTRUE(is_windows())) {
    # rattler: the environment was moved into #trash; its delete stopped at
    # the program's file, so the copy and its marker stay.
    trash <- rattler_trash()
    discard <- grep("^[^/]+[.]discard$", trash, value = TRUE)
    expect_length(discard, 1L)
    copy <- sub("[.]discard$", "", discard)
    expect_true(
      paste0(copy, "/", busy_program()$path) %in% trash,
      label = paste(trash, collapse = " ")
    )
    # micromamba: the file was renamed next to where the environment was.
    expect_identical(
      micromamba_trash(),
      paste0(
        "rt-busy-only-micromamba.mamba_trash/",
        busy_program()$path,
        ".mamba_trash"
      )
    )
  } else {
    expect_identical(rattler_trash(), character(0L))
    expect_identical(micromamba_trash(), character(0L))
  }

  # Once the program has ended, the next removal of each backend.
  for (method in methods) {
    stop_busy_program(processes[[method]])
    env_name <- paste0("rt-busy-later-", method)
    condathis::create_env(
      "rtbusy",
      env_name = env_name,
      channels = channel,
      method = method,
      verbose = "silent"
    )
    expect_removed(env_name, method)
  }
  # rattler's trash is purged on every system.
  expect_identical(rattler_trash(), character(0L))
  if (isTRUE(is_windows())) {
    # R-26: micromamba never deletes its renamed file.
    expect_identical(
      micromamba_trash(),
      paste0(
        "rt-busy-only-micromamba.mamba_trash/",
        busy_program()$path,
        ".mamba_trash"
      )
    )
  } else {
    expect_identical(micromamba_trash(), character(0L))
  }
})
