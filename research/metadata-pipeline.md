# Metadata pipeline: edits, blocks, first artist, normalization

Status: research for `#7`, parent `#1`. Behaviour only, no upstream code, strings, comments or assets copied.

Source snapshot: `kawaiiDango/pano-scrobbler` at commit `990154031e761b8e5460a0585fc834b43c9e2d71` (2026-10-06). All citations are paths in that snapshot; the table at the end maps short names to full paths.

## 1. Field model

Pano carries four editable text fields and four transport fields.

| Field | Meaning | Required at submission | Editable by rules |
| --- | --- | --- | --- |
| `track` | title tag | yes | yes |
| `artist` | artist tag | yes | yes |
| `album` | album tag | no | yes |
| `albumArtist` | album artist tag | no | yes |
| `duration` | track length | no | no |
| `timestamp` | playback start | yes for a scrobble | no |
| `trackNumber` | track number tag | no, never populated | no |
| `appId` | player package or process id | no | no, but scopes regex rules |

The data class is `ScrobbleData` (`ScrobbleData.kt:8-34`). The platform layer collects title, artist, album, album artist, track number, duration, art URL and, on desktop, a normalized URL host (`MediaInfoStructs.kt:9-18`). `PlayingTrackInfo.toScrobbleData` omits track number, so it is never submitted or edited even though the platform reads it (`PlayingTrackInfo.kt:212-220`). Art URL is display-only. Duration is sent only when it falls between 30 seconds and 60 minutes (`ScrobbleData.kt:18`, `Lastfm.kt:80-110`). Timestamp is the play start and survives every edit (`ScrobbleQueue.kt:80-88`, `PlayingTrackInfo.kt:212-220`).

| Rule type | Match fields | Fields it can write | App-scoped | License |
| --- | --- | --- | --- | --- |
| Simple edit | track, artist, album, album artist | track, artist, album, album artist | no | no |
| Regex replace | track, artist, album, album artist | track, artist, album, album artist | yes | no |
| Regex extract | track, artist, album, album artist | track, artist, album, album artist | yes | yes |
| Regex block | track, artist, album, album artist | none | yes | yes |
| Metadata block | track, artist, album, album artist, exact only | none | no | yes |
| First artist | artist | artist, album artist when it equalled the old artist | yes | no |
| Preset | track, artist, album, album artist, depending on preset | track, artist, album, album artist, depending on preset | some presets | no |
| Album fill | none | album, album artist | no | no |

Anything called a "tag" in this document means one of those four text values as reported by the OS media session. Pano does not read or write embedded file tags, genre, year, composer, MusicBrainz IDs, or Last.fm user tags. Composer is read only by the Android Sonos fix described in section 12.

## 2. Where the pipeline sits

The order on every new track is fixed.

1. The platform adapter reads the media session and trims title, artist, album and album artist (`MetadataTransforms.android.kt:13-18`, `MetadataTransforms.jvm.kt:30-36`).
2. Android and desktop apply a small set of per-player fixes to broken tags before anything else runs (`MetadataTransforms.android.kt:34-137`, `MetadataTransforms.jvm.kt:48-60`).
3. `prepareForScrobbling` replaces sentinel values in artist, album and album artist, then snapshots the data (`PlayingTrackInfo.kt:165-174`).
4. On Windows Deezer and TIDAL, Pano may replace artist, album and album artist from the vendor API before the rule pipeline (`ScrobbleQueue.kt:205-210`, `ScrobbleEverywhere.kt:246-276`).
5. `preprocessMetadata` runs blocks, simple edits, regex edits, a second simple pass, built-in presets and first-artist extraction (`ScrobbleEverywhere.kt:90-244`).
6. Pano may fill a missing album from its cache or Last.fm after the rules (`ScrobbleQueue.kt:240-254`, `ScrobbleEverywhere.kt:402-485`).
7. The same preprocessed object feeds now playing and the scrobble (`ScrobbleQueue.kt:195-203`, `ScrobbleQueue.kt:256-276`).

A second full pass exists. If the first pass applied no user edit but presets or first-artist extraction changed the data, Pano reruns block check, simple edits, regex edits and the second simple pass on the preset output, with presets disabled for that pass (`ScrobbleEverywhere.kt:224-230`, `ScrobbleEverywhere.kt:90-148`).

## 3. Simple edits

### 3.1 Shape

A simple edit has four optional match values, one per field, and four optional replacement values. A match value is active only when its flag is set; an inactive field is a wildcard. A replacement value of null means "leave this field alone". A replacement value of the empty string is meaningful for album and album artist: it clears the field. For track and artist, an empty replacement is ignored and the current value survives (`SimpleEditsDao.kt:68-77`, `SimpleEdit.kt:31-58`).

The match tuple is unique. Saving a rule with the same active match values replaces the earlier rule, including its replacements and its `continueMatching` flag (`SimpleEdit.kt:10-28`, `SimpleEditsDao.kt:53-57`, `SimpleEditsDao.kt:124-140`). Rules have no name, no app scope and no user-visible order. Creating a rule without an existing scrobble saves it directly and applies nothing (`EditScrobbleUtils.kt:95-98`).

The UI requires at least one match field and one replacement field. Track and artist must be non-empty when their match or replacement is enabled. Album and album artist may be enabled with an empty value, which is how a user clears them (`SimpleEditsAddScreen.kt:142-184`).

