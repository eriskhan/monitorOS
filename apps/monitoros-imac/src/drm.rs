//! Read-only discovery of the Radeon card that owns the connected 5K panel.
//!
//! `drm_root` is normally `/sys/class/drm`; accepting a path keeps discovery
//! testable without a GPU, privileges, or numeric DRM connector IDs.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DrmDevice {
    pub path: PathBuf,
    pub reason: String,
}

pub fn select_device(drm_root: &Path, explicit: Option<&Path>) -> io::Result<Option<DrmDevice>> {
    if let Some(path) = explicit {
        return Ok(Some(DrmDevice {
            path: path.to_path_buf(),
            reason: "explicit --device override; automatic discovery bypassed".to_string(),
        }));
    }

    let entries = match fs::read_dir(drm_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(context(drm_root, error)),
    };
    let mut names = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| context(drm_root, error))?;
        if let Ok(name) = entry.file_name().into_string() {
            names.push(name);
        }
    }
    names.sort();

    let mut candidates = Vec::new();
    for card in names.iter().filter(|name| is_card(name)) {
        let vendor = read_attribute(&drm_root.join(card).join("device/vendor"))?;
        if !vendor.is_some_and(|value| value.trim().eq_ignore_ascii_case("0x1002")) {
            continue;
        }

        let prefix = format!("{card}-");
        let mut connectors = Vec::new();
        for connector in names.iter().filter(|name| name.starts_with(&prefix)) {
            let root = drm_root.join(connector);
            let status = read_attribute(&root.join("status"))?;
            if !status.is_some_and(|value| value.trim() == "connected") {
                continue;
            }
            let modes = read_attribute(&root.join("modes"))?;
            if modes.is_some_and(|value| value.lines().any(|mode| mode.trim() == "5120x2880")) {
                connectors.push(connector.as_str());
            }
        }

        if !connectors.is_empty() {
            candidates.push(DrmDevice {
                path: Path::new("/dev/dri").join(card),
                reason: format!(
                    "AMD PCI vendor 0x1002; connected {} advertises 5120x2880",
                    connectors.join(", ")
                ),
            });
        }
    }

    match candidates.len() {
        0 => Ok(None),
        1 => Ok(candidates.pop()),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "ambiguous DRM discovery: multiple AMD cards have a connected 5120x2880 connector: {}; refusing to choose (use --device only for an intentional override)",
                candidates
                    .iter()
                    .map(|device| device.path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        )),
    }
}

fn is_card(name: &str) -> bool {
    name.strip_prefix("card").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn read_attribute(path: &Path) -> io::Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(value) => Ok(Some(value)),
        // DRM devices/attributes may not exist yet or may disappear mid-scan.
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(context(path, error)),
    }
}

