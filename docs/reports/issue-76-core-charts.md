# Issue #76 — Core charts worker report

- Base: `f8907349e7c7373e01905064a213704e22953091`
- Branch: `feat/core-charts`
- Scope: core-charts milestone only (CH-01, the agreed CH-02 subset, supported CH-07 totals and CH-08 refresh). This is not #76 completion and makes no Store claim.
- Evidence images: `docs/reports/issue-76/`.

## Delivered

- **Local reads**: one full-database aggregation counts every stored listen once, independent of deliveries, targets, current connection and History paging. Chart keys use the existing `Identity` trim/lowercase rule but never replace the stored metadata or feedback identity. Groups are artist; album + album artist with track-artist fallback; track + artist across albums and players. Blank required fields omit a row and report the omission count while still counting in the exact range total. Ties sort by normalized key, display spelling is deterministic, artwork comes from the earliest stored cover, and the list is bounded to Top 50.
- **Windows**: Gregorian calendar in the Mac's current time zone. Today from midnight, Week from Monday, Month from the first, Year from 1 January, All time unbounded. Bounded ranges are start-inclusive/end-exclusive; Custom includes both selected calendar dates through the next local midnight and rejects reversed dates. Time-zone and day-change notifications re-resolve while Charts is visible.
- **Service reads**: Last.fm `user.getTopArtists/getTopAlbums/getTopTracks` with `7day/1month/12month/overall`, provider ranks/counts/MBIDs; ListenBrainz `artists/releases/recordings` with `week/month/year/all_time`, returned `from_ts`/`to_ts` and `last_updated`, and a distinct 204 statistics-not-ready state. Missing MBIDs keep named rows with source-scoped fallback keys. Libre.fm resolves to a named local fallback without a request; network/auth/rate-limit/malformed failures never change the source.
- **Totals**: exact local listen totals for every local range. Last.fm `user.getInfo.playcount` and ListenBrainz `/listen-count` are fetched only for service All time, cached separately with their own timestamps. Other service period totals and range loves are unavailable, never zero or a sum of Top 50.
- **Cache and lifecycle**: SQLite schema 10 stores scoped list and total rows keyed by endpoint, account, service, type, native period, schema and local resolved window/time zone. Local standard caches retain one snapshot per selection across rolling-window and time-zone changes; Custom retains one per chart type. Fresh results show immediately; refresh occurs at 15 minutes or on request and coalesces. Failure preserves rows and original save time. Publication and cache writes are guarded by selection, account and lifecycle generation. Unlink and identity replacement evict remote rows inside the connection transaction, so an eviction failure aborts the operation instead of leaving old rows behind. Deactivation cancels the owned task, artwork load and observers.
- **Native UI**: the existing 899 × 558 takeover now has a section control (History first on reopen) and the current-connection read switcher at the trailing edge on Charts. Charts uses the accepted Context rail: source, periods, source note and supported total; Artists/Albums/Tracks, saved age, Refresh, returned/rolling period detail, notice and ranked rows with 52 pt sleeves. The shared 76 pt pinned strip covers playing, paused, off and idle-hidden states. Custom dismisses the takeover and opens the Settings-only date page; Save stays in Settings and Open Charts is explicit.
- **Harness**: deterministic normal, loading, empty, not-ready, failed, failed-with-saved-data, long-names, no-connection, local, Libre.fm-fallback, All-time-account, paused and off scenarios. `scripts/gate.sh` now renders the normal Charts takeover.

## Round 1 review fixes

- **F1** — every credential-lookup outcome now re-checks `isCurrent(request)` after the await, including nil, blank and thrown results. Controlled delayed-credential tests switch to local history before releasing a nil lookup, and deactivate before releasing an error; neither publishes a failure, changes the current phase or writes a service cache row.
- **F2** — local aggregation now runs on a dedicated read-only `ChartReadConnection` actor with its own SQLite connection and a deferred read transaction. The writer/capture actor is free during the scan; the reader yields and checks cancellation every 64 rows. Tests hold the real scan at row 64 while capture persists a listen, the outbox delivers it and History advances; dismissal cancels the scan without writing a cache row. The held scan keeps its consistent starting total of 200 while the database reaches 201.
- **F3** — service headings, notices and row accessibility values use the effective source's native period label (`Rolling 7 days`, `Previous completed week`, and so on). Local mode keeps `This week`. The heading always names the Top 50 cap, even with fewer rows. Visual and spoken units are singular at one (`1 play`, `1 listen`). The account-total accessibility label includes its saved age. `ChartCopy` tests cover Last.fm, ListenBrainz and local wording, including row values.
- **F4** — Settings copy now describes listener actions rather than implementation. `Save range` stays in Settings; `Range actions` no longer says “Save and return”. The page shows the saved range separately from unsaved date edits and disables Open Charts while save is in flight. `selectSavedCustomRange()` resets source and period to the saved local Custom dates; a test saves Custom, browses Week and a service source, then verifies Open Charts' public selection action returns to the saved dates and range.
- **F5** — album grouping now requires a nonblank album and a nonblank album artist or track-artist fallback. Whitespace-only fallbacks are omitted from the ranked list while remaining in the exact range total; a valid album artist with a missing track artist stays included.
- **F6** — every local read now opens and owns its own read-only SQLite connection and deferred transaction. Overlapping type/period changes, hide/reopen and close cannot share a transaction or statement; close marks the reader closed, active reads abort at their next ownership check and close their own handles. Tests hold the first real scan at row 64, switch type, hide/reopen, and close the store while it is held; the newest selection reaches correct ready data, the reopened view reaches data, and close produces a local-read failure without a stale cache or a use-after-close.

