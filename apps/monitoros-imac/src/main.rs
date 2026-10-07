mod control;
mod discovery;
mod drm;
mod lifecycle;
mod link;
mod process;

use lifecycle::{Lifecycle, WorkerAction};
use std::io;
use std::os::fd::RawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ExitCode, Stdio};
use std::time::{Duration, Instant};

const DEFAULT_INTERFACE: &str = "thunderbolt0";
const DEFAULT_BIND: &str = "[::]:5202";
const DRM_SYSFS_ROOT: &str = "/sys/class/drm";
const DEFAULT_VIDEO_WORKER: &str = "/usr/lib/monitoros/imac5k-stream";
const RETRY_DELAY: Duration = Duration::from_secs(1);
const STOP_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, Eq, PartialEq)]
struct Options {
    interface: String,
    bind: String,
    control_bind: String,
    backlight_root: PathBuf,
    device: Option<PathBuf>,
    drm_sysfs_root: PathBuf,
    video_worker: PathBuf,
    self_test: bool,
    show_help: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            interface: DEFAULT_INTERFACE.to_string(),
            bind: DEFAULT_BIND.to_string(),
            control_bind: control::DEFAULT_CONTROL_BIND.to_string(),
            backlight_root: PathBuf::from(control::DEFAULT_BACKLIGHT_ROOT),
            device: None,
            drm_sysfs_root: PathBuf::from(DRM_SYSFS_ROOT),
            video_worker: PathBuf::from(DEFAULT_VIDEO_WORKER),
            self_test: false,
            show_help: false,
        }
    }
}

impl Options {
    fn parse_from(args: &[String]) -> Result<Self, String> {
        let mut options = Self::default();
        let mut index = 0;

        while index < args.len() {
            match args[index].as_str() {
                "--interface" => {
                    index += 1;
                    options.interface = value(args, index, "--interface")?.to_string();
                }
                "--bind" => {
                    index += 1;
                    options.bind = value(args, index, "--bind")?.to_string();
                }
                "--control-bind" => {
                    index += 1;
                    options.control_bind = value(args, index, "--control-bind")?.to_string();
                }
                "--backlight-root" => {
                    index += 1;
                    options.backlight_root = PathBuf::from(value(args, index, "--backlight-root")?);
                }
                "--device" => {
                    index += 1;
                    options.device = Some(PathBuf::from(value(args, index, "--device")?));
                }
                "--video-worker" => {
                    index += 1;
                    options.video_worker = PathBuf::from(value(args, index, "--video-worker")?);
                }
                "--drm-sysfs-root" => {
                    index += 1;
                    options.drm_sysfs_root = PathBuf::from(value(args, index, "--drm-sysfs-root")?);
                }
                "--self-test" => options.self_test = true,
                "-h" | "--help" => options.show_help = true,
                argument => return Err(format!("unknown argument: {argument}")),
            }
            index += 1;
        }

        if options.interface.is_empty()
            || options.interface.contains('/')
            || options.interface.len() >= libc::IFNAMSIZ
        {
            return Err("--interface must be a Linux interface name".to_string());
        }
        bind_port(&options.bind)?;
        bind_port(&options.control_bind)?;
        if options.backlight_root.as_os_str().is_empty() {
            return Err("--backlight-root must not be empty".to_string());
        }
        if options
            .device
            .as_ref()
            .is_some_and(|path| path.as_os_str().is_empty())
        {
            return Err("--device must not be empty".to_string());
        }
        if options.video_worker.as_os_str().is_empty() {
            return Err("--video-worker must not be empty".to_string());
        }
        if options.drm_sysfs_root.as_os_str().is_empty() {
            return Err("--drm-sysfs-root must not be empty".to_string());
        }

        Ok(options)
    }
}

