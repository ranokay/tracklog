#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/verify.sh"

echo "==> surface shots"
mkdir -p tracklog/shots
rm -rf tracklog/shots/playing tracklog/shots/paused tracklog/shots/off tracklog/shots/feed-unavailable tracklog/shots/charts
rm -rf tracklog/shots/charts-*
rm -rf tracklog/shots/history-*
rm -rf tracklog/shots/search-*
rm -rf tracklog/shots/loved-*
rm -rf tracklog/shots/details-*
rm -rf tracklog/shots/images-settings
rm -rf tracklog/shots/charts-override
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

echo "==> surface shots: charts"
run_chart_shots() {
    local name="$1"
    local fixture="$2"
    local demo="${3:-playing}"
    echo "==> surface shots: charts-$name"
    (cd tracklog && TRACKLOG_DEMO_STATE="$demo" TRACKLOG_HARNESS_CHARTS="$fixture" TRACKLOG_HARNESS_SECTION=charts droppykit run -- --shots "./shots/charts-$name" --report "./shots/charts-$name/report.json" --shot-height 1900)
    python3 scripts/check_shot_report.py "tracklog/shots/charts-$name/report.json" "tracklog/shots/charts-$name"
}

# Every chart state the contract names, each as a clean harness run. The
# playing strip stays visible beside loading and failed charts, and the
# long-names fixture also gives that strip a long title.
for fixture in normal loading empty not-ready failed failed-saved long-names listenbrainz all-time all-time-total-failed \
    local local-empty local-missing-metadata libre-fallback no-connection rate-limited-saved app-credentials needs-sign-in; do
    run_chart_shots "$fixture" "$fixture"
done

# Pinned-strip branches: off, paused, playing (above) and absent (idle and
# feed unavailable).
for state in paused off idle feed-unavailable; do
    run_chart_shots "$state" normal "$state"
done

echo "==> surface shots: charts-contrast"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_CHARTS=normal TRACKLOG_HARNESS_SECTION=charts TRACKLOG_HARNESS_CONTRAST=increased droppykit run -- --shots ./shots/charts-contrast --report ./shots/charts-contrast/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/charts-contrast/report.json tracklog/shots/charts-contrast

echo "==> surface shots: charts-reduced-motion"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_CHARTS=normal TRACKLOG_HARNESS_SECTION=charts TRACKLOG_HARNESS_REDUCE_MOTION=1 droppykit run -- --shots ./shots/charts-reduced-motion --report ./shots/charts-reduced-motion/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/charts-reduced-motion/report.json tracklog/shots/charts-reduced-motion

echo "==> surface shots: charts-settings"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_CHARTS=normal TRACKLOG_HARNESS_SECTION=charts TRACKLOG_HARNESS_SETTINGS_PAGE=charts droppykit run -- --shots ./shots/charts-settings --report ./shots/charts-settings/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/charts-settings/report.json tracklog/shots/charts-settings

echo "==> surface shots: history"
run_history_shots() {
    local fixture="$1"
    echo "==> surface shots: history-$fixture"
    (cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_HISTORY="$fixture" droppykit run -- --shots "./shots/history-$fixture" --report "./shots/history-$fixture/report.json" --shot-height 1900)
    python3 scripts/check_shot_report.py "tracklog/shots/history-$fixture/report.json" "tracklog/shots/history-$fixture"
}

# The browse states #81 names: empty, large, a track snapshot, missing art,
# a positioned jump with its newer action, the two failure scopes and the
# refusal bar the harness's own Settings refusal produces.
for fixture in empty large track track-missing-artwork jump track-error feed-error settings-refused delete; do
    run_history_shots "$fixture"
done

echo "==> surface shots: history-edit"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_HISTORY=edit TRACKLOG_HARNESS_SETTINGS_PAGE=history-edit droppykit run -- --shots ./shots/history-edit --report ./shots/history-edit/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/history-edit/report.json tracklog/shots/history-edit

