#' Construct the rattler backend object for condathis
#'
#' The object that `.onLoad()` registers with
#' `condathis::register_backend()` under the name `"rattler"`: a list of
#' the backend functions of condathis's contract (version 2, condathis
#' 0.2.0.9010; see `?condathis::register_backend`), with its own class.
#' condathis registers each function as an S3 method of its generic of the
#' same name, so this package declares no S3 methods.
#'
#' The object has the three required functions and the five optional ones
#' that need rattler: `backend_clean_cache()`, `backend_quiesce()`,
#' `backend_native_platform()`, `backend_can_solve()` and
#' `backend_resolve_run_in_dir()` (environments given by
#' `condathis::env_path()`). condathis's
#' defaults supply the rest (`backend_get_install_dir()`,
#' `backend_get_env_dir()`, `backend_list_envs()`, `backend_env_exists()`,
#' `backend_list_packages()`, `backend_remove_env()` and
#' `backend_available()`): rattler environments are conda prefixes in
#' `<condathis::backend_root_dir("rattler")>/envs`, which the defaults list,
#' read and remove as micromamba's file system rules do.
#'
#' A build without the Rust library (WebAssembly, see `tools/config.R`)
#' gets the object of `new_backend_rattler_unsupported()` instead, so that
#' the package still loads and registers, as condathis requires of a
#' backend package it knows.
#'
#' @param rust_available `TRUE` when the Rust routines of the package are
#'   loaded (see `rattler_rust_available()`).
#'
#' @returns A named list of class
#'   `c("condathis_backend_rattler", "condathis_backend")`.
#'
#' @keywords internal
#' @noRd
new_backend_rattler <- function(rust_available = rattler_rust_available()) {
  if (isFALSE(rust_available)) {
    return(new_backend_rattler_unsupported())
  }
  return(structure(
    list(
      backend_create_env = rattler_backend_create_env,
      backend_install = rattler_backend_install,
      backend_resolve_run = rattler_backend_resolve_run,
      backend_resolve_run_in_dir = rattler_backend_resolve_run_in_dir,
      backend_clean_cache = rattler_backend_clean_cache,
      backend_quiesce = rattler_backend_quiesce,
      backend_native_platform = rattler_backend_native_platform,
      backend_can_solve = rattler_backend_can_solve
    ),
    class = c("condathis_backend_rattler", "condathis_backend")
  ))
}

#' Whether the Rust routines of the package are loaded
#'
#' `FALSE` in a build without the Rust library: on WebAssembly (webR),
#' `tools/config.R` compiles only `src/wasm/init.c`, which registers no
#' routines. It checks the routine, not the platform, so the same rule holds
#' for any build without Rust, and a test can build one on any platform.
#'
#' @returns `TRUE` or `FALSE`.
#'
#' @keywords internal
#' @noRd
rattler_rust_available <- function() {
  return(isTRUE(is.loaded("wrap__rt_job_poll", PACKAGE = "rattlerthis")))
}

#' The rattler backend object of a build without the Rust library
#'
#' Registered instead of `new_backend_rattler()`'s object when
#' `rattler_rust_available()` is `FALSE`. `backend_available()` is `FALSE`,
#' so `method = "auto"` never picks it for a new environment. The three
#' functions that condathis requires abort with
#' `rattler_abort_rust_unavailable()`, so `method = "rattler"` fails with a
#' condathis error that says why. They have the arguments of the real ones,
#' which `condathis::register_backend()` checks. condathis's defaults supply
#' the rest: they read the file system, and find no rattler environment.
#'
#' @returns A named list of class
#'   `c("condathis_backend_rattler", "condathis_backend")`.
#'
#' @keywords internal
#' @noRd
new_backend_rattler_unsupported <- function() {
  unsupported <- function(fn) {
    stub <- function() rattler_abort_rust_unavailable()
    formals(stub) <- formals(fn)
    return(stub)
  }
  return(structure(
    list(
      backend_create_env = unsupported(rattler_backend_create_env),
      backend_install = unsupported(rattler_backend_install),
      backend_resolve_run = unsupported(rattler_backend_resolve_run),
      backend_available = function(backend) FALSE
    ),
    class = c("condathis_backend_rattler", "condathis_backend")
  ))
}

