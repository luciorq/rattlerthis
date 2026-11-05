# Parity of an environment's lifecycle: the same condathis calls with
# `method = "micromamba"` and `method = "rattler"` (spec section 6.2, row
# test-parity-lifecycle.R): create, keep or refuse, overwrite (also a
# failing replacement, which restores the old environment), install and
# remove. Both backends must return results of one structure (P-D7),
# print the same messages, fail with the same condathis classes (apart
# from the allowlist of R-3) and list the same packages, with identical
# `list_packages()` frames for empty and non-empty environments. Symbolic
# links are not environments, names may start with a dot, and the default
# environment is one name across backends (R-17). A root and a local
# channel below a `/t/<word>/` directory work with both backends.
#
# Environments are in the process sandbox (setup.R), named
# `rt-plc-<test>-mm` and `rt-plc-<test>-rt` (see `psolve_env_name()`).
# Every test calls `local_parity_micromamba()` first.

# The type of every element of a condathis result.
lifecycle_result_types <- function(res) {
  return(vapply(unclass(res), typeof, character(1L)))
}

# The environment names that `list_envs()` gives for `method`.
lifecycle_env_names <- function(method) {
  return(condathis::list_envs(method = method)$env_name)
}

# The entries of a backend's trash directory (condathis's
# `<root>/envs/#trash`), empty after every operation.
lifecycle_trash <- function(method) {
  root <- condathis::get_install_dir(method = method)$path
  return(list.files(
    fs::path(root, "envs", "#trash"),
    all.files = TRUE,
    no.. = TRUE
  ))
}

