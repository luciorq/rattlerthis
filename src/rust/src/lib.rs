//! rattlerthis's Rust layer: the rattler backend of condathis.
//!
//! Long operations are jobs (`job.rs`): `rt_install()`,
//! `rt_install_explicit()`, `rt_solve_check()`, `rt_activation_env()`,
//! `rt_clean_cache()` and `rt_test_job_sleep()` return an external pointer at
//! once, and R polls it with `rt_job_poll()` and stops
//! it with `rt_job_cancel()`. Errors reach R as
//! `"[rattlerthis:<kind>] <text>"` (`error.rs`).
//!
//! The Rust layer reads no rattlerthis-specific environment variable or
//! option; it honors the generic conda variables rattler itself reads (the
//! `CONDA_OVERRIDE_*` virtual package overrides).

use extendr_api::prelude::*;

mod activation;
mod cache;
mod channels;
mod envfile;
mod error;
mod explicit;
mod history;
mod install;
mod job;
mod linkscripts;
mod lock;
mod net;
mod netenv;
mod paths;
mod pkgfile;
mod runtime;
mod secrets;
mod spectext;
mod testserver;
#[cfg(test)]
mod testutil;
mod vpkgs;
#[cfg(feature = "wheels")]
mod wheel;

use job::{Job, JobOutput, PollResult};

/// On macOS, arms fork detection when the library is loaded (a Mach-O module
/// initializer), so a fork knows it is one even if the parent never called
/// an entry point: macOS limits what a fork may do (see `install.rs`
/// `ensure_link_allowed()` and `net.rs` `ensure_http_allowed()`). Elsewhere
/// every entry point arms it (`runtime::note_entry()`).
#[cfg(target_os = "macos")]
#[used]
#[link_section = "__DATA,__mod_init_func"]
static ARM_FORK_DETECTION: extern "C" fn() = {
    extern "C" fn arm() {
        runtime::note_entry();
    }
    arm
};

fn opt(value: Nullable<String>) -> Option<String> {
    match value {
        Nullable::Null => None,
        Nullable::NotNull(s) => Some(s),
    }
}

fn r_error(msg: String) -> extendr_api::Error {
    extendr_api::Error::Other(error::r_safe(msg))
}

/// Strings for R: NUL characters written as `\0` (`error::r_safe()`).
fn r_strings(values: impl IntoIterator<Item = String>) -> Vec<String> {
    values.into_iter().map(error::r_safe).collect()
}

/// A data frame from named character columns of equal length.
fn data_frame(columns: Vec<(&str, Vec<String>)>) -> extendr_api::Result<Robj> {
    let nrow = columns.first().map_or(0, |(_, v)| v.len());
    let names: Vec<&str> = columns.iter().map(|(n, _)| *n).collect();
    let values: Vec<Robj> = columns.into_iter().map(|(_, v)| Robj::from(r_strings(v))).collect();
    let mut list = List::from_names_and_values(names, values)?;
    list.set_class(["data.frame"])?;
    // The compact form R uses for automatic row names: c(NA, -n).
    let row_names: Robj = if nrow == 0 {
        Robj::from(Vec::<i32>::new())
    } else {
        // i32::MIN is R's NA_integer_.
        Robj::from(vec![i32::MIN, -(nrow as i32)])
    };
    list.set_attrib(row_names_symbol(), row_names)?;
    Ok(list.into())
}

fn output_to_robj(out: JobOutput) -> extendr_api::Result<Robj> {
    match out {
        JobOutput::Install(o) => {
            let records = data_frame(vec![
                ("op", o.records.iter().map(|r| r.op.to_string()).collect()),
                ("name", o.records.iter().map(|r| r.name.clone()).collect()),
                ("version", o.records.iter().map(|r| r.version.clone()).collect()),
                ("build", o.records.iter().map(|r| r.build.clone()).collect()),
                ("channel", o.records.iter().map(|r| r.channel.clone()).collect()),
                ("subdir", o.records.iter().map(|r| r.subdir.clone()).collect()),
            ])?;
            let skipped = data_frame(vec![
                (
                    "package",
                    o.link_scripts_skipped.iter().map(|(p, _)| p.clone()).collect(),
                ),
                (
                    "script",
                    o.link_scripts_skipped.iter().map(|(_, s)| s.to_string()).collect(),
                ),
            ])?;
            Ok(list!(
                prefix = error::r_safe(o.prefix),
                records = records,
                channels = r_strings(o.channels),
                link_scripts_skipped = skipped
            )
            .into())
        }
        JobOutput::Logical(v) => Ok(match v {
            Some(b) => Rbool::from(b).into(),
            None => Rbool::na().into(),
        }),
        JobOutput::Env(env) => {
            let (names, values): (Vec<String>, Vec<Option<String>>) = env.into_iter().unzip();
            // `NA` for a variable the activation unset.
            let values: Vec<Robj> = values
                .into_iter()
                .map(|value| Robj::from(value.map(error::r_safe)))
                .collect();
            Ok(List::from_names_and_values(r_strings(names), values)?.into())
        }
        JobOutput::Clean(c) => Ok(list!(
            removed = r_strings(c.removed),
            failed = r_strings(c.failed),
            bytes = c.bytes
        )
        .into()),
    }
}

