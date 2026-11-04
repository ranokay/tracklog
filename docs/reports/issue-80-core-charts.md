# Issue #80 Core charts — worker report

- Base: `c0bcd20c6bd5778ba648e0207283531ce50dc71d` (`feat: build ListenBrainz charts (#110)`)
- Gate head: `98717b96a0fcd7c536c7a5e5865d25e112ccfbe5` (`test: guard post-stop capture in chart lifecycle test`)
- Branch: `feat/core-charts-80`
- State: committed locally, not pushed. Review fixes F1–F4 are included; this report commit adds documentation and evidence only.
- Scope: CH-01, the accepted CH-02 subset, supported CH-07 totals and CH-08 refresh. Part of #76; it does not close #76 or #77 and makes no Store or milestone-complete claim.

## Contract reconciliation

| Matrix row | Accepted #74 contract | What was qualified |
| --- | --- | --- |
| CH-01 Charts tabs | Artists, albums and tracks for the current source and period; up to 50 ranked items; no graph, collage, arrows, grid or detail page. | Both service adapters and local history produce all three types. The list is capped at 50; the range total covers every listen. No deferred surface exists in the app. |
| CH-02 Period selector | Week/Month/Year/All time for services with native mappings; Today and Custom local-only; calendar windows, Monday weeks, DST, time-zone changes and inclusive Custom dates. | `ChartCalendarTests`, local composition tests and the interactive Service/Local matrices. Today and Custom are available only in local mode; service selection clamps them to Week. Custom is entered only through Settings. |
| CH-07 Range totals | Exact local totals for every supported local range; separately fetched, labelled and timestamped all-time account totals; other service period totals unavailable; loves unavailable. | Local totals are exact (`120` over 50 ranked rows). Last.fm/ListenBrainz account totals are separate cache entries and separate labels. Week/Month/Year show `Range totals unavailable`. No loves metric or surface is offered, so no unsupported zero is shown. |
| CH-08 Refresh charts | Saved snapshot first; 15-minute and manual refresh; coalescing; failure retention; scoped caches; obsolete-response guards; lifecycle ownership. | Cache/lifecycle tests plus the interactive failed-saved refresh and repeated Reload walk. Unlink, identity replacement and restart offline were exercised on real temporary SQLite. |

Libre.fm and no connection are explicit local-history states: the Libre.fm fallback is named and never queried for statistics; no connection offers local history and Services settings. Unsupported remote statistics are never represented as empty, zero or another source's rows.

## Composition proof

New tests added only where coverage was missing:

| Test | Closes |
| --- | --- |
| `failingChartTransportLeavesCaptureDeliveryAndHistoryCurrent` | Chart transport fails (not held) for Last.fm and ListenBrainz while the same transport still delivers. The listen persists, now-playing and History stay current, the delivery reaches `.delivered`, and the chart remains `.failed(.offline)`. |
| `runtimeDeactivateReactivateCyclesLeaveNoLateChartOrCaptureWork` | Three runtime-level deactivate/reactivate cycles; a final held obsolete chart response publishes nothing and writes no cache; a playback sample after the final deactivation changes no state or stored listen; no freshness wake survives. |
| `albumMissingMetadataIsItsOwnStateWithAnExactTotal` | All album records lack album data → `.noMetadata(omitted:)`, exact range total including omissions, explanatory state (not `.empty`). |
| `equalCountTieBreakUsesNormalizedKeyAndSequentialRanks` | Equal-count case/outer-space artist variants order by normalized key with sequential ranks and a deterministic representative spelling; stored metadata is not rewritten. |
| `signInFailureCopyMatchesWhetherSavedChartsExist` | A no-saved sign-in failure no longer claims saved charts stay visible. |

Reused coverage, by #74 acceptance item:

