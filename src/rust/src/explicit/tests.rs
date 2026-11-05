//! Explicit installs on local channels, over `file://` and HTTP, checked
//! against what micromamba 2.10.0 writes for the same files.

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use super::*;
use crate::job::{JobOutput, Phase};
use crate::testutil::{make_channel, slow_server, wait, TestPkg};

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    chans: PathBuf,
}

fn script_pkg(name: &str, version: &str) -> TestPkg {
    let record = PackageRecord::new(
        PackageName::new_unchecked(name),
        VersionWithSource::from_str(version).unwrap(),
        "0".into(),
    );
    let mut pkg = TestPkg::new(name, version);
    for kind in [linkscripts::PRE_LINK, linkscripts::POST_LINK, linkscripts::PRE_UNLINK] {
        pkg = pkg.file(&linkscripts::script_path(&record, kind), "exit 0\n");
    }
    pkg
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
        make_channel(&chans, "plink", &[script_pkg("plink", "1.0"), script_pkg("plink", "2.0")]);
        Fixture {
            _dir: dir,
            root,
            chans,
        }
    }

    fn archive(&self, chan: &str, file: &str) -> PathBuf {
        self.chans.join(chan).join("noarch").join(file)
    }

    fn url(&self, chan: &str, file: &str) -> String {
        Url::from_file_path(self.archive(chan, file)).unwrap().to_string()
    }

    fn chan_url(&self, chan: &str) -> String {
        Url::from_directory_path(self.chans.join(chan))
            .unwrap()
            .as_str()
            .trim_end_matches('/')
            .to_string()
    }

    fn hashes(&self, chan: &str, file: &str) -> ArchiveHashes {
        hash_file(&self.archive(chan, file)).unwrap()
    }

    fn prefix(&self, name: &str) -> PathBuf {
        self.root.join("envs").join(name)
    }

    fn job(&self, prefix: &Path, urls: &[String]) -> Job {
        self.job_with(prefix, urls, false)
    }

    fn job_with(&self, prefix: &Path, urls: &[String], lock_file: bool) -> Job {
        install_explicit_job(ExplicitInput {
            urls: urls.to_vec(),
            prefix: prefix.to_path_buf(),
            platform: None,
            pkgs_cache_dir: self.root.join("pkgs"),
            lock_file,
            net: Default::default(),
        })
    }

    fn install(&self, prefix: &Path, urls: &[String]) -> Result<InstallOutcome, String> {
        match wait(&self.job(prefix, urls))? {
            JobOutput::Install(out) => Ok(out),
            other => Err(format!("unexpected output {other:?}")),
        }
    }
}

fn history_body(prefix: &Path) -> Vec<String> {
    std::fs::read_to_string(prefix.join("conda-meta/history"))
        .unwrap()
        .lines()
        .map(|l| if l.starts_with("==> ") { "==> DATE <==".to_string() } else { l.to_string() })
        .collect()
}

fn record_json(prefix: &Path, file: &str) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(prefix.join("conda-meta").join(file)).unwrap()).unwrap()
}

const MD5: &str = "27a5d1994ce4b649f07ee00fe6b9142f";
const SHA: &str = "df343a2364a3cefbaf3df8e6d8b9f77b64f2d52f2fdc4753668b3a2775334714";

