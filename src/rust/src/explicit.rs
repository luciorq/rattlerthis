//! Installs exact package URLs without a solve (`rt_install_explicit()`):
//! the lines of an explicit file (`@EXPLICIT`) and the packages a conda-lock
//! file selects, as `micromamba create -f` installs them
//! (`create_explicit_transaction_from_urls()` in
//! `libmamba/src/core/transaction.cpp`, `PackageInfo::from_url()` in
//! `libmamba/src/specs/package_info.cpp`).
//!
//! Each line is a package URL or a local path (`~` expanded as libmamba
//! expands it), optionally followed by `#<md5>`, `#<sha256>` or
//! `#sha256:<sha256>`; any other fragment is ignored, as libmamba ignores
//! it. The package's channel is the URL's directory without its platform
//! subdirectory. When the line gives a hash, the download is checked against
//! it (sha256 when given, else md5, as libmamba checks one hash); a mismatch
//! is an error of kind `hash_mismatch` and nothing is installed. libmamba
//! compares a hash as text with the archive's lower-case digest, so a hash
//! with upper-case digits never matches: it is refused before anything is
//! fetched. The package record keeps the md5 and sha256 of the archive and
//! its size, as micromamba's, and the channel decoded as micromamba writes
//! it (`file:///a/sp chans/ch A`); the history line keeps the URL's spelling
//! (`channels.rs` `record_channel_display()`).
//!
//! A job, with the phases and the cancel rules of `rt_install()`: `lock`
//! (the prefix lock), `prefetch` (every package is downloaded or read,
//! checked and extracted into the package cache, under the cache's global
//! lock) and `link` (rattler's `Installer`, link scripts off). The history
//! gets one revision: a `+` line per package in the file's order, and the
//! `# update specs` line micromamba writes for explicit installs
//! (`name==version=build` for each line); for the packages of a conda-lock
//! file micromamba writes no specs line, and neither does this.
//!
//! micromamba's order of the `+` lines of a lock file install comes from a
//! hash set (`std::unordered_set` in `create_explicit_transaction_from_lockfile()`):
//! the reverse of the file's order with libstdc++ and libc++ (Linux, macOS),
//! the file's order with Microsoft's library (Windows), as observed with
//! micromamba 2.10.0. rattlerthis always writes the file's order.
//!
//! Differences from micromamba, by design:
//!
//! - A package already installed under the same name is replaced; micromamba
//!   adds the new record next to the old one. condathis only installs
//!   explicit files into new environments, where the two agree.
//! - A file that lists one package name twice is refused (kind `env_file`);
//!   micromamba installs both records.
//! - Wheels (`.whl`), source archives (`.tar.gz`) and `git+https` lines are
//!   refused with kind `unsupported`: micromamba would hand them to its
//!   package fetcher, which installs conda packages only.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use rattler::install::{Installer, Transaction, TransactionOperation};
use rattler_cache::package_cache::{CacheKey, PackageCache};
use rattler_conda_types::package::{DistArchiveIdentifier, IndexJson, PackageFile};
use rattler_conda_types::{PackageName, PackageRecord, Subdir, PrefixRecord, RepoDataRecord, VersionWithSource};
use rattler_digest::{Md5, Md5Hash, Sha256, Sha256Hash};
use rattler_networking::LazyClient;
use url::Url;

use crate::activation::parse_platform;
use crate::channels::percent_decode;
use crate::error::{error_chain, RtError, RtResult};
use crate::history::append_history;
use crate::install::{self, InstallOutcome, TxRow};
use crate::job::{spawn_job, Job, JobCtx, JobOutput, Phase};
use crate::linkscripts;
use crate::lock;
use crate::net;
use crate::spectext::{has_archive_extension, is_hex_text, libmamba_strip};

/// The file rattlerthis keeps next to a package it fetched over HTTP in the
/// package cache (`<pkgs>/<name>-<version>-<build>/info/`): the archive's
/// URL, md5, sha256 and size, which rattler's cache does not keep. A later
/// explicit install of the same URL reads the hashes from it instead of
/// downloading the archive again.
const ARCHIVE_INFO: &str = "rattlerthis-archive.json";

/// One line of an explicit file.
#[derive(Clone, Debug, PartialEq)]
pub struct ExplicitEntry {
    pub url: Url,
    pub file_name: String,
    pub name: String,
    pub version: String,
    pub build: String,
    /// The channel URL (the URL's directory without the platform
    /// subdirectory), without a trailing slash.
    pub channel: String,
    /// The URL's platform subdirectory, when it names one.
    pub platform: Option<String>,
    pub md5: Option<Md5Hash>,
    pub sha256: Option<Sha256Hash>,
}