test_that("create, install and remove give one result structure, the same messages and the same package frames", {
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  chan_b <- channel_url("chB")
  chan_c <- channel_url("chC")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-plc-cycle", method)
    defer_remove_env(env_name, method = method)
    steps <- list()
    steps$create <- psolve_capture(condathis::create_env(
      env_name = env_name,
      channels = chan_a,
      method = method,
      verbose = "output"
    ))
    empty_pkgs <- condathis::list_packages(env_name, method = method)
    steps$install <- psolve_capture(condathis::install_packages(
      "foo",
      "baz",
      env_name = env_name,
      channels = c(chan_a, chan_c),
      method = method,
      verbose = "output"
    ))
    pkgs <- condathis::list_packages(env_name, method = method)
    # bar needs foo >=2, which only chB has: foo is upgraded.
    steps$upgrade <- psolve_capture(condathis::install_packages(
      "bar",
      env_name = env_name,
      channels = c(chan_b, chan_a, chan_c),
      method = method,
      verbose = "output"
    ))
    upgraded_pkgs <- condathis::list_packages(env_name, method = method)
    valid <- condathis::validate_env(
      "foo>=2",
      "bar",
      env_name = env_name,
      method = method
    )
    steps$remove <- psolve_capture(condathis::remove_env(
      env_name,
      method = method,
      verbose = "output"
    ))
    gone <- isFALSE(condathis::env_exists(env_name, method = method))
    for (step in names(steps)) {
      expect_null(steps[[step]]$error, label = paste(method, step))
      expect_identical(
        steps[[step]]$warnings,
        list(),
        label = paste(method, step, "warnings")
      )
    }
    seen[[method]] <- list(
      steps = steps,
      messages = lapply(steps, function(captured) {
        return(psolve_mask(captured$messages, env = env_name))
      }),
      empty_pkgs = empty_pkgs,
      pkgs = pkgs,
      upgraded_pkgs = upgraded_pkgs,
      valid = valid,
      gone = gone,
      trash = lifecycle_trash(method)
    )
  }
  mm <- seen$micromamba
  rt <- seen$rattler

  # One result structure (P-D7): class, names and types of every element.
  for (step in names(rt$steps)) {
    mm_res <- mm$steps[[step]]$value
    rt_res <- rt$steps[[step]]$value
    expect_s3_class(rt_res, "condathis_result")
    expect_identical(class(rt_res), class(mm_res), label = step)
    expect_identical(names(rt_res), names(mm_res), label = step)
    expect_identical(
      lifecycle_result_types(rt_res),
      lifecycle_result_types(mm_res),
      label = step
    )
    expect_identical(rt_res$status, 0L)
    expect_identical(mm_res$status, 0L)
    expect_false(rt_res$timeout)
    expect_false(mm_res$timeout)
    # rattler runs no command line (R-2): `cmd`, `stderr` and `pid` are
    # NA. micromamba's `cmd` is its command line.
    expect_identical(rt_res$cmd, NA_character_, label = step)
    expect_identical(rt_res$stderr, NA_character_, label = step)
    expect_identical(rt_res$pid, NA_integer_, label = step)
    expect_true(rlang::is_string(mm_res$cmd), label = step)
    expect_match(mm_res$cmd, "micromamba", fixed = TRUE, label = step)
  }
  expect_identical(
    rt$steps$create$value$env_name,
    psolve_env_name("rt-plc-cycle", "rattler")
  )
  expect_identical(
    mm$steps$create$value$env_name,
    psolve_env_name("rt-plc-cycle", "micromamba")
  )
  # rattler's `stdout` holds its transaction lines (R-2): none for an empty
  # environment (R-30), then one per package, removals first (in the
  # transaction's order, see test-parity-install-channels.R).
  expect_identical(rt$steps$create$value$stdout, "")
  expect_identical(
    sort(strsplit(rt$steps$install$value$stdout, "\n", fixed = TRUE)[[1L]]),
    c(
      paste0("+ baz 1.0 0 ", chan_c, "/noarch"),
      paste0("+ foo 1.0 0 ", chan_a, "/noarch")
    )
  )
  expect_identical(
    sort(strsplit(rt$steps$upgrade$value$stdout, "\n", fixed = TRUE)[[1L]]),
    sort(c(
      paste0("- foo 1.0 0 ", chan_a, "/noarch"),
      paste0("+ foo 2.0 0 ", chan_b, "/noarch"),
      paste0("+ bar 1.0 0 ", chan_b, "/noarch")
    ))
  )
  expect_match(
    rt$steps$upgrade$value$stdout,
    paste0("^- foo 1.0 0 [^\n]*\n")
  )

  # The same messages, from condathis, on both backends; micromamba's own
  # output goes to standard output (R-2), rattler prints nothing at
  # "output".
  expect_identical(rt$messages, mm$messages)
  expect_length(rt$messages$create, 1L)
  expect_match(
    rt$messages$create,
    "Environment <env> successfully created.",
    fixed = TRUE
  )
  expect_length(rt$messages$remove, 1L)
  expect_match(
    rt$messages$remove,
    "Environment <env> successfully removed.",
    fixed = TRUE
  )
  for (step in names(rt$steps)) {
    expect_identical(rt$steps[[step]]$output, character(0L), label = step)
  }

  # Identical list_packages() frames: names, order, types and values (the
  # channels are the same local directories for both backends).
  expect_identical(rt$empty_pkgs, mm$empty_pkgs)
  expect_identical(nrow(rt$empty_pkgs), 0L)
  expect_identical(
    names(rt$empty_pkgs),
    c(
      "base_url",
      "build_number",
      "build_string",
      "channel",
      "dist_name",
      "name",
      "platform",
      "version"
    )
  )
  expect_identical(rt$pkgs, mm$pkgs)
  expect_identical(rt$pkgs$name, c("baz", "foo"))
  expect_identical(
    names(rt$pkgs),
    c(
      "base_url",
      "build_number",
      "build_string",
      "channel",
      "dist_name",
      "md5",
      "name",
      "platform",
      "sha256",
      "url",
      "version"
    )
  )
  expect_identical(rt$pkgs$channel, c(chan_c, chan_a))
  expect_identical(
    rt$pkgs$md5[[2L]],
    channel_record("chA/noarch/foo-1.0-0.tar.bz2")$md5
  )
  expect_identical(rt$upgraded_pkgs, mm$upgraded_pkgs)
  expect_identical(
    paste(rt$upgraded_pkgs$name, rt$upgraded_pkgs$version),
    c("bar 1.0", "baz 1.0", "foo 2.0")
  )
  expect_s3_class(rt$upgraded_pkgs, "tbl_df")

  expect_true(rt$valid)
  expect_true(mm$valid)
  expect_true(rt$gone)
  expect_true(mm$gone)
  expect_identical(rt$trash, character(0L))
  expect_identical(mm$trash, character(0L))
})

