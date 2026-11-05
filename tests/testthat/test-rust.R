# The Rust entry points, called directly, where condathis cannot show the
# behavior: job control, channel normalization, reading environment files,
# and the bytes of `conda-meta/history`. Every job
# runs through `rattler_await()`, as the backend's hooks run them, so its
# errors have their classes. Prefixes live in temporary directories, not in
# the rattler root, so condathis never lists them.

# A new prefix path (not created) and the rattler caches of the process
# sandbox.
local_rust_prefix <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(pattern = "rt-rust-", .local_envir = env)
  return(file.path(normalizePath(dir, winslash = "/"), "prefix"))
}

rust_install <- function(specs, prefix, channels, platform = NULL) {
  cache_dirs <- rattler_cache_dirs(create = TRUE)
  return(rattler_await(function() {
    rt_install(
      specs,
      prefix,
      channels,
      "strict",
      platform,
      as.character(cache_dirs$repodata),
      as.character(cache_dirs$pkgs)
    )
  }))
}

rust_install_explicit <- function(urls, prefix, lock_file = FALSE) {
  cache_dirs <- rattler_cache_dirs(create = TRUE)
  return(rattler_await(function() {
    rt_install_explicit(
      urls,
      prefix,
      NULL,
      as.character(cache_dirs$pkgs),
      lock_file = lock_file
    )
  }))
}

# Polls a job until it is done, at most `timeout` seconds; returns the
# result, or the error condition.
poll_until_done <- function(job, timeout = 30) {
  started <- Sys.time()
  repeat {
    value <- tryCatch(rt_job_poll(job), error = function(e) e)
    if (isFALSE(is.null(value))) {
      return(value)
    }
    if (as.numeric(difftime(Sys.time(), started, units = "secs")) > timeout) {
      stop("The job did not finish in time.")
    }
    Sys.sleep(0.01)
  }
}

history_header_pattern <- "^==> [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} <==$"

# --- Jobs -----------------------------------------------------------------------

test_that("a job reports its phase, its result, and stops on cancel", {
  live_before <- rt_live_jobs()
  job <- rt_test_job_sleep(30)
  expect_identical(rt_job_phase(job), "sleep")
  expect_null(rt_job_poll(job))
  expect_identical(rt_live_jobs(), live_before + 1L)
  # TRUE: it stopped without completing.
  expect_true(rt_job_cancel(job))
  result <- poll_until_done(job, timeout = 10)
  expect_s3_class(result, "error")
  expect_match(
    conditionMessage(result),
    "^\\[rattlerthis:cancelled\\] ",
    perl = TRUE
  )
  expect_identical(rt_job_phase(job), "done")
  expect_identical(rt_live_jobs(), live_before)
  # A done job keeps its result, and a second cancel changes nothing.
  expect_true(rt_job_cancel(job))
  expect_identical(
    conditionMessage(tryCatch(rt_job_poll(job), error = function(e) e)),
    conditionMessage(result)
  )

  job <- rt_test_job_sleep(0.05)
  expect_true(poll_until_done(job))
  # FALSE: it had completed.
  expect_false(rt_job_cancel(job))
  expect_true(rt_job_poll(job))
  expect_identical(rt_job_phase(job), "done")
})

test_that("a job that R no longer references is cancelled", {
  live_before <- rt_live_jobs()
  local({
    job <- rt_test_job_sleep(30)
    expect_identical(rt_live_jobs(), live_before + 1L)
  })
  invisible(gc(full = TRUE))
  started <- Sys.time()
  while (
    isTRUE(rt_live_jobs() > live_before) &&
      as.numeric(difftime(Sys.time(), started, units = "secs")) < 15
  ) {
    Sys.sleep(0.02)
  }
  expect_identical(rt_live_jobs(), live_before)
})

test_that("this build has no wheel support, and knows its platform", {
  # The two wheel tests skip because of this (the `wheels` Cargo feature
  # is off by default).
  expect_false(rt_has_wheel_support())
  expect_identical(rt_native_platform(), r_build_platform())
})

