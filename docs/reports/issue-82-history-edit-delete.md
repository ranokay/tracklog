# Issue #82 local history editing and deletion — worker report

- Base: `aa6bdeb257b24dd94b33b8a5f8295be5affff908` (`feat: build history navigation (#112)`)
- Branch: `feat/history-edit-delete-82`
- Scope: ticket 6 of the approved breakdown, part of #76. It builds matrix rows
  `NP-08` (edit an existing scrobble) and `NP-09` (delete an existing scrobble)
  for local history and leaves qualified remote write-back to its dependent
  tickets.
- State: the owner agreed this contract in the implementation run before any
  code changed. Implementation, tests, harness evidence and the receipt-backed
  gate are complete. The gate ran at code head
  `15fc972a3bceaa3b70eef6ee59d3408b1a8fe628`; later commits add this report and
  evidence only.

## Contract

The owner agreed these rules before implementation. Where the worker's
proposal and the owner's ruling differ, the ruling here is authoritative.

### 1. Local mutation identity

A local edit changes only the four stored **processed** values: title, artist,
album and album artist, each trimmed. Title and artist stay required; album and
album artist can be cleared to empty.

An edit does **not** change:

- `id`, `raw`, `startedAt`, `capturedAt`, `bundleID`, `duration`,
  `playedDuration`;
- `artworkHash`, the stored raw `track_identity` column, or the durable
  `dedup_key` built from raw identity, bundle id and start.

The row stays one stored listen, counted once. Because the track-history key
and the local chart keys derive from processed title and artist, the edited row
moves to the edited track and out of the old one. The History page, track view,
delivery reads and local chart results refresh after the write. No separate
"edited" marker is stored: the processed columns are the durable record.

### 2. Dedup consequences

- An edit never changes duplicate suppression: the durable key uses raw
  identity, bundle id and start; the engine's short repeat guard also uses raw
  identity.
- A repeat is a new play with a new start instant and is captured again. A
  duplicate is the same track identity and start instant and remains
  suppressed.
- Delete removes the listen and its local delivery rows and records a
  **one-way hash** of the dedup key in `deleted_listens`. The table never stores
  the readable dedup key, because that key contains track, artist and album
  text. The hash uses a system one-way hash, not a new dependency.
- The tombstone is hidden: it is not a history row, not counted, not exported
  and not shown. It keeps a deleted play from being re-captured after a restart
  or feed replay. A later play with a different start is still a repeat.

### 3. Pending and in-flight delivery handling

- An edit preserves every existing delivery row: state, attempts, last attempt,
  next attempt, last error, abandoned reason, service reference and target.
  It creates no target and revives no abandoned row. Zero targets remains
  valid.
- Waiting and retrying deliveries keep their state and backoff. The sender reads
  the stored listen at send time, so the next attempt sends the edited
  processed values. This does not rerun metadata rules on retry; it reads the
  already-stored processed row.
- An edit does not make rows due now and does not reset attempts. Manual Retry
  remains the explicit remedy.
- Delivered rows stay delivered and are not resent. Abandoned rows stay
  abandoned. Zero-target listens stay zero-target.
- A request already in flight carries the values read before the edit. Tracklog
  cannot recall it; it may still arrive. A delete removes the listen and its
  local delivery rows in one transaction, but a send already under way may
  still arrive and cannot be recalled. Tracklog records no local success for
  that request.
- Delete performs no remote call. A delivered copy already on a service stays.

### 4. Feedback and artwork references

- Local feedback is keyed by processed metadata identity. An edit changes that
  identity, so the row shows the new identity's feedback; the old feedback is
  not migrated or deleted. Editing a loved listen therefore shows it as not
  loved unless the edited values are already loved.
- Delete leaves feedback untouched: feedback is track knowledge, not history.
- Artwork is content-hashed and shared, with a raw-track mapping. Edit changes
  neither the raw identity nor the artwork hash. Delete leaves the shared
  artwork and mapping for later listens and launches. No garbage collection is
  added.

### 5. Remote consistency

This ticket makes no remote writes.

The UI says, in the edit page and delete confirmation:

- `Changes stay on this Mac. Last.fm history cannot be rewritten; Libre.fm and
  ListenBrainz are not changed by this update.`
- `Last.fm cannot rewrite history. Libre.fm and ListenBrainz are not changed by
  this update.`

Per live delivery state:

- waiting/retrying, edit: `Waiting for <service>: the next attempt will use
  these values.`
- waiting/retrying, delete: `Waiting for <service>: that delivery will be
  discarded. A send already under way may still arrive.`
