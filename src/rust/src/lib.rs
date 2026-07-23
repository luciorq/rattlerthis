use extendr_api::prelude::*;

mod activation;
mod error;
mod install;
mod runtime;
#[cfg(feature = "wheels")]
mod wheel;

fn opt(value: Nullable<String>) -> Option<String> {
    match value {
        Nullable::Null => None,
        Nullable::NotNull(s) => Some(s),
    }
}

/// Solve `specs` against `channels` and link the result into `prefix`,
/// preserving whatever is already installed there. Used by both
/// `create_env()` and `install()` on the R side.
///
/// @noRd
#[extendr]
fn rt_install(
    specs: Vec<String>,
    prefix: String,
    channels: Vec<String>,
    channel_priority: String,
    platform: Nullable<String>,
    repodata_cache_dir: String,
    pkgs_cache_dir: String,
) -> extendr_api::Result<List> {
    let outcome = install::solve_and_install(install::InstallInput {
        specs,
        prefix: prefix.into(),
        channels,
        channel_priority,
        platform: opt(platform),
        repodata_cache_dir: repodata_cache_dir.into(),
        pkgs_cache_dir: pkgs_cache_dir.into(),
    })
    .map_err(extendr_api::Error::from)?;

    let name: Vec<String> = outcome
        .records
        .iter()
        .map(|r| r.package_record.name.as_normalized().to_string())
        .collect();
    let version: Vec<String> = outcome
        .records
        .iter()
        .map(|r| r.package_record.version.to_string())
        .collect();
    let build: Vec<String> = outcome
        .records
        .iter()
        .map(|r| r.package_record.build.clone())
        .collect();
    let channel: Vec<String> = outcome
        .records
        .iter()
        .map(|r| r.channel.clone().unwrap_or_default())
        .collect();

    Ok(list!(
        prefix = outcome.prefix.to_string_lossy().to_string(),
        name = name,
        version = version,
        build = build,
        channel = channel
    ))
}

/// Compute the environment variables that activating `prefix` would change,
/// as a named list of strings. Does not spawn the target CLI tool; `run()`
/// on the R side merges this into a `processx::run()` call.
///
/// @noRd
#[extendr]
fn rt_activation_env(prefix: String, platform: Nullable<String>) -> extendr_api::Result<List> {
    let env = activation::activation_env(prefix.into(), opt(platform))
        .map_err(extendr_api::Error::from)?;
    let (names, values): (Vec<String>, Vec<String>) = env.into_iter().unzip();
    List::from_names_and_values(names, values)
}

// Macro to generate exports.
// This ensures exported functions are registered with R.
// See corresponding C code in `entrypoint.c`.
extendr_module! {
    mod rattlerthis;
    fn rt_install;
    fn rt_activation_env;
}
