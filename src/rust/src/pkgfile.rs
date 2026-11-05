//! Package archives into the package cache, with micromamba's file modes.
//!
//! micromamba 2.10.0 extracts with libarchive and `ARCHIVE_EXTRACT_PERM`
//! (`libmamba/src/core/package_handling.cpp`), so every file of a package
//! keeps the mode its archive gives it, whatever the process umask, and
//! environments get those modes through their hard links (directories, made
//! while linking, follow the umask with both). rattler's extraction
//! (`rattler_package_streaming`) creates each file with the umask applied to
//! 0666 and adds 0111 when the archive mode has an execute bit: under umask
//! 027 a 644 file became 640 and a 755 one 751 (measured 2026-10-29 against
//! micromamba's 644 and 755).
//!
//! So rattlerthis extracts from a local file (downloads go to a temporary
//! file next to the cache entry first) and then gives each regular file of
//! the new cache entry the permission bits of its archive entry
//! ([`apply_archive_modes()`]); setuid and setgid bits are never set. Cache
//! entries extracted before are left as they are.

use std::path::{Path, PathBuf};
use std::time::Duration;

use rattler_networking::LazyClient;
use rattler_package_streaming::{ExtractError, ExtractResult};
use url::Url;

/// Why fetching an archive into the cache failed.
#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error(transparent)]
    Extract(#[from] ExtractError),
    #[error("{0}")]
    Http(String),
}

impl FetchError {
    /// A connection that failed, timed out or broke off: worth another try
    /// (HTTP statuses are retried by the client's middleware).
    fn should_retry(&self) -> bool {
        match self {
            FetchError::Extract(e) => e.should_retry(),
            FetchError::Http(_) => false,
        }
    }
}

/// The archive type of a URL or path by its file name (`.conda` or
/// `.tar.bz2`), as rattler decides it.
fn archive_suffix(name: &str) -> Option<&'static str> {
    if name.ends_with(".conda") {
        Some(".conda")
    } else if name.ends_with(".tar.bz2") {
        Some(".tar.bz2")
    } else {
        None
    }
}

/// Downloads `url` into a new temporary file in `dir` (deleted when the
/// returned path is dropped), with the archive's suffix so that it is
/// extracted as its type.
async fn download_once(client: &LazyClient, url: &Url, dir: &Path) -> Result<tempfile::TempPath, FetchError> {
    let suffix = archive_suffix(url.path()).ok_or(FetchError::Extract(ExtractError::UnsupportedArchiveType))?;
    let file = tempfile::Builder::new()
        .prefix(".rattlerthis-download-")
        .suffix(suffix)
        .tempfile_in(dir)
        .map_err(|e| FetchError::Extract(ExtractError::IoError(e)))?;
    let (file, path) = file.into_parts();
    let mut file = tokio::fs::File::from_std(file);
    let mut response = client
        .client()
        .get(url.clone())
        .send()
        .await
        .map_err(|e| FetchError::Extract(ExtractError::ReqwestError(e)))?;
    if !response.status().is_success() {
        return Err(FetchError::Http(format!(
            "HTTP status {} for {}",
            response.status(),
            crate::secrets::hide_url(url)
        )));
    }
    use tokio::io::AsyncWriteExt;
    loop {
        match response.chunk().await {
            Ok(Some(bytes)) => file
                .write_all(&bytes)
                .await
                .map_err(|e| FetchError::Extract(ExtractError::IoError(e)))?,
            Ok(None) => break,
            // A body that breaks off after a good response.
            Err(e) => {
                return Err(FetchError::Extract(ExtractError::IoError(std::io::Error::other(e))));
            }
        }
    }
    file.flush()
        .await
        .map_err(|e| FetchError::Extract(ExtractError::IoError(e)))?;
    drop(file);
    Ok(path)
}

/// [`download_once()`] with the retries of package downloads: a failed
/// connection, a timeout or a broken body is tried again `retries` times,
/// `wait` apart, as rattler's package cache retries them; HTTP statuses
/// are left to the client's middleware.
pub async fn download(
    client: &LazyClient,
    url: &Url,
    dir: &Path,
    retries: u32,
    wait: Duration,
) -> Result<tempfile::TempPath, FetchError> {
    let mut tries = 0u32;
    loop {
        tries += 1;
        match download_once(client, url, dir).await {
            Ok(path) => return Ok(path),
            Err(e) if e.should_retry() && tries <= retries => tokio::time::sleep(wait).await,
            Err(e) => return Err(e),
        }
    }
}

