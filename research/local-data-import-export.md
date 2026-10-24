# Pano local data, import and export

Behaviour specification for the Pano Scrobbler droplet. Read from Pano's Kotlin source at
[`a7c8318`][pano-repo] (12 May 2026), its docs, and its issue tracker. No Pano code, strings or
assets are reused here.

**Short answer.** Pano's SQLite database is a queue, a rule store, a source-hint log and a derived
cache. It is **not** a listening-history database. History is fetched from whichever service is
current. Settings and accounts live in a plaintext JSON DataStore; session keys are inside it. The
only user-facing backup format is a Pano JSON file containing settings, edits, the blocklist, artist
splitting exceptions and (in an unimplemented private mode) source hints. Pano can also *write*
scrobbles to a CSV/JSONL file, and can use that file as a service, but it cannot import a foreign
listening history into its database or export its database.

A parity droplet that promises "local SQLite as the source of truth" must therefore go beyond Pano:
store every accepted scrobble locally, keep per-service delivery state, import Pano JSON and
Last.fm-style CSV, and export a full backup. Pano's JSON remains the compatibility format for rules
and settings; it is not a history format.

---

## 1. Where Pano keeps data

| Store | Android | Desktop | Contents | Survives reinstall? |
| --- | --- | --- | --- | --- |
| Preferences | `files/main-prefs.json` | `<app data>/data/main-prefs.json` | Accounts incl. session keys, settings, UI state, some derived caches | Only via Android system backup |
| Main database | `databases/pendingScrobbles` | `<app data>/data/panodb.db` | Pending queue, rules, source hints, seen cache | Only via Android system backup |
| HTTP cache | `cache/ktor` | `<app data>/cache/ktor` | Cached service responses, capped at 40 MB | No |
| Logs | `files/logs` | `<app data>/logs` | Diagnostics | No |
| User exports | User-chosen | User-chosen | Pano JSON | User-managed |
| File scrobble sink | User-chosen | User-chosen | CSV or JSONL | User-managed |

Sources: Android and desktop database paths [PlatformStuff.android.kt:301-317][pano-platform-android],
[PlatformStuff.desktop.kt:150-158][pano-platform-desktop]; preference file name
[MainPrefs.kt:336][pano-mainprefs]; cache cap [HybridCacheStorage.kt:13-14][pano-cache].

The Android manifest enables system backup and includes the `database`, `file` and `sharedpref`
domains [AndroidManifest.xml:36-41][pano-manifest], [backup_rules.xml][pano-backup-rules],
[data_extraction_rules.xml][pano-data-extraction-rules]. Because the preference JSON contains account session
keys, those keys are *eligible* for Android cloud backup. The user-facing export deliberately does
not include them [strings.xml:291][pano-strings].

---

## 2. What each store contains

### 2.1 Settings and accounts (`main-prefs.json`)

Pano uses one DataStore JSON document, `MainPrefs`, for several different kinds of data
[MainPrefs.kt:41-130][pano-mainprefs]:

| Group | Examples | Exportable? | Refetchable? |
| --- | --- | --- | --- |
| Scrobbling behaviour | enabled, submit now playing, delay seconds/percent, minimum duration, fetch missing album, prevent duplicate ambient scrobbles | Yes (public subset) | No |
| App filters | allowed packages, blocked packages, auto-detect, per-preset package maps | Yes (public subset) | No; Android package IDs are device-specific |
| Accounts and session | `scrobbleAccounts`, `currentAccountType`, drawer data, pinned friends, Last.fm cookies, Spotify access token | **No** | Re-authenticate |
| Presentation | theme, contrast, day/night, first day of week, grid mode, window state, collage options | Partly (theme fields only) | No |
| Local UX history | search history, tag history, seen app labels | No | No |
| Integrations | Discord RPC, proxy, Spotify/Deezer/Tidal flags, search URL template | Partly (public subset) | No |
| Entitlement | receipt, signature, last licence check | **No** | Re-check |

Account entries are `{type, user, authKey, apiRoot}`. `user` carries name, URL, real name, country,
registration time, image URL and pinned order [UserCached.kt:38-43][pano-usercached]. `authKey` is
the service session key or token. Pano keeps one account per service type (`distinctBy { it.type }`)
[Scrobblable.kt:170-172][pano-account-type]; multiple accounts of the same service are not modelled.

The public export schema is a separate `Public` data class [MainPrefs.kt:156-205][pano-mainprefs].
It carries only the cross-device settings, with legacy aliases such as `master` for
`scrobblerEnabled`, `delay_secs`, `delay_per`, `now_playing`, `fetch_album`, `auto_detect`,
`show_scrobble_sources`, `search_in_source`, `app_whitelist`, and `link_heart_button_to_rating`.
Accounts, current account, cookies, pinned friends, drawer data, search/tag history, receipts and
window state are absent.

**Security note.** Session keys are stored in the same plaintext JSON as ordinary preferences. A
droplet must keep them in Keychain and keep them out of both the database and every export.

### 2.2 Pending queue (`PendingScrobbles`)

One row per failed action. The entity [PendingScrobble.kt:14-30][pano-pending-entity] embeds the
scrobble metadata and adds:

| Column | Meaning |
| --- | --- |
| `_id` | Local autoincrement id |
| `event` | `scrobble`, `love` or `unlove` |
| `services` | Bitmask of services still owed this action |
| `lastFailedTimestamp` | Last attempt, epoch ms |
| `lastFailedReason` | First exception message, truncated to 100 chars |
| `canForceRetry` | The failure was a retryable network error |
| scrobble fields | artist, track, album, timestamp (epoch ms), track number, album artist, duration (ms), app id |

The service bitmask is built from stable `AccountType.id` values: Last.fm 0, Libre.fm 1, GNU FM 2,
ListenBrainz 3, custom ListenBrainz 4, Pleroma 6, file 7; 5 is unused [Scrobblable.kt:155-164][pano-account-type].

Behaviour:

- Pano first attempts the network call, then inserts a pending row if any service failed
  [ScrobbleEverywhere.kt:341-357][pano-scrobble-everywhere]. A crash between a successful send and
  the local bookkeeping step has no local record to recover from. A droplet should enqueue first,
  then send.
