# Shared helpers of rattlerthis's tests.
#
# The tests drive condathis's exported functions with `method = "rattler"`
# (and, in the parity files, the same calls with `method = "micromamba"`),
# on the local channels of `fixtures/channels`. See setup.R for the
# sandbox every test process runs in, and setup-micromamba.R for the
# micromamba binary of the parity files.

# --- Run state ----------------------------------------------------------------

# State of this test process: `sandbox` (the paths of the process sandbox,
# set by setup.R), `runner_micromamba` (the `CONDATHIS_MICROMAMBA_PATH` the
# runner gave, recorded before setup.R unsets it), `micromamba` and
# `micromamba_error` (set by setup-micromamba.R), `channels_dir` (the
# session copy of the test channels).
rt_test_state <- new.env(parent = emptyenv())

# The fixtures directory, absolute: testthat sources the helpers (and each
# test file) from tests/testthat, but a test may change the working
# directory (`local_condathis_sandbox()` does).
if (isTRUE(dir.exists("fixtures"))) {
  rt_test_state$fixtures_dir <- normalizePath("fixtures", winslash = "/")
}

# A path below tests/testthat/fixtures.
fixtures_path <- function(...) {
  base <- rt_test_state$fixtures_dir
  if (is.null(base) || isFALSE(dir.exists(base))) {
    base <- testthat::test_path("fixtures")
  }
  return(file.path(base, ...))
}

# Records the `CONDATHIS_MICROMAMBA_PATH` of the runner, once: setup.R and
# setup-micromamba.R both call it before either unsets the variable, so
# their order does not matter.
remember_runner_micromamba <- function() {
  if (is.null(rt_test_state$runner_micromamba)) {
    rt_test_state$runner_micromamba <- Sys.getenv(
      "CONDATHIS_MICROMAMBA_PATH",
      unset = ""
    )
  }
  return(rt_test_state$runner_micromamba)
}

# --- Operating systems ----------------------------------------------------------
# `is_windows()` is rattlerthis's own (the tests run in its namespace).

is_macos <- function() {
  return(identical(Sys.info()[["sysname"]], "Darwin"))
}

is_linux <- function() {
  return(identical(Sys.info()[["sysname"]], "Linux"))
}

# A native ARM64 build of R (and so of rattlerthis) on Windows.
is_windows_arm64 <- function() {
  return(isTRUE(is_windows()) && identical(R.version$arch, "aarch64"))
}

# Whether the Rosetta 2 daemon runs (Apple Silicon); FALSE elsewhere.
# condathis's own probe, so tests branch exactly as its fallback does.
rosetta_running <- function() {
  if (isFALSE(is_macos())) {
    return(FALSE)
  }
  probe <- get("is_rosetta_running", envir = asNamespace("condathis"))
  return(isTRUE(probe()))
}

# The conda platform this R, and so this build of rattlerthis, is for:
# what rattler solves for without a `platform`.
r_build_platform <- function() {
  os <- switch(
    Sys.info()[["sysname"]],
    Linux = "linux",
    Darwin = "osx",
    Windows = "win",
    tolower(Sys.info()[["sysname"]])
  )
  arch <- R.version$arch
  if (identical(arch, "x86_64")) {
    return(paste0(os, "-64"))
  }
  if (isTRUE(arch %in% c("aarch64", "arm64"))) {
    return(paste0(os, if (identical(os, "linux")) "-aarch64" else "-arm64"))
  }
  return(paste0(os, "-", arch))
}

# The platform names condathis accepts (`known_platforms`).
condathis_known_platforms <- function() {
  return(get("known_platforms", envir = asNamespace("condathis")))
}

# --- Sandboxes ------------------------------------------------------------------