- delivered: `Delivered to <service>: that copy stays.`
- abandoned: `Not delivered to <service>: unchanged.`
- no targets: `No service received this listen.`

Recorded state: an edit writes only the processed columns and leaves delivery
state, attempts, errors and references alone. A delete removes the listen and
its local delivery rows and writes only the hashed tombstone. Neither operation
records a remote success or issues a write-back request.

### Remember as rule

The optional action is off by default, saved atomically with the row edit, and
uses a normal `SimpleEditRule`, so it follows the settled specificity-then-
recency order, wildcard matching, field merging and "only enabled fields
change" rules. It affects future plays only and never rewrites other history
rows. Saving it may revise the session in flight through the existing
`reviseCurrentSubmission` path, which is still a future scrobble.

The rule matches every non-empty sentinel-cleaned **raw** field, using
`SimpleEditRule.Match.prefilled(from: MetadataPipeline.sentinelCleanup(raw))`,
the same builder the existing Edit action uses. It replaces only the fields the
edit changed. A remembered album correction therefore does not apply to the
same title and artist on a different album.

### Delete confirmation

Inline, pinned bar in History:

- Title: `Delete “<title>”?`
- Body: `This listen will be removed from this Mac's history.`
- Service lines from the live delivery rows, including the in-flight warning
  for any waiting or retrying delivery.
- Footer: `Last.fm cannot rewrite history. Libre.fm and ListenBrainz are not
  changed by this update.`
- Buttons: `Cancel` (default and Escape) and `Delete` (destructive, no default
  Return binding).
- The bar is one accessible group read in order. It never auto-confirms and
  can be dismissed without changing anything.

### Accepted consequences

- One listen can hold different metadata on different services.
- Editing a loved listen shows it as not loved unless the new values are
  already loved; the old feedback stays.
- Deleting a listen deletes its stored `service_reference`, so later
  service-delete tickets cannot reach those remote copies.
- Shared artwork stays after a delete.

## Implementation

- Migration 11 adds `deleted_listens(dedup_hash PRIMARY KEY, deleted_at)`.
  `ListenTombstone.hash(of:)` uses system CryptoKit SHA-256; the readable dedup
  key is never stored. `ListenMutationStore` edit and delete each run in one
  immediate SQLite transaction. The edit writes the four processed columns,
  the optional rule and local chart-cache deletion together. The delete writes
  the hash tombstone, removes the listen, cascades its delivery rows and clears
  local chart caches.
- `insertListenRow` checks the hashed tombstone inside its existing insert
  transaction, so a deleted play is not reinserted by a restart or feed replay.
- `CaptureRuntime.editListen` and `deleteListen` publish only after the store
  commits. They update the loaded feed, close a track view whose key may have
  moved, reload track history after a delete, reload delivery state, and tell
  the chart read model to clear its local snapshot. A validation or storage
  error is thrown to the page or bar with no success state.
- History rows gain `Edit listen…` and `Delete listen…`. Edit opens the
  `history-edit` Settings page with Track, Artist, Album, Album artist, an
  off-by-default `Remember as rule` switch, the per-service consequences and
  Save/Cancel. Delete uses the pinned inline confirmation bar with the exact
  live service lines and the in-flight warning.
- `GLOSSARY.md` now defines Local edit, Remember as rule and Delete tombstone,
  and the Simple edit entry records the explicit-row-edit exception.
  `docs/accessibility/voiceover-checklist.md` records the new History menu,
  confirmation and edit-page requirements.
- The harness has `history-delete` and `history-edit` states, and the gate
  checks both reports. The harness's contextual edit route sets its Settings
  page directly; the date-jump refusal state is unchanged.

### Composition proof

The focused suite is 15 tests in `HistoryMutationTests`, plus the schema-11
update to `FeedbackStoreTests.migratesFromThePreviousSchemaAndKeepsHistory`.
The tests use real temporary SQLite files (several reopened after a close),
`FakeClock`, replayed playback and recording/scripted service adapters.