1. `localChartsCountEachListenOnceAcrossDeliveriesAndHistoryPages` (three targets, pending/delivered/abandoned, zero-target, 120 listens, 10-row History page, 50-row list, total 120); `lastFMChartKeepsTheFirstFiftyProviderRows`, `lastFMChartCapsEveryEntityTypeAtFifty`, `listenBrainzChartMatrixKeepsOrderAndCapsEveryEntityAndPeriod`.
2. `groupingNormalizesAndOmitMissingMetadataWithoutChangingFeedbackKeys`, `albumGroupingRequiresAlbumAndAnArtistFallback`, the two new local tests, `charts-long-names` and `charts-local-missing-metadata` shots.
3. `ChartCalendarTests` (`standardWindowsStartAtTheAgreedLocalBoundaries`, `boundedWindowsAreStartInclusiveAndEndExclusive`, `weekStartsOnMondayAcrossTheWeekend`, `customIncludesBothSelectedDatesThroughTheNextMidnight`, `reversedCustomDatesAreRejected`, `dstDaysKeepTheirWallClockBoundaries`, `aTimeZoneChangeMovesTheSameCalendarWindow`, `leapDayBelongsToItsDayMonthAndYear`), `localWindowMembershipIsHalfOpen`, `aTimeZoneChangeRecomputesTheLocalWindowWhileOpen`, `savingACustomRangeIncludesTheEndDayAndPersistsLocalSource`, `lastFMChartPeriodsUseNativeRollingValues`, `listenBrainzChartsUseCompletedPeriodsAndReturnedDates`, `notReadyAndEmptyAreDistinct`, `listenBrainzCopyMeasuresDataAgeFromTheReturnedEnd`, `listenBrainzSpanIsAUTCWeekInEveryMacZone`, `aSavedListenBrainzSpanSurvivesRestartFailureAndNotReady`.
4. `lastFMChartsUseRollingPeriodsAndProviderCounts`, `listenBrainzChartMatrixKeepsOrderAndCapsEveryEntityAndPeriod`, `libreFMOffersNamedLocalFallbackWithoutARequest`, `serviceChartsClampTodayAndCustomToWeek`, `cachedRowsAreScopedByAccountAndSelection`, `unlinkEvictsRemoteCacheAndRelinkCannotShowIt`, `identityReplacementEvictsTheOldAccountAndCannotShowIt`, `restartOfflineRestoresTheMatchingSavedChartAndItsRealAge`, `aLateResponseAfterSelectionChangeCannotBecomeCurrentOrBeCached`, `aLateServiceResponseAfterSourceChangeCannotOverwriteLocalCharts`, `aLateResponseAfterPeriodChangeCannotBecomeCurrentOrBeCached`; interactive source-switch readout.
5. `cacheIsFreshForFifteenMinutesThenRefreshes`, `aVisibleFreshChartRefreshesAtFifteenMinutes`, `aFailedRefreshKeepsRowsAndTheirOriginalAge`, `aFailedRefreshWithoutSavedRowsShowsTheFailure`, `notReadyWithSavedRowsKeepsThemAndNotReadyWithoutDataIsItsOwnState`, `repeatedRefreshesCoalesce`, the three manual-refresh-during-read tests, the three late-response tests, `deactivateStopsLateWorkAndReactivationLoadsAgain`, `deactivatingStopsTheFreshnessWakeAndReactivationRefreshes`, `hidingStopsTheFreshnessWakeAndShowingAgainRefreshes`, `restartOfflineRestoresTheMatchingSavedChartAndItsRealAge`, `aSavedListenBrainzSpanSurvivesRestartFailureAndNotReady`, the new runtime-cycle test.
6. `localChartsCountEachListenOnceAcrossDeliveriesAndHistoryPages` (120-total vs 50 rows), `allTimeListSucceedsWhenTheTotalFails`, `allTimeTotalSucceedsWhenTheListFails`, `lastFMAllTimeRowsStayReadyWhenTheAccountTotalFails`, `listenBrainzFetchesTheAccountTotalOnlyForAllTime`, `allTimeTotalsKeepTheirOwnAgeWhenOnlyTheTotalFails`, `anOlderFreshTotalRefreshesWithoutRefetchingTheFreshList`; `charts-all-time` and `charts-all-time-total-failed` shots.
7. Gate shots and the interactive AX walk; see the accessibility matrix. Audible VoiceOver is not passed.
8. `chartWorkDoesNotBlockCaptureDeliveryOrHistory`, `delayedLastFMChartWorkDoesNotBlockCaptureOrDelivery`, `localAggregationDoesNotBlockCaptureDeliveryOrHistory`, the new failing-transport test and the new runtime-cycle test; `charts-loading` and `charts-failed` shots show the playing strip beside the loading/failed chart, and `charts-idle`/`charts-feed-unavailable` show the absent branch.
9. The focused suite uses the sibling Tests package, real temporary SQLite, `FakeClock`, the existing HTTP transport seam, real Last.fm/ListenBrainz adapters and scripted fixtures. The receipt-backed gate and live-host limits are below.

### Observable acceptance map (#74 items 1–9)

