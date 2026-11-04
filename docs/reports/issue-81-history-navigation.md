# Issue #81 History navigation — worker report

- Base: `6468f3a71f0edc88e0aee214a30fd4b92b33dab3` (`fix: qualify core charts (#111)`)
- Branch: `feat/history-navigation-81`
- State: implementation, tests, harness fixtures and documentation. Gate receipt pending in the section below.
- Scope: History date jump, the jumped window's newer/older paging, one track's full local history, and the Settings handoff. Part of #76; it does not close #76 and makes no Store or milestone-complete claim.

## Contract

Issue #81 selects ticket 5 of the approved breakdown. The signed matrix marks
`NP-04` (time jump) and `NP-07` (track history) as `later`; this ticket builds
those two bounded rows now and does not reopen the rest of the `later` pass.
Nothing else from the matrix is pulled in.

### Track-history identity

One track is every stored listen whose processed values produce the same
`LocalTrackIdentity.key(title:artist:)`:

```swift
Identity.joined([processed.title, processed.artist])
```

This is the same key `LocalChartAggregator` uses for `.tracks`. The key was
extracted into `LocalTrackIdentity` in `LocalChartGrouping.swift` and both
surfaces call it, so they cannot diverge. The chart additionally omits rows
without both title and artist (`chartKey`); track history still gives a
blank-artist row its own title-only history. For every row the Tracks chart
contains, the chart count and the track-history count are the same.

The identity is deliberately **not** the stored raw `track_identity` column:
that includes album and album artist and keeps the player's raw spelling, so
one displayed track would split across albums, players and simple edits (and
would disagree with the Tracks chart). It is also **not** feedback identity
(`processed.identity`, which includes album and album artist). The opening
row supplies the header's displayed title, artist and album; every row keeps
its own captured processed metadata. Count and first-listened date are SQL
aggregates over the whole local history, independent of the loaded History
page, the current connection and delivery targets.

### Date-jump positioning

A jump to local date/time `D` opens a fresh window whose newest row is the
last stored listen at the earliest start instant `>= D`, ordered by
`(started_at ASC, id DESC)`, so every listen sharing that start second is
included. Rows older than that position follow through the existing keyset
paging. Rows above the position are not loaded. A jumped window pages toward
newer rows with `Show newer listens`; each press prepends the immediately
newer page by `(started_at, id)` keyset, keeps the existing rows, and returns
to normal top mode when the newest stored listen is reached.

Older and newer availability are **one-row keyset existence queries**
(`hasOlderListen(than:)`, `hasNewerListen(than:)`) anchored on the window's
oldest/newest row. Neither is derived from `total - loaded`, which was wrong
for a jumped window (it reported more forever once the oldest row was
reached).

### Missing-date behaviour

- The chosen local day has no listens but a later listen exists: open at the
  next listen and say `No listens on <day>. Showing the next listen.`
- `D` is newer than every stored listen: open the newest page and say
  `No listens after <date>. Showing the newest listens.`
- Empty database: the ordinary `Nothing played yet` state, no jump notice.
- Every positioned window says `Showing from <top row date>` and offers
  `Newest`.

A jump is one-shot. It is set by Settings, consumed when the runtime applies
it, and retained across a refused or interrupted presentation so the next
open retries it. Deactivation/restart clears it. Dismissal deliberately does
not clear it: the takeover is re-created when Settings hands back, and
clearing on the old view's disappearance would lose the request. Explicit
`Newest` discards it.

### Track view state

The open track view is a **snapshot**: it reads once when opened and refreshes
only on reopen or `Try again`; it does not live-update on each capture, so
capture never waits for it. A listen captured while it is open persists, and
the next reload shows the new full count and first-listened date with no
duplicate row in the already loaded page. A track-read failure is scoped to
`state.trackHistory.failure`: it does not set `state.failure`, does not
replace the feed, and capture continues.

## Implementation

- `LocalChartGrouping.swift`: `LocalTrackIdentity` shared key; the Tracks
  aggregator now calls it.
- `HistoryNavigation.swift`: position, notice, `HistoryNavigationStore`,
  `TrackHistoryStore`, `TrackHistory`.
- `SQLiteListenStore+HistoryNavigation.swift`: jump/keyset queries and
  SQLite's `TrackHistoryStore` conformance. No migration; `schemaVersion`
  stays 10. The date-jump index already exists (`listens_started_at`).
- `ChartReadConnection.swift`: track-history summary (full scan) and page
  (stops at its limit) on the dedicated read-only connection, filtered in
  Swift by the shared key. No SQL `lower()` and no stored derived key.
- `CaptureRuntime+History.swift`: jump, newer/older paging, exact has-more,
  anchored capture reload, one-shot request and in-flight guard.
- `CaptureRuntime+HistoryNotice.swift`: the small position/missing-day notice helpers.
- `CaptureRuntime+TrackHistory.swift`: open/reload/load-more/close, scoped
  failure.