#[test]
fn lines_parse_as_libmamba_parses_them() {
    let e = parse_explicit_entry(&format!("  file:///c/chA/noarch/foo-1.0-0.tar.bz2#{MD5}  ")).unwrap();
    assert_eq!(e.url.as_str(), "file:///c/chA/noarch/foo-1.0-0.tar.bz2");
    assert_eq!((e.name.as_str(), e.version.as_str(), e.build.as_str()), ("foo", "1.0", "0"));
    assert_eq!(e.channel, "file:///c/chA");
    assert_eq!(e.platform.as_deref(), Some("noarch"));
    assert_eq!(e.md5.map(|h| hex(&h)), Some(MD5.to_string()));
    assert_eq!(e.sha256, None);
    assert_eq!(e.spec_string(), "foo==1.0=0");
    for line in [
        format!("https://h/c/linux-64/foo-1.0-0.conda#sha256:{SHA}"),
        format!("https://h/c/linux-64/foo-1.0-0.conda#{SHA}"),
    ] {
        let e = parse_explicit_entry(&line).unwrap();
        assert_eq!(e.sha256.map(|h| hex(&h)), Some(SHA.to_string()), "{line}");
        assert_eq!(e.md5, None);
        assert_eq!(e.channel, "https://h/c");
        assert_eq!(e.platform.as_deref(), Some("linux-64"));
        assert_eq!(e.url.fragment(), None);
    }
    // Other fragments are ignored (micromamba "junkhash").
    for frag in ["xyz", "sha256:abc", "abcd", ""] {
        let e = parse_explicit_entry(&format!("https://h/x/foo-1.0-0.tar.bz2#{frag}")).unwrap();
        assert_eq!((e.md5, e.sha256), (None, None), "{frag}");
        // A directory that is not a platform stays in the channel.
        assert_eq!(e.channel, "https://h/x");
        assert_eq!(e.platform, None);
    }
    // Percent-encoded file names, and dashes in names.
    let e = parse_explicit_entry("https://h/c/noarch/my-pkg-1.0%2Bcpu-py_0.tar.bz2").unwrap();
    assert_eq!((e.name.as_str(), e.version.as_str(), e.build.as_str()), ("my-pkg", "1.0+cpu", "py_0"));
}

#[test]
fn hashes_with_upper_case_digits_match_nothing() {
    // libmamba keeps such a hash and compares it as text with the archive's
    // lower-case digest (micromamba upmd5, upsha: "tarball has incorrect").
    for line in [
        format!("file:///c/chA/noarch/foo-1.0-0.tar.bz2#{}", MD5.to_uppercase()),
        format!("file:///c/chA/noarch/foo-1.0-0.tar.bz2#{}", SHA.to_uppercase()),
        format!("file:///c/chA/noarch/foo-1.0-0.tar.bz2#sha256:{}", SHA.to_uppercase()),
    ] {
        let err = parse_explicit_entry(&line).unwrap_err();
        assert_eq!(err.kind(), "hash_mismatch", "{line}: {err}");
    }
    let f = Fixture::new();
    let p = f.prefix("upper");
    let err = f
        .install(&p, &[format!("{}#{}", f.url("chA", "foo-1.0-0.tar.bz2"), MD5.to_uppercase())])
        .unwrap_err();
    assert!(err.starts_with("[rattlerthis:hash_mismatch]"), "{err}");
    assert!(!p.exists());
    // libmamba's strip: control characters around a line are dropped, and
    // so is a byte order mark except on macOS (`spectext.rs`).
    let bom = if cfg!(target_os = "macos") { "" } else { "\u{feff}" };
    let e = parse_explicit_entry(&format!("{bom}\u{1}file:///c/chA/noarch/foo-1.0-0.tar.bz2#{MD5}\u{b}")).unwrap();
    assert_eq!(e.url.as_str(), "file:///c/chA/noarch/foo-1.0-0.tar.bz2");
    assert_eq!(e.md5.map(|h| hex(&h)), Some(MD5.to_string()));
}

#[test]
fn home_is_expanded_as_libmamba_expands_it() {
    let home = || Some(PathBuf::from("/h"));
    assert_eq!(expand_home_with("~", home).unwrap(), PathBuf::from("/h"));
    assert_eq!(expand_home_with("~/x/y", home).unwrap(), PathBuf::from("/h").join("x/y"));
    assert_eq!(expand_home_with("~x/y", home).unwrap(), PathBuf::from("~x/y"));
    assert_eq!(expand_home_with("a/~/b", home).unwrap(), PathBuf::from("a/~/b"));
    // `~\` is a home only on Windows.
    let backslash = expand_home_with("~\\x", home).unwrap();
    if cfg!(windows) {
        assert_eq!(backslash, PathBuf::from("/h").join("x"));
    } else {
        assert_eq!(backslash, PathBuf::from("~\\x"));
    }
    assert!(expand_home_with("~/x", || None).is_err());
    assert_eq!(expand_home_with("x", || None).unwrap(), PathBuf::from("x"));
}