| # | Evidence |
| --- | --- |
| 1 | `localChartsCountEachListenOnceAcrossDeliveriesAndHistoryPages`; the 50-row service cap tests; `charts-long-names` end-of-list. |
| 2 | `groupingNormalizesAndOmitMissingMetadataWithoutChangingFeedbackKeys`, `albumGroupingRequiresAlbumAndAnArtistFallback`, `equalCountTieBreakUsesNormalizedKeyAndSequentialRanks`, `albumMissingMetadataIsItsOwnStateWithAnExactTotal`, `charts-local-missing-metadata`. |
| 3 | `ChartCalendarTests`, `localWindowMembershipIsHalfOpen`, `aTimeZoneChangeRecomputesTheLocalWindowWhileOpen`, the native Last.fm/ListenBrainz period tests, `notReadyAndEmptyAreDistinct`, the returned-span tests, `charts-listenbrainz`, `charts-not-ready`. |
| 4 | The service/local matrix tests and `libreFMOffersNamedLocalFallbackWithoutARequest`; account/selection cache isolation and late-response tests; `unlinkEvictsRemoteCacheAndRelinkCannotShowIt`, `identityReplacementEvictsTheOldAccountAndCannotShowIt`, `restartOfflineRestoresTheMatchingSavedChartAndItsRealAge`; interactive source-switch readout; `charts-libre-fallback`, `charts-no-connection`. |
| 5 | The fresh/expired/no-cache, empty, failed-with/without-saved, coalescing, late-response, hide/deactivate and restart-offline tests; the new runtime-cycle test; interactive failed-saved refresh and Reload walk; the normal/loading/empty/not-ready/failed/failed-saved shots. |
| 6 | The local 120-total/50-row test, the list/total independence tests, `listenBrainzFetchesTheAccountTotalOnlyForAllTime`, the independent total age/freshness tests; `charts-all-time`, `charts-all-time-total-failed`. |
| 7 | **Harness output:** 25 chart states, the pinned matrix, the AX walk and the accessibility matrix. **Not passed:** audible VoiceOver and the real host Custom/Settings handoff (reasons below). |
| 8 | The delayed/failing/local chart isolation tests and the new runtime-cycle test; the playing strip in `charts-loading` and `charts-failed`; the absent branch in `charts-idle`/`charts-feed-unavailable`. |
| 9 | The sibling-package Swift Testing suite, the receipt-backed gate, and the interactive harness walk. **Not passed:** real host load and live service qualification (reasons below). |


## Gate

Command on the gate head:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Exit `0`, frozen gate `true`, clean before and after.
- Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261104T033501Z-022f28814a05.json`
- Log: `/Users/ranokay/.local/state/agent-tools/gates/20261104T033501Z-022f28814a05.log`
- Duration: 731.7 seconds.

| Command | Observed |
| --- | --- |
| `hk check --all` | SwiftFormat, SwiftLint and jactionlint clean; 0 SwiftLint violations in 271 files |
| `swift test --package-path Tests` | 607 tests in 92 suites; 51 media tests in 7 suites; 90 chart tests in 4 chart suites |
| `droppykit build` | universal droplet, x86_64 + arm64, `kit.minAPI` 1.19.0 |
| `droppykit validate` | `Ready to submit` |
| 29 harness report runs (4 base states + 25 chart-related runs) | every report `verdict: ok`, `problems: []`, `activation.active: true`, `activation.error: null` |

Chart states rendered and checked by the gate:

`normal`, `loading`, `empty`, `not-ready`, `failed`, `failed-saved`, `long-names`, `listenbrainz`, `all-time`, `all-time-total-failed`, `local`, `local-empty`, `local-missing-metadata`, `libre-fallback`, `no-connection`, `rate-limited-saved`, `app-credentials`, `needs-sign-in`, `paused`, `off`, `idle`, `feed-unavailable`, `contrast`, `reduced-motion`, and the Settings `charts` page.

Selected images are in `docs/reports/issue-80/`; each chart image is the notch panel cropped from that state's `expanded-surface.png`, and the checked reports are in `docs/reports/issue-80/reports/`.

### Native observations

- Normal: Last.fm artists, `Top 50 artists · Rolling 7 days`, 42/35/28 play counts, `Range totals unavailable`, playing strip present.
- Loading: `Loading top artists…`, `First load`, playing strip still current.
- Empty: `No listens in this range`, `Show all time`, `Use local history`.
- Not-ready: `Statistics are not ready`, separate from empty and from a failure, with `Try again` and `Use local history`.
- Failed: `Charts could not be loaded` with connection remedy and local fallback; the playing strip stays current.
- Failed saved: rows and `Saved 2 hr ago` remain; notice `Offline · showing saved charts` and `Try again`; the original age is retained.
- Long names: chart rows truncate; the list shows `2 artists shown`; the playing strip truncates a long title.
- Pinned strip matrix:

| Shot | Demo state | Branch exercised |
| --- | --- | --- |
| `charts-normal` | playing | playing |
| `charts-loading` | playing | playing, current beside loading |
| `charts-failed` | playing | playing, current beside failure |
| `charts-long-names` | playing, long title | playing, long-title treatment |
| `charts-paused` | paused | paused |
| `charts-off` | off | off |
| `charts-idle` | idle | absent (healthy, no playback) |
| `charts-feed-unavailable` | feed-unavailable | absent (no now-playing) |

- Increase Contrast draws row separators; Reduce Motion produced `Tracklog motion: reduced crossfade 0.16s` in the gate log (copied to `docs/reports/issue-80/reduced-motion.log`).
- ListenBrainz shows `Returned span … · data ends … · statistics updated …` in the completed week. All time shows `12,345 Last.fm · account total`, `Saved just now`; total-failure keeps the ranked rows and shows `Account total unavailable`.
- Local shows `6 local listens` and `Custom`; local-empty shows `0` with `No listens in this range`; local-missing-metadata shows `No album details in this range` with `2 listens are still included in the range total`.
- Libre.fm: `Libre.fm has no charts API. Showing this Mac's history.` No connection: `No connection selected` with `Use local history` and `Open Services settings`.
- Rate-limited-saved keeps saved rows and age with `Rate limited · showing saved charts`; app-credentials and needs-sign-in show distinct remedies; the needs-sign-in no-saved copy was corrected to `Sign in again in Settings, or use this Mac's local history.`

