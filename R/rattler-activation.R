#' The cache of rattler activations
#'
#' One entry per environment directory (prefix): `list(stamp, base, env)`,
#' see `rattler_activation()`. Lives as long as the R session.
#'
#' @keywords internal
#' @noRd
rattler_activation_cache <- new.env(parent = emptyenv())

#' The activation of a rattler environment, cached per environment
#'
#' The variables that activating `prefix` changes in `base_env`: one
#' `rt_activation_env()` job, which starts an activation shell with
#' `base_env` as its whole environment and runs the environment's
#' `activate.d` scripts. condathis caches micromamba's activation per
#' environment (see `get_micromamba_activation_envvars()` in condathis), so
#' a slow `activate.d` script does not run for every command; this does
#' the same for rattler.
#'
#' A cached activation is used while three things are as they were when it
#' was cached:
#'
#' * the environment, by `rattler_activation_stamp()`: the files of
#'   `conda-meta` (an install, a removal, `conda-meta/state`) and the
#'   contents of the activation's own files (`etc/conda/activate.d`,
#'   `etc/conda/env_vars.d`);
#' * `base_env` after `rattler_activation_base()`, except `TMPDIR`, which
#'   condathis sets to a new directory for every command;
#' * the environment directory itself (the cache key).
#'
#' An activation whose variables name the `TMPDIR` of its call (an
#' `activate.d` script that exports a path below it) is not cached: that
#' directory is deleted when the command ends. The activation runs in the
#' working directory of the R session, so one whose variables name it (a
#' script that exports `$PWD`) is reused only from that working directory,
#' as condathis does for micromamba's (`activation_cache_rule()` in
#' condathis).
#'
#' The `PATH` of the activation is tidied as condathis tidies micromamba's
#' (see `rattler_tidy_path()`).
#'
#' @param prefix Character string, the environment directory.
#' @param base_env Named character vector, the environment of the command
#'   before activation, or `NULL` (direct calls: the R session's).
#' @param use_cache Logical. `FALSE` neither reads nor fills the cache.
#'   Defaults to `TRUE`.
#' @param timeout Numeric, the seconds the activation may take (see
#'   `rattler_await()`).
#'
#' @returns A named character vector of the variables the activation sets
#'   or changes, and `NA` for a variable it unsets (an `activate.d` script
#'   that runs `unset`): condathis then removes it from the command's
#'   environment, as it does for micromamba's activation.
#'
#' @keywords internal
#' @noRd
rattler_activation <- function(
  prefix,
  base_env,
  use_cache = TRUE,
  timeout = Inf
) {
  prefix <- as.character(prefix)
  start_env <- rattler_activation_base(base_env)
  call_tmp_dir <- rattler_env_value(start_env, "TMPDIR")
  cache_base <- start_env[rattler_env_names_other_than(start_env, "TMPDIR")]
  stamp <- NULL
  if (isTRUE(use_cache)) {
    stamp <- rattler_activation_stamp(prefix)
    cached <- get0(prefix, envir = rattler_activation_cache, inherits = FALSE)
    if (
      isFALSE(is.null(cached)) &&
        identical(cached$stamp, stamp) &&
        identical(cached$base, cache_base) &&
        (is.null(cached$wd) || identical(cached$wd, getwd()))
    ) {
      return(cached$env)
    }
  }
  changed <- rattler_await(
    function() {
      rt_activation_env(prefix, NULL, names(start_env), unname(start_env))
    },
    strategy = "silent",
    label = "The activation",
    timeout = timeout
  )
  activation_env <- vapply(changed, as.character, character(1L))
  activation_env <- rattler_tidy_path(activation_env)
  values <- activation_env[!is.na(activation_env)]
  if (
    isTRUE(use_cache) &&
      isFALSE(rattler_names_dir(values, call_tmp_dir))
  ) {
    wd <- getwd()
    wd_spellings <- unique(c(
      wd,
      tryCatch(normalizePath(wd, mustWork = FALSE), error = function(e) wd)
    ))
    wd_values <- rattler_activation_own_values(values, start_env, prefix)
    names_wd <- any(vapply(
      wd_spellings,
      function(dir) rattler_names_dir(wd_values, dir),
      logical(1L)
    ))
    assign(
      prefix,
      list(
        stamp = stamp,
        base = cache_base,
        wd = if (isTRUE(names_wd)) wd,
        env = activation_env
      ),
      envir = rattler_activation_cache
    )
  }
  return(activation_env)
}

