# One condathis sandbox for the whole test process (see
# `local_condathis_sandbox()` in helper.R): home, data, cache, config and
# state directories under one root, so condathis's root and the rattler
# root inside it start new and empty, and every package and repodata cache
# is shared by the tests of this process. Tests that need their own
# environments use distinct environment names; tests that assert on a
# fresh, empty root make a sandbox of their own.
#
# The runner's `CONDATHIS_MICROMAMBA_PATH` is recorded first (see
# setup-micromamba.R) and then unset: only the parity files use
# micromamba, through `local_parity_micromamba()`.

withr::local_options(
  .new = list(
    warnPartialMatchArgs = TRUE,
    warnPartialMatchAttr = TRUE,
    warnPartialMatchDollar = TRUE
  ),
  .local_envir = testthat::teardown_env()
)

remember_runner_micromamba()

rt_test_state$sandbox <- local_condathis_sandbox(
  env = testthat::teardown_env(),
  pattern = "rt-test-"
)

# No rattler job may still write into the sandbox when it is deleted (the
# deletion registered first, so it runs last). Every test waits for its
# own jobs; this only guards against one that did not.
withr::defer(
  rattler_wait_idle(timeout = 30),
  envir = testthat::teardown_env()
)