test_that("an existing environment is kept, refused or replaced alike, and a failed replacement restores it", {
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  chan_c <- channel_url("chC")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-plc-keep", method)
    defer_remove_env(env_name, method = method)
    condathis::create_env(
      "foo",
      env_name = env_name,
      channels = chan_a,
      method = method,
      verbose = "silent"
    )
    before <- condathis::list_packages(env_name, method = method)
    out <- list()
    # Nothing requested: kept, nothing runs.
    out$bare <- psolve_capture(condathis::create_env(
      env_name = env_name,
      method = method,
      verbose = "output"
    ))
    # Satisfied: kept, with condathis's message.
    out$satisfied <- psolve_capture(condathis::create_env(
      "foo",
      env_name = env_name,
      channels = chan_a,
      method = method,
      verbose = "output"
    ))
    # Not satisfied: refused.
    out$refused <- psolve_capture(condathis::create_env(
      "foo>=2",
      env_name = env_name,
      channels = chan_a,
      method = method,
      verbose = "output"
    ))
    # An environment file is never compared: refused.
    out$file <- psolve_capture(condathis::create_env(
      env_file = envfile_fixture("e5.txt"),
      env_name = env_name,
      channels = chan_a,
      method = method,
      verbose = "output"
    ))
    after_refusals <- condathis::list_packages(env_name, method = method)
    # A replacement that does not solve: the old environment is back.
    out$failed <- psolve_capture(condathis::create_env(
      "rt-plc-no-such-package",
      env_name = env_name,
      channels = chan_a,
      overwrite = TRUE,
      method = method,
      verbose = "silent"
    ))
    after_failure <- condathis::list_packages(env_name, method = method)
    trash_after_failure <- lifecycle_trash(method)
    # A replacement builds exactly the request.
    out$replaced <- psolve_capture(condathis::create_env(
      "baz",
      env_name = env_name,
      channels = chan_c,
      overwrite = TRUE,
      method = method,
      verbose = "silent"
    ))
    seen[[method]] <- list(
      out = out,
      messages = lapply(out, function(captured) {
        return(psolve_mask(captured$messages, env = env_name))
      }),
      error_messages = lapply(out, function(captured) {
        if (is.null(captured$error)) {
          return(NULL)
        }
        return(psolve_mask(
          conditionMessage(captured$error),
          env = env_name
        ))
      }),
      before = before,
      after_refusals = after_refusals,
      after_failure = after_failure,
      trash_after_failure = trash_after_failure,
      replaced = psolve_summary(env_name, method),
      trash = lifecycle_trash(method)
    )
  }
  mm <- seen$micromamba
  rt <- seen$rattler

  for (case in c("bare", "satisfied", "replaced")) {
    expect_null(rt$out[[case]]$error, label = case)
    expect_null(mm$out[[case]]$error, label = case)
  }
  # Kept: nothing ran, so neither result has a command line.
  for (case in c("bare", "satisfied")) {
    expect_identical(rt$out[[case]]$value$cmd, NA_character_, label = case)
    expect_identical(mm$out[[case]]$value$cmd, NA_character_, label = case)
    expect_identical(rt$out[[case]]$value$status, 0L, label = case)
  }
  expect_identical(rt$messages, mm$messages)
  expect_length(rt$messages$satisfied, 1L)
  expect_match(
    rt$messages$satisfied,
    "Environment <env> already has the requested packages.",
    fixed = TRUE
  )
  # An empty request is satisfied by any environment.
  expect_identical(rt$messages$bare, rt$messages$satisfied)
  for (case in c("refused", "file")) {
    expect_s3_class(rt$out[[case]]$error, "condathis_create_env_exists")
    expect_s3_class(mm$out[[case]]$error, "condathis_create_env_exists")
    expect_identical(
      class(rt$out[[case]]$error),
      class(mm$out[[case]]$error),
      label = case
    )
  }
  expect_identical(rt$error_messages$refused, mm$error_messages$refused)
  expect_identical(rt$error_messages$file, mm$error_messages$file)
  expect_identical(rt$after_refusals, rt$before)
  expect_identical(mm$after_refusals, mm$before)
  expect_identical(rt$before, mm$before)

  # The failed replacement: condathis's classes on both, micromamba's
  # status classes on its own (R-3), rattler's solve error as the parent.
  psolve_expect_same_failure(
    mm$out$failed$error,
    rt$out$failed$error,
    rattler_kind = "solve"
  )
  expect_s3_class(rt$out$failed$error, "condathis_create_env_failed")
  expect_identical(rt$after_failure, rt$before)
  expect_identical(mm$after_failure, mm$before)
  expect_identical(rt$trash_after_failure, character(0L))
  expect_identical(mm$trash_after_failure, character(0L))

  expect_identical(rt$replaced, "baz 1.0 chC")
  expect_identical(mm$replaced, rt$replaced)
  expect_identical(rt$trash, character(0L))
  expect_identical(mm$trash, character(0L))
})