# A condathis sandbox: home, data, cache, config and state directories
# under one new root, so condathis's root
# (`tools::R_user_dir("condathis", "data")`) and the rattler root inside it
# (`condathis::backend_root_dir("rattler")`) are new and empty, and neither
# is created yet. Every CONDA_*/MAMBA_* variable a developer shell may set
# is removed (CONDA_ENVS_PATH in particular: a shell that sets it to a real
# envs directory must never receive test environments), and so are
# `CONDATHIS_MICROMAMBA_PATH` and the option `condathis.micromamba_path`:
# only the parity files use micromamba (`local_parity_micromamba()`).
# `condathis.backend_priority` is unset, so new environments reach the
# rattler backend only through `method = "rattler"`.
#
# setup.R makes one for the whole test process (`env =
# testthat::teardown_env()`), so the package and repodata caches of both
# backends are shared by every test; a test that asserts on a fresh, empty
# root calls it again for a sandbox of its own, deleted when the test ends.
#
# Returns a list of paths: `root`, `home`, `data`, `cache`, `wd`, and
# `rattler`, the rattler root (not created).
local_condathis_sandbox <- function(
  env = parent.frame(),
  pattern = "rt-sandbox-"
) {
  remember_runner_micromamba()
  parent_dir <- rt_test_state$sandbox$root %||% tempdir()
  root <- withr::local_tempdir(
    pattern = pattern,
    tmpdir = parent_dir,
    .local_envir = env
  )
  root <- normalizePath(root, winslash = "/", mustWork = TRUE)
  paths <- list(
    root = root,
    home = file.path(root, "home"),
    data = file.path(root, "data"),
    cache = file.path(root, "cache"),
    config = file.path(root, "config"),
    state = file.path(root, "state"),
    wd = file.path(root, "wd")
  )
  for (dir in paths[-1L]) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  }
  withr::local_envvar(
    c(
      HOME = paths$home,
      USERPROFILE = paths$home,
      LOCALAPPDATA = paths$data,
      APPDATA = paths$data,
      R_USER_DATA_DIR = paths$data,
      XDG_DATA_HOME = paths$data,
      R_USER_CACHE_DIR = paths$cache,
      XDG_CACHE_HOME = paths$cache,
      R_USER_CONFIG_DIR = paths$config,
      XDG_CONFIG_HOME = paths$config,
      XDG_STATE_HOME = paths$state,
      CONDATHIS_MICROMAMBA_PATH = NA,
      CONDA_ENVS_PATH = NA,
      CONDA_ENVS_DIRS = NA,
      CONDA_PKGS_DIRS = NA,
      CONDA_PREFIX = NA,
      CONDA_DEFAULT_ENV = NA,
      CONDA_PROMPT_MODIFIER = NA,
      CONDA_ROOT_PREFIX = NA,
      CONDA_SHLVL = NA,
      CONDA_EXE = NA,
      CONDA_SUBDIR = NA,
      CONDARC = NA,
      MAMBA_ENVS_PATH = NA,
      MAMBA_ENVS_DIRS = NA,
      MAMBA_PKGS_DIRS = NA,
      MAMBA_ROOT_PREFIX = NA,
      MAMBA_EXE = NA,
      MAMBA_PLATFORM = NA,
      MAMBARC = NA
    ),
    .local_envir = env
  )
  withr::local_options(
    list(condathis.backend_priority = NULL, condathis.micromamba_path = NULL),
    .local_envir = env
  )
  withr::local_dir(paths$wd, .local_envir = env)
  # Computed inside the sandbox; nothing is created.
  paths$rattler <- condathis::backend_root_dir("rattler")
  return(paths)
}

# The micromamba binary of the parity files, as `CONDATHIS_MICROMAMBA_PATH`
# for the calling test (or file, with `env = testthat::teardown_env()` from
# a file's top level). The binary is the runner's (CONDATHIS_MICROMAMBA_PATH
# when the run started) or the one setup-micromamba.R installed. A missing
# binary fails the caller: there is no skip.
local_parity_micromamba <- function(env = parent.frame()) {
  path <- rt_test_state$micromamba
  if (is.null(path) || isFALSE(nzchar(path)) || isFALSE(file.exists(path))) {
    stop(
      "No micromamba for the parity tests: ",
      rt_test_state$micromamba_error %||%
        "setup-micromamba.R did not run (run the tests with testthat).",
      call. = FALSE
    )
  }
  withr::local_envvar(
    c(CONDATHIS_MICROMAMBA_PATH = path),
    .local_envir = env
  )
  return(invisible(path))
}

# --- Channels -------------------------------------------------------------------

