# Link scripts on both backends (spec 3.11, 6.2 row
# test-parity-linkscripts.R; R-1, decision Q6): micromamba runs the
# pre-link, post-link and pre-unlink scripts of packages; rattler runs none
# of them, and condathis warns after the operation succeeded, naming the
# packages, with class `condathis_<fn>_link_scripts_skipped`. The scripts of
# the fixture `plink` and of the channel `prlink` (built by
# helper-parity-run.R) write a marker file when they run.

# Runs `expr` and returns `list(value, warnings)`: the warnings it signaled,
# muffled.
pr_with_warnings <- function(expr) {
  warnings <- list()
  value <- withCallingHandlers(
    expr,
    warning = function(cnd) {
      warnings[[length(warnings) + 1L]] <<- cnd
      invokeRestart("muffleWarning")
    }
  )
  return(list(value = value, warnings = warnings))
}

# Asserts the one link-script warning of `warnings`: the classes of
# condathis's `warn_link_scripts_skipped()` for `fn`, the fields, and the
# skipped scripts (a data frame with the columns `package` and `script`,
# compared without order).
pr_expect_skip_warning <- function(warnings, fn, env_name, scripts) {
  expect_length(warnings, 1L)
  cnd <- warnings[[1L]]
  expect_s3_class(cnd, paste0("condathis_", fn, "_link_scripts_skipped"))
  expect_s3_class(cnd, "condathis_link_scripts_skipped")
  expect_s3_class(cnd, "condathis_warning")
  expect_identical(cnd$backend, "rattler")
  expect_identical(cnd$env_name, env_name)
  expect_identical(
    cnd$packages,
    sort(unique(scripts$package), method = "radix")
  )
  sort_rows <- function(df) {
    df <- df[order(df$package, df$script, method = "radix"), , drop = FALSE]
    rownames(df) <- NULL
    return(df)
  }
  expect_identical(sort_rows(cnd$scripts), sort_rows(scripts))
  return(invisible(cnd))
}

pr_scripts <- function(package, script) {
  return(data.frame(
    package = package,
    script = script,
    stringsAsFactors = FALSE
  ))
}

pr_prefix <- function(env_name, method) {
  return(as.character(condathis::get_env_dir(env_name, method = method)))
}

test_that("micromamba runs the scripts of a new environment, rattler warns", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pls-create")
  pr_defer_remove_envs(env_names)
  results <- list()
  for (method in pr_methods) {
    out <- pr_with_warnings(
      condathis::create_env(
        "plink",
        env_name = env_names[[method]],
        channels = channel_url("plink"),
        method = method,
        verbose = "silent"
      )
    )
    results[[method]] <- out$value
    expect_identical(out$value$status, 0L, info = method)
    prefix <- pr_prefix(env_names[[method]], method)
    expect_identical(env_records(prefix)$name, "plink", info = method)
    markers <- list.files(prefix, pattern = "-ran$")
    if (identical(method, "micromamba")) {
      expect_length(out$warnings, 0L)
      expect_identical(markers, c("post-link-ran", "pre-link-ran"))
    } else {
      # R-1: rattler runs neither script, and condathis says so.
      expect_identical(markers, character(0L))
      cnd <- pr_expect_skip_warning(
        out$warnings,
        fn = "create_env",
        env_name = env_names[[method]],
        scripts = pr_scripts("plink", c("pre-link", "post-link"))
      )
      text <- conditionMessage(cnd)
      expect_match(text, "did not run the pre-link scripts of plink")
      expect_match(text, "did not run the post-link scripts of plink")
      expect_match(text, "method = \"micromamba\"", fixed = TRUE)
    }
  }
  # The data is in the warning only: both results have the same structure
  # (P-D7).
  expect_identical(class(results$rattler), class(results$micromamba))
  expect_identical(names(results$rattler), names(results$micromamba))
  expect_null(attr(results$rattler, "link_scripts_skipped"))
})

