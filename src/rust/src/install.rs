//! Solve requested `MatchSpec`s against channels and link the result into a
//! prefix (`rt_install()`), and the solve-only check (`rt_solve_check()`).
//!
//! An install is a job (`job.rs`) with these phases:
//!
//! 1. `lock`: exclusive lock on `<prefix>/conda-meta/conda-meta.lock`
//!    (`lock.rs`), held until the history is written;
//! 2. `fetch`: repodata for the effective channels (`channels.rs`) and the
//!    platforms `[platform, noarch]`;
//! 3. `solve`: resolvo, with the installed records as favored ("locked")
//!    candidates, a bare-name spec for every installed package that is not
//!    requested again, libmamba's pins as constraints (the python minor
//!    version, and `conda-meta/pinned`), and the virtual packages of the
//!    target platform (`CONDA_OVERRIDE_*` honored);
//! 4. `prefetch`: every package the transaction installs is downloaded and
//!    extracted into the package cache, under the cache's global lock;
//! 5. `link`: rattler's `Installer`, which finds every package cached, so it
//!    only works locally. Link scripts stay off.
//!
//! The job enters `link` only once rattler's `Installer` holds the package
//! cache's global lock and starts the transaction (its reporter's
//! `on_transaction_start()`, before the first unlink); until then a cancel
//! drops the Installer, which has only created the prefix directory by
//! then. At most one link runs at a time in a process (`runtime.rs`).
//!
//! A cancel or failure before `link` leaves the prefix as it was; a prefix
//! that was not an environment before (no history, no records) is removed
//! again, while the job still holds its lock. After the link the history is
//! appended (`history.rs`) and the skipped link scripts are collected
//! (`linkscripts.rs`).
//!
//! Only the requested channels are used, as micromamba with
//! `--override-channels`: installed packages stay solvable through the
//! locked records even when their channel is not listed (rattler adds locked
//! records as candidates, and strict priority applies to repodata only).
//!
//! As libmamba (`allow_uninstall`, on by default): when the installed
//! packages cannot all stay with the request, the solve keeps as many of
//! them as it can (divide and conquer over the installed names) and removes
//! the others; the request itself is never relaxed.
//!
//! The prefix is resolved as micromamba resolves it (`paths.rs`).

use std::collections::{HashMap, HashSet};
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rattler::install::{
    InstallationResultRecord, Installer, Reporter, Transaction, TransactionOperation,
};
use rattler_cache::package_cache::PackageCache;
use rattler_conda_types::{
    package::DistArchiveType, Channel, GenericVirtualPackage, MatchSpec, Matches, PackageName,
    PackageRecord, ParseStrictness, Platform, PrefixRecord, RepoDataRecord,
};
use rattler_repodata_gateway::fetch::{CacheAction, FetchRepoDataError};
use rattler_repodata_gateway::{ChannelConfig, Gateway, GatewayError, RepoData, SourceConfig};
use rattler_solve::{resolvo, ChannelPriority, SolveError, SolverImpl, SolverTask};
use rattler_networking::LazyClient;

use crate::activation::parse_platform;
use crate::channels::{
    channel_config, channel_url_string, effective_channels, normalize_spec_channel, percent_decode,
    record_channel_display, split_multichannel_specs, ChannelRestriction,
};
use crate::error::{error_chain, RtError, RtResult};
use crate::history::{append_history, update_spec_string};
use crate::job::{spawn_job, Job, JobCtx, JobOutput, Phase};
use crate::linkscripts;
use crate::lock;
use crate::net;
use crate::spectext::{spec_text, url_md5_unsolvable};
#[cfg(feature = "wheels")]
use crate::wheel;

/// libmamba's default number of parallel downloads.
pub(crate) const DOWNLOAD_CONCURRENCY: usize = 5;

pub struct InstallInput {
    pub specs: Vec<String>,
    pub prefix: PathBuf,
    pub channels: Vec<String>,
    pub channel_priority: String,
    pub platform: Option<String>,
    pub repodata_cache_dir: PathBuf,
    pub pkgs_cache_dir: PathBuf,
    /// The settings of the job's HTTP clients (`netenv.rs`).
    pub net: crate::netenv::NetSettings,
}

/// One line of the transaction: `op` is `"+"` (installed, or the new side
/// of a change) or `"-"` (removed, or the old side of a change).
#[derive(Clone, Debug, PartialEq)]
pub struct TxRow {
    pub op: &'static str,
    pub name: String,
    pub version: String,
    pub build: String,
    pub channel: String,
    pub subdir: String,
}

#[derive(Clone, Debug)]
pub struct InstallOutcome {
    pub prefix: String,
    /// The transaction, `-` rows before `+` rows (the history's order).
    pub records: Vec<TxRow>,
    /// The effective channel URLs, without trailing slashes.
    pub channels: Vec<String>,
    /// `(package, script)`, script one of `pre-link`, `post-link`,
    /// `pre-unlink`.
    pub link_scripts_skipped: Vec<(String, &'static str)>,
}

pub fn parse_channel_priority(value: &str) -> RtResult<ChannelPriority> {
    match value {
        "strict" => Ok(ChannelPriority::Strict),
        "flexible" => Ok(ChannelPriority::Flexible),
        "disabled" => Ok(ChannelPriority::Disabled),
        other => Err(RtError::InvalidChannelPriority {
            value: other.to_string(),
        }),
    }
}

/// Parses specs the way rattlerthis always has (lenient), after libmamba's
/// cleanup of the text (`spectext.rs`: a byte order mark, a comment, a
/// non-hex URL fragment go), and rewrites the channel of a channel-qualified
/// spec like the channel list.
pub fn parse_specs(specs: &[String]) -> RtResult<Vec<MatchSpec>> {
    let cfg = channel_config();
    specs
        .iter()
        .map(|s| {
            let text = spec_text(s).into_text();
            let spec = MatchSpec::from_str(&text, ParseStrictness::Lenient).map_err(|source| {
                if text.is_ascii() {
                    RtError::ParseMatchSpec {
                        spec: s.clone(),
                        source,
                    }
                } else {
                    unmatchable_spec(&text)
                }
            })?;
            normalize_spec_channel(spec, &cfg)
        })
        .collect()
}

/// A spec rattler cannot parse that has a non-ASCII character (such as a
/// byte order mark micromamba keeps on macOS, see `spectext.rs`): libmamba
/// takes any name, and then finds no package with it ("does not exist"), so
/// the request is unsolvable (a solve check answers `FALSE`).
fn unmatchable_spec(text: &str) -> RtError {
    RtError::Solve(SolveError::Unsolvable(vec![format!(
        "{text:?} does not exist: no package name has its characters (micromamba: \"does not \
         exist (perhaps a typo or a missing channel)\")"
    )]))
}

/// The records in `<prefix>/conda-meta`, read one by one in file-name order
/// (not with rattler's parallel reader: see `runtime.rs`). Empty when the
/// prefix does not exist.
pub fn read_prefix_records(prefix: &Path) -> RtResult<Vec<PrefixRecord>> {
    let dir = prefix.join("conda-meta");
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let entries = std::fs::read_dir(&dir)
        .map_err(|e| RtError::io_at(format!("failed to read {}", dir.display()), e))?;
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    paths.sort();
    paths
        .iter()
        .map(|p| {
            PrefixRecord::from_path(p)
                .map_err(|e| RtError::io_at(format!("failed to read {}", p.display()), e))
        })
        .collect()
}

pub(crate) fn is_wheel(record: &RepoDataRecord) -> bool {
    matches!(record.identifier.archive_type, DistArchiveType::Wheel(_))
}

fn find_record<'a>(records: &'a [PrefixRecord], name: &str) -> Option<&'a PrefixRecord> {
    records
        .iter()
        .find(|r| r.repodata_record.package_record.name.as_normalized() == name)
}

/// libmamba's `python_pin()` (`libmamba/src/core/pinning.cpp`): when python is
/// installed and no requested spec's name matches `python`, pin
/// `python <major>.<minor>.*`; when `python-freethreading` is installed too,
/// also pin `python_abi` to its minor version and ABI tag.
pub fn python_pins(installed: &[PrefixRecord], requested: &[MatchSpec]) -> RtResult<Vec<MatchSpec>> {
    let Some(python) = find_record(installed, "python") else {
        return Ok(Vec::new());
    };
    let python_name = PackageName::new_unchecked("python");
    if requested.iter().any(|s| s.name.matches(&python_name)) {
        return Ok(Vec::new());
    }
    let version = python.repodata_record.package_record.version.to_string();
    let parts: Vec<&str> = version.split('.').collect();
    if parts.len() < 2 {
        return Ok(Vec::new());
    }
    let mut pins = vec![format!("python {}.{}.*", parts[0], parts[1])];
    if find_record(installed, "python-freethreading").is_some() {
        if let Some(abi) = find_record(installed, "python_abi") {
            let pr = &abi.repodata_record.package_record;
            if let Some(pos) = pr.build.find('_') {
                let abi_tag = &pr.build[pos..];
                let v = pr.version.to_string();
                let vparts: Vec<&str> = v.split('.').collect();
                let version_pin = if vparts.len() >= 2 {
                    format!("={}.{}", vparts[0], vparts[1])
                } else {
                    format!("={v}")
                };
                pins.push(format!(
                    "python_abi[version=\"{version_pin}\",build=\"*{abi_tag}\"]"
                ));
            }
        }
    }
    pins.iter()
        .map(|p| {
            MatchSpec::from_str(p, ParseStrictness::Lenient).map_err(|source| RtError::ParseMatchSpec {
                spec: p.clone(),
                source,
            })
        })
        .collect()
}

