#' Create a Conda environment
#'
#' Creates a Conda environment managed by `rattlerthis` and installs
#' dependencies from package specs. Environment solving and installation
#' happen in-process via the `rattler` Rust library; no external package
#' manager binary is downloaded or invoked. See `PLAN.md`.
#'
#' @param packages Character vector of package MatchSpec strings.
#'   Examples: `"python=3.13"`, `"conda-forge::xz"`. Defaults to `NULL`,
#'   which creates an empty environment.
#' @param env_name Character string with the target environment name.
#'   Defaults to `"rattlerthis-env"`.
#' @param channels Character vector with channel names used for dependency
#'   resolution. Defaults to `"conda-forge"`.
#' @param channel_priority Character string with channel priority mode.
#'   Supported values are `"strict"` and `"disabled"` (the `resolvo` solver
#'   backend does not implement a `"flexible"` mode). Defaults to
#'   `"strict"`.
#' @param platform Character string with the platform used for dependency
#'   solving (for example, `"linux-64"`, `"osx-64"`, `"osx-arm64"`,
#'   `"win-64"`). Defaults to `NULL`, which uses the current platform.
#'   Cross-platform solving is not yet exercised end to end; see `TODO.md`.
#' @param overwrite Logical value that controls whether an existing
#'   environment should always be recreated. Defaults to `FALSE`.
#' @param verbose Character string controlling console output. Supported
#'   values are `"output"`, `"silent"`, `"cmd"`, `"spinner"`, and `"full"`.
#'   Defaults to `"output"`.
#'
#' @returns An object of class `rattlerthis_result`, invisibly: a list with
#'   `status`, `env_name`, `prefix`, `packages` (a tibble of installed
#'   records), and `duration`.
#'
#' @examples
#' \dontrun{
#' withr::with_envvar(
#'   c(RATTLERTHIS_ROOT_DIR = withr::local_tempdir()),
#'   {
#'     create_env(packages = "xz", env_name = "xz-env")
#'     run("xz", "--version", env_name = "xz-env")
#'   }
#' )
#' }
#'
#' @export
create_env <- function(
  packages = NULL,
  env_name = "rattlerthis-env",
  channels = "conda-forge",
  channel_priority = c("strict", "disabled"),
  platform = NULL,
  overwrite = FALSE,
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  channel_priority <- rlang::arg_match(channel_priority)
  verbose_list <- parse_strategy_verbose(verbose)

  if (isFALSE(rlang::is_bool(overwrite))) {
    cli::cli_abort(
      message = c(
        `x` = "Argument {.arg overwrite} needs to be a {.cls logical} value."
      ),
      class = "rattlerthis_create_invalid_overwrite_arg"
    )
  }

  if (isTRUE(overwrite) && env_exists(env_name)) {
    remove_env(env_name, verbose = "silent")
  }

  if (isTRUE(verbose_list$strategy %in% c("cmd", "full"))) {
    cli::cli_inform(
      message = c(`i` = "Solving environment {.field {env_name}}...")
    )
  }

  result <- call_rt_install(
    packages = packages,
    env_name = env_name,
    channels = channels,
    channel_priority = channel_priority,
    platform = platform
  )

  if (isTRUE(verbose_list$strategy %in% c("full", "output"))) {
    cli::cli_inform(
      message = c(`!` = "Environment {.field {env_name}} successfully created.")
    )
  }

  invisible(result)
}