Saved match values are lowercased but not trimmed. Saved replacements are trimmed (`SimpleEditsDao.kt:124-140`). Matching lowercases the current values before the database query, so matching is case-insensitive for the Unicode lowercase mapping but not whitespace-insensitive (`SimpleEditsDao.kt:82-87`). Null album and album artist are compared as empty strings.

### 3.2 Matching and precedence

All active match fields must equal the current field exactly. There is no substring or regex matching. The query orders matches by the number of active match fields descending, then by row id descending (`SimpleEditsDao.kt:17-34`). A rule that matches artist and track therefore runs before a rule that matches artist only. Among rules with the same number of active fields, the newest saved rule runs first. Because `INSERT OR REPLACE` deletes and reinserts on conflict, re-saving a rule also makes it newest.

Matching rules merge field by field. The first rule in that order that supplies a replacement for a field claims it, and later rules cannot overwrite it. A less specific rule can still fill a field that the more specific rule left null. All matching rules run; the source contains a commented-out early exit, so a `continueMatching` flag on one simple edit does not stop lower-specificity simple edits in the same pass (`SimpleEditsDao.kt:91-121`).

`continueMatching` therefore gates only later phases. The first pass returns false if any matching simple edit has the flag off, and that stops regex edits, the second simple pass, presets and first-artist extraction (`SimpleEditsDao.kt:96-121`, `ScrobbleEverywhere.kt:113-150`). A matching rule that changes no field still counts as an applied edit: it sets `userEditsApplied`, which suppresses the later second pass and the title-parse presets (`ScrobbleEverywhere.kt:113-118`, `RegexPresets.kt:80-82`).

### 3.3 Examples

Rule A matches artist `Example Band` and album `First Album`, and sets album to `Second Album`. Rule B matches artist `Example Band` only, and sets artist to `Example Band (UK)`.

Input `Example Band` / `First Album` matches both. A has two active fields, so it runs first and claims album. B then claims artist. Output is `Example Band (UK)` / `Second Album`.

Rule C matches track `Song` only and sets album to `Compilation`. Rule D matches track `Song` and artist `Example Band` and sets artist to `Example Band (UK)`. D runs first and claims artist; C then claims album. Both fields change.

A rule with album or album artist enabled and empty clears that field for every scrobble whose other active fields match. Track and artist cannot be cleared by a simple edit.

A rule that matches only `track` and `artist`, with `continueMatching` off, prevents regex edits and presets for that scrobble but does not stop other matching simple edits from applying.

## 4. Regex edits

### 4.1 Shape and mode

A regex edit has a name used only as a label, an integer order, four search patterns, an optional replacement block, a set of app ids, a case-sensitivity flag, an optional player action, a `continueMatching` flag and an enabled flag (`RegexEdit.kt:19-57`).

The mode is derived, not stored. A non-null player action makes it a block rule. With no player action and no replacement block, it is an extract rule. With a replacement block, it is a replace rule (`RegexMode.kt:9-13`). The UI builds exactly these three shapes (`RegexEditsAddScreen.kt:181-236`).

An empty app-id set means every app. A non-empty set matches the current app id exactly. Disabled rules are never evaluated. The enabled rules are read in ascending order and capped at 50 without a license or 300 with one; a rule past the cap, including a block rule, is ignored (`RegexEditsDao.kt:22-35`, `Stuff.kt:62-63`).

New rules are inserted with order -1, so they sort ahead of rules with non-negative order until the user drags the list. Dragging rewrites the whole list with indexes starting at zero (`RegexEditsAddScreen.kt:191-232`, `RegexEditsScreen.kt:135-138`). Duplicate order values have no specified tie-break.

### 4.2 Matching

For each non-empty search pattern, Pano runs a substring search against the corresponding current field. Empty patterns are not conditions. A rule matches only when every non-empty pattern finds something (`RegexEditsDao.kt:101-127`). The regex is not anchored, so a pattern can match in the middle of a value. Case-insensitive is the default; the flag applies to all four fields of that rule (`RegexEdit.kt:33`, `RegexEditsDao.kt:112-114`).

A pattern that fails to compile is treated as no match and the rule does not apply (`RegexEditsDao.kt:116-120`). The UI pre-validates patterns, but imported rules may bypass that check (`RegexEditsAddScreen.kt:1011-1029`).

Rules run sequentially in order and each one sees the output of the previous one. A matching rule with `continueMatching` off stops the regex loop after that rule (`RegexEditsDao.kt:101-171`). The break happens whenever the rule matched, even if the rule produced no change, for example an extract rule with missing capture groups or an unlicensed block rule. That break does not propagate to later phases unless some rule actually produced new data; later phases read the last successfully changed rule's flag (`ScrobbleEverywhere.kt:133-138`, `RegexEditsDao.kt:146-169`).

### 4.3 Replace rules

A replace rule needs a replacement block. Pano applies the search pattern for each of the four fields to that field's current value, using either first-match-only or all-matches depending on the rule's replace-all flag. Replacement text can reference capture groups (`RegexEditsDao.kt:233-287`).

All four fields are transformed, not only the fields whose patterns acted as match conditions. An empty search pattern is skipped while deciding whether the rule matches, but it is still compiled and applied during replacement. A non-empty replacement for a field with an empty search pattern therefore inserts text at the start of that field, or between every character when replace-all is on. This is a real footgun, not a rejected input (`RegexEditsDao.kt:101-127`, `RegexEditsDao.kt:248-287`).

The rule is discarded as a whole if the resulting track or artist is empty. Album and album artist are allowed to become empty, and are then stored as null (`RegexEditsDao.kt:290-299`). A track or artist made only of whitespace passes this check and may be emptied by the final trim.

