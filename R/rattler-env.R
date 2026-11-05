#' The name of this backend in condathis
#'
#' The value users pass as `method` to condathis's functions.
#'
#' @keywords internal
#' @noRd
rattler_backend_name <- "rattler"

#' The verbose levels condathis passes to backend functions
#'
#' @keywords internal
#' @noRd
rattler_verbose_values <- c("output", "silent", "cmd", "spinner", "full")

#' The root of the rattler backend
#'
#' `<condathis root>/rattler`, from `condathis::backend_root_dir()`. It is
#' computed on every call, so it follows `condathis::with_sandbox_dir()`,
#' and it is never created here: queries must not create it.
#'
#' @returns An `fs_path`, absolute.
#'
#' @keywords internal
#' @noRd
rattler_root <- function() {
  return(condathis::backend_root_dir(rattler_backend_name))
}

#' The directory (prefix) of a rattler environment
#'
#' The directory that condathis's default `backend_get_env_dir()` gives for
#' this backend: `<root>/envs/<env_name>`.
#'
#' @param env_name Character string with the environment name.
#'
#' @returns An `fs_path`. Nothing is created.
#'
#' @keywords internal
#' @noRd
rattler_env_dir <- function(env_name) {
  return(fs::path(rattler_root(), "envs", env_name))
}

#' Is a directory a conda environment?
#'
#' The rule of condathis's default listing: a directory with
#' `conda-meta/history`.
#'
#' @param env_dir Character string, the directory.
#'
#' @returns `TRUE` or `FALSE`.
#'
#' @keywords internal
#' @noRd
rattler_is_env_dir <- function(env_dir) {
  return(isTRUE(fs::file_exists(fs::path(env_dir, "conda-meta", "history"))))
}

#' The network root of the rattler backend
#'
#' condathis's root, the parent of `rattler_root()`: micromamba's root
#' prefix, whose `ssl/cert.pem` (`Library/ssl/cacert.pem` on Windows)
#' micromamba trusts instead of the system's CA bundle when it exists. The
#' jobs that download get it, so rattler trusts the same certificates (see
#' `rt_install()`).
#'
#' @returns A character string. Nothing is created.
#'
#' @keywords internal
#' @noRd
rattler_net_root <- function() {
  return(as.character(fs::path_dir(rattler_root())))
}

#' The package and repodata caches of the rattler backend
#'
#' `<root>/pkgs` (extracted packages) and `<root>/repodata_cache` (channel
#' metadata). condathis owns `<root>/conda-pkgs`, the package cache of the
#' Conda tools that run inside rattler environments, so it is not used
#' here.
#'
#' @param create Logical. `TRUE` creates both directories, for a call that
#'   downloads. Defaults to `FALSE`.
#'
#' @returns A list with the `fs_path` elements `pkgs` and `repodata`.
#'
#' @keywords internal
#' @noRd
rattler_cache_dirs <- function(create = FALSE) {
  root <- rattler_root()
  dirs <- list(
    pkgs = fs::path(root, "pkgs"),
    repodata = fs::path(root, "repodata_cache")
  )
  if (isTRUE(create)) {
    fs::dir_create(unlist(dirs, use.names = FALSE))
  }
  return(dirs)
}

#' The cache directory of the tools a rattler create runs
#'
#' `<root>/cache`, the `XDG_CACHE_HOME` of the pip steps of a create (see
#' `rattler_pip_base_env()`), as condathis gives micromamba, and so its pip,
#' `<micromamba root>/cache`. pip keeps its cache in `pip` below it on
#' Linux (on macOS and Windows pip does not read `XDG_CACHE_HOME`, with
#' either backend). `backend_clean_cache()` deletes it.
#'
#' @returns An `fs_path`. Nothing is created.
#'
#' @keywords internal
#' @noRd
rattler_tool_cache_dir <- function() {
  return(fs::path(rattler_root(), "cache"))
}

#' Is R running on Windows?
#'
#' @keywords internal
#' @noRd
is_windows <- function() {
  return(identical(.Platform$OS.type, "windows"))
}

#' The verbose level of a backend call
#'
#' condathis passes exactly one of `rattler_verbose_values`. A direct call
#' that leaves `verbose` at the default vector of the signature gets its
#' first element, as `rlang::arg_match()` does; `TRUE` and `FALSE` are read
#' as condathis reads them.
#'
#' @param verbose The `verbose` argument of a backend function.
#'
#' @returns One of `rattler_verbose_values`.
#'
#' @keywords internal
#' @noRd
rattler_strategy <- function(verbose) {
  if (isTRUE(verbose)) {
    return("output")
  }
  if (isFALSE(verbose)) {
    return("silent")
  }
  return(rlang::arg_match0(
    verbose[[1L]],
    values = rattler_verbose_values,
    arg_nm = "verbose"
  ))
}

