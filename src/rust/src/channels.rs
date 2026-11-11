//! Channel list normalization, the way `micromamba` resolves `-c` arguments.
//!
//! condathis always calls micromamba with `--override-channels`, so only the
//! channels given are used. micromamba then:
//!
//! 1. drops `nodefaults` (`libmamba/src/api/install.cpp`);
//! 2. expands `defaults` to `https://repo.anaconda.com/pkgs/main` and
//!    `https://repo.anaconda.com/pkgs/r`, plus `https://repo.anaconda.com/pkgs/msys2`
//!    on Windows (a compile-time choice in `context.hpp`, so `cfg!(windows)`
//!    here);
//! 3. maps the names `pkgs/main`, `pkgs/r`, `pkgs/pro` (and `pkgs/msys2` on
//!    Windows) to `https://repo.anaconda.com/<name>` (`channel_context.cpp`);
//! 4. appends the channel of each channel-qualified spec (`bioconda::x`) that
//!    is not listed yet (`populate_context_channels_from_specs()`);
//! 5. and uses each channel once.
//!
//! rattler's own `Channel::from_str` would instead map `defaults`,
//! `nodefaults` and `pkgs/main` to `https://conda.anaconda.org/<name>`.
//!
//! A spec that names the `defaults` multichannel (`defaults::foo`) cannot
//! carry it into rattler's solver, whose channel filter is one channel:
//! [`split_multichannel_specs()`] takes the channel off and returns the
//! restriction instead, which the solve applies to the candidate records
//! (`install.rs`), as libmamba solves such a spec with any record of its
//! name from the member channels.

use rattler_conda_types::{Channel, ChannelConfig, MatchSpec, PackageName};
use std::sync::Arc;

use crate::error::{RtError, RtResult};

const ANACONDA_REPO: &str = "https://repo.anaconda.com";

/// The channel configuration used for every parse: the conda.anaconda.org
/// alias and relative paths resolved against the working directory.
pub fn channel_config() -> ChannelConfig {
    ChannelConfig::default_with_root_dir(
        std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from(".")),
    )
}

fn anaconda_custom_channel(name: &str) -> Option<String> {
    let known = matches!(name, "pkgs/main" | "pkgs/r" | "pkgs/pro")
        || (cfg!(windows) && name == "pkgs/msys2");
    known.then(|| format!("{ANACONDA_REPO}/{name}"))
}

fn defaults_channels() -> Vec<String> {
    let mut out = vec![
        format!("{ANACONDA_REPO}/pkgs/main"),
        format!("{ANACONDA_REPO}/pkgs/r"),
    ];
    if cfg!(windows) {
        out.push(format!("{ANACONDA_REPO}/pkgs/msys2"));
    }
    out
}

/// Multichannels the tests define (a name and its member channels), so a
/// solve can be checked against local channels.
#[cfg(test)]
pub(crate) static TEST_MULTICHANNELS: std::sync::Mutex<Vec<(String, Vec<String>)>> =
    std::sync::Mutex::new(Vec::new());

/// The member channels of a multichannel, as libmamba's
/// `custom_multichannels` has them under condathis's configuration:
/// `defaults` only.
fn multichannel(name: &str) -> Option<Vec<String>> {
    if name == "defaults" {
        return Some(defaults_channels());
    }
    #[cfg(test)]
    {
        if let Some((_, members)) = TEST_MULTICHANNELS.lock().unwrap().iter().find(|(n, _)| n == name) {
            return Some(members.clone());
        }
    }
    None
}

/// The canonical form used for deduplication and for the strings handed back
/// to R: the base URL without its trailing slash.
pub fn channel_url_string(channel: &Channel) -> String {
    channel.base_url.as_str().trim_end_matches('/').to_string()
}

/// Expands one `-c` argument into the channels micromamba would use for it
/// (none for `nodefaults`, two or three for `defaults`).
fn expand_one(raw: &str, cfg: &ChannelConfig) -> RtResult<Vec<Channel>> {
    let trimmed = raw.trim();
    let parse = |s: &str| {
        Channel::from_str(s, cfg).map_err(|source| RtError::ParseChannel {
            channel: raw.to_string(),
            source,
        })
    };
    if trimmed == "nodefaults" {
        return Ok(Vec::new());
    }
    if let Some(members) = multichannel(trimmed) {
        return members.iter().map(|c| parse(c)).collect();
    }
    let without_slash = trimmed.trim_end_matches('/');
    if let Some(url) = anaconda_custom_channel(without_slash) {
        return Ok(vec![parse(&url)?]);
    }
    Ok(vec![parse(trimmed)?])
}

