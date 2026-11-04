# Interactive harness AX walk — method (issue #81)

- Date: 2026-11-04, 06:20–06:50 local time.
- App: `/Users/ranokay/.t3/worktrees/tracklog/t3-22270a9c/tracklog/.build/TracklogHarness.app`
  (`TracklogHarness`, window `Tracklog — DroppyKit harness`, 1320 × 940).
- Fixtures:
  - `TRACKLOG_DEMO_STATE=playing` (normal History, pending banner expanded)
  - `TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_HISTORY=track`
  - `TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_HISTORY=empty`
  - `TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_HISTORY=jump`
  - `TRACKLOG_DEMO_STATE=playing TRACKLOG_HARNESS_SETTINGS_PAGE=history`
- Method: the running harness window was shown in the **Expanded surface** or
  **Settings pane** page and driven with Cua Driver AX presses (`AXPress` on
  `AXButton`/`AXMenuButton` elements by fresh `element_token`). The date field
  was focused with a foreground click and edited with foreground keystrokes;
  its displayed value was read from the screenshot. Observations are AX-tree
  reads from the same window. Row frames are window points.
- The harness renders three copies of the expanded surface (Notch, Dynamic
  Island, Camera Island). AX reads include all three; the readouts below quote
  the first copy unless the copies differ.
- This is the harness, not Droppy Playground. AX-tree inspection is not
  audible VoiceOver. The real-host Settings handoff is recorded in the report
  as not passed.
- The gate's fixture reports for the same states are in
  `docs/reports/issue-81/reports/`; the interactive walk has no `report.json`.
