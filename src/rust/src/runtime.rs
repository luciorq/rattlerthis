//! Per-process state shared by every job: a tokio runtime, a private rayon
//! pool and the job registry.
//!
//! R calls into the compiled library on its main thread and has no event
//! loop of its own. Long operations therefore run as jobs (`job.rs`) on a
//! tokio runtime owned by this module, and R polls them.
//!
//! # Fork safety
//!
//! `fork()` (`parallel::mcparallel()`, `mclapply()`) copies only the calling
//! thread. A child that used the parent's runtime would queue work for worker
//! threads that do not exist in it and hang. So the state remembers the pid
//! that built it. When `std::process::id()` differs, a fresh state is built
//! for the new pid and swapped in through an `AtomicPtr`, and the parent's
//! state is leaked: dropping it would join threads that do not exist, and no
//! lock of the parent's is ever taken by the child.
//!
//! rattler links packages on rayon (`rayon::spawn_fifo` and parallel
//! iterators inside its `Installer`). rayon's global pool has the same fork
//! problem and cannot be rebuilt, so rattlerthis never lets rattler touch it:
//! the link runs on a worker of the private pool below (whose `spawn_fifo` and
//! parallel iterators then stay in that pool), and rattlerthis reads prefix
//! records itself instead of calling rattler's parallel readers.
//!
//! A link blocks one worker of that pool for its whole duration (rattler's
//! `Installer` future is driven there with `block_on`), while the work it
//! spawns onto the pool needs other workers. So at most one link runs at a
//! time in a process (`link_permit`): with as many concurrent links as the
//! pool has threads, every worker would wait for work none of them can run.
//!
//! Windows has no `fork()`; the pid check is then a cheap no-op.

use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// How long an idle tokio blocking thread lives. Short, so that "no blocking
/// thread alive" (see [`RtState::blocking_threads_alive`]) soon follows "no
/// blocking work running".
const BLOCKING_KEEP_ALIVE: Duration = Duration::from_millis(100);

pub struct RtState {
    pub pid: u32,
    pub runtime: tokio::runtime::Runtime,
    pub rayon: rayon::ThreadPool,
    /// Jobs started in this process that have not reported `done` yet.
    pub live_jobs: AtomicUsize,
    /// One permit: the link that holds it is the only one running (see the
    /// module documentation).
    pub link_permit: tokio::sync::Semaphore,
    workers: usize,
    threads_started: Arc<AtomicUsize>,
    threads_stopped: Arc<AtomicUsize>,
}

impl RtState {
    fn build(pid: u32) -> RtState {
        let cpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(2);
        let workers = cpus.clamp(2, 8);
        let started = Arc::new(AtomicUsize::new(0));
        let stopped = Arc::new(AtomicUsize::new(0));
        let on_start = started.clone();
        let on_stop = stopped.clone();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(workers)
            .thread_name("rattlerthis-tokio")
            .thread_keep_alive(BLOCKING_KEEP_ALIVE)
            .on_thread_start(move || {
                on_start.fetch_add(1, Ordering::SeqCst);
            })
            .on_thread_stop(move || {
                on_stop.fetch_add(1, Ordering::SeqCst);
            })
            .enable_all()
            .build()
            .expect("failed to start the rattlerthis tokio runtime");
        // At least two threads: the link runs `block_on` on one worker while
        // the others execute the jobs rattler spawns onto the pool (and only
        // one link runs at a time, `link_permit`).
        let rayon = rayon::ThreadPoolBuilder::new()
            .num_threads(cpus.max(2))
            .thread_name(|i| format!("rattlerthis-link-{i}"))
            .build()
            .expect("failed to start the rattlerthis link thread pool");
        RtState {
            pid,
            runtime,
            rayon,
            live_jobs: AtomicUsize::new(0),
            link_permit: tokio::sync::Semaphore::new(1),
            workers,
            threads_started: started,
            threads_stopped: stopped,
        }
    }