#' Abort because this build has no Rust library
#'
#' @param call Environment reported as the caller.
#'
#' @returns Does not return. The error has the classes
#'   `rattlerthis_rust_unavailable`, `condathis_backend_unsupported` and
#'   `rattlerthis_error`.
#'
#' @keywords internal
#' @noRd
rattler_abort_rust_unavailable <- function(call = rlang::caller_env()) {
  platform <- R.version$platform
  cli::cli_abort(
    message = c(
      `x` = "The {.field rattler} backend is not available in this build of {.pkg rattlerthis}.",
      `i` = "It was built without its Rust library (R platform {.val {platform}}), which rattler needs. rattler cannot be built for WebAssembly (webR).",
      `i` = "Install {.pkg rattlerthis} on Linux, macOS or Windows to use it."
    ),
    class = c(
      "rattlerthis_rust_unavailable",
      "condathis_backend_unsupported",
      "rattlerthis_error"
    ),
    platform = platform,
    call = call
  )
}

#' Register this package as condathis's `"rattler"` backend
#'
#' Called from `.onLoad()` and from the `packageEvent("condathis",
#' "onLoad")` hook, so a reload of condathis (its registry lives in its own
#' namespace) registers the backend again. A function at the top level of
#' the package, so `.onUnload()` finds the hook with `identical()`.
#' `NAMESPACE` imports nothing from condathis, so loading this package
#' does not load condathis: `.onLoad()` loads it (with its version check)
#' before it calls this. A backend object that breaks condathis's contract
#' fails the registration, and so the load of this package: condathis
#' reports it with `condathis_backend_load_failed` when it loads the
#' package on demand.
#' condathis is called with `condathis::`, never through imports: after a
#' reload of condathis, imported copies would be the functions of the old
#' namespace.
#'
#' @param ... Ignored. The hook is called with the package name and path.
#'
#' @returns `TRUE`, invisibly.
#'
#' @keywords internal
#' @noRd
register_condathis_backend <- function(...) {
  condathis::register_backend(rattler_backend_name, new_backend_rattler())
  return(invisible(TRUE))
}

#' Remove this package's backend registration from condathis
#'
#' Called from `.onUnload()`: condathis must not dispatch into an unloaded
#' namespace. Unloading never loads condathis.
#'
#' @returns Logical, invisibly: whether a backend was unregistered.
#'
#' @keywords internal
#' @noRd
unregister_condathis_backend <- function() {
  if (isFALSE(isNamespaceLoaded("condathis"))) {
    return(invisible(FALSE))
  }
  removed <- tryCatch(
    isTRUE(condathis::unregister_backend(rattler_backend_name)),
    error = function(e) FALSE
  )
  return(invisible(removed))
}

#' Remove this package's condathis load hook
#'
#' Called from `.onUnload()`, before `unregister_condathis_backend()`. The
#' hook list belongs to base R and outlives this package: left behind, the
#' hook would register the functions of an unloaded namespace the next
#' time condathis loads. Only this package's own hook is removed (matched
#' with `identical()`).
#'
#' @returns Logical, invisibly: whether a hook was removed.
#'
#' @keywords internal
#' @noRd
remove_condathis_load_hook <- function() {
  hook_name <- packageEvent("condathis", "onLoad")
  hooks <- getHook(hook_name)
  is_own <- vapply(
    hooks,
    function(hook) identical(hook, register_condathis_backend),
    logical(1L)
  )
  if (isFALSE(any(is_own))) {
    return(invisible(FALSE))
  }
  setHook(hook_name, hooks[!is_own], action = "replace")
  return(invisible(TRUE))
}

#' Abort for an environment that does not exist
#'
#' condathis checks that an environment exists before it calls
#' `backend_install()` and `backend_resolve_run()`. These hooks still get a
#' missing environment when that check failed, or from a direct call, and
#' then signal this error, with condathis's class `condathis_env_not_found`
#' (see *Missing environments* in `?condathis::register_backend`).
#'
#' @param env_name Character string with the environment name.
#' @param class Character vector of the more specific classes.
#' @param call Environment reported as the caller.
#'
#' @returns Does not return.
#'
#' @keywords internal
#' @noRd
rattler_abort_env_not_found <- function(
  env_name,
  class = NULL,
  call = rlang::caller_env()
) {
  cli::cli_abort(
    message = c(
      `x` = "Environment {.field {env_name}} does not exist.",
      `!` = "Check {.code condathis::list_envs()} for available environments."
    ),
    class = c(
      "rattlerthis_env_not_found",
      class,
      "condathis_env_not_found",
      "rattlerthis_error"
    ),
    env_name = env_name,
    call = call
  )
}