## Observable test evidence

`swift test --package-path Tests`: **565 tests in 92 suites passed**. The new focused suites are:

- `ChartCalendarTests`: exact start/end membership, Monday week starts, month/year starts, leap day, DST 23/25-hour days, time-zone change, inclusive Custom end, reversed rejection.
- `ChartLocalTests`: 120 listens across three delivery targets, pending/retrying/abandoned/zero-target rows and a 10-row History page still total 120 once and list 50; normalization, album-artist fallback, track grouping across albums/players, stable omissions and feedback identity; deterministic artwork; Today boundaries; time-zone recomputation while open; bounded local caches; Custom save/reject; History-first default and selection persistence.
- `ChartServiceTests`: all three Last.fm and ListenBrainz entity types, native period parameters, provider counts/ranks/MBIDs, returned dates, 204 versus empty, app-credential and rate-limit distinctions, Libre.fm named fallback with zero requests, absent connection, and no credential in cache payloads.
- `ChartCacheTests`: fresh/expired/missing cache, failed refresh with and without saved rows, coalescing, late obsolete responses, per-account/source/type/period isolation, restart offline with the original age, unlink eviction and an injected eviction failure that rolls back unlink, identity replacement, deactivation and reactivation, independent total age, and capture/delivery/History continuity while a chart request is held open. Round 1 adds delayed nil/error credential publication guards and real local-scan occupancy/cancellation tests.
- `ChartCalendarTests` and `ChartCopy` assertions cover service/local period labels, Top 50 headings, singular units and row accessibility values. F6 adds overlapping local-read, hide/reopen and close-while-held coverage.

## Native harness observation

Headless shots were rendered after build and each report had `problems: []`:

`charts-normal`, `charts-loading`, `charts-empty`, `charts-not-ready`, `charts-failed`, `charts-failed-saved`, `charts-long-names`, `charts-no-connection`, `charts-local`, `charts-libre-fallback`, `charts-all-time`, `charts-all-time-total-failed`, `charts-all-time-total-saved-failed`, `charts-paused`, `charts-off`, `charts-idle`, `charts-contrast`, `charts-settings`.

The harness shot width is fixed at 1180, which crops about 19 points from the right edge of the 899-point takeover stage. Full-width native window screenshots were therefore captured at 1320 points and inspected for normal, long names, failed, ListenBrainz not-ready, All-time total failure with and without a saved total, local mode, no connection and Custom Settings: `docs/reports/issue-76/live-*.png`. The headless pair still shows both hardware styles; the live screenshots show the full-width running window.

The running harness was also driven through its accessibility tree:

- Opening the surface with no chart override showed **History first**.
- Switching Charts → On this Mac → Albums → Month changed the visible heading and rows through the real read model.
- The current-connection read switcher remained at the trailing edge of the section row; source, type and period controls exposed selected states.
- Last.fm showed `Top 50 artists · Rolling 7 days`; ListenBrainz showed `Top 50 artists · Previous completed week` with the returned dates line; local showed `Top 50 artists · This week`.
- Paused, off and idle strip states were rendered; rows and totals showed singular units at one, `Account total unavailable` with no saved total, and `Could not refresh account total · showing saved total` with the retained total and age when only the total refresh failed. The duplicate period subtitle was removed from the heading.
- Row accessibility labels are `Rank 1, Blondie, 42 plays` (or listens); `ChartCopy` tests cover the source/period row value.
- The Charts Settings page renders through `TRACKLOG_HARNESS_SETTINGS_PAGE=charts`; native controls expose `AXDateTimeArea` start/end dates and `AXButton` Save/Open Charts. Tab reached the start-date field; deeper keyboard traversal was not established because the harness does not expose a full focus chain.
- The contrast override strengthens row separators.

## Limits and unpassed checks

- **Audible VoiceOver was not run.** The harness has no accessibility checker, and enabling VoiceOver would change an OS setting and require a system prompt outside this task's permission. Only the AX tree and rendered states above were inspected. Mark the Charts VoiceOver row unpassed in the checklist rather than treating AX evidence as speech.
- **Keyboard path is still the documented gap for the takeover.** The takeover remains pointer-and-VoiceOver only. Settings controls are native and the start-date field received focus under Tab, but a full keyboard traversal with the host's Settings window was not established. No takeover keyboard path is claimed.
- **Host Settings handoff is unverified.** The harness workspace returns `false` for `openSettingsPage`, so clicking Custom recorded the refusal in Activity. The page itself renders in the Settings-pane preview, and the drop-in code calls the same host route used by the existing Services page. No Droppy Playground or host load was performed: that would install outside the repository, which this run's permission does not cover.
- **Live services were not contacted.** Harness fixtures and Swift tests use the real adapters over a controlled transport. No authorized live Last.fm/ListenBrainz smoke was available, so service-specific behaviour is not qualified. Rate-limit, auth, empty, returned-date and 204 handling are fixture contracts, not live evidence.
- **Concurrent load is verified at the composition seam**, where a held chart request leaves capture, delivery and History working. It was not replayed by a human over a long live session.

## Deferred

No activity graph, rank arrows, grid/list switch, chart text export, detail page, collage, random picks, search, friends, tags, edit/delete, import/export, advanced rules, new endpoints, deep links, menu bar extra or Store submission work is included. The matrix's remaining `later` rows and #76 itself remain open.
