//! Channel credentials in what rattlerthis writes and says, kept out as
//! libmamba keeps them out.
//!
//! A channel URL can carry a login (`https://user:password@host/channel`)
//! or a token (`https://host/t/<token>/channel`). libmamba 2.10.0 writes
//! the `url` of a package record with them hidden
//! (`CondaURL::Credentials::Hide`: `user:*****@`, `/t/*****/`), the record's
//! `channel` and the history lines without them
//! (`CondaURL::Credentials::Remove`), and hides them in its messages
//! (`hide_secrets()` in `util.cpp`). rattler kept the URL of the solve in
//! the record, so `conda-meta/*.json` (readable by every user under the
//! usual umask) and condathis's `list_packages()` showed the secret, and so
//! did the error of a failed download. The download itself still uses the
//! URL with its credentials: only what is written or said changes.

use rattler_conda_types::RepoDataRecord;
use url::Url;

/// What libmamba writes in place of a password or a token.
pub const HIDDEN: &str = "*****";

/// Whether `segment` is a channel token, as libmamba reads one
/// (`is_token()` in `conda_url.cpp`): at least two characters, letters,
/// digits and `-`, with `_` allowed in the first two (anaconda.org user
/// names). A token hidden already (libmamba's `*****`, rattler's
/// `********`) counts too, so hiding and removing are idempotent.
fn is_token(segment: &str) -> bool {
    if !segment.is_empty() && segment.bytes().all(|b| b == b'*') {
        return true;
    }
    let bytes = segment.as_bytes();
    if bytes.len() < 2 {
        return false;
    }
    bytes.iter().enumerate().all(|(i, &b)| {
        b.is_ascii_alphanumeric() || b == b'-' || (i < 2 && b == b'_')
    })
}

/// The path of `url` after its `/t/<token>` prefix, when it has one.
fn path_without_token(url: &Url) -> Option<String> {
    let mut segments = url.path_segments()?;
    match (segments.next(), segments.next()) {
        (Some("t"), Some(token)) if is_token(token) => {
            let rest: Vec<&str> = segments.collect();
            Some(format!("/{}", rest.join("/")))
        }
        _ => None,
    }
}

/// Whether credentials can be in `url`: local files have none.
fn may_carry_credentials(url: &Url) -> bool {
    url.scheme() != "file"
}

/// `url` with its credentials hidden, as libmamba writes the `url` of a
/// package record: the password of a login becomes `*****` (also a login
/// without one, `user@`, gets `user:*****@`), and so does the token of a
/// `/t/<token>/` path.
pub fn hide_url(url: &Url) -> Url {
    if !may_carry_credentials(url) {
        return url.clone();
    }
    let mut out = url.clone();
    if !out.username().is_empty() {
        let _ = out.set_password(Some(HIDDEN));
    }
    if let Some(rest) = path_without_token(url) {
        out.set_path(&format!("/t/{HIDDEN}{rest}"));
    }
    out
}

/// `url` without its credentials, as libmamba writes the `channel` of a
/// package record and the history: no login, no `/t/<token>` prefix.
pub fn remove_credentials(url: &Url) -> Url {
    if !may_carry_credentials(url) {
        return url.clone();
    }
    let mut out = url.clone();
    if !out.username().is_empty() || out.password().is_some() {
        let _ = out.set_password(None);
        let _ = out.set_username("");
    }
    if let Some(rest) = path_without_token(url) {
        out.set_path(&rest);
    }
    out
}

/// Whether `url` has a login or a token.
fn has_credentials(url: &Url) -> bool {
    may_carry_credentials(url)
        && (!url.username().is_empty() || url.password().is_some() || path_without_token(url).is_some())
}

/// A channel URL as text without its credentials. Text without
/// credentials is kept as it is written (records keep the channel of a
/// local directory decoded, `file:///a/sp chans/ch A/`, which parsing would
/// encode), and so is text that is not a URL.
pub fn remove_credentials_str(channel: &str) -> String {
    match Url::parse(channel) {
        Ok(url) if has_credentials(&url) => remove_credentials(&url).to_string(),
        _ => channel.to_string(),
    }
}

/// The record as rattlerthis writes it into `conda-meta` and the history:
/// its `url` with the credentials hidden, its `channel` without them.
pub fn public_record(record: &RepoDataRecord) -> RepoDataRecord {
    let mut out = record.clone();
    out.url = hide_url(&record.url);
    out.channel = record.channel.as_deref().map(remove_credentials_str);
    out
}

/// `text` with the credentials of the URLs in it hidden, as libmamba hides
/// them in its messages (`hide_secrets()`): every `/t/<token>` becomes
/// `/t/*****`, and the password of every `<scheme>://user:password@`
/// becomes `*****`.
pub fn hide_secrets(text: &str) -> String {
    hide_logins(&hide_tokens(text))
}

fn is_token_byte(b: u8, at: usize) -> bool {
    b.is_ascii_alphanumeric() || b == b'-' || (at < 2 && b == b'_')
}

