#' Run the pip steps of an environment file, as micromamba runs them
#'
#' After the Conda packages of a create are linked, micromamba 2.10.0
#' installs the `pip:` sections of a YAML file and the pip packages of a
#' lock file with the environment's own pip (libmamba's
#' `install_for_other_pkgmgr()`). This runs the same steps, from
#' `rt_read_env_file()` (`list(manager, specs, cwd)` each), in file order,
#' one after the other, each for its own `specs`, even an empty one:
#'
#' * The specs are written, each followed by a newline, to a new file
#'   `mambaf<10 random letters and digits>` in `cwd` (the directory of the
#'   environment file), which is deleted afterwards.
#' * The command is micromamba's (see `rattler_pip_command()`), started in
#'   `cwd`, in the activated environment: the variables condathis gives
#'   the commands of a rattler environment and micromamba gives its own
#'   (see `rattler_pip_base_env()`), with the activation of the environment
#'   on top (see `rattler_activation()`). On Windows, micromamba's wrapper
#'   also sets `PYTHONIOENCODING=utf-8` and `PYTHONUTF8=1`, and so does
#'   this.
#' * Output: `"\nInstalling <manager> packages: <specs>\n"` and the output
#'   of the command go to `stdout` of the result, and are printed at the
#'   level `"full"` only, as condathis shows micromamba's output; at the
#'   other levels nothing is printed (at `"cmd"`, condathis's request line
#'   is all), with a spinner as condathis shows one for micromamba.
#' * A step that does not exit with status 0, or whose program the
#'   environment does not have, aborts with kind `pip` (see
#'   `rattler_abort_pip()`): the create fails, as micromamba's does ("pip
#'   failed to install packages"), and condathis then removes the new
#'   environment.
#'
#' @param steps The `pip` element of a request.
#' @param prefix Character string, the environment directory.
#' @param strategy One of `rattler_verbose_values`.
#' @param call Environment reported as the caller of errors.
#'
#' @returns `NULL` when there is no step, else `list(stdout, stderr)`: the
#'   text of every step, in order.
#'
#' @keywords internal
#' @noRd
rattler_run_pip_steps <- function(
  steps,
  prefix,
  strategy,
  call = rlang::caller_env()
) {
  if (isFALSE(length(steps) > 0L)) {
    return(NULL)
  }
  stdout <- character(0L)
  stderr <- character(0L)
  for (step in steps) {
    step_result <- rattler_run_pip_step(
      step,
      prefix = prefix,
      strategy = strategy,
      call = call
    )
    stdout <- c(stdout, step_result$stdout)
    stderr <- c(stderr, step_result$stderr)
  }
  return(list(
    stdout = paste(stdout, collapse = ""),
    stderr = paste(stderr, collapse = "")
  ))
}

#' Run one pip step
#'
#' See `rattler_run_pip_steps()`.
#'
#' @param step `list(manager, specs, cwd)`.
#' @inheritParams rattler_run_pip_steps
#'
#' @returns `list(stdout, stderr)`.
#'
#' @keywords internal
#' @noRd
rattler_run_pip_step <- function(step, prefix, strategy, call) {
  manager <- as.character(step$manager)
  specs <- as.character(step$specs)
  cwd <- as.character(step$cwd)
  spec_file <- rattler_pip_spec_file(cwd, specs, call = call)
  on.exit(unlink(spec_file), add = TRUE)
  tmp_dir <- tempfile(pattern = "rattler-tmp")
  fs::dir_create(tmp_dir)
  on.exit(unlink(tmp_dir, recursive = TRUE, force = TRUE), add = TRUE)

  # The specs can be pip options with an index URL and its login.
  header <- paste0(
    "\nInstalling ",
    manager,
    " packages: ",
    paste(rattler_hide_secrets(specs), collapse = ", "),
    "\n"
  )
  full <- identical(strategy, "full")
  if (isTRUE(full)) {
    cat(header)
  }
  command <- rattler_pip_command(manager, prefix, spec_file)
  if (isFALSE(nzchar(command$command))) {
    rattler_abort_pip(
      manager,
      command,
      status = 127L,
      stdout = header,
      stderr = paste0(
        "The environment has no ",
        command$program,
        " program (looked in ",
        paste(rattler_env_bin_dirs(prefix), collapse = ", "),
        ").\n"
      ),
      call = call
    )
  }
  base_env <- rattler_pip_base_env(tmp_dir)
  activation_env <- rattler_activation(prefix, base_env, use_cache = FALSE)
  child_env <- rattler_apply_env(base_env, activation_env)
  if (isTRUE(is_windows())) {
    child_env <- rattler_apply_env(
      child_env,
      c(PYTHONIOENCODING = "utf-8", PYTHONUTF8 = "1")
    )
  }
  px_res <- tryCatch(
    processx::run(
      command = command$command,
      args = command$args,
      wd = cwd,
      env = child_env,
      echo = full,
      spinner = rattler_shows_spinner(strategy),
      error_on_status = FALSE,
      cleanup_tree = TRUE,
      encoding = "UTF-8"
    ),
    error = function(e) {
      # The program did not start.
      list(
        status = 127L,
        stdout = "",
        stderr = paste0(conditionMessage(e), "\n")
      )
    }
  )
  stdout <- paste0(header, px_res$stdout %||% "")
  stderr <- px_res$stderr %||% ""
  if (isFALSE(identical(as.integer(px_res$status), 0L))) {
    rattler_abort_pip(
      manager,
      command,
      status = as.integer(px_res$status),
      stdout = stdout,
      stderr = stderr,
      call = call
    )
  }
  return(list(stdout = stdout, stderr = stderr))
}

