//! Environment files, read the way `micromamba create -f` reads them
//! (micromamba 2.10.0: `libmamba/src/api/install.cpp` `file_specs_hook()`,
//! `read_yaml_file()`; `libmamba/src/core/env_lockfile_conda.cpp`,
//! `env_lockfile_mambajs.cpp`; `libmamba/src/core/transaction.cpp`
//! `create_explicit_transaction_from_lockfile()`).
//!
//! The kind comes from the file name, as micromamba decides it:
//!
//! 1. a name ending in `-lock.yml` or `-lock.yaml` is a conda-lock file;
//! 2. a name ending in `.json` is a mambajs lock file;
//! 3. a name ending in `.yml` or `.yaml` is an environment YAML file;
//! 4. anything else is a text file: an explicit file when one of its lines
//!    starts with `@EXPLICIT`, else a list of specs, one per line.
//!
//! The parsing follows micromamba's rules, including its quirks:
//!
//! - YAML `sel(...)` selectors are evaluated for the platform this library
//!   was built for, not for a requested `--platform`: micromamba reads the
//!   file before it applies `--platform` (checked with micromamba 2.10.0,
//!   `create --platform win-64 -f` with `sel(win)` and `sel(linux)`
//!   entries installs the `sel(linux)` package on Linux).
//! - YAML files are decoded as yaml-cpp decodes them: UTF-8, UTF-16 or
//!   UTF-32, detected from the first bytes, with or without a byte order
//!   mark (which is dropped).
//! - YAML scalars are taken as written (`1.50` stays `1.50`, `!!int 007`
//!   reads `007`: tags are ignored), and a null scalar reads as `null`, as
//!   yaml-cpp's `as<std::string>()` gives them.
//! - A top-level key given twice keeps its first value (yaml-cpp's
//!   `node[key]`), a variable given twice its last one (yaml-cpp's
//!   conversion to `std::map`). A top-level list is an empty environment; a
//!   single top-level value is an error.
//! - `${VAR}` and `$VAR` in YAML channels are expanded from the process
//!   environment (libmamba's `expandvars()`); an unset variable is kept as
//!   written.
//! - Text files are UTF-8: each line is trimmed of ASCII white space; blank
//!   lines and lines starting with `#` are dropped, and so are lines
//!   starting with `@` other than `@EXPLICIT`. A byte order mark stays in
//!   the first line, as micromamba keeps it (so a file that starts with one
//!   and then `@EXPLICIT` or `#` is a spec list whose first spec is wrong,
//!   in both); the spec parser drops it from a spec (`spectext.rs`). An empty
//!   text file is an error, and so is one with NUL bytes (UTF-16 text).
//! - A field that holds a NUL character (YAML's `\0` escape) is refused, as
//!   R strings cannot hold one (micromamba cuts the spec at the NUL).
//! - conda-lock files: version 1 only; the `conda` packages of category
//!   `main` whose platform is the target platform or `noarch`.
//! - mambajs lock files: `lockVersion` 1.0.x; the `packages` whose `subdir`
//!   is the target platform or `noarch` (whatever the file's `platform`),
//!   at `<channel>/<subdir>/<file name>`, where `<channel>` is the first
//!   `channelInfo` URL of the package's `channel`, or that channel resolved
//!   as a `-c` argument when `channelInfo` does not list it.
//!
//! pip packages are not installed here. [`EnvFile::pip`] holds the pip
//! steps micromamba runs after the create, so that the caller can run the
//! same ones: one per YAML `pip:` section, and one for the pip packages of
//! a lock file (see [`PipGroup`]). YAML `variables:` are read only to be
//! reported as not used: condathis runs micromamba with `--no-env`, which
//! does not use them either.
//!
//! What rattler does not support is an error of kind `unsupported`, which
//! condathis turns into `condathis_backend_unsupported`: wheels, source
//! archives and VCS URLs among the conda packages of a lock file.

use crate::activation::NATIVE_SUBDIR;
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use rattler_conda_types::Subdir;
use serde::de::{self, Deserializer, EnumAccess, IgnoredAny, MapAccess, SeqAccess, VariantAccess, Visitor};
use serde::Deserialize;

use crate::error::{RtError, RtResult};
use crate::explicit::parse_explicit_entry;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnvFileKind {
    Yaml,
    Explicit,
    Plain,
    CondaLock,
    MambajsLock,
}

impl EnvFileKind {
    pub fn name(self) -> &'static str {
        match self {
            EnvFileKind::Yaml => "yaml",
            EnvFileKind::Explicit => "explicit",
            EnvFileKind::Plain => "plain",
            EnvFileKind::CondaLock => "conda_lock",
            EnvFileKind::MambajsLock => "mambajs_lock",
        }
    }
}

/// The pip manager of a YAML `pip:` section (micromamba's `pip`, or `uv`
/// when the dependencies list `uv`).
pub const PIP: &str = "pip";
/// The pip manager of the pip packages of a lock file.
pub const PIP_NO_DEPS: &str = "pip --no-deps";
/// The manager of the `pip:` sections of a YAML file that lists `uv`.
pub const UV: &str = "uv";

/// A pip step of an environment file: what micromamba 2.10.0 runs after it
/// linked the Conda packages (libmamba's `install_for_other_pkgmgr()`;
/// checked with micromamba 2.10.0 run as condathis runs it, on Linux).
///
/// micromamba writes `specs`, each followed by `\n`, to a new file named
/// `mambaf` plus 10 random letters and digits (no extension) in `cwd`, and
/// runs one command in the activated environment (its activation script,
/// then the command; `cmd.exe /D /C` on Windows), with `cwd` as the
/// working directory and micromamba's own standard output and error:
///
/// - `pip`: `<python> -m pip install -r <file> --no-input`;
/// - `pip --no-deps`: `<python> -m pip install --no-deps -r <file> --no-input`;
/// - `uv`: `<uv> pip install -r <file>`.
///
/// `<python>` and `<uv>` are the absolute paths of the first `python` and
/// `uv` (`python.exe`, `uv.exe` on Windows) in the environment's
/// executable directories (`bin`; on Windows the prefix itself,
/// `Library/mingw-w64/bin`, `Library/usr/bin`, `Library/bin`, `Scripts`,
/// `bin`), or an empty word when there is none. pip's `--quiet` is never
/// added (only `--quiet` or `--json`, which condathis does not pass, add
/// it). The file is deleted afterwards. A command that does not exit with
/// status 0 fails the create ("pip failed to install packages"), after
/// the Conda packages were linked. The steps run in file order, once the
/// Conda transaction succeeded (also when it had nothing to do), each for
/// its own `specs`, even an empty one (`pip: []`), and never for a dry run.
#[derive(Clone, Debug, PartialEq)]
pub struct PipGroup {
    /// [`PIP`], [`PIP_NO_DEPS`] or [`UV`].
    pub manager: String,
    /// The requirement lines: a YAML section's entries as written, or
    /// `<name> @ <url>#sha256=<sha256>` per pip package of a lock file (the
    /// sha256 empty when the lock has none).
    pub specs: Vec<String>,
    /// The absolute directory of the environment file, as given (not
    /// resolved): pip's working directory, where the requirements file is
    /// written.
    pub cwd: String,
}

