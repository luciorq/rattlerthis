# Two R sessions that change one rattler environment at the same time.
#
# condathis locks an environment (by name, outside every root) for each
# create_env(), install_packages() and remove_env(), for every backend: a
# second session waits for the first, says so after 2 s, and never reaches
# its backend function meanwhile (R-25, R-32: the tests at the end, as
# condathis's own tests of the lock for micromamba).
#
# Below that, rattler locks the environment for a whole install
# (`conda-meta/conda-meta.lock`, as libmamba locks `conda-meta`) (P-A7):
# the first test calls the install hook directly in both sessions, as a
# program that bypasses condathis's lock would, and the second install
# waits (its job is in phase `lock`) until the first has linked, then
# solves against what the first installed. The first install is held in
# its download by a local HTTP channel (`local_http_channel()`), so the
# test decides when it may finish. A sandbox of its own: no package is in
# rattler's cache yet.
#
# Environment names start with "rt-lock-".

# The files that the package records of a prefix list and that are
# missing from it.
missing_record_files <- function(prefix) {
  record_files <- list.files(
    file.path(prefix, "conda-meta"),
    pattern = "[.]json$",
    full.names = TRUE
  )
  listed <- as.character(unlist(lapply(record_files, function(record_file) {
    record <- jsonlite::fromJSON(record_file, simplifyVector = FALSE)
    return(as.character(unlist(record[["files"]])))
  })))
  return(listed[!file.exists(file.path(prefix, listed))])
}

# Runs the hook `hook` of the rattler backend object with the list `args`
# (by name, as condathis calls it) in `session`, and returns at once, as
# `start_condathis_call()` does for condathis's functions: the value of
# the call is the same list, collected with `session_outcome()`.
start_rattler_hook_call <- function(session, hook, args) {
  session$call(
    function(hook, args) {
      error_class <- NULL
      error_message <- NULL
      rattler_ns <- asNamespace("rattlerthis")
      backend <- rattler_ns$new_backend_rattler()
      value <- tryCatch(
        {
          do.call(backend[[hook]], c(list(backend), args))
          "done"
        },
        interrupt = function(cnd) "interrupted",
        error = function(cnd) {
          error_class <<- class(cnd)
          error_message <<- conditionMessage(cnd)
          return("error")
        }
      )
      return(list(
        value = value,
        error_class = error_class,
        error_message = error_message,
        error_kind = NULL,
        live_jobs = rattler_ns$rt_live_jobs(),
        warnings = character(0L)
      ))
    },
    args = list(hook = hook, args = args)
  )
  return(invisible(session))
}

test_that("two installs that bypass condathis's lock take turns at rattler's prefix lock", {
  local_condathis_sandbox()
  env_name <- "rt-lock-env"
  condathis::create_env(
    "baz",
    env_name = env_name,
    channels = channel_url("chC"),
    method = "rattler",
    verbose = "silent"
  )
  env_dir <- condathis::get_env_dir(env_name, method = "rattler")
  server <- local_http_channel("chA")
  first <- local_r_session()
  second <- local_r_session()
  phase_file <- file.path(withr::local_tempdir(pattern = "rt-lock-"), "phases")
  trace_job_phases(second, phase_file)

  # The first install holds the environment's lock while it downloads.
  start_rattler_hook_call(
    first,
    "backend_install",
    list(
      packages = "foo",
      env_name = env_name,
      channels = server$url("chA"),
      channel_priority = "strict",
      verbose = "silent"
    )
  )
  wait_for_download(server, 1L)
  # The second install, from a local channel, waits for the lock.
  start_rattler_hook_call(
    second,
    "backend_install",
    list(
      packages = "devtool",
      env_name = env_name,
      channels = channel_url("chD"),
      channel_priority = "strict",
      verbose = "silent"
    )
  )
  wait_until(
    function() "lock" %in% read_job_phases(phase_file),
    what = "the second install to wait for the lock"
  )
  Sys.sleep(1)
  expect_identical(utils::tail(read_job_phases(phase_file), 1L), "lock")
  expect_identical(second$poll_process(0L), "timeout")
  expect_identical(env_records(env_dir)$name, "baz")

  # Once the download goes on, both installs finish, one after the other.
  http_channel_release(server)
  expect_condathis_call(session_outcome(first, timeout = 60), "done")
  expect_condathis_call(session_outcome(second, timeout = 60), "done")

  # Each package once, every file the records list present, no lock file
  # left, and the history in the order of the installs.
  expect_identical(
    condathis::list_packages(env_name, method = "rattler")$name,
    c("baz", "devtool", "foo")
  )
  expect_identical(env_records(env_dir)$name, c("baz", "devtool", "foo"))
  expect_identical(missing_record_files(env_dir), character(0L))
  expect_false(file.exists(file.path(env_dir, "conda-meta", "conda-meta.lock")))
  history <- read_history(env_dir)
  expect_identical(
    grep("^[+-]", history$lines, value = TRUE),
    c(
      paste0("+", channel_url("chC"), "/noarch::baz-1.0-0"),
      paste0("+", server$url("chA"), "/noarch::foo-1.0-0"),
      paste0("+", channel_url("chD"), "/noarch::devtool-1.0-0")
    )
  )
  expect_identical(
    grep("^# update specs:", history$lines, value = TRUE),
    c(
      "# update specs: [\"baz\"]",
      "# update specs: [\"foo\"]",
      "# update specs: [\"devtool\"]"
    )
  )
  expect_identical(http_channel_downloads(server), 1L)
})

