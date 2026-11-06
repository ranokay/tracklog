#!/usr/bin/env bash
# The palette's host contract: the panel is key and main, the activation began,
# the key monitor and observers are installed, and close clears the panel so a
# second open works. The harness installs Droppy's panel activation provider
# for this run; a panel that refuses main raises the same exception the host
# raises and the check fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/tracklog"

swift build --product TracklogHarness
TRACKLOG_HARNESS_HOST_PANEL_ACTIVATION=1 .build/debug/TracklogHarness --panel-check
