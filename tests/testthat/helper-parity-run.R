# Helpers of test-parity-childenv.R, test-parity-verbose.R,
# test-parity-linkscripts.R, test-clean-cache.R and test-sandbox.R. Every
# name starts with `pr_`, so these never collide with the helpers of other
# test files.

# Channels built by these helpers, once per test process: name -> directory.
pr_state <- new.env(parent = emptyenv())

# --- Output -----------------------------------------------------------------------

# What an expression prints: `stdout` (the lines of standard output),
# `messages` (the text of the messages it signals, which are muffled) and
# `stderr` (the lines written straight to the message stream, such as a
# cli spinner's). Warnings and errors pass through. The value is in
# `value`.
pr_capture <- function(expr) {
  messages <- character(0L)
  value <- NULL
  err_file <- tempfile(pattern = "rt-pr-stderr-")
  err_con <- file(err_file, open = "wt")
  sink(err_con, type = "message")
  stdout <- tryCatch(
    utils::capture.output(
      value <- withCallingHandlers(
        expr,
        message = function(cnd) {
          messages <<- c(messages, conditionMessage(cnd))
          invokeRestart("muffleMessage")
        }
      )
    ),
    finally = {
      sink(type = "message")
      close(err_con)
    }
  )
  stderr <- readLines(err_file, warn = FALSE)
  unlink(err_file)
  return(list(
    stdout = stdout,
    messages = sub("\n$", "", messages),
    stderr = stderr,
    value = value
  ))
}

# --- Channels built at test time ------------------------------------------------

# The SHA-256 of a file, or NULL where this R has no `tools::sha256sum()`
# (older versions of R): repodata and paths.json may leave it out, and both
# backends then check the MD5.
pr_sha256 <- function(path) {
  tools_ns <- asNamespace("tools")
  if (isFALSE(exists("sha256sum", envir = tools_ns, inherits = FALSE))) {
    return(NULL)
  }
  sha256sum <- get("sha256sum", envir = tools_ns)
  return(unname(sha256sum(path)))
}

# Builds a noarch conda package (`<name>-<version>-0.tar.bz2`) in
# `subdir_dir`, as tools/make-test-channels.py builds the fixtures: `files`
# is a named list, path in the prefix -> content (a string, written as
# bytes); `.sh` files are executable. Returns the repodata record.
pr_build_package <- function(subdir_dir, name, version, files) {
  stage <- tempfile(pattern = "rt-pr-pkg-")
  dir.create(file.path(stage, "info"), recursive = TRUE)
  on.exit(unlink(stage, recursive = TRUE), add = TRUE)
  paths <- sort(names(files), method = "radix")
  path_entries <- list()
  for (path in paths) {
    target <- file.path(stage, path)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    writeBin(charToRaw(files[[path]]), target)
    if (isTRUE(endsWith(path, ".sh"))) {
      Sys.chmod(target, mode = "755")
    }
    entry <- list(`_path` = path, path_type = "hardlink")
    entry$sha256 <- pr_sha256(target)
    entry$size_in_bytes <- file.size(target)
    path_entries <- c(path_entries, list(entry))
  }
  index <- list(
    build = "0",
    build_number = 0L,
    depends = character(0L),
    license = "MIT",
    name = name,
    noarch = "generic",
    subdir = "noarch",
    timestamp = 1700000000000,
    version = version
  )
  jsonlite::write_json(
    index,
    file.path(stage, "info", "index.json"),
    auto_unbox = TRUE,
    digits = NA
  )
  jsonlite::write_json(
    list(paths = path_entries, paths_version = 1L),
    file.path(stage, "info", "paths.json"),
    auto_unbox = TRUE,
    digits = NA
  )
  writeLines(paths, file.path(stage, "info", "files"))
  file_name <- paste0(name, "-", version, "-0.tar.bz2")
  archive <- file.path(normalizePath(subdir_dir, winslash = "/"), file_name)
  withr::with_dir(
    stage,
    utils::tar(
      archive,
      files = c("info/index.json", "info/paths.json", "info/files", paths),
      compression = "bzip2",
      tar = "internal"
    )
  )
  record <- index
  record$md5 <- unname(tools::md5sum(archive))
  record$sha256 <- pr_sha256(archive)
  record$size <- file.size(archive)
  return(record)
}

# Builds a local channel `<process sandbox>/pr-channels/<name>` with the
# noarch packages of `packages` (a list of `list(name, version, files)`),
# its repodata.json, and an empty repodata.json in every other known
# subdir. Once per test process; returns the directory.
pr_channel_dir <- function(name, packages) {
  dir <- pr_state[[name]]
  if (isFALSE(is.null(dir)) && isTRUE(dir.exists(dir))) {
    return(dir)
  }
  parent_dir <- rt_test_state$sandbox$root %||% tempdir()
  dir <- file.path(parent_dir, "pr-channels", name)
  noarch_dir <- file.path(dir, "noarch")
  dir.create(noarch_dir, recursive = TRUE, showWarnings = FALSE)
  records <- list()
  for (pkg in packages) {
    record <- pr_build_package(
      noarch_dir,
      name = pkg$name,
      version = pkg$version,
      files = pkg$files
    )
    records[[paste0(pkg$name, "-", pkg$version, "-0.tar.bz2")]] <- record
  }
  jsonlite::write_json(
    list(
      info = list(subdir = "noarch"),
      packages = records,
      packages.conda = structure(list(), names = character(0L)),
      repodata_version = 1L
    ),
    file.path(noarch_dir, "repodata.json"),
    auto_unbox = TRUE,
    digits = NA,
    pretty = TRUE
  )
  fill_channel_subdirs(dir)
  dir <- normalizePath(dir, winslash = "/", mustWork = TRUE)
  pr_state[[name]] <- dir
  return(dir)
}

