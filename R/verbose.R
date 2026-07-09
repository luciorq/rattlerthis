#' Parse the `verbose` argument shared by `rattlerthis`'s public functions
#'
#' Reuses `condathis`'s `verbose` vocabulary for anyone migrating from it.
#'
#' @param verbose Character string. One of `"output"`, `"silent"`, `"cmd"`,
#'   `"spinner"`, or `"full"`. Logical values are accepted for backward
#'   compatibility: `TRUE` maps to `"output"` and `FALSE` maps to `"silent"`.
#'
#' @returns A list with the parsed `strategy` and a `quiet` logical flag.
#'
#' @keywords internal
#' @noRd
parse_strategy_verbose <- function(
  verbose = c("output", "silent", "cmd", "spinner", "full")
) {
  if (rlang::is_logical(verbose) && identical(length(verbose), 1L)) {
    verbose <- if (isTRUE(verbose)) "output" else "silent"
  }
  verbose <- rlang::arg_match(
    verbose,
    values = c("output", "silent", "cmd", "spinner", "full")
  )
  list(
    strategy = verbose,
    quiet = verbose %in% c("silent", "cmd")
  )
}
