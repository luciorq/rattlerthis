//! File locks: the prefix lock of an install and the package cache's global
//! lock, both waited for without blocking a thread, so a cancel can stop the
//! wait.
//!
//! - The prefix lock is an exclusive lock on `<prefix>/conda-meta/conda-meta.lock`,
//!   the file libmamba locks (`LockFile(prefix / "conda-meta")`, which names
//!   it `<dir>/<dir name>.lock`, `libmamba/src/core/util.cpp`). It is held
//!   from before the installed records are read until the history is
//!   written, so two sessions installing into one environment take turns.
//!   As libmamba's `LockFileOwner`, a lock that created its file removes it
//!   again when it is released, so an environment keeps no lock file. The
//!   file is removed while the lock is still held, and every lock checks,
//!   once it holds its file, that the path still names that file (device and
//!   inode, or volume serial number and file index on Windows); when it does
//!   not (the file was removed or replaced while this lock waited), it starts
//!   over with the file now at the path. So removing a lock file never lets
//!   two sessions in at once. libmamba's lock is a POSIX record lock and this
//!   one a `flock(2)` / `LockFileEx` lock, so the two do not exclude each
//!   other; a rattler environment is only ever changed through rattler.
//! - The global cache lock is the one rattler's `Installer` takes
//!   (`<pkgs>/.cache.lock`, `rattler_cache` `CacheGlobalLock`): rattler
//!   coordinates every cross-process access to a package cache through it.
//!   rattler never removes that file, and neither does rattlerthis.

use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use fs4::{FileExt, TryLockError};

use crate::error::{RtError, RtResult};
use crate::job::JobCtx;

const POLL: Duration = Duration::from_millis(50);

/// How long opening a lock file is retried when Windows refuses it. A file
/// removed while another handle is open stays "delete pending" (and cannot
/// be opened) on file systems without POSIX delete semantics, until the
/// session holding that handle notices and closes it.
const DENIED_RETRY_LIMIT: Duration = Duration::from_secs(30);

/// An exclusive file lock, released when dropped.
#[derive(Debug)]
pub struct FileLock {
    file: Option<File>,
    path: PathBuf,
    /// Whether the lock file is removed on release (this lock created it).
    remove: bool,
}

impl FileLock {
    /// Removes the lock file (whoever created it), runs `then` while the
    /// lock is still held, and releases the lock.
    pub fn release_removing(mut self, then: impl FnOnce()) {
        let _ = std::fs::remove_file(&self.path);
        self.remove = false;
        then();
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        if let Some(file) = self.file.take() {
            if self.remove {
                let _ = std::fs::remove_file(&self.path);
            }
            let _ = FileExt::unlock(&file);
        }
    }
}

/// Opens (or creates) the lock file. `Ok(None)` when the file disappeared
/// between the two attempts, which the caller retries.
fn open_lock_file(path: &Path) -> std::io::Result<Option<(File, bool)>> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    match OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(file) => return Ok(Some((file, true))),
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    match OpenOptions::new().read(true).write(true).open(path) {
        Ok(file) => Ok(Some((file, false))),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// The identity of an open file: device and inode.
#[cfg(unix)]
fn file_id(file: &File) -> std::io::Result<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let meta = file.metadata()?;
    Ok((meta.dev(), meta.ino()))
}

/// The identity of an open file: volume serial number and file index.
#[cfg(windows)]
fn file_id(file: &File) -> std::io::Result<(u64, u64)> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
    };
    // SAFETY: a plain query on a handle this `File` owns, into a local.
    unsafe {
        let mut info: BY_HANDLE_FILE_INFORMATION = std::mem::zeroed();
        if GetFileInformationByHandle(file.as_raw_handle() as _, &mut info) == 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok((
            u64::from(info.dwVolumeSerialNumber),
            (u64::from(info.nFileIndexHigh) << 32) | u64::from(info.nFileIndexLow),
        ))
    }
}

/// The identity of the file `path` names now.
fn path_id(path: &Path) -> std::io::Result<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let meta = std::fs::metadata(path)?;
        Ok((meta.dev(), meta.ino()))
    }
    #[cfg(windows)]
    {
        file_id(&File::open(path)?)
    }
}

async fn pause(ctx: Option<&JobCtx>) -> RtResult<()> {
    match ctx {
        Some(ctx) => {
            ctx.cancellable(async {
                tokio::time::sleep(POLL).await;
                Ok(())
            })
            .await
        }
        None => {
            tokio::time::sleep(POLL).await;
            Ok(())
        }
    }
}