# Two sessions create an environment from one HTTP channel at the same
# time, and the second one downloads the channel's noarch metadata again
# while the first one reads it from rattler's repodata cache, which every R
# session of the root shares. The cached copy is made an hour old first, so
# the second session does not reuse it (libmamba's lifetime of metadata
# without `Cache-Control`): with a server without validators (no ETag), it
# downloads the metadata again; with `update = TRUE`, the channel's noarch
# metadata changes after the first session read it (a channel update, so
# the ETag changes too). The first session's download
# of the platform's metadata is held, so it is still reading the noarch
# metadata when the second session replaces the cached copy. On Windows
# the cached copy cannot be replaced while the first session has it open
# (rattler maps the file into memory); rattler then reads the cached copy
# or downloads again. Neither session may fail.
expect_metadata_race_succeeds <- function(validators, update) {
  platform <- r_build_platform()
  server <- local_http_channel(
    "chA",
    validators = validators,
    hold_pattern = paste0("/", platform, "/repodata[.]json$")
  )
  noarch_downloads <- function() {
    return(sum(
      http_channel_log(server) == "GET /chA/noarch/repodata.json 200"
    ))
  }
  prefix <- if (isTRUE(validators)) "rt-lock-etag-" else "rt-lock-meta-"
  env_names <- paste0(prefix, c("1", "2"))
  first <- local_r_session()
  second <- local_r_session()
  start_condathis_call(
    first,
    "create_env",
    list(
      "foo",
      env_name = env_names[[1L]],
      channels = server$url("chA"),
      method = "rattler",
      verbose = "silent"
    )
  )
  wait_for_download(server, 1L)
  wait_until(
    function() noarch_downloads() >= 1L,
    what = "the first session's download of the noarch metadata"
  )
  Sys.sleep(0.5)
  age_rattler_repodata_cache()
  if (isTRUE(update)) {
    cat(
      "\n",
      file = file.path(server$root, "chA", "noarch", "repodata.json"),
      append = TRUE
    )
  }
  start_condathis_call(
    second,
    "create_env",
    list(
      "foo",
      env_name = env_names[[2L]],
      channels = server$url("chA"),
      method = "rattler",
      verbose = "silent"
    )
  )
  wait_until(
    function() noarch_downloads() >= 2L,
    what = "the second session's download of the noarch metadata"
  )
  Sys.sleep(1)
  http_channel_release(server)
  first_outcome <- session_outcome(first, timeout = 90)
  second_outcome <- session_outcome(second, timeout = 90)
  expect_condathis_call(first_outcome, "done")
  expect_condathis_call(second_outcome, "done")
  for (env_name in env_names) {
    expect_true(condathis::env_exists(env_name, method = "rattler"))
    expect_identical(
      env_records(condathis::get_env_dir(env_name, method = "rattler"))$name,
      "foo"
    )
  }
  return(invisible(NULL))
}

test_that("two sessions that download one channel's metadata at once both succeed", {
  local_condathis_sandbox()
  expect_metadata_race_succeeds(validators = FALSE, update = FALSE)
})

test_that("two sessions that read a channel that was just updated both succeed", {
  local_condathis_sandbox()
  expect_metadata_race_succeeds(validators = TRUE, update = TRUE)
})

# --- condathis's environment lock -------------------------------------------

# The marker files of a call that `lock_race_call()` started: `in` when it
# reached condathis's backend function `hook` (it holds the environment's
# lock then), `waiting` when it said that it waits for the lock, and `go`,
# which the test creates to let a held call go on.
lock_race_marker <- function(sync_dir, label, what) {
  return(file.path(sync_dir, paste0(label, ".", what)))
}