impl ExplicitEntry {
    /// The spec micromamba writes for the line in the history's
    /// `# update specs` (`explicit_spec()`): `name==version=build`.
    pub fn spec_string(&self) -> String {
        format!("{}=={}={}", self.name, self.version, self.build)
    }

    fn normalized_name(&self) -> String {
        PackageName::from_str(&self.name)
            .map(|n| n.as_normalized().to_string())
            .unwrap_or_else(|_| self.name.to_ascii_lowercase())
    }

    /// The package cache directory name of the package.
    fn cache_segment(&self) -> String {
        format!("{}-{}-{}", self.normalized_name(), self.version, self.build)
    }

    /// The `channel` of the package's record, as micromamba writes it: the
    /// channel URL decoded (`file:///a/sp chans/ch A`), with the trailing
    /// slash rattler's records carry. The history and the transaction rows
    /// keep the URL's own spelling (`channels.rs`
    /// `record_channel_display()`).
    fn record_channel(&self) -> String {
        format!("{}/", percent_decode(&self.channel))
    }
}

/// What a line's fragment says about the archive.
#[derive(Clone, Debug, PartialEq)]
enum Fragment {
    /// No hash (no fragment, or one libmamba ignores).
    None,
    Md5(Md5Hash),
    Sha256(Sha256Hash),
    /// A hash libmamba keeps but that no archive can match: it compares the
    /// text with the archive's lower-case hex digest, and this one has
    /// upper-case digits.
    Unmatchable { kind: &'static str, hash: String },
}

/// libmamba's hash fragment rules (`PackageInfo::from_url()`):
/// `sha256:<64 hex digits>`, or 32 hex digits (md5) or 64 (sha256), in
/// either case; anything else is ignored.
fn parse_hash_fragment(fragment: &str) -> Fragment {
    let (kind, hash) = if let Some(hash) = fragment.strip_prefix("sha256:") {
        if hash.len() != 64 || !is_hex_text(hash) {
            return Fragment::None;
        }
        ("SHA256", hash)
    } else if is_hex_text(fragment) && fragment.len() == 32 {
        ("MD5", fragment)
    } else if is_hex_text(fragment) && fragment.len() == 64 {
        ("SHA256", fragment)
    } else {
        return Fragment::None;
    };
    if hash.bytes().any(|b| b.is_ascii_uppercase()) {
        return Fragment::Unmatchable {
            kind,
            hash: hash.to_string(),
        };
    }
    match kind {
        "MD5" => rattler_digest::parse_digest_from_hex::<Md5>(hash).map_or(Fragment::None, Fragment::Md5),
        _ => rattler_digest::parse_digest_from_hex::<Sha256>(hash).map_or(Fragment::None, Fragment::Sha256),
    }
}

/// Splits a line into its URL part and hash fragment, as
/// `PackageInfo::from_url()` does (after libmamba's `util::strip()`). `Err`
/// when the line is not a package URL.
fn split_line(line: &str) -> Result<(String, Option<String>), String> {
    let stripped = libmamba_strip(line);
    let s: &str = &stripped;
    if has_archive_extension(s) {
        return Ok((s.to_string(), None));
    }
    if let Some(idx) = s.rfind('#') {
        let (url, hash) = (&s[..idx], &s[idx + 1..]);
        if has_archive_extension(url) {
            return Ok((url.to_string(), Some(hash.to_string())));
        }
    }
    if s.starts_with("git+https") {
        return Ok((s.to_string(), None));
    }
    Err(format!("not a package URL: {s:?} (micromamba: \"Fail to parse PackageInfo URL\")"))
}

/// Whether micromamba accepts `url` as a package URL (used for every entry
/// of a lock file, pip ones included).
pub fn check_package_url(url: &str) -> Result<(), String> {
    split_line(url).map(|_| ())
}

/// `true` when `s` starts with a URL scheme (`<letters>://`).
fn has_scheme(s: &str) -> bool {
    match s.find("://") {
        Some(i) if i > 0 => {
            let scheme = &s[..i];
            scheme.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
                && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
        }
        _ => false,
    }
}

/// libmamba's `user_home_dir()`: on Windows `USERPROFILE`, else `HOMEDRIVE`
/// followed by `HOMEPATH`; elsewhere `HOME`, else the user's entry in the
/// password database. Empty values count as unset.
pub(crate) fn user_home_dir() -> Option<PathBuf> {
    let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty());
    if cfg!(windows) {
        if let Some(home) = var("USERPROFILE") {
            return Some(PathBuf::from(home));
        }
        let mut home = var("HOMEDRIVE").unwrap_or_default();
        home.push(var("HOMEPATH").unwrap_or_default());
        return (!home.is_empty()).then(|| PathBuf::from(home));
    }
    var("HOME")
        .map(PathBuf::from)
        .or_else(passwd_home)
        .filter(|p| !p.as_os_str().is_empty())
}

