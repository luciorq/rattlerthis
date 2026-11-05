//! The text of a spec as libmamba's `MatchSpec::parse()` and
//! `PackageInfo::from_url()` see it (micromamba 2.10.0,
//! `libmamba/src/specs/match_spec.cpp`, `package_info.cpp`), before rattler
//! parses it.
//!
//! - Everything after `" #"` (a space, then `#`) is a comment.
//! - The text is stripped with libmamba's `util::strip()`, which removes the
//!   leading and trailing bytes for which `std::isgraph()` is false in
//!   micromamba's locale: spaces and control characters, and on Linux and
//!   Windows every byte of a non-ASCII character too, such as the byte order
//!   mark a Windows editor puts in front of the first line of a file. On
//!   macOS micromamba runs in the `C.UTF-8` locale, where Apple's C library
//!   counts the Latin-1 bytes `0xA1`-`0xFF` (but `0xAD`) as graphic, so a
//!   byte order mark stays there and the spec does not match (checked with
//!   micromamba 2.10.0 on all three systems).
//! - A package URL (a name ending in `.tar.bz2`, `.conda`, `.whl` or
//!   `.tar.gz`) may carry a fragment. libmamba reads a fragment of hex
//!   digits as an MD5 the package must have; any other fragment (such as
//!   `#sha256:<hex>`) is dropped.
//!
//! micromamba can never install a URL spec with an MD5 fragment: it solves
//! before it downloads, while the URL's package has no MD5 yet, so the spec
//! matches nothing ("Could not solve for environment specs"), also when the
//! hash is the right one. [`url_md5_unsolvable()`] gives the same outcome.

use std::borrow::Cow;

use rattler_solve::SolveError;

use crate::error::{RtError, RtResult};

/// libmamba's archive extensions (`specs/archive.cpp`).
const ARCHIVE_EXTENSIONS: [&str; 4] = [".tar.bz2", ".conda", ".whl", ".tar.gz"];

pub fn has_archive_extension(s: &str) -> bool {
    ARCHIVE_EXTENSIONS.iter().any(|ext| s.ends_with(ext))
}

/// `std::isgraph()` of a byte in the locale micromamba sets (see the module
/// docs).
fn is_graphic(b: u8) -> bool {
    b.is_ascii_graphic() || (cfg!(target_os = "macos") && b >= 0xA1 && b != 0xAD)
}

/// libmamba's `util::strip()`: without the leading and trailing bytes that
/// are not graphic. Where that cuts a character apart (only possible on
/// macOS), the rest of it becomes U+FFFD.
pub fn libmamba_strip(s: &str) -> Cow<'_, str> {
    let b = s.as_bytes();
    let start = b.iter().position(|&c| is_graphic(c)).unwrap_or(b.len());
    let end = b.iter().rposition(|&c| is_graphic(c)).map_or(start, |i| i + 1);
    String::from_utf8_lossy(&b[start..end])
}

