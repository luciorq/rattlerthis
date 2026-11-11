//! Environment file parsing, checked against what micromamba 2.10.0 does
//! with the same files (`micromamba create -f`, 2026-10-28).

use super::*;

fn no_env(_: &str) -> Option<String> {
    None
}

fn yaml(text: &str) -> RtResult<EnvFile> {
    read_yaml(text, "env.yml", Subdir::Linux64, &no_env)
}

fn yaml_on(text: &str, platform: Subdir) -> RtResult<EnvFile> {
    read_yaml(text, "env.yml", platform, &no_env)
}

fn kind_of(err: &RtError) -> &'static str {
    err.kind()
}

#[test]
fn kinds_follow_the_file_name() {
    assert_eq!(classify("a/environment.yml"), EnvFileKind::Yaml);
    assert_eq!(classify("env.yaml"), EnvFileKind::Yaml);
    assert_eq!(classify("conda-lock.yml"), EnvFileKind::CondaLock);
    assert_eq!(classify("x-lock.yaml"), EnvFileKind::CondaLock);
    assert_eq!(classify("lock.json"), EnvFileKind::MambajsLock);
    assert_eq!(classify("spec.txt"), EnvFileKind::Plain);
    assert_eq!(classify("pixi.lock"), EnvFileKind::Plain);
    // Case sensitive, as micromamba.
    assert_eq!(classify("ENV.YML"), EnvFileKind::Plain);
    assert_eq!(EnvFileKind::CondaLock.name(), "conda_lock");
}

#[test]
fn yaml_basic_fields() {
    let f = yaml(
        "name: other\nchannels:\n  - chB\n  - nodefaults\ndependencies:\n  - foo\n  - bar >=1\n",
    )
    .unwrap();
    assert_eq!(f.kind, EnvFileKind::Yaml);
    assert_eq!(f.name.as_deref(), Some("other"));
    assert_eq!(f.channels, vec!["chB", "nodefaults"]);
    assert_eq!(f.specs, vec!["foo", "bar >=1"]);
    assert!(f.variables.is_empty() && f.urls.is_empty() && f.problems.is_empty());
}

#[test]
fn yaml_selectors_and_ignored_items() {
    // micromamba y1: nested lists, nulls and other keys are ignored.
    let text = "dependencies:\n  - foo\n  - sel(unix): baz\n  - {sel(osx): bar}\n  - [nested]\n  - ~\n  - other: x\n";
    assert_eq!(yaml_on(text, Subdir::Linux64).unwrap().specs, vec!["foo", "baz"]);
    assert_eq!(yaml_on(text, Subdir::OsxArm64).unwrap().specs, vec!["foo", "baz", "bar"]);
    assert_eq!(yaml_on(text, Subdir::Win64).unwrap().specs, vec!["foo"]);
    let text = "dependencies:\n  - sel(win): baz\n  - sel(linux): foo\n  - sel(osx): bar\n";
    assert_eq!(yaml_on(text, Subdir::Win64).unwrap().specs, vec!["baz"]);
    assert_eq!(yaml_on(text, Subdir::WinArm64).unwrap().specs, vec!["baz"]);
    assert_eq!(yaml_on(text, Subdir::LinuxAarch64).unwrap().specs, vec!["foo"]);
    assert_eq!(yaml_on(text, Subdir::Osx64).unwrap().specs, vec!["bar"]);
    assert!(yaml_on(text, Subdir::EmscriptenWasm32).unwrap().specs.is_empty());
}

#[test]
fn yaml_selector_errors() {
    // micromamba y2 and y3.
    let err = yaml("dependencies:\n  - sel( linux): foo\n").unwrap_err();
    assert_eq!(kind_of(&err), "env_file");
    assert!(err.to_string().contains("Value not in [unix, linux, osx, win]"), "{err}");
    let err = yaml("dependencies:\n  - sel(linux): [foo, baz]\n").unwrap_err();
    assert!(err.to_string().contains("Complicated selection merge"), "{err}");
    // An unselected list is fine (micromamba y4).
    assert_eq!(
        yaml("dependencies:\n  - sel(win): [foo, baz]\n  - baz\n").unwrap().specs,
        vec!["baz"]
    );
    assert!(eval_selector("sel()", Subdir::Linux64).is_err());
    assert!(eval_selector("sel(linux", Subdir::Linux64).is_err());
}

