//! Virtual packages, built the way libmamba 2.10 builds them
//! (`libmamba/src/core/virtual_packages.cpp`, `get_virtual_packages()`), so
//! a solve sees the same `__*` packages as micromamba's:
//!
//! - the target platform `<os>-<arch>` decides which packages exist; a
//!   platform without a `-` (`noarch`) has none but `__cuda`;
//! - `win`: `__win`; `linux`: `__unix`, `__linux` and `__glibc`; `osx`:
//!   `__unix` and `__osx`; `emscripten`: `__unix`; every platform:
//!   `__archspec`;
//! - a version comes from `CONDA_OVERRIDE_<NAME>` when that variable is set
//!   (also to a target that is not this machine's OS, and also when empty),
//!   else from this machine when it runs that OS, else it is `0`; `__glibc`
//!   is left out instead when its version is empty or this machine is not
//!   Linux;
//! - `__archspec` has version `1` and the build string
//!   `CONDA_OVERRIDE_ARCHSPEC` (taken verbatim), else the x86-64
//!   microarchitecture level of this CPU (`x86_64_v4` ... `x86_64`) for a
//!   `*-64` target, `x86` for `*-32`, else the platform's architecture
//!   (`arm64`, `aarch64`, `ppc64le`, ...);
//! - `__cuda` from `CONDA_OVERRIDE_CUDA` or this machine's driver, for any
//!   target; no `__cuda_arch` (libmamba has none).
//!
//! rattler's own `VirtualPackages::detect_for_platform()` differs: it uses
//! archspec microarchitecture names (`skylake_avx512`, `m1`), assumes
//! default OS versions for other targets, keeps `CONDA_OVERRIDE_OSX` and
//! `CONDA_OVERRIDE_WIN` for a Linux target, and rejects archspec names it
//! does not know.

use std::path::Path;
use std::str::FromStr;

use rattler_conda_types::{GenericVirtualPackage, PackageName, Platform, Version};
use rattler_virtual_packages::{Cuda, LibC, Linux, Osx, Windows};

use crate::error::{RtError, RtResult};

/// `CONDA_OVERRIDE_<NAME>`, when set (possibly to an empty string).
fn env_override(name: &str) -> Option<String> {
    std::env::var_os(format!("CONDA_OVERRIDE_{}", name.to_ascii_uppercase()))
        .map(|v| v.to_string_lossy().into_owned())
}

/// libmamba's `make_virtual_package()`: an empty version or build string
/// becomes `0`.
fn make(name: &str, version: &str, build: &str) -> RtResult<GenericVirtualPackage> {
    let version = if version.is_empty() { "0" } else { version };
    let build = if build.is_empty() { "0" } else { build };
    let parsed = Version::from_str(version).map_err(|e| {
        RtError::VirtualPackages(format!("invalid version {version:?} for {name}: {e}"))
    })?;
    Ok(GenericVirtualPackage {
        name: PackageName::new_unchecked(name),
        version: parsed,
        build_string: build.to_string(),
    })
}

fn host_windows_version() -> Option<String> {
    Windows::current()
        .and_then(|w| w.version)
        .map(|v| v.to_string())
}

fn host_linux_version() -> Option<String> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    Linux::current().ok().flatten().map(|l| l.version.to_string())
}

fn host_glibc_version() -> Option<String> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    LibC::current()
        .ok()
        .flatten()
        .filter(|libc| libc.family.eq_ignore_ascii_case("glibc"))
        .map(|libc| libc.version.to_string())
}

fn host_osx_version() -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    Osx::current().ok().flatten().map(|o| o.version.to_string())
}

/// libmamba's `get_archspec_x86_64()`: the x86-64 microarchitecture level of
/// this CPU (`x86_64` on a CPU that is not x86-64).
pub fn x86_64_level() -> &'static str {
    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::is_x86_feature_detected as has;
        if has!("avx512f") && has!("avx512bw") && has!("avx512cd") && has!("avx512dq") && has!("avx512vl") {
            return "x86_64_v4";
        }
        if has!("avx") && has!("avx2") && has!("bmi1") && has!("bmi2") && has!("fma") {
            return "x86_64_v3";
        }
        if has!("popcnt") && has!("sse3") && has!("ssse3") && has!("sse4.1") && has!("sse4.2") {
            return "x86_64_v2";
        }
    }
    "x86_64"
}

