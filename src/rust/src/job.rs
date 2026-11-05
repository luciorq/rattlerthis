//! Jobs: long rattler operations that run on the tokio runtime while R polls.
//!
//! An entry point such as `rt_install()` starts a job and returns at once
//! with an external pointer to it. R then calls `rt_job_poll()` until the job
//! is done (sleeping between polls with `Sys.sleep()`, which R interrupts
//! natively) and `rt_job_cancel()` when it is interrupted. Rust threads only
//! ever produce plain Rust values; every R object is built on the R thread,
//! in `rt_job_poll()`.
//!
//! # Phases and cancellation
//!
//! An install goes through `lock` (waiting for the prefix lock), `fetch`
//! (repodata), `solve`, `prefetch` (every package to install is downloaded
//! and extracted into the package cache) and `link` (rattler's `Installer`,
//! which then finds every package cached and only works locally). A cancel
//! request:
//!
//! - in `lock`, `fetch` and `prefetch` drops the futures doing the work;
//! - in `solve` sets the solver's cancellation token, and resolvo returns
//!   `SolveError::Cancelled`;
//! - in `link` is ignored: the link always finishes, so the prefix is never
//!   left half linked;
//! - in an activation kills the shell (see `activation.rs`).
//!
//! The phase and the cancel request share one atomic word, so a job enters
//! `link` only if no cancel came first, and `rt_job_cancel()` knows from the
//! same word whether the job stopped before `link` (`TRUE`) or will complete
//! (`FALSE`). A job that finishes without ever entering `link` (an
//! activation, a solve check, a cache clean) after a cancel was requested
//! reports `cancelled` even when its work had completed, so the answer of
//! `rt_job_cancel()` and the result always agree. The final transition to
//! `done` records in the same word whether the job completed, which answers
//! a cancel that comes after it.
//!
//! A job that ends with an error (a cancel included) waits until the
//! runtime's blocking threads are idle before it reports `done`, so no thread
//! of rattler's is still writing into a cache or prefix directory when R goes
//! on to restore, delete or clean it.
//!
//! # Lifetimes
//!
//! Everything a job uses (gateway, HTTP client, package-cache handles, memory
//! maps) is owned by its future and dropped with it; nothing is cached across
//! jobs. `Job`'s `Drop` (an R finalizer) never blocks: it requests a cancel
//! and detaches. A job is tied to the process that started it: a forked
//! child that still holds the external pointer never touches its state (it
//! might be locked by a thread that does not exist in the child).

use std::future::Future;
use std::mem::ManuallyDrop;
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::FutureExt;
use tokio_util::sync::CancellationToken;

use crate::cache::CleanOutcome;
use crate::error::{RtError, RtResult};
use crate::install::InstallOutcome;
use crate::runtime::{self, RtState};

/// How long a failed or cancelled job waits for blocking threads to finish
/// before it reports `done` anyway (so a blocking thread that never ends,
/// whoever started it, cannot hold every failed job for long).
const IDLE_WAIT_LIMIT: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Phase {
    Lock = 0,
    Fetch = 1,
    Solve = 2,
    Prefetch = 3,
    Link = 4,
    Activate = 5,
    Clean = 6,
    Sleep = 7,
    Done = 8,
}

impl Phase {
    pub fn name(self) -> &'static str {
        match self {
            Phase::Lock => "lock",
            Phase::Fetch => "fetch",
            Phase::Solve => "solve",
            Phase::Prefetch => "prefetch",
            Phase::Link => "link",
            Phase::Activate => "activate",
            Phase::Clean => "clean",
            Phase::Sleep => "sleep",
            Phase::Done => "done",
        }
    }

    fn from_word(word: u32) -> Phase {
        match (word & PHASE_MASK) as u8 {
            0 => Phase::Lock,
            1 => Phase::Fetch,
            2 => Phase::Solve,
            3 => Phase::Prefetch,
            4 => Phase::Link,
            5 => Phase::Activate,
            6 => Phase::Clean,
            7 => Phase::Sleep,
            _ => Phase::Done,
        }
    }
}

const PHASE_MASK: u32 = 0xff;
const CANCEL_BIT: u32 = 1 << 8;
/// Set with `done` when the job completed with its result (not an error).
const OK_BIT: u32 = 1 << 9;

/// The result of a job, as plain Rust data. Converted to R objects in
/// `rt_job_poll()` (`lib.rs`).
#[derive(Clone, Debug)]
pub enum JobOutput {
    Install(InstallOutcome),
    /// `TRUE`, `FALSE` or `NA` (`None`).
    Logical(Option<bool>),
    /// Variables an activation set or changed (`Some`) and unset (`None`),
    /// in a stable order.
    Env(Vec<(String, Option<String>)>),
    Clean(CleanOutcome),
}

