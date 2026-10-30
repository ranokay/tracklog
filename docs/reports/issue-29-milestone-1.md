# Issue #29 milestone 1 — worker report

- Base: `694b61eb1e8586e7add19a40aef933cfe997b7a6`
- Implementation head: `e783eb2f408b00f7fd059080476a513328476c48`
- Branch: `feat/milestone-1-droppy-surfaces`
- State: implementation, evidence and this report are committed locally; the
  tree is clean. No push, PR or merge.

## Engine and package checks

Run in this order by `mise run gate`, through the frozen receipt runner:

```sh
/Users/ranokay/.agents/tools/run gate_run -- mise run gate
```

- Exit `0`, frozen gate `true`, head `e783eb2`, clean before and after.
- Receipt: `/Users/ranokay/.local/state/agent-tools/gates/20261030T103420Z-f8e11db4a37d.json`
- Log: `/Users/ranokay/.local/state/agent-tools/gates/20261030T103420Z-f8e11db4a37d.log`

| Command | Exit | Observed |
| --- | --- | --- |
| `hk check --all` | 0 | SwiftFormat, SwiftLint and jactionlint clean |
| `swift test --package-path Tests` | 0 | 509 tests in 86 suites passed |
| `droppykit build` | 0 | universal droplet built; newest API call 1.19.0 |
| `droppykit validate` | 0 | `Ready to submit` |
| four harness shot runs | 0 | every report `problems: []`, `verdict: ok` |
| `python3 scripts/check_shot_report.py …` | 0 | four provided surfaces, both widget widths, every declared page present |

## Round-2 findings

- **F5 closed** — Paired paused and feed-unavailable cards retain the pending
  badge; paired remains only the 48 pt sleeve, title/countdown, Love and Queue.
  The takeover strip and paused/off state-bar overflow expose Pause, Edit,
  Block, Stop scrobbling and Settings. Runtime AX showed the full strip menu.
- **F6 closed** — Master-off takes precedence over `pausedUntil`. Runtime:
  Pause → Stop → History showed `Scrobbling is off` / `Turn on`; Turn on
  returned to the preserved pause with Resume.
- **F7 fixed** — `exportOperationID` scopes cleanup to the operation that owns
  the task. An old defer cannot clear a newer task, panel or alert. Panel
  clearing is identity-checked; `deactivate()` cancels the task, closes the
  save panel, and now also closes an open native alert with
  `NSApp.abortModal()` only when `NSApp.modalWindow` is that exact alert
  window; a host modal nested above is never aborted. Runtime: Reload while the
  save panel was open closed it, produced no Exported HUD, and the new
  activation continued. The same Reload while the write-error alert was open
  removed the alert and all dialogs; Activity showed no Exported HUD.
  The pending-read/new-export/old-completion sequence is enforced by the
  operation-id checks rather than separately instrumented; that specific
  sequence was not observed as a timed runtime trace.
- **F8 partially fixed** — Root anchors and the SDK page-link route are correct.
  The harness uses the public `DropletSettingsPageOpener`; every page link now
  goes through `TracklogSettingsPageLink`, which makes the row focusable and
  forwards Return/Space to that opener. Runtime keyboard evidence:
  `Tab` once focused `AXButton "Apps"`; `Return` opened the Apps page.
  `Tab` twice focused `AXButton "Services"`; `Return` opened Services.
  Nested-page switches did not enter the Tab chain: `Tab` stayed on the search
  `AXTextField` on Apps. `defaults read NSGlobalDomain AppleKeyboardUIMode` is
  unset (default 0, Full Keyboard Access off); changing it is outside the
  authorization. This nested-control keyboard check remains unpassed.
- **F9 closed (as configured-path evidence)** — Reduce Motion selects the
  0.16 s opacity transition (`AccessibilityMotion.reducedCrossfade`) and the
  Core test asserts it is below 200 ms. The committed log records
  `Tracklog motion: reduced crossfade 0.16s` when the reduced runtime mounted;
  the log is configured-path evidence, not a measured animation duration.
  Cancel/Undo was exercised in the reduced runtime, but no frame timing was
  captured.
- **F10 closed** — A real write failure through the running flow (immutable
  target in a writable folder) showed the native alert, left the target file
  unchanged, and produced no Exported HUD.

## Committed screenshots

Screenshots are in `docs/reports/issue-29/`:

- `shelf-playing.png`, `shelf-paused.png`, `shelf-off.png`,
  `shelf-feed-unavailable.png`
- `history-playing.png`
- `settings-root.png`, `settings-data.png`, `settings-about.png`
- `shelf-contrast.png`, `history-contrast.png`
- `hud.png`
- `export-write-error.png`
- `export-sample.json`
- `reduced-motion.log`

## Runtime observations

These were run in the harness against the in-memory demo store and offline
adapters. They prove control-to-runtime behavior and visible state; they do
not prove a real service accepted a scrobble.

- Solo AX element: `Heart of Glass, Blondie` with value
  `1:18 of 3:45, scrobbles in 107 seconds, 2 waiting`; Love, Queue and More are
  separate elements. Paired exposes title and countdown, then Love and Queue.
- Love/Unlove toggled the heart. Widget overflow opened with Cancel, Pause,
  Edit, Block, Stop and Settings; Pause/Resume and Stop changed the widget and
  state bar as prescribed.
- Capture crossed the threshold and added history and pending delivery rows;
  Cancel/Undo restored the session; Block removed now playing and prevented
  the next history row.
- Export success wrote the versioned file and raised the Exported HUD;
  cancellation was silent; the immutable-target write showed the native alert.
- History rows expose a delivery value and the separate
  `Actions for Heart of Glass` menu.
- HUD tests assert the exact spoken strings, mechanics, silence and recovery.

## Explicit completion blockers

- Actual VoiceOver speech was not run; the AX tree and keyboard sequence were
  inspected instead.
- Nested Settings control keyboard traversal remains unpassed because Full
  Keyboard Access is off (`AppleKeyboardUIMode` unset/0) and changing the OS
  setting is outside the authorized boundary.
- No live Last.fm, Libre.fm or ListenBrainz smoke: no dedicated credentials.
- Droppy Playground loading was not performed under the outside-repository
  boundary.

## Notes

- `droplet.json` is unchanged: surfaces `shelf-widget`, `expanded-surface`,
  `settings-pane`, `hud`; capabilities `network-client`, `expanded-surface`,
  `hud`, `clipboard-write`, `apple-events`; `minAppVersion` 15.3.0; `minAPI`
  1.19.0 matches the build report.
- The CI workflow remains one pinned `macos-26` test workflow on push and pull
  request to `main`.
- `docs/accessibility/voiceover-checklist.md` is outside the submitted package.
