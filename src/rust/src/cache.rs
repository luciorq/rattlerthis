//! Emptying rattler's caches (`rt_clean_cache()`).
//!
//! Deletes everything in the package cache directory except its global lock
//! file `.cache.lock` (extracted packages, their `<pkg>.lock` metadata files,
//! `cuda-info-v1.json`), and everything in the repodata cache directory.
//! Nothing outside the two directories is touched, and a directory that does
//! not exist is not created.
//!
//! The package cache's global lock is held while its entries are deleted, so
//! a clean never races an install of another R session (rattler's
//! `Installer` holds the same lock while it links). A file that cannot be
//! deleted (on Windows: in use, or read-only after a retry that clears the
//! read-only attribute) is reported in `failed`; the other entries are still
//! deleted.
//!
//! A cancel stops the deletion before the next top-level entry (an
//! extracted package, a repodata file); the entry being deleted is finished.
//! A partly deleted cache is still valid: rattler revalidates every entry it
//! uses.

use std::path::{Path, PathBuf};

use crate::error::{RtError, RtResult};
use crate::job::{spawn_job, Job, JobCtx, JobOutput, Phase};
use crate::lock;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CleanOutcome {
    /// Top-level entries removed, as absolute paths.
    pub removed: Vec<String>,
    /// Paths that could not be removed.
    pub failed: Vec<String>,
    /// Bytes of the files removed.
    pub bytes: f64,
}

pub fn clean_cache_job(pkgs_cache_dir: PathBuf, repodata_cache_dir: PathBuf) -> Job {
    spawn_job(Phase::Clean, move |ctx| async move {
        let out = clean(&ctx, &pkgs_cache_dir, &repodata_cache_dir).await?;
        Ok(JobOutput::Clean(out))
    })
}

async fn clean(ctx: &JobCtx, pkgs: &Path, repodata: &Path) -> RtResult<CleanOutcome> {
    let mut out = CleanOutcome::default();
    if pkgs.is_dir() {
        let _lock = lock::lock_exclusive(&lock::cache_lock_path(pkgs), Some(ctx), false).await?;
        let dir = pkgs.to_path_buf();
        let skip = lock::cache_lock_path(pkgs);
        out = run_blocking(ctx, dir, Some(skip)).await?;
    }
    if repodata.is_dir() {
        let more = run_blocking(ctx, repodata.to_path_buf(), None).await?;
        out.removed.extend(more.removed);
        out.failed.extend(more.failed);
        out.bytes += more.bytes;
    }
    Ok(out)
}

/// Empties `dir` on a blocking thread, stopping before the next top-level
/// entry when the job is cancelled.
async fn run_blocking(ctx: &JobCtx, dir: PathBuf, skip: Option<PathBuf>) -> RtResult<CleanOutcome> {
    if ctx.is_cancelled() {
        return Err(RtError::Cancelled);
    }
    let job = ctx.clone();
    tokio::task::spawn_blocking(move || empty_dir(&dir, skip.as_deref(), &|| job.is_cancelled()))
        .await
        .map_err(|e| RtError::Internal(format!("cache cleaning failed: {e}")))?
}

fn empty_dir(dir: &Path, skip: Option<&Path>, cancelled: &dyn Fn() -> bool) -> RtResult<CleanOutcome> {
    let mut out = CleanOutcome::default();
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => {
            out.failed.push(dir.to_string_lossy().to_string());
            return Ok(out);
        }
    };
    let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for path in paths {
        if cancelled() {
            return Err(RtError::Cancelled);
        }
        if Some(path.as_path()) == skip {
            continue;
        }
        let failed_before = out.failed.len();
        remove_tree(&path, &mut out);
        if out.failed.len() == failed_before {
            out.removed.push(path.to_string_lossy().to_string());
        }
    }
    Ok(out)
}

/// Removes `path` (file, link or directory tree) entry by entry, recording
/// failures and the bytes of the files removed.
fn remove_tree(path: &Path, out: &mut CleanOutcome) {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(_) => {
            out.failed.push(path.to_string_lossy().to_string());
            return;
        }
    };
    if meta.is_dir() {
        if let Ok(entries) = std::fs::read_dir(path) {
            for entry in entries.flatten() {
                remove_tree(&entry.path(), out);
            }
        }
        if remove_with_retry(path, true).is_err() {
            out.failed.push(path.to_string_lossy().to_string());
        }
    } else {
        let size = meta.len() as f64;
        match remove_with_retry(path, false) {
            Ok(()) => out.bytes += size,
            Err(_) => out.failed.push(path.to_string_lossy().to_string()),
        }
    }
}