#' The command of a pip step, as micromamba builds it
#'
#' libmamba's `get_pkg_mgr_install_command()`, as condathis runs
#' micromamba (no `--quiet`: condathis passes neither `--quiet` nor
#' `--json`):
#'
#' * `"pip"`: `<python> -m pip install -r <file> --no-input`;
#' * `"pip --no-deps"` (the pip packages of a lock file):
#'   `<python> -m pip install --no-deps -r <file> --no-input`;
#' * `"uv"` (a YAML file that lists `uv`): `<uv> pip install -r <file>`.
#'
#' `<python>` and `<uv>` are found in the environment as libmamba finds
#' them (see `rattler_env_program()`); `command` is `""` when the
#' environment has no such program.
#'
#' @param manager `"pip"`, `"pip --no-deps"` or `"uv"`.
#' @param prefix Character string, the environment directory.
#' @param spec_file Character string, the requirements file.
#'
#' @returns `list(command, args, program)`, `program` being `"python"` or
#'   `"uv"`.
#'
#' @keywords internal
#' @noRd
rattler_pip_command <- function(manager, prefix, spec_file) {
  spec_file <- as.character(spec_file)
  if (identical(manager, "uv")) {
    return(list(
      command = rattler_env_program(prefix, "uv"),
      args = c("pip", "install", "-r", spec_file),
      program = "uv"
    ))
  }
  args <- c("-m", "pip", "install")
  if (identical(manager, "pip --no-deps")) {
    args <- c(args, "--no-deps")
  }
  return(list(
    command = rattler_env_program(prefix, "python"),
    args = c(args, "-r", spec_file, "--no-input"),
    program = "python"
  ))
}

#' The directories libmamba looks in for a program of an environment
#'
#' libmamba's `get_path_dirs()`: `bin` on Linux and macOS; on Windows the
#' prefix itself, `Library/mingw-w64/bin`, `Library/usr/bin`,
#' `Library/bin`, `Scripts` and `bin`, in that order.
#'
#' @param prefix Character string, the environment directory.
#'
#' @returns Character vector of directories.
#'
#' @keywords internal
#' @noRd
rattler_env_bin_dirs <- function(prefix) {
  prefix <- as.character(prefix)
  if (isFALSE(is_windows())) {
    return(file.path(prefix, "bin"))
  }
  return(c(
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
  ))
}

#' A program of an environment, as libmamba finds it
#'
#' libmamba's `which_in()` over `rattler_env_bin_dirs()`: the first
#' directory with a regular file of that name (on Windows also with
#' `.exe`) that can be executed (any file on Windows).
#'
#' @param prefix Character string, the environment directory.
#' @param name Character string, such as `"python"`.
#'
#' @returns The absolute path, or `""` when there is none.
#'
#' @keywords internal
#' @noRd
rattler_env_program <- function(prefix, name) {
  candidates <- if (isTRUE(is_windows())) {
    c(paste0(name, ".exe"), name)
  } else {
    name
  }
  for (dir in rattler_env_bin_dirs(prefix)) {
    for (candidate in candidates) {
      path <- file.path(dir, candidate)
      if (
        isTRUE(file.exists(path)) &&
          isFALSE(dir.exists(path)) &&
          (isTRUE(is_windows()) || identical(file.access(path, 1L)[[1L]], 0L))
      ) {
        return(path)
      }
    }
  }
  return("")
}

#' Write the requirements file of a pip step
#'
#' A new file in `dir`, named as libmamba names it (`mambaf` and 10
#' random characters, here of `0-9a-f`, no extension), with each spec
#' followed by a newline, in UTF-8. A file that cannot be written aborts
#' with kind `io`.
#'
#' @param dir Character string, the directory.
#' @param specs Character vector, possibly empty.
#' @param call Environment reported as the caller.
#'
#' @returns The path of the file.
#'
#' @keywords internal
#' @noRd
rattler_pip_spec_file <- function(dir, specs, call = rlang::caller_env()) {
  repeat {
    # Random without R's random number generator, whose state belongs to
    # the user: a hash of a new temporary file name.
    token <- substr(rlang::hash(list(tempfile(), Sys.time())), 1L, 10L)
    path <- file.path(dir, paste0("mambaf", token))
    if (isFALSE(file.exists(path))) {
      break
    }
  }
  text <- if (isTRUE(length(specs) > 0L)) {
    charToRaw(enc2utf8(paste0(specs, "\n", collapse = "")))
  } else {
    raw(0L)
  }
  written <- tryCatch(
    {
      writeBin(text, path)
      TRUE
    },
    error = function(e) conditionMessage(e)
  )
  if (isFALSE(isTRUE(written))) {
    rlang::abort(
      message = paste0(
        "Cannot write the requirements file of pip in ",
        dir,
        ": ",
        written
      ),
      class = rattler_error_class("io"),
      kind = "io",
      call = call
    )
  }
  return(path)
}

