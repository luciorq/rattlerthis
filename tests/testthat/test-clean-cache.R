# condathis::clean_cache() with the rattler backend (spec 3.12 and 6.2,
# row test-clean-cache.R; D25, C-I, C-J, C-L): it empties rattler's package
# cache (`<rattler root>/pkgs`) and channel metadata cache
# (`<rattler root>/repodata_cache`) through `backend_clean_cache()`, and
# condathis deletes `<rattler root>/conda-pkgs`, the package cache of Conda
# tools run in rattler environments. Nothing outside condathis's
# directories is touched, nothing is created when there is nothing to
# clean, and micromamba is never installed for it. Every test has a sandbox
# of its own: clean_cache() cleans the caches of every backend.

# The entries of a directory, or NULL when it does not exist.
pr_entries <- function(dir) {
  if (isFALSE(dir.exists(dir))) {
    return(NULL)
  }
  return(list.files(dir, all.files = TRUE, no.. = TRUE))
}

# Writes `text` to `path`, creating its directory.
pr_write_file <- function(path, text = "rt-pr marker") {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(text, path)
  return(invisible(path))
}

# The micromamba binary of the parity tests, used here only as a Conda tool
# that runs inside a rattler environment (condathis does not use it as a
# backend: CONDATHIS_MICROMAMBA_PATH stays unset).
pr_conda_tool <- function() {
  path <- rt_test_state$micromamba
  if (is.null(path) || isFALSE(file.exists(path))) {
    stop(
      "No micromamba to run as a Conda tool: ",
      rt_test_state$micromamba_error %||% "setup-micromamba.R did not run.",
      call. = FALSE
    )
  }
  return(path)
}

test_that("clean_cache() with nothing to clean creates nothing", {
  paths <- local_condathis_sandbox()
  condathis_root <- dirname(paths$rattler)
  out <- pr_capture(res <- condathis::clean_cache(verbose = "output"))
  expect_identical(out$stdout, character(0L))
  expect_length(out$messages, 1L)
  expect_match(out$messages, "Cache successfully removed")
  expect_s3_class(res, "condathis_result")
  expect_identical(res$status, 0L)
  expect_identical(res$cmd, NA_character_)
  # No root was created, so micromamba was neither installed nor run.
  # (Not asked through `micromamba_bin_path()`, which creates the root.)
  expect_false(dir.exists(paths$rattler))
  expect_false(dir.exists(condathis_root))
  expect_identical(pr_entries(paths$data), character(0L))
  expect_identical(pr_entries(paths$cache), character(0L))
})