#[test]
fn records_keep_micromambas_channel_and_history_spelling() {
    let f = Fixture::new();
    // A channel directory with spaces (micromamba "spaces": the record's
    // channel decoded, the history line as the URL spells it) and an archive
    // outside a platform directory ("flat": no subdir in the history line).
    let sp_dir = f.root.join("sp chans").join("ch A");
    std::fs::create_dir_all(sp_dir.join("noarch")).unwrap();
    std::fs::copy(f.archive("chA", "foo-1.0-0.tar.bz2"), sp_dir.join("noarch/foo-1.0-0.tar.bz2")).unwrap();
    let flat_dir = f.root.join("flat");
    std::fs::create_dir_all(&flat_dir).unwrap();
    std::fs::copy(f.archive("chA", "foo-1.0-0.tar.bz2"), flat_dir.join("foo-1.0-0.tar.bz2")).unwrap();
    let dir_url = |dir: &Path| Url::from_directory_path(dir).unwrap().as_str().trim_end_matches('/').to_string();

    let p = f.prefix("sp");
    let out = f
        .install(&p, &[sp_dir.join("noarch/foo-1.0-0.tar.bz2").to_string_lossy().to_string()])
        .unwrap();
    let encoded = dir_url(&sp_dir);
    assert!(encoded.contains("sp%20chans/ch%20A"), "{encoded}");
    let decoded = format!("{}/", encoded.replace("%20", " "));
    assert_eq!(record_json(&p, "foo-1.0-0.json")["channel"], decoded.as_str());
    assert_eq!(history_body(&p)[1], format!("+{encoded}/noarch::foo-1.0-0"));
    assert_eq!(out.records[0].channel, encoded);
    assert_eq!(out.channels, vec![encoded.clone()]);

    let p = f.prefix("flat");
    let out = f
        .install(&p, &[Url::from_file_path(flat_dir.join("foo-1.0-0.tar.bz2")).unwrap().to_string()])
        .unwrap();
    let flat = dir_url(&flat_dir);
    assert_eq!(history_body(&p)[1], format!("+{flat}::foo-1.0-0"));
    let rec = record_json(&p, "foo-1.0-0.json");
    assert_eq!(rec["channel"], format!("{flat}/").as_str());
    assert_eq!(rec["subdir"], "noarch");
    assert_eq!((out.records[0].channel.as_str(), out.records[0].subdir.as_str()), (flat.as_str(), "noarch"));
}

#[test]
fn local_paths_become_file_urls() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chA").join("noarch").join("foo-1.0-0.tar.bz2");
    let e = parse_explicit_entry(&path.to_string_lossy()).unwrap();
    assert_eq!(e.url, Url::from_file_path(&path).unwrap());
    assert_eq!(e.channel, Url::from_directory_path(dir.path().join("chA")).unwrap().as_str().trim_end_matches('/'));
    let dotted = dir.path().join("chA").join("x").join("..").join("noarch").join("foo-1.0-0.tar.bz2");
    assert_eq!(parse_explicit_entry(&dotted.to_string_lossy()).unwrap().url, e.url);
    let rel = parse_explicit_entry("chA/noarch/foo-1.0-0.tar.bz2").unwrap();
    assert_eq!(
        rel.url,
        Url::from_file_path(std::env::current_dir().unwrap().join("chA/noarch/foo-1.0-0.tar.bz2")).unwrap()
    );
}

#[test]
fn unsupported_and_invalid_lines() {
    for line in [
        "https://h/c/noarch/six-1.16.0-py2.py3-none-any.whl",
        "https://h/c/noarch/six-1.16.0.tar.gz#abc",
        "git+https://github.com/x/y@main#egg=y",
    ] {
        assert_eq!(parse_explicit_entry(line).unwrap_err().kind(), "unsupported", "{line}");
    }
    for line in [
        "file:///c/chA/noarch/foo-1.0-0",
        "file:///c/chA/noarch/foo-1.0-0.tar.bz2  # comment",
        "file:///c/chA/noarch/foo.tar.bz2",
        "foo",
    ] {
        let err = parse_explicit_entry(line).unwrap_err();
        assert_eq!(err.kind(), "env_file", "{line}: {err}");
    }
    let err = parse_explicit_entries(&[
        "file:///c/chB/noarch/foo-2.0-0.tar.bz2".to_string(),
        "file:///c/chA/noarch/foo-1.0-0.tar.bz2".to_string(),
    ])
    .unwrap_err();
    assert_eq!(err.kind(), "env_file");
    assert!(err.to_string().contains("listed twice"), "{err}");
    assert!(check_package_url("https://h/c/noarch/six-1.16.0-py2.py3-none-any.whl").is_ok());
    assert!(check_package_url("https://h/c/noarch/six").is_err());
}

