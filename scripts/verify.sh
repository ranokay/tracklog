#!/usr/bin/env bash
# The inner fix-loop checks: everything `gate` runs except the surface shots.
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

echo "==> license resources"
for notice in LICENSE NOTICE THIRD_PARTY_NOTICES.txt; do
    cmp "$notice" "tracklog/Assets/Licenses/$notice"
done

echo "==> lint"
hk check --all

echo "==> script tests"
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py'

echo "==> engine tests"
python3 scripts/run_with_timeout.py swift test --package-path Tests

echo "==> droplet build"
(cd tracklog && droppykit build)

echo "==> droplet validation"
(cd tracklog && droppykit validate)

echo "==> verify passed"
