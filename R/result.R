#' Build a `rattlerthis_result` object from a raw `rt_install()` return value
#'
#' @param rt_result List returned by the internal `rt_install()` bridge.
#' @param env_name Character string with the environment name.
#' @returns An object of class `rattlerthis_result`.
#' @keywords internal
#' @noRd
new_rattlerthis_result <- function(rt_result, env_name) {
  packages <- tibble::tibble(
    name = rt_result$name,
    version = rt_result$version,
    build = rt_result$build,
    channel = rt_result$channel
  )
  structure(
    list(
      status = 0L,
      env_name = env_name,
      prefix = rt_result$prefix,
      packages = packages,
      duration = NA_real_
    ),
    class = "rattlerthis_result"
  )
}

#' @export
print.rattlerthis_result <- function(x, ...) {
  cli::cli_inform(
    message = c(
      `v` = "Environment {.field {x$env_name}} ({.path {x$prefix}})",
      `i` = "{nrow(x$packages)} package{?s} installed."
    )
  )
  invisible(x)
}

#' Solve `packages` against `channels` and link the result into `env_name`'s
#' prefix, creating the environment root and cache directories as needed.
#'
#' Shared by `create_env()` and `install()`: both ultimately call the same
#' Rust bridge, which always folds in whatever is already installed in the
#' prefix so adding packages never drops existing ones. See PLAN.md
#' ("Installation").
#'
#' @keywords internal
#' @noRd
call_rt_install <- function(
  packages,
  env_name,
  channels,
  channel_priority,
  platform
) {
  fs::dir_create(get_install_dir())
  fs::dir_create(get_repodata_cache_dir())
  fs::dir_create(get_pkgs_cache_dir())

  specs <- packages
  if (rlang::is_null(specs)) {
    specs <- character(0L)
  }

  rt_result <- rethrow_error_install(
    rt_install(
      specs = as.character(specs),
      prefix = as.character(get_env_dir(env_name)),
      channels = as.character(channels),
      channel_priority = channel_priority,
      platform = platform,
      repodata_cache_dir = as.character(get_repodata_cache_dir()),
      pkgs_cache_dir = as.character(get_pkgs_cache_dir())
    )
  )
  new_rattlerthis_result(rt_result, env_name = env_name)
}

#' Compute the activation environment variables for `env_name`'s prefix.
#'
#' @keywords internal
#' @noRd
call_rt_activation_env <- function(env_name, platform = NULL) {
  rethrow_error_activate(
    rt_activation_env(
      prefix = as.character(get_env_dir(env_name)),
      platform = platform
    )
  )
}
