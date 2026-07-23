//! Solve requested `MatchSpec`s against one or more channels and link the
//! result into a prefix.
//!
//! `solve_and_install` handles both `create_env()` and `install()` from the R
//! side: it always re-reads whatever is already linked into `prefix` (empty
//! if the prefix doesn't exist yet) and folds it into the solve as
//! `locked_packages` plus bare-name specs, so adding one package never drops
//! packages that were already there. See PLAN.md ("Installation").

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use rattler::install::Installer;
#[cfg(feature = "wheels")]
use rattler::install::PythonInfo;
use rattler_cache::package_cache::PackageCache;
use rattler_conda_types::{
    package::DistArchiveType, Channel, ChannelConfig, GenericVirtualPackage, MatchSpec,
    PackageName, Platform, PrefixRecord, RepoDataRecord,
};
use rattler_repodata_gateway::Gateway;
use rattler_solve::{resolvo, ChannelPriority, SolverImpl, SolverTask};
use rattler_virtual_packages::{VirtualPackageOverrides, VirtualPackages};

use crate::error::{RtError, RtResult};
use crate::runtime::runtime;
#[cfg(feature = "wheels")]
use crate::wheel;

pub struct InstallOutcome {
    pub prefix: PathBuf,
    pub records: Vec<RepoDataRecord>,
}

pub struct InstallInput {
    pub specs: Vec<String>,
    pub prefix: PathBuf,
    pub channels: Vec<String>,
    pub channel_priority: String,
    pub platform: Option<String>,
    pub repodata_cache_dir: PathBuf,
    pub pkgs_cache_dir: PathBuf,
}

fn parse_platform(platform: &Option<String>) -> RtResult<Platform> {
    match platform {
        None => Ok(Platform::current()),
        Some(s) => {
            Platform::from_str(s).map_err(|_| RtError::InvalidPlatform { platform: s.clone() })
        }
    }
}

fn parse_channel_priority(value: &str) -> ChannelPriority {
    match value {
        "disabled" => ChannelPriority::Disabled,
        // "strict" and anything else fall back to resolvo's default.
        _ => ChannelPriority::Strict,
    }
}

fn parse_channels(channels: &[String], config: &ChannelConfig) -> RtResult<Vec<Channel>> {
    channels
        .iter()
        .map(|c| {
            Channel::from_str(c, config).map_err(|source| RtError::ParseChannel {
                channel: c.clone(),
                source,
            })
        })
        .collect()
}

/// `channels` plus whatever channel each already-installed package actually
/// came from (tracked on its `RepoDataRecord`).
///
/// Without this, a call like `install(packages = "xz")` — defaulting to
/// `channels = "conda-forge"` — would only query conda-forge; the bare-name
/// "keep" spec generated for an existing `conda-pypi::cowsay` install would
/// then have nothing to match against (conda-pypi never got queried) and the
/// solve would fail as unsolvable, breaking any environment with a package
/// from a non-default channel the instant you `install()` anything else into
/// it without re-listing every channel by hand.
fn channels_with_existing(channels: Vec<Channel>, existing: &[PrefixRecord]) -> Vec<Channel> {
    let mut seen: HashSet<String> = channels.iter().map(|c| c.base_url.to_string()).collect();
    let mut all_channels = channels;
    for record in existing
        .iter()
        .filter_map(|p| p.repodata_record.channel.as_ref())
    {
        if !seen.insert(record.clone()) {
            continue;
        }
        if let Ok(url) = url::Url::parse(record) {
            all_channels.push(Channel::from_url(url));
        }
    }
    all_channels
}

fn parse_specs(specs: &[String]) -> RtResult<Vec<MatchSpec>> {
    specs
        .iter()
        .map(|s| {
            s.parse::<MatchSpec>()
                .map_err(|source| RtError::ParseMatchSpec {
                    spec: s.clone(),
                    source,
                })
        })
        .collect()
}

/// Existing packages linked into `prefix`, empty if the prefix does not
/// exist yet (a brand-new environment).
fn existing_records(prefix: &Path) -> RtResult<Vec<PrefixRecord>> {
    Ok(PrefixRecord::collect_from_prefix::<PrefixRecord>(prefix)?)
}

