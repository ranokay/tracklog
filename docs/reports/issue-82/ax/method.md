# Interactive harness AX walk — method (issue #82)

- Date: 2026-11-04, implementation run.
- App: `/Users/ranokay/.t3/worktrees/tracklog/t3-15b81b49/tracklog/.build/TracklogHarness.app`
  (`TracklogHarness`, window `Tracklog — DroppyKit harness`, 1320 × 940).
- Fixture: `TRACKLOG_DEMO_STATE=playing` (normal History, pending banner and
  pending list, three surface copies). No History fixture override.
- Method: the running harness window was shown in the **Expanded surface** and
  **Settings pane** pages and driven with Cua Driver AX presses
  (`AXPress` on `AXButton`/`AXMenuButton` by fresh `element_token`). The row
  Actions menu was opened with the separate 28 × 28 `AXMenuButton`; the delete
  confirmation was opened from `Delete listen…`; the edit page was opened from
  `Edit listen…` and driven by setting/typing the Album field, toggling
  `Remember as rule`, and pressing Return (the page's default Save action).
- The harness renders three copies of the expanded surface (Notch, Dynamic
  Island, Camera Island). AX reads include all three; the readouts quote the
  first copy unless the copies differ.
- This is the harness, not Droppy Playground. AX-tree inspection is not
  audible VoiceOver. The real-host handoff and live-service writes were not
  run and are recorded as not passed in the report.
