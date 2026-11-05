#' Start a rattler job, wait for it and return its result
#'
#' Every long rattler call (solve, download, link, activation, cache
#' cleaning) runs as a job on Rust threads, and R polls it here with
#' `Sys.sleep()` (2 ms, doubling up to 50 ms), which R interrupts as usual.
#'
#' The job is started here, by `start`, once the exit handler that stops
#' it is in place, so an interrupt can never leave a job running that
#' nobody waits for. On an interrupt (Ctrl-C), or any other exit before
#' the job is done, the job is cancelled and then waited for until it is
#' idle, before the interrupt goes on (see `rattler_stop_job()`). So no
#' rattler thread still writes into a directory that condathis restores,
#' deletes or cleans next. A link is never interrupted: a cancel during the
#' link waits until it has finished.
#'
#' A spinner shows in an interactive session at every level but
#' `"silent"`.
#'
#' @param start A function without arguments that starts the job, by
#'   calling one of the `rt_*()` entry points, and returns it.
#' @param strategy One of `rattler_verbose_values`. Defaults to `"silent"`.
#' @param label Character string, the text next to the spinner.
#' @param timeout Numeric, the seconds the job may take (`Inf`, the
#'   default, for no limit). A job that runs longer is stopped as on an
#'   interrupt (a link still finishes), and the call aborts with kind
#'   `cancelled`.
#' @param call Environment reported as the caller of errors.
#'
#' @returns The result of the job. A failed job aborts with the classes of
#'   `rattler_error_class()`.
#'
#' @keywords internal
#' @noRd
rattler_await <- function(
  start,
  strategy = "silent",
  label = "rattler",
  timeout = Inf,
  call = rlang::caller_env()
) {
  state <- new.env(parent = emptyenv())
  state$job <- NULL
  state$done <- FALSE
  state$spinner <- NULL
  on.exit(rattler_settle_job(state), add = TRUE)
  if (isTRUE(rattler_shows_spinner(strategy))) {
    state$spinner <- rattler_make_spinner(label)
  }
  # No interrupt between the start of the job and the assignment: the exit
  # handler must see every job that was started.
  suspendInterrupts({
    state$job <- tryCatch(
      start(),
      error = function(e) rattler_abort(e, call = call)
    )
  })
  delay <- 0.002
  started <- proc.time()[["elapsed"]]
  repeat {
    value <- tryCatch(rt_job_poll(state$job), error = function(e) e)
    if (isTRUE(inherits(value, "error"))) {
      state$done <- TRUE
      rattler_abort(value, call = call)
    }
    if (isFALSE(is.null(value))) {
      state$done <- TRUE
      return(value)
    }
    if (isTRUE(proc.time()[["elapsed"]] - started > timeout)) {
      # The exit handler stops the job.
      rattler_abort(
        simpleError(sprintf(
          "[rattlerthis:cancelled] %s ran out of time after %s second%s.",
          label,
          format(timeout),
          if (identical(timeout, 1)) "" else "s"
        )),
        call = call
      )
    }
    if (isFALSE(is.null(state$spinner))) {
      state$spinner$spin()
    }
    Sys.sleep(delay)
    delay <- min(delay * 2, 0.05)
  }
}

#' A cli spinner for a running job, or `NULL`
#'
#' A spinner that cli cannot build (a bad `cli.spinner` option) is left out
#' instead of failing the call.
#'
#' @param label Character string, the text next to the spinner.
#'
#' @returns A cli spinner object, or `NULL`.
#'
#' @keywords internal
#' @noRd
rattler_make_spinner <- function(label) {
  return(tryCatch(
    cli::make_spinner(template = paste0("{spin} ", label)),
    error = function(e) NULL
  ))
}

#' The exit handler of `rattler_await()`
#'
#' Removes the spinner, then stops the job when it is not done (see
#' `rattler_stop_job()`), with interrupts suspended, so no interrupt stops
#' this handler half way. The interrupt that made `rattler_await()` exit
#' goes on afterwards; a further one that came while the job was stopped
#' is dropped (see `rattler_drop_pending_interrupt()`), so it cannot cut
#' condathis's cleanup short.
#'
#' @param state The state environment of `rattler_await()`, with the
#'   elements `job`, `done` and `spinner`.
#'
#' @returns `NULL`, invisibly.
#'
#' @keywords internal
#' @noRd
rattler_settle_job <- function(state) {
  suspendInterrupts({
    if (isFALSE(is.null(state$spinner))) {
      tryCatch(state$spinner$finish(), error = function(e) NULL)
    }
    if (isFALSE(state$done) && isFALSE(is.null(state$job))) {
      rattler_stop_job(state$job)
      rattler_drop_pending_interrupt()
    }
  })
  return(invisible(NULL))
}

