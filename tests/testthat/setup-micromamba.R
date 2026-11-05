# The micromamba binary of the parity files (the files that run the same
# condathis calls with `method = "micromamba"` and `method = "rattler"`).
#
# When the runner gives one (`CONDATHIS_MICROMAMBA_PATH` set when the run
# starts), it is recorded and the variable is unset for the run. Otherwise
# micromamba is installed once per run with `condathis::install_micromamba()`
# into a session-scoped sandbox of its own, which is deleted at the end of
# the run. Either way no test downloads micromamba, and only
# `local_parity_micromamba()` makes condathis use it. A failed install is
# recorded, and fails every test that calls `local_parity_micromamba()`
# (there is no skip).

local({
  runner_path <- remember_runner_micromamba()
  withr::local_envvar(
    c(CONDATHIS_MICROMAMBA_PATH = NA),
    .local_envir = testthat::teardown_env()
  )
  if (isTRUE(nzchar(runner_path))) {
    if (isTRUE(file.exists(runner_path))) {
      rt_test_state$micromamba <- normalizePath(
        runner_path,
        winslash = "/",
        mustWork = TRUE
      )
    } else {
      rt_test_state$micromamba_error <- paste0(
        "CONDATHIS_MICROMAMBA_PATH names a file that does not exist: ",
        runner_path
      )
    }
    return(invisible(NULL))
  }
  mm_root <- tempfile(pattern = "rt-micromamba-", tmpdir = tempdir())
  dir.create(mm_root, recursive = TRUE)
  withr::defer(
    unlink(mm_root, recursive = TRUE, force = TRUE),
    envir = testthat::teardown_env()
  )
  dirs <- file.path(
    mm_root,
    c("home", "data", "cache", "config", "state")
  )
  for (dir in dirs) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  }
  installed <- tryCatch(
    withr::with_envvar(
      c(
        HOME = dirs[[1L]],
        USERPROFILE = dirs[[1L]],
        LOCALAPPDATA = dirs[[2L]],
        APPDATA = dirs[[2L]],
        R_USER_DATA_DIR = dirs[[2L]],
        XDG_DATA_HOME = dirs[[2L]],
        R_USER_CACHE_DIR = dirs[[3L]],
        XDG_CACHE_HOME = dirs[[3L]],
        R_USER_CONFIG_DIR = dirs[[4L]],
        XDG_CONFIG_HOME = dirs[[4L]],
        XDG_STATE_HOME = dirs[[5L]],
        CONDATHIS_MICROMAMBA_PATH = NA
      ),
      withr::with_options(
        list(condathis.micromamba_path = NULL),
        {
          condathis::install_micromamba(verbose = "silent")
          as.character(condathis::micromamba_bin_path())
        }
      )
    ),
    error = function(e) e
  )
  if (isTRUE(inherits(installed, "error"))) {
    rt_test_state$micromamba_error <- paste0(
      "condathis::install_micromamba() failed: ",
      conditionMessage(installed)
    )
  } else if (isFALSE(file.exists(installed))) {
    rt_test_state$micromamba_error <- paste0(
      "condathis::install_micromamba() left no binary at ",
      installed
    )
  } else {
    rt_test_state$micromamba <- normalizePath(
      installed,
      winslash = "/",
      mustWork = TRUE
    )
  }
  return(invisible(NULL))
})
