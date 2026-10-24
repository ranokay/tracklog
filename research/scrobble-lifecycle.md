# Pano scrobble lifecycle, specified from behaviour

Research for the clean-room Droppy droplet. This file describes behaviour only. No Pano code, strings, comments or assets are reproduced.

Upstream baseline: `kawaiiDango/pano-scrobbler` at commit `9901540` (6 October 2026). Citations use the short keys in [Sources](#sources). The fork's Kotlin on the `apple/macos-implementation` branch is from May 2026 and is not authoritative; where it differs, this file follows upstream and says so.

Most detail below describes the Android media-session path, which is the richest. Desktop differences are called out where they change a rule. Upstream has no macOS transport; the macOS limits are in [What macOS makes possible](#what-macos-makes-possible).

The important headline: Pano is not a "scrobble when the track ends" client. It arms a timer when it first sees a track playing, submits while the track is still playing once the timer expires, and only persists a scrobble after a submission attempt fails. [ML:200-239], [I203] Everything else follows from those three choices.

## Terms

- **Session**: one media source Pano can observe. On Android this is a media session token, normally one per app plus session tag. On desktop it is a player identity. A session carries metadata, a play state and sometimes a position.
- **Track identity**: a 32-bit hash of album artist, artist, album, title, app id and session key. Duration and track number are not in the hash. The hash is computed from the platform metadata after built-in per-app transforms and before user edit and block rules. [PT:123, 101-135]
- **Arm**: create the in-memory timer that will submit a scrobble when it expires. Arming is the point where Pano decides a play is a candidate.
- **Played time**: wall-clock time accumulated while the track is playing, with pause gaps excluded. It is not the feed's playback position.
- **Threshold**: the amount of played time required before the armed timer fires.
- **Now playing**: the optional "currently listening" call to each service. It is separate from the scrobble.
- **Pending scrobble**: a row in the local database created after a submission failed. Pano does not persist an intent before it first attempts submission.

## Defaults

| Setting | Default | Accepted range |
| --- | --- | --- |
| Master scrobble switch | on | on or off |
| Submit now playing | on | on or off |
| Delay percent | 50% | 30 to 95% |
| Delay cap | 240 seconds | 30 to 360 seconds |
| Minimum track length | 30 seconds | 10 to 60 seconds, UI steps of 5 |
| Automatically scrobble new apps, Android only | on | on or off; also requires the new-app notification channel |

Sources: [MP:42-61, 368-376], [MP:230-237] for clamping, [PS:601-663] for the controls. The defaults changed in July 2026: the cap was 180 seconds before, and unknown-duration tracks used a two-minute assumed length before. Current upstream is 240 seconds and a flat 30 seconds for unknown duration. [C]

The master switch also requires at least one configured account that can scrobble. With no such account, Pano does not arm anything. [ML:32-33]

## Lifecycle in order

This is the order the rules actually apply. Later rules only run if earlier ones admit the play.

1. **Master gate.** Scrobbling is enabled and at least one account can scrobble. [ML:32-33]
2. **Session admission.** The source app must pass the per-app rule for the platform. A rejected session gets no tracker, so its metadata never enters the pipeline. [SL:79-84, 107-130]
3. **Metadata normalization.** Trim fields, map platform state to Pano's states, apply per-app metadata transforms, and read duration. Empty title or artist cancels. Advertisement flags, remote-playback flags, Chromecast sessions, and certain player-specific cases cancel. [MT:13-22, 129-137], [PB:14-70]
4. **Identity.** Compute the track hash from platform album artist, artist, album and title plus app id and session key. [PT:123]
5. **State gate.** Metadata alone does not arm while the session is paused. The play state must be playing, either already when metadata arrives or in a later state event. [ML:242-298, 356-404]
6. **Played-time accounting.** On a resume or first observation, start a play segment. On pause or stop, add the segment to played time if a timer is still pending, else reset played time. [PT:165-198], [ML:417-423]
7. **Threshold calculation.** Compute the target played time, subtract what has already been played, and keep a minimum remaining delay of 2 seconds. [ML:200-221]
8. **Cross-session arbitration.** Before arming, a global scrobble lock decides whether this session or another currently playing session may proceed. [ML:73-139, 223-238]
9. **Local notification.** Show the track as now playing locally, with the track's hash and state. [SQ:181-186]
10. **Metadata preprocessing.** After a one-second settle delay, fetch missing metadata, apply edit rules and block rules. A block can cancel the scrobble and optionally mute or skip the player. A parse failure becomes an error and cancels. [SQ:188-277]
11. **Now playing.** If enabled and allowed by the expiry rule, send now playing to every configured service that can scrobble, bounded so it finishes five seconds before the scrobble is due. Failure is not retried. [SQ:96-142]
12. **Wait.** Sleep in 500 ms ticks until the due monotonic time, unless the track is locked for editing. [SQ:144-151]
13. **Submit.** Launch the service calls in a scope that survives cancellation, then mark the track as scrobbled locally. [SQ:156-178]
14. **Failure handling.** Insert one pending row carrying the set of services that failed, or all configured scrobble-capable services if no service produced a result, then schedule a retry. [SE:286-329]
15. **Retry.** Persisted rows are retried in timestamp order, in batches of up to 50, with per-service bookkeeping and platform-specific backoff. [PW:57-134], [PD:26-30]

## Threshold rule

At default settings the effective rule is: scrobble once played time reaches 50% of the track's duration or four minutes, whichever is smaller, but not before 29.4 seconds. A track that ends first is normally not scrobbled.

With a known positive duration `d`, a delay percent `p`, a delay cap `c`, and a minimum length `m`:

```
target = max( min(d * p / 100, c), m - 0.6s )
delay  = max( target - played, 2s )
```

The subtraction and 2-second floor are applied when a new timer is armed, including on resume. [ML:211-221]

At default settings the formula approximates Last.fm's rule: half the duration or four minutes, whichever is earlier, with a 30-second floor. [LF-SC] The percent is configurable from 30 to 95, so a user can make Pano submit earlier or later than Last.fm's own 50% guideline. The service receives a timestamp and duration, not played time, so the threshold is effectively a client-side policy.

The `0.6s` tolerance exists so that a track reported as slightly shorter than 30 seconds, for example 29988 ms, still passes the 30-second floor. [ML:209-215]

With unknown, zero or negative duration, the target is exactly 30 seconds. That branch does not apply the minimum-length floor, so setting the minimum above 30 seconds has no effect on unknown-duration tracks. [ML:211-218]

With default settings, the target is:

| Track duration | Target played time |
| --- | --- |
| 20 seconds | 29.4 seconds, so normally never reached before the track ends |
| 30 seconds | 29.4 seconds, at the very end, so the result depends on the player's state reporting |
| 45 seconds | 29.4 seconds |
| 1 minute | 30 seconds |
| 3 minutes | 90 seconds |
| 8 minutes | 240 seconds |
| 10 minutes or longer | 240 seconds |
| unknown | 30 seconds |

Notes:

- The percentage is of the track's total duration, not of the elapsed position. A 10-minute track scrobbles after 4 minutes of actual playing, not after 5.
- The target can exceed the cap when the minimum-length floor is larger than the cap. The floor is applied after the minimum of percent and cap. For example, a 60-second minimum with a 30-second cap yields a 59.4-second target. [ML:211-215]
- The timer uses a monotonic clock, so wall-clock adjustments do not move it. Tick granularity is 500 ms. [SQ:36, 72, 146-150]
- The timer is armed before metadata preprocessing. Time spent fetching missing metadata counts toward the threshold. If preprocessing outlasts the threshold, submission happens immediately after preprocessing and now playing is usually skipped. [SQ:72, 90-151]
- The delay is recomputed on every resume that re-arms the track, using accumulated played time, so a pause does not restart the countdown. [ML:366-397]

## Played-time accounting

Pano tracks played time in two pieces: total played time and the start of the current playing segment. [PT:84-97]

- Arming sets the play start time and the segment start only if they are unset. [PT:165-182]
- Pausing adds the current segment to total played time only if a timer is still pending. If the scrobble already went out, pausing resets played time instead. [ML:417-423]
- Resuming starts a new segment. Pause gaps therefore do not count. [PT:194-210]
- Buffering is not treated as a pause. The waiting state preserves the previous playback state and the segment clock keeps running, so buffering time is counted as played time. [ML:407-413], [PT:194-198]
- Played time is wall-clock time, not position. A seek forward does not reduce the remaining delay, and a seek backward does not increase it. [ML:220-221]

There is an upstream defect worth not copying: a metadata change does not reset total played time directly. On a gapless track change after a pause, the new track can inherit the previous track's accumulated played time and scrobble early. A later playing event with a different identity resets it, but a gapless player may not send one. [PT:101-135, 188-192], [ML:242-298] The May fork did reset played time explicitly in the metadata path. [FML:154-162]

## Scrobble timestamp

The timestamp sent with a scrobble is the play's start time as Pano knows it. It is set when Pano first accepts the track's metadata while the session is playing, or at the first arm if the metadata arrived while paused. It is preserved across pause and resume while the play is still pending, and reset when Pano treats the play as a repeat or a restart. [PT:131-134, 188-192, 217]

It is not corrected for a track that was already in progress when Pano started observing it. If Pano starts mid-track, the timestamp is the observation time, not the true start. [PT:131-134, 217], [ML:371-380]

Notification-derived scrobbles are a mixed case. Shazam and Audile use the timestamp from the notification; Audile supplies a sample timestamp and Shazam uses the time the notification arrived. Pixel Now Playing uses the time Pano arms the scrobble. [NL:325-371]

Duration is sent in milliseconds internally and converted to seconds for Last.fm. An unknown duration is omitted rather than sent as zero. [PT:212-220], [LF:109]

The timestamp determines history order. Pano uses it for retry ordering but does not use it to deduplicate. [PD:26-30]

## Now playing

Summary: now playing is sent when a scrobble is first armed, after a settle second and preprocessing, not at playback start and not at the threshold. It is re-sent only on a new arm or a resume that passes the stale window. It is never refreshed on a timer, on a seek inside the track, or by a user edit.

Now playing is sent from inside the armed job, not at the instant playback starts and not when the threshold is reached. On a fresh track it therefore goes out roughly one settle second plus preprocessing time after Pano first observes the track playing. [SQ:90-142, 188-203]

Conditions for sending:

- The submit-now-playing preference is on at the moment the job reaches the call. [SQ:96-107]
- The track did not come from a notification source that supplies its own timestamp. Shazam and Audile pass a timestamp override, which suppresses now playing. Pixel Now Playing does not, so it can send now playing. [SQ:99-107], [NL:325-371]
- Either this is the first arm of the play, or enough time has passed since the previous arm that the old now-playing is considered stale. The stale window is three quarters of the track duration, capped at four minutes. [SQ:99-107]

The call is raced against the scrobble due time minus five seconds. If preprocessing leaves less than five seconds, the timeout is non-positive and now playing is skipped. [SQ:109-112]

After the call, Pano advances the track state and records a ListenBrainz recording id if one came back, even when the call timed out or failed. Now-playing failures are not retried, matching Last.fm's guidance. A now-playing failure does not block the scrobble. Pano also does not refresh now playing periodically; the call is event-driven. [SQ:114-142]

Pano does not clear now playing on pause, stop, skip or track change. Last.fm has no clear call. The previous now-playing remains on the service until another now-playing call or server expiry. [ML:417-432], [LF-NP]

Consequences to keep in mind:

- A short track, or a track skipped before the timer, can send now playing and then never scrobble. Pano does not withdraw it.
- A pause after now playing but before the threshold leaves a now-playing entry that never becomes a scrobble.
- Resuming after a long pause can send now playing again. For unknown duration the stale window is zero, so practically every resume re-sends it. [SQ:99-107]
- A seek inside the track does not re-send now playing, and neither does a user edit. A seek to near the start can be treated as a repeat and re-send it if the stale window has passed. Otherwise only a new arm or a resume that passes the stale window re-sends it.
- The local notification changes from "now playing" to "scrobbled" when the timer fires and the submission is launched, before the network call finishes. [SQ:174-178]

## Playback transitions

### Pause

When a pause, stop or none state arrives and the previous state was playing, Pano does the following. [ML:347-354, 417-432]

1. If a timer is still pending, add the current playing segment to played time. Otherwise reset played time.
2. Remove the pending timer for the last scrobble hash.
3. Remove the local notification.
4. Unmute if Pano had muted this session.
5. Release the cross-session scrobble lock and promote another eligible session if one exists.

A pause does not cancel a submission that has already been launched. Once the due time passes, the network call runs in an independent scope and survives pause, skip or track change. [SQ:156-172]

A pause while the track is locked for editing does not cancel the timer either, because removal of a locked hash is refused. The wait loop can then exit with the track no longer playing and drop the scrobble. [SQ:146-154, 326-330]

### Resume

On a transition to playing, if the track has not been cancelled, Pano marks it playing and may reset played time when the identity changed or when playback resumes at the very start. On desktop, the near-start reset also requires the timeline to have moved by more than a second. [ML:356-369]

It arms a new timer only when no timer exists for the hash and one of these holds:

- The reported position is within the first 1500 ms and duration is known.
- The track has not yet been submitted, and this is not the short spam window of repeated playing events at a low position within the first three seconds of the play. [ML:371-397]

If the track was already submitted and resumes mid-track, no new timer is armed, so there is no duplicate. If it was paused before the threshold, the new timer is the old target minus accumulated played time, floored at two seconds.

Resuming at the start of an already submitted track can be treated as a repeat, not a duplicate. That is covered below.

### Seek

Pano does not use seeks to change the threshold. The timer is wall-clock based. [ML:220-221]

- A forward seek inside the track does not make the scrobble fire early.
- A backward seek inside the track does not make it fire again while a timer is pending.
- On desktop, seeks refresh the local notification and Discord presence because timeline-only changes are surfaced there. On Android, timeline-only events are ignored. [ML:336-345, 398-403], [DML:26]
- A seek to within the first 1500 ms while playing is treated as a possible restart. On desktop, the timeline must also have moved. If a timer is still pending, played time is reset but the existing timer is not moved, so the track can scrobble earlier than a full threshold measured from the restart. If no timer exists and the track was already submitted, the repeat path arms a new scrobble. [ML:366-397]
- Pano does not detect a general seek for scrobbling purposes, only the near-start case.

### Repeat

A repeat is a new play and should produce a new scrobble. Pano treats a metadata change that alters the identity as a new play, and treats the same identity returning to the start of the track while playing as a repeat. [ML:381-397]

On a near-start repeat of an already submitted hash, Pano re-applies the original metadata, re-runs preprocessing and now playing, resets the play start time, and arms a new timer. This produces a second scrobble with a new timestamp. [ML:381-397]

If the player repeats a track without resetting position and without changing metadata, Pano sees no event that distinguishes the repeat and does not scrobble it again. The feed must expose either a position reset or a metadata boundary.

A loop that restarts within the first three seconds of a playing state can be suppressed by the spam guard. [ML:375-379]

### Skip

Pano's skip control only sends a transport command. It does not itself mark a scrobble, cancel a scrobble, or tell the service that the user skipped. [SL:202-208]

The outcome depends on where the timer was:

- Skip before the timer expires: the next metadata or pause event removes the pending timer, so no scrobble.
- Skip after the timer expires: the submission has already been launched in an independent scope, so it still scrobbles.
- Skip during the one-second settle delay or during preprocessing: the job is cancelled, so neither now playing nor the scrobble is sent. [SQ:188-203]
- Skip that arrives as a track change while playing: the old timer is removed by the new arm, but an already launched submission is unaffected. [ML:200-203, 242-298]

The boundary is the timer, not the skip event. There is an unavoidable race within a few hundred milliseconds of the due time.

### Track change

A metadata change that alters album artist, artist, album or title produces a new hash. Pano cancels the previous pending timer for that session, resets the track state, and, if the session is playing, arms the new track. [ML:242-298]

The previous submission, if already launched, is not cancelled. This is deliberate because the earlier track met the rule before the change.

A duration-only change is ignored unless the new duration differs by more than one second. This tolerance prevents players that report duration incrementally from churning the state. A duration-only change can re-arm a track whose timer is gone, which is a duplicate risk after the original scrobble. [ML:252-265, 270-298]

If metadata arrives before the playing state, Pano waits for the playing event. If the playing state arrives first, the later metadata arms the track because the previous state is already playing. [ML:288-292, 371-380]

If the new metadata is the same as the old, nothing is reset. This covers gapless playback where no state change occurs. [ML:246-270]

### Stop and session removal

Stopping a session calls pause, which accumulates played time if a timer is pending, cancels the timer, hides the notification and releases the lock. The session tracker is then removed. [SL:218-221], [ML:417-432]

Disabling the master switch, blocking an app, or removing an allowed app causes the session list to be recomputed. Sessions that no longer qualify are stopped and their pending timers are cancelled. Re-allowing an app mid-track creates a tracker, and the immediate state and metadata callbacks can arm the current track from that point onward. [SL:56-77]

## Short tracks and unknown duration

Upstream has no explicit "reject if duration is below the minimum" guard. Instead, the minimum becomes a floor on the target, and a short track normally ends before the floor is reached. [ML:211-221] The setting reads like a track-length filter, but the code uses it as a lower bound on played time, so it is not a hard eligibility filter.

With the default 30-second minimum:

- Tracks shorter than about 29.4 seconds normally never scrobble.
- A track up to about one minute scrobbles at roughly 29.4 to 30 seconds, not at half its duration.
- A 30-second track is a boundary case. The 0.6-second tolerance exists so a 29988 ms reporting still counts, but the track must remain in a playing state long enough for the timer to fire.
- A short track can still scrobble if the player keeps reporting playing after the audio ended, or if the feed's duration is wrong. Pano has no independent end-of-track check.

Lowering the minimum to 10 seconds allows shorter tracks to scrobble, but Last.fm's own rule says a track must be longer than 30 seconds. [LF-SC] The maintainer has said scrobbling below 30 seconds should not have been a feature and kept it only because it existed historically. [I600] Treat the 10-second setting as an upstream compatibility escape hatch, not as behaviour to emulate by default.

Unknown duration always uses 30 seconds, regardless of the minimum setting. For a radio stream with a long actual track, that can be less than half the true duration. Pano accepts this because the feed did not provide a duration. [ML:211-218]

## Duplicate suppression

Pano has several partial mechanisms, none of which is a full deduplication guarantee.

### One timer per track identity

The in-memory timer map is keyed by the track hash. Arming returns immediately if a live timer already exists for that hash. [SQ:64-70]

The hash includes app id and session key, plus album artist, artist, album and title. It excludes duration and track number. It is computed from platform metadata after built-in transforms and before user edits. As a result:

- The same track on two sessions has two different hashes, so the timer map alone does not deduplicate across sessions.
- A metadata edit does not change the hash, even if the final scrobble has a different artist or title.
- A duration correction does not change the hash. [PT:101-135]

After a submission, the timer entry becomes completed and no longer counts as present, which is what allows a later repeat to arm again. [SQ:43-58]

### Cross-session scrobble lock

Before arming, a session takes a global lock. If another session holds it, the requester waits eight seconds and then checks again. [ML:73-122, 442-449]

- If the holder is no longer eligible, meaning not playing, missing title or artist, or cancelled, the requester takes over.
- If the holder is still eligible, the requester cancels its own timer and removes its local notification if it is a different session. It does not compare the two tracks. A second app playing a genuinely different track is suppressed while the first keeps playing. [ML:108-121, 223-238]
- When the holder pauses, stops, is cancelled, or its session is removed, it releases the lock and promotes the eligible waiting session with the earliest session start time. [ML:124-139, 303-312, 417-432]

This is a heuristic against two players reporting the same audio, not identity-based duplicate detection. It also means that if the holder never pauses, for example a radio player, a second player cannot scrobble at all.

The lock is in memory only and is per platform listener. It does not survive process death.

### Recognition-app duplicate guard

Notification-derived sources such as music-recognition apps are a separate path. If the guard is enabled and any media session is currently playing, Pano refuses to process the recognition notification. The guard is off by default. [NL:197-203], [MP:60]

This is the only cross-path deduplication. It does not compare tracks either. It simply suppresses recognition scrobbles while something else is playing.

### What is not deduplicated

- A repeat is intentionally a new scrobble. [ML:381-397]
- A pause and resume at the start of a track can be treated as a repeat, especially on players that reset position on pause. The unknown-duration variant of that bug was fixed, but a known-duration player that reports position zero on resume can still produce a second scrobble. [I857]
- A process restart loses all in-memory play state. Re-observing the same play can arm and scrobble it again. Nothing checks recent history or pending rows before submitting.
- The persisted pending table has no unique key on artist, track, timestamp or service. A duplicate arm, for example after a process restart or a duration update, can insert the same scrobble more than once. [PD:44-64], [PE:13-31]
- There is no cross-device or server-side check. The open feature request for checking Last.fm recent tracks before submitting is still open. [I905] The FAQ blames duplicated Spotify scrobbles on running more than one scrobbler. [FAQ:40-44]
- The queue records service types, not account ids. If two accounts of the same type exist, a pending row cannot distinguish them. Upstream appears to assume one account per service. [PE:23-24]

## Offline queue, retry, backoff and ordering

### What gets queued, and when

Pano does not queue an intent before submission. It attempts the service calls first. Only after at least one service fails does it write a pending row. [SE:286-329]

Consequences:

- An offline track is queued only after its threshold timer fires and the network attempt fails.
- A track skipped before its timer is never queued.
- If the process dies after the timer fires but before the failure is persisted, the scrobble is lost. The local state may already say "scrobbled" because Pano marks it before the network call finishes. [SQ:156-178]
- Now-playing failures are never queued. [SQ:114-142], [LF-NP]

This does not match Last.fm's recommendation that the client cache unsubmitted scrobbles so they survive a restart. [LF-SC] It is a real gap in upstream, not a behaviour to preserve blindly.

### Row shape

A row stores the full scrobble data, the event type, a set of service types that still owe a submission, the last failure time, a truncated failure reason, and a flag for network-retryable failures. The primary key is an autoincrement id, so inserts always create a new row. [PE:13-31]

When some services succeed and others fail, Pano removes the successful services from the row and updates the row. When all services succeed, or return a terminal result, it deletes the row. [PW:100-124]

Terminal results include success and Last.fm error codes 6 and 7, which are parameter and resource errors rather than temporary failures. A service that is logged out has its bit removed from every row, and rows with no services left are deleted. [PW:100-124, 208-219]

### Submission order and batching

- Rows are submitted in ascending scrobble timestamp order, oldest first. [PD:26-30]
- At most 700 scrobble rows are fetched per run. [PW:223-229]
- They are sent in batches of at most 50 per service, matching Last.fm's batch limit. [PW:226-227], [LF-SC]
- Services are iterated in turn. Each service receives all rows in the batch that still name it. Partial success is then reconciled per row. [PW:80-121]
- Pending loves are processed before pending scrobbles, up to 100, with a one-second gap between each. A large love backlog delays scrobbles. [PW:42-47, 136-188]
- The retry worker is scheduled on app UI start if rows exist, after any live scrobble failure, and forcefully after a live scrobble succeeds if the force-retry query is true. [MV:85-98], [SE:311-329]
- The force-retry query is true when any row has a network-retryable failure or is older than 60 minutes. [PD:89-92]

### Backoff

Android uses WorkManager with a network constraint, a unique work name, and exponential backoff starting at one hour. [PWK:33-66] A normal schedule also gets a 30-second initial delay and keeps existing work rather than replacing it. A forced schedule replaces existing work and has no initial delay. The practical sequence is roughly one hour, two hours, four hours, then the WorkManager cap.

Desktop uses a different scheduler: one-hour initial delay, factor four, three attempts. [PWJ:6-23] However, the desktop scheduler only retries when the worker throws; the pending worker normally returns a Retry result rather than throwing. Its unique-work map also keeps an entry after a completed job, so a later non-forced schedule can be ignored. [DWM:32-50, 56-95] Treat desktop retry timing as unspecified. The report about offline scrobbles not being sent on Windows is consistent with this. [I755]

Within one worker run, a service that fails twice stops receiving further batches. That limits rate-limit damage but also means a large backlog drains slowly. [PW:62-64, 85-92, 223-229] A run reports Retry if any service recorded a failure, which is what triggers the Android backoff. [PW:46-53]

### Ordering against new scrobbles

Pano does not enforce "cached before new". A live scrobble submits immediately, while the retry worker runs separately. The timestamps preserve the order in service history, but the request order can interleave. Last.fm recommends sending cached scrobbles before new ones. [LF-SC]

If more than 700 rows are pending, a successful run does not automatically schedule another run. The remaining rows wait for the next app start, the next live failure, or the force-retry trigger. [PW:57-65, 223-229], [MV:85-98]

There is no total queue size cap. The maintainer has described how a backlog can grow past a service's daily limit and consume the next day's quota. [I970]

### Retryable failures

Pano marks a failure as force-retryable for name resolution, TLS, socket timeout and socket errors, plus API codes 11, 403 and 502. [PD:109-116] Last.fm's own list is 11 and 16 as temporary, plus 9 for reauthentication. [LF-SC] The mismatch means code 16 is retried only on the normal schedule, not by the force path. Rate-limit code 29 is not treated specially; the code for it is commented out. [PW:85-89]

## Per-app include and exclude

### Android media sessions

A session is admitted when the master switch is on and one of these holds:

- The package is explicitly allowed.
- Automatic new-app scrobbling is on, the package is not explicitly blocked, and the new-app notification channel is enabled.
- The package is allowed even if it also appears in the block list. Allow wins. [SL:79-84]

The saved app list produces both lists. Checked apps go into the allow list and are removed from the block list. Unchecked apps go into the block list and are removed from the allow list. [ALS:119-153]

The resulting three-way behaviour:

| App state | Auto-detect on | Auto-detect off |
| --- | --- | --- |
| Explicitly allowed | scrobbles | scrobbles |
| Explicitly blocked, not allowed | never scrobbles | never scrobbles |
| Never seen, unlisted | scrobbles if the new-app channel is enabled | never scrobbles |

The new-app notification channel is checked once when the listener is created, not reactively. [SL:49-51] If the channel is disabled at that point, unlisted apps do not scrobble until the listener is recreated.

When an unlisted app wins the scrobble lock, Pano posts an app-detected notification with allow and block actions. [SL:223-232]

Changing the master switch, allow list, block list or auto-detect setting recomputes active sessions immediately. Sessions that no longer qualify are stopped, which cancels their pending timers. [SL:56-77]

### Desktop players

Desktop has no automatic new-app scrobbling. A player scrobbles only when its normalized app id is in the allow list. [DML:60-64] An empty allow list therefore means no scrobbles at all, unlike Android's default.

Desktop also has website host rules. A track whose normalized URL host is in the blocked host set is treated as ignored, which cancels it before submission. [DML:148-162] New hosts are recorded when a scrobble is about to proceed. [DML:216-224]

### Notification sources

Recognition apps are separate from media sessions. Their package must still pass the same per-app rule. If the ambient duplicate guard is on and any media session reports playing with a title, the recognition path is suppressed. [NL:197-203]

The recognition path also bypasses the media threshold. Shazam and Audile results submit immediately with the notification's timestamp and no now playing. Pixel Now Playing waits 15 seconds, uses the time Pano arms the scrobble, may send now playing, and enforces a five-minute cooldown for the same track hash. Neither path accumulates played time against the media threshold. [NL:325-371]

### Source-specific ignores

These are not user app rules but hard-coded source exceptions that decide whether a play is eligible:

- Android advertisement metadata cancels the play. Telegram voice notes with no album and matching artist and album artist also cancel. [MT:129-137]
- Android Spotify remote playback is ignored unless the user enables remote Spotify scrobbling. [PB:33-41]
- Yamaha sessions with no transport actions are ignored. [PB:57-62]
- Chromecast remote sessions are ignored, except the Chromecast player itself. [PB:64-68]
- On Windows, Spotify has its own ad heuristic based on missing album, track number zero and no skip action. The same path ignores all Spotify playback when remote Spotify scrobbling is disabled. [PBD:26-40]
- The YouTube Music ad heuristic based on non-seekable playback is disabled in current upstream because newer clients broke it. [PB:43-55]

The FAQ says metadata alone cannot distinguish non-music YouTube videos from music, and suggests blocking channels or turning the source off. [FAQ:50-55]

## Edge cases and ambiguities

| Case | Current upstream behaviour | Status |
| --- | --- | --- |
| Track skipped exactly at the threshold | Timer may already have fired and launched submission, so it can scrobble | Race, not deterministic |
| Pause exactly at the threshold | Same as skip; submission survives pause | Race |
| Short track that sends now playing but never reaches the floor | Now playing remains, no scrobble | Deliberate consequence |
| Unknown duration | Fixed 30-second target, minimum-length setting ignored | Inconsistent; the minimum has no effect here |
| Gapless track change after a pause | New track can inherit old played time and scrobble early | Apparent regression; treat as a defect |
| Duration metadata changes after submission | Can re-arm and produce a second scrobble | Duplicate risk |
| Player resets position to zero on pause | Can be treated as a repeat and scrobble twice | Player-dependent |
| Player repeats without position or metadata event | No second scrobble | Feed-dependent |
| Two players, different tracks, both playing | Only one scrobbles while the lock holder remains eligible | Coarse heuristic |
| No artist or empty title | Cancelled; recovery needs a later playback state event | Possible missed scrobble |
| Pano starts observing a track already in progress | Counts from observation, not from actual start | Deliberate "start from any position" behaviour |
| Process dies during the threshold | No scrobble | No durable intent |
| Process dies after marking scrobbled but before network completion | Scrobble can be lost | Marking happens before the call |
| Repeated failure inserts | Duplicate pending rows possible | No unique key |
| User edits or blocks a track after it was queued | Queued row is still submitted; rules are not re-evaluated on retry | Rule changes are not retroactive |
| Account removed while rows are pending | That service bit is stripped; empty rows deleted | Account model dependent |
| Multiple accounts of one service | Pending row cannot distinguish accounts | Upstream likely assumes one per type |
| Web player host in the blocked set | Cancels the play before submission on desktop | Platform-specific |

There are no upstream unit tests for the media listener, timer, lock or retry worker. The lifecycle is expressed entirely in platform callbacks and issue reports. [TESTS] Treat the rules above as code-derived intent, not as a tested contract.

Untestable or unverified here:

- Whether a particular player emits position, state and metadata in a useful order.
- Whether a player keeps reporting playing after a track ends.
- How the Android OS schedules background work under battery restrictions.
- Whether Last.fm accepts a scrobble whose client-side threshold was computed from an unknown duration.
- Whether the desktop retry scheduler ever runs more than once per app session. The code suggests it may not, but this was not exercised.
- The exact macOS helper behaviour across players and OS versions. See the next section.

## What macOS makes possible

Upstream Pano has no official macOS transport. The map for this project records that macOS has no public now-playing data API, and that the route recorded there is an undocumented media helper that returns the current track as JSON with title, artist, album, duration, elapsed, rate and bundle id. [MAP] The frozen macOS port in the fork has a stub global provider and documents the same limitation: there is no stable public API for reading every other app's now-playing metadata. Its working provider uses AppleScript polling for a fixed set of players and browser tabs. [PORT-G:14-20], [PORT-A:7, 42-64, 105-134]

That changes which upstream rules can be reproduced:

| Upstream rule | macOS feasibility |
| --- | --- |
| Per-app allow and block by package | Possible if the helper reports the source bundle id |
| Per-session tags and multiple concurrent sessions | Not guaranteed; likely one current session |
| Position, duration and rate | Possible via elapsed, duration and rate, with polling latency |
| Push playback state events | Not available; state must be inferred from rate and elapsed movement |
| Pause and resume | Inferable when rate is zero or elapsed stops advancing; buffering is indistinguishable from pause |
| Seek detection | Inferable as an elapsed jump that wall-clock time does not explain |
| Repeat detection | Possible when elapsed resets to near zero with the same identity |
| Skip detection | Only as a track identity change; no separate skip event |
| Advertisement flag | Not available; no reliable ad detection |
| Remote playback and Chromecast distinction | Not available without source flags |
| Transport actions such as skip or mute | Not available from the helper, so block rules cannot act on the player |
| Browser hostname rules | Not available if the helper omits the URL; bundle id only identifies the browser |
| Cross-session duplicate lock | Cannot be reproduced if only one session is visible; reduce to single-identity suppression |
| Exact threshold timing | Approximate to the polling interval, though elapsed lets the client reconstruct the true start |
| Durable pending queue | Independent of the feed; the droplet must own it because the Droppy host process can terminate or reload the droplet |
| Now-playing submit and update | Possible; Last.fm has no clear call, so a later call can only overwrite it |
| Per-service partial retry | Independent of the feed; reuse the row-per-service model |

The helper's `elapsed` field is an opportunity upstream does not use. Upstream sets the scrobble timestamp to the moment it first observed the play, which can be minutes late if it started mid-track. A client with elapsed can compute the true start time and reconstruct played time. That would be more accurate than Pano, not parity. This is a product decision for the media-feed ticket, not something to assume here.

The helper also makes a durable intent record more important than it is on Android. Upstream can lose a scrobble if the process dies during the threshold, but an Android foreground service makes that rare. The Droppy host process can terminate or reload the droplet without giving it a chance to flush, so parity with Pano's user-visible behaviour likely requires persisting the current play's identity and accumulated played time, or accepting that these interruptions lose the play. That is a design decision, not an upstream rule.

## Implications for the droplet

These are consequences of the spec, not new decisions.

- Use a single timer per active play, driven by monotonic time, with a two-second floor and a 500 ms tick. Recompute on resume, not on every state event.
- Decide whether to persist the pre-submission play state. Upstream does not. A droplet whose host can restart probably should.
- Keep now playing and the scrobble as separate calls. Do not retry now playing. Do not assume pause or skip clears it.
- Keep the threshold policy global across services. Pano does not vary it per service.
- Do not copy the gapless played-time carry-over or the unknown-duration minimum bypass. Both look like defects.
- Treat the cross-session lock as a heuristic. With a single-session macOS feed it is mostly unnecessary, but identity suppression is still needed for repeats, metadata refreshes and process reloads.
- Decide the app-list default explicitly. Android defaults to auto-detect, desktop defaults to deny. They are not the same product behaviour.
- Persist pending rows by service identity, not just service type, if the droplet supports more than one account per service.
- Rate-limit and cap the queue. Upstream's unbounded queue is a known way to lose a day of scrobbles.

## Sources

Short keys used above. All Kotlin paths are relative to the upstream repository at `9901540`.

| Key | Path or document | Link |
| --- | --- | --- |
| ML | `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/MediaListener.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/media/MediaListener.kt |
| SQ | `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/ScrobbleQueue.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/media/ScrobbleQueue.kt |
| PT | `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/PlayingTrackInfo.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/media/PlayingTrackInfo.kt |
| SL | `composeApp/src/androidMain/kotlin/com/arn/scrobble/media/SessListener.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/androidMain/kotlin/com/arn/scrobble/media/SessListener.kt |
| NL | `composeApp/src/androidMain/kotlin/com/arn/scrobble/media/NLService.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/androidMain/kotlin/com/arn/scrobble/media/NLService.kt |
| PB | `composeApp/src/androidMain/kotlin/com/arn/scrobble/media/PlaybackInfoTransforms.android.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/androidMain/kotlin/com/arn/scrobble/media/PlaybackInfoTransforms.android.kt |
| MT | `composeApp/src/androidMain/kotlin/com/arn/scrobble/media/MetadataTransforms.android.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/androidMain/kotlin/com/arn/scrobble/media/MetadataTransforms.android.kt |
| PBD | `composeApp/src/jvmMain/kotlin/com/arn/scrobble/media/PlaybackInfoTransforms.jvm.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/jvmMain/kotlin/com/arn/scrobble/media/PlaybackInfoTransforms.jvm.kt |
| DML | `composeApp/src/jvmMain/kotlin/com/arn/scrobble/media/DesktopMediaListener.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/jvmMain/kotlin/com/arn/scrobble/media/DesktopMediaListener.kt |
| SE | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/ScrobbleEverywhere.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/ScrobbleEverywhere.kt |
| PW | `composeApp/src/commonMain/kotlin/com/arn/scrobble/work/PendingScrobblesWorker.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/work/PendingScrobblesWorker.kt |
| PD | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PendingScrobblesDao.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PendingScrobblesDao.kt |
| PE | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PendingScrobble.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PendingScrobble.kt |
| PWK | `composeApp/src/androidMain/kotlin/com/arn/scrobble/work/PendingScrobblesWork.android.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/androidMain/kotlin/com/arn/scrobble/work/PendingScrobblesWork.android.kt |
| PWJ | `composeApp/src/jvmMain/kotlin/com/arn/scrobble/work/PendingScrobblesWork.jvm.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/jvmMain/kotlin/com/arn/scrobble/work/PendingScrobblesWork.jvm.kt |
| DWM | `composeApp/src/jvmMain/kotlin/com/arn/scrobble/work/DesktopWorkManager.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/jvmMain/kotlin/com/arn/scrobble/work/DesktopWorkManager.kt |
| MP | `composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/MainPrefs.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/MainPrefs.kt |
| PS | `composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/PrefsScreen.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/PrefsScreen.kt |
| ALS | `composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/AppListScreen.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/AppListScreen.kt |
| MV | `composeApp/src/commonMain/kotlin/com/arn/scrobble/main/MainViewModel.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/main/MainViewModel.kt |
| LF | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/Lastfm.kt` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/Lastfm.kt |
| C | Commit `addcdba`, scrobble delay change | https://github.com/kawaiiDango/pano-scrobbler/commit/addcdbab0ad00f78c5d2cea4233921a97f57e0fe |
| FAQ | `faq.md` | https://github.com/kawaiiDango/pano-scrobbler/blob/9901540/faq.md |
| LF-SC | Last.fm Scrobbling 2.0 documentation, scrobble rules and retry guidance | https://www.last.fm/api/scrobbling |
| LF-NP | Last.fm Scrobbling 2.0 documentation, now-playing guidance | https://www.last.fm/api/scrobbling |
| I203 | Issue 203, submit only after playback ends | https://github.com/kawaiiDango/pano-scrobbler/issues/203 |
| I600 | Issue 600, scrobbling tracks shorter than 10 seconds | https://github.com/kawaiiDango/pano-scrobbler/issues/600 |
| I755 | Issue 755, offline scrobbles not sent on Windows | https://github.com/kawaiiDango/pano-scrobbler/issues/755 |
| I857 | Issue 857, duplicate scrobbles after pausing with Winamp | https://github.com/kawaiiDango/pano-scrobbler/issues/857 |
| I905 | Issue 905, cross-device duplicate detection, open | https://github.com/kawaiiDango/pano-scrobbler/issues/905 |
| I970 | Issue 970, scrobble delay ignores the flat-seconds threshold | https://github.com/kawaiiDango/pano-scrobbler/issues/970 |
| MAP | This project's map, issue 1, macOS feed constraints | https://github.com/ranokay/pano-scrobbler-droppy/issues/1 |
| PORT | Frozen macOS port, PR 1 | https://github.com/ranokay/pano-scrobbler/pull/1 |
| PORT-G | Fork branch, `apple/Packages/MacIntegration/Sources/GlobalNowPlayingProvider.swift` | https://github.com/ranokay/pano-scrobbler/blob/a7c83182/apple/Packages/MacIntegration/Sources/GlobalNowPlayingProvider.swift |
| PORT-A | Fork branch, `apple/Packages/MacIntegration/Sources/AppleScriptNowPlayingProvider.swift` | https://github.com/ranokay/pano-scrobbler/blob/a7c83182/apple/Packages/MacIntegration/Sources/AppleScriptNowPlayingProvider.swift |
| FML | Fork branch, `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/MediaListener.kt` at the May 2026 baseline, not upstream | https://github.com/ranokay/pano-scrobbler/blob/a7c83182/composeApp/src/commonMain/kotlin/com/arn/scrobble/media/MediaListener.kt |
| TESTS | Upstream test tree; no media lifecycle tests | https://github.com/kawaiiDango/pano-scrobbler/tree/9901540/composeApp/src/commonTest |

The frozen port is GPL-3.0 [MAP] and is a behavioural reference only. [PORT] Its provider files were read for the macOS platform limitation, not as a source of implementation.
