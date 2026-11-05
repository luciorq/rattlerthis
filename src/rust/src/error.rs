//! Error type used across the crate.
//!
//! Every error has a *kind* (`RtError::kind()`), a short stable word that the
//! R side turns into a condition class (`rattlerthis_rattler_<kind>`). At the
//! R boundary an error becomes the message `"[rattlerthis:<kind>] <text>"`,
//! so R can recover the kind without parsing the text, and never has to read
//! the text as cli markup.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum RtError {
    #[error("invalid platform {platform:?}")]
    InvalidPlatform { platform: String },

    #[error("failed to parse match spec {spec:?}: {source}")]
    ParseMatchSpec {
        spec: String,
        #[source]
        source: rattler_conda_types::ParseMatchSpecError,
    },

    #[error("invalid pin {line:?} in {path}: {source}")]
    ParsePin {
        line: String,
        path: String,
        #[source]
        source: rattler_conda_types::ParseMatchSpecError,
    },

    #[error("failed to parse channel {channel:?}: {source}")]
    ParseChannel {
        channel: String,
        #[source]
        source: rattler_conda_types::ParseChannelError,
    },

    #[error(
        "invalid channel priority {value:?}; it must be \"strict\", \"flexible\" or \"disabled\""
    )]
    InvalidChannelPriority { value: String },

    #[error("failed to detect virtual packages: {0}")]
    VirtualPackages(String),

    #[error("failed to query repodata: {0}")]
    Gateway(String),

    /// A package could not be downloaded or extracted into the package cache
    /// (the `prefetch` phase), or a cache lock could not be taken.
    #[error("{0}")]
    Fetch(String),

    /// A downloaded package did not have the hash its record (or its URL
    /// fragment) promised.
    #[error("{0}")]
    HashMismatch(String),

    #[error("failed to solve environment: {0}")]
    Solve(rattler_solve::SolveError),

    #[error("failed to install packages: {0}")]
    Install(String),

    #[error("failed to activate environment: {0}")]
    Activation(String),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("{context}: {source}")]
    IoAt {
        context: String,
        #[source]
        source: std::io::Error,
    },

    /// The job was cancelled (`rt_job_cancel()` or its external pointer was
    /// garbage collected) before it changed anything.
    #[error("the operation was cancelled")]
    Cancelled,

    /// A panic caught at the job boundary, or a job polled from a process it
    /// does not belong to (a forked child).
    #[error("internal error: {0}")]
    Internal(String),

    /// An environment file (or an explicit package list) that cannot be read
    /// or parsed, or that micromamba refuses too (`envfile.rs`,
    /// `explicit.rs`).
    #[error("{0}")]
    EnvFile(String),

    /// Content the rattler backend does not support but micromamba does: a
    /// `pip:` section of an environment file, pip packages of a lock file, a
    /// mambajs lock file, a wheel or source archive in an explicit file.
    /// condathis raises `condathis_backend_unsupported` for it.
    #[error("{0}")]
    Unsupported(String),

    #[cfg(feature = "wheels")]
    #[error(
        "cannot install wheel package {name:?}: no `python` package is present in the \
         environment. Request python alongside it, e.g. \
         packages = c(\"python\", \"{name}\")"
    )]
    WheelMissingPython { name: String },

    // `rattler::install::python::PythonInfoError` isn't part of that crate's
    // public API (only `PythonInfo` itself is re-exported), so the concrete
    // error type can't be named here; its `Display` message is captured at
    // the call site instead.
    #[cfg(feature = "wheels")]
    #[error("failed to determine the environment's Python layout: {0}")]
    PythonInfo(String),

    #[cfg(feature = "wheels")]
    #[error("failed to download wheel from {url}: {source}")]
    WheelDownload {
        url: String,
        #[source]
        source: reqwest::Error,
    },

    #[cfg(feature = "wheels")]
    #[error("failed to read wheel archive for {name:?}: {source}")]
    WheelArchive {
        name: String,
        #[source]
        source: zip::result::ZipError,
    },

    #[cfg(feature = "wheels")]
    #[error("failed to parse entry point {line:?} for {name:?}: {source}")]
    WheelEntryPoint {
        name: String,
        line: String,
        #[source]
        source: rattler_conda_types::package::ParseEntryPointError,
    },

    #[cfg(feature = "wheels")]
    #[error("wheel installation task panicked: {0}")]
    TaskJoin(#[from] tokio::task::JoinError),

    /// Built without the `wheels` feature but the solve returned at least
    /// one wheel-format record (e.g. from the `conda-pypi` channel). This
    /// build only handles conda-format (`.conda`/`.tar.bz2`) packages.
    #[error(
        "package {name:?} is only available as a Python wheel (e.g. from the `conda-pypi` \
         channel); this build of rattlerthis was compiled without wheel support"
    )]
    WheelUnsupported { name: String },
}

