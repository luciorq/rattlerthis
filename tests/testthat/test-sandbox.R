# condathis::with_sandbox_dir() and the rattler backend (spec 2.4 and 6.2,
# row test-sandbox.R; C2, C-L, decision Q26): the rattler root,
# `condathis::backend_root_dir("rattler")`, follows the sandbox, so
# environments and caches made inside it go into the sandbox and leave with
# it; nothing appears in the roots outside (checked by path, never by
# writing there); and rattler work that still runs in this R process when
# the sandbox ends is waited for before the sandbox is deleted.

# The files and directories below `dir` with their sizes and modification
# times, to compare a directory before and after.
pr_snapshot <- function(dir) {
  files <- list.files(
    dir,
    recursive = TRUE,
    all.files = TRUE,
    include.dirs = TRUE,
    no.. = TRUE
  )
  files <- sort(files, method = "radix")
  info <- file.info(file.path(dir, files))
  return(data.frame(
    path = files,
    size = info$size,
    mtime = as.numeric(info$mtime),
    stringsAsFactors = FALSE
  ))
}

test_that("with_sandbox_dir() moves the rattler root into the sandbox", {
  outer <- local_condathis_sandbox()
  outer_condathis_root <- dirname(outer$rattler)
  expect_false(dir.exists(outer_condathis_root))
  env_name <- "rt-sbx-inside"

  inside <- condathis::with_sandbox_dir({
    root <- condathis::backend_root_dir("rattler")
    condathis::create_env(
      "foo",
      env_name = env_name,
      channels = channel_url("chA"),
      method = "rattler",
      verbose = "silent"
    )
    list(
      sandbox = dirname(Sys.getenv("HOME")),
      root = as.character(root),
      install_dir = as.character(
        condathis::get_install_dir(method = "rattler")$path
      ),
      env_dir = as.character(
        condathis::get_env_dir(env_name, method = "rattler")
      ),
      envs = condathis::list_envs(method = "rattler")$env_name,
      exists = condathis::env_exists(env_name, method = "rattler"),
      pkgs = list.files(file.path(root, "pkgs"))
    )
  })

  # Inside: the root, the environment and the package cache are in the
  # sandbox.
  expect_true(path_is_within(inside$root, pr_real_path(inside$sandbox)))
  expect_false(path_is_within(inside$root, outer$root))
  expect_identical(pr_real_path(inside$install_dir), pr_real_path(inside$root))
  expect_true(path_is_within(inside$env_dir, inside$root))
  expect_identical(inside$envs, env_name)
  expect_true(inside$exists)
  expect_true("foo-1.0-0" %in% inside$pkgs)
  # Afterwards: the sandbox is gone with all of it, the root is the outer
  # one again, and nothing appeared outside.
  expect_false(dir.exists(inside$sandbox))
  expect_identical(
    as.character(condathis::backend_root_dir("rattler")),
    as.character(outer$rattler)
  )
  expect_false(condathis::env_exists(env_name, method = "rattler"))
  expect_false(dir.exists(outer$rattler))
  expect_false(dir.exists(outer_condathis_root))
  for (dir in c(
    outer$home,
    outer$data,
    outer$cache,
    outer$config,
    outer$state
  )) {
    expect_identical(
      list.files(dir, all.files = TRUE, no.. = TRUE),
      character(0L),
      info = dir
    )
  }
})