/// libmamba's `file_pins()`: every line of `<prefix>/conda-meta/pinned` is a
/// pin (blank lines and `#` comments skipped; libmamba would reject them).
/// Each line is cleaned as libmamba's spec parser cleans it, so a byte order
/// mark in front of the first pin is dropped (on macOS it stays, and the pin,
/// on a name no package has, changes nothing, as with micromamba).
pub fn file_pins(prefix: &Path) -> RtResult<Vec<MatchSpec>> {
    let path = prefix.join("conda-meta").join("pinned");
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let text = std::fs::read_to_string(&path)
        .map_err(|e| RtError::io_at(format!("failed to read {}", path.display()), e))?;
    text.lines()
        .map(|line| (line, spec_text(line).into_text()))
        .filter(|(_, pin)| !pin.is_empty() && !pin.starts_with('#'))
        .filter_map(|(line, pin)| match MatchSpec::from_str(&pin, ParseStrictness::Lenient) {
            Ok(spec) => Some(Ok(spec)),
            // A name with a non-ASCII character (a byte order mark kept on
            // macOS): libmamba pins a name no package has, which changes
            // nothing.
            Err(_) if !pin.is_ascii() => None,
            Err(source) => Some(Err(RtError::ParsePin {
                line: line.to_string(),
                path: path.display().to_string(),
                source,
            })),
        })
        .collect()
}

/// Virtual packages of the target platform, as libmamba builds them
/// (`vpkgs.rs`), with `CONDA_OVERRIDE_*` honored.
pub async fn detect_virtual_packages(
    platform: Platform,
    cache_dir: PathBuf,
) -> RtResult<Vec<GenericVirtualPackage>> {
    tokio::task::spawn_blocking(move || crate::vpkgs::detect(platform, Some(&cache_dir)))
        .await
        .map_err(|e| RtError::Internal(format!("virtual package detection failed: {e}")))?
}

/// libmamba's `add_pip_as_python_dependency` (on by default, and condathis
/// does not change it), request side (`create_install_request()` in
/// `libmamba/src/api/install.cpp`): when a requested spec names `python` and
/// none names `pip`, `pip` is requested too. Returns the spec to add.
pub fn pip_request(requested: &[MatchSpec]) -> Option<MatchSpec> {
    let named = |name: &str| {
        requested
            .iter()
            .any(|s| s.name.as_exact().is_some_and(|n| n.as_normalized() == name))
    };
    (named("python") && !named("pip")).then(|| {
        MatchSpec::from_str("pip", ParseStrictness::Lenient).expect("`pip` is a valid spec")
    })
}

/// libmamba's `add_pip_as_python_dependency`, repodata side
/// (`add_pip_as_python_dependency()` in `libmamba/src/solver/libsolv/helpers.cpp`):
/// in a repodata set (one channel subdir) that has a `pip` record, every
/// `python` record whose version starts with a character `>= '2'` gets a
/// dependency on `pip`, and every `pip` record a dependency on `python`.
/// Returns, per set, the patched copies of those records (empty when
/// nothing is patched).
///
/// libmamba adds `python` to `pip` as a prerequisite (after libsolv's
/// `SOLVABLE_PREREQMARKER`), which it leaves out when it writes the record
/// to `conda-meta`, while the `pip` of `python` is written. So the solve
/// sees both, and [`solve()`] gives back `pip` records as the channel has
/// them (see [`unpatched_pip()`]).
fn pip_patched_records(repodata: &[RepoData]) -> Vec<Vec<RepoDataRecord>> {
    repodata
        .iter()
        .map(|set| {
            let has_pip = set
                .iter()
                .any(|r| r.package_record.name.as_normalized() == "pip");
            if !has_pip {
                return Vec::new();
            }
            set.iter()
                .filter_map(|r| {
                    let name = r.package_record.name.as_normalized();
                    let added = if name == "python"
                        && r.package_record
                            .version
                            .to_string()
                            .chars()
                            .next()
                            .is_some_and(|c| c >= '2')
                    {
                        "pip"
                    } else if name == "pip" {
                        "python"
                    } else {
                        return None;
                    };
                    let mut patched = (*r).clone();
                    if !patched.package_record.depends.iter().any(|d| d == added) {
                        patched.package_record.depends.push(added.to_string());
                    }
                    Some(patched)
                })
                .collect()
        })
        .collect()
}

/// The solved records with every `pip` record of `repodata` as the channel
/// has it, without the `python` dependency of [`pip_patched_records()`]
/// (libmamba writes `pip`'s record without it). Records of installed
/// packages (the favored ones) are left as they are.
fn unpatched_pip(solved: Vec<RepoDataRecord>, repodata: &[RepoData]) -> Vec<RepoDataRecord> {
    solved
        .into_iter()
        .map(|record| {
            if record.package_record.name.as_normalized() != "pip" {
                return record;
            }
            repodata
                .iter()
                .flat_map(|set| set.iter())
                .find(|r| r.identifier == record.identifier && r.url == record.url)
                .cloned()
                .unwrap_or(record)
        })
        .collect()
}

fn query_platforms(platform: Platform) -> Vec<Platform> {
    // The gateway fetches exactly the subdirs it is given; `noarch` is not
    // implied.
    if platform == Platform::NoArch {
        vec![platform]
    } else {
        vec![platform, Platform::NoArch]
    }
}

/// Where a repodata query reads channel metadata from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RepodataCache {
    /// The repodata cache while it is fresh by libmamba's rule (see
    /// [`fresh_flat_channels()`]), else rattler's default: the cache while
    /// rattler deems it fresh, else the channel (which replaces the cached
    /// copy).
    Refresh,
    /// Only the repodata cache, however old; a subdir without a cached
    /// copy fails.
    CacheOnly,
    /// rattler's default for every channel: the cache while rattler deems
    /// it fresh, else the channel. The fallback of [`RepodataCache::Refresh`]
    /// when a cache that libmamba's rule calls fresh is one rattler cannot
    /// use (see [`fetch_repodata()`]).
    Default,
}

/// libmamba's default lifetime of cached channel metadata whose server sent
/// no `Cache-Control: max-age` (`subdir_index.cpp` `load_cache()`).
const DEFAULT_REPODATA_MAX_AGE: Duration = Duration::from_secs(60 * 60);

/// The `max-age` of a `Cache-Control` header as libmamba reads it: the first
/// `max-age=<digits>` anywhere in it.
fn cache_control_max_age(cache_control: &str) -> Option<Duration> {
    let at = cache_control.find("max-age=")?;
    let digits: String = cache_control[at + "max-age=".len()..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse::<u64>().ok().map(Duration::from_secs)
}

/// rattler's name of the cache files of a subdir's `repodata.json`
/// (`rattler_repodata_gateway`'s `url_to_cache_filename()`, which is not
/// public): the first 4 bytes of the MD5 of the URL without its final
/// `/repodata.json`, in hex.
fn repodata_cache_key(subdir_url: &url::Url) -> String {
    let mut base = subdir_url.to_string();
    if !base.ends_with('/') {
        base.push('/');
    }
    let url = format!("{base}repodata.json");
    let url = url.strip_suffix("/repodata.json").unwrap_or(&url);
    let hash = rattler_digest::compute_bytes_digest::<rattler_digest::Md5>(url);
    hash[0..4].iter().map(|b| format!("{b:02x}")).collect()
}

/// Whether rattler's cached `repodata.json` of a subdir is fresh by
/// libmamba's rule (`local_repodata_ttl` 1, its default): younger than the
/// `max-age` of the `Cache-Control` the server sent, else than an hour. The
/// age is that of the cache's `.info.json`, which rattler writes on every
/// download and every 304 answer, as libmamba's age restarts then.
fn flat_cache_is_fresh(repodata_cache_dir: &Path, subdir_url: &url::Url, now: std::time::SystemTime) -> bool {
    let key = repodata_cache_key(subdir_url);
    let info = repodata_cache_dir.join(format!("{key}.info.json"));
    if !repodata_cache_dir.join(format!("{key}.json")).is_file() {
        return false;
    }
    let Ok(modified) = std::fs::metadata(&info).and_then(|m| m.modified()) else {
        return false;
    };
    let max_age = std::fs::read(&info)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|state| state.get("cache_control").and_then(|v| v.as_str()).and_then(cache_control_max_age))
        .unwrap_or(DEFAULT_REPODATA_MAX_AGE);
    match now.duration_since(modified) {
        Ok(age) => age < max_age,
        // Written in the future (a clock change): as libmamba, fresh.
        Err(_) => true,
    }
}

