# Output per verbose level on both backends (spec 3.14 and 6.2, row
# test-parity-verbose.R; R-2): what create_env(), install_packages(),
# remove_env(), the queries, run(), run_bin() and clean_cache() print at
# "silent", "output", "cmd", "spinner" and "full". condathis's own
# messages are the same for both backends. micromamba echoes its command
# line at "cmd" and "full" and streams its log at "full"; rattler runs no
# command: it prints a one-line description of its request at "cmd" and
# "full" (on standard output, as processx echoes micromamba's command
# line), then one line per package of the transaction at "full", and
# nothing for what condathis's defaults do (remove, queries). The tests run
# without an interactive session, so neither backend shows a spinner; the
# last tests check rattler's spinner rule with a mock.

pr_levels <- c("silent", "output", "cmd", "spinner", "full")

# micromamba's echoed command line as one string: processx breaks it into
# lines that end with ` \`.
pr_joined <- function(lines) {
  lines <- sub("[[:space:]]*\\\\$", "", trimws(lines))
  return(paste(lines, collapse = " "))
}

# The messages with the environment name replaced, to compare them across
# backends.
pr_messages <- function(captured, env_name) {
  return(gsub(env_name, "<ENV>", captured$messages, fixed = TRUE))
}

test_that("create, install and remove print per level as R-2 says, on both backends", {
  local_parity_micromamba()
  channel_a <- channel_url("chA")
  channel_c <- channel_url("chC")
  for (verbose in pr_levels) {
    env_names <- pr_env_names(paste0("rt-pvb-", verbose))
    pr_defer_remove_envs(env_names)
    out <- list()
    for (method in pr_methods) {
      env_name <- env_names[[method]]
      out[[method]] <- list(
        create = pr_capture(condathis::create_env(
          "foo",
          env_name = env_name,
          channels = channel_a,
          method = method,
          verbose = verbose
        )),
        install = pr_capture(condathis::install_packages(
          "baz",
          env_name = env_name,
          channels = c(channel_a, channel_c),
          method = method,
          verbose = verbose
        )),
        remove = pr_capture(condathis::remove_env(
          env_name,
          method = method,
          verbose = verbose
        ))
      )
    }
    for (op in c("create", "install", "remove")) {
      info <- paste(verbose, op)
      mm <- out$micromamba[[op]]
      rt <- out$rattler[[op]]
      # condathis's messages, the same for both backends.
      expect_identical(
        pr_messages(rt, env_names[["rattler"]]),
        pr_messages(mm, env_names[["micromamba"]]),
        info = info
      )
      if (isTRUE(verbose %in% c("output", "full"))) {
        expect_length(rt$messages, 1L)
        expect_match(rt$messages, "successfully", info = info)
      } else {
        expect_length(rt$messages, 0L)
      }
      # Nothing goes to the message stream outside of messages.
      expect_identical(rt$stderr, character(0L), info = info)
      expect_identical(mm$stderr, character(0L), info = info)
      if (isTRUE(verbose %in% c("silent", "output", "spinner"))) {
        expect_identical(rt$stdout, character(0L), info = info)
        expect_identical(mm$stdout, character(0L), info = info)
      }
    }

    rt_name <- env_names[["rattler"]]
    mm_name <- env_names[["micromamba"]]
    request <- list(
      create = paste("Running rattler create", rt_name, "-c", channel_a, "foo"),
      install = paste(
        "Running rattler install",
        rt_name,
        "-c",
        channel_a,
        "-c",
        channel_c,
        "baz"
      )
    )
    transaction <- list(
      create = paste("+ foo 1.0 0", paste0(channel_a, "/noarch")),
      install = paste("+ baz 1.0 0", paste0(channel_c, "/noarch"))
    )
    if (identical(verbose, "cmd")) {
      expect_identical(out$rattler$create$stdout, request$create)
      expect_identical(out$rattler$install$stdout, request$install)
      # remove_env() is condathis's default, which runs no command.
      expect_identical(out$rattler$remove$stdout, character(0L))
      mm_lines <- lapply(out$micromamba, function(x) pr_joined(x$stdout))
      expect_match(out$micromamba$create$stdout[[1L]], "^Running")
      expect_match(mm_lines$create, "micromamba", fixed = TRUE)
      expect_match(mm_lines$create, paste("create -n", mm_name), fixed = TRUE)
      expect_match(mm_lines$install, paste("install -n", mm_name), fixed = TRUE)
      expect_match(
        mm_lines$remove,
        paste("env remove -n", mm_name),
        fixed = TRUE
      )
    }
    if (identical(verbose, "full")) {
      expect_identical(
        out$rattler$create$stdout,
        c(request$create, transaction$create)
      )
      expect_identical(
        out$rattler$install$stdout,
        c(request$install, transaction$install)
      )
      expect_identical(out$rattler$remove$stdout, character(0L))
      # micromamba's command line, then its log.
      mm_lines <- lapply(out$micromamba, function(x) pr_joined(x$stdout))
      expect_match(out$micromamba$create$stdout[[1L]], "^Running")
      expect_match(mm_lines$create, paste("create -n", mm_name), fixed = TRUE)
      expect_match(mm_lines$create, "Linking foo-1.0-0", fixed = TRUE)
      expect_match(mm_lines$create, "Transaction finished", fixed = TRUE)
      expect_match(mm_lines$install, "Linking baz-1.0-0", fixed = TRUE)
      expect_match(mm_lines$remove, "Unlinking foo-1.0-0", fixed = TRUE)
      expect_match(mm_lines$remove, "Unlinking baz-1.0-0", fixed = TRUE)
    }

    # The results: rattler's `stdout` holds its transaction lines at every
    # level, and it has no command line (R-2).
    res <- out$rattler$create$value
    expect_identical(res$stdout, paste0(transaction$create, "\n"))
    expect_identical(res$cmd, NA_character_)
    expect_identical(res$stderr, NA_character_)
    expect_identical(res$pid, NA_integer_)
    res <- out$micromamba$create$value
    expect_true(rlang::is_string(res$cmd) && isFALSE(is.na(res$cmd)))
    expect_true(rlang::is_string(res$stdout))
  }
})

