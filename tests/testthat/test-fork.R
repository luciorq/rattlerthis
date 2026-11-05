# rattler in R processes that the parallel package makes (P-A1): forked
# children (`parallel::mcparallel()`, on Linux and macOS) and PSOCK workers
# (every OS). rattler works on threads of a runtime that each process
# starts, and a forked child has none of its parent's threads: rattlerthis
# starts new ones in the child. Each test makes one rattler call in the
# parent first, so the parent's threads exist when the child is made.
#
# * Linux: a forked child creates, installs and runs as its parent does.
# * macOS: a forked child must not use CoreFoundation, which rattler needs
#   to link a package (the Time Machine exclusion of a new prefix) and for
#   HTTP(S) (Security.framework), so rattlerthis refuses there with a
#   classed error instead of letting macOS kill R: kind `link` for every
#   create and install (checked first, so also for one from an HTTP
#   channel), and kind `fetch` for the download of a solve check, which
#   then answers NA ("cannot tell"); running a command, a solve check on
#   a local channel and cleaning a cache (rattler's job, on directories of
#   the child's own) work. The same work succeeds in a PSOCK worker.
#   micromamba runs as a separate program, so it has no such limit
#   (difference R-31 of the backend spec).
# * Windows has no fork; PSOCK workers do the work.
#
# Environment names start with "rt-fork-".

# What a process did with rattler: a create, an install and a run in a
# new environment `env_name` (the install and the run go to `fallback_env`
# when the create failed), a create from an HTTP channel, and the backend's
# solve check (`backend_can_solve()`, which downloads channel metadata but
# links nothing) against a local and the HTTP channel: called directly,
# because condathis reads its errors as "cannot tell", and rattler's cache
# cleaning job (`rt_clean_cache()`, which condathis's `clean_cache()` runs)
# on a package and a repodata cache directory of its own, so no other
# work loses its cache. Each step gives `ok`, the error's classes and the
# `kind` of the rattler error in its parent chain; the solve checks also
# their `value`, the cleaning what is left in its directories.
# Self-contained: it runs in a forked child or in a PSOCK worker.
rattler_work <- function(
  env_name,
  fallback_env,
  polyglot,
  local_chA,
  http_chA
) {
  attempt <- function(expr) {
    return(tryCatch(
      {
        force(expr)
        list(ok = TRUE, class = NULL, kind = NA_character_)
      },
      error = function(e) {
        kind <- NA_character_
        cnd <- e
        while (isFALSE(is.null(cnd))) {
          if (inherits(cnd, "rattlerthis_rattler_error")) {
            kind <- cnd$kind
            break
          }
          cnd <- cnd$parent
        }
        return(list(ok = FALSE, class = class(e), kind = kind))
      }
    ))
  }
  ns <- asNamespace("rattlerthis")
  backend <- ns$new_backend_rattler()
  solve_check <- function(channel) {
    value <- NULL
    step <- attempt(
      value <- backend$backend_can_solve(
        backend,
        packages = "foo",
        channels = channel,
        channel_priority = "strict",
        platform = ns$rt_native_platform()
      )
    )
    step$value <- value
    return(step)
  }
  solve_local <- solve_check(local_chA)
  solve_http <- solve_check(http_chA)
  cache_dir <- tempfile(pattern = "rt-fork-cache-")
  cache_dirs <- file.path(cache_dir, c("pkgs", "repodata_cache"))
  for (dir in cache_dirs) {
    dir.create(file.path(dir, "entry"), recursive = TRUE)
    writeLines("cached", file.path(dir, "entry", "file.txt"))
  }
  clean <- attempt(ns$rattler_await(function() {
    ns$rt_clean_cache(cache_dirs[[1L]], cache_dirs[[2L]])
  }))
  clean$left <- list.files(cache_dirs, recursive = TRUE)
  unlink(cache_dir, recursive = TRUE)
  create <- attempt(condathis::create_env(
    "polyglot",
    env_name = env_name,
    channels = polyglot,
    method = "rattler",
    verbose = "silent"
  ))
  target <- if (isTRUE(create$ok)) env_name else fallback_env
  install <- attempt(condathis::install_packages(
    "foo",
    env_name = target,
    channels = local_chA,
    method = "rattler",
    verbose = "silent"
  ))
  output <- NULL
  run <- attempt(
    output <- condathis::parse_output(condathis::run(
      "polyglot",
      env_name = target,
      method = "rattler",
      verbose = "silent"
    ))
  )
  http_env <- paste0(env_name, "-http")
  create_http <- attempt(condathis::create_env(
    "foo",
    env_name = http_env,
    channels = http_chA,
    method = "rattler",
    verbose = "silent"
  ))
  return(list(
    create = create,
    install = install,
    run = run,
    first_line = output[[1L]],
    create_http = create_http,
    solve_local = solve_local,
    solve_http = solve_http,
    clean = clean,
    target_packages = condathis::list_packages(target, method = "rattler")$name,
    http_packages = if (isTRUE(create_http$ok)) {
      condathis::list_packages(http_env, method = "rattler")$name
    },
    live_jobs = ns$rt_live_jobs()
  ))
}
environment(rattler_work) <- globalenv()

