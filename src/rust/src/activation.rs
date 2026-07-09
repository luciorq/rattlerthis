//! Compute the environment-variable diff that activating a prefix would
//! produce, without spawning the user's target CLI tool. `run()` on the R
//! side merges this into the child process's environment and lets
//! `processx::run()` do the actual spawning. See PLAN.md ("Process execution
//! split").

use std::collections::HashMap;
use std::path::PathBuf;
use std::str::FromStr;

use rattler_conda_types::Platform;
use rattler_shell::activation::{ActivationVariables, Activator, PathModificationBehavior};
use rattler_shell::shell::{Bash, CmdExe, ShellEnum};

use crate::error::{RtError, RtResult};

pub fn activation_env(
    prefix: PathBuf,
    platform: Option<String>,
) -> RtResult<HashMap<String, String>> {
    let platform = match platform {
        None => Platform::current(),
        Some(s) => {
            Platform::from_str(&s).map_err(|_| RtError::InvalidPlatform { platform: s })?
        }
    };

    let shell: ShellEnum = if platform.is_windows() {
        CmdExe.into()
    } else {
        Bash::default().into()
    };

    let activator = Activator::from_path(&prefix, shell, platform)?;

    let variables = ActivationVariables {
        conda_prefix: None,
        path: None,
        path_modification_behavior: PathModificationBehavior::Prepend,
        current_env: std::env::vars().collect(),
    };

    Ok(activator.run_activation(variables, None)?)
}
