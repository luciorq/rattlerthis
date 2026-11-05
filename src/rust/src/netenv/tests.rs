//! The network settings, checked against what micromamba 2.10.0 did with
//! the same environment and files (run as condathis runs it, 2026-10-29).

use super::*;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn lookup(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let vars: Vec<(String, String)> = vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    move |name: &str| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())
}

fn proxies(vars: &[(&str, &str)]) -> ProxyEnv {
    ProxyEnv::from_lookup(&lookup(vars))
}

fn url(s: &str) -> url::Url {
    url::Url::parse(s).unwrap()
}

#[test]
fn proxies_follow_libcurl() {
    let p = "http://proxy:3128";
    // micromamba x1 to x4: lower-case http_proxy only; https_proxy and
    // all_proxy in either case.
    assert_eq!(proxies(&[("http_proxy", p)]).proxy_for(&url("http://h/x")).as_deref(), Some(p));
    assert_eq!(proxies(&[("HTTP_PROXY", p)]).proxy_for(&url("http://h/x")), None);
    assert_eq!(proxies(&[("https_proxy", p)]).proxy_for(&url("https://h/x")).as_deref(), Some(p));
    assert_eq!(proxies(&[("HTTPS_PROXY", p)]).proxy_for(&url("https://h/x")).as_deref(), Some(p));
    assert_eq!(proxies(&[("http_proxy", p)]).proxy_for(&url("https://h/x")), None);
    for name in ["all_proxy", "ALL_PROXY"] {
        let env = proxies(&[(name, p)]);
        assert_eq!(env.proxy_for(&url("http://h/x")).as_deref(), Some(p));
        assert_eq!(env.proxy_for(&url("https://h/x")).as_deref(), Some(p));
    }
    // The scheme's variable before all_proxy; lower case before upper case.
    let env = proxies(&[("all_proxy", "http://all:1"), ("https_proxy", "http://low:1"), ("HTTPS_PROXY", "http://up:1")]);
    assert_eq!(env.proxy_for(&url("https://h/x")).as_deref(), Some("http://low:1"));
    assert_eq!(env.proxy_for(&url("http://h/x")).as_deref(), Some("http://all:1"));
    // An empty value is unset; a proxy without a scheme is an HTTP proxy;
    // credentials stay in the URL (sent as Proxy-Authorization).
    assert_eq!(proxies(&[("https_proxy", ""), ("HTTPS_PROXY", p)]).proxy_for(&url("https://h/x")).as_deref(), Some(p));
    assert_eq!(
        proxies(&[("http_proxy", "proxy:3128")]).proxy_for(&url("http://h/x")).as_deref(),
        Some("http://proxy:3128")
    );
    assert_eq!(
        proxies(&[("http_proxy", "http://u:p@proxy:1")]).proxy_for(&url("http://h/x")).as_deref(),
        Some("http://u:p@proxy:1")
    );
    // no_proxy (either case) wins; local files never use a proxy.
    let env = proxies(&[("all_proxy", p), ("NO_PROXY", "h")]);
    assert_eq!(env.proxy_for(&url("http://h/x")), None);
    assert_eq!(env.proxy_for(&url("http://other/x")).as_deref(), Some(p));
    assert_eq!(proxies(&[("all_proxy", p)]).proxy_for(&url("file:///x")), None);
    assert_eq!(ProxyEnv::default().proxy_for(&url("http://h/x")), None);
}

#[test]
fn no_proxy_follows_libcurl() {
    // Names: the name or a parent domain, any case, dots at either end
    // ignored; nonexample.com is not example.com.
    assert!(no_proxy_matches("example.com", "example.com"));
    assert!(no_proxy_matches("example.com", "WWW.Example.COM"));
    assert!(no_proxy_matches(".example.com", "www.example.com"));
    assert!(no_proxy_matches("example.com.", "example.com"));
    assert!(no_proxy_matches("example.com", "example.com."));
    assert!(!no_proxy_matches("example.com", "nonexample.com"));
    assert!(!no_proxy_matches("www.example.com", "example.com"));
    // Lists: commas with blanks around them; a blank without a comma ends
    // the list (libcurl's loop).
    assert!(no_proxy_matches("a.org, b.org ,c.org", "c.org"));
    assert!(no_proxy_matches("a.org,,b.org", "b.org"));
    assert!(!no_proxy_matches("a.org b.org", "b.org"));
    // `*` alone matches all, and only alone.
    assert!(no_proxy_matches("*", "anything"));
    assert!(!no_proxy_matches("*, a.org", "anything"));
    // Addresses: exact, or a network with bits; never a name match.
    assert!(no_proxy_matches("127.0.0.1", "127.0.0.1"));
    assert!(no_proxy_matches("10.0.0.0/8", "10.1.2.3"));
    assert!(!no_proxy_matches("10.0.0.0/8", "11.1.2.3"));
    assert!(!no_proxy_matches("0.0.1", "127.0.0.1"));
    assert!(no_proxy_matches("::1", "[::1]"));
    assert!(no_proxy_matches("[fd00::]/8", "[fdab::1]"));
    assert!(!no_proxy_matches("127.0.0.1", "[::1]"));
    assert!(!no_proxy_matches("", "h"));
}

