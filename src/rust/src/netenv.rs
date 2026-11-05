//! The network settings micromamba 2.10.0 honors when condathis runs it
//! (`--rc-file` with condathis's own file, `--no-env`), so that rattler's
//! HTTP clients honor the same ones and no others.
//!
//! Measured with micromamba 2.10.0 run as condathis runs it (2026-10-29,
//! Linux; its static libcurl 8.23 with OpenSSL 3.5), against local servers
//! that log every request:
//!
//! - Proxies (libcurl's own variables): `http_proxy` (lower case only: an
//!   upper-case `HTTP_PROXY` is ignored), `https_proxy` or `HTTPS_PROXY`,
//!   `all_proxy` or `ALL_PROXY`, and `no_proxy` or `NO_PROXY`. A proxy
//!   without a scheme is an HTTP proxy, and its `user:password@` is sent as
//!   `Proxy-Authorization`. The `.condarc` `proxy_servers` are never read.
//! - Certificates: none of `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`,
//!   `SSL_CERT_DIR`, `CURL_CA_BUNDLE`, `MAMBA_SSL_VERIFY`,
//!   `CONDA_SSL_VERIFY` or `MAMBA_CACERT_PATH` is used: `ssl_verify` is
//!   `<system>`, so libmamba (`download/downloader.cpp`
//!   `init_remote_fetch_params()`) uses `ssl/cert.pem` of its root prefix
//!   (`Library/ssl/cacert.pem` on Windows) when it exists, else on Linux
//!   and macOS the first CA bundle of a fixed list of system locations, and
//!   on Windows the system store. Only that bundle is trusted.
//! - Credentials: `~/.mamba/auth/authentication.json` (`BearerToken` for
//!   the `host:port` of the request; `CondaToken`, inserted as
//!   `/t/<token>/`, and `BasicHTTPAuthentication`, for the longest key
//!   that is a prefix of `host:port/path`); `.netrc` (`NETRC`, else
//!   `~/.netrc`, and `_netrc` on Windows) when the URL has no credentials;
//!   and credentials or a `/t/<token>/` in the channel URL itself. The
//!   tokens of `~/.continuum/anaconda-client/tokens` are not used.
//!
//! The root prefix of micromamba is condathis's root (condathis sets
//! `MAMBA_ROOT_PREFIX` to it for micromamba's own processes), which the R
//! side passes as the job's network root. micromamba also trusts
//! `ssl/cert.pem` of the prefix its binary lives in, a property of the
//! micromamba installation that has no counterpart here.

use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

use base64::Engine;
use reqwest_middleware::{Middleware, Next};

/// The settings of a job's HTTP clients that do not come from the process
/// environment: condathis's root, whose `ssl/cert.pem` is a CA bundle as for
/// micromamba (see the module docs). `None` uses only the system bundle.
#[derive(Clone, Debug, Default)]
pub struct NetSettings {
    pub root: Option<PathBuf>,
}

impl NetSettings {
    pub fn new(root: Option<String>) -> Self {
        NetSettings {
            root: root.filter(|r| !r.is_empty()).map(PathBuf::from),
        }
    }
}

// ---------------------------------------------------------------------------
// Proxies, as libcurl reads them (`lib/url.c` `detect_proxy()`,
// `lib/noproxy.c` `Curl_check_noproxy()`).

/// The proxy variables of the process environment.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProxyEnv {
    http: Option<String>,
    https: Option<String>,
    all: Option<String>,
    no_proxy: Option<String>,
}

impl ProxyEnv {
    /// libcurl's lookup: the lower-case name, else (but for `http_proxy`)
    /// the upper-case one; an empty value counts as unset.
    pub fn from_lookup(get: &dyn Fn(&str) -> Option<String>) -> Self {
        let var = |name: &str| get(name).filter(|v| !v.is_empty());
        ProxyEnv {
            http: var("http_proxy"),
            https: var("https_proxy").or_else(|| var("HTTPS_PROXY")),
            all: var("all_proxy").or_else(|| var("ALL_PROXY")),
            no_proxy: var("no_proxy").or_else(|| var("NO_PROXY")),
        }
    }

