#!/usr/bin/env python3
"""Run a command under a hard timeout and tear down its whole process tree.

The timeout is a single default here so `mise run test` and the verify loop
cannot drift. A descendant that leaves its parent's session or process group
would escape a group-only kill, so the tree is snapshotted before signalling.

The command must be a trusted argv list supplied by repository automation
(`mise` or `scripts/verify.sh`). This script never uses a shell, so shell
metacharacters stay literal arguments.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time

DEFAULT_TIMEOUT_SECONDS = 900.0
DEFAULT_GRACE_SECONDS = 2.0
KILL_WAIT_SECONDS = 5.0
POLL_SECONDS = 0.05


def process_table() -> dict[int, int]:
    """Return pid -> parent pid for every process visible to this user."""
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid="],
        check=False,
        capture_output=True,
        text=True,
    )
    table: dict[int, int] = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            pid, parent = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        table[pid] = parent
    return table


def descendants(root: int) -> set[int]:
    """Return root and every process below it, following parent links."""
    table = process_table()
    found = {root}
    changed = True
    while changed:
        changed = False
        for pid, parent in table.items():
            if parent in found and pid not in found:
                found.add(pid)
                changed = True
    return found


def is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_tree(pids: set[int], signum: int) -> None:
    """Signal every pid and every group in the snapshot, except our own.

    macOS can report EPERM when a group holds only zombies. Treat that as
    "nothing left to signal" and keep going to the per-PID targets.
    """
    groups: set[int] = set()
    for pid in pids:
        try:
            groups.add(os.getpgid(pid))
        except (ProcessLookupError, PermissionError):
            continue
    try:
        own_group = os.getpgid(0)
    except (ProcessLookupError, PermissionError):
        own_group = None
    if own_group is not None:
        groups.discard(own_group)
    for group in groups:
        try:
            os.killpg(group, signum)
        except (ProcessLookupError, PermissionError):
            pass
    for pid in pids:
        if pid == os.getpid():
            continue
        try:
            os.kill(pid, signum)
        except (ProcessLookupError, PermissionError):
            pass


def wait_gone(
    pids: set[int],
    timeout: float,
    child: subprocess.Popen | None = None,
) -> set[int]:
    deadline = time.monotonic() + timeout
    remaining = {pid for pid in pids if is_alive(pid)}
    while remaining and time.monotonic() < deadline:
        time.sleep(POLL_SECONDS)
        if child is not None:
            child.poll()
        remaining = {pid for pid in pids if is_alive(pid)}
    return remaining


def kill_child_group(pid: int) -> None:
    """Kill anything the child left in its process group after it exits."""
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def tear_down(child: subprocess.Popen, grace: float) -> set[int]:
    """Snapshot, SIGTERM, re-snapshot after the grace, SIGKILL, then wait."""
    root = child.pid
    targets = descendants(root)
    signal_tree(targets, signal.SIGTERM)
    if wait_gone(targets, grace, child):
        # The child may have spawned after the first snapshot; resnapshot from
        # the root and from every survivor before escalating.
        survivors = {pid for pid in targets if is_alive(pid)}
        refresh = descendants(root)
        for pid in list(survivors):
            refresh |= descendants(pid)
        survivors |= refresh
        survivors.add(root)
        signal_tree(survivors, signal.SIGKILL)
        try:
            child.wait(timeout=KILL_WAIT_SECONDS)
        except subprocess.TimeoutExpired:
            pass
        return wait_gone(survivors, KILL_WAIT_SECONDS, child)
    return set()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="seconds before the bound fires (default: %(default)s)",
    )
    parser.add_argument(
        "--grace",
        type=float,
        default=DEFAULT_GRACE_SECONDS,
        help="seconds between SIGTERM and SIGKILL (default: %(default)s)",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="command and arguments to run",
    )
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    received: int | None = None

    def handle(signum: int, _frame: object) -> None:
        nonlocal received
        if received is None:
            received = signum

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    # Trusted repository automation supplies the argv list; shell=False keeps
    # every metacharacter a literal argument.
    child = subprocess.Popen(command, start_new_session=True)
    deadline = time.monotonic() + args.timeout
    timed_out = False
    while True:
        code = child.poll()
        if code is not None:
            break
        if received is not None:
            break
        if time.monotonic() >= deadline:
            timed_out = True
            break
        time.sleep(POLL_SECONDS)

    if received is not None:
        print(
            f"run_with_timeout: received SIG{received}; tearing down the process tree",
            file=sys.stderr,
        )
        remaining = tear_down(child, args.grace)
        if remaining:
            print(f"run_with_timeout: still alive after SIGKILL: {sorted(remaining)}", file=sys.stderr)
        return 128 + received

    if timed_out:
        print(
            f"run_with_timeout: timeout bound of {args.timeout:g}s fired; "
            "killed the process tree",
            file=sys.stderr,
        )
        remaining = tear_down(child, args.grace)
        if remaining:
            print(f"run_with_timeout: still alive after SIGKILL: {sorted(remaining)}", file=sys.stderr)
        return 124

    if code is None:
        raise RuntimeError("the child exited without a status")
    # A normal exit does not prove the child's group is empty: a test helper
    # that outlives the runner in the same group would be orphaned.
    kill_child_group(child.pid)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
