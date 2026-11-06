# Issue #120 search palette in the real host — worker report

- Base: `0b3841640271b26a99dbac9156931246ac15bf96`
- Branch: `fix/takeover-palette-crash`
- Scope: the real-host search palette crash and the input, artwork, shelf and
  reopen findings that followed it. This report does not close #76.

Provenance labels: **head** means the run was on the head commit named in the
section. **b1fbef9** means the supervisor's real-host run or an earlier worker's
run on that commit or the base. Those were not re-run here.

## Root cause (from the Droppy exceptions log, read in an earlier run)

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

The harness passed the crash check before because `DroppyPanelActivation.begin`
returns `nil` there. The fixture installs the host contract through
`DroppyKitSurfaceBridge.installPanelActivationProvider`, gated on
`host.environment.isHarness` and `TRACKLOG_HARNESS_HOST_PANEL_ACTIVATION=1`:

- it activates the app, makes the panel key and main;
- when `panel.canBecomeMain` is false it raises the same
  `NSInternalInconsistencyException` with the host's reason string.

`TracklogDroplet.runPaletteContractCheck()` drives the palette through
`openSearchPalette()` and asserts the panel is key and main, the activation
began, the key monitor and observers are installed, close clears the panel so a
second open works, and the frame clears the shelf clearance. A passing run
prints the frame. `scripts/panel_check.sh` runs it; `scripts/gate.sh` calls that
script after the surface shots.

## Unfixed run (base `0b38416`, **b1fbef9**)

Scripted check, from the earlier worker's run on the base:

```text
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'Invalid parameter not satisfying: [self canBecomeMainWindow]'
...
5 TracklogSearchPaletteController.open
6 TracklogDroplet.openSearchPalette
7 TracklogDroplet.runPaletteContractCheck
exit=134
```

Accessibility press through the takeover's search button, from the same earlier
run: the panel window existed but WindowServer reported `is_on_screen: false`, and
its accessibility tree was empty. The supervisor's real-host run on `b1fbef9`
then showed the crash gone and typed keys reaching the field (see below).

## Fixed run (head `1e2db5d`, **head**)

Scripted check, `scripts/panel_check.sh` with `TRACKLOG_HARNESS_HOST_PANEL_ACTIVATION=1`,
on the source commit `1e2db5d`:

```text
panel check: passed (frame Optional((560.0, 294.0, 680.0, 560.0)), visible Optional((0.0, 0.0, 1800.0, 1130.0)), shelf clearance 264.0pt, 1280×600 frame (300.0, 16.0, 680.0, 308.0))
```

`frame` is AppKit coordinates. Top-left origin, the palette's top edge is at
y 315 on the 1169pt screen (1169 − (294 + 560)); its visible frame's top is at
y 39.

Harness window, host-contract fixture on, head `1e2db5d` built into the harness
app. Driven with accessibility presses and synthetic keys, never the real
pointer:

- Pressing the takeover's search button ("Search and play") opened the panel:
  680 × 560 at (560, 315), layer 3, on screen. Its accessibility tree had the
  field, the close button, the four groups and the "Last.fm app credentials are
  missing" banner, because that run had no Last.fm credentials.
- With `TRACKLOG_HARNESS_PALETTE=normal`, the palette opened at launch at the same
  frame. The fixture set the query to `blo` by value. The search ran: Artists,
  Albums and Tracks each read "Expanded. 10 results", Loved read "8 results". No
  group stayed "Not searched".

Not verified on head:

- Typed keys reaching the field. Synthetic `b`, `l`, `o` key events did not
  reach a palette that stayed open. The palette closed during the key events,
  while another session's harness shared the desktop, and the cause was not
  isolated. Typed keys were proven on the real host at `b1fbef9` only.
- The close button, widget-row reopen, artwork on rows and on the shelf widget
  after the palette opens and closes. None was re-run on head, so no claim about
  them stands here.

## Shelf placement

Observed on the real host at `b1fbef9` by the supervisor: the palette was at
layer 101 and the shelf at layer 100, the shelf still drew over the palette's
field and first result row, and the shelf stayed open while the palette was up.
The mechanism is not known. A higher window level is not treated as the fix.

Measured on the real host at `b1fbef9`, in screen points, top-left origin: the
shelf window at x 450, y 0, 900 wide (its height was not measured); the shell
bottom at about y 216; the page pill bottom at about y 258, spanning x about 672
to 1128.

Computed on head, from DroppyKit 1.22.0 metrics and the Tracklog widget's
declared `.fixed(150)` height:

- `shelfClearance` = top inset 47 + widget 150 + slot 1.5 × 2 + bottom inset 16
  = 216 (shell bottom), + 48 for the page pill = **264**. The top inset is the
  notch height plus 10, with notch height 37 (`DroppyShellMetrics.physicalNotchHeight`,
  the harness's fixture). The 216 matches the shell bottom measured on the real
  host; a 32pt notch would give 211, so the earlier "259 matching 258" was wrong.
  The owner's real notch height is not measured directly.
- The palette starts `clearance + 12` below the visible frame's top. The visible
  top is 39pt below the screen top on this display: the Music window's bounds are
  y 39, height 1130, on a 1169pt screen, and the harness reports visible frame
  `(0, 0, 1800, 1130)`. So the palette's top edge is 39 + 276 = 315, 57pt below the
  measured pill bottom at 258.
- The clearance is measured from the screen's top, where the shelf window starts,
  but the placement is measured from the visible top. The 39pt menu bar is extra
  margin, not part of the 264.
- On a synthetic 1280 × 600 screen the frame is (300, 16, 680, 308) in AppKit
  coordinates, which is top-left y 276 to 584, inside the screen and 12pt below
  the clearance.

What is not yet known about the real shelf: its window height, and whether a
second widget on the same shelf page can be taller than 150pt. The clearance
counts only the Tracklog card, so a taller widget would move the shelf's extent
below the palette's top.

## What changed

- `TracklogSearchPaletteController`: `canBecomeMain = true`. The panel level is
  `.floating` (was `.popUpMenu` at `b1fbef9`). The palette is placed below the
  host shelf's extent by `shelfClearance`, clamped to the space below it and the
  visible frame. `prepare()` / `present()` / `presentAfterGesture()` split with a
  cancellable pending presentation. The `shelfClearance` doc comment states what
  was observed and what is not known.
- `TracklogDroplet+Search`: `openSearchPalette()` prepares inside the gesture and
  presents on the next run-loop turn; a second summon closes a prepared or open
  palette.
- `TracklogHarness`: host-contract provider and `--panel-check`.
- `TracklogDroplet+HarnessPalette`: harness-only contract check. The frame and
  shelf checks, and the passing line that prints the measured frame.
- `scripts/panel_check.sh`, `scripts/gate.sh`: the regression guard runs in the
  gate after the surface shots.

## Checks

- `scripts/panel_check.sh` — exit 0 on `1e2db5d`, output above.
- `hk check --all` (SwiftLint, SwiftFormat) — exit 0 on `1e2db5d`.
- `mise run gate` — run on the final head; see the REPORT for the commit and exit.

## Real-host results on `1477b9e`

The supervisor ran these in the real Droppy Playground, with the real pointer
and real key events, on a macOS display of 1800 × 1169. The worker did not run
them. Each item states what was seen. Nothing was run on the Playground from the
worker's thread.

- A real click on the takeover's search button did not crash the host. No new
  entry in `~/Library/Logs/Droppy/exceptions.log` and no new crash report.
- The panel was 680 × 560 at x 560, y 316, layer 3. The shelf window was at
  layer 100. The shell bottom measured about y 216 and the page pill bottom about
  y 258, so nothing overlapped the field or the results. The shelf stayed open at
  first, then closed by itself after a real click inside the palette with the
  pointer moved away. The palette stayed open and key.
- Real typed `blo` reached the field and ran a search: Artists read "Expanded.
  10 results", and the other groups returned results too. A real click in the
  field placed the caret, and the next key gave `blno` with new results. These
  were live, unauthenticated, read-only Last.fm catalogue searches through the
  Playground. Queries: `blo`, `blno`.
- The first Escape cleared the query and the second closed the palette.
- After closing, the shelf widget kept its cover. A real click on the widget row
  reopened the takeover with covers on every row. The issue's neutral-sleeve
  symptom did not appear with this fix installed. This is "not reproduced", not a
  proven mechanism.
- Opened again, a real click outside the palette closed it, closed the shelf and
  returned the foreground to the other app.
- Database row counts were unchanged across the retest: 52 listens, 156
  deliveries, integrity check ok.

## Still untested on the real host

- The shelf overflow entry.
- The rebindable shortcut.
- Return, Option-Return and Command-Return on a result.
- Input-method composition.
- A second widget on the same shelf page that is taller than Tracklog's card.
  The clearance does not account for it, so the palette could sit under that
  shelf's extent.
- The notch height on other displays. 37 is assumed from the measured shell
  bottom, which the owner's display matched.