/// The message of `err` followed by the messages of its sources that it does
/// not already include, joined by `": "`. Several rattler errors print only
/// a summary ("failed to link foo-1.0-0") and keep the cause as a source.
pub fn error_chain(err: &(dyn std::error::Error + 'static)) -> String {
    let mut msg = err.to_string();
    let mut source = err.source();
    while let Some(s) = source {
        let text = s.to_string();
        if !text.is_empty() && !msg.contains(&text) {
            msg.push_str(": ");
            msg.push_str(&text);
        }
        source = s.source();
    }
    msg
}

impl From<rattler_virtual_packages::DetectVirtualPackageError> for RtError {
    fn from(err: rattler_virtual_packages::DetectVirtualPackageError) -> Self {
        RtError::VirtualPackages(error_chain(&err))
    }
}

impl From<rattler_repodata_gateway::GatewayError> for RtError {
    fn from(err: rattler_repodata_gateway::GatewayError) -> Self {
        RtError::Gateway(error_chain(&err))
    }
}

impl From<rattler::install::InstallerError> for RtError {
    fn from(err: rattler::install::InstallerError) -> Self {
        match err {
            rattler::install::InstallerError::Cancelled => RtError::Cancelled,
            other => RtError::Install(error_chain(&other)),
        }
    }
}

impl From<rattler_solve::SolveError> for RtError {
    fn from(err: rattler_solve::SolveError) -> Self {
        match err {
            rattler_solve::SolveError::Cancelled => RtError::Cancelled,
            other => RtError::Solve(other),
        }
    }
}

impl RtError {
    /// The stable error kind, one of `invalid_platform`, `invalid_spec`,
    /// `invalid_channel`, `invalid_channel_priority`, `virtual_packages`,
    /// `fetch`, `solve`, `link`, `activation`, `io`, `env_file`,
    /// `unsupported`, `hash_mismatch`, `wheel_unsupported`, `cancelled` or
    /// `internal`.
    pub fn kind(&self) -> &'static str {
        match self {
            RtError::InvalidPlatform { .. } => "invalid_platform",
            RtError::ParseMatchSpec { .. } | RtError::ParsePin { .. } => "invalid_spec",
            RtError::ParseChannel { .. } => "invalid_channel",
            RtError::InvalidChannelPriority { .. } => "invalid_channel_priority",
            RtError::VirtualPackages(_) => "virtual_packages",
            RtError::Gateway(_) | RtError::Fetch(_) => "fetch",
            RtError::HashMismatch(_) => "hash_mismatch",
            RtError::Solve(_) => "solve",
            RtError::Install(_) => "link",
            RtError::Activation(_) => "activation",
            RtError::Io(_) | RtError::IoAt { .. } => "io",
            RtError::Cancelled => "cancelled",
            RtError::Internal(_) => "internal",
            RtError::EnvFile(_) => "env_file",
            RtError::Unsupported(_) => "unsupported",
            #[cfg(feature = "wheels")]
            RtError::WheelDownload { .. } => "fetch",
            #[cfg(feature = "wheels")]
            RtError::WheelMissingPython { .. }
            | RtError::PythonInfo(_)
            | RtError::WheelArchive { .. }
            | RtError::WheelEntryPoint { .. } => "link",
            #[cfg(feature = "wheels")]
            RtError::TaskJoin(_) => "internal",
            RtError::WheelUnsupported { .. } => "wheel_unsupported",
        }
    }

    /// The message R receives: `"[rattlerthis:<kind>] <text>"`, safe for R
    /// (see [`r_safe()`]), with the credentials of channel URLs hidden as
    /// libmamba hides them in its messages (see [`crate::secrets`]).
    pub fn r_message(&self) -> String {
        r_safe(crate::secrets::hide_secrets(&format!("[rattlerthis:{}] {}", self.kind(), self)))
    }

    pub fn io_at(context: impl Into<String>, source: std::io::Error) -> Self {
        RtError::IoAt {
            context: context.into(),
            source,
        }
    }
}

pub type RtResult<T> = Result<T, RtError>;

/// `text` with every NUL character written as `\0`. R strings cannot hold a
/// NUL: extendr raises an error message through a C string and aborts the
/// process on one, and R refuses to make a string with one. User text (a
/// spec, a URL, repodata) can carry one into a message or a result.
pub fn r_safe(text: String) -> String {
    if text.contains('\0') {
        text.replace('\0', "\\0")
    } else {
        text
    }
}

impl From<RtError> for extendr_api::Error {
    fn from(err: RtError) -> Self {
        extendr_api::Error::Other(err.r_message())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_carry_the_kind_prefix() {
        let err = RtError::InvalidChannelPriority {
            value: "bogus".into(),
        };
        assert_eq!(err.kind(), "invalid_channel_priority");
        assert!(err
            .r_message()
            .starts_with("[rattlerthis:invalid_channel_priority] invalid channel priority"));
        assert_eq!(RtError::Cancelled.kind(), "cancelled");
        assert_eq!(
            RtError::from(rattler_solve::SolveError::Cancelled).kind(),
            "cancelled"
        );
        assert_eq!(
            RtError::from(rattler_solve::SolveError::Unsolvable(vec!["x".into()])).kind(),
            "solve"
        );
        assert_eq!(RtError::Unsupported("x".into()).kind(), "unsupported");
        assert_eq!(RtError::EnvFile("x".into()).kind(), "env_file");
        assert_eq!(
            RtError::Unsupported("a pip: section".into()).r_message(),
            "[rattlerthis:unsupported] a pip: section"
        );
        let io = RtError::io_at("reading x", std::io::Error::other("boom"));
        assert_eq!(io.kind(), "io");
        assert_eq!(io.to_string(), "reading x: boom");
    }

    #[test]
    fn messages_never_carry_a_nul() {
        let err = RtError::EnvFile("a\0b".into());
        assert_eq!(err.r_message(), "[rattlerthis:env_file] a\\0b");
        assert!(std::ffi::CString::new(err.r_message()).is_ok());
        let err: extendr_api::Error = RtError::Unsupported("pip \"x\0y\"".into()).into();
        assert!(!err.to_string().contains('\0'));
        assert_eq!(r_safe("plain".into()), "plain");
    }
}