#' Show a spinner while a job runs?
#'
#' As condathis's own `spinner_flag`: in an interactive session, at every
#' level but `"silent"`.
#'
#' @param strategy One of `rattler_verbose_values`.
#'
#' @returns `TRUE` or `FALSE`.
#'
#' @keywords internal
#' @noRd
rattler_shows_spinner <- function(strategy) {
  return(
    isTRUE(rlang::is_interactive()) && isFALSE(identical(strategy, "silent"))
  )
}

#' Print the one-line description of a rattler request
#'
#' The analog of the command line that micromamba echoes at the levels
#' `"cmd"` and `"full"`: `Running rattler <words>`. It goes to standard
#' output with `cat()`, as condathis echoes micromamba's command line, so
#' `suppressMessages()` hides neither. The password and the token of a
#' channel URL are shown as `*****`, as condathis shows them in
#' micromamba's (see `rattler_hide_secrets()`).
#'
#' @param strategy One of `rattler_verbose_values`.
#' @param words Character vector, the words after `rattler`.
#'
#' @returns `NULL`, invisibly.
#'
#' @keywords internal
#' @noRd
rattler_print_request <- function(strategy, words) {
  if (isFALSE(strategy %in% c("cmd", "full"))) {
    return(invisible(NULL))
  }
  words <- rattler_hide_secrets(words)
  quote <- grepl("[[:space:]\"']", words) | !nzchar(words)
  words[quote] <- shQuote(words[quote], type = "cmd")
  cat(paste(c("Running", "rattler", words), collapse = " "), "\n", sep = "")
  return(invisible(NULL))
}

#' Hide the credentials of URLs in text
#'
#' `rt_hide_secrets()`, the rule of rattlerthis's error messages, which is
#' also condathis's: every `/t/<token>` becomes `/t/*****`, and the
#' password of every `<scheme>://user:password@` becomes `*****`. `NA`
#' stays `NA`. Text that is not valid UTF-8 is kept as it is.
#'
#' @param x Character vector.
#'
#' @returns Character vector.
#'
#' @keywords internal
#' @noRd
rattler_hide_secrets <- function(x) {
  x <- enc2utf8(as.character(x))
  todo <- !is.na(x) & validUTF8(x)
  if (isTRUE(any(todo))) {
    x[todo] <- rt_hide_secrets(x[todo])
  }
  return(x)
}

#' The words that describe a create or install
#'
#' @param action `"create"` or `"install"`.
#' @param env_name Character string with the environment name.
#' @param request The request, from `rattler_env_file_request()` or
#'   `rattler_specs_request()`.
#' @param platform `NULL`, or the platform to solve for.
#' @param channel_priority `"strict"`, `"flexible"` or `"disabled"`. Only a
#'   priority other than `"strict"` is shown.
#'
#' @returns Character vector, for `rattler_print_request()`.
#'
#' @keywords internal
#' @noRd
rattler_request_words <- function(
  action,
  env_name,
  request,
  platform,
  channel_priority = "strict"
) {
  words <- c(action, env_name)
  if (isFALSE(is.null(request$env_file))) {
    words <- c(words, "-f", as.character(request$env_file))
  }
  if (isFALSE(is.null(request$channels))) {
    words <- c(words, as.vector(rbind("-c", request$channels)))
    if (isFALSE(identical(channel_priority, "strict"))) {
      words <- c(words, "--channel-priority", channel_priority)
    }
  }
  if (isFALSE(is.null(platform))) {
    words <- c(words, "--platform", platform)
  }
  if (is.null(request$env_file)) {
    words <- c(words, request$specs)
  }
  return(words)
}

#' The transaction of a rattler job as text lines
#'
#' One line per record: `+ name version build channel/subdir` for a
#' package that was installed, and `-` for one that was removed, in the
#' order of the transaction (removals first). These lines are the `stdout`
#' of the result, and what the level `"full"` prints.
#'
#' @param records The `records` data frame of a job result.
#'
#' @returns Character vector, possibly empty.
#'
#' @keywords internal
#' @noRd
rattler_transaction_lines <- function(records) {
  if (
    isFALSE(is.data.frame(records)) ||
      identical(nrow(records), 0L)
  ) {
    return(character(0L))
  }
  return(paste(
    records[["op"]],
    records[["name"]],
    records[["version"]],
    records[["build"]],
    paste0(records[["channel"]], "/", records[["subdir"]])
  ))
}

