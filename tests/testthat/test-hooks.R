# The eight functions of the rattler backend object, called directly, for
# what condathis's public API cannot show (test-condathis-conformance.R
# checks them through condathis): the three required ones (create, install,
# resolve_run) and the five optional ones that need rattler
# (resolve_run_in_dir, clean_cache, quiesce, native_platform, can_solve).
# condathis's defaults answer the others. Also the R layer under them:
# `rattler_await()` and the error classes. Environments are in the process
# sandbox (setup.R), with names that start with "rt-hooks-".

hook_names <- c(
  "backend_create_env",
  "backend_install",
  "backend_resolve_run",
  "backend_resolve_run_in_dir",
  "backend_clean_cache",
  "backend_quiesce",
  "backend_native_platform",
  "backend_can_solve"
)

# Calls hook `name` of the rattler backend object, as condathis's
# dispatch does: the object first, every other argument by name.
call_hook <- function(name, ...) {
  backend <- new_backend_rattler()
  return(backend[[name]](backend, ...))
}

empty_skipped <- data.frame(
  package = character(0L),
  script = character(0L),
  stringsAsFactors = FALSE
)

# A base environment as condathis builds it before an activation: the
# session's, with condathis's clean overlay (`CONDA_SHLVL = "0"`), and a
# stale CONDA_PREFIX that the hook must drop.
hook_base_env <- function(...) {
  base_env <- Sys.getenv()
  base_env <- stats::setNames(as.character(base_env), names(base_env))
  base_env[["CONDA_SHLVL"]] <- "0"
  base_env[["CONDA_PREFIX"]] <- if (isTRUE(is_windows())) {
    "C:\\rt-bogus\\prefix"
  } else {
    "/rt-bogus/prefix"
  }
  extra <- c(...)
  base_env[names(extra)] <- extra
  return(base_env)
}

# The entries of a PATH value.
path_entries <- function(value) {
  return(strsplit(value, .Platform$path.sep, fixed = TRUE)[[1L]])
}

# --- The object -------------------------------------------------------------------

test_that("the backend object has the three required and five rattler hooks", {
  backend <- new_backend_rattler()
  expect_identical(
    class(backend),
    c("condathis_backend_rattler", "condathis_backend")
  )
  expect_identical(names(backend), hook_names)
  expect_identical(backend$backend_create_env, rattler_backend_create_env)
  expect_identical(backend$backend_install, rattler_backend_install)
  expect_identical(backend$backend_resolve_run, rattler_backend_resolve_run)
  expect_identical(
    backend$backend_resolve_run_in_dir,
    rattler_backend_resolve_run_in_dir
  )
  expect_identical(backend$backend_clean_cache, rattler_backend_clean_cache)
  expect_identical(backend$backend_quiesce, rattler_backend_quiesce)
  expect_identical(
    backend$backend_native_platform,
    rattler_backend_native_platform
  )
  expect_identical(backend$backend_can_solve, rattler_backend_can_solve)
})

# --- backend_create_env() ---------------------------------------------------------

test_that("backend_create_env() builds the request into the absent prefix", {
  env_name <- "rt-hooks-create"
  defer_remove_env(env_name)
  prefix <- rattler_env_dir(env_name)
  expect_false(dir.exists(prefix))
  expect_silent(
    res <- call_hook(
      "backend_create_env",
      packages = "foo",
      env_name = env_name,
      channels = channel_url("chA"),
      verbose = "silent"
    )
  )
  # No command line: condathis reports `cmd`, `stderr` and `pid` as NA
  # (R-2). `stdout` holds the transaction lines.
  expect_identical(
    res,
    list(
      status = 0L,
      stdout = paste0("+ foo 1.0 0 ", channel_url("chA"), "/noarch\n"),
      link_scripts_skipped = empty_skipped
    )
  )
  expect_true(file.exists(file.path(prefix, "conda-meta", "history")))
  expect_identical(env_records(prefix)$name, "foo")
  # condathis writes its backend marker after the hook, not the hook.
  expect_false(file.exists(file.path(prefix, ".condathis", "backend.json")))
  # rattler marks every prefix as a cache directory (R-7, decision Q13).
  expect_true(file.exists(file.path(prefix, "CACHEDIR.TAG")))
  expect_true(condathis::env_exists(env_name, method = "rattler"))
  # The caches are rattler's own, in the rattler root.
  root <- condathis::backend_root_dir("rattler")
  expect_true(dir.exists(file.path(root, "pkgs")))
  expect_true(dir.exists(file.path(root, "repodata_cache")))
})