fn value<'a>(args: &'a [String], index: usize, flag: &str) -> Result<&'a str, String> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn bind_port(target: &str) -> Result<u16, String> {
    let rest = target
        .strip_prefix('[')
        .ok_or_else(|| "listener requires [IPv6%scope]:PORT".to_string())?;
    let closing = rest
        .find(']')
        .ok_or_else(|| "listener requires [IPv6%scope]:PORT".to_string())?;
    let host = &rest[..closing];
    if host.is_empty() || !host.contains(':') {
        return Err("listener requires [IPv6%scope]:PORT".to_string());
    }
    let port_text = rest[closing + 1..]
        .strip_prefix(':')
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "listener requires [IPv6%scope]:PORT".to_string())?;

    port_text
        .parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .ok_or_else(|| "listener port must be in 1...65535".to_string())
}


fn run_command(program: &str, args: &[&str]) -> io::Result<()> {
    let output = process::command(program).args(args).output()?;
    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(io::Error::other(format!(
        "{program} {} failed with {}: {}",
        args.join(" "),
        output.status,
        stderr.trim()
    )))
}

fn configure_link(options: &Options) -> io::Result<()> {
    run_command("ip", &["link", "set", "dev", &options.interface, "up"])
}

fn try_load_thunderbolt_net() {
    match run_command("modprobe", &["thunderbolt_net"]) {
        Ok(()) => println!("thunderbolt_net ready"),
        Err(error) => eprintln!(
            "warning: could not modprobe thunderbolt_net: {error}; continuing in case it is built in or already managed"
        ),
    }
}

