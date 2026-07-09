//! A single lazily-initialized tokio runtime shared by every `#[extendr]`
//! entry point. R calls into the compiled library synchronously and has no
//! event loop of its own, so async rattler APIs are driven with
//! `runtime().block_on(...)`, blocking the calling R thread while tokio's
//! worker threads do the actual network/CPU work. See PLAN.md ("Async
//! bridging") for the rationale.

use std::sync::OnceLock;
use tokio::runtime::Runtime;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to start the rattlerthis tokio runtime")
    })
}
