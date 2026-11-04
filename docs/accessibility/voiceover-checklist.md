# Tracklog VoiceOver checklist

This checklist is run in the manual smoke before a submission. It lives outside
`tracklog/`, so it is not part of the submitted droplet package.

The automated harness has no accessibility checker. The gate report proves the
surfaces render; it does not prove VoiceOver speech, focus order or keyboard
reachability. Record what was actually run, and leave a requirement unpassed
when its runtime evidence is unavailable.

## How to run

1. Open the harness with `droppykit run` and load the state under test with the
   `TRACKLOG_DEMO_STATE` environment override (`playing`, `paused`, `off`,
   `feed-unavailable`).
2. For VoiceOver, start a VoiceOver session before the run. Do not change macOS
   accessibility settings or approve a system prompt as part of the run.
3. For keyboard, use Tab, Shift-Tab, Space, Return and the arrow keys only.
4. For Reduce Motion, use the harness environment override. For Increase
   Contrast, inspect the appearance with the contrast override. Record the
   actual method used.
5. Note every requirement as passed, unpassed or blocked, with the state and
   width it covered.

## Shelf widget, solo

Expected structure, in order:

1. One text element.
   - Playing label: `<title>, <artist>`.
   - Playing value: `<elapsed> of <duration>, scrobbles in <n> seconds, <n> waiting`.
   - Idle and off act as an open-History button.
2. Love. Exposes its toggle state (`Loved` / `Not loved`) and says whether a
   supporting connection is missing.
3. Queue. Opens History with the pending list expanded. Present when something
   is waiting.
4. More. Opens the pause, cancel/undo, Edit, Block, Stop scrobbling and Settings
   actions.

Checks:

- Artwork is not a separate stop.
- Updates while the widget is visible never auto-announce.
- The countdown updates on the sample cadence, not a per-second timer.
- Status copy is spoken as text, not only drawn as a colour or glyph.
- Every icon-only control has a 24×24 pt minimum target (28 preferred).

## Shelf widget, paired

Expected structure, in order:

1. One text element: title, then countdown.
2. Love.
3. Queue.

Checks:

- No solo header, artist, album, progress or More is present.
- No artist is spoken for the paired composition.
- The same state copy is present for paused, off, idle and feed unavailable.

## History takeover

Expected structure:

- Day headers are headings.
- Each row is one element: `<title>, <artist>, <album>, <time>` with a delivery
  value that names each service for a mixed state.
- A separate `Actions for <title>` menu holds the row actions.
- Pressing the row itself opens that track's local history. The row must expose
  the button trait and a default press action; its press area must stop before
  the separate Actions menu.
- The pending banner is one element plus its action button.
- The paused bar reads `Scrobbling paused until <time>` with a separate Resume
  button.
- Empty states are read.
- `Jump to date` opens the History settings page and reads as a button. If the
  host refuses the page, the takeover says `Settings could not be opened here.
  Open Tracklog's History settings to choose a date or edit a listen.` with a
  separate Dismiss button; it never fails silently.
- The `Actions for <title>` menu includes `Edit listen…` and `Delete listen…`.
  Delete opens an inline confirmation; Edit dismisses to the Settings edit page.
- The delete confirmation is one group read in order: `Delete "<title>"?`, the
  local-removal sentence, one line per live delivery state, the Last.fm/local
  footer, then separate `Cancel` and `Delete` buttons. Any waiting or retrying
  delivery says `A send already under way may still arrive.` Cancel is the
  default and Escape closes the confirmation without changing anything.
- The Settings History edit page carries Track, Artist, Album and Album artist
  fields, an off-by-default `Remember as rule` toggle, the per-service
  consequences, and separate Cancel and Save buttons. Track and Artist cannot
  be saved empty. A failed save stays on the page with its message.
- A date-jumped window reads `Showing from <date and time>` with `Show newer
  listens` and `Newest` buttons. It keeps the requested window rather than
  resetting to the newest feed.