/// The home directory of the password database (Rust's `home_dir()` asks
/// `getpwuid_r()` when `HOME` is unset or empty).
#[allow(deprecated)]
fn passwd_home() -> Option<PathBuf> {
    std::env::home_dir()
}

/// libmamba's `expand_home()`: `~` alone, or followed by a separator,
/// becomes the user's home directory. The separator is `/` on Unix; on
/// Windows it is the one that follows the `~` (`/` or `\`).
fn expand_home(s: &str) -> Result<PathBuf, String> {
    expand_home_with(s, user_home_dir)
}

fn expand_home_with(s: &str, home: impl FnOnce() -> Option<PathBuf>) -> Result<PathBuf, String> {
    let seps: &[char] = if cfg!(windows) { &['/', '\\'] } else { &['/'] };
    if s != "~" && !s.strip_prefix('~').is_some_and(|rest| rest.starts_with(seps)) {
        return Ok(PathBuf::from(s));
    }
    let home = home().ok_or_else(|| format!("cannot expand ~ in {s}: the home directory is not known"))?;
    let mut p = home;
    if s.len() > 2 {
        p.push(&s[2..]);
    }
    Ok(p)
}

/// libmamba's `path_to_url()`: `~` expanded, made absolute against the
/// working directory and normalized lexically.
fn path_to_url(s: &str) -> Result<Url, String> {
    let expanded = expand_home(s)?;
    let absolute = if expanded.is_absolute() {
        expanded
    } else {
        std::env::current_dir()
            .map_err(|e| format!("cannot resolve {s}: {e}"))?
            .join(expanded)
    };
    let mut normal = PathBuf::new();
    for component in absolute.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normal.pop();
            }
            other => normal.push(other.as_os_str()),
        }
    }
    Url::from_file_path(&normal).map_err(|()| format!("cannot turn {s} into a file URL"))
}

/// Parses one explicit line (a URL or a local path, with an optional hash
/// fragment). Kind `env_file` when it is not a package URL, `unsupported`
/// for a wheel, a source archive or a VCS URL, `hash_mismatch` for a hash
/// no archive can match.
pub fn parse_explicit_entry(line: &str) -> RtResult<ExplicitEntry> {
    let (url_part, fragment) = split_line(line).map_err(RtError::EnvFile)?;
    let url_part = url_part.as_str();
    if url_part.starts_with("git+https") {
        return Err(RtError::Unsupported(format!(
            "{url_part} is a pip VCS URL; the rattler backend installs conda packages only"
        )));
    }
    if url_part.ends_with(".whl") || url_part.ends_with(".tar.gz") {
        let what = if url_part.ends_with(".whl") { "a Python wheel" } else { "a source archive" };
        return Err(RtError::Unsupported(format!(
            "{url_part} is {what}; the rattler backend installs conda packages (.conda, .tar.bz2) \
             only"
        )));
    }
    let url = if has_scheme(url_part) {
        Url::parse(url_part).map_err(|e| RtError::EnvFile(format!("invalid package URL {url_part}: {e}")))?
    } else {
        path_to_url(url_part).map_err(RtError::EnvFile)?
    };
    let (md5, sha256) = match fragment.as_deref().map_or(Fragment::None, parse_hash_fragment) {
        Fragment::None => (None, None),
        Fragment::Md5(md5) => (Some(md5), None),
        Fragment::Sha256(sha256) => (None, Some(sha256)),
        Fragment::Unmatchable { kind, hash } => {
            return Err(RtError::HashMismatch(format!(
                "the {kind} given for {url_part} ({hash}) has upper-case hex digits, so no archive \
                 matches it: micromamba compares it with the archive's {kind} as lower-case text \
                 (micromamba: \"tarball has incorrect {kind}\")"
            )))
        }
    };
    let mut segments: Vec<String> = url
        .path_segments()
        .map(|s| s.map(percent_decode).collect())
        .unwrap_or_default();
    let file_name = segments.pop().unwrap_or_default();
    let identifier = DistArchiveIdentifier::try_from_filename(&file_name).ok_or_else(|| {
        RtError::EnvFile(format!(
            "missing name, version or build in the package file name \"{file_name}\" of {url_part}"
        ))
    })?;
    let platform = segments
        .last()
        .filter(|s| Subdir::from_str(s).is_ok())
        .cloned();
    let mut channel_url = url.clone();
    channel_url.set_fragment(None);
    channel_url.set_query(None);
    if let Ok(mut path) = channel_url.path_segments_mut() {
        path.pop();
        if platform.is_some() {
            path.pop();
        }
    }
    let channel = channel_url.as_str().trim_end_matches('/').to_string();
    let mut url = url;
    url.set_fragment(None);
    Ok(ExplicitEntry {
        url,
        file_name,
        name: identifier.identifier.name,
        version: identifier.identifier.version,
        build: identifier.identifier.build_string,
        channel,
        platform,
        md5,
        sha256,
    })
}

