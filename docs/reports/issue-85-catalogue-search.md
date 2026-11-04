# Issue #85 Catalogue search and search-and-play — worker report

- Base: `aa6bdeb257b24dd94b33b8a5f8295be5affff908` (`feat: build history navigation (#112)`)
- Branch: `feat/catalogue-search-85`
- Code head: `1df390c8189f8e7e67051a59bd27795c12eb86fb` (the gate receipt below is for this head; later commits are documentation and evidence only)
- State: implementation, composition tests, harness fixtures and this report. The receipt-backed gate passed; the Gate section records the receipt and clean-tree state.
- Scope: ticket 9 of the approved breakdown. This report does not close #76 and makes no Store or milestone-complete claim.

## Contract

The owner confirmed the palette and result interactions in [#85 comment 6625541675](https://github.com/ranokay/tracklog/issues/85#issuecomment-6625541675). This implementation follows that contract:

- **Playback URL schemes.** Only `http` and `https` are rendered and opened. Every play goes through `host.workspace.open`; `NSWorkspace` is never used to bypass the host. The Settings page refuses any other scheme.
- **One surface at a time.** Opening the palette from the takeover dismisses the takeover first, using the same `dismissTakeoverForSettings` path Settings uses. Opening Settings from the palette closes the palette first. A second summon closes the panel. Clicking outside closes it. One `close(endingSearch:)` funnel removes the key monitor and observers, ends the search session, calls `DroppyPanelActivation.finish()`, orders the panel out and clears the controller; `deactivate()` uses the same funnel.
- **Opening paths.** A search button in the takeover's section bar, an item in the shelf overflow menu (palette opener only), and a rebindable `global-shortcuts` shortcut with no default chord. The panel is a droplet-owned 680 × 560 `NSPanel` clamped to the screen's visible frame, on `DroppyPanelSurface`, activated with `DroppyPanelActivation`. The `launcher` capability is not used.
- **Loved results.** The Loved group filters the current connection's loved tracks when that connection is Last.fm, reading at most 5 pages of 200 per query. The group is labelled with the account (`Loved by <account>`) and says `first 1,000 checked` only when more pages remained. Otherwise it explains why the group is unavailable. It never appears as an empty group, and a user connection is not needed for catalogue reads.
- **Keyboard and groups.** Groups are Artists, Albums, Tracks and Loved, five rows visible, collapsible, each with a Show more row. ↑/↓ move through group headers, result rows and Show more rows; Return toggles a header, expands Show more, or runs the primary action on a row. Esc clears the text first and closes only when the text is empty. The search field keeps focus; selection is announced. Collapsed and expanded state resets on every open.
- **Primary action.** Search and play when a template is set, otherwise the row's Last.fm page. Command-Return always opens Last.fm. A row with no valid service page offers no Last.fm action and reports that inline.
- **Query lifecycle.** 300 ms debounce, at least 2 characters, one request per search group, at most four groups in flight, 10 results per group, a 15-second group deadline. Each group fails separately. A new query invalidates the old generation; late replies cannot replace current results. Closing or deactivating stops all owned work; nothing is cached.
- **Template.** `{query}` exactly once, only in the path, query or fragment, never in the host or userinfo; an http/https URL with a host; no userinfo; RFC 3986 unreserved encoding (a space is `%20`); substitution is one pass, so a literal `{query}` in typed text stays data. No default is shipped.
- **Play surfaces.** Palette results, History rows, track history, chart rows and the now-playing strip menu. With no template, Play opens the Search settings page. The shelf overflow menu deliberately has no Play item.
- **Input methods and accessibility.** While the field editor has marked text, Return, arrows and Esc go to the field editor and run no palette action. Because focus stays in the field, VoiceOver selection and group-state changes are posted as `NSAccessibility` announcements; group headers expose their state and count as accessibility values.
- **Isolation.** Catalogue requests always target `https://ws.audioscrobbler.com/2.0/` with no `sk`, whatever the current connection is. Search never touches the listen store, capture or delivery.

## Implementation

Core:

- `SearchTemplate.swift`: validation, one-pass rendering, RFC 3986 percent encoding.
- `SearchPlayback.swift`: `PlaybackOutcome` and the injected host opener.
- `CatalogueSearch.swift`: group kinds, rows, phases, failures and shared query builders.
- `CatalogueSearchReadModel.swift`: debounce, generation invalidation, per-group tasks, timeout race, loved paging and filtering.
- `LastFMSearch.swift`: `artist.search`, `album.search`, `track.search`, `user.getlovedtracks`; adapter conformance; https URL normalisation.
- `LastFMPayloads.swift`: search and loved payloads, array-or-object lists.
- `PaletteKeyRouter.swift`: key routing including the marked-text pass-through.
- `CaptureRuntime+Search.swift`, `TracklogAppState`, `CaptureRuntime`, `CaptureRuntime+Lifecycle`, `CaptureRuntime+Connections`: model ownership, lifecycle, template persistence and published state.
- `SettingsExport.swift`, `CaptureRuntime+Export.swift`: additive optional `search_template`.

Droplet:

- `TracklogSearchPalette.swift`, `TracklogSearchPaletteController.swift`: the panel, field, groups, rows, keyboard, announcements, close funnel and accessibility.
- `TracklogSearchSettingsPage.swift`: the URL template page with validation and examples.
- `TracklogDroplet+Search.swift`: opening, playing, Settings handoffs, template save/remove and harness helpers.
- `TracklogTakeover.swift`: section-bar search button and refusal bar.
- `TracklogHistoryBars.swift`: `SearchRefusalBar`.
- `TracklogActionMenu.swift`, `TracklogWidget+Controls.swift`, `TracklogNowPlayingStrip.swift`: palette opener in the shelf overflow; Play only in the strip menu.
- `TracklogHistoryComponents.swift`, `TracklogChartsView.swift`: Play menu items, custom accessibility actions and the per-type chart queries.
- `TracklogSettings.swift`, `TracklogDroplet+Settings.swift`: root link and Settings search entry.
- `droplet.json`: `global-shortcuts` only.
- `HarnessDemo+Palette.swift`, `HarnessDemo.swift`, `TracklogDroplet+Composition.swift`: deterministic fixtures and harness wiring.

## Composition proof

The suite uses the real `LastFMAdapter`/`LastFMClient` over a controlled routing transport, real temporary SQLite for connections, `FakeClock` for the debounce, and injected opener/settings closures for play. It asserts outbound behaviour rather than private helpers.

| Test | Closes |
| --- | --- |
| `catalogueReadsNeedAppCredentialsButNoUserConnection` | No Last.fm connection; three search groups ready, Loved unavailable; real requests carry the app key, no `sk`, and the Last.fm endpoint. |
| `missingAppCredentialsShowTheSettingsRemedyWithoutARequest` | Every group fails with `.appCredentials(.missing)`, `needsSettings`, no request at all. |
| `rejectedAppCredentialsNameTheProblemAndLeaveOtherGroupsAlone` | Code 10 fails only Artists; other groups stay ready; the app-key remedy is named. |
| `fourGroupsRunAtOnceWithTenResultsAndBoundedPages` | Four groups in flight, 10 result limit, loved page size 200, 15-second default asserted. |
| `theDebounceWaitsThreeHundredMillisecondsAndRequiresTwoCharacters` | One character sends nothing; the second waits 300 ms; no request before the clock advance. |
| `aNewQueryCancelsTheOldAndIgnoresLateReplies` | Held old query; new query settles; late old replies never replace it. |
| `closingAndDeactivatingStopOwnedWork` | End session and deactivate leave idle groups, no results after released requests. |
| `oneGroupFailureLeavesTheOtherGroupsIntact` | A transport failure fails only Artists. |
| `aTimedOutGroupFailsWithoutHoldingTheOthers` | A held group times out while the others finish; the race returns without waiting for the held request. |
| `lovedReadsAtMostFivePagesAndSaysWhenTheLimitWasReached` | Five pages of 200, ten matching rows, account detail and `first 1,000 checked`. |
| `lovedReportsTheLimitEvenWithFewerThanTenMatches` | Five pages with only one match each still say `first 1,000 checked`; the cap is decided by pages read, not by reaching ten rows. |
| `lovedStopsWhenTheLastPageIsReached` | Two pages, no limit text. |
| `lovedExplainsWhenTheCurrentConnectionIsNotLastFM` | ListenBrainz current: unavailable explanation, no loved request. |
| `lastFMRequestsKeepTheirEndpointAndSessionKeyForLibreFMAndListenBrainz` | Endpoint and no `sk` under both other current connections. |
| `aHeldSearchDoesNotBlockCaptureOrDelivery` | Held search; a listen persists and its delivery reaches delivered before the search is released. |
| `aSetTemplatePlaysTheEncodedRowQuery`, `withoutATemplateThePaletteRowOpensItsLastFMPage`, `withoutATemplateTheStandalonePlayActionOpensSearchSettings` | Both primary behaviours and the Settings remedy. |
| `aRefusedLaunchIsReportedAndNotSwallowed`, `aRefusedLastFMPageIsReportedWithoutBlamingTheTemplate`, `aRefusedSettingsHandoffIsReported` | The controlled opener reports refused template launches, refused Last.fm page opens and refused Settings handoffs separately. |
| `aRowWithoutAValidPageOffersNoLastFMAction` | No Last.fm action for a row whose service URL is invalid. |
| `schemelessAndHTTPLinksBecomeHTTPS`, `otherSchemesHostlessAndUserInfoValuesAreRejected` | Service links normalise to https; other schemes, hostless values and userinfo are rejected. |
| `aQueryIsEncodedWithRFC3986UnreservedCharacters`, `substitutionIsOnePassSoTypedPlaceholderTextStaysData` | Encoding and one-pass substitution. |
| template validation tests | Exactly one placeholder; http/https; host; no userinfo; placeholder only in path/query/fragment; unparseable template. |
| palette key routing tests | Marked-text pass-through for Return, arrows and Esc; plain and Command-Return. |
| settings export tests | Old export without the template still decodes; a template round-trips; runtime export carries the saved value. |
| `savingPublishesAndPersistsOnlyAValidTemplate` | Valid save publishes/persists; invalid save changes nothing. |

Full suite: **672 tests in 102 suites**, exit `0`.

## Gate

Command:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Result and receipt: exit `0`, frozen gate `true`, clean before and after, at head `1df390c8189f8e7e67051a59bd27795c12eb86fb`.
  - Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261104T095446Z-fd81afedfe6b.json`
  - Log: `/Users/ranokay/.local/state/agent-tools/gates/20261104T095446Z-fd81afedfe6b.log`
  - Duration: 1082.8 seconds.
  - `git_before` and `git_after` both report head `1df390c…`, empty porcelain status and the same tracked-content hash.
- `hk check --all`: SwiftFormat, SwiftLint and jactionlint clean; 0 SwiftLint violations in 306 files.
- `swift test --package-path Tests`: 672 tests in 102 suites; 51 media tests in 7 suites.
- `droppykit build`: universal droplet, x86_64 + arm64, `kit.minAPI` 1.19.0 covers every call.
- `droppykit validate`: `Ready to submit`.
- New harness states: `search-refusal` and `search-settings`; every existing expanded surface now shows the section-bar search button.
- Artifacts: `docs/reports/issue-85/search-settings.png`, `search-refusal.png`, `search-settings.json` and `search-refusal.json` under `docs/reports/issue-85/reports/`; the gate's charts surface is `charts-search-button.png`.

## Native observations

All palette evidence is from the running `TracklogHarness`; the panel is a separate droplet-owned `NSPanel`, so `droppykit run --shots` cannot capture it. The deterministic fixtures are listed in `HarnessDemo+Palette.swift` and were opened with `TRACKLOG_HARNESS_PALETTE=<fixture>`. Image names in this section and the evidence list are relative to `docs/reports/issue-85/`; the AX readouts are in `docs/reports/issue-85/ax/`.

| State | Fixture | Result |
| --- | --- | --- |
| Normal results | `normal` | Artists, Albums, Tracks and Loved; 5 rows each, Show more rows, account detail, no credentials banner. `palette-normal.png` |
| Loading | `loading` | Spinners at the source label and in every group; `Searching…`; `palette-loading.png` |
| Empty | `empty` | Each group says `No artists/albums/tracks match this search`; `palette-empty.png` |
| Failed group | `failed` | Artists failed with `The Last.fm catalogue could not be reached.` and Try again; other groups ready; `palette-failed-group.png` |
| Missing credentials | `credentials-missing` | Banner names the missing pair, Open Settings; every group fails with the Settings remedy; no request; `palette-credentials-missing.png` |
| Rejected credentials | `credentials-rejected` | Banner `Last.fm rejected the app key`; group failures name the same; `palette-credentials-rejected.png` |
| Long names | `long-names` | Titles truncate with an ellipsis; AX labels keep the full text; `palette-long-names.png` |
| Non-Latin text | `cjk` | Japanese query, artists, albums and tracks render; `palette-cjk.png` |
| Loved unavailable | `loved-unavailable` | `Loved results come from a Last.fm account. The current connection is ListenBrainz; choose a Last.fm connection in Charts.`; `palette-loved-unavailable.png` |
| Loved limit | `loved-limit` | `Loved by listener · first 1,000 checked`, ten rows; `palette-loved-limit-loved.png` |
| Failed launch | `failed-launch` with `TRACKLOG_HARNESS_OPEN_REFUSED=1` | Primary action refused; inline `Search and play could not be opened. Check the URL template in Search settings.`; `palette-failed-launch.png` |
| Takeover refusal bar | `TRACKLOG_HARNESS_PALETTE=refusal` | Gate shot `search-refusal`; `Search and play could not be opened. Check the URL template in Search settings.` with Dismiss. |
| Search Settings | `TRACKLOG_HARNESS_SETTINGS_PAGE=search` | Gate shot `search-settings`; URL template field, Save/Remove and the rules. |

Keyboard walk in the running harness:

- Field focused on open; Up/Down moved the highlight from Blondie through Blondie cover band while the field kept its caret and text.
- Return on Show more artists expanded the group to all ten; the selection moved to the first newly visible row. Return on the Artists header collapsed it; the header AX value changed to `Collapsed`.
- Esc with `blo` in the field cleared the text, kept the panel open and showed the empty prompt. Esc again closed the panel.
- A foreground click on the harness window (outside the panel) closed the panel.

Touch points:

- The takeover's section-bar search button is visible in every expanded-surface shot and opens the palette.
- History rows expose `AXButton` with an extra `search and play` action; the row menu includes the same item.
- The now-playing strip menu contains `Search and play this track` above the shared menu items; the shelf overflow menu contains only `Search and play…` and no Play item.
- Chart rows expose an `AXUnknown` labelled row with a `Search and play` custom action and a context menu; the Artists/Albums/Tracks query mapping is artist, `artist album`, and `artist title`.
- The now-playing strip's `More` menu starts with `Search and play this track`; screenshot `strip-overflow-menu.png`.
- The shelf overflow menu contains only `Search and play…` as its palette opener and no Play item; screenshot `shelf-overflow-menu.png`.

## Accessibility

The checklist is `docs/accessibility/voiceover-checklist.md`; it now has a Search palette section and a run-record row. AX readouts are under `docs/reports/issue-85/ax/`.

| Requirement | Result | Method |
| --- | --- | --- |
| Field keeps focus while arrows move | Passed (AX + screenshot) | The query text stayed highlighted; the selection highlight moved through rows. |
| Selection is announced | Implemented (not audibly verified) | `NSAccessibility.post(... .announcementRequested ...)` on the panel content view when selection moves and when a query settles. |
| Group state is announced | Implemented (not audibly verified) | One settled summary names every group's count, no-match, failed or unavailable state; group header values also carry state and count. |
| Group headers are reachable and toggle | Passed (AX) | `AXButton` values `Expanded. 10 results` / `Collapsed`; Return toggled. |
| Show more is reachable | Passed (AX) | `AXButton` `Show more artists` with value `10 results`; Return expanded. |
| Esc clears then closes | Passed (harness) | Text cleared first; second Esc removed the panel. |
| Marked input-method text | Passed (unit) | `PaletteKeyRouter` returns `passThrough` for Return, keypad Enter, arrows and Esc while marked text is present. A live IME run was not performed. |
| Credentials remedy | Passed (AX + screenshot) | Banner and group Settings buttons; no request for missing credentials. |
| Long and non-Latin names | Passed (AX + screenshot) | Full AX labels; one-line visual truncation. |
| Failed launch | Passed (AX + screenshot) | Inline notice; panel stays open. |
| Chart row Play | Passed (AX) | `AXUnknown` `Rank 1, Blondie, 42 plays` with `AXShowMenu` and a named `Search and play` action. |
| Strip and shelf menus | Passed (AX) | Strip `More` contains `Search and play this track`; shelf `More` contains `Search and play…` and no Play. |
| Takeover refusal bar | Passed (gate shot) | `search-refusal` shot and AX tree. |
| Audible VoiceOver | Not run | No VoiceOver session or microphone capture. |

## Evidence classes and limits

| Class | Result | Evidence |
| --- | --- | --- |
| Composition tests | Run | 672 tests / 102 suites; controlled transport, real adapter requests, SQLite and opener spies. |
| Harness output | Run | Gate `search-refusal`, `search-settings`, existing expanded-surface states; interactive palette states and screenshots. |
| Real host load | **Not run** | Installing into Droppy Playground writes outside this worktree; not permitted in this run. |
| Shortcut in Droppy's Shortcuts page | **Not run** | The shortcut is registered with `defaultShortcut: nil`; the real host page was not opened. |
| Live Last.fm service | **Not run** | Public Last.fm API documentation was read for `artist.search`, `album.search`, `track.search` and `user.getlovedtracks`; no live call was made. |
| Audible VoiceOver | **Not run** | AX-tree inspection and announcement code only. |

No new enrichment provider, package dependency, delivery routing change or database migration was added. The only manifest change is the `global-shortcuts` capability. The template is persisted in Droppy preferences as `playbackTemplate`; the settings export adds the optional `search_template` key and existing documents still decode. Credentials never enter logs, caches, exports or screenshots.