/// Each HTTP channel of `channels`, and whether its cached metadata (flat
/// `repodata.json`, for every subdir of `platforms`) is fresh by libmamba's
/// rule: a query then reads it from the cache without asking the server, as
/// micromamba does. A channel with a subdir that is not cached (or that is
/// served as sharded repodata) keeps rattler's own rules.
fn fresh_flat_channels(repodata_cache_dir: &Path, channels: &[Channel], platforms: &[Platform]) -> Vec<(url::Url, bool)> {
    let now = std::time::SystemTime::now();
    channels
        .iter()
        .filter(|c| matches!(c.base_url.url().scheme(), "http" | "https"))
        .map(|c| {
            let fresh = platforms
                .iter()
                .all(|p| flat_cache_is_fresh(repodata_cache_dir, &c.platform_url(*p), now));
            (url::Url::clone(c.base_url.url()), fresh)
        })
        .collect()
}

fn gateway(
    client: &LazyClient,
    repodata_cache_dir: &Path,
    cache: &PackageCache,
    mode: RepodataCache,
    channels: &[Channel],
    platforms: &[Platform],
) -> Gateway {
    let builder = Gateway::builder()
        .with_client(client.clone())
        .with_cache_dir(repodata_cache_dir.to_path_buf())
        .with_package_cache(cache.clone());
    let builder = match mode {
        // Every queried HTTP channel gets its own entry: rattler matches the
        // entries as URL prefixes.
        RepodataCache::Refresh => builder.with_channel_config(ChannelConfig {
            default: SourceConfig::default(),
            per_channel: fresh_flat_channels(repodata_cache_dir, channels, platforms)
                .into_iter()
                .map(|(url, fresh)| {
                    let config = if fresh {
                        SourceConfig {
                            cache_action: CacheAction::ForceCacheOnly,
                            ..SourceConfig::default()
                        }
                    } else {
                        SourceConfig::default()
                    };
                    (url, config)
                })
                .collect(),
        }),
        RepodataCache::CacheOnly => builder.with_channel_config(ChannelConfig {
            default: SourceConfig {
                cache_action: CacheAction::ForceCacheOnly,
                ..SourceConfig::default()
            },
            per_channel: HashMap::new(),
        }),
        RepodataCache::Default => builder.with_channel_config(ChannelConfig {
            default: SourceConfig::default(),
            per_channel: HashMap::new(),
        }),
    };
    builder.finish()
}

/// Is `err` rattler's answer to a cached subdir it cannot use while it may
/// not download (`NoCacheAvailable`)? A channel that libmamba's freshness
/// rule reads from its cache ([`fresh_flat_channels()`]) gets it when
/// rattler's own check of the cached copy fails: metadata cached while the
/// clock was ahead (rattler finds its age inconsistent), a `Cache-Control`
/// rattler cannot parse, a damaged cache file. micromamba then downloads the
/// metadata again.
fn is_unusable_cache(err: &GatewayError) -> bool {
    matches!(
        err,
        GatewayError::FetchRepoDataError(FetchRepoDataError::NoCacheAvailable(_))
    )
}

/// What a repodata query needs besides the request: the HTTP client, the
/// repodata cache directory and the package cache.
pub(crate) struct RepodataSource<'a> {
    pub client: &'a LazyClient,
    pub repodata_cache_dir: &'a Path,
    pub package_cache: &'a PackageCache,
}

/// Is `err` a failure to replace a cached `repodata.json` with a new copy?
/// On Windows that fails while another process (another R session using
/// the same root) has the cached copy memory-mapped: rattler maps the file
/// while it reads a subdir, and Windows refuses to replace a mapped file.
fn is_persist_failure(err: &GatewayError) -> bool {
    matches!(
        err,
        GatewayError::FetchRepoDataError(FetchRepoDataError::FailedToPersistTemporaryFile(..))
    )
}

/// How long [`query_repodata()`] tries again after a failure to replace a
/// cached `repodata.json` (see [`is_persist_failure()`]).
#[cfg(not(test))]
const PERSIST_RETRY_FOR: Duration = Duration::from_secs(30);
#[cfg(test)]
const PERSIST_RETRY_FOR: Duration = Duration::from_secs(3);

/// Runs a repodata query, `refresh`, and handles a failure to replace a
/// cached `repodata.json` (see [`is_persist_failure()`]), which micromamba
/// never has (it does not keep the file open): the copy in the cache is
/// then the one another session is reading, so `cache_only` (the same
/// query with only the repodata cache) is tried; when that fails too (a
/// subdir that nobody has cached yet), `refresh` is tried again after a
/// pause (100 ms, doubling up to 1 s), until it or `cache_only` succeeds,
/// for at most [`PERSIST_RETRY_FOR`]. Any other error is returned at once.
/// Every wait and query stops on a cancel.
async fn query_repodata<R, RF, C, CF>(ctx: &JobCtx, refresh: R, cache_only: C) -> RtResult<Vec<RepoData>>
where
    R: Fn() -> RF,
    RF: std::future::Future<Output = Result<Vec<RepoData>, GatewayError>>,
    C: Fn() -> CF,
    CF: std::future::Future<Output = Result<Vec<RepoData>, GatewayError>>,
{
    let started = Instant::now();
    let mut pause = Duration::from_millis(100);
    loop {
        let err = match ctx.cancellable(async { Ok(refresh().await) }).await? {
            Ok(repodata) => return Ok(repodata),
            Err(err) if is_persist_failure(&err) => err,
            Err(err) => return Err(err.into()),
        };
        if let Ok(repodata) = ctx.cancellable(async { Ok(cache_only().await) }).await? {
            return Ok(repodata);
        }
        if started.elapsed() >= PERSIST_RETRY_FOR {
            return Err(err.into());
        }
        ctx.cancellable(async {
            tokio::time::sleep(pause).await;
            Ok(())
        })
        .await?;
        pause = (pause * 2).min(Duration::from_secs(1));
    }
}

fn has_record(repodata: &[RepoData], name: &str) -> bool {
    repodata
        .iter()
        .any(|set| set.iter().any(|r| r.package_record.name.as_normalized() == name))
}

/// The specs a gateway query fetches for `specs`: each spec, plus the bare
/// name of every spec with an exact name. rattler's gateway returns only the
/// records a root spec matches (`foo>=2` brings no `foo 1.0`), and resolvo's
/// strict channel priority only sees the records it was given; libsolv
/// excludes every lower-priority channel that has the name at all. With the
/// bare names, every channel's records of a requested name reach the solver.
fn query_specs(specs: &[MatchSpec]) -> Vec<MatchSpec> {
    let mut out = specs.to_vec();
    let mut seen: HashSet<PackageName> = specs
        .iter()
        .filter_map(|s| s.name.as_exact().filter(|n| *s == MatchSpec::from((*n).clone())).cloned())
        .collect();
    for spec in specs {
        if let Some(name) = spec.name.as_exact() {
            if seen.insert(name.clone()) {
                out.push(MatchSpec::from(name.clone()));
            }
        }
    }
    out
}