/// Parses every line and refuses a package name given twice.
pub fn parse_explicit_entries(lines: &[String]) -> RtResult<Vec<ExplicitEntry>> {
    let entries: Vec<ExplicitEntry> = lines.iter().map(|l| parse_explicit_entry(l)).collect::<RtResult<_>>()?;
    let mut seen: HashMap<String, &ExplicitEntry> = HashMap::new();
    for entry in &entries {
        if let Some(first) = seen.insert(entry.normalized_name(), entry) {
            return Err(RtError::EnvFile(format!(
                "the package {} is listed twice ({} and {}); an environment holds one version of \
                 each package",
                entry.name, first.file_name, entry.file_name
            )));
        }
    }
    Ok(entries)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The hashes and size of a package archive.
#[derive(Clone, Copy, Debug, PartialEq)]
struct ArchiveHashes {
    md5: Md5Hash,
    sha256: Sha256Hash,
    size: u64,
}

/// Checks `hashes` against what the line promised: sha256 when given, else
/// md5 (libmamba's `PackageFetcher::validate()`).
fn check_hashes(entry: &ExplicitEntry, hashes: &ArchiveHashes) -> RtResult<()> {
    let mismatch = |kind: &str, expected: String, actual: String| {
        RtError::HashMismatch(format!(
            "the {kind} of {} does not match the one given for it: expected {expected}, got {actual}",
            entry.url
        ))
    };
    if let Some(sha256) = entry.sha256 {
        if sha256 != hashes.sha256 {
            return Err(mismatch("SHA256", hex(&sha256), hex(&hashes.sha256)));
        }
    } else if let Some(md5) = entry.md5 {
        if md5 != hashes.md5 {
            return Err(mismatch("MD5", hex(&md5), hex(&hashes.md5)));
        }
    }
    Ok(())
}

/// The record that names the package in the cache before its `index.json`
/// is known: name, version and build from the file name, and the hashes.
fn stub_record(entry: &ExplicitEntry, md5: Option<Md5Hash>, sha256: Option<Sha256Hash>) -> RtResult<PackageRecord> {
    let name = PackageName::from_str(&entry.name)
        .map_err(|e| RtError::EnvFile(format!("invalid package name in {}: {e}", entry.file_name)))?;
    let version = VersionWithSource::from_str(&entry.version)
        .map_err(|e| RtError::EnvFile(format!("invalid version in {}: {e}", entry.file_name)))?;
    // Not validated against CEP 26: micromamba takes any build string.
    let mut record = PackageRecord::new(name, version, rattler_conda_types::package::BuildString::new_unchecked(entry.build.clone()));
    record.md5 = md5;
    record.sha256 = sha256;
    Ok(record)
}

/// md5, sha256 and size of a local archive, in one read.
fn hash_file(path: &Path) -> std::io::Result<ArchiveHashes> {
    use rattler_digest::digest::Digest;
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut md5 = Md5::new();
    let mut sha256 = Sha256::new();
    let mut size = 0u64;
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        md5.update(&buf[..n]);
        sha256.update(&buf[..n]);
        size += n as u64;
    }
    Ok(ArchiveHashes {
        md5: md5.finalize(),
        sha256: sha256.finalize(),
        size,
    })
}

#[derive(serde::Serialize, serde::Deserialize)]
struct ArchiveInfo {
    url: String,
    md5: String,
    sha256: String,
    size: u64,
}

fn read_archive_info(dir: &Path, url: &Url) -> Option<ArchiveHashes> {
    let bytes = std::fs::read(dir.join("info").join(ARCHIVE_INFO)).ok()?;
    let info: ArchiveInfo = serde_json::from_slice(&bytes).ok()?;
    // Written with the credentials of the URL hidden (`write_archive_info()`).
    if info.url != crate::secrets::hide_url(url).as_str() && info.url != url.as_str() {
        return None;
    }
    Some(ArchiveHashes {
        md5: rattler_digest::parse_digest_from_hex::<Md5>(&info.md5)?,
        sha256: rattler_digest::parse_digest_from_hex::<Sha256>(&info.sha256)?,
        size: info.size,
    })
}