#' The `backend_create_env()` function of the rattler backend
#'
#' condathis calls it only when the environment directory does not exist:
#' it has moved an existing environment aside (`overwrite = TRUE`) or
#' deleted a directory that was not an environment, and it moves the old
#' environment back when this call fails (see `?condathis::register_backend`).
#' The request comes from `packages` or from `env_file` (see
#' `rattler_env_file_request()`). rattler solves, downloads and links in
#' this R process, as one job (`rt_install()`, or `rt_install_explicit()`
#' for explicit and lock files). It runs no link scripts and reports
#' them as `link_scripts_skipped`, which condathis warns about. The
#' `variables:` of a YAML file are not used, as by micromamba, which
#' condathis runs with `--no-env` (see `rattler_report_env_variables()`).
#' Then the pip steps of the file run, as micromamba runs them (see
#' `rattler_run_pip_steps()`); a failed one fails the create, and condathis
#' removes the new environment.
#'
#' @inheritParams rattler_backend_install
#' @param env_file `NULL`, or the path of an environment file.
#' @param overwrite `TRUE` or `FALSE`. Not used: the directory is always
#'   free when condathis calls this function.
#'
#' @returns `list(status = 0L, stdout, link_scripts_skipped)`, see
#'   `rattler_mutation_result()`; after pip steps, `stdout` also holds
#'   their output and `stderr` their standard error.
#'
#' @keywords internal
#' @noRd
rattler_backend_create_env <- function(
  backend,
  packages = NULL,
  env_file = NULL,
  env_name = "condathis-env",
  channels = "conda-forge",
  channel_priority = c("strict", "flexible", "disabled"),
  additional_channels = NULL,
  platform = NULL,
  overwrite = FALSE,
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  strategy <- rattler_strategy(verbose)
  channel_priority <- channel_priority[[1L]]
  prefix <- rattler_env_dir(env_name)
  request <- if (is.null(env_file)) {
    rattler_specs_request(packages, channels, additional_channels)
  } else {
    rattler_env_file_request(
      env_file,
      channels = channels,
      additional_channels = additional_channels,
      platform = platform
    )
  }
  cache_dirs <- rattler_cache_dirs(create = TRUE)
  on.exit(rattler_forget_activation(prefix), add = TRUE)
  rattler_print_request(
    strategy,
    rattler_request_words(
      "create",
      env_name,
      request,
      platform,
      channel_priority = channel_priority
    )
  )
  job_result <- rattler_await(
    function() {
      rattler_start_install(
        request,
        prefix = prefix,
        channel_priority = channel_priority,
        platform = platform,
        cache_dirs = cache_dirs
      )
    },
    strategy = strategy,
    label = paste0("Creating environment ", env_name)
  )
  result <- rattler_mutation_result(job_result, strategy = strategy)
  rattler_report_env_variables(strategy, request$variables)
  pip_result <- rattler_run_pip_steps(
    request$pip,
    prefix = prefix,
    strategy = strategy
  )
  if (isFALSE(is.null(pip_result))) {
    result$stdout <- paste0(result$stdout, pip_result$stdout)
    result$stderr <- pip_result$stderr
  }
  return(result)
}

