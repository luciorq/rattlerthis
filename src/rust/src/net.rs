//! The HTTP client of a job, with libmamba's network behavior.
//!
//! libmamba 2.10 (`context.hpp` `remote_fetch_params`, `download/downloader.cpp`):
//! a 10 s connect timeout and up to 3 retries. An HTTP 413, 429 or 5xx
//! answer is retried after the server's `Retry-After` (curl's
//! `CURLINFO_RETRY_AFTER`), and at once when the answer has none; a
//! transfer error (other than a few curl configuration errors) is retried
//! 2 s after the failure (`retry_timeout`). `file://` URLs are never
//! retried. Its stall limit (below 30 bytes/s for 60 s) is approximated by a
//! 60 s read timeout, and a `Retry-After` above 60 s is capped at 60 s (the
//! user can always interrupt; libmamba waits as long as the server asks).
//! `Retry-After` is read in its seconds form; an HTTP date counts as none.
//!
//! One client is built per job and dropped with it. It is used for repodata
//! (rattler's gateway) and, with the `wheels` feature, for wheels.
//!
//! Every client honors the proxies, certificates and credentials micromamba
//! honors when condathis runs it, and only those (`netenv.rs`): libcurl's
//! proxy variables (never the system's proxy settings), the CA bundle
//! libmamba chooses (never `SSL_CERT_FILE` or `SSL_CERT_DIR`), and
//! `~/.mamba/auth/authentication.json` and `.netrc` credentials.
//!
//! Package downloads (the prefetch phase, explicit installs and the
//! `Installer`) use [`download_client()`], whose middleware retries only
//! HTTP statuses: their transport errors are retried by the download loop
//! around them (`pkgfile::download()`, [`MAX_RETRIES`] times,
//! [`RETRY_WAIT`] apart), which also retries a body that breaks off after
//! the response. A transport retry in both would multiply the attempts
//! (4 x 4).

use std::time::Duration;

use reqwest_middleware::{ClientWithMiddleware, Middleware, Next};

use crate::error::{RtError, RtResult};
use crate::netenv::{Credentials, CredentialsMiddleware, NetSettings, ProxyEnv, Trust};

pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
pub const READ_TIMEOUT: Duration = Duration::from_secs(60);
pub const MAX_RETRIES: u32 = 3;
pub const RETRY_WAIT: Duration = Duration::from_secs(2);

const USER_AGENT: &str = concat!("rattlerthis/", env!("CARGO_PKG_VERSION"));

/// The plain `reqwest` client (no middleware): the timeouts, the proxies of
/// the process environment as libcurl reads them, and the certificates
/// libmamba trusts (see `netenv.rs`). The environment and the CA bundle
/// are read when the client is built.
pub fn plain_client(settings: &NetSettings) -> RtResult<reqwest::Client> {
    plain_client_with(settings, ProxyEnv::from_process())
}

/// [`plain_client()`] with the given proxy variables.
pub fn plain_client_with(settings: &NetSettings, proxies: ProxyEnv) -> RtResult<reqwest::Client> {
    let builder = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(CONNECT_TIMEOUT)
        .read_timeout(READ_TIMEOUT)
        // No system proxy settings (the Windows registry, macOS's network
        // settings): only libcurl's variables.
        .no_proxy()
        .proxy(reqwest::Proxy::custom(move |url| proxies.proxy_for(url)));
    let builder = match crate::netenv::trust_for(settings.root.as_deref(), &|p| p.is_file()) {
        Trust::System => builder,
        Trust::Bundle(bundle) => {
            // An unreadable or invalid bundle trusts nothing, as curl's
            // `CURLOPT_CAINFO` with such a file.
            let certs = std::fs::read(&bundle)
                .ok()
                .and_then(|pem| reqwest::Certificate::from_pem_bundle(&pem).ok())
                .unwrap_or_default();
            builder.tls_certs_only(certs)
        }
        Trust::Nothing => builder.tls_certs_only(Vec::new()),
    };
    builder
        .build()
        .map_err(|e| RtError::Fetch(format!("failed to build the HTTP client: {e}")))
}

/// The client of a job: [`plain_client()`] plus the credentials of the
/// process (`netenv.rs`) and [`RetryMiddleware`].
pub fn client(settings: &NetSettings) -> RtResult<ClientWithMiddleware> {
    Ok(reqwest_middleware::ClientBuilder::new(plain_client(settings)?)
        .with(CredentialsMiddleware::new(Credentials::from_process()))
        .with(RetryMiddleware::default())
        .build())
}

/// The client for package downloads: [`plain_client()`] plus the
/// credentials and a [`RetryMiddleware`] that retries HTTP statuses only
/// (see the module docs).
pub fn download_client(settings: &NetSettings) -> RtResult<ClientWithMiddleware> {
    Ok(reqwest_middleware::ClientBuilder::new(plain_client(settings)?)
        .with(CredentialsMiddleware::new(Credentials::from_process()))
        .with(RetryMiddleware::statuses_only())
        .build())
}