#[test]
fn yaml_shapes_micromamba_accepts_or_refuses() {
    // `dependencies` that is not a list counts as none (micromamba y5).
    assert!(yaml("dependencies: foo\n").unwrap().specs.is_empty());
    // A null `channels` is refused (micromamba y6).
    let err = yaml("channels:\ndependencies:\n  - foo\n").unwrap_err();
    assert!(err.to_string().contains("'channels'"), "{err}");
    // `variables` as a list is refused (micromamba y8).
    assert_eq!(kind_of(&yaml("variables: [a, b]\n").unwrap_err()), "env_file");
    // A null name is fine (micromamba y9).
    assert_eq!(yaml("name:\ndependencies:\n  - foo\n").unwrap().name, None);
    // An empty file is an empty environment (micromamba y10).
    let f = yaml("").unwrap();
    assert!(f.specs.is_empty() && f.channels.is_empty());
    assert!(yaml("# only a comment\n").unwrap().specs.is_empty());
    // A top-level list is an empty environment (micromamba toplist); a
    // single value is refused (topscalar).
    let f = yaml("- foo\n- baz\n").unwrap();
    assert!(f.specs.is_empty() && f.channels.is_empty());
    let err = yaml("justascalar\n").unwrap_err();
    assert_eq!(kind_of(&err), "env_file");
    assert!(err.to_string().contains("operator[] call on a scalar"), "{err}");
    // Invalid YAML.
    assert_eq!(kind_of(&yaml("dependencies: [foo\n").unwrap_err()), "env_file");
    // Only the first document counts, as yaml-cpp's LoadFile.
    assert_eq!(
        yaml("dependencies:\n  - foo\n---\ndependencies:\n  - bar\n").unwrap().specs,
        vec!["foo"]
    );
}

#[test]
fn yaml_variables_keep_their_text() {
    // As micromamba y7 reads them (shown at verbose "full" only).
    let f = yaml(
        "variables:\n  EMPTY:\n  T: true\n  H: 0x10\n  Q: \"quoted\"\n  a: lower\n  A: upper\n  NUM: 1.50\ndependencies:\n  - foo\n",
    )
    .unwrap();
    assert_eq!(
        f.variables,
        vec![
            ("A".to_string(), "upper".to_string()),
            ("EMPTY".to_string(), "null".to_string()),
            ("H".to_string(), "0x10".to_string()),
            ("NUM".to_string(), "1.50".to_string()),
            ("Q".to_string(), "quoted".to_string()),
            ("T".to_string(), "true".to_string()),
            ("a".to_string(), "lower".to_string()),
        ]
    );
}

#[test]
fn yaml_tags_are_ignored_and_repeated_keys_follow_yaml_cpp() {
    // micromamba ytag2 and ytag3: tags do not change the text.
    let f = yaml(
        "channels:\n  - !!str chA\n  - !custom chC\ndependencies:\n  - !custom foo\n  - {sel(unix): !!str baz}\n  - !!str 7z\nvariables: !mytag\n  N: !!int 007\n  S: !!str 1.50\n  F: !!float 1.50\n  Y: !!bool yes\n  X: !custom val\n",
    )
    .unwrap();
    assert_eq!(f.channels, vec!["chA", "chC"]);
    assert_eq!(f.specs, vec!["foo", "baz", "7z"]);
    let vars: Vec<(&str, &str)> = f.variables.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    assert_eq!(vars, vec![("F", "1.50"), ("N", "007"), ("S", "1.50"), ("X", "val"), ("Y", "yes")]);
    // micromamba yrepeat: the first of a repeated top-level key, the last of
    // a repeated variable.
    let f = yaml(
        "channels:\n  - chA\ndependencies:\n  - foo\nchannels:\n  - chC\ndependencies:\n  - baz\nvariables:\n  A: first\n  A: second\n  B: one\nvariables:\n  C: other\nname: n1\nname: n2\n",
    )
    .unwrap();
    assert_eq!(f.channels, vec!["chA"]);
    assert_eq!(f.specs, vec!["foo"]);
    assert_eq!(f.name.as_deref(), Some("n1"));
    assert_eq!(
        f.variables,
        vec![("A".to_string(), "second".to_string()), ("B".to_string(), "one".to_string())]
    );
}

fn pip_groups(f: &EnvFile) -> Vec<(&str, Vec<&str>)> {
    f.pip
        .iter()
        .map(|g| (g.manager.as_str(), g.specs.iter().map(String::as_str).collect()))
        .collect()
}