test_that("install_packages() runs or reports the scripts of what it links", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pls-install")
  pr_defer_remove_envs(env_names)
  for (method in pr_methods) {
    condathis::create_env(
      "foo",
      env_name = env_names[[method]],
      channels = channel_url("chA"),
      method = method,
      verbose = "silent"
    )
    out <- pr_with_warnings(
      condathis::install_packages(
        "plink",
        env_name = env_names[[method]],
        channels = c(channel_url("chA"), channel_url("plink")),
        method = method,
        verbose = "silent"
      )
    )
    expect_identical(out$value$status, 0L, info = method)
    prefix <- pr_prefix(env_names[[method]], method)
    expect_identical(env_records(prefix)$name, c("foo", "plink"))
    markers <- list.files(prefix, pattern = "-ran$")
    if (identical(method, "micromamba")) {
      expect_length(out$warnings, 0L)
      expect_identical(markers, c("post-link-ran", "pre-link-ran"))
    } else {
      expect_identical(markers, character(0L))
      pr_expect_skip_warning(
        out$warnings,
        fn = "install_packages",
        env_name = env_names[[method]],
        scripts = pr_scripts("plink", c("pre-link", "post-link"))
      )
    }
  }
})

test_that("an upgrade runs or reports the pre-unlink script of the old version", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pls-upgrade")
  pr_defer_remove_envs(env_names)
  channel <- pr_prlink_channel()
  for (method in pr_methods) {
    first <- pr_with_warnings(
      condathis::create_env(
        "prlink=1.0",
        env_name = env_names[[method]],
        channels = channel,
        method = method,
        verbose = "silent"
      )
    )
    prefix <- pr_prefix(env_names[[method]], method)
    out <- pr_with_warnings(
      condathis::install_packages(
        "prlink=2.0",
        env_name = env_names[[method]],
        channels = channel,
        method = method,
        verbose = "silent"
      )
    )
    expect_identical(env_records(prefix)$version, "2.0", info = method)
    if (identical(method, "micromamba")) {
      expect_length(first$warnings, 0L)
      expect_length(out$warnings, 0L)
      # The old version's pre-unlink script, then the new version's
      # pre-link and post-link scripts.
      expect_identical(
        pr_link_markers(prefix),
        c(
          `prlink-post-link` = "2.0",
          `prlink-pre-link` = "2.0",
          `prlink-pre-unlink` = "1.0"
        )
      )
    } else {
      expect_length(pr_link_markers(prefix), 0L)
      pr_expect_skip_warning(
        first$warnings,
        fn = "create_env",
        env_name = env_names[[method]],
        scripts = pr_scripts("prlink", c("pre-link", "post-link"))
      )
      cnd <- pr_expect_skip_warning(
        out$warnings,
        fn = "install_packages",
        env_name = env_names[[method]],
        scripts = pr_scripts("prlink", c("pre-unlink", "pre-link", "post-link"))
      )
      expect_match(
        conditionMessage(cnd),
        "did not run the pre-unlink scripts of prlink before it removed them"
      )
    }
  }
})

test_that("remove_env() runs or reports the pre-unlink scripts", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pls-remove")
  pr_defer_remove_envs(env_names)
  channel <- pr_prlink_channel()
  for (method in pr_methods) {
    suppressWarnings(
      condathis::create_env(
        "prlink=2.0",
        env_name = env_names[[method]],
        channels = channel,
        method = method,
        verbose = "silent"
      ),
      classes = "condathis_link_scripts_skipped"
    )
    prefix <- pr_prefix(env_names[[method]], method)
    # The pre-unlink script also writes next to the environment directory,
    # which outlives the removal (see `pr_link_script()`).
    outside_marker <- paste0(prefix, ".prlink-pre-unlink-ran")
    withr::defer(unlink(outside_marker))
    out <- pr_with_warnings(
      condathis::remove_env(
        env_names[[method]],
        method = method,
        verbose = "silent"
      )
    )
    expect_false(
      condathis::env_exists(env_names[[method]], method = method),
      info = method
    )
    expect_false(dir.exists(prefix), info = method)
    if (identical(method, "micromamba")) {
      expect_length(out$warnings, 0L)
      expect_true(file.exists(outside_marker))
      expect_identical(trimws(readLines(outside_marker, warn = FALSE)), "2.0")
    } else {
      expect_false(file.exists(outside_marker))
      cnd <- pr_expect_skip_warning(
        out$warnings,
        fn = "remove_env",
        env_name = env_names[[method]],
        scripts = pr_scripts("prlink", "pre-unlink")
      )
      text <- conditionMessage(cnd)
      expect_match(text, "before it removed them")
      expect_match(text, "undo changes outside the environment")
      # Nothing to install: no hint to use micromamba.
      expect_no_match(text, "method = \"micromamba\"", fixed = TRUE)
    }
  }
})

