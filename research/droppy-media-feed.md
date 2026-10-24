# Droppy media feed contract

Research for [issue #4][issue]. This documents what `DroppyMediaHelper.app` exposes, what a Droppy scrobbler droplet can rely on, and what it must own itself.

Probed on 2026-10-24 against Droppy 16.1.2-beta.7 on macOS 27.2, build 26B5091g. The helper was run read-only. No Droppy files were changed.

## Summary

- The helper is the only practical route to now-playing metadata for browser and arbitrary media inside a Store droplet. DroppyKit 1.21.0 exposes a now-playing *view*, not a data API [kit-player][kit-api].
- The helper is an undocumented, unversioned feed built on Apple's private MediaRemote framework. The public explanation for why it still works is its `com.apple.` bundle identifier, a prefix macOS 15.4 and later still admits to MediaRemote [adapter]. Treat it as best effort, not as a contract.
- `get` and `stream` return full metadata only for the current front player. The `sessions` array is a light roster of every known client, with title, playing state and bundle id but no artist, album, duration or position. A scrobbler cannot read full metadata for a chosen background player.
- One-shot polling costs about 17 ms wall time, 9 ms CPU and 12 MB peak RSS per call. At 1 Hz that is about 33 CPU seconds per hour, roughly 0.9 percent of one core, plus 86,400 process launches per day. Adaptive polling at 2 to 5 seconds while playing is defensible. A flat 1 Hz daemon is not.
- Borrow metadata and optional transport commands. Own source selection, track identity, the scrobble state machine, ad and podcast filtering, retries, storage and fallback.

## What the helper is

A Droppy droplet runs inside Droppy's process. `Bundle.main.bundleURL` is the host app, so the helper resolves relative to the host bundle [docs-citizen]:

```
<host>.app/Contents/Helpers/DroppyMediaHelper.app/Contents/MacOS/DroppyMediaHelper
```

For a normal Droppy install that is `/Applications/Droppy.app/Contents/Helpers/DroppyMediaHelper.app/Contents/MacOS/DroppyMediaHelper`. DockDoor's Store droplet uses exactly this path and checks that the file is executable before using it [dd]. The helper is a separate executable, so each `get` is a fresh process and each `stream` is a long-lived one.

A Store droplet cannot ship its own media adapter either. Submissions may depend on DroppyKit alone and may not include binary targets or extra executables [docs-submit]. That leaves Droppy's helper or AppleScript.

Local bundle facts:

| Item | Value |
| --- | --- |
| Bundle identifier | `com.apple.controlcenter.DroppyMediaHelper` |
| `CFBundleShortVersionString` | `1.0` |
| `CFBundleVersion` | `1` |
| `LSMinimumSystemVersion` | `14.0` |
| `LSBackgroundOnly` | `true` |
| Linked framework | `/System/Library/PrivateFrameworks/MediaRemote.framework` |
| Signature | Droppy's Developer ID team, hardened runtime |
| Architecture in this build | arm64 only |

The public explanation for why it still works is that its bundle identifier starts with `com.apple.`. The `mediaremote-adapter` project documents that macOS 15.4 stopped answering ordinary apps, and that processes whose bundle identifier starts with `com.apple.` are still granted MediaRemote access [adapter]. Droppy's helper has such an identifier and uses private MediaRemote notifications and commands. This is a compatibility shim, not a public entitlement, and Apple can close it again.

Droppy's changelog shows both sides of that risk. Version 14.0.3, 2026-06-01, restored Now Playing metadata on macOS 15.4 and later "where the system stopped reporting it to non-Apple apps" [changelog]. Version 14.0.4, 2026-06-07, fixed Now Playing metadata "coming back empty on macOS Tahoe 26.5" [changelog].

No Droppy documentation page describes the helper. The documentation handbook contains 16 uses of "Now Playing" and zero mentions of `DroppyMediaHelper`, "media helper" or "Music Source" [handbook]. The public descriptions of the helper are DockDoor's source, a Droppy maintainer comment in Trench, and observed output.

The maintainer acknowledged the arrangement. When DockDoor 1.0.12 moved to the helper, the Trench reply said:

> DockDoor's own now-playing reader is a separate helper program that can't ship inside a droplet, so the Music widget waited for data that never came. DockDoor 1.0.12 in the Droplet Store now reads what's playing through Droppy's own media helper, the same one the notch player uses, so the widget fills in with the song, artwork and working controls, and it works for other players too. [trench-dd]

That is the strongest public statement that the helper is meant to serve more than Droppy's own UI. It is still a support statement in a bug thread, not a compatibility promise.

## Command surface

Running the helper with no arguments prints this usage line to stderr and exits 1:

```
Usage: DroppyMediaHelper <stream|apple-clock-stream|get|send <commandId> [targetBundleId]|seek|test> [args]
```

| Command | Arguments | Behavior observed |
| --- | --- | --- |
| `get` | `[--now] [--no-artwork]` | Prints one JSON line and exits 0. `--now` produced the same envelope and payload as plain `get` in a fresh process. It did not add an `elapsedTimeNow` field. |
| `stream` | `[--no-diff] [--debounce=N] [--no-artwork]` | Prints one JSON object per line and stays alive until terminated. First line is a full snapshot. Droppy's own process runs `stream --no-diff --debounce=180`. |
| `send` | `<commandId> [targetBundleId]` | Sends a MediaRemote command. DockDoor does not read stdout for commands [dd]. `send 99` printed nothing and exited 0. Missing argument exits 1. A target with no client exits 5 and prints `send: no now-playing client belongs to <id>; nothing sent`. |
| `seek` | `<microseconds>` | Seeks the front player. DockDoor does not read stdout for it [dd]. Missing argument exits 1 and prints `seek: expected position in microseconds`. |
| `test` | none | Printed nothing and exited 0 in this probe. The upstream adapter's `test` can briefly create a fake now-playing entry when nothing is playing; Droppy's behavior there is unconfirmed. |
| `apple-clock-stream` | none | Internal mode. Printed nothing when run from a shell and exited 0. The binary contains the error `apple-clock-stream: Droppy owner process is unavailable`. |
| `qnext`, `qplay`, `skipto` | internal | Referenced in the binary with JSON result types, but absent from the usage line. Undocumented queue operations. Do not use. |

Unknown subcommands exit 1. Unknown flags are ignored: `get --bogus` exited 0 and returned normal JSON. That matters because a removed flag does not fail loudly.

### `get`

A trimmed `get --now --no-artwork` from the probe:

```json
{
  "type": "data",
  "diff": false,
  "ownerLost": false,
  "artworkOmitted": true,
  "payload": {
    "bundleIdentifier": "app.zen-browser.zen",
    "title": "Taste",
    "artist": "Ari Abdul",
    "album": "Taste",
    "duration": 186.6075,
    "elapsedTime": 85.008253,
    "playbackRate": 0,
    "playing": false,
    "timestamp": "2026-10-24T11:03:52.864Z",
    "contentItemIdentifier": "C98EE358-349C-4B0C-A0FD-C11359D765CD"
  },
  "front": { "bundleIdentifier": "app.zen-browser.zen" },
  "sessions": [
    {
      "bundleIdentifier": "app.zen-browser.zen",
      "title": "Taste",
      "playing": false,
      "track": true
    }
  ]
}
```

Key order varies between calls. Parse by key, never by position or string prefix.

`--no-artwork` adds `artworkOmitted: true` and is meant to drop artwork fields. Droppy's helper honored the flag by setting the marker; the probe item had no artwork, so the byte omission itself was not measured. The helper in Droppy Playground 1.0.29 returned the same payload without `artworkOmitted`; treat the flag as host-dependent and strip `artworkData` client-side if it appears.

### `stream`

The first line of `stream --no-diff --debounce=180`:

```json
{
  "type": "data",
  "diff": false,
  "revision": 1,
  "ownerGeneration": 1792858516589271,
  "ownerLost": false,
  "payload": { "title": "Taste", "artist": "Ari Abdul", "playing": false },
  "front": { "bundleIdentifier": "app.zen-browser.zen" },
  "sessions": [ { "bundleIdentifier": "app.zen-browser.zen", "title": "Taste", "playing": false, "track": true } ]
}
```

`stream` adds `revision` and `ownerGeneration`. `revision` starts at 1 and appears to be a per-stream counter; no later line was observed. `ownerGeneration` is an opaque owner generation and differed between separate stream runs. Neither field is documented.

With the default diffing, `diff: true` means the payload holds only changed keys, and a key set to `null` must be removed from the last full snapshot. `--no-diff` avoids that merge logic and is what Droppy itself uses. A scrobbler should use `--no-diff` if it uses `stream` at all.

The stream printed nothing for 15 seconds while the player was paused. There is no heartbeat. Droppy's own maintainer says Droppy "re-checks what is really playing whenever the stream goes quiet", which implies callers need their own staleness timer [trench-sessions].

### `send` and `seek`

`send` takes MediaRemote command IDs. The upstream adapter documents IDs 0 through 13: play, pause, toggle, stop, next, previous, shuffle, repeat, forward seek start and end, backward seek start and end, back 15 seconds, forward 15 seconds [adapter]. DockDoor uses 0, 1, 2, 4 and 5 [dd]. The helper accepts an integer but does not validate it: `send 99` exited 0 and printed nothing.

The optional second argument targets a bundle id. It is best effort. The binary warns that if the target "is not the front now-playing client and MRMediaRemoteSendCommandToClient is unavailable; nothing sent". A real background client may work; a bogus one exits 5.

`seek` takes microseconds and has no target argument. Payload `elapsedTime` and `duration` are seconds. Mixing the two units is an easy bug.

## JSON contract

Envelope fields:

| Field | Type | Presence | Meaning |
| --- | --- | --- | --- |
| `type` | string | always | `"data"` in every observed line |
| `payload` | object or null | always | Full metadata for the front player. Treat null or a missing title as no usable media. |
| `front` | object | observed | `{ "bundleIdentifier": "..." }` for the current front client |
| `sessions` | array | observed | Light roster of known clients |
| `diff` | bool | always | Whether `payload` is partial |
| `ownerLost` | bool | observed | Owner-loss flag; observed false |
| `artworkOmitted` | bool | with `--no-artwork` on Droppy | Artwork was left out |
| `revision` | integer | `stream` only | Per-stream line counter |
| `ownerGeneration` | integer | `stream` only | Opaque owner generation |

Payload fields:

| Field | Type | Observed | Notes |
| --- | --- | --- | --- |
| `bundleIdentifier` | string | yes | Player or browser bundle id |
| `parentApplicationBundleIdentifier` | string | no | Referenced in the binary; DockDoor prefers it over `bundleIdentifier` [dd] |
| `title` | string | yes | Required in practice |
| `artist` | string | yes | May be empty when the source does not report it |
| `album` | string | yes | May equal the title for browser sources |
| `duration` | number, seconds | yes | Can be missing, zero or unusable for live streams |
| `elapsedTime` | number, seconds | yes | Position at `timestamp` |
| `playbackRate` | number | yes | 0 while paused; DockDoor treats a positive rate as playing [dd] |
| `playing` | bool | yes | Use this and `playbackRate`, not one alone |
| `timestamp` | string | yes | ISO 8601 UTC. Droppy emitted milliseconds; Playground emitted whole seconds. |
| `contentItemIdentifier` | string | yes | Item id; may be missing. DockDoor uses it for its artwork cache and falls back to the title [dd]. |
| `artworkData` | base64 string | no | Present only when artwork is available and not omitted |
| `artworkIdentifier` | string | no | Referenced in the binary; likely an artwork cache key |
| `isLiveStream` | bool | no | The binary references `kMRMediaRemoteNowPlayingInfoIsLiveStream`; the emitted key was not observed |
| `iTunesStoreIdentifier` | value | no | Referenced in the binary; not observed |
| `dolbyAtmos`, `lossless`, `mimeType` | values | no | Referenced in the binary; probably Apple Music quality metadata; not observed |

To compute the live position, use the timestamp anchor rather than expecting a "now" field:

```
position = elapsedTime + (now - timestamp) * playbackRate
```

Clamp the result to `[0, duration]` when `duration > 0`, and clamp a future `timestamp` to now. DockDoor does exactly this [dd]. This gives a useful position between polls and lets a 5 second poll behave like a 1 second one for progress display.

Timestamp parsing needs both ISO 8601 forms. DockDoor keeps one formatter with fractional seconds and one without, because both appear [dd]. The probe confirmed the difference between Droppy and Playground.

No-media behavior was not directly observed. DockDoor defends against a literal `null` line and against a missing `payload` object, and clears its state in both cases [dd]. A scrobbler should handle `null`, `{ "payload": null }`, an empty payload and a missing title as "unknown", not automatically as "track stopped".

## macOS version requirements

| Layer | Requirement | Evidence |
| --- | --- | --- |
| Droppy app | macOS 14 Sonoma or later, Apple Silicon and Intel | [docs-what] |
| Helper bundle | `LSMinimumSystemVersion` 14.0 | Local `Info.plist` |
| MediaRemote access | macOS 15.4 and later admits processes whose bundle id starts with `com.apple.` | [adapter] plus local helper bundle id |
| Known OS regressions | 15.4 broke ordinary apps; 26.5 returned empty metadata; Droppy fixed both in 14.0.3 and 14.0.4 | [changelog] |
| Observed working | macOS 27.2, Droppy 16.1.2-beta.7 | Local probe |
| Not tested | macOS 14.x and 15.x | No test host |

The helper has a macOS 14 floor, but the MediaRemote workaround only matters from 15.4 onward. Do not use the presence of the helper as proof that metadata will arrive. Validate the payload.

Architecture follows the host build. This Droppy install and its helper are arm64 only, while the installed Droppy Playground helper is universal. Droppy's docs say Apple Silicon and Intel [docs-what], so an Intel build should carry a compatible helper, but a scrobbler should treat a launch failure or bad CPU type as a normal unavailable case.

## Multi-player and multi-source behavior

macOS has one front now-playing client and a roster of clients that can report now-playing state. The helper exposes both:

- `front` names the client whose metadata is in `payload`.
- `sessions` lists every client the helper knows about, including paused ones.
- Each session has `bundleIdentifier`, `title`, `playing` and `track`.
- A session has no artist, album, duration, elapsed time or playback rate.

Droppy's maintainer described the roster in a Trench reply about a paused browser tab:

> the media helper now reports every session so a paused tab is caught even when another app outranks it, and Droppy re-checks what is really playing whenever the stream goes quiet [trench-sessions]

The same reply says the change was coming in the next nightly after 2026-09-21. DockDoor's droplet requires Droppy 15.3.0 [dd-manifest], which is a practical floor for roster-based reading. The exact first build was not confirmed.

Droppy's own UI has a Music Source picker. Version 14.0.4 added a menu bar picker "so you can pin Droppy's HUDs to a single app ... instead of following whatever macOS Now Playing reports" [changelog]. A Trench idea got this reply from the maintainer:

> Coming in the next update: right-click the notch and there's a Source menu to pick which app drives Now Playing, no trip to the menu bar needed [trench-source]

That picker is Droppy UI policy. It is not exposed to helper consumers. A droplet that runs `get` still receives whatever the helper considers front.

Two audible sources were not tested. The roster behavior is confirmed by the maintainer comment, but the exact selection rules when two apps are audibly playing remain undocumented.

### What this means for a scrobbler

| Question | Answer |
| --- | --- |
| Can I see that another app is playing? | Yes, from `sessions`, with bundle id, title and `playing` |
| Can I read that app's artist, album, duration or position? | No, unless it is the front player |
| Can I ask the helper for a specific app's metadata? | No. `get` and `stream` have no bundle filter |
| Can I send a command to a specific app? | Yes, `send <id> <bundleId>`, best effort |
| Can I seek a specific app? | No, `seek` targets the front player only |
| Can I pin a source the way Droppy's UI does? | No public API for that |

This is the central limitation. If a browser ad, a muted video or a podcast takes the front seat while Spotify keeps playing, the helper would report the ad as `payload`. Spotify would appear only as a session row, if the roster includes it. The scrobbler knows Spotify is playing but cannot read the track. It must either wait for the front to return, use a per-app AppleScript path for Music or Spotify, or accept a gap.

## Per-app filtering

Read filtering is not possible inside the helper. A caller filters the front payload by `parentApplicationBundleIdentifier` first and `bundleIdentifier` second, the same order DockDoor uses [dd]. `sessions` can confirm that another app is active, but it cannot supply that app's full metadata.

Write filtering is possible but weak. `send` accepts a target bundle id. The binary's own error text says a target that is not the front client only works when `MRMediaRemoteSendCommandToClient` is available. Treat targeted control as best effort.

For a scrobbler that must cover Music and Spotify reliably, AppleScript is the stronger per-app source. Droppy's permissions page lists Automation for "Music and Spotify for playback" [docs-permissions]. It needs the user's Automation consent, and it provides per-app metadata regardless of which app owns the front seat. Browsers have no equivalent, so the helper remains the only route there.

There is no URL or domain field in the payload. A browser session exposes a bundle id, title, artist, album and duration. That is not enough to tell a YouTube song from a YouTube ad with certainty. Browser scrobbling is inherently heuristic.

## Ads, podcasts and live streams

The helper does not expose an ad, podcast or media-type field in the observed payload. The binary references `com.apple.podcasts` and `kMRMediaRemoteNowPlayingInfoIsLiveStream`, but neither produced a classification field in the probe. `sessions[].track` is a boolean, observed `true` for a browser music track; its exact meaning is undocumented. Do not use it as the only classifier.

Known hazards from Droppy's own bug history:

- Muted autoplaying videos on news sites and social feeds stole the media player from Spotify and Apple Music while music kept playing. Droppy fixed that in 14.1.0 [changelog]. A helper consumer can still see the same front-seat changes when Droppy's heuristics do not apply.
- Chromium browsers can report an infinite duration for a live stream. Droppy's helper once dropped that update "without a trace", and every later update built on it was dropped too, leaving the UI counting from stale data. The helper now leaves the bad number out [trench-browser].
- Browser media detection has a long fix history: tabs not detected until music paused, sessions disappearing while still playing, next and previous not working, and album art mismatches [changelog].

A scrobbler needs its own filters:

- Require `playing == true` and a plausible `playbackRate`.
- Require a non-empty title and artist for music scrobbles, or an explicit allowlist for apps that report instrumentals.
- Reject `duration <= 0` or missing duration for non-live media.
- Exclude `com.apple.podcasts` by default unless the user opts into podcast scrobbling.
- Exclude browser bundle ids by default, or require the user to opt in per browser.
- Treat a missing or unchanged payload as unknown, not as a stop event.
- Never turn a single bad record into a track end. Wait for a valid replacement or a timeout.

Podcast episodes and ads inside podcasts have no chapter or ad marker in the payload schema. Any ad skipping is a title and duration heuristic at best.

## Polling cost and battery

Measured with 50 sequential `get --now --no-artwork` calls on the probe machine, using `resource.getrusage(RUSAGE_CHILDREN)`:

| Metric | Per call |
| --- | --- |
| Wall time | 17.1 ms |
| User CPU | 5.8 ms |
| System CPU | 3.25 ms |
| Total CPU | about 9 ms |
| Peak RSS | 11.9 MB |

Derived cost:

| Interval | Calls per day | CPU per hour | Share of one core |
| --- | --- | --- | --- |
| 1 s | 86,400 | 32.6 s | about 0.9% |
| 5 s | 17,280 | 6.5 s | about 0.18% |
| 15 s | 5,760 | 2.2 s | about 0.06% |
| 30 s | 2,880 | 1.1 s | about 0.03% |

These numbers are CPU time only. They exclude scheduler wakeups, process creation overhead, page cache churn and the cost of the caller's own JSON parsing. At 1 Hz the process launches are likely more important for battery than the 33 CPU seconds per hour. The measurement used `--no-artwork`; a payload with base64 artwork can add hundreds of kilobytes per update, which is why DockDoor fetches artwork only when the item changes [dd] and why a scrobbler should never request it.

For comparison, Droppy's own long-lived helper was observed after 57 minutes of elapsed time:

```
stream --no-diff --debounce=180     TIME 0:00.04     RSS 7,136 KB     %CPU 0.0
```

An idle stream is effectively free compared with polling. Updates add work, but there is no per-call process launch.

## Is continuous polling acceptable?

Not as a flat 1 Hz process spawn for the droplet's whole lifetime.

It is technically feasible. At 1 Hz it costs about 0.9 percent of one core and 86,400 process launches per day. On a Mac that is plugged in, that is tolerable. On battery, it is avoidable waste whenever nothing is playing, and Droppy's own guidance for droplets says a poll nobody looks at is "Droppy draining the battery", that work should run only while someone can see it, and that polling faster than the data changes is a review problem [docs-citizen].

An adaptive schedule is defensible. DockDoor's own 1.0.12 changelog says it reads the helper "only while the widget is on screen" [dd-changelog], which is the same rule a scrobbler should apply in a different form: work only while there is media to observe.

| State | Interval | Reason |
| --- | --- | --- |
| No payload or no title | 15 to 30 s | Confirm media appeared without constant spawning |
| Paused | 10 to 15 s | Position does not move; track changes are the only event |
| Playing | 2 to 5 s | Enough to catch track changes and seek jumps; interpolate position from `timestamp` |
| Just after a track change or seek | immediate | Avoid waiting a full interval for the new identity |

A 5 second interval costs about 0.18 percent of one core and 17,280 launches per day, which is a reasonable ceiling for an always-on scrobbler. A 1 second interval should be a short burst around a known transition, not the steady state.

A supervised `stream` is the energy-correct shape: one process, no per-update spawn, event-driven updates. It is also the shape Droppy uses for itself. The reason not to depend on it is ownership. DockDoor's authors deliberately avoid it:

> This service asks it with one-shot reads (`get`), never its `stream`, which Droppy's player owns and sweeps by command line [dd]

A 15 second probe of a second stream was not killed, so the sweep is not immediate or unconditional. That is not enough evidence to build on. A droplet that spawns the same helper executable as Droppy's own player may look like a duplicate during Droppy's stale-helper cleanup. If a scrobbler does use `stream`, it must own supervision, restart with backoff, and a staleness timeout that falls back to `get`. For a Store droplet, one-shot adaptive polling is the safer contract.

The droplet also must stop all polling in `deactivate()`. DroppyKit calls `deactivate()` when the user disables or removes the droplet, and anything still running afterward is a review finding [docs-submit].

## Stability of the path and the contract

### Path

The relative path inside the host bundle is stable across Droppy updates. `Bundle.main.bundleURL` resolves to Droppy for a droplet, so no absolute path is needed [docs-citizen]. Droppy's installer requires the app to live in Applications [docs-install], and Droppy updates itself, so the helper binary is replaced without changing its relative path [docs-updates]. The same relative path exists in Droppy Playground, which is useful for development but is a different host with its own helper build.

The absolute path is not stable. A renamed app, a copy outside Applications, a moved bundle or a different host all change it. An external tool should resolve Droppy by bundle id `iordv.Droppy` and append the relative path; a droplet should use `Bundle.main.bundleURL`.

There is no versioned helper API. `CFBundleShortVersionString` is `1.0` and `CFBundleVersion` is `1` in both the Droppy 16.1.2-beta.7 helper and the Playground 1.0.29 helper. The version field cannot tell a caller which commands or fields exist.

### Contract

The contract is undocumented and unversioned. The only public descriptions are DockDoor's consumer code, a Droppy maintainer comment in Trench, and observed output. There is no JSON schema, no compatibility promise, and no deprecation path. The helper has hidden commands (`qnext`, `qplay`, `skipto`) and hidden fields, and unknown flags are silently ignored.

The contract has already drifted:

- `--micros` had no effect: `get --now --micros` still returned `duration` and `elapsedTime`, not `durationMicros` and `elapsedTimeMicros`.
- `--allow-missing-title` could not be tested because the probe track had a title.
- `get --now` did not add `elapsedTimeNow`, which the upstream adapter does.
- Droppy's helper emitted millisecond timestamps; Playground's emitted whole-second timestamps.
- Playground's helper did not emit `artworkOmitted` for `--no-artwork`.

These are not necessarily bugs. They show that the helper is a Droppy-internal tool, not a reimplementation of the adapter's public CLI.

### What breaks if Droppy changes the helper

| Change | Symptom | Detection | Response |
| --- | --- | --- | --- |
| Helper moved, renamed or removed | Spawn fails with `ENOENT` or permission error | `isExecutableFile`, `Process.run` error | Mark the feed unavailable; fall back to AppleScript for Music and Spotify; keep queued scrobbles |
| Command or flag removed | Exit 1, or a flag is ignored and a field disappears | Validate required keys and freshness, do not trust exit 0 | Re-resolve path, retry once, then degrade |
| JSON key renamed or removed | `title`, `artist` or `timestamp` is nil | Schema validation on every read | Skip the record, keep the last good state, log the shape |
| `sessions` or `front` semantics change | Wrong app attributed, or a playing app invisible | Compare `front` with `sessions[].playing` | Prefer the documented consumer behavior, but treat the feed as suspect |
| Bundle id changes | Empty payload on macOS 15.4 and later | `test` nonzero or persistent empty payload | Require a Droppy update; no client-side fix |
| macOS update breaks MediaRemote again | Empty metadata across all apps | Same as above, with OS version in logs | Require a Droppy update; fall back to AppleScript |
| Helper hangs | No stdout within its 1.5 s internal bound | Caller timeout at about 2 s | Kill the process group, mark unavailable, retry with backoff |
| Droppy updates while a poll runs | One or two failed reads | Spawn error or short read | Retry after the update settles; do not clear the queue |
| A second stream is swept | Stream exits with no error | EOF, no heartbeat | Fall back to `get`; do not loop restart aggressively |
| Invalid duration or live stream | Payload missing, or a bad value blocks updates | Validate types; compare `revision` | Treat as unknown or live; do not scrobble as a normal track |
| Artwork unexpectedly included | Large payload, CPU spike, memory spike | Payload size | Drop `artworkData` before image decode; never request it |

### Stability rating

| Aspect | Rating | Reason |
| --- | --- | --- |
| Relative path in host bundle | High | Same relative path in Droppy and Playground; unchanged in the observed Droppy build |
| Absolute path | Low | Depends on install location, app name and host |
| Command names | Medium | Listed in usage, but hidden commands exist and no versioning |
| Flags | Low | Unknown flags ignored, upstream flags already ignored |
| JSON field set | Low | No schema, optional fields, host drift |
| Semantics | Low | `sessions`, `front`, `track`, `ownerLost` undocumented |
| OS access | Low | Private MediaRemote allowlist, broken in 15.4 and 26.5 |
| Support commitment | Low | No Droppy docs, one documented consumer, Trench comment only |

Overall: an undocumented dependency suitable for a best-effort feed, not for the only path to a scrobble that must not be lost.

## What a scrobbler must own versus borrow

| Concern | Borrow from the helper | Own in the droplet |
| --- | --- | --- |
| Current front metadata | Title, artist, album, duration, elapsed, rate, bundle id | Validate and normalize every field |
| Playback position | `elapsedTime`, `timestamp`, `playbackRate` | Interpolation, clock skew, clamping, seek detection |
| Transport | `send`, `seek` if the droplet exposes controls | Confirmation, optimistic state, error handling |
| Source discovery | `front` and `sessions` | Allowlist, browser policy, source switching policy |
| Multi-player policy | Roster hints | Which app wins when several are playing |
| Track identity | `contentItemIdentifier` when present | Dedupe, fallback identity, repeat detection |
| Scrobble rules | Nothing | Start, pause, resume, seek, stop, 50 percent or 4 minute threshold |
| Ads, podcasts, live streams | Nothing reliable | Filtering and user preferences |
| Network and storage | Nothing | Last.fm, ListenBrainz, Libre.fm and Pleroma clients, SQLite queue, retries |
| Lifecycle | Nothing | Sleep and wake, Droppy quit, `deactivate()`, backoff |
| Fallback | Nothing | AppleScript for Music and Spotify, unavailable state for the rest |
| Privacy and consent | Nothing | What is read, what is sent, user controls |

## Failure modes

| Failure | What the user sees | What the scrobbler must do |
| --- | --- | --- |
| Droppy not installed or helper missing | No now playing at all | Show an unavailable state; keep the queue; do not crash |
| Harness or preview has no Droppy helper | No now playing during development | Use a fixture or the unavailable state; do not treat the harness as Droppy |
| Helper present but not executable | Spawn error | Try the Playground path only for development; otherwise unavailable |
| Helper hangs | No metadata | Timeout at about 2 s, kill the process group, retry with backoff |
| Droppy update replaces the helper | One or two missed reads | Re-resolve on failure, retry, keep state |
| macOS update breaks MediaRemote | Every app returns empty | Health check, log, fall back to AppleScript, tell the user Droppy may need an update |
| Multiple players, front is an ad or video | Wrong title or no title while `sessions` shows music | Do not scrobble the ad; wait for the front to return; use AppleScript for the music app if allowed |
| Podcast or audiobook takes the front seat | Long non-music title | Exclude by bundle id or duration policy |
| Live stream with no duration | Missing duration or position resets | Mark live, skip scrobble or handle per service rules |
| Browser tab disappears | Payload null or stale | Confirm with a timeout; do not treat one null as a stop |
| Seek or restart | Elapsed jumps backward | Reset the position anchor; do not start a new scrobble |
| Track repeats | Same title, new item id or reset elapsed | Use `contentItemIdentifier` plus elapsed reset to detect a repeat |
| Helper returns a partial diff | Missing keys | Use `--no-diff`, or merge diffs with a full snapshot |
| Invalid number in one update | Later updates stale | Validate types; keep the last good record; watch `revision` |

## Recommendation

1. Wrap the helper behind a small `MediaFeed` interface with `read`, `send`, `seek` and `health`. Keep the path resolution, process launch, timeout and JSON parsing in one place.
2. Resolve the helper from `Bundle.main.bundleURL` and check `isExecutableFile` before every launch. Fall back to the Droppy Playground path only in development.
3. Use `get --now --no-artwork`. Parse one JSON line, validate the envelope and required fields, and strip artwork even when the flag claims it is omitted.
4. Poll adaptively: 2 to 5 seconds while playing, 10 to 15 seconds paused, 15 to 30 seconds when no media is present. Read immediately after a track change or seek. Stop in `deactivate()`.
5. Treat `stream` as owned by Droppy. DockDoor reports that Droppy sweeps it, and a 15 second probe is not enough to rely on it. If a stream is used for a non-Store build, supervise it, handle EOF and fall back to polling.
6. Scrobble the front player only. Treat a playing row in `sessions` as a hint, not as readable metadata. Use AppleScript for Music and Spotify when per-app coverage matters.
7. Own the track state machine, identity, thresholds, queue, retries and ad and podcast filters. The helper supplies observations, not scrobble decisions.
8. Treat any missing or invalid field as unknown. Never turn a parse failure into a stop event or a lost scrobble.
9. Run `test` once at activation and after repeated empty payloads, not on a timer. Log the helper path, bundle version, host version and macOS version with failures.
10. Ask the Droppy maintainer for a supported now-playing data API or a documented helper contract. Until then, ship the feed adapter and fallbacks as best effort and say so in the droplet's README.

## Open questions

- Does `get` work when Droppy is not running? The helper is a separate process and talks to mediaremoted, but this was not tested. A droplet always runs inside a live host, so the question matters only for an external tool.
- What exactly does the helper print when no media is present: `null`, `{ "payload": null }`, or a payload with no title? DockDoor handles all three.
- What do `track`, `ownerLost`, `ownerGeneration` and `revision` mean in edge cases? Only `revision` is obviously a counter.
- Does `sessions` include every player macOS knows about, or only those that registered with MediaRemote? The maintainer's comment says every session, but the boundary is unclear.
- Is `stream` actually swept by Droppy, and under what trigger? DockDoor says it is; a 15 second probe survived.
- Does `--no-artwork` work in every host build? Playground did not report `artworkOmitted`.
- Which Droppy build first shipped the all-session roster: 15.2.3 nightly or 15.3.0? DockDoor's manifest uses 15.3.0 as its floor.
- Does the helper work on Intel Droppy builds? This install is arm64 only; Playground is universal.
- Can a sandboxed or notarized third-party caller spawn another app's helper? DockDoor spawns it from inside Droppy, so that path works; an external caller was not tested.
- Are `isLiveStream`, `iTunesStoreIdentifier`, `dolbyAtmos`, `lossless` and `mimeType` ever emitted? The binary references them; the probe did not see them.

## Sources

- [Issue #4, Pin down Droppy's media feed contract][issue]
- [DockDoor `MediaRemoteService.swift`, commit 8a70ff3][dd]
- [DockDoor `droplet.json`, commit 8a70ff3][dd-manifest]
- [DockDoor changelog, 1.0.12][dd-changelog]
- [Trench 8a8c2bb0, DockDoor music player not working][trench-dd]
- [Trench 1edb34f6, paused browser tab and every-session reporting][trench-sessions]
- [Trench bcf513ec, browser playback and invalid duration][trench-browser]
- [Trench 84ff10e6, media Source selector][trench-source]
- [Droppy docs, What Droppy is][docs-what]
- [Droppy docs, Install and activate][docs-install]
- [Droppy docs, Updates and channels][docs-updates]
- [Droppy docs, Permissions][docs-permissions]
- [Droppy docs, Good citizen][docs-citizen]
- [Droppy docs, Submitting][docs-submit]
- [Droppy docs, DroppyNowPlayingPlayer][kit-player]
- [DroppyKit API index][kit-api]
- [Droppy changelog][changelog]
- [Droppy documentation handbook][handbook]
- [mediaremote-adapter README][adapter]

[issue]: https://github.com/ranokay/pano-scrobbler-droppy/issues/4
[dd]: https://gitlab.com/droppyformac1/droplets/-/blob/8a70ff37919a76f169e96485c797db4e306f1164/droplets/dockdoor/Sources/DockDoor/Utilities/Media/MediaRemoteService.swift
[dd-manifest]: https://gitlab.com/droppyformac1/droplets/-/blob/8a70ff37919a76f169e96485c797db4e306f1164/droplets/dockdoor/droplet.json
[dd-changelog]: https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/CHANGELOG.md
[trench-dd]: https://getdroppy.app/trench?post=8a8c2bb0-acc0-4e15-ba8e-1d4f66e7bbe7
[trench-sessions]: https://getdroppy.app/trench?post=1edb34f6-3ff6-4d78-acc7-12642848d0c4
[trench-browser]: https://getdroppy.app/trench?post=bcf513ec-7b31-493d-8e58-f22dae0fd35f
[trench-source]: https://getdroppy.app/trench?post=84ff10e6-806c-4a66-aa27-39dafd6d2aba
[docs-what]: https://getdroppy.app/docs/what
[docs-install]: https://getdroppy.app/docs/install
[docs-updates]: https://getdroppy.app/docs/updates
[docs-permissions]: https://getdroppy.app/docs/permissions
[docs-citizen]: https://getdroppy.app/docs/droppykit/good-citizen
[docs-submit]: https://getdroppy.app/docs/droppykit/submitting
[kit-player]: https://getdroppy.app/docs/droppykit/api/droppy-now-playing-player
[kit-api]: https://getdroppy.app/docs/droppykit/api
[changelog]: https://getdroppy.app/changelog
[handbook]: https://getdroppy.app/docs/handbook
[adapter]: https://github.com/ungive/mediaremote-adapter