fn write_archive_info(dir: &Path, url: &Url, hashes: &ArchiveHashes) {
    // The package cache keeps no credentials of a channel.
    let info = ArchiveInfo {
        url: crate::secrets::hide_url(url).to_string(),
        md5: hex(&hashes.md5),
        sha256: hex(&hashes.sha256),
        size: hashes.size,
    };
    if let Ok(text) = serde_json::to_string(&info) {
        let _ = std::fs::write(dir.join("info").join(ARCHIVE_INFO), text);
    }
}

/// The package record from the extracted package's `info/index.json` and
/// the archive's hashes; the subdir is the URL's platform when it names one
/// (libmamba takes the platform from the URL).
fn build_record(entry: &ExplicitEntry, dir: &Path, hashes: &ArchiveHashes) -> RtResult<RepoDataRecord> {
    let index = IndexJson::from_package_directory(dir).map_err(|e| {
        RtError::Fetch(format!("failed to read info/index.json of {}: {e}", entry.file_name))
    })?;
    let mut record = PackageRecord::from_index_json(index, Some(hashes.size), Some(hashes.sha256), Some(hashes.md5))
        .map_err(|e| RtError::Fetch(format!("invalid info/index.json in {}: {e}", entry.file_name)))?;
    if let Some(platform) = &entry.platform {
        record.subdir = platform.clone();
    }
    let identifier = DistArchiveIdentifier::try_from_filename(&entry.file_name)
        .ok_or_else(|| RtError::EnvFile(format!("invalid package file name {}", entry.file_name)))?;
    Ok(RepoDataRecord {
        package_record: record,
        identifier,
        url: entry.url.clone(),
        channel: Some(entry.record_channel()),
    })
}