/// Takes an exclusive lock on `path` (creating the file and its directory),
/// polling until it is free. Stops with `RtError::Cancelled` when the job is
/// cancelled while waiting. With `remove_if_created`, a lock that created the
/// file removes it again when released.
pub async fn lock_exclusive(
    path: &Path,
    ctx: Option<&JobCtx>,
    remove_if_created: bool,
) -> RtResult<FileLock> {
    let lock_error = |e: std::io::Error| RtError::io_at(format!("failed to lock {}", path.display()), e);
    let start = Instant::now();
    loop {
        let (file, created) = match open_lock_file(path) {
            Ok(Some(opened)) => opened,
            Ok(None) => continue,
            Err(e)
                if cfg!(windows)
                    && e.kind() == ErrorKind::PermissionDenied
                    && start.elapsed() < DENIED_RETRY_LIMIT =>
            {
                pause(ctx).await?;
                continue;
            }
            Err(e) => {
                return Err(RtError::io_at(
                    format!("failed to open lock file {}", path.display()),
                    e,
                ))
            }
        };
        loop {
            match FileExt::try_lock(&file) {
                Ok(()) => break,
                Err(TryLockError::WouldBlock) => pause(ctx).await?,
                Err(TryLockError::Error(e)) => return Err(lock_error(e)),
            }
        }
        let held = file_id(&file).map_err(lock_error)?;
        if path_id(path).is_ok_and(|now| now == held) {
            return Ok(FileLock {
                file: Some(file),
                path: path.to_path_buf(),
                remove: remove_if_created && created,
            });
        }
        // The file was removed (or replaced) while this lock waited for it:
        // whoever holds the file now at the path is not excluded by this
        // lock. Let go and lock that one.
        let _ = FileExt::unlock(&file);
    }
}

/// The prefix lock file of `prefix`.
pub fn prefix_lock_path(prefix: &Path) -> PathBuf {
    prefix.join("conda-meta").join("conda-meta.lock")
}

/// The global lock file of a package cache directory.
pub fn cache_lock_path(pkgs_cache_dir: &Path) -> PathBuf {
    pkgs_cache_dir.join(".cache.lock")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job::{spawn_job, JobOutput, Phase, PollResult};

    fn rt() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }

    fn lock_job(path: &Path) -> crate::job::Job {
        let job_path = path.to_path_buf();
        spawn_job(Phase::Lock, move |ctx| async move {
            let _lock = lock_exclusive(&job_path, Some(&ctx), true).await?;
            Ok(JobOutput::Logical(Some(true)))
        })
    }

    #[test]
    fn a_second_lock_waits_and_can_be_cancelled() {
        let dir = tempfile::tempdir().unwrap();
        let prefix = dir.path().join("env");
        let path = prefix_lock_path(&prefix);
        let rt = rt();
        let first = rt.block_on(lock_exclusive(&path, None, true)).unwrap();
        assert!(path.is_file(), "the lock creates conda-meta/conda-meta.lock");

        // A job that waits for the same lock.
        let job = lock_job(&path);
        std::thread::sleep(Duration::from_millis(200));
        assert!(matches!(job.poll(), PollResult::Running), "waits for the lock");
        assert!(job.cancel());
        match job.wait() {
            PollResult::Failed(msg) => assert!(msg.starts_with("[rattlerthis:cancelled]"), "{msg}"),
            _ => panic!("expected a cancelled job"),
        }

        // Released on drop: the next one gets it.
        let job = lock_job(&path);
        std::thread::sleep(Duration::from_millis(100));
        drop(first);
        assert!(matches!(job.wait(), PollResult::Done(_)));
    }

    #[test]
    fn a_lock_removes_the_file_it_created_and_keeps_an_existing_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = prefix_lock_path(&dir.path().join("env"));
        let rt = rt();
        drop(rt.block_on(lock_exclusive(&path, None, true)).unwrap());
        assert!(!path.exists(), "a created lock file is removed on release");
        assert!(path.parent().unwrap().is_dir());
        std::fs::write(&path, "").unwrap();
        drop(rt.block_on(lock_exclusive(&path, None, true)).unwrap());
        assert!(path.is_file(), "an existing lock file stays");
        drop(rt.block_on(lock_exclusive(&path, None, false)).unwrap());
        assert!(path.is_file());
    }

    /// The race of a lock file removed while another session waits for it:
    /// the waiter (B) must not hold a lock on the removed file while a third
    /// session (C) holds the new file at the same path.
    #[test]
    fn a_removed_lock_file_does_not_let_two_sessions_in() {
        use std::sync::{Arc, Mutex};
        let dir = tempfile::tempdir().unwrap();
        let path = prefix_lock_path(&dir.path().join("env"));
        let held: Arc<Mutex<Vec<(Instant, Instant)>>> = Arc::new(Mutex::new(Vec::new()));
        let holder = |path: &Path| {
            let job_path = path.to_path_buf();
            let held = held.clone();
            spawn_job(Phase::Lock, move |ctx| async move {
                let lock = lock_exclusive(&job_path, Some(&ctx), true).await?;
                let start = Instant::now();
                tokio::time::sleep(Duration::from_millis(250)).await;
                held.lock().unwrap().push((start, Instant::now()));
                drop(lock);
                Ok(JobOutput::Logical(Some(true)))
            })
        };
        let a = rt().block_on(lock_exclusive(&path, None, true)).unwrap();
        // B opens A's file and waits for it.
        let b = holder(&path);
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(b.phase(), Phase::Lock);
        // A removes its file while holding it, then releases; C arrives.
        a.release_removing(|| {});
        let c = holder(&path);
        assert!(matches!(b.wait(), PollResult::Done(_)));
        assert!(matches!(c.wait(), PollResult::Done(_)));
        let mut spans = held.lock().unwrap().clone();
        spans.sort();
        assert_eq!(spans.len(), 2);
        assert!(spans[0].1 <= spans[1].0, "two sessions held the lock at once: {spans:?}");
        assert!(!path.exists());
    }
}