    pub fn from_process() -> Self {
        Self::from_lookup(&|name: &str| std::env::var(name).ok())
    }

    /// The proxy URL for a request to `url`, or `None` to connect directly:
    /// `no_proxy` first, then the variable of the URL's scheme, then
    /// `all_proxy`. A proxy without a scheme is an HTTP proxy, as in
    /// libcurl.
    pub fn proxy_for(&self, url: &url::Url) -> Option<String> {
        let specific = match url.scheme() {
            "http" => self.http.as_ref(),
            "https" => self.https.as_ref(),
            _ => return None,
        };
        let host = url.host_str()?;
        if self.no_proxy.as_deref().is_some_and(|list| no_proxy_matches(list, host)) {
            return None;
        }
        let proxy = specific.or(self.all.as_ref())?;
        if proxy.contains("://") {
            Some(proxy.clone())
        } else {
            Some(format!("http://{proxy}"))
        }
    }
}

fn is_blank(c: u8) -> bool {
    c == b' ' || c == b'\t'
}

/// libcurl's `Curl_check_noproxy()`: whether `host` (of a URL; brackets of
/// an IPv6 address allowed) is excluded by the `no_proxy` list. `*` alone
/// excludes every host. Otherwise the list holds names, separated by
/// commas (blanks around them allowed): a host name matches a name equal
/// to it or to one of its parent domains (case-insensitive, leading and
/// trailing dots ignored); an IP address matches an address or a
/// `address/bits` network.
pub fn no_proxy_matches(list: &str, host: &str) -> bool {
    if host.is_empty() || list.is_empty() {
        return false;
    }
    if list == "*" {
        return true;
    }
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    let ip: Option<IpAddr> = host.parse().ok();
    let name = host.strip_suffix('.').unwrap_or(host);
    let b = list.as_bytes();
    let mut i = 0;
    while i < b.len() {
        while i < b.len() && is_blank(b[i]) {
            i += 1;
        }
        let start = i;
        while i < b.len() && !is_blank(b[i]) && b[i] != b',' {
            i += 1;
        }
        let token = &list[start..i];
        if !token.is_empty() {
            let matched = match ip {
                Some(ip) => cidr_matches(ip, token),
                None => name_matches(name, token),
            };
            if matched {
                return true;
            }
        }
        while i < b.len() && is_blank(b[i]) {
            i += 1;
        }
        if i >= b.len() || b[i] != b',' {
            break;
        }
        while i < b.len() && b[i] == b',' {
            i += 1;
        }
    }
    false
}

fn name_matches(name: &str, token: &str) -> bool {
    let token = token.strip_suffix('.').unwrap_or(token);
    let token = token.strip_prefix('.').unwrap_or(token);
    if token.is_empty() {
        return false;
    }
    if token.len() == name.len() {
        return token.eq_ignore_ascii_case(name);
    }
    if token.len() < name.len() {
        let cut = name.len() - token.len();
        return name.as_bytes()[cut - 1] == b'.'
            && name.is_char_boundary(cut)
            && name[cut..].eq_ignore_ascii_case(token);
    }
    false
}