/// Poll a job.
///
/// `NULL` while the job runs; its result once it is done; an R error with
/// the message `"[rattlerthis:<kind>] <text>"` when it failed (kind
/// `cancelled` after a cancel). A done job keeps its result, so polling it
/// again returns the same value.
///
/// @noRd
#[extendr]
fn rt_job_poll(job: ExternalPtr<Job>) -> extendr_api::Result<Robj> {
    runtime::note_entry();
    match job.poll() {
        PollResult::Running => Ok(Robj::from(())),
        PollResult::Done(out) => output_to_robj(out),
        PollResult::Failed(msg) => Err(r_error(msg)),
    }
}

/// Request that a job stops, and return at once.
///
/// `TRUE` when the job stops (or stopped) without completing: before its
/// link phase, or a solve check, activation, cache clean or sleep (such a
/// job then always ends with kind `cancelled`, also when its work had just
/// finished). `FALSE` when it is linking and will complete, or already
/// completed. Keep polling until the job is done either way.
///
/// @noRd
#[extendr]
fn rt_job_cancel(job: ExternalPtr<Job>) -> bool {
    runtime::note_entry();
    job.cancel()
}

/// The current phase of a job: `"lock"` (waiting for the prefix lock),
/// `"fetch"`, `"solve"`, `"prefetch"`, `"link"`, `"activate"`, `"clean"`,
/// `"sleep"` or `"done"`.
///
/// @noRd
#[extendr]
fn rt_job_phase(job: ExternalPtr<Job>) -> String {
    runtime::note_entry();
    job.phase().name().to_string()
}

/// Number of jobs of this process that are not done yet.
///
/// @noRd
#[extendr]
fn rt_live_jobs() -> i32 {
    runtime::note_entry();
    job::live_jobs() as i32
}

/// Start a job that solves `specs` against `channels` and links the result
/// into `prefix`, keeping what is installed there (create and install).
/// Installed packages that block the request are removed, as micromamba
/// does. `prefix` is resolved as micromamba resolves it (symbolic links,
/// and backslashes on Windows). Each spec is cleaned as micromamba's parser
/// cleans it (a byte order mark, a ` #` comment and a package URL's non-hex
/// fragment go); a package URL with a hex fragment does not solve (kind
/// `solve`), as with micromamba. A package installed from a URL gets the
/// URL's channel and the archive's hashes and size in its record.
///
/// Result: `list(prefix, records = data.frame(op, name, version, build,
/// channel, subdir), channels, link_scripts_skipped = data.frame(package,
/// script))`; `prefix` is the resolved path.
///
/// Downloads honor what micromamba honors when condathis runs it: the
/// proxy variables libcurl reads (`http_proxy`, `https_proxy`,
/// `all_proxy`, `no_proxy`, the last three also upper-case), the CA bundle
/// libmamba chooses (`<net_root>/ssl/cert.pem`, `Library/ssl/cacert.pem` on
/// Windows, when it exists; else the first of libmamba's system bundles,
/// the system store on Windows), and the credentials of
/// `~/.mamba/auth/authentication.json`, `.netrc` and the channel URLs.
/// `net_root` is condathis's root (micromamba's root prefix), or `NULL`.
///
/// @noRd
// The R function's arguments, one by one.
#[allow(clippy::too_many_arguments)]
#[extendr]
fn rt_install(
    specs: Vec<String>,
    prefix: String,
    channels: Vec<String>,
    channel_priority: String,
    platform: Nullable<String>,
    repodata_cache_dir: String,
    pkgs_cache_dir: String,
    #[extendr(default = "NULL")] net_root: Nullable<String>,
) -> ExternalPtr<Job> {
    runtime::note_entry();
    ExternalPtr::new(install::install_job(install::InstallInput {
        specs,
        prefix: prefix.into(),
        channels,
        channel_priority,
        platform: opt(platform),
        repodata_cache_dir: repodata_cache_dir.into(),
        pkgs_cache_dir: pkgs_cache_dir.into(),
        net: netenv::NetSettings::new(opt(net_root)),
    }))
}