The replacement block may set a fetch-album flag. If the rule succeeds, that flag allows the post-rule album lookup even though a user edit ran (`RegexEdit.kt:49-57`, `ScrobbleEverywhere.kt:137`, `ScrobbleEverywhere.kt:44-46`). The UI exposes this only when the global album-fetch preference is on (`RegexEditsAddScreen.kt:127`, `RegexEditsAddScreen.kt:163-165`, `RegexEditsAddScreen.kt:470-486`).

### 4.4 Extract rules

An extract rule must contain named capture groups called `track` and `artist`, and may contain one each called `album` and `albumArtist`. The UI enforces exactly one track group, exactly one artist group, and at most one album and one album-artist group across all four patterns (`RegexEditsAddScreen.kt:933-991`, `RegexEdit.kt:58-62`).

When the rule matches, Pano looks for each named group in the match results, in field order track, album, artist, album artist, and takes the first value found for each group name (`RegexEditsDao.kt:180-218`). It accepts the result only when both track and artist are non-empty. Album and album artist are copied from their groups. If either group is absent, that field becomes null, so extraction clears an album or album artist that the pattern did not capture (`RegexEditsDao.kt:221-228`).

Extraction requires a valid license and Java 8 or later; without them the rule has no effect (`RegexEditsDao.kt:140-151`). The UI also requires at least one app id for an extract rule (`RegexEditsAddScreen.kt:1008-1010`).

### 4.5 Block rules

A block rule matches like any other regex rule. When it matches and the license is valid, Pano stops the whole pipeline immediately, submits nothing, and returns the player action (`RegexEditsDao.kt:131-138`, `ScrobbleEverywhere.kt:128-132`). The first matching block rule in order wins. Earlier regex replacements in the same pass are irrelevant because the track is cancelled. Because the regex pass runs after the first simple pass, a simple edit can make a regex block match or stop matching.

Without a valid license the block branch does nothing. If the rule has `continueMatching` off, which the UI always sets for block rules, it still stops later regex rules, but it does not block the scrobble (`RegexEditsDao.kt:131-138`, `RegexEditsDao.kt:168-169`, `RegexEditsAddScreen.kt:222-232`).

### 4.6 Examples

Replace: a rule matches an artist containing a featured-artist marker and replaces the artist with the main artist while leaving track, album and album artist replacement text empty. Because the other search patterns are empty and their replacement text is empty, those fields are unchanged.

Replace-all: a rule matches a repeated separator in the album and removes all occurrences. With replace-all off, only the first occurrence would be removed.

Accidental insertion: a rule matches artist only and puts replacement text into the track field while leaving the track search pattern empty. The track value gets the replacement text prepended, because the empty pattern matches at position zero.

Extract: a rule matches the track value `Artist Name - Song Name` and captures artist and track. If the input album was `Old Album` and the rule has no album group, the resulting album is cleared. The same rule on a value without both groups produces no change and is not counted as applied.

Chain: rule one extracts artist and track from a decorated title; rule two, later in order, strips a version marker from the extracted track. Rule two sees the output of rule one.

Rejected output: a replace rule whose pattern removes the entire track value is discarded, and the data from before that rule survives. A rule whose replacement leaves only spaces is accepted and then trimmed to an empty track.

## 5. Blocks

Pano has two independent block mechanisms.

### 5.1 Metadata block list

The block list has four exact match fields: track, artist, album and album artist. A blank field is a wildcard. A row with all four blank is rejected by the query. Stored values are lowercased, and matching lowercases the current values, so matching is case-insensitive; null album and album artist compare as empty strings (`BlockedMetadata.kt:10-26`, `BlockedMetadataDao.kt:23-37`, `BlockedMetadataDao.kt:128-143`).

The match is full-field equality, never substring. A blank album means "any album", so the block list cannot express "only tracks with no album". A regex block can express that with an empty-value pattern.

When several rows match, Pano chooses the row with the fewest blank fields, which is the most specific. Ties are not defined by the query; the implementation keeps the first row in database order among the least-blank rows, and that order has no `ORDER BY` (`BlockedMetadataDao.kt:90-124`). Treat tie order as unspecified.

The block check runs before any edit at the start of each pipeline pass, including the optional second pass. A match returns the block action and no edited data, so a simple edit cannot rewrite a blocked track into an allowed one (`ScrobbleEverywhere.kt:96-104`, `ScrobbleEverywhere.kt:224-230`).

### 5.2 Player action

The action is one of ignore, skip or mute. Ignore submits nothing and leaves playback alone. Skip asks the player to move to the next track. Mute asks the player to mute. Skip and mute depend on the player exposing those controls; the scrobble is cancelled either way (`BlockPlayerAction.kt:1-6`, `PlayingTrackNotifyEvents.kt:157-166`).

Blocks require a valid license. Without one, the lookup returns no match (`BlockedMetadataDao.kt:90-98`). The same gate applies to regex block and extract rules. Simple edits, replace rules, presets and first-artist extraction are not gated (`RegexEditsDao.kt:90-91`, `RegexEditsDao.kt:131-151`).

### 5.3 Blocking from the UI

Saving a block from the now-playing UI inserts the lowercased row and immediately cancels the current track with the chosen action (`BlockedMetadataAddDialog.kt:308-341`). The dialog prefills from the currently displayed scrobble data (`PanoNotifications.android.kt:240-252`). If that displayed data has already been rewritten by rules, the saved block can describe values that never appear in the pre-edit data, so the same track may not match on the next play. This is a race between when the notification is opened and when preprocessing finished.