test_that("a missing environment aborts with the same classes and messages", {
  local_parity_micromamba()
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-plc-missing", method)
    calls <- list(
      remove = psolve_capture(condathis::remove_env(
        env_name,
        method = method,
        verbose = "silent"
      )),
      install = psolve_capture(condathis::install_packages(
        "foo",
        env_name = env_name,
        channels = channel_url("chA"),
        method = method,
        verbose = "silent"
      )),
      list = psolve_capture(condathis::list_packages(
        env_name,
        method = method
      )),
      validate = psolve_capture(condathis::validate_env(
        "foo",
        env_name = env_name,
        method = method
      ))
    )
    seen[[method]] <- list(
      classes = lapply(calls, function(captured) class(captured$error)),
      messages = lapply(calls, function(captured) {
        return(psolve_mask(conditionMessage(captured$error), env = env_name))
      }),
      exists = condathis::env_exists(env_name, method = method),
      dir = fs::dir_exists(condathis::get_env_dir(env_name, method = method))
    )
  }
  expect_identical(seen$rattler$classes, seen$micromamba$classes)
  expect_identical(seen$rattler$messages, seen$micromamba$messages)
  expect_true(
    "condathis_remove_env_env_not_found" %in% seen$rattler$classes$remove
  )
  expect_true(
    "condathis_install_packages_env_not_found" %in%
      seen$rattler$classes$install
  )
  expect_true(
    "condathis_list_packages_env_not_found" %in% seen$rattler$classes$list
  )
  for (method in psolve_methods) {
    expect_false(seen[[method]]$exists, label = method)
    expect_false(seen[[method]]$dir, label = method)
  }
})

