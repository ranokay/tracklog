#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v droppykit >/dev/null 2>&1; then
    echo "error: droppykit is not on PATH; see tracklog/README.md" >&2
    exit 1
fi

if ! command -v hk >/dev/null 2>&1; then
    echo "error: hk is not on PATH; run mise install" >&2
    exit 1
fi

echo "==> lint"
hk check --all

echo "==> engine tests"
swift test --package-path Tests

echo "==> droplet build"
(cd tracklog && droppykit build)

echo "==> droplet validation"
(cd tracklog && droppykit validate)

echo "==> surface shots"
mkdir -p tracklog/shots
rm -rf tracklog/shots/playing tracklog/shots/paused tracklog/shots/off tracklog/shots/feed-unavailable
rm -f tracklog/shots/report.json tracklog/shots/*.png

# The main report keeps the documented path and the playing state. Each extra
# state is a separate clean harness run; every report is checked, not only the
# first.
(cd tracklog && TRACKLOG_DEMO_STATE=playing droppykit run -- --shots ./shots --report ./shots/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/report.json tracklog/shots

for state in paused off feed-unavailable; do
    echo "==> surface shots: $state"
    (cd tracklog && TRACKLOG_DEMO_STATE="$state" droppykit run -- --shots "./shots/$state" --report "./shots/$state/report.json" --shot-height 1900)
    python3 scripts/check_shot_report.py "tracklog/shots/$state/report.json" "tracklog/shots/$state"
done

echo "==> gate passed"
echo "manual: run the live Last.fm/ListenBrainz smoke test before bumping the version"
