# Droppy review precedent for a background scrobbler

Research for [issue #9](https://github.com/ranokay/pano-scrobbler-droppy/issues/9). Checked 2026-10-24 against the public DroppyKit docs (last updated 2026-09-09), the Droplet Store at commit [`154eb35`](https://gitlab.com/droppyformac1/droplets/-/commit/154eb35ad155b31f49c2731048c080f78ba30035), the public droplet catalogue, the Trench board, and the Last.fm API docs. No private Discord thread or maintainer conversation was available.

## Short answer

The public rules do not settle continuous scrobbling. The good-citizen page says to stop work when nothing is visible, then allows "a timer the user started, a download, a live activity that is counting down". A scrobbler is user-started but open-ended. No public droplet scrobbles, so there is no acceptance precedent to point at.

Three shipped droplets do sustained work beyond the visible surface. Sales polls store APIs every two minutes while an account is connected. DropClip keeps global input monitors while the droplet is enabled. DockDoor keeps Dock and accessibility observers, and reads Droppy's media helper once per second while a media widget is on screen. Sales and DropClip are first-party. DockDoor sits on the community shelf but the maintainer submitted it. None is a community-authored scrobbler.

DockDoor is the only GPL-3.0 droplet in the Store repository. Its provenance file records the upstream author's written permission and the maintainer's direct involvement. The docs still say GPL cannot go into a droplet. Treat DockDoor as a one-off, not a route for Pano code.

Attribution has a working precedent. DropClip's Store description says "Based on OpenClip by Ganesh M, under the MIT License", and its README keeps the upstream name to attribution only. A clean-room MIT droplet can probably say "Inspired by Pano Scrobbler" in its README and description, but the docs name ports and marks, not inspiration. Ask before shipping.

The exact questions for the maintainer are at the end.

## The written rules

### Work stops when nobody is looking

[Good citizen](https://getdroppy.app/docs/droppykit/good-citizen):

> A widget nobody is looking at needs no fresh data. Refresh while it is on screen and stop when it is not.

The page adds that "Each rule on this page is one a submission broke, and review sends it back for." This is review-enforced, not advice.

### The exception for unseen work

The same page:

> Some work has to run unseen: a timer the user started, a download, a live activity that is counting down. That is fine. A poll for a widget nobody has open is not, and neither is polling faster than the data changes.

Read narrowly, scrobbling is none of the three examples. Read by purpose, it is work the user started and expects to continue. The docs do not resolve which reading review uses. This is the central unknown.

### Opt-in for work that sends data

> Anything that takes something over, costs battery, holds the notch or sends data starts off, and the user switches it on in your settings pane.

The examples that follow include "a request that sends something about the user ... before the user has said yes to it". A scrobbler sends track data to a third party, so the literal reading requires a switch in the droplet's settings, not just installing the droplet.

### Tear down on deactivate

[Submitting](https://getdroppy.app/docs/droppykit/submitting) lists what review sends back:

> Work that does not stop. A timer or observer that survives `deactivate()`. Swift cannot unload code, so it runs until Droppy relaunches.

The lifecycle page says the same in stronger terms: "Everything `activate(host:)` starts, `deactivate()` stops", and "After it returns the droplet must be inert" ([droplet-setup](https://getdroppy.app/docs/droppykit/droplet-setup)). The Store's [CONTRIBUTING](https://gitlab.com/droppyformac1/droplets/-/blob/main/CONTRIBUTING.md) repeats it: "Work that survives `deactivate()`: a timer, an observer, a window."

### Secrets go in the Keychain

> `DropletPreferencesService` is plain `UserDefaults` in Droppy's own domain, under `droplet.<your-id>.<key>`: anything that can read Droppy's preferences file reads it in plain text. API keys, tokens, passwords and one-time-password seeds go in the Keychain.

The page gives a `SecItemAdd` / `SecItemCopyMatching` example and asks for a Sign out or Remove key button that deletes the item. The capability table separately grants `network-client` for "Outbound network requests" ([droplet-setup](https://getdroppy.app/docs/droppykit/droplet-setup)).

### GPL and AGPL

> Code under the GPL or the AGPL cannot go into a droplet, because a droplet runs linked into Droppy's own process. Ask before using anything under another copyleft licence.

The Store [LICENSE](https://gitlab.com/droppyformac1/droplets/-/blob/main/LICENSE) says each droplet keeps its own licence, and the repository's source-available terms do not change it. The developer terms add that the submitter must own or be licensed to use everything in the droplet ([terms](https://getdroppy.app/droplet-developer-terms)).

### Names and credit

> Name every project, artwork, sound or data set you did not make yourself in your README's Credits section: whose it is, its licence and a link.

> Say so when your droplet is a port of somebody else's project, and have their permission.

> No other company's logo, icon or mark appears anywhere in your droplet: the widget, the settings page, the README or your Icon concept. Your droplet's name is yours, not another company's ... When the droplet works with a service, say that in plain words where it matters ... and draw your own glyph for what the droplet does.

The "mark in the README" sentence is in tension with DropClip's accepted attribution, covered below. Read in context, the rule targets third-party branding, not a factual credit line.

## What the Store ships

### DockDoor is the background-work precedent, with caveats

DockDoor's manifest declares `accessibility`, `screen-capture`, `global-shortcuts`, `calendars`, `apple-events` and `network-client`, and only one surface, `settings-pane` ([droplet.json](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/droplet.json)). It declares no shelf widget, live activity or notch surface, so a droplet can be settings-only in its declared surfaces.

The engine starts the Dock observer, window observers, event tap, gestures and active-app indicator when their switches are on, and tears them down in `stop()` ([DockDoorEngine.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/Sources/DockDoor/DockDoorEngine.swift)). `deactivate()` calls `engine.stop()` and clears the capture flag ([DockDoorDroplet.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/Sources/DockDoor/DockDoorDroplet.swift)). This is persistent, user-enabled observation with no surface open.

The media read is the closest thing to scrobbler polling. It invokes Droppy's bundled helper at `Contents/Helpers/DroppyMediaHelper.app/Contents/MacOS/DroppyMediaHelper` with one-shot `get --now` reads, "once when a Dock hover begins and the last read is stale", and "every second while a media widget is on screen (`beginWatching`)". The file says: "Nothing runs while no widget is up, so DockDoor costs nothing at idle", and it "never its `stream`, which Droppy's player owns" ([MediaRemoteService.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/Sources/DockDoor/Utilities/Media/MediaRemoteService.swift)). The timer is one second with 0.2 tolerance; `endWatching()` invalidates it.

That code arrived in [MR !194](https://gitlab.com/droppyformac1/droplets/-/merge_requests/194), merged 2026-10-21, which also changed the default media mode to `universal` and added the helper path. The merge is the review evidence; the merge request has no public reviewer comments. The original port is [MR !176](https://gitlab.com/droppyformac1/droplets/-/merge_requests/176), merged 2026-10-19.

Caveat: DockDoor is `creator.kind: community` for ejbills, but `creator.gitlab` is `droppyformac`, and the MR author is `droppyformac`. It is a maintainer-submitted port, not an independent community submission.

### Sales runs a continuous network loop

Sales is first-party, proprietary, and declares `network-client` and `hud` ([droplet.json](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/droplet.json)). Its own header describes "a few small requests every couple of minutes, and nothing in between: no timer runs while the reads are asleep" ([SalesDroplet.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/Sources/Sales/SalesDroplet.swift)).

`startLoop()` reads, sleeps for the user's interval, and reads again, while `Task` is not cancelled. The default is every two minutes, with options from one to fifteen minutes ([SalesSettings.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/Sources/Sales/SalesSettings.swift)). The loop runs while a store is connected, independent of whether the shelf or notch is showing. `deactivate()` cancels the loop and the sleep. Failures back off from one minute to thirty, and a refused key waits fifteen minutes.

Keys are in the Keychain: one generic password per store, service `app.getdroppy.droplet.sales.<host bundle id>`, `kSecAttrAccessibleAfterFirstUnlock`, deleted in `prepareForRemoval()` ([SalesKeychain.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/Sources/Sales/SalesKeychain.swift)). The comment is explicit: "Keys live in the Keychain and nowhere else: never in preferences, never in a file, never in a log line."

This is accepted continuous background network work with user-connected credentials. It is first-party, and it has a visible notch total, so it does not prove what review would say to a community scrobbler.

### DropClip keeps global monitors and bends the Keychain rule

DropClip is first-party, licensed MIT and Apache-2.0, and a fork of OpenClip. Its runtime starts a selection monitor, hotkeys, an extensions watcher and a pause timer on activation, and `suspend()` stops the monitor, shortcuts and watcher on `deactivate()` ([DropClipDroplet.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/Droppy/DropClipDroplet.swift)). The monitor installs global mouse and keyboard event monitors that run whenever the droplet is enabled, with no Droppy surface open ([MacSelectionMonitor.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/Platform/MacSelectionMonitor.swift)).

Its secrets do not use the Keychain. `SecretStore` writes `~/.dropclip/secrets.json` with POSIX 0600 and says it "Replaces macOS Keychain to avoid code-signing ACL prompts, build-signature mismatches, and user authorization dialogs" ([SecretStore.swift](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/Platform/SecretStore.swift)). That contradicts the Keychain rule and still shipped. It is first-party, and the file holds AI provider keys, so treat it as a deliberate first-party exception, not a pattern for a community droplet.

DropClip also supplies the attribution precedent. Its Store description ends "Based on OpenClip by Ganesh M, under the MIT License" ([droplet.json](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/droplet.json)). The README says the fork needs nobody's permission because it was taken under MIT, and "Never use the OpenClip name or logo as DropClip's branding. The name appears only in attribution" ([README](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/README.md)).

### What is absent

The public catalogue has 43 droplets and none matches scrobble, Last.fm, ListenBrainz or Pano ([catalogue](https://getdroppy.app/api/v1/droplets), checked 2026-10-24). A search of the public Trench board returned no post matching scrobble, Last.fm, ListenBrainz or Pano ([Trench](https://getdroppy.app/trench), checked the same day). The search may not cover comments or private Discord, so this shows the absence of a public record, not the absence of discussion.

Of the six droplets in the Store repository, three do sustained work: Sales, DropClip and DockDoor. Sales and DropClip are first-party. DockDoor is the only community-shelf one, and the maintainer submitted it. The independent community droplets, Thaw and Devly, do not demonstrate an always-on background loop: Thaw refreshes once on activation and Devly declares only `clipboard-write`.

## DockDoor and the GPL exception

The facts:

- `droplet.json` says `"license": "GPL-3.0-only"`, and the description says "DockDoor is GPL-3.0; the port is published in the Droplet Store under the same licence."
- `PROVENANCE.md` records upstream commit `77e4771` (2026-10-17), "Upstream licence: GPL-3.0, reproduced in `LICENSE`", and: "Permission: the author agreed in writing on 2026-10-18 to a DockDoor/Droppy collaboration in which Droppy renames nothing, keeps the DockDoor name and icon, adds backlinks to DockDoor Pro and the donation page, and may use 'any bit of the code from the open source repo'. The full conversation is held by Droppy's maintainer." ([PROVENANCE.md](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/PROVENANCE.md))
- The licence file is the full GPL-3.0 text with DockDoor's copyright ([LICENSE](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/LICENSE)).
- The MR was opened and merged by `droppyformac` on 2026-10-19.

What this means, as inference rather than stated policy: the GPL rule exists because a droplet is linked into Droppy's proprietary process. DockDoor's provenance treats the upstream author's written permission as what made this port acceptable, and the maintainer merged it himself. That is an exception tied to that author, that code and that reviewer. It is not a general path for Pano Scrobbler, which is GPL-3.0-or-later ([Pano licence](https://github.com/kawaiiDango/pano-scrobbler/blob/main/LICENSE)). Code copied from Pano would bring GPL terms and would need the same kind of permission and the same maintainer decision. A clean-room MIT droplet avoids the issue.

The docs have not been updated to mention the exception. A reader of Good citizen alone would conclude DockDoor cannot exist.

## "Inspired by Pano Scrobbler"

What the docs allow:

- Credit every project you did not make in the README's Credits section, with owner, licence and link.
- Say when the droplet is a port, and have the author's permission.
- Do not use another company's logo, icon or mark as your branding. The droplet's name and icon are yours.

What the Store shows:

- DropClip names OpenClip in its public Store description and README, keeps the name out of its product identity, and states the MIT basis. It was accepted, though as a first-party droplet.
- DockDoor keeps the upstream name and icon by written agreement. That is a negotiated exception, not a model for a clean-room droplet.
- An open, unmerged MR for Slow Quit Apps uses the phrase "Inspired by and ported from [SlowQuit]" ([MR !100](https://gitlab.com/droppyformac1/droplets/-/merge_requests/100)). It is not merged, so it is a style example, not precedent.

Inference: a clean-room MIT droplet that copies no code, strings or assets can use a factual line such as "Inspired by Pano Scrobbler by kawaiiDango" in the README Credits and manifest description. It should not use Pano in the droplet name, icon or product identity, and it should say plainly that no Pano code was used. Because the docs only spell out ports, and because Pano is GPL, this needs the maintainer's answer before the wording is fixed.

## Inferences for the design

These are recommendations from the evidence, not statements of policy.

1. Default the droplet to off, and add a separate "Scrobble in the background" switch that also defaults off. The docs say data-sending work starts off and is switched on in the settings pane. A connected account alone may not satisfy the literal rule.
2. Keep a visible, user-controlled status somewhere in Droppy, such as a settings row that says what is being scrobbled and a live activity only while a track plays. Sales and DockDoor both give the user a surface that explains the background work.
3. Poll the helper while music plays, not all day at full rate. DockDoor's accepted rate is one second while a media widget is visible, but a scrobbler runs for hours. Two to five seconds with `--no-artwork`, plus a pause when playback stops, is easier to defend on battery. The exact rate is a maintainer question.
4. Send now-playing when a track starts and the scrobble when Last.fm's threshold is met. Last.fm asks for both, sets the threshold at half the track or four minutes, whichever comes first, and recommends a local cache that survives restarts, with batches of up to 50 ([Last.fm scrobbling](https://www.last.fm/api/scrobbling)).
5. Keep the session key in the Keychain and delete it on disconnect and removal. Do not put it in `DropletPreferencesService`. Ask whether review accepts the app-level API secret that Last.fm desktop authentication requires.
6. Keep a provenance note that names Pano, its GPL-3.0 licence and the fact that no code, strings or assets were copied. Do not take anything from Pano or the frozen macOS port.
7. Say in the Store description that scrobbling runs while Droppy is running. The submission rules allow no executable besides the harness and document no login-item API, so scrobbling stops when Droppy quits.

## Questions for the maintainer

These are the exact questions to post. Each answer unblocks a design or wording decision.

### Background scrobbling

1. Will the Store accept a droplet whose main job runs while no Droppy surface is open, if the user turns it on and connects a scrobbling account?

   Unblocks: whether an always-on scrobbling engine is viable at all, or whether the droplet must be shelf-only.

2. What counts as the user turning it on: enabling the droplet, connecting the Last.fm account, or a separate "Scrobble in the background" switch that defaults off?

   Unblocks: the settings layout, the default state, and the first-run flow.

3. Does "a timer the user started" in Good citizen cover an open-ended user-enabled service like scrobbling, or only finite timers, downloads and countdowns?

   Unblocks: whether we need an explicit exception, and how the review risk is described in the plan.

4. Should scrobbling stop when the Mac sleeps, the screen locks, the screen turns off, or Droppy quits? What should happen to a track that spans a sleep?

   Unblocks: sleep/wake handling, queue timestamps, and what the Store description promises.

5. Is "scrobbles while Droppy is running" acceptable, given a droplet cannot install a login item or a helper agent?

   Unblocks: the product claim and whether any parity item depends on scrobbling while Droppy is closed.

### Media helper

6. Is `Contents/Helpers/DroppyMediaHelper.app` a supported interface for droplets, or an internal dependency that may change without notice?

   Unblocks: whether to depend on the helper, duplicate a MediaRemote path, or ask for an SDK API first.

7. What poll interval is acceptable while music plays? DockDoor uses one second, but only while a media widget is on screen. Is two to five seconds acceptable for a scrobbler that runs for hours?

   Unblocks: the timer interval, battery estimate, and review copy about energy use.

8. May we call the helper's `get --now` while nothing is on screen, given that scrobbling needs it? May we ever use `stream`, or is that reserved for Droppy's player?

   Unblocks: the read strategy and whether the droplet can work at all without an exception.

9. Could DroppyKit expose a now-playing data service or a `media-read` capability? If so, should the droplet wait for it rather than depend on the helper?

   Unblocks: build-now versus SDK-request sequencing.

### Network, storage and Keychain

10. Is continuous outbound traffic to the user's scrobbling services acceptable under `network-client` once an account is connected, and what should the Store description disclose?

    Unblocks: the capability list and the public privacy wording.

11. Is a local SQLite queue in `containerDirectory`, with retry and backoff, the expected design? Is there a size or retention limit review would want?

    Unblocks: the queue schema and cleanup policy.

12. Is the Last.fm session key required to be in the Keychain, and is the app-level Last.fm API secret allowed to ship in the binary? Which service name convention do you want: `droplet.<id>` or `app.getdroppy.droplet.<id>...`?

    Unblocks: authentication storage, Keychain migration, and the security review.

13. Is a disconnect control required, and must it delete the session key, the local queue and any cached history? What else should removal clear?

    Unblocks: the account settings page and `prepareForRemoval()`.

### GPL and attribution

14. DockDoor is GPL-3.0-only in the Store while Good citizen says GPL cannot go in. Was that a one-off permissioned port, and is there any general exception path?

    Unblocks: confirmation that a clean-room MIT droplet is the only route, and that no Pano code or assets can be considered.

15. May a clean-room MIT droplet say "Inspired by Pano Scrobbler" in its README and manifest description? Does that require kawaiiDango's permission, and where may the name appear?

    Unblocks: the droplet name, Store summary, description and README wording.

16. Does the Credits section need Pano's name, its GPL-3.0 licence and a "no code copied" statement even though the implementation is clean-room?

    Unblocks: the exact Credits and PROVENANCE contents.

17. Can we get a pre-review of the background design before building it, and through which channel: a draft MR, the Trench, Discord or email?

    Unblocks: whether to ask now or discover the answer in review.

## Sources

- [Good citizen](https://getdroppy.app/docs/droppykit/good-citizen), DroppyKit docs, last updated 2026-09-09.
- [Submitting](https://getdroppy.app/docs/droppykit/submitting), DroppyKit docs, last updated 2026-09-09.
- [Droplet setup and lifecycle](https://getdroppy.app/docs/droppykit/droplet-setup), DroppyKit docs.
- [Droplet developer terms](https://getdroppy.app/droplet-developer-terms), version 2026-09-17.
- [Droplet Store repository](https://gitlab.com/droppyformac1/droplets), commit `154eb35`.
- [Store CONTRIBUTING](https://gitlab.com/droppyformac1/droplets/-/blob/main/CONTRIBUTING.md).
- [Store LICENSE](https://gitlab.com/droppyformac1/droplets/-/blob/main/LICENSE).
- [DockDoor manifest](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/droplet.json), [provenance](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/PROVENANCE.md), [licence](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/LICENSE), [engine](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/Sources/DockDoor/DockDoorEngine.swift), [media service](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/Sources/DockDoor/Utilities/Media/MediaRemoteService.swift).
- [DockDoor port MR !176](https://gitlab.com/droppyformac1/droplets/-/merge_requests/176), [media helper MR !194](https://gitlab.com/droppyformac1/droplets/-/merge_requests/194).
- [Sales manifest](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/droplet.json), [droplet](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/Sources/Sales/SalesDroplet.swift), [settings](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/Sources/Sales/SalesSettings.swift), [Keychain](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/Sources/Sales/SalesKeychain.swift).
- [DropClip manifest](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/droplet.json), [README](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/README.md), [runtime](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/Droppy/DropClipDroplet.swift), [selection monitor](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/Platform/MacSelectionMonitor.swift), [secret store](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/Platform/SecretStore.swift).
- [Pano Scrobbler licence](https://github.com/kawaiiDango/pano-scrobbler/blob/main/LICENSE), GPL-3.0-or-later.
- [Last.fm scrobbling 2.0](https://www.last.fm/api/scrobbling).
- [Droplet catalogue API](https://getdroppy.app/api/v1/droplets), 43 entries on 2026-10-24.
- [The Trench](https://getdroppy.app/trench), public board search on 2026-10-24.
