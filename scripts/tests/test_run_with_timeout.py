#!/usr/bin/env python3
"""Tests for the process-tree timeout wrapper."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "run_with_timeout.py"

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


def wait_for_file(path: Path, timeout: float = 5.0) -> None:
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


def wait_gone(pids: list[int], timeout: float = 5.0) -> None:
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
        wait_for_file(pidfile, timeout=3.0)
        return [int(value) for value in pidfile.read_text(encoding="utf-8").split()]

    def test_normal_exit_status_and_live_output(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "10",
                sys.executable,
                "-c",
                "import sys; print('streamed'); print('streamed-error', file=sys.stderr); raise SystemExit(7)",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("streamed", result.stdout)
        self.assertIn("streamed-error", result.stderr)

    def test_timeout_kills_child_and_own_session_grandchild(self) -> None:
        process, pidfile = self.start_hanging("2")
        pids = self.pids_from(pidfile)
        _stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 124, stderr)
        self.assertIn("timeout bound", stderr)
        self.assertIn("fired", stderr)
        wait_gone(pids)

    def test_outer_sigterm_and_sigint_tear_down_the_tree(self) -> None:
        for signum, expected in ((signal.SIGTERM, 143), (signal.SIGINT, 130)):
            with self.subTest(signum=signum):
                process, pidfile = self.start_hanging("600")
                pids = self.pids_from(pidfile)
                os.kill(process.pid, signum)
                _stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, expected, stderr)
                wait_gone(pids)


if __name__ == "__main__":
    unittest.main()
