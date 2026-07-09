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

use rattler::install::{Installer, InstallerError};
use rattler_cache::package_cache::PackageCache;
use rattler_conda_types::{
    Channel, ChannelConfig, GenericVirtualPackage, MatchSpec, PackageName, Platform,
    PrefixRecord, RepoDataRecord,
};
use rattler_repodata_gateway::Gateway;
use rattler_solve::{resolvo, ChannelPriority, SolverImpl, SolverTask};
use rattler_virtual_packages::{VirtualPackageOverrides, VirtualPackages};

use crate::error::{RtError, RtResult};
use crate::runtime::runtime;

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

    // Nothing new requested: just make sure the prefix exists (used by
    // `create_env(packages = NULL)`), keeping whatever is already installed.
    if input.specs.is_empty() {
        let records: Vec<RepoDataRecord> =
            existing.into_iter().map(|p| p.repodata_record).collect();
        if records.is_empty() {
            runtime().block_on(link_records(&input, platform, Vec::new()))?;
        }
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

    let query_specs_for_gateway = query_specs.clone();
    let repodata = runtime().block_on(async move {
        gateway
            .query(channels, vec![platform], query_specs_for_gateway)
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

    runtime().block_on(link_records(&input, platform, solved.records.clone()))?;

    Ok(InstallOutcome {
        prefix: input.prefix,
        records: solved.records,
    })
}

async fn link_records(
    input: &InstallInput,
    platform: Platform,
    records: Vec<RepoDataRecord>,
) -> Result<(), InstallerError> {
    Installer::new()
        .with_execute_link_scripts(false)
        .with_package_cache(PackageCache::new(input.pkgs_cache_dir.clone()))
        .with_target_platform(platform)
        .install(&input.prefix, records)
        .await?;
    Ok(())
}