impl PipGroup {
    fn new(manager: &str, specs: Vec<String>) -> Self {
        PipGroup {
            manager: manager.to_string(),
            specs,
            cwd: String::new(),
        }
    }
}

/// What an environment file asks for.
#[derive(Clone, Debug, PartialEq)]
pub struct EnvFile {
    pub kind: EnvFileKind,
    /// The YAML `name:` (`None` when absent or null). condathis names the
    /// environment itself, so it is only informative.
    pub name: Option<String>,
    /// YAML channels, in file order, with environment variables expanded.
    /// `nodefaults` is kept (the channel normalization drops it).
    pub channels: Vec<String>,
    /// The specs of a YAML file (after selectors) or of a plain list.
    pub specs: Vec<String>,
    /// YAML `variables:`, sorted by name (byte order, as libmamba's
    /// `std::map`), values as written.
    pub variables: Vec<(String, String)>,
    /// The `# platform:` line of an explicit file.
    pub file_platform: Option<String>,
    /// Package URLs to install without a solve: the lines of an explicit
    /// file, or the selected packages of a lock file (`url#<sha256>`, or
    /// `url#<md5>` when the lock has no sha256).
    pub urls: Vec<String>,
    /// The platforms a lock file says it was resolved for (`metadata.platforms`).
    pub platforms: Vec<String>,
    /// Notes that do not stop the install (micromamba prints them as
    /// warnings).
    pub problems: Vec<String>,
    /// The pip steps micromamba runs after the create, in order.
    pub pip: Vec<PipGroup>,
}

impl EnvFile {
    fn new(kind: EnvFileKind) -> Self {
        EnvFile {
            kind,
            name: None,
            channels: Vec::new(),
            specs: Vec::new(),
            variables: Vec::new(),
            file_platform: None,
            urls: Vec::new(),
            platforms: Vec::new(),
            problems: Vec::new(),
            pip: Vec::new(),
        }
    }
}

/// The kind of an environment file by its name (micromamba's
/// `is_env_lockfile_name()` and `is_yaml_file_name()`; case sensitive).
pub fn classify(path: &str) -> EnvFileKind {
    if path.ends_with("-lock.yml") || path.ends_with("-lock.yaml") {
        EnvFileKind::CondaLock
    } else if path.ends_with(".json") {
        EnvFileKind::MambajsLock
    } else if path.ends_with(".yml") || path.ends_with(".yaml") {
        EnvFileKind::Yaml
    } else {
        // Explicit or plain, decided by the content.
        EnvFileKind::Plain
    }
}

fn env_file_error(path: &str, msg: impl fmt::Display) -> RtError {
    RtError::EnvFile(format!("cannot use the environment file {path}: {msg}"))
}

/// Reads and parses an environment file. `platform` selects the packages of
/// a lock file; YAML selectors always follow the platform this library was
/// built for (see the module docs). Nothing is downloaded or installed.
pub fn read_env_file(path: &Path, platform: Subdir) -> RtResult<EnvFile> {
    let shown = path.to_string_lossy().to_string();
    let kind = classify(&shown);
    let bytes = std::fs::read(path).map_err(|e| env_file_error(&shown, format!("cannot read it: {e}")))?;
    let mut file = match kind {
        EnvFileKind::Yaml => read_yaml(&yaml_text(&bytes), &shown, NATIVE_SUBDIR, &env_lookup),
        EnvFileKind::CondaLock => read_conda_lock(&yaml_text(&bytes), &shown, platform),
        EnvFileKind::MambajsLock => read_mambajs_lock(&bytes, &shown, platform, &crate::channels::channel_config()),
        _ => read_text(&plain_text(&bytes, &shown)?, &shown),
    }?;
    if !file.pip.is_empty() {
        let cwd = file_dir(path).map_err(|e| env_file_error(&shown, format!("cannot find its directory: {e}")))?;
        for group in &mut file.pip {
            group.cwd = cwd.clone();
        }
    }
    check_no_nul(&file, &shown)?;
    Ok(file)
}

/// The directory pip runs in for a file: libmamba's
/// `fs::absolute(file).parent_path()`, the absolute path of the file as
/// given (symbolic links are not resolved), without its last component.
fn file_dir(path: &Path) -> std::io::Result<String> {
    let absolute = std::path::absolute(path)?;
    let dir = absolute.parent().unwrap_or(&absolute);
    Ok(dir.to_string_lossy().to_string())
}

fn env_lookup(name: &str) -> Option<String> {
    std::env::var_os(name).map(|v| v.to_string_lossy().to_string())
}

// ---------------------------------------------------------------------------
// Encodings.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Encoding {
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
}

/// The encoding of a YAML stream from its first bytes, and the length of
/// its byte order mark: the table of the YAML specification (section 5.2),
/// which yaml-cpp follows, so micromamba reads UTF-16 and UTF-32 files with
/// or without a byte order mark.
fn detect_yaml_encoding(b: &[u8]) -> (Encoding, usize) {
    match b {
        [0, 0, 0xFE, 0xFF, ..] => (Encoding::Utf32Be, 4),
        [0, 0, 0, _, ..] => (Encoding::Utf32Be, 0),
        [0xFF, 0xFE, 0, 0, ..] => (Encoding::Utf32Le, 4),
        [_, 0, 0, 0, ..] => (Encoding::Utf32Le, 0),
        [0xFE, 0xFF, ..] => (Encoding::Utf16Be, 2),
        [0, _, ..] => (Encoding::Utf16Be, 0),
        [0xFF, 0xFE, ..] => (Encoding::Utf16Le, 2),
        [_, 0, ..] => (Encoding::Utf16Le, 0),
        [0xEF, 0xBB, 0xBF, ..] => (Encoding::Utf8, 3),
        _ => (Encoding::Utf8, 0),
    }
}