/// libcurl's `Curl_cidr4_match()` and `Curl_cidr6_match()`: no bits (or 0)
/// is an exact match; an address of the other family never matches.
fn cidr_matches(ip: IpAddr, token: &str) -> bool {
    let (addr, bits) = match token.split_once('/') {
        Some((addr, bits)) => (addr, bits.parse::<u32>().unwrap_or(0)),
        None => (token, 0),
    };
    let addr = addr
        .strip_prefix('[')
        .and_then(|a| a.strip_suffix(']'))
        .unwrap_or(addr);
    match (ip, addr.parse::<IpAddr>()) {
        (IpAddr::V4(ip), Ok(IpAddr::V4(net))) => {
            let bits = if bits == 0 { 32 } else { bits };
            if bits > 32 {
                return false;
            }
            let mask = if bits == 32 { u32::MAX } else { !(u32::MAX >> bits) };
            (u32::from(ip) & mask) == (u32::from(net) & mask)
        }
        (IpAddr::V6(ip), Ok(IpAddr::V6(net))) => {
            let bits = if bits == 0 { 128 } else { bits };
            if bits > 128 {
                return false;
            }
            let mask = if bits == 128 { u128::MAX } else { !(u128::MAX >> bits) };
            (u128::from(ip) & mask) == (u128::from(net) & mask)
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Certificates.

/// libmamba's system CA bundles (`download/downloader.cpp`
/// `cert_locations`), tried in this order on Linux and macOS.
pub const SYSTEM_CA_BUNDLES: [&str; 10] = [
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/pki/tls/cacert.pem",
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    "/etc/ssl/cert.pem",
    "/System/Library/OpenSSL/certs/cert.pem",
    "/usr/local/etc/openssl/cert.pem",
    "/usr/local/share/certs/ca-root-nss.crt",
    "/usr/local/share/certs/ca-root.crt",
];

/// The CA bundle of a root prefix: `ssl/cert.pem`, `Library/ssl/cacert.pem`
/// on Windows (as conda-forge's `ca-certificates` installs it).
pub fn root_ca_bundle(root: &Path) -> PathBuf {
    if cfg!(windows) {
        root.join("Library").join("ssl").join("cacert.pem")
    } else {
        root.join("ssl").join("cert.pem")
    }
}

/// The certificates HTTPS connections trust.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Trust {
    /// The system's (Windows without a bundle in the root).
    System,
    /// Only the certificates of this PEM bundle.
    Bundle(PathBuf),
    /// No certificate at all: no CA bundle exists (libmamba aborts with "No
    /// CA certificates found on system").
    Nothing,
}

/// The trust of libmamba's `ssl_verify = "<system>"`: the root's bundle
/// when it exists, else on Windows the system store, elsewhere the first
/// bundle of [`SYSTEM_CA_BUNDLES`] that exists (`exists` tells).
pub fn trust_for(root: Option<&Path>, exists: &dyn Fn(&Path) -> bool) -> Trust {
    if let Some(bundle) = root.map(root_ca_bundle).filter(|b| exists(b)) {
        return Trust::Bundle(bundle);
    }
    if cfg!(windows) {
        return Trust::System;
    }
    match SYSTEM_CA_BUNDLES.iter().map(PathBuf::from).find(|p| exists(p)) {
        Some(bundle) => Trust::Bundle(bundle),
        None => Trust::Nothing,
    }
}

// ---------------------------------------------------------------------------
// Credentials.

/// One entry of libmamba's authentication database.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Auth {
    Bearer(String),
    Basic { user: String, password: String },
    CondaToken(String),
}

/// `~/.mamba/auth/authentication.json`, keyed as written (`host[:port]` or
/// `host[:port]/path`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AuthDb {
    entries: HashMap<String, Auth>,
}

