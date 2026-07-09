#' Install packages in a Conda environment
#'
#' Installs packages into an existing `rattlerthis` environment. If the
#' target environment does not exist, it is created first. Packages already
#' installed in the environment are always kept: the underlying solve folds
#' them in alongside the newly requested packages, so `install()` never
#' silently drops something `create_env()` or a previous `install()` call
#' put there. See `PLAN.md`.
#'
#' @param packages Character vector of package MatchSpec strings to install.
#' @param env_name Character string with the target environment name.
#'   Defaults to `"rattlerthis-env"`.
#' @param channels Character vector with channel names used for dependency
#'   resolution. Defaults to `"conda-forge"`.
#' @param channel_priority Character string with channel priority mode.
#'   Supported values are `"strict"` and `"disabled"`. Defaults to
#'   `"strict"`.
#' @param verbose Character string controlling console output. Supported
#'   values are `"output"`, `"silent"`, `"cmd"`, `"spinner"`, and `"full"`.
#'   Defaults to `"output"`.
#'
#' @returns An object of class `rattlerthis_result`, invisibly.
#'
#' @examples
#' \dontrun{
#' withr::with_envvar(
#'   c(RATTLERTHIS_ROOT_DIR = withr::local_tempdir()),
#'   {
#'     create_env(packages = "xz", env_name = "xz-env")
#'     install(packages = "zstd", env_name = "xz-env")
#'   }
#' )
#' }
#'
#' @export
install <- function(
  packages,
  env_name = "rattlerthis-env",
  channels = "conda-forge",
  channel_priority = c("strict", "disabled"),
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  rlang::check_required(packages)
  channel_priority <- rlang::arg_match(channel_priority)
  verbose_list <- parse_strategy_verbose(verbose)

  result <- call_rt_install(
    packages = packages,
    env_name = env_name,
    channels = channels,
    channel_priority = channel_priority,
    platform = NULL
  )

  if (
    isTRUE(verbose_list$strategy %in% c("full", "output")) &&
      isTRUE(length(packages) > 0L)
  ) {
    cli::cli_inform(
      message = c(
        `!` = "{cli::qty(packages)}Package{?s} {.field {packages}} successfully installed in environment {.field {env_name}}."
      )
    )
  }

  invisible(result)
}