- `TracklogAppState.swift`: published track/jump/pending/settings state.
- Views: `TracklogHistory.swift`, `TracklogHistoryComponents.swift`,
  `TracklogHistoryBars.swift`, `TracklogTrackHistory.swift`,
  `TracklogHistorySettingsPage.swift`, `TracklogNowPlayingStrip.swift`.
- Settings: `history` page, root link and search entry.
- Harness: `HarnessDemo+History.swift` with `empty`, `large`, `track`,
  `track-missing-artwork`, `jump`, `track-error`, `feed-error` and
  `settings-refused` fixtures.
- Gate: `scripts/gate.sh` runs the new History states and the History
  Settings page.

## Composition proof

New tests use real temporary SQLite, `FakeClock`, replayed playback, the
scripted ListenBrainz transport and the dedicated read connection. The
focused suite is 17 tests in three suites.

| Test | Closes |
| --- | --- |
| `aJumpStartsAtTheFirstListenAndPagesBothWays` | 250-row jump, 121-row older page set, 128 newer rows, no duplicate/skip, anchor retained, normal mode restored. |
| `aMidnightJumpStartsAtTheFirstListenOfTheNewDay` | Local day boundary at 23:59:59 / 00:00:00; same-second request. |
| `timestampTiesCrossNewerPagesExactlyOnce` | Ties at the newer page boundary, stored `(started_at, id)` order, 12 rows loaded once. |
| `aMissingDayNamesTheDayAndShowsTheNextListen` | Empty day, after-newest, before-oldest notices. |
| `anEmptyHistoryShowsNoJumpNotice` | Empty database has the ordinary empty state. |
| `aCaptureDoesNotMoveAJumpedWindow` | Capture while browsing older history keeps the window; Newest restores the live top. |
| `aFailedJumpKeepsTheLoadedFeed` | A failed jump read leaves the feed and reports history failure. |
| `aPendingJumpSurvivesARefusedPresentationAndConsumesOnce` | Stopped runtime retains; started runtime consumes once; Newest clears. |
| `aPendingJumpSurvivesANavigationResetButNotARestart` | Refused/interrupted presentation retention; restart clears. |
| `trackHistoryShowsFullCountFirstListenAndPagesIndependently` | 150-track listens interleaved with 50 others; 50-row pages, full count, first date, feed untouched. |
| `trackHistoryUsesTheSharedTracksChartKey` | Two albums, two players, two raw spellings merged by a real simple edit, non-ASCII case, zero delivery targets; count equals the local `.tracks` chart item. |
| `aBlankArtistHasItsOwnTitleOnlyHistory` | Title-only key and no Tracks chart item. |
| `trackHistoryIgnoresDeliveryTargetsAndTheCurrentConnection` | Two-target listens count once; scripted transport makes no service read; current connection change leaves the view unchanged. |
| `aTrackReadFailureStaysInTheTrackViewAndCaptureContinues` | Scoped failure, feed/global failures untouched, capture persists, retry recovers. |
| `aCaptureWhileTrackHistoryIsOpenAppearsOnReload` | Snapshot semantics; reload has the new count, unchanged first date, no duplicate. |
| `trackHistorySurvivesRelaunchAndRestartClearsNavigation` | Reopened SQLite has the same count/first/rows; stop clears track/jump/pending. |
| `aHeldTrackHistoryScanDoesNotBlockCapture` | Held read connection at row 64; capture still persists and now playing advances; reload sees the new row. |

### Observable acceptance map (#81)

| # | Evidence |
| --- | --- |
| 1 | `History` Settings page (`history-settings.png`), Settings → History AX handoff, `Jump to date` refusal bar, no text field in the takeover. |
| 2 | Contract section above: jump position, missing dates, shared track key, newer/older existence queries, snapshot failure scope. |
| 3 | `trackHistoryShowsFullCountFirstListenAndPagesIndependently`, `trackHistoryIgnoresDeliveryTargetsAndTheCurrentConnection`, `trackHistoryUsesTheSharedTracksChartKey`; track view header `75 listens` / `First listened …` in the harness. |
| 4 | Empty, large, missing-art, feed-error and track-error shots; failure-scope and held-read tests; pinned strip present in every shot. |
| 5 | The focused suite above; gate `swift test`. |
| 6 | AX walk readouts and `harness-window.png`; Views/VoiceOver checklist updated. Real Playground and audible VoiceOver recorded as not passed. |
| 7 | Gate receipt below; new History states in `scripts/gate.sh`. |

## Gate

