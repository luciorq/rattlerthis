# TODO

Status and roadmap for `rattlerthis`. See `PLAN.md` for the design behind
these decisions.

Dependency currency: the rattler-family crates (`rattler`,
`rattler_conda_types`, `rattler_solve`, `rattler_repodata_gateway`,
`rattler_shell`, `rattler_virtual_packages`, `rattler_cache`) ship from one
monorepo in lockstep and move fast. Last checked/bumped to latest 2026-07-10
(`rattler` 0.47.0, `rattler_conda_types` 0.48.0, `rattler_repodata_gateway`
0.30.0, plus lockfile-only patch bumps for the rest). When bumping again,
bump all of them together — mismatched versions across this family can
resolve to two copies of the same crate in the dependency graph and fail to
compile (hit this once with a scratch probe project during development).

## Milestone: v0.1 (done)

Goal: `create_env()`, `install()`, and `run()` work end to end for the
native platform against `conda-forge`. Verified 2026-07-08 with a real
network solve/install/run/remove cycle (`xz`, then adding `zstd` via
`install()`) and the `testthat` suite (`NOT_CRAN=true`, 32/32 passing).

- [x] Package skeleton scaffolded with `rextendr::use_extendr()`
- [x] `DESCRIPTION`, `LICENSE`, `README.md`
- [x] `PLAN.md` design doc
- [x] `src/rust/Cargo.toml` with rattler dependencies; `cargo build` green
      standalone
- [x] Rust: `runtime.rs` — lazy global tokio runtime
- [x] Rust: `error.rs` — error type + conversion to `extendr_api::Error`
- [x] Rust: `install.rs` — gateway repodata fetch + resolvo solve +
      `rattler::install::Installer`, combined into one `solve_and_install()`
      (solve and install turned out tightly coupled enough in v0.1 that a
      separate `solve.rs` would just be a pass-through; revisit if/when
      solving without installing becomes a use case, e.g. for lockfiles)
- [x] Rust: `activation.rs` — `rattler_shell::Activator` wrapper, returns
      named env vars
- [x] R: `create-env.R`, `install.R`, `run.R`, `env-utils.R`, `verbose.R`,
      `rethrow-error.R`, `result.R` (no `zzz.R` needed — `useDynLib` in the
      generated `extendr-wrappers.R` is sufficient, no extra `.onLoad` logic
      required)
- [x] `devtools::document()` + `devtools::load_all()` succeed
- [x] Smoke test: `create_env(packages = "xz")` →
      `run("xz", "--version")` → `install(packages = "zstd")` →
      `remove_env()` against the real conda-forge network
- [x] `testthat` scaffolding (network tests behind `skip_if_offline()` /
      `skip_on_cran()`, mirroring `condathis`)

Deliberate deviations from the original plan, discovered while implementing:

- `channel_priority` only offers `"strict"`/`"disabled"` (not `"flexible"`
  like condathis) — `rattler_solve`'s `ChannelPriority` enum doesn't
  implement a flexible mode, so exposing the option would be dishonest.
- `list_packages()` reads `conda-meta/*.json` directly in R (via
  `jsonlite`) instead of going through a Rust bridge function — it's a
  plain directory-and-JSON read with no solving/installing involved, so a
  Rust round-trip would add nothing.

## Fixed bugs

