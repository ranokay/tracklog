# Issue #29 milestone 1 — worker report

- Base: `694b61eb1e8586e7add19a40aef933cfe997b7a6`
- Implementation head: `6d54d4e` (PR #69, draft)
- Branch: `feat/milestone-1-droppy-surfaces`
- State: pushed. The gate passes at this head; the live service smoke, Playground
  load and the accessibility run are recorded below.

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

### Final gate at `6d54d4e`

`mise run gate` ran on the PR head and exited 0:

| Command | Observed |
| --- | --- |
| `hk check --all` | SwiftFormat, SwiftLint and jactionlint clean |
| `swift test --package-path Tests` | 510 tests in 87 suites passed |
| `droppykit build` | universal droplet; newest API call 1.19.0 |
| `droppykit validate` | ready to submit |
| harness shots | every report `problems: []`, every declared surface provided |

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
  Nested-page switches did not enter the Tab chain with Full Keyboard Access
  off. The authorized rerun with `AppleKeyboardUIMode = 3` reached the nested
  rows and controls; see the accessibility run below.
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

The first group was run in the harness against the in-memory demo store and
offline adapters. The live smoke below was run against the built droplet in
Droppy Playground with real service accounts.

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

### Live service smoke

Bundle: `.build/Tracklog.droplet` from `6d54d4e`, loaded in Droppy Playground
(Store row switched on). The song was BABYMONSTER — “Woke Up In Tokyo (RUKA &
ASA)”, 2:23, played from Music.

- Capture stored one local listen with the track-start timestamp and delivered
  it to all three connections.
- Last.fm accepted the scrobble (recent tracks showed it at 11:51 UTC) and it
  was deleted through the Last.fm library UI afterwards. Last.fm has no
  unscrobble API method.
- ListenBrainz accepted the listen (`listened_at` 1793361105, `recording_msid`
  `b797f653-fcaa-44ad-bb5d-ff1830d9faef`); `POST /1/delete-listen` was queued
  and processed at the top of the hour.
- Libre.fm accepted the scrobble. Libre.fm (GNU FM) has no user-facing or API
  delete path; `LibreFMAdapter` already declares `supportsDelete: false`.
  The three test scrobbles (the smoke track plus the two tracks Music played
  next) remain on the test account and cannot be removed by Tracklog.

The run found a real defect: the helper's `get --now` repeats the track-start
timestamp and can keep `elapsedTime` at zero, so the engine measured no played
time and a short track never crossed its threshold. `MediaSample.observedAt`
now carries the poll clock; the engine accumulates from it and the helper
derives the position from it. Regression tests cover the payload and the
engine.

### Accessibility run

- Full Keyboard Access was enabled (`AppleKeyboardUIMode = 3`) for the run and
  restored to its prior unset state afterwards.
- Tab traversal reached every control in the Tracklog settings pane:
  scrobbling, Pause, Send now playing, Minimum length, Apps, Services, Edits,
  Blocks, Data, About.
- On the Services page, Tab reached the ListenBrainz, Last.fm and Libre.fm
  connection rows, Add service and Set up Last.fm app credentials. Space
  activated a connection row; the Last.fm detail page then exposed its
  checkbox, Use for reading, Sign in with Last.fm and Unlink to Tab.
- VoiceOver was enabled for the run and turned off afterwards. The VoiceOver
  cursor moved through the Last.fm detail controls in order (checkbox, Use for
  reading, Sign in with Last.fm, Unlink), so the labels and focus order are
  reachable. The caption panel was not enabled: toggling it raised a system
  authorization prompt, which was cancelled. Speech was therefore verified
  through the VoiceOver cursor and AX labels, not captured as audio.

## Explicit completion blockers

- Actual VoiceOver speech was not captured as audio. The caption panel needs a
  system authorization prompt; the run used the VoiceOver cursor and AX labels
  instead.
- Libre.fm cannot delete individual scrobbles. The three smoke scrobbles remain
  on the test account; only Libre.fm support or account deletion can remove
  them.
- The Last.fm deletion is manual (no unscrobble API); it was done through the
  library UI for this run.

## Notes

- `droplet.json` is unchanged: surfaces `shelf-widget`, `expanded-surface`,
  `settings-pane`, `hud`; capabilities `network-client`, `expanded-surface`,
  `hud`, `clipboard-write`, `apple-events`; `minAppVersion` 15.3.0; `minAPI`
  1.19.0 matches the build report.
- The CI workflow remains one pinned `macos-26` test workflow on push and pull
  request to `main`.
- `docs/accessibility/voiceover-checklist.md` is outside the submitted package.
