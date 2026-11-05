#!/usr/bin/env python3
"""Tests for the process-tree timeout wrapper."""

from __future__ import annotations

import importlib.util
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "run_with_timeout.py"
WAIT_SECONDS = 60.0

_SPEC = importlib.util.spec_from_file_location("run_with_timeout", str(SCRIPT))
assert _SPEC is not None and _SPEC.loader is not None
WRAPPER = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(WRAPPER)

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

# The child ignores SIGTERM, starts a same-group grandchild, then exits 0 as
# soon as the release file appears. A signal sent before that exit exercises the
# early-signal path after the child has already been reaped.
EARLY_SIGNAL_CHILD = """
import os
import signal
import subprocess
import sys

signal.signal(signal.SIGTERM, signal.SIG_IGN)
pidfile, release = sys.argv[1], sys.argv[2]
grandchild = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
with open(pidfile, "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()} {grandchild.pid}\\n")
while not os.path.exists(release):
    pass
raise SystemExit(0)
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

    def test_shell_metacharacters_stay_literal_arguments(self) -> None:
        child = self.root / "args-child.py"
        child.write_text("import sys\nprint(repr(sys.argv[1:]))\n", encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "60",
                "--",
                sys.executable,
                str(child),
                "a; echo injected",
                "$(echo injected)",
                "`echo injected`",
            ],
            capture_output=True,
            check=False,
            text=True,
            timeout=WAIT_SECONDS,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("'a; echo injected'", result.stdout)
        self.assertIn("'$(echo injected)'", result.stdout)
        self.assertIn("'`echo injected`'", result.stdout)

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
            check=False,
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

    def test_signal_before_completion_wins(self) -> None:
        self.assertTrue(WRAPPER.signal_wins(15, True))
        self.assertFalse(WRAPPER.signal_wins(15, False))
        self.assertFalse(WRAPPER.signal_wins(None, True))

    def test_early_signal_cleans_the_child_group(self) -> None:
        pidfile = self.root / f"early-signal-{time.monotonic_ns()}"
        release = self.root / f"release-{time.monotonic_ns()}"
        child = self.root / f"early-signal-child-{time.monotonic_ns()}.py"
        child.write_text(EARLY_SIGNAL_CHILD, encoding="utf-8")
        process = subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout",
                "600",
                "--grace",
                "0.3",
                "--",
                sys.executable,
                str(child),
                str(pidfile),
                str(release),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        pids = self.pids_from(pidfile)
        os.kill(process.pid, signal.SIGTERM)
        release.write_text("release", encoding="utf-8")
        _stdout, stderr = process.communicate(timeout=WAIT_SECONDS)
        self.assertEqual(process.returncode, 143, stderr)
        wait_gone(pids)

    def test_kill_child_group_ignores_permission_error(self) -> None:
        with mock.patch.object(
            WRAPPER.os,
            "killpg",
            side_effect=PermissionError(1, "Operation not permitted"),
        ):
            WRAPPER.kill_child_group(os.getpid())

    def test_signal_tree_survives_permission_error_from_getpgid(self) -> None:
        calls: list[tuple[str, int, int]] = []

        def getpgid(_pid: int) -> int:
            raise PermissionError(1, "Operation not permitted")

        def kill(pid: int, signum: int) -> None:
            calls.append(("kill", pid, signum))

        with mock.patch.object(WRAPPER.os, "getpgid", side_effect=getpgid):
            with mock.patch.object(WRAPPER.os, "kill", side_effect=kill):
                WRAPPER.signal_tree({101, 202}, signal.SIGTERM)

        self.assertEqual(
            set(calls),
            {("kill", 101, signal.SIGTERM), ("kill", 202, signal.SIGTERM)},
        )

    def test_signal_tree_reaches_pids_after_killpg_permission_error(self) -> None:
        calls: list[tuple[str, int, int]] = []

        def getpgid(pid: int) -> int:
            return 1000 + pid

        def killpg(_group: int, signum: int) -> None:
            calls.append(("killpg", _group, signum))
            raise PermissionError(1, "Operation not permitted")

        def kill(pid: int, signum: int) -> None:
            calls.append(("kill", pid, signum))
            if pid == 101:
                raise PermissionError(1, "Operation not permitted")

        with mock.patch.object(WRAPPER.os, "getpgid", side_effect=getpgid):
            with mock.patch.object(WRAPPER.os, "killpg", side_effect=killpg):
                with mock.patch.object(WRAPPER.os, "kill", side_effect=kill):
                    WRAPPER.signal_tree({101, 202}, signal.SIGTERM)

        self.assertEqual(
            {call for call in calls if call[0] == "kill"},
            {("kill", 101, signal.SIGTERM), ("kill", 202, signal.SIGTERM)},
        )
        self.assertEqual(len([call for call in calls if call[0] == "killpg"]), 2)


if __name__ == "__main__":
    unittest.main()