#[test]
fn yaml_pip_sections_are_pip_steps() {
    // micromamba p1: one pip step per section, in file order, entries as
    // written; `pip` is added to the specs.
    let f = yaml(
        "dependencies:\n  - python\n  - pip:\n    - six==1.16.0\n    - -r extra.txt\n    - ./localpkg\n  - pip:\n    - second\n",
    )
    .unwrap();
    assert_eq!(f.specs, vec!["python", "pip"]);
    assert_eq!(
        pip_groups(&f),
        vec![("pip", vec!["six==1.16.0", "-r extra.txt", "./localpkg"]), ("pip", vec!["second"])]
    );
    // An empty section is a step too (micromamba runs pip with an empty
    // requirements file), and `pip` is added once.
    let f = yaml("dependencies:\n  - python\n  - pip: []\n  - pip\n").unwrap();
    assert_eq!(f.specs, vec!["python", "pip"]);
    assert_eq!(pip_groups(&f), vec![("pip", vec![])]);
    // With `uv` among the dependencies, uv installs them and nothing is
    // added; a `uv` with a version does not count (micromamba compares the
    // text).
    let f = yaml("dependencies:\n  - uv\n  - pip:\n    - six\n").unwrap();
    assert_eq!(f.specs, vec!["uv"]);
    assert_eq!(pip_groups(&f), vec![("uv", vec!["six"])]);
    let f = yaml("dependencies:\n  - uv>=0.5\n  - pip:\n    - six\n").unwrap();
    assert_eq!(f.specs, vec!["uv>=0.5", "pip"]);
    assert_eq!(pip_groups(&f), vec![("pip", vec!["six"])]);
    // A null entry reads `null`, as yaml-cpp's conversion gives it.
    assert_eq!(pip_groups(&yaml("dependencies:\n  - pip:\n    - ~\n").unwrap()), vec![("pip", vec!["null"])]);
    // No section, no step.
    assert!(yaml("dependencies:\n  - pip\n").unwrap().pip.is_empty());
    assert_eq!(kind_of(&yaml("dependencies:\n  - pip: six\n").unwrap_err()), "env_file");
    assert_eq!(kind_of(&yaml("dependencies:\n  - pip:\n").unwrap_err()), "env_file");
    assert_eq!(kind_of(&yaml("dependencies:\n  - pip:\n    - [a]\n").unwrap_err()), "env_file");
    // A later error still wins, as micromamba reads everything first.
    let err = yaml("dependencies:\n  - pip:\n    - six\n  - sel(bogus): x\n").unwrap_err();
    assert_eq!(kind_of(&err), "env_file");
}

#[test]
fn expandvars_follows_libmamba() {
    let lookup = |name: &str| match name {
        "CH" => Some("file:///chans".to_string()),
        "EMPTY" => Some(String::new()),
        "SELF" => Some("$SELF".to_string()),
        _ => None,
    };
    assert_eq!(expandvars("${CH}/chA", &lookup), "file:///chans/chA");
    assert_eq!(expandvars("$CH/chA", &lookup), "file:///chans/chA");
    assert_eq!(expandvars("$NOPE/x/${CH}", &lookup), "$NOPE/x/file:///chans");
    assert_eq!(expandvars("${EMPTY}x", &lookup), "x");
    assert_eq!(expandvars("${CH", &lookup), "${CH");
    assert_eq!(expandvars("${}x$", &lookup), "${}x$");
    assert_eq!(expandvars("plain", &lookup), "plain");
    // A value that refers to itself stops (libmamba would recurse forever).
    assert_eq!(expandvars("$SELF", &lookup), "$SELF");
    let f = read_yaml(
        "channels:\n  - ${CH}/chC\n  - $NOPE/x\ndependencies:\n  - baz\n",
        "e.yml",
        Subdir::Linux64,
        &lookup,
    )
    .unwrap();
    assert_eq!(f.channels, vec!["file:///chans/chC", "$NOPE/x"]);
}

#[test]
fn text_files_plain_and_explicit() {
    // micromamba p1.
    let f = read_text("# comment\n\nfoo  # trailing\n  baz\n@weird\n", "s.txt").unwrap();
    assert_eq!(f.kind, EnvFileKind::Plain);
    assert_eq!(f.specs, vec!["foo  # trailing", "baz"]);
    let f = read_text("bar\r\nfoo>=2\r\n", "s.txt").unwrap();
    assert_eq!(f.specs, vec!["bar", "foo>=2"]);
    // micromamba p3, p4: empty files are refused.
    for text in ["\n# only comments\n\n", ""] {
        let err = read_text(text, "s.txt").unwrap_err();
        assert_eq!(kind_of(&err), "env_file");
        assert!(err.to_string().contains("Got an empty file"), "{err}");
    }
    // micromamba p5: specs before @EXPLICIT are ignored.
    let f = read_text("foo\n@EXPLICIT\n", "s.txt").unwrap();
    assert_eq!(f.kind, EnvFileKind::Explicit);
    assert!(f.urls.is_empty() && f.specs.is_empty());
    // Leading and trailing blank lines, the platform line, CRLF, indent.
    let f = read_text(
        "\n# This file may be used to create an environment\r\n# platform: linux-64\r\n  @EXPLICIT\r\nfile:///c/noarch/foo-1.0-0.tar.bz2#abc\r\n\r\n  file:///c/noarch/bar-1.0-0.conda  \n",
        "e.txt",
    )
    .unwrap();
    assert_eq!(f.kind, EnvFileKind::Explicit);
    assert_eq!(f.file_platform.as_deref(), Some("linux-64"));
    assert_eq!(
        f.urls,
        vec!["file:///c/noarch/foo-1.0-0.tar.bz2#abc", "file:///c/noarch/bar-1.0-0.conda"]
    );
    assert_eq!(read_text("@EXPLICIT\nx\n", "e.txt").unwrap().file_platform, None);
}