fn spawn_video_worker(
    options: &Options,
    device: &Path,
    brightness_fd: RawFd,
) -> io::Result<Child> {
    let mut command = process::command(&options.video_worker);
    command
        .arg("--device")
        .arg(device)
        .arg("--bind")
        .arg(&options.bind)
        .arg("--brightness-fd")
        .arg(brightness_fd.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    // The brightness pipe is CLOEXEC in monitorosd. Clear that flag only in
    // the forked child just before exec, so the video worker can consume
    // logical brightness updates while monitorosd keeps ownership.
    unsafe {
        command.pre_exec(move || {
            let flags = libc::fcntl(brightness_fd, libc::F_GETFD);
            if flags < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::fcntl(
                brightness_fd,
                libc::F_SETFD,
                flags & !libc::FD_CLOEXEC,
            ) < 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }

    command.spawn()
}

fn run_daemon(options: Options) -> io::Result<()> {
    println!(
        "monitorosd: interface={} bind={} control_bind={} backlight={} device={} worker={}",
        options.interface,
        options.bind,
        options.control_bind,
        options.backlight_root.display(),
        options
            .device
            .as_ref()
            .map_or_else(|| "auto".to_string(), |path| path.display().to_string()),
        options.video_worker.display()
    );

    let signals = process::Signals::new()?;
    let mut links = link::LinkMonitor::new(&options.interface)?;
    try_load_thunderbolt_net();

    let control_server = control::ControlServer::start(
        &options.control_bind,
        &options.backlight_root,
    )?;

    let service_port = bind_port(&options.bind).map_err(io::Error::other)?;
    let _advertiser = match discovery::Advertiser::start(&options.interface, service_port) {
        Ok(advertiser) => Some(advertiser),
        Err(error) => {
            eprintln!(
                "warning: monitorOS Bonjour advertisement unavailable: {error}"
            );
            None
        }
    };
    println!(
        "monitorosd: subscribed to rtnetlink link notifications for {}",
        options.interface
    );
    let mut worker: Option<Child> = None;
    let result = supervise(
        &options,
        &signals,
        &mut links,
        &mut worker,
        &control_server,
    );
    // Notification failures (including lost netlink events) must also close
    // any old accepted connection. This applies outside systemd as well.
    if let Err(error) = &result {
        eprintln!("monitorosd: supervisor failed: {error}; cleaning up video worker");
    }
    stop_worker(&mut worker)?;
    result
}

fn stop_worker(worker: &mut Option<Child>) -> io::Result<()> {
    if let Some(child) = worker.as_mut() {
        let status = process::stop_and_reap(child, STOP_TIMEOUT)?;
        println!(
            "monitorosd: reaped video worker pid={} status={status}",
            child.id()
        );
    }
    *worker = None;
    Ok(())
}

fn supervise(
    options: &Options,
    signals: &process::Signals,
    links: &mut link::LinkMonitor,
    worker: &mut Option<Child>,
    control_server: &control::ControlServer,
) -> io::Result<()> {
    let mut state = Lifecycle::default();
    let mut next_link_attempt = Instant::now();
    let mut next_worker_attempt = Instant::now();
    let initial_deadline = Instant::now() + Duration::from_secs(5);
    let mut device_diagnostic = String::new();
    let mut worker_starts = 0_u64;

    loop {
        if signals.drain()? {
            println!("monitorosd: shutdown requested");
            state.shutdown();
        }
        let initialized = links.initialized;
        // Apply EVERY event in order: down/up in one batch must still recycle
        // the old session. Do not collapse the batch to its final link state.
        for link in links.drain()? {
            if state.observe_link(link) || !initialized {
                match link {
                    Some(link) => println!(
                        "monitorosd: interface {} index={} {}",
                        options.interface,
                        link.index,
                        if link.up {
                            "up with carrier"
                        } else {
                            "down (administrative or carrier)"
                        }
                    ),
                    None => println!("monitorosd: interface {} absent/deleted; waiting for source (healthy idle state)", options.interface),
                }
                next_link_attempt = Instant::now();
            }
        }
        let now = Instant::now();

        let worker_exited = match worker.as_mut() {
            Some(child) => match child.try_wait()? {
                Some(status) => {
                    eprintln!(
                        "monitorosd: video worker pid={} exited with {status}",
                        child.id()
                    );
                    true
                }
                None => false,
            },
            None => false,
        };

        if worker_exited {
            *worker = None;
            state.worker_reaped();
            next_worker_attempt = now + RETRY_DELAY;
            if state.worker_action() == Some(WorkerAction::Start) {
                println!(
                    "monitorosd: scheduling worker restart in {}s",
                    RETRY_DELAY.as_secs()
                );
            }
        }

        if state.worker_action() == Some(WorkerAction::Stop) {
            stop_worker(worker)?;
            state.worker_reaped();
            next_worker_attempt = Instant::now();
            // Drain signals and link events queued during graceful cleanup
            // before deciding whether a replacement may start.
            continue;
        }
        if state.finished() {
            return Ok(());
        }
        if !links.initialized && now >= initial_deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "initial rtnetlink query timed out",
            ));
        }

        if links.initialized && state.needs_configuration() && now >= next_link_attempt {
            println!(
                "monitorosd: bringing {} up for automatic IPv6 link-local",
                options.interface
            );
            match configure_link(options) {
                Ok(()) => {
                    state.configured();
                    println!(
                        "monitorosd: {} ready for automatic IPv6 link-local",
                        options.interface
                    );
                }
                Err(error) => {
                    eprintln!("monitorosd: link configuration failed: {error}; retrying");
                    next_link_attempt = now + RETRY_DELAY;
                }
            }
        }

        if links.initialized
            && state.worker_action() == Some(WorkerAction::Start)
            && now >= next_worker_attempt
        {
            next_worker_attempt = now + RETRY_DELAY;
            let selection = drm::select_device(&options.drm_sysfs_root, options.device.as_deref());
            let diagnostic = match &selection {
                Ok(Some(device)) => format!("selected DRM device {}: {}", device.path.display(), device.reason),
                Ok(None) => format!("waiting for DRM device: no AMD card with a connected 5120x2880 connector in {}; retrying every {}s", options.drm_sysfs_root.display(), RETRY_DELAY.as_secs()),
                Err(error) => format!("DRM discovery failed: {error}; video worker not started; retrying every {}s", RETRY_DELAY.as_secs()),
            };
            if diagnostic != device_diagnostic {
                if selection.is_err() {
                    eprintln!("monitorosd: {diagnostic}");
                } else {
                    println!("monitorosd: {diagnostic}");
                }
                device_diagnostic = diagnostic;
            }
            if let Ok(Some(device)) = selection {
                if let Err(error) = control_server.prepare_worker() {
                    eprintln!(
                        "monitorosd: failed to seed video-worker brightness: {error}"
                    );
                    next_worker_attempt = now + RETRY_DELAY;
                    continue;
                }

                match spawn_video_worker(
                    options,
                    &device.path,
                    control_server.output_fd(),
                ) {
                    Ok(child) => {
                        worker_starts = worker_starts.saturating_add(1);
                        println!(
                            "monitorosd: video worker started pid={} device={} restarts={}",
                            child.id(),
                            device.path.display(),
                            worker_starts - 1
                        );
                        *worker = Some(child);
                        state.worker_started();
                    }
                    Err(error) => {
                        eprintln!(
                            "monitorosd: failed to start video worker {}: {error}; retrying",
                            options.video_worker.display()
                        );
                        next_worker_attempt = now + RETRY_DELAY;
                    }
                }
            }
        }

        let deadline = if !links.initialized {
            Some(initial_deadline)
        } else {
            [
                state.needs_configuration().then_some(next_link_attempt),
                (state.worker_action() == Some(WorkerAction::Start)).then_some(next_worker_attempt),
            ]
            .into_iter()
            .flatten()
            .min()
        };
        // Stable streaming sleeps indefinitely until a link event, child exit,
        // or TERM/INT. Timers only retry failed startup/configuration work.
        process::wait(links.fd(), signals.fd(), deadline)?;
    }
}