impl AuthDb {
    /// Parses the file as libmamba's `Context::load_authentication_info()`
    /// does: `{"<key>": {"type": "CondaToken", "token": ...}}`, `"BearerToken"`
    /// with `token`, `"BasicHTTPAuthentication"` with `user` (optional) and
    /// a base64 `password`. An entry libmamba cannot use (another type, a
    /// password that is not base64) gives no credentials; a malformed file
    /// keeps the entries read before the problem.
    pub fn parse(text: &str) -> Self {
        let mut db = AuthDb::default();
        let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(text) else {
            return db;
        };
        // In key order, as nlohmann iterates an object.
        let mut items: Vec<(String, serde_json::Value)> = map.into_iter().collect();
        items.sort_by(|a, b| a.0.cmp(&b.0));
        for (key, el) in items {
            let text = |name: &str| el.get(name).and_then(|v| v.as_str()).map(str::to_string);
            let Some(kind) = text("type") else {
                break;
            };
            let auth = match kind.as_str() {
                "CondaToken" => match text("token") {
                    Some(token) => Auth::CondaToken(token),
                    None => break,
                },
                "BearerToken" => match text("token") {
                    Some(token) => Auth::Bearer(token),
                    None => break,
                },
                "BasicHTTPAuthentication" => {
                    let Some(encoded) = text("password") else {
                        break;
                    };
                    match decode_base64(&encoded) {
                        Some(password) => Auth::Basic {
                            user: text("user").unwrap_or_default(),
                            password,
                        },
                        None => continue,
                    }
                }
                _ => continue,
            };
            db.entries.insert(key, auth);
        }
        db
    }

    /// libmamba's `find_weaken()` with its `URLWeakener`: the entry of
    /// `key/`, `key`, then of `key` without its last path element (with and
    /// without the final `/`), and so on up to the host.
    pub fn find_weaken(&self, key: &str) -> Option<&Auth> {
        let mut k: String = if key.ends_with('/') {
            key.to_string()
        } else {
            format!("{key}/")
        };
        loop {
            if let Some(auth) = self.entries.get(&k) {
                return Some(auth);
            }
            let pos = k.rfind('/')?;
            if pos + 1 == k.len() {
                k.truncate(pos);
            } else {
                k.truncate(pos + 1);
            }
            if k.is_empty() {
                return None;
            }
        }
    }
}

fn decode_base64(text: &str) -> Option<String> {
    let engine = base64::engine::GeneralPurpose::new(
        &base64::alphabet::STANDARD,
        base64::engine::GeneralPurposeConfig::new()
            .with_decode_padding_mode(base64::engine::DecodePaddingMode::Indifferent),
    );
    let bytes = engine.decode(text.trim()).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

fn encode_basic(user: &str, password: &str) -> String {
    format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}"))
    )
}

/// The machines of a `.netrc` file, as libcurl reads it (`lib/netrc.c`):
/// whitespace-separated tokens (double-quoted ones with `\` escapes; an
/// unquoted `#` starts a comment), `machine <name>` (case-insensitive) or
/// `default`, then `login` and `password`; `macdef` skips to the next empty
/// line.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Netrc {
    machines: Vec<(Option<String>, Option<String>, Option<String>)>,
}

impl Netrc {
    pub fn parse(text: &str) -> Self {
        let mut machines = Vec::new();
        // (machine, login, password) of the entry being read; `None` before
        // the first `machine` or `default`.
        let mut current: Option<(Option<String>, Option<String>, Option<String>)> = None;
        let mut lines = text.lines();
        let mut pending: Vec<String> = Vec::new();
        let next_token = |pending: &mut Vec<String>, lines: &mut std::str::Lines| -> Option<String> {
            loop {
                if !pending.is_empty() {
                    return Some(pending.remove(0));
                }
                let line = lines.next()?;
                *pending = netrc_tokens(line);
            }
        };
        while let Some(token) = next_token(&mut pending, &mut lines) {
            match token.as_str() {
                "machine" => {
                    if let Some(entry) = current.take() {
                        machines.push(entry);
                    }
                    let name = next_token(&mut pending, &mut lines);
                    current = Some((Some(name.unwrap_or_default()), None, None));
                }
                "default" => {
                    if let Some(entry) = current.take() {
                        machines.push(entry);
                    }
                    current = Some((None, None, None));
                }
                "login" => {
                    let value = next_token(&mut pending, &mut lines);
                    if let Some(entry) = current.as_mut() {
                        entry.1 = value;
                    }
                }
                "password" => {
                    let value = next_token(&mut pending, &mut lines);
                    if let Some(entry) = current.as_mut() {
                        entry.2 = value;
                    }
                }
                "account" => {
                    next_token(&mut pending, &mut lines);
                }
                "macdef" => {
                    pending.clear();
                    for line in lines.by_ref() {
                        if line.trim().is_empty() {
                            break;
                        }
                    }
                }
                _ => {}
            }
        }
        if let Some(entry) = current.take() {
            machines.push(entry);
        }
        Netrc { machines }
    }