- **2026-07-09 — solving failed for any package with a `noarch` dependency**
  (reported as "environment solving is not working on macOS arm64", but not
  actually platform-specific). `solve_and_install()` in
  `src/rust/src/install.rs` queried the gateway for `vec![platform]` only;
  channels split packages between a platform subdir and a sibling `noarch`
  subdir, and the gateway doesn't add `noarch` on its own. Any dependency
  chain touching a noarch package (`pip`, `setuptools`, `tzdata`, most of
  the Python ecosystem) came back "unsolvable". Invisible during initial
  testing because the smoke test only used compiled-only packages (`xz`,
  `zstd`), which never touch noarch. Fixed by querying
  `[platform, Platform::NoArch]`. See PLAN.md ("Repodata fetching and
  solving") and the regression test in `tests/testthat/test-create-env.R`.
- **2026-07-10 — `install()` broke after a wheel package was present**. Two
  separate bugs, both hit while adding wheel support (see the new milestone
  below): (1) `install()`'s default `channels = "conda-forge"` didn't
  include whatever channel an existing wheel package came from, so the
  "keep it installed" spec was unsolvable; fixed by
  `channels_with_existing()` unioning in each existing record's actual
  channel. (2) Passing an explicit installed-packages list to `Installer`
  on a second `install()` into the same prefix panicked inside rattler's
  `ClobberRegistry`/`path_resolver` (confirmed on both 0.46.0 and 0.47.0);
  fixed by using `Installer::with_ignored_packages()` instead, which
  doesn't hit that code path. See PLAN.md ("Wheel packages") and the
  regression tests in `tests/testthat/test-wheel.R` /
  `src/rust/src/install.rs`'s `install_after_wheel_does_not_panic`.

## Milestone: wheel packages (`conda-pypi` channel) (done)

Now gated behind the `wheels` Cargo feature (default off) as of the CRAN
vendoring work — see PLAN.md "Vendoring and CRAN size". `cargo build
--features wheels` re-enables it; the R-level API and generated
`extendr-wrappers.R` are unaffected either way (`rt_install`'s signature
doesn't change — only what happens internally when a solve returns a
wheel-format record).

Goal: packages resolved from a wheel-format channel (raw `.whl`, as served
by `conda-pypi` and similar) install correctly, since `rattler`'s own
`Installer`/`PackageCache` don't support that yet as published on crates.io.
Verified 2026-07-10 with a real network solve/install/run cycle
(`python` + `conda-pypi::cowsay`, including running its `console_scripts`
entry point) and `tests/testthat/test-wheel.R`.

- [x] `src/rust/src/wheel.rs` — download, extract, place under
      `site-packages` per the wheel install-scheme rules, generate
      `console_scripts` entry points, write a `conda-meta/*.json`
- [x] `solve_and_install()`/`link_records()` partition conda vs. wheel
      records; `Installer` only ever sees the conda side
- [x] `channels_with_existing()` — re-solving no longer requires the caller
      to keep repeating every channel a previously-installed package came
      from
- [x] `install()` after a wheel package present: no unsolvable errors, no
      panics, wheel package survives

Known limitations specific to wheel support (separate from the general
list below):

- Only `console_scripts` entry points are generated; `gui_scripts` and other
  entry-point groups (rare for CLI-style packages, which is `rattlerthis`'s
  focus) are ignored.
- No wheel content verification: neither the file hash embedded in the
  `RepoDataRecord` nor the wheel's own `RECORD` file hashes are checked
  against what was actually downloaded.
- `.data/data/` and `.data/headers/` wheel categories are mapped per PEP 427
  but not exercised by any test — pure-Python packages needing them are
  uncommon.
- No pruning: if a solve legitimately drops a wheel package (a real conflict
  forces its removal, not just "wasn't re-specified"), the old
  `conda-meta/*.json` and its files are not cleaned up. This mirrors
  `Installer`'s own all-or-nothing semantics for conda packages in v0.1 (see
  "Later ideas" below) rather than being wheel-specific, but hasn't been
  exercised for wheels specifically.
- Compiled (non-pure-Python) wheels aren't a concern today since
  `conda-pypi` itself only serves pure-Python wheels, but nothing in
  `wheel.rs` checks a wheel's platform/ABI tag against the target
  environment — if a future wheel channel serves compiled wheels, they'd be
  extracted as-is with no compatibility check.

## Milestone: `condathis` backend adapter (done, 2026-07-15)

Goal: make `rattlerthis` a conforming backend for `condathis`'s in-progress
pluggable-backend system, as a standalone adapter that's fully testable
without `condathis` needing to exist yet. See
`.github/devdocs/feat-rattlerthis-backend/{PLAN,TODO}.md` for the full
design and status — real wiring into `condathis` (S3 method registration,
`.onLoad()` hookup) is deferred there until `condathis`'s own
backend-abstraction milestone ships.

## Deferred (known limitations, not yet implemented)

- **Interrupt handling**: a blocking `block_on()` solve/install cannot be
  cancelled by Ctrl+C from R. Needs polling `R_CheckUserInterrupt()` against
  a `tokio::task::JoinHandle` instead of a plain `block_on`.
- **Cross-platform solving**: the `platform =` argument is accepted but only
  same-platform solving is exercised. Needs virtual-package injection for
  the *target* platform rather than the *host* platform, and validation that
  linking makes sense for non-native platforms (it generally doesn't outside
  of `--platform noarch`).