#' The `backend_install()` function of the rattler backend
#'
#' Solves `packages` together with what the environment has (installed
#' packages are kept as favored records, and libmamba's python minor pin
#' and `conda-meta/pinned` apply), against only `channels` and
#' `additional_channels`, for `platform`, and links the result: one
#' `rt_install()` job. It never creates an environment: a missing one
#' aborts with `condathis_install_packages_env_not_found`.
#'
#' @param backend The backend object.
#' @param packages Character vector of match specs.
#' @param env_name Character string with the environment name.
#' @param channels Character vector of channel names or URLs.
#' @param channel_priority `"strict"`, `"flexible"` or `"disabled"`.
#' @param additional_channels `NULL`, or more channels, after `channels`.
#' @param platform `NULL` (the platform rattlerthis was built for), or the
#'   platform to solve for.
#' @param verbose One of `"output"`, `"silent"`, `"cmd"`, `"spinner"` and
#'   `"full"`.
#'
#' @returns `list(status = 0L, stdout, link_scripts_skipped)`.
#'
#' @keywords internal
#' @noRd
rattler_backend_install <- function(
  backend,
  packages,
  env_name = "condathis-env",
  channels = "conda-forge",
  channel_priority = c("strict", "flexible", "disabled"),
  additional_channels = NULL,
  platform = NULL,
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  strategy <- rattler_strategy(verbose)
  channel_priority <- channel_priority[[1L]]
  prefix <- rattler_env_dir(env_name)
  if (isFALSE(rattler_is_env_dir(prefix))) {
    rattler_abort_env_not_found(
      env_name,
      class = "condathis_install_packages_env_not_found"
    )
  }
  request <- rattler_specs_request(packages, channels, additional_channels)
  cache_dirs <- rattler_cache_dirs(create = TRUE)
  on.exit(rattler_forget_activation(prefix), add = TRUE)
  rattler_print_request(
    strategy,
    rattler_request_words(
      "install",
      env_name,
      request,
      platform,
      channel_priority = channel_priority
    )
  )
  job_result <- rattler_await(
    function() {
      rattler_start_install(
        request,
        prefix = prefix,
        channel_priority = channel_priority,
        platform = platform,
        cache_dirs = cache_dirs
      )
    },
    strategy = strategy,
    label = paste0("Installing into environment ", env_name)
  )
  return(rattler_mutation_result(job_result, strategy = strategy))
}

#' The `backend_resolve_run()` function of the rattler backend
#'
#' Describes how to run `cmd` in the activated environment. The activation
#' runs the environment's activation scripts (`activate.d`) and sets the
#' variables of `conda-meta/state` and `etc/conda/env_vars.d` (as written,
#' never expanded by the shell on Linux and macOS, as micromamba exports
#' them), in a shell that rattlerthis starts with `base_env` as its whole
#' environment (`bash`, else `sh`; `cmd.exe` on Windows), as one
#' `rt_activation_env()` job, so the session's own `CONDA_*` settings never
#' reach it. The activation is cached per environment, as condathis caches
#' micromamba's, until the environment or `base_env` changes (see
#' `rattler_activation()`), so the `activate.d` scripts do not run for
#' every command. The variables it changes, plus
#' `CONDA_DEFAULT_ENV` and `CONDA_PROMPT_MODIFIER` as micromamba's
#' activation sets them, are returned as `env`, with `NA` for a variable
#' that an `activate.d` script unsets; condathis applies them on top of
#' `base_env` (and removes the `NA` ones). On Windows the `PATH` variable
#' keeps the spelling it has in `base_env`; its empty and repeated entries
#' are dropped, as condathis drops them from micromamba's (see
#' `rattler_tidy_path()`). `command` stays the bare `cmd`: condathis looks
#' it up as micromamba's `run()` does on each OS.
#'
#' @inheritParams rattler_backend_install
#' @param cmd Character string, the command.
#' @param args Character vector of arguments.
#' @param base_env Named character vector, the environment of the command
#'   before activation, or `NULL` (direct calls only: the R session's
#'   environment).
#' @param timeout Numeric, the seconds the activation may take: an
#'   activation that runs out of time is stopped (its shell and what it
#'   started are killed) and aborts with kind `cancelled`, and condathis
#'   reports the call as timed out.
#'
#' @returns `list(command, args, env, dir = NULL)`.
#'
#' @keywords internal
#' @noRd
rattler_backend_resolve_run <- function(
  backend,
  cmd,
  args = character(0L),
  env_name = "condathis-env",
  verbose = "silent",
  base_env = NULL,
  timeout = Inf
) {
  prefix <- rattler_env_dir(env_name)
  if (isFALSE(rattler_is_env_dir(prefix))) {
    rattler_abort_env_not_found(env_name)
  }
  return(rattler_resolve_run_in_prefix(
    prefix,
    cmd = cmd,
    args = args,
    base_env = base_env,
    env_label = env_name,
    timeout = timeout
  ))
}

