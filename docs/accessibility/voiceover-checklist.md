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
- The pending banner is one element plus its action button.
- The paused bar reads `Scrobbling paused until <time>` with a separate Resume
  button.
- Empty states are read.

Checks:

- Delivery state pairs a glyph with spoken words; colour is never the only
  signal.
- The takeover is pointer-and-VoiceOver only. The droplet claims no keyboard
  path until the menu bar extra lands. Record this as a known gap, not a pass.
- Opening Settings dismisses the takeover.
- No text field exists anywhere in the takeover.

## Settings

Settings is the only typed surface and must be fully keyboard-operable.

Checks:

- Root `scrobbling` and the pages `services`, `edits`, `blocks`, `data`,
  `about`, plus `apps`, `lastfm-credentials`, `add-service` and per-connection
  pages are reachable.
- Every control is reachable with Tab/Shift-Tab and operable with Space,
  Return or the arrow keys.
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
| Settings | | | | | |
| HUD | | | | | |

Known limitation: actual VoiceOver speech cannot be established by the AX tree
inspection used for implementation. If a VoiceOver session was not available,
mark the VoiceOver rows unpassed and do not call the milestone complete.