- **Non-HTTPS channels**: only plain `https://conda.anaconda.org`-style
  channels are supported. No S3, OCI, git, or local-path channels yet
  (`rattler_repodata_gateway`/`rattler_networking` support these; just not
  wired up).
- **Lockfiles**: no `rattler_lock` support (`create_env(lockfile = ...)` /
  exporting a solved environment to a lockfile).
- **Post-link / pre-unlink scripts**: `Installer` runs with
  `execute_link_scripts = false`. Packages that rely on these for
  correctness may end up incompletely configured.
- **Progress reporting**: no `Reporter` is attached to the `Gateway` query or
  the `Installer` at all yet — `verbose` only toggles R-side
  before/after messages, there's no per-download/per-link progress. See the
  `PyReporter` pattern in `py-rattler`'s `installer.rs` for prior art on
  bridging this back into a caller-supplied callback.
- **CRAN packaging**: MSRV pin exists (`tools/msrv.R`), but no
  `R CMD check --as-cran` pass yet. Installation is GitHub-only for now and
  requires a working Rust toolchain on the user's machine.
  - [x] Vendoring story: `src/rust/vendor.tar.xz`, built with
        `cargo vendor-filterer` (platform-filtered to the 5 triples actually
        shipped, `--keep-dep-kinds=no-dev`) against the `native-tls`
        (not `rustls`) feature set, default (non-`wheels`) features only.
        445 crates/60MB compressed/954MB unpacked → 412 crates/14MB
        compressed/184MB unpacked. Verified: `cargo build --offline`
        against the regenerated tree succeeds; `cargo test --lib` passes
        with and without `--features wheels`. See PLAN.md "Vendoring and
        CRAN size".
  - [ ] `DESCRIPTION`'s `SystemRequirements` should mention OpenSSL
        (Linux only — macOS/Windows use native-tls with zero extra system
        deps) now that the TLS backend is `native-tls`, not `rustls`.
  - [ ] Verify the regenerated vendor tree offline-builds on a real Windows
        (`x86_64-pc-windows-gnu`/Rtools) and macOS (both arm64 and x86_64)
        machine, not just cross-checked logically on Linux — the platform
        list passed to `cargo vendor-filterer` was chosen from
        `Makevars.win.in`'s target triple and known R-for-macOS
        architectures, not verified by an actual cross/native build on
        those OSes.
  - [ ] `cran-comments.md`: preemptively justify the vendored tarball size
        to CRAN reviewers (offline build requirement, not a choice) rather
        than waiting for a reviewer to ask. Precedent to keep in mind:
        `r-polars` never made it onto CRAN and distributes via r-universe
        instead, specifically over vendored-dependency size — this may
        still be a viable fallback if CRAN pushes back even after the
        above.
  - [ ] `cargo tree --duplicates` (or `cargo-deny`'s duplicate-version
        check) as a CI step, so re-vendoring doesn't silently regrow
        version drift (`hashbrown` currently resolves to 4 different
        versions, `rand`/`getrandom`/`thiserror` to 2 each).
  - [ ] No `R CMD check --as-cran` pass yet (`just check` exists but hasn't
        been run against this vendoring setup end-to-end).
- **`env_file` support in `create_env()`**: not in the signature yet
  (`environment.yml`-style specs aren't parsed). Add the parameter when the
  parsing is actually implemented, not before.
- **Windows support**: `rattler_shell`/`Activator` support Windows shells,
  but this hasn't been build- or run-tested on Windows yet.
- **macOS build dependencies**: haven't confirmed the Rust crate builds
  cleanly on macOS arm64 from a clean toolchain (Xcode CLT version, whether
  `aws-lc-sys`/`ring` pull in a `cmake`/`nasm` requirement transitively via
  the TLS stack). Worth a clean-machine build check before calling macOS
  arm64 supported.

## Later ideas (not scheduled)

- Package cache pruning / `clean_cache()` equivalent to `condathis::clean_cache()`.
- Dependency-satisfaction short-circuiting like `condathis::satisfies_dependencies()`,
  so `create_env()` skips resolving when the env already matches the request.
- Exposing `rattler_virtual_packages` detection results directly
  (`detect_virtual_packages()`) for users who want to inspect solver inputs.
