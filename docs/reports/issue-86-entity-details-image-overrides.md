# Issue #86 Entity details and image overrides — worker report

- Base: started from `10e20840c8f71913cb8c492cb779cdb23cf36aac` (`feat: build loved browsing (#87) (#115)`).
- Branch: `feat/entity-details-image-overrides-86`.
- Code head: `9eb6ed44e1e8397dc52fed424922a5913708166e`.
- State: implementation, composition tests, harness fixtures, glossary and checklist updates. The receipt-backed gate passed at the code head; the report and evidence are the only later changes.
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
| `anUnreadableOverrideFallsBackToNeutralAndStaysRemovable` | Missing stored copy → neutral + removable, after restart. |
| `anOversizedSelectionIsRefusedBeforeItEntersTheStore` | 20 MiB input limit. |
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

Full suite: **778 tests in 106 suites**, exit `0`.

## Gate

Command:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Result and receipt: exit `0`, frozen gate `true`, clean before and after, at head `9eb6ed44e1e8397dc52fed424922a5913708166e`.
  - Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261104T203447Z-c9d69661f137.json`
  - Log: `/Users/ranokay/.local/state/agent-tools/gates/20261104T203447Z-c9d69661f137.log`
  - Duration: 1624.9 seconds.
  - `git_before` and `git_after` both report head `9eb6ed4…`, empty porcelain status and the same tracked-content hash.
- `hk check --all`: SwiftFormat, SwiftLint and jactionlint clean; 0 violations in 335 files.
- `swift test --package-path Tests`: 778 tests in 106 suites; 51 media tests in 7 suites.
- `droppykit build`: universal, x86_64 + arm64, `kit.minAPI` 1.19.0 covers every call.
- `droppykit validate`: `Ready to submit`.
- New gate runs: `details-artist`, `details-artist-approximate`, `details-artist-no-connection`, `details-album`, `details-album-service-image`, `details-track`, `details-album-listenbrainz`, `details-override`, `details-corrupt-override`, `details-long-names`, `images-settings` and `charts-override`. Every `report.json` reported no problems and every declared surface `provided`.
- Evidence: `docs/reports/issue-86/` holds the PNGs and report JSONs above plus a contrast shot and the live observation notes.

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
| Long metadata | `long-names` | Long artist and track names stay inside the row and truncate/wrap without replacing the count; `details-long-names.png` |
| Images settings | `override` + settings page `images` | Chosen image, Choose image/Remove image, saved Blondie row with Remove, lookup switch and privacy note; `images-settings.png` |
| Chart row override | `override` + Charts | Blondie's chart row uses the orange override; `charts-override.png` |
| Increased contrast | `artist` + contrast override | Detail separators and borders strengthen; `details-contrast.png` |

### Live harness

The harness was launched with `droppykit run` and the real `TracklogHarness` process, not only the shot renderer.

- The expanded surface showed the artist page with AX heading `Blondie`, the full local count, `First listened`/`Last listened`, and an AX button `Heart of Glass, Blondie, 1 listen` with help `Opens this track's page` (`docs/reports/issue-86/live-observations.txt`).
- The Images page showed the pending `Chosen image` section, `Choose image…`, `Remove image`, the saved Blondie row with its own `Remove`, and the lookup switch in the on position with the Apple privacy note.
- Activating `Choose image…` opened a real `NSOpenPanel` titled `Choose an artist or album image` in the host process. It was cancelled without choosing a file. This proves the direct AppKit route; a sandboxed Store build was not available.
- A palette fixture run opened the separate palette over the harness; the Artists group showed Blondie with the orange override sleeve and the footer `Return opens details · ⌥Return plays · ⌘Return opens Last.fm · Esc clears, then closes`.
- **Not completed:** the detail-from-palette Return observation. An unrelated macOS TCC prompt from Raycast took focus before Return was sent. Per the task rules I did not approve or dismiss that system prompt. The stale-takeover guard is implemented (`expandedSurfaceDidDismiss`/`takeoverDidDisappear` compare the owning presentation id), but I am not claiming a completed live run of that sequence.
- **Not run:** live Last.fm `getInfo` (no working app pair/session), live ListenBrainz, VoiceOver speech, Droppy Playground install, and a Store-signed build.

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
- The palette Return survival was not observed live because an unrelated system prompt took focus. The code guard and composition-level stack invalidation are in place; a live Playground pass should complete it.
- Droppy Playground and a signed Store build were not tested.
- The harness shot renderer clips the far-right edge of every expanded surface on this display; that is present in existing Charts shots too and is not specific to the detail page.

## Glossary and invariants

- `GLOSSARY.md` now defines **Artist image** and **Image override**, and the Artwork entry explicitly says artwork is not the artist image.
- No branding, licensing, credential, host-capability or clean-room change. No new package. The droplet still depends only on DroppyKit.
- Overrides are absent from the settings export; the lookup switch is an additive optional key (`artist_image_lookups`, defaulting on when absent).
