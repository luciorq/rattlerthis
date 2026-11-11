//! Install, solve-check, pins, lock and cancel tests on local channels.

use crate::activation::NATIVE_SUBDIR;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::*;
use crate::job::{JobOutput, Phase};
use crate::testutil::{make_channel, slow_server, wait, TestPkg};
use rattler_conda_types::Matches;

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    chans: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        let chans = root.join("chans");
        make_channel(&chans, "chA", &[TestPkg::new("foo", "1.0")]);
        make_channel(
            &chans,
            "chB",
            &[
                TestPkg::new("foo", "2.0"),
                TestPkg::new("bar", "1.0").depends("foo >=2"),
            ],
        );
        make_channel(&chans, "chC", &[TestPkg::new("baz", "1.0")]);
        Fixture {
            _dir: dir,
            root,
            chans,
        }
    }

    fn chan(&self, name: &str) -> String {
        self.chans.join(name).to_string_lossy().to_string()
    }

    fn chan_url(&self, name: &str) -> String {
        url::Url::from_directory_path(self.chans.join(name))
            .unwrap()
            .as_str()
            .trim_end_matches('/')
            .to_string()
    }

    fn prefix(&self, name: &str) -> PathBuf {
        self.root.join("envs").join(name)
    }

    fn install(&self, prefix: &Path, specs: &[&str], channels: &[String], prio: &str) -> Result<InstallOutcome, String> {
        let job = install_job(InstallInput {
            specs: specs.iter().map(|s| s.to_string()).collect(),
            prefix: prefix.to_path_buf(),
            channels: channels.to_vec(),
            channel_priority: prio.into(),
            platform: None,
            repodata_cache_dir: self.root.join("repodata_cache"),
            pkgs_cache_dir: self.root.join("pkgs"),
            net: Default::default(),
        });
        match wait(&job)? {
            JobOutput::Install(out) => Ok(out),
            other => Err(format!("unexpected output {other:?}")),
        }
    }

    fn check(&self, specs: &[&str], channels: &[String], prio: &str, platform: &str) -> Result<Option<bool>, String> {
        let job = solve_check_job(SolveCheckInput {
            specs: specs.iter().map(|s| s.to_string()).collect(),
            channels: channels.to_vec(),
            channel_priority: prio.into(),
            platform: platform.into(),
            repodata_cache_dir: self.root.join("repodata_cache"),
            pkgs_cache_dir: self.root.join("pkgs"),
            net: Default::default(),
        });
        match wait(&job)? {
            JobOutput::Logical(v) => Ok(v),
            other => Err(format!("unexpected output {other:?}")),
        }
    }
}

fn installed(prefix: &Path) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = read_prefix_records(prefix)
        .unwrap()
        .iter()
        .map(|r| {
            (
                r.repodata_record.package_record.name.as_normalized().to_string(),
                r.repodata_record.package_record.version.to_string(),
            )
        })
        .collect();
    out.sort();
    out
}

fn pairs(v: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = v.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect();
    v.sort();
    v
}

fn history_body(prefix: &Path) -> Vec<String> {
    std::fs::read_to_string(prefix.join("conda-meta/history"))
        .unwrap()
        .lines()
        .map(|l| {
            if l.starts_with("==> ") {
                "==> DATE <==".to_string()
            } else {
                l.to_string()
            }
        })
        .collect()
}