test_that("both backends say at \"full\" that YAML variables are not used", {
  # condathis runs micromamba with `--no-env`, so neither backend uses the
  # `variables:` of a YAML file. micromamba's log says so, and condathis
  # shows that log at "full"; rattler prints its own line there, on
  # standard output. Nothing at the other levels.
  local_parity_micromamba()
  lines <- c(
    micromamba = "Variables from yaml file are not considered",
    rattler = "Variables of the environment file are not used: EMPTY, MY_VAR, NUM, lower_var."
  )
  for (verbose in c("full", "cmd")) {
    env_names <- pr_env_names(paste0("rt-pvb-vars-", verbose))
    pr_defer_remove_envs(env_names)
    for (method in pr_methods) {
      out <- pr_capture(condathis::create_env(
        env_file = envfile_fixture("e4.yml"),
        env_name = env_names[[method]],
        method = method,
        verbose = verbose
      ))
      said <- grepl(lines[[method]], out$stdout, fixed = TRUE)
      info <- paste(method, verbose)
      if (identical(verbose, "full")) {
        expect_identical(sum(said), 1L, info = info)
      } else {
        expect_identical(sum(said), 0L, info = info)
      }
      expect_false(
        any(grepl("ariables", c(out$messages, out$stderr), fixed = TRUE)),
        info = info
      )
    }
  }
})