test_that("rt_hide_secrets() hides credentials with condathis's rule", {
  # One rule for both packages: what rattlerthis says (its errors, its
  # request line) and what condathis says and returns read the same.
  cases <- c(
    "HTTP status 404 Not Found for http://h:1/t/SECRETTOK/chA/noarch/foo-1.0-0.tar.bz2",
    "failed (http://rt-user:rt-pw@127.0.0.1:1/chA/x) and https://a:b@c",
    "http://u:p@h/t/ab/c http://h/t/x/y",
    "https://u:p@ss@h/c",
    "'https://u:p@h/c'",
    "{\"a\":\"https://u:p@h/c\",\"b\":\"https://v:q@h2/c\"}",
    "https://u:p@h/x:y@z",
    "https://h/t/ab_cd/c",
    "https://h/t/a_/c",
    "http://u:*****@h/t/*****/c",
    "http://h/t/********/c",
    "http://u:p@[::1]:8/c",
    "\033[34mhttps://u:p@h\033[39m",
    "caf\u00e9 https://u:p\u00e9@h/t/tk-1/c",
    "no url here",
    "user@host: denied",
    "https://user@host/c",
    "a://b",
    "https://host/t/",
    "https://host/t/x",
    NA
  )
  expect_identical(rt_hide_secrets(cases), condathis:::hide_secrets(cases))
  expect_identical(
    rt_hide_secrets(c("http://u:p@h/t/tk-1/c", NA)),
    c("http://u:*****@h/t/*****/c", NA)
  )
  expect_identical(rt_hide_secrets(character(0L)), character(0L))
})

# --- Channels -------------------------------------------------------------------

test_that("rt_effective_channels() resolves channels as micromamba does", {
  forge <- "https://conda.anaconda.org/conda-forge"
  anaconda <- "https://repo.anaconda.com/pkgs/"
  expect_identical(rt_effective_channels("conda-forge", character(0L)), forge)
  # `defaults` is repo.anaconda.com (msys2 too on Windows), not
  # conda.anaconda.org/defaults; `nodefaults` is dropped.
  defaults <- paste0(anaconda, c("main", "r"))
  if (isTRUE(is_windows())) {
    defaults <- c(defaults, paste0(anaconda, "msys2"))
  }
  expect_identical(rt_effective_channels("defaults", character(0L)), defaults)
  expect_identical(
    rt_effective_channels(c("conda-forge", "nodefaults"), character(0L)),
    forge
  )
  msys2 <- if (isTRUE(is_windows())) {
    paste0(anaconda, "msys2")
  } else {
    "https://conda.anaconda.org/pkgs/msys2"
  }
  expect_identical(
    rt_effective_channels(
      c("pkgs/main", "pkgs/r/", "pkgs/pro", "pkgs/msys2"),
      character(0L)
    ),
    c(paste0(anaconda, c("main", "r", "pro")), msys2)
  )
  # Each channel once, without a trailing slash, in the order given; the
  # channels of channel-qualified specs follow.
  expect_identical(
    rt_effective_channels(
      c("conda-forge", "conda-forge/", paste0(forge, "/")),
      c("bioconda::samtools", "conda-forge::xz", "xz")
    ),
    c(forge, "https://conda.anaconda.org/bioconda")
  )
  expect_identical(
    rt_effective_channels(c("bioconda", "conda-forge"), character(0L)),
    c("https://conda.anaconda.org/bioconda", forge)
  )
  # A `defaults::` spec adds the channels of `defaults`.
  expect_identical(
    rt_effective_channels("conda-forge", "defaults::xz"),
    c(
      forge,
      paste0(anaconda, c("main", "r")),
      if (isTRUE(is_windows())) {
        paste0(anaconda, "msys2")
      }
    )
  )
  # Local channels keep their URL.
  expect_identical(
    rt_effective_channels(
      channel_url("chA"),
      paste0(channel_url("chB"), "::bar")
    ),
    c(channel_url("chA"), channel_url("chB"))
  )
  expect_rattler_error(
    rattler_call(rt_effective_channels(character(0L), "foo[[")),
    kind = "invalid_spec"
  )
  expect_rattler_error(
    rattler_call(rt_effective_channels("bad channel://x y", character(0L))),
    kind = "invalid_channel"
  )
})

# --- Environment files ----------------------------------------------------------

