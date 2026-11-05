# Issue #86 Entity details and image overrides — worker report

- Base: started from `10e20840c8f71913cb8c492cb779cdb23cf36aac` (`feat: build loved browsing (#87) (#115)`).
- Branch: `feat/entity-details-image-overrides-86`.
- Code head: `786d5e7e462b6737b1d20aebcdf3f62efc0f980f`.
- State: implementation, composition tests, harness fixtures, glossary and checklist updates, the review-round-2 fixes for F12, F13 and F14, the F15 picker-entity fix, the review-round-3 PR comment fixes, and the live F1, F2, F11, F12, F14 and F15 checks. The receipt-backed gate passed at `786d5e7`; the later commits are documentation and evidence only.
- Scope: ticket 10 of the approved breakdown. This report does not close #76 and makes no Store or milestone-complete claim.

## Contract

The owner accepted the 13 decisions in [#86 comment 6638938906](https://github.com/ranokay/tracklog/issues/86#issuecomment-6638938906). This implementation follows them, including the later clarification that Loved rows open details through the History row entry.

## Check-first results

- **Last.fm `getInfo`** — verified against the primary API docs (`artist.getInfo`, `album.getInfo`, `track.getInfo`). Each takes an optional `username` that adds the account's play count. The implementation uses those fields and does not read tags or wiki text.
- **Libre.fm** — checked against the live GNU FM endpoint and its public developer docs. `artist.getInfo` works but returns no stats block; `album.getInfo` answers error 3 (`No method with that name in this package`); `track.getInfo` works but returns no `userplaycount`. Decision 2 therefore gives Libre.fm the one-line reason rather than a service section.
- **Last.fm artist images** — the API's artist image is the same white-star placeholder for many artists, which is why decision 6 skips it. The artist page uses the override, the iTunes approximation, or the neutral sleeve.
- **`NSOpenPanel`** — DroppyKit 1.20.1 has no file-picker API and no file-picker capability. The existing export uses `NSSavePanel` directly, so the same direct AppKit route is used. It opened in the harness host process (see live observations). No manifest capability was added.

## Implementation

Core:

- `EntityDetail.swift`: `EntityKind`, `EntityRequest` (local chart grouping keys, optional MBID), local detail, service facts/failure states, ListenBrainz links, image sources, `ImageOverride`, copy.
- `LocalChartGrouping.swift`: artist and album key builders shared by every list and override.
- `EntityDetailStore.swift`, `SQLiteListenStore+EntityDetail.swift`: local detail, override CRUD, artist-image cache. Migration 12 adds `image_overrides` and `artist_image_cache`; `schemaVersion` is 12.
- Reference-aware blob lifetime: removal, replacement and expiry delete an `artwork` row only when no listen, `track_artwork`, override or cache row still names it.
- `ChartReadConnection+EntityDetail.swift`: one read-only scan for count, first, last, captured cover and top tracks; no writer-actor or capture work.
- `ArtistImage.swift`: iTunes Search client (`entity=album`, `attribute=artistTerm`, limit 10), exact-normalised matching, ambiguity, 30-day hit / 1-day miss cache, HTTPS-only image loader with a 5 MiB response cap and no credentials.
- `LastFMClient+Entity.swift`: `getInfo` requests and facts, reusing `LastFMError.serviceFailure` for the existing classification. Error 10/26/13 → app credentials; 401/403/9/14 → needs sign-in; 29/429 → rate limit; transport/5xx → offline; error 6/7 with a not-found message → missing, other rejections keep their message.
- `EntityDetailReadModel.swift`: bounded 20-page stack, back re-reads the revealed page, every move invalidates older loads, service reads have no persistent cache, connection changes clear/reload only service, artist-page-only lookup, override precedence, and owned-work cancellation.
- `CaptureRuntime*`, `TracklogAppState`, `CaptureSettings`, `SettingsExport`: composition, lifecycle, the lookup switch, and additive `artist_image_lookups` (defaults on when an older export omits it).

Droplet:

- `TracklogEntityDetail.swift`: one takeover detail surface with Back, local section, top tracks (buttons that push the track page), the track's paged listens, service section, image header, approximate caption and Change image/Remove.
- `TracklogImagesSettingsPage.swift`: pending Change image flow, file picker, every override with Remove, lookup switch and Apple privacy note.
- `TracklogTakeover.swift`, `TracklogHistory.swift`, `TracklogHistoryComponents.swift`, `TracklogChartsView.swift`, `TracklogLovedView.swift`, `TracklogSearchPalette*.swift`: entry points, chart/palette overrides, Return/Option-Return/Command-Return, connection switcher on detail pages, stale-presentation guard.
- `HarnessDemo+Detail.swift` and the detail gate fixtures.

## Composition proof

Real temporary SQLite (reopened where persistence matters), `FakeClock`, the real `LastFMClient`, `ITunesSearchClient` and image loader over the scripted `EntityTransport`.

| Test | Closes |
| --- | --- |
| `localSectionIsGlobalAndIgnoresTheCurrentConnection` | Count/first/last/top track stay while the current connection changes to ListenBrainz. |
| `historyAndChartRowsResolveTheSameLocalKeys` | History and chart rows reach one album page and key. |
| `lastFMServiceFactsCarryTheAccountPlayCountAndConnectionName` | `artist.getInfo` parameter shape, app key, `username`, no `sk`, facts and link. |
| `nonLastFMConnectionsExplainAndOnlyListenBrainzLinksWithAnMBID` | Libre.fm/ListenBrainz reason, no Last.fm read, MBID-only ListenBrainz link. |
| `connectionChangeClearsTheServiceSectionAndIgnoresTheLateReply` | Service cleared/reloaded; held old facts cannot land. |
| `reopeningADetailReadsTheServiceAgain` | No persistent detail service cache. |
| `thePageStackPushesTracksAndBackReloadsTheRevealedPage` | Top-track row pushes; Back reloads the artist page and then closes to the list. |
| `aLateReplyFromThePageJustLeftCannotOverwriteTheNewPage` | Older page load invalidated by a move. |
| `thePageStackStaysBounded` | 20-page bound; Back closes the stack. |
| service failure tests (missing, rejected, needs sign-in, offline, 5xx, rate limit, timeout, missing, generic) | Each named state, local section retained, missing is not a failure. |
| `missingAppCredentialsSendNoRequestAndOfferTheSettingsRemedy` | Zero Last.fm requests, Settings remedy. |
| `aFailedPageNeverShowsAnotherEntitysFacts` | No cross-entity facts on a failed page. |
| `overridesSurviveRestartUnlinkDeletionAndStayOutOfExport` | Reopen, unlink, listen delete, export exclusion. |
| `removingOrReplacingAnOverrideDeletesItsBytes` | Old blob absent after replace/remove, including after reopen. |
| `aListenReferencedBlobSurvivesOverrideRemoval` | Shared content hash referenced by a listen survives. |
| `anUnreadableOverrideFallsBackToNeutralAndStaysRemovable` | Missing stored copy → neutral + removable, after restart; local section finishes; no Apple/image request. |
| `anUndecodableOverrideAlsoOwnsTheNeutralSleeve` | Present-but-corrupt blob → neutral, no Apple request. |
| `anUnreadableAlbumOverrideBeatsACapturedCoverAndTheServiceImage` | Unreadable album override beats captured and service images; chart/palette helpers stay override-owned. |
| `theImageFileReaderRefusesEmptyOversizedAndInaccessibleFiles` | Empty/inaccessible → unreadable; real oversize → too large; valid image accepted. |
| `deactivatingStopsAnInFlightOverrideLoad` | A held activation override read publishes nothing after deactivation. |
| `aStartedOverrideKeepsItsDraftAfterTheDetailCloses` | Change image draft survives the detail close and saves through the explicit entity API. |
| `aSuccessfulSaveClearsItsOwnDraft` | A save clears the draft only when it still names the saved entity. |
| `anExplicitSaveSurvivesTheDraftBeingClearedFirst` | The page leaving during the file read clears the draft; the entity captured before the picker still receives the file. |
| `anExplicitSaveTargetsItsOwnEntityAndLeavesAnotherDraft` | Replace on another row during the read changes the draft; the file still saves to the chosen entity and the other draft stays. |
| `anExplicitSaveSurvivesTheDraftChangingDuringTheStoreWrite` | A draft change while the store write is held cannot redirect or lose the save. |
| `aPaletteOpenedDetailLeavesTheNewestFeedUnderneath` | Jump, dismissal reset, detail opened before and after the mount load, then Back to the newest rows. |
| `aDeleteOnTheTrackPageKeepsEveryLoadedPage` | Delete keeps rows beyond the first page. |
| `aFailedReloadKeepsTheRowsAndLeavesTheServiceAlone` | Failed reload keeps rows and failure bar; service section unchanged. |
| `listenBrainzChartRowsCarryTheirMBIDsForEveryEntity` | Real ListenBrainz payloads give artist/release/recording MBIDs and all three links. |
| `anOversizedSelectionIsRefusedBeforeItEntersTheStore` | 20 MiB input limit. |
| `removingAnAlbumOverrideRestoresTheServiceImage` | Released album page returns to `.service` with the one image request it already made. |
| `removingAnAlbumOverrideStartsTheServiceImageThatArrivedUnderIt` | Override up when the facts arrived; Remove starts exactly one service-image request. |
| `albumImagesUseOverrideThenCapturedThenServiceThenNeutral` | Album precedence and “service image only when reached”. |
| `anUnavailableAlbumImageEndsInTheNeutralSleeve` | Missing album image → neutral, no image request. |
| `aTrackUsesItsCapturedCoverAndNeverSearchesForAnArtistImage` | Track capture only; no Apple request. |
| `approximateArtistImagesUseAnExactMatchAndCarryThePrivacyContract` | `artistTerm`, `limit=10`, no credentials, approximate caption, 30-day entry. |
| `twoArtistIDsWithTheSameNameUseTheNeutralSleeve` | Ambiguity → neutral. |
| `aCachedApproximateImageAvoidsRequestsForThirtyDays` | Hit lifetime. |
| `aDefiniteMissIsRetriedAfterADayButAFailureIsRetriedOnTheNextOpen` | Definite miss vs failure cache policy. |
| `switchingLookupsOffHidesACachedApproximateImageWithoutARequest` | Off hides approximate images and sends nothing. |
| `anOverrideMeansNoAppleRequest` | Override short-circuits the lookup. |
| `oversizedOrCorruptRemoteImagesEndInTheNeutralSleeve` | Size and decode failures. |
| `switchingLookupsOff...` / `theLookupSwitchOffSendsNothingAndStillShowsOverrides` | Switch privacy contract. |
| `anExpiredApproximateImageIsRemovedWithItsBlob` | Expiry garbage-collects the old blob. |
| `historyLovedAndPaletteRowsUseTheSameLocalKeys` | Loved MBID and palette row mapping. |
| palette key routing tests | Option-Return plays; Return details; Command-Return Last.fm; marked text passes through. |
| settings export tests | Old export defaults the switch on; false round-trips; overrides absent. |
| updated track-history tests | Track history now runs through the one entity surface. |

Full suite at the `786d5e7` gate: **793 tests in 106 suites**, exit `0` (51 media tests in 7 suites). The focused entity suites are 53 tests, exit `0`.

## Gate

Command:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Result and receipt: exit `0`, frozen gate `true`, clean before and after, at head `786d5e7e462b6737b1d20aebcdf3f62efc0f980f`. The later commits are documentation and evidence only.
  - Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261105T003222Z-8208178c8394.json`
  - Log: `/Users/ranokay/.local/state/agent-tools/gates/20261105T003222Z-8208178c8394.log`
  - Duration: 1548.7 seconds.
  - `git_before` and `git_after` both report head `786d5e7…`, empty porcelain status and the same tracked-content hash.
- `hk check --all`: SwiftFormat, SwiftLint and jactionlint clean; 0 violations in 336 files.
- `swift test --package-path Tests`: 793 tests in 106 suites; 51 media tests in 7 suites.
- `droppykit build`: universal, x86_64 + arm64, `kit.minAPI` 1.19.0 covers every call.
- `droppykit validate`: `Ready to submit`.
- New gate runs: `details-artist`, `details-artist-approximate`, `details-artist-no-connection`, `details-album`, `details-album-service-image`, `details-track`, `details-album-listenbrainz`, `details-override`, `details-corrupt-override`, `details-long-names`, `details-track-delete`, `history-jump-back`, `loved-detail-back`, `images-settings` and `charts-override`. Every `report.json` reported no problems and every declared surface `provided`; `history-jump-back` still shows its jumped window after Back.
- Evidence: `docs/reports/issue-86/` holds the PNGs and report JSONs above plus a contrast shot, `live-f1-detail-override.png` (refreshed from the `19768f7` run) and the live observation notes.

## Native observations

### Fixture evidence (running harness)

All images are in `docs/reports/issue-86/`.

| State | Fixture | Result |
| --- | --- | --- |
| Artist page | `artist` | Local count, first/last, top track button, Last.fm facts, `Change image…`, neutral sleeve; `details-artist.png` |
| Approximate image | `artist-approximate` | Green approximate image and `Approximate artist image` caption; `details-artist-approximate.png` |
| No connection | `artist-no-connection` | `None` switcher and `No connection is current. Connect Last.fm in Services to see service details.`; `details-artist-no-connection.png` |
| Album with captured cover | `album` | Captured red cover above the Last.fm image; release date, listeners, plays and `Your plays`; `details-album.png` |
| Album with service image | `album-service-image` | No captured cover, purple Last.fm image shown; `details-album-service-image.png` |
| Track page | `track` | Captured cover, first/last, paged listen row, duration and Last.fm plays; `details-track.png` |
| ListenBrainz MBID | `album-listenbrainz` | One-line reason plus `Open on ListenBrainz`; `details-album-listenbrainz.png` |
| Override | `override` | Orange override header and `Remove`; `details-override.png` |
| Corrupt override | `corrupt-override` | Neutral sleeve, unreadable-copy sentence and `Remove`; `details-corrupt-override.png` |
| Track delete confirmation | `track-delete` | Delete bar on the track page with Cancel/Delete; `details-track-delete.png` |
| Long metadata | `long-names` | Long artist and track names stay inside the row and truncate/wrap without replacing the count; `details-long-names.png` |
| Images settings | `corrupt-override` + settings page `images` | Pending `Chosen image` for Talking Heads with Choose image/Remove image, the unreadable Talking Heads saved row with Replace/Remove, the valid Blondie row, lookup switch and privacy note; `images-settings.png` |
| Chart row override | `override` + Charts | Blondie's chart row uses the orange override; `charts-override.png` |
| Increased contrast | `artist` + contrast override | Detail separators and borders strengthen; `details-contrast.png` |
| History jump survives a detail | `history-jump-back` + `TRACKLOG_HARNESS_HISTORY=jump` | Back reveals the same `Showing from 3 Nov 2026 at 21:18` window; `history-jump-back.png` |
| Loved rows survive a detail | `loved-back` + Loved section | Back reveals the same loaded Loved rows; `loved-detail-back.png` |

### Live harness

The harness was launched with `droppykit run` and the real `TracklogHarness` process, not only the shot renderer.

- The expanded surface showed the artist page with AX heading `Blondie`, the full local count, `First listened`/`Last listened`, and an AX button `Heart of Glass, Blondie, 1 listen` with help `Opens this track's page` (`docs/reports/issue-86/live-observations.txt`).
- The Images page showed the pending `Chosen image` section, `Choose image…`, `Remove image`, the saved Blondie row with its own `Remove`, and the lookup switch in the on position with the Apple privacy note.
- Activating `Choose image…` opened a real `NSOpenPanel` titled `Choose an artist or album image` in the host process. It was cancelled without choosing a file. This proves the direct AppKit route; a sandboxed Store build was not available.
- A palette fixture run opened the separate palette over the harness; the Artists group showed Blondie with the orange override sleeve and the footer `Return opens details · ⌥Return plays · ⌘Return opens Last.fm · Esc clears, then closes`.
- **Change image flow (F1):** round 1 reached the Settings pane with the draft; round 2 completed the save. In a fresh `TRACKLOG_HARNESS_DETAIL=artist` launch, `Choose image…` opened the real `NSOpenPanel`, the panel's own `Pictures` sidebar and the file row `tracklog-issue86-panel-choice.png` selected a file outside the repo, and the saved list showed `Blondie` with `Replace image for Blondie` and `Remove image for Blondie`. Reopening the artist page showed `Remove` and the chosen image (`live-f1-detail-override.png`). See `docs/reports/issue-86/live-observations.txt` for the panel window and the modal-stall cause.
- **Palette keys (F11):** with the palette open over the detail, Return on the Blondie row closed the palette and opened the Blondie artist detail; it survived the takeover presentation. Option-Return closed the palette and the harness Activity log recorded `open https://music.example/search?q=Blondie` (the play action). In round 2, Command-Return on a fresh `TRACKLOG_HARNESS_PALETTE=normal` launch closed the palette and the Activity page recorded `open https://www.last.fm/music/Blondie`; no detail opened.
- **Track delete (F2):** the confirmation renders on the track page and the shot is `details-track-delete.png`. Round 2 completed the live clicks on a fresh `TRACKLOG_HARNESS_DETAIL=track` launch: Cancel left `1 listen` and the row; Delete changed the local section to `0 listens` and closed the bar.
- **Palette Return and Back (F12):** a fresh `TRACKLOG_HARNESS_HISTORY=jump TRACKLOG_HARNESS_PALETTE=normal` launch jumped, opened the palette (dismissing the takeover), opened Blondie from the palette with Return and went Back. History showed `Thursday, 5 November 2026` first, 6 listens and no `Showing from` bar, so the jumped rows did not survive as the newest feed.
- **Images draft (F14):** after the F1 save the `Chosen image` section cleared while the page stayed. Opening `Change image…` again, leaving the Settings pane for the Expanded surface and returning showed no `Chosen image`; the saved list stayed.
- **Not run:** live Last.fm `getInfo` (no working app pair/session), live ListenBrainz, live album-image removal (F13, covered by composition tests), VoiceOver speech, Droppy Playground install, and a Store-signed build.

## Accessibility

The checklist is `docs/accessibility/voiceover-checklist.md`; it now has an Entity details section, the Images settings page and updated History/Loved/Search rows.

| Requirement | Result | Method |
| --- | --- | --- |
| Detail title is a heading; row is one element | Passed (AX) | AXHeading `Blondie`; top track exposes a button label and hint. |
| Top-track rows are interactive | Passed (fixture + code) | Each row is a button that pushes the track page; the page stack composition test covers the return reload. |
| Long names stay inside the row | Passed (shot) | `details-long-names.png`; the title keeps the count and image actions readable. |
| Approximate image is captioned | Passed (shot) | `Approximate artist image` under the title. |
| Images page controls are labelled | Passed (AX) | `Choose image…`, `Remove image`, `Remove`, `Look up artist images`. |
| `NSOpenPanel` opens in the host | Passed (live harness) | Window `Choose an artist or album image`. |
| VoiceOver speech | Not run | No VoiceOver session; AX structure only. |
| Full Tab traversal of the takeover | Not run | Known gap recorded by the checklist. |

## Limitations and follow-ups

- Live Last.fm/Libre.fm/ListenBrainz reads were not exercised in this environment. The transport-level tests use the real request builders and exact response shapes; they do not replace a live smoke test before a version bump.
- F13's released album image was not observed live: the harness override fixtures are artist images and no live Last.fm album read is configured. The composition tests cover both request counts.
- Droppy Playground and a signed Store build were not tested.
- The harness shot renderer clips the far-right edge of every expanded surface on this display; that is present in existing Charts shots too and is not specific to the detail page.

## Glossary and invariants

- `GLOSSARY.md` now defines **Artist image** and **Image override**, and the Artwork entry explicitly says artwork is not the artist image.
- No branding, licensing, credential, host-capability or clean-room change. No new package. The droplet still depends only on DroppyKit.
- Overrides are absent from the settings export; the lookup switch is an additive optional key (`artist_image_lookups`, defaulting on when absent).

## Review fixes

All eleven round-1 findings were addressed in `07a43cb`. Round 2 found three more code findings (F12-F14) and reopened the live checks for F1, F2 and F11; those are addressed in `98ec63a`, `c4f601f` and `8c68562` and recorded below. The report separates what is proven by tests/fixtures from what was observed live.

- **F1 — a real file saved through the picker (round 2).** `closeEntityDetail()` no longer clears `imageOverrideDraft`; deactivation and a new page still clear it. The harness has an Images settings route, and `aStartedOverrideKeepsItsDraftAfterTheDetailCloses` covers the close-and-save path. Live, in a fresh `TRACKLOG_HARNESS_DETAIL=artist` launch: `Change image…` showed `Chosen image` / `Blondie` after the takeover dismissal; `Choose image…` opened the real `NSOpenPanel` titled `Choose an artist or album image`; the panel's own `Pictures` sidebar and the file row `tracklog-issue86-panel-choice.png` (outside the repo) selected it with AXOpen; the saved list then showed `Blondie` with `Replace image for Blondie` and `Remove image for Blondie`, and reopening the artist page showed `Remove` plus the chosen image. The header is visual: `live-f1-detail-override.png` was sampled for the chosen PNG's flat colour and 4,533 matching pixels sit in the header sleeve region. Panel details and the stall cause are in `docs/reports/issue-86/live-observations.txt`.
- **F2 — live Cancel and Delete (round 2).** `TracklogEntityDetailView` renders `HistoryDeleteBar` for `state.pendingListenDelete`. Live, in a fresh `TRACKLOG_HARNESS_DETAIL=track` launch: `Delete listen…` showed `Delete "Heart of Glass"?`; Cancel left the page at `1 listen` with the row in place; the second `Delete` changed the local section to `0 listens` and closed the bar.
- **F3 — originating list preserved.** The takeover keeps the section view mounted under the detail and hides it from hit testing/VoiceOver instead of replacing it. `history-jump-back.png` shows the same `Showing from 3 Nov 2026 at 21:18` window after Back; `loved-detail-back.png` shows the same loaded Loved rows after Back. Section switches and takeover dismissal still run the section's hide/reset.
- **F4 — reload keeps rows.** `reload()` no longer calls `loadPage`; it keeps rows and the service section, merges the refreshed first page into the loaded pages, and keeps rows beside the failure bar. `aDeleteOnTheTrackPageKeepsEveryLoadedPage` loads 120 rows and deletes one; `aFailedReloadKeepsTheRowsAndLeavesTheServiceAlone` holds 120 rows through a failed read and asserts the service section is unchanged. Back still reloads from scratch.
- **F5 — unreadable override owns neutral.** An override row now marks `overridePresent`; a missing or undecodable blob resolves to neutral, skips the iTunes lookup and the album `getInfo` image request, and chart/palette helpers report the override as present with nil readable data. Tests cover missing, corrupt, artist and album-with-captured-cover cases. The doc comment now says neutral.
- **F6 — Replace and unreadable rows.** Each saved row has `Replace` (same picker/draft) and `Remove`; an unreadable row reads `The saved copy could not be read. Replace or remove it.` with an element-specific VoiceOver label. `images-settings.png` shows both rows and both actions.
- **F7 — no stale local write.** `loadOverride` re-reads `state.entityDetail` after the artwork await. `anUnreadableOverrideFallsBackToNeutralAndStaysRemovable` asserts the local section finishes.
- **F8 — chart MBIDs.** `EntityRequest.chartItem` passes `providerID` for artists and albums as well as tracks. `listenBrainzChartRowsCarryTheirMBIDsForEveryEntity` decodes real ListenBrainz payloads and asserts `/artist/`, `/release/` and `/recording/` links.
- **F9 — file reading off the main actor.** `ImageOverrideFileReader` starts the security scope before the size check, returns unreadable for empty/missing/unknown files, too large only for a real oversize, and is called from `Task.detached`. The reader test covers empty, sparse-oversized, missing and valid files; an unreadable or oversized choice never touches an existing override.
- **F10 — owned activation work.** The override load and cache prune tasks are stored and cancelled in `deactivate()`; the unused `loadMoreTask` was removed. `deactivatingStopsAnInFlightOverrideLoad` holds the activation read, deactivates, releases it and asserts no publication.
- **F11 — palette keys (round 2).** Return on the Blondie palette row opened the Blondie artist detail. Command-Return on a fresh `TRACKLOG_HARNESS_PALETTE=normal` launch closed the palette and the harness Activity page recorded exactly `open https://www.last.fm/music/Blondie` (`01:05:21.674`); no detail opened. Option-Return was observed in round 1 (`open https://music.example/search?q=Blondie`). The key router and both palette paths are also covered by tests.
- **F12 — a palette detail keeps the newest feed underneath.** `openHistory` no longer skips the load when `state.entityDetail != nil`, and `reloadHistory()` no longer calls `closeEntityDetail()`. The feed load therefore runs under a detail opened before or during the mount task, and the other `reloadHistory` caller (the jump bar's Newest action) has no detail to close because the bar is only reachable from the section, not the detail. `aPaletteOpenedDetailLeavesTheNewestFeedUnderneath` covers jump, dismissal reset, both orderings and Back; the in-takeover jump Back stays `history-jump-back`. Live: jump, palette opening, Return on Blondie, Back showed `Thursday, 5 November 2026` first with 6 listens and no `Showing from` bar.
- **F13 — removing an album override restores the next source.** `removeOverride` restarts the album image path, and `maybeStartServiceImage` no longer drops a copy it already downloaded when precedence is not ready; the released page returns to `.service` without a second request, or fetches it when the override was up when the facts arrived. `removingAnAlbumOverrideRestoresTheServiceImage` asserts `.service` with exactly 1 request total; `removingAnAlbumOverrideStartsTheServiceImageThatArrivedUnderIt` asserts 0 before Remove and exactly 1 after. The Images copy now says "the page's next available image, or the neutral sleeve" instead of naming the captured cover only.
- **F14 — the chosen image clears on the way out.** `finishImagesSettingsPage` is now called by the Images page's `onDisappear` (the unused `goBackInSettings` call is gone), a successful save clears only its own draft, and an explicit save copies the entity before the first suspension. `aSuccessfulSaveClearsItsOwnDraft`, `anExplicitSaveSurvivesTheDraftBeingClearedFirst`, `anExplicitSaveTargetsItsOwnEntityAndLeavesAnotherDraft` and `anExplicitSaveSurvivesTheDraftChangingDuringTheStoreWrite` cover the draft paths, the last with a held store write. Live: after the F1 save the section cleared on the spot; opening `Change image…` again, leaving the Settings pane and returning showed no `Chosen image`, while the saved list stayed.
- **F15 — the picker saves to the entity it started with.** `chooseImageOverrideFile` now takes the draft and captures it before `runModal`, then passes that explicit entity through the off-main read to `saveImageOverride`. The page leaving during the read no longer makes the save throw `noSelection`, and Replace on another row no longer redirects the first file. `saveOverride` clears the draft only when it still names the saved entity, so the other entity's draft survives, and a failed save sets `state.imageOverrideError` even when the page has gone, where the next visit shows it. `saveSelectedImageOverride` and `selectOverrideImage` are removed and their tests moved to the explicit API. Live recheck on `19768f7`: `Change image…` → real panel → `Pictures` → `tracklog-issue86-panel-choice.png` → saved list `Blondie` with Replace/Remove; the reopened artist detail showed `Remove` and the chosen image (`live-f1-detail-override.png`, 4,533 sampled pixels). The panel's modal stall remains the runModal cause recorded in the live notes.

### Review round 3 (PR comments)

Three CodeRabbit "Minor · Functional" comments were verified against the source and fixed in `786d5e7`.

- **The Images settings shot really starts a draft.** `HarnessDemo+Detail` began the pending draft only for the `override` fixture, while the gate's `images-settings` shot uses `corrupt-override`. The guard now includes both, so the shot shows `Chosen image` / `Talking Heads` with `Choose image…` and `Remove image` beside the unreadable Talking Heads row and the valid Blondie row. `images-settings.png` was refreshed from the gate run.
- **A track page's Open artist/album pushes instead of replacing the stack.** `openEntityDetailFromHistory` called `openEntityDetail`, which replaces the stack with the new request, so Back from an artist or album opened on a track page closed the detail instead of returning to the track. It now pushes when a detail is already open and opens fresh only from the History feed. Live: the track page's row menu `Open artist` opened Blondie, and Back returned to the same track page (`Blondie — Parallel Lines`, `Duration`).
- **Loved rows describe the track and only offer real actions.** The row hint is always `Opens this track's page`; the unlove-unavailable reason stays in `actionReasonBar` instead of replacing the hint, and the unused `unavailableReason` property is gone. The `Open artist` and `Open album` accessibility actions are exposed only when the row has that field, matching the context menu.