# A `file://` URL of a local path (no trailing slash; `file:///C:/...` on
# Windows).
file_url <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  path <- sub("/+$", "", path)
  if (isTRUE(startsWith(path, "/"))) {
    return(paste0("file://", path))
  }
  return(paste0("file:///", path))
}

# Writes an empty repodata.json in every known subdir of condathis that a
# channel does not have yet, so both backends find every subdir they may
# query.
fill_channel_subdirs <- function(channel_dir) {
  for (subdir in condathis_known_platforms()) {
    target <- file.path(channel_dir, subdir, "repodata.json")
    if (isFALSE(file.exists(target))) {
      dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
      writeLines(
        paste0(
          "{\"info\": {\"subdir\": \"",
          subdir,
          "\"}, \"packages\": {}, \"packages.conda\": {}, ",
          "\"repodata_version\": 1}"
        ),
        target
      )
    }
  }
  return(invisible(channel_dir))
}

# The session copy of the test channels (fixtures/channels; built by
# tools/make-test-channels.py): copied once per test process into the
# process sandbox, with an empty repodata.json added for every other known
# subdir. Tests never write into the copy; a test that needs a changed
# channel copies one with `local_test_channel()`.
test_channels_dir <- function() {
  dir <- rt_test_state$channels_dir
  if (isFALSE(is.null(dir)) && isTRUE(dir.exists(dir))) {
    return(dir)
  }
  source_dir <- fixtures_path("channels")
  if (isFALSE(dir.exists(source_dir))) {
    stop("The test channels are missing: ", source_dir, call. = FALSE)
  }
  parent_dir <- rt_test_state$sandbox$root %||% tempdir()
  dir <- file.path(parent_dir, "channels")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  for (channel in list.dirs(source_dir, recursive = FALSE, full.names = TRUE)) {
    file.copy(channel, dir, recursive = TRUE, copy.date = TRUE)
    fill_channel_subdirs(file.path(dir, basename(channel)))
  }
  dir <- normalizePath(dir, winslash = "/", mustWork = TRUE)
  rt_test_state$channels_dir <- dir
  return(dir)
}

# The names of the test channels.
test_channel_names <- c(
  "chA",
  "chB",
  "chC",
  "chD",
  "plink",
  "osxonly",
  "winonly",
  "intelonly"
)

# The `file://` URL of one test channel (`channel_url("chA")`), or of the
# directory that holds them all (`channel_url()`, the `@CHANNEL_DIR@` of the
# env-file fixtures).
channel_url <- function(name = NULL) {
  dir <- test_channels_dir()
  if (is.null(name)) {
    return(file_url(dir))
  }
  stopifnot(isTRUE(name %in% test_channel_names))
  return(file_url(file.path(dir, name)))
}

# A private copy of one test channel for a test that changes it (adds a
# package, breaks an archive). Returns its directory; its URL is
# `file_url(dir)`.
local_test_channel <- function(name, env = parent.frame()) {
  stopifnot(isTRUE(name %in% test_channel_names))
  parent_dir <- withr::local_tempdir(pattern = "rt-chan-", .local_envir = env)
  file.copy(
    file.path(test_channels_dir(), name),
    parent_dir,
    recursive = TRUE,
    copy.date = TRUE
  )
  return(normalizePath(file.path(parent_dir, name), winslash = "/"))
}

# The repodata record of a package archive of the test channels, from its
# repodata.json: `channel_record("chA/noarch/foo-1.0-0.tar.bz2")$md5`.
channel_record <- function(archive) {
  parts <- strsplit(archive, "/", fixed = TRUE)[[1L]]
  stopifnot(identical(length(parts), 3L))
  repodata <- jsonlite::fromJSON(
    file.path(test_channels_dir(), parts[[1L]], parts[[2L]], "repodata.json"),
    simplifyVector = FALSE
  )
  record <- repodata$packages[[parts[[3L]]]]
  if (is.null(record)) {
    stop("No package ", archive, " in the test channels.", call. = FALSE)
  }
  return(record)
}