#' The `backend_resolve_run_in_dir()` function of the rattler backend
#'
#' Describes how to run `cmd` in the activated environment whose directory
#' (prefix) is `env_dir`: an environment given by `condathis::env_path()`,
#' which condathis did not create and which may belong to no backend, such
#' as one made by conda, mamba or micromamba elsewhere. condathis calls it
#' only after it checked that `env_dir` exists and has a `conda-meta`
#' directory, and only for `run()`, `run_bin()` and `run_pipeline()` with
#' activation. The activation is the one of `rattler_backend_resolve_run()`,
#' of that directory (cached per directory, see `rattler_activation()`).
#' `CONDA_DEFAULT_ENV` and `CONDA_PROMPT_MODIFIER` name the environment as
#' micromamba's activation names a directory (see `rattler_dir_env_name()`).
#' The environment is not changed, locked or registered.
#'
#' @inheritParams rattler_backend_resolve_run
#' @param env_dir Character string, the absolute path of the environment
#'   directory.
#'
#' @returns `list(command, args, env, dir = NULL)`.
#'
#' @keywords internal
#' @noRd
rattler_backend_resolve_run_in_dir <- function(
  backend,
  cmd,
  args = character(0L),
  env_dir,
  verbose = "silent",
  base_env = NULL,
  timeout = Inf
) {
  return(rattler_resolve_run_in_prefix(
    as.character(env_dir),
    cmd = cmd,
    args = args,
    base_env = base_env,
    env_label = NULL,
    timeout = timeout
  ))
}

#' Describe a command run in an activated rattler prefix
#'
#' The body of `rattler_backend_resolve_run()`, for an environment given by
#' name, and of `rattler_backend_resolve_run_in_dir()`, for one given by
#' path.
#'
#' @param prefix Character string, the environment directory.
#' @param cmd Character string, the command.
#' @param args Character vector of arguments.
#' @param base_env Named character vector, or `NULL`.
#' @param env_label Character string, the name of the environment, or
#'   `NULL` for an environment given by path (see `rattler_dir_env_name()`).
#' @param timeout Numeric, the seconds the activation may take.
#'
#' @returns `list(command, args, env, dir = NULL)`.
#'
#' @keywords internal
#' @noRd
rattler_resolve_run_in_prefix <- function(
  prefix,
  cmd,
  args = character(0L),
  base_env = NULL,
  env_label = NULL,
  timeout = Inf
) {
  activation_env <- rattler_activation(prefix, base_env, timeout = timeout)
  if (is.null(env_label)) {
    env_label <- rattler_dir_env_name(prefix, activation_env)
  }
  activation_env[["CONDA_DEFAULT_ENV"]] <- env_label
  activation_env[["CONDA_PROMPT_MODIFIER"]] <- paste0("(", env_label, ") ")
  return(list(
    command = cmd,
    args = as.character(args),
    env = activation_env,
    dir = NULL
  ))
}

#' The name of an environment given by its directory
#'
#' As libmamba's activation names a prefix (`Activator::get_default_env()`),
#' for `CONDA_DEFAULT_ENV` and `CONDA_PROMPT_MODIFIER`: `"base"` for
#' micromamba's root prefix (condathis's root, which condathis gives
#' micromamba), the directory's own name when its parent directory is named
#' `envs` (compared with case), else its path, spelled as `CONDA_PREFIX`.
#'
#' @param prefix Character string, the environment directory, as given.
#' @param activation_env Named character vector, the activation of
#'   `prefix`.
#'
#' @returns A character string.
#'
#' @keywords internal
#' @noRd
rattler_dir_env_name <- function(prefix, activation_env) {
  micromamba_root <- fs::path_dir(rattler_root())
  real_prefix <- tryCatch(fs::path_real(prefix), error = function(e) prefix)
  real_root <- tryCatch(
    fs::path_real(micromamba_root),
    error = function(e) micromamba_root
  )
  if (isTRUE(identical(as.character(real_prefix), as.character(real_root)))) {
    return("base")
  }
  if (identical(as.character(fs::path_file(fs::path_dir(prefix))), "envs")) {
    return(as.character(fs::path_file(prefix)))
  }
  conda_prefix <- rattler_env_value(activation_env, "CONDA_PREFIX")
  if (isTRUE(is.na(conda_prefix))) {
    return(as.character(prefix))
  }
  return(conda_prefix)
}

