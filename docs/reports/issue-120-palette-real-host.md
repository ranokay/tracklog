# Issue #120 search palette in the real host — worker report

- Base: `0b3841640271b26a99dbac9156931246ac15bf96`
- Branch: `fix/takeover-palette-crash`
- Scope: the real-host search palette crash and the input, artwork, shelf and
  reopen findings that followed it. This report does not close #76.

## Root cause

`~/Library/Logs/Droppy/exceptions.log` records both real-click crashes with the
same exception:

```text
NSInternalInconsistencyException
Reason: Invalid parameter not satisfying: [self canBecomeMainWindow]
```

The frames are host `_changeJustMain` → `DroppyPanelActivation.begin` →
`TracklogSearchPaletteController.open` → `TracklogDroplet.openSearchPalette`.
`PalettePanel` overrode `canBecomeMain` to `false`, while `DroppyPanelActivation`
makes the panel key **and main**. The host catches the exception, then terminates
because continuing after a main-thread exception corrupts SwiftUI observation
state. The `.ips` `abort()` is downstream of that.

The fix is `PalettePanel.canBecomeMain = true`. The issue's unconfirmed guess
about presenting during the gesture was not the abort cause; the panel is still
prepared inside the gesture and presented on the next run-loop turn, so the
presentation also leaves the gesture.

## Harness fixture

The harness passed this before because `DroppyPanelActivation.begin` returns
`nil` there. The fixture installs the host contract through
`DroppyKitSurfaceBridge.installPanelActivationProvider`, gated on
`host.environment.isHarness` and `TRACKLOG_HARNESS_HOST_PANEL_ACTIVATION=1`:

- it activates the app, makes the panel key and main;
- when `panel.canBecomeMain` is false it raises the same
  `NSInternalInconsistencyException` with the host's reason string.

`TracklogDroplet.runPaletteContractCheck()` drives the palette through
`openSearchPalette()` and asserts the panel is key and main, the activation
began, the key monitor and observers are installed, and close clears the panel
so a second open works. `scripts/panel_check.sh` runs it; `scripts/gate.sh`
calls that script after the surface shots.

## Unfixed run

Scripted check:

```text
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'Invalid parameter not satisfying: [self canBecomeMainWindow]'
...
5 TracklogSearchPaletteController.open
6 TracklogDroplet.openSearchPalette
7 TracklogDroplet.runPaletteContractCheck
exit=134
```

Accessibility press, no real pointer, through the takeover's search button:

- The panel window existed (680 × 560, layer 3, title “Search and play”) but
  WindowServer reported `is_on_screen: false`, and its accessibility tree was
  empty (`degraded_reason: ax_window_unresolved`).
- The same `fn+b`, `fn+l`, `fn+o` key events used on the fixed build
  (`cua-driver.hotkey`, route `synthetic_events`) typed “blo” into the main
  harness window's sidebar field (`AXTextField = "blo"`), not the palette. The
  palette stayed at “Type at least two characters”; every group stayed
  “Not searched”.
- Rows rendered after the press: the takeover was switched from History to
  Charts and back, which rebuilt the History rows. The rebuilt rows still showed
  their covers. The issue's row symptom did not reproduce in this fixture.
- The shelf widget page, rendered after the press, showed the neutral note
  sleeve. The mechanism is an inference: the exception leaves the panel set and
  the activation nil, and the widget's decode produced no image. The
  `ArtworkSleeve` decode path was not logged, so this is not a proven `onAppear`
  failure.
- The palette could not be closed through accessibility because it had no AX
  surface, so the widget-row reopen could not be observed in this run.

## Fixed run

Scripted check:

```text
panel check: passed
exit=0
```

Accessibility press, no real pointer:

- The panel window was 680 × 560 at layer 3 (`.floating`), on screen, with an
  accessibility tree containing the field, the close button and the groups. Its
  frame was x 560, y 315: below the host's measured shelf extent, whose page pill
  bottom is 258. The harness has no real shelf; the contract check asserts the
  frame clears the computed shelf clearance and still fits a 1280 × 600 screen.
- The same `fn+b`, `fn+l`, `fn+o` key events used on the unfixed build
  (`cua-driver.hotkey`, route `synthetic_events`) typed “blo” into the palette
  field. The sidebar field stayed empty (`AXTextField = "Search"`), and the
  groups left “Not searched”: Artists, Albums and Tracks each showed 10 results.
  An accessibility-set value also ran the search; the view's existing
  `onChange` is enough once the exception is gone.