const MD5: &str = "1ae1d2cf711106e2bcf906cb4c6cd0e2";
const SHA: &str = "5a0d090a8d7deb86b495d6a18f64901445a01dca1767bd571e5b2ccd02774c74";

fn lock_pkg(name: &str, manager: &str, platform: &str, category: &str, hash: &str, url: &str) -> String {
    format!(
        "- name: {name}\n  version: '1.0'\n  manager: {manager}\n  platform: {platform}\n  dependencies: {{}}\n  url: {url}\n  hash: {{{hash}}}\n  category: {category}\n  optional: false\n"
    )
}

fn lock_text(version: &str, packages: &[String]) -> String {
    format!(
        "version: {version}\nmetadata:\n  content_hash: {{linux-64: abc}}\n  channels: [{{url: 'file:///c/chC', used_env_vars: []}}]\n  platforms: [linux-64, osx-arm64]\n  sources: [environment.yml]\npackage:\n{}",
        packages.concat()
    )
}

fn both() -> String {
    format!("md5: {MD5}, sha256: {SHA}")
}

#[test]
fn conda_lock_selects_main_conda_packages_for_the_platform() {
    let u = |n: &str| format!("file:///c/chC/noarch/{n}-1.0-0.tar.bz2");
    let text = lock_text(
        "1",
        &[
            lock_pkg("baz", "conda", "linux-64", "main", &both(), &u("baz")),
            lock_pkg("devtool", "conda", "linux-64", "dev", &both(), &u("devtool")),
            lock_pkg("mac", "conda", "osx-arm64", "main", &format!("md5: {MD5}"), &u("mac")),
            lock_pkg("anyarch", "conda", "noarch", "main", &format!("md5: {MD5}"), &u("anyarch")),
            lock_pkg(
                "six",
                "pip",
                "osx-arm64",
                "main",
                &format!("sha256: {SHA}"),
                "https://files.example/six-1.16.0-py2.py3-none-any.whl",
            ),
            lock_pkg(
                "devpip",
                "pip",
                "linux-64",
                "dev",
                &format!("sha256: {SHA}"),
                "https://files.example/devpip-1.0-py3-none-any.whl",
            ),
        ],
    );
    let f = read_conda_lock(&text, "x-lock.yml", Subdir::Linux64).unwrap();
    assert_eq!(f.kind, EnvFileKind::CondaLock);
    assert_eq!(f.platforms, vec!["linux-64", "osx-arm64"]);
    // sha256 when the lock has it, else md5; file order.
    assert_eq!(
        f.urls,
        vec![format!("{}#{SHA}", u("baz")), format!("{}#{MD5}", u("anyarch"))]
    );
    assert!(f.problems.is_empty());
    // The pip packages of the platform (category main) are one pip step,
    // without dependencies (micromamba l1).
    assert!(f.pip.is_empty());
    let f = read_conda_lock(&text, "x-lock.yml", Subdir::OsxArm64).unwrap();
    assert_eq!(
        pip_groups(&f),
        vec![(
            "pip --no-deps",
            vec![format!("six @ https://files.example/six-1.16.0-py2.py3-none-any.whl#sha256={SHA}").as_str()]
        )]
    );
    // No packages for the platform: an empty environment, with a note.
    let f = read_conda_lock(&text, "x-lock.yml", Subdir::Win64).unwrap();
    assert_eq!(f.urls, vec![format!("{}#{MD5}", u("anyarch"))]);
    let only = lock_text("1", &[lock_pkg("baz", "conda", "osx-64", "main", &both(), &u("baz"))]);
    let f = read_conda_lock(&only, "x-lock.yml", Subdir::Linux64).unwrap();
    assert!(f.urls.is_empty());
    assert_eq!(f.problems.len(), 1, "{:?}", f.problems);
    // A pip package without a platform or for noarch is installed by
    // micromamba too; one without a sha256 gets an empty one; a line given
    // twice is written once.
    let noplat = lock_text(
        "1",
        &[
            lock_pkg("six", "pip", "''", "main", &format!("sha256: {SHA}"), "https://f/six-1.0-py3-none-any.whl"),
            lock_pkg("na", "pip", "noarch", "main", &format!("md5: {MD5}"), "https://f/na-1.0-py3-none-any.whl"),
            lock_pkg("six", "pip", "linux-64", "main", &format!("sha256: {SHA}"), "https://f/six-1.0-py3-none-any.whl"),
        ],
    );
    let f = read_conda_lock(&noplat, "x-lock.yml", Subdir::Linux64).unwrap();
    assert_eq!(
        pip_groups(&f),
        vec![(
            "pip --no-deps",
            vec![
                format!("six @ https://f/six-1.0-py3-none-any.whl#sha256={SHA}").as_str(),
                "na @ https://f/na-1.0-py3-none-any.whl#sha256="
            ]
        )]
    );
    assert!(f.urls.is_empty());
}

