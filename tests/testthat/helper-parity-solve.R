# Helpers of the parity files about solves, channels, pins, environment
# files and platforms (test-parity-lifecycle.R, test-parity-pins.R,
# test-parity-priority.R, test-parity-install-channels.R,
# test-parity-envfile.R, test-parity-platform.R).
#
# Those files run the same condathis calls with `method = "micromamba"`
# and `method = "rattler"` and compare what users see. Every name here
# starts with `psolve_`, so it cannot clash with the helpers of other
# files (testthat sources every helper file into one environment).

# --- Backends -------------------------------------------------------------------

# The two backends every parity test compares, micromamba first.
psolve_methods <- c("micromamba", "rattler")

# An environment name per backend: `<prefix>-mm` or `<prefix>-rt`. The
# names differ, because a name has one owner through condathis (R-17).
psolve_env_name <- function(prefix, method) {
  suffix <- if (identical(method, "micromamba")) "mm" else "rt"
  return(paste0(prefix, "-", suffix))
}

# The registered backend object of `method`, as condathis dispatches to it.
psolve_backend <- function(method) {
  get_backend <- get("get_backend", envir = asNamespace("condathis"))
  return(get_backend(method))
}

# condathis's generic `backend_can_solve()`, called with the registered
# backend object of `method`: the probe that condathis's emulation
# fallback asks (micromamba: `micromamba create --dry-run`; rattler: a
# solve check job).
psolve_can_solve <- function(method, ...) {
  generic <- get("backend_can_solve", envir = asNamespace("condathis"))
  return(generic(psolve_backend(method), ...))
}

# condathis's internal functions, by name.
psolve_condathis <- function(name) {
  return(get(name, envir = asNamespace("condathis")))
}

# --- Calls ----------------------------------------------------------------------

# Evaluates `expr` and records what a user sees: the value (or the error),
# every warning, every message and the text printed to standard output.
# Warnings and messages are muffled.
psolve_capture <- function(expr) {
  warnings <- list()
  messages <- character(0L)
  error <- NULL
  value <- NULL
  output <- utils::capture.output(
    value <- tryCatch(
      withCallingHandlers(
        expr,
        warning = function(cnd) {
          warnings[[length(warnings) + 1L]] <<- cnd
          invokeRestart("muffleWarning")
        },
        message = function(cnd) {
          messages <<- c(messages, conditionMessage(cnd))
          invokeRestart("muffleMessage")
        }
      ),
      error = function(cnd) {
        error <<- cnd
        return(NULL)
      }
    )
  )
  return(list(
    value = value,
    error = error,
    warnings = warnings,
    messages = messages,
    output = output
  ))
}

# The classes of the warnings of a `psolve_capture()` result.
psolve_warning_classes <- function(captured) {
  return(unique(unlist(lapply(captured$warnings, class))))
}

# Replaces every given string by `<name>` (fixed), for comparing messages
# that name environments or channels.
psolve_mask <- function(text, ...) {
  masks <- list(...)
  for (name in names(masks)) {
    text <- gsub(masks[[name]], paste0("<", name, ">"), text, fixed = TRUE)
  }
  return(text)
}

# Classes that only micromamba's failures have: the status of its process
# (R-3). Each backend's failure has condathis's classes otherwise.
psolve_micromamba_only_classes <- c(
  "condathis_micromamba_status_error",
  "condathis_cmd_status_error"
)

# Asserts that two failures, of micromamba and of rattler, have the same
# condathis classes, apart from the micromamba-only classes (R-3), and that
# rattler's has the rattler error of `rattler_kind` in its parent chain.
psolve_expect_same_failure <- function(mm_error, rt_error, rattler_kind) {
  testthat::expect_s3_class(mm_error, "condathis_error")
  testthat::expect_s3_class(rt_error, "condathis_error")
  testthat::expect_identical(
    setdiff(class(mm_error), psolve_micromamba_only_classes),
    class(rt_error)
  )
  testthat::expect_true(
    rlang::cnd_inherits(rt_error, paste0("rattlerthis_rattler_", rattler_kind)),
    label = paste0("rattler's parent error is of kind ", rattler_kind)
  )
  return(invisible(NULL))
}