/// The job's client, built on first use (rattler's `LazyClient`): a job that
/// only reads local channels never builds it, so it never initializes the
/// TLS library.
pub fn lazy_client(settings: &NetSettings) -> rattler_networking::LazyClient {
    let settings = settings.clone();
    rattler_networking::LazyClient::new(move || client(&settings).expect("failed to build the HTTP client"))
}

/// [`download_client()`], built on first use.
pub fn lazy_download_client(settings: &NetSettings) -> rattler_networking::LazyClient {
    let settings = settings.clone();
    rattler_networking::LazyClient::new(move || download_client(&settings).expect("failed to build the HTTP client"))
}

/// Refuses network work in a forked child on macOS.
///
/// macOS does not let a forked process use CoreFoundation once its parent
/// has (the process aborts: "The process has forked and you cannot use this
/// CoreFoundation functionality safely"), and the system TLS library
/// (`native-tls`, Security.framework) is built on it. A fork of an R session
/// that used rattlerthis (`parallel::mcparallel()`, `mclapply()`) therefore
/// gets this classed error instead of a crash when it would need an HTTP
/// client; local channels and the activation still work there. micromamba
/// starts a new process for every command, so it has no such limit.
pub fn ensure_http_allowed<'a>(urls: impl IntoIterator<Item = &'a url::Url>) -> RtResult<()> {
    if !cfg!(target_os = "macos") || !crate::runtime::is_forked_child() {
        return Ok(());
    }
    match urls
        .into_iter()
        .find(|u| matches!(u.scheme(), "http" | "https"))
    {
        None => Ok(()),
        Some(url) => Err(RtError::Fetch(format!(
            "cannot download from {url} in a forked R process on macOS: macOS does not let a \
             fork use the system TLS library once the parent has. Use a PSOCK cluster \
             (`parallel::makeCluster()`) or a new R process (callr) instead of \
             `parallel::mclapply()` or `parallel::mcparallel()`"
        ))),
    }
}

/// Whether an HTTP status is retried by libmamba.
pub fn status_is_retryable(status: reqwest::StatusCode) -> bool {
    status == reqwest::StatusCode::PAYLOAD_TOO_LARGE
        || status == reqwest::StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error()
}

/// Whether a transport error is retried: connection failures, timeouts and
/// broken transfers. Errors that come from building the request (an invalid
/// URL, a body that cannot be cloned) are not.
fn error_is_retryable(err: &reqwest_middleware::Error) -> bool {
    match err {
        reqwest_middleware::Error::Reqwest(e) => {
            !e.is_builder() && !e.is_redirect() && !e.is_status() && !e.is_decode()
        }
        reqwest_middleware::Error::Middleware(_) => false,
    }
}

fn retry_after(response: &reqwest::Response) -> Option<Duration> {
    let value = response.headers().get(reqwest::header::RETRY_AFTER)?;
    let secs: u64 = value.to_str().ok()?.trim().parse().ok()?;
    // A server asking for minutes is capped; the user can always interrupt.
    Some(Duration::from_secs(secs.min(60)))
}

/// Retries a request the way libmamba's downloader does: an HTTP status
/// after `Retry-After` (else at once), a transport error after `wait`
/// (unless `transport` is off).
#[derive(Clone, Debug)]
pub struct RetryMiddleware {
    max_retries: u32,
    wait: Duration,
    transport: bool,
}

impl Default for RetryMiddleware {
    fn default() -> Self {
        Self {
            max_retries: MAX_RETRIES,
            wait: RETRY_WAIT,
            transport: true,
        }
    }
}

impl RetryMiddleware {
    /// Retries HTTP statuses, not transport errors.
    pub fn statuses_only() -> Self {
        Self {
            transport: false,
            ..Self::default()
        }
    }
}

#[async_trait::async_trait]
impl Middleware for RetryMiddleware {
    async fn handle(
        &self,
        req: reqwest::Request,
        extensions: &mut http::Extensions,
        next: Next<'_>,
    ) -> reqwest_middleware::Result<reqwest::Response> {
        let mut retries = 0u32;
        loop {
            // A request whose body cannot be cloned is sent once.
            let Some(attempt) = req.try_clone() else {
                return next.run(req, extensions).await;
            };
            let result = next.clone().run(attempt, extensions).await;
            let wait = match &result {
                Ok(response) if status_is_retryable(response.status()) => {
                    retry_after(response).unwrap_or(Duration::ZERO)
                }
                Err(err) if self.transport && error_is_retryable(err) => self.wait,
                _ => return result,
            };
            if retries >= self.max_retries {
                return result;
            }
            retries += 1;
            drop(result);
            tokio::time::sleep(wait).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// A local HTTP server that answers the first `fail` requests with
    /// `status` (with `Retry-After: 0`) and the rest with 200 "ok".
    async fn flaky_server(fail: usize, status: u16) -> (String, Arc<AtomicUsize>) {
        flaky_server_with(fail, status, "retry-after: 0\r\n").await
    }

    async fn flaky_server_with(fail: usize, status: u16, extra: &'static str) -> (String, Arc<AtomicUsize>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let hits = Arc::new(AtomicUsize::new(0));
        let counter = hits.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let n = counter.fetch_add(1, Ordering::SeqCst);
                tokio::spawn(async move {
                    let mut buf = [0u8; 4096];
                    let _ = sock.read(&mut buf).await;
                    let (code, body) = if n < fail { (status, "no") } else { (200, "ok") };
                    let extra = if n < fail { extra } else { "" };
                    let reply = format!(
                        "HTTP/1.1 {code} X\r\ncontent-length: {}\r\n{extra}connection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = sock.write_all(reply.as_bytes()).await;
                    let _ = sock.shutdown().await;
                });
            }
        });
        (format!("http://{addr}/x"), hits)
    }

