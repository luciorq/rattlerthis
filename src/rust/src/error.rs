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
}

pub type RtResult<T> = Result<T, RtError>;

impl From<RtError> for extendr_api::Error {
    fn from(err: RtError) -> Self {
        extendr_api::Error::Other(err.to_string())
    }
}