/// The text of a YAML file (an environment file or a conda-lock file) as
/// yaml-cpp decodes it: in the encoding [`detect_yaml_encoding()`] finds,
/// without the byte order mark, invalid sequences replaced. libyaml (which
/// rattler's YAML parser uses) would take a UTF-8 byte order mark for part of
/// the first key and silently drop the rest of the mapping.
fn yaml_text(bytes: &[u8]) -> String {
    let (encoding, bom) = detect_yaml_encoding(bytes);
    let body = &bytes[bom..];
    let units16 = |be: bool| {
        body.chunks(2).map(move |c| match c {
            [a, b] if be => u16::from_be_bytes([*a, *b]),
            [a, b] => u16::from_le_bytes([*a, *b]),
            // An odd trailing byte.
            _ => 0xFFFD,
        })
    };
    let text = match encoding {
        Encoding::Utf8 => String::from_utf8_lossy(body).into_owned(),
        Encoding::Utf16Le | Encoding::Utf16Be => {
            char::decode_utf16(units16(encoding == Encoding::Utf16Be))
                .map(|c| c.unwrap_or(char::REPLACEMENT_CHARACTER))
                .collect()
        }
        Encoding::Utf32Le | Encoding::Utf32Be => body
            .chunks(4)
            .map(|c| match c {
                [a, b, c2, d] => {
                    let v = if encoding == Encoding::Utf32Be {
                        u32::from_be_bytes([*a, *b, *c2, *d])
                    } else {
                        u32::from_le_bytes([*a, *b, *c2, *d])
                    };
                    char::from_u32(v).unwrap_or(char::REPLACEMENT_CHARACTER)
                }
                _ => char::REPLACEMENT_CHARACTER,
            })
            .collect(),
    };
    // A byte order mark spelled in another encoding than the one detected.
    match text.strip_prefix('\u{feff}') {
        Some(rest) => rest.to_string(),
        None => text,
    }
}

/// The text of an explicit file or a spec list: UTF-8 (invalid sequences
/// replaced), a byte order mark kept, as libmamba's `read_lines()` keeps it
/// (its spec parser then strips it from the first spec). A file with NUL
/// bytes, such as a UTF-16 file (which micromamba cannot use either), is
/// refused.
fn plain_text(bytes: &[u8], path: &str) -> RtResult<String> {
    if bytes.contains(&0) {
        let hint = if bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) {
            " (it is UTF-16 text; save it as UTF-8)"
        } else {
            ""
        };
        return Err(env_file_error(path, format!("it is not a text file: it has NUL bytes{hint}")));
    }
    Ok(String::from_utf8_lossy(bytes).into_owned())
}

/// Refuses a file whose fields hold a NUL character (YAML's `\0` escape):
/// R strings cannot hold one. micromamba cuts such a spec at the NUL.
fn check_no_nul(file: &EnvFile, path: &str) -> RtResult<()> {
    let mut texts = file
        .name
        .iter()
        .chain(&file.channels)
        .chain(&file.specs)
        .chain(&file.file_platform)
        .chain(&file.urls)
        .chain(&file.platforms)
        .chain(&file.problems)
        .chain(file.variables.iter().flat_map(|(k, v)| [k, v]))
        .chain(file.pip.iter().flat_map(|g| g.specs.iter().chain([&g.cwd])));
    match texts.find(|t| t.contains('\0')) {
        Some(text) => Err(env_file_error(
            path,
            format!("{text:?} has a NUL character (\\0), which R strings cannot hold"),
        )),
        None => Ok(()),
    }
}

// ---------------------------------------------------------------------------
// YAML scalars and nodes as yaml-cpp reads them.

/// A YAML scalar as yaml-cpp's `as<std::string>()` returns it: the text as
/// written (whatever its tag: `!!int 007` reads `007`), and `null` for a
/// null scalar. Anything else is an error.
#[derive(Clone, Debug, Default, PartialEq)]
struct RawText(String);

impl<'de> Deserialize<'de> for RawText {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct RawVisitor;
        impl<'de> Visitor<'de> for RawVisitor {
            type Value = RawText;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a scalar")
            }
            fn visit_none<E: de::Error>(self) -> Result<RawText, E> {
                Ok(RawText("null".to_string()))
            }
            fn visit_unit<E: de::Error>(self) -> Result<RawText, E> {
                Ok(RawText("null".to_string()))
            }
            fn visit_some<D2: Deserializer<'de>>(self, d: D2) -> Result<RawText, D2::Error> {
                // serde_yaml hands any scalar to a string as written, tags
                // ignored.
                String::deserialize(d).map(RawText)
            }
        }
        deserializer.deserialize_option(RawVisitor)
    }
}

/// A mapping entry that may be absent (`Missing`), as opposed to present and
/// null.
#[derive(Debug, Default)]
enum Field<T> {
    #[default]
    Missing,
    Present(T),
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Field<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        T::deserialize(deserializer).map(Field::Present)
    }
}

impl<T> Field<T> {
    fn present(self) -> Option<T> {
        match self {
            Field::Missing => None,
            Field::Present(v) => Some(v),
        }
    }
}

/// A YAML node, read whatever its shape (custom tags such as `!foo` are
/// ignored, as yaml-cpp ignores them). Scalars carry the text rattler's
/// parser resolved them to (`1.50` reads `1.5`): only used where the text of
/// a number does not matter.
#[derive(Clone, Debug, PartialEq)]
enum Node {
    Null,
    Text(String),
    Seq(Vec<Node>),
    Map(Vec<(Node, Node)>),
}

impl Node {
    fn text(&self) -> Option<&str> {
        match self {
            Node::Text(t) => Some(t),
            _ => None,
        }
    }

    /// yaml-cpp's scalar text of the node (`null` for a null).
    fn scalar_text(&self) -> Option<String> {
        match self {
            Node::Null => Some("null".to_string()),
            Node::Text(t) => Some(t.clone()),
            Node::Seq(_) | Node::Map(_) => None,
        }
    }
}

struct NodeVisitor;

