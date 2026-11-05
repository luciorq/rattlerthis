//! Which link scripts rattler skipped.
//!
//! rattlerthis installs with link scripts off (`with_execute_link_scripts(false)`,
//! a user decision), while micromamba runs `pre-link`, `post-link` and
//! `pre-unlink` scripts (`libmamba/src/core/link.cpp` `run_script()`). So
//! every script micromamba would have run is reported, as `(package, script)`
//! pairs, and condathis warns about them. The rules are libmamba's:
//!
//! - the script is `bin/.<name>-<kind>.sh`, or `Scripts/.<name>-<kind>.bat`
//!   when micromamba runs on Windows; the choice follows the machine
//!   (libmamba's compile-time `util::on_win`), not the target platform;
//! - `pre-link` is looked up in the extracted package (the package cache
//!   entry the link reads from), before anything of the package is linked;
//!   a noarch python package's `python-scripts/` files are only moved to
//!   `bin/` in the prefix, so they never count as a `pre-link` script;
//! - `post-link` is looked up in the prefix after the package is linked;
//! - `pre-unlink` is looked up in the prefix before the package is removed
//!   (for every removed record and the old side of every change).

use std::path::Path;

use rattler_conda_types::PackageRecord;

pub const PRE_LINK: &str = "pre-link";
pub const POST_LINK: &str = "post-link";
pub const PRE_UNLINK: &str = "pre-unlink";

/// The relative path of a link script of `record`, as micromamba on this
/// machine looks for it.
pub fn script_path(record: &PackageRecord, kind: &str) -> String {
    let name = record.name.as_source();
    if cfg!(windows) {
        format!("Scripts/.{name}-{kind}.bat")
    } else {
        format!("bin/.{name}-{kind}.sh")
    }
}

fn found(base: &Path, record: &PackageRecord, kind: &'static str) -> Option<(String, &'static str)> {
    base.join(script_path(record, kind))
        .is_file()
        .then(|| (record.name.as_normalized().to_string(), kind))
}

/// The `pre-link` script of a package, from its extracted directory.
pub fn pre_link(package_dir: &Path, record: &PackageRecord) -> Option<(String, &'static str)> {
    found(package_dir, record, PRE_LINK)
}

/// The `post-link` script of a package just linked into `prefix`.
pub fn post_link(prefix: &Path, record: &PackageRecord) -> Option<(String, &'static str)> {
    found(prefix, record, POST_LINK)
}

/// The `pre-unlink` script of an installed package, from `prefix` (before
/// the package is removed).
pub fn pre_unlink(prefix: &Path, record: &PackageRecord) -> Option<(String, &'static str)> {
    found(prefix, record, PRE_UNLINK)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rattler_conda_types::{PackageName, Version};
    use std::str::FromStr;

    fn package(name: &str) -> PackageRecord {
        PackageRecord::new(
            PackageName::new_unchecked(name),
            Version::from_str("1.0").unwrap(),
            "0".into(),
        )
    }

    #[test]
    fn script_paths_follow_the_machine() {
        let r = package("plink");
        if cfg!(windows) {
            assert_eq!(script_path(&r, POST_LINK), "Scripts/.plink-post-link.bat");
            assert_eq!(script_path(&r, PRE_UNLINK), "Scripts/.plink-pre-unlink.bat");
        } else {
            assert_eq!(script_path(&r, POST_LINK), "bin/.plink-post-link.sh");
            assert_eq!(script_path(&r, PRE_LINK), "bin/.plink-pre-link.sh");
        }
    }

    #[test]
    fn scripts_are_found_where_micromamba_looks() {
        let dir = tempfile::tempdir().unwrap();
        let (bin, ext) = if cfg!(windows) { ("Scripts", "bat") } else { ("bin", "sh") };
        std::fs::create_dir_all(dir.path().join(bin)).unwrap();
        std::fs::write(dir.path().join(format!("{bin}/.plink-post-link.{ext}")), "x").unwrap();
        // The other OS's script never counts.
        let other = if cfg!(windows) { "bin/.plink-pre-unlink.sh" } else { "Scripts/.plink-pre-unlink.bat" };
        std::fs::create_dir_all(dir.path().join(other).parent().unwrap()).unwrap();
        std::fs::write(dir.path().join(other), "x").unwrap();
        let r = package("plink");
        assert_eq!(post_link(dir.path(), &r), Some(("plink".to_string(), POST_LINK)));
        assert_eq!(pre_link(dir.path(), &r), None);
        assert_eq!(pre_unlink(dir.path(), &r), None);
        assert_eq!(post_link(dir.path(), &package("other")), None);
    }
}
