# A seek back to the start starts a new listen session

Status: accepted

This records the recommended answer in the coordinator's scope comment on
#122 (issue comment 6693450624), which the owner-agreement rule in
`docs/agents/issue-tracker.md` applies to the third finding in that issue.

1. **A seek back to the start begins a new session.** When a playing
   observation shows the same track at its start after the previous position
   was materially later, the old session ends and a new one starts. The new
   session's `started_at` is when playback resumed, not the time Tracklog first
   saw the paused track. The issue's case — launched paused at 1:41, seeked to
   0:00, played at 09:23:01 — records `started_at` at the play time, not at
   launch time minus the paused position.
2. **The replaced session follows the normal end rule.** It becomes a listen
   only if its played time already met the existing listen threshold. The
   restart finalizes the old session through the same path as a track change:
   below the threshold it is discarded, and one that already scrobbled is not
   sent twice.
3. **A resume without a seek keeps its existing `started_at`.** Launching
   paused at 1:41 and then pressing play without seeking leaves the session's
   reconstructed start unchanged. This decision covers only a seek back to the
   start.
4. **Reuse the existing handling and thresholds.** The restart uses the
   engine's existing session, finalize and threshold code and the existing
   feed lead-in bound. No new setting and no new user control.

## Implementation notes

A playing sample is a restart when it jumped back
(`elapsed + 3 < lastElapsed`), its report is no older than the engine's
existing `leadIn`, and its position at that report
(`elapsed - played(over: observedAt - timestamp, at: sample)`) is under the
existing 3 seconds. The last position is the last one observed while playing;
a paused observation does not move it, so a seek made while paused is still
visible when playback resumes. A source with no report time of its own
(`timestamp == observedAt`) keeps the previous `elapsed < 3` behaviour.

**Known limit.** The rule assumes the report timestamp resets on a seek or
resume. The `get --now` path reports the track start instead
(`MediaHelper`, the `timestamp` and `elapsedFromStart` lines). For that source,
a forward seek followed by a backward seek inside the first 20 seconds of the
track can read as a restart, and the replaced session's played time resets.
The worst case is up to 20 seconds of played time on a listen that has barely
begun. Nothing is delivered twice. The fix, to report the last seek or resume
time from that path, is tracked in #125.

Detection and `finalize(at:)` happen in `ScrobbleEngine.ingest`, before the
new-session branch. The new session is created through the same path as a new
track, so `started_at` is `observedAt - elapsed` and `played` is
`unseenPlay(before:)`. `advance` no longer restarts a session and only updates
the last position for playing samples.

## Checks during implementation

- `CaptureSeekTests` drives `CaptureRuntime` with the real `TracklogAppState`
  and `SQLiteListenStore`: a paused launch at 1:41, a seek to 0:00 and a play
  four seconds before the first observation record the play time; the replaced
  below-threshold session produces no listen. A second composition test plays
  past the threshold before the seek and keeps the first listen.
- `ScrobbleEngineRestartTests` covers a backward seek to 0:15 mid-track (same session,
  same start), a plain pause and resume (same session), and a seek to 0:00 seen
  while paused (the session is replaced only when playback resumes).
- The existing `restartBeginsASession` test is unchanged: its sample has
  `timestamp == observedAt` and `elapsed == 0`, so the report position is 0 and
  the rule produces the same session as before.
