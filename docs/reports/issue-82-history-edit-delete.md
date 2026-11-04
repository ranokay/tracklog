# Issue #82 local history editing and deletion — worker report

- Base: `aa6bdeb257b24dd94b33b8a5f8295be5affff908` (`feat: build history navigation (#112)`)
- Branch: `feat/history-edit-delete-82`
- Scope: ticket 6 of the approved breakdown, part of #76. It builds matrix rows
  `NP-08` (edit an existing scrobble) and `NP-09` (delete an existing scrobble)
  for local history and leaves qualified remote write-back to its dependent
  tickets.
- State: the owner agreed this contract in the implementation run before any
  code changed. Implementation, tests, harness evidence and the gate follow in
  later commits.

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

- Title: `Delete "<title>"?`
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

## Implementation plan

- Migration 11 adds `deleted_listens(dedup_hash PRIMARY KEY, deleted_at)`.
- `ListenMutationStore` writes an edit (plus an optional rule and local chart
  cache invalidation) in one immediate transaction, and a delete (tombstone,
  listen, cascaded deliveries and cache invalidation) in another.
- The runtime exposes edit and delete, publishes success only after commit,
  refreshes History, track history, deliveries and local charts, and surfaces
  validation or storage failure without a success state.
- History rows gain `Edit listen...` and `Delete listen...`; editing opens a
  Settings page with four fields and the optional rule; deletion uses the
  pinned confirmation bar.
- Tests use real temporary SQLite reopened across restarts, a controlled clock,
  replayed playback and scripted service transport, covering waiting,
  retrying, delivered, abandoned and zero-target listens, failures, duplicate
  protection and concurrent capture.
- The harness renders the edit page and delete confirmation and the gate
  checks every report. The native flow is driven through the harness
  accessibility tree and recorded separately from fixtures.

## Gate

Pending implementation.