- On success, the service's bit is removed. The row is deleted when no bits remain. A partial
  success rewrites the row with the remaining services. API errors 6 and 7 are treated like success
  and also clear the service bit [PendingScrobblesWorker.kt:80-130][pano-worker].
- When an account is removed, its bit is cleared from every row and empty rows are deleted
  [PendingScrobblesDao.kt:67-98][pano-pending-dao]. Re-adding the account does not resurrect old
  pending work.
- Retries are scheduled as unique background work with network constraints, exponential backoff
  starting at one hour, and a 30-second initial delay for non-forced runs
  [PendingScrobblesWork.android.kt][pano-pending-work]. Rows are eligible after 30 minutes, or
  immediately when `canForceRetry` is set [PendingScrobblesDao.kt:86-90][pano-pending-dao].
- One run drains at most 2,500 scrobbles by descending timestamp, in batches of 50, and stops after
  repeated failures per service. Loves are drained separately, 100 at a time, one per second
  [PendingScrobblesWorker.kt:56-62,135-166,225-228][pano-worker].
- There is no TTL, no cap on row count and no dedupe constraint. A row can stay forever. Repeated
  plays correctly produce separate rows because there is no natural unique key.
- Loves use the same table. If an unlove is pending and the user loves the track, Pano rewrites the
  row's event to `love` and adds the service bits [ScrobbleEverywhere.kt:386-430][pano-scrobble-everywhere].
  Loves store artist/track (and album when known), not a scrobble timestamp.

### 2.3 Rules and lists

| Table | Natural key / order | Fields | In Pano JSON export |
| --- | --- | --- | --- |
| `simpleEdits` | Unique on the four `hasOrig*` flags plus the four original values | Original track/artist/album/album artist, replacement values, `continueMatching` | `simple_edits`, also read as legacy `edits` |
| `regexEdits` | `_id`; ordered by `order` | Name, four search patterns, optional four replacement patterns, package ids, case sensitivity, optional block action, `continueMatching`, `enabled` | `regex_rules` |
| `blockedMetadata` | Unique on track+album+artist+album artist | Each field may be blank as a wildcard; action `skip`, `mute` or `ignore` | `blocked_metadata` |
| `artistsWithDelimiters` | Unique artist, case-insensitive | One artist string | `artists_with_delimiters` (array of strings) |
| `customSpotifyMappings` | Unique artist+album | Spotify id or local file URI | **No** |
| `scrobbleSources` | `_id`, indexed by time | Epoch ms plus package name | Private export only |
| `seenTracks` / `seenAlbums` / `seenTrackAlbumAssociations` | Unique artist+track, artist+album, track+album | Loved state, art URL, fetch timestamps, association priority | **No** |

Sources: [SimpleEdit.kt][pano-simple-edit], [RegexEdit.kt][pano-regex-edit],
[BlockedMetadata.kt][pano-blocked], [ArtistWithDelimiters.kt][pano-delimiters],
[CustomSpotifyMapping.kt][pano-spotify-map], [ScrobbleSource.kt][pano-source],
[SeenEntitiesDao.kt][pano-seen-dao].

Rule semantics that matter to the data layer:

- Simple edits match case-insensitively on the original values; blank replacement fields mean "keep
  the incoming value". `continueMatching` controls whether later rules run.
- Regex rules are tried in `order`; only enabled rules apply. Pano caps enabled rules at 50 without a
  licence and 300 with one [Stuff.kt:62-63][pano-stuff]. That is an entitlement rule, not a storage
  constraint.
- A block entry with all four fields blank matches everything. The add dialog lowercases entries
  and matching lowercases the incoming scrobble; imported rows are inserted as-is, so an importer
  should normalize them. Multiple matches are resolved by preferring the entry with the fewest
  blank fields [BlockedMetadataDao.kt:65-145][pano-blocked].
- Artist splitting exceptions are a case-insensitive set of names; they affect metadata
  preprocessing, not storage.
- Custom Spotify mappings are local artwork overrides and are never exported, so they are lost on a
  device move. A droplet that supports artwork overrides should include them in its full backup.

### 2.4 Source hints (`scrobbleSources`)

Pano inserts one row per scrobble that carries an app id, before attempting submission
[ScrobbleEverywhere.kt:324-332][pano-scrobble-everywhere]. The row holds the scrobble timestamp and
the package name. When displaying remote recents, Pano looks for the nearest hint within one second
to attach an app icon [ScrobblesPagingSource.kt:99-118][pano-paging],
[ScrobbleSourcesDao.kt][pano-source-dao]. There is no pruning: rows accumulate for the life of the
install. The table is not in the public export; only the unimplemented private export would carry it
[ImExporter.kt:41-72][pano-imexporter], [ExportScreen.kt:61-63][pano-export-screen].

This is Android-specific data. On macOS the equivalent is a player or helper bundle id. A droplet
should store the source on the scrobble row itself and avoid a second unbounded table.

### 2.5 Derived caches

`seenTracks` stores artist, track, optional loved state, when the loved state was last written, and
when track info was last fetched [SeenTrack.kt][pano-seen-track]. The loved state is one global flag
per artist+track, not one per service; a love is fanned out to every linked account. `seenAlbums` stores artist, album,
art URL and when art was last fetched [SeenAlbum.kt][pano-seen-album]. The association table links
tracks to albums with a priority where the lower number wins: media player 10, recent tracks 20,
charts 30, track info 40, album info 50 [SeenTrackAlbumAssociation.kt][pano-seen-assoc]. `SeenEntitiesDao` rebuilds these from
`user.getRecentTracks`, loved tracks, top albums, album info and local media metadata
[SeenEntitiesDao.kt:138-330][pano-seen-dao]. They are a cache: losing them costs network calls and
loses locally known loved state until the next fetch.

The generic HTTP cache is separate: memory plus files, with responses whose `max-age` is at most 300
seconds kept in memory, everything else on disk, and disk trimmed oldest-first at 40 MB
[HybridCacheStorage.kt:13-80][pano-cache], [Requesters.kt:136-142][pano-requesters]. It can make a
recent history page readable offline, but it is not a queryable history and evicts without warning.