test_that("symbolic links are not environments, and names may start with a dot", {
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  outside <- withr::local_tempdir(pattern = "rt-plc-outside-")
  seen <- list()
  for (method in psolve_methods) {
    env_name <- psolve_env_name(".rt-plc-dot", method)
    defer_remove_env(env_name, method = method)
    created <- psolve_capture(condathis::create_env(
      "foo",
      env_name = env_name,
      channels = chan_a,
      method = method,
      verbose = "silent"
    ))
    env_dir <- psolve_env_dir(env_name, method)
    envs_dir <- dirname(env_dir)
    # A link to an environment of the same root, and a link to a copy of
    # it outside the root (fs creates a junction on Windows).
    alias_name <- psolve_env_name("rt-plc-alias", method)
    alias_dir <- file.path(envs_dir, alias_name)
    copy_dir <- file.path(outside, method)
    dir.create(copy_dir)
    file.copy(env_dir, copy_dir, recursive = TRUE)
    out_name <- psolve_env_name("rt-plc-alias-out", method)
    out_dir <- file.path(envs_dir, out_name)
    fs::link_create(env_dir, alias_dir)
    fs::link_create(file.path(copy_dir, basename(env_dir)), out_dir)
    withr::defer(unlink(c(alias_dir, out_dir), recursive = TRUE))
    alias_create <- psolve_capture(condathis::create_env(
      "foo",
      env_name = alias_name,
      channels = chan_a,
      method = method,
      verbose = "silent"
    ))
    seen[[method]] <- list(
      created = created,
      listed = lifecycle_env_names(method),
      exists = c(
        dot = condathis::env_exists(env_name, method = method),
        alias = condathis::env_exists(alias_name, method = method),
        out = condathis::env_exists(out_name, method = method)
      ),
      packages = psolve_summary(env_name, method),
      alias_list = psolve_capture(condathis::list_packages(
        alias_name,
        method = method
      )),
      alias_create = alias_create,
      target_kept = file.exists(file.path(env_dir, "conda-meta", "history")),
      alias_kept = file.exists(file.path(
        alias_dir,
        "conda-meta",
        "history"
      ))
    )
    unlink(c(alias_dir, out_dir), recursive = TRUE)
    removed <- psolve_capture(condathis::remove_env(
      env_name,
      method = method,
      verbose = "silent"
    ))
    seen[[method]]$removed <- removed
    seen[[method]]$listed_after <- lifecycle_env_names(method)
  }
  for (method in psolve_methods) {
    got <- seen[[method]]
    env_name <- psolve_env_name(".rt-plc-dot", method)
    expect_null(got$created$error, label = method)
    expect_true(env_name %in% got$listed, label = method)
    expect_false(
      psolve_env_name("rt-plc-alias", method) %in% got$listed,
      label = method
    )
    expect_false(
      psolve_env_name("rt-plc-alias-out", method) %in% got$listed,
      label = method
    )
    expect_identical(
      got$exists,
      c(dot = TRUE, alias = FALSE, out = FALSE),
      label = method
    )
    expect_identical(got$packages, "foo 1.0 chA", label = method)
    expect_s3_class(
      got$alias_list$error,
      "condathis_list_packages_env_not_found"
    )
    # condathis never deletes a link that opens another environment.
    expect_s3_class(got$alias_create$error, "condathis_create_env_failed")
    expect_true(
      rlang::cnd_inherits(
        got$alias_create$error,
        "condathis_unsafe_env_dir_delete"
      ),
      label = method
    )
    expect_true(got$target_kept, label = method)
    expect_true(got$alias_kept, label = method)
    expect_null(got$removed$error, label = method)
    expect_false(env_name %in% got$listed_after, label = method)
  }
  expect_identical(
    class(seen$rattler$alias_create$error),
    class(seen$micromamba$alias_create$error)
  )
})

