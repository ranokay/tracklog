# Issue #29 milestone 1 — worker report

- Base: `694b61eb1e8586e7add19a40aef933cfe997b7a6`
- Implementation head: `3d1cd60223d3ed9a89d3ce460e36cb73d0e27676`
- Branch: `feat/milestone-1-droppy-surfaces`
- State: all implementation and runtime checks that could be run under the
  authorized boundary are committed; the tree is clean. No push, PR or merge.

## Engine and package checks

Run in this order by `mise run gate`, through the frozen receipt runner:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Exit `0`, frozen gate `true`, head `3d1cd60`, clean before and after.
- Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261030T084954Z-68b763c66cf5.json`
- Log: `/Users/ranokay/.local/state/agent-tools/gates/20261030T084954Z-68b763c66cf5.log`

| Command | Exit | Observed |
| --- | --- | --- |
| `hk check --all` | 0 | SwiftFormat, SwiftLint and jactionlint clean |
| `swift test --package-path Tests` | 0 | 508 tests in 85 suites passed |
| `droppykit build` | 0 | universal droplet built; newest API call 1.19.0 |
| `droppykit validate` | 0 | `Ready to submit` |
| four harness shot runs | 0 | every report `problems: []`, `verdict: ok` |
| `python3 scripts/check_shot_report.py …` | 0 | four provided surfaces, both widget widths, every declared page present |

The four shot reports are `tracklog/shots/report.json`, and the `paused`,
`off`, and `feed-unavailable` reports in the matching subdirectories. The gate
checks each separately: activation active, no activation error, manifest
loaded, every declared surface `provided`, both widget widths declared, and
every declared surface PNG non-empty.

## Committed screenshots

Screenshots are in `docs/reports/issue-29/`:

- `shelf-playing.png`, `shelf-paused.png`, `shelf-off.png`,
  `shelf-feed-unavailable.png` — solo and paired at both widths in each state.
- `history-playing.png` — History with the pending list open and the pinned
  now-playing strip.
- `settings-root.png`, `settings-data.png`, `settings-about.png` — the root
  pane, Data, and About.
- `shelf-contrast.png`, `history-contrast.png` — the harness contrast override
  (`TRACKLOG_HARNESS_CONTRAST=increased`): solo header separator, row
  separators, and pending-panel borders.
- `hud.png` — the needs-sign-in card and strip.
- `export-sample.json` — the file written by the live export run.

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
  export HUD or file.
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
- No live Last.fm, Libre.fm or ListenBrainz smoke was run: no dedicated test
  account credentials are provisioned. All service proof is fixture- or
  fake-adapter-backed.
- Droppy Playground loading was not performed: installing the bundle writes
  outside the repository and was not authorized.
- The native write-error alert was not observed in the running app. The
  `SettingsExportReadFailure` path is unit-tested and the write catch is in
  `TracklogDroplet+Export.swift`, but the save-panel write-failure path remains
  unproven at runtime.
- The harness installs no settings page opener, so nested Settings page
  navigation was verified by mounting Data and About through the harness-only
  `TRACKLOG_HARNESS_SETTINGS_PAGE` override, not by following a live link.

## Notes

- `droplet.json` is unchanged: surfaces `shelf-widget`, `expanded-surface`,
  `settings-pane`, `hud`; capabilities `network-client`, `expanded-surface`,
  `hud`, `clipboard-write`, `apple-events`; `minAppVersion` 15.3.0; `minAPI`
  1.19.0 matches the build report.
- The CI workflow remains one pinned `macos-26` test workflow on push and pull
  request to `main`.
- The VoiceOver checklist is outside the submitted package at
  `docs/accessibility/voiceover-checklist.md`.
