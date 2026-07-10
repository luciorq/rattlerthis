# PLAN

Design decisions for `rattlerthis`, an R package that creates and manages
'Conda' environments and runs CLI tools inside them, in the spirit of
[`condathis`](https://github.com/luciorq/condathis) but without shelling out
to an external `micromamba` binary.

## Why not condathis's approach

`condathis` downloads a `micromamba` release binary on first use and drives
it as a subprocess (`create`, `install`, `env list`, `env remove`, `run`).
That works, but it means: a binary download step, parsing another program's
stdout/JSON as the API contract, and being bound by whatever `micromamba`
exposes on the CLI.

`rattlerthis` instead links the [`rattler`](https://github.com/conda/rattler)
Rust crates — the library that `pixi` and `conda`'s tooling are built on —
directly into the compiled R package via
[`rextendr`](https://extendr.github.io/rextendr/). Solving, installing, and
shell activation happen in-process, as real function calls with typed
results, not text parsed from a subprocess.

## Architecture

The package has two halves:

- **Rust** (`src/rust/`): an `extendr`-based crate depending directly on
  `rattler`, `rattler_conda_types`, `rattler_solve` (default `resolvo`
  backend), `rattler_repodata_gateway` (`gateway` feature), `rattler_shell`,
  `rattler_virtual_packages`, and `rattler_cache` (`rattler_networking` is
  pulled in transitively, not depended on directly). It compiles into the
  package's shared library (the standard `rextendr` arrangement:
  `crate-type = ["rlib", "staticlib"]`, linked in via `src/entrypoint.c`).
- **R** (`R/`): thin wrappers around the generated `.Call` bindings, adding
  argument validation, condathis-style verbosity handling, and classed error
  rethrowing, matching R user expectations (`cli`-formatted messages,
  `rlang::abort()` conditions).

No `libsolv_c` (avoids a C compiler + `bindgen` build dependency —
`rattler_solve` already defaults to the pure-Rust `resolvo` backend). No
`cli-tools`/`oauth`/S3/git-channel features — kept minimal so the crate
builds fast and portably.

## Async bridging

R calls into the compiled library synchronously; there is no R event loop to
hand async work to (unlike Python's `asyncio`, which `py-rattler` bridges
into via `pyo3-async-runtimes`). `rattlerthis` instead keeps one
`tokio::runtime::Runtime` (multi-thread flavor) alive for the life of the R
session, created lazily on first use and stored in a `std::sync::OnceLock`.
Every `#[extendr]` entry point that needs async rattler APIs does
`runtime().block_on(async { ... })`: the calling R thread blocks while
tokio's worker threads do the actual network/CPU work.

Known limitation: a blocking `block_on` cannot be interrupted by Ctrl+C from
R mid-solve. See TODO.md.

## Process execution split (the `run()` design)

Rust's job is to *compute* the activated environment, not to *spawn* the
target CLI tool. `rattler_shell::activation::Activator` produces the PATH and
environment variables a shell would have after `conda activate <prefix>`;
`rattlerthis` exposes that as a named character vector to R.
`rattlerthis::run()` merges those variables with `withr::local_envvar()` and
runs the actual command with `processx::run()` — the same pattern
`condathis::run_bin()` already uses for its no-activation-script fast path.

This keeps process management (streaming stdout/stderr, spinners, timeouts,
interrupt-safe waiting) in R, where `processx` already solves it well, and
keeps the new Rust surface narrowly scoped to solving/installing/activating.

## Install root and directory layout

Mirrors `condathis::get_install_dir()`, using `tools::R_user_dir("rattlerthis",
"data")` by default. Overridable via the R option `rattlerthis.root_dir` or
the environment variable `RATTLERTHIS_ROOT_DIR` (option takes precedence).

```
<root>/
  envs/<env_name>/       # installed prefixes (one per environment)
  pkgs/                  # extracted package cache (rattler_cache)
  repodata_cache/        # sparse repodata cache (rattler_repodata_gateway)
```

## MatchSpec parsing

Done in Rust via `rattler_conda_types::MatchSpec`'s real `FromStr` parser,
rather than `condathis::parse_match_spec()`'s regex approximation. This means
`rattlerthis` accepts exactly what conda's own MatchSpec grammar accepts
(channel::name version build), and parse errors are real parser errors
surfaced as R conditions, not silent misparses.

## Repodata fetching and solving

`rattler_repodata_gateway::Gateway` fetches and caches repodata per
channel/platform under `<root>/repodata_cache`. `rattler_solve`'s `resolvo`
solver resolves the requested `MatchSpec`s, together with virtual packages
detected for the current machine (`rattler_virtual_packages::VirtualPackages::detect()`,
e.g. `__glibc`, `__osx`, `__cuda`), into a `Vec<RepoDataRecord>` for the
target platform.

Platform defaults to `rattler_conda_types::Platform::current()`. An explicit
`platform =` argument is accepted by `create_env()`/`install()` for API
forward-compatibility, but only same-platform solving is exercised/guaranteed
in this milestone — see TODO.md for cross-platform solving.

The gateway is queried for `[platform, Platform::NoArch]`, not just
`[platform]`: every conda channel splits packages between a
platform-specific subdir (`linux-64`, `osx-arm64`, ...) and a sibling
`noarch` subdir for platform-independent packages (most of the Python
ecosystem — `pip`, `setuptools`, `tzdata`, and so on). The gateway only
fetches exactly the platforms it's told to; it does not add `noarch` on its
own. Missing this initially meant any dependency chain touching a noarch
package came back "unsolvable" — invisible in testing that only used
compiled-only packages (`xz`, `zstd`), but broke on essentially anything
Python-flavored. Regression test: `tests/testthat/test-create-env.R`
("resolves packages with noarch dependencies").

## Installation

`rattler::install::Installer` links the resolved records into
`<root>/envs/<env_name>`. Post-link/pre-unlink scripts are not executed
(`execute_link_scripts = false`): some conda packages rely on these for
correct behavior, so this is a known gap, not a design endorsement — see
TODO.md.

`Installer::install()` takes the *complete desired set* of records for the
prefix — anything already linked that isn't in that set gets treated as
extraneous and removed. That matters because `create_env()` and `install()`
share one Rust entry point (`solve_and_install`, in `src/rust/src/install.rs`):
every call first reads whatever `PrefixRecord`s are already in the prefix
(empty for a brand-new environment) via
`PrefixRecord::collect_from_prefix()`, then folds them into the solve as
`SolverTask::locked_packages` (so the solver prefers keeping their versions)
plus bare-name `MatchSpec`s for any package not being re-specified by name
(so the solver keeps them present at all). The final `install()` call then
gets old + new together. Without this, `install(packages = "zstd")` on an
environment that already has `xz` would silently uninstall `xz` — the solve
would only know about `zstd`, and `Installer` would delete everything else in
the prefix as unwanted. Verified with the `xz` → `install("zstd")` smoke test
in `tests/testthat/test-install.R`.

## Wheel packages

Newer conda channels — `conda-pypi` chief among them — publish pure-Python
packages as raw `.whl` files (downloaded straight from
`files.pythonhosted.org`) instead of `.conda`/`.tar.bz2` archives.
`rattler_conda_types` (0.47/0.48) already models this at the type level
(`DistArchiveType::Wheel`, `RepoDataRecord.identifier`), and the solver
resolves `MatchSpec`s against wheel records without complaint — but neither
`rattler::install::Installer` nor `rattler_cache::package_cache` (as
published on crates.io at the time of writing) know how to fetch or link a
`.whl`. `rattlerthis` implements that itself, in
`src/rust/src/wheel.rs`, rather than waiting on upstream:

- `solve_and_install()` partitions the solver's resolved records into
  conda-format and wheel-format (`is_wheel()`, keyed off
  `identifier.archive_type`).
- Conda-format records go through `Installer` exactly as before.
- Wheel-format records are downloaded with a plain `reqwest::Client` (a
  direct dependency added just for this — everything else reuses whatever
  HTTP client `rattler_repodata_gateway` already needed) and extracted with
  the `zip` crate (a `.whl` is a plain zip archive). Each entry is placed
  under the environment's `site-packages` following the wheel install-scheme
  rules (PEP 427): plain files and `<dist>-<version>.dist-info/` go straight
  into `site-packages`; anything under `<dist>-<version>.data/<category>/` is
  redirected per `category` (`scripts` → the env's `bin`/`Scripts` dir,
  `purelib`/`platlib` → `site-packages`, `data` → the prefix root, `headers`
  → `include/`).
- `<dist>-<version>.dist-info/entry_points.txt`'s `[console_scripts]` section
  is parsed and turned into real executables by reusing rattler's own
  `EntryPoint::from_str` (already hardened against path traversal / command
  injection in the script body — see its `ParseEntryPointError` variants)
  and its `python_entry_point_template()` (the exact same script template
  `Installer` generates for `noarch: python` packages' own entry points).
  `get_windows_launcher()` is reused too, so Windows gets the same signed
  `.exe` launcher `Installer` would use — untested on Windows, like the rest
  of the crate; see TODO.md.
- The result is written as a normal `conda-meta/<name>-<version>-<build>.json`
  via `PrefixRecord::from_repodata_record().write_to_path()`, so `list_packages()`,
  `env_exists()`, and the next `create_env()`/`install()`'s `existing_records()`
  all see it exactly like any other installed package — no separate
  bookkeeping.
- Wheel packages require `python` to already be resolved into the same
  environment (to know the target `site-packages`/`bin` layout via
  `PythonInfo::from_python_record`); requesting one without `python` present
  fails with a clear `rattlerthis_error_install` telling the user to add it.

Two non-obvious fixes were needed to make `install()` work correctly on an
environment that already has a wheel package in it — both covered by
regression tests (`tests/testthat/test-wheel.R`,
`src/rust/src/install.rs`'s `install_after_wheel_does_not_panic`):

1. **`channels_with_existing()`**: `install()` defaults to
   `channels = "conda-forge"`. The "keep this package" bare-name spec
   generated for an already-installed `conda-pypi::cowsay` needs *some*
   channel that actually has `cowsay` in it to solve against — if the
   caller doesn't happen to re-list `conda-pypi` on every subsequent call,
   the solve fails as unsolvable. `solve_and_install()` now unions the
   requested `channels` with whatever channel each already-installed
   package's `RepoDataRecord.channel` says it actually came from, so a
   package's origin channel doesn't have to be remembered and repeated by
   the caller forever.
2. **No `Installer::with_installed_packages()` on a second install**:
   passing an explicit `Vec<PrefixRecord>` for "what's currently installed"
   (which seemed like the obvious way to tell `Installer` "these wheel
   conda-meta entries are real, don't remove them") routes `Installer`
   through a `Transaction`/`ClobberRegistry` code path
   (`path_resolver::PathResolver::reprioritize_packages`) that panics on a
   second `install()` into the same prefix, in rattler 0.46.0 — an upstream
   bug, not something wrong with the records themselves. `link_records()`
   instead leaves `Installer` on its own working auto-discovery
   (`PrefixRecord::collect_minimal_from_prefix`) and uses
   `Installer::with_ignored_packages()` with just the wheel package *names*,
   which is documented and tested upstream to leave those entries alone
   without needing the fuller (and apparently panic-triggering) explicit
   installed-packages path.

## Return values

`create_env()` and `install()` have no subprocess stdout/stderr to hand back
(there's no subprocess — the work happens in-process), so they return an S3
object of class `rattlerthis_result`: a list with `status`, `env_name`,
`prefix`, `packages` (a tibble of the records that ended up installed), and
`duration`. `run()` keeps `condathis`'s contract exactly: whatever
`processx::run()` returns (`status`, `stdout`, `stderr`, `timeout`), since it
really does spawn the target CLI as a subprocess.

## Error handling

Rust functions return `extendr_api::Result<T>`. Failures from `rattler`,
`rattler_solve`, or `rattler_repodata_gateway` (parse errors, unsolvable
environments, download/link failures) are wrapped in a single `RtError` enum
(`src/rust/src/error.rs`) with descriptive `Display` messages, converted to
`extendr_api::Error::Other(String)` at the R boundary. Solving and installing
happen inside one Rust call (see "Installation" above), so R can't
distinguish a solve failure from an install failure by error class alone —
both come back through the same bridge call. R-side wrappers catch and
rethrow as classed conditions — `rattlerthis_error_install`,
`rattlerthis_error_activate`, `rattlerthis_error_run` — via `rlang::abort()`,
so callers can `tryCatch()` on specific failure classes, matching
`condathis`'s `rethrow_error_*()` convention.

## R API surface

```r
create_env(
  packages = NULL, env_name = "rattlerthis-env",
  channels = "conda-forge",
  channel_priority = c("strict", "disabled"),
  platform = NULL, overwrite = FALSE, verbose = c("output", "silent", "cmd", "spinner", "full")
)

install(
  packages, env_name = "rattlerthis-env", channels = "conda-forge",
  channel_priority = c("strict", "disabled"),
  verbose = c("output", "silent", "cmd", "spinner", "full")
)

run(
  cmd, ..., env_name = "rattlerthis-env",
  verbose = c("output", "silent", "cmd", "spinner", "full"),
  error = c("cancel", "continue"), stdout = "|", stderr = "|", stdin = NULL
)
```

Supporting functions: `list_envs()`, `env_exists()`, `remove_env()`,
`list_packages()`, `get_env_dir()`, `get_install_dir()`.

Three deliberate departures from `condathis`:

- **Default channels** are `"conda-forge"` only, not
  `c("conda-forge", "bioconda")`. `condathis` defaults to bioinformatics
  channels because that's its primary use case; `rattlerthis` is
  general-purpose, so bioconda is opt-in (`channels = c("conda-forge", "bioconda")`).
- **`channel_priority`** only offers `"strict"`/`"disabled"`, defaulting to
  `"strict"` (resolvo's native behavior). `condathis` also exposes a
  `"flexible"` mode (a `micromamba`-specific behavior) and defaults to
  `"disabled"`; `rattler_solve`'s `ChannelPriority` enum has no flexible
  mode, so exposing the option here would be dishonest.
- **No `env_file` parameter yet.** `condathis::create_env()` accepts an
  `environment.yml`-style file; `rattlerthis` doesn't parse those yet, so
  the parameter isn't in the signature at all (a reserved-but-unimplemented
  parameter would violate "no half-finished implementations" — see
  TODO.md for when this lands).

## Verbosity

Reuses `condathis`'s `verbose` vocabulary
(`"output"|"silent"|"cmd"|"spinner"|"full"`) for anyone migrating from it. In
this milestone there is no solve/install progress reporting at all from the
Rust side — no `Reporter` is attached to the `Gateway` query or the
`Installer` — `verbose` only controls whether the R wrappers print a
before/after `cli::cli_inform()` message. A real `Reporter` streaming
progress back into R (see TODO.md) is the natural next step once the
happy path is solid.