#' The values of an activation that the activation itself added
#'
#' For the check of the working directory in `rattler_activation()`: the
#' entries of `PATH` that `base_env` already has, and the paths of the
#' environment and of condathis's root, are left out. They are in most
#' values, and the working directory is often a directory above them (the
#' home directory), which would bind every activation to it.
#'
#' @param values Named character vector, the activation without `NA`s.
#' @param start_env Named character vector, the environment the activation
#'   started from.
#' @param prefix Character string, the environment directory.
#'
#' @returns A character vector.
#'
#' @keywords internal
#' @noRd
rattler_activation_own_values <- function(values, start_env, prefix) {
  base_path <- rattler_env_value(start_env, "PATH")
  base_entries <- if (isTRUE(is.na(base_path))) {
    character(0L)
  } else {
    strsplit(base_path, .Platform$path.sep, fixed = TRUE)[[1L]]
  }
  path_names <- rattler_name_matches(names(values), "PATH")
  out <- unname(values[!path_names])
  for (path_value in values[path_names]) {
    entries <- strsplit(path_value, .Platform$path.sep, fixed = TRUE)[[1L]]
    out <- c(out, setdiff(entries, base_entries))
  }
  fixed_dirs <- c(prefix, fs::path_dir(rattler_root()))
  fixed_dirs <- unique(c(
    fixed_dirs,
    vapply(
      fixed_dirs,
      function(dir) {
        return(tryCatch(
          normalizePath(dir, mustWork = FALSE),
          error = function(e) dir
        ))
      },
      character(1L)
    )
  ))
  for (dir in sub("[/\\\\]+$", "", fixed_dirs)) {
    for (spelling in unique(c(
      dir,
      gsub("\\\\", "/", dir),
      gsub("/", "\\\\", dir)
    ))) {
      out <- gsub(spelling, "", out, fixed = TRUE)
    }
  }
  return(out)
}

#' Forget the cached activation of an environment
#'
#' Called by the create and install hooks, which change the environment.
#' `rattler_activation_stamp()` would see the change too; this also drops
#' the entries of environment directories that no longer exist.
#'
#' @param prefix Character string, the environment directory.
#'
#' @returns `NULL`, invisibly.
#'
#' @keywords internal
#' @noRd
rattler_forget_activation <- function(prefix) {
  keys <- ls(envir = rattler_activation_cache, all.names = TRUE)
  stale <- keys[!fs::dir_exists(keys)]
  drop <- intersect(c(as.character(prefix), stale), keys)
  if (isTRUE(length(drop) > 0L)) {
    rm(list = drop, envir = rattler_activation_cache)
  }
  return(invisible(NULL))
}

#' What an activation of an environment depends on, as a value
#'
#' The name, size and modification time of every file in `conda-meta`
#' (packages installed or removed, `history`, `state`), and the size and a
#' hash of the contents of every file in `etc/conda/activate.d` and
#' `etc/conda/env_vars.d`, which the activation reads. Two equal stamps mean
#' an unchanged environment for `rattler_activation()`. Only metadata is
#' read for `conda-meta`, which can hold many large records; the
#' activation's own files are small.
#'
#' @param prefix Character string, the environment directory.
#'
#' @returns A character vector.
#'
#' @keywords internal
#' @noRd
rattler_activation_stamp <- function(prefix) {
  meta <- rattler_dir_files(fs::path(prefix, "conda-meta"))
  meta_part <- if (isTRUE(length(meta) > 0L)) {
    info <- fs::file_info(meta)
    paste(
      "meta",
      fs::path_file(meta),
      as.numeric(info$size),
      # Seconds, not a formatted time: formatting a time sets `TZDIR` in
      # the session on macOS, which changes the next `base_env`.
      sprintf("%.9f", as.numeric(info$modification_time)),
      sep = "|"
    )
  }
  scripts <- c(
    rattler_dir_files(fs::path(prefix, "etc", "conda", "activate.d")),
    rattler_dir_files(fs::path(prefix, "etc", "conda", "env_vars.d"))
  )
  scripts_part <- if (isTRUE(length(scripts) > 0L)) {
    paste(
      "script",
      fs::path_rel(scripts, prefix),
      as.numeric(fs::file_size(scripts)),
      vapply(
        as.character(scripts),
        function(path) {
          tryCatch(rlang::hash_file(path), error = function(e) NA_character_)
        },
        character(1L)
      ),
      sep = "|"
    )
  }
  return(c(meta_part, scripts_part))
}

