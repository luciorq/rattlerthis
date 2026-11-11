//! The environment variables activating a prefix changes (`rt_activation_env()`).
//!
//! condathis passes the child's environment before activation (`base_env`,
//! as two vectors of names and values). It is both rattler's
//! `ActivationVariables.current_env` and the whole environment of the
//! activation shell, so the result does not depend on the R session's
//! variables (and a non-UTF-8 session variable cannot break it).
//!
//! rattler's `Activator::run_activation()` waits in `Command::output()`, which
//! cannot be stopped, so a hanging `activate.d` script would outlive an
//! interrupt. rattlerthis builds the same script itself (rattler's
//! activation script framed by two environment dumps), runs it as a child
//! process it can kill, and diffs the two dumps with the shell's own parser.
//! On Unix the shell runs in its own process group and a cancel kills the
//! whole group, so commands an `activate.d` script started die with it; on
//! Windows the shell and its child processes are killed with `taskkill /T`.
//!
//! The shell's exit is found by polling `try_wait()` (`waitpid(WNOHANG)`),
//! not through a `SIGCHLD` handler: processx and R's parallel package
//! install their own handlers and do not pass the signal on, so a wait that
//! relies on `SIGCHLD` (tokio's, on macOS) would never see the shell exit.
//! Polling reaps only this shell's pid, so it takes nothing from them.
//!
//! The prefix is resolved as micromamba resolves it (`paths.rs`), so
//! `CONDA_PREFIX` and the `PATH` entries are the same paths micromamba
//! gives; on Windows the prefix's `PATH` entries use backslashes only.
//!
//! The shell is `bash` when `bash` is on the `PATH` of `base_env`, else `sh`
//! (`micromamba run` also falls back to `sh`, `libmamba/src/core/util.cpp`),
//! and `cmd.exe` for a Windows target.
//!
//! The variables of `conda-meta/state` and `etc/conda/env_vars.d` are text
//! as written: libmamba exports them in single quotes
//! (`libmamba/src/core/activation.cpp`). rattler_shell's `Bash` puts a value
//! with a `$` in double quotes, so the shell would expand `$NAME` and run
//! `` `...` `` and `$(...)` in it. For a Unix shell they are therefore not
//! part of rattler's script: they are in the shell's environment from the
//! start (so `activate.d` scripts see them, as with libmamba, which exports
//! them before it runs those scripts), together with the backup of a value
//! they replace that rattler's script would write, and the result has them
//! as written unless an `activate.d` script changed them. cmd.exe expands
//! `%NAME%` in libmamba's `@SET` lines as in rattler's, so a Windows target
//! keeps rattler's script.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::str::FromStr;
use std::time::Duration;

use rattler_conda_types::Subdir;
use rattler_shell::activation::{ActivationVariables, Activator, PathModificationBehavior};
use rattler_shell::shell::{Bash, BashFlavor, CmdExe, Shell, ShellScript};

use crate::error::{RtError, RtResult};
use crate::job::{spawn_job, Job, JobCtx, JobOutput, Phase};

/// Marks the two environment dumps in the shell's output.
const SEPARATOR: &str = "____RATTLERTHIS_ENV_SEPARATOR____";

/// The conda subdir of the platform this library was built for. Resolved at
/// compile time: a target without a conda subdir fails to build here
/// instead of failing at run time. (WebAssembly, the one such r-universe
/// target, builds the package without the Rust library; see
/// `tools/config.R`.)
pub const NATIVE_SUBDIR: Subdir = match Subdir::current() {
    Some(subdir) => subdir,
    None => panic!("rattlerthis: the build target has no conda subdir"),
};

pub fn parse_platform(platform: Option<&str>) -> RtResult<Subdir> {
    match platform {
        None => Ok(NATIVE_SUBDIR),
        Some(s) => Subdir::from_str(s).map_err(|_| RtError::InvalidPlatform {
            platform: s.to_string(),
        }),
    }
}

/// Splits `PATH` the way the target shell does.
fn path_entries(path: &str, platform: Subdir) -> Vec<PathBuf> {
    let sep = if platform.is_windows() { ';' } else { ':' };
    path.split(sep)
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .collect()
}

