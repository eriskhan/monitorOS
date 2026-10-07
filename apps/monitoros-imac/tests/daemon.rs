//! Real daemon/child processes, but no DRM access or module writes.
//! Host-network tests use a deliberately nonexistent interface; the one real
//! link-configuration test runs inside an isolated network namespace.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

struct Daemon {
    child: Child,
    root: PathBuf,
}

impl Daemon {
    fn new() -> Self {
        Self::with_interface("m0-no-such-link", true)
    }

    fn with_interface(interface: &str, stub_ip: bool) -> Self {
        Self::with_discovery(interface, stub_ip, false)
    }

    fn with_discovery(interface: &str, stub_ip: bool, discover: bool) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let instance = NEXT.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "monitoros-daemon-test-{}-{}",
            std::process::id(),
            instance
        ));
        fs::create_dir(&root).unwrap();
        let control_port = 30_000 + (instance % 20_000) as u16;
        let control_bind = format!("127.0.0.1:{control_port}");
        for name in if stub_ip {
            &["ip", "modprobe"][..]
        } else {
            &["modprobe"][..]
        } {
            executable(&root.join(name), "#!/bin/sh\nexit 0\n");
        }
        executable(&root.join("worker"), "#!/bin/sh\ntrap 'printf \"stopped %s\\n\" \"$$\" >> \"$M0_TEST_EVENTS\"; exit 0' TERM INT\nprintf 'started %s\\n' \"$$\" >> \"$M0_TEST_EVENTS\"\nwhile :; do sleep 0.02; done\n");
        let log = fs::File::create(root.join("daemon.log")).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_monitorosd"));
        command.arg("--drm-sysfs-root").arg(root.join("drm"));
        if !discover {
            command.args(["--device", "/dev/dri/test-override"]);
        }
        let child = command
            .args([
                "--interface",
                interface,
                "--control-bind",
                control_bind.as_str(),
                "--video-worker",
            ])
            .arg(root.join("worker"))
            .env("PATH", format!("{}:/usr/bin:/bin", root.display()))
            .env("M0_TEST_EVENTS", root.join("events"))
            .process_group(0)
            .stdout(Stdio::from(log.try_clone().unwrap()))
            .stderr(Stdio::from(log))
            .spawn()
            .unwrap();
        Self { child, root }
    }

    fn started(&self) -> Vec<i32> {
        self.events()
            .lines()
            .filter_map(|line| {
                line.strip_prefix("started ")
                    .and_then(|pid| pid.parse().ok())
            })
            .collect()
    }

    fn events(&self) -> String {
        fs::read_to_string(self.root.join("events")).unwrap_or_default()
    }

    fn until(&mut self, condition: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(8);
        while !condition(self) {
            assert!(
                Instant::now() < deadline,
                "daemon timed out: {}",
                fs::read_to_string(self.root.join("daemon.log")).unwrap()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }
}

#[test]
fn real_link_events_recycle_sessions_in_an_isolated_network_namespace() {
    const INSIDE: &str = "MONITOROS_TEST_NETNS";
    if std::env::var_os(INSIDE).is_none() {
        let supported = Command::new("unshare")
            .args(["--user", "--map-root-user", "--net", "true"])
            .output();
        let ip_available = Command::new("ip")
            .arg("-Version")
            .output()
            .is_ok_and(|output| output.status.success());
        if !supported.is_ok_and(|output| output.status.success()) || !ip_available {
            eprintln!("skipping kernel link-event integration: unprivileged network namespaces or iproute2 unavailable");
            return;
        }
        let status = Command::new("unshare")
            .args(["--user", "--map-root-user", "--net"])
            .arg(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "real_link_events_recycle_sessions_in_an_isolated_network_namespace",
                "--nocapture",
            ])
            .env(INSIDE, "1")
            .status()
            .unwrap();
        assert!(status.success());
        return;
    }

    fn ip(args: &[&str]) -> String {
        let output = Command::new("ip").args(args).output().unwrap();
        assert!(
            output.status.success(),
            "ip {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }
    fn ready_without_static_ipv4() -> bool {
        let link = ip(&["-o", "link", "show", "dev", "m0tb"]);
        let ipv4 = ip(&["-4", "-o", "address", "show", "dev", "m0tb"]);
        link.split_once('<')
            .and_then(|(_, rest)| rest.split_once('>'))
            .is_some_and(|(flags, _)| flags.split(',').any(|flag| flag == "UP"))
            && ipv4.trim().is_empty()
    }

    let mut daemon = Daemon::with_interface("m0tb", false);
    daemon.until(|daemon| daemon.started().len() == 1);
    ip(&["link", "add", "m0tb", "type", "dummy"]);
    daemon.until(|_| ready_without_static_ipv4());
    let first = daemon.started()[0];

    // Deletion must retire a live worker even though its fake accepted session
    // never notices network loss on its own.
    ip(&["link", "delete", "m0tb"]);
    daemon.until(|daemon| daemon.started().len() >= 2);
    assert!(!Path::new(&format!("/proc/{first}")).exists());
    assert!(daemon.events().contains(&format!("stopped {first}")));

    ip(&["link", "add", "m0tb", "type", "dummy"]);
    daemon.until(|_| ready_without_static_ipv4());
    // A link can also lose carrier without its netdev disappearing.
    daemon.until(|daemon| {
        fs::read_to_string(daemon.root.join("daemon.log"))
            .unwrap()
            .matches("up with carrier")
            .count()
            >= 2
    });
    let before = daemon.started();
    let previous = *before.last().unwrap();
    ip(&["link", "set", "m0tb", "carrier", "off"]);
    daemon.until(|daemon| daemon.started().len() > before.len());
    assert!(!Path::new(&format!("/proc/{previous}")).exists());
    ip(&["link", "set", "m0tb", "carrier", "on"]);

    // Rapid administrative down/up must not overlap old and new workers.
    let before = daemon.started().len();
    ip(&["link", "set", "m0tb", "down"]);
    ip(&["link", "set", "m0tb", "up"]);
    daemon.until(|daemon| daemon.started().len() > before);
    daemon.until(|_| ready_without_static_ipv4());
    let mut active = None;
    for line in daemon.events().lines() {
        let (kind, pid) = line.split_once(' ').unwrap();
        if kind == "started" {
            assert!(
                active.is_none(),
                "multiple active workers: {}",
                daemon.events()
            );
            active = Some(pid.to_string());
        } else {
            assert_eq!(active.take().as_deref(), Some(pid));
        }
    }
    assert!(active.is_some());
    assert_eq!(
        unsafe { libc::kill(daemon.child.id() as i32, libc::SIGTERM) },
        0
    );
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if let Some(status) = daemon.child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(20));
    }
    assert!(!fs::read_to_string(daemon.root.join("daemon.log"))
        .unwrap()
        .contains("SIGKILL"));
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // Test-only last-resort cleanup of this isolated process group, including
        // fake workers if a regression causes the daemon to abandon them.
        unsafe {
            libc::kill(-(self.child.id() as i32), libc::SIGKILL);
        }
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn executable(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn daemon_restarts_exited_worker_then_reaps_child_on_term_and_int() {
    for (worker_signal, signal) in [
        (libc::SIGTERM, libc::SIGTERM),
        (libc::SIGKILL, libc::SIGINT),
    ] {
        let mut daemon = Daemon::new();
        daemon.until(|daemon| daemon.started().len() == 1);
        let first = daemon.started()[0];
        // Only a fake worker owned by this test receives the signal.
        assert_eq!(unsafe { libc::kill(first, worker_signal) }, 0);
        daemon.until(|daemon| daemon.started().len() == 2);
        let second = daemon.started()[1];
        assert_ne!(first, second);
        assert!(
            !Path::new(&format!("/proc/{first}")).exists(),
            "old worker must be reaped before replacement"
        );
        assert_eq!(unsafe { libc::kill(daemon.child.id() as i32, signal) }, 0);
        let deadline = Instant::now() + Duration::from_secs(8);
        let status = loop {
            if let Some(status) = daemon.child.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline, "daemon did not exit");
            thread::sleep(Duration::from_millis(20));
        };
        assert!(
            status.success(),
            "daemon must handle shutdown, not die from the signal: {status}"
        );
        assert!(daemon.events().contains(&format!("stopped {second}")));
        assert!(
            !Path::new(&format!("/proc/{second}")).exists(),
            "shutdown left a worker behind"
        );
        assert_eq!(
            daemon.started().len(),
            2,
            "shutdown must not spawn a replacement"
        );
        let log = fs::read_to_string(daemon.root.join("daemon.log")).unwrap();
        assert!(log.contains("absent/deleted"));
        assert!(log.contains("reaped video worker"));
        assert!(!log.contains("sending SIGKILL"));
    }
}

#[test]
fn delayed_drm_and_absent_source_keep_the_same_daemon_alive() {
    let mut daemon = Daemon::with_discovery("m0-no-such-link", true, true);
    daemon.until(|daemon| {
        fs::read_to_string(daemon.root.join("daemon.log"))
            .unwrap()
            .contains("waiting for DRM device")
    });
    // Cross multiple retry deadlines before exposing the panel.
    thread::sleep(Duration::from_millis(2200));
    assert!(daemon.child.try_wait().unwrap().is_none());
    assert!(daemon.started().is_empty());
    let drm = daemon.root.join("drm");
    fs::create_dir_all(drm.join("card7/device")).unwrap();
    fs::write(drm.join("card7/device/vendor"), "0x1002\n").unwrap();
    fs::create_dir(drm.join("card7-eDP-1")).unwrap();
    fs::write(drm.join("card7-eDP-1/status"), "connected\n").unwrap();
    fs::write(drm.join("card7-eDP-1/modes"), "5120x2880\n").unwrap();
    daemon.until(|daemon| daemon.started().len() == 1);
    let log = fs::read_to_string(daemon.root.join("daemon.log")).unwrap();
    assert!(log.contains("selected DRM device /dev/dri/card7"));
    assert!(log.contains("healthy idle state"));
    assert!(daemon.child.try_wait().unwrap().is_none());
    assert_eq!(
        unsafe { libc::kill(daemon.child.id() as i32, libc::SIGTERM) },
        0
    );
    daemon.until(|daemon| daemon.events().contains("stopped "));
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if let Some(status) = daemon.child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(20));
    }
    assert!(!Path::new(&format!("/proc/{}", daemon.started()[0])).exists());
}
