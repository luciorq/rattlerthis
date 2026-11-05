# Helpers of the concurrency tests (test-interrupt.R, test-fork.R,
# test-lock.R and test-parity-remove-busy.R):
#
# * other R sessions (callr) that run condathis calls which a test
#   interrupts or races. A session copies the environment variables and
#   library paths of this process when it starts, so it works in the
#   sandbox of the test that starts it;
# * a local HTTP channel whose package downloads wait until the test
#   releases them, so a create or an install is caught during its download
#   (rattler's phase `prefetch`), without network access;
# * a local channel with a package built at test time from files of this
#   machine (a program that a test runs from an environment);
# * the processes below a process (ps), and waiting for a condition.

# --- Waiting --------------------------------------------------------------------

# Waits until `condition()` is TRUE, polling every 50 ms, at most `timeout`
# seconds. The test errors when the time runs out, so a broken expectation
# never hangs the run.
wait_until <- function(condition, timeout = 30, what = "the condition") {
  started <- Sys.time()
  repeat {
    if (isTRUE(condition())) {
      return(invisible(TRUE))
    }
    waited <- as.numeric(difftime(Sys.time(), started, units = "secs"))
    if (isTRUE(waited > timeout)) {
      stop(
        "Timed out after ",
        timeout,
        " s waiting for ",
        what,
        ".",
        call. = FALSE
      )
    }
    Sys.sleep(0.05)
  }
}

# Seconds since `started`.
seconds_since <- function(started) {
  return(as.numeric(difftime(Sys.time(), started, units = "secs")))
}

# --- Other R sessions -----------------------------------------------------------

# The environment variables of an R process that a helper starts with
# callr: callr's `defaults` and `TMPDIR`, this process's `tempdir()`. R
# makes its temporary directory in `TMPDIR` (on Windows too, before `TMP`
# and `TEMP`). A helper that kills the process leaves that directory
# behind; inside this process's `tempdir()`, it goes when this process
# ends.
child_r_envvars <- function(defaults) {
  return(c(defaults, TMPDIR = tempdir()))
}

# A new R session (callr) with condathis and rattlerthis loaded, closed
# (killed when busy) when the caller ends. It has this process's library
# paths and environment variables, so start it after the sandbox of the
# test; its temporary directory is inside this process's
# (`child_r_envvars()`).
local_r_session <- function(env = parent.frame()) {
  options <- callr::r_session_options(libpath = .libPaths())
  options$env <- child_r_envvars(options$env)
  session <- callr::r_session$new(options = options, wait = TRUE)
  withr::defer(session$close(), envir = env)
  session$run(function() {
    loadNamespace("condathis")
    loadNamespace("rattlerthis")
    return(invisible(NULL))
  })
  return(session)
}

# Sends an interrupt (as Ctrl-C does) to a session that runs a call.
# On Windows, callr's `interrupt()` sends CTRL+C, which never reaches the R
# of a callr session (it runs in a process group of its own); CTRL+BREAK
# does, through ps (checked on Windows 11 with R 4.6.1, callr 3.8.0 and ps
# 1.9.3: CTRL+C left a 20 s job running, CTRL+BREAK stopped it in
# 0.06 s). On Linux and macOS, `interrupt()` sends SIGINT.
interrupt_session <- function(session) {
  if (isTRUE(is_windows())) {
    ps::ps_interrupt(session$as_ps_handle(), ctrl_c = FALSE)
  } else {
    session$interrupt()
  }
  return(invisible(session))
}

# Waits for the call that a session runs, at most `timeout` seconds.
# Returns `list(state, seconds, result, error)`: `state` is "ready" when the
# call returned (then `result` is its value, or `error` its error) and
# "timeout" otherwise.
session_outcome <- function(session, timeout = 60) {
  started <- Sys.time()
  state <- session$poll_process(as.integer(timeout * 1000))
  seconds <- seconds_since(started)
  if (isFALSE(identical(state, "ready"))) {
    return(list(state = state, seconds = seconds, result = NULL, error = NULL))
  }
  out <- session$read()
  return(list(
    state = state,
    seconds = seconds,
    result = out$result,
    error = out$error
  ))
}

