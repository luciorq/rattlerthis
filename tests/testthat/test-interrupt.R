# Interrupts (Ctrl-C) of rattler's work, delivered for real to another R
# session (callr) that runs condathis calls with `method = "rattler"`.
# rattler works in the R process, so on an interrupt it cancels its job,
# waits until the job's threads are idle, and lets the interrupt go on to
# condathis, which deletes a new environment directory or moves the old
# environment back (spec 3.13). test-hooks.R and
# test-condathis-conformance.R signal the interrupt from a mock; here it
# comes from outside, as from a user: SIGINT on Linux and macOS, CTRL+BREAK
# on Windows (see `interrupt_session()` in helper-concurrency.R).
#
# Downloads are caught with a local HTTP channel that holds them until the
# test releases them (`local_http_channel()`), so the interrupt reaches the
# create or install while it downloads (phase `prefetch`), before anything
# in the environment changed. That test uses a sandbox of its own, so no
# package is in rattler's cache yet. Environment names start with
# "rt-int-".

# Interrupts `session` and returns the outcome of its call, which must
# return within `timeout` seconds.
interrupt_and_wait <- function(session, timeout = 30) {
  interrupt_session(session)
  return(session_outcome(session, timeout = timeout))
}

# What an environment holds: its package names, its history (bytes) and
# whether the test's file `kept.txt` is still there.
env_snapshot <- function(env_name) {
  env_dir <- condathis::get_env_dir(env_name, method = "rattler")
  history <- file.path(env_dir, "conda-meta", "history")
  return(list(
    exists = condathis::env_exists(env_name, method = "rattler"),
    packages = condathis::list_packages(env_name, method = "rattler")$name,
    history = readBin(history, "raw", file.size(history)),
    kept = file.exists(file.path(env_dir, "kept.txt"))
  ))
}

# The entries of condathis's trash directory of the rattler backend, which
# must be empty after every operation.
rattler_trash_entries <- function() {
  trash_dir <- file.path(
    condathis::backend_root_dir("rattler"),
    "envs",
    "#trash"
  )
  return(list.files(trash_dir, all.files = TRUE, no.. = TRUE))
}

test_that("an interrupt stops a rattler job within a second", {
  session <- local_r_session()
  marker <- file.path(withr::local_tempdir(pattern = "rt-int-"), "started")
  session$call(
    function(marker) {
      ns <- asNamespace("rattlerthis")
      writeLines("started", marker)
      value <- tryCatch(
        ns$rattler_await(function() ns$rt_test_job_sleep(30)),
        interrupt = function(cnd) "interrupted"
      )
      return(list(value = value, live_jobs = ns$rt_live_jobs()))
    },
    args = list(marker = marker)
  )
  wait_until(function() file.exists(marker), what = "the job to start")
  Sys.sleep(0.3)
  interrupted_at <- Sys.time()
  outcome <- interrupt_and_wait(session)
  expect_condathis_call(outcome, "interrupted")
  expect_lt(seconds_since(interrupted_at), 1)
  # The session goes on working: a new job runs to its end.
  expect_true(session$run(function() {
    ns <- asNamespace("rattlerthis")
    return(ns$rattler_await(function() ns$rt_test_job_sleep(0.05)))
  }))
})