/// Repodata of `specs` and their dependencies for `[platform, noarch]`.
///
/// rattler's gateway only fetches the records that `specs` can reach, while
/// libmamba checks a whole subdir for a `pip` record before it makes `pip` a
/// dependency of that subdir's `python` records, and makes `python` one of
/// every `pip` record (see [`pip_patched_records()`]). So when `python` is
/// reachable and `pip` was not fetched, or the other way round, the query is
/// run again with the missing name added (the gateway answers from its cache
/// for everything fetched already).
async fn fetch_repodata(
    ctx: &JobCtx,
    source: &RepodataSource<'_>,
    channels: Vec<Channel>,
    platform: Platform,
    specs: &[MatchSpec],
) -> RtResult<Vec<RepoData>> {
    // One gateway per mode for the whole fetch: a gateway keeps the subdirs
    // it has read, so a query run again reads only what failed before.
    let platforms = query_platforms(platform);
    let refreshing = gateway(
        source.client,
        source.repodata_cache_dir,
        source.package_cache,
        RepodataCache::Refresh,
        &channels,
        &platforms,
    );
    let cached = gateway(
        source.client,
        source.repodata_cache_dir,
        source.package_cache,
        RepodataCache::CacheOnly,
        &channels,
        &platforms,
    );
    let default = gateway(
        source.client,
        source.repodata_cache_dir,
        source.package_cache,
        RepodataCache::Default,
        &channels,
        &platforms,
    );
    let query = |specs: Vec<MatchSpec>| {
        let channels = channels.clone();
        let refreshing = &refreshing;
        let cached = &cached;
        let default = &default;
        async move {
            let run = |gateway: &Gateway| {
                let query = gateway
                    .query(channels.clone(), query_platforms(platform), specs.clone())
                    .recursive(true);
                async move { query.execute().await.map(|out| out.repodata) }
            };
            // A cache that libmamba's rule calls fresh but rattler cannot
            // use is downloaded again, as micromamba does.
            let run = &run;
            let refresh = move || async move {
                match run(refreshing).await {
                    Err(err) if is_unusable_cache(&err) => run(default).await,
                    other => other,
                }
            };
            query_repodata(ctx, refresh, || run(cached)).await
        }
    };
    let specs = query_specs(specs);
    let repodata = query(specs.clone()).await?;
    let missing = match (has_record(&repodata, "python"), has_record(&repodata, "pip")) {
        (true, false) => Some("pip"),
        (false, true) => Some("python"),
        _ => None,
    };
    if let Some(name) = missing {
        let mut specs = specs;
        specs.push(MatchSpec::from_str(name, ParseStrictness::Lenient).expect("a package name is a valid spec"));
        return query(specs).await;
    }
    Ok(repodata)
}

/// Strict channel priority for channel-qualified specs, as libsolv applies
/// it: every channel after the first one (in priority order) that has a
/// record of a name is excluded for that name, so `pb::foo` cannot be met
/// when an earlier channel has `foo`. resolvo skips the records of other
/// channels before it applies strict priority, so this is checked here.
///
/// libsolv keeps an installed package whatever the priority of the
/// channels: a spec that an installed record of its channel (or, for a
/// multichannel, of a member channel) already satisfies is not checked
/// (micromamba 2.10.0: `install_packages("chB::foo")` with `chA` first,
/// foo of chB installed, changes nothing).
fn check_strict_spec_channels(
    specs: &[MatchSpec],
    restrictions: &[ChannelRestriction],
    channels: &[Channel],
    repodata: &[RepoData],
    installed: &[PrefixRecord],
) -> RtResult<()> {
    let has_name = |name: &PackageName, url: &str| {
        repodata.iter().any(|set| {
            set.iter().any(|r| {
                r.package_record.name == *name && r.channel.as_deref().map(|c| c.trim_end_matches('/')) == Some(url)
            })
        })
    };
    // Channels compare without credentials (installed records have none,
    // see `secrets.rs`), trailing slashes and percent-encoding.
    let channel_key = |c: &str| percent_decode(&crate::secrets::remove_credentials_str(c.trim_end_matches('/')));
    let installed_satisfies = |name: &PackageName, spec: Option<&MatchSpec>, allowed: &[String]| {
        let allowed: Vec<String> = allowed.iter().map(|c| channel_key(c)).collect();
        installed.iter().any(|p| {
            let r = &p.repodata_record;
            r.package_record.name == *name
                && r.channel.as_deref().is_some_and(|c| allowed.contains(&channel_key(c)))
                && spec.is_none_or(|s| s.matches(&r.package_record))
        })
    };
    // A spec of a multichannel (`defaults::foo`): the first channel with
    // the name must be one of its members.
    for restriction in restrictions {
        let spec = specs.iter().find(|s| s.name.as_exact() == Some(&restriction.name));
        if installed_satisfies(&restriction.name, spec, &restriction.channels) {
            continue;
        }
        let first = channels
            .iter()
            .map(channel_url_string)
            .find(|url| has_name(&restriction.name, url));
        if let Some(first) = first {
            if !restriction.channels.contains(&first) {
                return Err(RtError::Solve(SolveError::Unsolvable(vec![format!(
                    "{} from {} is excluded by strict channel priority: {first} has {}",
                    restriction.name.as_source(),
                    restriction.multichannel,
                    restriction.name.as_source()
                )])));
            }
        }
    }
    for spec in specs {
        let (Some(channel), Some(name)) = (spec.channel.as_ref(), spec.name.as_exact()) else {
            continue;
        };
        let wanted = channel_url_string(channel);
        if installed_satisfies(name, Some(spec), std::slice::from_ref(&wanted)) {
            continue;
        }
        let first = channels.iter().map(channel_url_string).find(|url| has_name(name, url));
        if let Some(first) = first {
            if first != wanted {
                return Err(RtError::Solve(SolveError::Unsolvable(vec![format!(
                    "{} from {wanted} is excluded by strict channel priority: {first} has {}",
                    name.as_source(),
                    name.as_source()
                )])));
            }
        }
    }
    Ok(())
}

/// Drop repeated records *within* each `RepoData` set the gateway returned.
///
/// Works around a `rattler_repodata_gateway` bug (seen on 0.30.0): with
/// `.recursive(true)`, the same record can be added more than once to a single
/// returned set, and `rattler_solve` then rejects the whole solve with
/// `SolveError::DuplicateRecords`. Deduplicates *per set* only: two channels
/// can legitimately offer the same identifier, which is a choice for the
/// solver.
///
/// Records listed in `patched` (same set index, same identifier) replace the
/// gateway's.
fn dedup_repodata<'a>(
    repodata: &'a [RepoData],
    patched: &'a [Vec<RepoDataRecord>],
) -> Vec<Vec<&'a RepoDataRecord>> {
    repodata
        .iter()
        .zip(patched)
        .map(|(set, patched)| {
            let mut seen: HashSet<String> = HashSet::new();
            set.iter()
                .filter(|record| seen.insert(record.identifier.to_string()))
                .map(|record| {
                    patched
                        .iter()
                        .find(|p| p.identifier == record.identifier)
                        .unwrap_or(record)
                })
                .collect()
        })
        .collect()
}

pub(crate) struct SolveRequest {
    /// The request: always satisfied.
    pub specs: Vec<MatchSpec>,
    /// The names that only some channels may provide (specs of a
    /// multichannel, see `channels.rs`): every other candidate record of
    /// such a name, locked records included, is left out of the solve.
    pub restrictions: Vec<ChannelRestriction>,
    /// A bare-name spec per installed package: kept when the request allows.
    pub keep: Vec<MatchSpec>,
    pub locked: Vec<RepoDataRecord>,
    pub constraints: Vec<MatchSpec>,
    pub virtual_packages: Vec<GenericVirtualPackage>,
    pub channel_priority: ChannelPriority,
}

/// The largest part of `candidates` that solves together with `kept`
/// (divide and conquer: a chunk that solves is kept whole, one that does
/// not is split, a single spec that does not is dropped), and the solution
/// for everything kept. `base` is the solution for `kept` alone.
fn keep_what_solves<F>(
    run: &F,
    kept: &mut Vec<MatchSpec>,
    candidates: &[MatchSpec],
    best: &mut Vec<RepoDataRecord>,
) -> Result<(), SolveError>
where
    F: Fn(&[MatchSpec]) -> Result<Vec<RepoDataRecord>, SolveError>,
{
    if candidates.is_empty() {
        return Ok(());
    }
    let mut trial = kept.clone();
    trial.extend_from_slice(candidates);
    match run(&trial) {
        Ok(records) => {
            *kept = trial;
            *best = records;
            Ok(())
        }
        Err(SolveError::Unsolvable(_)) if candidates.len() > 1 => {
            let (left, right) = candidates.split_at(candidates.len() / 2);
            keep_what_solves(run, kept, left, best)?;
            keep_what_solves(run, kept, right, best)
        }
        Err(SolveError::Unsolvable(_)) => Ok(()),
        Err(other) => Err(other),
    }
}