fn is_executable_file(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// The value of `name` in `env`, case-insensitively on Windows.
fn env_get<'a>(env: &'a [(String, String)], name: &str) -> Option<&'a str> {
    env.iter()
        .rev()
        .find(|(k, _)| {
            if cfg!(windows) {
                k.eq_ignore_ascii_case(name)
            } else {
                k == name
            }
        })
        .map(|(_, v)| v.as_str())
}

/// `true` when `bash` is found on the `PATH` of `env`.
pub fn bash_on_path(env: &[(String, String)], platform: Subdir) -> bool {
    let Some(path) = env_get(env, "PATH") else {
        return false;
    };
    path_entries(path, platform)
        .iter()
        .any(|dir| is_executable_file(&dir.join("bash")))
}

/// The directory activation scripts are written to: the `TMPDIR` (Windows:
/// `TEMP`, `TMP`) of `env` when it exists, else the process's temporary
/// directory.
fn temp_root(env: &[(String, String)]) -> PathBuf {
    let names: &[&str] = if cfg!(windows) {
        &["TEMP", "TMP"]
    } else {
        &["TMPDIR"]
    };
    names
        .iter()
        .filter_map(|n| env_get(env, n))
        .map(PathBuf::from)
        .find(|p| p.is_dir())
        .unwrap_or_else(std::env::temp_dir)
}

pub struct ActivationInput {
    pub prefix: PathBuf,
    pub platform: Option<String>,
    pub env: Vec<(String, String)>,
}

pub fn activation_job(input: ActivationInput) -> Job {
    spawn_job(Phase::Activate, move |ctx| async move {
        let env = activation_env(&ctx, input).await?;
        Ok(JobOutput::Env(env))
    })
}

async fn activation_env(
    ctx: &JobCtx,
    mut input: ActivationInput,
) -> RtResult<Vec<(String, Option<String>)>> {
    let platform = parse_platform(input.platform.as_deref())?;
    input.prefix = crate::paths::weakly_canonical(&input.prefix);
    if platform.is_windows() {
        run_with_shell(ctx, CmdExe, platform, input).await
    } else {
        let flavor = if bash_on_path(&input.env, platform) {
            BashFlavor::Bash
        } else {
            BashFlavor::Sh
        };
        run_with_shell(ctx, Bash { flavor }, platform, input).await
    }
}