# Runs condathis's exported function `fn` with the list `args` in
# `session`, and returns at once (see `lock_race_outcome()`). When the call
# reaches condathis's backend function `hook` (the generic, which then
# calls the rattler hook), it creates the marker `in`, and with
# `hold = TRUE` it waits there until the marker `go` exists, holding the
# environment's lock. It creates `waiting` when condathis says that it
# waits for the lock. The value of the call is a list: `value` ("done",
# "error" or "interrupted"), `error_class`, `error_message` and `waited`
# (whether it said that it waits).
lock_race_call <- function(session, fn, args, hook, sync_dir, label, hold) {
  session$call(
    function(fn, args, hook, in_file, go_file, waiting_file, hold) {
      ns <- asNamespace("condathis")
      tracer <- bquote({
        file.create(.(in_file))
        if (isTRUE(.(hold))) {
          while (isFALSE(file.exists(.(go_file)))) {
            Sys.sleep(0.05)
          }
        }
      })
      suppressMessages(trace(hook, tracer = tracer, where = ns, print = FALSE))
      on.exit(suppressMessages(untrace(hook, where = ns)), add = TRUE)
      error_class <- NULL
      error_message <- NULL
      waited <- FALSE
      value <- withCallingHandlers(
        tryCatch(
          {
            do.call(getExportedValue("condathis", fn), args)
            "done"
          },
          interrupt = function(cnd) "interrupted",
          error = function(cnd) {
            error_class <<- class(cnd)
            error_message <<- conditionMessage(cnd)
            return("error")
          }
        ),
        message = function(cnd) {
          if (inherits(cnd, "condathis_env_lock_waiting")) {
            waited <<- TRUE
            file.create(waiting_file)
          }
          invokeRestart("muffleMessage")
        }
      )
      return(list(
        value = value,
        error_class = error_class,
        error_message = error_message,
        waited = waited
      ))
    },
    args = list(
      fn = fn,
      args = args,
      hook = hook,
      in_file = lock_race_marker(sync_dir, label, "in"),
      go_file = lock_race_marker(sync_dir, label, "go"),
      waiting_file = lock_race_marker(sync_dir, label, "waiting"),
      hold = hold
    )
  )
  return(invisible(session))
}

# The outcome of the call that `lock_race_call()` started: its value, or a
# list with the `value` "timeout" or "session error".
lock_race_outcome <- function(session, timeout = 120) {
  outcome <- session_outcome(session, timeout = timeout)
  if (isFALSE(identical(outcome$state, "ready"))) {
    return(list(value = "timeout"))
  }
  if (isFALSE(is.null(outcome$error))) {
    return(list(
      value = "session error",
      error_message = conditionMessage(outcome$error)
    ))
  }
  return(outcome$result)
}

# Starts `first` in session `a` and holds it inside its backend function,
# starts `second` in session `b`, checks that `b` waits for the lock
# without reaching its backend function, and lets `a` go on. Each call is
# a list with `fn`, `args` and `hook`. Returns both outcomes, how long `b`
# took to say that it waits, and whether `b` reached its backend function.
race_rattler_env_lock <- function(a, b, sync_dir, label, first, second) {
  label_a <- paste0(label, "-a")
  label_b <- paste0(label, "-b")
  lock_race_call(
    a,
    first$fn,
    first$args,
    hook = first$hook,
    sync_dir = sync_dir,
    label = label_a,
    hold = TRUE
  )
  wait_until(
    function() file.exists(lock_race_marker(sync_dir, label_a, "in")),
    timeout = 120,
    what = paste("the first call of", label)
  )
  b_started <- Sys.time()
  lock_race_call(
    b,
    second$fn,
    second$args,
    hook = second$hook,
    sync_dir = sync_dir,
    label = label_b,
    hold = FALSE
  )
  wait_until(
    function() file.exists(lock_race_marker(sync_dir, label_b, "waiting")),
    timeout = 60,
    what = paste("the second call of", label, "to wait")
  )
  waited <- seconds_since(b_started)
  # The second call has not reached its backend function, and still runs.
  expect_false(
    file.exists(lock_race_marker(sync_dir, label_b, "in")),
    label = label
  )
  expect_identical(b$poll_process(0L), "timeout", label = label)
  file.create(lock_race_marker(sync_dir, label_a, "go"))
  return(list(
    a = lock_race_outcome(a),
    b = lock_race_outcome(b),
    waited = waited,
    b_reached_backend = file.exists(lock_race_marker(sync_dir, label_b, "in"))
  ))
}