    fn fast_client() -> ClientWithMiddleware {
        reqwest_middleware::ClientBuilder::new(plain_client(&NetSettings::default()).unwrap())
            .with(RetryMiddleware {
                max_retries: MAX_RETRIES,
                wait: Duration::from_millis(10),
                transport: true,
            })
            .build()
    }

    #[test]
    fn server_errors_are_retried_three_times() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (url, hits) = flaky_server(3, 503).await;
            let res = fast_client().get(&url).send().await.unwrap();
            assert_eq!(res.status(), 200);
            assert_eq!(hits.load(Ordering::SeqCst), 4);

            let (url, hits) = flaky_server(10, 500).await;
            let res = fast_client().get(&url).send().await.unwrap();
            assert_eq!(res.status(), 500, "gives up after 3 retries");
            assert_eq!(hits.load(Ordering::SeqCst), 4);

            let (url, hits) = flaky_server(10, 404).await;
            let res = fast_client().get(&url).send().await.unwrap();
            assert_eq!(res.status(), 404, "a 404 is not retried");
            assert_eq!(hits.load(Ordering::SeqCst), 1);

            let (url, hits) = flaky_server(1, 429).await;
            let res = fast_client().get(&url).send().await.unwrap();
            assert_eq!(res.status(), 200);
            assert_eq!(hits.load(Ordering::SeqCst), 2);
        });
    }

    /// libmamba retries an HTTP error without `Retry-After` at once, and
    /// waits for `Retry-After` when the server sends it.
    #[test]
    fn server_errors_wait_only_for_retry_after() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let client = reqwest_middleware::ClientBuilder::new(plain_client(&NetSettings::default()).unwrap())
                .with(RetryMiddleware::default())
                .build();
            let (url, hits) = flaky_server_with(3, 503, "").await;
            let start = std::time::Instant::now();
            let res = client.get(&url).send().await.unwrap();
            assert_eq!(res.status(), 200);
            assert_eq!(hits.load(Ordering::SeqCst), 4);
            assert!(start.elapsed() < Duration::from_secs(1), "{:?}", start.elapsed());

            let (url, hits) = flaky_server_with(1, 503, "retry-after: 1\r\n").await;
            let start = std::time::Instant::now();
            let res = client.get(&url).send().await.unwrap();
            assert_eq!(res.status(), 200);
            assert_eq!(hits.load(Ordering::SeqCst), 2);
            assert!(start.elapsed() >= Duration::from_millis(900), "{:?}", start.elapsed());
        });
    }

    #[test]
    fn connection_errors_are_retried() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            // A port that was just free: connections are refused.
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = listener.local_addr().unwrap();
            drop(listener);
            let start = std::time::Instant::now();
            let err = fast_client()
                .get(format!("http://{addr}/x"))
                .send()
                .await
                .unwrap_err();
            assert!(error_is_retryable(&err));
            // 3 retries of 10 ms each.
            assert!(start.elapsed() >= Duration::from_millis(30));
        });
    }

    /// Package downloads: statuses are retried here, transport errors by the
    /// download loop around the request (rattler's cache, `explicit.rs`), so
    /// a broken connection is tried 4 times in all, not 16.
    #[test]
    fn download_client_leaves_transport_errors_to_the_download_loop() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (url, hits) = flaky_server_with(3, 503, "").await;
            let res = download_client(&NetSettings::default()).unwrap().get(&url).send().await.unwrap();
            assert_eq!(res.status(), 200);
            assert_eq!(hits.load(Ordering::SeqCst), 4);
            // A server that closes every connection at once: a transport
            // error, sent once by the download client, 4 times by the job's
            // client.
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let accepted = Arc::new(AtomicUsize::new(0));
            let counter = accepted.clone();
            tokio::spawn(async move {
                while let Ok((sock, _)) = listener.accept().await {
                    counter.fetch_add(1, Ordering::SeqCst);
                    drop(sock);
                }
            });
            let url = format!("http://{addr}/x");
            let err = download_client(&NetSettings::default()).unwrap().get(&url).send().await.unwrap_err();
            assert!(error_is_retryable(&err), "{err}");
            assert_eq!(accepted.load(Ordering::SeqCst), 1);
            fast_client().get(&url).send().await.unwrap_err();
            assert_eq!(accepted.load(Ordering::SeqCst), 1 + 4);
        });
    }

}