    /// Number of tokio blocking-pool threads alive (busy, or idle for less
    /// than [`BLOCKING_KEEP_ALIVE`]). tokio's worker threads also start
    /// through the blocking pool and never stop, so they are subtracted.
    pub fn blocking_threads_alive(&self) -> usize {
        let started = self.threads_started.load(Ordering::SeqCst);
        let stopped = self.threads_stopped.load(Ordering::SeqCst);
        started.saturating_sub(stopped).saturating_sub(self.workers)
    }

    /// Waits (asynchronously) until no blocking thread is alive, for at most
    /// `limit`. Used after a cancelled or failed job, so that blocking work
    /// rattler detached (a repodata parse, a file write of an aborted
    /// download) has finished before the job reports `done`.
    pub async fn wait_blocking_idle(&self, limit: Duration) {
        let start = std::time::Instant::now();
        while self.blocking_threads_alive() > 0 && start.elapsed() < limit {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

static STATE: AtomicPtr<RtState> = AtomicPtr::new(ptr::null_mut());

/// Set in a process that is a fork of one that used rattlerthis.
static FORKED: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn on_fork_child() {
    // Only an atomic store: async-signal-safe, as an atfork handler must be.
    FORKED.store(true, Ordering::SeqCst);
}

/// Called at the start of every entry point. Registers (once per process) a
/// `pthread_atfork()` child handler, so a fork of this process knows it is
/// one even before it builds its own state.
pub fn note_entry() {
    #[cfg(unix)]
    {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| {
            // SAFETY: registers a handler that only stores an atomic flag.
            unsafe {
                libc::pthread_atfork(None, None, Some(on_fork_child));
            }
        });
    }
}

/// Whether this process is a fork (`parallel::mcparallel()`, `mclapply()`)
/// of a process that used rattlerthis.
pub fn is_forked_child() -> bool {
    FORKED.load(Ordering::SeqCst)
}

/// The state of the current process, built on first use (and again in a
/// forked child).
pub fn state() -> &'static RtState {
    let pid = std::process::id();
    loop {
        let current = STATE.load(Ordering::Acquire);
        // SAFETY: a non-null pointer in STATE always comes from
        // `Box::into_raw` below and is never freed.
        if let Some(existing) = unsafe { current.as_ref() } {
            if existing.pid == pid {
                return existing;
            }
            FORKED.store(true, Ordering::SeqCst);
        }
        let fresh = Box::into_raw(Box::new(RtState::build(pid)));
        match STATE.compare_exchange(current, fresh, Ordering::AcqRel, Ordering::Acquire) {
            // The previous state (another pid's, or none) is leaked on
            // purpose: see the module documentation.
            Ok(_) => return unsafe { &*fresh },
            Err(_) => {
                // Another thread swapped first. Our state never ran anything;
                // shut its runtime down without waiting and try again.
                let fresh = unsafe { Box::from_raw(fresh) };
                let RtState { runtime, .. } = *fresh;
                runtime.shutdown_background();
            }
        }
    }
}

/// The state of the current process if it was already built, without building
/// one (so that a query such as `rt_live_jobs()` starts no threads).
pub fn existing_state() -> Option<&'static RtState> {
    let current = STATE.load(Ordering::Acquire);
    // SAFETY: as in `state()`.
    unsafe { current.as_ref() }.filter(|s| s.pid == std::process::id())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_is_built_once_per_process() {
        let a = state() as *const RtState;
        let b = state() as *const RtState;
        assert_eq!(a, b);
        assert_eq!(state().pid, std::process::id());
        assert!(existing_state().is_some());
    }

    #[test]
    fn blocking_threads_are_counted_and_expire() {
        // A private state, so that other tests running in parallel do not
        // keep blocking threads of their own alive.
        let s = RtState::build(std::process::id());
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let handle = s.runtime.spawn_blocking(move || {
            let _ = rx.recv();
        });
        let start = std::time::Instant::now();
        while s.blocking_threads_alive() == 0 && start.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(s.blocking_threads_alive(), 1);
        tx.send(()).unwrap();
        s.runtime.block_on(async {
            handle.await.unwrap();
            s.wait_blocking_idle(Duration::from_secs(5)).await;
        });
        assert_eq!(s.blocking_threads_alive(), 0);
    }
}