### 5.4 Examples

A row with artist `Podcast Channel` and the other fields blank blocks every track from that artist. A row with artist and track blocks one track. A row with artist, album and track is more specific and wins over the artist-only row. A row with album blank still matches tracks that have an album; it does not mean "no album".

A regex block scoped to one app can block a substring of the title, for example a sponsor segment marker, without blocking the whole artist.

## 6. First-artist extraction

First-artist extraction is opt-in per app. The preference is empty by default; the user selects apps explicitly (`MainPrefs.kt:134`, `ScrobbleEverywhere.kt:166-169`, `PrefsScreen.kt:580-599`). It runs after presets and before the final trim, only when presets were requested, `continueMatching` is still true, and title parsing did not fail (`ScrobbleEverywhere.kt:150-202`).

### 6.1 Algorithm

Pano trims the artist string. It returns the whole string unchanged when the entire string is in its allowlist. Otherwise it finds the earliest occurrence of any delimiter. If none exists, it returns the whole string. If one exists, it scans prefixes up to 1000 characters and keeps the longest prefix that is in the allowlist and is immediately followed by a delimiter or the end of the string. If no prefix qualifies, it returns the text before the earliest delimiter, trimmed (`FirstArtistExtractor.kt:154-255`).

The allowlist is a shipped set of 64-bit hashes of MusicBrainz artist names plus a user-managed list. Both are matched lowercased. The user list is trimmed, lowercased and de-duplicated by the database's case-insensitive unique index (`FirstArtistExtractor.kt:88-150`, `FirstArtistExtractor.kt:159-165`, `ArtistWithDelimiters.kt:9-20`). A candidate is also checked with its first spaced ampersand rewritten as the word "and", so a band allowlisted under the word form is not split on the ampersand (`FirstArtistExtractor.kt:187-197`).

Common delimiters are comma plus space, ideographic comma, Arabic comma, Arabic conjunction, Ethiopic comma, semicolon, spaced ampersand, fullwidth ampersand and spaced slash. The localized word "and" delimiters are added only when `useAnd` is true. `useAnd` is true only when the current app is configured for the fallback title-parse preset (`FirstArtistExtractor.kt:17-86`, `ScrobbleEverywhere.kt:171-188`).

The result replaces the artist. If the old album artist exactly equals the old artist, the album artist is replaced too; otherwise it is left alone (`ScrobbleEverywhere.kt:194-200`). A change sets the presets-applied flag, which can trigger the second pipeline pass.

### 6.2 Examples

`Alpha, Beta` with neither name allowlisted becomes `Alpha`, using the fallback before the comma.

`Known Duo & Guest` where `Known Duo` is allowlisted becomes `Known Duo`, using the longest allowlisted prefix. It does not become `Known Duo & Guest` unless the whole string is allowlisted.

`Known Duo, Wind & Fire` where the whole string is allowlisted stays unchanged, even though it contains a comma. This is how the allowlist protects band names with punctuation.

`Alpha; Beta` and `Alpha、Beta` become `Alpha`. A value with no delimiter is unchanged.

A string that starts with a delimiter after trimming can produce an empty artist, because the fallback takes an empty prefix. For example, a value beginning with a comma and a space. This empty value is not rejected by the pipeline.

The `useAnd` condition is platform-sensitive. On desktop the app id usually is not an Android package name, so the localized "and" delimiters are normally not enabled there. The normalized URL host is not consulted for first-artist extraction.

## 7. Normalization, presets and tag handling

### 7.1 Trim and empty values

The platform adapters trim title, artist, album and album artist as they read them (`MetadataTransforms.android.kt:13-18`, `MetadataTransforms.jvm.kt:30-36`). After all rules, `trimmed()` trims all four text fields and converts an empty album or album artist to null (`ScrobbleData.kt:29-34`, `ScrobbleEverywhere.kt:204-210`).

There is no case folding, Unicode normalization, diacritic folding, punctuation normalization or whitespace collapsing of the final values. Values are submitted in the case the tags and rules produced. Services may still canonicalize or ignore them: the FAQ notes Last.fm's filter for placeholder titles and its legacy artist and track corrections (`faq.md:87-95`).

### 7.2 Sentinel values

Before rules run, Pano applies three fixes (`MetadataUtils.kt:474-493`, applied at `PlayingTrackInfo.kt:169-171`).

Artist exactly equal to the two-letter placeholder `va`, ignoring case, becomes empty. Album and album artist values matching the known unknown-placeholder forms become empty; the set includes plain, bracketed and angle-bracketed variants of unknown, unknown album and unknown artist. Album artist exactly equal to `VA`, ignoring case, becomes the conventional `Various Artists` label. Title is not sanitized.

These checks use English lowercase matching for the unknown set. The only various-artists mapping that runs is the `VA` to conventional-label case; the longer multilingual various-artists list is currently unreferenced (`MetadataUtils.kt:7-18`, `MetadataUtils.kt:21-37`, `MetadataUtils.kt:518`). An artist legitimately named `VA` is therefore dropped.

### 7.3 Built-in presets

Presets are internal replace rules that run after user edits when `continueMatching` is true. They run in this fixed order: title parse, fallback title parse, remastered, single/EP, explicit, album version. Only enabled presets run, and album version is off by default. The default enabled set is title parse, fallback title parse, remastered, explicit and single/EP (`RegexPresets.kt:22-47`, `RegexPresets.kt:58-67`, `RegexPresets.kt:80-95`, `MainPrefs.kt:122`).

