//! `conda-meta/history`, in the format micromamba 2.10 writes
//! (`libmamba/src/core/history.cpp` `History::add_entry()`):
//!
//! ```text
//! ==> 2026-10-27 19:28:03 <==
//! -https://conda.anaconda.org/conda-forge/linux-64::xz-5.6.2-h4bc722e_1
//! +file:///abs/chans/chB/noarch::foo-2.0-0
//! # update specs: ["bar"]
//! ```
//!
//! The date is local time. `-` lines (removed packages, and the old side of a
//! change) come before `+` lines (installed packages, and the new side of a
//! change); each names the record's channel URL without its trailing slash,
//! then `/<subdir>::<name>-<version>-<build>`. The specs line lists the
//! requested specs, each double-quoted with `"` and `\` escaped (C++
//! `std::quoted`), and is left out when no spec was requested. Each spec is
//! written as libmamba writes it back (`MatchSpec::to_string()`, see
//! [`update_spec_string()`]). On Windows the lines end with CRLF: libmamba
//! writes the file in text mode.
//!
//! The order of the `+` and `-` lines is rattler's (dependencies first), not
//! libsolv's transaction order: the two agree where dependencies decide the
//! order and may differ among unrelated packages. condathis reads the lines
//! as a set.
//!
//! micromamba also writes `# cmd: <command line>` and `# conda version: 3.8.0`
//! lines. rattlerthis writes neither (decision Q12 of SPEC-backend.md): it is
//! not conda, and the backend cannot see the user's call. condathis's
//! `get_env_history_channels()` reads only the `+` and `-` lines.

use std::io::Write;
use std::path::Path;

use rattler_conda_types::version_spec::{EqualityOperator, LogicalOperator, RangeOperator, StrictRangeOperator};
use rattler_conda_types::{MatchSpec, PackageNameMatcher, ParseStrictness, RepoDataRecord, StringMatcher, VersionSpec};

use crate::channels::record_channel_display;
use crate::spectext::spec_text;
use crate::error::{RtError, RtResult};

/// `<channel>/<subdir>::<name>-<version>-<build>`, or
/// `<channel>::<name>-<version>-<build>` for a package URL without a
/// platform directory (see [`record_channel_display()`]).
pub fn dist_string(record: &RepoDataRecord) -> String {
    let pr = &record.package_record;
    let (channel, with_subdir) = record_channel_display(record);
    let subdir = if with_subdir { format!("/{}", pr.subdir) } else { String::new() };
    format!("{channel}{subdir}::{}-{}-{}", pr.name.as_source(), pr.version, pr.build)
}