- Rows rendered after the press: the takeover was switched from History to
  Charts and back, which rebuilt the History rows. The rebuilt rows kept their
  covers.
- The close button closed the panel; the window list then contained only the
  main harness window.
- The shelf widget page showed the red cover, not the neutral sleeve.
- Pressing the widget row after the palette closed recorded
  `present "history"` at 16:51:34.228 on the Activity page.

No `ArtworkSleeve` change was made. The unfixed fixture did not reproduce the
row symptom, so the row half is left to the real host. The widget's neutral
sleeve and the fixed cover are consistent with the exception being the cause,
but the widget mechanism remains an inference because the decode path was not
logged.

## Shelf placement

The supervisor's real-host run on `b1fbef9` showed the palette at layer 101 and
the shelf at layer 100, with the palette's z_index higher, and the shelf still
composited on top: the widget card covered the middle of the search field and
the page pill sat over the first result row. The shelf stayed open while the
palette was up and collapsed only after the palette closed. A higher window
level is therefore not the fix.

The palette is now placed below the shelf instead:

- The real-host shelf measured the shell bottom at about 216 and the page pill
  bottom at about 258, with the shelf window at x 450 and 900 wide.
- `shelfClearance` computes the shell from `DroppyShellMetrics`: top inset
  (`closedHeight + 10` on a notch, 16 on an island) + the Tracklog widget's
  150pt card + the 1.5pt slot on both edges + the 16pt bottom inset, plus 48pt
  for the page pill. With a 32pt notch this is 259, matching the measured 258.
- The palette starts `shelfClearance + 12` below the visible frame top. On the
  owner's 1800 × 1169 screen the visible frame top is 44, so the frame is
  x 560, y 315, 680 × 560. The measured page pill bottom is 258; the palette
  starts 57pt below it, and the field and results follow.
- The height is clamped to the space below the clearance and the frame to the
  visible frame. On a synthetic 1280 × 600 screen the contract check gets a
  680 × 313 frame starting at y 271, inside the screen and below the clearance;
  the palette's own minimum is 320 × 240.

## What changed

- `TracklogSearchPaletteController`: `canBecomeMain = true`; the palette is
  placed below the host shelf's extent instead of relying on the window level.
  `shelfClearance` is the shell's top inset, this droplet's 150pt widget card,
  the slot and bottom inset, plus 48pt for the host's page pill below the shell.
  The palette height is clamped to the space below that clearance, and the frame
  is clamped to the visible frame. `prepare()` / `present()` /
  `presentAfterGesture()` split with a cancellable pending presentation;
  harness contract snapshot with the frame.
- `TracklogDroplet+Search`: `openSearchPalette()` prepares inside the gesture
  and presents on the next run-loop turn; a second summon closes a prepared or
  open palette.
- `TracklogHarness`: host-contract provider and `--panel-check`.
- `TracklogDroplet+HarnessPalette`: harness-only contract check.
- `scripts/panel_check.sh`, `scripts/gate.sh`: the regression guard runs in the
  gate after the surface shots.

## Checks

- `mise run gate` — passed on the change; the palette contract section printed
  `panel check: passed` before `==> gate passed`.
- The palette contract check asserts the panel frame is inside the visible frame,
  starts at least `shelfClearance` below its top, and stays inside a synthetic
  1280 × 600 screen below the same clearance.
- `mise run test` — 796 tests in 106 suites passed.
- `mise run lint` — SwiftLint, SwiftFormat and jactionlint clean.

## Real host still has to prove

The harness has no real Droppy shelf and no real notch surface, so the
coordinator's real-host check still owns:

- A real click on the takeover's search button does not abort the Playground.
- The shelf no longer covers the search field or the first result row at the
  new frame. The supervisor's real-host run measured the shelf page pill bottom
  at 258 and the palette now starts at y 315; the shelf stays open while the
  palette is up, so the check has to confirm the visible separation.
- The window level is not the mechanism: the real host showed the shelf still
  compositing above a layer-101 palette at layer 100. The palette is now at
  `.floating` and placed clear of the shelf.
- Once the panel is really key, the palette closes on resign key and the shelf
  closes on a click outside it.
- Real typed keys reach the field (the harness proves the panel is key and
  focused and that an accessibility-set value runs the search).
- Artwork stays on rows and the shelf widget after the palette opens and
  closes.
- The real widget row reopens the takeover after the palette closes.