test_that("queries print nothing for rattler; micromamba echoes `env list`", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pvb-query")
  pr_defer_remove_envs(env_names)
  for (method in pr_methods) {
    condathis::create_env(
      "foo",
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
  }
  for (verbose in pr_levels) {
    out <- list()
    for (method in pr_methods) {
      env_name <- env_names[[method]]
      out[[method]] <- list(
        list_envs = pr_capture(condathis::list_envs(
          method = method,
          verbose = verbose
        )),
        env_exists = pr_capture(condathis::env_exists(
          env_name,
          method = method,
          verbose = verbose
        )),
        list_packages = pr_capture(condathis::list_packages(
          env_name,
          method = method,
          verbose = verbose
        ))
      )
    }
    for (op in names(out$rattler)) {
      info <- paste(verbose, op)
      mm <- out$micromamba[[op]]
      rt <- out$rattler[[op]]
      expect_identical(rt$stdout, character(0L), info = info)
      expect_identical(rt$stderr, character(0L), info = info)
      expect_identical(
        pr_messages(rt, env_names[["rattler"]]),
        pr_messages(mm, env_names[["micromamba"]]),
        info = info
      )
      if (
        identical(op, "list_packages") &&
          isTRUE(verbose %in% c("output", "full"))
      ) {
        expect_match(
          pr_messages(rt, env_names[["rattler"]]),
          "Retrieved 1 package from environment <ENV>\\.$",
          info = info
        )
      } else {
        expect_length(rt$messages, 0L)
      }
      # micromamba lists environments with its binary and echoes that
      # command; it reads the package records from the file system, but at
      # "full" through `micromamba list`, echoed as well.
      if (
        isTRUE(op %in% c("list_envs", "env_exists")) &&
          isTRUE(verbose %in% c("cmd", "full"))
      ) {
        expect_match(pr_joined(mm$stdout), "env list", fixed = TRUE)
      } else if (identical(op, "list_packages") && identical(verbose, "full")) {
        expect_match(
          pr_joined(mm$stdout),
          paste("list -n", env_names[["micromamba"]]),
          fixed = TRUE
        )
      } else {
        expect_identical(mm$stdout, character(0L), info = info)
      }
    }
    expect_true(out$rattler$env_exists$value)
    expect_identical(
      out$rattler$list_packages$value$name,
      out$micromamba$list_packages$value$name
    )
  }
})

test_that("run() and run_bin() print condathis's Running line on both backends", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pvb-run")
  pr_defer_remove_envs(env_names)
  for (method in pr_methods) {
    condathis::create_env(
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
  }
  args <- c("-e", "cat('hi\\n')")
  for (verbose in pr_levels) {
    out <- list()
    for (method in pr_methods) {
      for (fn in c("run", "run_bin")) {
        out[[method]][[fn]] <- pr_capture(getExportedValue("condathis", fn)(
          rscript_path(),
          args,
          env_name = env_names[[method]],
          method = method,
          verbose = verbose
        ))
      }
    }
    # The command's line ends in CRLF on Windows.
    hi_line <- if (isTRUE(is_windows())) "hi\r" else "hi"
    rt_bin <- out$rattler$run_bin
    for (method in pr_methods) {
      for (fn in c("run", "run_bin")) {
        info <- paste(verbose, method, fn)
        captured <- out[[method]][[fn]]
        expect_length(captured$messages, 0L)
        expect_identical(captured$stderr, character(0L), info = info)
        expect_identical(
          captured$value$stdout,
          paste0(hi_line, "\n"),
          info = info
        )
      }
    }
    # condathis's line (long ones are wrapped, with ` \` at the end).
    running <- setdiff(rt_bin$stdout, hi_line)
    expected <- switch(
      verbose,
      silent = character(0L),
      spinner = character(0L),
      output = hi_line,
      cmd = running,
      full = c(running, hi_line)
    )
    if (isTRUE(verbose %in% c("cmd", "full"))) {
      expect_match(running[[1L]], "^Running ")
      expect_match(
        pr_joined(running),
        basename(rscript_path()),
        fixed = TRUE
      )
    }
    # run() and run_bin() start the command directly for both backends, on
    # every OS (R-4): the same Running line and output.
    for (method in pr_methods) {
      for (fn in c("run", "run_bin")) {
        expect_identical(
          out[[method]][[fn]]$stdout,
          expected,
          info = paste(verbose, method, fn)
        )
      }
    }
  }
})