When any user edit applied, the two title-parse presets are skipped; the other presets still run (`RegexPresets.kt:58-61`, `RegexPresets.kt:80-82`). On Windows the two title-parse presets are removed from the preset list entirely (`RegexPresets.kt:63-67`).

Title parse applies when the app is in its configured app set, or on non-Windows desktop when the normalized URL host identifies YouTube or YouTube Music (`RegexPresets.kt:63-67`, `RegexPresets.kt:148-155`). It is eligible when the album is empty and the artist does not end with the YouTube topic suffix, or for Yandex Music's placeholder album. It parses artist and title from the video title, clears album and album artist, and on failure without fallback aborts the scrobble with an error instead of submitting (`RegexPresets.kt:156-181`, `ScrobbleQueue.kt:223-238`). The fallback variant leaves the data unchanged when parsing fails. A topic-suffixed artist is shortened by removing the suffix.

The title parser removes leading genre brackets, leading track numbers, music-video markers and Japanese original markers, then tries quoted forms, Japanese bracket forms and a "track by artist" form. It falls back to splitting on an ordered separator list, then to a Japanese bracket form, then to treating the whole string as the title (`MetadataUtils.kt:154-184`, `MetadataUtils.kt:313-362`, `MetadataUtils.kt:387-472`). The separator search returns the first separator in list order, not the earliest separator in the string (`MetadataUtils.kt:313-362`). The extracted track is further cleaned of bracketed suffixes, official/video/audio markers, years, live markers, pipe suffixes, quoted fragments and numeric prefixes; the artist is cleaned of bidirectional marks and numeric prefixes (`MetadataUtils.kt:202-311`, `MetadataUtils.kt:365-383`).

Remastered removes the first remaster marker from the track and from the album, for example a trailing parenthesized remaster year. Explicit and clean remove the first explicit or clean marker from the track and album, and also remove a single leading or trailing enclosed-E style marker when whitespace separates it from the text (`RegexPresets.kt:184-220`, `RegexPresets.kt:257-294`, `RegexPresets.kt:324-336`). Single/EP removes a trailing single or EP designation from the album, but only for Apple Music, iTunes on Windows and the Apple Music URL host (`RegexPresets.kt:222-255`). Album version removes an album-version marker from the track and is off by default (`RegexPresets.kt:296-317`).

These presets run for all apps unless they have an app or host condition. A Spotify scrobble with a remaster marker in the title is therefore shortened by default.

### 7.4 Album fill after rules

A missing album can be filled after all rules, but only when the global album-fetch preference is on and the album is still empty. The normal path is blocked if any simple or regex edit applied. A regex replace rule can opt back in with its fetch-album flag (`ScrobbleEverywhere.kt:44-46`, `ScrobbleQueue.kt:243-254`).

Pano first checks its local seen-album cache for the artist and track, then asks Last.fm. The Last.fm path can also supply the album artist, and it can remove a trailing single designation from the fetched album name (`ScrobbleEverywhere.kt:402-485`). This lookup uses the post-rule artist and track, so rules that rename an artist can prevent a cache hit.

The album-fetch preference defaults off (`MainPrefs.kt:62`).

### 7.5 Tag handling summary

Pano reads the four text tags, duration, track number and art URL from the OS media session. It submits the four text tags plus duration and timestamp. Track number is read but never copied into the submitted object. Art URL is UI-only. Genre, year, composer, comments, embedded artwork and MusicBrainz identifiers are not part of the scrobble payload (`ScrobbleData.kt:8-17`, `PlayingTrackInfo.kt:212-220`, `Lastfm.kt:80-110`, `Pleroma.kt:56-65`).

Album artist is a separate submitted tag and is not inferred from artist. When absent it stays absent; the display conversion falls back to artist, but the wire payload does not (`ScrobbleData.kt:20-27`).

Platform adapters repair known-bad tags before rules. Android handles Pandora prefixes, Podcast Addict, Sonos composer and combined fields, Difm and Huawei field fixups, Yandex and Spotify extra markers, Nintendo's empty artist, Apple Music Classical's album-artist-as-artist, and Telegram voice messages as ignore-worthy (`MetadataTransforms.android.kt:34-137`). Desktop Windows splits Apple Music's malformed combined artist field on an em dash and treats the second part as the album (`MetadataTransforms.jvm.kt:48-60`). These fixes are source-specific and would not automatically apply to a clean media helper on macOS.

## 8. Surfaces: now playing, scrobble, history

### 8.1 Now playing and the scrobble

Pipeline output is computed once per track and stored on the in-memory track object. Both the now-playing submission and the later scrobble use it (`ScrobbleQueue.kt:195-203`, `ScrobbleQueue.kt:256-276`, `PlayingTrackInfo.kt:235-250`). With now-playing disabled, rules affect only the scrobble. With the track blocked, neither is sent. With a title-parse failure, neither is sent and an error is shown (`ScrobbleQueue.kt:212-238`).

If additional metadata has to be fetched again before scrobbling, now playing uses the current preprocessed data, while the late scrobble reruns metadata fetch and preprocessing (`ScrobbleQueue.kt:195-203`, `ScrobbleQueue.kt:205-210`). The two submissions can therefore differ when a service returns different metadata between them.

### 8.2 Live history edit

The history screen reads from the active service, not from a local scrobble log. Editing is offered for Last.fm, ListenBrainz and Libre.fm, and not for File or Pleroma accounts (`ScrobblesScreen.kt:142-147`). A history row supplies track, artist, album and timestamp; album artist and duration are null because the recent-tracks payload does not carry them (`ScrobblesReusables.kt:656-668`).

