//! Error type used across the crate, converted into `extendr_api::Error` at
//! the R boundary so failures surface as normal R conditions.

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

    #[error("failed to parse channel {channel:?}: {source}")]
    ParseChannel {
        channel: String,
        #[source]
        source: rattler_conda_types::ParseChannelError,
    },

    #[error("failed to detect virtual packages: {0}")]
    VirtualPackages(#[from] rattler_virtual_packages::DetectVirtualPackageError),

    #[error("failed to query repodata: {0}")]
    Gateway(#[from] rattler_repodata_gateway::GatewayError),

    #[error("failed to solve environment: {0}")]
    Solve(#[from] rattler_solve::SolveError),

    #[error("failed to install packages: {0}")]
    Install(#[from] rattler::install::InstallerError),

    #[error("failed to activate environment: {0}")]
    Activation(#[from] rattler_shell::activation::ActivationError),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[cfg(feature = "wheels")]
    #[error(
        "cannot install wheel package {name:?}: no `python` package is present in the \
         environment. Request python alongside it, e.g. \
         packages = c(\"python\", \"{name}\")"
    )]
    WheelMissingPython { name: String },

    // `rattler::install::python::PythonInfoError` isn't part of that crate's
    // public API (only `PythonInfo` itself is re-exported), so the concrete
    // error type can't be named here — its `Display` message is captured at
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

pub type RtResult<T> = Result<T, RtError>;

impl From<RtError> for extendr_api::Error {
    fn from(err: RtError) -> Self {
        extendr_api::Error::Other(err.to_string())
    }
}