# A link script that records that it ran: it writes `version` to
# `<prefix>/prlink-<kind>-ran`. A pre-unlink script also writes it next to
# the environment directory (`<prefix>.prlink-pre-unlink-ran`), which
# outlives the removal of the environment. `.sh` for Linux and macOS,
# `.bat` (CRLF) for Windows.
pr_link_script <- function(kind, version, shell = c("sh", "bat")) {
  shell <- rlang::arg_match(shell)
  marker <- paste0("prlink-", kind, "-ran")
  if (identical(shell, "sh")) {
    lines <- c(
      "#!/bin/sh",
      paste0("echo ", version, " > \"$PREFIX/", marker, "\"")
    )
    if (identical(kind, "pre-unlink")) {
      lines <- c(lines, paste0("echo ", version, " > \"$PREFIX.", marker, "\""))
    }
    return(paste0(paste(lines, collapse = "\n"), "\n"))
  }
  # `(echo x)> file`: a digit right before `>` would name a handle.
  lines <- paste0("@(echo ", version, ")> \"%PREFIX%\\", marker, "\"")
  if (identical(kind, "pre-unlink")) {
    lines <- c(
      lines,
      paste0("@(echo ", version, ")> \"%PREFIX%.", marker, "\"")
    )
  }
  return(paste0(paste(lines, collapse = "\r\n"), "\r\n"))
}

# The files of `prlink` <version>: its three link scripts for both shells
# and a README.
pr_prlink_files <- function(version) {
  files <- list()
  files[["share/prlink/README"]] <- paste0("prlink ", version, "\n")
  for (kind in c("pre-link", "post-link", "pre-unlink")) {
    files[[paste0("bin/.prlink-", kind, ".sh")]] <- pr_link_script(
      kind,
      version,
      shell = "sh"
    )
    files[[paste0("Scripts/.prlink-", kind, ".bat")]] <- pr_link_script(
      kind,
      version,
      shell = "bat"
    )
  }
  return(files)
}

# The channel `prlink`, built at test time (the fixtures have no second
# version of a package with link scripts):
#
# * prlink 1.0 and 2.0: pre-link, post-link and pre-unlink scripts that
#   write their version to `<prefix>/prlink-<kind>-ran` (pre-unlink also
#   to `<prefix>.prlink-pre-unlink-ran`, see `pr_link_script()`);
# * prfail 1.0: a post-link script that writes `1.0` to
#   `<prefix>/prfail-post-link-ran` and then fails (exit status 1);
# * practd 1.0: an `activate.d` script that sets `RT_PR_ACTD=on`.
pr_prlink_channel <- function() {
  packages <- list(
    list(name = "prlink", version = "1.0", files = pr_prlink_files("1.0")),
    list(name = "prlink", version = "2.0", files = pr_prlink_files("2.0")),
    list(
      name = "prfail",
      version = "1.0",
      files = list(
        `share/prfail/README` = "prfail 1.0\n",
        `bin/.prfail-post-link.sh` = paste0(
          "#!/bin/sh\n",
          "echo 1.0 > \"$PREFIX/prfail-post-link-ran\"\n",
          "exit 1\n"
        ),
        `Scripts/.prfail-post-link.bat` = paste0(
          "@(echo 1.0)> \"%PREFIX%\\prfail-post-link-ran\"\r\n",
          "@exit /b 1\r\n"
        )
      )
    ),
    list(
      name = "practd",
      version = "1.0",
      files = list(
        `share/practd/README` = "practd 1.0\n",
        `etc/conda/activate.d/practd.sh` = "export RT_PR_ACTD=on\n",
        `etc/conda/activate.d/practd.bat` = "@set \"RT_PR_ACTD=on\"\r\n"
      )
    )
  )
  return(file_url(pr_channel_dir("prlink", packages)))
}

# The markers of link scripts that ran in `prefix`: a named character
# vector, kind -> the version that the script wrote. Empty when none ran.
pr_link_markers <- function(prefix) {
  files <- list.files(prefix, pattern = "-ran$", full.names = TRUE)
  values <- vapply(
    files,
    function(path) trimws(readLines(path, warn = FALSE)[[1L]]),
    character(1L)
  )
  names(values) <- sub("-ran$", "", basename(files))
  return(values[order(names(values), method = "radix")])
}

# --- Paths -------------------------------------------------------------------------

# The real path of `path`, also when it does not exist: its longest existing
# ancestor is realized (macOS `/var` is `/private/var`) and the rest is
# appended.
pr_real_path <- function(path) {
  path <- as.character(path)
  if (isTRUE(file.exists(path))) {
    return(normalizePath(path, winslash = "/", mustWork = TRUE))
  }
  parent <- dirname(path)
  if (identical(parent, path)) {
    return(path)
  }
  return(file.path(pr_real_path(parent), basename(path)))
}

# --- Backends -----------------------------------------------------------------------

# The two backends, in the order the parity tests run them.
pr_methods <- c("micromamba", "rattler")

# An environment name for each backend: `<prefix>-mm` and `<prefix>-rt`.
# Names are one namespace across backends, so each backend gets its own.
pr_env_names <- function(prefix) {
  return(c(
    micromamba = paste0(prefix, "-mm"),
    rattler = paste0(prefix, "-rt")
  ))
}

# Removes the environments of `env_names` (named by method) at the end of
# the caller, if they exist, muffling the link-script warning.
pr_defer_remove_envs <- function(env_names, env = parent.frame()) {
  for (method in names(env_names)) {
    local({
      env_name <- env_names[[method]]
      env_method <- method
      defer_remove_env(env_name, method = env_method, env = env)
    })
  }
  return(invisible(env_names))
}