#[test]
fn installs_in_file_order_with_micromambas_history_and_records() {
    let f = Fixture::new();
    let p = f.prefix("e");
    let foo = f.hashes("chB", "foo-2.0-0.tar.bz2");
    // bar first, though it depends on foo: no solve, the file's order.
    let urls = vec![
        f.url("chB", "bar-1.0-0.tar.bz2"),
        format!("{}#{}", f.url("chB", "foo-2.0-0.tar.bz2"), hex(&foo.md5)),
    ];
    let out = f.install(&p, &urls).unwrap();
    let chb = f.chan_url("chB");
    assert_eq!(
        history_body(&p),
        vec![
            "==> DATE <==".to_string(),
            format!("+{chb}/noarch::bar-1.0-0"),
            format!("+{chb}/noarch::foo-2.0-0"),
            "# update specs: [\"bar==1.0=0\", \"foo==2.0=0\"]".to_string(),
        ]
    );
    let rows: Vec<(String, String, String)> = out
        .records
        .iter()
        .map(|r| (r.op.to_string(), r.name.clone(), r.channel.clone()))
        .collect();
    assert_eq!(
        rows,
        vec![
            ("+".to_string(), "bar".to_string(), chb.clone()),
            ("+".to_string(), "foo".to_string(), chb.clone())
        ]
    );
    assert_eq!(out.channels, vec![chb.clone()]);
    assert!(out.link_scripts_skipped.is_empty());
    // Both hashes and the size of the archive, as micromamba's records.
    let bar = f.hashes("chB", "bar-1.0-0.tar.bz2");
    let rec = record_json(&p, "bar-1.0-0.json");
    assert_eq!(rec["md5"], hex(&bar.md5));
    assert_eq!(rec["sha256"], hex(&bar.sha256));
    assert_eq!(rec["size"], bar.size);
    assert_eq!(rec["url"], f.url("chB", "bar-1.0-0.tar.bz2"));
    assert_eq!(rec["channel"].as_str().unwrap().trim_end_matches('/'), chb);
    assert_eq!(rec["subdir"], "noarch");
    assert_eq!(rec["depends"], serde_json::json!(["foo >=2"]));
    assert_eq!(out.prefix, crate::paths::weakly_canonical(&p).to_string_lossy());
    assert!(!p.join("conda-meta/conda-meta.lock").exists());

    // The packages of a lock file: no specs line, as micromamba.
    let p = f.prefix("lock");
    let JobOutput::Install(_) = wait(&f.job_with(&p, &urls, true)).unwrap() else {
        panic!("unexpected output")
    };
    assert_eq!(
        history_body(&p),
        vec![
            "==> DATE <==".to_string(),
            format!("+{chb}/noarch::bar-1.0-0"),
            format!("+{chb}/noarch::foo-2.0-0"),
        ]
    );
}

#[test]
fn a_wrong_hash_installs_nothing() {
    let f = Fixture::new();
    let foo = f.url("chA", "foo-1.0-0.tar.bz2");
    for (i, frag) in [
        "00000000000000000000000000000000".to_string(),
        format!("sha256:{}", "0".repeat(64)),
    ]
    .iter()
    .enumerate()
    {
        let p = f.prefix(&format!("bad{i}"));
        let err = f.install(&p, &[format!("{foo}#{frag}")]).unwrap_err();
        assert!(err.starts_with("[rattlerthis:hash_mismatch]"), "{err}");
        assert!(!p.exists(), "{} was left behind", p.display());
    }
    // The right hashes, in both forms, install.
    let h = f.hashes("chA", "foo-1.0-0.tar.bz2");
    f.install(&f.prefix("good1"), &[format!("{foo}#{}", hex(&h.md5))]).unwrap();
    f.install(&f.prefix("good2"), &[format!("{foo}#sha256:{}", hex(&h.sha256))]).unwrap();
    // A sha256 is checked over an md5 (libmamba checks one hash).
    let err = f
        .install(&f.prefix("bad3"), &[format!("{foo}#{}", "1".repeat(64))])
        .unwrap_err();
    assert!(err.starts_with("[rattlerthis:hash_mismatch]"), "{err}");
}