pub(crate) struct JobShared {
    pid: u32,
    word: AtomicU32,
    token: CancellationToken,
    solve_token: rattler_solve::CancellationToken,
    /// `None` while running; the output, or the R error message, once done.
    result: Mutex<Option<Result<JobOutput, String>>>,
}

impl JobShared {
    /// Sets the cancel bit and returns the word before it.
    fn request_cancel(&self) -> u32 {
        let prev = self.word.fetch_or(CANCEL_BIT, Ordering::SeqCst);
        self.token.cancel();
        self.solve_token.cancel();
        prev
    }
}

/// What an R external pointer holds.
pub struct Job {
    shared: ManuallyDrop<Arc<JobShared>>,
}

/// What a job's future gets: its phase, its cancellation state and the
/// process state it runs on.
#[derive(Clone)]
pub struct JobCtx {
    shared: Arc<JobShared>,
    pub state: &'static RtState,
}

impl JobCtx {
    /// Moves to `phase`, unless a cancel was requested.
    pub fn phase(&self, phase: Phase) -> RtResult<()> {
        let mut word = self.shared.word.load(Ordering::SeqCst);
        loop {
            if word & CANCEL_BIT != 0 {
                return Err(RtError::Cancelled);
            }
            let next = (word & !PHASE_MASK) | phase as u32;
            match self.shared.word.compare_exchange(
                word,
                next,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return Ok(()),
                Err(actual) => word = actual,
            }
        }
    }

    /// Enters `link`. From here on a cancel request is ignored.
    pub fn enter_link(&self) -> RtResult<()> {
        self.phase(Phase::Link)
    }

    /// Whether the job is in `link` (it will complete).
    pub fn in_link(&self) -> bool {
        Phase::from_word(self.shared.word.load(Ordering::SeqCst)) == Phase::Link
    }

    /// The point of no return of a job that may finish without linking
    /// anything (an install whose transaction is empty): enters `link`
    /// unless it is there already, so a later cancel reports that the job
    /// completes. Fails with `RtError::Cancelled` when a cancel came first.
    pub fn commit(&self) -> RtResult<()> {
        if self.in_link() {
            Ok(())
        } else {
            self.enter_link()
        }
    }

    /// Requests a cancel of this job from inside it (a test hook).
    #[cfg(test)]
    pub fn request_cancel(&self) {
        self.shared.request_cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.shared.word.load(Ordering::SeqCst) & CANCEL_BIT != 0
    }

    /// The token resolvo polls during a solve.
    pub fn solve_token(&self) -> rattler_solve::CancellationToken {
        self.shared.solve_token.clone()
    }

    /// Resolves when a cancel is requested.
    pub async fn cancelled(&self) {
        self.shared.token.cancelled().await
    }

    /// Runs `fut` until it completes or a cancel is requested; in the second
    /// case `fut` is dropped and the result is `RtError::Cancelled`.
    pub async fn cancellable<T, F>(&self, fut: F) -> RtResult<T>
    where
        F: Future<Output = RtResult<T>>,
    {
        if self.is_cancelled() {
            return Err(RtError::Cancelled);
        }
        tokio::select! {
            biased;
            _ = self.shared.token.cancelled() => Err(RtError::Cancelled),
            res = fut => res,
        }
    }
}

/// Starts a job on the runtime of the current process. `make` builds the
/// job's future from its context.
pub fn spawn_job<F, Fut>(initial: Phase, make: F) -> Job
where
    F: FnOnce(JobCtx) -> Fut,
    Fut: Future<Output = RtResult<JobOutput>> + Send + 'static,
{
    let state = runtime::state();
    let shared = Arc::new(JobShared {
        pid: state.pid,
        word: AtomicU32::new(initial as u32),
        token: CancellationToken::new(),
        solve_token: rattler_solve::CancellationToken::new(),
        result: Mutex::new(None),
    });
    let ctx = JobCtx {
        shared: shared.clone(),
        state,
    };
    let fut = make(ctx);
    state.live_jobs.fetch_add(1, Ordering::SeqCst);
    let done_shared = shared.clone();
    state.runtime.spawn(async move {
        let res = match AssertUnwindSafe(fut).catch_unwind().await {
            Ok(res) => res,
            Err(panic) => Err(RtError::Internal(panic_message(&*panic))),
        };
        if res.is_err() {
            state.wait_blocking_idle(IDLE_WAIT_LIMIT).await;
        }
        // The final transition. A cancel requested while the job was not in
        // `link` wins over a completed result: `rt_job_cancel()` answered
        // that the job would not complete.
        let mut word = done_shared.word.load(Ordering::SeqCst);
        let completed = loop {
            let cancel_won =
                word & CANCEL_BIT != 0 && Phase::from_word(word) != Phase::Link;
            let completed = res.is_ok() && !cancel_won;
            let next = (word & !PHASE_MASK & !OK_BIT)
                | Phase::Done as u32
                | if completed { OK_BIT } else { 0 };
            match done_shared.word.compare_exchange(
                word,
                next,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => break completed,
                Err(actual) => word = actual,
            }
        };
        let res = match res {
            Ok(_) if !completed => Err(RtError::Cancelled.r_message()),
            other => other.map_err(|e| e.r_message()),
        };
        // Not live any more before the result is visible, so a poller that
        // sees the result also sees the job gone from `rt_live_jobs()`.
        state.live_jobs.fetch_sub(1, Ordering::SeqCst);
        *done_shared
            .result
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(res);
    });
    Job {
        shared: ManuallyDrop::new(shared),
    }
}