fn cache_error(entry: &ExplicitEntry, err: &(dyn std::error::Error + 'static)) -> RtError {
    RtError::Fetch(format!(
        "failed to fetch {}: {}",
        crate::secrets::hide_url(&entry.url),
        error_chain(err)
    ))
}

/// A package fetched into the cache: its record and extracted directory.
struct Fetched {
    record: RepoDataRecord,
    dir: PathBuf,
}

/// Why the download closure failed, so the error keeps its kind.
#[derive(Debug, thiserror::Error)]
enum DownloadError {
    #[error(transparent)]
    Fetch(#[from] crate::pkgfile::FetchError),
    #[error(transparent)]
    Extract(#[from] rattler_package_streaming::ExtractError),
    #[error("{0}")]
    Mismatch(String),
}

/// A local archive: read and hashed, checked, then extracted into the cache
/// (unless the cache has it with the same sha256).
async fn fetch_file(cache: &PackageCache, entry: &ExplicitEntry) -> RtResult<Fetched> {
    let path = entry
        .url
        .to_file_path()
        .map_err(|()| RtError::Fetch(format!("invalid file URL {}", entry.url)))?;
    let read_path = path.clone();
    let hashes = tokio::task::spawn_blocking(move || hash_file(&read_path))
        .await
        .map_err(|e| RtError::Internal(format!("hashing {} failed: {e}", path.display())))?
        .map_err(|e| RtError::Fetch(format!("failed to read {}: {e}", path.display())))?;
    check_hashes(entry, &hashes)?;
    let stub = stub_record(entry, Some(hashes.md5), Some(hashes.sha256))?;
    // The archive's file modes, as micromamba keeps them (`pkgfile.rs`).
    let meta = cache
        .get_or_fetch(
            CacheKey::from(&stub),
            move |destination| {
                let path = path.clone();
                // The cache records the archive's sha256 with the entry.
                async move {
                    crate::pkgfile::extract_with_modes(&path, &destination)
                        .await
                        .map(|result| Some(result.sha256))
                }
            },
            None,
        )
        .await
        .map_err(|e| cache_error(entry, &e))?;
    let dir = meta.path().to_path_buf();
    let record = build_record(entry, &dir, &hashes)?;
    Ok(Fetched { record, dir })
}

/// An archive over HTTP: from the cache when rattlerthis fetched that URL
/// before (its hashes are kept next to the package), else downloaded,
/// checked and extracted.
async fn fetch_http(
    cache: &PackageCache,
    pkgs_cache_dir: &Path,
    client: &LazyClient,
    entry: &ExplicitEntry,
) -> RtResult<Fetched> {
    let cache_dir = pkgs_cache_dir.join(entry.cache_segment());
    for attempt in 0..2 {
        let downloaded: Arc<Mutex<Option<ArchiveHashes>>> = Arc::new(Mutex::new(None));
        let mismatch: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let key = CacheKey::from(&stub_record(entry, entry.md5, entry.sha256)?);
        let fetch = {
            let client = client.clone();
            let entry = entry.clone();
            let downloaded = downloaded.clone();
            let mismatch = mismatch.clone();
            move |destination: PathBuf| {
                let client = client.clone();
                let entry = entry.clone();
                let downloaded = downloaded.clone();
                let mismatch = mismatch.clone();
                async move {
                    // The download client retries HTTP statuses; a failed
                    // connection, a timeout or a transfer that breaks after a
                    // good response is retried here, as rattler's cache
                    // retries them (`pkgfile::download()`): 4 attempts
                    // at most. The archive goes to a temporary file, so its
                    // file modes can be kept (`pkgfile.rs`).
                    let dir = crate::pkgfile::download_dir(&destination);
                    let archive =
                        crate::pkgfile::download(&client, &entry.url, &dir, net::MAX_RETRIES, net::RETRY_WAIT).await?;
                    let res = crate::pkgfile::extract_with_modes(&archive, &destination).await?;
                    let hashes = ArchiveHashes {
                        md5: res.md5,
                        sha256: res.sha256,
                        size: res.total_size,
                    };
                    if let Err(e) = check_hashes(&entry, &hashes) {
                        let text = e.to_string();
                        *mismatch.lock().unwrap() = Some(text.clone());
                        return Err(DownloadError::Mismatch(text));
                    }
                    *downloaded.lock().unwrap() = Some(hashes);
                    Ok::<_, DownloadError>(Some(hashes.sha256))
                }
            }
        };
        let res = cache.get_or_fetch(key, fetch, None).await;
        if let Some(text) = mismatch.lock().unwrap().take() {
            return Err(RtError::HashMismatch(text));
        }
        let meta = res.map_err(|e| cache_error(entry, &e))?;
        let dir = meta.path().to_path_buf();
        let fresh = *downloaded.lock().unwrap();
        let hashes = match fresh {
            Some(hashes) => {
                write_archive_info(&dir, &entry.url, &hashes);
                Some(hashes)
            }
            // A cache hit: usable when this URL was fetched before and the
            // hashes kept then agree with the line's.
            None => read_archive_info(&dir, &entry.url).filter(|h| check_hashes(entry, h).is_ok()),
        };
        if let Some(hashes) = hashes {
            let record = build_record(entry, &dir, &hashes)?;
            return Ok(Fetched { record, dir });
        }
        if attempt == 0 {
            // A package of that name, version and build from elsewhere, or
            // without known hashes: fetch it again.
            tokio::fs::remove_dir_all(&cache_dir)
                .await
                .map_err(|e| RtError::io_at(format!("failed to remove {}", cache_dir.display()), e))?;
        }
    }
    Err(RtError::Internal(format!(
        "the package cache kept returning {} without its hashes",
        cache_dir.display()
    )))
}

/// A record of a URL spec (rattler's direct URL query: no channel, no
/// hashes, no size), completed as micromamba records such a package: the
/// URL's channel (decoded, see [`ExplicitEntry::record_channel()`]), the
/// URL's platform as its subdir, and the archive's md5, sha256 and size.
/// A local archive is read for its hashes; a download is fetched into the
/// package cache with them (a second download when rattler's query fetched
/// it already without keeping them). The caller holds the package cache's
/// global lock.
pub(crate) async fn complete_direct_url_record(
    cache: &PackageCache,
    pkgs_cache_dir: &Path,
    client: &LazyClient,
    mut record: RepoDataRecord,
) -> RtResult<RepoDataRecord> {
    let entry = parse_explicit_entry(record.url.as_str())?;
    let hashes = if entry.url.scheme() == "file" {
        let path = entry
            .url
            .to_file_path()
            .map_err(|()| RtError::Fetch(format!("invalid file URL {}", entry.url)))?;
        let read_path = path.clone();
        tokio::task::spawn_blocking(move || hash_file(&read_path))
            .await
            .map_err(|e| RtError::Internal(format!("hashing {} failed: {e}", path.display())))?
            .map_err(|e| RtError::Fetch(format!("failed to read {}: {e}", path.display())))?
    } else {
        let fetched = fetch_http(cache, pkgs_cache_dir, client, &entry).await?;
        let pr = &fetched.record.package_record;
        match (pr.md5, pr.sha256, pr.size) {
            (Some(md5), Some(sha256), Some(size)) => ArchiveHashes { md5, sha256, size },
            _ => return Err(RtError::Internal(format!("no hashes for {}", entry.url))),
        }
    };
    let pr = &mut record.package_record;
    pr.md5 = Some(hashes.md5);
    pr.sha256 = Some(hashes.sha256);
    pr.size = Some(hashes.size);
    if let Some(platform) = &entry.platform {
        pr.subdir = platform.clone();
    }
    record.channel = Some(entry.record_channel());
    Ok(record)
}

async fn fetch_entry(
    cache: PackageCache,
    pkgs_cache_dir: PathBuf,
    client: LazyClient,
    entry: ExplicitEntry,
    semaphore: Arc<tokio::sync::Semaphore>,
) -> RtResult<Fetched> {
    let _permit = semaphore
        .acquire_owned()
        .await
        .map_err(|_| RtError::Internal("download semaphore closed".into()))?;
    if entry.url.scheme() == "file" {
        fetch_file(&cache, &entry).await
    } else {
        fetch_http(&cache, &pkgs_cache_dir, &client, &entry).await
    }
}

/// The `prefetch` phase of an explicit install: every entry fetched into
/// the cache, `DOWNLOAD_CONCURRENCY` at a time, under the cache's global
/// lock. The first failure, or a cancel, aborts the others (awaited until
/// they are gone). Returns the records in the entries' order.
async fn prefetch_explicit(
    ctx: &JobCtx,
    cache: &PackageCache,
    pkgs_cache_dir: &Path,
    client: &LazyClient,
    entries: &[ExplicitEntry],
) -> RtResult<Vec<Fetched>> {
    ctx.phase(Phase::Prefetch)?;
    if entries.is_empty() {
        return Ok(Vec::new());
    }
    net::ensure_http_allowed(entries.iter().map(|e| &e.url))?;
    let _cache_lock = lock::lock_exclusive(&lock::cache_lock_path(pkgs_cache_dir), Some(ctx), false).await?;
    let semaphore = Arc::new(tokio::sync::Semaphore::new(install::DOWNLOAD_CONCURRENCY));
    let mut set = tokio::task::JoinSet::new();
    for (i, entry) in entries.iter().enumerate() {
        let fut = fetch_entry(
            cache.clone(),
            pkgs_cache_dir.to_path_buf(),
            client.clone(),
            entry.clone(),
            semaphore.clone(),
        );
        set.spawn(async move { fut.await.map(|f| (i, f)) });
    }
    let mut slots: Vec<Option<Fetched>> = entries.iter().map(|_| None).collect();
    let result = ctx
        .cancellable(async {
            while let Some(joined) = set.join_next().await {
                match joined {
                    Ok(res) => {
                        let (i, fetched) = res?;
                        slots[i] = Some(fetched);
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
    result?;
    Ok(slots.into_iter().map(|s| s.expect("every entry was fetched")).collect())
}

pub struct ExplicitInput {
    pub urls: Vec<String>,
    pub prefix: PathBuf,
    pub platform: Option<String>,
    pub pkgs_cache_dir: PathBuf,
    /// The URLs come from a lock file: no `# update specs` line.
    pub lock_file: bool,
    /// The settings of the job's HTTP clients (`netenv.rs`).
    pub net: crate::netenv::NetSettings,
}

pub fn install_explicit_job(input: ExplicitInput) -> Job {
    spawn_job(Phase::Lock, move |ctx| async move {
        Ok(JobOutput::Install(install_explicit(&ctx, input).await?))
    })
}

async fn install_explicit(ctx: &JobCtx, input: ExplicitInput) -> RtResult<InstallOutcome> {
    install::ensure_link_allowed()?;
    let platform = parse_platform(input.platform.as_deref())?;
    // Every line is checked before anything is locked or created.
    let entries = parse_explicit_entries(&input.urls)?;
    let prefix = crate::paths::weakly_canonical(&input.prefix);

    let prefix_lock = lock::lock_exclusive(&lock::prefix_lock_path(&prefix), Some(ctx), true).await?;
    let before = install::read_prefix_records(&prefix);
    let was_environment = before
        .as_ref()
        .map_or(true, |b| install::is_environment(&prefix, b));
    let res = match before {
        Ok(before) => install_explicit_locked(ctx, &input, platform, entries, prefix.clone(), before).await,
        Err(e) => Err(e),
    };
    if res.is_err() && !was_environment && !ctx.in_link() {
        prefix_lock.release_removing(|| install::remove_new_prefix(&prefix));
    } else {
        drop(prefix_lock);
    }
    res
}

async fn install_explicit_locked(
    ctx: &JobCtx,
    input: &ExplicitInput,
    platform: Subdir,
    entries: Vec<ExplicitEntry>,
    prefix: PathBuf,
    before: Vec<PrefixRecord>,
) -> RtResult<InstallOutcome> {
    let cache = PackageCache::new(input.pkgs_cache_dir.clone());
    let client = net::lazy_download_client(&input.net);
    let new_installer = |installed: Vec<PrefixRecord>| {
        Installer::new()
            .with_execute_link_scripts(false)
            .with_link_options(install::link_options())
            .with_package_cache(cache.clone())
            .with_download_client(client.clone())
            .with_target_platform(platform)
            .with_installed_packages(installed)
    };
    let mut channels: Vec<String> = Vec::new();
    for entry in &entries {
        if !channels.contains(&entry.channel) {
            channels.push(entry.channel.clone());
        }
    }
    let update_specs: Vec<String> = if input.lock_file {
        Vec::new()
    } else {
        entries.iter().map(ExplicitEntry::spec_string).collect()
    };

    // No packages (an explicit file with only its header): make sure the
    // prefix exists, as micromamba does.
    if entries.is_empty() {
        ctx.phase(Phase::Prefetch)?;
        if before.is_empty() {
            install::link(ctx, new_installer(Vec::new()), prefix.clone(), Vec::new(), None).await?;
        }
        ctx.commit()?;
        return Ok(InstallOutcome {
            prefix: prefix.to_string_lossy().to_string(),
            records: Vec::new(),
            channels,
            link_scripts_skipped: Vec::new(),
        });
    }

    let mut fetched = prefetch_explicit(ctx, &cache, &input.pkgs_cache_dir, &client, &entries).await?;
    // The records are written without the credentials of their URLs, as
    // libmamba writes them (`secrets.rs`); the packages are in the cache.
    for f in &mut fetched {
        f.record = crate::secrets::public_record(&f.record);
    }
    let new_names: HashSet<PackageName> = fetched
        .iter()
        .map(|f| f.record.package_record.name.clone())
        .collect();
    let existing_wheel_names: HashSet<PackageName> = before
        .iter()
        .filter(|p| install::is_wheel(&p.repodata_record))
        .map(|p| p.repodata_record.package_record.name.clone())
        .collect();
    // What is installed stays, except the packages the file replaces.
    let mut desired: Vec<RepoDataRecord> = before
        .iter()
        .filter(|p| !install::is_wheel(&p.repodata_record))
        .filter(|p| !new_names.contains(&p.repodata_record.package_record.name))
        .map(|p| p.repodata_record.clone())
        .collect();
    desired.extend(fetched.iter().map(|f| f.record.clone()));

    let planned = Transaction::from_current_and_desired(
        before.iter(),
        desired.iter(),
        None,
        Some(&existing_wheel_names),
        platform,
    )
    .map_err(|e| RtError::Install(error_chain(&e)))?;
    let changes = !planned.operations.is_empty();
    let pre_unlink: HashSet<String> = planned
        .removed_packages()
        .filter_map(|old| linkscripts::pre_unlink(&prefix, &old.repodata_record.package_record))
        .map(|(name, _)| name)
        .collect();
    drop(planned);

    let installer = new_installer(before.clone()).with_ignored_packages(existing_wheel_names);
    let cache_lock_dir = changes.then_some(input.pkgs_cache_dir.as_path());
    let transaction = install::link(ctx, installer, prefix.clone(), desired, cache_lock_dir).await?;
    ctx.commit()?;

    let dirs: HashMap<&str, &Path> = fetched
        .iter()
        .map(|f| (f.record.url.as_str(), f.dir.as_path()))
        .collect();
    let order: HashMap<&str, usize> = fetched
        .iter()
        .enumerate()
        .map(|(i, f)| (f.record.url.as_str(), i))
        .collect();
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
        if let Some(old) = old.and_then(|o| install::old_record(o, &before)) {
            removed.push(&old.repodata_record);
            let name = old.repodata_record.package_record.name.as_normalized();
            if pre_unlink.contains(name) {
                skipped.push((name.to_string(), linkscripts::PRE_UNLINK));
            }
        }
        if let Some(new) = new {
            installed.push(new);
        }
    }
    // The file's order, as micromamba's history and transaction.
    installed.sort_by_key(|r| order.get(r.url.as_str()).copied().unwrap_or(usize::MAX));
    for new in &installed {
        if let Some(dir) = dirs.get(new.url.as_str()) {
            skipped.extend(linkscripts::pre_link(dir, &new.package_record));
        }
        skipped.extend(linkscripts::post_link(&prefix, &new.package_record));
    }
    install::fix_record_modes(&prefix, &installed);
    skipped.sort_by_key(|(_, kind)| if *kind == linkscripts::PRE_UNLINK { 0 } else { 1 });
    let mut records: Vec<TxRow> = removed.iter().map(|r| install::row("-", r)).collect();
    records.extend(installed.iter().map(|r| install::row("+", r)));

    append_history(&prefix, &removed, &installed, &update_specs)?;

    Ok(InstallOutcome {
        prefix: prefix.to_string_lossy().to_string(),
        records,
        channels,
        link_scripts_skipped: skipped,
    })
}

#[cfg(test)]
mod tests;