test_that("rt_read_env_file() reads YAML files as micromamba create -f does", {
  read <- function(name, platform = NULL) {
    return(rattler_call(rt_read_env_file(envfile_fixture(name), platform)))
  }
  fields <- c(
    "kind",
    "name",
    "channels",
    "specs",
    "variables",
    "file_platform",
    "urls",
    "platforms",
    "problems",
    "pip"
  )

  e1 <- read("e1.yml")
  expect_identical(names(e1), fields)
  expect_identical(e1$kind, "yaml")
  # `name:` is read, and condathis never uses it.
  expect_identical(e1$name, "other")
  expect_identical(e1$channels, channel_url("chB"))
  expect_identical(e1$specs, "foo")
  expect_identical(e1$variables, stats::setNames(character(0L), character(0L)))
  expect_identical(e1$file_platform, NA_character_)
  expect_identical(e1$urls, character(0L))
  expect_identical(e1$problems, character(0L))

  # `nodefaults` stays in the list; the install drops it.
  expect_identical(read("e2.yml")$channels, c(channel_url("chB"), "nodefaults"))

  # Selectors follow this machine, as micromamba's follow its own, also
  # with another platform.
  e3_specs <- if (isTRUE(is_windows())) {
    "baz"
  } else if (isTRUE(is_macos())) {
    c("devtool", "baz")
  } else {
    c("foo", "baz")
  }
  expect_identical(read("e3.yml")$specs, e3_specs)
  expect_identical(read("e3.yml", platform = "win-64")$specs, e3_specs)
  expect_identical(
    read("e3.yml")$channels,
    c(channel_url("chA"), channel_url("chC"), channel_url("chD"))
  )

  # Variables: names as written, sorted, values as written ("1.50" stays,
  # an empty value is "null").
  expect_identical(
    read("e4.yml")$variables,
    c(EMPTY = "null", MY_VAR = "hello", NUM = "1.50", lower_var = "x")
  )

  # `${VAR}` in a channel is expanded from the environment; an unset
  # variable is left as written.
  withr::with_envvar(c(ENVFILE_CHANNEL_DIR = NA), {
    expect_identical(
      read("e12-envvar.yml")$channels,
      "${ENVFILE_CHANNEL_DIR}/chC"
    )
  })
  withr::with_envvar(c(ENVFILE_CHANNEL_DIR = channel_url()), {
    expect_identical(read("e12-envvar.yml")$channels, channel_url("chC"))
  })
})

test_that("rt_read_env_file() reads text and lock files as micromamba create -f does", {
  read <- function(name, platform = NULL) {
    return(rattler_call(rt_read_env_file(envfile_fixture(name), platform)))
  }
  # A plain spec list: blank and comment lines are dropped, specs are kept
  # as read (the install cleans them as micromamba's parser does).
  e5 <- read("e5.txt")
  expect_identical(e5$kind, "plain")
  expect_identical(e5$specs, c("foo", "baz  # trailing comment"))
  expect_identical(e5$urls, character(0L))

  # An explicit file: the URL lines with their hash fragments, and the
  # platform of its header.
  e6 <- read("e6.txt")
  expect_identical(e6$kind, "explicit")
  expect_identical(e6$specs, character(0L))
  expect_identical(e6$file_platform, "linux-64")
  expect_identical(
    e6$urls,
    c(
      paste0(
        channel_url("chA"),
        "/noarch/foo-1.0-0.tar.bz2#",
        channel_record("chA/noarch/foo-1.0-0.tar.bz2")$md5
      ),
      paste0(
        channel_url("chC"),
        "/noarch/baz-1.0-0.tar.bz2#sha256:",
        channel_record("chC/noarch/baz-1.0-0.tar.bz2")$sha256
      )
    )
  )

  # A conda-lock file: the main conda packages of the platform, as
  # `url#<sha256>`; the platforms of the lock; a note for a platform
  # without packages.
  lock_url <- function(archive) {
    return(paste0(
      channel_url(),
      "/",
      archive,
      "#",
      channel_record(archive)$sha256
    ))
  }
  e7 <- read("e7-lock.yml", platform = "linux-64")
  expect_identical(e7$kind, "conda_lock")
  expect_identical(
    e7$urls,
    c(
      lock_url("chA/noarch/foo-1.0-0.tar.bz2"),
      lock_url("chC/noarch/baz-1.0-0.tar.bz2")
    )
  )
  expect_identical(
    e7$platforms,
    c("linux-64", "linux-aarch64", "osx-64", "osx-arm64", "win-64", "win-arm64")
  )
  expect_identical(e7$problems, character(0L))
  expect_identical(
    read("e7-lock.yml", platform = "osx-arm64")$urls,
    lock_url("chC/noarch/baz-1.0-0.tar.bz2")
  )
  e7_none <- read("e7-lock.yml", platform = "linux-32")
  expect_identical(e7_none$urls, character(0L))
  expect_identical(
    e7_none$problems,
    "the lock file has no conda packages of category main for linux-32"
  )
  # Without a platform, the lock gives the packages of this build's.
  expect_identical(
    read("e7-lock.yml")$urls,
    read("e7-lock.yml", platform = r_build_platform())$urls
  )
})

