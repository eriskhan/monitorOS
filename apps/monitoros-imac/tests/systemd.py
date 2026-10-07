#!/usr/bin/env python3
"""Exercise shipped service policy under a real, isolated user-manager unit.

No root, DRM access, production unit changes, module loads, or network writes.
Python and a running user systemd manager are test dependencies only.
"""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def ctl(*args, check=True):
    return subprocess.run(
        ["systemctl", "--user", *args],
        check=check, capture_output=True, text=True, timeout=25,
    )


def run(daemon):
    name = f"monitoros-test-{uuid.uuid4().hex}.service"
    with tempfile.TemporaryDirectory(prefix="monitoros-systemd-") as directory:
        root = Path(directory)
        events = root / "events"
        log = root / "daemon.log"
        for binary in ("ip", "modprobe"):
            stub = root / binary
            stub.write_text("#!/bin/sh\nexit 0\n")
            stub.chmod(0o755)
        worker = root / "worker"
        worker.write_text(f"""#!{sys.executable}
import os, signal, time
from pathlib import Path
root = Path({directory!r})
def record(kind):
    with (root / 'events').open('a') as stream:
        stream.write(f'{{kind}} {{os.getpid()}}\\n')
def stop(sig, frame):
    if (root / 'ignore-term').exists():
        record('ignored')
        return
    record('stopped')
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
record('started')
while True:
    time.sleep(0.05)
""")
        worker.chmod(0o755)

        # Keep production lifecycle directives verbatim. Only adapt credentials,
        # paths and output for an unprivileged, hardware-free fixture.
        original = (Path(__file__).resolve().parent.parent / "systemd/monitorosd.service").read_text()
        replacements = {
            "User": None, "Group": None,
            "ExecStart": f'{daemon} --interface m0-no-such-link --drm-sysfs-root {root}/drm --video-worker {worker}',
            "Environment": f'PATH={root}:/usr/bin:/bin',
            "StandardOutput": f'append:{log}',
            "StandardError": f'append:{log}',
        }
        lines = []
        for line in original.splitlines():
            key = line.split("=", 1)[0]
            if key in replacements:
                if replacements[key] is not None:
                    lines.append(f"{key}={replacements[key]}")
            else:
                lines.append(line)
        unit = root / name
        unit.write_text("\n".join(lines) + "\n")

        def prop(key):
            return ctl("show", name, f"--property={key}", "--value").stdout.strip()

        def records(kind):
            if not events.exists():
                return []
            return [int(line.split()[1]) for line in events.read_text().splitlines()
                    if line.startswith(kind + " ")]

        def alive(pid):
            return Path(f"/proc/{pid}").exists()

        def until(predicate, message, timeout=16):
            deadline = time.monotonic() + timeout
            while not predicate():
                if time.monotonic() >= deadline:
                    raise AssertionError(message)
                time.sleep(0.05)

        def cgroup_empty(group):
            assert group.startswith("/") and group != "/", "missing fixture cgroup"
            path = Path("/sys/fs/cgroup" + group)
            return all(not file.read_text().strip() for file in path.rglob("cgroup.procs"))

        def main_pid():
            return int(prop("MainPID"))

        def worker_started_after(count):
            until(lambda: len(records("started")) == count + 1, "worker did not restart exactly once")
            return records("started")[-1]

        try:
            ctl("link", "--runtime", str(unit))
            ctl("daemon-reload")
            ctl("start", name)
            initial = main_pid()
            assert initial > 1
            until(lambda: log.exists() and "waiting for DRM device" in log.read_text(), "no DRM wait log")
            time.sleep(2.2)
            assert main_pid() == initial and prop("ActiveState") == "active"
            assert prop("NRestarts") == "0" and not records("started")
            assert "healthy idle state" in log.read_text()
            drm = root / "drm"
            (drm / "card7/device").mkdir(parents=True)
            (drm / "card7/device/vendor").write_text("0x1002\n")
            panel = drm / "card7-eDP-1"
            panel.mkdir()
            (panel / "status").write_text("connected\n")
            (panel / "modes").write_text("5120x2880\n")
            first = worker_started_after(0)
            assert main_pid() == initial
            print("PASS: no source/delayed DRM remains active; panel readiness starts worker", flush=True)

            os.kill(first, signal.SIGKILL)
            second = worker_started_after(1)
            assert not alive(first) and main_pid() == initial
            print("PASS: worker crash is reaped and recovered by the same daemon", flush=True)

            # The dead parent cannot clean up: systemd must retire the old child.
            os.kill(initial, signal.SIGKILL)
            third = worker_started_after(2)
            assert second in records("stopped") and not alive(second)
            assert not alive(initial) and main_pid() != initial
            assert int(prop("NRestarts")) >= 1
            timeline = events.read_text()
            assert timeline.index(f"stopped {second}") < timeline.index(f"started {third}")
            print("PASS: daemon SIGKILL invokes cgroup cleanup before restart", flush=True)

            previous_main = main_pid()
            os.kill(previous_main, signal.SIGTERM)
            fourth = worker_started_after(3)
            assert not alive(previous_main) and main_pid() != previous_main
            assert third in records("stopped") and not alive(third)
            assert int(prop("NRestarts")) >= 2
            print("PASS: unexpected clean daemon exit also recovers", flush=True)

            group = prop("ControlGroup")
            ctl("stop", name)
            assert fourth in records("stopped") and not alive(fourth)
            assert cgroup_empty(group)
            time.sleep(2.3)
            assert prop("ActiveState") == "inactive" and len(records("started")) == 4
            print("PASS: explicit stop reaps worker, empties cgroup and suppresses restart", flush=True)

            (root / "ignore-term").touch()
            ctl("start", name)
            stuck = worker_started_after(4)
            group = prop("ControlGroup")
            before = time.monotonic()
            ctl("stop", name)
            assert time.monotonic() - before >= 5
            assert stuck in records("ignored") and stuck not in records("stopped")
            assert not alive(stuck) and cgroup_empty(group)
            assert "SIGKILL" in log.read_text()
            print("PASS: stuck worker receives bounded grace before daemon escalation", flush=True)

            # Repeat with no living supervisor: exercise systemd's outer bound.
            ctl("start", name)
            stuck = worker_started_after(5)
            os.kill(main_pid(), signal.SIGKILL)
            before = time.monotonic()
            worker_started_after(6)
            assert time.monotonic() - before >= 10
            assert not alive(stuck) and stuck in records("ignored")
            (root / "ignore-term").unlink()
            ctl("stop", name)
            print("PASS: systemd's stop timeout cleans a stuck orphan before recovery", flush=True)
        except BaseException:
            print(log.read_text() if log.exists() else "No daemon log", file=sys.stderr)
            print(ctl("status", name, "--no-pager", check=False).stdout, file=sys.stderr)
            raise
        finally:
            (root / "ignore-term").unlink(missing_ok=True)
            ctl("stop", name, check=False)
            ctl("disable", "--runtime", name, check=False)
            ctl("reset-failed", name, check=False)
            ctl("daemon-reload")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("daemon", type=Path)
    parser.add_argument("--require", action="store_true")
    args = parser.parse_args()
    try:
        available = ctl("show", "--property=Version", "--value", check=False).returncode == 0
    except FileNotFoundError:
        available = False
    if not available:
        print("SKIP: no running systemd user manager (use --require to make this fatal)")
        sys.exit(1 if args.require else 0)
    # Generated unit paths must not need systemd escaping.
    daemon = args.daemon.resolve(strict=True)
    if any(character.isspace() or character in '%"\\' for character in str(daemon)):
        parser.error("use a daemon path without whitespace or systemd specifier/escape characters")
    run(daemon)