impl<'de> Visitor<'de> for NodeVisitor {
    type Value = Node;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a YAML node")
    }
    fn visit_bool<E: de::Error>(self, v: bool) -> Result<Node, E> {
        Ok(Node::Text(v.to_string()))
    }
    fn visit_i64<E: de::Error>(self, v: i64) -> Result<Node, E> {
        Ok(Node::Text(v.to_string()))
    }
    fn visit_u64<E: de::Error>(self, v: u64) -> Result<Node, E> {
        Ok(Node::Text(v.to_string()))
    }
    fn visit_f64<E: de::Error>(self, v: f64) -> Result<Node, E> {
        Ok(Node::Text(v.to_string()))
    }
    fn visit_str<E: de::Error>(self, v: &str) -> Result<Node, E> {
        Ok(Node::Text(v.to_string()))
    }
    fn visit_string<E: de::Error>(self, v: String) -> Result<Node, E> {
        Ok(Node::Text(v))
    }
    fn visit_none<E: de::Error>(self) -> Result<Node, E> {
        Ok(Node::Null)
    }
    fn visit_unit<E: de::Error>(self) -> Result<Node, E> {
        Ok(Node::Null)
    }
    fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<Node, D::Error> {
        Node::deserialize(d)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Node, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = seq.next_element::<Node>()? {
            items.push(item);
        }
        Ok(Node::Seq(items))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Node, A::Error> {
        let mut entries = Vec::new();
        while let Some((k, v)) = map.next_entry::<Node, Node>()? {
            entries.push((k, v));
        }
        Ok(Node::Map(entries))
    }
    fn visit_enum<A: EnumAccess<'de>>(self, data: A) -> Result<Node, A::Error> {
        // A custom tag (`!foo value`): the value.
        let (_tag, variant) = data.variant::<IgnoredAny>()?;
        variant.newtype_variant::<Node>()
    }
}

impl<'de> Deserialize<'de> for Node {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(NodeVisitor)
    }
}

/// The `channels` of an environment file: a list of scalars, as written.
struct RawList(Vec<RawText>);

impl<'de> Deserialize<'de> for RawList {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ListVisitor;
        impl<'de> Visitor<'de> for ListVisitor {
            type Value = RawList;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a list of strings")
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<RawList, A::Error> {
                let mut items = Vec::new();
                while let Some(item) = seq.next_element::<RawText>()? {
                    items.push(item);
                }
                Ok(RawList(items))
            }
            fn visit_enum<A: EnumAccess<'de>>(self, data: A) -> Result<RawList, A::Error> {
                let (_tag, variant) = data.variant::<IgnoredAny>()?;
                variant.newtype_variant::<RawList>()
            }
        }
        deserializer.deserialize_any(ListVisitor)
    }
}

/// The `variables` of an environment file: a mapping of scalars, as
/// written; a name given twice keeps its last value, as yaml-cpp's
/// conversion to `std::map` keeps it.
struct RawVars(BTreeMap<String, String>);

impl<'de> Deserialize<'de> for RawVars {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct VarsVisitor;
        impl<'de> Visitor<'de> for VarsVisitor {
            type Value = RawVars;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a mapping of names to strings")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<RawVars, A::Error> {
                let mut vars = BTreeMap::new();
                while let Some((k, v)) = map.next_entry::<RawText, RawText>()? {
                    vars.insert(k.0, v.0);
                }
                Ok(RawVars(vars))
            }
            fn visit_enum<A: EnumAccess<'de>>(self, data: A) -> Result<RawVars, A::Error> {
                let (_tag, variant) = data.variant::<IgnoredAny>()?;
                variant.newtype_variant::<RawVars>()
            }
        }
        deserializer.deserialize_any(VarsVisitor)
    }
}

/// The parts of an environment file micromamba reads. A top-level key
/// given twice keeps its first value, as yaml-cpp's `node[key]` finds it.
#[derive(Default)]
struct YamlEnv {
    name: Option<RawText>,
    channels: Option<RawList>,
    dependencies: Option<Node>,
    variables: Option<RawVars>,
}

/// The first document of an environment file.
enum YamlTop {
    /// A mapping.
    Env(YamlEnv),
    /// Empty, null, or a sequence (micromamba creates an empty environment
    /// for a top-level list).
    Empty,
    /// A single scalar, which micromamba refuses.
    Scalar,
}

impl<'de> Deserialize<'de> for YamlTop {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct TopVisitor;
        impl<'de> Visitor<'de> for TopVisitor {
            type Value = YamlTop;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("an environment file")
            }
            fn visit_bool<E: de::Error>(self, _: bool) -> Result<YamlTop, E> {
                Ok(YamlTop::Scalar)
            }
            fn visit_i64<E: de::Error>(self, _: i64) -> Result<YamlTop, E> {
                Ok(YamlTop::Scalar)
            }
            fn visit_u64<E: de::Error>(self, _: u64) -> Result<YamlTop, E> {
                Ok(YamlTop::Scalar)
            }
            fn visit_f64<E: de::Error>(self, _: f64) -> Result<YamlTop, E> {
                Ok(YamlTop::Scalar)
            }
            fn visit_str<E: de::Error>(self, _: &str) -> Result<YamlTop, E> {
                Ok(YamlTop::Scalar)
            }
            fn visit_none<E: de::Error>(self) -> Result<YamlTop, E> {
                Ok(YamlTop::Empty)
            }
            fn visit_unit<E: de::Error>(self) -> Result<YamlTop, E> {
                Ok(YamlTop::Empty)
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<YamlTop, A::Error> {
                while seq.next_element::<IgnoredAny>()?.is_some() {}
                Ok(YamlTop::Empty)
            }
            fn visit_enum<A: EnumAccess<'de>>(self, data: A) -> Result<YamlTop, A::Error> {
                let (_tag, variant) = data.variant::<IgnoredAny>()?;
                variant.newtype_variant::<YamlTop>()
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<YamlTop, A::Error> {
                let mut env = YamlEnv::default();
                while let Some(key) = map.next_key::<Node>()? {
                    let shape = |what: &str| {
                        let what = what.to_string();
                        move |_: A::Error| <A::Error as de::Error>::custom(format!("could not read {what}"))
                    };
                    match key.text() {
                        Some("name") if env.name.is_none() => {
                            env.name = Some(map.next_value::<RawText>().map_err(shape("'name' as a string"))?);
                        }
                        Some("channels") if env.channels.is_none() => {
                            env.channels =
                                Some(map.next_value::<RawList>().map_err(shape("'channels' as a list of strings"))?);
                        }
                        Some("dependencies") if env.dependencies.is_none() => {
                            env.dependencies = Some(map.next_value::<Node>()?);
                        }
                        Some("variables") if env.variables.is_none() => {
                            env.variables = Some(
                                map.next_value::<RawVars>()
                                    .map_err(shape("'variables' as a mapping of names to strings"))?,
                            );
                        }
                        _ => {
                            map.next_value::<IgnoredAny>()?;
                        }
                    }
                }
                Ok(YamlTop::Env(env))
            }
        }
        deserializer.deserialize_any(TopVisitor)
    }
}