# Runs condathis's exported function `fn` with the list `args` in
# `session`, and returns at once (`session_outcome()` collects the
# outcome). The call's value is a list: `value` ("done" when the function
# returned, "interrupted" when an interrupt stopped it, "error" when it
# failed), `error_class`, `error_message` and `error_kind` (the classes and
# message of the error, and the `kind` of the rattler error in its parent
# chain; `NULL` without an error), `live_jobs` (`rt_live_jobs()` of the
# session right after) and `warnings` (the first class of each warning,
# which is muffled).
start_condathis_call <- function(session, fn, args) {
  session$call(
    function(fn, args) {
      warnings <- character(0L)
      error_class <- NULL
      error_message <- NULL
      error_kind <- NULL
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
            parent <- cnd
            while (isFALSE(is.null(parent))) {
              if (inherits(parent, "rattlerthis_rattler_error")) {
                error_kind <<- parent$kind
                break
              }
              parent <- parent$parent
            }
            return("error")
          }
        ),
        warning = function(cnd) {
          warnings <<- c(warnings, class(cnd)[[1L]])
          invokeRestart("muffleWarning")
        }
      )
      return(list(
        value = value,
        error_class = error_class,
        error_message = error_message,
        error_kind = error_kind,
        live_jobs = asNamespace("rattlerthis")$rt_live_jobs(),
        warnings = warnings
      ))
    },
    args = list(fn = fn, args = args)
  )
  return(invisible(session))
}

# Asserts the outcome of a `start_condathis_call()`: the call returned
# within its time, with `value`, and left no rattler job running. A
# failure shows the error of the call.
expect_condathis_call <- function(outcome, value) {
  testthat::expect_identical(outcome$state, "ready")
  testthat::expect_null(outcome$error)
  testthat::expect_identical(
    outcome$result$value,
    value,
    info = paste(
      c(outcome$result$error_kind, outcome$result$error_message),
      collapse = ": "
    )
  )
  testthat::expect_identical(outcome$result$live_jobs, 0L)
  return(invisible(outcome))
}

# Records the phase of every rattler job that `session` polls (see
# `rt_job_phase()`) in `phase_file`, one line per change, so a test can
# read them while the session runs: `trace()` adds this to
# `rt_job_poll()` in the session's rattlerthis namespace.
trace_job_phases <- function(session, phase_file) {
  session$run(
    function(phase_file) {
      tracer <- bquote({
        phase <- tryCatch(rt_job_phase(job), error = function(e) "error")
        last <- get0("rt_test_last_phase", envir = globalenv())
        if (isFALSE(identical(phase, last))) {
          assign("rt_test_last_phase", phase, envir = globalenv())
          cat(phase, "\n", sep = "", file = .(phase_file), append = TRUE)
        }
      })
      suppressMessages(trace(
        "rt_job_poll",
        tracer = tracer,
        where = asNamespace("rattlerthis"),
        print = FALSE
      ))
      return(invisible(NULL))
    },
    args = list(phase_file = phase_file)
  )
  return(invisible(phase_file))
}

# The phases `trace_job_phases()` recorded so far.
read_job_phases <- function(phase_file) {
  if (isFALSE(file.exists(phase_file))) {
    return(character(0L))
  }
  return(readLines(phase_file, warn = FALSE))
}

# --- A local HTTP channel that holds its downloads ------------------------------