test_that("two sessions never change one rattler environment at once (R-25, R-32)", {
  # The cases of condathis's own test for micromamba: a remove while an
  # install runs (R-25), an install while a remove runs, and an overwrite
  # against an install, both ways (R-32). The second call waits for the
  # first, then runs against what the first left.
  env_name <- "rt-lock-race"
  defer_remove_env(env_name)
  channels <- c(channel_url("chA"), channel_url("chC"), channel_url("chD"))
  a <- local_r_session()
  b <- local_r_session()
  sync_dir <- withr::local_tempdir(pattern = "rt-lock-sync-")
  common <- list(env_name = env_name, method = "rattler", verbose = "output")
  with_channels <- c(common, list(channels = channels))
  install <- function(pkg) {
    return(list(
      fn = "install_packages",
      args = c(list(pkg), with_channels),
      hook = "backend_install"
    ))
  }
  overwrite <- function(pkg) {
    return(list(
      fn = "create_env",
      args = c(list(pkg), with_channels, list(overwrite = TRUE)),
      hook = "backend_create_env"
    ))
  }
  remove <- list(fn = "remove_env", args = common, hook = "backend_remove_env")
  cases <- list(
    `install-remove` = list(
      first = install("baz"),
      second = remove,
      values = c("done", "done"),
      after = NULL
    ),
    `remove-install` = list(
      first = remove,
      second = install("baz"),
      values = c("done", "error"),
      error_class = "condathis_install_packages_env_not_found",
      after = NULL
    ),
    `overwrite-install` = list(
      first = overwrite("devtool"),
      second = install("baz"),
      values = c("done", "done"),
      after = c("baz", "devtool")
    ),
    `install-overwrite` = list(
      first = install("baz"),
      second = overwrite("devtool"),
      values = c("done", "done"),
      after = "devtool"
    )
  )
  env_packages <- function() {
    if (isFALSE(condathis::env_exists(env_name, method = "rattler"))) {
      return(NULL)
    }
    return(sort(condathis::list_packages(env_name, method = "rattler")$name))
  }
  for (case_name in names(cases)) {
    case <- cases[[case_name]]
    if (isTRUE(condathis::env_exists(env_name, method = "rattler"))) {
      condathis::remove_env(env_name, method = "rattler", verbose = "silent")
    }
    condathis::create_env(
      "foo",
      env_name = env_name,
      channels = channels,
      method = "rattler",
      verbose = "silent"
    )
    raced <- race_rattler_env_lock(
      a,
      b,
      sync_dir = sync_dir,
      label = case_name,
      first = case$first,
      second = case$second
    )
    info <- paste(case_name, raced$a$error_message, raced$b$error_message)
    expect_identical(c(raced$a$value, raced$b$value), case$values, info = info)
    expect_true(isTRUE(raced$b$waited), info = info)
    expect_false(isTRUE(raced$a$waited), info = info)
    # condathis says that it waits after 2 s.
    expect_gte(raced$waited, 1.9)
    if (isFALSE(is.null(case$error_class))) {
      expect_true(case$error_class %in% raced$b$error_class, info = info)
      expect_false(raced$b_reached_backend, info = info)
    }
    expect_identical(env_packages(), case$after, info = info)
  }

  # Two creates of one new environment: the second finds the first's
  # environment and keeps it, without reaching its backend.
  if (isTRUE(condathis::env_exists(env_name, method = "rattler"))) {
    condathis::remove_env(env_name, method = "rattler", verbose = "silent")
  }
  create_call <- list(
    fn = "create_env",
    args = c(list("foo"), with_channels),
    hook = "backend_create_env"
  )
  raced <- race_rattler_env_lock(
    a,
    b,
    sync_dir = sync_dir,
    label = "create-create",
    first = create_call,
    second = create_call
  )
  expect_identical(
    c(raced$a$value, raced$b$value),
    c("done", "done"),
    info = paste(raced$a$error_message, raced$b$error_message)
  )
  expect_false(raced$b_reached_backend)
  expect_identical(env_packages(), "foo")
  # No job was left, and no lock file inside the environment.
  env_dir <- condathis::get_env_dir(env_name, method = "rattler")
  expect_false(file.exists(file.path(env_dir, "conda-meta", "conda-meta.lock")))
  expect_identical(missing_record_files(env_dir), character(0L))
})