/// The first document of `text` (yaml-cpp's `LoadFile()` reads only the
/// first one), deserialized as `T`; `None` for an empty file.
fn first_document<T: for<'de> Deserialize<'de>>(text: &str) -> Result<Option<T>, serde_yaml::Error> {
    match serde_yaml::Deserializer::from_str(text).next() {
        None => Ok(None),
        Some(doc) => T::deserialize(doc).map(Some),
    }
}

// ---------------------------------------------------------------------------
// Environment YAML files.

/// libmamba's `eval_selector()`: `sel(win)`, `sel(unix)`, `sel(osx)` or
/// `sel(linux)`, true when it names `platform`'s family.
pub fn eval_selector(selector: &str, platform: Subdir) -> Result<bool, String> {
    if !(selector.starts_with("sel(") && selector.ends_with(')')) || selector.len() < 5 {
        return Err("Couldn't parse selector. Needs to start with sel( and end with )".to_string());
    }
    let expr = &selector[4..selector.len() - 1];
    let p = platform.as_str();
    let win = p.starts_with("win");
    let value = match expr {
        "win" => win,
        "unix" => !win,
        "linux" => !win && p.starts_with("linux"),
        "osx" => !win && p.starts_with("osx"),
        _ => {
            return Err(
                "Couldn't parse selector. Value not in [unix, linux, osx, win] or additional \
                 whitespaces found."
                    .to_string(),
            )
        }
    };
    Ok(value)
}

/// libmamba's `expandvars()`: replaces `${NAME}` and `$NAME` (`NAME` of
/// letters, digits and `_`) by the variable's value when it is set, and
/// leaves it as written when it is not. After each replacement the search
/// starts again from the beginning, as libmamba's does; a value that keeps
/// referring to itself stops after a fixed number of rounds.
pub fn expandvars(input: &str, lookup: &dyn Fn(&str) -> Option<String>) -> String {
    const MAX_ROUNDS: usize = 256;
    let mut s = input.to_string();
    for _ in 0..MAX_ROUNDS {
        if !s.contains('$') {
            return s;
        }
        match find_defined_var(&s, lookup) {
            Some((start, end, value)) => s.replace_range(start..end, &value),
            None => return s,
        }
    }
    s
}

fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// The first match of `\$(\{\w+\}|\w+)` whose variable is set.
fn find_defined_var(s: &str, lookup: &dyn Fn(&str) -> Option<String>) -> Option<(usize, usize, String)> {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'$' {
            i += 1;
            continue;
        }
        let (name_start, name_end, end) = if b.get(i + 1) == Some(&b'{') {
            let mut j = i + 2;
            while j < b.len() && is_word(b[j]) {
                j += 1;
            }
            if j > i + 2 && b.get(j) == Some(&b'}') {
                (i + 2, j, j + 1)
            } else {
                i += 1;
                continue;
            }
        } else {
            let mut j = i + 1;
            while j < b.len() && is_word(b[j]) {
                j += 1;
            }
            if j > i + 1 {
                (i + 1, j, j)
            } else {
                i += 1;
                continue;
            }
        };
        if let Some(value) = lookup(&s[name_start..name_end]) {
            return Some((i, end, value));
        }
        i = end;
    }
    None
}