#[test]
fn trust_follows_libmamba() {
    let root = PathBuf::from("/r");
    let bundle = root_ca_bundle(&root);
    assert_eq!(
        bundle,
        if cfg!(windows) { root.join("Library/ssl/cacert.pem") } else { root.join("ssl/cert.pem") }
    );
    // The root's bundle first.
    let b = bundle.clone();
    assert_eq!(trust_for(Some(&root), &move |p| p == b), Trust::Bundle(bundle));
    // Else the system: the first of libmamba's bundles that exists, or the
    // store on Windows.
    let second = PathBuf::from(SYSTEM_CA_BUNDLES[1]);
    let s2 = second.clone();
    let got = trust_for(Some(&root), &move |p| p == s2 || p == Path::new(SYSTEM_CA_BUNDLES[5]));
    if cfg!(windows) {
        assert_eq!(got, Trust::System);
        assert_eq!(trust_for(None, &|_| false), Trust::System);
    } else {
        assert_eq!(got, Trust::Bundle(second));
        assert_eq!(trust_for(None, &|_| false), Trust::Nothing);
    }
}

#[test]
fn the_authentication_file_is_read_as_libmamba_reads_it() {
    let text = r#"{
        "h:1": {"type": "BearerToken", "token": "bear"},
        "h:2/chA": {"type": "CondaToken", "token": "tok"},
        "h:3": {"type": "BasicHTTPAuthentication", "user": "us", "password": "cHc="},
        "h:4": {"type": "BasicHTTPAuthentication", "password": "not base64!"},
        "h:5": {"type": "Other", "token": "x"},
        "h:6": {"type": "BasicHTTPAuthentication", "password": "cHc"}
    }"#;
    let db = AuthDb::parse(text);
    assert_eq!(db.find_weaken("h:1"), Some(&Auth::Bearer("bear".into())));
    assert_eq!(db.find_weaken("h:2/chA"), Some(&Auth::CondaToken("tok".into())));
    assert_eq!(db.find_weaken("h:2/chA/noarch/repodata.json"), Some(&Auth::CondaToken("tok".into())));
    assert_eq!(db.find_weaken("h:2/chAB"), None);
    assert_eq!(db.find_weaken("h:2"), None);
    assert_eq!(db.find_weaken("h:3/any/path"), Some(&Auth::Basic { user: "us".into(), password: "pw".into() }));
    assert_eq!(db.find_weaken("h:4"), None);
    assert_eq!(db.find_weaken("h:5"), None);
    assert_eq!(db.find_weaken("h:6"), Some(&Auth::Basic { user: String::new(), password: "pw".into() }));
    // An entry without a type stops the reading (libmamba's exception), in
    // key order; a file that is not JSON gives nothing.
    let db = AuthDb::parse(r#"{"b": {"token": "x"}, "a": {"type": "BearerToken", "token": "t"}, "c": {"type": "BearerToken", "token": "t"}}"#);
    assert!(db.find_weaken("a").is_some());
    assert!(db.find_weaken("c").is_none());
    assert_eq!(AuthDb::parse("not json"), AuthDb::default());
}

#[test]
fn netrc_files_are_read_as_libcurl_reads_them() {
    let n = Netrc::parse(
        "machine a.org login la password pa\n# password not-this\nmachine B.org\n  login lb\n  password \"p b\\\"x\"\nmacdef init\ncd /\n\nmachine c.org login lc password pc\ndefault login ld password pd\n",
    );
    assert_eq!(n.lookup("a.org"), Some(("la".into(), "pa".into())));
    assert_eq!(n.lookup("b.ORG"), Some(("lb".into(), "p b\"x".into())));
    assert_eq!(n.lookup("c.org"), Some(("lc".into(), "pc".into())));
    assert_eq!(n.lookup("other"), Some(("ld".into(), "pd".into())));
    assert_eq!(Netrc::parse("machine a login x").lookup("b"), None);
    // NETRC, else the home's .netrc (_netrc on Windows when it is missing).
    let get = lookup(&[("NETRC", "/x/rc"), ("HOME", "/h")]);
    assert_eq!(netrc_path(&get, &|_| true), Some(PathBuf::from("/x/rc")));
    let get = lookup(&[("HOME", "/h")]);
    assert_eq!(netrc_path(&get, &|_| true), Some(PathBuf::from("/h").join(".netrc")));
    let want = if cfg!(windows) { "_netrc" } else { ".netrc" };
    assert_eq!(netrc_path(&get, &|_| false), Some(PathBuf::from("/h").join(want)));
}