# The server, run in its own R process (`callr::r_bg()`): serves the files
# below `root` over HTTP/1.1 on a free port (clients use 127.0.0.1; GET and
# HEAD, 404 for anything else), each request on a new connection. A file
# whose URL path matches `hold_pattern` (package archives by default) is
# sent in two steps while `hold_file` exists: the headers and the first
# bytes, then the rest once `hold_file` is gone; the server answers other
# requests meanwhile. For each such file it creates
# `<ctl_dir>/serving-<n>` when it starts to send it. A client that closes
# a held connection (a cancelled download) is dropped. With `validators =
# TRUE` it sends an `ETag` (the file's MD5) and answers a request that has
# it in `If-None-Match` with 304 Not Modified, as static file servers do;
# then a client keeps its cached copy instead of downloading the file
# again. With `FALSE` it sends no validator, as some dynamic servers, so
# every request downloads the file. It also works as an HTTP proxy for any
# host: a request for an absolute URL (`GET http://host/path`) is served
# from `root` as the request for `/path`. With `auth`, a request must have
# that `Authorization` header (a string), or, with `token`, a path below
# `/t/<token>/` (served as the path without it); anything else gets 401.
# It writes its port to `<ctl_dir>/port` and every request to
# `<ctl_dir>/log` (`<method> <target> <status>`, then
# ` authorization=<value>` when the request has that header).
# Self-contained: callr runs it in a new process.
http_channel_server <- function(
  root,
  ctl_dir,
  hold_file,
  validators = TRUE,
  hold_pattern = "[.](tar[.]bz2|conda)$",
  auth = NULL,
  token = NULL
) {
  server <- NULL
  for (i in seq_len(100L)) {
    port <- sample(20000:60000, 1L)
    server <- tryCatch(serverSocket(port), error = function(e) NULL)
    if (isFALSE(is.null(server))) {
      break
    }
  }
  if (is.null(server)) {
    stop("No free port for the HTTP channel.")
  }
  port_tmp <- file.path(ctl_dir, "port.tmp")
  writeLines(as.character(port), port_tmp)
  file.rename(port_tmp, file.path(ctl_dir, "port"))
  served <- 0L
  held <- list()
  log_line <- function(...) {
    cat(..., "\n", file = file.path(ctl_dir, "log"), append = TRUE, sep = "")
  }
  send_text <- function(con, ...) {
    writeBin(charToRaw(paste0(...)), con)
  }
  # Answers the request on `con`. Returns `NULL` when the response is
  # complete, or a list with the connection and the rest of the body when
  # it is held.
  respond <- function(con) {
    request <- readLines(con, n = 1L, warn = FALSE)
    if (identical(length(request), 0L)) {
      return(NULL)
    }
    if_none_match <- NULL
    authorization <- NULL
    repeat {
      header <- sub("\r$", "", readLines(con, n = 1L, warn = FALSE))
      if (identical(length(header), 0L) || isFALSE(nzchar(header))) {
        break
      }
      if (isTRUE(grepl("^if-none-match:", tolower(header)))) {
        if_none_match <- trimws(sub("^[^:]*:", "", header))
      }
      if (isTRUE(grepl("^authorization:", tolower(header)))) {
        authorization <- trimws(sub("^[^:]*:", "", header))
      }
    }
    parts <- strsplit(sub("\r$", "", request), " ", fixed = TRUE)[[1L]]
    method <- parts[[1L]]
    target <- sub("[?#].*$", "", parts[[2L]])
    # A proxy request names the whole URL.
    path <- utils::URLdecode(sub("^[a-z]+://[^/]*", "", target))
    shown <- if (grepl("^[a-z]+://", target)) target else path
    suffix <- if (isFALSE(is.null(authorization))) {
      paste0(" authorization=", authorization)
    } else {
      ""
    }
    allowed <- TRUE
    if (isFALSE(is.null(auth))) {
      allowed <- identical(authorization, auth)
    }
    if (isFALSE(is.null(token))) {
      prefix <- paste0("/t/", token, "/")
      allowed <- startsWith(path, prefix)
      path <- sub(prefix, "/", path, fixed = TRUE)
    }
    if (isFALSE(allowed)) {
      log_line(method, " ", shown, " 401", suffix)
      send_text(
        con,
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n",
        "Connection: close\r\n\r\n"
      )
      return(NULL)
    }
    file <- file.path(root, sub("^/+", "", path))
    found <- isTRUE(method %in% c("GET", "HEAD")) &&
      isFALSE(grepl("(^|/)[.][.](/|$)", path)) &&
      isTRUE(file.exists(file)) &&
      isFALSE(dir.exists(file))
    if (isFALSE(found)) {
      log_line(method, " ", shown, " 404", suffix)
      send_text(
        con,
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n",
        "Connection: close\r\n\r\n"
      )
      return(NULL)
    }
    etag <- paste0("\"", unname(tools::md5sum(file)), "\"")
    if (isTRUE(validators) && identical(if_none_match, etag)) {
      log_line(method, " ", shown, " 304", suffix)
      send_text(
        con,
        "HTTP/1.1 304 Not Modified\r\nETag: ",
        etag,
        "\r\nConnection: close\r\n\r\n"
      )
      return(NULL)
    }
    log_line(method, " ", shown, " 200", suffix)
    body <- readBin(file, "raw", file.size(file))
    send_text(
      con,
      "HTTP/1.1 200 OK\r\nContent-Length: ",
      length(body),
      "\r\nContent-Type: application/octet-stream\r\n",
      if (isTRUE(validators)) paste0("ETag: ", etag, "\r\n"),
      "Connection: close\r\n\r\n"
    )
    if (identical(method, "HEAD")) {
      return(NULL)
    }
    if (isFALSE(grepl(hold_pattern, path))) {
      writeBin(body, con)
      return(NULL)
    }
    served <<- served + 1L
    file.create(file.path(ctl_dir, sprintf("serving-%03d", served)))
    if (isFALSE(file.exists(hold_file))) {
      writeBin(body, con)
      return(NULL)
    }
    first <- min(16L, length(body))
    writeBin(body[seq_len(first)], con)
    flush(con)
    log_line("holding ", path)
    return(list(con = con, rest = body[-seq_len(first)], path = path))
  }
  repeat {
    if (isTRUE(length(held) > 0L) && isFALSE(file.exists(hold_file))) {
      for (entry in held) {
        tryCatch(
          {
            writeBin(entry$rest, entry$con)
            log_line("sent ", entry$path)
          },
          error = function(e) log_line("error ", conditionMessage(e))
        )
        try(close(entry$con), silent = TRUE)
      }
      held <- list()
    }
    sockets <- c(list(server), lapply(held, function(entry) entry$con))
    ready <- tryCatch(
      socketSelect(sockets, timeout = 0.05),
      error = function(e) rep(FALSE, length(sockets))
    )
    # A held client that is readable has closed its connection.
    gone <- which(ready[-1L])
    for (index in gone) {
      log_line("dropped ", held[[index]]$path)
      try(close(held[[index]]$con), silent = TRUE)
    }
    if (isTRUE(length(gone) > 0L)) {
      held <- held[-gone]
    }
    if (isFALSE(isTRUE(ready[[1L]]))) {
      next
    }
    con <- tryCatch(
      socketAccept(server, blocking = TRUE, open = "r+b", timeout = 10),
      error = function(e) NULL
    )
    if (is.null(con)) {
      next
    }
    kept <- tryCatch(respond(con), error = function(e) {
      log_line("error ", conditionMessage(e))
      return(NULL)
    })
    if (is.null(kept)) {
      try(close(con), silent = TRUE)
    } else {
      held[[length(held) + 1L]] <- kept
    }
  }
}

