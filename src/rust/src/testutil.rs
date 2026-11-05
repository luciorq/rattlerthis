//! Test helpers: tiny local conda channels and a throttled HTTP server.
//!
//! Channels are built in a temporary directory with `noarch: generic` (or
//! `noarch: python`) packages (`.tar.bz2`, written by
//! `rattler_package_streaming`), a `noarch/repodata.json` and an empty
//! `repodata.json` for the subdir of this platform, so tests need no
//! network.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use rattler_conda_types::compression_level::CompressionLevel;
use rattler_conda_types::Platform;
use rattler_digest::{compute_bytes_digest, Md5, Sha256};
use serde_json::json;

use crate::job::{Job, JobOutput, PollResult};

#[derive(Clone, Debug)]
pub struct TestPkg {
    pub name: String,
    pub version: String,
    pub build: String,
    pub depends: Vec<String>,
    /// `(relative path, contents)`.
    pub files: Vec<(String, Vec<u8>)>,
    /// `noarch: python` instead of `noarch: generic`.
    pub noarch_python: bool,
}

impl TestPkg {
    pub fn new(name: &str, version: &str) -> Self {
        TestPkg {
            name: name.into(),
            version: version.into(),
            build: "0".into(),
            depends: Vec::new(),
            files: vec![(format!("share/{name}/README"), format!("{name} {version}\n").into_bytes())],
            noarch_python: false,
        }
    }

    pub fn noarch_python(mut self) -> Self {
        self.noarch_python = true;
        self.files.clear();
        self
    }

    pub fn depends(mut self, dep: &str) -> Self {
        self.depends.push(dep.into());
        self
    }

    pub fn file(mut self, path: &str, contents: impl Into<Vec<u8>>) -> Self {
        self.files.push((path.into(), contents.into()));
        self
    }

    pub fn file_name(&self) -> String {
        format!("{}-{}-{}.tar.bz2", self.name, self.version, self.build)
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn build_package(pkg: &TestPkg, out: &Path) -> serde_json::Value {
    let stage = tempfile::tempdir().unwrap();
    let base = stage.path();
    let mut paths = Vec::new();
    let mut entries = Vec::new();
    for (rel, contents) in &pkg.files {
        let p = base.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, contents).unwrap();
        paths.push(p.clone());
        entries.push(json!({
            "_path": rel,
            "path_type": "hardlink",
            "sha256": hex(&compute_bytes_digest::<Sha256>(contents)),
            "size_in_bytes": contents.len(),
        }));
    }
    let index = json!({
        "name": pkg.name,
        "version": pkg.version,
        "build": pkg.build,
        "build_number": 0,
        "depends": pkg.depends,
        "subdir": "noarch",
        "noarch": if pkg.noarch_python { "python" } else { "generic" },
        "license": "MIT",
        "timestamp": 1700000000000u64,
    });
    let info = base.join("info");
    std::fs::create_dir_all(&info).unwrap();
    std::fs::write(info.join("index.json"), index.to_string()).unwrap();
    std::fs::write(
        info.join("paths.json"),
        json!({"paths": entries, "paths_version": 1}).to_string(),
    )
    .unwrap();
    let files: String = pkg.files.iter().map(|(r, _)| format!("{r}\n")).collect();
    std::fs::write(info.join("files"), files).unwrap();
    paths.push(info.join("index.json"));
    paths.push(info.join("paths.json"));
    paths.push(info.join("files"));

    let archive = out.join(pkg.file_name());
    let file = std::fs::File::create(&archive).unwrap();
    rattler_package_streaming::write::write_tar_bz2_package(
        file,
        base,
        &paths,
        CompressionLevel::Default,
        None,
        None,
    )
    .unwrap();
    let bytes = std::fs::read(&archive).unwrap();
    let mut record = index;
    record["md5"] = json!(hex(&compute_bytes_digest::<Md5>(&bytes)));
    record["sha256"] = json!(hex(&compute_bytes_digest::<Sha256>(&bytes)));
    record["size"] = json!(bytes.len());
    record
}

fn write_repodata(dir: &Path, subdir: &str, packages: BTreeMap<String, serde_json::Value>) {
    std::fs::create_dir_all(dir).unwrap();
    let repodata = json!({
        "info": {"subdir": subdir},
        "packages": packages,
        "packages.conda": {},
        "repodata_version": 1,
    });
    std::fs::write(dir.join("repodata.json"), repodata.to_string()).unwrap();
}

/// Builds `<root>/<name>` with `pkgs` and returns its path.
pub fn make_channel(root: &Path, name: &str, pkgs: &[TestPkg]) -> PathBuf {
    let dir = root.join(name);
    let noarch = dir.join("noarch");
    std::fs::create_dir_all(&noarch).unwrap();
    let mut records = BTreeMap::new();
    for pkg in pkgs {
        records.insert(pkg.file_name(), build_package(pkg, &noarch));
    }
    write_repodata(&noarch, "noarch", records);
    let native = Platform::current().to_string();
    write_repodata(&dir.join(&native), &native, BTreeMap::new());
    dir
}

/// Waits for a job (polling like R does) and returns its output or message.
pub fn wait(job: &Job) -> Result<JobOutput, String> {
    loop {
        match job.poll() {
            PollResult::Running => std::thread::sleep(Duration::from_millis(5)),
            PollResult::Done(out) => return Ok(out),
            PollResult::Failed(msg) => return Err(msg),
        }
    }
}

/// A local HTTP server for the files under `root`, which sends no cache
/// headers (no `ETag`, `Last-Modified` or `Cache-Control`). Files ending in
/// `.tar.bz2` are sent `chunk` bytes at a time with `pause` between chunks.
/// Returns the base URL, a counter of package requests started and one of
/// `repodata.json` requests.
pub struct SlowServer {
    pub url: String,
    pub package_requests: Arc<AtomicUsize>,
    pub repodata_requests: Arc<AtomicUsize>,
    _runtime: tokio::runtime::Runtime,
}

pub fn slow_server(root: PathBuf, chunk: usize, pause: Duration) -> SlowServer {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let listener = runtime
        .block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))
        .unwrap();
    let addr = listener.local_addr().unwrap();
    let counter = Arc::new(AtomicUsize::new(0));
    let hits = counter.clone();
    let repodata = Arc::new(AtomicUsize::new(0));
    let repodata_hits = repodata.clone();
    runtime.spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            let root = root.clone();
            let hits = hits.clone();
            let repodata_hits = repodata_hits.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = req
                    .lines()
                    .next()
                    .and_then(|l| l.split_whitespace().nth(1))
                    .unwrap_or("/")
                    .trim_start_matches('/')
                    .to_string();
                if path.ends_with("/repodata.json") {
                    repodata_hits.fetch_add(1, Ordering::SeqCst);
                }
                let file = root.join(&path);
                let Ok(body) = std::fs::read(&file) else {
                    let _ = sock
                        .write_all(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                        .await;
                    return;
                };
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-length: {}\r\ncontent-type: application/octet-stream\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                if sock.write_all(head.as_bytes()).await.is_err() {
                    return;
                }
                if path.ends_with(".tar.bz2") {
                    hits.fetch_add(1, Ordering::SeqCst);
                    for part in body.chunks(chunk) {
                        if sock.write_all(part).await.is_err() {
                            return;
                        }
                        tokio::time::sleep(pause).await;
                    }
                } else {
                    let _ = sock.write_all(&body).await;
                }
                let _ = sock.shutdown().await;
            });
        }
    });
    SlowServer {
        url: format!("http://{addr}"),
        package_requests: counter,
        repodata_requests: repodata,
        _runtime: runtime,
    }
}