fn panic_message(panic: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = panic.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else {
        "a rattler task panicked".to_string()
    }
}

/// The poll result of a job.
pub enum PollResult {
    Running,
    Done(JobOutput),
    Failed(String),
}

impl Job {
    fn owned_here(&self) -> bool {
        self.shared.pid == std::process::id()
    }

    fn foreign_error() -> String {
        RtError::Internal(
            "this job was started by another process (a fork of this one); \
             start the operation again in this process"
                .to_string(),
        )
        .r_message()
    }

    pub fn poll(&self) -> PollResult {
        if !self.owned_here() {
            return PollResult::Failed(Self::foreign_error());
        }
        let guard = self
            .shared
            .result
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match &*guard {
            None => PollResult::Running,
            Some(Ok(out)) => PollResult::Done(out.clone()),
            Some(Err(msg)) => PollResult::Failed(msg.clone()),
        }
    }

    /// Requests a cancel and returns at once. `true` when the job stops (or
    /// stopped) without completing, `false` when it is linking and will
    /// complete (or already completed).
    pub fn cancel(&self) -> bool {
        if !self.owned_here() {
            return false;
        }
        let prev = self.shared.request_cancel();
        match Phase::from_word(prev) {
            Phase::Link => false,
            Phase::Done => prev & OK_BIT == 0,
            _ => true,
        }
    }

    pub fn phase(&self) -> Phase {
        if !self.owned_here() {
            return Phase::Done;
        }
        Phase::from_word(self.shared.word.load(Ordering::SeqCst))
    }

