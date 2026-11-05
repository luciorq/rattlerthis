# TODO

Status and roadmap of `rattlerthis`, condathis's `"rattler"` backend. See
`PLAN.md` for the design.

Dependency currency: the rattler-family crates (`rattler`,
`rattler_conda_types`, `rattler_solve`, `rattler_repodata_gateway`,
`rattler_shell`, `rattler_virtual_packages`, `rattler_cache`) ship from one
monorepo in lockstep and move fast. Last bumped 2026-08-28 (`rattler`
0.48.6, `rattler_conda_types` 0.52.1, `rattler_solve` 9.0.5,
`rattler_repodata_gateway` 0.33.2, `rattler_virtual_packages` 6.0.0). Bump
them together: mismatched versions can resolve to two copies of one crate
and fail to compile. After every bump run `just update-vendor` and
`just check-msrv` (MSRV 1.88, CRAN's lowest flavour is 1.91.1), and check
whether the gateway still emits duplicate records (below).

## Done (history, short)

- **2026-07, v0.1**: solve, install, activate and run against conda-forge
  from R, with a front end of its own. Replaced in October 2026 (below).
- **2026-07-09**: solves query `[platform, noarch]`; any dependency chain
  through a `noarch` package (pip, tzdata) was unsolvable before.
- **2026-07-10 / 08-13, wheels**: `wheel.rs` installs `.whl` records
  (`conda-pypi`), behind the `wheels` Cargo feature (off by default);
  `dedup_repodata()` works around the gateway's `DuplicateRecords` from
  `.recursive(true)` (byte-identical copies of a record in one set).
- **2026-07 to 2026-10, condathis adapter** for the first backend
  contract: see `.github/devdocs/feat-rattlerthis-backend/TODO.md`.
- **2026-08-12, dev rextendr / extendr toolchain**: `document.c` instead of
  a second `cargo run`, `extendr-api` pinned to a git rev,
  `@WINDOWS_TARGET@`, quoted paths, wrapper regeneration only for
  development builds while documenting (`@DOCUMENT_FLAG@`, `ROXYGEN_PKG`),
  and the `$(NATIVE_LIBS)` capture fixed for from-scratch builds.
- **2026-08, CRAN groundwork**: MSRV corrected to 1.88 and monitored
  (`just check-msrv`); `GNU make` and OpenSSL in `SystemRequirements`;
  `tools/config.R` checks `pkg-config` + OpenSSL on Linux; `native-tls`
  instead of `rustls`; `cargo vendor-filterer` per shipped triple; crate
  contents stripped; rustc's `native-static-libs` linked into the package.
- **2026-10-22, build fixes**: per-platform vendoring merge with a stub
  guard; a vendor marker so a failed build never reuses a stale tree;
  Windows import libraries copied into `$(LIBDIR)`.
- **2026-10-27 / 28, condathis contract v2** (the backend spec's units):
  - RT-1 / RT-2 (Rust): jobs with phases and cancel, a fork-aware runtime,
    `prefetch` before the prefix changes, libmamba's pins, a prefix lock,
    timeouts and retries, a killable activation with an `sh` fallback,
    history lines, link-script detection, the cache cleaner, environment
    files (YAML, explicit, plain, conda-lock), virtual packages of the
    target platform.
  - RT-3 (R): the front end, the root variable and option, and the 6
    hand-synced copies of condathis code are deleted; 7 backend functions
    over the Rust jobs; condathis's defaults for the rest.
  - RT-4: the test suite through condathis (both backends for parity).
  - RT-5: CI for Linux, macOS, Windows x64 and Windows on ARM64; README;
    these devdocs; `Makevars.win.in` reads link-search directories one per
    line (paths with spaces).
- Built and tested on Linux, macOS arm64 (CRAN R) and Windows x64
  (Rtools45, `x86_64-pc-windows-gnu` host toolchain); the
  `aarch64-pc-windows-gnullvm` cross build links into an ARM64 DLL that
  imports only system DLLs and `R.dll`.

## Open

- [ ] First run of `.github/workflows/win-arm64.yaml` on `windows-11-arm`:
      the ARM64 DLL has only been cross-built and linked so far, never
      loaded or tested natively.
- [ ] First run of `.github/workflows/R-CMD-check.yaml`. Both need the
      condathis ref of `Remotes` pushed (pin a SHA once it is).
- [ ] `R CMD check --as-cran` with tests. A local run on Linux
      (2026-10-28, release build, `--no-tests`) had no error; its WARNING
      (no `checkbashisms` script) and NOTEs (no network time, the
      conda-forge toolchain's `-march=nocona`) came from that machine.
- [ ] `cran-comments.md`: justify the vendored tarball (31.8MB now, see
      PLAN.md "Vendoring and CRAN size"); if refused, the policy's hosted
      bundle with an embedded sha256 (not GitHub), then r-universe.
- [ ] `cargo tree --duplicates` (or `cargo-deny`) as a CI step, so
      re-vendoring does not regrow version drift.
- [ ] No CI step detects a stale `vendor.tar.xz` after a
      `Cargo.toml` / `Cargo.lock` change.
- [ ] Report upstream to `conda/rattler`, and drop `dedup_repodata()` once
      the gateway stops emitting duplicate records (still present in
      `rattler_repodata_gateway` 0.33.2). Rider: ask for feature gates on
      `rattler_menuinst` and `rattler_pty` (about 0.27MB compressed).
- [ ] Channels other than HTTP(S) and local directories (S3, OCI, git) are
      not wired up; proxy, custom CA and channel-token settings of
      micromamba are not read (a token in the URL works).
- [ ] Progress: no per-download or per-link progress, only a spinner.
- [ ] Wheel limitations: only `console_scripts` entry points; no hash
      check of the downloaded wheel or its `RECORD`; `.data/data` and
      `.data/headers` untested; no platform/ABI check of compiled wheels.
- [ ] The differences from micromamba that could be closed are listed in
      `?rattlerthis` and in the backend spec's difference table (pip in
      environment files, PyPI packages in `list_packages()`, `.pyc`
      compilation, `defaults::pkg` specs, file modes under a umask other
      than 022, proxy and token settings).