#[test]
fn conda_lock_errors() {
    let u = "file:///c/chC/noarch/baz-1.0-0.tar.bz2";
    let ok = lock_pkg("baz", "conda", "linux-64", "main", &both(), u);
    let err = read_conda_lock(&lock_text("2", std::slice::from_ref(&ok)), "x-lock.yml", Subdir::Linux64).unwrap_err();
    assert!(err.to_string().contains("unknown lock file version '2'"), "{err}");
    assert_eq!(kind_of(&err), "env_file");
    let no_hash = ok.replace(&format!("  hash: {{{}}}\n", both()), "");
    assert!(read_conda_lock(&lock_text("1", &[no_hash]), "x-lock.yml", Subdir::Linux64).is_err());
    let empty_hash = ok.replace(&both(), "");
    let err = read_conda_lock(&lock_text("1", &[empty_hash]), "x-lock.yml", Subdir::Linux64).unwrap_err();
    assert!(err.to_string().contains("'hash.md5' or 'hash.sha256'"), "{err}");
    let bad_url = ok.replace(u, "file:///c/chC/noarch/baz-1.0-0");
    assert!(read_conda_lock(&lock_text("1", &[bad_url]), "x-lock.yml", Subdir::Linux64).is_err());
    let no_name = ok.replace("- name: baz\n  version", "- version");
    assert!(read_conda_lock(&lock_text("1", &[no_name]), "x-lock.yml", Subdir::Linux64).is_err());
    let text = lock_text("1", &[ok]);
    for (from, to) in [
        ("  platforms: [linux-64, osx-arm64]\n", ""),
        ("  sources: [environment.yml]\n", ""),
        ("  content_hash: {linux-64: abc}\n", ""),
        (", used_env_vars: []", ""),
    ] {
        assert!(
            read_conda_lock(&text.replace(from, to), "x-lock.yml", Subdir::Linux64).is_err(),
            "{from}"
        );
    }
    assert!(read_conda_lock("", "x-lock.yml", Subdir::Linux64).is_err());
}

#[test]
fn conda_lock_hashes_are_checked_as_micromamba_checks_them() {
    let u = "file:///c/chC/noarch/baz-1.0-0.tar.bz2";
    let lock = |hash: &str| lock_text("1", &[lock_pkg("baz", "conda", "linux-64", "main", hash, u)]);
    let read = |hash: &str| read_conda_lock(&lock(hash), "x-lock.yml", Subdir::Linux64);
    // micromamba hjunk, htrunc, hjunkmd5, hmd5junk, upshalock, upmd5lock:
    // "tarball has incorrect SHA256/MD5".
    for hash in [
        "sha256: 'nothex'".to_string(),
        format!("sha256: '{}', md5: {MD5}", &SHA[..63]),
        "sha256: 'zz', md5: '00000000000000000000000000000000'".to_string(),
        "md5: 'abc'".to_string(),
        format!("sha256: {}", SHA.to_uppercase()),
        format!("md5: {}", MD5.to_uppercase()),
    ] {
        let err = read(&hash).unwrap_err();
        assert_eq!(kind_of(&err), "hash_mismatch", "{hash}: {err}");
        assert!(err.to_string().contains("tarball has incorrect"), "{err}");
    }
    // The sha256 is the one checked (micromamba hupper2); an empty sha256
    // counts as none (hempty).
    assert_eq!(read(&format!("sha256: {SHA}, md5: 'junk'")).unwrap().urls, vec![format!("{u}#{SHA}")]);
    assert_eq!(read(&format!("sha256: '', md5: {MD5}")).unwrap().urls, vec![format!("{u}#{MD5}")]);
    // A package hash of an entry for another platform is not checked.
    let other = lock_text(
        "1",
        &[
            lock_pkg("baz", "conda", "linux-64", "main", &format!("md5: {MD5}"), u),
            lock_pkg("mac", "conda", "osx-arm64", "main", "md5: 'x'", "file:///c/chC/noarch/mac-1.0-0.tar.bz2"),
        ],
    );
    assert!(read_conda_lock(&other, "x-lock.yml", Subdir::Linux64).is_ok());
    // A wheel or source archive among the conda packages is unsupported.
    let whl = lock_text(
        "1",
        &[lock_pkg("six", "conda", "linux-64", "main", &format!("md5: {MD5}"), "file:///c/chC/noarch/six-1.0-py3-none-any.whl")],
    );
    assert_eq!(kind_of(&read_conda_lock(&whl, "x-lock.yml", Subdir::Linux64).unwrap_err()), "unsupported");
}