# Asserts that a step of `rattler_work()` failed with condathis's class
# `class` and a rattler error of kind `kind` as its parent.
expect_refused_step <- function(step, class, kind) {
  expect_false(step$ok)
  expect_true(all(c(class, "condathis_backend_error") %in% step$class))
  expect_identical(step$kind, kind)
  return(invisible(step))
}

test_that("a forked child uses rattler after its parent did", {
  parent_env <- "rt-fork-parent"
  child_env <- "rt-fork-child"
  for (env_name in c(parent_env, child_env, paste0(child_env, "-http"))) {
    defer_remove_env(env_name)
  }
  # The parent's call: its runtime threads exist when the child is forked.
  condathis::create_env(
    "polyglot",
    env_name = parent_env,
    channels = condathis_polyglot_channel(),
    method = "rattler",
    verbose = "silent"
  )
  if (isTRUE(is_windows())) {
    # No fork on Windows (the PSOCK test below does the work).
    expect_error(parallel::mcparallel(1L), "mcparallel")
    return(invisible(NULL))
  }
  server <- local_http_channel("chA")
  http_channel_release(server)
  args <- list(
    env_name = child_env,
    fallback_env = parent_env,
    polyglot = condathis_polyglot_channel(),
    local_chA = channel_url("chA"),
    http_chA = server$url("chA")
  )
  job <- parallel::mcparallel(do.call(rattler_work, args), silent = TRUE)
  res <- parallel::mccollect(job, wait = FALSE, timeout = 60)
  if (is.null(res)) {
    tools::pskill(job$pid, tools::SIGKILL)
    parallel::mccollect(job, wait = TRUE)
  }
  # The child returned within 60 s, with no rattler job left running.
  expect_false(is.null(res))
  res <- res[[1L]]
  expect_false(inherits(res, "try-error"), label = format(res))
  expect_identical(res$live_jobs, 0L)
  # Running a command, a solve check on a local channel and cleaning a
  # cache work in a child on both systems.
  expect_true(res$run$ok)
  expect_identical(res$first_line, polyglot_first_line())
  expect_true(res$solve_local$ok)
  expect_true(res$solve_local$value)
  expect_true(res$clean$ok)
  expect_identical(res$clean$left, character(0L))
  if (isTRUE(is_macos())) {
    # A create or an install is refused before anything else (kind
    # `link`), also from an HTTP channel. The solve check refuses the
    # download (kind `fetch`) and so cannot tell: NA.
    expect_refused_step(res$create, "condathis_create_env_failed", "link")
    expect_refused_step(
      res$install,
      "condathis_install_packages_failed",
      "link"
    )
    expect_refused_step(res$create_http, "condathis_create_env_failed", "link")
    expect_true(res$solve_http$ok)
    expect_identical(res$solve_http$value, NA)
    # Nothing is left of the refused creates, and the parent's
    # environment is as it was.
    expect_false(condathis::env_exists(child_env, method = "rattler"))
    expect_false(dir.exists(condathis::get_env_dir(
      child_env,
      method = "rattler"
    )))
    expect_false(
      condathis::env_exists(paste0(child_env, "-http"), method = "rattler")
    )
    expect_identical(res$target_packages, "polyglot")
    expect_identical(
      condathis::list_packages(parent_env, method = "rattler")$name,
      "polyglot"
    )
  } else {
    expect_true(res$create$ok)
    expect_true(res$install$ok)
    expect_true(res$create_http$ok)
    expect_true(res$solve_http$ok)
    expect_true(res$solve_http$value)
    expect_identical(res$target_packages, c("foo", "polyglot"))
    expect_identical(res$http_packages, "foo")
    # The parent sees what the child made.
    expect_identical(
      condathis::list_packages(child_env, method = "rattler")$name,
      c("foo", "polyglot")
    )
  }
  # The parent goes on working after the child.
  res <- condathis::run(
    "polyglot",
    env_name = parent_env,
    method = "rattler",
    verbose = "silent"
  )
  expect_identical(condathis::parse_output(res)[[1L]], polyglot_first_line())
})

