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

- [x] `.github/workflows/win-arm64.yaml` on `windows-11-arm`: the first
      run (2026-11-05, run 41948564276) built, loaded and tested the ARM64
      DLL natively, with 11 test failures and a failed DLL check step. With
      the fixes of PR #2 (python 3.14 where conda-forge has no 3.12 for
      win-arm64, the quoted platform in the emulation message, `cygpath -m`
      for `llvm-objdump`), run 41961267989 passed: 0 failures, 0 errors,
      2 skips, and the DLL check. The environment a failing pip step had
      left behind under x64 emulation is gone with native python.
- [x] First run of `.github/workflows/R-CMD-check.yaml`: passed on Linux,
      macOS and Windows x64 (2026-11-05, run 41948564235). `Remotes` names
      condathis's `main` branch; pin a SHA if `main` breaks it.
- [ ] `R CMD check --as-cran` with tests. A local run on Linux
      (2026-10-28, release build, `--no-tests`) had no error; its WARNING
      (no `checkbashisms` script) and NOTEs (no network time, the
      conda-forge toolchain's `-march=nocona`) came from that machine.
- [ ] `cran-comments.md`: justify the vendored tarball (35.0MB on
      2026-11-05, about 3x the largest accepted Rust package, `tok` at
      11.6MB; see PLAN.md "Vendoring and CRAN size"). If refused, download
      it from Zenodo with an embedded sha256 (PLAN.md "Releasing the
      vendored tarball").
- [ ] Vendored-tarball release tooling, before the first CRAN submission
      (PLAN.md "Checksum tooling"): record sha256, size, crate count and
      the `Cargo.lock` sha256 of each released tarball in a committed
      file; a `just verify-vendor` recipe that checks the Zenodo copy;
      a verified Zenodo download in `tools/config.R` when the tarball is
      missing; ideally a reproducible archive (fixed `tar` metadata and
      `xz` threads).
- [ ] A Zenodo record for `vendor.tar.xz`, with one version per released
      tarball (each CRAN submission or update, and each major release).
- [ ] `LICENSE.note` for the authorship and copyright of the vendored
      crates, as CRAN's Rust policy requires: `rextendr::write_license_note()`,
      regenerated with each released tarball.
- [x] Register `rattlerthis` in `luciorq.r-universe.dev` (`packages.json`)
      for binaries on every platform, including Windows on ARM64. The
      first builds (PLAN.md "r-universe builds"): on 2026-11-05 (run
      41963069103, `8699e99`) every platform failed to load the package,
      because r-universe installed condathis 0.1.4 from CRAN and
      rattlerthis needs >= 0.2.0. The next build (run 41971824155,
      `447318e`) failed only on the five Windows targets, in
      `test-parity-childenv.R` (paths such as `c://r//bin`): the condathis
      bug fixed in condathis `52e241f`. Its rebuild as a reverse dependency
      of condathis (2026-11-06, run 42297699059) passed 13 of 14 binaries,
      Windows x64 included (no `zstd-sys` problem), and WebAssembly built
      without Rust.
- [ ] macOS x86_64, R 4.6.2 on r-universe (2026-11-06, run 42297699059,
      job 128170186393): R segfaulted (`address 0x0`) after 10 minutes of
      `tests/testthat.R`, inside `fs::dir_ls()` called from
      `backend_has_env_dirs("micromamba")`. The same commit passed on macOS
      x86_64 R 4.5.3, macOS arm64 and every other platform. Not yet known
      if it repeats: only an r-universe admin can re-run the job, so the
      next build (a push to `main`) shows it. If it repeats, reproduce on
      an Intel Mac (omicron is arm64), for example under ASan.
- [x] WebAssembly fails gracefully (2026-11-05): `tools/config.R` builds
      only `src/wasm/init.c` on webR, and the package registers a backend
      that is never available and aborts with `rattlerthis_rust_unavailable`
      (`test-rust-unavailable.R`). rattler does not compile for
      `wasm32-unknown-emscripten` (`mio`, through tokio's `net`).
- [ ] Move the `extendr-api` git pin (`74afddc`) to the first extendr
      release that contains #1101 (the `write__make_<module>_wrappers` C
      entry point), and then to crates.io. Not in 0.9.0 or 0.8.2
      (re-checked 2026-11-05).
- [x] rextendr is a development tool only (2026-11-05): `Config/Needs/dev`
      names the CRAN `rextendr`, and `Config/rextendr/version` is 0.5.0
      (0.5.0.9000 does not exist, and made rextendr warn).
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