fn request(u: &str) -> reqwest::Request {
    reqwest::Request::new(reqwest::Method::GET, url(u))
}

fn auth_of(r: &reqwest::Request) -> Option<String> {
    r.headers()
        .get(reqwest::header::AUTHORIZATION)
        .map(|v| v.to_str().unwrap().to_string())
}

#[test]
fn credentials_are_applied_as_micromamba_applies_them() {
    let creds = Credentials {
        db: AuthDb::parse(
            r#"{
            "127.0.0.1:81": {"type": "BearerToken", "token": "bear"},
            "127.0.0.1": {"type": "BearerToken", "token": "hostonly"},
            "127.0.0.1:82/chA": {"type": "CondaToken", "token": "tok"},
            "127.0.0.1:83": {"type": "BasicHTTPAuthentication", "user": "us", "password": "cHc="}
        }"#,
        ),
        netrc: Netrc::parse("machine 127.0.0.1 login nu password np\n"),
    };
    // micromamba a1: a bearer token of host:port; a bare host does not
    // match a URL with a port (a2).
    let mut r = request("http://127.0.0.1:81/chA/noarch/repodata.json");
    creds.apply(&mut r);
    assert_eq!(auth_of(&r).as_deref(), Some("Bearer bear"));
    // a4, a5: a conda token for a path prefix, inserted as /t/<token>/; a
    // token in the URL stays; another path gets none. With no other
    // credentials, the .netrc login applies (a8).
    let mut r = request("http://127.0.0.1:82/chA/noarch/repodata.json");
    creds.apply(&mut r);
    assert_eq!(r.url().path(), "/t/tok/chA/noarch/repodata.json");
    assert_eq!(auth_of(&r).as_deref(), Some("Basic bnU6bnA="));
    let mut r = request("http://127.0.0.1:82/t/mine/chA/noarch/repodata.json");
    creds.apply(&mut r);
    assert_eq!(r.url().path(), "/t/mine/chA/noarch/repodata.json");
    let mut r = request("http://127.0.0.1:82/chB/noarch/repodata.json");
    creds.apply(&mut r);
    assert_eq!(r.url().path(), "/chB/noarch/repodata.json");
    // a7: basic credentials for the host, before .netrc.
    let mut r = request("http://127.0.0.1:83/chA/x");
    creds.apply(&mut r);
    assert_eq!(auth_of(&r).as_deref(), Some("Basic dXM6cHc="));
    // a10: credentials of the URL (reqwest's header) win over the file and
    // .netrc.
    let mut r = request("http://127.0.0.1:83/chA/x");
    r.headers_mut()
        .insert(reqwest::header::AUTHORIZATION, "Basic dXU6dXA=".parse().unwrap());
    creds.apply(&mut r);
    assert_eq!(auth_of(&r).as_deref(), Some("Basic dXU6dXA="));
    // Nothing for other schemes.
    let mut r = request("file:///127.0.0.1/x");
    creds.apply(&mut r);
    assert_eq!(auth_of(&r), None);
    assert_eq!(Credentials::default().db, AuthDb::default());
}

// ---------------------------------------------------------------------------
// Against local servers.

fn tls_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/testthat/fixtures/tls")
}

/// A plain HTTP server that records the request line and Authorization
/// header of each request and answers 200 with `body` (or 403 to CONNECT).
async fn recording_server(body: &'static str) -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let log = log.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let text = String::from_utf8_lossy(&buf[..n]).to_string();
                let mut lines = text.split("\r\n");
                let first = lines.next().unwrap_or("").to_string();
                for line in lines.take_while(|l| !l.is_empty()) {
                    let lower = line.to_ascii_lowercase();
                    if lower.starts_with("authorization:") || lower.starts_with("proxy-authorization:") {
                        log.lock().unwrap().push(format!("  {line}"));
                    }
                }
                log.lock().unwrap().insert(0, first.clone());
                let reply = if first.starts_with("CONNECT") {
                    "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_string()
                } else {
                    format!("HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len())
                };
                let _ = sock.write_all(reply.as_bytes()).await;
                let _ = sock.shutdown().await;
            });
        }
    });
    (port, seen)
}