fn context(path: &Path, error: io::Error) -> io::Error {
    io::Error::new(error.kind(), format!("{}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Tree(PathBuf);

    impl Tree {
        fn new() -> Self {
            static NEXT_ID: AtomicU64 = AtomicU64::new(0);
            let root = std::env::temp_dir().join(format!(
                "monitoros-drm-test-{}-{}",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            Self(root)
        }

        fn card(&self, name: &str, vendor: &str) {
            let device = self.0.join(name).join("device");
            fs::create_dir_all(&device).unwrap();
            fs::write(device.join("vendor"), vendor).unwrap();
        }

        fn connector(&self, name: &str, status: &str, modes: &str) {
            let connector = self.0.join(name);
            fs::create_dir_all(&connector).unwrap();
            fs::write(connector.join("status"), status).unwrap();
            fs::write(connector.join("modes"), modes).unwrap();
        }

        fn select(&self) -> io::Result<Option<DrmDevice>> {
            select_device(&self.0, None)
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn selects_amd_card_with_connected_5k_panel() {
        let tree = Tree::new();
        tree.card("card7", "0x1002\n");
        tree.connector("card7-eDP-4", "connected\n", "1920x1080\n5120x2880\n");

        let selected = tree.select().unwrap().unwrap();
        assert_eq!(selected.path, Path::new("/dev/dri/card7"));
        assert!(selected.reason.contains("0x1002"));
        assert!(selected.reason.contains("card7-eDP-4"));
        assert!(selected.reason.contains("5120x2880"));
    }

    #[test]
    fn ignores_non_amd_and_non_card_entries() {
        let tree = Tree::new();
        for (name, vendor) in [("card0", "0x8086"), ("renderD128", "0x1002")] {
            tree.card(name, vendor);
            tree.connector(&format!("{name}-eDP-1"), "connected", "5120x2880");
        }
        fs::write(tree.0.join("version"), "drm 1.1.0").unwrap();
        assert_eq!(tree.select().unwrap(), None);
    }

    #[test]
    fn ignores_disconnected_or_non_5k_amd_connectors() {
        let tree = Tree::new();
        tree.card("card2", "0x1002");
        tree.connector("card2-DP-1", "disconnected", "5120x2880");
        tree.connector("card2-eDP-1", "connected", "2560x2880\n5120x2880i\n");
        tree.connector("card2-DP-2", "unknown", "5120x2880");
        assert_eq!(tree.select().unwrap(), None);
    }

    #[test]
    fn reports_ambiguous_cards_in_deterministic_order() {
        let tree = Tree::new();
        for name in ["card8", "card2"] {
            tree.card(name, "0x1002");
            tree.connector(&format!("{name}-eDP-1"), "connected", "5120x2880");
        }
        let error = tree.select().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("/dev/dri/card2, /dev/dri/card8"));
        assert!(error.to_string().contains("refusing to choose"));
    }

    #[test]
    fn no_match_can_be_retried_after_device_appears() {
        let tree = Tree::new();
        assert_eq!(tree.select().unwrap(), None);
        assert_eq!(
            select_device(&tree.0.join("not-yet-created"), None).unwrap(),
            None
        );
        tree.card("card5", "0x1002");
        // Incomplete sysfs registration is also a retryable no-device result.
        assert_eq!(tree.select().unwrap(), None);
        tree.connector("card5-eDP-1", "connected", "5120x2880");
        assert_eq!(
            tree.select().unwrap().unwrap().path,
            Path::new("/dev/dri/card5")
        );
        fs::remove_file(tree.0.join("card5-eDP-1/modes")).unwrap();
        assert_eq!(tree.select().unwrap(), None);
    }

    #[test]
    fn connector_must_belong_to_the_amd_card() {
        let tree = Tree::new();
        tree.card("card1", "0x1002");
        tree.card("card10", "0x8086");
        tree.connector("card10-eDP-1", "connected", "5120x2880");
        assert_eq!(tree.select().unwrap(), None);
    }

    #[test]
    fn multiple_matching_connectors_on_one_card_are_not_ambiguous() {
        let tree = Tree::new();
        tree.card("card3", "0x1002");
        for connector in ["card3-eDP-1", "card3-DP-3"] {
            tree.connector(connector, "connected", "5120x2880");
        }
        assert_eq!(
            tree.select().unwrap().unwrap().path,
            Path::new("/dev/dri/card3")
        );
    }

    #[test]
    fn sysfs_read_errors_are_not_treated_as_no_device() {
        let tree = Tree::new();
        tree.card("card3", "0x1002");
        tree.connector("card3-eDP-1", "connected", "5120x2880");
        let modes = tree.0.join("card3-eDP-1/modes");
        fs::remove_file(&modes).unwrap();
        fs::create_dir(&modes).unwrap();
        assert!(tree
            .select()
            .unwrap_err()
            .to_string()
            .contains("card3-eDP-1/modes"));
    }

    #[test]
    fn explicit_override_bypasses_even_invalid_sysfs() {
        let tree = Tree::new();
        let invalid_root = tree.0.join("not-a-directory");
        fs::write(&invalid_root, "invalid sysfs").unwrap();
        assert!(select_device(&invalid_root, None).is_err());
        let selected = select_device(&invalid_root, Some(Path::new("/dev/dri/card9")))
            .unwrap()
            .unwrap();
        assert_eq!(selected.path, Path::new("/dev/dri/card9"));
        assert!(selected.reason.contains("override"));
    }

    #[cfg(unix)]
    #[test]
    fn follows_drm_class_symlinks() {
        use std::os::unix::fs::symlink;
        let devices = Tree::new();
        devices.card("card4", "0x1002");
        devices.connector("card4-eDP-1", "connected", "5120x2880");
        let class = Tree::new();
        symlink(devices.0.join("card4"), class.0.join("card4")).unwrap();
        symlink(devices.0.join("card4-eDP-1"), class.0.join("card4-eDP-1")).unwrap();
        assert_eq!(
            class.select().unwrap().unwrap().path,
            Path::new("/dev/dri/card4")
        );
    }
}