#[test]
fn invalid_lists_touch_nothing() {
    let f = Fixture::new();
    let p = f.prefix("dup");
    let err = f
        .install(&p, &[f.url("chB", "foo-2.0-0.tar.bz2"), f.url("chA", "foo-1.0-0.tar.bz2")])
        .unwrap_err();
    assert!(err.starts_with("[rattlerthis:env_file]"), "{err}");
    assert!(!p.exists());
    let err = f
        .install(&p, &["https://h/c/noarch/six-1.16.0-py2.py3-none-any.whl".to_string()])
        .unwrap_err();
    assert!(err.starts_with("[rattlerthis:unsupported]"), "{err}");
    let err = f.install(&p, &[f.url("chA", "nope-1.0-0.tar.bz2")]).unwrap_err();
    assert!(err.starts_with("[rattlerthis:fetch]"), "{err}");
    assert!(!p.exists());
    let err = install_explicit_job(ExplicitInput {
        urls: vec![],
        prefix: p.clone(),
        platform: Some("bogus".into()),
        pkgs_cache_dir: f.root.join("pkgs"),
        lock_file: false,
        net: Default::default(),
    });
    assert!(wait(&err).unwrap_err().starts_with("[rattlerthis:invalid_platform]"));
}

#[test]
fn an_empty_list_creates_an_empty_environment() {
    let f = Fixture::new();
    let p = f.prefix("empty");
    let out = f.install(&p, &[]).unwrap();
    assert!(out.records.is_empty() && out.channels.is_empty());
    assert!(p.join("conda-meta").is_dir());
    assert!(install::read_prefix_records(&p).unwrap().is_empty());
}

#[test]
fn same_names_are_replaced_and_link_scripts_reported() {
    let f = Fixture::new();
    let p = f.prefix("pl");
    let out = f.install(&p, &[f.url("plink", "plink-1.0-0.tar.bz2")]).unwrap();
    assert_eq!(
        out.link_scripts_skipped,
        vec![
            ("plink".to_string(), linkscripts::PRE_LINK),
            ("plink".to_string(), linkscripts::POST_LINK)
        ]
    );
    let out = f
        .install(&p, &[f.url("plink", "plink-2.0-0.tar.bz2"), f.url("chA", "foo-1.0-0.tar.bz2")])
        .unwrap();
    assert_eq!(
        out.link_scripts_skipped,
        vec![
            ("plink".to_string(), linkscripts::PRE_UNLINK),
            ("plink".to_string(), linkscripts::PRE_LINK),
            ("plink".to_string(), linkscripts::POST_LINK)
        ]
    );
    let names: Vec<String> = install::read_prefix_records(&p)
        .unwrap()
        .iter()
        .map(|r| r.repodata_record.identifier.to_string())
        .collect();
    assert_eq!(names, vec!["foo-1.0-0.tar.bz2", "plink-2.0-0.tar.bz2"]);
    let pl = f.chan_url("plink");
    let cha = f.chan_url("chA");
    let body = history_body(&p);
    assert_eq!(
        body[3..].to_vec(),
        vec![
            "==> DATE <==".to_string(),
            format!("-{pl}/noarch::plink-1.0-0"),
            format!("+{pl}/noarch::plink-2.0-0"),
            format!("+{cha}/noarch::foo-1.0-0"),
            "# update specs: [\"plink==2.0=0\", \"foo==1.0=0\"]".to_string(),
        ],
        "{body:?}"
    );
    // Installing what is there changes nothing.
    let out = f.install(&p, &[f.url("chA", "foo-1.0-0.tar.bz2")]).unwrap();
    assert!(out.records.is_empty(), "{:?}", out.records);
}