test_that("rt_read_env_file() gives the pip steps and reads mambajs files", {
  read <- function(path, platform = NULL) {
    return(rattler_call(rt_read_env_file(path, platform)))
  }
  # A pip section: one step, run in the file's directory, with `pip` added
  # to the specs, as micromamba does.
  e8_path <- envfile_fixture("e8-pip.yml")
  e8 <- read(e8_path)
  expect_identical(e8$kind, "yaml")
  expect_identical(e8$specs, c("foo", "pip"))
  expect_length(e8$pip, 1L)
  expect_identical(e8$pip[[1L]]$manager, "pip")
  expect_identical(e8$pip[[1L]]$specs, "six==1.16.0")
  expect_identical(
    normalizePath(e8$pip[[1L]]$cwd),
    normalizePath(dirname(e8_path))
  )
  # The pip packages of a lock file for the platform: one step without
  # dependencies, `<name> @ <url>#sha256=<sha256>`.
  e9 <- read(envfile_fixture("e9-pip-lock.yml"), platform = "linux-64")
  expect_identical(e9$kind, "conda_lock")
  expect_length(e9$urls, 1L)
  expect_identical(e9$pip[[1L]]$manager, "pip --no-deps")
  expect_identical(
    e9$pip[[1L]]$specs,
    paste0(
      "six @ https://files.pythonhosted.org/packages/d9/5a/",
      "e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/",
      "six-1.16.0-py2.py3-none-any.whl#sha256=",
      "8abb2f1d86890a2dfb989f9a77cfcfd3e47c2a354b01111771326f8aa26e0254"
    )
  )
  # A mambajs lock file: its packages at the channelInfo URL, no pip step.
  e10 <- read(envfile_fixture("e10-mambajs.json"))
  expect_identical(e10$kind, "mambajs_lock")
  expect_identical(e10$platforms, "linux-64")
  expect_identical(
    e10$urls,
    paste0(
      channel_url("chC"),
      "/noarch/baz-1.0-0.tar.bz2#",
      channel_record("chC/noarch/baz-1.0-0.tar.bz2")$sha256
    )
  )
  expect_identical(e10$pip, list())
  # Other files have no pip step.
  expect_identical(read(envfile_fixture("e1.yml"))$pip, list())
  missing_file <- file.path(withr::local_tempdir(), "missing.yml")
  expect_rattler_error(read(missing_file), kind = "env_file")
  empty_file <- file.path(withr::local_tempdir(), "empty.txt")
  file.create(empty_file)
  expect_rattler_error(read(empty_file), kind = "env_file")
  expect_rattler_error(
    read(envfile_fixture("e7-lock.yml"), platform = "bogus-64"),
    kind = "invalid_platform"
  )
})

# --- History and state ----------------------------------------------------------

test_that("conda-meta/history has micromamba's lines, without # cmd and # conda version", {
  prefix <- local_rust_prefix()
  result <- rust_install("foo", prefix, channel_url("chA"))
  expect_identical(
    names(result),
    c("prefix", "records", "channels", "link_scripts_skipped")
  )
  expect_identical(result$channels, channel_url("chA"))
  history <- read_history(prefix)
  expect_length(history$lines, 3L)
  expect_match(history$lines[[1L]], history_header_pattern)
  expect_identical(
    history$lines[-1L],
    c(
      paste0("+", channel_url("chA"), "/noarch::foo-1.0-0"),
      "# update specs: [\"foo\"]"
    )
  )
  # libmamba writes the file in text mode: CRLF on Windows.
  expect_identical(history$crlf, isTRUE(is_windows()))

  # A change: the old side first, then the new side, dependencies first.
  result <- rust_install("bar", prefix, channel_url("chB"))
  expect_identical(result$records$op, c("-", "+", "+"))
  expect_identical(result$records$name, c("foo", "foo", "bar"))
  expect_identical(result$records$version, c("1.0", "2.0", "1.0"))
  expect_identical(
    result$records$channel,
    c(channel_url("chA"), channel_url("chB"), channel_url("chB"))
  )
  expect_identical(result$records$subdir, rep("noarch", 3L))
  history <- read_history(prefix)
  expect_length(history$lines, 8L)
  expect_match(history$lines[[4L]], history_header_pattern)
  expect_identical(
    history$lines[5:8],
    c(
      paste0("-", channel_url("chA"), "/noarch::foo-1.0-0"),
      paste0("+", channel_url("chB"), "/noarch::foo-2.0-0"),
      paste0("+", channel_url("chB"), "/noarch::bar-1.0-0"),
      "# update specs: [\"bar\"]"
    )
  )
  # Decision Q12 (R-18): no `# cmd:` and no `# conda version:` lines.
  expect_false(any(startsWith(history$lines, "# cmd:")))
  expect_false(any(startsWith(history$lines, "# conda version:")))
  expect_identical(
    env_records(prefix)[, c("name", "version")],
    data.frame(name = c("bar", "foo"), version = c("1.0", "2.0"))
  )
})