The edit dialog is prefilled with the displayed values as replacements and the original values as match fields (`PanoModalNavGraph.kt:155-175`). Applying it runs one simple edit, not the regex, block, preset or first-artist pipeline (`EditScrobbleUtils.kt:47-63`). The simple edit is applied unconditionally; the match fields are not rechecked against the scrobble. They exist only for the rule that may be saved for future tracks (`SimpleEditsDao.kt:68-77`, `EditScrobbleUtils.kt:56-58`).

The edit path trims both sides, requires non-empty track and artist, rejects a no-change edit, and offers to fetch a missing album when both old and new albums are empty and the preference is on (`EditScrobbleUtils.kt:108-176`). It then submits the new scrobble to the currently selected account only, deletes the original scrobble, and optionally scrobbles one more time when the track and artist are unchanged but the album changed or an album artist was supplied (`EditScrobbleUtils.kt:128-131`, `EditScrobbleUtils.kt:141`, `EditScrobbleUtils.kt:178-195`, `Scrobblable.kt:200-202`).

That extra scrobble is a duplicate risk. The normal sequence is submit, delete, then submit again. Deletion errors other than invalidated Last.fm cookies are ignored (`EditScrobbleUtils.kt:183-189`).

The 14-day Last.fm limit applies. If the service ignores a scrobble older than 14 days and the save option is on, Pano saves the rule for future tracks and reports that the edit could not be applied (`EditScrobbleUtils.kt:82-93`, `Stuff.kt:81`, `faq.md:57-60`). On success the edited row is pushed back to the UI list (`EditScrobbleUtils.kt:78-80`).

A rule is saved only after a successful edit, unless the old-scrobble branch above fires (`EditScrobbleUtils.kt:64-68`, `EditScrobbleUtils.kt:82-93`). The save option defaults on (`SimpleEditsAddScreen.kt:123`).

### 8.3 Edit from the now-playing notification

This uses the same single-edit path with a track hash. On success Pano submits a scrobble immediately, updates now playing, marks the track locked as scrobbled and removes the queued scrobble (`EditScrobbleUtils.kt:47-76`, `PlayingTrackNotifyEvents.kt:181-205`). The queued scrobble is cancelled so the immediate submission is not duplicated.

The route now carries both the displayed data and the original data. Replacements start from the displayed data, which may already include pipeline output, while match fields use the original (`PanoRoute.kt:348-355`, `PanoModalNavGraph.kt:155-175`, `PanoNotifications.android.kt:208-212`). The one-off application still does not verify those match fields.

If the edit is saved, the rule uses the displayed values as replacements, so it can pin the current pipeline result for future tracks. If the edit is not saved, only the immediate scrobble changes.

### 8.4 Pending retries and local stores

Pano has no local table of successfully submitted scrobbles. Its database holds pending scrobbles, edit rules, block rules, source records, seen-track and seen-album caches, and custom mappings (`PanoDb.kt:11-22`). History comes from the service or the File backend.

When a submission fails, Pano stores the post-edit scrobble in the pending queue (`ScrobbleEverywhere.kt:286-324`). Retries submit the stored values unchanged and never rerun the pipeline (`PendingScrobblesWorker.kt:57-95`). A rule added later does not revise already queued scrobbles.

The seen-track cache is updated with the post-edit artist, track and album when the album is non-empty (`ScrobbleEverywhere.kt:331-340`). The scrobble-source record uses the post-edit timestamp and app id (`ScrobbleEverywhere.kt:289-298`).

The File backend writes an append-only log. Its delete operation does nothing, so any edit path that reached it would add a corrected entry and leave the original in place (`FileScrobblable.kt:124-126`). The normal history UI does not offer editing for File accounts.

### 8.5 Surface matrix

| Behaviour | Now playing | Scrobble | Live history edit | Pending retry |
| --- | --- | --- | --- | --- |
| Simple edits | yes | yes | one rule only, unconditional | already applied |
| Regex replace or extract | yes | yes | no | already applied |
| Metadata block list | yes, cancels both | yes | no | no |
| Regex block | yes, cancels both | yes | no | no |
| Presets | yes | yes | no | already applied |
| First artist | yes | yes | no | already applied |
| Sentinel cleanup | yes | yes | no, raw values are passed in | already applied |
| Album fill | yes, after rules | yes, after rules | yes, when both albums empty and pref on | no |

## 9. End-to-end ordering and chaining

The complete order is:

1. Read and trim platform tags.
2. Apply source-specific tag repairs.
3. Apply sentinel cleanup to artist, album and album artist.
4. Replace metadata from Deezer or TIDAL on Windows when configured.
5. Check the metadata block list.
6. Run all matching simple edits in specificity order.
7. If `continueMatching`, run regex edits in order until a block or a break.
8. If `continueMatching`, run simple edits again on the regex output.
9. If `continueMatching`, run enabled presets in fixed order, then first-artist extraction.
10. Trim and null empty album and album artist.
11. If no user edit applied and presets or first artist changed something, repeat steps 5 to 8 once.
12. Fill a missing album if eligible.
13. Look up loved state and submit now playing and the scrobble.

Chaining rules:

| Pair | Chains |
| --- | --- |
| Simple to simple | yes, per-field claim across every match |
| Simple to regex | yes, unless a simple rule turns `continueMatching` off |
| Regex to regex | yes, in order; a break or block stops later rules |
| Regex to simple | yes, the second simple pass |
| Simple or regex to preset | yes, unless `continueMatching` is off |
| Preset to simple | only through the optional second pass, and only when no user edit had applied before the preset |
| Preset to first artist | yes |
| First artist to second pass | yes, first-artist changes count as preset changes |
| Any rule to live history edit | no |
| Any rule to pending retry | no |