### Harness shot viewport (F2)

The raw `--shots` pages are 2360 × 3800 px (1180 × 1900 pt). The expanded
surface content is 898 × 557 (AXStaticText). The shot page is narrower than the
laid-out surface, so every raw chart PNG clips the surface's right edge: the
Refresh control and the third overflow dot sit at the page boundary, and the
panel's right rounded corner is outside the page. This is the harness shot
viewport, not layout overflow:

- Window: 1320 × 940 at global origin (240, 87), right edge x 1560.
- Surface content: 898 × 557.
- Right-most controls: Refresh and More x 1463..1487; Cancel x 1427..1451;
  Love x 1399..1423; connection switcher container x 1279..1487.
- All right-most controls end at least 73 pt before the window's right edge,
  and the connection popup is inside the 898 pt content.

`docs/reports/issue-80/ax/harness-window.png` is a native 2640 × 1880 window
capture showing the full panel right edge, the Refresh control and the
overflow circle. DroppyKit's harness has no width option (`--shot-height`
only), so the raw shot limit is recorded rather than worked around. The
committed chart images are notch-panel crops of the raw shots and inherit the
same right-edge clip.

### Review findings (rounds 1–2)

- **F1 fixed.** The section picker was 21 pt (`controlSize(.small)`), the
  connection menu 15 pt, and the playing/states overflow menu 20 × 14 pt; the
  Love control was disabled in the harness because its Last.fm adapter did not
  declare love support. The picker is now `.regular` (24 pt), the connection
  switcher is a native menu-style `Picker` (190 × 28 inside a 208 pt container)
  with a visible chevron overlay, both overflow menus use
  `DroppyCircleButtonStyle(size: 24)` (24 × 24), and the harness adapter
  declares love support. Every chart takeover control is listed with its
  measured frame in `ax/frames.txt`; the affected normal, loading, failed,
  failed-saved, paused, off, long-names and needs-sign-in shots were
  re-inspected.
- **F2 resolved as a harness viewport limit.** See the section above; the
  window capture shows the full right edge. No production layout change was
  needed.
- **F3 fixed.** The owner install command verifies the build, stages a
  complete copy, and only then replaces the bundle; a missing build or failed
  copy leaves the installed bundle in place. The sibling `Container` is
  untouched. The staged replacement was proven against a scratch Playground
  layout: `diff -r` exit 0 and `Container/sub/keep.txt` preserved
  (`docs/reports/issue-80/install-proof.txt`). The VoiceOver commands use the
  real fixture value `local`, and the `ListeningBrainz` typo is corrected to
  `ListenBrainz`.