    /// The login and password for `host`: the first `machine` of that name,
    /// else `default`.
    pub fn lookup(&self, host: &str) -> Option<(String, String)> {
        let found = self
            .machines
            .iter()
            .find(|(m, _, _)| m.as_deref().is_some_and(|m| m.eq_ignore_ascii_case(host)))
            .or_else(|| self.machines.iter().find(|(m, _, _)| m.is_none()))?;
        match (&found.1, &found.2) {
            (None, None) => None,
            (login, password) => Some((login.clone().unwrap_or_default(), password.clone().unwrap_or_default())),
        }
    }
}

fn netrc_tokens(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = line.chars().peekable();
    loop {
        while chars.peek().is_some_and(|c| c.is_whitespace()) {
            chars.next();
        }
        let Some(&first) = chars.peek() else {
            return out;
        };
        // An unquoted `#` starts a comment, to the end of the line.
        if first == '#' {
            return out;
        }
        let mut token = String::new();
        if first == '"' {
            chars.next();
            while let Some(c) = chars.next() {
                match c {
                    '"' => break,
                    '\\' => match chars.next() {
                        Some('n') => token.push('\n'),
                        Some('r') => token.push('\r'),
                        Some('t') => token.push('\t'),
                        Some(other) => token.push(other),
                        None => break,
                    },
                    other => token.push(other),
                }
            }
        } else {
            while let Some(&c) = chars.peek() {
                if c.is_whitespace() {
                    break;
                }
                token.push(c);
                chars.next();
            }
        }
        out.push(token);
    }
}

/// libcurl's `.netrc`: `NETRC` when set (libmamba passes it to curl), else
/// `<home>/.netrc` with the home from `HOME` (else the password database;
/// on Windows `USERPROFILE`), and on Windows `<home>/_netrc` when there is
/// no `.netrc`.
pub fn netrc_path(get: &dyn Fn(&str) -> Option<String>, exists: &dyn Fn(&Path) -> bool) -> Option<PathBuf> {
    if let Some(file) = get("NETRC").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(file));
    }
    let home = get("HOME").filter(|v| !v.is_empty()).map(PathBuf::from).or_else(|| {
        if cfg!(windows) {
            get("USERPROFILE").filter(|v| !v.is_empty()).map(PathBuf::from)
        } else {
            #[allow(deprecated)]
            std::env::home_dir()
        }
    })?;
    let dotted = home.join(".netrc");
    if cfg!(windows) && !exists(&dotted) {
        return Some(home.join("_netrc"));
    }
    Some(dotted)
}

/// The credentials of a job: the authentication database and `.netrc`.
#[derive(Clone, Debug, Default)]
pub struct Credentials {
    pub db: AuthDb,
    pub netrc: Netrc,
}

impl Credentials {
    /// Reads `~/.mamba/auth/authentication.json` (the home of libmamba's
    /// `user_home_dir()`) and the `.netrc` file; a missing or unreadable
    /// file gives no credentials.
    pub fn from_process() -> Self {
        let db = crate::explicit::user_home_dir()
            .map(|home| home.join(".mamba").join("auth").join("authentication.json"))
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|text| AuthDb::parse(&text))
            .unwrap_or_default();
        let netrc = netrc_path(&|name: &str| std::env::var(name).ok(), &|p: &Path| p.exists())
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|text| Netrc::parse(&text))
            .unwrap_or_default();
        Credentials { db, netrc }
    }

    /// Applies libmamba's credentials to a request (see [`apply_credentials()`]).
    pub fn apply(&self, request: &mut reqwest::Request) {
        apply_credentials(self, request)
    }
}