fn hide_tokens(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut copied = 0;
    let mut i = 0;
    while let Some(found) = text[i..].find("/t/") {
        let start = i + found + 3;
        let mut end = start;
        while end < bytes.len() && (bytes[end] == b'*' || is_token_byte(bytes[end], end - start)) {
            end += 1;
        }
        if is_token(&text[start..end]) {
            out.push_str(&text[copied..start]);
            out.push_str(HIDDEN);
            copied = end;
        }
        i = end.max(start);
    }
    out.push_str(&text[copied..]);
    out
}

fn hide_logins(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut copied = 0;
    let mut i = 0;
    while let Some(found) = text[i..].find("://") {
        let start = i + found + 3;
        // The authority ends at the path, or where the URL ends in the text.
        let end = text[start..]
            .find(|c: char| c == '/' || c.is_whitespace() || "()[]<>\"'`,".contains(c))
            .map_or(text.len(), |n| start + n);
        let authority = &text[start..end];
        if let Some(at) = authority.rfind('@') {
            if let Some(colon) = authority[..at].find(':') {
                let pass_start = start + colon + 1;
                out.push_str(&text[copied..pass_start]);
                out.push_str(HIDDEN);
                copied = start + at;
            }
        }
        i = end.max(start);
    }
    out.push_str(&text[copied..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn urls_are_written_as_libmamba_writes_them() {
        // micromamba 2.10.0: `url` of conda-meta/foo-1.0-0.json, then
        // `channel` (2026-10-30, a local server).
        let token = url("http://127.0.0.1:42367/t/SECRETTOK/chA/noarch/foo-1.0-0.tar.bz2");
        assert_eq!(
            hide_url(&token).as_str(),
            "http://127.0.0.1:42367/t/*****/chA/noarch/foo-1.0-0.tar.bz2"
        );
        assert_eq!(
            remove_credentials(&url("http://127.0.0.1:42367/t/SECRETTOK/chA/")).as_str(),
            "http://127.0.0.1:42367/chA/"
        );
        let login = url("http://rt-user:rt-pw@127.0.0.1:20737/chA/noarch/foo-1.0-0.tar.bz2");
        assert_eq!(
            hide_url(&login).as_str(),
            "http://rt-user:*****@127.0.0.1:20737/chA/noarch/foo-1.0-0.tar.bz2"
        );
        assert_eq!(
            remove_credentials_str("http://rt-user:********@127.0.0.1:20737/chA/"),
            "http://127.0.0.1:20737/chA/"
        );
        // rattler's own redaction of a token, in the channel it records.
        assert_eq!(
            remove_credentials_str("http://127.0.0.1:42367/t/********/chA/"),
            "http://127.0.0.1:42367/chA/"
        );
        // A decoded local channel keeps its spelling.
        assert_eq!(remove_credentials_str("file:///a/sp chans/ch A/"), "file:///a/sp chans/ch A/");
        assert_eq!(remove_credentials_str("conda-forge"), "conda-forge");
        // A login without a password gets one hidden, as in libmamba.
        assert_eq!(hide_url(&url("https://user@host/c/x.conda")).as_str(), "https://user:*****@host/c/x.conda");
        // Idempotent.
        assert_eq!(hide_url(&hide_url(&token)), hide_url(&token));
        assert_eq!(hide_url(&hide_url(&login)), hide_url(&login));
        // No credentials: unchanged, also a channel named `t` and local files.
        for plain in [
            "https://conda.anaconda.org/conda-forge/noarch/x-1-0.conda",
            "https://host/t/",
            "https://host/t/x",
            "file:///t/ab/chA/noarch/x-1-0.conda",
        ] {
            assert_eq!(hide_url(&url(plain)).as_str(), plain);
            assert_eq!(remove_credentials(&url(plain)).as_str(), plain);
        }
    }

    #[test]
    fn records_lose_their_credentials() {
        let record = crate::history::tests::record("http://u:p@h/t/tk-1/chA/", "noarch", "foo", "1.0", "0");
        let public = public_record(&record);
        assert_eq!(public.url.as_str(), "http://u:*****@h/t/*****/chA/noarch/foo-1.0-0.tar.bz2");
        assert_eq!(public.channel.as_deref(), Some("http://h/chA/"));
        assert_eq!(public.package_record, record.package_record);
    }

    #[test]
    fn messages_hide_secrets_as_libmamba_does() {
        assert_eq!(
            hide_secrets("HTTP status 404 Not Found for http://h:1/t/SECRETTOK/chA/noarch/foo-1.0-0.tar.bz2"),
            "HTTP status 404 Not Found for http://h:1/t/*****/chA/noarch/foo-1.0-0.tar.bz2"
        );
        assert_eq!(
            hide_secrets("failed (http://rt-user:rt-pw@127.0.0.1:1/chA/x) and https://a:b@c"),
            "failed (http://rt-user:*****@127.0.0.1:1/chA/x) and https://a:*****@c"
        );
        assert_eq!(
            hide_secrets("http://u:p@h/t/ab/c http://h/t/x/y"),
            "http://u:*****@h/t/*****/c http://h/t/x/y"
        );
        for plain in ["no url here", "http://h/chA/noarch", "user@host: denied", "a://b"] {
            assert_eq!(hide_secrets(plain), plain);
        }
    }
}