test_that("the default environment is one name for both backends (R-17)", {
  local_parity_micromamba()
  chan_a <- channel_url("chA")
  default_env <- "condathis-env"
  rscript <- rscript_path()
  seen <- list()
  for (method in psolve_methods) {
    other <- setdiff(psolve_methods, method)
    defer_remove_env(default_env, method = method)
    # install_packages() creates the missing default environment, empty,
    # with the backend that method names, then installs into it.
    installed <- psolve_capture(condathis::install_packages(
      "foo",
      channels = chan_a,
      method = method,
      verbose = "output"
    ))
    owner <- c(
      micromamba = condathis::env_exists(default_env, method = "micromamba"),
      rattler = condathis::env_exists(default_env, method = "rattler")
    )
    packages <- psolve_summary(default_env, method)
    # The other backend may read it, with a warning, and may not change it.
    ran <- psolve_capture(condathis::run(
      rscript,
      "-e",
      "cat('ok')",
      method = other,
      verbose = "silent"
    ))
    changed <- psolve_capture(condathis::create_env(
      "foo",
      env_name = default_env,
      channels = chan_a,
      method = other,
      verbose = "silent"
    ))
    removed <- psolve_capture(condathis::remove_env(
      default_env,
      method = method,
      verbose = "silent"
    ))
    seen[[method]] <- list(
      installed = installed,
      owner = owner,
      packages = packages,
      ran = ran,
      changed = changed,
      removed = removed
    )
  }
  mm <- seen$micromamba
  rt <- seen$rattler
  expect_null(rt$installed$error)
  expect_null(mm$installed$error)
  expect_identical(rt$installed$value$env_name, default_env)
  expect_identical(rt$installed$messages, mm$installed$messages)
  # The default environment is created silently.
  expect_length(rt$installed$messages, 1L)
  expect_match(
    rt$installed$messages,
    "Package foo successfully installed in environment condathis-env.",
    fixed = TRUE
  )
  expect_identical(rt$owner, c(micromamba = FALSE, rattler = TRUE))
  expect_identical(mm$owner, c(micromamba = TRUE, rattler = FALSE))
  expect_identical(rt$packages, "foo 1.0 chA")
  expect_identical(mm$packages, rt$packages)
  for (method in psolve_methods) {
    got <- seen[[method]]
    other <- setdiff(psolve_methods, method)
    expect_null(got$ran$error, label = method)
    expect_identical(
      condathis::parse_output(got$ran$value),
      "ok",
      label = method
    )
    expect_identical(
      psolve_warning_classes(got$ran)[[1L]],
      "condathis_backend_mismatch_warning",
      label = method
    )
    expect_match(
      conditionMessage(got$ran$warnings[[1L]]),
      paste0(
        "Environment condathis-env is owned by backend ",
        method,
        ", not ",
        other,
        "."
      ),
      fixed = TRUE,
      label = method
    )
    expect_s3_class(got$changed$error, "condathis_backend_mismatch")
    expect_null(got$removed$error, label = method)
  }
  expect_identical(class(rt$changed$error), class(mm$changed$error))
  expect_false(condathis::env_exists(default_env))
})

# The modes of the files and directories of an environment, by path:
# package files, conda-meta and the directories (not what only one backend
# writes: condathis's `.condathis`, rattler's `CACHEDIR.TAG`, the marker
# files of the link scripts micromamba runs).
umask_modes <- function(env_name, method) {
  prefix <- psolve_env_dir(env_name, method)
  paths <- list.files(
    prefix,
    recursive = TRUE,
    all.files = TRUE,
    include.dirs = TRUE,
    no.. = TRUE
  )
  paths <- paths[
    !grepl("^[.]condathis|^CACHEDIR[.]TAG$|-ran$|^conda-meta/history$", paths)
  ]
  modes <- format(file.info(file.path(prefix, paths))$mode)
  return(stats::setNames(modes, paths)[order(paths)])
}

