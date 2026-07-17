# TODO

Status and roadmap for making `rattlerthis` a conforming `condathis`
backend. See `PLAN.md` for the design behind these decisions.

## Milestone: standalone adapter (done, 2026-07-15)

- [x] `R/resolve-run.R`: `resolve_run_command(cmd, env_name)` — extracted
      from `run()` (PLAN.md decision 4)
- [x] `R/run.R`: `run()` calls `resolve_run_command()` instead of inlining
      the env-exists check / activation-env lookup / cmd-path resolution;
      behavior-preserving (same error class, same path resolution)
- [x] `R/condathis-backend.R`: `new_backend_rattler()` constructor + the 10
      adapter functions (`backend_create_env`, `backend_install`,
      `backend_remove_env`, `backend_list_envs`, `backend_env_exists`,
      `backend_list_packages`, `backend_get_env_dir`,
      `backend_get_install_dir`, `backend_resolve_run`,
      `backend_available`) — PLAN.md decisions 1-3
- [x] `tests/testthat/test-condathis-backend.R`: mismatch-handling tests
      (no network needed — `env_file` non-`NULL`, `channel_priority =
      "flexible"`, `additional_channels` merge) plus a real
      create/install/resolve_run/list/remove cycle against conda-forge
      (`skip_if_offline()`/`skip_on_cran()`, same pattern as
      `test-create-env.R`). Verified 2026-07-15: 8 offline assertions pass
      standalone; full suite (`NOT_CRAN=true`) passes including the real
      network round-trip — `backend_resolve_run()`'s output was fed
      straight into a bare `processx::run()` call in the test (standing in
      for `condathis`'s eventual single call site) and successfully ran
      `xz --version` inside the resolved environment.
- [x] `devtools::document()` + full existing test suite still green
      (behavior-preserving refactor of `run()` did not change anything
      observable — same 8 pre-existing test files, all still passing)
- [x] Update this package's own `TODO.md`
      (`.github/devdocs/feat-initial-impl/TODO.md`) with a short pointer to
      this milestone, so it's discoverable from the main roadmap doc

## Deferred (blocked on `condathis`'s own backend-abstraction milestone)

Not started in `condathis` yet
(`condathis/.github/devdocs/feat-backend-abstraction/TODO.md`) — nothing
here can proceed until the generics/registry exist there.

- [ ] Turn the 10 plain adapter functions into real S3 methods:
      `backend_create_env.condathis_backend_rattler <- function(backend,
      ...) backend_create_env(backend, ...)` (etc. for all 10), or rename
      in place
- [ ] `.onLoad()` in `R/rattlerthis-package.R`: `if
      (requireNamespace("condathis", quietly = TRUE))
      condathis::register_backend("rattler", new_backend_rattler())`
- [ ] Add `condathis` to `Suggests` (not `Imports`/`Depends` — the adapter
      must not force a hard dependency either direction, per `condathis`'s
      own PLAN.md decision 3)
- [ ] End-to-end smoke test: `condathis::create_env(..., method =
      "rattler")` → `condathis::run()` against a real `rattlerthis`-backed
      environment, proving `backend_resolve_run()`'s output is actually
      consumable by `condathis`'s single `processx::run()` call site
- [ ] Flag the `list_packages()` column-schema mismatch (see PLAN.md,
      "Known gap to flag upward") to whoever picks up `condathis`'s
      `backend_list_packages()` dispatch — needs a decision there, not
      here, about whether backends normalize to one schema or keep their
      own
- [ ] README updates in both packages once the two actually talk to each
      other

## Later ideas (not scheduled)

- If `condathis` ever wants `backend_available()` to be a real probe rather
  than an unconditional `TRUE` (e.g. checking a minimum `rattler` crate
  version, or that the repodata cache directory is writable), revisit
  decision 3's reasoning — not needed today since load-time linking already
  makes "available" trivially true.