test_that("backend_create_env() without packages makes an empty environment", {
  env_name <- "rt-hooks-empty"
  defer_remove_env(env_name)
  res <- call_hook(
    "backend_create_env",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  # An empty transaction: `stdout` is "" (R-30).
  expect_identical(res$stdout, "")
  prefix <- rattler_env_dir(env_name)
  expect_identical(file.size(file.path(prefix, "conda-meta", "history")), 0)
  expect_identical(nrow(env_records(prefix)), 0L)
})

test_that("a create that fails leaves no prefix", {
  env_name <- "rt-hooks-create-fail"
  prefix <- rattler_env_dir(env_name)
  cnd <- expect_rattler_error(
    call_hook(
      "backend_create_env",
      packages = "rt-no-such-package",
      env_name = env_name,
      channels = channel_url("chA"),
      verbose = "silent"
    ),
    kind = "solve"
  )
  expect_match(conditionMessage(cnd), "rt-no-such-package", fixed = TRUE)
  expect_false(dir.exists(prefix))
  expect_false(condathis::env_exists(env_name, method = "rattler"))
})

test_that("backend_create_env() reports the link scripts it did not run", {
  # rattler never runs link scripts (R-1); condathis warns with the names.
  env_name <- "rt-hooks-plink"
  defer_remove_env(env_name)
  res <- call_hook(
    "backend_create_env",
    packages = "plink",
    env_name = env_name,
    channels = channel_url("plink"),
    verbose = "silent"
  )
  expect_identical(
    res$link_scripts_skipped,
    data.frame(
      package = c("plink", "plink"),
      script = c("pre-link", "post-link"),
      stringsAsFactors = FALSE
    )
  )
  prefix <- rattler_env_dir(env_name)
  expect_identical(env_records(prefix)$name, "plink")
  expect_identical(
    list.files(prefix, pattern = "-ran$", recursive = TRUE),
    character(0L)
  )
})

test_that("backend_create_env() reads an environment file", {
  env_name <- "rt-hooks-envfile"
  defer_remove_env(env_name)
  # Command-line channels first: with chA before the file's chB and strict
  # priority, foo 1.0 from chA (fixture e1).
  res <- call_hook(
    "backend_create_env",
    env_file = envfile_fixture("e1.yml"),
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  expect_identical(res$status, 0L)
  records <- env_records(rattler_env_dir(env_name))
  expect_identical(records$name, "foo")
  expect_identical(records$version, "1.0")
  # The variables of a YAML file are not used, as by micromamba, which
  # condathis runs with --no-env: no conda-meta/state.
  env_name <- "rt-hooks-envfile-vars"
  defer_remove_env(env_name)
  call_hook(
    "backend_create_env",
    env_file = envfile_fixture("e4.yml"),
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  expect_false(file.exists(
    file.path(rattler_env_dir(env_name), "conda-meta", "state")
  ))
})

# --- backend_install() ------------------------------------------------------------

test_that("backend_install() never creates a missing environment", {
  env_name <- "rt-hooks-install-missing"
  prefix <- rattler_env_dir(env_name)
  cnd <- expect_error(
    call_hook(
      "backend_install",
      packages = "foo",
      env_name = env_name,
      channels = channel_url("chA"),
      verbose = "silent"
    ),
    class = "rattlerthis_env_not_found"
  )
  expect_s3_class(cnd, "condathis_install_packages_env_not_found")
  expect_s3_class(cnd, "condathis_env_not_found")
  expect_false(dir.exists(prefix))
  # A directory without conda-meta/history is not an environment either.
  dir.create(prefix, recursive = TRUE)
  withr::defer(unlink(prefix, recursive = TRUE))
  expect_error(
    call_hook(
      "backend_install",
      packages = "foo",
      env_name = env_name,
      channels = channel_url("chA"),
      verbose = "silent"
    ),
    class = "condathis_install_packages_env_not_found"
  )
  expect_identical(
    list.files(prefix, all.files = TRUE, no.. = TRUE),
    character(0L)
  )
})

test_that("backend_install() solves with what the environment has", {
  env_name <- "rt-hooks-install"
  defer_remove_env(env_name)
  call_hook(
    "backend_create_env",
    packages = "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  # bar needs foo >=2: the installed foo 1.0 is replaced by foo 2.0 of chB,
  # whose transaction lines list the old side first.
  res <- call_hook(
    "backend_install",
    packages = "bar",
    env_name = env_name,
    channels = channel_url("chB"),
    verbose = "silent"
  )
  expect_identical(res$status, 0L)
  expect_identical(
    res$stdout,
    paste0(
      "- foo 1.0 0 ",
      channel_url("chA"),
      "/noarch\n",
      "+ foo 2.0 0 ",
      channel_url("chB"),
      "/noarch\n",
      "+ bar 1.0 0 ",
      channel_url("chB"),
      "/noarch\n"
    )
  )
  expect_identical(res$link_scripts_skipped, empty_skipped)
  records <- env_records(rattler_env_dir(env_name))
  expect_identical(records$name, c("bar", "foo"))
  expect_identical(records$version, c("1.0", "2.0"))
  # Nothing to do: an empty transaction.
  res <- call_hook(
    "backend_install",
    packages = "bar",
    env_name = env_name,
    channels = channel_url("chB"),
    verbose = "silent"
  )
  expect_identical(res$stdout, "")
})

# --- backend_resolve_run() --------------------------------------------------------

test_that("backend_resolve_run() activates the environment from base_env", {
  env_name <- "rt-hooks-resolve"
  defer_remove_env(env_name)
  call_hook(
    "backend_create_env",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  prefix <- rattler_env_dir(env_name)
  base_env <- hook_base_env()
  path_name <- "PATH"
  if (isTRUE(is_windows())) {
    # The activation keeps the spelling of the variable in base_env.
    path_value <- base_env[[which(toupper(names(base_env)) == "PATH")[[1L]]]]
    base_env <- base_env[toupper(names(base_env)) != "PATH"]
    base_env[["Path"]] <- path_value
    path_name <- "Path"
  }
  res <- call_hook(
    "backend_resolve_run",
    cmd = "rt-some-command",
    args = c("-a", "b c"),
    env_name = env_name,
    verbose = "silent",
    base_env = base_env
  )
  expect_identical(names(res), c("command", "args", "env", "dir"))
  # The command stays bare: condathis looks it up on the child's PATH.
  expect_identical(res$command, "rt-some-command")
  expect_identical(res$args, c("-a", "b c"))
  expect_null(res$dir)
  env <- res$env
  expect_type(env, "character")
  expect_identical(env[["CONDA_DEFAULT_ENV"]], env_name)
  expect_identical(env[["CONDA_PROMPT_MODIFIER"]], paste0("(", env_name, ") "))
  expect_identical(env[["CONDA_SHLVL"]], "1")
  expect_identical(
    normalizePath(env[["CONDA_PREFIX"]], winslash = "/"),
    normalizePath(prefix, winslash = "/")
  )
  # The stale CONDA_PREFIX was dropped before the activation: no backups
  # of a deactivated environment.
  expect_identical(
    grep("^CONDA_ENV_SHLVL_", names(env), value = TRUE),
    character(0L)
  )
  # Only the variables the activation changed, plus condathis's two.
  expect_false("HOME" %in% names(env))
  expect_true(path_name %in% names(env))
  if (isTRUE(is_windows())) {
    expect_false("PATH" %in% names(env))
    first <- path_entries(env[[path_name]])[[1L]]
    expect_identical(first, normalizePath(prefix, winslash = "\\"))
  } else {
    first <- path_entries(env[[path_name]])[[1L]]
    expect_identical(
      normalizePath(first, mustWork = FALSE),
      normalizePath(file.path(prefix, "bin"), mustWork = FALSE)
    )
  }
  # The rest of the PATH is base_env's, without empty or repeated entries
  # (R-5).
  base_entries <- path_entries(base_env[[path_name]])
  base_entries <- unique(base_entries[nzchar(base_entries)])
  entries <- path_entries(env[[path_name]])
  expect_identical(
    entries[seq.int(
      length(entries) - length(base_entries) + 1L,
      length(entries)
    )],
    base_entries
  )
})

test_that("the activation's PATH has no empty or repeated entries (R-5)", {
  env_name <- "rt-hooks-path"
  defer_remove_env(env_name)
  call_hook(
    "backend_create_env",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  sep <- .Platform$path.sep
  base_env <- hook_base_env()
  path_name <- names(base_env)[toupper(names(base_env)) == "PATH"][[1L]]
  dirs <- c(tempdir(), R.home("bin"))
  # Empty entries first, in the middle and last, and a repeated entry; the
  # session's PATH after them, for the activation shell.
  base_env[[path_name]] <- paste0(
    sep,
    dirs[[1L]],
    sep,
    sep,
    dirs[[2L]],
    sep,
    dirs[[1L]],
    sep,
    base_env[[path_name]],
    sep
  )
  res <- call_hook(
    "backend_resolve_run",
    cmd = "x",
    env_name = env_name,
    base_env = base_env
  )
  value <- res$env[[path_name]]
  expect_false(endsWith(value, sep))
  expect_false(startsWith(value, sep))
  entries <- path_entries(value)
  expect_true(all(nzchar(entries)))
  expect_identical(anyDuplicated(entries), 0L)
  expected <- path_entries(base_env[[path_name]])
  expected <- unique(expected[nzchar(expected)])
  expect_identical(
    entries[seq.int(length(entries) - length(expected) + 1L, length(entries))],
    expected
  )
  expect_identical(expected[1:2], dirs)
  expect_identical(
    rattler_tidy_path(c(
      PATH = paste0("a", sep, sep, "b", sep, "a", sep),
      X = "c::"
    ))[["PATH"]],
    paste0("a", sep, "b")
  )
  expect_identical(
    rattler_tidy_path(c(PATH = paste0("a", sep), X = "c::"))[["X"]],
    "c::"
  )
})

test_that("pip steps run micromamba's commands with the environment's programs", {
  prefix <- withr::local_tempdir(pattern = "rt-hooks-pip-")
  spec_file <- file.path(prefix, "mambafx")
  # No python: an empty command, which the step reports as not found.
  expect_identical(rattler_env_program(prefix, "python"), "")
  bin_dir <- if (isTRUE(is_windows())) prefix else file.path(prefix, "bin")
  dir.create(bin_dir, showWarnings = FALSE)
  program <- file.path(
    bin_dir,
    if (isTRUE(is_windows())) "python.exe" else "python"
  )
  writeLines("", program)
  if (isFALSE(is_windows())) {
    # A file that cannot be executed is not a program on Linux and macOS.
    Sys.chmod(program, "644")
    expect_identical(rattler_env_program(prefix, "python"), "")
    Sys.chmod(program, "755")
  }
  expect_identical(rattler_env_program(prefix, "python"), program)
  expect_identical(
    rattler_pip_command("pip", prefix, spec_file),
    list(
      command = program,
      args = c("-m", "pip", "install", "-r", spec_file, "--no-input"),
      program = "python"
    )
  )
  expect_identical(
    rattler_pip_command("pip --no-deps", prefix, spec_file)$args,
    c("-m", "pip", "install", "--no-deps", "-r", spec_file, "--no-input")
  )
  uv <- rattler_pip_command("uv", prefix, spec_file)
  expect_identical(uv$command, "")
  expect_identical(uv$args, c("pip", "install", "-r", spec_file))
  expect_identical(
    rattler_env_bin_dirs(prefix),
    if (isTRUE(is_windows())) {
      c(
        prefix,
        file.path(
          prefix,
          c(
            "Library/mingw-w64/bin",
            "Library/usr/bin",
            "Library/bin",
            "Scripts",
            "bin"
          )
        )
      )
    } else {
      file.path(prefix, "bin")
    }
  )
  # The requirements file: `mambaf` and 10 characters, each spec on a line.
  seed_before <- get0(".Random.seed", envir = globalenv(), inherits = FALSE)
  path <- rattler_pip_spec_file(prefix, c("a==1", "b @ file:///x.whl#sha256=0"))
  expect_identical(
    get0(".Random.seed", envir = globalenv(), inherits = FALSE),
    seed_before
  )
  expect_match(basename(path), "^mambaf[0-9a-z]{10}$")
  expect_identical(
    readBin(path, "raw", 100L),
    charToRaw("a==1\nb @ file:///x.whl#sha256=0\n")
  )
  empty <- rattler_pip_spec_file(prefix, character(0L))
  expect_identical(file.size(empty), 0)
  expect_false(identical(path, empty))
  # The environment pip starts from: condathis's overlay for the commands
  # of a rattler environment, and the backend's own cache directory.
  withr::local_envvar(c(CONDA_PREFIX = "/rt-bogus", RT_HOOKS_KEEP = "kept"))
  base <- rattler_pip_base_env("/rt-tmp")
  expect_identical(base[["TMPDIR"]], "/rt-tmp")
  expect_identical(base[["CONDA_PREFIX"]], "")
  expect_identical(base[["CONDA_SHLVL"]], "0")
  expect_identical(base[["RT_HOOKS_KEEP"]], "kept")
  expect_identical(base[["R_HOME"]], "")
  expect_identical(
    base[["CONDA_ENVS_PATH"]],
    as.character(fs::path(rattler_root(), "envs"))
  )
  expect_identical(
    base[["CONDA_PKGS_DIRS"]],
    as.character(fs::path(rattler_root(), "conda-pkgs"))
  )
  expect_identical(base[["MAMBA_PKGS_DIRS"]], base[["CONDA_PKGS_DIRS"]])
  expect_identical(
    base[["XDG_CACHE_HOME"]],
    as.character(rattler_tool_cache_dir())
  )
  expect_false("CONDA_ENVS_DIRS" %in% names(base))
})

test_that("an activation needs no bash", {
  env_name <- "rt-hooks-sh"
  defer_remove_env(env_name)
  call_hook(
    "backend_create_env",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  prefix <- rattler_env_dir(env_name)
  if (isTRUE(is_windows())) {
    # cmd.exe activates on Windows; the variable keeps its spelling, here
    # `PATH`.
    base_env <- hook_base_env()
    path_value <- base_env[[which(toupper(names(base_env)) == "PATH")[[1L]]]]
    base_env <- base_env[toupper(names(base_env)) != "PATH"]
    base_env[["PATH"]] <- path_value
    res <- call_hook(
      "backend_resolve_run",
      cmd = "x",
      env_name = env_name,
      base_env = base_env
    )
    expect_true("PATH" %in% names(res$env))
    expect_false("Path" %in% names(res$env))
    expect_identical(res$env[["CONDA_SHLVL"]], "1")
  } else {
    # A PATH with `sh` but no `bash`: the activation falls back to `sh`, as
    # `micromamba run` does (P-A8).
    sh_dir <- withr::local_tempdir(pattern = "rt-sh-only-")
    sh_path <- Sys.which("sh")
    expect_true(nzchar(sh_path))
    file.symlink(normalizePath(sh_path), file.path(sh_dir, "sh"))
    expect_false(file.exists(file.path(sh_dir, "bash")))
    res <- call_hook(
      "backend_resolve_run",
      cmd = "x",
      env_name = env_name,
      base_env = hook_base_env(PATH = sh_dir)
    )
    expect_identical(res$env[["CONDA_SHLVL"]], "1")
    expect_identical(
      path_entries(res$env[["PATH"]]),
      c(file.path(normalizePath(prefix), "bin"), sh_dir)
    )
  }
})

test_that("state and env_vars.d values are set as written", {
  # On Linux and macOS rattler passes them to the activation shell in its
  # environment, so the shell never reads them as code; cmd.exe expands
  # %VAR% on Windows, with both backends. micromamba writes them into its
  # activation script in single quotes without escaping them, so a value
  # with a single quote differs between the backends
  # (test-parity-childenv.R).
  env_name <- "rt-hooks-state"
  defer_remove_env(env_name)
  call_hook(
    "backend_create_env",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  prefix <- rattler_env_dir(env_name)
  literal <- "$HOME and ${RT_HOOKS_X} and $(echo x) and `echo y` and 'a'"
  jsonlite::write_json(
    list(
      env_vars = list(RT_HOOKS_LIT = literal, RT_HOOKS_PCT = "%RT_HOOKS_X%")
    ),
    file.path(prefix, "conda-meta", "state"),
    auto_unbox = TRUE
  )
  vars_dir <- file.path(prefix, "etc", "conda", "env_vars.d")
  dir.create(vars_dir, recursive = TRUE)
  jsonlite::write_json(
    list(RT_HOOKS_D = "$RT_HOOKS_X"),
    file.path(vars_dir, "rt-hooks.json"),
    auto_unbox = TRUE
  )
  res <- call_hook(
    "backend_resolve_run",
    cmd = "x",
    env_name = env_name,
    base_env = hook_base_env(RT_HOOKS_X = "expanded")
  )
  expect_identical(res$env[["RT_HOOKS_LIT"]], literal)
  expect_identical(res$env[["RT_HOOKS_D"]], "$RT_HOOKS_X")
  expect_identical(
    res$env[["RT_HOOKS_PCT"]],
    if (isTRUE(is_windows())) "expanded" else "%RT_HOOKS_X%"
  )
})

test_that("a variable an activate.d script unsets is NA in the activation", {
  # condathis removes a variable whose value is NA from the command's
  # environment, as micromamba's activation unsets it.
  env_name <- "rt-hooks-unset"
  defer_remove_env(env_name)
  call_hook(
    "backend_create_env",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  activate_dir <- file.path(
    rattler_env_dir(env_name),
    "etc",
    "conda",
    "activate.d"
  )
  dir.create(activate_dir, recursive = TRUE)
  if (isTRUE(is_windows())) {
    writeLines(
      c("@set \"RT_HOOKS_GONE=\"", "@set \"RT_HOOKS_NEVER=\""),
      file.path(activate_dir, "rt-hooks.bat")
    )
  } else {
    writeLines(
      c("unset RT_HOOKS_GONE", "unset RT_HOOKS_NEVER"),
      file.path(activate_dir, "rt-hooks.sh")
    )
  }
  res <- call_hook(
    "backend_resolve_run",
    cmd = "x",
    env_name = env_name,
    base_env = hook_base_env(RT_HOOKS_GONE = "session", RT_HOOKS_KEPT = "kept")
  )
  gone <- names(res$env)[toupper(names(res$env)) == "RT_HOOKS_GONE"]
  expect_length(gone, 1L)
  expect_identical(unname(res$env[[gone]]), NA_character_)
  # Only that one: a variable that was not set, or that the scripts kept,
  # is not part of the activation, and nothing else is unset.
  expect_identical(names(res$env)[is.na(res$env)], gone)
  expect_false(any(
    toupper(names(res$env)) %in% c("RT_HOOKS_NEVER", "RT_HOOKS_KEPT")
  ))
})

test_that("backend_resolve_run_in_dir() activates a directory and names it by its path", {
  # An environment given by condathis::env_path(): a conda prefix that no
  # backend owns, here a directory with only conda-meta and an activate.d
  # script, which the hook must not change.
  prefix <- file.path(withr::local_tempdir(pattern = "rt-hooks-dir-"), "pfx")
  activate_dir <- file.path(prefix, "etc", "conda", "activate.d")
  dir.create(file.path(prefix, "conda-meta"), recursive = TRUE)
  dir.create(activate_dir, recursive = TRUE)
  if (isTRUE(is_windows())) {
    writeLines(
      "@set \"RT_HOOKS_DIR=on\"",
      file.path(activate_dir, "rt-hooks.bat")
    )
  } else {
    writeLines(
      "export RT_HOOKS_DIR=on",
      file.path(activate_dir, "rt-hooks.sh")
    )
  }
  prefix <- normalizePath(prefix, winslash = "/")
  files_before <- list.files(prefix, recursive = TRUE, all.files = TRUE)
  res <- call_hook(
    "backend_resolve_run_in_dir",
    cmd = "rt-some-command",
    args = c("-a", "b c"),
    env_dir = prefix,
    verbose = "silent",
    base_env = hook_base_env()
  )
  expect_identical(names(res), c("command", "args", "env", "dir"))
  expect_identical(res$command, "rt-some-command")
  expect_identical(res$args, c("-a", "b c"))
  expect_null(res$dir)
  env <- res$env
  expect_identical(env[["RT_HOOKS_DIR"]], "on")
  expect_identical(env[["CONDA_SHLVL"]], "1")
  expect_identical(
    normalizePath(env[["CONDA_PREFIX"]], winslash = "/"),
    prefix
  )
  # As micromamba's activation of a directory: the environment is named by
  # its path, as CONDA_PREFIX spells it.
  expect_identical(env[["CONDA_DEFAULT_ENV"]], env[["CONDA_PREFIX"]])
  expect_identical(
    env[["CONDA_PROMPT_MODIFIER"]],
    paste0("(", env[["CONDA_PREFIX"]], ") ")
  )
  # Nothing written into the environment.
  expect_identical(
    list.files(prefix, recursive = TRUE, all.files = TRUE),
    files_before
  )
})

test_that("an environment given by its directory is named as libmamba names it", {
  # `Activator::get_default_env()`: "base" for micromamba's root prefix
  # (condathis's root), the directory's name when its parent is named
  # `envs` (with case), else its path as CONDA_PREFIX spells it.
  dir <- withr::local_tempdir(pattern = "rt-hooks-name-")
  activation <- c(CONDA_PREFIX = "spelled-as-conda-prefix")
  expect_identical(
    rattler_dir_env_name(file.path(dir, "envs", "my.env"), activation),
    "my.env"
  )
  expect_identical(
    rattler_dir_env_name(file.path(dir, "Envs", "my.env"), activation),
    "spelled-as-conda-prefix"
  )
  expect_identical(
    rattler_dir_env_name(file.path(dir, "pfx"), character(0L)),
    file.path(dir, "pfx")
  )
  expect_identical(
    rattler_dir_env_name(fs::path_dir(rattler_root()), activation),
    "base"
  )
})

test_that("backend_resolve_run() aborts for a missing environment", {
  cnd <- expect_error(
    call_hook(
      "backend_resolve_run",
      cmd = "x",
      env_name = "rt-hooks-no-env",
      base_env = hook_base_env()
    ),
    class = "rattlerthis_env_not_found"
  )
  expect_s3_class(cnd, "condathis_env_not_found")
  expect_false(dir.exists(rattler_env_dir("rt-hooks-no-env")))
})

# --- backend_clean_cache() --------------------------------------------------------

test_that("backend_clean_cache() without caches returns NULL and creates nothing", {
  paths <- local_condathis_sandbox()
  expect_silent(res <- call_hook("backend_clean_cache", verbose = "cmd"))
  expect_null(res)
  expect_false(dir.exists(paths$rattler))
})

test_that("backend_clean_cache() empties rattler's caches and nothing else", {
  paths <- local_condathis_sandbox()
  env_name <- "rt-hooks-clean"
  call_hook(
    "backend_create_env",
    packages = "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    verbose = "silent"
  )
  pkgs_dir <- file.path(paths$rattler, "pkgs")
  repodata_dir <- file.path(paths$rattler, "repodata_cache")
  conda_pkgs <- file.path(paths$rattler, "conda-pkgs")
  dir.create(conda_pkgs)
  writeLines("condathis's", file.path(conda_pkgs, "marker"))
  # Local channels are read in place, so only the package cache has
  # entries here.
  expect_true(length(list.files(pkgs_dir)) > 0L)

  cache_dirs <- rattler_cache_dirs()
  request_line <- paste(
    "Running rattler clean",
    cache_dirs$pkgs,
    cache_dirs$repodata
  )
  output <- capture.output(
    res <- call_hook("backend_clean_cache", verbose = "cmd")
  )
  expect_identical(output, request_line)
  expect_identical(names(res), c("status", "stdout"))
  expect_identical(res$status, 0L)
  expect_match(
    res$stdout,
    "^Removed [1-9][0-9]* cache entr(y|ies) \\([0-9]+ bytes\\)\\.\n$"
  )
  # Both directories stay, empty but for rattler's cache lock, which other
  # sessions may hold (R-29); condathis's conda-pkgs is not rattler's.
  expect_identical(
    list.files(pkgs_dir, all.files = TRUE, no.. = TRUE),
    ".cache.lock"
  )
  expect_identical(
    list.files(repodata_dir, all.files = TRUE, no.. = TRUE),
    character(0L)
  )
  expect_true(file.exists(file.path(conda_pkgs, "marker")))
  unlink(conda_pkgs, recursive = TRUE)
  # The environment still has its package (linked, not in the cache).
  expect_identical(env_records(rattler_env_dir(env_name))$name, "foo")
  expect_true(file.exists(
    file.path(rattler_env_dir(env_name), "share", "foo", "README")
  ))
  # A cleaned cache is no cache to clean for condathis.
  has_cache <- get(
    "backend_has_cache_entries",
    envir = asNamespace("condathis")
  )
  expect_false(has_cache("rattler"))
  # Nothing left: 0 entries; "full" prints the summary.
  output <- capture.output(
    res <- call_hook("backend_clean_cache", verbose = "full")
  )
  expect_identical(
    output,
    c(request_line, "Removed 0 cache entries (0 bytes).")
  )
})

test_that("backend_clean_cache() deletes the cache of the pip steps", {
  paths <- local_condathis_sandbox()
  tool_cache <- file.path(paths$rattler, "cache")
  dir.create(file.path(tool_cache, "pip"), recursive = TRUE)
  writeLines("pip's", file.path(tool_cache, "pip", "marker"))
  output <- capture.output(
    res <- call_hook("backend_clean_cache", verbose = "cmd")
  )
  cache_dirs <- rattler_cache_dirs()
  expect_identical(
    output,
    paste(
      "Running rattler clean",
      cache_dirs$pkgs,
      cache_dirs$repodata,
      rattler_tool_cache_dir()
    )
  )
  expect_identical(res$status, 0L)
  expect_match(res$stdout, "^Removed 1 cache entry ")
  expect_false(dir.exists(tool_cache))
  # Nothing else was created.
  expect_identical(
    list.files(paths$rattler, all.files = TRUE, no.. = TRUE),
    character(0L)
  )
})

# --- backend_can_solve() ------------------------------------------------------------

test_that("backend_can_solve() answers TRUE, FALSE or NA", {
  can_solve <- function(..., channel_priority = "strict") {
    return(call_hook(
      "backend_can_solve",
      channel_priority = channel_priority,
      ...
    ))
  }
  native <- r_build_platform()
  expect_true(can_solve(
    packages = "foo",
    channels = channel_url("chA"),
    platform = native
  ))
  expect_false(can_solve(
    packages = "foo>=3",
    channels = channel_url("chA"),
    platform = native
  ))
  # bar needs foo >=2, which only chB has.
  expect_false(can_solve(
    packages = "bar",
    channels = channel_url("chA"),
    platform = native
  ))
  # With chB after chA, strict priority keeps foo to chA's 1.0; without
  # priority, foo 2.0 of chB is a candidate too.
  expect_false(can_solve(
    packages = "bar",
    channels = channel_url("chA"),
    additional_channels = channel_url("chB"),
    platform = native
  ))
  expect_true(can_solve(
    packages = "bar",
    channels = channel_url("chA"),
    additional_channels = channel_url("chB"),
    channel_priority = "disabled",
    platform = native
  ))
  # Packages of one platform only.
  expect_false(can_solve(
    packages = "osxonly",
    channels = channel_url("osxonly"),
    platform = "linux-64"
  ))
  expect_true(can_solve(
    packages = "osxonly",
    channels = channel_url("osxonly"),
    platform = "osx-64"
  ))
  expect_true(can_solve(
    packages = "winonly",
    channels = channel_url("winonly"),
    platform = "win-64"
  ))
  expect_false(can_solve(
    packages = "winonly",
    channels = channel_url("winonly"),
    platform = "win-arm64"
  ))
  for (platform in c("linux-64", "osx-64", "win-64")) {
    expect_true(
      can_solve(
        packages = "intelonly",
        channels = channel_url("intelonly"),
        platform = platform
      ),
      label = platform
    )
  }
  for (platform in c("linux-aarch64", "osx-arm64", "win-arm64")) {
    expect_false(
      can_solve(
        packages = "intelonly",
        channels = channel_url("intelonly"),
        platform = platform
      ),
      label = platform
    )
  }
  # Cannot tell: a channel that does not exist, a spec rattler cannot read.
  missing_channel <- paste0(
    file_url(withr::local_tempdir(pattern = "rt-hooks-")),
    "/rt-no-channel"
  )
  expect_identical(
    can_solve(packages = "foo", channels = missing_channel, platform = native),
    NA
  )
  expect_identical(
    can_solve(
      packages = "foo[[",
      channels = channel_url("chA"),
      platform = native
    ),
    NA
  )
  # Environment files: YAML is solved; explicit and lock files need no
  # solve, as micromamba's dry run succeeds for them on every platform.
  expect_true(can_solve(
    env_file = envfile_fixture("e1.yml"),
    channels = channel_url("chA"),
    platform = native
  ))
  for (platform in c(native, "win-64", "osx-arm64")) {
    expect_true(can_solve(
      env_file = envfile_fixture("e6.txt"),
      channels = "conda-forge",
      platform = platform
    ))
    expect_true(can_solve(
      env_file = envfile_fixture("e7-lock.yml"),
      channels = "conda-forge",
      platform = platform
    ))
  }
  # An unknown platform is an error (condathis validates platforms first,
  # and counts an error as NA).
  expect_rattler_error(
    can_solve(
      packages = "foo",
      channels = channel_url("chA"),
      platform = "bogus-64"
    ),
    kind = "invalid_platform"
  )
  # A pip section adds `pip` to the solve, as micromamba's dry run does
  # (pip itself does not run): chA has no pip.
  expect_false(can_solve(
    env_file = envfile_fixture("e8-pip.yml"),
    channels = channel_url("chA"),
    platform = native
  ))
  # A mambajs lock file needs no solve either.
  expect_true(can_solve(
    env_file = envfile_fixture("e10-mambajs.json"),
    channels = "conda-forge",
    platform = native
  ))
})

# --- backend_native_platform() ----------------------------------------------------

test_that("backend_native_platform() is the platform this build solves for", {
  expect_identical(call_hook("backend_native_platform"), r_build_platform())
  expect_identical(call_hook("backend_native_platform"), rt_native_platform())
  # condathis dispatches its generic to it.
  generic <- get("backend_native_platform", envir = asNamespace("condathis"))
  expect_identical(generic(new_backend_rattler()), r_build_platform())
  # The platform of the micromamba binary condathis installs for this R
  # (R-6): both follow the architecture R was built for (an x64 R on an
  # ARM64 Windows PC reports "x86-64" and gets win-64, an x86_64 R under
  # Rosetta 2 osx-64).
  micromamba_choice <- get(
    "is_micromamba_available_for_arch",
    envir = asNamespace("condathis")
  )
  expect_identical(call_hook("backend_native_platform"), micromamba_choice())
})

# --- backend_quiesce() ------------------------------------------------------------

test_that("backend_quiesce() waits until no job runs", {
  expect_identical(rt_live_jobs(), 0L)
  res <- withVisible(call_hook("backend_quiesce", timeout = 5))
  expect_true(res$value)
  expect_false(res$visible)

  job <- rt_test_job_sleep(0.4)
  started <- Sys.time()
  res <- withVisible(call_hook("backend_quiesce", timeout = 10))
  waited <- as.numeric(difftime(Sys.time(), started, units = "secs"))
  expect_true(res$value)
  expect_false(res$visible)
  expect_true(waited >= 0.3)
  expect_identical(rt_live_jobs(), 0L)
  expect_true(rt_job_poll(job))

  # After a second it says why R does not return yet. The job sleeps long
  # enough that a loaded machine still reaches the wait well within it.
  job <- rt_test_job_sleep(4)
  expect_message(
    res <- call_hook("backend_quiesce", timeout = 10),
    "Waiting for"
  )
  expect_true(res)
  expect_identical(rt_live_jobs(), 0L)
})

test_that("backend_quiesce() warns and returns FALSE when the timeout runs out", {
  job <- rt_test_job_sleep(30)
  withr::defer({
    rt_job_cancel(job)
    rattler_wait_idle(timeout = 10)
  })
  cnd <- expect_warning(
    res <- call_hook("backend_quiesce", timeout = 0.2),
    class = "rattlerthis_quiesce_timeout"
  )
  expect_false(res)
  expect_s3_class(cnd, "rattlerthis_warning")
  expect_identical(cnd$live_jobs, 1L)
  # condathis's generic gives the same answer.
  generic <- get("backend_quiesce", envir = asNamespace("condathis"))
  expect_warning(
    expect_false(generic(new_backend_rattler(), timeout = 0.1)),
    class = "rattlerthis_quiesce_timeout"
  )
  expect_true(rt_job_cancel(job))
  expect_true(rattler_wait_idle(timeout = 10))
  expect_identical(rt_live_jobs(), 0L)
})

# --- rattler_await() and errors -----------------------------------------------------

test_that("rattler_await() returns the result and classes the errors", {
  expect_true(rattler_await(function() rt_test_job_sleep(0.01)))
  # An error while the job starts: classed, with the error as parent, and
  # no job left.
  cnd <- expect_error(
    rattler_await(function() stop("cannot start {here}")),
    class = "rattlerthis_rattler_error"
  )
  expect_s3_class(cnd, "rattlerthis_error")
  expect_identical(cnd$kind, NA_character_)
  expect_identical(conditionMessage(cnd$parent), "cannot start {here}")
  expect_identical(rt_live_jobs(), 0L)
  # Kind `unsupported` is lifted to condathis's class; text with braces is
  # kept as it is.
  cnd <- expect_rattler_error(
    rattler_abort(simpleError("[rattlerthis:unsupported] no {pip} here")),
    kind = "unsupported"
  )
  expect_s3_class(cnd, "condathis_backend_unsupported")
  expect_identical(conditionMessage(cnd), "no {pip} here")
  for (kind in rattler_error_kinds) {
    expect_rattler_error(
      rattler_abort(simpleError(paste0("[rattlerthis:", kind, "] text"))),
      kind = kind
    )
  }
})

test_that("an interrupt cancels the job and waits until it is idle", {
  real_poll <- rt_job_poll
  polls <- 0L
  testthat::local_mocked_bindings(rt_job_poll = function(job) {
    polls <<- polls + 1L
    if (identical(polls, 2L)) {
      rlang::interrupt()
    }
    return(real_poll(job))
  })
  started <- Sys.time()
  res <- tryCatch(
    rattler_await(function() rt_test_job_sleep(30)),
    interrupt = function(cnd) "interrupted"
  )
  expect_identical(res, "interrupted")
  expect_true(as.numeric(difftime(Sys.time(), started, units = "secs")) < 10)
  expect_identical(rt_live_jobs(), 0L)
})

test_that("an interrupt during a link waits for the link to finish", {
  # A job that is linking answers FALSE to a cancel and completes (R-15):
  # rt_job_cancel() is mocked to answer so for a sleeping job.
  real_poll <- rt_job_poll
  polls <- 0L
  testthat::local_mocked_bindings(
    rt_job_cancel = function(job) FALSE,
    rt_job_poll = function(job) {
      polls <<- polls + 1L
      if (identical(polls, 2L)) {
        rlang::interrupt()
      }
      return(real_poll(job))
    }
  )
  started <- Sys.time()
  expect_message(
    res <- tryCatch(
      rattler_await(function() rt_test_job_sleep(1.5)),
      interrupt = function(cnd) "interrupted"
    ),
    "finish linking"
  )
  expect_identical(res, "interrupted")
  expect_true(as.numeric(difftime(Sys.time(), started, units = "secs")) >= 1.3)
  expect_identical(rt_live_jobs(), 0L)
  # A second interrupt during that wait, delivered for real, is in
  # test-interrupt.R.
})

test_that("a spinner that cli cannot build does not fail a create", {
  # A bad `cli.spinner` option makes cli::make_spinner() fail; the job then
  # runs without a spinner, and none is left running.
  env_name <- "rt-hooks-spinner"
  defer_remove_env(env_name)
  withr::local_options(cli.spinner = "rt-hooks-no-such-spinner")
  rlang::local_interactive(TRUE)
  expect_error(cli::make_spinner())
  expect_null(rattler_make_spinner("Creating"))
  out <- utils::capture.output(
    res <- suppressMessages(condathis::create_env(
      "foo",
      env_name = env_name,
      channels = channel_url("chA"),
      method = "rattler",
      verbose = "spinner"
    ))
  )
  expect_identical(res$status, 0L)
  expect_true(condathis::env_exists(env_name, method = "rattler"))
  expect_identical(rt_live_jobs(), 0L)
})

test_that("the pip steps get the variables that condathis gives the commands of an environment", {
  # rattler_pip_base_env() copies condathis's clean overlay
  # (`get_clean_conda_envvars()` with `child_conda_dirs()`), which
  # condathis does not export: this keeps the two lists equal.
  get_clean <- getFromNamespace("get_clean_conda_envvars", "condathis")
  child_dirs <- getFromNamespace("child_conda_dirs", "condathis")
  env_dir <- file.path(rattler_root(), "envs", "rt-hooks-pip-env")
  clean <- get_clean(
    "rt-hooks-tmp",
    conda_dirs = child_dirs(new_backend_rattler(), env_dir = env_dir)
  )
  withr::local_envvar(
    CONDA_ENVS_DIRS = "/session/envs",
    CONDARC = "/session/condarc",
    MAMBA_ROOT_PREFIX = "/session/root"
  )
  env <- rattler_pip_base_env("rt-hooks-tmp")
  for (name in names(clean)) {
    if (is.null(clean[[name]])) {
      expect_false(name %in% names(env), info = name)
    } else {
      expect_identical(
        unname(env[[name]]),
        as.character(clean[[name]]),
        info = name
      )
    }
  }
  # And the cache of pip, under the rattler root (micromamba's is
  # `<root>/cache`).
  expect_identical(
    unname(env[["XDG_CACHE_HOME"]]),
    as.character(rattler_tool_cache_dir())
  )
})
