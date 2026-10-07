//! Linux process notifications and bounded, graceful child cleanup.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus};
use std::thread;
use std::time::{Duration, Instant};

pub struct Signals {
    fd: OwnedFd,
    previous_mask: libc::sigset_t,
}

impl Signals {
    /// The daemon is single-threaded. Block these signals before spawning any
    /// children, then consume them in poll/signalfd instead of async handlers.
    pub fn new() -> io::Result<Self> {
        // SAFETY: initialized sigset_t buffers, used only by this thread.
        unsafe {
            let mut mask = std::mem::zeroed();
            let mut previous_mask = std::mem::zeroed();
            libc::sigemptyset(&mut mask);
            for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGCHLD] {
                libc::sigaddset(&mut mask, signal);
            }
            if libc::sigprocmask(libc::SIG_BLOCK, &mask, &mut previous_mask) < 0 {
                return Err(io::Error::last_os_error());
            }
            let fd = libc::signalfd(-1, &mask, libc::SFD_CLOEXEC | libc::SFD_NONBLOCK);
            if fd < 0 {
                let error = io::Error::last_os_error();
                libc::sigprocmask(libc::SIG_SETMASK, &previous_mask, std::ptr::null_mut());
                return Err(error);
            }
            Ok(Self {
                fd: OwnedFd::from_raw_fd(fd),
                previous_mask,
            })
        }
    }

    pub fn fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    pub fn drain(&self) -> io::Result<bool> {
        let mut shutdown = false;
        loop {
            // SAFETY: read writes at most one record to a properly sized buffer.
            let mut info: libc::signalfd_siginfo = unsafe { std::mem::zeroed() };
            let size = std::mem::size_of_val(&info);
            let count = unsafe {
                libc::read(
                    self.fd(),
                    (&mut info as *mut libc::signalfd_siginfo).cast(),
                    size,
                )
            };
            if count < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::WouldBlock {
                    return Ok(shutdown);
                }
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if count as usize != size {
                return Err(io::Error::other("short signalfd record"));
            }
            shutdown |= matches!(info.ssi_signo as i32, libc::SIGTERM | libc::SIGINT);
        }
    }
}

impl Drop for Signals {
    fn drop(&mut self) {
        // SAFETY: restore this thread's saved mask after child cleanup.
        unsafe {
            libc::sigprocmask(libc::SIG_SETMASK, &self.previous_mask, std::ptr::null_mut());
        }
    }
}

pub fn command(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut command = Command::new(program);
    // SAFETY: only async-signal-safe libc functions run between fork and exec.
    // Children must not inherit the supervisor's blocked TERM/INT/CHLD mask.
    unsafe {
        command.pre_exec(|| {
            let mut mask = std::mem::zeroed();
            libc::sigemptyset(&mut mask);
            if libc::sigprocmask(libc::SIG_SETMASK, &mask, std::ptr::null_mut()) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command
}

pub fn stop_and_reap(child: &mut Child, timeout: Duration) -> io::Result<ExitStatus> {
    if let Some(status) = child.try_wait()? {
        return Ok(status);
    }
    println!(
        "monitorosd: SIGTERM video worker pid={}; allowing {}ms for cleanup",
        child.id(),
        timeout.as_millis()
    );
    // SAFETY: this is our owned, unreaped child; no other thread can reap it
    // and allow PID reuse between try_wait and kill.
    if unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) } < 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            return Err(error);
        }
    }
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            eprintln!("monitorosd: video worker pid={} exceeded graceful shutdown timeout; sending SIGKILL", child.id());
            child.kill()?;
            return child.wait();
        }
        // Only child teardown uses a short wait; link state is never polled.
        thread::sleep(Duration::from_millis(20));
    }
}

pub fn wait(link_fd: RawFd, signal_fd: RawFd, deadline: Option<Instant>) -> io::Result<()> {
    let mut descriptors = [
        libc::pollfd {
            fd: link_fd,
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: signal_fd,
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    let timeout = deadline.map_or(-1, |at| {
        at.saturating_duration_since(Instant::now())
            .as_millis()
            .saturating_add(1)
            .min(i32::MAX as u128) as i32
    });
    // SAFETY: poll receives the full mutable array and its exact length.
    let result = unsafe {
        libc::poll(
            descriptors.as_mut_ptr(),
            descriptors.len() as libc::nfds_t,
            timeout,
        )
    };
    if result < 0 {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    if descriptors
        .iter()
        .any(|fd| fd.revents & (libc::POLLHUP | libc::POLLNVAL) != 0)
    {
        return Err(io::Error::other(
            "link/signal notification descriptor closed",
        ));
    }
    // POLLERR is consumed by recv/read next iteration (e.g. netlink ENOBUFS).
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::process::ExitStatusExt;
    use std::process::Stdio;

    struct TestChild(Child);

    impl Drop for TestChild {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn ready_child(script: &str) -> TestChild {
        let mut child = command("/bin/sh")
            .args(["-c", script])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut ready = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut ready)
            .unwrap();
        assert_eq!(ready.trim(), "ready");
        TestChild(child)
    }

    #[test]
    fn child_unblocks_signals_and_is_reaped_after_graceful_cleanup() {
        let _signals = Signals::new().unwrap();
        let mut child =
            ready_child("trap 'exit 23' TERM; echo ready; while :; do sleep 0.02; done");
        let status = stop_and_reap(&mut child.0, Duration::from_secs(2)).unwrap();
        assert_eq!(
            status.code(),
            Some(23),
            "TERM handler must run, not SIGKILL"
        );
        assert_eq!(child.0.try_wait().unwrap(), Some(status));
    }

    #[test]
    fn unresponsive_child_is_killed_only_after_the_grace_period() {
        let mut child = ready_child("trap '' TERM; echo ready; while :; do sleep 0.02; done");
        let timeout = Duration::from_millis(100);
        let start = Instant::now();
        let status = stop_and_reap(&mut child.0, timeout).unwrap();
        assert!(start.elapsed() >= timeout);
        assert_eq!(status.signal(), Some(libc::SIGKILL));
        assert_eq!(child.0.try_wait().unwrap(), Some(status));
    }
}