test_that("PSOCK workers create, install and run with rattler at once", {
  parent_env <- "rt-fork-psock-parent"
  env_names <- c("rt-fork-psock-1", "rt-fork-psock-2")
  for (env_name in c(
    parent_env,
    env_names,
    paste0(c(parent_env, env_names), "-http")
  )) {
    defer_remove_env(env_name)
  }
  condathis::create_env(
    "polyglot",
    env_name = parent_env,
    channels = condathis_polyglot_channel(),
    method = "rattler",
    verbose = "silent"
  )
  server <- local_http_channel("chA")
  http_channel_release(server)
  # The parent downloads the HTTP channel's metadata first, so the workers
  # find it in rattler's repodata cache, still valid by the server's ETag.
  # Two sessions that download it at the same time are the case of
  # test-lock.R.
  condathis::create_env(
    "foo",
    env_name = paste0(parent_env, "-http"),
    channels = server$url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  # The workers start with this process's environment variables (so its
  # sandbox) and get its library paths.
  cluster <- parallel::makePSOCKcluster(2L, timeout = 120)
  withr::defer(parallel::stopCluster(cluster))
  parallel::clusterCall(
    cluster,
    function(lib_paths) {
      .libPaths(lib_paths)
      return(invisible(NULL))
    },
    .libPaths()
  )
  # Both workers create, install and run at the same time, from the same
  # channels: they share rattler's package cache.
  results <- parallel::parLapply(
    cluster,
    env_names,
    rattler_work,
    fallback_env = parent_env,
    polyglot = condathis_polyglot_channel(),
    local_chA = channel_url("chA"),
    http_chA = server$url("chA")
  )
  for (res in results) {
    expect_true(res$create$ok)
    expect_true(res$install$ok)
    expect_true(res$run$ok)
    expect_identical(res$first_line, polyglot_first_line())
    expect_true(res$create_http$ok)
    expect_true(res$solve_local$value)
    expect_true(res$solve_http$value)
    expect_true(res$clean$ok)
    expect_identical(res$clean$left, character(0L))
    expect_identical(res$target_packages, c("foo", "polyglot"))
    expect_identical(res$http_packages, "foo")
    expect_identical(res$live_jobs, 0L)
  }
  for (env_name in env_names) {
    expect_identical(
      condathis::list_packages(env_name, method = "rattler")$name,
      c("foo", "polyglot")
    )
  }
})