pub fn solve_and_install(input: InstallInput) -> RtResult<InstallOutcome> {
    let platform = parse_platform(&input.platform)?;
    let channel_config = ChannelConfig::default_with_root_dir(
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    );
    let channels = parse_channels(&input.channels, &channel_config)?;
    let channel_priority = parse_channel_priority(&input.channel_priority);
    let existing = existing_records(&input.prefix)?;
    let channels = channels_with_existing(channels, &existing);

    // Nothing new requested: just make sure the prefix exists (used by
    // `create_env(packages = NULL)`), keeping whatever is already installed.
    if input.specs.is_empty() {
        if existing.is_empty() {
            runtime().block_on(link_records(&input, platform, Vec::new(), &existing))?;
        }
        let records: Vec<RepoDataRecord> =
            existing.into_iter().map(|p| p.repodata_record).collect();
        return Ok(InstallOutcome {
            prefix: input.prefix,
            records,
        });
    }

    let new_specs = parse_specs(&input.specs)?;
    let new_names: HashSet<PackageName> = new_specs
        .iter()
        .filter_map(|s| s.name.as_exact().cloned())
        .collect();

    // Keep every already-installed package that isn't being re-specified by
    // name, expressed as a bare-name spec so the solver treats it as a root
    // requirement (present, but free to move if a conflict forces it).
    let keep_specs: Vec<MatchSpec> = existing
        .iter()
        .map(|p| p.repodata_record.package_record.name.clone())
        .filter(|name| !new_names.contains(name))
        .map(MatchSpec::from)
        .collect();

    let mut query_specs = new_specs;
    query_specs.extend(keep_specs);

    let locked: Vec<RepoDataRecord> = existing
        .iter()
        .map(|p| p.repodata_record.clone())
        .collect();

    let gateway = Gateway::builder()
        .with_cache_dir(input.repodata_cache_dir.clone())
        .with_package_cache(PackageCache::new(input.pkgs_cache_dir.clone()))
        .finish();

    // Every platform-specific subdir has a sibling `noarch` subdir carrying
    // pure-Python (and other platform-independent) packages. Omitting it
    // here meant any dependency chain touching a noarch package (`pip`,
    // `setuptools`, `tzdata`, ...) came back unsolvable — the gateway only
    // fetches exactly the platforms it's given, it does not add `noarch` on
    // its own. Compiled-only packages like the `xz`/`zstd` smoke test never
    // touch a noarch package, which is why this didn't show up until someone
    // tried installing something with real Python dependencies.
    let query_platforms = if platform == Platform::NoArch {
        vec![platform]
    } else {
        vec![platform, Platform::NoArch]
    };

    let query_specs_for_gateway = query_specs.clone();
    let repodata = runtime().block_on(async move {
        gateway
            .query(channels, query_platforms, query_specs_for_gateway)
            .recursive(true)
            .execute()
            .await
    })?;

    let virtual_packages: Vec<GenericVirtualPackage> =
        VirtualPackages::detect(&VirtualPackageOverrides::default())?
            .into_generic_virtual_packages()
            .collect();

    let mut task = SolverTask::from_iter(&repodata);
    task.specs = query_specs;
    task.locked_packages = locked.iter().collect();
    task.virtual_packages = virtual_packages;
    task.channel_priority = channel_priority;

    let solved = resolvo::Solver::default().solve(task)?;

    runtime().block_on(link_records(&input, platform, solved.records.clone(), &existing))?;

    Ok(InstallOutcome {
        prefix: input.prefix,
        records: solved.records,
    })
}

fn is_wheel(record: &RepoDataRecord) -> bool {
    matches!(record.identifier.archive_type, DistArchiveType::Wheel(_))
}

/// Links `records` (the complete desired state for the prefix) into it.
///
/// Wheel-format records (the `conda-pypi` channel and similar) are split out
/// and handled by [`wheel::install_wheel`] instead of `Installer`: neither
/// `Installer` nor `rattler_cache::package_cache` know how to fetch or link a
/// raw `.whl` file (see `wheel.rs`). `Installer` only ever sees the
/// conda-format records; the wheel package names are passed via
/// `with_ignored_packages` so it leaves their hand-written
/// `conda-meta/*.json` entries alone instead of treating them as extraneous
/// and deleting them.
///
/// Note this deliberately does *not* use `with_installed_packages` to tell
/// `Installer` about the conda-format side of what's already there — as
/// tempting as that looks for symmetry, doing so runs `Installer` through a
/// `Transaction`/`ClobberRegistry` code path
/// (`path_resolver::PathResolver::reprioritize_packages`) that panics on a
/// second install into the same prefix, confirmed on both rattler 0.46.0
/// and 0.47.0 (see `install_after_wheel_does_not_panic`). Leaving it unset
/// keeps `Installer` on its own (working) auto-discovery via
/// `PrefixRecord::collect_minimal_from_prefix`.
async fn link_records(
    input: &InstallInput,
    platform: Platform,
    records: Vec<RepoDataRecord>,
    existing: &[PrefixRecord],
) -> RtResult<()> {
    let (wheel_records, conda_records): (Vec<_>, Vec<_>) =
        records.into_iter().partition(is_wheel);

    let existing_wheel_names: HashSet<PackageName> = existing
        .iter()
        .filter(|p| is_wheel(&p.repodata_record))
        .map(|p| p.repodata_record.package_record.name.clone())
        .collect();

    Installer::new()
        .with_execute_link_scripts(false)
        .with_package_cache(PackageCache::new(input.pkgs_cache_dir.clone()))
        .with_target_platform(platform)
        .with_ignored_packages(existing_wheel_names)
        .install(&input.prefix, conda_records.clone())
        .await
        .map_err(RtError::from)?;

    install_wheels(wheel_records, &conda_records, &input.prefix, platform, existing).await
}