/// `host` or `host:port` of a URL, as libmamba's keys spell it.
fn host_key(url: &url::Url) -> Option<String> {
    let host = url.host_str()?;
    Some(match url.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
    })
}

/// The token of a `/t/<token>/...` path, as libmamba's `CondaURL` finds it.
fn path_token(path: &str) -> Option<&str> {
    let rest = path.strip_prefix("/t/")?;
    let token = rest.split('/').next().unwrap_or("");
    (!token.is_empty()).then_some(token)
}

/// What libmamba (and its libcurl) adds to a request to `url`:
///
/// 1. the entry of the database for the longest prefix of
///    `host[:port]/path` (the path without a `/t/<token>`): a
///    `BasicHTTPAuthentication` when the request has no credentials yet
///    (libmamba puts it into the channel URL), a `CondaToken` as
///    `/t/<token>/` when the path has no token;
/// 2. a `BearerToken` entry of `host[:port]` as `Authorization: Bearer`,
///    which replaces any other `Authorization`;
/// 3. else, without credentials so far, the `.netrc` login of the host.
///
/// URL credentials reach here as the `Authorization` header that reqwest
/// made of them.
pub fn apply_credentials(creds: &Credentials, request: &mut reqwest::Request) {
    let url = request.url().clone();
    if !matches!(url.scheme(), "http" | "https") {
        return;
    }
    let Some(host) = host_key(&url) else {
        return;
    };
    let auth_header = reqwest::header::AUTHORIZATION;
    let mut has_auth = request.headers().contains_key(&auth_header)
        || !url.username().is_empty()
        || url.password().is_some();
    let path = url.path().to_string();
    let token = path_token(&path).map(str::to_string);
    let without_token = match &token {
        Some(t) => path["/t/".len() + t.len()..].to_string(),
        None => path.clone(),
    };
    let key = format!("{host}{}", without_token.trim_end_matches('/'));
    match creds.db.find_weaken(&key) {
        Some(Auth::Basic { user, password }) if !has_auth => {
            if let Ok(value) = reqwest::header::HeaderValue::from_str(&encode_basic(user, password)) {
                request.headers_mut().insert(&auth_header, value);
                has_auth = true;
            }
        }
        Some(Auth::CondaToken(new)) if token.is_none() => {
            let mut changed = url.clone();
            changed.set_path(&format!("/t/{new}{without_token}"));
            *request.url_mut() = changed;
        }
        _ => {}
    }
    if let Some(Auth::Bearer(bearer)) = creds.db.find_weaken(&host) {
        if let Ok(value) = reqwest::header::HeaderValue::from_str(&format!("Bearer {bearer}")) {
            request.headers_mut().insert(&auth_header, value);
            return;
        }
    }
    if !has_auth {
        if let Some((login, password)) = url.host_str().and_then(|h| creds.netrc.lookup(h)) {
            if let Ok(value) = reqwest::header::HeaderValue::from_str(&encode_basic(&login, &password)) {
                request.headers_mut().insert(&auth_header, value);
            }
        }
    }
}

/// The middleware that applies [`Credentials`] to every request of a client.
#[derive(Clone, Debug, Default)]
pub struct CredentialsMiddleware {
    creds: std::sync::Arc<Credentials>,
}

impl CredentialsMiddleware {
    pub fn new(creds: Credentials) -> Self {
        CredentialsMiddleware {
            creds: std::sync::Arc::new(creds),
        }
    }
}

#[async_trait::async_trait]
impl Middleware for CredentialsMiddleware {
    async fn handle(
        &self,
        mut req: reqwest::Request,
        extensions: &mut http::Extensions,
        next: Next<'_>,
    ) -> reqwest_middleware::Result<reqwest::Response> {
        self.creds.apply(&mut req);
        next.run(req, extensions).await
    }
}

#[cfg(test)]
mod tests;