Precedence between types:

1. Metadata block list wins over everything.
2. Simple edits run before regex edits, but regex edits can overwrite their output.
3. Regex block wins over earlier regex replacements and cancels the track.
4. The second simple pass can overwrite regex output.
5. Presets run after user edits but cannot run when `continueMatching` is off.
6. First artist runs last and can shorten any artist produced earlier.
7. Album fill runs after all rules and can add an album but does not overwrite one.

The title-parse presets are the one place where user edits beat presets outright: any user edit suppresses them, while the other presets still run.

## 10. Misses, empty output and failures

| Situation | Result |
| --- | --- |
| Simple rule matches nothing | Pipeline unchanged; later phases run |
| Simple rule matches but no replacement applies | Counted as an edit; `continueMatching` can stop later phases |
| Simple rule enables an empty album or album artist | Field is cleared |
| Simple rule enables an empty track or artist | Replacement has no effect; validation normally prevents this |
| Regex rule matches nothing | Pipeline unchanged |
| Regex replace produces empty track or artist | Whole rule discarded; earlier data survives |
| Regex replace produces empty album or album artist | Field becomes null |
| Regex replace produces whitespace-only track or artist | Accepted, then trimmed to empty |
| Regex extract lacks a required named group | No change; not counted as applied |
| Regex extract lacks an album group | Album becomes null |
| Regex pattern fails to compile | Treated as no match |
| Regex block matches | No data; scrobble cancelled |
| Regex block matches without a license | No block; may still break the regex loop |
| Block-list row matches | No edits; now playing and scrobble cancelled |
| Block-list tie | Unspecified row order among equally specific rows |
| First artist finds no delimiter | Artist unchanged |
| First artist starts with a delimiter | Artist can become empty |
| Title parse fails without fallback | Whole scrobble aborts with an error |
| Title parse fails with fallback | Data unchanged |
| History edit has empty track or artist | Rejected before submission |
| History edit changes nothing | Rejected as no change |
| History edit is too old for Last.fm | Optional rule save, edit fails |
| Album fill finds nothing | Album stays empty |

## 11. Ambiguities and bugs

These are behaviours that a parity implementation must either reproduce or consciously correct.

1. Simple `continueMatching` does not stop lower-specificity simple edits in the same pass. Only later phases stop.
2. Regex `continueMatching` breaks on a match even when the rule produced no output, but that break does not necessarily stop later phases.
3. An unlicensed block or extract rule can still break the regex loop while doing nothing.
4. Replacement transforms every field even when that field's search pattern is empty. A non-empty replacement with an empty search inserts text.
5. Regex matching is substring search. Full-field matching requires explicit anchors.
6. Extraction clears album and album artist unless their groups are captured.
7. New regex rules use order -1, so they run before older rules until the list is dragged. Equal orders have no specified tie-break.
8. Block-list tie order is not defined by a query order.
9. Simple match values are lowercased but not trimmed; block values are lowercased but not trimmed. Trailing spaces in a rule can prevent a match. Current values are trimmed at platform extraction and again after rules, but a regex can introduce spaces before the second simple pass.
10. Live history edit applies its replacement without checking the match fields.
11. History edit always submits before deleting. It can duplicate a scrobble when the track and artist are unchanged and the album changed or an album artist was supplied.
12. History edit only touches the currently selected account, while normal scrobbles go to every connected account.
13. History edit is unavailable for File and Pleroma. The File backend's delete is a no-op anyway.
14. A block saved from the now-playing UI can encode post-edit values and then fail to match the raw values on the next play.
15. Any user edit suppresses album fill unless a regex replacement opts in.
16. A matching but no-op simple edit still counts as a user edit and can suppress title parsing and the second pass.
17. Title-parse presets are skipped on Windows and skipped whenever any user edit applied.
18. On desktop, first-artist extraction normally does not enable the localized "and" delimiters because `useAnd` depends on Android package ids, not URL hosts.
19. The metadata block list cannot express "album is empty"; a blank field is a wildcard.
20. Sentinel cleanup can drop an artist whose real name is `VA`.
21. Extraction and replacement can produce an empty artist after the final trim; the pipeline does not validate artist before submission.
22. `trackNumber` is read from the platform but never reaches the submitted object.
23. Last.fm can canonicalize or ignore submitted values after Pano finishes. The FAQ documents this for placeholder titles and legacy corrections.
24. Album-fetch requests can be throttled and return a "fetch again" result. The album-guess path does not propagate that retry into the scrobble path.
25. The simple edit screen's no-change validation does not reliably fire after its text-field migration. The service-side no-change check in `EditScrobbleUtils` still catches equal values when applying to an existing scrobble, but a no-op rule can be saved from the rule editor.

## 12. Platform-specific behaviour

Android reads `MediaMetadata`, including album artist, artist, album, title, track number and duration, and uses package names as app ids (`MetadataTransforms.android.kt:9-22`). Title-parse presets use Android package sets. First-artist `useAnd` uses those same package sets. Skip and mute actions go through the Android player controls. The regex engine is the JVM one.

