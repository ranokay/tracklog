# Interactive harness AX walk — method

- Date: 2026-11-04, 03:40–05:00 local time.
- App: `/Users/ranokay/.t3/worktrees/tracklog/t3-f84360fe/tracklog/.build/TracklogHarness.app`
  (`TracklogHarness`, window `Tracklog — DroppyKit harness`).
- Fixtures: `TRACKLOG_HARNESS_CHARTS=normal` (playing), `failed-saved` (playing),
  and `loading` (playing), each with `TRACKLOG_HARNESS_SECTION=charts`.
  The round-1 control frames in `frames.txt` were re-measured after the fixes
  on the same app at about 04:30–04:35, including paused, off and local states.
- Method: the running harness window was shown in the **Expanded surface**
  page and driven with Cua Driver background AX presses (`AXPress` on
  `AXButton` elements by role/name); observations are AX-tree reads from the
  same window. Each matrix row below is a control press followed by an
  `AXHeading`/`AXStaticText` expectation that matched. Ranked rows are the
  row elements' `label` plus `value_description`.
- This is the harness, not Droppy Playground. AX-tree inspection is not
  audible VoiceOver. The harness host refuses `openSettingsPage`, so the
  Custom-to-Settings handoff was observed as a refusal/no-op here; the real
  host handoff is recorded as not passed in the report.
- F4's connection selection (Last.fm → No connection → Last.fm) and the
  History shared-header capture are in `connection-switch.txt` and
  `history-header.png`.
- Interactive harness mode exposes no `report.json`. The equivalent
  fixture-backed gate reports are in `docs/reports/issue-80/reports/`.