#[test]
fn files_are_decoded_as_micromamba_decodes_them() {
    let dir = tempfile::tempdir().unwrap();
    let write = |name: &str, bytes: &[u8]| {
        let p = dir.path().join(name);
        std::fs::write(&p, bytes).unwrap();
        p
    };
    let utf16 = |text: &str, be: bool| -> Vec<u8> {
        text.encode_utf16()
            .flat_map(|u| if be { u.to_be_bytes() } else { u.to_le_bytes() })
            .collect()
    };
    let utf32le = |text: &str| -> Vec<u8> { text.chars().flat_map(|c| (c as u32).to_le_bytes()).collect() };
    // `conda env export` order: `name:` first (micromamba ybomexport,
    // u16lebom, u16benobom, u16lenobom, u8bomyml).
    let text = "name: myenv\nchannels:\n  - chA\ndependencies:\n  - foo\n  - baz\nvariables:\n  MYV: 1\n";
    let bom8 = [&[0xEF, 0xBB, 0xBF][..], text.as_bytes()].concat();
    let bom16le = [&[0xFF, 0xFE][..], &utf16(text, false)].concat();
    let bom16be = [&[0xFE, 0xFF][..], &utf16(text, true)].concat();
    let bom32le = [&[0xFF, 0xFE, 0, 0][..], &utf32le(text)].concat();
    for (name, bytes) in [
        ("bom8.yml", bom8.clone()),
        ("bom16le.yml", bom16le),
        ("bom16be.yml", bom16be),
        ("le16.yml", utf16(text, false)),
        ("be16.yml", utf16(text, true)),
        ("bom32le.yml", bom32le),
        ("le32.yml", utf32le(text)),
    ] {
        let f = read_env_file(&write(name, &bytes), Subdir::Linux64).unwrap();
        assert_eq!(f.name.as_deref(), Some("myenv"), "{name}");
        assert_eq!(f.channels, vec!["chA"], "{name}");
        assert_eq!(f.specs, vec!["foo", "baz"], "{name}");
        assert_eq!(f.variables, vec![("MYV".to_string(), "1".to_string())], "{name}");
    }
    // A conda-lock file with a byte order mark.
    let lock = lock_text("1", &[lock_pkg("baz", "conda", "linux-64", "main", &both(), "file:///c/chC/noarch/baz-1.0-0.tar.bz2")]);
    let f = read_env_file(&write("b-lock.yml", &[&[0xEF, 0xBB, 0xBF][..], lock.as_bytes()].concat()), Subdir::Linux64).unwrap();
    assert_eq!(f.urls.len(), 1);
    // Text files keep a byte order mark in the first line, as micromamba
    // (the spec parser drops it; micromamba bomplain); one before
    // `@EXPLICIT` makes the file a spec list in both (bomexplicit).
    let f = read_env_file(&write("p.txt", &[&[0xEF, 0xBB, 0xBF][..], b"foo\nbaz\n"].concat()), Subdir::Linux64).unwrap();
    assert_eq!(f.specs, vec!["\u{feff}foo", "baz"]);
    let f = read_env_file(&write("x.txt", &[&[0xEF, 0xBB, 0xBF][..], b"@EXPLICIT\nfile:///c/noarch/foo-1.0-0.tar.bz2\n"].concat()), Subdir::Linux64).unwrap();
    assert_eq!(f.kind, EnvFileKind::Plain);
    // UTF-16 text files (micromamba u16txt cannot use them either).
    let err = read_env_file(&write("u.txt", &[&[0xFF, 0xFE][..], &utf16("foo\n", false)].concat()), Subdir::Linux64).unwrap_err();
    assert_eq!(kind_of(&err), "env_file");
    assert!(err.to_string().contains("UTF-16"), "{err}");
    // A NUL escape in YAML (micromamba ynul cuts the spec at it).
    let err = read_env_file(&write("n.yml", b"dependencies:\n  - \"foo\\0x\"\n"), Subdir::Linux64).unwrap_err();
    assert_eq!(kind_of(&err), "env_file");
    assert!(err.to_string().contains("NUL") && !err.to_string().contains('\0'), "{err}");
    let err = read_env_file(&write("n2.yml", b"name: \"a\\0b\"\n"), Subdir::Linux64).unwrap_err();
    assert!(err.r_message().is_ascii() && !err.r_message().contains('\0'), "{err}");
}

fn mambajs(platform: Subdir, text: &str) -> RtResult<EnvFile> {
    read_mambajs_lock(text.as_bytes(), "x.json", platform, &crate::channels::channel_config())
}