/// Runs resolvo on a blocking thread; a cancel sets the solver's token.
///
/// When the request and every installed package cannot be solved together,
/// the request is solved with as many installed packages as fit (libmamba's
/// `allow_uninstall`); the original error stands when the request cannot be
/// met even alone.
pub(crate) async fn solve(
    ctx: &JobCtx,
    repodata: Vec<RepoData>,
    request: SolveRequest,
) -> RtResult<Vec<RepoDataRecord>> {
    ctx.phase(Phase::Solve)?;
    let token = ctx.solve_token();
    let handle = tokio::task::spawn_blocking(move || {
        let patched = pip_patched_records(&repodata);
        let allowed = |r: &RepoDataRecord| request.restrictions.iter().all(|x| x.allows(r));
        let available: Vec<Vec<&RepoDataRecord>> = dedup_repodata(&repodata, &patched)
            .into_iter()
            .map(|set| set.into_iter().filter(|r| allowed(r)).collect())
            .collect();
        let locked: Vec<&RepoDataRecord> = request.locked.iter().filter(|r| allowed(r)).collect();
        let run = |specs: &[MatchSpec]| {
            let mut task = SolverTask::from_iter(available.iter().cloned());
            task.specs = specs.to_vec();
            task.constraints = request.constraints.clone();
            task.locked_packages = locked.clone();
            task.virtual_packages = request.virtual_packages.clone();
            task.channel_priority = request.channel_priority;
            task.cancellation_token = Some(token.clone());
            resolvo::Solver.solve(task).map(|r| r.records)
        };
        let mut all = request.specs.clone();
        all.extend(request.keep.iter().cloned());
        let solved = match run(&all) {
            Err(SolveError::Unsolvable(problems)) if !request.keep.is_empty() => {
                let mut best = match run(&request.specs) {
                    Ok(records) => records,
                    Err(SolveError::Unsolvable(_)) => return Err(SolveError::Unsolvable(problems)),
                    Err(other) => return Err(other),
                };
                let mut kept = request.specs.clone();
                keep_what_solves(&run, &mut kept, &request.keep, &mut best)?;
                best
            }
            other => other?,
        };
        Ok(unpatched_pip(solved, &repodata))
    });
    match handle.await {
        Ok(res) => res.map_err(RtError::from),
        Err(e) => Err(RtError::Internal(format!("the solver failed: {e}"))),
    }
}

/// Dependencies first, as libsolv orders its transaction. The `pip`
/// dependency libmamba's rule gives `python` (see [`pip_patched_records()`])
/// is left out of the ordering, and `pip` is ordered after `python` (the
/// prerequisite libmamba gives it), so python comes before pip as with
/// micromamba also when both are noarch (rattler would otherwise break the
/// python <-> pip cycle at an arbitrary edge). Packages no dependency orders
/// may come in another order than libsolv's.
fn install_order(records: Vec<RepoDataRecord>) -> Vec<RepoDataRecord> {
    #[derive(Clone)]
    struct Key(usize, PackageRecord);
    impl AsRef<PackageRecord> for Key {
        fn as_ref(&self) -> &PackageRecord {
            &self.1
        }
    }
    let keys: Vec<Key> = records
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let mut pr = r.package_record.clone();
            if pr.name.as_normalized() == "python" {
                pr.depends.retain(|d| d != "pip");
            } else if pr.name.as_normalized() == "pip" && !pr.depends.iter().any(|d| d == "python") {
                pr.depends.push("python".to_string());
            }
            Key(i, pr)
        })
        .collect();
    let order: Vec<usize> = PackageRecord::sort_topologically(keys)
        .into_iter()
        .map(|k| k.0)
        .collect();
    let mut slots: Vec<Option<RepoDataRecord>> = records.into_iter().map(Some).collect();
    order.into_iter().filter_map(|i| slots[i].take()).collect()
}

/// The records of URL specs (rattler's direct URL query gives them no
/// channel, no hashes and no size), completed as micromamba's records of
/// such packages (`explicit::complete_direct_url_record()`); a package
/// installed from the same URL keeps its installed record. Runs in the
/// `prefetch` phase under the package cache's global lock, which it returns
/// for [`prefetch()`]; `None` (nothing done) when there is no such record.
async fn complete_direct_url_records(
    ctx: &JobCtx,
    cache: &PackageCache,
    pkgs_cache_dir: &Path,
    client: &LazyClient,
    before: &[PrefixRecord],
    records: &mut [RepoDataRecord],
) -> RtResult<Option<lock::FileLock>> {
    let direct: Vec<usize> = (0..records.len()).filter(|&i| records[i].channel.is_none()).collect();
    if direct.is_empty() {
        return Ok(None);
    }
    ctx.phase(Phase::Prefetch)?;
    net::ensure_http_allowed(direct.iter().map(|&i| &records[i].url))?;
    let cache_lock = lock::lock_exclusive(&lock::cache_lock_path(pkgs_cache_dir), Some(ctx), false).await?;
    for i in direct {
        // Installed records carry the URL with its credentials hidden (see
        // `secrets.rs`).
        let hidden = crate::secrets::hide_url(&records[i].url);
        if let Some(installed) = before
            .iter()
            .find(|p| crate::secrets::hide_url(&p.repodata_record.url) == hidden)
        {
            records[i] = installed.repodata_record.clone();
            continue;
        }
        let record = records[i].clone();
        records[i] = ctx
            .cancellable(crate::explicit::complete_direct_url_record(cache, pkgs_cache_dir, client, record))
            .await?;
    }
    Ok(Some(cache_lock))
}

fn record_url_error(record: &RepoDataRecord) -> RtError {
    RtError::Fetch(format!("invalid file URL {} for {}", record.url, record.identifier))
}