# --- Environments ---------------------------------------------------------------

# The packages of an environment as condathis lists them, with the columns
# that do not depend on the backend's root: name, version, build string,
# channel and platform, sorted by name.
psolve_packages <- function(env_name, method) {
  pkgs <- condathis::list_packages(env_name, method = method)
  out <- data.frame(
    name = as.character(pkgs$name),
    version = as.character(pkgs$version),
    build = as.character(pkgs$build_string),
    channel = as.character(pkgs$channel),
    platform = as.character(pkgs$platform),
    stringsAsFactors = FALSE
  )
  out <- out[order(out$name, method = "radix"), , drop = FALSE]
  rownames(out) <- NULL
  return(out)
}

# `"name version channel"` of every package of an environment, sorted by
# name, with the channel named by its test channel (`chA`) where it is one.
psolve_summary <- function(env_name, method) {
  pkgs <- psolve_packages(env_name, method = method)
  return(paste(pkgs$name, pkgs$version, psolve_channel_label(pkgs$channel)))
}

# The name of a test channel (`chA`, or a generated one, once generated)
# for its URL; other channels stay as they are.
psolve_channel_label <- function(channel) {
  dirs <- c(test_channels_dir(), psolve_state$channels_dir)
  label <- as.character(channel)
  for (dir in dirs) {
    prefix <- paste0(file_url(dir), "/")
    hit <- startsWith(label, prefix)
    label[hit] <- substring(label[hit], nchar(prefix) + 1L)
  }
  return(label)
}

# The directory of an environment of `method`.
psolve_env_dir <- function(env_name, method) {
  return(as.character(condathis::get_env_dir(env_name, method = method)))
}

# The revisions of `conda-meta/history`: a list with, per revision, the
# `+`/`-` lines (sorted: the order of unrelated packages differs, see
# test-parity-install-channels.R) and the `# update specs` and
# `# remove specs` lines. The header (a local time) and micromamba's
# `# cmd:` and `# conda version:` lines (R-18) are dropped.
psolve_history <- function(env_name, method) {
  lines <- read_history(psolve_env_dir(env_name, method))$lines
  starts <- grep("^==> .* <==$", lines)
  revisions <- lapply(seq_along(starts), function(i) {
    last <- if (i < length(starts)) starts[[i + 1L]] - 1L else length(lines)
    body <- lines[seq.int(starts[[i]] + 1L, length.out = last - starts[[i]])]
    changes <- sort(body[grepl("^[+-]", body)], method = "radix")
    specs <- body[grepl("^# (update|remove) specs: ", body)]
    return(c(changes, specs))
  })
  return(revisions)
}

# --- Generated channels -----------------------------------------------------------

# Run state of the generated channels.
psolve_state <- new.env(parent = emptyenv())

# The program files of the `python` packages. micromamba runs
# `<python> -q -m pip inspect --local` whenever an environment has python
# and pip (`PrefixData::load_site_packages()` of libmamba, for `list`,
# `install` and `env remove`), and fails when no program named python
# starts; an empty output means "nothing installed with pip". So the
# package has a program that starts and prints nothing on standard output:
# `bin/python`, a shell script, on Linux and macOS; on Windows, where
# libmamba looks for `python.exe` in the prefix, a copy of the system's
# `where.exe`, which prints nothing with `-q`. The channel is built on the
# machine that runs the tests, so each machine gets its own. rattler never
# runs it.
psolve_python_files <- function() {
  if (isTRUE(is_windows())) {
    system_root <- Sys.getenv("SystemRoot", unset = "C:/Windows")
    where_exe <- file.path(system_root, "System32", "where.exe")
    return(list(list(path = "python.exe", source = where_exe, mode = "644")))
  }
  return(list(list(
    path = "bin/python",
    text = "#!/bin/sh\nexit 0\n",
    mode = "755"
  )))
}

