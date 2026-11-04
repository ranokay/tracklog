# Issue #87 Loved browsing — worker report

- Base: started from `8fb73ff7db105c817cb65c54100886e84f57d0b5` (`feat: build catalogue search and search-and-play (#85)`).
- Branch: `feat/loved-list-current-connection`
- Code head: `d5bef8412b597d67459c3c2e3dfaf898cafc5f99` (the gate receipt below is for this head; later commits are documentation and evidence only).
- State: implementation, composition tests, harness fixtures and this report. The receipt-backed gate passed; the Gate section records the receipt and clean-tree state.
- Scope: ticket 11 of the approved breakdown. This report does not close #76 and makes no Store or milestone-complete claim.

## Contract

The signed matrix row is NP-05, "Loved list backed by the current connection" ([#12 comment](https://github.com/ranokay/tracklog/issues/12#issuecomment-6387789493)); the parent specification is [#76](https://github.com/ranokay/tracklog/issues/76). The contract was settled from the primary API documentation and the current code before implementation.

### Read operations and paging

| Service | Read | Paging | Auth | Current state vs events |
| --- | --- | --- | --- | --- |
| Last.fm | `user.getlovedtracks` (`page`, `limit`; `lovedtracks.track[].name/artist.name/mbid`, `@attr.page/totalPages`) | Page, 50 rows per page; next page while `page < totalPages` | Last.fm application pair only; no `sk`, no listener session | Currently-loved rows only. The returned date is the current love's timestamp, not a love/unlove event log; unloving removes the row. |
| Libre.fm / GNU FM | The same method at the connection's own `/2.0/` root (`GNU FM nixtape/2.0`, `UserXML::getLovedTracks`) | Page, 50 rows per page; `@attr.totalPages` | Compiled client key only; unsigned, no `sk`, no `api_sig` | Same current-state semantics (GNU FM `Loved_Tracks`; unlove removes the entry). |
| ListenBrainz | `GET /1/feedback/user/{user}/get-feedback?score=1&count=50&offset=…&metadata=true` | Raw feedback offset; offset advances by every returned feedback item, including entries this app cannot name | Token sent when available; the default read is public | Positive recording feedback only; `created` is the current feedback's timestamp. Reset removes it. |
| Custom ListenBrainz endpoint | Same standard path on `connection.endpoint` | Raw offset | Same | Same. A server answering 404/405/501 for the read is treated as not providing it, not as a transient failure. |
| Pleroma | None | — | — | No `ServiceKind` exists in this build (#97 owns additional service connections). The reader map still refuses any kind without a reader with the unavailable state. |

Two public, unauthenticated shape checks were made (no credentials): Libre.fm's `user.getlovedtracks` answered 200 with `lovedtracks.track[]`, `@attr.totalPages` and `date.uts`; ListenBrainz's `get-feedback` answered 200 with `feedback[]`, `total_count` and `track_metadata`. The account names and returned rows are not reproduced or committed. Every fixture, test and report row uses synthetic names (`listener`, `Example Artist`, `Example Track One`).

### Authentication and readiness

| Case | Read sent | Rows | Unlove | Remedy |
| --- | --- | --- | --- | --- |
| Signed in, credential present, enabled | Yes | Yes, current account only | Yes | — |
| Signed in, paused (disabled) | Yes | Yes | No | `Last.fm is paused. Turn it on in Services to unlove tracks.` |
| Needs sign-in (stored) | No | Cleared | No | `Last.fm needs sign-in. Sign in on Services to browse its loved tracks.` |
| Credential missing | No | Cleared | No | `The saved Last.fm credential is missing. Sign in on Services.` |
| Credential unavailable (Keychain read throws) | No | Cleared on first load; kept on refresh | No | `Tracklog could not read the saved credential. Unlock the login keychain, then try again.` + Try again |
| Read rejected 401/403 | Yes | Cleared on first load; kept on refresh with a notice | No while the notice shows | `Last.fm rejected the saved credential. Sign in on Services.` |

A read rejection updates only the published Loved state. It does not change the connection's stored `authState`; the single sign-in transition remains in the feedback/delivery outbox, which owns held queues and is shared by every connection. A read model writing that state could race the outbox and turn a transient 401 into a lost delivery window.

### Cache and navigation

No persistent cache. The takeover's third section, `Loved`, reads the current connection every time it opens; leaving or switching connection clears the published rows. The current-connection switcher moves the read cursor and never changes delivery targets. Page-size is 50 for all services; a page-based removal re-reads the last loaded page and deduplicates by row key, and a ListenBrainz removal steps the next raw offset back by one.

## Implementation

Core:

- `LovedBrowsing.swift`: cursor, row/page types, reader port, unsupported error, failure/phase/state, copy, and normalized title+artist matching for a row whose service does not supply an album.
- `LovedReadModel.swift`: lifecycle, generation/connection-scope/mutation-revision guards, idempotent show, first read (up to three pages when every entry lacks metadata), load-more, refresh-with-rows, in-flight revocation on removal, page-omission accounting that is built locally and replaced only on publication, the retry-deadline wake, eligibility publication and feedback reconciliation.
- `LastFMSearch.swift`, `LastFMPayloads.swift` (unchanged payload shape), `LibreFMAdapter.swift`, `ListenBrainzLoved.swift`: real readers for the three services.
- `Feedback.swift`, `SQLiteListenStore+Feedback.swift`, `DeliveryOutbox+Feedback.swift`, `CaptureRuntime+Feedback.swift`: `serviceRow(connectionID:reference:)`, the source-scoped reference hand-off, the normalized title+artist feedback lookup that clears every album-bearing local identity, `applyFeedback`'s success list, `unloveLovedRow` with the pressed row id, the non-blocking reconciliation call, and the Loved seam. `FeedbackIdentity` uses the one `Identity` normalization rather than a second copy.
- `CaptureRuntime.swift`, `CaptureRuntime+Lifecycle.swift`, `CaptureRuntime+Connections.swift`, `TracklogAppState.swift`, `ChartModel.swift`: model ownership, activation/deactivation, connection notifications, `lovedState`, `TakeoverSection.loved`.

Droplet:

- `TracklogTakeover.swift`: third section, connection switcher on the service-read sections, Loved content.
- `TracklogLovedView.swift`: header/source, refresh, rows with separate Unlove buttons, loading/empty/metadata-unavailable/unsupported/failed states, refresh and load-more notices, per-row action failure, rate-limit suppression.
- `TracklogDroplet+Loved.swift`: show/hide/refresh/load-more/unlove, Services and app-credentials remedies, presentation for the harness.
- `TracklogDroplet.swift`, `TracklogHistory.swift`, `TracklogDroplet+Charts.swift`: harness section selection and dismissal.

Harness: `HarnessDemo+Loved.swift` plus the composition hooks; fixtures `normal`, `loading`, `empty`, `failed`, `unsupported`, `app-credentials`, `long-names`, `no-connection`, `needs-sign-in`, `credential-rejected`, `paused`, `action-failure`, `refresh-failure`, `rate-limited`, `metadata-unavailable`.

## Composition proof

The suite uses real `LastFMAdapter`/`LibreFMAdapter`/`ListenBrainzAdapter` over a controlled routing transport, a temporary SQLite database, the real connection service and credential store, `FakeClock`, and a HUD probe. It asserts durable state, outbound requests and published state rather than private helpers.

| Test | Closes |
| --- | --- |
| `lastFMReadsTheCurrentAccountsLovedPageEveryTime` | Current account, page 1, 50 rows, app key, **no `sk`**, signed request; no local history or feedback write; a second show reads again (no cache). |
| `libreFMReadsItsOwnGNUFMRoot` | GNU FM read at the connection root, compiled key, unsigned, no session. |
| `listenBrainzReadsFeedbackByRawOffsetAndOmitsUnnamedRows` | `get-feedback` path, score/metadata/count, token header; one omitted row; next offset advances by the raw three items; duplicate rows dedupe on load-more. |
| `listenBrainzOffsetAdvancesByRawRowsAndStepsBackAfterRemoval` | Offset 2 after one omitted item; after unloving a shown row the next request is offset 1. |
| `pageBasedRemovalRereadsTheLastPageWithoutSkipping` | Pages 1 and 2 loaded; removal makes the next read page 2 again, brings the boundary row in once, dedupes, then reads page 3. |
| `aSourceScopedReferenceNeverLeaksToAnotherListenBrainzConnection` | Two ListenBrainz endpoints; the source gets its row MBID with no lookup, the other resolves its own MBID; one lookup, two posts. |
| `aPartialUnloveLeavesTheRowAndNamesTheFailure` | Last.fm fails, ListenBrainz succeeds: the row stays, the exact per-row notice is published, the HUD names ListenBrainz only, no local listen is written. |
| `theStripHeartRemovesAMatchingRowAndALoveRereads` | The now-playing track carries album and album artist; the Last.fm row does not. The strip unlove removes the row and clears the full local identity, and the next toggle sends `track.love`; the love re-read is a first-page read. |
| `aHistoryUnloveClearsEveryLocalFeedbackIdentityForTheSameTrack` | A History listen with album and album artist clears every local identity for the same normalized title and artist; the Last.fm row leaves the list; the next toggle sends `track.love`. |
| `unlovingASecondRowWithTheSameMetadataPostsAndRemovesThatRow` | Two ListenBrainz rows share metadata but not MBID; unloving the second removes that row by id and posts the second MBID, leaving the first. |
| `unlovingThroughTheStripRereadsWhenTwoRowsShareTitleAndArtist` | A non-row unlove that matches two rows does not guess: it re-reads the first page. |
| `aHeldLoadMoreAfterUnloveIsDiscardedAndKeepsTheSteppedOffset` | A held load-more that lands after an unlove is discarded; the next ListenBrainz offset is the stepped-back one and the row stays gone. |
| `aHeldPageLoadMoreAfterUnloveKeepsTheLastPageCursor` | The page-based equivalent: a held page 3 load-more is discarded, and the next read is last-page reconciliation before page 3. |
| `aHeldRefreshAfterUnloveDoesNotRestoreTheRow` | A held refresh that started before an unlove cannot restore the removed row. |
| `loadMoreDuringARefreshSendsNoRequest` | Load-more during a first-page read sends no old-cursor request and does not stick the loading flag. |
| `unlovingTheOnlyRowOnTheFinalPageDoesNotInventAnotherPage` | The final page's cursor stays nil: no extra read, and the state becomes empty. |
| `unlovingTheLastLoadedRowWithMorePagesNeverPublishesEmpty` | Removing the last loaded row with more pages publishes a live list state, re-reads the boundary page, then reaches the next page. |
| `rowsRunningOutWithOmissionsIsMetadataUnavailable` | Rows running out with omitted entries is metadata-unavailable, never the empty account copy. |
| `reReadingAPageLeavesOmittedUnchanged` | A reconciliation page re-read does not add its omitted count twice. |
| `aRateLimitEndsAtTheDeadlineAndRestoresRetryAndUnlove` | The injected clock ends the wait, clears the deadline, restores the action, and a retry reads. |
| `aRateLimitedFirstReadOffersRetryAfterTheHint` | A rate-limited first read can be retried after the hint, not only after reopening. |
| `hidingCancelsTheRateLimitWake` | Hiding cancels the deadline wake; no late state publishes. |
| `aRejectedFirstReadNamesTheCredential` | A first-read 401 publishes the exact `rejected the saved credential` copy. |
| `aLoveReReadDoesNotHoldTheFeedbackChain` | A held love re-read does not block a following unlove from reaching the service; the held read cannot restore the row. |
| `aRefreshReplacesTheCountedOmittedPages` | Two pages with one omitted item each read 2, a refresh replaces the count with page 1's 1, and the next load-more returns it to 2. |
| `aDiscardedRefreshKeepsTheCountedOmittedPages` | A refresh held across an unlove is discarded; the existing omitted count and counted-page set are unchanged, so the following page re-read cannot inflate or drop the count. |
| `needsSignInSendsNoReadAndOffersNoUnlove` | Stored needs-sign-in: zero requests, needs-sign-in phase, no action. |
| `aPausedConnectionStillReadsButOffersNoUnlove` | Paused still lists, action disabled with the pause reason. |
| `missingCredentialSendsNoRead` | No request; credential-missing phase. |
| `anUnreadableCredentialSendsNoRead` | Keychain read failure: no request; credential-unavailable phase. |
| `aRejectedRefreshKeepsRowsAndLeavesTheConnectionSignedIn` | A 401 refresh keeps the same-connection rows, publishes the auth notice, disables the action, and leaves the connection signed in. |
| `aFailedFirstReadIsRecoveredByTryAgain` | 500 first read; a later refresh reads and replaces the failure with rows. |
| `aRateLimitSuppressesImmediateRetryUntilTheHint` | Rows stay, retry deadline is published, an immediate refresh sends nothing, and a refresh after the deadline reads. |
| `allOmittedRowsDoNotClaimAnEmptyAccount` | A read with every entry lacking metadata is `metadataUnavailable`, not empty. |
| `anEmptySuccessIsNotAnError` | A successful zero-row page is the empty state. |
| `anUnsupportedCustomRootShowsAnUnavailableState` | A custom ListenBrainz root answering 404 is unavailable with the Open Services remedy and no action. |
| `switchingConnectionDropsRowsAndIgnoresTheLateReply` | A held Last.fm reply is released after switching to ListenBrainz; only the new account's row can publish. |

Full suite: **736 tests in 104 suites**, plus **51 media tests in 7 suites**, exit `0`.

## Gate

Command:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Result and receipt: exit `0`, frozen gate `true`, clean before and after, at head `d5bef8412b597d67459c3c2e3dfaf898cafc5f99`.
  - Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261104T152312Z-cdfa6a3e75f2.json`
  - Log: `/Users/ranokay/.local/state/agent-tools/gates/20261104T152312Z-cdfa6a3e75f2.log`
  - Duration: 1355.7 seconds.
  - `git_before` and `git_after` both report head `d5bef84…`, empty porcelain status and the same tracked-content hash.
- `hk check --all`: SwiftFormat, SwiftLint and jactionlint clean; 0 SwiftLint violations in 321 files.
- `swift test --package-path Tests`: 736 tests in 104 suites; 51 media tests in 7 suites.
- `droppykit build`: universal droplet, x86_64 + arm64, `kit.minAPI` 1.19.0 covers every call.
- `droppykit validate`: `Ready to submit`.
- New harness states: `loved-normal`, `loved-loading`, `loved-empty`, `loved-failed`, `loved-unsupported`, `loved-app-credentials`, `loved-long-names`, `loved-no-connection`, `loved-needs-sign-in`, `loved-credential-rejected`, `loved-paused`, `loved-action-failure`, `loved-refresh-failure`, `loved-rate-limited`, `loved-metadata-unavailable`.

## Native observations

All Loved evidence is from the running `TracklogHarness`; every account, row and response is a synthetic fixture. Image names in this section and the evidence list are relative to `docs/reports/issue-87/`; the AX readouts are in `docs/reports/issue-87/ax/`.

| State | Fixture | Result |
| --- | --- | --- |
| Normal rows | `normal` | `Loved`, `Last.fm · listener`, `Refresh loved tracks`, eight `Example Track …` rows with separate `Unlove …` buttons; `loved-normal.png` |
| Loading | `loading` | `AXBusyIndicator` `Loading loved tracks`, `Loading loved tracks…`; header and switcher remain; `loved-loading.png` |
| Empty | `empty` | `No loved tracks on Last.fm`, `Tracks you love there appear here.`; no rows; `loved-empty.png` |
| Failed | `failed` | `Loved tracks could not be loaded`, `Last.fm could not be reached…`, `Try again`; `loved-failed.png` |
| Unsupported custom root | `unsupported` | `Loved tracks unavailable`, `This ListenBrainz-compatible server does not provide loved tracks.`, `Open Services`; `loved-unsupported.png` |
| App credentials | `app-credentials` | `Loved tracks could not be loaded`, missing-pair copy, `Try again` and `Open Settings`; `loved-app-credentials.png` |
| Long names | `long-names` | Long titles and the long artist render in one line with the full AX label; `loved-long-names.png` |
| No current connection | `no-connection` | `Current connection, none`; `Loved tracks unavailable` with the switcher/Services remedy; no rows; `loved-no-connection.png` |
| Needs sign-in | `needs-sign-in` | `Last.fm needs sign-in. Sign in on Services to browse its loved tracks.` with `Try again` and `Open Services`; `loved-needs-sign-in.png` |
| Credential rejected | `credential-rejected` | `Last.fm rejected the saved credential. Sign in on Services.` with `Try again` and `Open Services`; `loved-credential-rejected.png` |
| Paused connection | `paused` | Rows remain; reason bar `Last.fm is paused. Turn it on in Services to unlove tracks.`; no `Unlove` buttons; each row carries the pause reason as its help; `loved-paused.png` |
| Refused row action | `action-failure` | Notice `Could not unlove “Example Track One” on Last.fm. The service did not confirm the change.` with `Dismiss`; the row remains; `Dismiss` pressed interactively removes the notice and keeps the row; `loved-action-failure.png`, `loved-action-dismissed.png` |
| Refresh failure over rows | `refresh-failure` | Notice `Could not refresh loved tracks. Showing the last loaded list. …` with `Try again`; the rows remain; `loved-refresh-failure.png` |
| Rate limit | `rate-limited` | `Last.fm is rate limiting requests. Try again after 16:42.`; `Refresh` disabled; no `Try again`; `loved-rate-limited.png` |
| Loved rows without metadata | `metadata-unavailable` | `Loved tracks need metadata`, `ListenBrainz has loved recordings for this account, but none of the first 2 could be matched to track metadata.`; no rows; `loved-metadata-unavailable.png` |
| Unlove a row | `normal`, AX press on `Unlove Example Track One` | The row and its button leave the list; the next row becomes the first; the pinned strip stays; `loved-unloved.png` |

Touch points:

- The section picker exposes `History`, `Charts` and `Loved`; `Loved` is selected.
- The connection switcher shows `Last.fm · listener` on the Last.fm fixtures, `ListenBrainz · listener` on the custom-root and metadata fixtures, and `Current connection, none` on the no-connection fixture.
- Rows expose one `AXUnknown` element carrying `<title>, <artist>, <album>`; the heart is a separate `AXButton` named `Unlove <title>` with the fan-out hint. When the action is unavailable, the row's help states why and no heart is present.
- The action notice is one `AXStaticText` with its exact spoken copy plus a separate `Dismiss` button; pressing `Dismiss` removes both and leaves the row.
- `Open Services` is wired to the droplet's Services page. The harness host refuses Settings pages, so the actual handoff is not observed here.

## Accessibility

The checklist is `docs/accessibility/voiceover-checklist.md`; it now has a Loved section and a run-record row. AX readouts are under `docs/reports/issue-87/ax/`.

| Requirement | Result | Method |
| --- | --- | --- |
| Section control names all three sections | Passed (AX) | `AXRadioButton` `History`, `Charts`, `Loved`; `Loved` selected. |
| Source label and heading | Passed (AX) | `AXHeading` `Loved`, `AXStaticText` `Last.fm · listener`. |
| Rows are one spoken element | Passed (AX) | `AXUnknown` `Example Track One, Example Artist, Example Album`. |
| Unlove is a separate named action | Passed (AX) | `AXButton` `Unlove Example Track One`, 24 pt target, fan-out hint. |
| Loading state | Passed (AX) | `AXBusyIndicator` `Loading loved tracks` plus the static text. |
| Empty state | Passed (AX) | `No loved tracks on Last.fm` and the explanation; no rows. |
| Unsupported state | Passed (AX) | `Loved tracks unavailable` with the custom-server copy and `Open Services`. |
| Failure state | Passed (AX) | `Loved tracks could not be loaded`, offline copy, `Try again`. |
| Needs sign-in | Passed (AX) | `Last.fm needs sign-in…` with `Open Services`. |
| Credential rejected | Passed (AX) | `Last.fm rejected the saved credential. Sign in on Services.` |
| Paused reason and no action | Passed (AX) | Reason bar and row help; no `Unlove` buttons. |
| Per-row action failure | Passed (AX + screenshot) | Exact notice text, `Dismiss`, row remains; `Dismiss` exercised. |
| Refresh failure with rows | Passed (AX) | Notice and `Try again` over retained rows. |
| Rate-limit wait | Passed (AX) | Wait text, disabled `Refresh`, no immediate `Try again`. |
| Metadata unavailable | Passed (AX) | `Loved tracks need metadata` and the omitted count; no empty-account claim. |
| No connection | Passed (AX) | `Current connection, none` and the switcher/Services remedy. |
| Row removed after source confirmation | Passed (AX + screenshot) | The row and its button disappear; the strip remains. |
| Audible VoiceOver | Not run | No VoiceOver session or microphone capture. |

## Evidence classes and limits

| Class | Result | Evidence |
| --- | --- | --- |
| Composition tests | Run | 736 tests / 104 suites; controlled transport, real adapters, temporary SQLite, fake clock and HUD probe. |
| Harness output | Run | Fifteen Loved gate shots, the interactive unlove and dismissed-notice screenshots, and the AX readouts. |
| Live service shape | Run (public, unauthenticated) | Libre.fm and ListenBrainz shape checks; no account names or rows retained. No authenticated Last.fm/Libre.fm/ListenBrainz smoke, because the run has no user credentials. |
| Real host load | **Not run** | Installing into Droppy Playground writes outside this worktree; not permitted in this run. |
| Settings handoff from Loved | **Not run** | The harness host refuses `openSettingsPage`; the button is wired but the real host page is not observed. |
| Audible VoiceOver | **Not run** | AX-tree inspection only. |

No new package dependency, credential path, delivery route or database migration. The current-connection switcher, services, adapters and HUD were reused. The Loved list never claims a range-love total; the only counts are the rows currently loaded and the count of entries the service could not name. Last.fm/GNU FM loved rows carry no album, so reconciliation matches normalized title and artist and a row unlove clears every local identity for that pair; ListenBrainz rows also carry the service's release name. Unloving a Loved row fans out through the existing feedback policy, and a partial success leaves the row and names the source service.