echo "==> surface shots: history-settings"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_SETTINGS_PAGE=history droppykit run -- --shots ./shots/history-settings --report ./shots/history-settings/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/history-settings/report.json tracklog/shots/history-settings

echo "==> surface shots: search-refusal"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_PALETTE=refusal droppykit run -- --shots ./shots/search-refusal --report ./shots/search-refusal/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/search-refusal/report.json tracklog/shots/search-refusal

echo "==> surface shots: search-settings"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_SETTINGS_PAGE=search droppykit run -- --shots ./shots/search-settings --report ./shots/search-settings/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/search-settings/report.json tracklog/shots/search-settings

echo "==> surface shots: loved"
run_loved_shots() {
    local fixture="$1"
    echo "==> surface shots: loved-$fixture"
    (cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_LOVED="$fixture" TRACKLOG_HARNESS_SECTION=loved droppykit run -- --shots "./shots/loved-$fixture" --report "./shots/loved-$fixture/report.json" --shot-height 1900)
    python3 scripts/check_shot_report.py "tracklog/shots/loved-$fixture/report.json" "tracklog/shots/loved-$fixture"
}

# The states #87 names: normal rows, loading, a successful empty list, a read
# failure, a compatible server without the read, unusable app credentials,
# long names, no current connection, needs sign-in, a rejected credential, a
# paused connection, a refused row action, a failed refresh over rows, a rate
# limit and loved recordings without metadata.
for fixture in normal loading empty failed unsupported app-credentials long-names no-connection \
    needs-sign-in credential-rejected paused action-failure refresh-failure rate-limited metadata-unavailable; do
    run_loved_shots "$fixture"
done

echo "==> surface shots: details"
run_detail_shots() {
    local fixture="$1"
    echo "==> surface shots: details-$fixture"
    (cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_DETAIL="$fixture" droppykit run -- --shots "./shots/details-$fixture" --report "./shots/details-$fixture/report.json" --shot-height 1900)
    python3 scripts/check_shot_report.py "tracklog/shots/details-$fixture/report.json" "tracklog/shots/details-$fixture"
}

# Artist, album and track pages, Last.fm facts, the no-connection reason, the
# ListenBrainz MBID link, the approximate artist image, an explicit override,
# an unreadable stored copy and long metadata.
for fixture in artist artist-approximate artist-no-connection album album-service-image track \
    album-listenbrainz override corrupt-override long-names track-delete; do
    run_detail_shots "$fixture"
done

echo "==> surface shots: history-jump-back"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_DETAIL=history-jump-back TRACKLOG_HARNESS_HISTORY=jump droppykit run -- --shots ./shots/history-jump-back --report ./shots/history-jump-back/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/history-jump-back/report.json tracklog/shots/history-jump-back

echo "==> surface shots: loved-detail-back"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_DETAIL=loved-back TRACKLOG_HARNESS_SECTION=loved TRACKLOG_HARNESS_LOVED=normal droppykit run -- --shots ./shots/loved-detail-back --report ./shots/loved-detail-back/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/loved-detail-back/report.json tracklog/shots/loved-detail-back

echo "==> surface shots: images-settings"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_DETAIL=corrupt-override TRACKLOG_HARNESS_SETTINGS_PAGE=images droppykit run -- --shots ./shots/images-settings --report ./shots/images-settings/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/images-settings/report.json tracklog/shots/images-settings

echo "==> surface shots: charts-override"
(cd tracklog && TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_DETAIL=override TRACKLOG_HARNESS_SECTION=charts droppykit run -- --shots ./shots/charts-override --report ./shots/charts-override/report.json --shot-height 1900)
python3 scripts/check_shot_report.py tracklog/shots/charts-override/report.json tracklog/shots/charts-override

echo "==> gate passed"
echo "manual: run the live Last.fm/ListenBrainz smoke test before bumping the version"