# Serves copies of the test channels `names` over HTTP, from a new server
# process that is killed when the caller ends (its temporary directory is
# inside this process's, `child_r_envvars()`). Package downloads are held
# from the start (see `http_channel_server()`): release them with
# `http_channel_release()`. `validators = FALSE` makes every request
# download the file again; `hold_pattern` chooses the files that are held;
# `auth` and `token` are the credentials it requires.
# Returns a list with `url(name)` (the channel's URL), `hold` (the hold
# file), `ctl` (the control directory) and `process`.
local_http_channel <- function(
  names,
  validators = TRUE,
  hold_pattern = "[.](tar[.]bz2|conda)$",
  auth = NULL,
  token = NULL,
  env = parent.frame()
) {
  root <- withr::local_tempdir(pattern = "rt-http-", .local_envir = env)
  for (name in names) {
    stopifnot(isTRUE(name %in% test_channel_names))
    file.copy(file.path(test_channels_dir(), name), root, recursive = TRUE)
  }
  ctl <- withr::local_tempdir(pattern = "rt-http-ctl-", .local_envir = env)
  hold <- file.path(ctl, "hold")
  file.create(hold)
  process <- callr::r_bg(
    http_channel_server,
    args = list(
      root = root,
      ctl_dir = ctl,
      hold_file = hold,
      validators = validators,
      hold_pattern = hold_pattern,
      auth = auth,
      token = token
    ),
    libpath = .libPaths(),
    env = child_r_envvars(callr::rcmd_safe_env()),
    supervise = TRUE
  )
  withr::defer(process$kill(), envir = env)
  port_file <- file.path(ctl, "port")
  wait_until(
    function() file.exists(port_file) || isFALSE(process$is_alive()),
    timeout = 30,
    what = "the HTTP channel server"
  )
  if (isFALSE(file.exists(port_file))) {
    stop(
      "The HTTP channel server did not start: ",
      paste(process$read_all_error_lines(), collapse = "\n"),
      call. = FALSE
    )
  }
  base_url <- paste0("http://127.0.0.1:", readLines(port_file, n = 1L))
  return(list(
    url = function(name) paste0(base_url, "/", name),
    root = root,
    hold = hold,
    ctl = ctl,
    process = process
  ))
}

# The number of downloads of held files (package archives by default) the
# server has started.
http_channel_downloads <- function(server) {
  return(length(list.files(server$ctl, pattern = "^serving-")))
}

# Waits until the server has started `count` package downloads; the error
# of a timeout lists the requests the server got.
wait_for_download <- function(server, count, timeout = 60) {
  tryCatch(
    wait_until(
      function() http_channel_downloads(server) >= count,
      timeout = timeout,
      what = paste0("package download ", count, " of the HTTP channel")
    ),
    error = function(e) {
      stop(
        conditionMessage(e),
        " Requests: ",
        paste(http_channel_log(server), collapse = "; "),
        call. = FALSE
      )
    }
  )
  return(invisible(server))
}