#' Drop an interrupt that is pending while interrupts are suspended
#'
#' On Windows, an interrupt that comes while interrupts are suspended is
#' only marked as pending (`Sys.sleep()` does not deliver it, as it does on
#' Linux and macOS), and R signals it as soon as the suspension ends:
#' after `rattler_stop_job()`, that is in the middle of condathis's cleanup
#' of the environment directory (checked on Windows 11 with R 4.6.1). Here
#' interrupts are allowed for a loop long enough for R to check for one
#' (R checks every 1000 steps of a loop), and one that is signaled is
#' caught.
#'
#' @returns `NULL`, invisibly.
#'
#' @keywords internal
#' @noRd
rattler_drop_pending_interrupt <- function() {
  tryCatch(
    allowInterrupts({
      for (i in seq_len(5000L)) {
        NULL
      }
    }),
    interrupt = function(cnd) NULL
  )
  return(invisible(NULL))
}

#' Cancel a job and wait until it is idle
#'
#' Called when `rattler_await()` exits before its job is done, mostly
#' after an interrupt. `rt_job_cancel()` stops the lock, fetch, solve and
#' download phases at once (a job that stops waits at most 10 s for
#' rattler's blocking threads), and lets a link finish; either way the job
#' is polled until it reports done, so its threads have stopped writing.
#' Further interrupts are ignored until then: condathis deletes or
#' restores the environment directory right after, and a link that went on
#' would write into it, or into a new environment that condathis then
#' lists. `suspendInterrupts()` alone does not hold them on Linux and
#' macOS, because `Sys.sleep()` lets an interrupt through there, so each
#' wait catches it. After one second of waiting, a message says why R does
#' not return yet.
#'
#' @param job The job.
#'
#' @returns `TRUE`, invisibly, once the job is done.
#'
#' @keywords internal
#' @noRd
rattler_stop_job <- function(job) {
  stops <- tryCatch(isTRUE(rt_job_cancel(job)), error = function(e) TRUE)
  started <- Sys.time()
  told <- FALSE
  delay <- 0.002
  repeat {
    finished <- tryCatch(
      isFALSE(is.null(rt_job_poll(job))),
      error = function(e) TRUE
    )
    if (isTRUE(finished)) {
      return(invisible(TRUE))
    }
    if (
      isFALSE(told) &&
        isTRUE(as.numeric(difftime(Sys.time(), started, units = "secs")) > 1)
    ) {
      if (isTRUE(stops)) {
        cli::cli_inform(c(`i` = "Waiting for {.field rattler} to stop."))
      } else {
        cli::cli_inform(
          c(
            `i` = "Waiting for {.field rattler} to finish linking, which cannot be interrupted."
          )
        )
      }
      told <- TRUE
    }
    tryCatch(Sys.sleep(delay), interrupt = function(cnd) NULL)
    delay <- min(delay * 2, 0.05)
  }
}

#' Wait until no rattler job runs in this R process
#'
#' A job that an interrupt cancelled is waited for until it is idle (see
#' `rattler_await()`), so normally no job runs when condathis asks. This
#' waits until `rt_live_jobs()` is 0, at most `timeout` seconds, so
#' condathis deletes no directory that a rattler thread still writes to,
#' also for a job that another call left running. After one second of
#' waiting, a message says why. The backend's `backend_quiesce()`.
#'
#' @param timeout Positive number of seconds.
#'
#' @returns `TRUE`, invisibly, when no job runs any more. `FALSE` when
#'   `timeout` ran out, with a warning of class
#'   `c("rattlerthis_quiesce_timeout", "rattlerthis_warning")` and the
#'   field `live_jobs`.
#'
#' @keywords internal
#' @noRd
rattler_wait_idle <- function(timeout = 30) {
  started <- Sys.time()
  told <- FALSE
  delay <- 0.002
  repeat {
    live <- rt_live_jobs()
    if (identical(as.integer(live), 0L)) {
      return(invisible(TRUE))
    }
    waited <- as.numeric(difftime(Sys.time(), started, units = "secs"))
    if (isTRUE(waited >= timeout)) {
      cli::cli_warn(
        message = c(
          `!` = "{.field rattler} still runs {live} job{?s} in this R process after {timeout} second{?s}.",
          `i` = "Files in the {.field rattler} root may still be written."
        ),
        class = c("rattlerthis_quiesce_timeout", "rattlerthis_warning"),
        live_jobs = live
      )
      return(FALSE)
    }
    if (isFALSE(told) && isTRUE(waited > 1)) {
      cli::cli_inform(
        c(`i` = "Waiting for {.field rattler} to finish its work.")
      )
      told <- TRUE
    }
    Sys.sleep(min(delay, max(timeout - waited, 0.001)))
    delay <- min(delay * 2, 0.05)
  }
}