    /// Blocks the calling thread until the job is done. For tests only: the
    /// R side polls instead.
    #[cfg(test)]
    pub fn wait(&self) -> PollResult {
        loop {
            match self.poll() {
                PollResult::Running => std::thread::sleep(Duration::from_millis(5)),
                other => return other,
            }
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        if self.owned_here() {
            self.shared.request_cancel();
            // SAFETY: dropped exactly once, here.
            unsafe { ManuallyDrop::drop(&mut self.shared) };
        }
        // In a forked child the shared state is leaked on purpose: its mutex
        // or token may be held by a thread that only exists in the parent.
    }
}

/// Jobs of this process that have not reported `done`.
pub fn live_jobs() -> usize {
    runtime::existing_state()
        .map(|s| s.live_jobs.load(Ordering::SeqCst))
        .unwrap_or(0)
}

/// A job that sleeps for `secs` seconds (a test hook for interrupts and
/// `backend_quiesce()`). Its result is `TRUE`.
pub fn sleep_job(secs: f64) -> Job {
    let secs = if secs.is_finite() && secs > 0.0 { secs } else { 0.0 };
    spawn_job(Phase::Sleep, move |ctx| async move {
        ctx.cancellable(async {
            tokio::time::sleep(Duration::from_secs_f64(secs)).await;
            Ok(())
        })
        .await?;
        Ok(JobOutput::Logical(Some(true)))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn sleep_job_completes() {
        let job = sleep_job(0.01);
        match job.wait() {
            PollResult::Done(JobOutput::Logical(Some(true))) => {}
            other => panic!("unexpected result: {}", describe(&other)),
        }
        assert_eq!(job.phase(), Phase::Done);
        assert!(!job.cancel(), "a completed job reports that it completed");
    }

    #[test]
    fn cancel_stops_a_sleeping_job_quickly() {
        let job = sleep_job(60.0);
        std::thread::sleep(Duration::from_millis(20));
        let start = Instant::now();
        assert!(job.cancel());
        match job.wait() {
            PollResult::Failed(msg) => assert!(msg.starts_with("[rattlerthis:cancelled]"), "{msg}"),
            other => panic!("unexpected result: {}", describe(&other)),
        }
        // A cancelled job also waits for blocking threads that other tests,
        // running in parallel, may keep busy; hence the generous bound.
        assert!(start.elapsed() < IDLE_WAIT_LIMIT + Duration::from_secs(5));
        // A second cancel of a cancelled job still says "did not complete".
        assert!(job.cancel());
    }

    #[test]
    fn dropping_a_job_cancels_it_without_blocking() {
        let state = runtime::state();
        let before = Instant::now();
        let job = sleep_job(60.0);
        let shared = (*job.shared).clone();
        drop(job);
        assert!(before.elapsed() < Duration::from_secs(1), "drop must not block");
        let start = Instant::now();
        loop {
            let done = shared.result.lock().unwrap().is_some();
            if done {
                break;
            }
            assert!(
                start.elapsed() < IDLE_WAIT_LIMIT + Duration::from_secs(10),
                "dropped job never finished"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        let _ = state;
    }

    #[test]
    fn link_phase_is_not_interrupted() {
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let rx = Arc::new(Mutex::new(rx));
        let job = spawn_job(Phase::Prefetch, move |ctx| async move {
            ctx.enter_link()?;
            // Simulates a link: waits for the test to cancel, then finishes.
            let rx = rx.clone();
            tokio::task::spawn_blocking(move || {
                let _ = rx.lock().unwrap().recv_timeout(Duration::from_secs(10));
            })
            .await
            .unwrap();
            Ok(JobOutput::Logical(Some(true)))
        });
        let start = Instant::now();
        while job.phase() != Phase::Link {
            assert!(start.elapsed() < Duration::from_secs(5));
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(!job.cancel(), "cancel during link reports that the job will complete");
        tx.send(()).unwrap();
        match job.wait() {
            PollResult::Done(JobOutput::Logical(Some(true))) => {}
            other => panic!("unexpected result: {}", describe(&other)),
        }
    }

    #[test]
    fn a_cancel_before_link_prevents_the_link() {
        let (go_tx, go_rx) = std::sync::mpsc::channel::<()>();
        let go_rx = Arc::new(Mutex::new(go_rx));
        let job = spawn_job(Phase::Prefetch, move |ctx| async move {
            let go_rx = go_rx.clone();
            tokio::task::spawn_blocking(move || {
                let _ = go_rx.lock().unwrap().recv_timeout(Duration::from_secs(10));
            })
            .await
            .unwrap();
            ctx.enter_link()?;
            Ok(JobOutput::Logical(Some(true)))
        });
        assert!(job.cancel());
        go_tx.send(()).unwrap();
        match job.wait() {
            PollResult::Failed(msg) => assert!(msg.starts_with("[rattlerthis:cancelled]"), "{msg}"),
            other => panic!("unexpected result: {}", describe(&other)),
        }
    }

    /// `rt_job_cancel()`'s answer and the job's result always agree: `TRUE`
    /// means the job ends with `cancelled`, `FALSE` that it ends with its
    /// result, however close the cancel comes to the job's end.
    #[test]
    fn cancel_answers_agree_with_results() {
        for i in 0..2000 {
            let job = sleep_job(0.0);
            for _ in 0..(i % 7) {
                std::thread::yield_now();
            }
            let stopped = job.cancel();
            match (stopped, job.wait()) {
                (true, PollResult::Failed(msg)) if msg.starts_with("[rattlerthis:cancelled]") => {}
                (false, PollResult::Done(JobOutput::Logical(Some(true)))) => {}
                (stopped, other) => panic!("cancel said {stopped}, result {}", describe(&other)),
            }
            assert_eq!(job.cancel(), stopped, "a later cancel gives the same answer");
        }
    }

    #[test]
    fn panics_become_internal_errors() {
        let job = spawn_job(Phase::Fetch, |_ctx| async move {
            if std::process::id() > 0 {
                panic!("boom");
            }
            Ok(JobOutput::Logical(None))
        });
        match job.wait() {
            PollResult::Failed(msg) => {
                assert!(msg.starts_with("[rattlerthis:internal]"), "{msg}");
                assert!(msg.contains("boom"), "{msg}");
            }
            other => panic!("unexpected result: {}", describe(&other)),
        }
    }

    pub(crate) fn describe(r: &PollResult) -> String {
        match r {
            PollResult::Running => "running".into(),
            PollResult::Done(out) => format!("done: {out:?}"),
            PollResult::Failed(msg) => format!("failed: {msg}"),
        }
    }
}