async fn run_with_shell<T: Shell + Clone + Send + 'static>(
    ctx: &JobCtx,
    shell: T,
    platform: Subdir,
    input: ActivationInput,
) -> RtResult<Vec<(String, Option<String>)>> {
    let activation_error = |e: &dyn std::fmt::Display| RtError::Activation(e.to_string());
    let mut activator = Activator::from_path(&input.prefix, shell.clone(), platform)
        .map_err(|e| activation_error(&e))?;
    let literal = if platform.is_windows() {
        Vec::new()
    } else {
        // A name that is not a shell identifier, or a value with a NUL,
        // stays in rattler's script, which treats it as before (like
        // libmamba's `export` line, the shell does not set such a name).
        let (literal, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut activator.env_vars)
            .into_iter()
            .partition(|(key, value)| is_shell_identifier(key) && !value.contains('\0'));
        activator.env_vars = kept.into_iter().collect();
        with_env_var_backups(literal, &input.env)
    };
    let current_env: HashMap<String, String> = input.env.iter().cloned().collect();
    let variables = ActivationVariables {
        conda_prefix: None,
        path: None,
        path_modification_behavior: PathModificationBehavior::Prepend,
        current_env,
    };
    let activation = activator
        .activation(variables)
        .map_err(|e| activation_error(&e))?;

    let mut script = ShellScript::new(shell.clone(), platform);
    script
        .print_env()
        .and_then(|s| s.echo(SEPARATOR))
        .map_err(|e| activation_error(&e))?;
    script.append_script(&activation.script);
    script
        .echo(SEPARATOR)
        .and_then(|s| s.print_env())
        .map_err(|e| activation_error(&e))?;
    let contents = script.contents().map_err(|e| activation_error(&e))?;

    let dir = tempfile::Builder::new()
        .prefix("rattlerthis-activate-")
        .tempdir_in(temp_root(&input.env))
        .map_err(|e| RtError::io_at("failed to create the activation script directory", e))?;
    let script_path = dir.path().join(format!("activation.{}", shell.extension()));
    std::fs::write(&script_path, contents)
        .map_err(|e| RtError::io_at("failed to write the activation script", e))?;

    // The shell writes to files, not pipes: a process an activate.d script
    // leaves running in the background would hold a pipe open, so reading
    // it to the end would wait for that process (and, on Windows, keep a
    // blocking reader thread alive).
    let out_path = dir.path().join("stdout.txt");
    let err_path = dir.path().join("stderr.txt");
    let out_file = std::fs::File::create(&out_path)
        .map_err(|e| RtError::io_at("failed to create the activation output file", e))?;
    let err_file = std::fs::File::create(&err_path)
        .map_err(|e| RtError::io_at("failed to create the activation output file", e))?;
    let mut command = shell.create_run_script_command(&script_path);
    command
        .env_clear()
        .envs(input.env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .envs(literal.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .stdin(Stdio::null())
        .stdout(Stdio::from(out_file))
        .stderr(Stdio::from(err_file));
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let child = command.spawn().map_err(|e| {
        RtError::Activation(format!(
            "failed to start {} for the activation script: {e}",
            shell.executable()
        ))
    })?;
    let mut child = ShellChild(Some(child));

    let mut delay = Duration::from_millis(1);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(e) => return Err(RtError::Activation(format!("activation script failed: {e}"))),
        }
        tokio::select! {
            biased;
            _ = ctx.cancelled() => {
                child.kill();
                return Err(RtError::Cancelled);
            }
            _ = tokio::time::sleep(delay) => {}
        }
        delay = (delay * 2).min(Duration::from_millis(20));
    };
    child.0 = None;
    let stdout = std::fs::read(&out_path)
        .map_err(|e| RtError::io_at("failed to read the activation output", e))?;
    let stderr = std::fs::read(&err_path).unwrap_or_default();
    drop(dir);

    if !status.success() {
        return Err(RtError::Activation(format!(
            "the activation script exited with {}:\n{}",
            status,
            String::from_utf8_lossy(&stderr).trim_end()
        )));
    }
    let stdout = String::from_utf8_lossy(&stdout);
    let (before, rest) = stdout
        .split_once(SEPARATOR)
        .unwrap_or(("", stdout.as_ref()));
    let (_, after) = rest.rsplit_once(SEPARATOR).unwrap_or(("", ""));
    let before = shell.parse_env(before);
    let after = shell.parse_env(after);
    let mut changed: Vec<(String, Option<String>)> = after
        .iter()
        .filter(|(key, value)| !key.is_empty() && before.get(*key) != Some(*value))
        .map(|(key, value)| (key.to_string(), Some(value.to_string())))
        .collect();
    // A variable of the first dump that the second lacks was unset by the
    // activation (an `activate.d` script): `None`, so the command does not
    // get it either, as libmamba's activation reports it (condathis unsets
    // a variable whose value is `NA`).
    changed.extend(
        before
            .keys()
            .filter(|key| !key.is_empty() && !after.contains_key(*key))
            .map(|key| (key.to_string(), None)),
    );
    // A literal variable is in `before` already; it is part of the result
    // with its value unless the activation changed or removed it.
    for (key, value) in &literal {
        if after.get(key.as_str()) == Some(&value.as_str())
            && !changed.iter().any(|(k, _)| k == key)
        {
            changed.push((key.clone(), Some(value.clone())));
        }
    }
    if platform.is_windows() {
        for (key, value) in changed.iter_mut() {
            if let (true, Some(value)) = (key.eq_ignore_ascii_case("PATH"), value.as_mut()) {
                *value = backslash_prefix_entries(value, &input.prefix);
            }
        }
    }
    changed.sort();
    Ok(changed)
}

/// The variables a Unix shell gets as written (from the activator's
/// variables of `conda-meta/state` and `etc/conda/env_vars.d`, in their
/// order), each after the backup that rattler's script writes for a
/// variable `env` already has (`CONDA_ENV_SHLVL_<level>_<NAME>`).
fn with_env_var_backups(vars: Vec<(String, String)>, env: &[(String, String)]) -> Vec<(String, String)> {
    let shlvl = env_get(env, "CONDA_SHLVL")
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(0)
        + 1;
    let mut out = Vec::with_capacity(vars.len());
    for (key, value) in vars {
        if let Some(existing) = env_get(env, &key) {
            out.push((format!("CONDA_ENV_SHLVL_{shlvl}_{key}"), existing.to_string()));
        }
        out.push((key, value));
    }
    out
}