fn mambajs_text(packages: &str, pip: &str) -> String {
    format!(
        "{{\"lockVersion\": \"1.0.1\", \"platform\": \"linux-64\", \"channels\": [\"cA\", \"cB\"], \
         \"channelInfo\": {{\"cA\": [{{\"url\": \"file:///c/chA/\"}}, {{\"url\": \"https://mirror.example/chA\"}}], \
         \"cB\": [{{\"url\": \"https://example.org/chB\"}}]}}, \"packages\": {{{packages}}}, \"pipPackages\": {{{pip}}}}}"
    )
}

fn mambajs_pkg(file: &str, subdir: &str, channel: &str, hash: &str) -> String {
    let name = file.split('-').next().unwrap();
    format!(
        "\"{file}\": {{\"name\": \"{name}\", \"version\": \"1.0\", \"build\": \"0\", \"subdir\": \"{subdir}\", \
         \"channel\": \"{channel}\"{hash}}}"
    )
}

#[test]
fn mambajs_lock_files_follow_libmamba() {
    // micromamba m1: conda packages of the target platform and noarch, at
    // `<first channelInfo URL>/<subdir>/<file>`; the sha256 when given,
    // else the md5, else no hash; a channel that channelInfo does not list
    // is resolved as a -c argument.
    let packages = [
        mambajs_pkg("foo-1.0-0.tar.bz2", "noarch", "cA", &format!(", \"hash\": {{\"md5\": \"{MD5}\", \"sha256\": \"{SHA}\"}}")),
        mambajs_pkg("bar-1.0-0.conda", "linux-64", "cB", &format!(", \"hash\": {{\"md5\": \"{MD5}\"}}")),
        mambajs_pkg("mac-1.0-0.tar.bz2", "osx-arm64", "cA", ""),
        mambajs_pkg("cf-1.0-0.tar.bz2", "noarch", "conda-forge", ""),
    ]
    .join(", ");
    let pip = format!(
        "\"six-1.16.0-py2.py3-none-any.whl\": {{\"name\": \"six\", \"version\": \"1.16.0\", \"url\": \"https://p/six.whl\", \
         \"registry\": \"pypi\", \"hash\": {{\"sha256\": \"{SHA}\"}}}}, \
         \"attrs-1.0-py3-none-any.whl\": {{\"name\": \"attrs\", \"version\": \"1.0\", \"url\": \"https://p/attrs.whl\", \"registry\": \"pypi\"}}"
    );
    let f = mambajs(Subdir::Linux64, &mambajs_text(&packages, &pip)).unwrap();
    assert_eq!(f.kind, EnvFileKind::MambajsLock);
    assert_eq!(f.kind.name(), "mambajs_lock");
    assert_eq!(f.platforms, vec!["linux-64"]);
    // JSON objects in key order, as nlohmann reads them.
    assert_eq!(
        f.urls,
        vec![
            format!("https://example.org/chB/linux-64/bar-1.0-0.conda#{MD5}"),
            "https://conda.anaconda.org/conda-forge/noarch/cf-1.0-0.tar.bz2".to_string(),
            format!("file:///c/chA/noarch/foo-1.0-0.tar.bz2#{SHA}"),
        ]
    );
    // Every pip package, whatever the platform: one step without
    // dependencies (micromamba m1, an absent hash gives `#sha256=`).
    assert_eq!(
        pip_groups(&f),
        vec![(
            "pip --no-deps",
            vec!["attrs @ https://p/attrs.whl#sha256=", format!("six @ https://p/six.whl#sha256={SHA}").as_str()]
        )]
    );
    assert!(f.problems.is_empty());
    // The file's `platform` does not select: another target gets noarch
    // and its own subdir.
    let f = mambajs(Subdir::OsxArm64, &mambajs_text(&packages, "")).unwrap();
    assert_eq!(f.urls.len(), 3);
    assert!(f.urls.iter().any(|u| u.ends_with("/osx-arm64/mac-1.0-0.tar.bz2")), "{:?}", f.urls);
    assert!(f.pip.is_empty());
    let f = mambajs(Subdir::Win64, &mambajs_text(&mambajs_pkg("mac-1.0-0.tar.bz2", "osx-arm64", "cA", ""), "")).unwrap();
    assert!(f.urls.is_empty());
    assert_eq!(f.problems.len(), 1, "{:?}", f.problems);
}

