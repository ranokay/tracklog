# Issue #29 milestone 1 — worker report

- Base: `694b61eb1e8586e7add19a40aef933cfe997b7a6`
- Implementation head: `9488ed2e4a918be9f5dd4a43072b63b90e89a7cf`
- Branch: `feat/milestone-1-droppy-surfaces`
- State: implementation, evidence and this report are committed locally; the
  tree is clean. No push, PR or merge.

## Engine and package checks

Run in this order by `mise run gate`, through the frozen receipt runner:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Exit `0`, frozen gate `true`, head `9488ed2`, clean before and after.
- Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261030T094655Z-ad8eadff2f08.json`
- Log: `/Users/ranokay/.local/state/agent-tools/gates/20261030T094655Z-ad8eadff2f08.log`

| Command | Exit | Observed |
| --- | --- | --- |
| `hk check --all` | 0 | SwiftFormat, SwiftLint and jactionlint clean |
| `swift test --package-path Tests` | 0 | 509 tests in 86 suites passed |
| `droppykit build` | 0 | universal droplet built; newest API call 1.19.0 |
| `droppykit validate` | 0 | `Ready to submit` |
| four harness shot runs | 0 | every report `problems: []`, `verdict: ok` |
| `python3 scripts/check_shot_report.py …` | 0 | four provided surfaces, both widget widths, every declared page present |

The four shot reports are `tracklog/shots/report.json`, and the `paused`,
`off`, and `feed-unavailable` reports in the matching subdirectories. The gate
checks each separately: activation active, no activation error, manifest
loaded, every declared surface `provided`, both widget widths declared, and
every declared surface PNG non-empty.

## Round-1 findings

- **F5** — The paired widget keeps its 48 pt sleeve/title/countdown/Love/Queue
  composition and no solo header or overflow. Its paused and feed-unavailable
  shots retain the pending badge (`2 scrobbles waiting` in the AX tree and the
  paired image). The takeover strip and paused/off state bar now expose the
  same action menu: Pause (30 minutes/1/2/4 hours), Edit, Block, Stop
  scrobbling and Settings, with Resume in the paused bar. Runtime AX opened the
  strip menu and showed every item.
- **F6** — The history bottom bar checks the master switch before the pause.
  Runtime sequence: Pause, then Stop scrobbling, then History showed
  `Scrobbling is off` / `Turn on`; Turn on returned to
  `Scrobbling paused until 11:59` with Resume because the pause is
  intentionally preserved; Resume then cleared it.
- **F7** — Export is now an owned task; `deactivate()` cancels it, closes its
  save panel, and clears the harness page. Every continuation checks the
  activation identity, cancellation and `host != nil` before opening UI,
  writing or showing the HUD. Starting another export while one is active is
  ignored. Runtime: opening the export panel and pressing Reload closed the
  panel and produced no `hud.confirm.export`.
- **F8** — Search entries now point at real `.id` anchors on the root page
  (`scrobbling`, `apps`, `services`, `edits`, `blocks`, `data`, `about`). The
  harness installs the public `DropletSettingsPageOpener` environment and routes
  its page links through `makeSettingsPage`; clicking Data in the running
  harness opened the Data page. Root links are focusable. Full root/nested
  keyboard traversal could not be confirmed under the harness focus policy
  without changing the OS full-keyboard-access setting, which is outside the
  authorized boundary; this remains an explicit unpassed item.
- **F9** — Added `TracklogMotion`: normal motion remains the SDK transition;
  Reduce Motion uses a 0.16 s crossfade for droplet-owned state/control swaps.
  A 0.16 s contract constant is unit-tested below 200 ms. Runtime with
  `TRACKLOG_HARNESS_REDUCE_MOTION=1` logged
  `Tracklog motion: reduced crossfade 0.16s` when the strip mounted; the log is
  committed at `docs/reports/issue-29/reduced-motion.log`.
- **F10** — Reproduced a real write failure through the running export flow by
  saving over an immutable file with a writable parent folder. The native alert
  showed `Settings could not be exported` / `You don’t have permission to save
  the file “Tracklog Settings.json” in the folder “export”`; the target file was
  unchanged and Activity showed no `hud.confirm.export`. Screenshot:
  `docs/reports/issue-29/export-write-error.png`.

## Committed screenshots

Screenshots are in `docs/reports/issue-29/`:

- `shelf-playing.png`, `shelf-paused.png`, `shelf-off.png`,
  `shelf-feed-unavailable.png` — solo and paired at both widths in each state.
  The paused and feed-unavailable paired cards show the pending badge.
- `history-playing.png` — History with the pending list open and the pinned
  now-playing strip.
- `settings-root.png`, `settings-data.png`, `settings-about.png` — the root
  pane, Data, and About.
- `shelf-contrast.png`, `history-contrast.png` — the harness contrast override
  (`TRACKLOG_HARNESS_CONTRAST=increased`): solo header separator, row
  separators, and pending-panel borders.
- `hud.png` — the needs-sign-in card and strip.
- `export-write-error.png` — the native write-error alert.
- `export-sample.json` — the file written by the successful export run.
- `reduced-motion.log` — the reduced-motion runtime marker.

## Runtime observations

These were run in the harness against the in-memory demo store and offline
adapters. They prove control-to-runtime behavior and visible state; they do
not prove a real service accepted a scrobble.

- Solo AX element: `Heart of Glass, Blondie` with value
  `1:18 of 3:45, scrobbles in 107 seconds, 2 waiting`; Love, Queue and More are
  separate elements. Paired exposes title and countdown, then Love and Queue.
- Love/Unlove toggled the heart and its selected/loved value.
- Widget overflow opened with Cancel, Pause (30 minutes/1/2/4 hours), Edit,
  Block, Stop scrobbling and Settings. Pause produced the paused widget and
  state copy with Resume; Resume restarted the scripted source and the next
  sample returned the widget to playing.
- The scripted source crossed the threshold: History went from 6 to 8 listens
  and the pending queue from 2 to 3, proving capture and delivery-row creation
  in the harness store.
- Cancel produced `Tracking cancelled` with Undo; Undo restored the session
  from the same played time.
- Block from a History row and from the widget raised
  `present "hud.confirm.block"`; the next scripted sample produced no now
  playing and no new history row. Existing rows were untouched.
- Stop scrobbling changed the widget to `Scrobbling is off` with the queue
  badge intact.
- Opening Settings from the widget opened the pane.
- The queue badge logged `present "history"` to the host.
- Export success wrote a versioned JSON file and logged
  `present "hud.confirm.export"`. Cancelling the save panel closed it without an
  export HUD or file. The immutable-target run showed the native alert and no
  export HUD.
- History rows expose `AXUnknown` with label
  `Heart of Glass, Blondie, Parallel Lines, 10:07` and value
  `waiting for ListenBrainz`; a separate `Actions for Heart of Glass`
  `AXMenuButton` exposes the row menu.
- The HUD tests assert the exact spoken strings, card/strip mechanics, silent
  events, repeats and recovery.

## Explicit completion blockers

These are unpassed requirements, not passes:

- Actual VoiceOver speech was not run. The OS accessibility setting was not
  changed under the outside-repository boundary; the AX tree and keyboard
  interaction were inspected instead.
- Full keyboard traversal of the root and nested Settings links was not
  confirmed under the harness focus policy; the page-link route itself was
  exercised with the public opener environment.
- No live Last.fm, Libre.fm or ListenBrainz smoke was run: no dedicated test
  account credentials are provisioned. All service proof is fixture- or
  fake-adapter-backed.
- Droppy Playground loading was not performed: installing the bundle writes
  outside the repository and was not authorized.

## Notes

- `droplet.json` is unchanged: surfaces `shelf-widget`, `expanded-surface`,
  `settings-pane`, `hud`; capabilities `network-client`, `expanded-surface`,
  `hud`, `clipboard-write`, `apple-events`; `minAppVersion` 15.3.0; `minAPI`
  1.19.0 matches the build report.
- The CI workflow remains one pinned `macos-26` test workflow on push and pull
  request to `main`.
- The VoiceOver checklist is outside the submitted package at
  `docs/accessibility/voiceover-checklist.md`.