| Test | Covers |
| --- | --- |
| `anEditChangesOnlyTheProcessedValuesAndSurvivesRestart` | processed-only edit; stable raw, id, start, bundle, duration, artwork, dedup; reopen. |
| `aBlankTitleOrArtistIsRefusedWithoutChangingTheRow` | required fields and no partial write. |
| `anEditAndDeleteLeaveTrackFeedbackAndSharedArtwork` | feedback keyed by processed identity; no migration; shared artwork survives; deliveries gone after delete. |
| `aDeletedListenIsNotRecapturedButANewStartIsARepeat` | 64-hex tombstone with no readable title, artist, album or key; same play refused after reopen; new start captured. |
| `anEditRefreshesHistoryTrackAndChartReads` | History/track key moves; local chart caches cleared; corrected chart reload; track view after delete. |
| `aWaitingDeliveryKeepsItsStateAndSendsEditedValues` | waiting state, attempts and next attempt preserved; next batch carries edited metadata. |
| `aRetryingDeliveryKeepsItsBackoffAndSendsEditedValues` | retrying state, attempts, error and next attempt preserved; retry carries edited metadata. |
| `deliveredAbandonedAndZeroTargetRowsSurviveAnEditAndDisappearOnDelete` | delivered reference and abandoned reason survive an edit; all states disappear locally on delete; no extra service batch. |
| `oneEditLeavesDifferentMetadataOnDifferentServices` | one delivered copy keeps the original metadata while a waiting target sends the edit. |
| `aDeleteDuringAnInFlightSendDoesNotRecallIt` | a held send is not recalled; its row is gone and no second batch is sent. |
| `aCaptureConcurrentWithADeleteKeepsHistoryConsistent` | capture and delete interleave; one row remains, counts agree, one tombstone. |
| `aStorageFailureLeavesTheRowAndPublishesNoSuccess` | edit and delete throw, `state.failure` is storage, durable and loaded rows remain. |
| `aRememberedAlbumCorrectionAppliesToFuturePlaysOnThatAlbumOnly` | rule matches all raw fields; replaces only album; existing row untouched; same album corrected; different album not corrected. |
| `aLocalMutationMakesNoServiceWriteBackRequest` | real ListenBrainz adapter and scripted transport: edit and delete add no request. |
| `theNoticesNameEveryServiceStateAndTheInFlightLimit` | exact waiting, delivered, abandoned, no-target and in-flight copy. |

### Observable acceptance map (#82)

| # | Evidence |
| --- | --- |
| 1 | Contract above; owner agreed before the code commit; report commit `54d02c5` precedes the implementation commit `15fc972`. |
| 2 | History `Actions` menu has Edit/Delete; `history-edit` Settings page; `history-delete` confirmation; interactive AX walk. |
| 3 | Immediate transactions; reopened SQLite tests; local chart/track/History refresh; storage-failure test. |
| 4 | Exact edit-page and delete-bar copy; scripted transport proves no write-back. |
| 5 | 15 focused tests with real SQLite, controlled clock/playback and scripted transport. |
| 6 | Receipt-backed gate; interactive native delete and edit runs; AX readouts; separate evidence classes below. |
| 7 | No Tracklog identity, licence, credential, capability or dependency change; base `aa6bdeb`; unrelated work preserved. |

## Gate