test_that("clean_cache() prints the part of each backend per level", {
  # A sandbox of its own, so the caches of this test process stay; it
  # unsets CONDATHIS_MICROMAMBA_PATH, so the parity micromamba comes after.
  paths <- local_condathis_sandbox()
  local_parity_micromamba()
  for (verbose in pr_levels) {
    # Fill both backends' package caches first.
    for (method in pr_methods) {
      condathis::create_env(
        "foo",
        env_name = paste0("rt-pvb-clean-", verbose, "-", method),
        channels = channel_url("chA"),
        method = method,
        verbose = "silent"
      )
    }
    cache_dirs <- rattler_cache_dirs()
    request <- paste(
      "Running rattler clean",
      cache_dirs$pkgs,
      cache_dirs$repodata
    )
    out <- pr_capture(condathis::clean_cache(verbose = verbose))
    info <- verbose
    expect_identical(out$stderr, character(0L), info = info)
    if (isTRUE(verbose %in% c("output", "full"))) {
      expect_length(out$messages, 1L)
      expect_match(out$messages, "Cache successfully removed", info = info)
    } else {
      expect_length(out$messages, 0L)
    }
    if (isTRUE(verbose %in% c("silent", "output", "spinner"))) {
      expect_identical(out$stdout, character(0L), info = info)
    } else {
      # micromamba's command line comes first (backend priority), then
      # rattler's request line.
      rt_at <- match(request, out$stdout)
      expect_false(is.na(rt_at), info = info)
      mm_part <- pr_joined(out$stdout[seq_len(rt_at - 1L)])
      expect_match(out$stdout[[1L]], "^Running")
      expect_match(mm_part, "clean", fixed = TRUE)
      expect_match(mm_part, "--force-pkgs-dirs", fixed = TRUE)
      rt_part <- out$stdout[-seq_len(rt_at)]
      if (identical(verbose, "cmd")) {
        expect_identical(rt_part, character(0L))
      } else {
        # "full": how much rattler removed (foo, its lock file and
        # rattler's CUDA probe cache).
        expect_length(rt_part, 1L)
        expect_match(
          rt_part,
          "^Removed [1-9][0-9]* cache entr(y|ies) \\([0-9]+ bytes\\)\\.$"
        )
      }
    }
    # micromamba's package cache is gone, rattler's is empty but for its
    # lock file (see test-hooks.R).
    expect_false(dir.exists(file.path(dirname(paths$rattler), "pkgs")))
    expect_identical(
      list.files(cache_dirs$pkgs, all.files = TRUE, no.. = TRUE),
      ".cache.lock"
    )
  }
})

test_that("the spinner rule is the same on both backends", {
  # condathis decides micromamba's spinner (processx's, shown only when
  # base::interactive() is TRUE, so never in these tests; R-2) with
  # `parse_strategy_verbose()`; rattler decides its cli spinner with the
  # same rule.
  parse_verbose <- get(
    "parse_strategy_verbose",
    envir = asNamespace("condathis")
  )
  for (interactive in c(FALSE, TRUE)) {
    rlang::local_interactive(interactive)
    for (verbose in pr_levels) {
      expect_identical(
        rattler_shows_spinner(verbose),
        isTRUE(parse_verbose(verbose)$spinner_flag),
        info = paste(interactive, verbose)
      )
      expect_identical(
        rattler_shows_spinner(verbose),
        isTRUE(interactive) && isFALSE(identical(verbose, "silent"))
      )
    }
  }
})