### 2.6 What Pano does not store

- **No scrobble history table.** The recents screen pages `user.getRecentTracks` (or the equivalent)
  from the current service [ScrobblesPagingSource.kt:51-70][pano-paging]. The maintainer explicitly
  declined a local post-submission store and pointed at scrobbling to a file instead
  ([#377][issue-377], [#388][issue-388]); a user asking where scrobble logs live was told there are
  none ([#378][issue-378]). File scrobbling is a shipped feature, not a hidden log [README][pano-readme].
- **No now-playing row.** Now-playing is a transient network call.
- **No account export.** The export UI says logins are excluded for security
  [strings.xml:291][pano-strings].
- **No database export.** A user asking for CSV of listened data was told the feature does not exist
  ([#616][issue-616]).
- **No local search index.** Pano removed its indexer in March 2026 and replaced it with the seen
  cache; the index was a cache of top artists/albums/tracks and loves, not a play log
  [commit `85608ae2`][pano-index-removal].

---

## 3. Import and export formats

### 3.1 Pano JSON backup

Produced by Configure → Import & export → Export; the picker proposes a JSON file with an app-name
prefix and a date suffix [ExportScreen.kt:60-64][pano-export-screen]. Top-level shape
[ImExporter.kt:255-276][pano-imexporter]:

```json
{
  "pano_version": 0,
  "simple_edits": [],
  "regex_rules": [],
  "blocked_metadata": [],
  "artists_with_delimiters": [],
  "settings": {}
}
```

`scrobble_sources` is present only in the private variant; the public writer emits it as null, and
nulls are omitted.

| Key | Type | Notes |
| --- | --- | --- |
| `pano_version` | integer | App version code, **not** an export-schema version. Import does not gate on it. |
| `simple_edits` | array or absent | Legacy readers also accept the key `edits`. |
| `regex_rules` | array or absent | Current rule shape. |
| `regex_edits` | array or absent | Legacy v3 rule shape; accepted on import and migrated. |
| `blocked_metadata` | array or absent | |
| `artists_with_delimiters` | array of strings or absent | |
| `scrobble_sources` | array or absent | Private export only; null/omitted in the public export. |
| `settings` | object or absent | Public settings subset. |

Row keys, for mapping into a droplet:

| Array | Keys per row |
| --- | --- |
| `simple_edits[]` | `hasOrigTrack`, `origTrack`, `hasOrigArtist`, `origArtist`, `hasOrigAlbum`, `origAlbum`, `hasOrigAlbumArtist`, `origAlbumArtist`, `track`, `album`, `artist`, `albumArtist`, `continueMatching` |
| `regex_rules[]` | `order`, `name`, `search.{searchTrack,searchAlbum,searchArtist,searchAlbumArtist}`, `replacement.{replacementTrack,replacementAlbum,replacementArtist,replacementAlbumArtist,replaceAll}`, `appIds`, `caseSensitive`, `blockPlayerAction`, `continueMatching`, `enabled` |
| `blocked_metadata[]` | `track`, `album`, `artist`, `albumArtist`, `blockPlayerAction` |
| `artists_with_delimiters[]` | a bare string |
| `scrobble_sources[]` | `timeMillis`, `pkg` (private export only) |

There is deliberately no `scrobbles` array. Serialization conventions
[ImExporter.kt:29-38][pano-imexporter]:

- Pretty-printed JSON, UTF-8.
- Unknown keys ignored on read.
- Nulls omitted; default values written.
- `_id` is stripped from every exported row. Pano's own imports therefore allocate new ids; a
  hand-edited file that supplies `_id` is read as-is and can collide, so a droplet importer should
  ignore it.
- Simple edits and blocklist rows are exported oldest-first (the DAO's newest-first query is
  reversed); regex rules are exported in `order`.
- There is no history, pending queue, account, cookie, seen-cache or custom-mapping key.

**Public versus private.** `export()` writes settings, simple edits, regex rules, blocked metadata
and artist delimiters; it deliberately writes `scrobble_sources: null`
[ImExporter.kt:41-61][pano-imexporter]. `exportPrivateData()` writes only scrobble sources, but the
UI never calls it; the private filename is prepared and the call is marked as a TODO
[ExportScreen.kt:61-63,205][pano-export-screen].

**Import options.** The user chooses any of: settings, simple edits, regex rules, blocked metadata,
artist delimiters, scrobble sources [ImportScreen.kt:190-220][pano-import-screen]. There is no
history, pending queue, account or custom-mapping option. For list tables the user also chooses:

| Mode | Effect |
| --- | --- |
| Replace all | Empty the selected list tables, then insert imported rows. |
| Merge, replacing existing | Insert with conflict replacement, so imported rows win on natural-key collisions. |
| Merge, keeping existing | Insert with conflict ignore, so local rows win. |

Regex rules ignore that mode except for the initial empty step: Pano drops `_id` and `order` when
comparing, then inserts only rules that are not already present [RegexEditsDao.kt:61-72][pano-regex-dao].
Artist delimiters and scrobble sources use replacement inserts. Settings are applied to the existing
document, not replaced wholesale; package allowlists are filtered to apps that exist on the target
device, and if every imported package is missing, the local list is kept
[ImExporter.kt:100-140][pano-imexporter].

**Legacy regex shape.** Before the current four-field patterns, a rule had a single `pattern`, a
`replacement`, a set of `fields`, a set of `packages`, and optional `extractionPatterns`. Import
expands one legacy rule into one current rule per field, skips built-in presets, and maps the old
snake-case `albumartist` field to `albumArtist` [ImExporter.kt:143-208][pano-imexporter]. A droplet
importer must accept both shapes; an exporter should write only the current shape.

**Gaps a droplet should close in its own full backup:** history, pending queue, accounts (metadata
only), custom artwork mappings, seen/loved cache if desired, and the private source hints. Keep those
in a separate, versioned Droppy backup rather than adding them to the Pano-compatible file.

### 3.2 Pano CSV and JSONL scrobble log

Pano can be configured with a file "service" that appends each scrobble to a CSV or JSONL file
[FileScrobblable.kt:59-90][pano-file]. This is a sink, not a backup; it is also readable back as a
recents source, capped at the last 1 MB [FileScrobblable.kt:149-190,363][pano-file].

| Field | Type | Meaning |
| --- | --- | --- |
| `timeHuman` | string | Locale-formatted display time; do not parse it |
| `timeMs` | integer | Epoch milliseconds |
| `artist` | string | |
| `track` | string | |
| `album` | string or empty | |
| `albumArtist` | string or empty | |
| `durationMs` | integer or empty | |
| `mediaPlayerPackage` | string or empty | |
| `mediaPlayerName` | string or empty | Display label captured at write time |
| `mediaPlayerVersion` | string or empty | |
| `event` | `scrobble`, `love` or `unlove` | Missing value defaults to `scrobble` |

The CSV header is exactly those eleven columns [FileScrobblable.kt:365-366][pano-file]. The header is
written only when Pano creates an empty file; an existing file without a header is accepted. The
reader discards a first line that starts with `timeHuman` (CSV) or is incomplete because the read
started mid-file. JSONL is one object per line with the same keys. `timeHuman` is produced by a
locale-aware formatter, so `timeMs` is the only reliable timestamp.

Mapping to a droplet: `event = scrobble` becomes a history row; `love`/`unlove` become a desired
love state plus a pending action. `mediaPlayerPackage` becomes the source id. There is no track
number and no MusicBrainz id.

### 3.3 Last.fm CSV

Last.fm does not publish one canonical CSV schema. Its own support guidance points users at the API
(XML/JSON) or at third-party exporters for CSV [Last.fm support][lastfm-support]. In practice the
widely used header is:

```text
uts,utc_time,artist,artist_mbid,album,album_mbid,track,track_mbid
```

| CSV field | Type | Droplet field | Notes |
| --- | --- | --- | --- |
| `uts` | integer seconds | `played_at_ms = uts * 1000` | UTC Unix time |
| `utc_time` | display string | ignore | Human-readable, not authoritative |
| `artist` | string | `artist` | |
| `artist_mbid` | UUID or empty | optional `artist_mbid` | Not needed for playback/history |
| `album` | string or empty | `album` | Empty means unknown |
| `album_mbid` | UUID or empty | optional `album_mbid` | |
| `track` | string | `track` | |
| `track_mbid` | UUID or empty | optional `track_mbid` | |

This header is documented by an independent analysis of a Last.fm export and by independent
importers [Last.fm schema][lastfm-schema], [rocksky importer][rocksky-import]. Treat it as a
de-facto shape, not a guarantee. Some exporters reorder columns, omit headers, use
`timestamp`/`title`/`song`, or include `album_artist`/`duration`. A robust importer should:

1. Sniff the delimiter (comma, tab, semicolon) and encoding (UTF-8 with or without BOM).
2. Read a header when present; otherwise ask the user to map columns, with a best-guess preview.
3. Accept aliases: `uts`/`timestamp`/`time`/`date`, `artist`/`artist_name`,
   `track`/`title`/`song`, `album`/`album_name`, `album_artist`/`albumartist`,
   `duration`/`duration_ms`/`length`.
4. Reject rows without artist, track or a positive timestamp; report counts, do not fail the file.
5. Convert seconds to milliseconds once, at the boundary.

The common eight-column Last.fm export has no album artist, duration, source, event or track number.
Do not invent them:
leave album artist null and let display fall back to artist, as Pano does in `ScrobbleData.toTrack()`
[ScrobbleData.kt:20-27][pano-scrobble-data].

Bulk-imported histories can contain many rows with identical `uts` but different tracks. Dedupe on
`(uts, normalized artist, normalized track, normalized album)`, not on time alone.

### 3.4 Last.fm API JSON (backfill, not a file format)

`user.getRecentTracks` returns pages of at most 200, with `date.uts` in seconds and an optional
`@attr.nowplaying` entry that has no timestamp [Last.fm API][lastfm-recenttracks]. This is the right
source for an optional one-time backfill or reconciliation. Exclude now-playing entries, convert
seconds to milliseconds, and mark the rows as imported. Last.fm's support documentation describes
the API as the bulk route; the CSV header below comes from exporters, not a first-party spec
[Last.fm support][lastfm-support].

`track.scrobble` accepts at most 50 scrobbles per request, timestamps in seconds and duration in
seconds [Last.fm API][lastfm-scrobble]. A queue batch size above 50 is invalid for Last.fm even if
other services allow more; keep the shared batch at 50 or chunk per service.

### 3.5 Formats not supported by Pano

- No Last.fm CSV import or full-history export ([#616][issue-616], [#377][issue-377]).
- No generic CSV/JSON import in the Kotlin app. The macOS port in this fork adds a simple
  `artist, track, album, timestamp` CSV/JSON import screen, but that is port behaviour, not Pano
  Kotlin behaviour [FileScrobbleView.swift][fork-file-import].
- No Spotify, Apple Music or ListenBrainz file import. Out of scope unless a later ticket asks.
- No Pano database import. The Room database is app-private and is not an export format; the only
  supported migration path out of Pano is the JSON backup and, separately, its CSV/JSONL scrobble
  sink.
- Pano's LAN transfer sends the same public JSON over an ad-hoc HTTPS/mDNS channel
  [ExportVM.kt][pano-export-vm], [ImportVM.kt][pano-import-vm]. Do not copy that transport; file
  import/export gives the same data with less attack surface.

---

## 4. Offline history versus refetchable data

| Data | Pano stores it? | Needed offline? | Can be refetched? | Droplet decision |
| --- | --- | --- | --- | --- |
| Accepted scrobble (who/what/when) | **No** | **Yes** | Partly, per service; not if every delivery failed | **Store locally, authoritative** |
| Pending scrobble | Yes | **Yes** | **No** | Store locally |
| Pending love/unlove | Yes | **Yes** | **No** | Store locally |
| Delivery attempts and last error | Yes, on pending rows | Diagnostic only | No | Store per delivery |
| Account metadata | Yes | Yes | No, but user can re-enter | Store, no secrets |
| Session keys | Yes, plaintext | Yes | Re-auth | Keychain only |
| Settings | Yes | Yes | No | Store, export |
| Simple/regex/block rules | Yes | Yes | No | Store, export |
| Artist delimiters | Yes | Yes | No | Store, export |
| Artwork overrides | Yes | Nice to have | No | Store, export |
| Source hints | Yes | For icons | No | Fold into history |
| Seen tracks/albums/loved/art | Yes | No | Yes | Cache, disposable |
| Charts, friends, search | HTTP cache only | No | Yes | Cache |
| Remote recent history | HTTP cache only | No | Yes | Import/reconcile once |
| Profile/drawer/pinned friends | Yes, prefs | No | Yes | Cache |
| Search/tag history | Yes, prefs | UX only | No | Settings |
| Cookies/Spotify token | Yes, prefs | Yes | Re-auth | Keychain |

The key distinction: **history that this Mac heard is local-only until a service accepts it**. A
service copy is a backup, not the source. Anything the user created locally (rules, edits, source,
settings) cannot be refetched. Anything a service produced (charts, art, tags, loved state, remote
history) can be rebuilt.

---

## 5. What the droplet must store

### 5.1 Design rules

1. **Local history is authoritative.** Insert the scrobble locally before any network call, in the
   same transaction that creates its per-service delivery rows. Pano's send-then-queue order is a
   data-loss window, not a behaviour to copy.
2. **Per-service delivery, not a bitmask.** A normalized delivery row per account makes partial
   failure, retries, account removal and export explicit. A bitmask is compact but hides attempt
   history and breaks when service ids change.
3. **Imported history is inert.** Rows imported from Last.fm or Pano files must never be
   automatically submitted to a service. Mark them `origin = imported` and give them no queued
   delivery. A separate, explicit "backfill" action can create deliveries later.
4. **Secrets never enter the database or an export.** Keychain keyed by account UUID. Export
   account metadata only, so the restore flow can prompt for re-authentication.
5. **Cache is disposable.** Keep derived data in a separate SQLite file (or clearly marked cache
   tables) so it can be dropped, recreated or capped without a user-data migration.
6. **Every export is versioned and every import is idempotent.** History imports are the one
   operation users will retry; duplicates are unacceptable.
7. **Use UTC epoch milliseconds internally.** Convert to seconds only at service and CSV
   boundaries. Never parse a locale-formatted display time.

### 5.2 Minimum schema

`library.sqlite`:

| Table | Columns | Notes |
| --- | --- | --- |
| `meta` | `key`, `value` | Schema version, app version, install id, last migration |
| `account` | `id` UUID, `service` text, `username`, `api_root`, `display_name`, `avatar_url`, `created_at`, `last_auth_at`, `auth_state` | One row per linked account; token in Keychain under `account.<id>` |
| `scrobble` | `id`, `played_at_ms`, `artist`, `track`, `album`, `album_artist`, `duration_ms`, `track_number`, `source_bundle_id`, `source_name`, `origin`, `import_batch_id`, `dedupe_key`, `created_at`, `updated_at`, `edited_at`, `deleted_at` | Unique `dedupe_key`; index on `played_at_ms`, `(artist, track)` |
| `delivery` | `scrobble_id`, `account_id`, `state`, `attempt_count`, `next_attempt_at`, `last_attempt_at`, `last_error_code`, `last_error`, `remote_id`, `sent_at` | PK `(scrobble_id, account_id)`; index `(state, next_attempt_at)` |
| `love_state` | `artist_key`, `track_key`, `desired`, `updated_at` | Global desired state; per-account delivery rows carry the fan-out |
| `pending_action` | `id`, `account_id`, `kind`, `artist`, `track`, `album`, `album_artist`, `target_scrobble_id`, `state`, `attempt_count`, `next_attempt_at`, `last_error` | Loves, un-loves, remote edits, remote deletes |
| `rule_simple` | same fields as Pano's `simpleEdits`, with a stable local id | Natural-key unique index |
| `rule_regex` | same fields as Pano's `regexEdits`, with `order`, `enabled` | Import/export both shapes |
| `rule_block` | track, album, artist, album artist, action | Lowercase on write; wildcard blanks |
| `rule_artist_delimiter` | artist, casefolded artist | Unique |
| `rule_artwork` | artist, album, spotify_id, file_uri | Optional parity with Pano's custom mappings |
| `import_batch` | `id`, `format`, `source_name`, `file_hash`, `imported_at`, `row_count`, `skipped_count` | Makes re-import idempotent and auditable |
| `source_hint` | `played_at_ms`, `bundle_id` | Optional; only if remote recents need decoration |

Settings are not in this database. They live in `DropletPreferencesService` (the map's split puts
SQLite in charge of scrobbles, the queue and rules), and the export writer serializes them.

`cache.sqlite` (or `cache_*` tables): `cache_track`, `cache_album`, `cache_track_album`,
`cache_love`, `cache_art`. All rebuildable.

`dedupe_key` should be a hash of casefolded artist, casefolded track, casefolded album (or empty),
and `played_at_ms` rounded to the second. Two different tracks bulk-imported at the same second stay
distinct; the same row re-imported collapses. This is the natural identity of a scrobble in Pano's
CSV (time plus artist plus track), not a database row id.

### 5.3 Write path

Capture:

1. Receive metadata from the media helper, normalize whitespace, apply rules.
2. Begin a transaction.
3. Insert `scrobble` with `origin = captured`.
4. Insert one `delivery` row per enabled account, state `queued`.
5. Commit, then update the UI.

Sender:

1. Select due deliveries, grouped by account, oldest first, at most 50 per Last.fm request.
2. Mark `sending` with an attempt timestamp.
3. On success, mark every accepted row `sent`; on partial/ignored response, record the per-row
   result. On transport failure, mark `failed` with a next attempt.
4. Never delete the history row when delivery succeeds. Only delivery state changes.

Edits and deletes:

- Local edit updates the history row and creates `pending_action` rows for services that support
  remote edits, rather than mutating a remote copy and losing the local record.
- Local delete is a tombstone (`deleted_at`), kept until every service confirms or the user chooses
  "delete locally only". This prevents a later refetch from resurrecting it.
- Loves write `love_state` first, then queue per-account actions.

Import:

1. Stream-parse the file; never load a multi-year history fully into memory.
2. Create an `import_batch` with a file hash.
3. Normalize and dedupe within the file.
4. Insert rows with `origin = imported`, `import_batch_id` set, and no deliveries.
5. Report inserted / duplicate / skipped counts. Re-running the same file inserts nothing.

### 5.4 Export modes

| Export | Contents | Purpose |
| --- | --- | --- |
| Droppy backup (`droppy-backup.json`) | Version, accounts without secrets, history, deliveries, pending actions, rules, settings, import batches | Restore on a new Mac |
| Pano-compatible JSON backup | Settings, simple edits, regex rules, blocked metadata, artist delimiters; optional source hints | Move lists/settings to or from Pano |
| History CSV (`uts,utc_time,artist,artist_mbid,album,album_mbid,track,track_mbid`) | Every scrobble, seconds, empty MBIDs when unknown; no secrets | Spreadsheet, Last.fm-style tools |
| Pano history CSV/JSONL | Pano's eleven-column shape | Feed Pano's file service or another Pano install |

Keep the Pano-compatible writer separate from the full backup. Do not add unknown history keys to
the Pano file and assume Pano will preserve them; Pano ignores unknown keys, so a round trip through
Pano would silently drop them anyway.

Import merge policy:

- History: always merge by `dedupe_key`; never replace the local library from a file.
- Rules: offer Pano's three modes, but implement them as explicit upsert policies per table.
- Settings: apply known keys only; ignore Android-only package filters with a report.
- Accounts: match on service + username + api_root; never import a token.
- Pending queue: restore paused and show the count. A restored pending row may already have reached
  the service before the backup, so automatic resubmission risks duplicates. Let the user resume.
- Reinstall restore: if the database is missing but preferences say a backup was exported, offer
  import on first launch.

---

## 6. Migration, updates and reinstall

### 6.1 Versioning

- `PRAGMA application_id` identifies the library database; `PRAGMA user_version` holds the schema
  version. Also keep a human-readable version in `meta` for diagnostics.
- Export formats have their own integer `format_version`, independent of the database and the app
  version. Pano's `pano_version` is an app version code and is not a schema signal
  [ImExporter.kt:255-276][pano-imexporter].
- Service identifiers are text codes (`lastfm`, `listenbrainz`, `librefm`, `pleroma`), not Pano's
  bit positions. If an integer is needed for compact storage, reserve values permanently and never
  renumber. Pano's ids already have a hole at 5 [Scrobblable.kt:155-164][pano-account-type].

### 6.2 Migration protocol

1. On open, read `user_version`.
2. If the database is empty, create the current schema and stamp the version.
3. If `user_version == current`, open normally.
4. If `user_version < current`, take a consistent snapshot first (`VACUUM INTO` or checkpoint +
   copy), then run each migration step in order inside a transaction. Stop on the first error and
   leave the original database untouched.
5. If `user_version > current`, do not run destructive fallback. Open read-only and tell the user to
   update the droplet. Pano uses destructive fallback on downgrade
   [PanoDb.kt:44-51][pano-db]; a source-of-truth database must not.
6. After migration, run `PRAGMA integrity_check` and `PRAGMA foreign_key_check`; log row counts.
7. Keep the last one or two pre-migration snapshots in the container, and delete them only after a
   successful launch.

Pano's own history shows why this matters: it carries three manual migrations for table rewrites and
nine automatic migrations between versions 9 and 19 [PanoDb.kt:23-33][pano-db],
[ManualMigrations.kt:8-230][pano-manual-migrations]. One manual migration rebuilds the pending
queue and regex tables and deletes preset rows; another rewrites the old edits table. A droplet will
have fewer tables, but the same rule applies: ship small, ordered, tested steps, never edit a
migration that has shipped.

### 6.3 SQLite settings

- `journal_mode = WAL`; `foreign_keys = ON` on every connection; `busy_timeout` of a few seconds;
  `synchronous = NORMAL` for a scrobble log (use `FULL` if the product prefers durability over
  throughput).
- One writer. Serialize writes through an actor or a dedicated queue; readers can use snapshots.
- Never do SQLite work on Droppy's main actor; file I/O and decoding belong off it
  [Droppy good citizen][droppy-good-citizen].
- Use `TEXT` for names, `INTEGER` for epoch ms and booleans, and `NULL` for genuinely absent album
  or album artist values. Do not mix `NULL` and `''` for the same meaning; if a unique index needs
  empty strings, normalize deliberately.
- Add indexes for the actual queries: history by time, history by artist/track, due deliveries,
  pending actions, and import batch.

### 6.4 Surviving updates and reinstalls

Droppy guarantees the container across **updates**; the docs do not promise it across removal and
reinstall [DropletEnvironmentService][droppy-env]. Preferences are stronger: droplet-scoped
preferences survive being disabled, re-enabled, updated, and even removed/reinstalled
[DropletPreferencesService][droppy-prefs]. Secrets belong in Keychain
[Droppy good citizen][droppy-good-citizen].

Therefore:

- Put settings that must survive a reinstall in `DropletPreferencesService`, not only in SQLite.
  The database remains the source of truth for history; preferences carry the small configuration
  and a "last export" marker.
- Treat the container as durable across updates but not across uninstall. The documented escape
  hatch is an export file; offer it prominently and remind the user before removal if the host
  exposes that moment.
- Keychain items are independent of the container. If the database is gone but Keychain tokens
  remain, do not silently recreate accounts: show the account metadata, ask the user to confirm,
  and bind tokens to new account UUIDs. Delete orphaned items.
- On a fresh database, if preferences indicate a prior install, offer "Restore from backup" instead
  of starting empty.
- Do not store absolute paths or security-scoped bookmarks in the database. If a user grants a
  backup folder, keep the bookmark in preferences and refresh it on launch.

### 6.5 What "survive reinstall" means for each class

| Class | Update | Reinstall | Mechanism |
| --- | --- | --- | --- |
| Settings | Yes | Yes | Droplet preferences |
| Secrets | Yes | Usually yes | Keychain |
| History | Yes | **Not guaranteed** | Container + export |
| Pending queue | Yes | **Not guaranteed** | Container + export |
| Rules | Yes | **Not guaranteed** | Container + export, also Pano JSON |
| Cache | Yes | No | Rebuild |

If the product requires history to survive reinstall without a manual export, that is a separate
decision: it needs a host-supported durable location or a user-granted backup folder, and should be
raised with the Droppy maintainer rather than assumed.

---

## 7. Retention

| Store | Pano | Droplet recommendation |
| --- | --- | --- |
| History | None | Keep forever by default; user may export or delete ranges |
| Pending scrobbles | Forever, no cap | Keep until success or explicit discard; warn at a visible cap (e.g. 10k) instead of silently dropping |
| Pending loves | Forever | Same |
| Delivery attempts | On pending row, overwritten | Keep last error and count per account; prune sent rows only if storage demands |
| Source hints | Forever, one per scrobble | On the scrobble row; no separate growth |
| Seen/loved/art cache | Forever, no pruning | TTL and size cap; rebuild on demand |
| HTTP cache | 40 MB, oldest first | Keep a similar cap; never treat it as history |
| Logs | Short-lived | Cap size and age; never log tokens or full history |
| Pre-migration snapshots | None | Keep the last one or two |
| Import batches | None | Keep forever; tiny and makes re-import safe |
| Tombstones | None | Keep until all services confirm, then purge after a fixed window |

Pano's unbounded tables are a warning, not a model. `scrobbleSources` grows once per scrobble and is
never pruned; `seenTracks`/`seenAlbums` have no delete query. A droplet with local history would
inherit that growth twice if it copied the design.

---

## 8. Acceptance checks

1. **Pano JSON round trip.** Import a v3 export with legacy `regex_edits` and preset rows, then a v4
   export with `simple_edits`/`regex_rules`; both produce the same rules. Re-export in current shape
   and import that into a clean database.
2. **No accidental history submission.** Import a 10k-row Last.fm CSV; assert zero network scrobble
   calls and zero delivery rows.
3. **Idempotent import.** Import the same file twice; second run inserts zero history rows and
   reports duplicates.
4. **Offline history.** Disable network, capture a scrobble, kill and relaunch; the scrobble and its
   queued deliveries are visible. Re-enable network; delivery succeeds without duplicating the row.
5. **Crash safety.** Kill the process during capture and during send; on relaunch there is either a
   complete scrobble with deliveries or no row, never a half row.
6. **Partial failure.** Two accounts, one rejects; history stays, one delivery is `sent`, the other
   retries, and the local row is not deleted.
7. **Account removal.** Remove an account; its queued deliveries are cancelled, other accounts keep
   theirs, and history remains.
8. **Migration.** Create a v1 database, run the full migration chain, assert row counts, foreign keys
   and integrity; simulate a failure and assert rollback plus snapshot.
9. **Downgrade guard.** Open a future schema with an older build; it opens read-only and does not
   erase data.
10. **Reinstall restore.** Delete the container but keep preferences/Keychain; first launch offers
    restore, imported accounts require re-authentication, and no token is read from the backup.
11. **Secret audit.** Search the database, exports and logs for token material; none.
12. **CSV edge cases.** Quoted commas, CRLF, BOM, missing header, blank album, duplicate timestamps,
    Unicode names and a row with a bad timestamp all behave as specified.

---

## 9. Open questions

- Does `containerDirectory` survive droplet removal/reinstall in the shipping host? The docs only
  promise updates. This blocks any claim stronger than "export is the escape hatch"; ask in the
  Droppy policy ticket.
- Multiple accounts per service: Pano models one per service type. If the droplet supports more,
  delivery and love tables need `account_id` everywhere from day one (the proposal above does).
- Should restored pending scrobbles resume automatically or stay paused? Paused is safer; automatic
  is closer to Pano's reinstall behaviour.
- Is encrypted export in scope? Listening history is sensitive; Pano does not encrypt its export.
- Do we keep Pano JSON compatibility forever, or only as a one-time migration path? Keeping it is
  cheap for rules/settings and valuable for users leaving Pano.

---

## Sources

Pano source read at commit [`a7c8318237d480d64f06b38d890e3f23506683b9`][pano-repo] (12 May 2026).
Paths below are relative to the repository root.

| Claim | Source |
| --- | --- |
| Database version 19, ten entities, destructive downgrade | [PanoDb.kt][pano-db] |
| Manual migrations 7→8, 8→9, 14→15 | [ManualMigrations.kt][pano-manual-migrations] |
| Pending row shape and columns | [PendingScrobble.kt][pano-pending-entity] |
| Pending queue queries, bitmask removal, retry window | [PendingScrobblesDao.kt][pano-pending-dao] |
| Batch limits, retry policy, partial success handling | [PendingScrobblesWorker.kt][pano-worker] |
| Android work scheduling and backoff | [PendingScrobblesWork.android.kt][pano-pending-work] |
| Queue-after-send and source-hint insertion | [ScrobbleEverywhere.kt][pano-scrobble-everywhere] |
| Service ids and one account per type | [Scrobblable.kt][pano-account-type] |
| Account fields and session key | [UserCached.kt][pano-usercached] |
| Settings/account document and public export subset | [MainPrefs.kt][pano-mainprefs] |
| Export payload, aliases, merge modes, legacy regex migration | [ImExporter.kt][pano-imexporter] |
| Export/import UI and options | [ExportScreen.kt][pano-export-screen], [ImportScreen.kt][pano-import-screen] |
| Export excludes logins | [strings.xml:291][pano-strings] |
| Pano CSV/JSONL fields and header | [FileScrobblable.kt][pano-file] |
| Rule entities and natural keys | [SimpleEdit.kt][pano-simple-edit], [RegexEdit.kt][pano-regex-edit], [BlockedMetadata.kt][pano-blocked], [ArtistWithDelimiters.kt][pano-delimiters], [CustomSpotifyMapping.kt][pano-spotify-map] |
| Source hints and lookup window | [ScrobbleSource.kt][pano-source], [ScrobbleSourcesDao.kt][pano-source-dao], [ScrobblesPagingSource.kt][pano-paging] |
| Seen cache fields and rebuild paths | [SeenTrack.kt][pano-seen-track], [SeenAlbum.kt][pano-seen-album], [SeenTrackAlbumAssociation.kt][pano-seen-assoc], [SeenEntitiesDao.kt][pano-seen-dao] |
| HTTP cache cap and eviction | [HybridCacheStorage.kt][pano-cache], [Requesters.kt][pano-requesters] |
| Android and desktop data paths | [PlatformStuff.android.kt][pano-platform-android], [PlatformStuff.desktop.kt][pano-platform-desktop] |
| Android backup includes database and files | [AndroidManifest.xml][pano-manifest], [backup_rules.xml][pano-backup-rules], [data_extraction_rules.xml][pano-data-extraction-rules] |
| No local history, no CSV export | [#377][issue-377], [#378][issue-378], [#616][issue-616] |
| File scrobbling request and outcome | [#388][issue-388], [README][pano-readme] |
| Indexer removal | [commit `85608ae2`][pano-index-removal] |
| Last.fm has no single CSV schema; API is the official route | [Last.fm support][lastfm-support] |
| Last.fm recent-tracks response shape and seconds | [Last.fm API: user.getRecentTracks][lastfm-recenttracks] |
| Last.fm scrobble limit, seconds, duration | [Last.fm API: track.scrobble][lastfm-scrobble] |
| Common Last.fm CSV header (secondary) | [Last.fm export schema][lastfm-schema], [independent importer][rocksky-import] |
| Droppy container persists across updates | [DropletEnvironmentService][droppy-env] |
| Droppy preferences survive reinstall | [DropletPreferencesService][droppy-prefs] |
| Secrets in Keychain; files in container; main actor | [Droppy good citizen][droppy-good-citizen] |

[pano-repo]: https://github.com/kawaiiDango/pano-scrobbler/tree/a7c8318237d480d64f06b38d890e3f23506683b9
[pano-db]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PanoDb.kt
[pano-manual-migrations]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/ManualMigrations.kt
[pano-pending-entity]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PendingScrobble.kt
[pano-pending-dao]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PendingScrobblesDao.kt
[pano-worker]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/work/PendingScrobblesWorker.kt
[pano-pending-work]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/androidMain/kotlin/com/arn/scrobble/work/PendingScrobblesWork.android.kt
[pano-scrobble-everywhere]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/ScrobbleEverywhere.kt
[pano-account-type]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/Scrobblable.kt
[pano-usercached]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/UserCached.kt
[pano-mainprefs]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/MainPrefs.kt
[pano-imexporter]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/ImExporter.kt
[pano-export-screen]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/ExportScreen.kt
[pano-import-screen]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/ImportScreen.kt
[pano-strings]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/composeResources/values/strings.xml
[pano-file]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/file/FileScrobblable.kt
[pano-simple-edit]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/SimpleEdit.kt
[pano-regex-edit]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/RegexEdit.kt
[pano-regex-dao]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/RegexEditsDao.kt
[pano-blocked]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/BlockedMetadataDao.kt
[pano-delimiters]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/ArtistsWithDelimiters.kt
[pano-spotify-map]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/CustomSpotifyMapping.kt
[pano-source]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/ScrobbleSource.kt
[pano-source-dao]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/ScrobbleSourcesDao.kt
[pano-paging]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/recents/ScrobblesPagingSource.kt
[pano-seen-track]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/SeenTrack.kt
[pano-seen-album]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/SeenAlbum.kt
[pano-seen-assoc]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/SeenTrackAlbumAssociation.kt
[pano-seen-dao]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/db/SeenEntitiesDao.kt
[pano-cache]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/cache/HybridCacheStorage.kt
[pano-requesters]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/Requesters.kt
[pano-platform-android]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/androidMain/kotlin/com/arn/scrobble/utils/PlatformStuff.android.kt
[pano-platform-desktop]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/desktopMain/kotlin/com/arn/scrobble/utils/PlatformStuff.desktop.kt
[pano-manifest]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/androidMain/AndroidManifest.xml
[pano-backup-rules]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/androidMain/res/xml/backup_rules.xml
[pano-data-extraction-rules]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/androidMain/res/xml/data_extraction_rules.xml
[pano-readme]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/README.md
[pano-stuff]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/utils/Stuff.kt
[pano-scrobble-data]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/ScrobbleData.kt
[pano-export-vm]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/ExportVM.kt
[pano-import-vm]: https://github.com/kawaiiDango/pano-scrobbler/blob/a7c8318237d480d64f06b38d890e3f23506683b9/composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/ImportVM.kt
[pano-index-removal]: https://github.com/kawaiiDango/pano-scrobbler/commit/85608ae2eff0ebd705549eca344e7ae1f53261a8
[fork-file-import]: https://github.com/ranokay/pano-scrobbler/blob/main/apple/Apps/macOS/Sources/Views/FileScrobbleView.swift
[issue-377]: https://github.com/kawaiiDango/pano-scrobbler/issues/377
[issue-378]: https://github.com/kawaiiDango/pano-scrobbler/issues/378
[issue-388]: https://github.com/kawaiiDango/pano-scrobbler/issues/388
[issue-616]: https://github.com/kawaiiDango/pano-scrobbler/issues/616
[lastfm-support]: https://support.last.fm/t/how-can-i-download-backup-my-last-fm-scrobbling-data/171
[lastfm-recenttracks]: https://www.last.fm/api/show/user.getRecentTracks
[lastfm-scrobble]: https://www.last.fm/api/show/track.scrobble
[lastfm-schema]: https://github.com/mattb/music-history-analysis/blob/main/LASTFM-SCHEMA.md
[rocksky-import]: https://github.com/tsirysndr/rocksky/blob/main/apps/cli/src/lib/importParsers.ts
[droppy-env]: https://getdroppy.app/docs/droppykit/api/droplet-environment-service
[droppy-prefs]: https://getdroppy.app/docs/droppykit/api/droplet-preferences-service
[droppy-good-citizen]: https://getdroppy.app/docs/droppykit/good-citizen