Command:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Result: exit `0`, frozen gate `true`, clean before and after, at head
  `15fc972a3bceaa3b70eef6ee59d3408b1a8fe628`.
  - Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261104T083158Z-498715eb74f2.json`
  - Log: `/Users/ranokay/.local/state/agent-tools/gates/20261104T083158Z-498715eb74f2.log`
  - Duration: 1204.4 seconds.
  - The commits after this code head are documentation and evidence only; the
    source and test tree the gate checked is unchanged.
- `hk check --all`: SwiftFormat, SwiftLint and jactionlint clean; 0 SwiftLint
  violations in 294 files.
- `swift test --package-path Tests`: 642 tests in 97 suites; 51 media tests in
  7 suites.
- `droppykit build`: universal droplet, x86_64 + arm64.
- `droppykit validate`: `Ready to submit`.
- Every harness report `verdict: ok`, `problems: []`, active activation, every
  declared surface provided.
- New shot states: `history-delete`, `history-edit`. Existing History,
  Charts, shelf, HUD, settings and lock-screen states remain in the gate.
- Checked fixture reports are in `docs/reports/issue-82/reports/`; selected
  images are in `docs/reports/issue-82/`.

## Native observations

Interactive harness, normal `TRACKLOG_DEMO_STATE=playing` History, driven via
Cua Driver AX presses:

- Row menu: `Actions for Heart of Glass` opened the full menu with
  `Deliveries`, `Feedback`, `History` (`Edit listen…`, `Delete listen…`),
  `Block` and `Copy metadata`.
- Delete: `Delete listen…` on `Once in a Lifetime` opened
  `Delete “Once in a Lifetime”?` with
  `Retrying for ListenBrainz: that delivery will be discarded. A send already
  under way may still arrive.` and the Last.fm/local footer. `Cancel` closed
  the bar. Repeating and pressing `Delete` removed the row, changed the header
  from `6 listens` to `5 listens`, and removed its pending-queue entry with no
  service request.
- Edit: `Edit listen…` on `Heart of Glass` opened the Settings page prefilled
  with `Heart of Glass`, `Blondie`, `Parallel Lines` and an empty album artist.
  `Delivered to ListenBrainz: that copy stays.` was the service line. The run
  set Album to `Parallel Lines (Deluxe)`, turned `Remember as rule` on, and
  saved. History returned with
  `Heart of Glass, Blondie, Parallel Lines (Deluxe), 18:42`; the row kept its
  delivered value and id. The pinned now-playing heart changed from `Loved` to
  `Not loved`, as the accepted feedback consequence predicts.
- Fixture shots add the same delete confirmation over a retiring ListenBrainz
  delivery and the edit page over a delivered row.

Selected evidence:

- `history-delete.png` (cropped first notch panel; the right edge is the same
  shot-viewport limit recorded for issues #80 and #81),
  `history-delete-full.png`, `history-edit.png`,
  `delete-confirmation-interactive.png`, `history-edited.png`.
- AX readouts: `ax/method.md`, `ax/delete-confirmation.txt`,
  `ax/edit-page.txt`.

## Accessibility

AX-tree inspection is not audible VoiceOver. The checklist is
`docs/accessibility/voiceover-checklist.md`.

| Requirement | Result | Method |
| --- | --- | --- |
| Row remains one `AXButton` with its #26 label/value | Passed (AX) | `Heart of Glass, Blondie, Parallel Lines (Deluxe), 18:42`, value `delivered to ListenBrainz`. |
| Actions menu is separate and includes both history actions | Passed (AX) | `Actions for Heart of Glass` 28 × 28; menu items `Edit listen…`, `Delete listen…`. |
| Delete confirmation is read in order | Passed (AX) | Heading, removal sentence, waiting/in-flight line, footer, then separate buttons. |
| Cancel is explicit and does not mutate | Passed (interactive) | `Cancel` removed the bar; row and pending delivery stayed. |
| Delete is explicit and destructive | Passed (interactive) | `Delete` removed the row and its delivery; no default Return binding. |
| Escape closes the confirmation | Implemented, not exercised | `keyboardShortcut(.cancelAction)` on Cancel; no Escape key was sent in the AX walk. |
| Edit page fields are labelled and prefilled | Passed (AX) | Track/Artist/Album/Album artist values above. |
| Remember as rule is off by default and operable | Passed (AX + interactive) | CheckBox value `0`, then toggled on before Save. |
| Save is disabled until a change | Passed (AX) | Save exposed without an enabled action before the field changed. |
| Failed save keeps the page | Passed (test) | `aStorageFailureLeavesTheRowAndPublishesNoSuccess`; not forced interactively. |
| 24-point targets | Passed (style) | `DroppyQuietButtonStyle(size: .small)` and the 28 × 28 menu; no new icon-only target. |
| Full keyboard walk | Not run | AX presses and Return only; no Tab/Shift-Tab walk. |
| Audible VoiceOver | Not passed / blocked | No microphone audio and no accessibility-setting change; AX labels only. |
| Real Playground host load | Not passed | No installation outside the repository. |

## Evidence classes and limits

| Class | Result | Evidence |
| --- | --- | --- |
| Composition tests | Run | 642 tests / 97 suites; 15 focused mutation tests. These do not prove UI or runtime behaviour. |
| Harness output | Run | `history-delete` and `history-edit`; every report `problems: []`; selected images above. |
| Interactive harness AX | Run | Actions menu, cancel/confirm delete, edit-and-save walk; AX readouts above. |
| Real host load | **Not passed** | The droplet was not installed in Droppy Playground; no changes outside the repository. |
| Live service qualification | **Not passed** | No live credentials or production writes. The scripted transport proves zero write-back requests for edit/delete. |
| Audible VoiceOver | **Not passed / blocked** | AX-tree inspection only. |

No version bump, Store submission, credential change, capability change or
dependency was added. The database schema moved to 11 with the one migration
above. `droplet.json`, licensing and Tracklog branding are unchanged. Tests
remain in the sibling `Tests` package.

## Questions for the owner

None. The five contract items, the hashed tombstone, the in-flight warning and
the remember-as-rule option C were agreed before implementation; the accepted
consequences are recorded above.

