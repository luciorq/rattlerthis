# `rattlerthis` as condathis's backend

`rattlerthis` is condathis's `"rattler"` backend under condathis's backend
contract version 2 (condathis 0.2.0.9010; `?condathis::register_backend`).
The current design is in `.github/devdocs/feat-initial-impl/PLAN.md`
("What rattlerthis is", "The backend functions"); this file keeps the
decisions that shaped it and the history, in short. "The backend spec" is
the design document of the October 2026 move (not in the repository); IDs
such as R-5, CP2 or Q22 are its difference, review and decision IDs.

## Decisions (October 2026, binding)

- rattlerthis is only condathis's backend. All front-end functionality and
  user interaction come from condathis's functions with
  `method = "rattler"`; rattlerthis exports nothing and has no options or
  environment variables of its own.
- Same behavior for both backends wherever possible; every remaining
  difference is flagged (`?rattlerthis`).
- micromamba keeps running link scripts; rattler skips them, reports them
  in the result's `link_scripts_skipped`, and condathis warns naming the
  packages.
- The rattler root is `condathis::backend_root_dir("rattler")`, the
  `rattler` directory of condathis's root, with `envs/`, `pkgs/`,
  `repodata_cache/` and the condathis-owned `conda-pkgs/`.
  `with_sandbox_dir()` isolates it.
- condathis owns the generic parts (checks, results, listings, the
  environment-directory life cycle, platform choice and emulation
  fallback, link-script warnings), with defaults any conda-prefix backend
  can use. rattlerthis implements 7 functions: create, install,
  resolve_run, clean_cache, quiesce, native_platform and can_solve.

## History

- **2026-07-15**: a standalone adapter for condathis's first contract (10
  generics): plain functions over rattlerthis's own front end, with no
  condathis dependency, before condathis had a registry.
- **2026-08-13**: registered with condathis through
  `register_backend()` (a named list of functions; condathis registers the
  S3 methods), with the load-order-safe `.onLoad()` and condathis `onLoad`
  hook pattern.
- **2026-10-22 to 10-26**: conformance rounds against condathis 0.2.0.9009
  (`test-condathis-conformance.R`), and copies of condathis's
  keep/refuse checks so rattlerthis's own `create_env()` answered as
  condathis does.
- **2026-10-27 / 28**: contract v2 (the backend spec, units RT-1 to RT-5):
  the front end, the copies, the own root (`RATTLERTHIS_ROOT_DIR`,
  `rattlerthis.root_dir`) and `channels_with_existing()` are gone; long
  calls are Rust jobs; condathis loads rattlerthis on demand.

## Follow-ups outside this package

On condathis's side or in the backend spec, not in rattlerthis:

- optionally, interrupts suspended in condathis's own delete and restore
  cleanup, for any backend.

Done on 2026-10-29 (fix stage): condathis's environment lock for every
backend (R-25, R-32), the `NA` "unset" marker in `env` (rattler reports a
variable an `activate.d` script unsets), micromamba's `run()` through
condathis's own activation on every OS (R-4), and the
`backend_resolve_run_in_dir()` hook for `env_path()` environments, which
rattlerthis implements (R-14).
