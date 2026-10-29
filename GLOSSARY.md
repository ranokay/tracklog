# Glossary

## Connection

One authenticated identity at one service endpoint: a service kind, the endpoint it talks to, and the account identifier the service reports. A person can have several connections, but never two on the same endpoint.

## Service kind

The protocol family a connection speaks: Last.fm, Libre.fm/GNU FM, ListenBrainz, or Pleroma. One kind can have several endpoints — a GNU FM root, a custom ListenBrainz-compatible server.

## App credentials

The Last.fm application's API key and shared secret, which sign every request. Tracklog compiles in the project's own public pair; a listener may save an override in the Keychain, and the override takes precedence. The pair is never shown back, written to the database, logged or exported. Changing it invalidates every Last.fm session, so every Last.fm connection becomes needs sign-in and its pending deliveries are held until it reconnects.

## Identity

The account identifier a service reports — a Last.fm, Libre.fm or ListenBrainz username, a Pleroma account id — scoped to the endpoint. Re-signing in with the same identity resumes a paused connection; a different identity replaces it.

## Current connection

The connection service-backed reads are scoped to: charts, friends, profile, tags, collage top items and service search. A read cursor only; it never decides where a scrobble goes, and local history is not scoped to it.

## Listen

One play of one track, identified by the track's identity and the time it started. A listen fans out to delivery targets, or to none.

## Scrobble

One listen's delivery to one connection: the unit the UI counts when it says "12 scrobbles waiting". A listen with three delivery targets is three scrobbles; a listen with none is still a listen, but no scrobble.

## Delivery target

A connection a listen was headed for when it was captured. A listen fans out to every enabled connection, so it has several targets, or none.

## Pending delivery

One listen headed for one connection. Its states are waiting, retrying, delivered and abandoned.

## Enabled / paused

The per-connection switch. Paused stops now-playing and holds that connection's pending deliveries. It does not unlink or discard anything.

## Needs sign-in

A connection whose credentials the service rejected. It keeps its identity, holds its pending deliveries, and resumes them when the same identity signs in again.

## Abandoned

A pending delivery that will not be delivered: its connection was explicitly unlinked, or the service permanently rejected the listen. The listen remains in local history, marked as not delivered to that service.

## Repeat and duplicate

A repeat is a new play of a track that already played, and is scrobbled again. A duplicate is one play recorded twice, and is suppressed by track identity and the play's start time.

## Chart source

Where a statistics view reads from: the current connection's service history, or this Mac's local history. A view names its source; local is the fallback where the connection has no statistics API or the range is custom.

## Friend

A person whose listening the current connection makes visible, such as a Last.fm friend or a ListenBrainz follow. Friends are scoped to one connection and never merged across connections.

## Player

An app that owns playback and appears in the media feed, identified by its bundle identifier. Music and Spotify are allowed at first run; every other player is denied until the user allows it on the Apps page. A player is not a media source: one media source observes whichever player is active.

## Media source

The adapter currently supplying playback observations: Droppy's media helper, or Automation for Music or Spotify when the helper cannot see the player. One source speaks at a time, and the helper is authoritative wherever it does.

## Local history

The authoritative record of listens on this Mac. Global and independent of connections: every listen survives unlink, is exportable, and can exist with no delivery target.

## Simple edit

A saved metadata rule with four optional match fields and four optional replacements. An inactive match field is a wildcard; every active one must equal the listen's current value, case-insensitively and trimmed. Matching rules merge replacements field by field, most specific first and then newest first. An inactive replacement leaves the field alone; an empty album or album artist replacement clears it. Local history keeps the values each listen was captured with.

## Block

A saved cancellation rule with four fields: track, artist, album and album artist. A blank field is a wildcard, and a block with all four blank is refused. Matching is full-field, case-insensitively and trimmed, after sentinel cleanup and before any simple edit, so an edit cannot rewrite a blocked track into an allowed one. A match cancels the listen: no now playing, no history row and no delivery. Existing history keeps its rows; a block applies to future plays.

## Cancelled listen

The in-flight listen the user suppressed before it scrobbled. Cancel keeps the session's played time and threshold, suppresses its scrobble and history row until the track changes or restarts, and leaves an already-sent now playing alone. Undo re-enables it from the same played time. Once the threshold fires there is nothing left to cancel, so the control is hidden.

## Artwork

The cover shown with the current track and with each listen in History. It comes from the bytes the media helper embeds in its now-playing answer; Tracklog never searches a network for it. One lookup happens when the track identity changes, the image is downscaled on its long edge, and the result is named by a content hash so the same cover is stored once and reused by later listens and launches. Artwork is best effort: a lookup, decode or write failure never delays a scrobble.

## Neutral sleeve

The stand-in drawn when a listen has no artwork, the lookup failed, or the track came through Automation. Its note glyph and weight are derived from the track identity, so the same track always gets the same sleeve and two tracks do not look accidentally identical.
