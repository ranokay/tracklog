#!/usr/bin/env python3
"""Tests for the process-tree timeout wrapper."""

from __future__ import annotations

import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "run_with_timeout.py"
WAIT_SECONDS = 60.0

# The child ignores SIGTERM and starts a grandchild in its own session, so only
# the snapshot plus SIGKILL escalation can remove both.
HANGING_CHILD = """
import os
import signal
import subprocess
import sys
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
pidfile = sys.argv[1]
grandchild = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)",
    ],
    start_new_session=True,
)
with open(pidfile, "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()} {grandchild.pid}\\n")
time.sleep(600)
"""

STREAMING_CHILD = """
import sys

print("streamed", flush=True)
print("streamed-error", file=sys.stderr, flush=True)
sys.stdin.readline()
raise SystemExit(7)
"""

# The grandchild inherits the child's process group. The child exits 0 while
# the grandchild is still running, so only the normal-exit group kill removes
# it.
SAME_GROUP_CHILD = """
import subprocess
import sys

pidfile = sys.argv[1]
grandchild = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
with open(pidfile, "w", encoding="utf-8") as handle:
    handle.write(str(grandchild.pid))
"""


def wait_for_file(path: Path, timeout: float = WAIT_SECONDS) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise AssertionError(f"{path} did not appear")
        time.sleep(0.05)


def is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_gone(pids: list[int], timeout: float = WAIT_SECONDS) -> None:
    deadline = time.monotonic() + timeout
    while any(is_alive(pid) for pid in pids):
        if time.monotonic() >= deadline:
            raise AssertionError(f"processes still alive: {[pid for pid in pids if is_alive(pid)]}")
        time.sleep(0.05)


class RunWithTimeoutTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def start_hanging(self, timeout: str) -> tuple[subprocess.Popen[str], Path]:
        pidfile = self.root / f"pids-{time.monotonic_ns()}"
        child = self.root / f"child-{time.monotonic_ns()}.py"
        child.write_text(HANGING_CHILD, encoding="utf-8")
        process = subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                timeout,
                "--grace",
                "0.3",
                "--",
                sys.executable,
                str(child),
                str(pidfile),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return process, pidfile

    def pids_from(self, pidfile: Path) -> list[int]:
        wait_for_file(pidfile)
        return [int(value) for value in pidfile.read_text(encoding="utf-8").split()]

    def test_normal_exit_status_and_live_output(self) -> None:
        child = self.root / "streaming-child.py"
        child.write_text(STREAMING_CHILD, encoding="utf-8")
        process = subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "600",
                "--",
                sys.executable,
                str(child),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        lines: dict[str, str] = {}
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + WAIT_SECONDS
        try:
            while len(lines) < 2 and time.monotonic() < deadline:
                for key, _ in selector.select(timeout=deadline - time.monotonic()):
                    line = key.fileobj.readline()
                    if line:
                        lines[key.data] = line.strip()
            self.assertIsNone(process.poll(), "the child must still be running while its lines are read")
            self.assertEqual(lines.get("stdout"), "streamed")
            self.assertEqual(lines.get("stderr"), "streamed-error")
        finally:
            selector.close()
            if process.poll() is None:
                try:
                    process.stdin.write("release\n")
                    process.stdin.flush()
                except BrokenPipeError:
                    pass
        _stdout, stderr = process.communicate(timeout=WAIT_SECONDS)
        self.assertEqual(process.returncode, 7, stderr)

    def test_timeout_kills_child_and_own_session_grandchild(self) -> None:
        process, pidfile = self.start_hanging("15")
        pids = self.pids_from(pidfile)
        _stdout, stderr = process.communicate(timeout=WAIT_SECONDS)
        self.assertEqual(process.returncode, 124, stderr)
        self.assertIn("timeout bound", stderr)
        self.assertIn("fired", stderr)
        wait_gone(pids)

    def test_normal_exit_cleans_up_the_child_group(self) -> None:
        pidfile = self.root / f"same-group-{time.monotonic_ns()}"
        child = self.root / f"same-group-child-{time.monotonic_ns()}.py"
        child.write_text(SAME_GROUP_CHILD, encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "600",
                "--",
                sys.executable,
                str(child),
                str(pidfile),
            ],
            capture_output=True,
            text=True,
            timeout=WAIT_SECONDS,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        wait_for_file(pidfile)
        grandchild = int(pidfile.read_text(encoding="utf-8").strip())
        wait_gone([grandchild])

    def test_outer_sigterm_and_sigint_tear_down_the_tree(self) -> None:
        for signum, expected in ((signal.SIGTERM, 143), (signal.SIGINT, 130)):
            with self.subTest(signum=signum):
                process, pidfile = self.start_hanging("600")
                pids = self.pids_from(pidfile)
                os.kill(process.pid, signum)
                _stdout, stderr = process.communicate(timeout=WAIT_SECONDS)
                self.assertEqual(process.returncode, expected, stderr)
                wait_gone(pids)


if __name__ == "__main__":
    unittest.main()
