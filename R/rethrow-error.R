#' Rethrow a solve/install failure as a classed `rattlerthis` condition
#'
#' @param expr Expression that calls into the compiled Rust bridge.
#' @returns The value of `expr`, or aborts with class
#'   `rattlerthis_error_install`.
#' @keywords internal
#' @noRd
rethrow_error_install <- function(expr) {
  rlang::try_fetch(
    expr,
    error = function(cnd) {
      cli::cli_abort(
        message = c(
          `x` = "Failed to solve or install packages.",
          `i` = conditionMessage(cnd)
        ),
        class = "rattlerthis_error_install",
        parent = cnd
      )
    }
  )
}

#' Rethrow an activation failure as a classed `rattlerthis` condition
#'
#' @inheritParams rethrow_error_install
#' @returns The value of `expr`, or aborts with class
#'   `rattlerthis_error_activate`.
#' @keywords internal
#' @noRd
rethrow_error_activate <- function(expr) {
  rlang::try_fetch(
    expr,
    error = function(cnd) {
      cli::cli_abort(
        message = c(
          `x` = "Failed to activate the environment.",
          `i` = conditionMessage(cnd)
        ),
        class = "rattlerthis_error_activate",
        parent = cnd
      )
    }
  )
}

#' Rethrow a `run()` subprocess failure as a classed `rattlerthis` condition
#'
#' @inheritParams rethrow_error_install
#' @returns The value of `expr`, or aborts with class `rattlerthis_error_run`.
#' @keywords internal
#' @noRd
rethrow_error_run <- function(expr) {
  rlang::try_fetch(
    expr,
    error = function(cnd) {
      cli::cli_abort(
        message = c(
          `x` = "Failed to run the command.",
          `i` = conditionMessage(cnd)
        ),
        class = "rattlerthis_error_run",
        parent = cnd
      )
    }
  )
}