test_that("clean_cache() empties rattler's caches and conda-pkgs, and keeps the environments", {
  paths <- local_condathis_sandbox()
  condathis_root <- dirname(paths$rattler)
  env_name <- "rt-cc-keep"
  condathis::create_env(
    "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  pkgs_dir <- file.path(paths$rattler, "pkgs")
  repodata_dir <- file.path(paths$rattler, "repodata_cache")
  conda_pkgs_dir <- file.path(paths$rattler, "conda-pkgs")
  # Local channels are read in place: rattler's metadata cache is empty for
  # them, so it gets an entry here (as a remote channel would leave).
  pr_write_file(file.path(repodata_dir, "rt-pr-repodata.json"))
  pr_write_file(file.path(conda_pkgs_dir, "rt-pr-tool", "marker"))
  # The cache of the pip steps of creates (pip's own on Linux).
  tool_cache_dir <- file.path(paths$rattler, "cache")
  pr_write_file(file.path(tool_cache_dir, "pip", "http-v2", "marker"))
  expect_true(length(pr_entries(pkgs_dir)) > 1L)

  expect_no_warning(res <- condathis::clean_cache(verbose = "silent"))
  expect_identical(res$status, 0L)
  # rattler's caches stay, empty but for its cache lock (see test-hooks.R);
  # condathis deletes its conda-pkgs directory, and rattler the cache of
  # its pip steps, as condathis deletes micromamba's `cache`.
  expect_identical(pr_entries(pkgs_dir), ".cache.lock")
  expect_identical(pr_entries(repodata_dir), character(0L))
  expect_false(dir.exists(conda_pkgs_dir))
  expect_false(dir.exists(tool_cache_dir))
  # The environment is intact, and works.
  expect_true(condathis::env_exists(env_name, method = "rattler"))
  expect_identical(
    condathis::list_packages(env_name, method = "rattler")$name,
    "foo"
  )
  prefix <- condathis::get_env_dir(env_name, method = "rattler")
  expect_true(file.exists(file.path(prefix, "share", "foo", "README")))
  # Nothing of micromamba's appeared: only the rattler root and condathis's
  # locks (of the environment, and of the package caches, which
  # clean_cache() itself takes), which clean_cache() keeps.
  expect_identical(pr_entries(condathis_root), c("locks", "rattler"))
  expect_setequal(
    pr_entries(file.path(condathis_root, "locks")),
    c("#cache.lock", paste0(env_name, ".lock"))
  )
  expect_false(file.exists(condathis::micromamba_bin_path()))
  # A cleaned cache is used again.
  condathis::install_packages(
    "baz",
    env_name = env_name,
    channels = c(channel_url("chA"), channel_url("chC")),
    method = "rattler",
    verbose = "silent"
  )
  expect_true(any(startsWith(pr_entries(pkgs_dir), "baz-1.0-0")))
})

test_that("clean_cache() leaves the caches of other tools", {
  # The per-user caches of conda and mamba and the global cache of other
  # rattler tools (such as pixi) are not condathis's: they stay, also when
  # rattler's own caches are cleaned (the home-footprint rule, asserted here
  # for the rattler backend). condathis's own cache directory is emptied.
  paths <- local_condathis_sandbox()
  condathis::create_env(
    "foo",
    env_name = "rt-cc-other",
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  kept <- c(
    file.path(paths$cache, "conda", "proc", "rt-pr-marker"),
    file.path(paths$cache, "rattler", "cache", "rt-pr-marker"),
    file.path(paths$home, ".mamba", "pkgs", "rt-pr-marker"),
    file.path(paths$home, ".conda", "pkgs", "rt-pr-marker")
  )
  for (path in kept) {
    pr_write_file(path)
  }
  own <- file.path(
    tools::R_user_dir("condathis", which = "cache"),
    "rt-pr-marker"
  )
  pr_write_file(own)
  condathis::clean_cache(verbose = "silent")
  for (path in kept) {
    expect_true(file.exists(path), info = path)
  }
  expect_false(file.exists(own))
  expect_identical(
    pr_entries(file.path(paths$rattler, "pkgs")),
    ".cache.lock"
  )
})

test_that("a Conda tool in a rattler environment caches into conda-pkgs only", {
  # Children of a rattler environment get CONDA_PKGS_DIRS and
  # MAMBA_PKGS_DIRS = `<rattler root>/conda-pkgs` (C-J, decision Q9): a
  # Conda tool run there caches in condathis's tree, never in
  # `<condathis root>/pkgs` (micromamba's cache) or `~/.conda/pkgs`, and
  # clean_cache() empties it without micromamba.
  paths <- local_condathis_sandbox()
  condathis_root <- dirname(paths$rattler)
  env_name <- "rt-cc-tool"
  condathis::create_env(
    "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  tool_prefix <- file.path(paths$root, "rt-cc-tool-prefix")
  res <- condathis::run_bin(
    pr_conda_tool(),
    "create",
    "--yes",
    "--prefix",
    tool_prefix,
    "--override-channels",
    "--channel",
    channel_url("chC"),
    "baz",
    env_name = env_name,
    method = "rattler",
    verbose = "silent"
  )
  expect_identical(res$status, 0L)
  expect_true(file.exists(file.path(tool_prefix, "share", "baz", "README")))
  conda_pkgs_dir <- file.path(paths$rattler, "conda-pkgs")
  expect_true(file.exists(file.path(conda_pkgs_dir, "urls.txt")))
  tool_cache <- list.files(
    conda_pkgs_dir,
    recursive = TRUE,
    include.dirs = TRUE
  )
  expect_true(any(grepl("baz-1.0-0", tool_cache, fixed = TRUE)))
  expect_false(dir.exists(file.path(condathis_root, "pkgs")))
  expect_false(dir.exists(file.path(paths$home, ".conda", "pkgs")))
  expect_false(dir.exists(file.path(paths$home, ".mamba", "pkgs")))

  condathis::clean_cache(verbose = "silent")
  expect_false(dir.exists(conda_pkgs_dir))
  expect_false(dir.exists(file.path(condathis_root, "pkgs")))
  expect_false(file.exists(condathis::micromamba_bin_path()))
  expect_identical(pr_entries(condathis_root), c("locks", "rattler"))
})

test_that("an entry that cannot be deleted is reported after the rest is deleted", {
  paths <- local_condathis_sandbox()
  for (pkg in c("foo", "baz")) {
    condathis::create_env(
      pkg,
      env_name = paste0("rt-cc-busy-", pkg),
      channels = channel_url(if (identical(pkg, "foo")) "chA" else "chC"),
      method = "rattler",
      verbose = "silent"
    )
  }
  pkgs_dir <- file.path(paths$rattler, "pkgs")
  conda_pkgs_marker <- file.path(paths$rattler, "conda-pkgs", "marker")
  pr_write_file(conda_pkgs_marker)
  busy_entry <- file.path(pkgs_dir, "baz-1.0-0")
  # A read-only file is deleted: rattler clears the attribute that makes
  # Windows refuse it (conda packages often ship read-only files).
  read_only <- file.path(pkgs_dir, "foo-1.0-0", "share", "foo", "README")
  Sys.chmod(read_only, mode = "444")
  # What cannot be deleted: on Windows, a file another program has open; on
  # Linux and macOS, the contents of a directory without write permission.
  if (isTRUE(is_windows())) {
    con <- file(file.path(busy_entry, "share", "baz", "README"), open = "r")
    release <- function() close(con)
  } else {
    locked_dir <- file.path(busy_entry, "share")
    Sys.chmod(locked_dir, mode = "555")
    release <- function() Sys.chmod(locked_dir, mode = "755")
  }
  released <- FALSE
  withr::defer(if (isFALSE(released)) release())
  root_user <- isFALSE(is_windows()) &&
    identical(Sys.info()[["effective_user"]], "root")

  if (isTRUE(root_user)) {
    # root deletes whatever its directory permissions say.
    expect_no_error(condathis::clean_cache(verbose = "silent"))
  } else {
    cnd <- expect_backend_failure(
      condathis::clean_cache(verbose = "silent"),
      class = "condathis_clean_cache_failed",
      parent_class = "rattlerthis_rattler_io"
    )
    expect_match(conditionMessage(cnd), "rattler", fixed = TRUE)
    parent <- cnd$parent
    expect_identical(parent$kind, "io")
    failed <- gsub("\\\\", "/", parent$failed)
    expect_true(any(endsWith(failed, "pkgs/baz-1.0-0")))
    # Everything else is gone, also what condathis deletes after the
    # backends: its conda-pkgs directory.
    expect_identical(
      sort(pr_entries(pkgs_dir), method = "radix"),
      c(".cache.lock", "baz-1.0-0")
    )
    expect_false(file.exists(read_only))
    expect_false(file.exists(conda_pkgs_marker))
  }
  release()
  released <- TRUE
  # Once released, the next call cleans the rest.
  expect_no_error(condathis::clean_cache(verbose = "silent"))
  expect_identical(pr_entries(pkgs_dir), ".cache.lock")
})

test_that("clean_cache() waits for rattler's work in this process first", {
  # A rattler job that still runs (left by an interrupt whose wait was
  # broken) is waited for before anything is deleted (C-L, decision Q26).
  paths <- local_condathis_sandbox()
  condathis::create_env(
    "foo",
    env_name = "rt-cc-quiesce",
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  live_at_clean <- NULL
  real_clean <- rt_clean_cache
  testthat::local_mocked_bindings(
    rt_clean_cache = function(pkgs_cache_dir, repodata_cache_dir) {
      live_at_clean <<- rt_live_jobs()
      return(real_clean(pkgs_cache_dir, repodata_cache_dir))
    }
  )
  job <- rt_test_job_sleep(0.6)
  started <- Sys.time()
  suppressMessages(condathis::clean_cache(verbose = "silent"))
  waited <- as.numeric(difftime(Sys.time(), started, units = "secs"))
  expect_identical(live_at_clean, 0L)
  expect_true(waited >= 0.5)
  expect_true(rt_job_poll(job))
  expect_identical(rt_live_jobs(), 0L)
})