/// Start a job that checks whether `specs` solve for `platform`.
///
/// Result: `TRUE` (solves), `FALSE` (unsolvable, also for a package URL
/// with a hex fragment), `NA` (cannot tell: a missing channel, no network,
/// an invalid spec). Nothing is downloaded or linked. The network settings
/// are those of `rt_install()`.
///
/// @noRd
#[extendr]
fn rt_solve_check(
    specs: Vec<String>,
    channels: Vec<String>,
    channel_priority: String,
    platform: String,
    repodata_cache_dir: String,
    pkgs_cache_dir: String,
    #[extendr(default = "NULL")] net_root: Nullable<String>,
) -> ExternalPtr<Job> {
    runtime::note_entry();
    ExternalPtr::new(install::solve_check_job(install::SolveCheckInput {
        specs,
        channels,
        channel_priority,
        platform,
        repodata_cache_dir: repodata_cache_dir.into(),
        pkgs_cache_dir: pkgs_cache_dir.into(),
        net: netenv::NetSettings::new(opt(net_root)),
    }))
}

/// Start a job that computes the variables activating `prefix` changes,
/// starting from the environment given by `env_names` and `env_values` (also
/// the activation shell's whole environment). `prefix` is resolved as
/// micromamba resolves it, so `CONDA_PREFIX` and the `PATH` entries name
/// the same path as micromamba's.
///
/// Result: a named list of strings, `NA` for a variable the activation
/// unset.
///
/// @noRd
#[extendr]
fn rt_activation_env(
    prefix: String,
    platform: Nullable<String>,
    env_names: Vec<String>,
    env_values: Vec<String>,
) -> extendr_api::Result<ExternalPtr<Job>> {
    runtime::note_entry();
    if env_names.len() != env_values.len() {
        return Err(r_error(
            error::RtError::Internal(format!(
                "env_names has {} elements but env_values has {}",
                env_names.len(),
                env_values.len()
            ))
            .r_message(),
        ));
    }
    Ok(ExternalPtr::new(activation::activation_job(
        activation::ActivationInput {
            prefix: prefix.into(),
            platform: opt(platform),
            env: env_names.into_iter().zip(env_values).collect(),
        },
    )))
}

/// Start a job that empties rattler's package and repodata caches. A
/// cancel stops it before the next top-level entry.
///
/// Result: `list(removed = chr, failed = chr, bytes = dbl)`.
///
/// @noRd
#[extendr]
fn rt_clean_cache(pkgs_cache_dir: String, repodata_cache_dir: String) -> ExternalPtr<Job> {
    runtime::note_entry();
    ExternalPtr::new(cache::clean_cache_job(
        pkgs_cache_dir.into(),
        repodata_cache_dir.into(),
    ))
}

/// Start a job that sleeps for `secs` seconds (a test hook for interrupts
/// and quiescing). Result: `TRUE`.
///
/// @noRd
#[extendr]
fn rt_test_job_sleep(secs: f64) -> ExternalPtr<Job> {
    runtime::note_entry();
    ExternalPtr::new(job::sleep_job(secs))
}

/// Serve the files below `root` over HTTPS on 127.0.0.1, with the identity
/// `cert_pem` (PEM) and `key_der` (PKCS#8 DER), until the process ends (a
/// test hook for the network tests: run it in an R process of its own). The
/// port is written to `port_file` once the server listens; every request
/// line and its `Authorization` header are appended to `log_file` (`NULL`:
/// no log). Answers `GET` and `HEAD`, one request per connection. Returns
/// only on an error.
///
/// @noRd
#[extendr]
fn rt_test_https_server(
    root: String,
    cert_pem: String,
    key_der: String,
    port_file: String,
    log_file: Nullable<String>,
) -> extendr_api::Result<()> {
    runtime::note_entry();
    testserver::serve_forever(
        root.into(),
        cert_pem.into(),
        key_der.into(),
        port_file.into(),
        opt(log_file).map(Into::into),
    )
    .map_err(extendr_api::Error::from)
}