#' The result list of a create or an install
#'
#' What condathis reads from a mutation (see *Results* in
#' `?condathis::register_backend`): the status, the transaction lines as
#' `stdout`, and the link scripts that rattler did not run. There is no
#' command line, so `cmd`, `stderr` and `pid` are left out (condathis
#' reports them as `NA`). At the level `"full"`, the transaction lines are
#' printed to standard output.
#'
#' @param job_result The result of an `rt_install()` or
#'   `rt_install_explicit()` job.
#' @param strategy One of `rattler_verbose_values`.
#'
#' @returns `list(status = 0L, stdout, link_scripts_skipped)`.
#'
#' @keywords internal
#' @noRd
rattler_mutation_result <- function(job_result, strategy) {
  lines <- rattler_transaction_lines(job_result[["records"]])
  if (identical(strategy, "full") && isTRUE(length(lines) > 0L)) {
    cat(lines, sep = "\n")
  }
  stdout <- if (isTRUE(length(lines) > 0L)) {
    paste0(paste(lines, collapse = "\n"), "\n")
  } else {
    ""
  }
  return(list(
    status = 0L,
    stdout = stdout,
    link_scripts_skipped = rattler_link_scripts(
      job_result[["link_scripts_skipped"]]
    )
  ))
}

#' The link scripts that a job did not run, for condathis
#'
#' @param value The `link_scripts_skipped` element of a job result.
#'
#' @returns A data frame with the character columns `package` and
#'   `script`, possibly with zero rows.
#'
#' @keywords internal
#' @noRd
rattler_link_scripts <- function(value) {
  if (isFALSE(is.data.frame(value))) {
    return(data.frame(
      package = character(0L),
      script = character(0L),
      stringsAsFactors = FALSE
    ))
  }
  return(data.frame(
    package = as.character(value[["package"]]),
    script = as.character(value[["script"]]),
    stringsAsFactors = FALSE
  ))
}

#' A request from package specs
#'
#' @param packages Character vector of match specs, or `NULL`.
#' @param channels,additional_channels The channels condathis passed.
#'
#' @returns A list with `kind = "specs"`, `specs` and `channels`: the
#'   command-line channels first, then the additional ones, as micromamba
#'   gets them.
#'
#' @keywords internal
#' @noRd
rattler_specs_request <- function(packages, channels, additional_channels) {
  return(list(
    kind = "specs",
    specs = as.character(packages %||% character(0L)),
    channels = as.character(c(channels, additional_channels))
  ))
}

#' A request from an environment file
#'
#' Reads the file as `micromamba create -f` does (`rt_read_env_file()`,
#' which decides the kind by the file name) and builds what the create
#' needs:
#'
#' * `"yaml"`: the specs of the file, solved against the command-line
#'   channels, then the additional ones, then the channels of the file
#'   (micromamba puts the command-line channels first). Variables in the
#'   file's channels were expanded by `rt_read_env_file()`. Its
#'   `variables` are not used (see `rattler_report_env_variables()`).
#' * `"plain"`: one spec per line, solved against the command-line
#'   channels.
#' * `"explicit"`, `"conda_lock"` and `"mambajs_lock"`: the package URLs,
#'   installed without a solve; command-line channels are ignored, as
#'   micromamba ignores them. A lock file gives the packages of `platform`.
#'
#' The pip steps micromamba runs after the create (YAML `pip:` sections,
#' the pip packages of a lock file) are kept as `pip`, a list of
#' `list(manager, specs, cwd)` (see `rt_read_env_file()`), which the create
#' runs after the Conda packages are linked (see `rattler_run_pip_steps()`);
#' a `pip:` section also adds `pip` to the specs, as micromamba adds it.
#'
#' @param env_file Character string, the path of an existing file.
#' @param channels,additional_channels The channels condathis passed.
#' @param platform `NULL`, or the platform to build for.
#' @param call Environment reported as the caller of errors.
#'
#' @returns A list with `kind`, `env_file`, and `specs` and `channels`
#'   (YAML and plain files) or `urls` and `lock_file` (explicit and lock
#'   files), plus `variables` (a named character vector) and `pip`.
#'
#' @keywords internal
#' @noRd
rattler_env_file_request <- function(
  env_file,
  channels,
  additional_channels,
  platform,
  call = rlang::caller_env()
) {
  env_file <- as.character(env_file)
  file_spec <- rattler_call(
    rt_read_env_file(env_file, platform),
    call = call
  )
  kind <- file_spec[["kind"]]
  request <- list(
    kind = kind,
    env_file = env_file,
    variables = file_spec[["variables"]],
    pip = file_spec[["pip"]]
  )
  if (identical(kind, "yaml")) {
    request$specs <- as.character(file_spec[["specs"]])
    request$channels <- as.character(c(
      channels,
      additional_channels,
      file_spec[["channels"]]
    ))
    return(request)
  }
  if (identical(kind, "plain")) {
    request$specs <- as.character(file_spec[["specs"]])
    request$channels <- as.character(c(channels, additional_channels))
    return(request)
  }
  request$urls <- as.character(file_spec[["urls"]])
  request$lock_file <- isTRUE(kind %in% c("conda_lock", "mambajs_lock"))
  return(request)
}