/// Extracts a local archive into `destination` (rattler's extraction) and
/// gives its files the archive's modes ([`apply_archive_modes()`]).
pub async fn extract_with_modes(archive: &Path, destination: &Path) -> Result<ExtractResult, ExtractError> {
    let result = rattler_package_streaming::tokio::fs::extract(archive, destination).await?;
    let archive = archive.to_path_buf();
    let destination = destination.to_path_buf();
    tokio::task::spawn_blocking(move || apply_archive_modes(&archive, &destination))
        .await
        .map_err(|e| ExtractError::IoError(std::io::Error::other(e)))?
        .map_err(ExtractError::IoError)?;
    Ok(result)
}

/// The directory a fetch writes its temporary archive to: the parent of
/// the cache entry rattler extracts into.
pub fn download_dir(destination: &Path) -> PathBuf {
    destination
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| destination.to_path_buf())
}

/// Gives every regular file extracted from `archive` into `dir` the
/// permission bits (`0777`) of its archive entry, as libarchive's
/// `ARCHIVE_EXTRACT_PERM` restores them. Entries that are not regular files,
/// paths that leave `dir`, and paths that are not regular files in `dir`
/// (symbolic links are never followed) are skipped. Not on Windows, which
/// has no such modes.
#[cfg(unix)]
pub fn apply_archive_modes(archive: &Path, dir: &Path) -> std::io::Result<()> {
    let name = archive.to_string_lossy();
    let open = || std::fs::File::open(archive);
    let to_io = |e: ExtractError| match e {
        ExtractError::IoError(e) => e,
        other => std::io::Error::other(other),
    };
    if name.ends_with(".conda") {
        let mut info = rattler_package_streaming::seek::stream_conda_info(open()?).map_err(to_io)?;
        apply_entry_modes(&mut info, dir)?;
        let mut content = rattler_package_streaming::seek::stream_conda_content(open()?).map_err(to_io)?;
        apply_entry_modes(&mut content, dir)?;
    } else if name.ends_with(".tar.bz2") {
        let mut archive = rattler_package_streaming::read::stream_tar_bz2(open()?);
        apply_entry_modes(&mut archive, dir)?;
    }
    Ok(())
}