/// The conda subdir rattlerthis was compiled for (`Platform::current()`).
///
/// @noRd
#[extendr]
fn rt_native_platform() -> String {
    runtime::note_entry();
    rattler_conda_types::Platform::current().to_string()
}

/// The effective channel URLs (without trailing slashes) for `channels` and
/// the channel-qualified `specs`, as installs use them. No network.
///
/// @noRd
#[extendr]
fn rt_effective_channels(channels: Vec<String>, specs: Vec<String>) -> extendr_api::Result<Vec<String>> {
    runtime::note_entry();
    let specs = install::parse_specs(&specs).map_err(extendr_api::Error::from)?;
    let channels = channels::effective_channels(&channels, &specs, &channels::channel_config())
        .map_err(extendr_api::Error::from)?;
    Ok(channels.iter().map(channels::channel_url_string).collect())
}

/// Whether this build was compiled with the optional `wheels` Cargo feature,
/// i.e. whether it can install wheel-format packages (the `conda-pypi`
/// channel and similar). Off by default, including for CRAN builds; see
/// PLAN.md ("Wheel packages"). Exposed so the R test suite can skip
/// wheel-specific tests on a build that cannot satisfy them, instead of
/// reporting a configuration choice as a failure.
///
/// @noRd
#[extendr]
fn rt_has_wheel_support() -> bool {
    runtime::note_entry();
    cfg!(feature = "wheels")
}

/// `text` with the credentials of the URLs in it hidden, as rattlerthis
/// hides them in its error messages and libmamba in what it prints: every
/// `/t/<token>` becomes `/t/*****`, and the password of every
/// `<scheme>://user:password@` becomes `*****` (`secrets.rs`). condathis
/// hides them with the same rule. For the request line of the level
/// `"cmd"`. `NA` stays `NA`.
///
/// @noRd
#[extendr]
fn rt_hide_secrets(text: Strings) -> Strings {
    runtime::note_entry();
    // `elt()`, not `iter()`: `iter()` reads the data pointer of the vector,
    // which a debug build rejects for a vector of length zero.
    let hidden: Vec<Rstr> = (0..text.len())
        .map(|i| {
            let s = text.elt(i);
            if s.is_na() {
                Rstr::na()
            } else {
                Rstr::from(secrets::hide_secrets(&s))
            }
        })
        .collect();
    Strings::from_values(hidden)
}