test_that("an empty request makes an empty environment without a history entry", {
  prefix <- local_rust_prefix()
  result <- rust_install(character(0L), prefix, channel_url("chA"))
  expect_identical(nrow(result$records), 0L)
  expect_identical(file.size(file.path(prefix, "conda-meta", "history")), 0)
  expect_identical(nrow(env_records(prefix)), 0L)
  # rattler marks every prefix as a cache directory (R-7, decision Q13).
  expect_true(file.exists(file.path(prefix, "CACHEDIR.TAG")))
})

test_that("explicit and lock files install without a solve, with micromamba's history", {
  e6 <- rattler_call(rt_read_env_file(envfile_fixture("e6.txt"), NULL))
  prefix <- local_rust_prefix()
  result <- rust_install_explicit(e6$urls, prefix)
  expect_identical(result$records$name, c("foo", "baz"))
  history <- read_history(prefix)
  expect_identical(
    history$lines[-1L],
    c(
      paste0("+", channel_url("chA"), "/noarch::foo-1.0-0"),
      paste0("+", channel_url("chC"), "/noarch::baz-1.0-0"),
      "# update specs: [\"foo==1.0=0\", \"baz==1.0=0\"]"
    )
  )

  # A lock file gets no specs line, as micromamba writes none.
  e7 <- rattler_call(rt_read_env_file(
    envfile_fixture("e7-lock.yml"),
    "linux-64"
  ))
  prefix <- local_rust_prefix()
  rust_install_explicit(e7$urls, prefix, lock_file = TRUE)
  history <- read_history(prefix)
  expect_identical(
    history$lines[-1L],
    c(
      paste0("+", channel_url("chA"), "/noarch::foo-1.0-0"),
      paste0("+", channel_url("chC"), "/noarch::baz-1.0-0")
    )
  )

  # A wrong hash is refused before anything is created.
  e11 <- rattler_call(rt_read_env_file(
    envfile_fixture("e11-badhash.txt"),
    NULL
  ))
  prefix <- local_rust_prefix()
  expect_rattler_error(
    rust_install_explicit(e11$urls, prefix),
    kind = "hash_mismatch"
  )
  expect_false(dir.exists(prefix))
})

# --- Errors -----------------------------------------------------------------------

test_that("a failed job has the classes of its kind, and a failed create leaves no prefix", {
  prefix <- local_rust_prefix()
  cnd <- expect_rattler_error(
    rust_install("foo", prefix, channel_url("chA"), platform = "bogus-64"),
    kind = "invalid_platform"
  )
  # The `[rattlerthis:<kind>]` tag is not part of the message.
  expect_identical(conditionMessage(cnd), "invalid platform \"bogus-64\"")
  cnd <- expect_rattler_error(
    rust_install("rt-no-such-package", prefix, channel_url("chA")),
    kind = "solve"
  )
  expect_match(conditionMessage(cnd), "rt-no-such-package", fixed = TRUE)
  expect_false(dir.exists(prefix))
  cache_dirs <- rattler_cache_dirs(create = TRUE)
  expect_rattler_error(
    rattler_await(function() {
      rt_install(
        "foo",
        prefix,
        channel_url("chA"),
        "bogus",
        NULL,
        as.character(cache_dirs$repodata),
        as.character(cache_dirs$pkgs)
      )
    }),
    kind = "invalid_channel_priority"
  )
  expect_false(dir.exists(prefix))
})