/// The channel a channel-qualified spec names, in the form micromamba appends
/// it to the channel list, or `None`. A channel given by name (`bioconda`,
/// `pkgs/main`, `defaults`), which rattler resolved against the channel
/// alias, is returned as that name, so it goes through the same rewriting as
/// the channel list; any other channel (a URL, a local path) as its URL.
fn spec_channel_arg(spec: &MatchSpec, cfg: &ChannelConfig) -> Option<String> {
    let channel = spec.channel.as_ref()?;
    if let Some(name) = &channel.name {
        let by_name = cfg
            .channel_alias
            .join(&format!("{}/", name.trim_end_matches('/')))
            .ok();
        if by_name.as_ref() == Some(channel.base_url.url()) {
            return Some(name.clone());
        }
    }
    Some(channel.base_url.as_str().to_string())
}

/// The effective channel list for `channels` (in order) and the channels of
/// the channel-qualified `specs`, deduplicated by base URL.
pub fn effective_channels(
    channels: &[String],
    specs: &[MatchSpec],
    cfg: &ChannelConfig,
) -> RtResult<Vec<Channel>> {
    let mut out: Vec<Channel> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let mut push = |channel: Channel, out: &mut Vec<Channel>| {
        let key = channel_url_string(&channel);
        if !seen.contains(&key) {
            seen.push(key);
            out.push(channel);
        }
    };
    for raw in channels {
        for channel in expand_one(raw, cfg)? {
            push(channel, &mut out);
        }
    }
    for spec in specs {
        if let Some(arg) = spec_channel_arg(spec, cfg) {
            for channel in expand_one(&arg, cfg)? {
                push(channel, &mut out);
            }
        }
    }
    Ok(out)
}

/// Rewrites the channel of a channel-qualified spec the same way the channel
/// list is rewritten (`pkgs/main::x` -> `https://repo.anaconda.com/pkgs/main::x`),
/// so the solver's channel filter matches the records of that channel. A spec
/// naming the `defaults` multichannel is left alone here (see
/// [`split_multichannel_specs()`]).
pub fn normalize_spec_channel(mut spec: MatchSpec, cfg: &ChannelConfig) -> RtResult<MatchSpec> {
    let Some(arg) = spec_channel_arg(&spec, cfg) else {
        return Ok(spec);
    };
    let arg = arg.trim_end_matches('/').to_string();
    if let Some(url) = anaconda_custom_channel(&arg) {
        let channel = Channel::from_str(&url, cfg).map_err(|source| RtError::ParseChannel {
            channel: arg.clone(),
            source,
        })?;
        spec.channel = Some(Arc::new(channel));
    }
    Ok(spec)
}

/// A package name that only the records of some channels may provide: the
/// restriction of a spec that names a multichannel (`defaults::foo`).
#[derive(Clone, Debug, PartialEq)]
pub struct ChannelRestriction {
    pub name: PackageName,
    /// The member channels, as [`channel_url_string()`] gives them.
    pub channels: Vec<String>,
    /// The multichannel's name, for messages.
    pub multichannel: String,
}

impl ChannelRestriction {
    /// Whether a record may be used under this restriction: a record of
    /// another name always, one of this name only from a member channel.
    pub fn allows(&self, record: &rattler_conda_types::RepoDataRecord) -> bool {
        record.package_record.name != self.name
            || record
                .channel
                .as_deref()
                .map(|c| c.trim_end_matches('/'))
                .is_some_and(|c| self.channels.iter().any(|m| m == c))
    }
}