#' The environment of a pip step before activation
#'
#' The R session's environment with the variables that condathis gives
#' every command of a rattler environment (its clean overlay:
#' `get_clean_conda_envvars()` with `child_conda_dirs()` in condathis), as
#' micromamba's pip gets them from condathis's micromamba process: a new
#' `TMPDIR`, the Conda settings of the session cleared, `CONDA_ENVS_PATH`
#' (`<root>/envs`), `CONDA_PKGS_DIRS` and `MAMBA_PKGS_DIRS`
#' (`<root>/conda-pkgs`) of this backend, and `R_HOME` empty. condathis
#' runs micromamba with `XDG_CACHE_HOME=<micromamba root>/cache`, so pip
#' keeps its cache there on Linux; here it is `<rattler root>/cache`,
#' which `backend_clean_cache()` empties.
#'
#' @param tmp_dir Character string, the step's temporary directory.
#'
#' @returns A named character vector.
#'
#' @keywords internal
#' @noRd
rattler_pip_base_env <- function(tmp_dir) {
  root <- rattler_root()
  pkgs_dir <- as.character(fs::path(root, "conda-pkgs"))
  overrides <- list(
    TMPDIR = as.character(tmp_dir),
    CONDA_SHLVL = "0",
    MAMBA_SHLVL = "0",
    CONDA_ENVS_PATH = as.character(fs::path(root, "envs")),
    CONDA_ENVS_DIRS = NULL,
    CONDA_ROOT_PREFIX = "",
    CONDA_PREFIX = "",
    MAMBA_ENVS_PATH = "",
    MAMBA_ENVS_DIRS = "",
    MAMBA_ROOT_PREFIX = "",
    MAMBA_PREFIX = "",
    CONDARC = "",
    MAMBARC = "",
    CONDA_PROMPT_MODIFIER = "",
    MAMBA_PROMPT_MODIFIER = "",
    CONDA_DEFAULT_ENV = "",
    MAMBA_DEFAULT_ENV = "",
    CONDA_PKGS_DIRS = pkgs_dir,
    MAMBA_PKGS_DIRS = pkgs_dir,
    R_HOME = "",
    XDG_CACHE_HOME = as.character(rattler_tool_cache_dir())
  )
  session_env <- Sys.getenv()
  env <- as.character(session_env)
  names(env) <- names(session_env)
  for (name in names(overrides)) {
    env <- env[!rattler_name_matches(names(env), name)]
    if (isFALSE(is.null(overrides[[name]]))) {
      env[[name]] <- overrides[[name]]
    }
  }
  return(env)
}

#' Set variables in an environment block
#'
#' Each variable of `overlay` replaces every spelling of its name in
#' `env` (on Windows names have no case), under the overlay's spelling. A
#' variable whose value is `NA` (one the activation unset) is removed.
#'
#' @param env,overlay Named character vectors.
#'
#' @returns A named character vector.
#'
#' @keywords internal
#' @noRd
rattler_apply_env <- function(env, overlay) {
  for (name in names(overlay)) {
    env <- env[!rattler_name_matches(names(env), name)]
    if (isFALSE(is.na(overlay[[name]]))) {
      env[[name]] <- unname(overlay[[name]])
    }
  }
  return(env)
}

#' Abort for a pip step that failed
#'
#' Kind `pip` (classes `rattlerthis_rattler_pip`,
#' `rattlerthis_rattler_error`, `rattlerthis_error`), with micromamba's
#' text ("pip failed to install packages"), the command, its status and
#' its standard error, and the fields `kind`, `status`, `stdout` and
#' `stderr`, as condathis's error for a failed micromamba has `status` and
#' `stderr`.
#'
#' @param manager Character string, the step's manager.
#' @param command From `rattler_pip_command()`.
#' @param status Integer, the exit status.
#' @param stdout,stderr Character strings, the output of the step.
#' @param call Environment reported as the caller.
#'
#' @returns Does not return.
#'
#' @keywords internal
#' @noRd
rattler_abort_pip <- function(manager, command, status, stdout, stderr, call) {
  words <- c(command$command, command$args)
  quote <- grepl("[[:space:]\"']", words) | !nzchar(words)
  words[quote] <- shQuote(words[quote], type = "cmd")
  lines <- strsplit(stderr, "\r?\n")[[1L]]
  lines <- lines[nzchar(lines)]
  names(lines) <- rep(" ", length(lines))
  rlang::abort(
    message = c(
      paste0(
        "pip failed to install packages: `",
        paste(words, collapse = " "),
        "` exited with status ",
        status,
        "."
      ),
      lines
    ),
    class = rattler_error_class("pip"),
    kind = "pip",
    manager = manager,
    status = status,
    stdout = stdout,
    stderr = stderr,
    call = call
  )
}