test_that("an interrupted download leaves no new environment and the old one as it was", {
  local_condathis_sandbox()
  old_name <- "rt-int-old"
  new_name <- "rt-int-new"
  condathis::create_env(
    "baz",
    env_name = old_name,
    channels = channel_url("chC"),
    method = "rattler",
    verbose = "silent"
  )
  writeLines(
    "kept",
    file.path(condathis::get_env_dir(old_name, method = "rattler"), "kept.txt")
  )
  before <- env_snapshot(old_name)
  expect_identical(before$packages, "baz")

  server <- local_http_channel("chA")
  http_chA <- server$url("chA")
  session <- local_r_session()
  phase_file <- file.path(withr::local_tempdir(pattern = "rt-int-"), "phases")
  trace_job_phases(session, phase_file)

  # Runs `fn` in the session until its package download has started,
  # interrupts it, and checks that the interrupt came during the download
  # and that the job never linked.
  interrupt_download <- function(fn, args, downloads) {
    unlink(phase_file)
    start_condathis_call(session, fn, args)
    wait_for_download(server, downloads)
    outcome <- interrupt_and_wait(session)
    expect_condathis_call(outcome, "interrupted")
    phases <- read_job_phases(phase_file)
    expect_true("prefetch" %in% phases, label = paste(phases, collapse = " "))
    expect_false("link" %in% phases, label = paste(phases, collapse = " "))
    return(invisible(outcome))
  }

  # A new environment: condathis deletes its directory.
  interrupt_download(
    "create_env",
    list(
      "foo",
      env_name = new_name,
      channels = http_chA,
      method = "rattler",
      verbose = "silent"
    ),
    downloads = 1L
  )
  expect_false(condathis::env_exists(new_name, method = "rattler"))
  expect_false(dir.exists(condathis::get_env_dir(new_name, method = "rattler")))
  expect_identical(rattler_trash_entries(), character(0L))

  # An install: the environment keeps its packages and history.
  interrupt_download(
    "install_packages",
    list(
      "foo",
      env_name = old_name,
      channels = http_chA,
      method = "rattler",
      verbose = "silent"
    ),
    downloads = 2L
  )
  expect_identical(env_snapshot(old_name), before)
  expect_identical(rattler_trash_entries(), character(0L))

  # A replacement (overwrite = TRUE): condathis moves the old environment
  # back.
  interrupt_download(
    "create_env",
    list(
      "foo",
      env_name = old_name,
      channels = http_chA,
      method = "rattler",
      overwrite = TRUE,
      verbose = "silent"
    ),
    downloads = 3L
  )
  expect_identical(env_snapshot(old_name), before)
  expect_identical(rattler_trash_entries(), character(0L))

  # Not interrupted, the same install completes once the download goes on.
  http_channel_release(server)
  start_condathis_call(
    session,
    "install_packages",
    list(
      "foo",
      env_name = old_name,
      channels = http_chA,
      method = "rattler",
      verbose = "silent"
    )
  )
  expect_condathis_call(session_outcome(session, timeout = 60), "done")
  expect_identical(
    condathis::list_packages(old_name, method = "rattler")$name,
    c("baz", "foo")
  )
  expect_identical(http_channel_downloads(server), 4L)
})