# The local channel condathis ships, holding only `polyglot` (noarch, no
# dependencies). Solving and installing from it needs no network.
condathis_polyglot_channel <- function() {
  channel_dir <- system.file(
    "extdata",
    "polyglot-channel",
    package = "condathis",
    mustWork = TRUE
  )
  return(normalizePath(channel_dir, winslash = "/", mustWork = TRUE))
}

# The first line `polyglot` prints on this platform.
polyglot_first_line <- function() {
  if (isTRUE(is_windows())) {
    return("System detected: Windows")
  }
  return("System detected: Linux/Unix")
}

# --- Environment files ----------------------------------------------------------

# An env-file fixture of fixtures/envfiles, ready to use: `@CHANNEL_DIR@`
# becomes `channel_url()` (the directory that holds the test channels), and
# a token such as `@MD5:chA/noarch/foo-1.0-0.tar.bz2@` or `@SHA256:...@`
# the hash of that archive (from the channel's repodata.json). The file is
# written, with the fixture's name, to `dir` (a new temporary directory of
# the caller by default), byte for byte otherwise. e12-envvar.yml also
# needs `ENVFILE_CHANNEL_DIR = channel_url()` in the environment.
envfile_fixture <- function(name, dir = NULL, env = parent.frame()) {
  source <- fixtures_path("envfiles", name)
  if (isFALSE(file.exists(source))) {
    stop("No env-file fixture ", name, call. = FALSE)
  }
  if (is.null(dir)) {
    dir <- withr::local_tempdir(pattern = "rt-envfile-", .local_envir = env)
  }
  text <- readChar(source, file.size(source), useBytes = TRUE)
  text <- gsub("@CHANNEL_DIR@", channel_url(), text, fixed = TRUE)
  tokens <- regmatches(text, gregexpr("@(MD5|SHA256):[^@]+@", text))[[1L]]
  for (token in unique(tokens)) {
    parts <- strsplit(substr(token, 2L, nchar(token) - 1L), ":", fixed = TRUE)
    parts <- parts[[1L]]
    record <- channel_record(parts[[2L]])
    hash <- if (identical(parts[[1L]], "MD5")) record$md5 else record$sha256
    text <- gsub(token, hash, text, fixed = TRUE)
  }
  target <- file.path(dir, name)
  writeBin(charToRaw(text), target)
  return(normalizePath(target, winslash = "/", mustWork = TRUE))
}

# --- Environments ---------------------------------------------------------------

# The package records of a conda prefix (`conda-meta/*.json`), as a data
# frame with the columns `name`, `version`, `build` and `channel`, sorted by
# name.
env_records <- function(prefix) {
  files <- list.files(
    file.path(prefix, "conda-meta"),
    pattern = "[.]json$",
    full.names = TRUE
  )
  records <- lapply(files, jsonlite::fromJSON, simplifyVector = FALSE)
  value <- function(record, field) {
    return(as.character(record[[field]] %||% NA_character_))
  }
  out <- data.frame(
    name = vapply(records, value, character(1L), field = "name"),
    version = vapply(records, value, character(1L), field = "version"),
    build = vapply(records, value, character(1L), field = "build"),
    channel = vapply(records, value, character(1L), field = "channel"),
    stringsAsFactors = FALSE
  )
  out <- out[order(out$name, method = "radix"), , drop = FALSE]
  rownames(out) <- NULL
  return(out)
}

# The lines of `conda-meta/history`, read as bytes, with the line ends kept
# apart: `lines` (without line ends) and `crlf` (TRUE when every line ends
# with CRLF).
read_history <- function(prefix) {
  path <- file.path(prefix, "conda-meta", "history")
  bytes <- readBin(path, "raw", file.size(path))
  text <- rawToChar(bytes)
  if (identical(text, "")) {
    return(list(lines = character(0L), crlf = NA))
  }
  lines <- strsplit(text, "\n", fixed = TRUE)[[1L]]
  crlf <- all(endsWith(lines, "\r"))
  return(list(lines = sub("\r$", "", lines), crlf = crlf))
}