#' Start the job that installs a request into a prefix
#'
#' @param request From `rattler_specs_request()` or
#'   `rattler_env_file_request()`.
#' @param prefix Character string, the environment directory.
#' @param channel_priority `"strict"`, `"flexible"` or `"disabled"`.
#' @param platform `NULL`, or the platform to solve for.
#' @param cache_dirs From `rattler_cache_dirs()`.
#'
#' @returns The job.
#'
#' @keywords internal
#' @noRd
rattler_start_install <- function(
  request,
  prefix,
  channel_priority,
  platform,
  cache_dirs
) {
  if (isFALSE(is.null(request$urls))) {
    return(rt_install_explicit(
      request$urls,
      as.character(prefix),
      platform,
      as.character(cache_dirs$pkgs),
      lock_file = isTRUE(request$lock_file),
      net_root = rattler_net_root()
    ))
  }
  return(rt_install(
    request$specs,
    as.character(prefix),
    request$channels,
    channel_priority,
    platform,
    as.character(cache_dirs$repodata),
    as.character(cache_dirs$pkgs),
    net_root = rattler_net_root()
  ))
}

#' Report the variables of an environment file that are not used
#'
#' condathis runs micromamba with `--no-env`, so micromamba does not use the
#' `variables:` of a YAML file: it writes no `conda-meta/state`, and says
#' so in its log ("Variables from yaml file are not considered"), which
#' condathis shows at the level `"full"`. rattler does the same, so both
#' backends give the same environment, and says it at `"full"` too, on
#' standard output.
#'
#' @param strategy One of `rattler_verbose_values`.
#' @param variables Named character vector, or `NULL`.
#'
#' @returns `NULL`, invisibly.
#'
#' @keywords internal
#' @noRd
rattler_report_env_variables <- function(strategy, variables) {
  if (identical(strategy, "full") && isTRUE(length(variables) > 0L)) {
    cat(
      "Variables of the environment file are not used: ",
      paste(names(variables), collapse = ", "),
      ".\n",
      sep = ""
    )
  }
  return(invisible(NULL))
}

#' The environment that a rattler activation starts from
#'
#' condathis's `base_env`, the environment of the command before
#' activation, without `CONDA_PREFIX`: condathis sets it to `""`, and
#' rattler would then treat `""` as an active environment to deactivate
#' and write `CONDA_ENV_SHLVL_*` backups. On Windows, every spelling of the
#' name is dropped. Without `base_env` (only from direct calls), the R
#' session's environment is used.
#'
#' @param base_env Named character vector, or `NULL`.
#'
#' @returns A named character vector.
#'
#' @keywords internal
#' @noRd
rattler_activation_base <- function(base_env) {
  if (is.null(base_env)) {
    base_env <- Sys.getenv()
  }
  env_names <- names(base_env)
  values <- as.character(base_env)
  names(values) <- env_names
  drop <- if (isTRUE(is_windows())) {
    toupper(env_names) == "CONDA_PREFIX"
  } else {
    env_names == "CONDA_PREFIX"
  }
  drop <- drop | is.na(env_names) | !nzchar(env_names %|na|% "")
  return(values[!drop])
}

#' Replace `NA` values
#'
#' @keywords internal
#' @noRd
`%|na|%` <- function(x, y) {
  x[is.na(x)] <- y
  return(x)
}