# Lets held and later package downloads go on.
http_channel_release <- function(server) {
  unlink(server$hold)
  return(invisible(server))
}

# The requests the server logged (for failure messages).
http_channel_log <- function(server) {
  log_file <- file.path(server$ctl, "log")
  if (isFALSE(file.exists(log_file))) {
    return(character(0L))
  }
  return(readLines(log_file, warn = FALSE))
}

# --- A channel with a package built at test time --------------------------------

# Builds a channel `<dir>/<channel>` with one noarch package `<package> 1.0
# 0` whose files are copies of local files: `files` maps a path in the
# package (`"bin/rt-busy"`) to the file to copy. The copies are executable.
# Every known subdir of condathis gets a repodata.json. Returns the channel
# directory; the URL is `file_url(dir)`.
local_package_channel <- function(
  channel,
  package,
  files,
  env = parent.frame()
) {
  root <- withr::local_tempdir(pattern = "rt-pkgchan-", .local_envir = env)
  stage <- file.path(root, "stage")
  dir.create(file.path(stage, "info"), recursive = TRUE)
  paths <- list()
  for (path in names(files)) {
    target <- file.path(stage, path)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    stopifnot(isTRUE(file.copy(files[[path]], target)))
    Sys.chmod(target, mode = "0755", use_umask = FALSE)
    paths[[length(paths) + 1L]] <- list(
      `_path` = path,
      path_type = "hardlink",
      size_in_bytes = file.size(target)
    )
  }
  index <- list(
    build = "0",
    build_number = 0L,
    depends = list(),
    license = "MIT",
    name = package,
    noarch = "generic",
    subdir = "noarch",
    version = "1.0"
  )
  jsonlite::write_json(
    index,
    file.path(stage, "info", "index.json"),
    auto_unbox = TRUE,
    digits = NA
  )
  jsonlite::write_json(
    list(paths = paths, paths_version = 1L),
    file.path(stage, "info", "paths.json"),
    auto_unbox = TRUE,
    digits = NA
  )
  writeLines(names(files), file.path(stage, "info", "files"))
  channel_dir <- file.path(root, channel)
  subdir_dir <- file.path(channel_dir, "noarch")
  dir.create(subdir_dir, recursive = TRUE)
  archive_name <- paste0(package, "-1.0-0.tar.bz2")
  archive <- file.path(subdir_dir, archive_name)
  top <- unique(vapply(
    strsplit(c("info/index.json", names(files)), "/", fixed = TRUE),
    function(parts) parts[[1L]],
    character(1L)
  ))
  withr::with_dir(
    stage,
    utils::tar(archive, files = top, compression = "bzip2", tar = "internal")
  )
  record <- index
  record$md5 <- unname(tools::md5sum(archive))
  record$size <- file.size(archive)
  repodata <- list(
    info = list(subdir = "noarch"),
    packages = stats::setNames(list(record), archive_name),
    packages.conda = structure(list(), names = character(0L)),
    repodata_version = 1L
  )
  jsonlite::write_json(
    repodata,
    file.path(subdir_dir, "repodata.json"),
    auto_unbox = TRUE,
    digits = NA
  )
  fill_channel_subdirs(channel_dir)
  return(normalizePath(channel_dir, winslash = "/", mustWork = TRUE))
}

# --- Processes ------------------------------------------------------------------

# The processes below a process (children, grandchildren, ...), as ps
# handles; an empty list when it has none or is gone.
process_descendants <- function(handle) {
  return(tryCatch(
    ps::ps_children(handle, recursive = TRUE),
    error = function(e) list()
  ))
}

# Is each process of a list of ps handles still running? A zombie (a
# process that has ended but was not reaped) counts as ended:
# `ps::ps_is_running()` is TRUE for one. In a container whose first process
# never reaps (`docker run` without `--init`, such as a CI job container),
# a killed process whose parent has ended stays a zombie.
processes_running <- function(handles) {
  return(vapply(
    handles,
    function(handle) {
      running <- tryCatch(ps::ps_is_running(handle), error = function(e) FALSE)
      zombie <- tryCatch(
        identical(ps::ps_status(handle), "zombie"),
        error = function(e) FALSE
      )
      return(isTRUE(running) && isFALSE(zombie))
    },
    logical(1L)
  ))
}
