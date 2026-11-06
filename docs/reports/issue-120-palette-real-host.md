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
- Typing “blo” reached the main harness window's sidebar field
  (`AXTextField = "blo"`), not the palette. The palette stayed at “Type at least
  two characters”; every group stayed “Not searched”.
- The shelf widget page showed the neutral note sleeve while the History rows
  kept their covers. The rows were already rendered before the exception; the
  widget appeared afterwards and never ran its decode.
- The palette could not be closed through accessibility because it had no AX
  surface, so the widget-row reopen could not be observed in this run.

## Fixed run

Scripted check:

```text
panel check: passed
exit=0
```

Accessibility press, no real pointer:

- The panel window was 680 × 560 at layer 101 (`.popUpMenu`), on screen, with an
  accessibility tree containing the field, the close button and the groups.
- An accessibility-set value “blo” reached the field and ran the search:
  Artists, Albums and Tracks each showed 10 results; no query seam was needed.
  The view's existing `onChange` is enough once the exception is gone.
- The close button closed the panel; the window list then contained only the
  main harness window.
- The shelf widget page showed the red cover, not the neutral sleeve.
- Pressing the widget row after the palette closed recorded
  `present "history"` at 16:51:34.228 on the Activity page.

No `ArtworkSleeve` change was made: the unfixed neutral widget and the fixed
cover are explained by the exception, not by a decode defect of their own.

## What changed

- `TracklogSearchPaletteController`: `canBecomeMain = true`; `.popUpMenu` level
  before and after activation; `prepare()` / `present()` /
  `presentAfterGesture()` split with a cancellable pending presentation;
  harness contract snapshot.
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
- `mise run test` — 796 tests in 106 suites passed.
- `mise run lint` — SwiftLint, SwiftFormat and jactionlint clean.

## Real host still has to prove

The harness has no real Droppy shelf and no real notch surface, so the
coordinator's real-host check still owns:

- A real click on the takeover's search button does not abort the Playground.
- The shelf does not cover the search field and does not stay above the
  palette; the palette sits at `.popUpMenu`, above the host's `NotchWindow`
  shelf.
- Once the panel is really key, the palette closes on resign key and the shelf
  closes on a click outside it.
- Real typed keys reach the field (the harness proves the panel is key and
  focused and that an accessibility-set value runs the search).
- Artwork stays on rows and the shelf widget after the palette opens and
  closes.
- The real widget row reopens the takeover after the palette closes.