test_that("rattler shows a spinner only for its own work", {
  labels <- character(0L)
  testthat::local_mocked_bindings(rattler_make_spinner = function(label) {
    labels <<- c(labels, label)
    return(NULL)
  })
  env_name <- "rt-pvb-spin"
  defer_remove_env(env_name)
  rlang::local_interactive(TRUE)
  suppressMessages({
    condathis::create_env(
      "foo",
      env_name = env_name,
      channels = channel_url("chA"),
      method = "rattler",
      verbose = "spinner"
    )
    condathis::install_packages(
      "baz",
      env_name = env_name,
      channels = c(channel_url("chA"), channel_url("chC")),
      method = "rattler",
      verbose = "output"
    )
  })
  expect_identical(
    labels,
    c(
      paste("Creating environment", env_name),
      paste("Installing into environment", env_name)
    )
  )
  # The activation of run() and condathis's defaults (queries, remove)
  # show none.
  labels <- character(0L)
  suppressMessages({
    condathis::run(
      rscript_path(),
      "-e",
      "invisible()",
      env_name = env_name,
      method = "rattler",
      verbose = "spinner"
    )
    condathis::list_packages(env_name, method = "rattler", verbose = "spinner")
    condathis::create_env(
      "foo",
      env_name = paste0(env_name, "-silent"),
      channels = channel_url("chA"),
      method = "rattler",
      verbose = "silent"
    )
    condathis::remove_env(
      paste0(env_name, "-silent"),
      method = "rattler",
      verbose = "spinner"
    )
  })
  expect_identical(labels, character(0L))
  # Not interactive: none at any level.
  rlang::local_interactive(FALSE)
  condathis::install_packages(
    "foo",
    env_name = env_name,
    channels = c(channel_url("chA"), channel_url("chC")),
    method = "rattler",
    verbose = "spinner"
  )
  expect_identical(labels, character(0L))
  # clean_cache(), in a sandbox of its own: the caches of this process stay.
  paths <- local_condathis_sandbox()
  condathis::create_env(
    "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  rlang::local_interactive(TRUE)
  suppressMessages(condathis::clean_cache(verbose = "spinner"))
  expect_identical(labels, "Cleaning the rattler caches")
})

test_that("rattler's request line shows the credentials of a channel as `*****`", {
  # As condathis shows micromamba's command line (R-10).
  out <- utils::capture.output(rattler_print_request(
    "cmd",
    c("create", "x", "-c", "http://u:pw@h/t/tok-1/chA", "foo", NA)
  ))
  expect_identical(
    out,
    "Running rattler create x -c http://u:*****@h/t/*****/chA foo NA"
  )
})

test_that("rattler's request line names the options it was given", {
  env_name <- "rt-pvb-words"
  defer_remove_env(env_name)
  channel_a <- channel_url("chA")
  out <- pr_capture(condathis::create_env(
    "foo >=1.0",
    env_name = env_name,
    channels = channel_a,
    channel_priority = "flexible",
    platform = "osx-64",
    method = "rattler",
    verbose = "cmd"
  ))
  # A word with a space is quoted.
  expect_identical(
    out$stdout,
    paste(
      "Running rattler create",
      env_name,
      "-c",
      channel_a,
      "--channel-priority flexible --platform osx-64",
      "\"foo >=1.0\""
    )
  )
  env_name <- "rt-pvb-words-file"
  defer_remove_env(env_name)
  env_file <- envfile_fixture("e1.yml")
  out <- pr_capture(condathis::create_env(
    env_file = env_file,
    env_name = env_name,
    channels = channel_a,
    channel_priority = "disabled",
    method = "rattler",
    verbose = "cmd"
  ))
  # The file's channels follow the command-line ones (spec 3.5).
  expect_identical(
    out$stdout,
    paste(
      "Running rattler create",
      env_name,
      "-f",
      env_file,
      "-c",
      channel_a,
      "-c",
      channel_url("chB"),
      "--channel-priority disabled"
    )
  )
})
