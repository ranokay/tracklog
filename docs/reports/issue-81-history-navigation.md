# Issue #81 History navigation — worker report

- Base: `6468f3a71f0edc88e0aee214a30fd4b92b33dab3` (`fix: qualify core charts (#111)`)
- Branch: `feat/history-navigation-81`
- State: implementation, tests, harness fixtures and documentation. The receipt-backed gate passed; the Gate section records the final receipt and head.
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
its own captured processed metadata. Count and first-listened date come from a
Swift-filtered full scan on the dedicated read connection over the whole local
history, independent of the loaded History page, the current connection and
delivery targets.

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

### Cover fill across page reads

A page read can start before `attachArtwork` and finish after it. The artwork
task used to fill only the already visible row; a later page apply then
overwrote it with the stale `artwork_hash == nil`, and nothing filled it again
that session. The runtime now also records every cover it resolves by raw
track identity, and every page apply (feed first page, jump, reload, older
page, newer page and both track-history page assignments) fills a nil hash
from that known set before publishing. A stale page can no longer erase a
cover in the running app. `aStalePageCannotEraseAKnownCover` forces the
ordering with a real store whose pages strip the hash and fails without this
merge.

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
- `CaptureRuntime+Artwork.swift`: session cover map and the stale-page merge.
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
focused suite is 19 tests in four suites.

| Test | Closes |
| --- | --- |
| `aJumpStartsAtTheFirstListenAndPagesBothWays` | 250-row jump, 121-row older page set, 128 newer rows, no duplicate/skip, anchor retained, normal mode restored. |
| `aMidnightJumpStartsAtTheFirstListenOfTheNewDay` | Local day boundary at 23:59:59 / 00:00:00; same-second request. |
| `timestampTiesCrossNewerPagesExactlyOnce` | Ties at the newer page boundary, stored `(started_at, id)` order, 12 rows loaded once. |
| `aMissingDayNamesTheDayAndShowsTheNextListen` | Empty day, after-newest, before-oldest notices. |
| `anEmptyHistoryShowsNoJumpNotice` | Empty database has the ordinary empty state. |
| `aCaptureDoesNotMoveAJumpedWindow` | Capture while browsing older history keeps the window; Newest restores the live top. |
| `aFailedJumpKeepsTheLoadedFeed` | A failed jump read leaves the feed, reports history failure and keeps the one-shot request for the next open. |
| `aPendingJumpSurvivesARefusedPresentationAndConsumesOnce` | Stopped runtime retains; started runtime consumes once; Newest clears. |
| `aPendingJumpSurvivesANavigationResetButNotARestart` | Refused/interrupted presentation retention; restart clears. |
| `trackHistoryShowsFullCountFirstListenAndPagesIndependently` | 150-track listens interleaved with 50 others; 50-row pages, full count, first date, feed untouched. |
| `trackHistoryUsesTheSharedTracksChartKey` | Two albums, two players, two raw spellings merged by a real simple edit, non-ASCII case, zero delivery targets; count equals the local `.tracks` chart item. |
| `aBlankArtistHasItsOwnTitleOnlyHistory` | Title-only key and no Tracks chart item. |
| `trackHistoryIgnoresDeliveryTargetsAndTheCurrentConnection` | Two-target listens count once; scripted transport makes no service read; current connection change leaves the view unchanged. |
| `aTrackReadFailureStaysInTheTrackViewAndCaptureContinues` | Scoped failure, feed/global failures untouched, capture persists, retry recovers. |
| `aCaptureWhileTrackHistoryIsOpenAppearsOnReload` | Snapshot semantics; reload has the new count, unchanged first date, no duplicate. |
| `trackHistorySurvivesRelaunchAndRestartClearsNavigation` | Reopened SQLite has the same count/first/rows; stop clears track/jump/pending. |
| `aCancelledLoadMoreLeavesTheViewReadyToRetry` | A load-more cancelled mid-scan clears `isLoading`; the retry uses the same cursor with no skipped or duplicate row. |
| `aPickerMinuteStartIgnoresHiddenSeconds` | A picked minute carrying 37 hidden seconds positions at the 00:00:10 listen; the raw second value skips it. |
| `aHeldTrackHistoryScanDoesNotBlockCapture` | Held read connection at row 64; capture still persists and now playing advances; reload sees the new row. |
| `aStalePageCannotEraseAKnownCover` | A real store whose pages strip the hash cannot erase a known cover on reload or append; fails before the merge. |

