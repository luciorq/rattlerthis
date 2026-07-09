#' Get the `rattlerthis` install root directory
#'
#' Mirrors `condathis::get_install_dir()`. Defaults to
#' `tools::R_user_dir("rattlerthis", "data")`, overridable via the R option
#' `rattlerthis.root_dir` or the environment variable `RATTLERTHIS_ROOT_DIR`
#' (the option takes precedence).
#'
#' @returns A character string with the install root directory path.
#' @export
get_install_dir <- function() {
  root <- getOption("rattlerthis.root_dir")
  if (rlang::is_null(root)) {
    root <- Sys.getenv("RATTLERTHIS_ROOT_DIR", unset = NA)
    if (isTRUE(is.na(root))) {
      root <- tools::R_user_dir("rattlerthis", "data")
    }
  }
  fs::path(root)
}

#' Get an environment directory path
#'
#' @param env_name Character string with the environment name.
#'   Defaults to `"rattlerthis-env"`.
#' @returns A character string with the expected environment directory path.
#' @export
get_env_dir <- function(env_name = "rattlerthis-env") {
  fs::path(get_install_dir(), "envs", env_name)
}

#' @keywords internal
#' @noRd
get_repodata_cache_dir <- function() {
  fs::path(get_install_dir(), "repodata_cache")
}

#' @keywords internal
#' @noRd
get_pkgs_cache_dir <- function() {
  fs::path(get_install_dir(), "pkgs")
}

#' List Conda environments managed by rattlerthis
#'
#' @returns A character vector of environment names.
#' @export
list_envs <- function() {
  envs_dir <- fs::path(get_install_dir(), "envs")
  if (isFALSE(fs::dir_exists(envs_dir))) {
    return(character(0L))
  }
  envs <- fs::dir_ls(envs_dir, type = "directory")
  envs <- envs[fs::dir_exists(fs::path(envs, "conda-meta"))]
  fs::path_file(envs)
}

#' Check whether a Conda environment exists
#'
#' @param env_name Character string with the environment name to check.
#' @returns `TRUE` when the environment exists and `FALSE` otherwise.
#' @export
env_exists <- function(env_name) {
  rlang::check_required(env_name)
  isTRUE(env_name %in% list_envs())
}

#' Remove a Conda environment
#'
#' @param env_name Character string with the environment name to remove.
#'   Defaults to `"rattlerthis-env"`.
#' @param verbose Character string controlling console output.
#'   Defaults to `"silent"`.
#' @returns `TRUE`, invisibly.
#' @export
remove_env <- function(
  env_name = "rattlerthis-env",
  verbose = c("silent", "cmd", "output", "spinner", "full")
) {
  verbose_list <- parse_strategy_verbose(verbose)
  if (isFALSE(env_exists(env_name))) {
    cli::cli_abort(
      message = c(
        `x` = "Environment {.field {env_name}} does not exist.",
        `!` = "Check {.code list_envs()} for available environments."
      ),
      class = "rattlerthis_error_env_remove"
    )
  }
  fs::dir_delete(get_env_dir(env_name))
  if (isTRUE(verbose_list$strategy %in% c("full", "output"))) {
    cli::cli_inform(
      message = c(`!` = "Environment {.field {env_name}} successfully removed.")
    )
  }
  invisible(TRUE)
}

#' List packages installed in a Conda environment
#'
#' Reads package metadata directly from the environment's `conda-meta`
#' directory.
#'
#' @param env_name Character string with the target environment name.
#'   Defaults to `"rattlerthis-env"`.
#' @returns A tibble with columns `name`, `version`, `build`,
#'   `build_number`, and `channel`.
#' @export
list_packages <- function(env_name = "rattlerthis-env") {
  if (isFALSE(env_exists(env_name))) {
    cli::cli_abort(
      message = c(
        `x` = "Environment {.field {env_name}} does not exist.",
        `!` = "Check {.code list_envs()} for available environments."
      ),
      class = "rattlerthis_list_packages_missing_env"
    )
  }
  meta_dir <- fs::path(get_env_dir(env_name), "conda-meta")
  files <- fs::dir_ls(meta_dir, type = "file", glob = "*.json")
  empty <- tibble::tibble(
    name = character(0L),
    version = character(0L),
    build = character(0L),
    build_number = integer(0L),
    channel = character(0L)
  )
  if (identical(length(files), 0L)) {
    return(empty)
  }
  rows <- lapply(files, function(f) {
    rec <- jsonlite::fromJSON(f, simplifyVector = TRUE)
    tibble::tibble(
      name = if (rlang::is_null(rec$name)) NA_character_ else rec$name,
      version = if (rlang::is_null(rec$version)) NA_character_ else rec$version,
      build = if (rlang::is_null(rec$build)) NA_character_ else rec$build,
      build_number = if (rlang::is_null(rec$build_number)) {
        NA_integer_
      } else {
        as.integer(rec$build_number)
      },
      channel = if (rlang::is_null(rec$channel)) NA_character_ else rec$channel
    )
  })
  do.call(rbind, rows)
}