fn fetch_error(record: &RepoDataRecord, err: &(dyn std::error::Error + 'static)) -> RtError {
    let text = error_chain(err);
    let msg = format!("failed to fetch {}: {text}", record.identifier);
    if text.contains("hash mismatch") {
        RtError::HashMismatch(msg)
    } else {
        RtError::Fetch(msg)
    }
}

/// Downloads and extracts one package into the cache, with the archive's
/// file modes as micromamba keeps them (`pkgfile.rs`); returns its URL and
/// the extracted directory. A download is checked against the record's
/// sha256, else its md5, as rattler's cache checks it.
async fn fetch_one(
    cache: PackageCache,
    client: LazyClient,
    record: RepoDataRecord,
    semaphore: Arc<tokio::sync::Semaphore>,
) -> RtResult<(String, PathBuf)> {
    let _permit = semaphore
        .acquire_owned()
        .await
        .map_err(|_| RtError::Internal("download semaphore closed".into()))?;
    let key = rattler_cache::package_cache::CacheKey::from(&record.package_record);
    let res = if record.url.scheme() == "file" {
        let path = record.url.to_file_path().map_err(|()| record_url_error(&record))?;
        cache
            .get_or_fetch(
                key,
                move |destination| {
                    let path = path.clone();
                    async move {
                        crate::pkgfile::extract_with_modes(&path, &destination)
                            .await
                            .map(|_| ())
                    }
                },
                None,
            )
            .await
    } else {
        let url = record.url.clone();
        let sha256 = record.package_record.sha256;
        let md5 = record.package_record.md5;
        cache
            .get_or_fetch(
                key,
                move |destination| {
                    let url = url.clone();
                    let client = client.clone();
                    async move {
                        let dir = crate::pkgfile::download_dir(&destination);
                        let archive =
                            crate::pkgfile::download(&client, &url, &dir, net::MAX_RETRIES, net::RETRY_WAIT).await?;
                        let result = crate::pkgfile::extract_with_modes(&archive, &destination).await?;
                        let mismatch = |expected: String, actual: String| {
                            crate::pkgfile::FetchError::Extract(rattler_package_streaming::ExtractError::HashMismatch {
                                url: crate::secrets::hide_url(&url).to_string(),
                                destination: destination.display().to_string(),
                                expected,
                                actual,
                                total_size: result.total_size,
                            })
                        };
                        let hex = |bytes: &[u8]| bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
                        match (sha256, md5) {
                            (Some(want), _) if want != result.sha256 => {
                                let _ = tokio::fs::remove_dir_all(&destination).await;
                                Err(mismatch(hex(&want), hex(&result.sha256)))
                            }
                            (None, Some(want)) if want != result.md5 => {
                                let _ = tokio::fs::remove_dir_all(&destination).await;
                                Err(mismatch(hex(&want), hex(&result.md5)))
                            }
                            _ => Ok(()),
                        }
                    }
                },
                None,
            )
            .await
    };
    // Keyed by the URL the installed record carries (see `secrets.rs`).
    res.map(|meta| (crate::secrets::hide_url(&record.url).to_string(), meta.path().to_path_buf()))
        .map_err(|e| fetch_error(&record, &e))
}

/// The `prefetch` phase: downloads and extracts `records` into the package
/// cache, `DOWNLOAD_CONCURRENCY` at a time, under the cache's global lock
/// (`held`, when the caller took it already; released when this returns).
/// The first failure, or a cancel, aborts the other downloads; they are
/// awaited until they are gone before this returns. Returns the extracted
/// directory of every record, by URL with the credentials hidden (the URL
/// of [`crate::secrets::public_record()`]).
pub(crate) async fn prefetch(
    ctx: &JobCtx,
    cache: &PackageCache,
    pkgs_cache_dir: &Path,
    client: &LazyClient,
    records: Vec<RepoDataRecord>,
    held: Option<lock::FileLock>,
) -> RtResult<HashMap<String, PathBuf>> {
    ctx.phase(Phase::Prefetch)?;
    let mut dirs = HashMap::new();
    if records.is_empty() {
        return Ok(dirs);
    }
    net::ensure_http_allowed(records.iter().map(|r| &r.url))?;
    let _cache_lock = match held {
        Some(lock) => lock,
        None => lock::lock_exclusive(&lock::cache_lock_path(pkgs_cache_dir), Some(ctx), false).await?,
    };
    let semaphore = Arc::new(tokio::sync::Semaphore::new(DOWNLOAD_CONCURRENCY));
    let mut set = tokio::task::JoinSet::new();
    for record in records {
        set.spawn(fetch_one(
            cache.clone(),
            client.clone(),
            record,
            semaphore.clone(),
        ));
    }
    let result = ctx
        .cancellable(async {
            while let Some(joined) = set.join_next().await {
                match joined {
                    Ok(res) => {
                        let (url, dir) = res?;
                        dirs.insert(url, dir);
                    }
                    Err(e) => return Err(RtError::Internal(format!("a download task failed: {e}"))),
                }
            }
            Ok(())
        })
        .await;
    if result.is_err() {
        set.abort_all();
        while set.join_next().await.is_some() {}
    }
    result.map(|()| dirs)
}

/// The panic payload that stops the `Installer` when a cancel came before
/// its transaction started (see [`LinkGate`]).
struct CancelUnwind;

/// The reporter that moves the job to `link` when rattler's `Installer`
/// starts its transaction: after it took the package cache's global lock
/// and before it unlinks anything. When a cancel came first it stops the
/// Installer right there, by unwinding out of its future (without the panic
/// hook, so nothing is printed); nothing in the prefix has changed then.
struct LinkGate {
    ctx: JobCtx,
    #[cfg(test)]
    prefix: PathBuf,
}

/// Prefixes whose installs are cancelled right at the transaction start (a
/// test hook for the race of a cancel with that moment).
#[cfg(test)]
pub(crate) static CANCEL_AT_TRANSACTION_START: std::sync::Mutex<Vec<PathBuf>> =
    std::sync::Mutex::new(Vec::new());

impl Reporter for LinkGate {
    fn on_transaction_start(&self, _transaction: &Transaction<PrefixRecord, RepoDataRecord>) {
        #[cfg(test)]
        if CANCEL_AT_TRANSACTION_START.lock().unwrap().contains(&self.prefix) {
            self.ctx.request_cancel();
        }
        if self.ctx.enter_link().is_err() {
            std::panic::resume_unwind(Box::new(CancelUnwind));
        }
    }
    fn on_transaction_operation_start(&self, _operation: usize) {}
    fn on_populate_cache_start(&self, _operation: usize, _record: &RepoDataRecord) -> usize {
        0
    }
    fn on_validate_start(&self, _cache_entry: usize) -> usize {
        0
    }
    fn on_validate_complete(&self, _validate_idx: usize) {}
    fn on_download_start(&self, _cache_entry: usize) -> usize {
        0
    }
    fn on_download_progress(&self, _download_idx: usize, _progress: u64, _total: Option<u64>) {}
    fn on_download_completed(&self, _download_idx: usize) {}
    fn on_populate_cache_complete(&self, _cache_entry: usize) {}
    fn on_unlink_start(&self, _operation: usize, _record: &PrefixRecord) -> usize {
        0
    }
    fn on_unlink_complete(&self, _index: usize) {}
    fn on_link_start(&self, _operation: usize, _record: &RepoDataRecord) -> usize {
        0
    }
    fn on_link_complete(&self, _index: usize) {}
    fn on_transaction_operation_complete(&self, _operation: usize) {}
    fn on_transaction_complete(&self) {}
    fn on_post_link_start(&self, _package_name: &str, _script_path: &str) -> usize {
        0
    }
    fn on_post_link_complete(&self, _index: usize, _success: bool) {}
    fn on_pre_unlink_start(&self, _package_name: &str, _script_path: &str) -> usize {
        0
    }
    fn on_pre_unlink_complete(&self, _index: usize, _success: bool) {}
}

pub(crate) type LinkedTransaction = Transaction<InstallationResultRecord, RepoDataRecord>;

/// Drives the Installer; a cancel before its transaction started drops it.
async fn run_installer(
    gate: &JobCtx,
    installer: Installer,
    prefix: PathBuf,
    desired: Vec<RepoDataRecord>,
) -> RtResult<LinkedTransaction> {
    let install = installer.install(&prefix, desired);
    futures::pin_mut!(install);
    let cancelled = gate.cancelled();
    futures::pin_mut!(cancelled);
    match futures::future::select(install, cancelled).await {
        futures::future::Either::Left((res, _)) => res.map(|r| r.transaction).map_err(RtError::from),
        futures::future::Either::Right(((), install)) => {
            if gate.in_link() {
                install.await.map(|r| r.transaction).map_err(RtError::from)
            } else {
                Err(RtError::Cancelled)
            }
        }
    }
}

/// The `link` phase: rattler's `Installer` on a worker of the private rayon
/// pool (so its `spawn_fifo` and parallel iterators use that pool), inside
/// the runtime's context, one link per process at a time. Waiting for that
/// turn, for the package cache's global lock and for the Installer to take
/// it stops on a cancel; the transaction itself is not cancellable.
/// `cache_lock_dir` is the package cache whose lock the Installer will take
/// (`None` when the transaction is empty: the Installer then takes no lock).
pub(crate) async fn link(
    ctx: &JobCtx,
    installer: Installer,
    prefix: PathBuf,
    desired: Vec<RepoDataRecord>,
    cache_lock_dir: Option<&Path>,
) -> RtResult<LinkedTransaction> {
    let state = ctx.state;
    let permit = ctx
        .cancellable(async {
            state
                .link_permit
                .acquire()
                .await
                .map_err(|_| RtError::Internal("the link permit is gone".into()))
        })
        .await?;
    // The Installer waits for the package cache's global lock in a blocking
    // call; waiting here first (cancellably) makes that wait short.
    if let Some(dir) = cache_lock_dir {
        drop(lock::lock_exclusive(&lock::cache_lock_path(dir), Some(ctx), false).await?);
    }
    let installer = installer.with_reporter(LinkGate {
        ctx: ctx.clone(),
        #[cfg(test)]
        prefix: prefix.clone(),
    });
    let handle = state.runtime.handle().clone();
    let gate = ctx.clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.rayon.spawn(move || {
        let _permit = permit;
        let _guard = handle.enter();
        let res = std::panic::catch_unwind(AssertUnwindSafe(|| {
            futures::executor::block_on(run_installer(&gate, installer, prefix, desired))
        }));
        let res = match res {
            Ok(res) => res,
            Err(payload) if payload.is::<CancelUnwind>() => Err(RtError::Cancelled),
            Err(payload) => Err(RtError::Internal(
                payload
                    .downcast_ref::<&str>()
                    .map(|s| s.to_string())
                    .or_else(|| payload.downcast_ref::<String>().cloned())
                    .unwrap_or_else(|| "the link panicked".to_string()),
            )),
        };
        let _ = tx.send(res);
    });
    match rx.await {
        Ok(res) => res,
        Err(_) => Err(RtError::Internal("the link thread ended without a result".into())),
    }
}

pub(crate) fn row(op: &'static str, record: &RepoDataRecord) -> TxRow {
    let pr = &record.package_record;
    TxRow {
        op,
        name: pr.name.as_normalized().to_string(),
        version: pr.version.to_string(),
        build: pr.build.clone(),
        channel: record_channel_display(record).0,
        subdir: pr.subdir.clone(),
    }
}

pub(crate) fn old_record<'a>(old: &'a InstallationResultRecord, before: &'a [PrefixRecord]) -> Option<&'a PrefixRecord> {
    match old {
        InstallationResultRecord::Max(pr) => Some(pr),
        InstallationResultRecord::Min(min) => before.iter().find(|p| p.name() == &min.name),
    }
}

/// Whether `prefix` is an environment: it has a history (every create
/// writes one) or package records.
pub(crate) fn is_environment(prefix: &Path, records: &[PrefixRecord]) -> bool {
    !records.is_empty() || prefix.join("conda-meta").join("history").exists()
}

/// Removes what a failed or cancelled create left of a prefix that was not
/// an environment before: what the lock and rattler's `Prefix::create()`
/// made (an empty history, `CACHEDIR.TAG`, `conda-meta`), and the prefix
/// directory if it is empty then. Runs while the prefix lock is held, after
/// the lock file is gone.
pub(crate) fn remove_new_prefix(prefix: &Path) {
    let meta = prefix.join("conda-meta");
    let history = meta.join("history");
    if std::fs::metadata(&history).is_ok_and(|m| m.is_file() && m.len() == 0) {
        let _ = std::fs::remove_file(&history);
    }
    let _ = std::fs::remove_dir(&meta);
    let tag = prefix.join("CACHEDIR.TAG");
    if std::fs::read_dir(prefix).is_ok_and(|entries| {
        entries
            .flatten()
            .all(|e| e.file_name() == "CACHEDIR.TAG")
    }) {
        let _ = std::fs::remove_file(&tag);
    }
    let _ = std::fs::remove_dir(prefix);
}

/// Package records rattler writes with mode 0600 (from a temporary file);
/// libmamba's are created with the umask applied to 0666. Gives the records
/// linked by this job that mode, measured on a probe file.
#[cfg(unix)]
pub(crate) fn fix_record_modes(prefix: &Path, records: &[&RepoDataRecord]) {
    use std::os::unix::fs::PermissionsExt;
    if records.is_empty() {
        return;
    }
    let meta = prefix.join("conda-meta");
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let probe = meta.join(format!(".rattlerthis-mode-{}-{nanos}", std::process::id()));
    let mode = match std::fs::OpenOptions::new().write(true).create_new(true).open(&probe) {
        Ok(file) => {
            let mode = file.metadata().map(|m| m.permissions().mode() & 0o777);
            drop(file);
            let _ = std::fs::remove_file(&probe);
            match mode {
                Ok(mode) => mode,
                Err(_) => return,
            }
        }
        Err(_) => return,
    };
    for record in records {
        let pr = &record.package_record;
        let path = meta.join(format!("{}-{}-{}.json", pr.name.as_normalized(), pr.version, pr.build));
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode));
    }
}