- **F4 fixed.** The connection switcher again visibly signals a menu: the
  menu-style `Picker` carries a visible, accessibility-hidden
  `chevron.up.chevron.down` overlay inside its 208 pt container; the popup is
  190 × 28. A real selection was exercised in the running harness: `No
  connection` changed the source note to `No connection selected` and removed
  every ranked row, then `Last.fm · listener` restored `Rank 1, Blondie, 42
  plays`. The AX control label/value and both states are recorded in
  `ax/connection-switch.txt`. The shared header was inspected on History as
  well (`ax/history-header.png`); the section picker is 85 × 24 / 84 × 24 and
  the connection switcher is Charts-only by design. Affected shots were
  re-inspected.

## Interactive harness walk

Readouts are committed under `docs/reports/issue-80/ax/`; the method and evidence limit are in `ax/method.md` and the harness window is `ax/harness-window.png`.

- Service fixture (`charts-normal`, playing, Last.fm · listener): 15 AX presses covering artists, albums and tracks across Week, Month, Year and All time; every heading expectation matched. Row labels and values include `Rank 1, Blondie, 42 plays` / `Last.fm · listener, Rolling 7 days`; 8 rows per type.
- Local mode, reached by `On this Mac`: 18 AX presses covering all three types across Today, Week, Month, Year and All time; every heading expectation matched. Local rows read `Rank 1, Blondie, 2 listens` / `On this Mac, This week`; the observed total was `7 local listens` after the harness playback source added one listen.
- Source switching: Service → On this Mac → Service replaced both rows and source notes; no service row remained under local, and no local row remained after switching back. The connection popup was also opened, switched to `No connection` (source note `No connection selected`) and back to `Last.fm · listener`; the selection took effect each time.
- Failed-saved refresh: pressing Refresh kept `Offline · showing saved charts`, `Saved 2 hr ago`, the saved detail and the ranked rows; the saved age was not replaced with `Saved just now`.
- Repeated Reload on `charts-loading`: three Reload presses, then `AXBusyIndicator (Loading charts)` and `First load` with the playing strip; after the 30-second fixture delay the rows appeared as `Rank 1, Blondie, 42 plays` with `Saved just now`. No early obsolete publish was observed. The Activity page contained no `error` or `Tracklog activated` text and the harness chrome showed `Active`. Interactive mode has no `report.json`; the equivalent gate report `reports/charts-loading.json` is `problems: []`.
- Custom: pressing `Custom` produced no AX change — the harness refuses the host Settings call. This is harness wiring only; the real host handoff is not passed.

## Accessibility

The checklist used is `docs/accessibility/voiceover-checklist.md`. AX-tree inspection is not audible VoiceOver.

| Requirement | Result | State and method |
| --- | --- | --- |
| Rank, item, count and source speech | Passed (AX) | Service and local rows: label `Rank 1, … , 42 plays`; value `Last.fm · listener, Rolling 7 days` or `On this Mac, This week`. |
| Selected controls expose state | Passed (AX) | Type, source and period buttons expose `Selected` / `Not selected`; the section is a radio group; the connection popup exposes label `Current connection` and value `Last.fm · listener`. |
| 24-point targets | Passed (AX) | Every interactive chart control measured: section `History` 85×24 and `Charts` 84×24; connection popup 190×28 inside a 208 pt container, with its menu item 220×24; source/type/period choices 31 high (including `Today` and `Custom`); Refresh 24×24; failure `Try again` 78.5×31, `Open Services settings` 161×31, `Use local history` 122.5×31; notice `Try again` 78.5×31; playing-strip Love 24×24, Cancel 24×24, More 24×24; paused `Resume` 71×31 and More 24×24; off `Turn on` 69×31 and More 24×24. Details in `ax/frames.txt`. |
| Reduce Motion | Passed (configured path) | Gate run with `TRACKLOG_HARNESS_REDUCE_MOTION=1`; log `Tracklog motion: reduced crossfade 0.16s`; `AccessibilityMotionTests` asserts < 0.2 s. No frame timing measured. |
| Increase Contrast | Passed (rendered) | `charts-contrast` shot shows row separators; production reads the real contrast environment, the harness override only reaches the same path. |
| Distinct empty/not-ready/failure copy | Passed (rendered) | Separate shots for empty, not-ready, failed, failed-saved, rate-limited-saved, app-credentials, needs-sign-in, no-connection and Libre fallback. |
| Saved rows after failed refresh | Passed (AX) | Interactive failed-saved refresh kept rows and `Saved 2 hr ago`. |
| No text field in the takeover | Passed (AX) | The expanded surface contains buttons, menus and static text only; the only text field is the harness search outside the surface. |
| Custom → Settings handoff | Not passed (host) | Harness Custom press was a no-op because the harness refuses `openSettingsPage`; `settings-charts.png` shows the destination page. The real Droppy Playground handoff was not run. |
| Browse-only keyboard takeover | Unpassed (known gap) | The takeover remains pointer-and-VoiceOver only; no keyboard path is claimed. |
| Audible VoiceOver speech | Unpassed / blocked | Enabling VoiceOver or changing macOS accessibility settings was outside this run's authorization; no speech was captured. AX labels above are not audible evidence. |