fn read_yaml(
    text: &str,
    path: &str,
    selector_platform: Subdir,
    lookup: &dyn Fn(&str) -> Option<String>,
) -> RtResult<EnvFile> {
    let mut out = EnvFile::new(EnvFileKind::Yaml);
    let top: Option<YamlTop> =
        first_document(text).map_err(|e| env_file_error(path, format!("invalid YAML: {e}")))?;
    let env = match top {
        None | Some(YamlTop::Empty) => return Ok(out),
        Some(YamlTop::Scalar) => {
            return Err(env_file_error(
                path,
                "the file is a single value, not a mapping (micromamba: \"operator[] call on a \
                 scalar\")",
            ))
        }
        Some(YamlTop::Env(env)) => env,
    };

    // dependencies: a non-empty sequence, else none at all.
    let mut pip: Vec<PipGroup> = Vec::new();
    if let Some(Node::Seq(items)) = &env.dependencies {
        for item in items {
            match item {
                Node::Null | Node::Seq(_) => {}
                Node::Text(spec) => out.specs.push(spec.clone()),
                Node::Map(entries) => {
                    for (key, value) in entries {
                        let key = key.scalar_text().ok_or_else(|| {
                            env_file_error(path, "a dependency mapping has a key that is not a scalar")
                        })?;
                        if key.starts_with("sel(") {
                            let selected =
                                eval_selector(&key, selector_platform).map_err(|e| env_file_error(path, e))?;
                            if selected {
                                match value {
                                    Node::Text(spec) => out.specs.push(spec.clone()),
                                    _ => {
                                        return Err(env_file_error(
                                            path,
                                            format!(
                                                "the selected entry {key} is not a single spec \
                                                 (micromamba: \"Complicated selection merge not \
                                                 implemented yet.\")"
                                            ),
                                        ))
                                    }
                                }
                            }
                        } else if key == "pip" {
                            // One pip step per section, even an empty one.
                            match value {
                                Node::Seq(specs) => {
                                    let mut group = Vec::with_capacity(specs.len());
                                    for spec in specs {
                                        group.push(spec.scalar_text().ok_or_else(|| {
                                            env_file_error(path, "the pip section has an entry that is not a string")
                                        })?);
                                    }
                                    pip.push(PipGroup::new(PIP, group));
                                }
                                _ => {
                                    return Err(env_file_error(path, "the pip section is not a list of strings"))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    out.name = env.name.map(|t| t.0).filter(|n| n != "null");
    out.channels = env
        .channels
        .map(|l| l.0)
        .unwrap_or_default()
        .into_iter()
        .map(|c| expandvars(&c.0, lookup))
        .collect();
    out.variables = env.variables.map(|v| v.0).unwrap_or_default().into_iter().collect();

    // libmamba (with `use_uv` off, as condathis's configuration leaves it):
    // when the dependencies name `uv` exactly, every section is installed
    // with uv and nothing is added; otherwise `pip` is added to the specs
    // unless they name it exactly.
    if !pip.is_empty() {
        if out.specs.iter().any(|s| s == UV) {
            for group in &mut pip {
                group.manager = UV.to_string();
            }
        } else if !out.specs.iter().any(|s| s == PIP) {
            out.specs.push(PIP.to_string());
        }
    }
    out.pip = pip;
    Ok(out)
}

// ---------------------------------------------------------------------------
// Text files: explicit files and spec lists.

const WHITESPACE: &[char] = &[' ', '\t', '\n', '\x0b', '\x0c', '\r'];

/// libmamba's `read_lines()`: trimmed lines without blank lines, `#`
/// comments and `@` lines other than `@EXPLICIT`.
fn read_lines(text: &str) -> Vec<String> {
    text.split('\n')
        .filter_map(|line| {
            let line = line.strip_suffix('\r').unwrap_or(line).trim_matches(WHITESPACE);
            if line.is_empty() || line.starts_with('#') {
                None
            } else if line.starts_with('@') {
                line.starts_with("@EXPLICIT").then(|| line.to_string())
            } else {
                Some(line.to_string())
            }
        })
        .collect()
}

fn read_text(text: &str, path: &str) -> RtResult<EnvFile> {
    let lines = read_lines(text);
    if lines.is_empty() {
        return Err(env_file_error(path, "the file is empty (micromamba: \"Got an empty file\")"));
    }
    match lines.iter().position(|l| l.starts_with("@EXPLICIT")) {
        Some(at) => {
            let mut out = EnvFile::new(EnvFileKind::Explicit);
            out.urls = lines[at + 1..].to_vec();
            // The `# platform:` line conda writes above `@EXPLICIT`.
            for raw in text.split('\n') {
                let raw = raw.strip_suffix('\r').unwrap_or(raw).trim_matches(WHITESPACE);
                if raw.starts_with("@EXPLICIT") {
                    break;
                }
                if let Some(p) = raw.strip_prefix("# platform: ") {
                    out.file_platform = Some(p.trim_matches(WHITESPACE).to_string());
                    break;
                }
            }
            Ok(out)
        }
        None => {
            let mut out = EnvFile::new(EnvFileKind::Plain);
            out.specs = lines;
            Ok(out)
        }
    }
}

// ---------------------------------------------------------------------------
// conda-lock files (version 1, the format micromamba reads).

#[derive(Deserialize, Default)]
struct LockDoc {
    #[serde(default)]
    version: Field<RawText>,
    #[serde(default)]
    metadata: Field<Option<LockMeta>>,
    #[serde(default)]
    package: Field<Option<Vec<LockPkg>>>,
}

#[derive(Deserialize, Default)]
struct LockMeta {
    #[serde(default)]
    platforms: Field<Option<Vec<RawText>>>,
    #[serde(default)]
    sources: Field<Option<Vec<RawText>>>,
    #[serde(default)]
    channels: Field<Option<Vec<LockChannel>>>,
    #[serde(default)]
    content_hash: Field<Option<BTreeMap<String, RawText>>>,
}

#[derive(Deserialize, Default)]
struct LockChannel {
    #[serde(default)]
    url: Field<RawText>,
    #[serde(default)]
    used_env_vars: Field<Vec<RawText>>,
}

#[derive(Deserialize, Default)]
struct LockPkg {
    #[serde(default)]
    name: Field<RawText>,
    #[serde(default)]
    version: Field<RawText>,
    #[serde(default)]
    manager: Field<RawText>,
    #[serde(default)]
    platform: Field<RawText>,
    #[serde(default)]
    category: Field<RawText>,
    #[serde(default)]
    url: Field<RawText>,
    #[serde(default)]
    hash: Field<Option<LockHash>>,
}

#[derive(Deserialize, Default)]
struct LockHash {
    #[serde(default)]
    md5: Field<RawText>,
    #[serde(default)]
    sha256: Field<RawText>,
}

struct LockEntry {
    name: String,
    manager: String,
    platform: String,
    category: String,
    url: String,
    md5: Option<String>,
    sha256: Option<String>,
}

fn required(field: Field<RawText>, what: &str, path: &str) -> RtResult<String> {
    field
        .present()
        .map(|t| t.0)
        .ok_or_else(|| env_file_error(path, format!("a package has no '{what}'")))
}

fn read_conda_lock(text: &str, path: &str, platform: Subdir) -> RtResult<EnvFile> {
    let doc: LockDoc = first_document(text)
        .map_err(|e| env_file_error(path, format!("invalid lock file: {e}")))?
        .unwrap_or_default();
    let version = doc
        .version
        .present()
        .ok_or_else(|| env_file_error(path, "the lock file has no 'version'"))?;
    match version.0.trim().parse::<i64>() {
        Ok(1) => {}
        Ok(v) => {
            return Err(env_file_error(
                path,
                format!("unknown lock file version '{v}' (micromamba reads version 1)"),
            ))
        }
        Err(_) => return Err(env_file_error(path, format!("invalid lock file version '{}'", version.0))),
    }
    let meta = doc.metadata.present().flatten().unwrap_or_default();
    let platforms: Vec<String> = meta.platforms.present().flatten().unwrap_or_default().into_iter().map(|t| t.0).collect();
    if platforms.is_empty() {
        return Err(env_file_error(path, "at least one 'metadata.platforms' entry must be specified"));
    }
    if meta.sources.present().flatten().unwrap_or_default().is_empty() {
        return Err(env_file_error(path, "at least one 'metadata.sources' entry must be specified"));
    }
    for channel in meta.channels.present().flatten().unwrap_or_default() {
        if channel.url.present().is_none() || channel.used_env_vars.present().is_none() {
            return Err(env_file_error(path, "every 'metadata.channels' entry needs 'url' and 'used_env_vars'"));
        }
    }
    if meta.content_hash.present().flatten().unwrap_or_default().is_empty() {
        return Err(env_file_error(path, "at least one 'metadata.content_hash' entry must be specified"));
    }

    let mut entries = Vec::new();
    for pkg in doc.package.present().flatten().unwrap_or_default() {
        let name = required(pkg.name, "name", path)?;
        let manager = required(pkg.manager, "manager", path)?;
        let pkg_platform = required(pkg.platform, "platform", path)?;
        required(pkg.version, "version", path)?;
        let category = pkg.category.present().map_or_else(|| "main".to_string(), |t| t.0);
        let hash = pkg
            .hash
            .present()
            .ok_or_else(|| env_file_error(path, format!("package {name} has no 'hash'")))?
            .unwrap_or_default();
        let md5 = hash.md5.present().map(|t| t.0).filter(|s| !s.is_empty());
        let sha256 = hash.sha256.present().map(|t| t.0).filter(|s| !s.is_empty());
        if md5.is_none() && sha256.is_none() {
            return Err(env_file_error(
                path,
                format!("package {name}: either 'hash.md5' or 'hash.sha256' must be specified"),
            ));
        }
        let url = required(pkg.url, "url", path)?;
        // micromamba parses every URL, pip ones included.
        crate::explicit::check_package_url(&url).map_err(|e| env_file_error(path, e))?;
        entries.push(LockEntry {
            name,
            manager,
            platform: pkg_platform,
            category,
            url,
            md5,
            sha256,
        });
    }

    let target = platform.as_str();
    let on_target = |p: &str| p == target || p == "noarch";
    let mut out = EnvFile::new(EnvFileKind::CondaLock);
    out.platforms = platforms;
    // libmamba also takes a pip package without a platform.
    let pip = entries
        .iter()
        .filter(|e| e.manager == "pip" && e.category == "main" && (on_target(&e.platform) || e.platform.is_empty()))
        .map(|e| pip_lock_spec(&e.name, &e.url, e.sha256.as_deref()));
    out.pip = pip_lock_group(pip);
    for entry in entries
        .iter()
        .filter(|e| e.manager == "conda" && e.category == "main" && on_target(&e.platform))
    {
        // The explicit installer checks every URL again; checking here gives
        // the error while nothing has started.
        parse_explicit_entry(&entry.url).map_err(|e| match e {
            RtError::EnvFile(msg) => env_file_error(path, msg),
            RtError::Unsupported(msg) => RtError::Unsupported(format!("the lock file {path}: {msg}")),
            other => other,
        })?;
        let hash = lock_hash(entry, path)?;
        let url = format!("{}#{hash}", entry.url);
        if !out.urls.contains(&url) {
            out.urls.push(url);
        }
    }
    if out.urls.is_empty() {
        out.problems.push(format!(
            "the lock file has no conda packages of category main for {target}"
        ));
    }
    Ok(out)
}

/// The hash micromamba checks a lock file's package against: its sha256
/// when the lock gives one, else its md5 (`PackageFetcher::validate()`),
/// compared as text with the lower-case hex digest of the archive. A hash
/// that cannot be such a digest (wrong length, not hex, upper-case digits)
/// matches no archive, so micromamba refuses the package after downloading
/// it ("tarball has incorrect SHA256"); rattlerthis refuses it here, with
/// kind `hash_mismatch`.
fn lock_hash<'a>(entry: &'a LockEntry, path: &str) -> RtResult<&'a str> {
    let (kind, hash, len) = match (&entry.sha256, &entry.md5) {
        (Some(sha256), _) => ("SHA256", sha256.as_str(), 64),
        (None, Some(md5)) => ("MD5", md5.as_str(), 32),
        (None, None) => unreachable!("checked when the lock was read"),
    };
    let digest = hash.len() == len && hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    if digest {
        Ok(hash)
    } else {
        Err(RtError::HashMismatch(format!(
            "the lock file {path} gives the {kind} {hash:?} for {}, which no archive matches: \
             micromamba compares it with the archive's {kind} as {len} lower-case hex digits \
             (micromamba: \"tarball has incorrect {kind}\")",
            entry.url
        )))
    }
}

/// The requirement line of a pip package of a lock file, as libmamba writes
/// it: `<name> @ <url>#sha256=<sha256>` (the sha256 empty when the lock has
/// none; pip then checks no hash).
fn pip_lock_spec(name: &str, url: &str, sha256: Option<&str>) -> String {
    format!("{name} @ {url}#sha256={}", sha256.unwrap_or(""))
}

/// The pip step of a lock file's pip packages: none without any. libmamba
/// collects them in a hash set, so a line given twice is written once (and
/// the order is the set's, which pip does not depend on with `--no-deps`;
/// this keeps the file's order).
fn pip_lock_group(specs: impl Iterator<Item = String>) -> Vec<PipGroup> {
    let mut unique: Vec<String> = Vec::new();
    for spec in specs {
        if !unique.contains(&spec) {
            unique.push(spec);
        }
    }
    if unique.is_empty() {
        Vec::new()
    } else {
        vec![PipGroup::new(PIP_NO_DEPS, unique)]
    }
}

// ---------------------------------------------------------------------------
// mambajs lock files (`lockVersion` 1.0.x, the format micromamba reads).

fn json_error(path: &str, msg: impl fmt::Display) -> RtError {
    env_file_error(path, format!("invalid mambajs lock file: {msg}"))
}

/// A required string field of a JSON object (nlohmann's `get<std::string>()`
/// fails for anything else).
fn json_str<'a>(value: &'a serde_json::Value, key: &str, what: &str, path: &str) -> RtResult<&'a str> {
    value
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| json_error(path, format!("{what} needs '{key}' as a string")))
}

/// The entries of a required JSON object, in key order, as nlohmann's
/// `items()` gives them (`serde_json` may keep the file's order).
fn json_object<'a>(
    value: &'a serde_json::Value,
    key: &str,
    path: &str,
) -> RtResult<Vec<(&'a String, &'a serde_json::Value)>> {
    let object = value
        .get(key)
        .and_then(|v| v.as_object())
        .ok_or_else(|| json_error(path, format!("'{key}' must be an object")))?;
    let mut entries: Vec<(&String, &serde_json::Value)> = object.iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    Ok(entries)
}

/// The `md5` and `sha256` of a mambajs package: an absent `hash` gives
/// none; a `hash` without either (or with both empty) is an error, as in
/// libmamba.
fn mambajs_hash(value: &serde_json::Value, name: &str, path: &str) -> RtResult<(String, String)> {
    let Some(hash) = value.get("hash") else {
        return Ok((String::new(), String::new()));
    };
    let field = |key: &str| -> RtResult<String> {
        match hash.get(key) {
            None => Ok(String::new()),
            Some(v) => v
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| json_error(path, format!("package {name}: 'hash.{key}' must be a string"))),
        }
    };
    let (md5, sha256) = (field("md5")?, field("sha256")?);
    if md5.is_empty() && sha256.is_empty() {
        return Err(json_error(
            path,
            format!(
                "package {name}: 'package.hash' provided but neither 'package.hash.md5' nor \
                 'package.hash.sha256' was found"
            ),
        ));
    }
    Ok((md5, sha256))
}

/// The URL of a mambajs `channel`: the first URL `channelInfo` gives for it,
/// else the channel resolved as micromamba resolves a `-c` argument (a name
/// through the channel alias, a URL or a path as it is), without a trailing
/// slash.
fn mambajs_channel_url(
    channel: &str,
    info: &BTreeMap<String, Vec<String>>,
    cfg: &rattler_conda_types::ChannelConfig,
    path: &str,
) -> RtResult<String> {
    let raw = match info.get(channel).and_then(|urls| urls.first()) {
        Some(url) => url.clone(),
        None => channel.to_string(),
    };
    let resolved = crate::channels::effective_channels(std::slice::from_ref(&raw), &[], cfg)
        .map_err(|e| json_error(path, format!("channel {channel:?}: {e}")))?;
    match resolved.first() {
        Some(first) => Ok(crate::channels::channel_url_string(first)),
        None => Err(json_error(path, format!("channel {channel:?} names no channel"))),
    }
}

/// Reads a mambajs lock file as libmamba 2.10 does
/// (`read_mambajs_environment_lockfile()`): `lockVersion` 1.0.x, a
/// non-empty `platform`, `channels` and `channelInfo` that list the same
/// names, and the `packages` and `pipPackages` objects (both required),
/// keyed by file name. The conda packages of `platform` and `noarch` become
/// URLs (`url#<sha256>`, `url#<md5>`, or the bare URL when the file gives
/// no hash), and every pip package a line of the pip step (category
/// `main`, no platform: libmamba takes them all).
fn read_mambajs_lock(
    bytes: &[u8],
    path: &str,
    platform: Subdir,
    cfg: &rattler_conda_types::ChannelConfig,
) -> RtResult<EnvFile> {
    let doc: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| json_error(path, e))?;
    if !doc.is_object() {
        return Err(json_error(path, "the file is not a JSON object"));
    }
    let version = json_str(&doc, "lockVersion", "the file", path)?;
    if !version.starts_with("1.0.") {
        return Err(env_file_error(
            path,
            format!("unknown mambajs lock file version '{version}' (micromamba reads 1.0.x)"),
        ));
    }
    let lock_platform = json_str(&doc, "platform", "the file", path)?;
    if lock_platform.is_empty() {
        return Err(json_error(path, "a `platform` must be specified, found empty value"));
    }
    let names: Vec<String> = match doc.get("channels").and_then(|v| v.as_array()) {
        Some(items) => items
            .iter()
            .map(|v| v.as_str().map(str::to_string))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| json_error(path, "'channels' must be a list of strings"))?,
        None => return Err(json_error(path, "'channels' must be a list of strings")),
    };
    let mut info: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (name, specs) in json_object(&doc, "channelInfo", path)? {
        if !names.contains(name) {
            return Err(json_error(
                path,
                format!("channel '{name}' in 'channelInfo' not found in 'channels' list"),
            ));
        }
        let specs = specs
            .as_array()
            .ok_or_else(|| json_error(path, format!("'channelInfo.{name}' must be a list")))?;
        let mut urls = Vec::with_capacity(specs.len());
        for spec in specs {
            urls.push(json_str(spec, "url", &format!("every 'channelInfo.{name}' entry"), path)?.to_string());
        }
        info.insert(name.clone(), urls);
    }
    if let Some(missing) = names.iter().find(|n| !info.contains_key(*n)) {
        return Err(json_error(
            path,
            format!("channel '{missing}' in 'channels' list not found in 'channelInfo' list"),
        ));
    }

    let target = platform.as_str();
    let mut out = EnvFile::new(EnvFileKind::MambajsLock);
    out.platforms = vec![lock_platform.to_string()];
    for (file_name, pkg) in json_object(&doc, "packages", path)? {
        let what = format!("package {file_name}");
        let name = json_str(pkg, "name", &what, path)?;
        json_str(pkg, "version", &what, path)?;
        json_str(pkg, "build", &what, path)?;
        let subdir = json_str(pkg, "subdir", &what, path)?;
        let channel = json_str(pkg, "channel", &what, path)?;
        let (md5, sha256) = mambajs_hash(pkg, name, path)?;
        if subdir != target && subdir != "noarch" {
            continue;
        }
        let base = format!("{}/{subdir}/{file_name}", mambajs_channel_url(channel, &info, cfg, path)?);
        parse_explicit_entry(&base).map_err(|e| match e {
            RtError::EnvFile(msg) => env_file_error(path, msg),
            RtError::Unsupported(msg) => RtError::Unsupported(format!("the lock file {path}: {msg}")),
            other => other,
        })?;
        let entry = LockEntry {
            name: name.to_string(),
            manager: "conda".to_string(),
            platform: subdir.to_string(),
            category: "main".to_string(),
            url: base.clone(),
            md5: Some(md5).filter(|h| !h.is_empty()),
            sha256: Some(sha256).filter(|h| !h.is_empty()),
        };
        let url = if entry.md5.is_none() && entry.sha256.is_none() {
            base
        } else {
            format!("{base}#{}", lock_hash(&entry, path)?)
        };
        if !out.urls.contains(&url) {
            out.urls.push(url);
        }
    }
    let mut pip = Vec::new();
    for (file_name, pkg) in json_object(&doc, "pipPackages", path)? {
        let what = format!("pip package {file_name}");
        let name = json_str(pkg, "name", &what, path)?;
        json_str(pkg, "version", &what, path)?;
        let url = json_str(pkg, "url", &what, path)?;
        json_str(pkg, "registry", &what, path)?;
        let (_md5, sha256) = mambajs_hash(pkg, name, path)?;
        pip.push(pip_lock_spec(name, url, Some(&sha256)));
    }
    out.pip = pip_lock_group(pip.into_iter());
    if out.urls.is_empty() {
        out.problems.push(format!(
            "the lock file has no conda packages of category main for {target}"
        ));
    }
    Ok(out)
}

#[cfg(test)]
mod tests;
