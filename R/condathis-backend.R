#' Construct a `rattlerthis` backend object for `condathis`
#'
#' `rattlerthis` keeps no real per-instance state: its install root is
#' resolved process-globally via `get_install_dir()`'s option/env-var
#' lookup, so the backend object itself carries nothing today. Exists so
#' the adapter functions below have a `backend` argument to dispatch on
#' once `condathis` defines the real generics. See PLAN.md ("`rattlerthis`
#' as a conforming `condathis` backend"), decision 2.
#'
#' @returns An object of class `c("condathis_backend_rattler",
#'   "condathis_backend")`.
#' @keywords internal
#' @noRd
new_backend_rattler <- function() {
  structure(list(), class = c("condathis_backend_rattler", "condathis_backend"))
}

#' Reconcile `condathis`'s `channel_priority` vocabulary with `rattlerthis`'s
#'
#' `condathis`'s contract vocabulary is `c("disabled", "strict",
#' "flexible")`; the `resolvo` solver only implements `"strict"`/
#' `"disabled"`. Errors loudly on `"flexible"` instead of silently
#' downgrading, since that would change solve semantics the caller didn't
#' ask for. See PLAN.md, decision 3.
#'
#' @keywords internal
#' @noRd
backend_channel_priority <- function(channel_priority) {
  if (identical(channel_priority, "flexible")) {
    cli::cli_abort(
      message = c(
        `x` = "The {.field rattler} backend does not support {.val flexible} {.arg channel_priority}.",
        `i` = "The {.pkg resolvo} solver only implements {.val strict} and {.val disabled}."
      ),
      class = "rattlerthis_backend_unsupported_channel_priority"
    )
  }
  channel_priority
}

#' Merge `channels`/`additional_channels` into `rattlerthis`'s single vector
#'
#' `rattlerthis` has no separate "additional channels" concept. See
#' PLAN.md, decision 3.
#'
#' @keywords internal
#' @noRd
backend_merge_channels <- function(channels, additional_channels) {
  c(channels, additional_channels)
}

#' Error loudly on an unsupported `env_file` request
#'
#' `rattlerthis::create_env()` has no `environment.yml` support yet.
#' Silently ignoring `env_file` would look like success while installing
#' nothing the caller asked for. See PLAN.md, decision 3.
#'
#' @keywords internal
#' @noRd
backend_check_env_file <- function(env_file) {
  if (isFALSE(rlang::is_null(env_file))) {
    cli::cli_abort(
      message = c(
        `x` = "The {.field rattler} backend does not support {.arg env_file} yet.",
        `i` = "{.code rattlerthis::create_env()} has no {.file environment.yml} parser. See rattlerthis's TODO.md (\"env_file support in create_env()\")."
      ),
      class = "rattlerthis_backend_unsupported_env_file"
    )
  }
  invisible(NULL)
}

#' `condathis` backend contract: create an environment
#'
#' Adapts `create_env()` to the `backend_create_env(backend, packages,
#' env_file, env_name, channels, channel_priority, additional_channels,
#' platform, overwrite, verbose)` shape from `condathis`'s backend
#' contract. See PLAN.md, decisions 2-3.
#'
#' @keywords internal
#' @noRd
backend_create_env <- function(
  backend,
  packages = NULL,
  env_file = NULL,
  env_name = "rattlerthis-env",
  channels = "conda-forge",
  channel_priority = c("strict", "disabled"),
  additional_channels = NULL,
  platform = NULL,
  overwrite = FALSE,
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  backend_check_env_file(env_file)
  channel_priority <- backend_channel_priority(channel_priority)
  create_env(
    packages = packages,
    env_name = env_name,
    channels = backend_merge_channels(channels, additional_channels),
    channel_priority = channel_priority,
    platform = platform,
    overwrite = overwrite,
    verbose = verbose
  )
}

#' `condathis` backend contract: install packages into an environment
#'
#' @keywords internal
#' @noRd
backend_install <- function(
  backend,
  packages,
  env_name = "rattlerthis-env",
  channels = "conda-forge",
  channel_priority = c("strict", "disabled"),
  additional_channels = NULL,
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  channel_priority <- backend_channel_priority(channel_priority)
  install(
    packages = packages,
    env_name = env_name,
    channels = backend_merge_channels(channels, additional_channels),
    channel_priority = channel_priority,
    verbose = verbose
  )
}

#' `condathis` backend contract: remove an environment
#'
#' @keywords internal
#' @noRd
backend_remove_env <- function(
  backend,
  env_name = "rattlerthis-env",
  verbose = c("silent", "cmd", "output", "spinner", "full")
) {
  remove_env(env_name = env_name, verbose = verbose)
}

#' `condathis` backend contract: list environments
#'
#' `rattlerthis::list_envs()` takes no `verbose` argument (a directory
#' scan has nothing to report); accepted here and dropped. See PLAN.md,
#' decision 3.
#'
#' @keywords internal
#' @noRd
backend_list_envs <- function(backend, verbose = "silent") {
  list_envs()
}

#' `condathis` backend contract: check whether an environment exists
#'
#' @keywords internal
#' @noRd
backend_env_exists <- function(backend, env_name, verbose = "silent") {
  env_exists(env_name)
}

#' `condathis` backend contract: list packages installed in an environment
#'
#' Passes `rattlerthis::list_packages()`'s tibble straight through. Its
#' columns (`name`, `version`, `build`, `build_number`, `channel`) do not
#' match `condathis`'s own `list_packages()` column set — see PLAN.md,
#' "Known gap to flag upward". Reconciling schemas across backends is a
#' `condathis`-side dispatch-layer decision, not something fixed here.
#'
#' @keywords internal
#' @noRd
backend_list_packages <- function(backend, env_name = "rattlerthis-env", verbose = "silent") {
  list_packages(env_name = env_name)
}

#' `condathis` backend contract: get an environment's directory
#'
#' @keywords internal
#' @noRd
backend_get_env_dir <- function(backend, env_name = "rattlerthis-env") {
  get_env_dir(env_name)
}

#' `condathis` backend contract: get the backend's install root directory
#'
#' @keywords internal
#' @noRd
backend_get_install_dir <- function(backend) {
  get_install_dir()
}

#' `condathis` backend contract: resolve (but do not execute) a command
#'
#' Returns `list(command, args, env, dir)` for `condathis`'s single
#' `processx::run()` call site to consume — does not spawn anything itself.
#' Built on `resolve_run_command()` (PLAN.md, decision 4), the same
#' plumbing `run()` uses, minus the actual `processx::run()` call.
#'
#' @keywords internal
#' @noRd
backend_resolve_run <- function(
  backend,
  cmd,
  args = character(0L),
  env_name = "rattlerthis-env",
  verbose = "silent"
) {
  resolved <- resolve_run_command(cmd = cmd, env_name = env_name)
  list(
    command = resolved$command,
    args = as.character(args),
    env = resolved$env,
    dir = NULL
  )
}

#' `condathis` backend contract: cheap availability probe
#'
#' Trivially `TRUE`: this code only runs once `rattlerthis`'s compiled
#' library has already loaded successfully (no lazy-load path), so there is
#' nothing further to probe. Documented explicitly so this isn't mistaken
#' for an unfinished implementation later. See PLAN.md, decision 3.
#'
#' @keywords internal
#' @noRd
backend_available <- function(backend) {
  TRUE
}