test_that("work inside a sandbox leaves the environments and caches outside", {
  outer <- local_condathis_sandbox()
  env_name <- "rt-sbx-outer"
  condathis::create_env(
    "foo",
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  outer_root <- dirname(outer$rattler)
  before <- pr_snapshot(outer_root)

  # The same name inside: another root, so another environment.
  condathis::with_sandbox_dir({
    expect_false(condathis::env_exists(env_name, method = "rattler"))
    condathis::create_env(
      "baz",
      env_name = env_name,
      channels = channel_url("chC"),
      method = "rattler",
      verbose = "silent"
    )
    expect_identical(
      condathis::list_packages(env_name, method = "rattler")$name,
      "baz"
    )
    condathis::clean_cache(verbose = "silent")
    condathis::remove_env(env_name, method = "rattler", verbose = "silent")
  })

  expect_identical(pr_snapshot(outer_root), before)
  expect_identical(
    condathis::list_packages(env_name, method = "rattler")$name,
    "foo"
  )
  expect_true("foo-1.0-0" %in% list.files(file.path(outer$rattler, "pkgs")))
})

test_that("method = 'auto' inside a sandbox sees only the sandbox's environments", {
  outer <- local_condathis_sandbox()
  env_name <- "rt-sbx-auto"
  condathis::create_env(
    env_name = env_name,
    channels = channel_url("chA"),
    method = "rattler",
    verbose = "silent"
  )
  outer_dir <- as.character(condathis::get_env_dir(
    env_name,
    method = "rattler"
  ))
  inside <- condathis::with_sandbox_dir({
    before <- condathis::env_exists(env_name)
    condathis::create_env(
      env_name = env_name,
      channels = channel_url("chA"),
      method = "rattler",
      verbose = "silent"
    )
    list(
      before = before,
      sandbox = dirname(Sys.getenv("HOME")),
      envs = condathis::list_envs()
    )
  })
  expect_false(inside$before)
  expect_identical(nrow(inside$envs), 1L)
  expect_identical(inside$envs$backend, "rattler")
  expect_identical(inside$envs$env_name, env_name)
  expect_true(path_is_within(inside$envs$path, pr_real_path(inside$sandbox)))
  # Outside, the outer environment is the one there is.
  envs <- condathis::list_envs()
  expect_identical(envs$env_name, env_name)
  expect_identical(pr_real_path(envs$path), pr_real_path(outer_dir))
})

test_that("rattler work left running is waited for before the sandbox is deleted", {
  # An interrupt cancels a rattler job and waits until it is idle; a second
  # interrupt could break that wait (R-15). The broken wait is mocked:
  # `rattler_stop_job()` returns at once and leaves the job running. The
  # sandbox must then wait for the job (`backend_quiesce()`, C-L) before it
  # deletes its directory, so no rattler thread writes into a deleted
  # sandbox.
  live_at_delete <- NULL
  deleted_at <- NULL
  real_delete <- get("delete_sandbox_root", envir = asNamespace("condathis"))
  testthat::local_mocked_bindings(
    delete_sandbox_root = function(sandbox_root) {
      live_at_delete <<- rt_live_jobs()
      deleted_at <<- Sys.time()
      return(real_delete(sandbox_root))
    },
    .package = "condathis"
  )
  real_poll <- rt_job_poll
  polls <- 0L
  # Held here: a job that R no longer references is cancelled when it is
  # garbage collected (see test-rust.R), which would end it early.
  held_job <- NULL
  testthat::local_mocked_bindings(
    rattler_stop_job = function(job) invisible(TRUE),
    rt_job_poll = function(job) {
      held_job <<- job
      polls <<- polls + 1L
      if (identical(polls, 2L)) {
        rlang::interrupt()
      }
      return(real_poll(job))
    }
  )
  sandbox_root <- NULL
  started <- Sys.time()
  # rattler says why it waits once it has waited a second; whether that
  # happens depends on how long stopping the sandbox's processes took
  # first, so the message is not asserted.
  suppressMessages(
    res <- tryCatch(
      condathis::with_sandbox_dir({
        sandbox_root <- dirname(Sys.getenv("HOME"))
        rattler_await(function() rt_test_job_sleep(1.5))
      }),
      interrupt = function(cnd) "interrupted"
    )
  )
  expect_identical(res, "interrupted")
  expect_false(is.null(sandbox_root))
  # The job was still running when the interrupt left with_sandbox_dir();
  # the sandbox was deleted only after it had finished.
  expect_identical(live_at_delete, 0L)
  expect_true(as.numeric(difftime(deleted_at, started, units = "secs")) >= 1.3)
  expect_false(dir.exists(sandbox_root))
  expect_identical(rt_live_jobs(), 0L)
  expect_true(real_poll(held_job))
})
