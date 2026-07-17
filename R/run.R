#' Run a command inside a Conda environment
#'
#' Executes a command in a Conda environment managed by `rattlerthis`. The
#' activation environment variables are computed in-process via
#' `rattler_shell::Activator`; the target command itself is then spawned
#' with `processx::run()`. See `PLAN.md` ("Process execution split").
#'
#' @param cmd Character string with the command to execute.
#' @param ... Additional unnamed command arguments passed to `cmd`.
#' @param env_name Character string with the target environment name.
#'   Defaults to `"rattlerthis-env"`. The environment must already exist
#'   (create it first with `create_env()`).
#' @param verbose Character string controlling console output. Supported
#'   values are `"output"`, `"silent"`, `"cmd"`, `"spinner"`, and `"full"`.
#'   Defaults to `"output"`.
#' @param error Character string that controls error behavior. Supported
#'   values are `"cancel"` and `"continue"`. Defaults to `"cancel"`.
#' @param stdout Standard output target. Defaults to `"|"` (capture stdout
#'   in the returned object). Provide a file path to redirect stdout to a
#'   file.
#' @param stderr Standard error target. Defaults to `"|"` (capture stderr in
#'   the returned object). Provide a file path to redirect stderr to a
#'   file.
#' @param stdin Standard input source. Defaults to `NULL` (no stdin
#'   stream). Provide a file path to use file contents as stdin.
#'
#' @returns A process result list (from `processx::run()`) with command
#'   output, error output, exit status, and timeout information.
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
run <- function(
  cmd,
  ...,
  env_name = "rattlerthis-env",
  verbose = c("output", "silent", "cmd", "spinner", "full"),
  error = c("cancel", "continue"),
  stdout = "|",
  stderr = "|",
  stdin = NULL
) {
  rlang::check_dots_unnamed()
  rlang::check_required(cmd)
  error <- rlang::arg_match(error)
  verbose_list <- parse_strategy_verbose(verbose)

  resolved <- resolve_run_command(cmd = cmd, env_name = env_name)

  args_vector <- c(...)
  if (rlang::is_null(args_vector)) {
    args_vector <- character(0L)
  }

  error_var <- identical(error, "cancel")

  withr::local_envvar(.new = resolved$env)

  px_res <- rethrow_error_run(
    expr = {
      processx::run(
        command = resolved$command,
        args = args_vector,
        spinner = identical(verbose_list$strategy, "spinner"),
        echo_cmd = identical(verbose_list$strategy, "cmd"),
        echo = verbose_list$strategy %in% c("output", "full"),
        stdout = stdout,
        stderr = stderr,
        stdin = stdin,
        error_on_status = error_var
      )
    }
  )

  invisible(px_res)
}
