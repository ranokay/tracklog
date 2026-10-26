#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v droppykit >/dev/null 2>&1; then
    echo "error: droppykit is not on PATH; see tracklog/README.md" >&2
    exit 1
fi

echo "==> engine tests"
swift test --package-path Tests

echo "==> droplet build"
(cd tracklog && droppykit build)

echo "==> droplet validation"
(cd tracklog && droppykit validate)

echo "==> surface shots"
mkdir -p tracklog/shots
rm -f tracklog/shots/report.json
(cd tracklog && droppykit run -- --shots ./shots --report ./shots/report.json)

python3 - "$ROOT/tracklog/shots/report.json" <<'PY'
import json
import os
import sys

report_path = sys.argv[1]
shot_dir = os.path.dirname(report_path)

with open(report_path) as handle:
    report = json.load(handle)

problems = report.get("problems", [])
if problems:
    sys.exit("shots reported problems:\n  " + "\n  ".join(problems))
if report.get("verdict") != "ok":
    sys.exit(f"shots verdict is {report.get('verdict')!r}, not 'ok'")

activation = report.get("activation") or {}
if not activation.get("active"):
    sys.exit("the droplet did not activate")
if activation.get("error"):
    sys.exit(f"activation failed: {activation['error']}")

manifest = report.get("manifest") or {}
if not manifest.get("loaded"):
    sys.exit(f"the manifest did not load: {manifest.get('problem')}")

pages = {
    "shelf-widget": "shelf-widget.png",
    "live-activity": "live-activity.png",
    "expanded-surface": "expanded-surface.png",
    "settings-pane": "settings-pane.png",
    "hud": "hud.png",
    "lock-screen-status": "lock-screen.png",
    "menu-bar-extra": "menu-bar.png",
}
surfaces = (report.get("droplet") or {}).get("surfaces") or []
if not surfaces:
    sys.exit("the manifest declares no surfaces")

missing = []
for surface in surfaces:
    page = pages.get(surface)
    if page is None:
        missing.append(f"{surface}: no known shot page")
    elif not os.path.getsize(os.path.join(shot_dir, page)):
        missing.append(f"{surface}: {page} is missing or empty")
if missing:
    sys.exit("declared surfaces were not rendered:\n  " + "\n  ".join(missing))

print(f"gate: {len(surfaces)} surface(s) rendered, no problems")
PY

echo "==> gate passed"
echo "manual: run the live Last.fm/ListenBrainz smoke test before bumping the version"