test_that("installed files keep the archive's modes on both backends, whatever the umask (R-34)", {
  # micromamba keeps the mode of each file of a package archive; rattler
  # extracts with the umask applied, and rattlerthis then gives the files
  # of a new cache entry their archive's modes. Directories and conda-meta
  # files follow the umask with both. Windows has no umask. A sandbox of
  # its own, so both backends extract the packages now.
  local_condathis_sandbox()
  local_parity_micromamba()
  server <- local_http_channel("chA")
  http_channel_release(server)
  umasks <- if (isTRUE(is_windows())) "none" else c("027", "077")
  for (umask in umasks) {
    if (isFALSE(identical(umask, "none"))) {
      old_umask <- Sys.umask(umask)
      withr::defer(Sys.umask(old_umask))
    }
    seen <- list()
    for (method in psolve_methods) {
      # A local channel (plink: scripts with mode 755, files with 644), an
      # HTTP channel and an explicit file.
      envs <- list(
        local = psolve_env_name(paste0("rt-plc-um", umask, "-local"), method),
        http = psolve_env_name(paste0("rt-plc-um", umask, "-http"), method),
        explicit = psolve_env_name(paste0("rt-plc-um", umask, "-expl"), method)
      )
      psolve_capture(condathis::create_env(
        "plink",
        env_name = envs$local,
        channels = channel_url("plink"),
        method = method,
        verbose = "silent"
      ))
      condathis::create_env(
        "foo",
        env_name = envs$http,
        channels = server$url("chA"),
        method = method,
        verbose = "silent"
      )
      condathis::create_env(
        env_file = envfile_fixture("e6.txt"),
        env_name = envs$explicit,
        method = method,
        verbose = "silent"
      )
      seen[[method]] <- lapply(envs, umask_modes, method = method)
    }
    for (kind in names(seen$micromamba)) {
      expect_identical(
        seen$rattler[[kind]],
        seen$micromamba[[kind]],
        label = paste(umask, kind)
      )
    }
    if (isFALSE(identical(umask, "none"))) {
      dir_mode <- if (identical(umask, "027")) "750" else "700"
      expect_identical(
        unname(seen$rattler$local[c(
          "bin/.plink-post-link.sh",
          "share/plink/README",
          "bin"
        )]),
        c("755", "644", dir_mode),
        label = umask
      )
      expect_identical(
        unname(seen$rattler$http["share/foo/README"]),
        "644",
        label = umask
      )
    }
  }
})

test_that("neither backend adds its environments to ~/.conda/environments.txt (R-12)", {
  # micromamba registers every environment it creates in the
  # `.conda/environments.txt` of its home, and nothing stops it. condathis
  # runs its create with a home of its own (`<micromamba root>/home`), so
  # the user's list stays as it is, except when micromamba needs the user's
  # home: a saved login, as here in the second part. rattler writes nothing
  # outside condathis's directory. A sandbox of its own, so the home is
  # new.
  sandbox <- local_condathis_sandbox()
  local_parity_micromamba()
  homes <- unique(c(Sys.getenv("HOME"), Sys.getenv("USERPROFILE")))
  homes <- homes[nzchar(homes)]
  registry <- file.path(homes, ".conda", "environments.txt")
  registered <- function(files) {
    lines <- unlist(lapply(files[file.exists(files)], readLines, warn = FALSE))
    lines <- lines[nzchar(lines)]
    if (identical(length(lines), 0L)) {
      return(character(0L))
    }
    return(normalizePath(lines, winslash = "/", mustWork = FALSE))
  }
  same_path <- function(a, b) {
    if (isTRUE(is_windows())) {
      return(tolower(a) %in% tolower(b))
    }
    return(a %in% b)
  }
  create_both <- function(prefix) {
    env_dirs <- list()
    for (method in psolve_methods) {
      env_name <- psolve_env_name(prefix, method)
      condathis::create_env(
        env_name = env_name,
        channels = channel_url("chA"),
        method = method,
        verbose = "silent"
      )
      env_dirs[[method]] <- normalizePath(
        psolve_env_dir(env_name, method),
        winslash = "/"
      )
    }
    return(env_dirs)
  }

  env_dirs <- create_both("rt-plc-registry")
  expect_false(any(file.exists(registry)))
  # micromamba's list is in the home condathis gives it.
  own_registry <- file.path(
    condathis::get_install_dir(method = "micromamba")$path,
    "home",
    ".conda",
    "environments.txt"
  )
  own_lines <- registered(own_registry)
  expect_true(same_path(env_dirs$micromamba, own_lines))
  expect_false(same_path(env_dirs$rattler, own_lines))

  # With a saved login micromamba needs the user's home, and registers its
  # environment there; rattler still does not.
  auth_file <- file.path(homes[[1L]], ".mamba", "auth", "authentication.json")
  dir.create(dirname(auth_file), recursive = TRUE)
  writeLines("{}", auth_file)
  env_dirs <- create_both("rt-plc-registry-auth")
  lines <- registered(registry)
  expect_true(same_path(env_dirs$micromamba, lines))
  expect_false(same_path(env_dirs$rattler, lines))
  expect_false(any(startsWith(lines, sandbox$rattler)))
})