# Removes an environment at the end of the caller, if it exists. The
# warning about skipped pre-unlink scripts (R-1) is muffled: tests that
# check it remove the environment themselves.
defer_remove_env <- function(
  env_name,
  method = "rattler",
  env = parent.frame()
) {
  withr::defer(
    {
      if (isTRUE(condathis::env_exists(env_name, method = method))) {
        withCallingHandlers(
          condathis::remove_env(env_name, method = method, verbose = "silent"),
          condathis_link_scripts_skipped = function(cnd) {
            invokeRestart("muffleWarning")
          }
        )
      }
    },
    envir = env
  )
  return(invisible(env_name))
}

# --- Assertions -----------------------------------------------------------------

# Name/value pairs of a child process's environment, from
# `rscript_print_env_args()` output.
parse_env_output <- function(lines) {
  lines <- lines[grepl("=", lines, fixed = TRUE)]
  return(stats::setNames(
    sub("^[^=]*=", "", lines),
    sub("=.*$", "", lines)
  ))
}

# Is `path` the directory `dir` or below it? Compares the spelling, with
# `/` and `\` taken as the same.
path_is_within <- function(path, dir) {
  path <- gsub("\\\\", "/", as.character(path))
  dir <- sub("/+$", "", gsub("\\\\", "/", as.character(dir)))
  if (isTRUE(is_windows())) {
    path <- tolower(path)
    dir <- tolower(dir)
  }
  return(identical(path, dir) || startsWith(path, paste0(dir, "/")))
}

# Assert a missing-environment error: its own class, plus the shared
# classes every missing-environment abort has.
expect_env_not_found <- function(object, class) {
  cnd <- testthat::expect_error(object, class = class)
  testthat::expect_s3_class(cnd, "condathis_env_not_found")
  testthat::expect_s3_class(cnd, "condathis_error")
  return(invisible(cnd))
}

# Assert a failed backend operation: condathis's classes, and the backend's
# own error (class `parent_class`) in the parent chain.
expect_backend_failure <- function(object, class, parent_class) {
  cnd <- testthat::expect_error(object, class = class)
  testthat::expect_s3_class(cnd, "condathis_backend_error")
  testthat::expect_s3_class(cnd, "condathis_error")
  testthat::expect_true(
    rlang::cnd_inherits(cnd, parent_class),
    label = paste0("the error has a parent of class ", parent_class)
  )
  return(invisible(cnd))
}

# Assert a classed rattler error: `rattlerthis_rattler_<kind>`,
# `rattlerthis_rattler_error` and `rattlerthis_error`, with the field
# `kind`.
expect_rattler_error <- function(object, kind) {
  cnd <- testthat::expect_error(
    object,
    class = paste0("rattlerthis_rattler_", kind)
  )
  testthat::expect_s3_class(cnd, "rattlerthis_rattler_error")
  testthat::expect_s3_class(cnd, "rattlerthis_error")
  testthat::expect_identical(cnd$kind, kind)
  return(invisible(cnd))
}

# --- Commands -------------------------------------------------------------------

# The absolute path of the Rscript of this R session. Tests use it as a
# command that exists on every platform: a bare name would be looked up on
# R's PATH, and `env`/`cat` do not exist on Windows.
rscript_path <- function() {
  exe <- if (isTRUE(is_windows())) "Rscript.exe" else "Rscript"
  return(normalizePath(
    file.path(R.home("bin"), exe),
    winslash = "/",
    mustWork = TRUE
  ))
}

# Arguments for `rscript_path()` that print the child's environment, one
# NAME=value per line.
rscript_print_env_args <- function() {
  return(c("-e", "e <- Sys.getenv(); writeLines(paste0(names(e), '=', e))"))
}

# Arguments for `rscript_path()` that copy standard input to standard output.
rscript_cat_args <- function() {
  return(c("-e", "writeLines(readLines(file('stdin')))"))
}

# --- Skips ----------------------------------------------------------------------

# The `wheels` Cargo feature is off by default (see PLAN.md, "Wheel
# packages"), so a stock build, including any CRAN build, cannot install
# wheel-format packages. These two tests are the only ones that may skip
# (the zero-skip rule): that is a deliberate build configuration, not a
# defect. Re-enable with `cargo build --features wheels`.
skip_if_no_wheel_support <- function() {
  if (isFALSE(rt_has_wheel_support())) {
    testthat::skip("built without the `wheels` Cargo feature")
  }
}