Windows reads SMTC metadata. Deezer and TIDAL can be enriched from their APIs before rules (`ScrobbleEverywhere.kt:246-276`). Apple Music on Windows has a malformed combined artist field split on an em dash (`MetadataTransforms.jvm.kt:48-60`). Title-parse presets are disabled on Windows (`RegexPresets.kt:63-67`). Single/EP recognises Apple Music and iTunes SMTC app ids (`RegexPresets.kt:222-255`).

Linux reads MPRIS. The preset app-id settings are ignored and the normalized URL host is used instead (`RegexPresets.kt:49-56`, `RegexPresets.kt:148-155`). This matters mainly for browser playback.

macOS through a Droppy media helper would look like the desktop path, but the helper's bundle id is not an Android package name and it probably does not provide a URL host. That makes app-scoped regex rules and URL-host title parsing hard to carry over directly. The Kotlin desktop path is not a native macOS metadata implementation; the frozen Swift port is a separate behaviour reference.

Regex syntax is JVM `java.util.regex`, including Java named-group syntax and `$n` replacement templates. Extract rules also require the JVM feature check (`RegexEditsDao.kt:141`). A Swift implementation using ICU regular expressions will differ in named-group syntax, replacement templates, Unicode case folding and some character classes.

The license checks on block, extract and regex-block are product gates, not metadata semantics. A parity implementation can keep them, drop them, or replace them with its own entitlement model.

## 13. Open decisions for the droplet

Pano gives no precedent for a local authoritative scrobble history, because it has none. The droplet's local SQLite is a new decision. Two options follow from Pano's behaviour.

Store only the submitted values. This matches the pending queue and the service history, and makes retries and display trivial. It loses the raw input, so a newly added rule cannot be replayed against past scrobbles.

Store raw input plus submitted output and the rule revision that produced it. This preserves replay and audit, and lets the user re-run rules over history without guessing. It costs a schema and a migration story.

The same choice applies to now playing. Pano shows the post-rule values but keeps the pre-rule values in memory for the edit dialog. A droplet that keeps both can reproduce that dialog exactly.

Three smaller decisions are needed. Whether to keep Pano's license gates. Whether to reproduce the duplicate-scrobble path in history editing or replace it with an in-place service edit. Whether to ship a MusicBrainz-derived allowlist for first-artist extraction, since its behaviour depends on the asset version and a Swift hash implementation.

## Sources

Base URL for all paths: `https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/`.

| Short name | Path |
| --- | --- |
| `ScrobbleEverywhere.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/ScrobbleEverywhere.kt` |
| `ScrobbleData.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/ScrobbleData.kt` |
| `Lastfm.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/Lastfm.kt` |
| `Pleroma.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/pleroma/Pleroma.kt` |
| `FileScrobblable.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/file/FileScrobblable.kt` |
| `Scrobblable.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/api/Scrobblable.kt` |
| `SimpleEdit.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/SimpleEdit.kt` |
| `SimpleEditsDao.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/SimpleEditsDao.kt` |
| `RegexEdit.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/RegexEdit.kt` |
| `RegexEditsDao.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/RegexEditsDao.kt` |
| `RegexMode.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/RegexMode.kt` |
| `BlockedMetadata.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/BlockedMetadata.kt` |
| `BlockedMetadataDao.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/BlockedMetadataDao.kt` |
| `BlockPlayerAction.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/BlockPlayerAction.kt` |
| `PanoDb.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/PanoDb.kt` |
| `ArtistWithDelimiters.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/db/ArtistWithDelimiters.kt` |
| `PlayingTrackInfo.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/PlayingTrackInfo.kt` |
| `ScrobbleQueue.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/ScrobbleQueue.kt` |
| `PlayingTrackNotifyEvents.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/PlayingTrackNotifyEvents.kt` |
| `MediaInfoStructs.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/media/MediaInfoStructs.kt` |
| `EditScrobbleUtils.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/edits/EditScrobbleUtils.kt` |
| `SimpleEditsAddScreen.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/edits/SimpleEditsAddScreen.kt` |
| `RegexEditsAddScreen.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/edits/RegexEditsAddScreen.kt` |
| `RegexEditsScreen.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/edits/RegexEditsScreen.kt` |
| `RegexPresets.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/edits/RegexPresets.kt` |
| `BlockedMetadataAddDialog.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/edits/BlockedMetadataAddDialog.kt` |
| `FirstArtistExtractor.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/utils/FirstArtistExtractor.kt` |
| `MetadataUtils.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/utils/MetadataUtils.kt` |
| `MainPrefs.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/MainPrefs.kt` |
| `PrefsScreen.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/pref/PrefsScreen.kt` |
| `Stuff.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/utils/Stuff.kt` |
| `ScrobblesReusables.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/recents/ScrobblesReusables.kt` |
| `ScrobblesScreen.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/recents/ScrobblesScreen.kt` |
| `PanoRoute.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/navigation/PanoRoute.kt` |
| `PanoModalNavGraph.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/navigation/PanoModalNavGraph.kt` |
| `PendingScrobblesWorker.kt` | `composeApp/src/commonMain/kotlin/com/arn/scrobble/work/PendingScrobblesWorker.kt` |
| `MetadataTransforms.android.kt` | `composeApp/src/androidMain/kotlin/com/arn/scrobble/media/MetadataTransforms.android.kt` |
| `MetadataTransforms.jvm.kt` | `composeApp/src/jvmMain/kotlin/com/arn/scrobble/media/MetadataTransforms.jvm.kt` |
| `PanoNotifications.android.kt` | `composeApp/src/androidMain/kotlin/com/arn/scrobble/utils/PanoNotifications.android.kt` |
| `faq.md` | `faq.md` |