/// Removes a file or an empty directory. On a permission error it clears the
/// read-only attribute (what makes Windows refuse to delete a file conda
/// packages often ship read-only) and tries once more.
fn remove_with_retry(path: &Path, dir: bool) -> std::io::Result<()> {
    let remove = || {
        if dir {
            std::fs::remove_dir(path)
        } else {
            std::fs::remove_file(path)
        }
    };
    match remove() {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            if let Ok(meta) = std::fs::symlink_metadata(path) {
                let mut perms = meta.permissions();
                if perms.readonly() {
                    #[allow(clippy::permissions_set_readonly_false)]
                    perms.set_readonly(false);
                    let _ = std::fs::set_permissions(path, perms);
                }
            }
            remove()
        }
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job::PollResult;

    #[test]
    fn empties_both_caches_and_keeps_the_lock_file() {
        let dir = tempfile::tempdir().unwrap();
        let pkgs = dir.path().join("pkgs");
        let repodata = dir.path().join("repodata_cache");
        std::fs::create_dir_all(pkgs.join("foo-1.0-0/info")).unwrap();
        std::fs::write(pkgs.join("foo-1.0-0/info/index.json"), "{}").unwrap();
        std::fs::write(pkgs.join("foo-1.0-0.lock"), "x").unwrap();
        std::fs::write(pkgs.join(".cache.lock"), "").unwrap();
        std::fs::write(pkgs.join("cuda-info-v1.json"), "{}").unwrap();
        std::fs::create_dir_all(repodata.join("shards-v1")).unwrap();
        std::fs::write(repodata.join("abc.json"), "0123456789").unwrap();
        std::fs::write(repodata.join("shards-v1/x.msgpack"), "1").unwrap();
        // Something next to the caches that must survive.
        std::fs::write(dir.path().join("keep"), "k").unwrap();

        let job = clean_cache_job(pkgs.clone(), repodata.clone());
        let out = match job.wait() {
            PollResult::Done(JobOutput::Clean(out)) => out,
            _ => panic!("clean failed"),
        };
        assert!(out.failed.is_empty(), "{out:?}");
        assert_eq!(out.removed.len(), 5, "{out:?}");
        assert_eq!(out.bytes, (2 + 1 + 2 + 10 + 1) as f64);
        let left: Vec<_> = std::fs::read_dir(&pkgs).unwrap().flatten().map(|e| e.file_name()).collect();
        assert_eq!(left, vec![std::ffi::OsString::from(".cache.lock")]);
        assert_eq!(std::fs::read_dir(&repodata).unwrap().count(), 0);
        assert!(dir.path().join("keep").is_file());
    }

    #[test]
    fn missing_directories_are_not_created() {
        let dir = tempfile::tempdir().unwrap();
        let pkgs = dir.path().join("pkgs");
        let repodata = dir.path().join("repodata_cache");
        let job = clean_cache_job(pkgs.clone(), repodata.clone());
        match job.wait() {
            PollResult::Done(JobOutput::Clean(out)) => assert_eq!(out, CleanOutcome::default()),
            _ => panic!("clean failed"),
        }
        assert!(!pkgs.exists() && !repodata.exists());
    }

    #[test]
    fn a_cancel_stops_before_the_next_entry() {
        let dir = tempfile::tempdir().unwrap();
        let pkgs = dir.path().join("pkgs");
        for i in 0..5 {
            std::fs::create_dir_all(pkgs.join(format!("p{i}"))).unwrap();
            std::fs::write(pkgs.join(format!("p{i}/f")), "x").unwrap();
        }
        let calls = std::cell::Cell::new(0);
        // Cancelled after two entries.
        let cancelled = || {
            calls.set(calls.get() + 1);
            calls.get() > 2
        };
        let res = empty_dir(&pkgs, None, &cancelled);
        assert!(matches!(res, Err(RtError::Cancelled)));
        let left = std::fs::read_dir(&pkgs).unwrap().count();
        assert_eq!(left, 3, "two entries removed, three left");
    }

    #[test]
    fn read_only_files_are_removed() {
        let dir = tempfile::tempdir().unwrap();
        let pkgs = dir.path().join("pkgs");
        std::fs::create_dir_all(pkgs.join("p/bin")).unwrap();
        std::fs::write(pkgs.join("p/bin/tool"), "x").unwrap();
        let mut perms = std::fs::metadata(pkgs.join("p/bin/tool")).unwrap().permissions();
        perms.set_readonly(true);
        std::fs::set_permissions(pkgs.join("p/bin/tool"), perms).unwrap();
        let job = clean_cache_job(pkgs.clone(), dir.path().join("none"));
        match job.wait() {
            PollResult::Done(JobOutput::Clean(out)) => {
                assert!(out.failed.is_empty(), "{out:?}");
                assert_eq!(out.removed.len(), 1);
            }
            _ => panic!("clean failed"),
        }
    }
}