/// `[A-Za-z_][A-Za-z0-9_]*`: a name `sh` and `bash` can `export`.
fn is_shell_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// The `PATH` entries under `prefix` with backslashes only: rattler joins
/// `Library/mingw-w64/bin` and friends to the prefix with forward slashes,
/// micromamba writes them with backslashes.
fn backslash_prefix_entries(path: &str, prefix: &Path) -> String {
    let prefix = prefix.to_string_lossy().replace('/', "\\").to_ascii_lowercase();
    path.split(';')
        .map(|entry| {
            let normalized = entry.replace('/', "\\");
            if normalized.to_ascii_lowercase().starts_with(&prefix) {
                normalized
            } else {
                entry.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(";")
}

/// The activation shell, killed with everything it started when dropped
/// before it was reaped (a cancel, or an error while waiting).
struct ShellChild(Option<std::process::Child>);

impl ShellChild {
    fn try_wait(&mut self) -> std::io::Result<Option<std::process::ExitStatus>> {
        match self.0.as_mut() {
            Some(child) => child.try_wait(),
            None => Ok(None),
        }
    }

    fn kill(&mut self) {
        if let Some(mut child) = self.0.take() {
            kill_tree(child.id());
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for ShellChild {
    fn drop(&mut self) {
        self.kill();
    }
}

/// Kills a cancelled activation shell and everything it started.
fn kill_tree(pid: u32) {
    #[cfg(unix)]
    {
        // The shell leads its own process group (`process_group(0)`).
        // SAFETY: plain syscall; a stale pid only yields ESRCH.
        unsafe {
            libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
        }
    }
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("taskkill")
            .args(["/T", "/F", "/PID", &pid.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::job::PollResult;
    use std::time::{Duration, Instant};

    fn session_env() -> Vec<(String, String)> {
        std::env::vars_os()
            .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
            .filter(|(k, _)| !k.starts_with("CONDA_") && k != "PATH")
            .chain(std::iter::once((
                "PATH".to_string(),
                "/usr/local/bin:/usr/bin:/bin".to_string(),
            )))
            .collect()
    }

    fn make_prefix(activate_script: Option<&str>) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("conda-meta")).unwrap();
        std::fs::write(dir.path().join("conda-meta/history"), "").unwrap();
        std::fs::create_dir_all(dir.path().join("bin")).unwrap();
        if let Some(body) = activate_script {
            let d = dir.path().join("etc/conda/activate.d");
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("x.sh"), body).unwrap();
        }
        dir
    }

    /// Whether `pid` has ended but was not reaped: a zombie. A killed
    /// orphan becomes one in a container whose first process never reaps
    /// (`docker run` without `--init`). Linux only: elsewhere `false`.
    fn is_zombie(pid: i32) -> bool {
        // The state follows the command name, which can hold `)`.
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .ok()
            .and_then(|stat| {
                stat.rsplit_once(')')
                    .map(|(_, rest)| rest.trim_start().starts_with('Z'))
            })
            .unwrap_or(false)
    }

    fn run(prefix: &Path, env: Vec<(String, String)>) -> Result<Vec<(String, Option<String>)>, String> {
        let job = activation_job(ActivationInput {
            prefix: prefix.to_path_buf(),
            platform: None,
            env,
        });
        match job.wait() {
            PollResult::Done(JobOutput::Env(env)) => Ok(env),
            PollResult::Failed(msg) => Err(msg),
            _ => Err("unexpected".into()),
        }
    }

    fn get<'a>(env: &'a [(String, Option<String>)], k: &str) -> Option<&'a str> {
        env.iter().find(|(n, _)| n == k).and_then(|(_, v)| v.as_deref())
    }

    fn removed(env: &[(String, Option<String>)]) -> Vec<&str> {
        env.iter().filter(|(_, v)| v.is_none()).map(|(n, _)| n.as_str()).collect()
    }

    #[test]
    fn activation_from_a_clean_base_env() {
        let prefix = make_prefix(Some("export RT_TEST_ACTIVATED=yes\n"));
        let mut env = session_env();
        // A stale shell level and prefix must not leak in: base_env is the
        // whole environment.
        env.push(("CONDA_SHLVL".into(), "0".into()));
        let out = run(prefix.path(), env).unwrap();
        assert_eq!(get(&out, "CONDA_SHLVL"), Some("1"));
        let resolved = crate::paths::weakly_canonical(prefix.path());
        assert_eq!(get(&out, "CONDA_PREFIX"), Some(resolved.to_str().unwrap()));
        assert_eq!(get(&out, "RT_TEST_ACTIVATED"), Some("yes"));
        let path = get(&out, "PATH").unwrap();
        assert!(path.starts_with(resolved.join("bin").to_str().unwrap()), "{path}");
        assert!(path.ends_with("/usr/local/bin:/usr/bin:/bin"), "{path}");
        assert!(!out.iter().any(|(k, _)| k.starts_with("CONDA_ENV_SHLVL_")), "{out:?}");
        // The activation itself unsets nothing.
        assert!(removed(&out).is_empty(), "{out:?}");
    }

    #[test]
    fn a_variable_an_activate_d_script_unsets_is_reported_as_removed() {
        let prefix = make_prefix(Some("unset RT_TEST_UNSET\nunset RT_TEST_NEVER_SET\n"));
        let mut env = session_env();
        env.push(("RT_TEST_UNSET".into(), "session".into()));
        env.push(("RT_TEST_KEPT".into(), "session".into()));
        let out = run(prefix.path(), env).unwrap();
        assert_eq!(removed(&out), vec!["RT_TEST_UNSET"], "{out:?}");
        assert!(!out.iter().any(|(k, _)| k == "RT_TEST_KEPT"), "{out:?}");
    }

    #[test]
    fn sh_is_used_when_bash_is_not_on_path() {
        let dir = tempfile::tempdir().unwrap();
        // A PATH with only `sh` (and `env`, which the dump runs by absolute
        // path anyway).
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let sh = ["/bin/sh", "/usr/bin/sh"].into_iter().find(|p| Path::new(p).exists()).unwrap();
        std::os::unix::fs::symlink(sh, bin.join("sh")).unwrap();
        let env: Vec<(String, String)> = session_env()
            .into_iter()
            .filter(|(k, _)| k != "PATH")
            .chain(std::iter::once(("PATH".into(), bin.to_string_lossy().to_string())))
            .collect();
        assert!(!bash_on_path(&env, NATIVE_SUBDIR));
        let prefix = make_prefix(Some("export RT_TEST_SH=1\n"));
        let out = run(prefix.path(), env).unwrap();
        assert_eq!(get(&out, "RT_TEST_SH"), Some("1"));
        assert_eq!(get(&out, "CONDA_SHLVL"), Some("1"));
    }

    #[test]
    fn a_hanging_activation_is_killed_on_cancel() {
        let marker = tempfile::tempdir().unwrap();
        let pidfile = marker.path().join("pid");
        let script = format!("sleep 300 &\necho $! > {}\nwait\n", pidfile.display());
        let prefix = make_prefix(Some(&script));
        let job = activation_job(ActivationInput {
            prefix: prefix.path().to_path_buf(),
            platform: None,
            env: session_env(),
        });
        let start = Instant::now();
        while !pidfile.exists() {
            assert!(start.elapsed() < Duration::from_secs(10), "activation script never started");
            std::thread::sleep(Duration::from_millis(10));
        }
        std::thread::sleep(Duration::from_millis(50));
        let sleep_pid: i32 = std::fs::read_to_string(&pidfile).unwrap().trim().parse().unwrap();
        assert!(job.cancel());
        match job.wait() {
            PollResult::Failed(msg) => assert!(msg.starts_with("[rattlerthis:cancelled]"), "{msg}"),
            _ => panic!("expected a cancelled activation"),
        }
        assert!(start.elapsed() < Duration::from_secs(40));
        // The grandchild started by activate.d is gone too (a zombie has
        // ended).
        let gone = (0..200).any(|_| {
            let alive = unsafe { libc::kill(sleep_pid, 0) } == 0 && !is_zombie(sleep_pid);
            if alive {
                std::thread::sleep(Duration::from_millis(10));
            }
            !alive
        });
        assert!(gone, "the activate.d child survived the cancel");
    }

    #[test]
    fn a_background_process_does_not_hold_the_activation() {
        // An activate.d script that leaves a process running (with the
        // shell's stdout) must not make the activation wait for it.
        let prefix = make_prefix(Some("sleep 30 &\nexport RT_TEST_BG=1\n"));
        let start = Instant::now();
        let out = run(prefix.path(), session_env()).unwrap();
        assert_eq!(get(&out, "RT_TEST_BG"), Some("1"));
        assert!(start.elapsed() < Duration::from_secs(20), "{:?}", start.elapsed());
    }

    #[test]
    fn state_variables_are_set_as_written() {
        // An activate.d script sees the variables, and neither `$NAME` nor
        // a command substitution in a value is expanded (libmamba exports
        // them in single quotes).
        let prefix = make_prefix(Some("export RT_TEST_SEEN=\"$RT_STATE_VAR\"\n"));
        let value = "A $HOME B `echo TICK` C $(echo SUB) D \"q\" E \\ F 'G'";
        std::fs::write(
            prefix.path().join("conda-meta/state"),
            r#"{"env_vars": {"RT_STATE_VAR": "A $HOME B `echo TICK` C $(echo SUB) D \"q\" E \\ F 'G'", "RT_CLOBBER": "new"}}"#,
        )
        .unwrap();
        let mut env = session_env();
        env.push(("RT_CLOBBER".into(), "old".into()));
        let out = run(prefix.path(), env).unwrap();
        assert_eq!(get(&out, "RT_STATE_VAR"), Some(value));
        assert_eq!(get(&out, "RT_TEST_SEEN"), Some(value));
        assert_eq!(get(&out, "RT_CLOBBER"), Some("new"));
        // The backup rattler's own script writes for a replaced value.
        assert_eq!(get(&out, "CONDA_ENV_SHLVL_1_RT_CLOBBER"), Some("old"));
    }

    #[test]
    fn an_activate_d_script_can_change_a_state_variable() {
        let prefix = make_prefix(Some("export RT_STATE_VAR=\"changed:$RT_STATE_VAR\"\n"));
        std::fs::write(prefix.path().join("conda-meta/state"), r#"{"env_vars": {"RT_STATE_VAR": "x$y"}}"#).unwrap();
        let out = run(prefix.path(), session_env()).unwrap();
        assert_eq!(get(&out, "RT_STATE_VAR"), Some("changed:x$y"));
    }

    #[test]
    fn a_failing_activation_is_an_activation_error() {
        let prefix = make_prefix(Some("exit 3\n"));
        let msg = run(prefix.path(), session_env()).unwrap_err();
        assert!(msg.starts_with("[rattlerthis:activation]"), "{msg}");
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;
    use crate::job::PollResult;
    use std::time::{Duration, Instant};

    fn session_env() -> Vec<(String, String)> {
        std::env::vars_os()
            .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
            .filter(|(k, _)| !k.to_ascii_uppercase().starts_with("CONDA_"))
            .collect()
    }

    fn make_prefix(script: Option<&str>) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("conda-meta")).unwrap();
        std::fs::write(dir.path().join("conda-meta").join("history"), "").unwrap();
        if let Some(body) = script {
            let d = dir.path().join("etc").join("conda").join("activate.d");
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("x.bat"), body).unwrap();
        }
        dir
    }

    fn get<'a>(env: &'a [(String, Option<String>)], k: &str) -> Option<&'a str> {
        env.iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(k))
            .and_then(|(_, v)| v.as_deref())
    }

    fn removed(env: &[(String, Option<String>)]) -> Vec<String> {
        env.iter()
            .filter(|(_, v)| v.is_none())
            .map(|(n, _)| n.to_ascii_uppercase())
            .collect()
    }

    #[test]
    fn cmd_activation_from_a_clean_base_env() {
        let prefix = make_prefix(Some("@set \"RT_TEST_ACTIVATED=yes\"\r\n"));
        let job = activation_job(ActivationInput {
            prefix: prefix.path().to_path_buf(),
            platform: None,
            env: session_env(),
        });
        let out = match job.wait() {
            PollResult::Done(JobOutput::Env(env)) => env,
            PollResult::Failed(msg) => panic!("{msg}"),
            _ => panic!("unexpected activation result"),
        };
        assert_eq!(get(&out, "CONDA_SHLVL"), Some("1"));
        let resolved = crate::paths::weakly_canonical(prefix.path());
        let resolved = resolved.to_str().unwrap();
        assert_eq!(get(&out, "CONDA_PREFIX"), Some(resolved));
        assert_eq!(get(&out, "RT_TEST_ACTIVATED"), Some("yes"));
        let path = get(&out, "PATH").unwrap();
        assert!(path.starts_with(resolved), "{path}");
        // Every entry under the prefix uses backslashes, as micromamba's.
        for entry in path.split(';').filter(|e| e.to_ascii_lowercase().starts_with(&resolved.to_ascii_lowercase())) {
            assert!(!entry.contains('/'), "{entry}");
        }
        assert!(!out.iter().any(|(k, _)| k.starts_with("CONDA_ENV_SHLVL_")), "{out:?}");
        // The activation itself unsets nothing.
        assert!(removed(&out).is_empty(), "{out:?}");
    }

    #[test]
    fn a_variable_an_activate_d_script_unsets_is_reported_as_removed() {
        let prefix = make_prefix(Some("@set \"RT_TEST_UNSET=\"\r\n@set \"RT_TEST_NEVER_SET=\"\r\n"));
        let mut env = session_env();
        env.push(("RT_TEST_UNSET".into(), "session".into()));
        env.push(("RT_TEST_KEPT".into(), "session".into()));
        let job = activation_job(ActivationInput {
            prefix: prefix.path().to_path_buf(),
            platform: None,
            env,
        });
        let out = match job.wait() {
            PollResult::Done(JobOutput::Env(env)) => env,
            PollResult::Failed(msg) => panic!("{msg}"),
            _ => panic!("unexpected activation result"),
        };
        assert_eq!(removed(&out), vec!["RT_TEST_UNSET".to_string()], "{out:?}");
        assert!(!out.iter().any(|(k, _)| k.eq_ignore_ascii_case("RT_TEST_KEPT")), "{out:?}");
    }

    #[test]
    fn a_forward_slash_prefix_is_resolved_like_micromamba() {
        let prefix = make_prefix(None);
        let forward = prefix.path().to_str().unwrap().replace('\\', "/");
        let job = activation_job(ActivationInput {
            prefix: PathBuf::from(&forward),
            platform: None,
            env: session_env(),
        });
        let out = match job.wait() {
            PollResult::Done(JobOutput::Env(env)) => env,
            PollResult::Failed(msg) => panic!("{msg}"),
            _ => panic!("unexpected activation result"),
        };
        let resolved = crate::paths::weakly_canonical(prefix.path());
        let conda_prefix = get(&out, "CONDA_PREFIX").unwrap();
        assert_eq!(conda_prefix, resolved.to_str().unwrap());
        assert!(!conda_prefix.contains('/'), "{conda_prefix}");
        let path = get(&out, "PATH").unwrap();
        let mingw = format!("{conda_prefix}\\Library\\mingw-w64\\bin");
        assert!(path.split(';').any(|e| e == mingw), "{path}");
    }

    #[test]
    fn a_background_process_does_not_hold_the_cmd_activation() {
        let prefix = make_prefix(Some("@start /b ping -n 30 127.0.0.1\r\n@set \"RT_TEST_BG=1\"\r\n"));
        let start = Instant::now();
        let job = activation_job(ActivationInput {
            prefix: prefix.path().to_path_buf(),
            platform: None,
            env: session_env(),
        });
        match job.wait() {
            PollResult::Done(JobOutput::Env(env)) => assert_eq!(get(&env, "RT_TEST_BG"), Some("1")),
            PollResult::Failed(msg) => panic!("{msg}"),
            _ => panic!("unexpected activation result"),
        }
        assert!(start.elapsed() < Duration::from_secs(20), "{:?}", start.elapsed());
    }

    #[test]
    fn a_hanging_cmd_activation_is_killed_on_cancel() {
        let prefix = make_prefix(Some("@ping -n 300 127.0.0.1 >nul\r\n"));
        let job = activation_job(ActivationInput {
            prefix: prefix.path().to_path_buf(),
            platform: None,
            env: session_env(),
        });
        std::thread::sleep(Duration::from_millis(1500));
        assert!(matches!(job.poll(), PollResult::Running), "the activation should hang");
        let start = Instant::now();
        assert!(job.cancel());
        match job.wait() {
            PollResult::Failed(msg) => assert!(msg.starts_with("[rattlerthis:cancelled]"), "{msg}"),
            _ => panic!("expected a cancelled activation"),
        }
        assert!(start.elapsed() < Duration::from_secs(40));
    }
}