test_that("a root and a local channel below a /t/<word>/ directory work with both backends", {
  # micromamba 2.9.0 and later hide every `/t/<word>` of their JSON output
  # as a channel token, paths included, and condathis hides them in the
  # channels of the history and of `list_packages()`. Under such a root,
  # condathis found no micromamba environment, and with both backends
  # `install_packages()` warned that a local channel below such a
  # directory, passed again, was left out. A sandbox of its own, with the
  # root below `t/proj1`.
  sandbox <- local_condathis_sandbox()
  local_parity_micromamba()
  data_dir <- file.path(sandbox$root, "t", "proj1", "data")
  dir.create(data_dir, recursive = TRUE)
  withr::local_envvar(c(R_USER_DATA_DIR = data_dir, XDG_DATA_HOME = data_dir))
  channel_parent <- file.path(sandbox$root, "t", "chan1")
  dir.create(channel_parent, recursive = TRUE)
  file.copy(condathis_polyglot_channel(), channel_parent, recursive = TRUE)
  channel <- file_url(file.path(channel_parent, "polyglot-channel"))
  for (method in psolve_methods) {
    env_name <- psolve_env_name("rt-plc-tdir", method)
    defer_remove_env(env_name, method = method)
    expect_match(
      condathis::get_install_dir(method = method)$path,
      "/t/proj1/",
      fixed = TRUE,
      label = method
    )
    steps <- list()
    steps$create <- psolve_capture(condathis::create_env(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = method,
      verbose = "silent"
    ))
    listed <- condathis::list_envs(method = method)$env_name
    exists <- condathis::env_exists(env_name, method = method)
    steps$install <- psolve_capture(condathis::install_packages(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = method,
      verbose = "silent"
    ))
    steps$keep <- psolve_capture(condathis::create_env(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = method,
      verbose = "output"
    ))
    steps$validate <- psolve_capture(condathis::validate_env(
      "polyglot",
      env_name = env_name,
      channels = channel,
      method = method
    ))
    steps$run <- psolve_capture(condathis::run(
      "polyglot",
      env_name = env_name,
      method = method,
      verbose = "silent"
    ))
    steps$remove <- psolve_capture(condathis::remove_env(
      env_name,
      method = method,
      verbose = "silent"
    ))
    for (step in names(steps)) {
      expect_null(steps[[step]]$error, label = paste(method, step))
      expect_identical(
        steps[[step]]$warnings,
        list(),
        label = paste(method, step, "warnings")
      )
    }
    expect_identical(listed, env_name, label = method)
    expect_true(exists, label = method)
    # Already satisfied: nothing runs.
    expect_match(
      steps$keep$messages,
      "already has the requested packages",
      fixed = TRUE,
      label = method
    )
    expect_identical(steps$keep$value$cmd, NA_character_, label = method)
    expect_true(steps$validate$value, label = method)
    # A failed run is reported above, and must not stop the test before
    # the other backend's turn.
    if (is.null(steps$run$error)) {
      expect_identical(
        condathis::parse_output(steps$run$value)[[1L]],
        polyglot_first_line(),
        label = method
      )
    }
    expect_false(
      condathis::env_exists(env_name, method = method),
      label = method
    )
  }
})