/// libmamba's `is_hash()`: only hex digits, in either case (an empty text
/// counts).
pub fn is_hex_text(s: &str) -> bool {
    s.bytes().all(|b| b.is_ascii_hexdigit())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpecText {
    /// The text rattler parses.
    Spec(String),
    /// A package URL with a fragment of hex digits, which libmamba makes
    /// the spec's MD5.
    UrlWithMd5 { url: String, md5: String },
}

impl SpecText {
    /// The text rattler parses (a URL with its MD5 fragment, for
    /// `UrlWithMd5`).
    pub fn into_text(self) -> String {
        match self {
            SpecText::Spec(s) => s,
            SpecText::UrlWithMd5 { url, md5 } => format!("{url}#{md5}"),
        }
    }
}

/// What libmamba's `MatchSpec::parse()` makes of `raw` before it parses the
/// spec itself (see the module docs).
pub fn spec_text(raw: &str) -> SpecText {
    let s = match raw.find(" #") {
        Some(i) => &raw[..i],
        None => raw,
    };
    let stripped = libmamba_strip(s);
    let s: &str = &stripped;
    if has_archive_extension(s) {
        return SpecText::Spec(s.to_string());
    }
    if let Some(i) = s.rfind('#') {
        let (url, fragment) = (&s[..i], &s[i + 1..]);
        if has_archive_extension(url) {
            if !fragment.is_empty() && is_hex_text(fragment) {
                return SpecText::UrlWithMd5 {
                    url: url.to_string(),
                    md5: fragment.to_string(),
                };
            }
            return SpecText::Spec(url.to_string());
        }
    }
    SpecText::Spec(s.to_string())
}

/// Refuses, as micromamba's solver does, a request with a package URL that
/// carries an MD5 fragment (kind `solve`, so a solve check answers `FALSE`).
pub fn url_md5_unsolvable(specs: &[String]) -> RtResult<()> {
    for raw in specs {
        if let SpecText::UrlWithMd5 { url, md5 } = spec_text(raw) {
            return Err(RtError::Solve(SolveError::Unsolvable(vec![format!(
                "the package URL {url} has the hash #{md5}, which micromamba reads as an MD5 the \
                 package must have before it is downloaded, so no package matches it (micromamba: \
                 \"Could not solve for environment specs\"); list package URLs with hashes in an \
                 explicit file (@EXPLICIT) instead"
            )])));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_removes_non_graphic_edges() {
        assert_eq!(libmamba_strip(" \t foo\r\n"), "foo");
        assert_eq!(libmamba_strip("f\u{feff}oo"), "f\u{feff}oo");
        assert_eq!(libmamba_strip("\u{1}\u{7f}"), "");
        if cfg!(target_os = "macos") {
            // micromamba bomplain on macOS: the mark stays.
            assert_eq!(libmamba_strip("\u{feff}foo 1.0"), "\u{feff}foo 1.0");
            assert_eq!(libmamba_strip("\u{e9}foo\u{e9}"), "\u{e9}foo\u{e9}");
            // U+0101 is C4 81, and 0x81 is not graphic.
            assert_eq!(libmamba_strip("foo\u{101}"), "foo\u{fffd}");
            // U+00A0 is C2 A0: 0xC2 is graphic, 0xA0 is not.
            assert_eq!(libmamba_strip("\u{a0}foo"), "\u{a0}foo");
            assert_eq!(libmamba_strip("foo\u{a0}"), "foo\u{fffd}");
        } else {
            assert_eq!(libmamba_strip("\u{feff}foo 1.0"), "foo 1.0");
            assert_eq!(libmamba_strip("\u{e9}foo\u{e9}"), "foo");
            assert_eq!(libmamba_strip("\u{feff}"), "");
            assert!(matches!(libmamba_strip("\u{feff}foo"), Cow::Borrowed(_)));
        }
    }

    #[test]
    fn spec_text_follows_libmamba() {
        let bom = if cfg!(target_os = "macos") { "\u{feff}foo" } else { "foo" };
        assert_eq!(spec_text("\u{feff}foo"), SpecText::Spec(bom.into()));
        assert_eq!(spec_text("foo  # comment"), SpecText::Spec("foo".into()));
        assert_eq!(spec_text(" \t# comment"), SpecText::Spec("# comment".into()));
        let url = "file:///c/noarch/baz-1.0-0.tar.bz2";
        assert_eq!(spec_text(url), SpecText::Spec(url.into()));
        // Fragments that are not hex are dropped (micromamba plainurlsha,
        // plainurljunk); hex ones are an MD5 (plainurl2, plainurlsha2).
        assert_eq!(spec_text(&format!("{url}#sha256:abcd")), SpecText::Spec(url.into()));
        assert_eq!(spec_text(&format!("{url}#zz")), SpecText::Spec(url.into()));
        assert_eq!(spec_text(&format!("{url}#")), SpecText::Spec(url.into()));
        assert_eq!(
            spec_text(&format!("{url}#ABC123")),
            SpecText::UrlWithMd5 {
                url: url.into(),
                md5: "ABC123".into()
            }
        );
        // Not a package URL: kept as written.
        assert_eq!(spec_text("foo#abc"), SpecText::Spec("foo#abc".into()));
    }

    #[test]
    fn url_md5_specs_do_not_solve() {
        let ok = vec!["foo".to_string(), "file:///c/noarch/baz-1.0-0.tar.bz2#zz".to_string()];
        assert!(url_md5_unsolvable(&ok).is_ok());
        let bad = vec![
            "foo".to_string(),
            "file:///c/noarch/baz-1.0-0.tar.bz2#1ae1d2cf711106e2bcf906cb4c6cd0e2".to_string(),
        ];
        let err = url_md5_unsolvable(&bad).unwrap_err();
        assert_eq!(err.kind(), "solve");
        assert!(matches!(err, RtError::Solve(SolveError::Unsolvable(_))));
    }
}
