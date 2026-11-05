//! Environment paths as micromamba resolves them.
//!
//! micromamba 2.10 resolves its target prefix with `fs::weakly_canonical()`
//! (`libmamba/src/api/configuration.cpp`): symbolic links in the part of
//! the path that exists are resolved, the rest is appended with `.` and `..`
//! resolved lexically, and on Windows the result uses backslashes and no
//! `\\?\` prefix. The prefix is what ends up in `CONDA_PREFIX`, in the
//! activated `PATH` and in every text file whose prefix placeholder is
//! replaced at link time, so rattlerthis resolves it the same way: under a
//! symbolic link (macOS's `/var` -> `/private/var`, a symlinked home on a
//! cluster) both backends then write the same path.

use std::path::{Component, Path, PathBuf};

/// `std::filesystem::weakly_canonical()`, as libmamba uses it.
pub fn weakly_canonical(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        match std::env::current_dir() {
            Ok(dir) => dir.join(path),
            Err(_) => return path.to_path_buf(),
        }
    };
    let components: Vec<Component<'_>> = absolute.components().collect();
    // The longest leading part that exists, canonicalized.
    let mut split = components.len();
    let mut base = loop {
        if split == 0 {
            break PathBuf::new();
        }
        let head: PathBuf = components[..split].iter().collect();
        if let Ok(canonical) = std::fs::canonicalize(&head) {
            break strip_verbatim(canonical);
        }
        split -= 1;
    };
    for component in &components[split..] {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                base.pop();
            }
            other => base.push(other.as_os_str()),
        }
    }
    base
}

/// Removes the `\\?\` (or `\\?\UNC\`) prefix `canonicalize()` puts on
/// Windows paths; `std::filesystem` on Windows returns the plain form.
#[cfg(windows)]
fn strip_verbatim(path: PathBuf) -> PathBuf {
    let Some(text) = path.to_str() else {
        return path;
    };
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{rest}"))
    } else if let Some(rest) = text.strip_prefix(r"\\?\") {
        PathBuf::from(rest)
    } else {
        path
    }
}

#[cfg(not(windows))]
fn strip_verbatim(path: PathBuf) -> PathBuf {
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn existing_parts_are_resolved_and_the_rest_is_appended() {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let root = strip_verbatim(root);
        std::fs::create_dir_all(root.join("real")).unwrap();
        let got = weakly_canonical(&root.join("real").join(".").join("envs").join("x").join("..").join("e"));
        assert_eq!(got, root.join("real").join("envs").join("e"));
        assert_eq!(weakly_canonical(&root), root);
    }

    #[cfg(unix)]
    #[test]
    fn symbolic_links_are_resolved() {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        std::fs::create_dir_all(root.join("real")).unwrap();
        std::os::unix::fs::symlink(root.join("real"), root.join("link")).unwrap();
        assert_eq!(
            weakly_canonical(&root.join("link").join("envs").join("e")),
            root.join("real").join("envs").join("e")
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_paths_use_backslashes_without_a_verbatim_prefix() {
        let dir = tempfile::tempdir().unwrap();
        let forward = dir.path().to_str().unwrap().replace('\\', "/") + "/envs/e";
        let got = weakly_canonical(Path::new(&forward));
        let text = got.to_str().unwrap();
        assert!(!text.contains('/'), "{text}");
        assert!(!text.starts_with(r"\\?\"), "{text}");
        assert!(text.ends_with(r"\envs\e"), "{text}");
    }
}