#' The error kinds of rattlerthis
#'
#' Every Rust error reaches R as `"[rattlerthis:<kind>] <text>"`. The kind
#' `pip` is raised in R, by a failed pip step of a create (see
#' `rattler_abort_pip()`).
#'
#' @keywords internal
#' @noRd
rattler_error_kinds <- c(
  "invalid_platform",
  "invalid_spec",
  "invalid_channel",
  "invalid_channel_priority",
  "virtual_packages",
  "fetch",
  "solve",
  "link",
  "activation",
  "io",
  "env_file",
  "unsupported",
  "hash_mismatch",
  "wheel_unsupported",
  "cancelled",
  "internal",
  "pip"
)

#' The classes of a Rust error
#'
#' `rattlerthis_rattler_<kind>`, then `rattlerthis_rattler_error` and
#' `rattlerthis_error`. Kind `unsupported` (wheels, source archives or VCS
#' URLs among the Conda packages of a lock file) also gets
#' `condathis_backend_unsupported`, which condathis keeps when it re-raises
#' the error (see *Errors* in `?condathis::register_backend`).
#'
#' @param kind Character string, one of `rattler_error_kinds`, or `NA`.
#'
#' @returns Character vector.
#'
#' @keywords internal
#' @noRd
rattler_error_class <- function(kind) {
  kind_class <- if (isTRUE(kind %in% rattler_error_kinds)) {
    paste0("rattlerthis_rattler_", kind)
  }
  unsupported_class <- if (identical(kind, "unsupported")) {
    "condathis_backend_unsupported"
  }
  return(c(
    kind_class,
    unsupported_class,
    "rattlerthis_rattler_error",
    "rattlerthis_error"
  ))
}

#' Abort with the classes of a Rust error
#'
#' Strips the `"[rattlerthis:<kind>] "` prefix from the message and aborts
#' with `rattler_error_class()` and the field `kind`. The text is passed as
#' is to `rlang::abort()`, so braces in it are never read as cli markup. An
#' error without the prefix (a wrong argument type in R) keeps its
#' message, gets the class `rattlerthis_rattler_error` and is the parent.
#'
#' @param cnd The error condition from an `rt_*()` call.
#' @param call Environment reported as the caller.
#'
#' @returns Does not return.
#'
#' @keywords internal
#' @noRd
rattler_abort <- function(cnd, call = rlang::caller_env()) {
  message <- conditionMessage(cnd)
  tag_pattern <- "^[[:space:]]*\\[rattlerthis:([a-z_]+)\\][[:space:]]?"
  if (isFALSE(grepl(tag_pattern, message))) {
    rlang::abort(
      message = message,
      class = rattler_error_class(NA_character_),
      kind = NA_character_,
      parent = cnd,
      call = call
    )
  }
  first_line <- strsplit(message, "\n", fixed = TRUE)[[1L]][[1L]]
  kind <- sub(paste0(tag_pattern, ".*$"), "\\1", first_line)
  text <- sub(tag_pattern, "", message)
  rlang::abort(
    message = text,
    class = rattler_error_class(kind),
    kind = kind,
    call = call
  )
}

#' Call a synchronous Rust entry point, with its errors classed
#'
#' @param expr The call, such as `rt_read_env_file(path, NULL)`.
#' @param call Environment reported as the caller.
#'
#' @returns The value of `expr`.
#'
#' @keywords internal
#' @noRd
rattler_call <- function(expr, call = rlang::caller_env()) {
  return(tryCatch(
    expr,
    error = function(e) rattler_abort(e, call = call)
  ))
}