Ten consecutive full `swift test --package-path Tests` runs after the cover
merge: exit 0 on every run (1–10). Before the merge, the same new test failed
with `artworkHash == nil` on both the reload and append assertions.

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
  head `4e8f55eb2f88fbc698cde8d23e83358848ff6e96`.
  - Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261104T063610Z-989a5d085c8a.json`
  - Log: `/Users/ranokay/.local/state/agent-tools/gates/20261104T063610Z-989a5d085c8a.log`
  - Duration: 867.3 seconds.
  - The commits after this code head are documentation and evidence only; the
    source and test tree the gate checked is unchanged.
- `hk check --all`: SwiftFormat, SwiftLint and jactionlint clean; 0 SwiftLint violations in 287 files.
- `swift test --package-path Tests`: 627 tests in 96 suites; 51 media tests in 7 suites.
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
- Row menu: right-clicking a feed row or a track row opened the same
  `Deliveries`/`Feedback`/`Block`/`Copy metadata` menu; the feed row remained
  one `AXButton` with `AXPress`.

## Accessibility

The checklist is `docs/accessibility/voiceover-checklist.md`; readouts are in
`docs/reports/issue-81/ax/`. AX-tree inspection is not audible VoiceOver.

| Requirement | Result | Method |
| --- | --- | --- |
| Row is one element with the #26 label/value | Passed (AX) | `AXButton` `Heart of Glass, Blondie, Parallel Lines, 18:42`, value `delivered to ListenBrainz`. |
| Row has the button trait and a default action | Passed (AX) | Actions `AXPress`, `AXScrollToVisible`; pressing opened track history. |
| Actions menu is separate and does not overlap the row press | Passed (AX) | Row 831 × 52 ends at x 1459; menu 28 × 28 starts at x 1459. |
| Right-click opens the same row menu | Passed (AX) | Feed row and track row both opened Deliveries, Feedback (Unlove/Hate), Block and Copy metadata; the feed row stayed one `AXButton`. |
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

Pointer note: the row-wide `contextMenu` is attached to the outer row
container, not the button label. That keeps the row as one `AXButton` with
`AXPress` while right-click still opens the same `Actions for <title>` menu
(delivery detail, love/hate, block and copy).

## Evidence classes and limits

| Class | Result | Evidence |
| --- | --- | --- |
| Composition tests | Run | 627 tests / 96 suites after the focused additions. These do not prove UI or runtime behaviour. |
| Harness output | Run | Empty, large, track, missing-art, jump, track-error, feed-error, refusal and Settings shots; interactive AX readouts. |
| Real host load | **Not passed** | The droplet was not installed in Droppy Playground; no changes outside the repository. |
| Live service qualification | **Not passed** | No live credentials or production writes; track history reads made no service request. |
| Audible VoiceOver | **Not passed / blocked** | AX-tree inspection only. |

No version bump, Store submission, credential change, capability change,
dependency or schema version change was added. `droplet.json`, licensing and
Tracklog branding are unchanged. Tests remain in the sibling `Tests` package.

## Questions for the owner

1. **Track identity.** The supervisor set the definition from spec #76's chart
   grouping rule: `Identity.joined([processed.title, processed.artist])`,
   shared with `LocalChartAggregator` `.tracks`, not raw `track_identity`
   (which includes album and album artist and raw spellings) and not feedback
   identity. This makes one displayed track agree with the local Tracks chart;
   a blank artist gets a title-only history. Please confirm this remains the
   intended identity.
2. **Date-jump and missing-date rules.** #81 left the exact positioning open.
   This change defines: first start instant at or after the chosen minute;
   empty day shows the next listen with a notice; after-newest shows the
   newest feed; before-oldest shows the oldest/next listen; empty history has
   no jump notice. Please confirm these are the intended product rules.
3. **Retained pending jump.** This differs from the approved plan's
   "dismissal clears it": the pending one-shot jump is retained through a
   refused or interrupted presentation and through dismissal, consumed once
   when applied, and cleared on restart. Retention was required because the
   Settings handoff re-creates the takeover view; clearing on the old view's
   disappearance lost the jump before the new view could apply it.
4. **Cover fill across page reads.** A stale page could overwrite a cover the
   artwork task filled while the page was being read, leaving the row
   cover-less for the session. The fix records resolved covers by raw track
   identity and merges them into every page apply;
   `aStalePageCannotEraseAKnownCover` forces the ordering and fails before the
   merge. The widened artwork wait and suite serialization are reverted. Please
   confirm the session-map approach is the intended behaviour (a cover resolved
   during a read is authoritative for that identity until a later cover
   replaces it).

The real Playground handoff, live-service smoke and audible VoiceOver remain
the same owner-run checks recorded for issue #80.