/// The virtual packages of `platform`, as libmamba builds them (see the
/// module documentation). `cache_dir` caches the CUDA detection.
pub fn detect(platform: Platform, cache_dir: Option<&Path>) -> RtResult<Vec<GenericVirtualPackage>> {
    let mut out = Vec::new();
    if let Some((os, arch)) = platform.as_str().split_once('-') {
        match os {
            "win" => {
                let version = env_override("win").or_else(host_windows_version).unwrap_or_default();
                out.push(make("__win", &version, "")?);
            }
            "linux" => {
                out.push(make("__unix", "", "")?);
                let version = env_override("linux").or_else(host_linux_version).unwrap_or_default();
                out.push(make("__linux", &version, "")?);
                let glibc = env_override("glibc").or_else(host_glibc_version).unwrap_or_default();
                if !glibc.is_empty() {
                    out.push(make("__glibc", &glibc, "")?);
                }
            }
            "osx" => {
                out.push(make("__unix", "", "")?);
                let version = env_override("osx").or_else(host_osx_version).unwrap_or_default();
                out.push(make("__osx", &version, "")?);
            }
            "emscripten" => out.push(make("__unix", "", "")?),
            _ => {}
        }
        let archspec = env_override("archspec").unwrap_or_else(|| match arch {
            "64" => x86_64_level().to_string(),
            "32" => "x86".to_string(),
            other => other.to_string(),
        });
        out.push(make("__archspec", "1", &archspec)?);
    }
    let cuda = env_override("cuda")
        .or_else(|| Cuda::current(cache_dir).map(|c| c.version.to_string()))
        .unwrap_or_default();
    if !cuda.is_empty() {
        out.push(make("__cuda", &cuda, "")?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(platform: Platform) -> Vec<(String, String, String)> {
        detect(platform, None)
            .unwrap()
            .into_iter()
            .filter(|p| p.name.as_normalized() != "__cuda")
            .map(|p| (p.name.as_normalized().to_string(), p.version.to_string(), p.build_string))
            .collect()
    }

    fn find(v: &[(String, String, String)], name: &str) -> Option<(String, String)> {
        v.iter()
            .find(|(n, _, _)| n == name)
            .map(|(_, ver, b)| (ver.clone(), b.clone()))
    }

    // These read the process environment; none of them sets an override
    // (that would race with tests running in parallel). Overrides are
    // checked from R, in a process of their own.

    #[test]
    fn only_the_target_os_family_gets_os_packages() {
        let win = names(Platform::Win64);
        assert!(find(&win, "__win").is_some());
        assert!(find(&win, "__unix").is_none() && find(&win, "__linux").is_none() && find(&win, "__osx").is_none());
        let osx = names(Platform::OsxArm64);
        assert!(find(&osx, "__osx").is_some() && find(&osx, "__unix").is_some());
        assert!(find(&osx, "__win").is_none() && find(&osx, "__glibc").is_none());
        let linux = names(Platform::LinuxAarch64);
        assert!(find(&linux, "__linux").is_some() && find(&linux, "__unix").is_some());
        assert!(find(&linux, "__win").is_none() && find(&linux, "__osx").is_none());
        assert!(names(Platform::NoArch).is_empty());
    }

    #[test]
    fn other_operating_systems_get_version_0() {
        if std::env::var_os("CONDA_OVERRIDE_WIN").is_none() && !cfg!(windows) {
            assert_eq!(find(&names(Platform::Win64), "__win"), Some(("0".into(), "0".into())));
        }
        if std::env::var_os("CONDA_OVERRIDE_OSX").is_none() && !cfg!(target_os = "macos") {
            assert_eq!(find(&names(Platform::Osx64), "__osx"), Some(("0".into(), "0".into())));
        }
        if std::env::var_os("CONDA_OVERRIDE_LINUX").is_none() && !cfg!(target_os = "linux") {
            assert_eq!(find(&names(Platform::Linux64), "__linux"), Some(("0".into(), "0".into())));
            assert!(find(&names(Platform::Linux64), "__glibc").is_none());
        }
    }

    #[test]
    fn archspec_is_the_platform_arch_or_the_x86_64_level() {
        if std::env::var_os("CONDA_OVERRIDE_ARCHSPEC").is_some() {
            return;
        }
        let arch = |p: Platform| find(&names(p), "__archspec").unwrap();
        assert_eq!(arch(Platform::OsxArm64), ("1".into(), "arm64".into()));
        assert_eq!(arch(Platform::WinArm64), ("1".into(), "arm64".into()));
        assert_eq!(arch(Platform::LinuxAarch64), ("1".into(), "aarch64".into()));
        assert_eq!(arch(Platform::LinuxPpc64le), ("1".into(), "ppc64le".into()));
        assert_eq!(arch(Platform::Linux32), ("1".into(), "x86".into()));
        let level = arch(Platform::Linux64).1;
        assert_eq!(level, x86_64_level());
        assert_eq!(arch(Platform::Win64).1, level);
        if cfg!(target_arch = "x86_64") {
            assert!(level.starts_with("x86_64"), "{level}");
        } else {
            assert_eq!(level, "x86_64");
        }
    }
}
