//! Install packages whose `RepoDataRecord` points at a raw `.whl` file
//! (the `conda-pypi` channel and similar wheel channels) instead of a
//! `.conda`/`.tar.bz2` archive.
//!
//! `rattler::install::Installer` and `rattler_cache::package_cache` don't
//! know how to fetch or link these yet — they only understand conda's own
//! archive formats — even though `rattler_conda_types` already models
//! `DistArchiveType::Wheel` at the type level and the solver resolves wheel
//! records without complaint. This module fills that gap: download the
//! wheel (a plain zip file), place its contents under the environment's
//! `site-packages` per the wheel install-scheme rules, generate
//! `console_scripts` shims by reusing rattler's own (unexported-but-public)
//! entry-point script template, and write a `conda-meta/*.json` so the
//! package is tracked exactly like any other. See PLAN.md ("Wheel
//! packages").

use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::str::FromStr;

use rattler::install::{get_windows_launcher, python_entry_point_template, PythonInfo};
use rattler_conda_types::{
    package::EntryPoint,
    prefix::Prefix,
    prefix_record::{PathType, PathsEntry},
    Platform, PrefixRecord, RepoDataRecord,
};
use rattler_digest::{compute_bytes_digest, Sha256, Sha256Hash};

use crate::error::{RtError, RtResult};

pub async fn install_wheel(
    client: &reqwest::Client,
    record: &RepoDataRecord,
    prefix: &Path,
    python_info: &PythonInfo,
    platform: Platform,
) -> RtResult<PrefixRecord> {
    let bytes = client
        .get(record.url.clone())
        .send()
        .await
        .and_then(reqwest::Response::error_for_status)
        .map_err(|source| RtError::WheelDownload {
            url: record.url.to_string(),
            source,
        })?
        .bytes()
        .await
        .map_err(|source| RtError::WheelDownload {
            url: record.url.to_string(),
            source,
        })?;

    let paths = {
        let bytes = bytes.to_vec();
        let record = record.clone();
        let prefix = prefix.to_path_buf();
        let python_info = python_info.clone();
        tokio::task::spawn_blocking(move || {
            extract_wheel(&bytes, &record, &prefix, &python_info, platform)
        })
        .await??
    };

    let prefix_record = PrefixRecord::from_repodata_record(record.clone(), paths);
    let prefix_dir = Prefix::create(prefix)?;
    prefix_record.write_to_path(
        prefix_dir
            .path()
            .join("conda-meta")
            .join(prefix_record.file_name()),
        true,
    )?;

    Ok(prefix_record)
}

fn extract_wheel(
    bytes: &[u8],
    record: &RepoDataRecord,
    prefix: &Path,
    python_info: &PythonInfo,
    platform: Platform,
) -> RtResult<Vec<PathsEntry>> {
    let name = record.package_record.name.as_normalized().to_string();

    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|source| RtError::WheelArchive {
            name: name.clone(),
            source,
        })?;

    let mut paths = Vec::new();
    let mut entry_points_txt: Option<String> = None;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|source| RtError::WheelArchive {
                name: name.clone(),
                source,
            })?;
        if entry.is_dir() {
            continue;
        }

        let archive_path = entry.name().to_string();
        if archive_path.ends_with(".dist-info/entry_points.txt") {
            let mut text = String::new();
            entry.read_to_string(&mut text)?;
            entry_points_txt = Some(text);
            continue;
        }

        let mut buf = Vec::with_capacity(entry.size() as usize);
        entry.read_to_end(&mut buf)?;
        #[cfg(unix)]
        let unix_mode = entry.unix_mode();
        drop(entry);

        let relative_path = map_wheel_path(&archive_path, python_info);
        let (sha256, size) = write_file(prefix, &relative_path, &buf)?;

        #[cfg(unix)]
        if let Some(mode) = unix_mode {
            set_unix_mode(prefix, &relative_path, mode)?;
        }

        paths.push(PathsEntry {
            relative_path,
            original_path: None,
            path_type: PathType::HardLink,
            no_link: false,
            sha256: Some(sha256),
            sha256_in_prefix: None,
            size_in_bytes: Some(size),
            file_mode: None,
            prefix_placeholder: None,
        });
    }

    if let Some(text) = entry_points_txt {
        let target_prefix = prefix.to_string_lossy().to_string();
        for line in console_script_lines(&text) {
            let entry_point =
                EntryPoint::from_str(&line).map_err(|source| RtError::WheelEntryPoint {
                    name: name.clone(),
                    line: line.clone(),
                    source,
                })?;
            paths.extend(write_entry_point(
                prefix,
                &target_prefix,
                &entry_point,
                python_info,
                platform,
            )?);
        }
    }

    Ok(paths)
}