#[test]
fn clients_use_the_proxies_of_the_environment() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let (proxy, proxied) = recording_server("proxied").await;
        let (direct, _) = recording_server("direct").await;
        let proxy_url = format!("http://us:pw@127.0.0.1:{proxy}");
        let get = |env: ProxyEnv, target: String| async move {
            let client = crate::net::plain_client_with(&NetSettings::default(), env).unwrap();
            match client.get(&target).send().await {
                Ok(res) => res.text().await.unwrap_or_default(),
                Err(e) => format!("error: {e}"),
            }
        };
        // An HTTP request through http_proxy, in absolute form, with the
        // proxy's credentials.
        let body = get(proxies(&[("http_proxy", &proxy_url)]), "http://channel.invalid/chA/x".into()).await;
        assert_eq!(body, "proxied");
        let log = proxied.lock().unwrap().clone();
        assert_eq!(log[0], "GET http://channel.invalid/chA/x HTTP/1.1");
        assert!(log.iter().any(|l| l == "  proxy-authorization: Basic dXM6cHc="), "{log:?}");
        // HTTP_PROXY is not used, and no_proxy goes direct.
        let target = format!("http://127.0.0.1:{direct}/x");
        assert_eq!(get(proxies(&[("HTTP_PROXY", &proxy_url)]), target.clone()).await, "direct");
        assert_eq!(
            get(proxies(&[("all_proxy", &proxy_url), ("no_proxy", "127.0.0.1")]), target.clone()).await,
            "direct"
        );
        assert_eq!(get(proxies(&[("all_proxy", &proxy_url)]), target.clone()).await, "proxied");
        // HTTPS through https_proxy: a CONNECT tunnel (refused here).
        proxied.lock().unwrap().clear();
        let body = get(proxies(&[("HTTPS_PROXY", &proxy_url)]), "https://channel.invalid/x".into()).await;
        assert!(body.starts_with("error:"), "{body}");
        assert_eq!(proxied.lock().unwrap()[0], "CONNECT channel.invalid:443 HTTP/1.1");
    });
}

#[test]
fn https_trusts_only_the_bundle_libmamba_chooses() {
    let dir = tls_dir();
    let identity = crate::testserver::identity(&dir.join("server.pem"), &dir.join("server-key.der")).unwrap();
    let files = tempfile::tempdir().unwrap();
    std::fs::write(files.path().join("hello.txt"), "hello").unwrap();
    let log = files.path().join("log.txt");
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let (port, serve) = crate::testserver::bind(files.path().to_path_buf(), identity, Some(log.clone()))
            .await
            .unwrap();
        tokio::spawn(serve);
        let target = format!("https://127.0.0.1:{port}/hello.txt");
        let get = |settings: NetSettings| {
            let target = target.clone();
            async move {
                let client = crate::net::plain_client_with(&settings, ProxyEnv::default()).unwrap();
                client.get(&target).send().await
            }
        };
        // The test CA in the root's bundle: trusted, and only it.
        let root = tempfile::tempdir().unwrap();
        let bundle = root_ca_bundle(root.path());
        std::fs::create_dir_all(bundle.parent().unwrap()).unwrap();
        std::fs::copy(dir.join("ca.pem"), &bundle).unwrap();
        let settings = NetSettings::new(Some(root.path().to_string_lossy().to_string()));
        let res = get(settings).await.unwrap();
        assert_eq!(res.status(), 200);
        assert_eq!(res.text().await.unwrap(), "hello");
        // Without it, the system's trust does not know the test CA.
        let err = get(NetSettings::default()).await.unwrap_err();
        assert!(crate::error::error_chain(&err).to_lowercase().contains("certif"), "{err:?}");
        // A HEAD request, and a file that is not there.
        let client = crate::net::plain_client_with(
            &NetSettings::new(Some(root.path().to_string_lossy().to_string())),
            ProxyEnv::default(),
        )
        .unwrap();
        assert_eq!(client.head(&target).send().await.unwrap().status(), 200);
        let missing = format!("https://127.0.0.1:{port}/missing");
        assert_eq!(client.get(&missing).send().await.unwrap().status(), 404);
    });
    let logged = std::fs::read_to_string(&log).unwrap();
    assert!(logged.contains("GET /hello.txt HTTP/1.1"), "{logged}");
    assert!(logged.contains("HEAD /hello.txt HTTP/1.1"), "{logged}");
}

#[test]
fn clients_send_the_credentials_of_the_files() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let (port, seen) = recording_server("ok").await;
        let creds = Credentials {
            db: AuthDb::parse(&format!(r#"{{"127.0.0.1:{port}": {{"type": "BearerToken", "token": "bear"}}}}"#)),
            netrc: Netrc::default(),
        };
        let client = reqwest_middleware::ClientBuilder::new(
            crate::net::plain_client_with(&NetSettings::default(), ProxyEnv::default()).unwrap(),
        )
        .with(CredentialsMiddleware::new(creds))
        .build();
        let res = client.get(format!("http://127.0.0.1:{port}/chA/x")).send().await.unwrap();
        assert_eq!(res.status(), 200);
        let log = seen.lock().unwrap().clone();
        assert_eq!(log[0], "GET /chA/x HTTP/1.1");
        assert!(log.iter().any(|l| l == "  authorization: Bearer bear"), "{log:?}");
    });
}