#' The `backend_clean_cache()` function of the rattler backend
#'
#' Empties rattler's package cache (`<root>/pkgs`, under rattler's cache
#' lock) and repodata cache (`<root>/repodata_cache`), one
#' `rt_clean_cache()` job, and deletes the cache of the tools a create runs
#' (`<root>/cache`, pip's on Linux, see `rattler_tool_cache_dir()`), as
#' condathis deletes micromamba's `<root>/cache`; nothing else. condathis
#' empties `<root>/conda-pkgs` itself. Without any of these directories
#' there is nothing to clean: nothing is created and no job starts. A file
#' that cannot be deleted (on Windows, one in use) aborts after everything
#' else was deleted. `pkgs` and `repodata_cache` stay, empty but for
#' `pkgs/.cache.lock`: rattler's installs of other R sessions lock that
#' file without checking that it is still the file at that path, so
#' deleting it could let two of them into the cache at once (micromamba's
#' clean deletes its `pkgs` directory). condathis counts neither directory
#' as a cache that needs cleaning.
#'
#' @inheritParams rattler_backend_install
#'
#' @returns `NULL` when there was nothing to clean, else
#'   `list(status = 0L, stdout)`, where `stdout` reports what was removed.
#'
#' @keywords internal
#' @noRd
rattler_backend_clean_cache <- function(
  backend,
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  strategy <- rattler_strategy(verbose)
  cache_dirs <- rattler_cache_dirs(create = FALSE)
  tool_cache <- rattler_tool_cache_dir()
  has_tool_cache <- isTRUE(fs::dir_exists(tool_cache))
  if (
    isFALSE(fs::dir_exists(cache_dirs$pkgs)) &&
      isFALSE(fs::dir_exists(cache_dirs$repodata)) &&
      isFALSE(has_tool_cache)
  ) {
    return(NULL)
  }
  rattler_print_request(
    strategy,
    c(
      "clean",
      as.character(cache_dirs$pkgs),
      as.character(cache_dirs$repodata),
      if (isTRUE(has_tool_cache)) as.character(tool_cache)
    )
  )
  has_caches <- isTRUE(fs::dir_exists(cache_dirs$pkgs)) ||
    isTRUE(fs::dir_exists(cache_dirs$repodata))
  cleaned <- if (isTRUE(has_caches)) {
    rattler_await(
      function() {
        rt_clean_cache(
          as.character(cache_dirs$pkgs),
          as.character(cache_dirs$repodata)
        )
      },
      strategy = strategy,
      label = "Cleaning the rattler caches"
    )
  } else {
    list(removed = character(0L), failed = character(0L), bytes = 0)
  }
  removed <- as.character(cleaned[["removed"]])
  # With `/` only, as condathis writes paths (rattler gives `\` below the
  # cache directories on Windows).
  failed <- as.character(fs::path_tidy(as.character(cleaned[["failed"]])))
  if (isTRUE(has_tool_cache)) {
    tool_failed <- rattler_delete_tool_cache(tool_cache)
    if (isTRUE(length(tool_failed) > 0L)) {
      failed <- c(failed, tool_failed)
    } else {
      removed <- c(removed, as.character(tool_cache))
    }
  }
  summary_line <- paste0(
    "Removed ",
    length(removed),
    " cache entr",
    if (identical(length(removed), 1L)) "y" else "ies",
    " (",
    format(sum(as.numeric(cleaned[["bytes"]])), scientific = FALSE),
    " bytes)."
  )
  if (identical(strategy, "full")) {
    cat(summary_line, "\n", sep = "")
  }
  if (isTRUE(length(failed) > 0L)) {
    cli::cli_abort(
      message = c(
        `x` = "Could not delete {length(failed)} entr{?y/ies} of the {.field rattler} caches.",
        `i` = "Close the programs that use them, and try again.",
        `i` = "Not deleted: {.path {failed}}."
      ),
      class = rattler_error_class("io"),
      kind = "io",
      failed = failed
    )
  }
  return(list(status = 0L, stdout = paste0(summary_line, "\n")))
}