fn self_test() -> Result<(), String> {
    let mut state = Lifecycle::default();
    let up = Some(lifecycle::Link { index: 7, up: true });
    state.observe_link(up);
    state.configured();
    state.worker_started();
    state.observe_link(None);
    state.observe_link(up);
    if state.worker_action() != Some(WorkerAction::Stop) {
        return Err("replug must retire the stale worker before starting another".to_string());
    }
    state.worker_reaped();
    if state.worker_action() != Some(WorkerAction::Start) || !state.needs_configuration() {
        return Err("replug must restore configuration and start a clean worker".to_string());
    }
    state.shutdown();
    if !state.finished() {
        return Err("shutdown must suppress restarts".to_string());
    }

    let args = vec![
        "--interface".to_string(),
        "tb-test0".to_string(),
        "--bind".to_string(),
        "[::]:5202".to_string(),
        "--control-bind".to_string(),
        "[::]:6203".to_string(),
        "--backlight-root".to_string(),
        "/tmp/backlight".to_string(),
        "--device".to_string(),
        "/dev/dri/card9".to_string(),
        "--video-worker".to_string(),
        "/tmp/imac5k-stream".to_string(),
    ];
    let options = Options::parse_from(&args)?;
    if options.interface != "tb-test0"
        || options.control_bind != "[::]:6203"
        || options.backlight_root.as_path() != Path::new("/tmp/backlight")
        || options.device.as_deref() != Some(Path::new("/dev/dri/card9"))
        || options.video_worker.as_path() != Path::new("/tmp/imac5k-stream")
    {
        return Err("option parsing produced unexpected values".to_string());
    }

    if Options::default().device.is_some() {
        return Err("default device selection must be automatic".to_string());
    }
    let selected = drm::select_device(Path::new("/unused-sysfs-root"), options.device.as_deref())
        .map_err(|error| error.to_string())?;
    if selected.map(|device| device.path) != options.device {
        return Err("explicit device override must bypass discovery".to_string());
    }

    println!("monitorosd self-test passed");
    Ok(())
}

