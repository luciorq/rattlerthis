#' Resolve the executable path and activation environment for a command
#'
#' Validates that `env_name` exists, computes the activation environment
#' variables via the Rust bridge, and resolves `cmd` to the environment's
#' `bin/` directory when present (falling back to the bare command name so
#' `processx`/`PATH` lookup can still find it otherwise). Does not spawn
#' anything. Shared by `run()` and the `condathis` backend adapter's
#' `backend_resolve_run()` — see PLAN.md ("`backend_resolve_run` needs new
#' shared internal plumbing").
#'
#' @param cmd Character string with the command to resolve.
#' @param env_name Character string with the target environment name.
#' @returns A list with `command` (character string) and `env` (named
#'   character vector of activation environment variables).
#' @keywords internal
#' @noRd
resolve_run_command <- function(cmd, env_name) {
  if (isFALSE(env_exists(env_name))) {
    cli::cli_abort(
      message = c(
        `x` = "Environment {.field {env_name}} does not exist.",
        `!` = "Create it first with {.code create_env(env_name = \"{env_name}\")}."
      ),
      class = "rattlerthis_run_missing_env"
    )
  }

  env_dir <- get_env_dir(env_name)
  activation_env <- call_rt_activation_env(env_name = env_name)

  cmd_path <- fs::path(env_dir, "bin", cmd)
  if (isFALSE(fs::file_exists(cmd_path))) {
    cmd_path <- cmd
  }

  list(
    command = as.character(cmd_path),
    env = activation_env
  )
}
