# rattlerthis

<!-- badges: start -->
<!-- badges: end -->

`rattlerthis` is the `"rattler"` backend of
[`condathis`](https://github.com/luciorq/condathis). It solves, installs
and activates 'Conda' environments inside the R process, through the Rust
library [`rattler`](https://github.com/conda/rattler) (the engine behind
`pixi`), bound to R with [`rextendr`](https://extendr.rs/rextendr/). There
is no package manager binary to download.

`rattlerthis` exports no functions. Everything a user does goes through
`condathis` with `method = "rattler"`: the arguments, checks, messages,
results and error classes are those of `condathis`.

## Installation

Building from source needs a Rust toolchain, `rustc` >= 1.88.0 and `cargo`
(<https://rustup.rs>), plus:

- Linux: `pkg-config` and the OpenSSL development headers (`libssl-dev` or
  `openssl-devel`);
- Windows x64: Rtools45 and the GNU host toolchain of Rust
  (`rustup default stable-x86_64-pc-windows-gnu`). With the MSVC host, the
  C code of the `zstd-sys` crate would need an `x86_64-w64-mingw32-gcc`
  that Rtools45 does not have;
- Windows on ARM64 (native ARM64 R): Rtools45 for aarch64 and the
  target `aarch64-pc-windows-gnullvm`
  (`rustup target add aarch64-pc-windows-gnullvm`);
- macOS: the Xcode command line tools.

```r
# install.packages("pak")
pak::pak("luciorq/rattlerthis")
```

This also installs the `condathis` version that `rattlerthis` needs. The
build downloads the Rust crates it needs from crates.io and GitHub.

## Usage

```r
library(condathis)

create_env("ripgrep", env_name = "rg", method = "rattler")
run("rg", "--version", env_name = "rg")
list_envs(method = "rattler")
remove_env("rg", method = "rattler")
```

`condathis` loads `rattlerthis` when `method = "rattler"` is used, and when
rattler environments exist, so `method = "auto"` finds them without loading
anything by hand.

The environments and rattler's caches live in
`condathis::backend_root_dir("rattler")`, the `rattler` directory inside
`condathis`'s data directory. `condathis::with_sandbox_dir()` moves it with
the rest of `condathis`'s directories, and `condathis::clean_cache()`
cleans rattler's caches too.

`rattlerthis` has no options and no environment variables of its own.
`condathis`'s settings apply, and the generic Conda variables
`CONDA_OVERRIDE_*` are honored, as micromamba honors them.

## Differences from the micromamba backend

Both backends behave the same wherever possible: commands run in the
same activated environment (also one given by `env_path()`), activations
are cached, pip sections of environment files are installed and listed
alike, and `condathis` lets one R session at a time change an
environment. The main differences:

- rattler never runs the `pre-link`, `post-link` and `pre-unlink` scripts
  of packages; `condathis` warns and names the packages
  (`condathis_link_scripts_skipped`). micromamba runs them. `activate.d`
  scripts run with both.
- No `.pyc` compilation of `noarch` Python packages at install time.
- No command line: the verbose level `"cmd"` prints a one-line
  description, and the results of `create_env()` and `install_packages()`
  have `NA` in `cmd` and `pid`, and in `stderr` unless pip steps ran (then
  pip's standard error).
- Errors carry `condathis`'s classes; the parent condition has rattler's
  (`rattlerthis_rattler_<kind>`) instead of micromamba's status classes.
- The command's environment: micromamba's activation also sets variables
  of its own (`MAMBA_EXE`, a `condabin` directory on `PATH`; `LC_ALL` on
  Linux and macOS; `PYTHONUTF8` and others on Windows).
- Ctrl-C stops a solve or a download at once, but waits for a link that
  has started.
- Separate package caches, a `CACHEDIR.TAG` in every environment, and
  paths 8 characters longer than micromamba's.
- Network settings are micromamba's (proxy variables, CA certificates,
  `~/.mamba/auth/authentication.json`, `.netrc`); retries and time-outs
  differ.

`?rattlerthis` lists the differences a user may notice.

## Development

The test suite runs with `NOT_CRAN=true` and must end with 0 failures, 0
errors and exactly 2 skips: the two wheel tests, which skip because the
`wheels` Cargo feature is off by default. The parity tests compare both
backends with the micromamba binary named by `CONDATHIS_MICROMAMBA_PATH`;
some download from conda-forge. CI (`.github/workflows/`) runs the check
and that test step on Linux, macOS, Windows x64 and Windows on ARM64.

The vendored Rust crates, `src/rust/vendor.tar.xz` (written by
`just update-vendor`), are not in git. A build without them downloads
the crates from crates.io, as CI does; with them, the build is offline.