# The packages of the channels this helper generates, per channel: name,
# version, depends, the subdirs that have it, and program files.
#
# `pyc`: python 3.11.0 and 3.12.0 (with a program, see
#   `psolve_python_files()`), pip (libmamba requests pip with
#   python and, where a subdir has pip, makes pip a dependency of python
#   and python one of pip; rattler does the same), `needs312`
#   (python >=3.12), `lib` 1.0 and 2.0,
#   `libuser` 1.0 (lib) and 2.0 (lib >=2), `needslib2` (lib >=2, one
#   version) and `libold` (lib <2).
# `vpk`: `osxvp`, osx-64 only, depending on the virtual package
#   `__osx >=11`.
psolve_channel_specs <- function() {
  pkg <- function(
    name,
    version,
    depends = character(0L),
    subdirs = "noarch",
    files = list()
  ) {
    return(list(
      name = name,
      version = version,
      depends = depends,
      subdirs = subdirs,
      files = files
    ))
  }
  return(list(
    pyc = list(
      pkg("python", "3.11.0", files = psolve_python_files()),
      pkg("python", "3.12.0", files = psolve_python_files()),
      pkg("pip", "24.0"),
      pkg("needs312", "1.0", depends = "python >=3.12"),
      pkg("lib", "1.0"),
      pkg("lib", "2.0"),
      pkg("libuser", "1.0", depends = "lib"),
      pkg("libuser", "2.0", depends = "lib >=2"),
      pkg("needslib2", "1.0", depends = "lib >=2"),
      pkg("libold", "1.0", depends = "lib <2")
    ),
    vpk = list(
      pkg("osxvp", "1.0", depends = "__osx >=11", subdirs = "osx-64")
    )
  ))
}

# JSON text of an R list, without pretty printing; a list stays an array
# and a length-one vector becomes a scalar.
psolve_json <- function(x) {
  return(as.character(jsonlite::toJSON(x, auto_unbox = TRUE, digits = NA)))
}

# Writes `text` as UTF-8 bytes with `\n` line ends (also on Windows).
psolve_write_text <- function(text, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeBin(charToRaw(enc2utf8(text)), path)
  return(invisible(path))
}

# The sha256 of a file, or `NULL` where R has no `tools::sha256sum()`
# (before R 4.5): both backends then check the md5 only.
psolve_sha256 <- function(path) {
  tools_ns <- asNamespace("tools")
  if (isFALSE(exists("sha256sum", envir = tools_ns, inherits = FALSE))) {
    return(NULL)
  }
  sha256sum <- get("sha256sum", envir = tools_ns)
  return(unname(sha256sum(path)))
}

