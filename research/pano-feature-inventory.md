# Pano Scrobbler — cross-platform feature inventory

Research for [#2](https://github.com/ranokay/pano-scrobbler-droppy/issues/2), feeding the
macOS Droppy droplet epic ([#1](https://github.com/ranokay/pano-scrobbler-droppy/issues/1)).

Purpose: enumerate every **user-facing** feature of Pano Scrobbler across Android (phone, tablet,
TV), Windows and Linux, then classify each as a **CAPABILITY** the macOS droplet must reproduce or
a **TRANSPORT** that Droppy replaces (media helper, shelf widget, live activity, menu bar tile, HUD,
URL handling). Behaviour and names only — no GPL code, strings or assets are reproduced here.

Snapshot: Pano Scrobbler **4.47** (versionCode 447, released 2026-10-06), upstream commit
[`9901540`](https://github.com/kawaiiDango/pano-scrobbler/tree/990154031e761b8e5460a0585fc834b43c9e2d71).
Upstream is GPL-3.0-or-later; this document is a clean-room behavioural description.

## How to read this

- **Platforms**: `A` Android phone/tablet · `TV` Android TV · `W` Windows · `L` Linux ·
  `D` desktop (Windows + Linux) · `All` = Android + TV + Windows + Linux.
- **Type**: `CAPABILITY` = product logic/data/UI the droplet must own. `TRANSPORT` = OS or
  shell integration that Droppy's own surfaces replace.
- Source tokens are defined in [Sources](#sources). Every row carries at least one.

The matrix catalogues **150 features**: 106 capability-led and 44 transport-led. Per-section counts are
in the section tables; the platform-only roll-up and the transport replacement map follow them.

## Platform coverage at a glance

| Platform | Status in 4.47 | Evidence |
|---|---|---|
| Android (phone/tablet) | Full | `[R]`, `[AM]` |
| Android TV / Chromebook | Reduced: no editing/deleting of scrobbles, no file target, no widget, no QS tile, QR-code login | `[R]`, `[C403]`, `[P]`, `[AM]` |
| Windows | Full desktop set | `[R]`, `[C444]`, `[CI]` |
| Linux | Full desktop set, MPRIS/AppImage specific extras | `[R]`, `[C440]`, `[CI]` |
| **macOS** | **Not supported at all** — only `androidTarget` and `jvm()` are built; CI releases Windows/Linux/Android only | `[CI]` |

The absence of a macOS target is why this inventory exists: every `CAPABILITY` below is a parity
requirement, and every `TRANSPORT` below is a surface Droppy already provides.

---

## 1. Services and accounts

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| SVC-01 | Last.fm account | Username/password session against the Last.fm API; scrobble, now-playing, love, history, charts, friends, tags, wiki, scrobble edit/delete | All | CAPABILITY — direct API client | `[R]` `[SVC]` `[LF]` |
| SVC-02 | Libre.fm / GNU FM servers | Login with username/password; custom server URL supported | All | CAPABILITY — same client with configurable API root | `[SVC]` `[GF]` |
| SVC-03 | ListenBrainz | Token login; submit listens/now-playing, feedback love/hate, stats ranges | All | CAPABILITY — token auth | `[SVC]` `[LB]` |
| SVC-04 | Custom ListenBrainz-compatible servers | Up to three extra server slots: API URL + token, optional "trust all TLS" for local IPs, warns when a server lacks endpoints | All | CAPABILITY — up to 3 slots | `[RT]` `[C441]` `[MP]` |
| SVC-05 | Pleroma | OAuth app flow against an instance; posts listens to the instance's scrobble endpoint and reads back recent scrobbles | All | CAPABILITY — instance-scoped OAuth | `[SVC]` `[PL]` |
| SVC-06 | Local file target | A pseudo-account that appends listens to a local file instead of the network | A + D (not TV) | CAPABILITY — see FILE-01 | `[R]` `[FS]` |
| SVC-07 | Fan-out to all configured services | One listen is submitted to every configured, enabled service | All | CAPABILITY — queue + per-target results | `[SVC]` `[MP]` |
| SVC-08 | Per-service scrobbling switch | Disable submission to one service without logging out | All | CAPABILITY | `[C446]` `[MP]` |
| SVC-09 | Account switcher / drawer | Picks the "current" account; history, charts, friends and profile are scoped to it | All | CAPABILITY | `[MP]` `[PH]` |
| SVC-10 | Logout and re-authenticate | Clears the session; Last.fm edit/delete needs a fresh auth | All | CAPABILITY | `[F]` `[ST]` |
| SVC-11 | QR-code login for TV | Shows a QR code that opens the service login on another device | TV | TRANSPORT — Droppy URL handling / phone handoff | `[C403]` |
| SVC-12 | Embedded and external browser login | In-app WebView for OAuth/password, or system browser; dependency hints when the WebView engine is missing | All | TRANSPORT — `ASWebAuthenticationSession` / default browser | `[F]` `[RT]` |
| SVC-13 | Delete-account guidance | Explains how to delete an account per service, with links for custom servers | All | CAPABILITY (content) | `[RT]` `[ST]` |

## 2. Capture and submission pipeline

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| CAP-01 | Master scrobble switch | Turn scrobbling on/off app-wide | All | CAPABILITY | `[P]` |
| CAP-02 | Pause scrobbling | Pause for 30 min / 1 / 2 / 4 h or until a chosen time | All | CAPABILITY | `[C444]` `[P]` |
| CAP-03 | Per-app allowlist | Chooses which media apps may scrobble; list shows app icons and names | All | CAPABILITY (policy) fed by TRANSPORT (source identity) | `[P]` `[SF]` |
| CAP-04 | Auto-detect new apps | On first playback, asks whether to keep scrobbling that app | A | CAPABILITY | `[P]` `[ST]` |
| CAP-05 | First-artist-only extraction | For selected apps, scrobbles only the first artist of a multi-artist string | All | CAPABILITY | `[P]` `[C404]` |
| CAP-06 | Artist splitting exceptions | Names that must never be split by the first-artist extractor | All | CAPABILITY | `[C429]` `[ST]` |
| CAP-07 | Music-recognition sources | Accepts listens from Pixel Now Playing, Shazam, Ambient Music Mod and Audile | A (not TV) | TRANSPORT — media helper equivalent, no macOS analogue | `[R]` `[F]` `[ST]` |
| CAP-08 | Duplicate ambient suppression | Skips recognition-app listens while the device is already playing music | A | CAPABILITY (dedupe rule) | `[P]` |
| CAP-09 | Spotify remote playback | Scrobbles Spotify playing on other devices | W (v4.44+), Android historically | TRANSPORT — requires Spotify Web API, not OS media | `[C444]` `[P]` `[F]` |
| CAP-10 | Per-website allowlist | Websites reported through MPRIS get their own on/off toggles; accumulates across players | L | TRANSPORT (identity) + CAPABILITY (policy) | `[C442]` `[MP]` |
| CAP-11 | Now-playing submission toggle | Enable/disable "now playing" separately from completed scrobbles | All | CAPABILITY | `[P]` |
| CAP-12 | Scrobble delay | Submits after whichever comes first: N minutes or N% of track length; warns when the delay invites rate limits | All | CAPABILITY | `[P]` `[ST]` |
| CAP-13 | Minimum track duration | Ignores tracks shorter than a configurable threshold | All | CAPABILITY | `[P]` |
| CAP-14 | Title parsing | Derives artist/title from "Artist - Track"-style strings, with a fallback rule; per-app for the two title presets | All | CAPABILITY | `[RX]` `[C440]` |
| CAP-15 | Metadata enrichment | Fills missing album/artist/art from Last.fm cache, Spotify (incl. artist images, country), Deezer (Windows), iTunes (Apple Music), Tidal SteelSeries (Windows) | All (source availability varies) | CAPABILITY — each source is an HTTP integration | `[P]` `[SF]` `[C404]` |
| CAP-16 | Offline queue | Saves scrobbles and loves while offline, submits later | All | CAPABILITY | `[P]` `[ST]` |
| CAP-17 | Pending scrobbles view | Lists queued items with last attempt time and last error; retry and delete | All | CAPABILITY | `[R]` `[C400]` `[ST]` |
| CAP-18 | Heart button mirrors media-app rating | Liking from the notification also favorites inside the source player (Apple Music, Tidal, Spotify, etc.) | A | TRANSPORT — media helper can write the rating where the app exposes it | `[P]` `[C403]` |
| CAP-19 | Scrobble-source icons | Shows which app each scrobble came from; data stays local | All | CAPABILITY | `[P]` `[ST]` |
| CAP-20 | Search & play in source app | Re-opens the source app and searches for the track | A | TRANSPORT — URL handling / media helper | `[P]` `[ST]` |
| CAP-21 | Forget unchecked apps | Desktop-only cleanup of apps no longer in the allowlist | D | CAPABILITY (UI affordance) | `[C418]` `[ST]` |
| CAP-22 | Delivery rate safety | Rate-limit warning text and batched pending submission | All | CAPABILITY | `[ST]` `[C400]` |

## 3. Now playing and history

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| NP-01 | Now-playing card | Album art, title/artist/album, elapsed/duration, loved state; remembers expanded/collapsed state; auto-expands when at top | All | CAPABILITY | `[C445]` `[MP]` `[P]` |
| NP-02 | Inline track actions | Love/unlove, hate/unhate (ListenBrainz), edit (including the in-flight track), block; finished rows can also be deleted | All | CAPABILITY | `[R]` `[ST]` |
| NP-03 | Recent scrobbles feed | Paged list of recent listens, pull-to-refresh, periodic auto-refresh, pending-scrobble banner | All | CAPABILITY | `[R]` `[P]` |
| NP-04 | Time jump | Jump the history to a specific date/time ("what was I listening to last month/last year") | All | CAPABILITY | `[R]` `[ST]` |
| NP-05 | Loved tab | List of loved tracks | All (service-dependent) | CAPABILITY | `[TAB]` |
| NP-06 | Random tab | Random track/album/artist from listening history | All | CAPABILITY | `[R]` `[TAB]` |
| NP-07 | Track history page | All scrobbles of one track, total count, first-scrobbled date | All | CAPABILITY | `[RT]` `[ST]` |
| NP-08 | Edit existing scrobble | Opens a field editor; the edit can be remembered as an edit rule; Last.fm rejects edits older than 14 days | All (Last.fm only for write-back) | CAPABILITY + service limitation | `[R]` `[F]` `[ST]` |
| NP-09 | Delete existing scrobble | Deletes a scrobble (Last.fm); delayed from local view | All (Last.fm only) | CAPABILITY | `[ST]` `[LF]` |
| NP-10 | Per-scrobble menu | Love/unlove, hate/unhate (ListenBrainz), block, copy metadata, share as text, search & play, open details | All | CAPABILITY | `[ST]` `[LB]` |
| NP-11 | Share scrobble | Share sheet with "artist — track, time"; optional app signature removed for supporters | All | TRANSPORT (share sheet) + CAPABILITY (text) | `[ST]` `[BILL]` |
| NP-12 | Detail pages | Artist, album, track and tag detail pages reachable from any list, including album-artist metadata | All | CAPABILITY | `[R]` |

## 4. Charts and statistics

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| CH-01 | Charts tabs | Top artists / albums / tracks for the selected account and period | All | CAPABILITY | `[TAB]` `[R]` |
| CH-02 | Period selector | Day, week, month, year, all-time, custom range, rolling "continuous" ranges, ListenBrainz ranges | All | CAPABILITY | `[TP]` `[ST]` |
| CH-03 | Rank-change indicators | Up/down/new/no-change arrows against the previous equivalent period, plus a legend | All | CAPABILITY | `[R]` `[ST]` |
| CH-04 | Listening activity graph | Bar chart of scrobble counts per day/week/month/year for the range | All | CAPABILITY | `[R]` `[ST]` |
| CH-05 | Tag cloud | Weighted tag cloud for the range; Last.fm accounts only | All (Last.fm) | CAPABILITY | `[R]` `[ST]` |
| CH-06 | Hidden tags | Persistent list of tags excluded from charts and tag cloud | All | CAPABILITY | `[ST]` `[MP]` |
| CH-07 | Range totals | Scrobbles in range, loves count where the service exposes it | All | CAPABILITY | `[C427]` |
| CH-08 | Refresh charts | Manual refresh plus cache-backed loading | All | CAPABILITY | `[C409]` |
| CH-09 | Grid/list layout | Switch chart entries between grid and list | All | CAPABILITY | `[MP]` `[ST]` |
| CH-10 | Share chart as text | "Copy as text" version of chart/collage data | All | CAPABILITY | `[C415]` `[ST]` |
| CH-11 | Charts legend dialog | Explains rank-change symbols | All | CAPABILITY | `[ST]` |

## 5. Collage generator and random picks

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| COL-01 | Collage sizes | Grids from 3×3 up to 6×6 from top albums/artists/tracks | A + D (not TV) | CAPABILITY | `[R]` `[CO]` |
| COL-02 | Collage options | Borders (rounded), captions (names/counts), username, profile picture, skip missing images | A + D | CAPABILITY | `[CO]` `[C403]` `[C320]` |
| COL-03 | Collage output | Save to photo gallery (Android), save file (desktop), share sheet, copy as text | A + D | TRANSPORT (gallery/share) + CAPABILITY (render) | `[CO]` `[ST]` |
| COL-04 | Random picker | Roll a random track, album or artist from history, with the same period selector | All | CAPABILITY | `[R]` `[RT]` |

## 6. Search and discovery

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| SRCH-01 | Global catalogue search | Search Last.fm for artists/albums/tracks and loved tracks, even when scrobbling elsewhere | All | CAPABILITY | `[R]` `[RT]` |
| SRCH-02 | Settings search | Filter the settings list by keyword | All | CAPABILITY | `[C437]` |
| SRCH-03 | Friends search | Filter the following list | All | CAPABILITY | `[ST]` `[RT]` |
| SRCH-04 | Grouped result sections | Results are split into artists / albums / tracks / loved, each collapsible | All | CAPABILITY | `[RT]` |
| SRCH-05 | Search & play | Opens the track in a chosen media app (Android) or a user-defined URL template with a query placeholder (desktop/Android) | All | TRANSPORT — Droppy URL handling | `[P]` `[C419]` `[ST]` |
| SRCH-06 | Artist/album image picker | Search images (Spotify) or pick from gallery; per-artist and per-album override | All | CAPABILITY + TRANSPORT (file picker) | `[RT]` `[C339]` |
| SRCH-07 | Approximate artist-image search | Falls back to the first Spotify result when names differ | All | CAPABILITY | `[P]` `[F]` |
| SRCH-08 | Tag search | Look up a tag's wiki and tagger/tagging counts, with a link out to the service's tag page | All (Last.fm) | CAPABILITY | `[ST]` `[RT]` |

## 7. Friends and social

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| FR-01 | Following list | Avatars, last-seen scrobble, country, join date; opening a friend shows their totals and today's count | All | CAPABILITY | `[R]` `[ST]` `[PH]` |
| FR-02 | Friend profile view | Opens a friend's scrobbles, loved, charts and stats as a read-only home pager | All | CAPABILITY | `[RT]` |
| FR-03 | Pin friends | Pin up to 10 favourites and drag-reorder them; the pinned section is a supporter feature | All | CAPABILITY | `[ST]` `[BILL]` |
| FR-04 | Sort friends | One-tap sort of the following list by most recent activity | All | CAPABILITY | `[ST]` `[RT]` |
| FR-05 | External profile/report links | Open profile or listening report on Last.fm/Libre.fm/ListenBrainz | All | TRANSPORT — URL handling | `[PH]` |

## 8. Tags

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| TAG-01 | Entity tags | Top tags shown on artist/album/track detail pages with tagger/tagging counts | All (Last.fm) | CAPABILITY | `[R]` `[ST]` |
| TAG-02 | Personal tags | Add/remove your own tags on an entity | All (Last.fm) | CAPABILITY | `[R]` `[ST]` |
| TAG-03 | Tag suggestions | Remembers tags you typed and offers them when adding personal tags | All | CAPABILITY | `[MP]` `[ST]` |
| TAG-04 | Tag details | Tag wiki, tagger/tagging counts, and a link out to the service's tag page | All (Last.fm) | CAPABILITY | `[RT]` `[ST]` |
| TAG-05 | Wiki language | Chooses which language's wiki to show for artists/albums/tracks/tags | All (Last.fm) | CAPABILITY | `[C445]` `[P]` |

## 9. Edits and blocks (metadata corrections)

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| ED-01 | Simple edits | Field-level replacement of track/artist/album/album artist; only enabled fields change; per-app scope | All | CAPABILITY | `[ST]` `[C410]` |
| ED-02 | Partial-edit expansion | Edit dialog can expand to a full screen for long forms | All | CAPABILITY | `[C414]` |
| ED-03 | Regex edits | Search/replace or named-capture extraction across the four metadata fields; first/all occurrences; case sensitivity | All | CAPABILITY | `[ST]` `[RX]` |
| ED-04 | Regex presets | Built-in rules: parse title, parse title with fallback, remastered, explicit, single/EP, album version | All | CAPABILITY | `[RX]` `[C409]` |
| ED-05 | Regex test screen | Dry-run rules against sample metadata, highlights required fields and matched patterns | All | CAPABILITY | `[ST]` `[C403]` |
| ED-06 | Rule chaining | "If found, continue with other rules" for both simple and regex rules | All | CAPABILITY | `[C429]` `[ST]` |
| ED-07 | Per-app rule scope | Rules apply only to selected apps (Android) or websites (Linux) | All | CAPABILITY | `[P]` `[RX]` |
| ED-08 | Rule ordering/toggling | Drag to reorder, enable/disable individually; every enabled rule is tried per scrobble | All | CAPABILITY | `[ST]` `[C409]` |
| ED-09 | Rule limits | 50 active regex rules; 300 with supporter license; UI explains the limit | All | CAPABILITY | `[C412]` `[C429]` |
| ED-10 | Blocked metadata | Block by any combination of track/album/artist/album artist, with wildcard-style "anything" | All | CAPABILITY | `[R]` `[BL]` |
| ED-11 | Block actions | On match: skip track, mute audio, or just don't scrobble; real-time block from a scrobble row | All | CAPABILITY (decision) + TRANSPORT (skip/mute via media helper) | `[ST]` `[BL]` `[C415]` |
| ED-12 | Block entry points | Block from now-playing card, history row, notification, tray menu | All | CAPABILITY | `[ST]` `[TR]` |

## 10. File scrobbling and manual control

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| FILE-01 | CSV/JSONL target | Appends one row/object per listen: time, artist, track, album, album artist, duration, media player, event | A + D (not TV) | CAPABILITY | `[R]` `[FS]` |
| FILE-02 | File creation/append | Create a new file or append to an existing one; write-permission check | A + D | CAPABILITY + TRANSPORT (file picker) | `[FS]` `[ST]` |
| FILE-03 | Format conversion | Converts an existing CSV to JSONL or vice versa | A + D | CAPABILITY | `[C426]` `[FS]` |
| FILE-04 | History from file | The file target reads its own file back as the history feed (charts/loves/friends are empty) | A + D | CAPABILITY | `[FS]` |
| FILE-05 | Manual scrobble entry | **No free-form "scrobble this track" form exists.** Manual control is limited to editing/cancelling the current track and the file target | — | Not a Pano feature — do not build for parity | `[RT]` |

## 11. Import, export and backup

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| IE-01 | Export to file | JSON backup of settings, simple edits, regex rules, blocked metadata, artist-split exceptions; logins deliberately excluded | All | CAPABILITY | `[IE]` `[ST]` |
| IE-02 | Granular import | Choose: skip lists, replace all, merge-replace, merge-keep; import settings separately | All | CAPABILITY | `[IE]` `[ST]` |
| IE-03 | Network transfer | Export/import between devices on the same LAN (mDNS discovery, IP/code entry); works desktop↔Android | All | TRANSPORT (discovery/transport) + CAPABILITY (payload) | `[C403]` `[C437]` `[MP]` |
| IE-04 | Import validation | Detects foreign/corrupt files, filters app/package names that don't exist on the target | All | CAPABILITY | `[IE]` `[ST]` |
| IE-05 | OS backup | Android auto-backup rules include app data | A | TRANSPORT — Droppy/iCloud backup | `[AM]` |

## 12. Notifications and digests

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| NOTI-01 | Interactive now-playing notification | Song info plus love, edit, cancel, block actions; desktop uses the tray menu instead | A | TRANSPORT — Droppy HUD/shelf; content and actions are CAPABILITY | `[R]` `[AM]` `[TR]` |
| NOTI-02 | Persistent/foreground notification | Keeps the scrobbler alive on OEMs that kill background apps; tap to hide | A (not TV) | TRANSPORT — no macOS equivalent needed | `[P]` `[SF]` |
| NOTI-03 | New-app notification | Announces a newly detected media app and asks to allow it (desktop variant links to settings) | A + D | TRANSPORT (delivery) + CAPABILITY (prompt) | `[ST]` `[P]` |
| NOTI-04 | Scrobble error notification | Surfaces submit failures and actionable fixes | A | TRANSPORT (delivery) + CAPABILITY (error model) | `[ST]` `[AM]` |
| NOTI-05 | Weekly/monthly/yearly digest | Top artists/albums/tracks pushed at period end; yearly fires at the year boundary; rescheduled when the clock/timezone changes | A (desktop digest path exists but its channel check is a stub, so it never fires) | CAPABILITY (query) + TRANSPORT (delivery) | `[R]` `[DG]` `[C428]` |
| NOTI-06 | Update notification | Notifies when a new desktop release is downloaded | D | TRANSPORT | `[P]` `[ST]` |
| NOTI-07 | Silent channels | Separate channels: scrobbling, new app, weekly digest, monthly digest, foreground service, updater; no sound | A | TRANSPORT — Droppy notification settings | `[ST]` `[AM]` |
| NOTI-08 | Notification-access onboarding | Explains why notification access is required and how to grant it; restricted-settings help for sideloaded Android 13+ | A + TV | TRANSPORT — macOS media helper needs no such grant | `[F]` `[ST]` |
| NOTI-09 | "Scrobbler was killed" recovery | Detects a system kill, shows the reason, offers OEM-specific fixes | A | TRANSPORT — meaningless on macOS | `[ST]` `[P]` |

## 13. Discord Rich Presence (desktop only)

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| RPC-01 | Rich Presence toggle | Publishes the current track to Discord; tray shows a hint when Discord integration is off/failed | D | CAPABILITY — Discord IPC client | `[R]` `[C426]` |
| RPC-02 | Three custom lines | Line 1/2/3 templates with placeholders for title, artist, album, album artist, media player | D | CAPABILITY | `[DR]` |
| RPC-03 | Compact "Listening to" line | Chooses which line appears in Discord's compact view, or uses the app name | D | CAPABILITY | `[DR]` `[ST]` |
| RPC-04 | Custom app name | Replaces the displayed application name with custom text | D | CAPABILITY | `[C426]` `[ST]` |
| RPC-05 | Album art | Cover art from metadata, optional fallback to Now Playing art, cache-first for speed | D | CAPABILITY | `[DR]` `[C441]` `[C444]` |
| RPC-06 | Show paused media for N | Keeps presence visible for a configurable pause window | D | CAPABILITY | `[DR]` |
| RPC-07 | Track URL | Adds the track URL as the details link | D | CAPABILITY | `[DR]` `[ST]` |
| RPC-08 | Loved state | Optionally shows a loved marker in presence | D | CAPABILITY | `[C439]` `[MP]` |
| RPC-09 | Presence button | Button points at the Pano repo, the Last.fm/ListenBrainz/Libre.fm profile, or a custom URL; can be hidden | D | CAPABILITY (custom URL may become a Droppy link) | `[DR]` `[MP]` |
| RPC-10 | Character limits and retry | Enforces Discord's field length limits, retries after failure, clears presence on stop | D | CAPABILITY | `[C441]` `[DR]` |

## 14. Automation, shortcuts and OS surfaces

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| AUTO-01 | Android automation provider | Content-provider commands: scrobbler on/off, love/unlove, cancel, allowlist/blocklist a package; calling apps must be explicitly allowlisted | A | TRANSPORT — Droppy shortcuts/URL handling; command semantics are CAPABILITY | `[AU]` `[F]` |
| AUTO-02 | Desktop CLI automation | Same commands plus focus-existing and quit, sent to the running instance over IPC | D | TRANSPORT — Droppy menu bar tile/URL scheme | `[AU]` `[TR]` `[ST]` |
| AUTO-03 | App shortcuts | Launcher long-press shortcuts for Settings and Search, implemented as deep links | A | TRANSPORT — Droppy URL handling | `[AM]` |
| AUTO-04 | Deep links | `pano-scrobbler://screen?route=<json>` opens any route, including settings and search | A | TRANSPORT — Droppy URL handling | `[AM]` `[RT]` |
| AUTO-05 | Quick Settings tile | Toggle scrobbling from the Android shade | A (not TV, API 33+) | TRANSPORT — menu bar tile | `[AM]` `[SF]` |
| AUTO-06 | Charts home-screen widget | Configurable per instance: account, period, album art, light/dark, opacity, shadow; refresh ≥45 min; reconfigurable | A (not TV) | TRANSPORT — Droppy shelf widget | `[AM]` `[WID]` `[C441]` |
| AUTO-07 | Desktop tray icon and menu | Three icon states (idle/scrobbling/error); per-player menu with love, edit, cancel, block, copy; settings, update, quit | D | TRANSPORT — menu bar tile | `[TR]` |
| AUTO-08 | Desktop launch options | Start minimized (`-m`), custom data directory (`-d`), single-instance enforcement, Windows console attach | D | TRANSPORT — app shell | `[F]` `[TR]` |
| AUTO-09 | Linux autostart / launcher | Toggle "run at startup" and add the AppImage to the application launcher | L | TRANSPORT — login items | `[SF]` `[C440]` |
| AUTO-10 | Android TV navigation | Leanback launcher entry, DPAD focus handling, no typing-heavy features, no file target | TV | TRANSPORT — N/A on macOS | `[AM]` `[P]` `[C403]` |
| AUTO-11 | OS media integration | Android notification listener + MediaSession, Windows System Media Transport Controls, Linux MPRIS (+ page URL) | All | TRANSPORT — Droppy media helper | `[F]` `[CI]` |
| AUTO-12 | Desktop system notifications | Native toast notifications for new app / downloaded update; Windows requires an installed Start-menu shortcut | W + L | TRANSPORT — Droppy HUD/Notification Center | `[F]` `[P]` |

## 15. Appearance, settings and app plumbing

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| UI-01 | Themes | Seed hue, palette style (tonal spot / expressive / vibrant / CMF), contrast low/medium/high; background opacity and window blur on desktop | All (blur: D) | CAPABILITY (theme tokens; blur/transparency are transport-limited) | `[TH]` `[ST]` |
| UI-02 | Dynamic system colors | Follows Material You system palette when enabled | A | TRANSPORT — macOS accent color equivalent | `[ST]` `[P]` |
| UI-03 | Light/dark/system + random | Day/night mode, plus random theme per process start | All | CAPABILITY | `[TH]` `[C428]` |
| UI-04 | UI language | Per-app language override plus system default; 30+ translations | All | CAPABILITY | `[P]` |
| UI-05 | First day of week | Auto or explicit, affects charts periods and calendars | All | CAPABILITY | `[P]` `[C427]` |
| UI-06 | Grid/list toggle | Applies to charts and entity lists | All | CAPABILITY | `[MP]` |
| UI-07 | Proxy | System / HTTP / SOCKS5, optional credentials | All | CAPABILITY | `[P]` `[C442]` `[C437]` |
| UI-08 | In-app help, FAQ, privacy | Rendered inside the app with search, not a web page | All | CAPABILITY (content) | `[C428]` `[RT]` |
| UI-09 | OSS credits and translators | License/credits screens | All | CAPABILITY | `[RT]` |
| UI-10 | Changelog | Shows release notes after an update | All | CAPABILITY | `[RT]` `[ST]` |
| UI-11 | Logs and diagnostics | Save logs to file; persistent logging on Android (off by default); crash reporting opt-in (Play build) | All | CAPABILITY + TRANSPORT (file export) | `[P]` `[C428]` |
| UI-12 | Supporter purchase | One-time purchase (Play billing) or activation code (Ko-fi/BuyMeACoffee); unlocks block lists, extra regex rules, friend pins, scrobble-source icons, signature-free sharing | All | CAPABILITY (decision) — must be ungated or rethought for an MIT droplet | `[BILL]` `[ST]` |
| UI-13 | Delete account screen | Step-by-step account deletion per service | All | CAPABILITY (content) | `[RT]` |

## 16. Distribution and updates

| ID | Feature | What it does | Platforms | Type → macOS/Droppy | Src |
|---|---|---|---|---|---|
| UPD-01 | Desktop auto-update | Checks GitHub releases, downloads and applies updates; can be disabled | D | TRANSPORT — Droppy/Sparkle | `[P]` `[C402]` |
| UPD-02 | Manual update check + changelog | Check now, view changelog | D | TRANSPORT | `[P]` |
| UPD-03 | Android distribution | Play Store, F-Droid-compatible repo, IzzyOnDroid, Obtainium, GitHub APK; non-Play builds are FOSS-only | A | TRANSPORT — outside droplet scope | `[R]` |
| UPD-04 | Desktop packaging | Windows installer + portable extract, winget; AUR, APT, COPR, Nix flake, AppImage, tar.zst | W + L | TRANSPORT — outside droplet scope | `[R]` `[C441]` `[C440]` |

---

## Platform-only features (explicit)

### Android only (phones/tablets; some not on TV)

- Notification-listener capture of other apps' media notifications, including apps with no media
  session (`[F]`, `[AM]`).
- Music-recognition sources: Pixel Now Playing, Shazam, Ambient Music Mod, Audile (`[R]`, `[ST]`).
- Charts home-screen widget, Quick Settings tile, launcher shortcuts, persistent foreground
  notification, digest notifications, notification-access onboarding (`[R]`, `[AM]`, `[SF]`).
- Content-provider automation for Tasker-style apps, replacing the old broadcast intents (`[F]`, `[AU]`).
- Heart button writing the rating back into the source player (`[P]`, `[C320]`).
- Scrobble-source icons and "search & play in source app" (`[P]`).
- TV-specific: QR-code login, no scrobble editing/deletion, no file target (`[C403]`).

### Windows only

- Spotify remote-playback toggle (v4.44+) (`[C444]`, `[P]`).
- Native tray menu (no Compose render for the menu) and Windows toast notifications tied to the
  installer's Start-menu shortcut (`[C444]`, `[F]`).
- Tidal SteelSeries metadata receiver, Deezer metadata (`[SF]`, `[C442]`).
- Portable ("extract only") installation mode (`[R]`, `[F]`).

### Linux only

- MPRIS capture, including per-website allowlists sourced from the player's reported page URL
  (`[F]`, `[C440]`, `[C442]`).
- Autostart toggle and AppImage launcher integration (`[SF]`, `[C440]`).
- Fractional scaling, X11 startup ordering, `xdg-open` fallback (`[C444]`, `[C429]`, `[C403]`).

### Desktop only (Windows + Linux)

- Discord Rich Presence in all its configuration (`[R]`, `[DR]`).
- Tray menu, CLI automation, `--minimized`, `--data-dir`, single-instance IPC (`[TR]`, `[F]`).
- Desktop auto-update from GitHub releases (`[P]`, `[C402]`).

### Android TV only / TV-specific reductions

- QR login; DPAD-first navigation; editing/deleting scrobbles removed; file target removed;
  widgets/QS tile absent (`[C403]`, `[P]`, `[AM]`).

### macOS

- Nothing. No build target, no release artifact, no platform-specific code path (`[CI]`).

---

## Transport replacement map

| Pano transport | What it actually is | Droppy replacement |
|---|---|---|
| Playback detection on Android (`AUTO-11`) | NotificationListenerService + MediaSession metadata | Droppy media helper |
| Playback detection on Windows (`AUTO-11`) | SystemMediaTransportControls via native library | Droppy media helper |
| Playback detection on Linux (`AUTO-11`) | MPRIS over D-Bus, incl. page URL | Droppy media helper |
| Now-playing notification (`NOTI-01`) | Interactive OS notification with actions | Shelf widget + HUD |
| Home-screen widget (`AUTO-06`) | RemoteViews charts widget | Shelf widget |
| Quick Settings tile (`AUTO-05`) | Android tile | Menu bar tile |
| Tray icon/menu (`AUTO-07`) | Desktop tray | Menu bar tile |
| App shortcuts / deep links (`AUTO-03`, `AUTO-04`) | Launcher shortcuts + `pano-scrobbler://` routes | Droppy URL handling |
| Automation (`AUTO-01`, `AUTO-02`) | Content provider / CLI IPC | URL handling + shortcuts |
| Share sheet (`NP-11`, `COL-03`) | Android/desktop share | macOS share sheet |
| Gallery/file pickers (`SRCH-06`, `FILE-02`) | SAF / native dialogs | Droppy file pickers |
| Login WebView (`SVC-12`) | Embedded browser | `ASWebAuthenticationSession` / default browser |
| Tray/scrobble notifications (`AUTO-12`) | Windows toasts, Linux notifications | HUD + Notification Center |
| "Live" now-playing surface | Notification + widget | Live activity |

Rows whose type starts with `TRANSPORT` are surfaces Droppy replaces; rows whose type starts with
`CAPABILITY` must exist inside the droplet. Composite rows are split in their notes.

---

## Parity notes and risks

1. **Service write-back asymmetry.** Last.fm supports edit/delete of past scrobbles (14-day limit,
   `[F]`); ListenBrainz supports love/hate feedback (`[LB]`); Pleroma is append-only with no loves
   (`[PL]`); the file target is append-only and cannot compute charts (`[FS]`). Parity must be
   capability-per-service, not a single lowest common denominator.
2. **Editing older scrobbles is impossible even with Last.fm Pro** — the app says so explicitly
   (`[F]`). Do not promise it.
3. **Metadata enrichment is third-party.** Artist images come from Spotify because Last.fm doesn't
   provide them; album art may come from Deezer/iTunes/now-playing (`[F]`, `[P]`). Each is a
   separate credential/ToS decision for the droplet.
4. **Rate limits are user-visible.** The app warns that submitting too fast/too many per day causes
   rejects and backlog growth (`[ST]`). The macOS client needs the same backoff and pending queue.
5. **Supporter gating exists in 4.47** (`[BILL]`, `[ST]`). An MIT droplet has no equivalent; the
   gated behaviours (block lists, extra regex rules, pins, source icons) should ship ungated or be
   deliberately re-scoped.
6. **Manual scrobbling does not exist** (`FILE-05`). "Manual and file scrobbling" in the issue maps
   to manual *control* (edit/cancel/block/love) plus the CSV/JSONL target.
7. **TV is a reduced target** (`[C403]`). Parity should be measured against phone/tablet + desktop,
   not TV.
8. **No macOS precedent.** There is no code path, packaging or OS integration to reuse; the
   droplet starts from Droppy's transports only.

---

## Sources

All upstream links pin commit
[`990154031e`](https://github.com/kawaiiDango/pano-scrobbler/tree/990154031e761b8e5460a0585fc834b43c9e2d71)
unless the source is a release note or the website.

| Token | Source |
|---|---|
| `R` | README, "Features" section — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/README.md#features |
| `W` | Project website — https://kawaiidango.github.io/pano-scrobbler/ |
| `F` | FAQ — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/faq.md |
| `C4xx` | Release notes, e.g. https://github.com/kawaiiDango/pano-scrobbler/releases/tag/444 |
| `ST` | UI strings (feature names/labels only) — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/composeResources/values/strings.xml |
| `P` | Settings screen — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/PrefsScreen.kt |
| `MP` | Preference model — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/MainPrefs.kt |
| `SVC` | Scrobbler abstraction — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/Scrobblable.kt |
| `LF` | Last.fm client — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/LastFm.kt |
| `GF` | GNU FM client — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/GnuFm.kt |
| `LB` | ListenBrainz client — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/listenbrainz/ListenBrainz.kt |
| `PL` | Pleroma client — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/pleroma/Pleroma.kt |
| `FS` | File target — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/file/FileScrobblable.kt |
| `IE` | Import/export — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/ImExporter.kt |
| `AM` | Android manifest — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/androidMain/AndroidManifest.xml |
| `AU` | Automation commands — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/automation/Automation.kt and https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/androidMain/kotlin/com/arn/scrobble/automation/AutomationProvider.kt |
| `WID` | Widget config — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/androidMain/kotlin/com/arn/scrobble/widget/ChartsWidgetConfigScreen.kt |
| `DR` | Discord RPC — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/jvmMain/kotlin/com/arn/scrobble/discordrpc/DiscordRpc.kt and .../DiscordRpcScreen.kt |
| `TR` | Tray + desktop entry — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/jvmMain/kotlin/com/arn/scrobble/utils/PanoTrayUtils.kt and .../main/main.kt |
| `SF` | Platform-specific settings — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/androidMain/kotlin/com/arn/scrobble/pref/PlatformSpecificPrefs.android.kt and .../jvmMain/.../PlatformSpecificPrefs.jvm.kt |
| `TH` | Themes — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/themes/ThemeUtils.kt |
| `RX` | Regex rules/presets — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/RegexEdit.kt and .../edits/RegexPresets.kt |
| `BL` | Blocked metadata — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/BlockedMetadata.kt |
| `DG` | Digests — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/work/DigestWorker.kt |
| `CO` | Collage — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/charts/CollageGeneratorDialog.kt |
| `TP` | Time periods — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/charts/TimePeriodsGenerator.kt |
| `TAB` | Tabs — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/navigation/PanoTab.kt |
| `RT` | Routes/screens — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/navigation/PanoRoute.kt |
| `PH` | Profile header — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/navigation/ProfileHeader.kt |
| `CI` | Build targets/CI — https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/build.gradle.kts and https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/.github/workflows/releases.yml |
| `BILL` | Billing/licensing — https://github.com/kawaiiDango/pano-scrobbler/tree/990154031e761b8e5460a0585fc834b43c9e2d71/extras-nonplay/src/main/kotlin/com/arn/scrobble/billing and .../extras-play/... |

Release notes consulted: `447`, `446`, `445`, `444`, `442`, `441`, `440`, `439`, `438`, `437`, `436`,
`435`, `433`, `429`, `428`, `427`, `426`, `420`, `419`, `418`, `414`, `410`, `409`, `404`, `403`,
`402`, `401`, `400`, `339`, `335`, `328`, `320`.