test_that("a failing post-link script fails neither backend's create", {
  # micromamba 2.10.0 ignores the exit status of a link script: libmamba's
  # `run_script()` (link.cpp) throws only when the script cannot be
  # started. So both create the environment; micromamba ran the script (it
  # wrote its marker before it failed) and says nothing, rattler ran no
  # script and warns (R-1).
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pls-fail")
  pr_defer_remove_envs(env_names)
  for (method in pr_methods) {
    out <- pr_with_warnings(
      condathis::create_env(
        "prfail",
        env_name = env_names[[method]],
        channels = pr_prlink_channel(),
        method = method,
        verbose = "silent"
      )
    )
    expect_identical(out$value$status, 0L, info = method)
    expect_true(
      condathis::env_exists(env_names[[method]], method = method),
      info = method
    )
    markers <- pr_link_markers(
      condathis::get_env_dir(env_names[[method]], method = method)
    )
    if (identical(method, "micromamba")) {
      expect_identical(markers, c(`prfail-post-link` = "1.0"))
      expect_length(out$warnings, 0L)
    } else {
      expect_length(markers, 0L)
      pr_expect_skip_warning(
        out$warnings,
        fn = "create_env",
        env_name = env_names[[method]],
        scripts = pr_scripts("prfail", "post-link")
      )
    }
  }
})

test_that("an explicit environment file runs or reports the scripts", {
  local_parity_micromamba()
  env_names <- pr_env_names("rt-pls-e13")
  pr_defer_remove_envs(env_names)
  env_file <- envfile_fixture("e13-plink.txt")
  for (method in pr_methods) {
    out <- pr_with_warnings(
      condathis::create_env(
        env_file = env_file,
        env_name = env_names[[method]],
        method = method,
        verbose = "silent"
      )
    )
    prefix <- pr_prefix(env_names[[method]], method)
    expect_identical(env_records(prefix)$name, "plink", info = method)
    markers <- list.files(prefix, pattern = "-ran$")
    if (identical(method, "micromamba")) {
      expect_length(out$warnings, 0L)
      expect_identical(markers, c("post-link-ran", "pre-link-ran"))
    } else {
      expect_identical(markers, character(0L))
      pr_expect_skip_warning(
        out$warnings,
        fn = "create_env",
        env_name = env_names[[method]],
        scripts = pr_scripts("plink", c("pre-link", "post-link"))
      )
    }
  }
})

test_that("rattler's warning is given at every verbose level", {
  # A warning is a condition, not output: "silent" does not hide it.
  for (verbose in c("silent", "output", "cmd", "spinner", "full")) {
    env_name <- paste0("rt-pls-level-", verbose)
    defer_remove_env(env_name)
    out <- pr_with_warnings(
      pr_capture(
        condathis::create_env(
          "plink",
          env_name = env_name,
          channels = channel_url("plink"),
          method = "rattler",
          verbose = verbose
        )
      )
    )
    pr_expect_skip_warning(
      out$warnings,
      fn = "create_env",
      env_name = env_name,
      scripts = pr_scripts("plink", c("pre-link", "post-link"))
    )
  }
})