# Builds one package archive (`<name>-<version>-0.tar.bz2`) in
# `subdir_dir`: `info/index.json`, `info/paths.json`, `info/files`,
# `share/<name>/README` and the program files of `spec$files`, as
# tools/make-test-channels.py builds them, with R's own tar. Returns the
# file name and its repodata record.
psolve_build_package <- function(subdir_dir, spec, subdir) {
  stage <- tempfile(pattern = "rt-pkg-", tmpdir = dirname(subdir_dir))
  dir.create(file.path(stage, "info"), recursive = TRUE)
  readme <- paste0("share/", spec$name, "/README")
  psolve_write_text(
    paste0(spec$name, " ", spec$version, "\n"),
    file.path(stage, readme)
  )
  files <- readme
  for (extra in spec$files) {
    target <- file.path(stage, extra$path)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    if (is.null(extra$text)) {
      stopifnot(isTRUE(file.copy(extra$source, target)))
    } else {
      psolve_write_text(extra$text, target)
    }
    Sys.chmod(target, mode = extra$mode, use_umask = FALSE)
    files <- c(files, extra$path)
  }
  files <- sort(files, method = "radix")
  path_entries <- lapply(files, function(file) {
    entry <- list(
      `_path` = file,
      path_type = "hardlink",
      size_in_bytes = file.size(file.path(stage, file))
    )
    file_sha256 <- psolve_sha256(file.path(stage, file))
    if (isFALSE(is.null(file_sha256))) {
      entry$sha256 <- file_sha256
    }
    return(entry)
  })
  index <- list(
    build = "0",
    build_number = 0L,
    depends = as.list(spec$depends),
    license = "MIT",
    name = spec$name,
    subdir = subdir,
    timestamp = 1700000000000,
    version = spec$version
  )
  if (identical(subdir, "noarch")) {
    index$noarch <- "generic"
  }
  psolve_write_text(psolve_json(index), file.path(stage, "info", "index.json"))
  psolve_write_text(
    psolve_json(list(paths = path_entries, paths_version = 1L)),
    file.path(stage, "info", "paths.json")
  )
  psolve_write_text(
    paste0(paste(files, collapse = "\n"), "\n"),
    file.path(stage, "info", "files")
  )
  file_name <- paste0(spec$name, "-", spec$version, "-0.tar.bz2")
  archive <- file.path(normalizePath(subdir_dir, winslash = "/"), file_name)
  withr::with_dir(
    stage,
    utils::tar(
      archive,
      files = list.files(".", all.files = TRUE, no.. = TRUE),
      compression = "bzip2",
      tar = "internal"
    )
  )
  unlink(stage, recursive = TRUE, force = TRUE)
  record <- index
  record$md5 <- unname(tools::md5sum(archive))
  archive_sha256 <- psolve_sha256(archive)
  if (isFALSE(is.null(archive_sha256))) {
    record$sha256 <- archive_sha256
  }
  record$size <- file.size(archive)
  return(list(file_name = file_name, record = record))
}

# Writes the repodata.json of one subdir.
psolve_write_repodata <- function(subdir_dir, subdir, records) {
  packages <- if (identical(length(records), 0L)) {
    structure(list(), names = character(0L))
  } else {
    records
  }
  repodata <- list(
    info = list(subdir = subdir),
    packages = packages,
    packages.conda = structure(list(), names = character(0L)),
    repodata_version = 1L
  )
  psolve_write_text(
    psolve_json(repodata),
    file.path(subdir_dir, "repodata.json")
  )
  return(invisible(subdir_dir))
}

# The directory of the generated channels: built once per test process,
# next to the session copy of the test channels, with a repodata.json in
# every known subdir of condathis.
psolve_channels_dir <- function() {
  dir <- psolve_state$channels_dir
  if (isFALSE(is.null(dir)) && isTRUE(dir.exists(dir))) {
    return(dir)
  }
  parent_dir <- rt_test_state$sandbox$root %||% tempdir()
  dir <- file.path(parent_dir, "psolve-channels")
  unlink(dir, recursive = TRUE, force = TRUE)
  dir.create(dir, recursive = TRUE)
  specs <- psolve_channel_specs()
  for (channel in names(specs)) {
    channel_dir <- file.path(dir, channel)
    records <- list()
    for (spec in specs[[channel]]) {
      for (subdir in spec$subdirs) {
        subdir_dir <- file.path(channel_dir, subdir)
        dir.create(subdir_dir, recursive = TRUE, showWarnings = FALSE)
        built <- psolve_build_package(subdir_dir, spec, subdir)
        records[[subdir]][[built$file_name]] <- built$record
      }
    }
    for (subdir in names(records)) {
      psolve_write_repodata(
        file.path(channel_dir, subdir),
        subdir,
        records[[subdir]]
      )
    }
    fill_channel_subdirs(channel_dir)
  }
  dir <- normalizePath(dir, winslash = "/", mustWork = TRUE)
  psolve_state$channels_dir <- dir
  return(dir)
}

# The `file://` URL of a generated channel (`"pyc"` or `"vpk"`).
psolve_channel <- function(name) {
  stopifnot(isTRUE(name %in% names(psolve_channel_specs())))
  return(file_url(file.path(psolve_channels_dir(), name)))
}