#' Delete the cache directory of the tools a create runs
#'
#' What cannot be deleted (a file in use on Windows, a directory without
#' write permission) is left, and reported.
#'
#' @param tool_cache Character string, from `rattler_tool_cache_dir()`.
#'
#' @returns Character vector: the paths (with `/`) that are left, empty
#'   when the directory is gone.
#'
#' @keywords internal
#' @noRd
rattler_delete_tool_cache <- function(tool_cache) {
  tryCatch(fs::dir_delete(tool_cache), error = function(e) NULL)
  if (isFALSE(fs::dir_exists(tool_cache))) {
    return(character(0L))
  }
  left <- fs::dir_ls(tool_cache, recurse = TRUE, all = TRUE, fail = FALSE)
  left <- left[!fs::dir_exists(left)]
  if (identical(length(left), 0L)) {
    left <- tool_cache
  }
  return(as.character(fs::path_tidy(left)))
}

#' The `backend_quiesce()` function of the rattler backend
#'
#' rattler works in R's own process, so stopping processes does not stop
#' it. condathis calls this before `with_sandbox_dir()` and `clean_cache()`
#' delete directories, and it waits for the jobs that still run (see
#' `rattler_wait_idle()`).
#'
#' @param backend The backend object.
#' @param timeout Positive number of seconds. Defaults to 30.
#'
#' @returns `TRUE`, invisibly, when no job runs any more. `FALSE` when
#'   `timeout` ran out, with a warning of class
#'   `rattlerthis_quiesce_timeout`.
#'
#' @keywords internal
#' @noRd
rattler_backend_quiesce <- function(backend, timeout = 30) {
  return(rattler_wait_idle(timeout = timeout))
}

#' The `backend_native_platform()` function of the rattler backend
#'
#' The platform rattlerthis was compiled for (`Platform::current()`): what
#' it solves for without a `platform`. An x64 R on an ARM64 Windows PC has
#' an x64 rattlerthis, so it gives `"win-64"`.
#'
#' @param backend The backend object.
#'
#' @returns A platform (subdir) name, such as `"linux-64"`.
#'
#' @keywords internal
#' @noRd
rattler_backend_native_platform <- function(backend) {
  return(rt_native_platform())
}

#' The `backend_can_solve()` function of the rattler backend
#'
#' Whether a create request solves for `platform`, for condathis's
#' emulation fallback (see `?condathis::register_backend`): one
#' `rt_solve_check()` job, which downloads channel metadata but no
#' package, against the repodata of `platform` and `noarch` and the virtual
#' packages of `platform` (`CONDA_OVERRIDE_*` honored). An `env_file` is
#' read as the create reads it: a YAML or plain file is solved (with the
#' `pip` that a `pip:` section adds; pip itself does not run, as in
#' micromamba's dry run), and an explicit or lock file needs no solve
#' (`TRUE`, as micromamba's dry run gives for every platform).
#'
#' @inheritParams rattler_backend_create_env
#'
#' @returns `TRUE` (solves), `FALSE` (does not solve) or `NA` (cannot
#'   tell: a missing channel, no network, an invalid spec). An error, such
#'   as an unreadable `env_file`, counts as `NA` for condathis.
#'
#' @keywords internal
#' @noRd
rattler_backend_can_solve <- function(
  backend,
  packages = NULL,
  env_file = NULL,
  channels = "conda-forge",
  channel_priority = c("strict", "flexible", "disabled"),
  additional_channels = NULL,
  platform
) {
  channel_priority <- channel_priority[[1L]]
  request <- if (is.null(env_file)) {
    rattler_specs_request(packages, channels, additional_channels)
  } else {
    rattler_env_file_request(
      env_file,
      channels = channels,
      additional_channels = additional_channels,
      platform = platform
    )
  }
  # No solve: micromamba's dry run succeeds for every platform, also for a
  # lock file without packages for `platform` (an empty environment).
  if (isTRUE(request$kind %in% c("explicit", "conda_lock", "mambajs_lock"))) {
    return(TRUE)
  }
  cache_dirs <- rattler_cache_dirs(create = TRUE)
  return(rattler_await(
    function() {
      rt_solve_check(
        request$specs,
        request$channels,
        channel_priority,
        platform,
        as.character(cache_dirs$repodata),
        as.character(cache_dirs$pkgs),
        net_root = rattler_net_root()
      )
    },
    strategy = "silent"
  ))
}