#[cfg(not(unix))]
pub(crate) fn fix_record_modes(_prefix: &Path, _records: &[&RepoDataRecord]) {}

/// How the Installer puts files into a prefix: as micromamba does, hard
/// links when the cache and the prefix are on one file system, else copies,
/// never copy-on-write clones. rattler would clone on file systems that
/// support it, and on macOS whole directories of the cache, which then keep
/// the cache's directory modes where micromamba's get the umask (R-34);
/// micromamba's files share the cache's, as hard links.
pub(crate) fn link_options() -> rattler::install::LinkOptions {
    rattler::install::LinkOptions {
        allow_symbolic_links: None,
        allow_hard_links: None,
        allow_ref_links: Some(false),
    }
}

pub fn install_job(input: InstallInput) -> Job {
    spawn_job(Phase::Lock, move |ctx| async move {
        Ok(JobOutput::Install(install(&ctx, input).await?))
    })
}

/// Refuses to link in a forked child on macOS, before anything is created.
///
/// rattler's `Installer` always runs `Prefix::create()`, which marks the
/// prefix as excluded from Time Machine backups through CoreFoundation, and
/// macOS aborts a forked process that uses CoreFoundation once its parent has
/// (CoreFoundation is initialized when rattlerthis is loaded). So a fork
/// (`parallel::mcparallel()`, `mclapply()`) gets this classed error instead
/// of a crash; activations, solve checks on local channels and cache cleaning
/// work there.
pub(crate) fn ensure_link_allowed() -> RtResult<()> {
    if cfg!(target_os = "macos") && crate::runtime::is_forked_child() {
        return Err(RtError::Install(
            "cannot create or change an environment in a forked R process on macOS: rattler \
             uses CoreFoundation for it, which macOS does not let a fork use. Use a PSOCK \
             cluster (`parallel::makeCluster()`) or a new R process (callr) instead of \
             `parallel::mclapply()` or `parallel::mcparallel()`"
                .to_string(),
        ));
    }
    Ok(())
}

/// What an install needs once its arguments are checked.
struct Plan {
    platform: Platform,
    channel_priority: ChannelPriority,
    requested: Vec<MatchSpec>,
    restrictions: Vec<ChannelRestriction>,
    update_specs: Vec<String>,
    channels: Vec<Channel>,
    channel_urls: Vec<String>,
    prefix: PathBuf,
}

async fn install(ctx: &JobCtx, input: InstallInput) -> RtResult<InstallOutcome> {
    ensure_link_allowed()?;
    let platform = parse_platform(input.platform.as_deref())?;
    let channel_priority = parse_channel_priority(&input.channel_priority)?;
    let mut requested = parse_specs(&input.specs)?;
    url_md5_unsolvable(&input.specs)?;
    // The specs as libmamba writes them to the history, plus libmamba's
    // `pip`.
    let mut update_specs: Vec<String> = input.specs.iter().map(|s| update_spec_string(s)).collect();
    if let Some(pip) = pip_request(&requested) {
        requested.push(pip);
        update_specs.push("pip".to_string());
    }
    let cfg = channel_config();
    let channels = effective_channels(&input.channels, &requested, &cfg)?;
    let (requested, restrictions) = split_multichannel_specs(requested, &cfg)?;
    let channel_urls: Vec<String> = channels.iter().map(channel_url_string).collect();
    let prefix = crate::paths::weakly_canonical(&input.prefix);

    let prefix_lock = lock::lock_exclusive(&lock::prefix_lock_path(&prefix), Some(ctx), true).await?;
    let before = read_prefix_records(&prefix);
    let was_environment = before.as_ref().map_or(true, |b| is_environment(&prefix, b));
    let plan = Plan {
        platform,
        channel_priority,
        requested,
        restrictions,
        update_specs,
        channels,
        channel_urls,
        prefix: prefix.clone(),
    };
    let res = match before {
        Ok(before) => install_locked(ctx, &input, plan, before).await,
        Err(e) => Err(e),
    };
    if res.is_err() && !was_environment && !ctx.in_link() {
        // A create that stops before it linked anything leaves nothing.
        prefix_lock.release_removing(|| remove_new_prefix(&prefix));
    } else {
        drop(prefix_lock);
    }
    res
}

