//! A small HTTPS file server for the network tests (`rt_test_https_server()`
//! and the Rust tests of `netenv.rs`): it serves the files below a
//! directory over TLS on `127.0.0.1`, answers `GET` and `HEAD` (404 for
//! anything else), one request per connection, and appends every request
//! line and its `Authorization` header to a log file. R has no TLS server,
//! and the test machines have no common one that micromamba's requests
//! work with.

use std::path::{Path, PathBuf};

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::error::{RtError, RtResult};

/// The server's identity: a PEM certificate (chain) and its private key, a
/// DER PKCS#8 file (kept as DER so the test fixtures hold no PEM key).
pub fn identity(cert_pem: &Path, key_der: &Path) -> RtResult<native_tls::Identity> {
    let cert = std::fs::read(cert_pem).map_err(|e| RtError::io_at(format!("cannot read {}", cert_pem.display()), e))?;
    let key = std::fs::read(key_der).map_err(|e| RtError::io_at(format!("cannot read {}", key_der.display()), e))?;
    let pem = pem_encode("PRIVATE KEY", &key);
    native_tls::Identity::from_pkcs8(&cert, pem.as_bytes())
        .map_err(|e| RtError::Internal(format!("invalid test certificate or key: {e}")))
}

fn pem_encode(label: &str, der: &[u8]) -> String {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(der);
    let mut out = format!("-----BEGIN {label}-----\n");
    for chunk in b64.as_bytes().chunks(64) {
        out.push_str(std::str::from_utf8(chunk).unwrap_or(""));
        out.push('\n');
    }
    out.push_str(&format!("-----END {label}-----\n"));
    out
}

/// Binds the server; the returned future serves until it is dropped.
pub async fn bind(
    root: PathBuf,
    identity: native_tls::Identity,
    log: Option<PathBuf>,
) -> RtResult<(u16, impl std::future::Future<Output = ()>)> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| RtError::io_at("cannot bind the test server".to_string(), e))?;
    let port = listener
        .local_addr()
        .map_err(|e| RtError::io_at("cannot bind the test server".to_string(), e))?
        .port();
    let acceptor = native_tls::TlsAcceptor::new(identity)
        .map_err(|e| RtError::Internal(format!("cannot start TLS: {e}")))?;
    let acceptor = std::sync::Arc::new(tokio_native_tls::TlsAcceptor::from(acceptor));
    let serve = async move {
        loop {
            let Ok((socket, _)) = listener.accept().await else {
                continue;
            };
            let acceptor = acceptor.clone();
            let root = root.clone();
            let log = log.clone();
            tokio::spawn(async move {
                if let Ok(stream) = acceptor.accept(socket).await {
                    let _ = respond(stream, &root, log.as_deref()).await;
                }
            });
        }
    };
    Ok((port, serve))
}

async fn respond<S>(mut stream: S, root: &Path, log: Option<&Path>) -> std::io::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut head = Vec::new();
    let mut buf = [0u8; 4096];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
        if head.len() > 64 * 1024 {
            return Ok(());
        }
    }
    let text = String::from_utf8_lossy(&head).to_string();
    let mut lines = text.split("\r\n");
    let request_line = lines.next().unwrap_or("").to_string();
    let auth = lines
        .take_while(|l| !l.is_empty())
        .find(|l| l.to_ascii_lowercase().starts_with("authorization:"))
        .map(str::to_string);
    if let Some(log) = log {
        let mut entry = format!("{request_line}\n");
        if let Some(auth) = &auth {
            entry.push_str(&format!("  {auth}\n"));
        }
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(log) {
            use std::io::Write;
            let _ = f.write_all(entry.as_bytes());
        }
    }
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let path = crate::channels::percent_decode(target.split(['?', '#']).next().unwrap_or("/"));
    let file = root.join(path.trim_start_matches('/'));
    let safe = !path.split('/').any(|c| c == "..");
    let body = if matches!(method, "GET" | "HEAD") && safe && file.is_file() {
        std::fs::read(&file).ok()
    } else {
        None
    };
    match body {
        Some(body) => {
            let headers = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(headers.as_bytes()).await?;
            if method == "GET" {
                stream.write_all(&body).await?;
            }
        }
        None => {
            stream
                .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .await?;
        }
    }
    stream.flush().await?;
    stream.shutdown().await
}

/// `rt_test_https_server()`: binds, writes the port to `port_file` (through a
/// temporary file, so a reader never sees half of it), and serves forever on
/// the calling thread. Run it in a process of its own.
pub fn serve_forever(root: PathBuf, cert_pem: PathBuf, key_der: PathBuf, port_file: PathBuf, log: Option<PathBuf>) -> RtResult<()> {
    let identity = identity(&cert_pem, &key_der)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| RtError::Internal(format!("cannot start the test server: {e}")))?;
    runtime.block_on(async move {
        let (port, serve) = bind(root, identity, log).await?;
        let tmp = port_file.with_extension("tmp");
        std::fs::write(&tmp, port.to_string()).map_err(|e| RtError::io_at(format!("cannot write {}", tmp.display()), e))?;
        std::fs::rename(&tmp, &port_file)
            .map_err(|e| RtError::io_at(format!("cannot write {}", port_file.display()), e))?;
        serve.await;
        Ok(())
    })
}