#[cfg(not(unix))]
pub fn apply_archive_modes(_archive: &Path, _dir: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn apply_entry_modes<R: std::io::Read>(archive: &mut tar::Archive<R>, dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    for entry in archive.entries()? {
        let entry = entry?;
        let header = entry.header();
        if !header.entry_type().is_file() {
            continue;
        }
        let mode = header.mode()? & 0o777;
        let path = entry.path()?;
        if !path.components().all(|c| matches!(c, std::path::Component::Normal(_))) {
            continue;
        }
        let target = dir.join(&path);
        match std::fs::symlink_metadata(&target) {
            Ok(meta) if meta.file_type().is_file() && meta.permissions().mode() & 0o7777 != mode => {
                std::fs::set_permissions(&target, std::fs::Permissions::from_mode(mode))?;
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tar stream with the given `(path, contents, mode)` files.
    #[cfg(unix)]
    fn tar_bytes(files: &[(&str, &str, u32)]) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        for (path, contents, mode) in files {
            let mut header = tar::Header::new_gnu();
            header.set_size(contents.len() as u64);
            header.set_mode(*mode);
            header.set_mtime(1_700_000_000);
            header.set_entry_type(tar::EntryType::Regular);
            builder.append_data(&mut header, path, contents.as_bytes()).unwrap();
        }
        builder.into_inner().unwrap()
    }

    #[cfg(unix)]
    const FILES: [(&str, &str, u32); 4] = [
        ("bin/run-me", "#!/bin/sh\necho hi\n", 0o755),
        ("share/modes/group-writable", "x\n", 0o664),
        ("share/modes/private", "x\n", 0o600),
        ("share/modes/plain", "x\n", 0o644),
    ];

    #[cfg(unix)]
    fn write_tar_bz2(path: &Path) {
        use std::io::Write;
        let mut enc = bzip2::write::BzEncoder::new(std::fs::File::create(path).unwrap(), bzip2::Compression::fast());
        let mut all = vec![("info/index.json", "{}", 0o644)];
        all.extend(FILES);
        enc.write_all(&tar_bytes(&all)).unwrap();
        enc.finish().unwrap();
    }

    #[cfg(unix)]
    fn write_conda(path: &Path) {
        use std::io::Write;
        let zst = |files: &[(&str, &str, u32)]| zstd::encode_all(&tar_bytes(files)[..], 3).unwrap();
        let mut zip = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
        let stored = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        zip.start_file("metadata.json", stored).unwrap();
        zip.write_all(br#"{"conda_pkg_format_version": 2}"#).unwrap();
        zip.start_file("info-modes-1.0-0.tar.zst", stored).unwrap();
        zip.write_all(&zst(&[("info/index.json", "{}", 0o600)])).unwrap();
        zip.start_file("pkg-modes-1.0-0.tar.zst", stored).unwrap();
        zip.write_all(&zst(&FILES)).unwrap();
        zip.finish().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn extracted_files_keep_the_archive_modes() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        for (archive, info_mode) in [
            (dir.path().join("modes-1.0-0.tar.bz2"), 0o644),
            (dir.path().join("modes-1.0-0.conda"), 0o600),
        ] {
            if archive.to_string_lossy().ends_with(".conda") {
                write_conda(&archive);
            } else {
                write_tar_bz2(&archive);
            }
            let out = dir.path().join(format!("out-{}", archive.file_name().unwrap().to_string_lossy()));
            let mode = |p: &str| std::fs::metadata(out.join(p)).unwrap().permissions().mode() & 0o7777;
            // Whatever rattler's extraction gave the files (the umask), they
            // end up with the archive's modes, the info files too.
            rt.block_on(extract_with_modes(&archive, &out)).unwrap();
            for (path, _, want) in FILES {
                assert_eq!(mode(path), want, "{path} of {}", archive.display());
            }
            assert_eq!(mode("info/index.json"), info_mode);
            // The modes are put back on files that were changed.
            std::fs::set_permissions(out.join("share/modes/plain"), std::fs::Permissions::from_mode(0o600)).unwrap();
            apply_archive_modes(&archive, &out).unwrap();
            assert_eq!(mode("share/modes/plain"), 0o644);
            // A symbolic link in place of a file is not followed.
            let outside = dir.path().join("outside");
            std::fs::write(&outside, "o").unwrap();
            std::fs::set_permissions(&outside, std::fs::Permissions::from_mode(0o600)).unwrap();
            std::fs::remove_file(out.join("share/modes/plain")).unwrap();
            std::os::unix::fs::symlink(&outside, out.join("share/modes/plain")).unwrap();
            apply_archive_modes(&archive, &out).unwrap();
            assert_eq!(std::fs::metadata(&outside).unwrap().permissions().mode() & 0o7777, 0o600);
            std::fs::remove_file(&outside).unwrap();
        }
    }

    #[test]
    fn downloads_retry_broken_connections() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            // A server whose answers break off after the headers.
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let accepted = std::sync::Arc::new(AtomicUsize::new(0));
            let counter = accepted.clone();
            tokio::spawn(async move {
                while let Ok((mut sock, _)) = listener.accept().await {
                    counter.fetch_add(1, Ordering::SeqCst);
                    let mut buf = [0u8; 4096];
                    let _ = sock.read(&mut buf).await;
                    let _ = sock
                        .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 1000\r\nconnection: close\r\n\r\nabc")
                        .await;
                    drop(sock);
                }
            });
            let dir = tempfile::tempdir().unwrap();
            let client = crate::net::lazy_download_client(&Default::default());
            let url = Url::parse(&format!("http://{addr}/c/noarch/a-1-0.conda")).unwrap();
            let err = download(&client, &url, dir.path(), 3, Duration::from_millis(10)).await.unwrap_err();
            assert!(err.should_retry(), "{err}");
            assert_eq!(accepted.load(Ordering::SeqCst), 4);
            // Nothing is left of the temporary files.
            assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
            // A refused connection is retried too (3 waits).
            let free = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let refused = free.local_addr().unwrap();
            drop(free);
            let url = Url::parse(&format!("http://{refused}/c/noarch/a-1-0.conda")).unwrap();
            let start = std::time::Instant::now();
            assert!(download(&client, &url, dir.path(), 3, Duration::from_millis(50)).await.is_err());
            assert!(start.elapsed() >= Duration::from_millis(150), "{:?}", start.elapsed());
            // A file that is not a package archive is refused before any
            // request.
            let url = Url::parse(&format!("http://{addr}/c/noarch/a.txt")).unwrap();
            assert!(download(&client, &url, dir.path(), 3, Duration::from_millis(10)).await.is_err());
            assert_eq!(accepted.load(Ordering::SeqCst), 4);
        });
    }

    #[test]
    fn archive_types_follow_the_file_name() {
        assert_eq!(archive_suffix("/c/noarch/a-1-0.conda"), Some(".conda"));
        assert_eq!(archive_suffix("/c/noarch/a-1-0.tar.bz2"), Some(".tar.bz2"));
        assert_eq!(archive_suffix("/c/noarch/a-1-0.whl"), None);
    }
}
