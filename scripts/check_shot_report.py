#!/usr/bin/env python3
"""Validate one harness shot report and the files it claims.

The gate renders four shelf states. Each report must be independently clean:
no problems, an ok verdict, a live activation, a loaded manifest, every
declared surface provided, both widget widths declared, and a non-empty PNG
for every declared surface.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

PAGES = {
    "shelf-widget": "shelf-widget.png",
    "live-activity": "live-activity.png",
    "expanded-surface": "expanded-surface.png",
    "settings-pane": "settings-pane.png",
    "hud": "hud.png",
    "lock-screen-status": "lock-screen.png",
    "menu-bar-extra": "menu-bar.png",
}


def fail(message: str) -> None:
    sys.exit(message)


def inside_worktree(path: Path) -> Path:
    root = Path.cwd().resolve()
    try:
        path.resolve().relative_to(root)
    except ValueError:
        fail(f"{path}: path is outside the repository worktree")
    return path.resolve()


def read_report(report_path: Path) -> dict:
    with report_path.open(encoding="utf-8") as handle:
        return json.load(handle)


def check_verdict(report: dict, report_path: Path) -> None:
    if report.get("problems"):
        fail("shots reported problems:\n  " + "\n  ".join(report["problems"]))
    if report.get("verdict") != "ok":
        fail(f"{report_path}: verdict is {report.get('verdict')!r}, not 'ok'")


def check_activation(report: dict, report_path: Path) -> None:
    activation = report.get("activation") or {}
    if not activation.get("active"):
        fail(f"{report_path}: the droplet did not activate")
    if activation.get("error"):
        fail(f"{report_path}: activation failed: {activation['error']}")
    manifest = report.get("manifest") or {}
    if not manifest.get("loaded"):
        fail(f"{report_path}: the manifest did not load: {manifest.get('problem')}")


def check_surfaces(report: dict, report_path: Path) -> list[str]:
    declared = (report.get("droplet") or {}).get("surfaces") or []
    if not declared:
        fail(f"{report_path}: the manifest declares no surfaces")
    verdicts = {
        surface.get("surface"): surface.get("verdict")
        for surface in report.get("surfaces") or []
    }
    for surface in declared:
        if verdicts.get(surface) != "provided":
            fail(f"{report_path}: {surface} is {verdicts.get(surface)!r}, not 'provided'")
    return declared


def check_widgets(report: dict, report_path: Path) -> None:
    widgets = report.get("shelfWidgets") or []
    if not widgets:
        fail(f"{report_path}: no shelf widget descriptors")
    for widget in widgets:
        if widget.get("preferredSoloWidth") is None or widget.get("preferredPairedWidth") is None:
            fail(f"{report_path}: widget {widget.get('id')!r} does not declare both widths")


def check_files(declared: list[str], shot_dir: Path, report_path: Path) -> None:
    for surface in declared:
        page = PAGES.get(surface)
        if page is None:
            fail(f"{report_path}: {surface} has no known shot page")
        path = shot_dir / page
        if not path.is_file() or path.stat().st_size == 0:
            fail(f"{report_path}: {surface} was not rendered ({path} missing or empty)")


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: check_shot_report.py <report.json> <shot-dir>")
    report_path = inside_worktree(Path(sys.argv[1]))
    shot_dir = inside_worktree(Path(sys.argv[2]))

    report = read_report(report_path)
    check_verdict(report, report_path)
    check_activation(report, report_path)
    declared = check_surfaces(report, report_path)
    check_widgets(report, report_path)
    check_files(declared, shot_dir, report_path)

    print(f"{report_path}: {len(declared)} surface(s), both widget widths, report ok")


if __name__ == "__main__":
    main()