#' The files of a directory, sorted, or none
#'
#' Regular files and symbolic links (the activation runs a script that is a
#' link, and `rlang::hash_file()` reads its target).
#'
#' @param dir Character string, the directory.
#'
#' @returns A sorted character vector of paths; empty when `dir` does not
#'   exist.
#'
#' @keywords internal
#' @noRd
rattler_dir_files <- function(dir) {
  if (isFALSE(fs::dir_exists(dir))) {
    return(character(0L))
  }
  files <- fs::dir_ls(
    dir,
    type = c("file", "symlink"),
    recurse = FALSE,
    all = TRUE
  )
  return(sort(as.character(files), method = "radix"))
}

#' Tidy the `PATH` of an activation as condathis tidies micromamba's
#'
#' condathis puts the directories that micromamba's activation adds in
#' front of the session's `PATH` without empty entries and without
#' repeated ones (`compose_path()` in condathis), for `run()`, `run_bin()`
#' and `run_pipeline()`; so a session `PATH` that ends in a separator (an
#' empty last entry, common on Windows) loses it. rattler's activation
#' kept every entry of the session's `PATH`. Here the empty entries and the
#' repeated ones (the first is kept; compared as written, also on Windows)
#' are dropped from the activation's `PATH`, in the order the activation
#' gave, so the scripts of `activate.d` still decide the order.
#'
#' @param activation_env Named character vector, from the activation.
#'
#' @returns `activation_env`, with its `PATH` (any spelling on Windows)
#'   tidied; an unset `PATH` (`NA`) stays unset.
#'
#' @keywords internal
#' @noRd
rattler_tidy_path <- function(activation_env) {
  path_names <- names(activation_env)[
    rattler_name_matches(names(activation_env), "PATH")
  ]
  for (name in path_names) {
    if (isTRUE(is.na(activation_env[[name]]))) {
      next
    }
    entries <- strsplit(
      activation_env[[name]],
      .Platform$path.sep,
      fixed = TRUE
    )[[1L]]
    entries <- unique(entries[nzchar(entries)])
    activation_env[[name]] <- paste(entries, collapse = .Platform$path.sep)
  }
  return(activation_env)
}

#' Does any value name a directory?
#'
#' @param values Character vector.
#' @param dir Character string, or `NA`.
#'
#' @returns `TRUE` when `dir` is not `NA` or empty and some value contains
#'   it (also with the other kind of slash on Windows).
#'
#' @keywords internal
#' @noRd
rattler_names_dir <- function(values, dir) {
  if (isTRUE(is.na(dir)) || isFALSE(nzchar(dir))) {
    return(FALSE)
  }
  spellings <- unique(c(
    dir,
    gsub("\\", "/", dir, fixed = TRUE),
    gsub("/", "\\", dir, fixed = TRUE)
  ))
  found <- vapply(
    spellings,
    function(spelling) any(grepl(spelling, values, fixed = TRUE)),
    logical(1L)
  )
  return(isTRUE(any(found)))
}

#' Which names are a variable name, as the OS compares them
#'
#' @param env_names Character vector of variable names.
#' @param name Character string.
#'
#' @returns A logical vector: exact matches, and on Windows also matches
#'   without case.
#'
#' @keywords internal
#' @noRd
rattler_name_matches <- function(env_names, name) {
  if (isTRUE(is_windows())) {
    return(toupper(env_names) == toupper(name))
  }
  return(env_names == name)
}

#' The value of a variable in an environment block, or `NA`
#'
#' @param env Named character vector.
#' @param name Character string.
#'
#' @returns The value of the first matching name (without case on
#'   Windows), or `NA_character_`.
#'
#' @keywords internal
#' @noRd
rattler_env_value <- function(env, name) {
  hit <- which(rattler_name_matches(names(env), name))
  if (identical(length(hit), 0L)) {
    return(NA_character_)
  }
  return(unname(env[[hit[[1L]]]]))
}

#' The names of an environment block other than one variable
#'
#' @param env Named character vector.
#' @param name Character string.
#'
#' @returns Logical vector over `env`: `TRUE` for every other variable.
#'
#' @keywords internal
#' @noRd
rattler_env_names_other_than <- function(env, name) {
  return(!rattler_name_matches(names(env), name))
}