fn usage() {
    println!(
        "monitorosd\n\n  --interface NAME      Thunderbolt network interface (default: {DEFAULT_INTERFACE})\n  --bind TARGET         video listener ([IPv6%scope]:PORT; default: {DEFAULT_BIND})\n  --control-bind TARGET control listener for brightness/volume (default: {})\n  --backlight-root PATH Linux backlight directory (default: {})\n  --device PATH         explicit DRM override (default: discover AMD connected 5K panel)\n  --video-worker PATH   imac5k-stream executable (default: {DEFAULT_VIDEO_WORKER})\n  --self-test           validate lifecycle state without hardware\n",
        control::DEFAULT_CONTROL_BIND,
        control::DEFAULT_BACKLIGHT_ROOT
    );
    println!("  --drm-sysfs-root PATH discovery fixture/debug root (default: {DRM_SYSFS_ROOT})");
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let options = match Options::parse_from(&args) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("monitorosd: {error}");
            usage();
            return ExitCode::from(64);
        }
    };

    if options.show_help {
        usage();
        return ExitCode::SUCCESS;
    }

    if options.self_test {
        return match self_test() {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("monitorosd self-test failed: {error}");
                ExitCode::FAILURE
            }
        };
    }

    match run_daemon(options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("monitorosd failed: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_reject_interface_paths() {
        let args = vec!["--interface".to_string(), "../thunderbolt0".to_string()];

        assert!(Options::parse_from(&args).is_err());
    }

    #[test]
    fn default_networking_uses_ipv6_listener() {
        let options = Options::parse_from(&[]).unwrap();
        assert_eq!(options.bind, "[::]:5202");
        assert_eq!(options.control_bind, "[::]:5203");
    }

    #[test]
    fn options_accept_runtime_overrides() {
        let args = vec![
            "--interface".to_string(),
            "thunderbolt7".to_string(),
            "--bind".to_string(),
            "[::1]:6000".to_string(),
            "--control-bind".to_string(),
            "[::1]:6003".to_string(),
            "--device".to_string(),
            "/dev/dri/card8".to_string(),
            "--video-worker".to_string(),
            "/opt/monitoros/imac5k-stream".to_string(),
        ];

        let options = Options::parse_from(&args).unwrap();
        assert_eq!(options.interface, "thunderbolt7");
        assert_eq!(options.bind, "[::1]:6000");
        assert_eq!(options.control_bind, "[::1]:6003");
        assert_eq!(options.device.as_deref(), Some(Path::new("/dev/dri/card8")));
        assert_eq!(
            options.video_worker.as_path(),
            Path::new("/opt/monitoros/imac5k-stream")
        );
    }

    #[test]
    fn bind_port_accepts_bracketed_ipv6() {
        assert_eq!(bind_port("[::]:5202").unwrap(), 5202);
        assert_eq!(bind_port("[fe80::1%thunderbolt0]:6000").unwrap(), 6000);

        assert!(bind_port("192.0.2.1:5202").is_err());
        assert!(bind_port("fe80::1:5202").is_err());
        assert!(bind_port("[fe80::1]5202").is_err());
        assert!(bind_port("[::]:0").is_err());
    }

    #[test]
    fn default_device_is_automatic_and_override_reaches_selector() {
        assert!(Options::parse_from(&[]).unwrap().device.is_none());
        let options = Options::parse_from(&["--device".into(), "/dev/dri/card8".into()]).unwrap();
        let selected = drm::select_device(Path::new("/dev/null"), options.device.as_deref())
            .unwrap()
            .unwrap();
        assert_eq!(selected.path, Path::new("/dev/dri/card8"));
        assert!(Options::parse_from(&["--device".into(), String::new()]).is_err());
        assert!(Options::parse_from(&["--drm-sysfs-root".into(), String::new()]).is_err());
    }
}
