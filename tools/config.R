# Note: Any variables prefixed with `.` are used for text
# replacement in the Makevars.in and Makevars.win.in

# On Linux, TLS is provided by `native-tls` linking system OpenSSL via
# `openssl-sys`, which needs `pkg-config` and OpenSSL's *development*
# headers (not just the runtime shared library) at build time -- see
# PLAN.md "Vendoring and CRAN size" for why `native-tls` instead of
# `rustls`. macOS/Windows use their own native TLS (Secure Transport /
# SChannel) and need nothing extra here. Checked before anything else so a
# missing system dependency fails fast with an actionable message instead
# of surfacing as a wall of `cargo`/`openssl-sys` build-script output deep
# in the Rust compile log.
if (Sys.info()[["sysname"]] == "Linux") {
  pkg_config_found <- nzchar(Sys.which("pkg-config"))
  openssl_found <- pkg_config_found &&
    system2("pkg-config", c("--exists", "openssl"), stdout = FALSE, stderr = FALSE) == 0L
  if (!openssl_found) {
    stop(
      "rattlerthis needs `pkg-config` and OpenSSL development headers to ",
      "build on Linux (used for TLS via `native-tls`). Install them, e.g.:\n",
      "  Debian/Ubuntu: sudo apt-get install -y pkg-config libssl-dev\n",
      "  Fedora/RHEL:   sudo dnf install -y pkg-config openssl-devel\n",
      "  Alpine:        sudo apk add pkgconfig openssl-dev\n",
      "then retry. See DESCRIPTION's SystemRequirements.",
      call. = FALSE
    )
  }
}

# check the packages MSRV first
source("tools/msrv.R")

# check DEBUG and NOT_CRAN environment variables
env_debug <- Sys.getenv("DEBUG")
env_not_cran <- Sys.getenv("NOT_CRAN")

# check if the vendored zip file exists
vendor_exists <- file.exists("src/rust/vendor.tar.xz")

is_not_cran <- env_not_cran != ""
is_debug <- env_debug != ""

if (is_debug) {
  # if we have DEBUG then we set not cran to true
  # CRAN is always release build
  is_not_cran <- TRUE
  message("Creating DEBUG build.")
}

if (!is_not_cran) {
  message("Building for CRAN.")
}

# we set cran flags only if NOT_CRAN is empty and if
# the vendored crates are present.
.cran_flags <- ifelse(
  !is_not_cran && vendor_exists,
  "-j 2 --offline",
  ""
)

# when DEBUG env var is present we use `--debug` build
.profile <- ifelse(is_debug, "", "--release")
.clean_targets <- ifelse(is_debug, "", "$(TARGET_DIR)")

# Whether to regenerate `R/extendr-wrappers.R` during the build.
#
# The generated file is committed to the repo, so regenerating it during
# `R CMD INSTALL` is redundant for an end-user install and actively harmful
# on CRAN: it writes *into the package source tree*, which CRAN discourages
# and which fails outright when the source is unpacked read-only. It also
# costs an extra compile+link of `rust/document.c` for no benefit.
#
# So: regenerate only for development builds (NOT_CRAN/DEBUG, which is what
# `devtools::load_all()` and `just document` set), and on CRAN just use the
# committed wrappers. Keeping the committed file in sync is a dev-time
# responsibility -- `just document` regenerates it, and any change to an
# `#[extendr]` signature that isn't re-documented shows up as a mismatch
# between `R/extendr-wrappers.R` and the compiled symbols.
.document_flag <- ifelse(is_not_cran, "1", "")

# We specify this target when building for webR
webr_target <- "wasm32-unknown-emscripten"

# here we check if the platform we are building for is webr
is_wasm <- identical(R.version$platform, webr_target)

# print to terminal to inform we are building for webr
if (is_wasm) {
  message("Building for WebR")
}

# we check if we are making a debug build or not
# if so, the LIBDIR environment variable becomes:
# LIBDIR = $(TARGET_DIR)/{wasm32-unknown-emscripten}/debug
# this will be used to fill out the LIBDIR env var for Makevars.in
target_libpath <- if (is_wasm) "wasm32-unknown-emscripten" else NULL
cfg <- if (is_debug) "debug" else "release"

# used to replace @LIBDIR@
.libdir <- paste(c(target_libpath, cfg), collapse = "/")

# use this to replace @TARGET@
# we specify the target _only_ on webR
# there may be use cases later where this can be adapted or expanded
.target <- ifelse(is_wasm, paste0("--target=", webr_target), "")

# add panic exports only for WASM builds
.panic_exports <- ifelse(
  is_wasm,
  "CARGO_PROFILE_DEV_PANIC=\"abort\" CARGO_PROFILE_RELEASE_PANIC=\"abort\" ",
  ""
)

# read in the Makevars.in file checking
is_windows <- .Platform[["OS.type"]] == "windows"

# Rust target triple to build for on Windows. Picked from what R itself was
# built as/with rather than hardcoded, because Rtools' toolchain differs
# across R versions and architectures:
#   - Windows on ARM64 (R 4.6+) needs `aarch64-pc-windows-gnullvm`
#   - Rtools built with clang (UCRT/LLVM) needs `x86_64-pc-windows-gnullvm`;
#     matching the CRT matters, a gnu/gnullvm mismatch shows up as duplicate
#     symbols or runtime crashes rather than a clean link error
#   - 32-bit R (pre-4.2) needs `i686-pc-windows-gnu`
#   - everything else is the classic `x86_64-pc-windows-gnu`
# These four triples are also what `just update-vendor` filters the vendored
# crate tree to, so keep the two lists in sync. Mirrors the upstream rextendr
# dev template.
.windows_target <- if (grepl("aarch", R.version$platform)) {
  "aarch64-pc-windows-gnullvm"
} else if (grepl("clang", Sys.getenv("R_COMPILED_BY"))) {
  "x86_64-pc-windows-gnullvm"
} else if (grepl("i386", R.version$platform)) {
  "i686-pc-windows-gnu"
} else {
  "x86_64-pc-windows-gnu"
}

# if windows we replace in the Makevars.win.in
mv_fp <- ifelse(
  is_windows,
  "src/Makevars.win.in",
  "src/Makevars.in"
)

# set the output file
mv_ofp <- ifelse(
  is_windows,
  "src/Makevars.win",
  "src/Makevars"
)

# delete the existing Makevars{.win/.wasm}
if (file.exists(mv_ofp)) {
  message("Cleaning previous `", mv_ofp, "`.")
  invisible(file.remove(mv_ofp))
}

# read as a single string
mv_txt <- readLines(mv_fp)

# replace placeholder values
new_txt <- gsub("@CRAN_FLAGS@", .cran_flags, mv_txt) |>
  gsub("@PROFILE@", .profile, x = _) |>
  gsub("@DOCUMENT_FLAG@", .document_flag, x = _) |>
  gsub("@WINDOWS_TARGET@", .windows_target, x = _) |>
  gsub("@CLEAN_TARGET@", .clean_targets, x = _) |>
  gsub("@LIBDIR@", .libdir, x = _) |>
  gsub("@TARGET@", .target, x = _) |>
  gsub("@PANIC_EXPORTS@", .panic_exports, x = _)

message("Writing `", mv_ofp, "`.")
con <- file(mv_ofp, open = "wb")
writeLines(new_txt, con, sep = "\n")
close(con)

message("`tools/config.R` has finished.")