/// `std::quoted()` of a spec: double quotes around it, with `"` and `\`
/// escaped by a backslash.
fn quoted(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// A version spec as libmamba prints it (`fmt::formatter<VersionSpec>`):
/// `==v`, `!=v`, `>v`, `>=v`, `<v`, `<=v`, `=v` (starts with), `!=v.*`,
/// `~=v`, `=*` (anything). A group is libmamba's right-deep binary tree, in
/// which every operand that is a branch is parenthesized (`>=0.5,<2,!=1.5`
/// -> `>=0.5,(<2,!=1.5)`). `None` for a form without a sure libmamba
/// equivalent, such as a group inside a group (libmamba gives `,` and `|`
/// other precedences than rattler).
fn libmamba_version(spec: &VersionSpec) -> Option<String> {
    Some(match spec {
        VersionSpec::Any => "=*".to_string(),
        VersionSpec::None => return None,
        VersionSpec::Range(op, v) => {
            let op = match op {
                RangeOperator::Greater => ">",
                RangeOperator::GreaterEquals => ">=",
                RangeOperator::Less => "<",
                RangeOperator::LessEquals => "<=",
            };
            format!("{op}{v}")
        }
        VersionSpec::Exact(EqualityOperator::Equals, v) => format!("=={v}"),
        VersionSpec::Exact(EqualityOperator::NotEquals, v) => format!("!={v}"),
        VersionSpec::StrictRange(StrictRangeOperator::StartsWith, v) => format!("={v}"),
        VersionSpec::StrictRange(StrictRangeOperator::NotStartsWith, v) => format!("!={v}.*"),
        VersionSpec::StrictRange(StrictRangeOperator::Compatible, v) => format!("~={v}"),
        VersionSpec::StrictRange(StrictRangeOperator::NotCompatible, _) => return None,
        VersionSpec::Group(op, items) => {
            if items.is_empty() || items.iter().any(|i| matches!(i, VersionSpec::Group(..))) {
                return None;
            }
            let sep = match op {
                LogicalOperator::And => ",",
                LogicalOperator::Or => "|",
            };
            let texts = items.iter().map(libmamba_version).collect::<Option<Vec<String>>>()?;
            // Right-deep: a, (b, (c, d)).
            let mut out = texts.last()?.clone();
            for (i, text) in texts.iter().rev().skip(1).enumerate() {
                out = if i == 0 { format!("{text}{sep}{out}") } else { format!("{text}{sep}({out})") };
            }
            out
        }
    })
}

/// The `name=version=build` form: `(version, build)` as written.
fn conda_build_form(rest: &str, name: &str) -> Option<(String, String)> {
    let tail = rest.strip_prefix(name)?.strip_prefix('=')?;
    if tail.starts_with('=') {
        return None;
    }
    let (version, build) = tail.split_once('=')?;
    let plain = |s: &str| !s.is_empty() && !s.contains(|c: char| "=<>!~,|[]() \t".contains(c));
    (plain(version) && plain(build)).then(|| (version.to_string(), build.to_string()))
}

/// A spec as libmamba writes it to the `# update specs` line
/// (`MatchSpec::to_string()`): the channel part as written, the name, then
/// the version (`foo >=2` -> `foo>=2`, `mid 2.*` -> `mid=2`,
/// `qux[version='>=2']` -> `qux>=2`, `foo 1.0` -> `foo==1.0`) and the build
/// string (`=<build>`), or both in brackets when the version is a compound
/// expression or the build string a glob. A spec with any other field (a
/// package URL, without the fragment libmamba drops), or that does not
/// parse, is written as given after libmamba's cleanup (`spectext.rs`); so
/// is a version expression that nests `,` and `|`.
pub fn update_spec_string(raw: &str) -> String {
    // What libmamba's parser keeps of the text (a byte order mark, a
    // comment and a non-hex URL fragment go).
    let text = spec_text(raw).into_text();
    let raw = text.as_str();
    let (prefix, rest) = match raw.find("::") {
        Some(i) => raw.split_at(i + 2),
        None => ("", raw),
    };
    let Ok(spec) = MatchSpec::from_str(rest, ParseStrictness::Lenient) else {
        return raw.to_string();
    };
    let MatchSpec {
        name,
        version,
        build,
        build_number,
        file_name,
        extras,
        flags,
        channel,
        subdir,
        namespace,
        md5,
        sha256,
        url,
        license,
        license_family,
        condition,
        track_features,
    } = spec;
    let other_fields = build_number.is_some()
        || file_name.is_some()
        || extras.is_some()
        || flags.is_some()
        || channel.is_some()
        || subdir.is_some()
        || namespace.is_some()
        || md5.is_some()
        || sha256.is_some()
        || url.is_some()
        || license.is_some()
        || license_family.is_some()
        || condition.is_some()
        || track_features.is_some();
    let PackageNameMatcher::Exact(name) = name else {
        return raw.to_string();
    };
    if other_fields {
        return raw.to_string();
    }
    let version = version.filter(|v| !matches!(v, VersionSpec::Any));
    let build = match build {
        Some(StringMatcher::Exact(b)) => Some((b, false)),
        // rattler parses `*`, `0*` and `*_0` into their own variants, not
        // into `Glob`; libmamba writes them as the globs they are.
        Some(StringMatcher::Any) => None,
        Some(StringMatcher::Prefix(p)) => Some((format!("{p}*"), true)),
        Some(StringMatcher::Suffix(s)) => Some((format!("*{s}"), true)),
        Some(StringMatcher::Glob(g)) if g.as_str() == "*" => None,
        Some(StringMatcher::Glob(g)) => Some((g.as_str().to_string(), true)),
        Some(_) => return raw.to_string(),
        None => None,
    };
    let version_text = match conda_build_form(rest.trim(), name.as_source()) {
        // libmamba keeps `=1.0` a "starts with" here; rattler reads `==1.0`.
        Some((v, _)) if build.is_some() => Some(format!("={v}")),
        _ => match &version {
            Some(v) => match libmamba_version(v) {
                Some(text) => Some(text),
                None => return raw.to_string(),
            },
            None => None,
        },
    };
    let complex = matches!(version, Some(VersionSpec::Group(..))) || build.as_ref().is_some_and(|(_, glob)| *glob);
    let mut out = format!("{prefix}{}", name.as_source());
    if !complex {
        match (&version_text, &build) {
            (v, Some((b, _))) => {
                out.push_str(v.as_deref().unwrap_or("=*"));
                out.push('=');
                out.push_str(b);
            }
            (Some(v), None) => out.push_str(v),
            (None, None) => {}
        }
    } else {
        let mut attrs = Vec::new();
        if let Some(v) = &version_text {
            attrs.push(format!("version=\"{v}\""));
        }
        if let Some((b, _)) = &build {
            attrs.push(format!("build=\"{b}\""));
        }
        out.push_str(&format!("[{}]", attrs.join(",")));
    }
    out
}

/// The text of one revision, with `date` as its header.
pub fn format_entry(
    date: &str,
    removed: &[&RepoDataRecord],
    installed: &[&RepoDataRecord],
    update_specs: &[String],
) -> String {
    let mut out = format!("==> {date} <==\n");
    for record in removed {
        out.push('-');
        out.push_str(&dist_string(record));
        out.push('\n');
    }
    for record in installed {
        out.push('+');
        out.push_str(&dist_string(record));
        out.push('\n');
    }
    if !update_specs.is_empty() {
        let specs: Vec<String> = update_specs.iter().map(|s| quoted(s)).collect();
        out.push_str(&format!("# update specs: [{}]\n", specs.join(", ")));
    }
    out
}

#[cfg(unix)]
extern "C" {
    fn tzset();
}

/// The local time as `%Y-%m-%d %H:%M:%S`, from the C library (libmamba uses
/// `std::localtime()` and `std::strftime()`), so `TZ` is honored the same way.
pub fn local_now() -> String {
    // SAFETY: plain C library calls on local, initialized values.
    unsafe {
        let mut t: libc::time_t = 0;
        libc::time(&mut t);
        let mut tm: libc::tm = std::mem::zeroed();
        #[cfg(unix)]
        let ok = {
            tzset();
            !libc::localtime_r(&t, &mut tm).is_null()
        };
        #[cfg(windows)]
        let ok = {
            libc::tzset();
            libc::localtime_s(&mut tm, &t) == 0
        };
        if !ok {
            return "1970-01-01 00:00:00".to_string();
        }
        format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min,
            tm.tm_sec
        )
    }
}