- Track history reads the track title as a heading, the full `<n> listens`
  count, `First listened <date>`, and each row as `<title>, <artist>, <album>,
  <date and time>` with its delivery value. Back to History is a separate
  button. A track read failure reads `Track history unavailable` with Try again
  and Back to History; it never replaces the feed.

Checks:

- Delivery state pairs a glyph with spoken words; colour is never the only
  signal.
- The takeover is pointer-and-VoiceOver for traversal. Escape closes the delete
  confirmation. Full Tab traversal of the takeover remains a known gap: record
  `defaults read NSGlobalDomain AppleKeyboardUIMode` and leave the Tab-order
  check not run when it is `0`.
- Opening Settings dismisses the takeover.
- No text field exists anywhere in the takeover.

## Charts takeover

Expected structure:

- The section control names `History` and `Charts`; reopening the takeover starts at History.
- The Charts rail holds Service / On this Mac, the period choices, the source note and the supported total. The current-connection read switcher sits at the trailing end of the section row.
- Each ranked row is one element: `Rank <n>, <title>, <subtitle>, <count> listens` (or `plays`), with the source and period as its value.
- Saved age and Refresh are separate controls; Refresh has a 24 pt target and says what it reloads.
- Empty, statistics-not-ready, loading, no-connection, offline-with-saved-data and failed-without-data are separate spoken states with their own actions.
- Libre.fm says it has no charts API and names the local history fallback.

Checks:

- Source, period and chart-type controls expose their selected state, not only a fill.
- The range total is named as local listens or as an account total; an unavailable total is spoken as unavailable, never zero.
- `Custom` dismisses the takeover and opens the Settings page; no text field exists in the takeover.
- Saved rows remain with their original age after a failed refresh.
- The pinned strip keeps playing, paused, off and idle presentations on both sections.
- Icon-only controls meet the 24 pt target.
- The takeover remains pointer-and-VoiceOver only. Record the lack of a keyboard path as a known gap, not a pass.

## Loved takeover

Expected structure:

- The section control names `History`, `Charts` and `Loved`; the current
  connection switcher sits at the trailing end of the header.
- The `Loved` heading is followed by the source label `<service> · <account>`.
- Each row is one element: `<title>, <artist>, <album>` with the value
  `Loved on <service>`. No row press: the list has no detail page in this
  milestone.
- Each row's heart is a separate button, `Unlove <title>`, with a 24 pt target
  and the hint that it removes the love on the service and every connected
  service that supports love.
- Loading, empty, all-omitted-metadata, unsupported, no-connection, failed and
  refresh-failure states are separate spoken states with their own actions.
  `Loved tracks unavailable` is not an empty listen; `No loved tracks` is only
  a successful empty read.
- A rate limit says when to try again and does not offer an ignored retry;
  once the wait ends the refresh and the action become available again.
- A first read rejected with 401/403 reads `<service> rejected the saved
  credential. Sign in on Services.` while Services still shows the connection
  signed in.
- A row action the source connection did not confirm stays in the list and is
  explained by `Could not unlove “<title>” on <service>. The service did not
  confirm the change.` with a separate Dismiss button; Dismiss removes only the
  notice.
- A refresh failure over existing rows keeps them and reads `Could not refresh
  loved tracks. Showing the last loaded list.` with the failure and Try again.
- A successful read whose entries all lack metadata reads `Loved tracks need
  metadata` with the omitted count; it never claims the account has no loved
  tracks.
- Unlove is offered only when the current connection is enabled, signed in and
  supports love. A paused, signed-out or unsupported connection says why in a
  separate notice.

Checks:

- The list never claims a range-love total or a historical love event.
- Rows are scoped to the current connection; switching the switcher clears the
  old rows before the new read.
- The now-playing strip stays pinned; its heart removes a matching Loved row
  and a love re-reads the first page.
- The takeover remains pointer-and-VoiceOver only.

## Settings

Settings is the only typed surface and must be fully keyboard-operable.

Checks:

- Root `scrobbling` and the pages `services`, `edits`, `blocks`, `data`,
  `about`, plus `apps`, `charts`, `history`, `history-edit`,
  `lastfm-credentials`, `add-service` and per-connection pages are reachable.
  `history-edit` is contextual: it is opened by a History row's Edit action.
- Every control is reachable with Tab/Shift-Tab and operable with Space,
  Return or the arrow keys.
- History holds one `Date and time` picker and `Show in History`. The picker is
  the only place a jump date is typed; Show in History dismisses to the
  positioned takeover.
- Token and secret fields are secure and never show a saved value back.
- Data names the live media source, Copy diagnostics works, and Export settings
  is present; Import is absent.
- About shows the licence, Droppy/DroppyKit, Last.fm attribution and the
  version.
- No droplet icon or droplet-name header is repeated inside the pane.

## HUD

Expected speech, exactly as presented:

- `Last.fm needs sign-in. Scrobbles are waiting.`
- `Last.fm and ListenBrainz need sign-in. Scrobbles are waiting.`
- `12 scrobbles are waiting for Last.fm, which is not accepting them.`
- `12 scrobbles are waiting across 2 services.`
- `Last.fm is rate limited. Retrying automatically.`
- `2 services are rate limited. Retrying automatically.`
- `Media feed unavailable. Playback will not be scrobbled.`
- `Loved on Last.fm.` / `Loved on 3 services.`
- `Unloved on Last.fm.`
- `Hated on ListenBrainz.`
- `Blocked <title>. It will not scrobble again.`
- `Scrobbling paused for 1 hour.` / `Scrobbling paused until 14:00.`
- `Scrobbling resumed.`
- `Settings exported.`
- `Last.fm reconnected. 4 scrobbles sent.`
- `Last.fm is accepting scrobbles again. 12 sent.`

Checks:

- The announcement fires on presentation, not on a view rebuild.
- A repeat with the same id replaces in place.
- Pre-existing states at activation are silent.
- Successful scrobbles and now-playing starts are silent.

## Search palette

Expected structure, in order:

1. Search field `Search the Last.fm catalogue`, focused on open, plus Clear and
   Close buttons.
2. The `Last.fm catalogue` source label and the search status.
3. Group headers for Artists, Albums, Tracks and Loved. Each header is a button
   with an expanded/collapsed value.
4. Up to 5 result rows per group and a `Show more <group>` row; Return toggles
   a header or expands the group.
5. A credentials banner when the app pair is missing or rejected, with an
   `Open Settings` button.
6. A footer that says whether Play is configured.

Checks:

- The field keeps focus while Up and Down move through headers and rows.
- VoiceOver hears the selected row through the palette's announcement, not by
  moving focus out of the field.
- When the query settles, one summary names every group's count, no-match,
  failed or unavailable state.
- A group header and a `Show more` row are reachable with Up/Down; Return
  toggles or expands them.
- Esc clears the text first and closes only when the field is empty.
- While an input method has marked text, Return, arrows and Esc stay in the
  field editor and run no palette action.
- The takeover has no text field; its search button only opens the palette.
- Group failures are announced and read, each with its own Try again.

## Motion, contrast and type

- Reduce Motion turns slides and pops into crossfades; no looping or ambient
  motion; transitions under 200 ms.
- Increase Contrast strengthens separators and borders, not only fills.
- Colours are system semantic colours.
- Text uses semantic text styles, not fixed point sizes.
- Icon-only controls meet the 24 pt target.

## Run record

Fill in for each smoke:

| Surface | State / width | VoiceOver | Keyboard | Motion / contrast | Notes |
| --- | --- | --- | --- | --- | --- |
| Shelf widget | | | | | |
| History | | | | | |
| History navigation | | | | | |
| Charts | | | | | |
| Loved | | | | | |
| Search palette | | | | | |
| Settings | | | | | |
| HUD | | | | | |

Known limitation: actual VoiceOver speech cannot be established by the AX tree
inspection used for implementation. If a VoiceOver session was not available,
mark the VoiceOver rows unpassed and do not call the milestone complete.