test_that("an interrupted activation stops its shell", {
  env_name <- "rt-int-activate"
  defer_remove_env(env_name)
  condathis::create_env(
    "polyglot",
    env_name = env_name,
    channels = condathis_polyglot_channel(),
    method = "rattler",
    verbose = "silent"
  )
  env_dir <- condathis::get_env_dir(env_name, method = "rattler")
  activate_dir <- file.path(env_dir, "etc", "conda", "activate.d")
  dir.create(activate_dir, recursive = TRUE, showWarnings = FALSE)
  marker_dir <- withr::local_tempdir(pattern = "rt-int-")
  marker <- file.path(marker_dir, "activating")
  # A script that writes the marker, then waits two minutes in a program
  # the activation shell starts.
  if (isTRUE(is_windows())) {
    script <- file.path(activate_dir, "rt-int-hang.bat")
    writeLines(
      c(
        paste0(
          "@echo started> \"",
          normalizePath(marker_dir, winslash = "\\"),
          "\\activating\""
        ),
        "@\"%SystemRoot%\\System32\\ping.exe\" -n 120 127.0.0.1 > nul"
      ),
      script,
      sep = "\r\n"
    )
  } else {
    script <- file.path(activate_dir, "rt-int-hang.sh")
    writeLines(c(paste0("echo started > '", marker, "'"), "sleep 120"), script)
  }

  session <- local_r_session()
  session_handle <- session$as_ps_handle()
  before_pids <- vapply(
    process_descendants(session_handle),
    ps::ps_pid,
    integer(1L)
  )
  start_condathis_call(
    session,
    "run",
    list(
      "polyglot",
      env_name = env_name,
      method = "rattler",
      verbose = "silent"
    )
  )
  wait_until(function() file.exists(marker), what = "the activation script")
  Sys.sleep(0.3)
  activation <- process_descendants(session_handle)
  activation <- activation[
    !vapply(activation, ps::ps_pid, integer(1L)) %in% before_pids
  ]
  # The shell and the program it waits for.
  expect_gte(length(activation), 1L)
  expect_true(all(processes_running(activation)))

  outcome <- interrupt_and_wait(session)
  expect_condathis_call(outcome, "interrupted")
  wait_until(
    function() isFALSE(any(processes_running(activation))),
    timeout = 10,
    what = "the activation's processes to end"
  )
  expect_false(any(processes_running(activation)))

  # Without the script, the environment runs its command.
  unlink(script)
  res <- session$run(
    function(env_name) {
      return(condathis::parse_output(condathis::run(
        "polyglot",
        env_name = env_name,
        method = "rattler",
        verbose = "silent"
      )))
    },
    args = list(env_name = env_name)
  )
  expect_identical(res[[1L]], polyglot_first_line())
})

test_that("a second interrupt while rattler waits for a link is ignored", {
  # A job that is linking cannot be cancelled: rt_job_cancel() answers
  # FALSE, here from a mock for a sleeping job, so the job runs to its end
  # (R-15). The first interrupt makes rattler wait for it; a second one
  # during that wait must neither end the wait (the job would go on writing
  # into a directory that condathis's cleanup deletes) nor, held by R on
  # Windows, fire inside that cleanup. The cleanup is stood for by an exit
  # handler that runs R code and then writes a file.
  session <- local_r_session()
  marker_dir <- withr::local_tempdir(pattern = "rt-int-")
  started_file <- file.path(marker_dir, "started")
  cleaned_file <- file.path(marker_dir, "cleaned")
  session$call(
    function(started_file, cleaned_file) {
      testthat::local_mocked_bindings(
        rt_job_cancel = function(job) FALSE,
        .package = "rattlerthis"
      )
      ns <- asNamespace("rattlerthis")
      create <- function() {
        on.exit({
          for (i in seq_len(2e6)) {
            NULL
          }
          writeLines("cleaned", cleaned_file)
        })
        writeLines("started", started_file)
        return(ns$rattler_await(function() ns$rt_test_job_sleep(2)))
      }
      started <- Sys.time()
      value <- suppressMessages(tryCatch(
        create(),
        interrupt = function(cnd) "interrupted"
      ))
      return(list(
        value = value,
        seconds = as.numeric(difftime(Sys.time(), started, units = "secs")),
        live_jobs = ns$rt_live_jobs(),
        cleaned = file.exists(cleaned_file)
      ))
    },
    args = list(started_file = started_file, cleaned_file = cleaned_file)
  )
  wait_until(function() file.exists(started_file), what = "the job to start")
  Sys.sleep(0.3)
  interrupt_session(session)
  Sys.sleep(0.6)
  interrupt_session(session)
  outcome <- session_outcome(session, timeout = 30)
  expect_identical(outcome$state, "ready")
  expect_null(outcome$error)
  expect_identical(outcome$result$value, "interrupted")
  # The job ran to its end (2 s) before the call returned.
  expect_gte(outcome$result$seconds, 1.8)
  expect_identical(outcome$result$live_jobs, 0L)
  expect_true(outcome$result$cleaned)
  # No interrupt is left over for the next call.
  expect_identical(
    session$run(function() {
      for (i in seq_len(2e6)) {
        NULL
      }
      return("later")
    }),
    "later"
  )
})