/// Appends a revision to `<prefix>/conda-meta/history` (creating the file).
pub fn append_history(
    prefix: &Path,
    removed: &[&RepoDataRecord],
    installed: &[&RepoDataRecord],
    update_specs: &[String],
) -> RtResult<()> {
    let date = local_now();
    let mut entry = format_entry(&date, removed, installed, update_specs);
    if cfg!(windows) {
        entry = entry.replace('\n', "\r\n");
    }
    let path = prefix.join("conda-meta").join("history");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| RtError::io_at(format!("failed to open {}", path.display()), e))?;
    file.write_all(entry.as_bytes())
        .map_err(|e| RtError::io_at(format!("failed to write {}", path.display()), e))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use rattler_conda_types::{PackageName, PackageRecord, Version};
    use std::str::FromStr;

    pub(crate) fn record(channel: &str, subdir: &str, name: &str, version: &str, build: &str) -> RepoDataRecord {
        let mut pr = PackageRecord::new(
            PackageName::new_unchecked(name),
            Version::from_str(version).unwrap(),
            rattler_conda_types::package::BuildString::new_unchecked(build),
        );
        pr.subdir = subdir.to_string();
        let file = format!("{name}-{version}-{build}.tar.bz2");
        let url = url::Url::parse(&format!("{channel}{subdir}/{file}")).unwrap();
        RepoDataRecord {
            package_record: pr,
            identifier: file.parse().unwrap(),
            url,
            channel: Some(channel.to_string()),
        }
    }

    #[test]
    fn entries_match_micromamba_bytes() {
        let foo = record("file:///abs/chans/chB/", "noarch", "foo", "2.0", "0");
        let bar = record("file:///abs/chans/chB/", "noarch", "bar", "1.0", "0");
        let xz = record(
            "https://conda.anaconda.org/conda-forge/",
            "linux-64",
            "xz",
            "5.6.2",
            "h4bc722e_1",
        );
        let text = format_entry(
            "2026-10-27 19:28:03",
            &[&xz],
            &[&foo, &bar],
            &["bar".to_string()],
        );
        assert_eq!(
            text,
            "==> 2026-10-27 19:28:03 <==\n\
             -https://conda.anaconda.org/conda-forge/linux-64::xz-5.6.2-h4bc722e_1\n\
             +file:///abs/chans/chB/noarch::foo-2.0-0\n\
             +file:///abs/chans/chB/noarch::bar-1.0-0\n\
             # update specs: [\"bar\"]\n"
        );
    }

    #[test]
    fn several_specs_are_quoted_and_none_leaves_the_line_out() {
        let text = format_entry(
            "d",
            &[],
            &[],
            &["foo >=1".to_string(), "a\"b\\c".to_string()],
        );
        assert_eq!(
            text,
            "==> d <==\n# update specs: [\"foo >=1\", \"a\\\"b\\\\c\"]\n"
        );
        assert_eq!(format_entry("d", &[], &[], &[]), "==> d <==\n");
    }

    #[test]
    fn update_specs_are_written_as_libmamba_writes_them() {
        // micromamba 2.10.0's `# update specs` lines for the same specs
        // (`micromamba create -c <local channel> <spec>`, 2026-10-28).
        let cases = [
            ("foo", "foo"),
            ("foo >=1", "foo>=1"),
            ("foo>=1.0,<2", "foo[version=\">=1.0,<2\"]"),
            ("foo 1.0.*", "foo=1.0"),
            ("foo=1.0", "foo=1.0"),
            ("foo 1.0", "foo==1.0"),
            ("foo==1.0", "foo==1.0"),
            ("foo=1.0=0", "foo=1.0=0"),
            ("foo 1.0 0", "foo==1.0=0"),
            ("foo~=1.0", "foo~=1.0"),
            ("foo!=2.0", "foo!=2.0"),
            ("foo[version='1.0',build='0']", "foo==1.0=0"),
            ("foo 1.0*", "foo=1.0"),
            ("foo>0.5|<0.1", "foo[version=\">0.5|<0.1\"]"),
            ("foo=*", "foo"),
            ("foo *", "foo"),
            ("foo[build=0]", "foo=*=0"),
            ("foo[build='0*']", "foo[build=\"0*\"]"),
            ("foo[build='*_0']", "foo[build=\"*_0\"]"),
            ("foo=1.0=0*", "foo[version=\"=1.0\",build=\"0*\"]"),
            ("foo[version='>=1']", "foo>=1"),
            ("foo >=0.5,<2,!=1.5", "foo[version=\">=0.5,(<2,!=1.5)\"]"),
            ("foo=1", "foo=1"),
            ("foo 1.*", "foo=1"),
            ("foo<=1.0", "foo<=1.0"),
            ("foo>0.1", "foo>0.1"),
            ("foo<2", "foo<2"),
            ("mid 2.*", "mid=2"),
            ("qux[version='>=2']", "qux>=2"),
            ("conda-forge::foo >=2", "conda-forge::foo>=2"),
            // Written as given (micromamba: `foo[version=">=1,(<2|>3)"]`).
            ("foo >=1,<2|>3", "foo >=1,<2|>3"),
        ];
        for (input, want) in cases {
            assert_eq!(update_spec_string(input), want, "{input}");
        }
    }

    #[test]
    fn append_creates_and_appends() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("conda-meta")).unwrap();
        let foo = record("https://conda.anaconda.org/conda-forge/", "noarch", "foo", "1", "0");
        append_history(dir.path(), &[], &[&foo], &["foo".into()]).unwrap();
        append_history(dir.path(), &[&foo], &[], &[]).unwrap();
        let text = std::fs::read_to_string(dir.path().join("conda-meta/history")).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 5, "{text}");
        assert!(lines[0].starts_with("==> ") && lines[0].ends_with(" <=="));
        // The local time has micromamba's shape.
        let date = &lines[0][4..lines[0].len() - 4];
        let shape: String = date
            .chars()
            .map(|c| if c.is_ascii_digit() { 'd' } else { c })
            .collect();
        assert_eq!(shape, "dddd-dd-dd dd:dd:dd", "{date}");
        assert!(!date.starts_with("1970"), "{date}");
        assert_eq!(lines[1], "+https://conda.anaconda.org/conda-forge/noarch::foo-1-0");
        assert_eq!(lines[2], "# update specs: [\"foo\"]");
        assert_eq!(lines[4], "-https://conda.anaconda.org/conda-forge/noarch::foo-1-0");
    }
}
