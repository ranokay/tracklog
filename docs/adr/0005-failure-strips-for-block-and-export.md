# A failed quick block and a failed export show a HUD strip

Status: accepted

This records the recommended answers in #128, which the owner-agreement rule
in `docs/agents/issue-tracker.md` applies. Decision 2 replaces the native alert
that #48 chose for a failed export.

1. **Two failure strips join the HUD vocabulary from #24.**
   `hud.failure.block` reads "Not blocked" and says "Could not block <title>.
   It may still scrobble." `hud.failure.export` reads "Not exported" and says
   "Settings could not be exported. The Data page says why." Both use the
   failure style: 4 seconds, normal priority, a warning glyph.
2. **The export alert goes.** A failed export, whether reading the rules or
   writing the file, shows the strip and leaves the system's error text under
   Export on the Data page until the next attempt. No modal loop remains, so
   `deactivate()` no longer has an alert window or a modal session to end.
3. **A failed quick block shows the strip.** This covers the widget's "Block
   this track" and a History row's block. The error still reaches the caller,
   which logs it. A block that already exists is an upsert, which succeeds and
   shows "Blocked" as before. The Blocks settings page keeps its inline error
   and shows no strip.

## Checks during implementation

- `HUDVocabularyTests` pins the identifier, word, glyph, duration, priority and
  spoken text of both strips.
- `QuickBlockFailureTests` drives `CaptureRuntime` with a block store whose
  save fails, and records through the same `HUDHostSession` the droplet uses.
  Both quick-block paths show "Not blocked" and never "Blocked".
- The export path is in the droplet target, which has no test target because
  the Store refuses tests in a submission. It calls the same `HUD.resolve` and
  `TracklogAppState.setExportFailure`, and `TracklogDroplet+Export.swift`
  holds no `NSAlert`.