#[test]
fn create_then_install_with_only_the_requested_channels() {
    let f = Fixture::new();
    let p = f.prefix("i1");
    let out = f.install(&p, &["bar"], &[f.chan("chB")], "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("bar", "1.0"), ("foo", "2.0")]));
    assert_eq!(out.channels, vec![f.chan_url("chB")]);
    assert_eq!(out.prefix, p.to_string_lossy());
    // Dependencies first.
    let names: Vec<&str> = out.records.iter().map(|r| r.name.as_str()).collect();
    assert_eq!(names, vec!["foo", "bar"]);
    assert!(out.records.iter().all(|r| r.op == "+" && r.subdir == "noarch"));
    assert_eq!(out.records[0].channel, f.chan_url("chB"));
    assert_eq!(
        std::fs::read_to_string(p.join("share/foo/README")).unwrap(),
        "foo 2.0\n"
    );

    // D19: only chC is queried; bar and foo stay although chB is not listed.
    f.install(&p, &["baz"], &[f.chan("chC")], "strict").unwrap();
    assert_eq!(
        installed(&p),
        pairs(&[("bar", "1.0"), ("baz", "1.0"), ("foo", "2.0")])
    );

    // foo from chA only: foo 2.0 stays (bar needs foo >=2), nothing changes.
    let out = f.install(&p, &["foo"], &[f.chan("chA")], "strict").unwrap();
    assert!(out.records.is_empty(), "{:?}", out.records);
    assert_eq!(
        installed(&p),
        pairs(&[("bar", "1.0"), ("baz", "1.0"), ("foo", "2.0")])
    );

    let b = f.chan_url("chB");
    let c = f.chan_url("chC");
    assert_eq!(
        history_body(&p),
        vec![
            "==> DATE <==".to_string(),
            format!("+{b}/noarch::foo-2.0-0"),
            format!("+{b}/noarch::bar-1.0-0"),
            "# update specs: [\"bar\"]".to_string(),
            "==> DATE <==".to_string(),
            format!("+{c}/noarch::baz-1.0-0"),
            "# update specs: [\"baz\"]".to_string(),
            "==> DATE <==".to_string(),
            "# update specs: [\"foo\"]".to_string(),
        ]
    );
    // As libmamba's, the lock file is removed when the install releases it.
    assert!(!lock::prefix_lock_path(&p).exists());
}

#[test]
fn an_upgrade_writes_minus_then_plus() {
    let f = Fixture::new();
    let p = f.prefix("up");
    f.install(&p, &["foo"], &[f.chan("chA")], "strict").unwrap();
    let out = f
        .install(&p, &["foo>=2"], &[f.chan("chB")], "strict")
        .unwrap();
    let ops: Vec<(&str, &str)> = out.records.iter().map(|r| (r.op, r.version.as_str())).collect();
    assert_eq!(ops, vec![("-", "1.0"), ("+", "2.0")]);
    let a = f.chan_url("chA");
    let b = f.chan_url("chB");
    let h = history_body(&p);
    assert_eq!(
        &h[3..],
        &[
            "==> DATE <==".to_string(),
            format!("-{a}/noarch::foo-1.0-0"),
            format!("+{b}/noarch::foo-2.0-0"),
            "# update specs: [\"foo>=2\"]".to_string(),
        ]
    );
}

#[test]
fn an_empty_create_makes_an_empty_env() {
    let f = Fixture::new();
    let p = f.prefix("empty");
    let out = f.install(&p, &[], &["conda-forge".to_string()], "strict").unwrap();
    assert!(out.records.is_empty());
    assert_eq!(std::fs::read_to_string(p.join("conda-meta/history")).unwrap(), "");
    assert!(read_prefix_records(&p).unwrap().is_empty());
    let meta: Vec<String> = std::fs::read_dir(p.join("conda-meta"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(meta, vec!["history".to_string()], "only the history, as micromamba");
}

#[test]
fn strict_priority_excludes_later_channels_for_requested_names() {
    // micromamba 2.10.0 on [chA (foo 1.0), chB (foo 2.0)], strict: a request
    // that only chB can meet is unsolvable, also when it names chB.
    let f = Fixture::new();
    let chans = vec![f.chan("chA"), f.chan("chB")];
    let noarch = "noarch";
    assert_eq!(f.check(&["foo>=2"], &chans, "strict", noarch).unwrap(), Some(false));
    let in_b = format!("{}::foo", f.chan_url("chB"));
    assert_eq!(f.check(&[&in_b], &chans, "strict", noarch).unwrap(), Some(false));
    let err = f.install(&f.prefix("sp"), &["foo>=2"], &chans, "strict").unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    let err = f.install(&f.prefix("sp"), &[&in_b], &chans, "strict").unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    assert!(!f.prefix("sp").exists());
    // Flexible and disabled priority take chB's foo.
    assert_eq!(f.check(&["foo>=2"], &chans, "flexible", noarch).unwrap(), Some(true));
    assert_eq!(f.check(&[&in_b], &chans, "disabled", noarch).unwrap(), Some(true));
    // chB first: chB's foo is the first.
    let ba = vec![f.chan("chB"), f.chan("chA")];
    assert_eq!(f.check(&[&in_b], &ba, "strict", noarch).unwrap(), Some(true));
}

#[test]
fn installed_packages_that_block_a_request_are_removed() {
    // micromamba 2.10.0 (libmamba's allow_uninstall): an installed package
    // that conflicts with the request is removed, the rest is kept.
    let f = Fixture::new();
    make_channel(&f.chans, "chD", &[TestPkg::new("needsfoo1", "1.0").depends("foo <2")]);
    let p = f.prefix("conflict");
    f.install(&p, &["needsfoo1", "baz"], &[f.chan("chA"), f.chan("chD"), f.chan("chC")], "strict")
        .unwrap();
    assert_eq!(
        installed(&p),
        pairs(&[("baz", "1.0"), ("foo", "1.0"), ("needsfoo1", "1.0")])
    );
    let out = f.install(&p, &["bar"], &[f.chan("chB")], "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("bar", "1.0"), ("baz", "1.0"), ("foo", "2.0")]));
    let mut ops: Vec<(&str, &str, &str)> = out
        .records
        .iter()
        .map(|r| (r.op, r.name.as_str(), r.version.as_str()))
        .collect();
    ops.sort();
    assert_eq!(
        ops,
        vec![("+", "bar", "1.0"), ("+", "foo", "2.0"), ("-", "foo", "1.0"), ("-", "needsfoo1", "1.0")]
    );
    // A request that cannot be met even alone is still an error, and
    // nothing changes.
    let err = f.install(&p, &["foo<2", "bar"], &[f.chan("chA"), f.chan("chB")], "flexible").unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    assert_eq!(installed(&p), pairs(&[("bar", "1.0"), ("baz", "1.0"), ("foo", "2.0")]));
}

#[test]
fn a_failed_create_leaves_nothing() {
    let f = Fixture::new();
    let p = f.prefix("fail");
    let err = f
        .install(&p, &["bar"], &[f.chan("chA"), f.chan("chB")], "strict")
        .unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    assert!(!p.exists(), "a failed create must not leave {}", p.display());
    let err = f
        .install(&p, &["nosuchpackage"], &[f.chan("chA")], "strict")
        .unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    assert!(!p.exists());
}

#[test]
fn channel_priority_grid_matches_micromamba() {
    // micromamba 2.10.0 on [chA, chB] (SPEC-backend.md 3.3).
    let f = Fixture::new();
    let chans = vec![f.chan("chA"), f.chan("chB")];
    let a = f.chan_url("chA");
    let b = f.chan_url("chB");
    let get = |name: &str, specs: &[&str], prio: &str| -> Vec<(String, String, String)> {
        let out = f.install(&f.prefix(name), specs, &chans, prio).unwrap();
        out.records
            .iter()
            .map(|r| (r.name.clone(), r.version.clone(), r.channel.clone()))
            .collect()
    };
    let t = |n: &str, v: &str, c: &str| (n.to_string(), v.to_string(), c.to_string());
    assert_eq!(get("s1", &["foo"], "strict"), vec![t("foo", "1.0", &a)]);
    assert_eq!(f.check(&["bar"], &chans, "strict", "linux-64").unwrap(), Some(false));
    assert_eq!(get("f1", &["foo"], "flexible"), vec![t("foo", "1.0", &a)]);
    assert_eq!(
        get("f2", &["bar"], "flexible"),
        vec![t("foo", "2.0", &b), t("bar", "1.0", &b)]
    );
    assert_eq!(get("d1", &["foo"], "disabled"), vec![t("foo", "2.0", &b)]);
    assert_eq!(
        get("d2", &["bar"], "disabled"),
        vec![t("foo", "2.0", &b), t("bar", "1.0", &b)]
    );
    let err = f.install(&f.prefix("x"), &["foo"], &chans, "bogus").unwrap_err();
    assert!(err.starts_with("[rattlerthis:invalid_channel_priority]"), "{err}");
    assert!(!f.prefix("x").exists());
}

#[test]
fn solve_check_true_false_na() {
    let f = Fixture::new();
    let a = vec![f.chan("chA")];
    let native = NATIVE_SUBDIR.to_string();
    assert_eq!(f.check(&["foo"], &a, "strict", &native).unwrap(), Some(true));
    assert_eq!(f.check(&["foo"], &a, "strict", "noarch").unwrap(), Some(true));
    // No candidates is "does not solve", as micromamba's solver_problems.
    assert_eq!(f.check(&["nosuch"], &a, "strict", &native).unwrap(), Some(false));
    assert_eq!(f.check(&["foo>=5"], &a, "strict", &native).unwrap(), Some(false));
    // A channel that does not exist, and a spec that does not parse: NA.
    let missing = vec![f.root.join("no-such-channel").to_string_lossy().to_string()];
    assert_eq!(f.check(&["foo"], &missing, "strict", &native).unwrap(), None);
    assert_eq!(f.check(&["foo[version="], &a, "strict", &native).unwrap(), None);
    // Invalid arguments are errors.
    assert!(f
        .check(&["foo"], &a, "strict", "bogus-64")
        .unwrap_err()
        .starts_with("[rattlerthis:invalid_platform]"));
    assert!(f
        .check(&["foo"], &a, "nope", &native)
        .unwrap_err()
        .starts_with("[rattlerthis:invalid_channel_priority]"));
    // A solve check creates no environment and fetches no package.
    assert!(!f.root.join("envs").exists());
    let pkgs = f.root.join("pkgs");
    if pkgs.exists() {
        assert!(std::fs::read_dir(&pkgs)
            .unwrap()
            .flatten()
            .all(|e| !e.path().join("info").exists()));
    }
}

#[test]
fn virtual_packages_follow_the_target_platform() {
    let dir = tempfile::tempdir().unwrap();
    let chans = dir.path().join("chans");
    make_channel(
        &chans,
        "vp",
        &[
            TestPkg::new("osxonly", "1.0").depends("__osx"),
            TestPkg::new("osx1013", "1.0").depends("__osx >=10.13"),
            TestPkg::new("winonly", "1.0").depends("__win"),
            TestPkg::new("future", "1.0").depends("__osx >=99"),
            TestPkg::new("arm", "1.0").depends("__archspec * arm64"),
            TestPkg::new("x64v1", "1.0").depends("__archspec * x86_64*"),
        ],
    );
    let f = Fixture {
        _dir: dir,
        root: chans.parent().unwrap().to_path_buf(),
        chans,
    };
    let ch = vec![f.chan("vp")];
    let chk = |spec: &str, platform: &str| f.check(&[spec], &ch, "strict", platform).unwrap();
    // As micromamba: only the target OS family's packages, and version 0
    // for an OS this machine does not run (no CONDA_OVERRIDE_OSX here).
    assert_eq!(chk("osxonly", "osx-64"), Some(true));
    assert_eq!(chk("osxonly", "osx-arm64"), Some(true));
    assert_eq!(chk("osxonly", "win-64"), Some(false));
    assert_eq!(chk("winonly", "win-64"), Some(true));
    assert_eq!(chk("winonly", "win-arm64"), Some(true));
    assert_eq!(chk("winonly", "linux-64"), Some(false));
    assert_eq!(chk("future", "osx-64"), Some(false));
    if std::env::var_os("CONDA_OVERRIDE_OSX").is_none() {
        let on_mac = cfg!(target_os = "macos");
        assert_eq!(chk("osx1013", "osx-64"), Some(on_mac));
    }
    if std::env::var_os("CONDA_OVERRIDE_ARCHSPEC").is_none() {
        // libmamba's archspec: the platform's arch, or the x86-64 level.
        assert_eq!(chk("arm", "osx-arm64"), Some(true));
        assert_eq!(chk("arm", "win-arm64"), Some(true));
        assert_eq!(chk("arm", "linux-aarch64"), Some(false));
        assert_eq!(chk("x64v1", "win-64"), Some(true));
        assert_eq!(chk("x64v1", "osx-arm64"), Some(false));
    }
}

#[test]
fn multichannel_specs_take_only_the_member_channels() {
    // As micromamba solves `defaults::foo`: foo only from the members of
    // the multichannel, which join the channel list. A multichannel of the
    // tests stands for `defaults` (`channels::TEST_MULTICHANNELS`).
    let f = Fixture::new();
    crate::channels::TEST_MULTICHANNELS
        .lock()
        .unwrap()
        .push(("rt-multi-a".into(), vec![f.chan_url("chA")]));
    let native = NATIVE_SUBDIR.to_string();
    // chB first and its foo newer: flexible priority still takes chA's.
    let prefix = f.prefix("multi");
    let out = f.install(&prefix, &["rt-multi-a::foo"], &[f.chan("chB")], "flexible").unwrap();
    assert_eq!(installed(&prefix), pairs(&[("foo", "1.0")]));
    assert_eq!(out.channels, vec![f.chan_url("chB"), f.chan_url("chA")]);
    assert_eq!(out.records[0].channel, f.chan_url("chA"));
    // The history keeps the spec as typed.
    assert!(history_body(&prefix).iter().any(|l| l == "# update specs: [\"rt-multi-a::foo\"]"), "{:?}", history_body(&prefix));
    // Strict priority: chB has foo and comes first, so the members' foo is
    // excluded; with a member first it solves.
    assert_eq!(f.check(&["rt-multi-a::foo"], &[f.chan("chB")], "strict", &native).unwrap(), Some(false));
    assert_eq!(f.check(&["rt-multi-a::foo"], &[f.chan("chA"), f.chan("chB")], "strict", &native).unwrap(), Some(true));
    // The restriction holds for dependencies too: bar needs foo >=2, which
    // only chB has.
    assert_eq!(f.check(&["bar", "rt-multi-a::foo"], &[f.chan("chB")], "flexible", &native).unwrap(), Some(false));
    assert_eq!(f.check(&["bar", "foo"], &[f.chan("chB")], "flexible", &native).unwrap(), Some(true));
    // An installed foo from another channel does not satisfy it: the
    // install changes foo to the member's.
    let prefix = f.prefix("multi-installed");
    f.install(&prefix, &["foo"], &[f.chan("chB")], "flexible").unwrap();
    assert_eq!(installed(&prefix), pairs(&[("foo", "2.0")]));
    f.install(&prefix, &["rt-multi-a::foo"], &[f.chan("chB")], "flexible").unwrap();
    assert_eq!(installed(&prefix), pairs(&[("foo", "1.0")]));
}

#[test]
fn channel_qualified_specs_add_their_channel() {
    let f = Fixture::new();
    let p = f.prefix("q");
    let spec = format!("{}::baz", f.chan_url("chC"));
    let out = f.install(&p, &[&spec], &[f.chan("chA")], "strict").unwrap();
    assert_eq!(out.channels, vec![f.chan_url("chA"), f.chan_url("chC")]);
    assert_eq!(installed(&p), pairs(&[("baz", "1.0")]));
    // micromamba N1: [chA] + chB::bar is unsolvable under strict priority.
    let spec = format!("{}::bar", f.chan_url("chB"));
    assert_eq!(f.check(&[&spec], &[f.chan("chA")], "strict", "noarch").unwrap(), Some(false));
}

fn python_fixture() -> Fixture {
    let f = Fixture::new();
    make_channel(
        &f.chans,
        "py",
        &[
            TestPkg::new("python", "3.11.0"),
            TestPkg::new("python", "3.12.0"),
            TestPkg::new("needs312", "1.0").depends("python >=3.12"),
            TestPkg::new("pip", "24.0").depends("python >=3.8"),
            TestPkg::new("anypy", "1.0").depends("python"),
            TestPkg::new("zed", "1.0"),
            TestPkg::new("zed", "2.0"),
        ],
    );
    make_channel(
        &f.chans,
        "nopip",
        &[
            TestPkg::new("python", "3.12.0"),
            TestPkg::new("anypy", "1.0").depends("python"),
        ],
    );
    // pip without a dependency on python, as in condathis's tests.
    make_channel(
        &f.chans,
        "pipnodep",
        &[
            TestPkg::new("python", "3.11.0"),
            TestPkg::new("python", "3.12.0"),
            TestPkg::new("pip", "24.0"),
        ],
    );
    make_channel(&f.chans, "pipalone", &[TestPkg::new("pip", "24.0")]);
    f
}

#[test]
fn python_minor_version_is_pinned_like_libmamba() {
    let f = python_fixture();
    let ch = vec![f.chan("py")];
    let p = f.prefix("py");
    f.install(&p, &["python=3.11"], &ch, "strict").unwrap();
    // A package that needs a newer python fails, as with micromamba.
    let err = f.install(&p, &["needs312"], &ch, "strict").unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    assert_eq!(installed(&p), pairs(&[("pip", "24.0"), ("python", "3.11.0")]));
    // Naming python lifts the pin.
    f.install(&p, &["needs312", "python=3.12"], &ch, "strict").unwrap();
    assert_eq!(
        installed(&p),
        pairs(&[("needs312", "1.0"), ("pip", "24.0"), ("python", "3.12.0")])
    );
    // micromamba 2.10.0 wrote the same lines on the same channel.
    let c = f.chan_url("py");
    assert_eq!(
        history_body(&p),
        vec![
            "==> DATE <==".to_string(),
            format!("+{c}/noarch::python-3.11.0-0"),
            format!("+{c}/noarch::pip-24.0-0"),
            "# update specs: [\"python=3.11\", \"pip\"]".to_string(),
            "==> DATE <==".to_string(),
            format!("-{c}/noarch::python-3.11.0-0"),
            format!("+{c}/noarch::python-3.12.0-0"),
            format!("+{c}/noarch::needs312-1.0-0"),
            "# update specs: [\"needs312\", \"python=3.12\", \"pip\"]".to_string(),
        ]
    );
}

#[test]
fn pip_is_added_like_libmamba() {
    let f = python_fixture();
    let native = NATIVE_SUBDIR.to_string();
    let nopip = vec![f.chan("nopip")];
    // Requesting python requests pip: unsolvable without pip.
    assert_eq!(f.check(&["python"], &nopip, "strict", &native).unwrap(), Some(false));
    // Not naming python: no pip, and none is needed.
    assert_eq!(f.check(&["anypy"], &nopip, "strict", &native).unwrap(), Some(true));
    let p = f.prefix("nopip");
    f.install(&p, &["anypy"], &nopip, "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("anypy", "1.0"), ("python", "3.12.0")]));
    // A set with pip: python records depend on pip.
    let py = vec![f.chan("py")];
    let p = f.prefix("withpip");
    f.install(&p, &["anypy"], &py, "strict").unwrap();
    assert_eq!(
        installed(&p),
        pairs(&[("anypy", "1.0"), ("pip", "24.0"), ("python", "3.12.0")])
    );
    // pip named explicitly is not added twice.
    assert!(pip_request(&parse_specs(&["python".into(), "pip=24".into()]).unwrap()).is_none());
    assert!(pip_request(&parse_specs(&["anypy".into()]).unwrap()).is_none());
    assert!(pip_request(&parse_specs(&["python>=3".into()]).unwrap()).is_some());
}

#[test]
fn pip_brings_python_like_libmamba() {
    let f = python_fixture();
    let native = NATIVE_SUBDIR.to_string();
    // libmamba makes python a prerequisite of every pip record of a subdir:
    // requesting pip installs python too, also when pip's record does not
    // depend on it.
    let ch = vec![f.chan("pipnodep")];
    assert_eq!(f.check(&["pip"], &ch, "strict", &native).unwrap(), Some(true));
    let p = f.prefix("pipnodep");
    let out = f.install(&p, &["pip"], &ch, "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("pip", "24.0"), ("python", "3.12.0")]));
    // python first, as micromamba orders them.
    let names: Vec<&str> = out.records.iter().map(|r| r.name.as_str()).collect();
    assert_eq!(names, vec!["python", "pip"]);
    // micromamba 2.10.0 writes pip's record without the added python, and
    // python's with the added pip.
    let records = read_prefix_records(&p).unwrap();
    let depends = |name: &str| -> Vec<String> {
        records
            .iter()
            .find(|r| r.repodata_record.package_record.name.as_normalized() == name)
            .map(|r| r.repodata_record.package_record.depends.clone())
            .unwrap()
    };
    assert_eq!(depends("pip"), Vec::<String>::new());
    assert_eq!(depends("python"), vec!["pip".to_string()]);
    let c = f.chan_url("pipnodep");
    assert_eq!(
        history_body(&p),
        vec![
            "==> DATE <==".to_string(),
            format!("+{c}/noarch::python-3.12.0-0"),
            format!("+{c}/noarch::pip-24.0-0"),
            "# update specs: [\"pip\"]".to_string(),
        ]
    );
    // Installing pip into an environment without python brings python.
    let p = f.prefix("pipinstall");
    f.install(&p, &[], &ch, "strict").unwrap();
    f.install(&p, &["pip"], &ch, "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("pip", "24.0"), ("python", "3.12.0")]));
    // Without any python, pip cannot be installed (micromamba: "requires
    // python, which does not exist").
    let alone = vec![f.chan("pipalone")];
    assert_eq!(f.check(&["pip"], &alone, "strict", &native).unwrap(), Some(false));
    let p = f.prefix("pipalone");
    let err = f.install(&p, &["pip"], &alone, "strict").unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    assert!(!p.exists());
}

/// A failure to replace a cached repodata.json, as Windows reports it while
/// another process has the file memory-mapped.
fn persist_error() -> GatewayError {
    let file = tempfile::NamedTempFile::new().unwrap();
    GatewayError::FetchRepoDataError(FetchRepoDataError::FailedToPersistTemporaryFile(
        tempfile::PersistError {
            error: std::io::Error::other("the file has a user-mapped section open"),
            file,
        },
        PathBuf::from("repodata_cache/0123abcd.json"),
    ))
}

fn other_gateway_error() -> GatewayError {
    GatewayError::FetchRepoDataError(FetchRepoDataError::NoCacheAvailable(
        url::Url::parse("https://example.invalid/chA/noarch/").unwrap(),
    ))
}

/// Runs `query_repodata()` in a job, with `refresh` failing for its first
/// `refresh_failures` calls (with `refresh_error`) and `cache_only` failing
/// for its first `cache_failures` calls. Returns the outcome (`Ok` when the
/// query gave repodata), the calls of each, and the time taken.
fn run_query_repodata(
    refresh_failures: usize,
    refresh_error: fn() -> GatewayError,
    cache_failures: usize,
) -> (Result<(), String>, usize, usize, Duration) {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let refresh_calls = Arc::new(AtomicUsize::new(0));
    let cache_calls = Arc::new(AtomicUsize::new(0));
    let took = Arc::new(std::sync::Mutex::new(Duration::ZERO));
    let (r, c, t) = (refresh_calls.clone(), cache_calls.clone(), took.clone());
    let job = spawn_job(Phase::Fetch, move |ctx| async move {
        let refresh = || {
            let n = r.fetch_add(1, Ordering::SeqCst);
            async move {
                if n < refresh_failures {
                    Err(refresh_error())
                } else {
                    Ok(Vec::new())
                }
            }
        };
        let cache_only = || {
            let n = c.fetch_add(1, Ordering::SeqCst);
            async move {
                if n < cache_failures {
                    Err(other_gateway_error())
                } else {
                    Ok(Vec::new())
                }
            }
        };
        let started = Instant::now();
        let res = query_repodata(&ctx, refresh, cache_only).await;
        *t.lock().unwrap() = started.elapsed();
        res?;
        Ok(JobOutput::Logical(Some(true)))
    });
    let outcome = wait(&job).map(|_| ());
    let took = *took.lock().unwrap();
    (
        outcome,
        refresh_calls.load(Ordering::SeqCst),
        cache_calls.load(Ordering::SeqCst),
        took,
    )
}

#[test]
fn a_cached_repodata_file_that_cannot_be_replaced_is_read_from_the_cache() {
    // The cached copy is used when it cannot be replaced.
    let (out, refresh, cache, _) = run_query_repodata(usize::MAX, persist_error, 0);
    assert_eq!(out, Ok(()));
    assert_eq!((refresh, cache), (1, 1));
    // A subdir nobody has cached yet: the download is tried again until the
    // file can be replaced.
    let (out, refresh, cache, _) = run_query_repodata(2, persist_error, usize::MAX);
    assert_eq!(out, Ok(()));
    assert_eq!((refresh, cache), (3, 2));
    // Any other error is reported at once.
    let (out, refresh, cache, _) = run_query_repodata(1, other_gateway_error, 0);
    assert!(out.as_ref().unwrap_err().starts_with("[rattlerthis:fetch]"), "{out:?}");
    assert_eq!((refresh, cache), (1, 0));
    // A file that can never be replaced, without a usable cache: the error,
    // after PERSIST_RETRY_FOR.
    let (out, refresh, _, took) = run_query_repodata(usize::MAX, persist_error, usize::MAX);
    let err = out.unwrap_err();
    assert!(err.starts_with("[rattlerthis:fetch]"), "{err}");
    assert!(err.contains("failed to persist temporary repodata.json"), "{err}");
    assert!(took >= PERSIST_RETRY_FOR, "{took:?}");
    assert!(took < PERSIST_RETRY_FOR + Duration::from_secs(5), "{took:?}");
    assert!(refresh > 2, "{refresh}");
}

#[test]
fn an_install_succeeds_while_another_gateway_reads_the_cached_repodata() {
    // A server without validators makes every gateway download the
    // channel's metadata again and replace the cached copy. A first gateway
    // keeps the subdirs it read, memory-mapped; on Windows the install's
    // gateway then cannot replace the cached files and reads them from the
    // cache instead (elsewhere it replaces them).
    let f = Fixture::new();
    let server = slow_server(f.chans.clone(), 256 * 1024, Duration::from_millis(1));
    let chan_url = format!("{}/chA", server.url);
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let cache = PackageCache::new(f.root.join("pkgs"));
    let client = net::lazy_client(&Default::default());
    let first = gateway(&client, &f.root.join("repodata_cache"), &cache, RepodataCache::Refresh, &[], &[]);
    let channel = Channel::from_url(url::Url::parse(&format!("{chan_url}/")).unwrap());
    let spec = MatchSpec::from_str("foo", ParseStrictness::Lenient).unwrap();
    let read = runtime
        .block_on(
            first
                .query(vec![channel], query_platforms(NATIVE_SUBDIR), vec![spec])
                .recursive(true)
                .execute(),
        )
        .unwrap();
    assert!(has_record(&read.repodata, "foo"));
    let p = f.prefix("mapped");
    f.install(&p, &["foo"], &[chan_url], "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("foo", "1.0")]));
    drop(first);
}

#[test]
fn channel_metadata_without_cache_headers_is_reused_for_an_hour() {
    // micromamba 2.10.0 (t1): a server without ETag or Cache-Control; a
    // second create within an hour downloads no repodata.json, one after
    // the cache aged two hours does.
    let f = Fixture::new();
    let server = slow_server(f.chans.clone(), 1 << 20, Duration::ZERO);
    let chan = format!("{}/chA", server.url);
    let requests = || server.repodata_requests.load(std::sync::atomic::Ordering::SeqCst);
    f.install(&f.prefix("ttl1"), &["foo"], std::slice::from_ref(&chan), "strict").unwrap();
    let first = requests();
    assert!(first >= 2, "the noarch and platform metadata: {first}");
    // The cache files rattler wrote are those this module checks.
    let cache = f.root.join("repodata_cache");
    let channel = Channel::from_url(url::Url::parse(&format!("{chan}/")).unwrap());
    for platform in query_platforms(NATIVE_SUBDIR) {
        let key = repodata_cache_key(&channel.platform_url(platform));
        assert!(cache.join(format!("{key}.info.json")).is_file(), "{key} for {platform}");
    }
    assert_eq!(
        fresh_flat_channels(&cache, std::slice::from_ref(&channel), &query_platforms(NATIVE_SUBDIR)),
        vec![(url::Url::clone(channel.base_url.url()), true)]
    );
    f.install(&f.prefix("ttl2"), &["foo"], std::slice::from_ref(&chan), "strict").unwrap();
    assert_eq!(requests(), first, "fresh: no download");
    // Two hours later: stale, downloaded again.
    let old = std::time::SystemTime::now() - Duration::from_secs(2 * 60 * 60);
    for entry in std::fs::read_dir(&cache).unwrap().flatten() {
        if entry.file_name().to_string_lossy().ends_with(".info.json") {
            std::fs::File::options()
                .write(true)
                .open(entry.path())
                .unwrap()
                .set_modified(old)
                .unwrap();
        }
    }
    f.install(&f.prefix("ttl3"), &["foo"], std::slice::from_ref(&chan), "strict").unwrap();
    assert!(requests() >= first + 2, "{} after {first}", requests());
}

#[test]
fn cache_control_max_age_is_read_as_libmamba_reads_it() {
    assert_eq!(cache_control_max_age("public, max-age=1200"), Some(Duration::from_secs(1200)));
    assert_eq!(cache_control_max_age("max-age=0"), Some(Duration::ZERO));
    assert_eq!(cache_control_max_age("no-cache"), None);
    assert_eq!(cache_control_max_age("s-maxage=10, max-age=x"), None);
    assert_eq!(
        repodata_cache_key(&url::Url::parse("https://conda.anaconda.org/conda-forge/noarch/").unwrap()),
        // The MD5 of `https://conda.anaconda.org/conda-forge/noarch`.
        "36521c4e"
    );
}

#[test]
fn conda_meta_pinned_is_honored() {
    let f = python_fixture();
    let ch = vec![f.chan("py")];
    let p = f.prefix("pin");
    f.install(&p, &["zed=1.0"], &ch, "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("zed", "1.0")]));
    std::fs::write(p.join("conda-meta/pinned"), "# keep zed\n\nzed 1.*\n").unwrap();
    let err = f.install(&p, &["zed>=2"], &ch, "strict").unwrap_err();
    assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
    std::fs::remove_file(p.join("conda-meta/pinned")).unwrap();
    f.install(&p, &["zed>=2"], &ch, "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("zed", "2.0")]));
    // A pin that does not parse is an invalid_spec error.
    std::fs::write(p.join("conda-meta/pinned"), "zed >>= 1\n").unwrap();
    let err = f.install(&p, &["zed"], &ch, "strict").unwrap_err();
    assert!(err.starts_with("[rattlerthis:invalid_spec]"), "{err}");
}

#[test]
fn python_pin_rules() {
    let rec = |name: &str, version: &str, build: &str| {
        let r = crate::history::tests::record("https://x/", "linux-64", name, version, build);
        PrefixRecord::from_repodata_record(r, Vec::new())
    };
    let spec = |s: &str| MatchSpec::from_str(s, ParseStrictness::Lenient).unwrap();
    let env = vec![rec("python", "3.12.4", "h1_0"), rec("xz", "5.6", "0")];
    let pins: Vec<String> = python_pins(&env, &[spec("xz")]).unwrap().iter().map(|s| s.to_string()).collect();
    assert_eq!(pins, vec!["python 3.12.*"]);
    assert!(python_pins(&env, &[spec("python>=3.13")]).unwrap().is_empty());
    assert!(python_pins(&[rec("xz", "5.6", "0")], &[spec("xz")]).unwrap().is_empty());
    let ft = vec![
        rec("python", "3.14.0", "h_cp314t"),
        rec("python-freethreading", "3.14.0", "0"),
        rec("python_abi", "3.14", "8_cp314t"),
    ];
    let pins = python_pins(&ft, &[spec("xz")]).unwrap();
    assert_eq!(pins.len(), 2);
    let abi = &pins[1];
    assert_eq!(abi.name.as_exact().unwrap().as_normalized(), "python_abi");
    let ok = rec("python_abi", "3.14", "9_cp314t");
    let bad = rec("python_abi", "3.14", "8_cp314");
    assert!(abi.matches(&ok.repodata_record.package_record));
    assert!(!abi.matches(&bad.repodata_record.package_record));
}

fn record_json(prefix: &Path, file: &str) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(prefix.join("conda-meta").join(file)).unwrap()).unwrap()
}

fn file_hashes(path: &Path) -> (String, String, u64) {
    use rattler_digest::{compute_file_digest, Md5, Sha256};
    let hex = |b: &[u8]| b.iter().map(|x| format!("{x:02x}")).collect::<String>();
    (
        hex(&compute_file_digest::<Md5>(path).unwrap()),
        hex(&compute_file_digest::<Sha256>(path).unwrap()),
        std::fs::metadata(path).unwrap().len(),
    )
}

#[test]
fn spec_text_is_cleaned_as_libmamba_cleans_it() {
    let f = Fixture::new();
    // micromamba bomplain: a byte order mark in front of the first spec is
    // dropped on Linux and Windows; on macOS it stays, and the spec fails
    // (see `spectext.rs`).
    let p = f.prefix("bom");
    let ch = [f.chan("chA"), f.chan("chC")];
    if cfg!(target_os = "macos") {
        // micromamba: "\u{feff}foo does not exist".
        let err = f.install(&p, &["\u{feff}foo", "baz"], &ch, "strict").unwrap_err();
        assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
        assert!(!p.exists());
        let platform = NATIVE_SUBDIR.to_string();
        assert_eq!(f.check(&["\u{feff}foo"], &ch, "strict", &platform).unwrap(), Some(false));
        f.install(&p, &["foo", "baz"], &ch, "strict").unwrap();
    } else {
        f.install(&p, &["\u{feff}foo", "baz"], &ch, "strict").unwrap();
        assert_eq!(history_body(&p).last().unwrap(), "# update specs: [\"foo\", \"baz\"]");
    }
    assert_eq!(installed(&p), pairs(&[("baz", "1.0"), ("foo", "1.0")]));
    // The same in `conda-meta/pinned`: the pin holds (micromamba reports the
    // conflict with bar, which needs foo >=2); on macOS it pins a name no
    // package has, and bar installs, as with micromamba (mm-pinbom).
    std::fs::write(p.join("conda-meta/pinned"), "\u{feff}foo 1.0\n").unwrap();
    let res = f.install(&p, &["bar"], &[f.chan("chB"), f.chan("chA")], "strict");
    if cfg!(target_os = "macos") {
        res.unwrap();
    } else {
        let err = res.unwrap_err();
        assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
        std::fs::remove_file(p.join("conda-meta/pinned")).unwrap();
        f.install(&p, &["bar"], &[f.chan("chB"), f.chan("chA")], "strict").unwrap();
    }
    assert_eq!(installed(&p), pairs(&[("bar", "1.0"), ("baz", "1.0"), ("foo", "2.0")]));
}

#[test]
fn url_specs_are_recorded_as_micromamba_records_them() {
    let f = Fixture::new();
    let archive = f.chans.join("chC").join("noarch").join("baz-1.0-0.tar.bz2");
    let url = url::Url::from_file_path(&archive).unwrap().to_string();
    let (md5, sha256, size) = file_hashes(&archive);
    let ch = vec![f.chan("chA")];
    // A fragment that is not hex is dropped (micromamba plainurlsha,
    // plainurljunk); the record gets the URL's channel and the archive's
    // hashes and size (plainurl3).
    let p = f.prefix("url");
    let out = f.install(&p, &["foo", &format!("{url}#sha256:{sha256}")], &ch, "strict").unwrap();
    let rec = record_json(&p, "baz-1.0-0.json");
    assert_eq!(rec["channel"].as_str().unwrap().trim_end_matches('/'), f.chan_url("chC"));
    assert_eq!(rec["md5"], md5.as_str());
    assert_eq!(rec["sha256"], sha256.as_str());
    assert_eq!(rec["size"], size);
    assert_eq!(rec["subdir"], "noarch");
    let baz_row = out.records.iter().find(|r| r.name == "baz").unwrap();
    assert_eq!(baz_row.channel, f.chan_url("chC"));
    let h = history_body(&p);
    assert!(h.contains(&format!("+{}/noarch::baz-1.0-0", f.chan_url("chC"))), "{h:?}");
    assert_eq!(h.last().unwrap(), &format!("# update specs: [\"foo\", \"{url}\"]"));
    // The same URL again: nothing changes.
    let out = f.install(&p, &[&url], &ch, "strict").unwrap();
    assert!(out.records.is_empty(), "{:?}", out.records);
    // A hex fragment is an MD5 micromamba cannot match before the download:
    // "Could not solve" (plainurl2, plainurl4, plainurlsha2), also when it is
    // the right one.
    for frag in [md5.clone(), sha256.clone()] {
        let p = f.prefix("urlmd5");
        let spec = format!("{url}#{frag}");
        let err = f.install(&p, &["foo", &spec], &ch, "strict").unwrap_err();
        assert!(err.starts_with("[rattlerthis:solve]"), "{err}");
        assert!(!p.exists());
        let platform = NATIVE_SUBDIR.to_string();
        assert_eq!(f.check(&[spec.as_str()], &ch, "strict", &platform).unwrap(), Some(false));
    }
}

#[test]
fn url_specs_over_http_get_their_hashes() {
    let f = Fixture::new();
    let server = slow_server(f.chans.clone(), 256 * 1024, Duration::from_millis(1));
    let url = format!("{}/chC/noarch/baz-1.0-0.tar.bz2", server.url);
    let (md5, sha256, size) = file_hashes(&f.chans.join("chC/noarch/baz-1.0-0.tar.bz2"));
    let requests = || server.package_requests.load(std::sync::atomic::Ordering::SeqCst);
    let p = f.prefix("h1");
    f.install(&p, &[&url], &[f.chan("chA")], "strict").unwrap();
    let rec = record_json(&p, "baz-1.0-0.json");
    assert_eq!((rec["md5"].as_str(), rec["sha256"].as_str()), (Some(md5.as_str()), Some(sha256.as_str())));
    assert_eq!(rec["size"], size);
    assert_eq!(rec["channel"].as_str().unwrap().trim_end_matches('/'), format!("{}/chC", server.url));
    // rattler's query downloads it once, the hashes need a second download;
    // a second environment finds both in the cache.
    let first = requests();
    assert!(first <= 2, "{first} downloads");
    f.install(&f.prefix("h2"), &[&url], &[f.chan("chA")], "strict").unwrap();
    assert_eq!(requests(), first);
    assert_eq!(record_json(&f.prefix("h2"), "baz-1.0-0.json")["sha256"], sha256.as_str());
}

#[test]
fn link_scripts_are_skipped_and_reported() {
    let f = Fixture::new();
    let script = "#!/bin/sh\ntouch \"$PREFIX/RAN-$0\"\n";
    // Scripts for the other OS are never reported (micromamba looks for the
    // `.sh` or the `.bat` scripts by the OS it runs on).
    let pkg = |v: &str| {
        TestPkg::new("plink", v)
            .file("bin/.plink-pre-link.sh", script)
            .file("bin/.plink-post-link.sh", script)
            .file("bin/.plink-pre-unlink.sh", script)
            .file("Scripts/.plink-post-link.bat", "@echo off\n")
    };
    make_channel(&f.chans, "plink", &[pkg("1.0"), pkg("2.0")]);
    let ch = vec![f.chan("plink")];
    let p = f.prefix("plink");
    let out = f.install(&p, &["plink=1.0"], &ch, "strict").unwrap();
    let kinds: Vec<(&str, &str)> = out
        .link_scripts_skipped
        .iter()
        .map(|(p, s)| (p.as_str(), *s))
        .collect();
    if NATIVE_SUBDIR.is_windows() {
        assert_eq!(kinds, vec![("plink", "post-link")]);
    } else {
        assert_eq!(kinds, vec![("plink", "pre-link"), ("plink", "post-link")]);
    }
    // Nothing ran.
    assert!(!std::fs::read_dir(&p).unwrap().flatten().any(|e| e
        .file_name()
        .to_string_lossy()
        .starts_with("RAN-")));
    // An upgrade: pre-unlink of the old record, then the new one's scripts.
    let out = f.install(&p, &["plink=2.0"], &ch, "strict").unwrap();
    let kinds: Vec<&str> = out.link_scripts_skipped.iter().map(|(_, s)| *s).collect();
    if NATIVE_SUBDIR.is_windows() {
        assert_eq!(kinds, vec!["post-link"]);
    } else {
        assert_eq!(kinds, vec!["pre-unlink", "pre-link", "post-link"]);
    }
    // No scripts, nothing reported.
    let out = f.install(&f.prefix("noscript"), &["foo"], &[f.chan("chA")], "strict").unwrap();
    assert!(out.link_scripts_skipped.is_empty());
    // The target platform does not change which scripts count.
    let other = if cfg!(windows) { "linux-64" } else { "win-64" };
    let job = install_job(InstallInput {
        specs: vec!["plink=1.0".into()],
        prefix: f.prefix("plink-other"),
        channels: ch.clone(),
        channel_priority: "strict".into(),
        platform: Some(other.into()),
        repodata_cache_dir: f.root.join("repodata_cache"),
        pkgs_cache_dir: f.root.join("pkgs"),
        net: Default::default(),
    });
    match wait(&job) {
        Ok(JobOutput::Install(out)) => {
            let kinds: Vec<&str> = out.link_scripts_skipped.iter().map(|(_, s)| *s).collect();
            if cfg!(windows) {
                assert_eq!(kinds, vec!["post-link"]);
            } else {
                assert_eq!(kinds, vec!["pre-link", "post-link"]);
            }
        }
        other => panic!("unexpected result {other:?}"),
    }
}

/// A noarch python package's `python-scripts/` files become `bin/` (Windows:
/// `Scripts/`) files in the prefix: micromamba finds the post-link script
/// there, but looks for the pre-link script in the extracted package, where
/// it is not under `bin/`.
#[test]
fn noarch_python_scripts_count_only_as_post_link() {
    let f = python_fixture();
    let ext = if cfg!(windows) { "bat" } else { "sh" };
    make_channel(
        &f.chans,
        "pyls",
        &[
            TestPkg::new("pyls", "1.0")
                .noarch_python()
                .depends("python")
                .file("site-packages/pyls/__init__.py", "")
                .file(&format!("python-scripts/.pyls-pre-link.{ext}"), "x\n")
                .file(&format!("python-scripts/.pyls-post-link.{ext}"), "x\n"),
        ],
    );
    let p = f.prefix("pyls");
    let out = f.install(&p, &["python", "pyls"], &[f.chan("py"), f.chan("pyls")], "strict").unwrap();
    assert_eq!(out.link_scripts_skipped, vec![("pyls".to_string(), "post-link")]);
    let bin = if cfg!(windows) { "Scripts" } else { "bin" };
    assert!(p.join(bin).join(format!(".pyls-pre-link.{ext}")).is_file());
}

#[cfg(unix)]
#[test]
fn package_records_get_the_umask_mode() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let p = f.prefix("modes");
    f.install(&p, &["bar"], &[f.chan("chB")], "strict").unwrap();
    let probe = p.join("conda-meta/probe");
    std::fs::write(&probe, "").unwrap();
    let want = std::fs::metadata(&probe).unwrap().permissions().mode() & 0o777;
    std::fs::remove_file(&probe).unwrap();
    for name in ["bar-1.0-0.json", "foo-2.0-0.json"] {
        let mode = std::fs::metadata(p.join("conda-meta").join(name)).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, want, "{name}");
    }
}

/// While another session holds the package cache's lock, an install waits
/// before `link` (rattler's Installer would wait for that lock without a
/// way to stop): a cancel then stops it, and nothing is changed.
#[test]
fn a_cancel_while_waiting_for_the_cache_lock_changes_nothing() {
    let f = Fixture::new();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    // Fill the cache first, so the job only waits for the lock before link.
    f.install(&f.prefix("warm"), &["baz"], &[f.chan("chC")], "strict").unwrap();
    let existing = f.prefix("existing");
    f.install(&existing, &["foo"], &[f.chan("chA")], "strict").unwrap();
    let history = std::fs::read_to_string(existing.join("conda-meta/history")).unwrap();
    for p in [f.prefix("new"), existing.clone()] {
        let held = rt
            .block_on(lock::lock_exclusive(&lock::cache_lock_path(&f.root.join("pkgs")), None, false))
            .unwrap();
        let job = install_job(InstallInput {
            specs: vec!["baz".into()],
            prefix: p.clone(),
            channels: vec![f.chan("chC")],
            channel_priority: "strict".into(),
            platform: None,
            repodata_cache_dir: f.root.join("repodata_cache"),
            pkgs_cache_dir: f.root.join("pkgs"),
            net: Default::default(),
        });
        std::thread::sleep(Duration::from_millis(500));
        assert_eq!(job.phase(), Phase::Prefetch, "waits for the cache lock before link");
        assert!(job.cancel(), "a cancel before link stops the job");
        assert!(wait(&job).unwrap_err().starts_with("[rattlerthis:cancelled]"));
        drop(held);
        if p == existing {
            assert_eq!(installed(&p), pairs(&[("foo", "1.0")]));
            assert_eq!(std::fs::read_to_string(p.join("conda-meta/history")).unwrap(), history);
            assert!(!lock::prefix_lock_path(&p).exists());
        } else {
            assert!(!p.exists(), "{} was left behind", p.display());
        }
    }
}

/// A cancel that comes just as rattler's Installer starts its transaction
/// (after it took the cache lock, before the first unlink) stops it there:
/// the environment is unchanged and the job reports `cancelled`.
#[test]
fn a_cancel_at_the_transaction_start_changes_nothing() {
    let f = Fixture::new();
    let p = f.prefix("at-start");
    f.install(&p, &["foo"], &[f.chan("chA")], "strict").unwrap();
    let history = std::fs::read_to_string(p.join("conda-meta/history")).unwrap();
    let resolved = crate::paths::weakly_canonical(&p);
    CANCEL_AT_TRANSACTION_START.lock().unwrap().push(resolved.clone());
    let job = install_job(InstallInput {
        specs: vec!["foo>=2".into()],
        prefix: p.clone(),
        channels: vec![f.chan("chB")],
        channel_priority: "strict".into(),
        platform: None,
        repodata_cache_dir: f.root.join("repodata_cache"),
        pkgs_cache_dir: f.root.join("pkgs"),
        net: Default::default(),
    });
    let res = wait(&job);
    CANCEL_AT_TRANSACTION_START.lock().unwrap().retain(|x| x != &resolved);
    assert!(res.unwrap_err().starts_with("[rattlerthis:cancelled]"));
    assert!(job.cancel(), "the job reports that it did not complete");
    assert_eq!(installed(&p), pairs(&[("foo", "1.0")]));
    assert_eq!(std::fs::read_to_string(p.join("share/foo/README")).unwrap(), "foo 1.0\n");
    assert_eq!(std::fs::read_to_string(p.join("conda-meta/history")).unwrap(), history);
    assert!(!lock::prefix_lock_path(&p).exists());
    // The next install goes through.
    f.install(&p, &["foo>=2"], &[f.chan("chB")], "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("foo", "2.0")]));
}

/// Links of several jobs in one process take turns, so they cannot all wait
/// on the link pool at once.
#[test]
fn concurrent_installs_in_one_process_all_complete() {
    let f = Fixture::new();
    let jobs: Vec<Job> = (0..6)
        .map(|i| {
            install_job(InstallInput {
                specs: vec!["bar".into(), "baz".into()],
                prefix: f.prefix(&format!("c{i}")),
                channels: vec![f.chan("chB"), f.chan("chC")],
                channel_priority: "strict".into(),
                platform: None,
                repodata_cache_dir: f.root.join("repodata_cache"),
                pkgs_cache_dir: f.root.join("pkgs"),
                net: Default::default(),
            })
        })
        .collect();
    for (i, job) in jobs.iter().enumerate() {
        wait(job).unwrap();
        assert_eq!(
            installed(&f.prefix(&format!("c{i}"))),
            pairs(&[("bar", "1.0"), ("baz", "1.0"), ("foo", "2.0")])
        );
    }
}

#[test]
fn installs_into_one_prefix_take_turns() {
    let f = Fixture::new();
    let p = f.prefix("locked");
    f.install(&p, &["foo"], &[f.chan("chA")], "strict").unwrap();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let held = rt.block_on(lock::lock_exclusive(&lock::prefix_lock_path(&p), None, true)).unwrap();
    let job = install_job(InstallInput {
        specs: vec!["baz".into()],
        prefix: p.clone(),
        channels: vec![f.chan("chC")],
        channel_priority: "strict".into(),
        platform: None,
        repodata_cache_dir: f.root.join("repodata_cache"),
        pkgs_cache_dir: f.root.join("pkgs"),
        net: Default::default(),
    });
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(job.phase(), Phase::Lock, "waits for the other session's lock");
    assert_eq!(installed(&p), pairs(&[("foo", "1.0")]));
    drop(held);
    wait(&job).unwrap();
    assert_eq!(installed(&p), pairs(&[("baz", "1.0"), ("foo", "1.0")]));

    // A create cancelled while another session holds the lock of the new
    // prefix leaves that session's lock file alone.
    let fresh = f.prefix("fresh");
    let held = rt.block_on(lock::lock_exclusive(&lock::prefix_lock_path(&fresh), None, true)).unwrap();
    let job = install_job(InstallInput {
        specs: vec!["baz".into()],
        prefix: fresh.clone(),
        channels: vec![f.chan("chC")],
        channel_priority: "strict".into(),
        platform: None,
        repodata_cache_dir: f.root.join("repodata_cache"),
        pkgs_cache_dir: f.root.join("pkgs"),
        net: Default::default(),
    });
    std::thread::sleep(Duration::from_millis(200));
    assert!(job.cancel());
    assert!(wait(&job).unwrap_err().starts_with("[rattlerthis:cancelled]"));
    assert!(lock::prefix_lock_path(&fresh).is_file());
    drop(held);
}

/// A channel served over HTTP whose package downloads take seconds.
fn slow_fixture() -> (Fixture, crate::testutil::SlowServer) {
    let f = Fixture::new();
    // About 1.5 MB that bzip2 cannot shrink.
    let mut state: u64 = 0x2545_F491_4F6C_DD1D;
    let noise: Vec<u8> = (0..1_500_000)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 24) as u8
        })
        .collect();
    make_channel(
        &f.chans,
        "big",
        &[TestPkg::new("big", "1.0").file("share/big/noise.bin", noise)],
    );
    // 16 KiB every 400 ms: about 40 s for the package.
    let server = slow_server(f.chans.clone(), 16 * 1024, Duration::from_millis(400));
    (f, server)
}

#[test]
fn cancel_during_prefetch_leaves_the_prefix_untouched() {
    let (f, server) = slow_fixture();
    let big = format!("{}/big", server.url);
    let start_job = |prefix: &Path| {
        install_job(InstallInput {
            specs: vec!["big".into()],
            prefix: prefix.to_path_buf(),
            channels: vec![big.clone()],
            channel_priority: "strict".into(),
            platform: None,
            repodata_cache_dir: f.root.join("repodata_cache"),
            pkgs_cache_dir: f.root.join("pkgs"),
            net: Default::default(),
        })
    };
    let wait_for_download = |job: &Job, before: usize| {
        let start = Instant::now();
        while server.package_requests.load(std::sync::atomic::Ordering::SeqCst) <= before {
            assert!(start.elapsed() < Duration::from_secs(30), "download never started: {:?}", job.phase());
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(job.phase(), Phase::Prefetch);
    };

    // A new environment: nothing is left behind.
    let p = f.prefix("new");
    let job = start_job(&p);
    wait_for_download(&job, 0);
    let t = Instant::now();
    assert!(job.cancel(), "a cancel during prefetch stops the job");
    let err = wait(&job).unwrap_err();
    assert!(err.starts_with("[rattlerthis:cancelled]"), "{err}");
    // Far less than the 40 s the download takes (the bound leaves room for
    // blocking work of tests running in parallel, which a cancelled job also
    // waits for).
    assert!(t.elapsed() < Duration::from_secs(20), "cancel took {:?}", t.elapsed());
    assert!(!p.exists(), "{} was left behind", p.display());

    // An existing environment: its packages and history are unchanged.
    let p = f.prefix("existing");
    f.install(&p, &["foo"], &[f.chan("chA")], "strict").unwrap();
    let history = std::fs::read_to_string(p.join("conda-meta/history")).unwrap();
    let job = start_job(&p);
    wait_for_download(&job, 1);
    assert!(job.cancel());
    assert!(wait(&job).unwrap_err().starts_with("[rattlerthis:cancelled]"));
    assert_eq!(installed(&p), pairs(&[("foo", "1.0")]));
    assert_eq!(std::fs::read_to_string(p.join("conda-meta/history")).unwrap(), history);
    assert!(!p.join("share/big").exists());

    // Not cancelled, the same install completes, over HTTP (a faster server).
    let fast = slow_server(f.chans.clone(), 256 * 1024, Duration::from_millis(5));
    let fast_big = format!("{}/big", fast.url);
    let out = f.install(&p, &["big"], std::slice::from_ref(&fast_big), "strict").unwrap();
    assert_eq!(out.records.len(), 1);
    assert_eq!(out.channels, vec![fast_big]);
    assert_eq!(installed(&p), pairs(&[("big", "1.0"), ("foo", "1.0")]));
    assert_eq!(std::fs::metadata(p.join("share/big/noise.bin")).unwrap().len(), 1_500_000);
}

/// Regression test for a panic once hit by `install()` into an env that
/// already has a wheel package, with a single-channel `channels =` argument
/// that does not list the wheel's channel again. It now also checks the
/// micromamba channel rule (D19): the second install queries conda-forge only,
/// and the installed wheel stays because installed records remain solvable
/// without their channel. It also covers `Installer::with_installed_packages`
/// on a second install into one prefix: rattler's clobber registry panics
/// ("Expected just reordering") unless it is given every record in
/// `conda-meta`, the wheel's included.
/// Needs the network; run with
/// `cargo test --features wheels -- --ignored install_after_wheel`.
#[cfg(feature = "wheels")]
#[test]
#[ignore = "hits the real conda-forge/conda-pypi network"]
fn install_after_wheel_does_not_panic() {
    let dir = tempfile::tempdir().unwrap();
    let prefix = dir.path().join("envs").join("e");
    let run = |specs: &[&str], channels: &[&str]| -> InstallOutcome {
        let job = install_job(InstallInput {
            specs: specs.iter().map(|s| s.to_string()).collect(),
            prefix: prefix.clone(),
            channels: channels.iter().map(|s| s.to_string()).collect(),
            channel_priority: "strict".into(),
            platform: None,
            repodata_cache_dir: dir.path().join("repodata_cache"),
            pkgs_cache_dir: dir.path().join("pkgs"),
            net: Default::default(),
        });
        match wait(&job).expect("install failed") {
            JobOutput::Install(out) => out,
            _ => unreachable!(),
        }
    };
    run(&["python", "conda-pypi::cowsay"], &["conda-forge", "conda-pypi"]);
    let names = |p: &Path| -> Vec<String> {
        read_prefix_records(p)
            .unwrap()
            .iter()
            .map(|r| r.repodata_record.package_record.name.as_normalized().to_string())
            .collect()
    };
    assert!(names(&prefix).iter().any(|n| n == "cowsay"));
    // Deliberately omits "conda-pypi", matching install()'s single-channel
    // default on the R side.
    let out = run(&["xz"], &["conda-forge"]);
    assert_eq!(out.channels, vec!["https://conda.anaconda.org/conda-forge"]);
    let after = names(&prefix);
    assert!(after.iter().any(|n| n == "cowsay"), "{after:?}");
    assert!(after.iter().any(|n| n == "xz"), "{after:?}");
}

/// P-A1: after the parent ran jobs, a `fork()`ed child (what
/// `parallel::mcparallel()` does) builds its own runtime and link pool and
/// installs from a local channel, without hanging. On macOS, where a fork
/// may not use CoreFoundation, it refuses installs and HTTP(S) with classed
/// errors instead of crashing, and still solves on local channels.
#[cfg(unix)]
#[test]
fn a_forked_child_installs_after_the_parent() {
    let f = Fixture::new();
    // The parent uses the runtime, the link pool and the cache first.
    f.install(&f.prefix("parent"), &["foo"], &[f.chan("chA")], "strict").unwrap();
    let child_prefix = f.prefix("child");
    // What every entry point does (and, on macOS, loading the library).
    crate::runtime::note_entry();
    // SAFETY: the child only runs rattlerthis code and leaves with _exit().
    let pid = unsafe { libc::fork() };
    assert!(pid >= 0, "fork failed");
    if pid == 0 {
        let code = (|| -> i32 {
            if !crate::runtime::is_forked_child() {
                return 2;
            }
            let res = f.install(&child_prefix, &["baz"], &[f.chan("chC")], "strict");
            if cfg!(target_os = "macos") {
                match res {
                    Err(e)
                        if e.starts_with("[rattlerthis:link]")
                            && e.contains("cannot create or change an environment in a forked") => {}
                    _ => return 3,
                }
                if child_prefix.exists() {
                    return 6;
                }
                if f.check(&["baz"], &[f.chan("chC")], "strict", "noarch") != Ok(Some(true)) {
                    return 7;
                }
            } else {
                match res {
                    Ok(out) if out.records.len() == 1 => {}
                    _ => return 4,
                }
            }
            let url = url::Url::parse("https://conda.anaconda.org/conda-forge").unwrap();
            let http = net::ensure_http_allowed([&url]);
            match (cfg!(target_os = "macos"), http) {
                (true, Err(e)) if e.r_message().starts_with("[rattlerthis:fetch] cannot download") => 0,
                (false, Ok(())) => 0,
                _ => 5,
            }
        })();
        unsafe { libc::_exit(code) };
    }
    let start = Instant::now();
    let mut status = 0;
    loop {
        let r = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if r == pid {
            break;
        }
        if start.elapsed() > Duration::from_secs(60) {
            unsafe { libc::kill(pid, libc::SIGKILL) };
            unsafe { libc::waitpid(pid, &mut status, 0) };
            panic!("the forked child hung");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(libc::WIFEXITED(status), "the child crashed (status {status})");
    assert_eq!(libc::WEXITSTATUS(status), 0, "the child failed");
    if !cfg!(target_os = "macos") {
        assert_eq!(installed(&child_prefix), pairs(&[("baz", "1.0")]));
    }
    // The parent still works.
    f.install(&f.prefix("parent"), &["baz"], &[f.chan("chC")], "strict").unwrap();
    assert!(!crate::runtime::is_forked_child());
}

#[test]
fn channel_credentials_stay_out_of_the_records_and_the_history() {
    // micromamba 2.10.0 writes the record's `url` with the token and the
    // password hidden, and its `channel` and the history without them
    // (`secrets.rs`); rattler kept the URL of the solve, so conda-meta (and
    // condathis's list_packages()) showed the secret.
    let f = Fixture::new();
    let token_chans = f.chans.join("t").join("tok-SECRET1");
    make_channel(&token_chans, "chA", &[TestPkg::new("foo", "1.0")]);
    let server = slow_server(f.chans.clone(), 1 << 20, Duration::ZERO);
    let host = server.url.trim_start_matches("http://").to_string();
    for (chan, url_prefix) in [
        (format!("{}/t/tok-SECRET1/chA", server.url), format!("http://{host}/t/*****/chA")),
        (format!("http://rt-user:rt-pw@{host}/chA"), format!("http://rt-user:*****@{host}/chA")),
    ] {
        let p = f.prefix(if chan.contains("/t/") { "cred-token" } else { "cred-login" });
        let out = f.install(&p, &["foo"], std::slice::from_ref(&chan), "strict").unwrap();
        let records = read_prefix_records(&p).unwrap();
        let record = &records[0].repodata_record;
        assert_eq!(record.url.as_str(), format!("{url_prefix}/noarch/foo-1.0-0.tar.bz2"), "{chan}");
        assert_eq!(record.channel.as_deref(), Some(format!("http://{host}/chA/").as_str()), "{chan}");
        let json = std::fs::read_to_string(p.join("conda-meta/foo-1.0-0.json")).unwrap();
        assert!(!json.contains("SECRET1") && !json.contains("rt-pw"), "{json}");
        let history = std::fs::read_to_string(p.join("conda-meta/history")).unwrap();
        assert!(history.contains(&format!("+http://{host}/chA/noarch::foo-1.0-0")), "{history}");
        assert!(!history.contains("SECRET1") && !history.contains("rt-pw"), "{history}");
        assert_eq!(out.records[0].channel, format!("http://{host}/chA"));
        // The same request again changes nothing.
        let again = f.install(&p, &["foo"], std::slice::from_ref(&chan), "strict").unwrap();
        assert!(again.records.is_empty(), "{:?}", again.records);
    }
    // A failed download names the URL with the token hidden.
    let job = install_job(InstallInput {
        specs: vec!["foo".into()],
        prefix: f.prefix("cred-404"),
        channels: vec![format!("{}/t/tok-SECRET2/chA", server.url)],
        channel_priority: "strict".into(),
        platform: None,
        repodata_cache_dir: f.root.join("repodata_cache"),
        pkgs_cache_dir: f.root.join("pkgs"),
        net: Default::default(),
    });
    let err = wait(&job).unwrap_err();
    assert!(!err.contains("SECRET2"), "{err}");
}

#[test]
fn channel_metadata_that_rattler_cannot_use_is_downloaded_again() {
    // Metadata cached while the clock was ahead: fresh by libmamba's rule,
    // but rattler's own check of its cache fails, and a cache-only query
    // then failed every create ("no usable repodata cache"). micromamba
    // downloads it again.
    let f = Fixture::new();
    let server = slow_server(f.chans.clone(), 1 << 20, Duration::ZERO);
    let chan = format!("{}/chA", server.url);
    let requests = || server.repodata_requests.load(std::sync::atomic::Ordering::SeqCst);
    f.install(&f.prefix("future1"), &["foo"], std::slice::from_ref(&chan), "strict").unwrap();
    let first = requests();
    let cache = f.root.join("repodata_cache");
    let future = std::time::SystemTime::now() + Duration::from_secs(3 * 60 * 60);
    for entry in std::fs::read_dir(&cache).unwrap().flatten() {
        if entry.file_name().to_string_lossy().ends_with(".json") {
            std::fs::File::options()
                .write(true)
                .open(entry.path())
                .unwrap()
                .set_modified(future)
                .unwrap();
        }
    }
    let p = f.prefix("future2");
    f.install(&p, &["foo"], std::slice::from_ref(&chan), "strict").unwrap();
    assert_eq!(installed(&p), pairs(&[("foo", "1.0")]));
    assert!(requests() > first, "{} after {first}", requests());
}

#[test]
fn strict_priority_keeps_an_installed_package_of_the_requested_channel() {
    // libsolv keeps installed packages whatever the channel priority:
    // micromamba installs `chB::foo` with chA first and foo 2.0 of chB
    // installed, changing nothing. rattler's pre-check refused it.
    let f = Fixture::new();
    let p = f.prefix("strict-installed");
    let chb = f.chan_url("chB");
    f.install(&p, &[&format!("{chb}::foo")], &[f.chan("chB")], "strict").unwrap();
    let out = f
        .install(&p, &[&format!("{chb}::foo")], &[f.chan("chA"), f.chan("chB")], "strict")
        .unwrap();
    assert!(out.records.is_empty(), "{:?}", out.records);
    assert_eq!(installed(&p), pairs(&[("foo", "2.0")]));
    // A spec the installed record does not satisfy is still checked.
    let err = f
        .install(&p, &[&format!("{chb}::foo<2")], &[f.chan("chA"), f.chan("chB")], "strict")
        .unwrap_err();
    assert!(err.contains("excluded by strict channel priority"), "{err}");
    // So is a channel the installed record does not come from.
    let q = f.prefix("strict-other");
    f.install(&q, &["foo"], &[f.chan("chA")], "strict").unwrap();
    let err = f
        .install(&q, &[&format!("{chb}::foo")], &[f.chan("chA"), f.chan("chB")], "strict")
        .unwrap_err();
    assert!(err.contains("excluded by strict channel priority"), "{err}");
}