#[test]
fn mambajs_lock_errors() {
    let ok = mambajs_pkg("foo-1.0-0.tar.bz2", "noarch", "cA", "");
    let err_of = |text: &str| mambajs(Subdir::Linux64, text).unwrap_err();
    // micromamba m2 to m5: no pipPackages, an empty hash, version 2.0.0.
    let no_pip = mambajs_text(&ok, "").replace(", \"pipPackages\": {}", "");
    assert_eq!(kind_of(&err_of(&no_pip)), "env_file");
    let empty_hash = mambajs_text(&mambajs_pkg("foo-1.0-0.tar.bz2", "noarch", "cA", ", \"hash\": {}"), "");
    let err = err_of(&empty_hash);
    assert!(err.to_string().contains("neither 'package.hash.md5' nor 'package.hash.sha256'"), "{err}");
    let err = err_of(&mambajs_text(&ok, "").replace("1.0.1", "2.0.0"));
    assert!(err.to_string().contains("unknown mambajs lock file version '2.0.0'"), "{err}");
    assert_eq!(kind_of(&err), "env_file");
    // channels and channelInfo must list the same names.
    let err = err_of(&mambajs_text(&ok, "").replace("[\"cA\", \"cB\"]", "[\"cA\"]"));
    assert!(err.to_string().contains("'cB' in 'channelInfo' not found"), "{err}");
    let err = err_of(&mambajs_text(&ok, "").replace("[\"cA\", \"cB\"]", "[\"cA\", \"cB\", \"cC\"]"));
    assert!(err.to_string().contains("'cC' in 'channels' list not found"), "{err}");
    for bad in [
        "not json".to_string(),
        "[]".to_string(),
        mambajs_text(&ok, "").replace("\"platform\": \"linux-64\"", "\"platform\": \"\""),
        mambajs_text(&ok.replace("\"build\": \"0\", ", ""), ""),
        mambajs_text(&ok, "\"x.whl\": {\"name\": \"x\", \"version\": \"1\", \"url\": \"https://p/x.whl\"}"),
    ] {
        assert_eq!(kind_of(&err_of(&bad)), "env_file", "{bad}");
    }
    // A hash no archive can match, and a wheel among the conda packages.
    let bad_hash = mambajs_text(&mambajs_pkg("foo-1.0-0.tar.bz2", "noarch", "cA", ", \"hash\": {\"md5\": \"ABC\"}"), "");
    assert_eq!(kind_of(&err_of(&bad_hash)), "hash_mismatch");
    let whl = mambajs_text(&mambajs_pkg("foo-1.0-py3-none-any.whl", "noarch", "cA", ""), "");
    assert_eq!(kind_of(&err_of(&whl)), "unsupported");
}

#[test]
fn pip_steps_run_in_the_directory_of_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let sub = dir.path().join("sub dir");
    std::fs::create_dir(&sub).unwrap();
    let yml = sub.join("env.yml");
    std::fs::write(&yml, "dependencies:\n  - pip:\n    - six\n").unwrap();
    let f = read_env_file(&yml, Subdir::Linux64).unwrap();
    assert_eq!(f.pip.len(), 1);
    assert_eq!(std::path::Path::new(&f.pip[0].cwd), sub.as_path());
    // A relative path is made absolute against the working directory, as
    // libmamba's `fs::absolute()` does.
    let rel = std::path::Path::new("some/where/env.yml");
    let want = std::env::current_dir().unwrap().join("some/where");
    assert_eq!(std::path::PathBuf::from(file_dir(rel).unwrap()), want);
    let json = sub.join("env.json");
    std::fs::write(&json, mambajs_text("", "\"x.whl\": {\"name\": \"x\", \"version\": \"1\", \"url\": \"https://p/x.whl\", \"registry\": \"pypi\"}")).unwrap();
    let f = read_env_file(&json, Subdir::Linux64).unwrap();
    assert_eq!(f.kind, EnvFileKind::MambajsLock);
    assert_eq!(std::path::Path::new(&f.pip[0].cwd), sub.as_path());
    let err = read_env_file(&dir.path().join("missing.yml"), Subdir::Linux64).unwrap_err();
    assert_eq!(kind_of(&err), "env_file");
}

#[test]
fn read_env_file_dispatches_on_the_name() {
    let dir = tempfile::tempdir().unwrap();
    let write = |name: &str, text: &str| {
        let p = dir.path().join(name);
        std::fs::write(&p, text).unwrap();
        p
    };
    let f = read_env_file(&write("e.yml", "dependencies:\n  - sel(win): baz\n  - sel(unix): foo\n"), Subdir::Win64).unwrap();
    // Selectors follow this library's platform, not the one asked for.
    let want = if cfg!(windows) { "baz" } else { "foo" };
    assert_eq!(f.specs, vec![want]);
    let f = read_env_file(&write("e.txt", "foo\n"), Subdir::Linux64).unwrap();
    assert_eq!(f.kind, EnvFileKind::Plain);
    let f = read_env_file(&write("e2.txt", "@EXPLICIT\n"), Subdir::Linux64).unwrap();
    assert_eq!(f.kind, EnvFileKind::Explicit);
}

#[test]
fn yaml_specs_parse_as_rattler_specs() {
    // A trailing comment, as micromamba's spec parser allows it.
    let specs = crate::install::parse_specs(&["foo  # trailing".to_string()]).unwrap();
    assert_eq!(specs[0].name.as_exact().unwrap().as_normalized(), "foo");
    assert_eq!(crate::history::update_spec_string("foo  # trailing"), "foo");
}