/// Maps a path inside a wheel archive to its destination relative to the
/// environment prefix, following the wheel install-scheme convention
/// (PEP 427): plain files and the `.dist-info` directory go straight into
/// `site-packages`; anything under `<dist>-<version>.data/<category>/` is
/// redirected per `category` (`scripts` -> the environment's `bin`
/// directory, `purelib`/`platlib` -> `site-packages`, `data` -> the prefix
/// root, `headers` -> `include/`).
fn map_wheel_path(archive_path: &str, python_info: &PythonInfo) -> PathBuf {
    let mut top_level = archive_path.splitn(2, '/');
    let first = top_level.next().unwrap_or_default();
    let rest_of_path = top_level.next();

    if let (true, Some(rest)) = (first.ends_with(".data"), rest_of_path) {
        let mut category_split = rest.splitn(2, '/');
        let category = category_split.next().unwrap_or_default();
        let sub_rest = category_split.next().unwrap_or_default();
        return match category {
            "scripts" => python_info.bin_dir.join(sub_rest),
            "purelib" | "platlib" => python_info.site_packages_path.join(sub_rest),
            "data" => PathBuf::from(sub_rest),
            "headers" => PathBuf::from("include").join(sub_rest),
            _ => python_info.site_packages_path.join(rest),
        };
    }

    python_info.site_packages_path.join(archive_path)
}

/// Extracts the `[console_scripts]` section of an `entry_points.txt` file as
/// `"command = module:function"` lines, ready for `EntryPoint::from_str`.
fn console_script_lines(entry_points_txt: &str) -> Vec<String> {
    let mut in_console_scripts = false;
    let mut lines = Vec::new();
    for raw_line in entry_points_txt.lines() {
        let line = raw_line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            in_console_scripts = line.eq_ignore_ascii_case("[console_scripts]");
            continue;
        }
        if in_console_scripts && !line.is_empty() && !line.starts_with('#') && !line.starts_with(';')
        {
            lines.push(line.to_string());
        }
    }
    lines
}

fn write_entry_point(
    prefix: &Path,
    target_prefix: &str,
    entry_point: &EntryPoint,
    python_info: &PythonInfo,
    platform: Platform,
) -> RtResult<Vec<PathsEntry>> {
    if platform.is_windows() {
        let script_rel = python_info
            .bin_dir
            .join(format!("{}-script.py", entry_point.command));
        let exe_rel = python_info.bin_dir.join(format!("{}.exe", entry_point.command));

        let script = python_entry_point_template(target_prefix, true, entry_point, python_info);
        let (script_sha256, script_size) = write_file(prefix, &script_rel, script.as_bytes())?;

        let launcher = get_windows_launcher(&platform);
        let (launcher_sha256, launcher_size) = write_file(prefix, &exe_rel, launcher)?;

        Ok(vec![
            PathsEntry {
                relative_path: script_rel,
                original_path: None,
                path_type: PathType::WindowsPythonEntryPointScript,
                no_link: false,
                sha256: Some(script_sha256),
                sha256_in_prefix: None,
                size_in_bytes: Some(script_size),
                file_mode: None,
                prefix_placeholder: None,
            },
            PathsEntry {
                relative_path: exe_rel,
                original_path: None,
                path_type: PathType::WindowsPythonEntryPointExe,
                no_link: false,
                sha256: Some(launcher_sha256),
                sha256_in_prefix: None,
                size_in_bytes: Some(launcher_size),
                file_mode: None,
                prefix_placeholder: None,
            },
        ])
    } else {
        let relative_path = python_info.bin_dir.join(&entry_point.command);
        let script = python_entry_point_template(target_prefix, false, entry_point, python_info);
        let (sha256, size) = write_file(prefix, &relative_path, script.as_bytes())?;

        #[cfg(unix)]
        set_unix_mode(prefix, &relative_path, 0o755)?;

        Ok(vec![PathsEntry {
            relative_path,
            original_path: None,
            path_type: PathType::UnixPythonEntryPoint,
            no_link: false,
            sha256: Some(sha256),
            sha256_in_prefix: None,
            size_in_bytes: Some(size),
            file_mode: None,
            prefix_placeholder: None,
        }])
    }
}

fn write_file(prefix: &Path, relative_path: &Path, bytes: &[u8]) -> RtResult<(Sha256Hash, u64)> {
    let absolute = prefix.join(relative_path);
    if let Some(parent) = absolute.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&absolute, bytes)?;
    Ok((compute_bytes_digest::<Sha256>(bytes), bytes.len() as u64))
}

#[cfg(unix)]
fn set_unix_mode(prefix: &Path, relative_path: &Path, mode: u32) -> RtResult<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(prefix.join(relative_path), std::fs::Permissions::from_mode(mode))?;
    Ok(())
}