/// Read an environment file the way `micromamba create -f` reads it. The
/// kind comes from the name: `-lock.yml`/`-lock.yaml` a conda-lock file,
/// `.json` a mambajs lock file, `.yml`/`.yaml` an environment YAML file,
/// anything else a text file (explicit when a line starts with
/// `@EXPLICIT`, else one spec per line). `platform` (default: this
/// library's) selects the packages of a lock file; YAML `sel()` selectors
/// follow this library's platform, as micromamba's follow its own. Nothing
/// is downloaded or installed. YAML and lock files may be UTF-8, UTF-16 or
/// UTF-32, with or without a byte order mark; text files are UTF-8.
///
/// Result: `list(kind = "yaml" | "explicit" | "plain" | "conda_lock" |
/// "mambajs_lock", name = chr(1) or NA, channels = chr (YAML channels,
/// environment variables expanded), specs = chr (with `pip` added as
/// micromamba adds it for a `pip:` section), variables = named chr (sorted
/// by name, values as written; used by neither backend), file_platform =
/// chr(1) or NA (an explicit file's `# platform:`), urls = chr (explicit
/// lines, or a lock file's packages as `url#<hash>`), platforms = chr (a
/// lock file's platforms), problems = chr, pip = list of `list(manager,
/// specs, cwd)`)`. `pip` holds the pip steps micromamba runs after the
/// create, in order: one per YAML `pip:` section (`manager` `"pip"`, or
/// `"uv"` when the dependencies list `uv`; `specs` as written, possibly
/// none) and one for a lock file's pip packages (`"pip --no-deps"`, specs
/// `<name> @ <url>#sha256=<sha256>`); `cwd` is the file's absolute
/// directory. micromamba writes the specs, one per line, to a file
/// `mambaf<10 random alphanumerics>` in `cwd` and runs `<env python> -m pip
/// install [--no-deps] -r <file> --no-input` (`<env uv> pip install -r
/// <file>` for `"uv"`) in the activated environment, in `cwd`; a non-zero
/// exit fails the create. Errors: kind `env_file` for a file that cannot be
/// read or parsed (also a text file with NUL bytes, and any field with a
/// NUL), `unsupported` for wheels or source archives among the conda
/// packages of a lock file, `hash_mismatch` for a lock file hash that no
/// archive can match (micromamba fails such a package after downloading
/// it).
///
/// @noRd
#[extendr]
fn rt_read_env_file(path: String, platform: Nullable<String>) -> extendr_api::Result<List> {
    runtime::note_entry();
    let platform = activation::parse_platform(opt(platform).as_deref()).map_err(extendr_api::Error::from)?;
    let file = envfile::read_env_file(std::path::Path::new(&path), platform).map_err(extendr_api::Error::from)?;
    let na_or = |v: Option<String>| -> Robj { Strings::from_values([Rstr::from(v)]).into() };
    let (names, values): (Vec<String>, Vec<String>) = file.variables.into_iter().unzip();
    let mut variables: Robj = Strings::from_values(values).into();
    variables.set_names(names)?;
    let pip: Vec<Robj> = file
        .pip
        .into_iter()
        .map(|g| {
            list!(
                manager = g.manager,
                specs = Strings::from_values(g.specs),
                cwd = g.cwd
            )
            .into()
        })
        .collect();
    Ok(list!(
        kind = file.kind.name(),
        name = na_or(file.name),
        channels = Strings::from_values(file.channels),
        specs = Strings::from_values(file.specs),
        variables = variables,
        file_platform = na_or(file.file_platform),
        urls = Strings::from_values(file.urls),
        platforms = Strings::from_values(file.platforms),
        problems = Strings::from_values(file.problems),
        pip = List::from_values(pip)
    ))
}

/// Start a job that links the packages at `urls` into `prefix` without a
/// solve (explicit files and lock files). Each URL (or local path) may end
/// in `#<md5>`, `#<sha256>` or `#sha256:<sha256>`, which the archive is
/// checked against (kind `hash_mismatch`, also for a hash with upper-case
/// digits, which micromamba never matches); other fragments are ignored.
/// A package already installed under the same name is replaced. Wheels, source archives and VCS URLs are
/// refused (kind `unsupported`), and so is a name given twice (kind
/// `env_file`). Link scripts are skipped and reported, as by `rt_install()`.
/// The history gets micromamba's `# update specs` line for an explicit file
/// (`name==version=build` per URL), and none when `lock_file` is `TRUE` (the
/// URLs of a conda-lock file), as micromamba writes none for lock files.
///
/// Result: as `rt_install()`'s; `channels` are the packages' channels. The
/// network settings are those of `rt_install()`.
///
/// @noRd
#[extendr]
fn rt_install_explicit(
    urls: Vec<String>,
    prefix: String,
    platform: Nullable<String>,
    pkgs_cache_dir: String,
    #[extendr(default = "FALSE")] lock_file: bool,
    #[extendr(default = "NULL")] net_root: Nullable<String>,
) -> ExternalPtr<Job> {
    runtime::note_entry();
    ExternalPtr::new(explicit::install_explicit_job(explicit::ExplicitInput {
        urls,
        prefix: prefix.into(),
        platform: opt(platform),
        pkgs_cache_dir: pkgs_cache_dir.into(),
        lock_file,
        net: netenv::NetSettings::new(opt(net_root)),
    }))
}

// Macro to generate exports.
// This ensures exported functions are registered with R.
// See corresponding C code in `entrypoint.c`.
extendr_module! {
    mod rattlerthis;
    fn rt_job_poll;
    fn rt_job_cancel;
    fn rt_job_phase;
    fn rt_live_jobs;
    fn rt_install;
    fn rt_install_explicit;
    fn rt_read_env_file;
    fn rt_solve_check;
    fn rt_activation_env;
    fn rt_clean_cache;
    fn rt_test_job_sleep;
    fn rt_test_https_server;
    fn rt_native_platform;
    fn rt_effective_channels;
    fn rt_has_wheel_support;
    fn rt_hide_secrets;
}
