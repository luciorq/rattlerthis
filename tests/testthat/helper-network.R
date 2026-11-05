# Helpers of the network tests (test-parity-network.R): an HTTPS channel
# with a test certificate authority, and condathis calls with both
# backends against the local HTTP channel of helper-concurrency.R used as a
# channel, a proxy or a server that needs credentials.

# The TLS files of fixtures/tls: `ca` (the test CA, PEM), `cert` (the
# server's certificate for 127.0.0.1, PEM) and `key` (its key, DER).
test_tls_files <- function() {
  dir <- fixtures_path("tls")
  return(list(
    ca = file.path(dir, "ca.pem"),
    cert = file.path(dir, "server.pem"),
    key = file.path(dir, "server-key.der")
  ))
}

# Serves copies of the test channels `names` over HTTPS with the test
# certificate (`rt_test_https_server()`, in a new R process killed when the
# caller ends; its temporary directory is inside this process's, see
# `child_r_envvars()`). Returns `list(url(name), log, process)`; `log` is
# the file with every request line.
local_https_channel <- function(names, env = parent.frame()) {
  root <- withr::local_tempdir(pattern = "rt-https-", .local_envir = env)
  for (name in names) {
    stopifnot(isTRUE(name %in% test_channel_names))
    file.copy(file.path(test_channels_dir(), name), root, recursive = TRUE)
  }
  ctl <- withr::local_tempdir(pattern = "rt-https-ctl-", .local_envir = env)
  port_file <- file.path(ctl, "port")
  log_file <- file.path(ctl, "log")
  tls <- test_tls_files()
  process <- callr::r_bg(
    function(root, cert, key, port_file, log_file) {
      getFromNamespace("rt_test_https_server", "rattlerthis")(
        root,
        cert,
        key,
        port_file,
        log_file
      )
    },
    args = list(
      root = root,
      cert = tls$cert,
      key = tls$key,
      port_file = port_file,
      log_file = log_file
    ),
    libpath = .libPaths(),
    env = child_r_envvars(callr::rcmd_safe_env()),
    supervise = TRUE
  )
  withr::defer(process$kill(), envir = env)
  wait_until(
    function() file.exists(port_file) || isFALSE(process$is_alive()),
    timeout = 60,
    what = "the HTTPS channel server"
  )
  if (isFALSE(file.exists(port_file))) {
    stop(
      "The HTTPS channel server did not start: ",
      paste(process$read_all_error_lines(), collapse = "\n"),
      call. = FALSE
    )
  }
  base_url <- paste0(
    "https://127.0.0.1:",
    readLines(port_file, n = 1L, warn = FALSE)
  )
  return(list(
    url = function(name) paste0(base_url, "/", name),
    log = log_file,
    process = process
  ))
}

# The log lines of an HTTPS channel.
https_channel_log <- function(server) {
  if (isFALSE(file.exists(server$log))) {
    return(character(0L))
  }
  return(readLines(server$log, warn = FALSE))
}

# The base URL (`http://127.0.0.1:<port>`) of an HTTP channel server, also
# its URL as a proxy.
http_channel_base <- function(server) {
  return(sub("/chA$", "", server$url("chA")))
}

# Empties the request log of an HTTP channel server.
http_channel_clear_log <- function(server) {
  unlink(file.path(server$ctl, "log"))
  return(invisible(server))
}

# The proxy variables libcurl and rattler read, all unset; `...` sets some.
local_proxy_env <- function(..., env = parent.frame()) {
  names <- c(
    "http_proxy",
    "HTTP_PROXY",
    "https_proxy",
    "HTTPS_PROXY",
    "all_proxy",
    "ALL_PROXY",
    "no_proxy",
    "NO_PROXY"
  )
  values <- stats::setNames(rep(NA_character_, length(names)), names)
  set <- c(...)
  values[names(set)] <- set
  # On Windows, names differ only in case are one variable: unset them
  # first, then set the given spellings.
  withr::local_envvar(values[is.na(values)], .local_envir = env)
  if (isTRUE(length(set) > 0L)) {
    withr::local_envvar(set, .local_envir = env)
  }
  return(invisible(set))
}

# Creates `foo` from `channel` with `method` in a new environment
# `<prefix>-mm` or `<prefix>-rt`; returns the error (or `NULL`) and the
# package names.
network_create <- function(prefix, channel, method, env = parent.frame()) {
  env_name <- psolve_env_name(prefix, method)
  defer_remove_env(env_name, method = method, env = env)
  captured <- psolve_capture(condathis::create_env(
    "foo",
    env_name = env_name,
    channels = channel,
    method = method,
    verbose = "silent"
  ))
  exists <- isTRUE(condathis::env_exists(env_name, method = method))
  return(list(
    error = captured$error,
    packages = if (isTRUE(exists)) {
      as.character(condathis::list_packages(env_name, method = method)$name)
    } else {
      character(0L)
    }
  ))
}

# Makes the cached channel metadata of both backends two hours old, so the
# next call downloads it again (libmamba's lifetime of metadata without
# `Cache-Control: max-age`, which rattlerthis follows, is an hour):
# rattler's `<rattler root>/repodata_cache/*.info.json` and micromamba's
# `<root>/pkgs/cache/*.json`.
age_rattler_repodata_cache <- function() {
  root <- fs::path_dir(condathis::backend_root_dir("rattler"))
  files <- c(
    list.files(
      file.path(root, "rattler", "repodata_cache"),
      pattern = "[.]info[.]json$",
      full.names = TRUE
    ),
    list.files(
      file.path(root, "pkgs", "cache"),
      pattern = "[.]json$",
      full.names = TRUE
    )
  )
  Sys.setFileTime(files, Sys.time() - 2 * 60 * 60)
  return(invisible(files))
}
