# Interactive harness AX walk — method

- Date: 2026-11-04, local time.
- App: `tracklog/.build/TracklogHarness.app` (`TracklogHarness`, window
  `Tracklog — DroppyKit harness`), launched with
  `TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_SECTION=loved` and one
  `TRACKLOG_HARNESS_LOVED` fixture per state.
- Method: the running harness was shown in the **Expanded surface** page and
  driven with Cua Driver background AX presses (`AXPress` on `AXButton`
  elements by role/name). Observations are AX-tree reads from the same window.
  Rows are the `AXUnknown` label plus its separate heart button. The harness
  repeats the takeover at the notch, Dynamic Island and camera geometries; the
  excerpts below are the first (notch) copy.
- This is the harness, not Droppy Playground. AX-tree inspection is not audible
  VoiceOver. The harness has no live service: every row, account and state is a
  synthetic fixture.