#[test]
fn http_urls_are_checked_and_cached() {
    let f = Fixture::new();
    let server = slow_server(f.chans.clone(), 256 * 1024, Duration::from_millis(1));
    let url = |chan: &str, file: &str| format!("{}/{chan}/noarch/{file}", server.url);
    let requests = || server.package_requests.load(Ordering::SeqCst);
    let foo = f.hashes("chA", "foo-1.0-0.tar.bz2");

    let p1 = f.prefix("h1");
    f.install(&p1, &[format!("{}#sha256:{}", url("chA", "foo-1.0-0.tar.bz2"), hex(&foo.sha256))])
        .unwrap();
    assert_eq!(requests(), 1);
    let rec = record_json(&p1, "foo-1.0-0.json");
    assert_eq!(rec["md5"], hex(&foo.md5));
    assert_eq!(rec["sha256"], hex(&foo.sha256));
    assert_eq!(rec["size"], foo.size);
    assert_eq!(rec["channel"].as_str().unwrap().trim_end_matches('/'), format!("{}/chA", server.url));
    // The same URL again, with either hash or none: from the cache.
    f.install(&f.prefix("h2"), &[format!("{}#{}", url("chA", "foo-1.0-0.tar.bz2"), hex(&foo.md5))])
        .unwrap();
    f.install(&f.prefix("h3"), &[url("chA", "foo-1.0-0.tar.bz2")]).unwrap();
    assert_eq!(requests(), 1);
    assert_eq!(record_json(&f.prefix("h3"), "foo-1.0-0.json")["md5"], hex(&foo.md5));
    // A wrong hash for a cached package: fetched again, then refused.
    let p4 = f.prefix("h4");
    let err = f
        .install(&p4, &[format!("{}#{}", url("chA", "foo-1.0-0.tar.bz2"), "0".repeat(32))])
        .unwrap_err();
    assert!(err.starts_with("[rattlerthis:hash_mismatch]"), "{err}");
    assert_eq!(requests(), 2);
    assert!(!p4.exists());
    // A package the cache got from elsewhere (here a file:// install of a
    // package with the same name, version and build) is fetched again.
    f.install(&f.prefix("f1"), &[f.url("chB", "bar-1.0-0.tar.bz2")]).unwrap();
    let before = requests();
    let p5 = f.prefix("h5");
    f.install(&p5, &[url("chB", "foo-2.0-0.tar.bz2"), url("chB", "bar-1.0-0.tar.bz2")]).unwrap();
    assert_eq!(requests(), before + 2);
    let bar = f.hashes("chB", "bar-1.0-0.tar.bz2");
    assert_eq!(record_json(&p5, "bar-1.0-0.json")["sha256"], hex(&bar.sha256));
    // A failed download.
    let err = f.install(&f.prefix("h6"), &[url("chA", "nope-1.0-0.tar.bz2")]).unwrap_err();
    assert!(err.starts_with("[rattlerthis:fetch]"), "{err}");
}

#[test]
fn cancel_during_prefetch_leaves_nothing() {
    let f = Fixture::new();
    let mut state: u64 = 0x2545_F491_4F6C_DD1D;
    let noise: Vec<u8> = (0..1_500_000)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 24) as u8
        })
        .collect();
    make_channel(&f.chans, "big", &[TestPkg::new("big", "1.0").file("share/big/noise.bin", noise)]);
    let server = slow_server(f.chans.clone(), 16 * 1024, Duration::from_millis(400));
    let p = f.prefix("big");
    let job = f.job(&p, &[format!("{}/big/noarch/big-1.0-0.tar.bz2", server.url)]);
    let start = Instant::now();
    while server.package_requests.load(Ordering::SeqCst) == 0 {
        assert!(start.elapsed() < Duration::from_secs(30), "download never started: {:?}", job.phase());
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(job.phase(), Phase::Prefetch);
    let t = Instant::now();
    assert!(job.cancel());
    let err = wait(&job).unwrap_err();
    assert!(err.starts_with("[rattlerthis:cancelled]"), "{err}");
    assert!(t.elapsed() < Duration::from_secs(20), "cancel took {:?}", t.elapsed());
    assert!(!p.exists(), "{} was left behind", p.display());
}