async fn install_locked(
    ctx: &JobCtx,
    input: &InstallInput,
    plan: Plan,
    before: Vec<PrefixRecord>,
) -> RtResult<InstallOutcome> {
    let Plan {
        platform,
        channel_priority,
        requested,
        restrictions,
        update_specs,
        channels,
        channel_urls,
        prefix,
    } = plan;
    ctx.phase(Phase::Fetch)?;
    let cache = PackageCache::new(input.pkgs_cache_dir.clone());
    // Repodata; packages are downloaded with `download_client` (`net.rs`).
    let client = net::lazy_client(&input.net);
    let download_client = net::lazy_download_client(&input.net);
    let new_installer = |installed: Vec<PrefixRecord>| {
        Installer::new()
            .with_execute_link_scripts(false)
            .with_link_options(link_options())
            .with_package_cache(cache.clone())
            .with_download_client(download_client.clone())
            .with_target_platform(platform)
            .with_installed_packages(installed)
    };

    // Nothing requested: make sure the prefix exists (`create_env()` without
    // packages), keeping whatever is installed. micromamba writes an empty
    // history and no revision for an empty create.
    if requested.is_empty() {
        if before.is_empty() {
            ctx.phase(Phase::Prefetch)?;
            link(ctx, new_installer(Vec::new()), prefix.clone(), Vec::new(), None).await?;
        }
        ctx.commit()?;
        return Ok(InstallOutcome {
            prefix: prefix.to_string_lossy().to_string(),
            records: Vec::new(),
            channels: channel_urls,
            link_scripts_skipped: Vec::new(),
        });
    }

    // Every installed package not requested again by name stays a root of
    // the solve when it can (present, but free to move when a request needs
    // it).
    let requested_names: HashSet<PackageName> = requested
        .iter()
        .filter_map(|s| s.name.as_exact().cloned())
        .collect();
    let keep: Vec<MatchSpec> = before
        .iter()
        .map(|p| p.repodata_record.package_record.name.clone())
        .filter(|name| !requested_names.contains(name))
        .map(MatchSpec::from)
        .collect();
    let mut query = requested.clone();
    query.extend(keep.iter().cloned());

    let mut constraints = python_pins(&before, &requested)?;
    constraints.extend(file_pins(&prefix)?);

    net::ensure_http_allowed(channels.iter().map(|c| -> &url::Url { c.base_url.url() }))?;
    let source = RepodataSource {
        client: &client,
        repodata_cache_dir: &input.repodata_cache_dir,
        package_cache: &cache,
    };
    let repodata = fetch_repodata(ctx, &source, channels.clone(), platform, &query).await?;
    if channel_priority == ChannelPriority::Strict {
        check_strict_spec_channels(&requested, &restrictions, &channels, &repodata, &before)?;
    }
    let virtual_packages = ctx
        .cancellable(detect_virtual_packages(platform, input.pkgs_cache_dir.clone()))
        .await?;

    let solved = solve(
        ctx,
        repodata,
        SolveRequest {
            specs: requested,
            restrictions,
            keep,
            locked: before.iter().map(|p| p.repodata_record.clone()).collect(),
            constraints,
            virtual_packages,
            channel_priority,
        },
    )
    .await?;
    let solved = install_order(solved);

    let (wheel_records, mut conda_records): (Vec<_>, Vec<_>) = solved.into_iter().partition(is_wheel);
    // Checked before anything touches the prefix.
    #[cfg(not(feature = "wheels"))]
    {
        if let Some(record) = wheel_records.first() {
            return Err(RtError::WheelUnsupported {
                name: record.package_record.name.as_normalized().to_string(),
            });
        }
    }

    // The packages of URL specs, completed as micromamba records them
    // before the transaction is planned (so a package installed from the
    // same URL before is not taken for a changed one).
    let cache_lock =
        complete_direct_url_records(ctx, &cache, &input.pkgs_cache_dir, &download_client, &before, &mut conda_records)
            .await?;

    // What the Installer will do (the same computation it runs itself), to
    // prefetch exactly the packages it installs and to find the pre-unlink
    // scripts while the old packages are still there.
    let existing_wheel_names: HashSet<PackageName> = before
        .iter()
        .filter(|p| is_wheel(&p.repodata_record))
        .map(|p| p.repodata_record.package_record.name.clone())
        .collect();
    // The Installer sees every installed record, wheels included (its clobber
    // registry is checked against every record in `conda-meta` after the
    // link), and leaves the wheel records alone as ignored packages: it can
    // neither fetch nor link them.
    let planned = Transaction::from_current_and_desired(
        before.iter(),
        conda_records.iter(),
        None,
        Some(&existing_wheel_names),
        platform,
    )
    .map_err(|e| RtError::Install(error_chain(&e)))?;
    let changes = !planned.operations.is_empty();
    let to_fetch: Vec<RepoDataRecord> = planned.installed_packages().map(|r| (*r).clone()).collect();
    let pre_unlink: HashSet<String> = planned
        .removed_packages()
        .filter_map(|old| linkscripts::pre_unlink(&prefix, &old.repodata_record.package_record))
        .map(|(name, _)| name)
        .collect();
    drop(planned);

    let package_dirs = prefetch(ctx, &cache, &input.pkgs_cache_dir, &download_client, to_fetch, cache_lock).await?;

    // The records are written without the credentials of their channel, as
    // libmamba writes them (`secrets.rs`). The packages are in the cache
    // already, so the Installer downloads nothing from the hidden URLs.
    let public_records: Vec<RepoDataRecord> = conda_records.iter().map(crate::secrets::public_record).collect();
    let installer = new_installer(before.clone()).with_ignored_packages(existing_wheel_names);
    let cache_lock_dir = changes.then_some(input.pkgs_cache_dir.as_path());
    let transaction = link(ctx, installer, prefix.clone(), public_records, cache_lock_dir).await?;
    // An empty transaction never entered `link`: this is the point after
    // which the job completes.
    ctx.commit()?;

    let mut removed: Vec<&RepoDataRecord> = Vec::new();
    let mut installed: Vec<&RepoDataRecord> = Vec::new();
    let mut skipped: Vec<(String, &'static str)> = Vec::new();
    for op in &transaction.operations {
        let (old, new) = match op {
            TransactionOperation::Install(new) => (None, Some(new)),
            TransactionOperation::Remove(old) => (Some(old), None),
            TransactionOperation::Change { old, new } | TransactionOperation::Reinstall { old, new } => {
                (Some(old), Some(new))
            }
        };
        if let Some(old) = old.and_then(|o| old_record(o, &before)) {
            removed.push(&old.repodata_record);
            let name = old.repodata_record.package_record.name.as_normalized();
            if pre_unlink.contains(name) {
                skipped.push((name.to_string(), linkscripts::PRE_UNLINK));
            }
        }
        if let Some(new) = new {
            installed.push(new);
            if let Some(dir) = package_dirs.get(new.url.as_str()) {
                skipped.extend(linkscripts::pre_link(dir, &new.package_record));
            }
            skipped.extend(linkscripts::post_link(&prefix, &new.package_record));
        }
    }
    fix_record_modes(&prefix, &installed);

    #[cfg(feature = "wheels")]
    let wheel_installed = install_wheels(&wheel_records, &conda_records, &prefix, platform, &before, &input.net).await?;
    #[cfg(feature = "wheels")]
    installed.extend(wheel_installed.iter());

    // Removals first (unlink order), then installs.
    skipped.sort_by_key(|(_, kind)| if *kind == linkscripts::PRE_UNLINK { 0 } else { 1 });
    let mut records: Vec<TxRow> = removed.iter().map(|r| row("-", r)).collect();
    records.extend(installed.iter().map(|r| row("+", r)));

    append_history(&prefix, &removed, &installed, &update_specs)?;

    Ok(InstallOutcome {
        prefix: prefix.to_string_lossy().to_string(),
        records,
        channels: channel_urls,
        link_scripts_skipped: skipped,
    })
}

/// Installs the wheel records of a solve (the `wheels` feature), returning
/// the ones newly installed.
#[cfg(feature = "wheels")]
async fn install_wheels<'a>(
    wheel_records: &'a [RepoDataRecord],
    conda_records: &[RepoDataRecord],
    prefix: &Path,
    platform: Platform,
    existing: &[PrefixRecord],
    net_settings: &crate::netenv::NetSettings,
) -> RtResult<Vec<&'a RepoDataRecord>> {
    use rattler::install::PythonInfo;
    if wheel_records.is_empty() {
        return Ok(Vec::new());
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
    let key = |r: &RepoDataRecord| {
        (
            r.package_record.name.as_normalized().to_string(),
            r.package_record.version.to_string(),
            r.package_record.build.clone(),
        )
    };
    let existing_keys: HashSet<(String, String, String)> = existing
        .iter()
        .filter(|p| is_wheel(&p.repodata_record))
        .map(|p| key(&p.repodata_record))
        .collect();
    let client = net::plain_client(net_settings)?;
    let mut installed = Vec::new();
    for record in wheel_records {
        if existing_keys.contains(&key(record)) {
            continue;
        }
        wheel::install_wheel(&client, record, prefix, &python_info, platform).await?;
        installed.push(record);
    }
    Ok(installed)
}

pub struct SolveCheckInput {
    pub specs: Vec<String>,
    pub channels: Vec<String>,
    pub channel_priority: String,
    pub platform: String,
    pub repodata_cache_dir: PathBuf,
    pub pkgs_cache_dir: PathBuf,
    /// The settings of the job's HTTP clients (`netenv.rs`).
    pub net: crate::netenv::NetSettings,
}

/// `rt_solve_check()`: whether `specs` solve for `platform`, with the
/// semantics of condathis's `micromamba create --dry-run` probe: `TRUE` when
/// the request solves, `FALSE` only when the solver reports it unsolvable
/// (which includes a package with no candidates), `NA` for anything else (a
/// missing channel, no network, a spec that does not parse). An invalid
/// platform or channel priority is an error. Nothing is downloaded or linked.
pub fn solve_check_job(input: SolveCheckInput) -> Job {
    spawn_job(Phase::Fetch, move |ctx| async move {
        let platform = parse_platform(Some(&input.platform))?;
        let channel_priority = parse_channel_priority(&input.channel_priority)?;
        let answer = match solve_check(&ctx, input, platform, channel_priority).await {
            Ok(()) => Some(true),
            Err(RtError::Cancelled) => return Err(RtError::Cancelled),
            Err(RtError::Solve(rattler_solve::SolveError::Unsolvable(_))) => Some(false),
            Err(_) => None,
        };
        Ok(JobOutput::Logical(answer))
    })
}

async fn solve_check(
    ctx: &JobCtx,
    input: SolveCheckInput,
    platform: Platform,
    channel_priority: ChannelPriority,
) -> RtResult<()> {
    let mut specs = parse_specs(&input.specs)?;
    url_md5_unsolvable(&input.specs)?;
    specs.extend(pip_request(&specs));
    let cfg = channel_config();
    let channels = effective_channels(&input.channels, &specs, &cfg)?;
    let (specs, restrictions) = split_multichannel_specs(specs, &cfg)?;
    let cache = PackageCache::new(input.pkgs_cache_dir.clone());
    let client = net::lazy_client(&input.net);
    net::ensure_http_allowed(channels.iter().map(|c| -> &url::Url { c.base_url.url() }))?;
    let source = RepodataSource {
        client: &client,
        repodata_cache_dir: &input.repodata_cache_dir,
        package_cache: &cache,
    };
    let repodata = fetch_repodata(ctx, &source, channels.clone(), platform, &specs).await?;
    if channel_priority == ChannelPriority::Strict {
        check_strict_spec_channels(&specs, &restrictions, &channels, &repodata, &[])?;
    }
    let virtual_packages = ctx
        .cancellable(detect_virtual_packages(platform, input.pkgs_cache_dir.clone()))
        .await?;
    solve(
        ctx,
        repodata,
        SolveRequest {
            specs,
            restrictions,
            keep: Vec::new(),
            locked: Vec::new(),
            constraints: Vec::new(),
            virtual_packages,
            channel_priority,
        },
    )
    .await?;
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests;