## Runtime isolation

- Existing composition tests prove held/failing Last.fm and ListenBrainz chart work does not block capture, History or delivery; local aggregation also yields and does not block.
- The new failing-transport test proves the same with chart requests that fail rather than hang, for both service kinds, while delivery still succeeds.
- The new runtime-cycle test proves repeated `start`/`stop` cycles leave no late publisher, cache write or freshness wake, and a post-deactivation playback sample changes nothing.
- `charts-loading` and `charts-failed` show the playing strip remains current beside the chart state; the gate report for each is clean.

## Evidence classes and limits

| Class | Result | Evidence |
| --- | --- | --- |
| Harness output | Run | 29 fixture reports, selected PNGs, Reduce Motion log line, interactive AX readouts. |
| Composition tests | Run | 607 tests / 92 suites at the gate head; 90 chart tests / 4 chart suites. These do not prove UI or runtime behaviour. |
| Real host load | **Not passed** | The droplet was not installed outside the repository; the launch brief prohibits that. Harness shots are not a Playground load. |
| Live service qualification | **Not passed** | No live credentials, production writes or live Last.fm/ListenBrainz/Libre.fm calls were used. |
| Audible VoiceOver | **Not passed / blocked** | No microphone audio and no accessibility-setting change; AX-tree inspection only. |

No version bump, Store submission, credential change, capability change or dependency was added. `droplet.json`, licensing files and Tracklog branding are unchanged. The test target remains outside the submitted droplet package.

## Questions for the owner

1. **Real Playground load and Custom handoff.** Run:
   ```sh
   DEST="$HOME/Library/Application Support/Droppy Playground/Droplets/tracklog"
   STAGING="$DEST/Tracklog.droplet.new"
   if [ ! -d tracklog/.build/Tracklog.droplet ]; then
       echo "Tracklog.droplet is missing; run droppykit build first" >&2
       exit 1
   fi
   mkdir -p "$DEST"
   rm -rf "$STAGING"
   cp -R tracklog/.build/Tracklog.droplet "$STAGING"
   rm -rf "$DEST/Tracklog.droplet"
   mv "$STAGING" "$DEST/Tracklog.droplet"
   open -a "Droppy Playground"
   ```
   This verifies the build first, stages a complete copy, and only then replaces the bundle; a missing build or failed copy leaves the installed bundle in place. The sibling `Container` directory is untouched. The staged replacement was proven against a scratch Playground layout under the ignored `.scratch` path: `diff -r` printed nothing and exited 0, and `Container/sub/keep.txt` survived (`docs/reports/issue-80/install-proof.txt`). Confirm the Store row reports the bundle loaded, open Charts, press Custom, and confirm the takeover dismisses and the Charts Settings page opens. This was outside the repository/permission limit.
2. **Live service smoke.** In Playground with the owner's test accounts, link Last.fm, ListenBrainz and Libre.fm, play one test track past the minimum duration, and confirm Last.fm recent tracks, ListenBrainz listens and Libre.fm scrobbles. No live credentials or production writes were used here.
3. **Audible VoiceOver.** With VoiceOver enabled by the owner, run the Charts states and follow `docs/accessibility/voiceover-checklist.md`. For example:
   ```sh
   cd tracklog
   TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_CHARTS=normal TRACKLOG_HARNESS_SECTION=charts droppykit run
   ```
   Then repeat with `TRACKLOG_HARNESS_CHARTS=local` and `TRACKLOG_HARNESS_CHARTS=failed-saved` (the fixture value is `local`; `charts-local` is only the shot directory name). This run did not change an OS accessibility setting or approve a prompt.