Command:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Result and receipt: exit `0`, frozen gate `true`, clean before and after, at
  head `c70fda0e258eb24fee415aa6fd931a3f44bcb189`.
  - Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261104T053334Z-82a4394e0aeb.json`
  - Log: `/Users/ranokay/.local/state/agent-tools/gates/20261104T053334Z-82a4394e0aeb.log`
  - Duration: 850.9 seconds.
- `hk check --all`: SwiftFormat, SwiftLint and jactionlint clean; 0 SwiftLint violations in 285 files.
- `swift test --package-path Tests`: 624 tests in 95 suites; 51 media tests in 7 suites.
- `droppykit build`: universal droplet, x86_64 + arm64.
- `droppykit validate`: `Ready to submit`.
- Every harness report `verdict: ok`, `problems: []`, active activation, every declared surface provided.
- New shot states: `history-empty`, `history-large`, `history-track`,
  `history-track-missing-artwork`, `history-jump`, `history-track-error`,
  `history-feed-error`, `history-settings-refused`, `history-settings`.

Selected images are in `docs/reports/issue-81/`; each History image is the
notch panel cropped from that state's `expanded-surface.png` (the same
right-edge shot-viewport limit recorded for issue #80). The checked reports
are in `docs/reports/issue-81/reports/`.

## Native observations

Harness fixtures, playing unless noted:

- Empty: `0 listens`, `Nothing played yet`, `Play something to start your
  history.`; pinned strip still shows the playing track.
- Large: `256 listens`; feed renders; no layout break.
- Track: `75 listens`, heading `Heart of Glass`, `Blondie — Parallel Lines`,
  `First listened 19 October 2026`, dated rows and the pinned strip.
- Track missing artwork: 45 `Blue Monday` rows with the deterministic neutral
  sleeve; count and first date still correct.
- Jump: `Showing from 3 Nov 2026 at 21:18`, `Show newer listens`, `Newest`;
  rows start at the first 3 November listen; pinned strip present. Pressing
  `Show newer listens` prepended the newer rows and ended in the regular feed.
- Track error: `Track history unavailable`, `Try again`, `Back to History`;
  the feed is not replaced and the pinned strip stays.
- Feed error: `History unavailable`; pinned strip stays.
- Settings History: one `Date and time` picker and `Show in History`; typing a
  date and pressing Show in History opened History at `3 Nov 2026 at 21:18`.
- Refusal: pressing `Jump to date` in the harness showed
  `Settings could not be opened here. Open Tracklog's History settings to
  choose a date.` with Dismiss.

## Accessibility

The checklist is `docs/accessibility/voiceover-checklist.md`; readouts are in
`docs/reports/issue-81/ax/`. AX-tree inspection is not audible VoiceOver.

| Requirement | Result | Method |
| --- | --- | --- |
| Row is one element with the #26 label/value | Passed (AX) | `AXButton` `Heart of Glass, Blondie, Parallel Lines, 18:42`, value `delivered to ListenBrainz`. |
| Row has the button trait and a default action | Passed (AX) | Actions `AXPress`, `AXScrollToVisible`; pressing opened track history. |
| Actions menu is separate and does not overlap the row press | Passed (AX) | Row 831 × 52 ends at x 1459; menu 28 × 28 starts at x 1459. |
| Day headers are headings | Passed (AX) | `AXHeading (Tuesday, 3 November 2026, 2 listens)`. |
| Empty states are read | Passed (AX) | `Nothing played yet` / `Play something to start your history.` |
| Track header and rows read | Passed (AX) | Heading, `75 listens`, `First listened …`, dated row labels/values. |
| Settings date entry and handoff | Passed (harness) | Date typed, Show in History → `Showing from 3 Nov 2026 at 21:18`. |
| Settings refusal is visible | Passed (AX) | Inline bar with Dismiss; takeover stays up. |
| 24-point targets | Passed (AX) | `Jump to date` 125 × 31, Back 85 × 31, Show newer 138 × 31, date area 139.5 × 22, Show in History 116.5 × 31, row menu 28 × 28. |
| No text field in the takeover | Passed (AX) | Only buttons, menus and static text in the expanded surface. |
| Real host handoff | Not passed (host) | The harness refuses `openSettingsPage`; the real Droppy Playground flow was not run (installing outside the repository is outside this run's permission). |
| Browse-only keyboard takeover | Unpassed (known gap) | Pointer-and-VoiceOver only; no keyboard path claimed. |
| Audible VoiceOver speech | Unpassed / blocked | No microphone audio and no accessibility-setting change; AX labels only. |

Pointer note: the row-wide right-click `contextMenu` was removed because it
made SwiftUI expose the row as `AXUnknown` with `AXShowMenu` instead of a
button with `AXPress`. The visible `Actions for <title>` menu remains the one
row menu and still holds delivery detail, love/hate, block and copy.

## Evidence classes and limits

| Class | Result | Evidence |
| --- | --- | --- |
| Composition tests | Run | 624 tests / 95 suites after the focused additions. These do not prove UI or runtime behaviour. |
| Harness output | Run | Empty, large, track, missing-art, jump, track-error, feed-error, refusal and Settings shots; interactive AX readouts. |
| Real host load | **Not passed** | The droplet was not installed in Droppy Playground; no changes outside the repository. |
| Live service qualification | **Not passed** | No live credentials or production writes; track history reads made no service request. |
| Audible VoiceOver | **Not passed / blocked** | AX-tree inspection only. |

No version bump, Store submission, credential change, capability change,
dependency or schema version change was added. `droplet.json`, licensing and
Tracklog branding are unchanged. Tests remain in the sibling `Tests` package.

## Questions for the owner

None blocking. The real Playground handoff, live-service smoke and audible
VoiceOver remain the same owner-run checks recorded for issue #80.