#[cfg(feature = "wheels")]
async fn install_wheels(
    wheel_records: Vec<RepoDataRecord>,
    conda_records: &[RepoDataRecord],
    prefix: &Path,
    platform: Platform,
    existing: &[PrefixRecord],
) -> RtResult<()> {
    if wheel_records.is_empty() {
        return Ok(());
    }

    let python_record = conda_records
        .iter()
        .find(|r| r.package_record.name.as_normalized() == "python")
        .map(|r| &r.package_record);
    let Some(python_record) = python_record else {
        return Err(RtError::WheelMissingPython {
            name: wheel_records[0]
                .package_record
                .name
                .as_normalized()
                .to_string(),
        });
    };
    let python_info = PythonInfo::from_python_record(python_record, platform)
        .map_err(|source| RtError::PythonInfo(source.to_string()))?;

    let existing_wheel_keys: HashSet<(String, String, String)> = existing
        .iter()
        .filter(|p| is_wheel(&p.repodata_record))
        .map(|p| record_key(&p.repodata_record))
        .collect();

    let client = reqwest::Client::new();
    for record in &wheel_records {
        if existing_wheel_keys.contains(&record_key(record)) {
            continue;
        }
        wheel::install_wheel(&client, record, prefix, &python_info, platform).await?;
    }

    Ok(())
}

#[cfg(feature = "wheels")]
fn record_key(record: &RepoDataRecord) -> (String, String, String) {
    (
        record.package_record.name.as_normalized().to_string(),
        record.package_record.version.to_string(),
        record.package_record.build.clone(),
    )
}

/// Built without the `wheels` feature: a solve that returned wheel-format
/// records can't be linked, so fail clearly instead of silently ignoring
/// them (matching what the `wheels`-enabled build reports for a missing
/// `python` package -- a specific error, not silent partial install).
#[cfg(not(feature = "wheels"))]
async fn install_wheels(
    wheel_records: Vec<RepoDataRecord>,
    _conda_records: &[RepoDataRecord],
    _prefix: &Path,
    _platform: Platform,
    _existing: &[PrefixRecord],
) -> RtResult<()> {
    match wheel_records.into_iter().next() {
        None => Ok(()),
        Some(record) => Err(RtError::WheelUnsupported {
            name: record.package_record.name.as_normalized().to_string(),
        }),
    }
}

#[cfg(all(test, feature = "wheels"))]
mod tests {
    use super::*;

    /// Regression test for a panic previously hit here: `install()` on an
    /// env that already has a wheel package, using a single-channel
    /// `channels =` argument that doesn't re-list the wheel's channel. Two
    /// separate bugs had to be fixed for this to pass: (1) the second solve
    /// needs `channels_with_existing` to add the wheel's channel back in, or
    /// its "keep" spec is unsolvable; (2) `link_records` must not call
    /// `Installer::with_installed_packages` on a second install into the
    /// same prefix — that path panics inside rattler's
    /// `ClobberRegistry`/`path_resolver` (confirmed on both 0.46.0 and
    /// 0.47.0; see the doc comment on `link_records`). Requires network
    /// access; run with
    /// `cargo test -- --ignored`.
    #[cfg(feature = "wheels")]
    #[test]
    #[ignore = "hits the real conda-forge/conda-pypi network"]
    fn install_after_wheel_does_not_panic() {
        let dir = tempfile::tempdir().unwrap();
        let prefix = dir.path().join("envs").join("e");
        let repodata_cache_dir = dir.path().join("repodata_cache");
        let pkgs_cache_dir = dir.path().join("pkgs");

        let outcome1 = solve_and_install(InstallInput {
            specs: vec!["python".into(), "conda-pypi::cowsay".into()],
            prefix: prefix.clone(),
            channels: vec!["conda-forge".into(), "conda-pypi".into()],
            channel_priority: "strict".into(),
            platform: None,
            repodata_cache_dir: repodata_cache_dir.clone(),
            pkgs_cache_dir: pkgs_cache_dir.clone(),
        })
        .expect("first solve_and_install failed");
        assert!(outcome1.records.iter().any(|r| r.package_record.name.as_normalized() == "cowsay"));

        // Deliberately omits "conda-pypi" here, matching install()'s
        // single-channel default on the R side.
        let outcome2 = solve_and_install(InstallInput {
            specs: vec!["xz".into()],
            prefix: prefix.clone(),
            channels: vec!["conda-forge".into()],
            channel_priority: "strict".into(),
            platform: None,
            repodata_cache_dir,
            pkgs_cache_dir,
        })
        .expect("second solve_and_install failed");
        assert!(outcome2.records.iter().any(|r| r.package_record.name.as_normalized() == "cowsay"));
        assert!(outcome2.records.iter().any(|r| r.package_record.name.as_normalized() == "xz"));
    }
}