/// Takes the channel off every spec that names a multichannel and has an
/// exact package name (`defaults::foo`), and returns the restriction it
/// implies. Call it after [`effective_channels()`], which adds the member
/// channels to the channel list as micromamba does. Other specs are
/// returned as they are.
pub fn split_multichannel_specs(
    specs: Vec<MatchSpec>,
    cfg: &ChannelConfig,
) -> RtResult<(Vec<MatchSpec>, Vec<ChannelRestriction>)> {
    let mut out = Vec::with_capacity(specs.len());
    let mut restrictions = Vec::new();
    for mut spec in specs {
        let arg = spec_channel_arg(&spec, cfg).map(|a| a.trim_end_matches('/').to_string());
        let members = arg.as_deref().and_then(multichannel);
        match (members, spec.name.as_exact().cloned(), arg) {
            (Some(members), Some(name), Some(arg)) => {
                let channels = members
                    .iter()
                    .map(|m| {
                        Channel::from_str(m, cfg)
                            .map(|c| channel_url_string(&c))
                            .map_err(|source| RtError::ParseChannel {
                                channel: m.clone(),
                                source,
                            })
                    })
                    .collect::<RtResult<Vec<String>>>()?;
                spec.channel = None;
                restrictions.push(ChannelRestriction {
                    name,
                    channels,
                    multichannel: arg,
                });
                out.push(spec);
            }
            _ => out.push(spec),
        }
    }
    Ok((out, restrictions))
}

/// `%XX` escapes decoded (invalid UTF-8 replaced); anything else kept.
pub fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (
                b.get(i + 1).and_then(|c| (*c as char).to_digit(16)),
                b.get(i + 2).and_then(|c| (*c as char).to_digit(16)),
            ) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// How a record's channel appears in a history line and a transaction row:
/// the base URL of its channel without the trailing slash (the directory of
/// its URL above the subdir when the record has no channel), spelled as the
/// package URL spells it (percent-encoded), and whether the subdir follows
/// it.
///
/// micromamba writes the `channel` of a package installed from a URL (an
/// explicit file, a URL spec) decoded in its record (`.../sp chans/ch A`),
/// but its history lines keep the URL's spelling (`.../sp%20chans/ch%20A`),
/// and a package URL without a platform directory gets no subdir there
/// (`+file:///dir::foo-1.0-0`). rattlerthis keeps the record's channel as
/// micromamba writes it, and derives these from the package URL whenever
/// the URL lies in that channel.
pub fn record_channel_display(record: &rattler_conda_types::RepoDataRecord) -> (String, bool) {
    let subdir = &record.package_record.subdir;
    let s = record.url.as_str();
    let url_dir = s.rsplit_once('/').map_or(s, |(dir, _)| dir);
    let in_subdir = url_dir.strip_suffix(&format!("/{subdir}"));
    let channel = record
        .channel
        .as_deref()
        .map(|c| c.trim_end_matches('/'))
        .filter(|c| !c.is_empty());
    let Some(channel) = channel else {
        return (in_subdir.unwrap_or(url_dir).to_string(), true);
    };
    let same = |dir: &str| dir == channel || percent_decode(dir) == channel;
    if let Some(base) = in_subdir.filter(|base| same(base)) {
        return (base.to_string(), true);
    }
    if same(url_dir) {
        return (url_dir.to_string(), false);
    }
    (channel.to_string(), true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rattler_conda_types::ParseStrictness;

    fn eff(channels: &[&str], specs: &[&str]) -> Vec<String> {
        let cfg = channel_config();
        let specs: Vec<MatchSpec> = specs
            .iter()
            .map(|s| MatchSpec::from_str(s, ParseStrictness::Lenient).unwrap())
            .collect();
        let channels: Vec<String> = channels.iter().map(|s| s.to_string()).collect();
        effective_channels(&channels, &specs, &cfg)
            .unwrap()
            .iter()
            .map(channel_url_string)
            .collect()
    }

    #[test]
    fn named_channels_use_the_channel_alias() {
        assert_eq!(
            eff(&["conda-forge", "bioconda"], &[]),
            vec![
                "https://conda.anaconda.org/conda-forge",
                "https://conda.anaconda.org/bioconda"
            ]
        );
    }

    #[test]
    fn nodefaults_is_dropped_and_defaults_expanded() {
        let mut expected = vec![
            "https://conda.anaconda.org/conda-forge".to_string(),
            "https://repo.anaconda.com/pkgs/main".to_string(),
            "https://repo.anaconda.com/pkgs/r".to_string(),
        ];
        if cfg!(windows) {
            expected.push("https://repo.anaconda.com/pkgs/msys2".to_string());
        }
        assert_eq!(eff(&["conda-forge", "nodefaults", "defaults"], &[]), expected);
        assert!(eff(&["nodefaults"], &[]).is_empty());
    }

    #[test]
    fn anaconda_custom_channels_map_to_repo_anaconda_com() {
        assert_eq!(
            eff(&["pkgs/main", "pkgs/r", "pkgs/pro"], &[]),
            vec![
                "https://repo.anaconda.com/pkgs/main",
                "https://repo.anaconda.com/pkgs/r",
                "https://repo.anaconda.com/pkgs/pro"
            ]
        );
        let msys2 = eff(&["pkgs/msys2"], &[]);
        if cfg!(windows) {
            assert_eq!(msys2, vec!["https://repo.anaconda.com/pkgs/msys2"]);
        } else {
            assert_eq!(msys2, vec!["https://conda.anaconda.org/pkgs/msys2"]);
        }
    }

    #[test]
    fn spec_channels_are_appended_once() {
        assert_eq!(
            eff(&["conda-forge"], &["bioconda::samtools", "bioconda::bcftools", "xz"]),
            vec![
                "https://conda.anaconda.org/conda-forge",
                "https://conda.anaconda.org/bioconda"
            ]
        );
        assert_eq!(
            eff(&["conda-forge"], &["conda-forge::xz"]),
            vec!["https://conda.anaconda.org/conda-forge"]
        );
        assert_eq!(
            eff(&[], &["pkgs/main::python"]),
            vec!["https://repo.anaconda.com/pkgs/main"]
        );
    }

    #[test]
    fn duplicates_are_removed_keeping_the_first() {
        assert_eq!(
            eff(
                &[
                    "conda-forge",
                    "https://conda.anaconda.org/conda-forge/",
                    "bioconda",
                    "conda-forge"
                ],
                &[]
            ),
            vec![
                "https://conda.anaconda.org/conda-forge",
                "https://conda.anaconda.org/bioconda"
            ]
        );
        assert_eq!(
            eff(&["defaults", "pkgs/main"], &[])[0],
            "https://repo.anaconda.com/pkgs/main"
        );
    }

    #[test]
    fn local_paths_become_file_urls() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_string_lossy().to_string();
        let got = eff(&[&path], &[]);
        assert_eq!(got.len(), 1);
        assert!(got[0].starts_with("file://"), "{got:?}");
        assert!(!got[0].ends_with('/'));
    }

    #[test]
    fn bad_channels_are_classed_errors() {
        let cfg = channel_config();
        let err = effective_channels(&["bad[x".to_string()], &[], &cfg).unwrap_err();
        assert_eq!(err.kind(), "invalid_channel");
    }

    #[test]
    fn spec_channels_are_rewritten_like_the_list() {
        let cfg = channel_config();
        let spec = MatchSpec::from_str("pkgs/main::python", ParseStrictness::Lenient).unwrap();
        let spec = normalize_spec_channel(spec, &cfg).unwrap();
        assert_eq!(
            channel_url_string(spec.channel.as_ref().unwrap()),
            "https://repo.anaconda.com/pkgs/main"
        );
        let spec = MatchSpec::from_str("bioconda::x", ParseStrictness::Lenient).unwrap();
        let spec = normalize_spec_channel(spec, &cfg).unwrap();
        assert_eq!(
            channel_url_string(spec.channel.as_ref().unwrap()),
            "https://conda.anaconda.org/bioconda"
        );
    }

    #[test]
    fn defaults_specs_become_restrictions_to_its_members() {
        let cfg = channel_config();
        let specs: Vec<MatchSpec> = ["defaults::numpy", "conda-forge::xz", "zlib"]
            .iter()
            .map(|s| MatchSpec::from_str(s, ParseStrictness::Lenient).unwrap())
            .collect();
        let (specs, restrictions) = split_multichannel_specs(specs, &cfg).unwrap();
        // numpy loses its channel; the others keep theirs.
        assert!(specs[0].channel.is_none());
        assert_eq!(specs[0].name.as_exact().unwrap().as_normalized(), "numpy");
        assert_eq!(
            channel_url_string(specs[1].channel.as_ref().unwrap()),
            "https://conda.anaconda.org/conda-forge"
        );
        assert!(specs[2].channel.is_none());
        let mut members = vec![
            "https://repo.anaconda.com/pkgs/main".to_string(),
            "https://repo.anaconda.com/pkgs/r".to_string(),
        ];
        if cfg!(windows) {
            members.push("https://repo.anaconda.com/pkgs/msys2".to_string());
        }
        assert_eq!(restrictions.len(), 1);
        assert_eq!(restrictions[0].name.as_normalized(), "numpy");
        assert_eq!(restrictions[0].channels, members);
        assert_eq!(restrictions[0].multichannel, "defaults");
        // The channel list gets the members, as micromamba's does.
        let all = eff(&["conda-forge"], &["defaults::numpy"]);
        let mut want = vec!["https://conda.anaconda.org/conda-forge".to_string()];
        want.extend(members);
        assert_eq!(all, want);
    }

    #[test]
    fn restrictions_allow_only_member_records_of_their_name() {
        use rattler_conda_types::{PackageRecord, RepoDataRecord, Version};
        use std::str::FromStr;
        let record = |name: &str, channel: &str| {
            let mut pr = PackageRecord::new(PackageName::new_unchecked(name), Version::from_str("1").unwrap(), rattler_conda_types::package::BuildString::new_unchecked("0"));
            pr.subdir = "noarch".to_string();
            RepoDataRecord {
                package_record: pr,
                identifier: format!("{name}-1-0.conda").parse().unwrap(),
                url: url::Url::parse(&format!("{channel}/noarch/{name}-1-0.conda")).unwrap(),
                channel: Some(format!("{channel}/")),
            }
        };
        let r = ChannelRestriction {
            name: PackageName::new_unchecked("numpy"),
            channels: vec!["https://repo.anaconda.com/pkgs/main".to_string()],
            multichannel: "defaults".to_string(),
        };
        assert!(r.allows(&record("numpy", "https://repo.anaconda.com/pkgs/main")));
        assert!(!r.allows(&record("numpy", "https://conda.anaconda.org/conda-forge")));
        assert!(r.allows(&record("scipy", "https://conda.anaconda.org/conda-forge")));
    }

    #[test]
    fn record_channel_urls_lose_the_trailing_slash() {
        use rattler_conda_types::{PackageName, PackageRecord, RepoDataRecord, Version};
        use std::str::FromStr;
        use url::Url;
        let record = |channel: Option<&str>, url: &str| {
            let mut pr = PackageRecord::new(
                PackageName::new_unchecked("foo"),
                Version::from_str("1").unwrap(),
                rattler_conda_types::package::BuildString::new_unchecked("0"),
            );
            pr.subdir = "noarch".to_string();
            RepoDataRecord {
                package_record: pr,
                identifier: "foo-1-0.conda".parse().unwrap(),
                url: Url::parse(url).unwrap(),
                channel: channel.map(str::to_string),
            }
        };
        let url = "https://conda.anaconda.org/conda-forge/noarch/foo-1-0.conda";
        let cf = "https://conda.anaconda.org/conda-forge".to_string();
        assert_eq!(record_channel_display(&record(Some("https://conda.anaconda.org/conda-forge/"), url)), (cf.clone(), true));
        assert_eq!(record_channel_display(&record(None, url)), (cf, true));
        // Another channel than the URL's: the channel, as given.
        assert_eq!(
            record_channel_display(&record(Some("https://mirror.example/cf/"), url)),
            ("https://mirror.example/cf".to_string(), true)
        );
        // A decoded channel (explicit files): the URL's spelling.
        let sp = "file:///a/sp%20chans/ch%20A/noarch/foo-1-0.conda";
        assert_eq!(
            record_channel_display(&record(Some("file:///a/sp chans/ch A/"), sp)),
            ("file:///a/sp%20chans/ch%20A".to_string(), true)
        );
        // No platform directory in the URL: no subdir (micromamba's
        // `+file:///a/flat::foo-1-0`).
        let flat = "file:///a/flat/foo-1-0.conda";
        assert_eq!(
            record_channel_display(&record(Some("file:///a/flat/"), flat)),
            ("file:///a/flat".to_string(), false)
        );
        assert_eq!(percent_decode("a%20b%zz%4"), "a b%zz%4");
    }
}
