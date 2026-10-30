#!/usr/bin/env python3
"""Validate one harness shot report and the files it claims.

The gate renders four shelf states. Each report must be independently clean:
no problems, an ok verdict, a live activation, a loaded manifest, every
declared surface provided, both widget widths declared, and a non-empty PNG
for every declared surface.
"""

from __future__ import annotations

import json
import os
import sys

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


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: check_shot_report.py <report.json> <shot-dir>")
    report_path, shot_dir = sys.argv[1], sys.argv[2]

    with open(report_path) as handle:
        report = json.load(handle)

    if report.get("problems"):
        fail("shots reported problems:\n  " + "\n  ".join(report["problems"]))
    if report.get("verdict") != "ok":
        fail(f"{report_path}: verdict is {report.get('verdict')!r}, not 'ok'")

    activation = report.get("activation") or {}
    if not activation.get("active"):
        fail(f"{report_path}: the droplet did not activate")
    if activation.get("error"):
        fail(f"{report_path}: activation failed: {activation['error']}")

    manifest = report.get("manifest") or {}
    if not manifest.get("loaded"):
        fail(f"{report_path}: the manifest did not load: {manifest.get('problem')}")

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

    widgets = report.get("shelfWidgets") or []
    if not widgets:
        fail(f"{report_path}: no shelf widget descriptors")
    for widget in widgets:
        if widget.get("preferredSoloWidth") is None or widget.get("preferredPairedWidth") is None:
            fail(f"{report_path}: widget {widget.get('id')!r} does not declare both widths")

    for surface in declared:
        page = PAGES.get(surface)
        if page is None:
            fail(f"{report_path}: {surface} has no known shot page")
        path = os.path.join(shot_dir, page)
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            fail(f"{report_path}: {surface} was not rendered ({path} missing or empty)")

    print(f"{report_path}: {len(declared)} surface(s), both widget widths, report ok")


if __name__ == "__main__":
    main()
