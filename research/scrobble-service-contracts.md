# Scrobbling service contracts

Research for [issue #5](https://github.com/ranokay/pano-scrobbler-droppy/issues/5). Scope: what a clean-room MIT Droppy droplet must implement to scrobble to Last.fm, Libre.fm, ListenBrainz and Pleroma, plus Discord Rich Presence over local IPC.

- **Date:** 2026-10-24
- **Method:** primary documentation and first-party source only. Pano Scrobbler and GNU FM were inspected read-only at the commits below to establish actual client behaviour; no code was copied.
- **Pano revision:** [`9901540`](https://github.com/kawaiiDango/pano-scrobbler/tree/990154031e761b8e5460a0585fc834b43c9e2d71)
- **Pano native components:** [`2589a4d`](https://github.com/kawaiiDango/pano-native-components/tree/2589a4d3831b47b87404e300588dfa8292b84e0c)
- **GNU FM (Libre.fm server) revision:** [`25cf883`](https://github.com/foocorp/gnu-fm/tree/25cf8834b66cb4922d51c6fa85ff8556bc361d54)

## Short answer

| Service | Contract in one line | Credential owner | Delete / edit |
| --- | --- | --- | --- |
| **Last.fm** | Full baseline: now playing, scrobble (batch 50), love/unlove, recent/loved reads. Browser token auth. | Deployment owner holds API key + shared secret; each user holds a session key. | No edit. No delete API; website only. |
| **Libre.fm** | Last.fm-shaped GNU FM API: now playing, single scrobble, love/unlove, recent/loved reads, plus `library.removeScrobble`. | Project/deployment owns a 32-char client key. No separate secret in GNU FM. | Delete yes; edit no. |
| **ListenBrainz** | Modern token API: playing-now, single/import listens, love/hate feedback, delete-listen, recent reads. | End user owns a token; no app registration. | Delete yes; edit no. |
| **Pleroma** | Deprecated “Listen” activity: one-way scrobble plus a recent-scrobbles read. No now playing, love or delete. | Per-instance OAuth app created at runtime; user owns the token. | No edit; no scrobble delete. |
| **Discord RPC** | Presence only. Local IPC, no OAuth needed for basic presence, public Application ID. | Project owns the Application ID; it is not a secret. | Clear activity on stop. |

**Two decisions that matter before implementation:**

1. **Do not ship a Last.fm shared secret in the MIT repository.** The protocol allows a client to embed one, but the secret signs every call on behalf of the app; publishing it makes it a shared public credential. The API terms do not expressly permit redistribution, and Last.fm can suspend the key at its discretion. Require the droplet owner to register a Last.fm API account and keep the key/secret in Keychain or deployment config, as Navidrome now does.
2. **A Libre.fm client key *can* ship.** In the final GNU FM release the API key is a length-checked identifier, not a signing secret; authentication is carried by the session key. Register a proper key/client code with Libre.fm, embed it as a client identifier, and keep the user’s session key in Keychain.

This is an engineering and risk reading of the published terms, not legal advice.

## Parity model

“Parity” here means feature parity at the adapter boundary, not identical server behaviour. Droppy should model **capabilities**, not assume four identical Last.fm clones:

| Capability | Last.fm | Libre.fm | ListenBrainz | Pleroma |
| --- | --- | --- | --- | --- |
| Now playing | Yes, optional, never retried | Yes | Yes (`playing_now`) | **No** |
| Scrobble | Yes, up to 50/request | Yes, one per request | Yes, up to 1000/request | Yes, one per request |
| Delayed/offline cache | Yes, resend in order | Yes | Yes, `import` type | Best effort |
| Love | Yes | Yes | Yes (`score: 1`) | **No** |
| Hate / reset feedback | No | No | Yes (`-1`, `0`) | **No** |
| Read recent history | Yes | Yes | Yes | Yes (public endpoint) |
| Edit scrobble | **No** | **No** | **No** | **No** |
| Delete scrobble | **No API** | Yes (`library.removeScrobble`) | Yes (`/1/delete-listen`) | **No** |
| Backfill/import | Not a documented bulk path | No | Yes (`import`) | No |
| Auth | Browser token → session key | Browser token → session key, or legacy mobile auth | User token | OAuth app + user token |
| App credential | API key + **shared secret** | 32-char client key (+ client code) | None | Per-instance `client_id`/`client_secret` |

Suggested UI labels:

- **Last.fm:** “Full support.”
- **Libre.fm:** “Last.fm-compatible; single scrobbles; delete supported.”
- **ListenBrainz:** “Full support; token only; import supported.”
- **Pleroma:** “Experimental; upstream deprecated scrobbling.”
- **Discord:** “Presence only; no scrobbling.”

## Last.fm

### Authentication flows available to a desktop client

Last.fm documents three paths; the **desktop token flow** is the right one for Droppy ([desktop how-to](https://www.last.fm/api/desktopauth), [auth spec](https://www.last.fm/api/authspec)).

**Desktop token flow (recommended)**

1. The app is registered as a Last.fm API account. It receives a 32-character **API key** and a **shared secret**, and configures an application name, description, optional logo and a callback URL. The callback URL is not used by the desktop flow, but is part of the account setup.
2. `auth.getToken` is called with `api_key` and `api_sig`. The token is single-use and valid for 60 minutes.
3. The app opens the system browser at `https://www.last.fm/api/auth/?api_key=…&token=…`. The user logs in (if needed) and grants the application access.
4. `auth.getSession` is called with `api_key`, `token` and `api_sig`; it returns a **session key**.
5. Subsequent write calls send `sk`, `api_key` and `api_sig`. Session keys have an infinite lifetime by default and can be revoked by the user on Last.fm’s application settings page.

Every signed call is `md5` over the alphabetically sorted `<name><value>` parameter string plus the shared secret; `format` and `callback` are excluded ([auth spec §8](https://www.last.fm/api/authspec)). The MD5 construction is the protocol; do not treat it as a security choice.

**Mobile flow (available, not recommended)**

`auth.getMobileSession` accepts the user’s username and **plaintext password** plus `api_key` and `api_sig`, and must be a POST over HTTPS ([auth spec §5](https://www.last.fm/api/authspec)). It still requires the shared secret, so it does not avoid the credential-ownership problem, and it makes Droppy handle the user’s Last.fm password. Prefer the browser flow.

**Web flow** is for callback-based web apps and is not relevant to a local droplet.

### Now-playing, scrobble and loved endpoints

All write calls are HTTP POST to `https://ws.audioscrobbler.com/2.0/` with form-urlencoded UTF-8 parameters ([REST notes](https://www.last.fm/api/rest)).

| Purpose | Method | Notes |
| --- | --- | --- |
| Now playing | `track.updateNowPlaying` | Optional; artist, track, optional album/trackNumber/mbid/duration/albumArtist. Failures should **not** be retried. |
| Scrobble | `track.scrobble` | Batch up to **50**; each entry needs artist, track, UNIX timestamp (UTC); optional album, trackNumber, mbid, albumArtist, duration, chosenByUser. |
| Love | `track.love` | Artist + track + auth. |
| Unlove | `track.unlove` | Artist + track + auth. |
| Recent listens | `user.getRecentTracks` | Read path; includes a now-playing entry when present. |
| Loved tracks | `user.getLovedTracks` | Read path. |

Scrobble rules ([Scrobbling 2.0](https://www.last.fm/api/scrobbling)):

- Track must be longer than 30 seconds.
- Played for at least half its duration, or 4 minutes, whichever comes first.
- Send now playing when playback starts; send the scrobble when the threshold is met (often at track end).
- Cache failed scrobbles across restarts and resend in order, batching up to 50.
- Retry only error `11` (service offline) and `16` (temporarily unavailable); re-authenticate on `9` (invalid session key). Do not retry other errors unchanged ([error codes](https://www.last.fm/api/errorcodes)).

### Rate limits

Last.fm does **not** publish a numeric requests-per-second quota. The constraints are:

- Be “reasonable”; continuous “several calls per second” or excessive calls can suspend the account ([API introduction](https://www.last.fm/api/intro)).
- The API terms reserve the right to set and enforce limits in their sole discretion, and prohibit circumventing them ([ToS §4.4](https://www.last.fm/api/tos)).
- Rate-limit failures surface as error `29` (“Your IP has made too many requests in a short period”).
- A suspended key surfaces as error `26`; the application is not allowed to make requests.
- Use an identifiable `User-Agent`, batch scrobbles, and back off on `29`.

Practical client budget: one request at a time, batch up to 50 scrobbles, and do not poll recents more than needed. Last.fm also imposes a **100 MB** cap on stored Last.fm Data ([ToS §4.3.4](https://www.last.fm/api/tos)), so do not build a local Last.fm metadata warehouse.

### Required application credentials and who must own them

| Credential | Issued to | Storage | Notes |
| --- | --- | --- | --- |
| API key | Developer/API account | Deployment config or Keychain | Identifies the application; appears in requests. |
| Shared secret | Developer/API account | Deployment config or Keychain; **never git** | Signs every call; compromise affects all users of that key. |
| Session key | Each user | Keychain, per account | Infinite until revoked; handle error `9` by re-auth. |

Last.fm’s docs say each API account page contains “an API key and secret; you will need both” ([authentication](https://www.last.fm/api/authentication)). The key is tied to the application identity (name, description, logo), not to an end user.

For a self-hosted droplet, the clean ownership model is:

- **Droplet owner** registers one Last.fm API account and supplies key + secret during setup.
- **Each Droppy user** authorizes their own Last.fm account and gets a session key in Keychain.
- The secret is app-level, not per-user; it must not be copied into the repository, logs, crash reports or exported diagnostics.

The alternative — every end user registers their own Last.fm API account — is technically possible but high-friction and not the documented model. The other alternative — one project-owned key embedded in the app — is the risky one discussed next.

### Can a Last.fm API key and shared secret ship inside an open client?

**Technically yes. As a shared project secret, no.**

What the terms actually say:

- The API account is issued to “You”; Last.fm “will provide You with an API key” and you may only use the APIs with the most recent user authentication key it provides ([ToS §2.6](https://www.last.fm/api/tos)).
- Use is limited to **non-commercial** purposes unless a commercial agreement is in place ([ToS §3.1–3.2](https://www.last.fm/api/tos)).
- Last.fm sets and enforces rate limits in its sole discretion and prohibits circumvention ([ToS §4.4](https://www.last.fm/api/tos)).
- Last.fm may terminate or suspend access at any time, with or without cause ([ToS §9.2](https://www.last.fm/api/tos)).
- The terms require credit/linking to Last.fm when Last.fm Data is displayed ([ToS §2.7, §4.2.2](https://www.last.fm/api/tos)).
- There is **no explicit clause** saying “do not disclose your shared secret”. There is also no clause granting permission to redistribute it.

Why that still means “do not ship it”:

- The shared secret is the app’s signing credential. In an open repository it is public by definition; anyone can compute `api_sig` as the app, mint sessions and consume the app’s quota.
- Abuse is charged to the app’s key. Last.fm can suspend the key (error `26`), which breaks every user at once, and rotation is not self-service in the normal case.
- The key is issued to the developer who accepted the terms, not to anonymous downstream users. Redistribution lets third parties use the API under that identity without accepting the terms.
- Last.fm’s own GPL desktop client contains fallback API key/secret values in source ([lastfm-desktop `UnicornCoreApplication.cpp`](https://github.com/lastfm/lastfm-desktop/blob/9ae84cf4ab204a92e6953abe14026df70c140519/lib/unicorn/UnicornCoreApplication.cpp)), which shows the protocol permits embedding. It does not establish that third-party redistribution is permitted or safe.
- Pano Scrobbler does embed credentials in its binaries, but deliberately **gitignores them from the repository** and the maintainer acknowledges they can be extracted from an APK ([Pano issue #527](https://github.com/kawaiiDango/pano-scrobbler/issues/527)). That is “shipped in a binary”, not “published as a shared secret in an MIT repo”.
- Navidrome removed its shared Last.fm key and now requires each deployment to create its own key/secret, citing security, best practices and terms compliance ([Navidrome integration docs](https://www.navidrome.org/docs/usage/integration/external-services/), [v0.51.0 release](https://github.com/navidrome/navidrome/releases/tag/v0.51.0)).

**Recommendation:** Droppy ships **neither the Last.fm shared secret nor a project-wide API key**. The key alone cannot sign calls, but it still identifies the app and is rate-limited, so publishing it has no upside. On first run, the droplet owner creates a Last.fm API account and enters key + secret; store them in Keychain (or deployment environment), sign locally, and never log them. If a future hosted product wants zero-config, put the secret behind a server-side signing broker; do not put it in the MIT client.

### Edit and delete support

- **Edit:** no API method. There is no `track.edit` or equivalent. Droppy should not offer “edit scrobble” for Last.fm.
- **Delete:** the API method was removed. Last.fm Support states: “It used to be possible to delete scrobbles via the Last.fm API, however the relevant API call has since been removed” ([Last.fm Support](https://support.last.fm/t/how-do-i-delete-an-artist-album-track-or-scrobble-from-my-library/213)). Deletion is website-only, one scrobble at a time (bulk delete exists for artists/albums/tracks in the web library).
- Pano implements delete through its own unscrobbler path rather than the public API; it needs a Last.fm **web session cookie and CSRF token**, not just the API session key ([`Lastfm.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/Lastfm.kt)). That is a website-session workaround, not a supported API contract. Do not depend on it for a clean-room client.
- Love/unlove **is** supported and is the only per-track state mutation available.

### What parity means for Last.fm

Parity = the baseline experience:

- Start now playing when playback starts (best effort, no retry).
- Scrobble at the half/4-minute threshold, with a durable offline queue and 50-per-batch resend.
- Love/unlove from the player.
- Show recent listens and loved tracks by reading the public user endpoints.
- Surface a “delete on Last.fm” link instead of pretending delete is available.
- Explain the one-time API account setup to the droplet owner; do not bury it.

## Libre.fm

### What it is

Libre.fm is the largest installation of **GNU FM**, the AGPL scrobbling server. Its developer documentation says the underlying code rarely changes from the final GNU FM release and gives the compatibility mapping ([Libre.fm fundamentals](https://github.com/libre-fm/developer/wiki/Libre.fm-fundamentals)):

| Libre.fm | Last.fm equivalent |
| --- | --- |
| `turtle.libre.fm` | `post.audioscrobbler.com` |
| `https://libre.fm/2.0/` | `https://ws.audioscrobbler.com/2.0/` |

So the practical contract is “Last.fm API 2.0, implemented by GNU FM”, with some extensions and omissions.

### Authentication flows

GNU FM implements the Last.fm-style auth methods ([`nixtape/2.0/index.php`](https://github.com/foocorp/gnu-fm/blob/25cf8834b66cb4922d51c6fa85ff8556bc361d54/nixtape/2.0/index.php)):

- `auth.getToken` — creates a one-hour token.
- `auth.getSession` — exchanges a user-authorized token for a session key.
- `auth.getMobileSession` — username plus `authtoken`, where `authtoken = md5(lower(username) + stored_password_hash)`. This is **not** Last.fm’s plaintext-password-plus-signature flow.

Desktop browser flow, as implemented by GNU FM’s auth page ([`nixtape/api/auth/index.php`](https://github.com/foocorp/gnu-fm/blob/25cf8834b66cb4922d51c6fa85ff8556bc361d54/nixtape/api/auth/index.php)):

1. `GET /api/auth/?api_key=…&token=…` shows the authorization page.
2. The user logs in/authorizes; GNU FM binds the token to the user.
3. The client calls `auth.getSession&token=…` and receives `session.key`.
4. Write calls use `sk`.

`auth.getSession` does not require `api_sig` in GNU FM’s implementation. The mobile path also differs from Last.fm: clients that send `password` + `api_sig` will not authenticate. Pano uses the mobile path with username/password ([`GnuFm.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/GnuFm.kt)); Droppy should prefer the browser token flow so it never handles the Libre.fm password.

GNU FM’s mobile session row is created with a one-hour expiry (`expires = time() + 3600`), although `get_userid` in the same release does not check it. Treat sessions as expirable and re-authenticate on error `9`.

### Now-playing, scrobble, loved and delete endpoints

GNU FM registers these methods ([method map](https://github.com/foocorp/gnu-fm/blob/25cf8834b66cb4922d51c6fa85ff8556bc361d54/nixtape/2.0/index.php#L84)):

| Purpose | Method | Notes |
| --- | --- | --- |
| Now playing | `track.updateNowPlaying` | Artist + track; optional album/trackNumber/mbid/duration/albumArtist. |
| Scrobble | `track.scrobble` | **Single track only**: the handler reads scalar `artist`, `track`, `timestamp`, not arrays. |
| Love | `track.love` | Artist + track + `sk`. |
| Unlove | `track.unlove` | Artist + track + `sk`. |
| Delete | `library.removeScrobble` | Artist + track + UNIX timestamp + `sk`; GNU FM-specific extension. |
| Recent listens | `user.getRecentTracks` | Read path. |
| Loved tracks | `user.getLovedTracks` | Read path. |

`library.removeScrobble` is the important parity difference: Libre.fm can delete an individual scrobble by artist/track/timestamp, which Last.fm’s public API cannot ([GNU FM handler](https://github.com/foocorp/gnu-fm/blob/25cf8834b66cb4922d51c6fa85ff8556bc361d54/nixtape/2.0/index.php#L951)). Pano calls it and tolerates “invalid method”/“invalid resource” as success, which is the right defensive shape if the live deployment differs ([`GnuFm.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/GnuFm.kt)).

### Rate limits

Libre.fm publishes no numeric API quota. The site terms say “Please do not send large amounts of automated traffic to Libre.fm” and describe Cloudflare blocking of hosting/VPN address ranges ([Libre.fm terms](https://libre.fm/terms.php), [Libre.fm help](https://libre.fm/about.php)). GNU FM’s final release contains no API rate limiter.

Practical rules:

- Send one scrobble at a time; do not attempt Last.fm-style batches.
- Use a descriptive `User-Agent` with a contact URL.
- Back off on `429`, Cloudflare challenges and connection resets.
- Do not poll recents aggressively; Libre.fm is a small, volunteer-run service.
- New accounts are waitlisted in batches ([fundamentals](https://github.com/libre-fm/developer/wiki/Libre.fm-fundamentals)); do not assume every Droppy user can create an account instantly.

### Required credentials and who must own them

- **API key:** 32 characters, requested at `https://libre.fm/api-keys.php`; Libre.fm asks new clients to also request a **client code** ([fundamentals](https://github.com/libre-fm/developer/wiki/Libre.fm-fundamentals)).
- **No shared secret in GNU FM.** The API key is a client identifier. `valid_api_key()` only checks `strlen($key) == 32`, and the request handlers do not call it; `valid_api_sig()` likewise only checks length and signatures are not verified. Authentication is the `sk` session lookup ([GNU FM source](https://github.com/foocorp/gnu-fm/blob/25cf8834b66cb4922d51c6fa85ff8556bc361d54/nixtape/2.0/index.php#L1714)).
- **Session key:** per user, stored in Keychain.

Pano uses a single constant string as both `apiKey` and `apiSecret` for Libre.fm ([`Stuff.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/utils/Stuff.kt), [`GnuFm.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/GnuFm.kt)) and it works because GNU FM does not validate either. That is evidence of what the server tolerates, not a recommendation to ship a short placeholder key.

### Can a Libre.fm API key ship inside an open client?

**Yes.** Unlike Last.fm, there is no separate signing secret in GNU FM. The key identifies the client; the user’s session key authorizes writes. Publishing the client key does not let someone act as another user. Libre.fm’s terms do not contain a confidentiality clause for API keys; they do prohibit large automated traffic and require attribution for listening data (CC BY 4.0) ([terms](https://libre.fm/terms.php)).

Caveats:

- The live Libre.fm deployment is maintained separately (`end-times-code`) and sits behind Cloudflare, so its validation may be stricter than the final GNU FM release. Register a real 32-character key and client code; do not assume signature-free behaviour forever.
- Keep the user’s `sk` in Keychain. The client key is not a user credential.
- If Libre.fm later introduces a shared secret, the Last.fm reasoning would apply again.

### Edit and delete support

- **Edit:** no method.
- **Delete:** `library.removeScrobble` exists in GNU FM and the website exposes per-scrobble delete ([Libre.fm help](https://libre.fm/about.php)). Treat live support as best-effort and tolerate error `3`/`7` if the deployment lacks it.
- **Love/unlove:** supported.

### What parity means for Libre.fm

Parity = “Last.fm-shaped, with two deliberate differences”:

- One scrobble per request, not a 50-item batch.
- Delete is available; edit is not.
- Now playing, love/unlove and recent/loved reads work.
- No charts/friends guarantees; Pano suppresses some chart surfaces for GNU FM.
- Label it as a small, volunteer-run, Last.fm-compatible service. Do not promise Last.fm-level availability or metadata quality.

## ListenBrainz

### Authentication

ListenBrainz uses a **user token**, not an app key. The token is found on the user’s settings page and sent as:

```
Authorization: Token <user-token>
```

([API index](https://listenbrainz.readthedocs.io/en/latest/users/api/), [API usage](https://listenbrainz.readthedocs.io/en/latest/users/api-usage.html)). Tokens can be reset by the user. `GET /1/validate-token` checks validity.

There is **no application registration** in the documented submission path: no client ID, no secret, no callback URL. That makes ListenBrainz the simplest service to support in an open client. Requests must include a meaningful `User-Agent` with a contact URL or email; missing/opaque agents may be blocked ([API index](https://listenbrainz.readthedocs.io/en/latest/users/api/)).

### Now-playing, scrobble, loved and delete endpoints

| Purpose | Endpoint | Notes |
| --- | --- | --- |
| Now playing | `POST /1/submit-listens` with `listen_type: "playing_now"` | One listen, no `listened_at`. Optional `return_msid=true` returns a recording MSID for later feedback. |
| Scrobble | `POST /1/submit-listens` with `listen_type: "single"` | One listen with `listened_at`. |
| Backfill/import | `POST /1/submit-listens` with `listen_type: "import"` | Up to 1000 listens / 10 MB per request. |
| Love/hate/reset | `POST /1/feedback/recording-feedback` | `score: 1` love, `-1` hate, `0` reset. Requires `recording_mbid` or `recording_msid`. |
| Read feedback | `GET /1/feedback/user/{user}/get-feedback` | Optional score filter. |
| Recent listens | `GET /1/user/{user}/listens` | Bounded queries only; use export for full history. |
| Now playing read | `GET /1/user/{user}/playing-now` | Public read. |
| Clear now playing | `POST /1/playing-now/delete` | Clears the user’s playing-now state; optional `client` scopes it. |
| Delete listen | `POST /1/delete-listen` | Body: `listened_at` + `recording_msid`; deletion is scheduled shortly after the hour. |

Sources: [Core API](https://listenbrainz.readthedocs.io/en/latest/users/api/core.html), [JSON docs](https://listenbrainz.readthedocs.io/en/latest/users/json.html), [Feedback API](https://listenbrainz.readthedocs.io/en/latest/users/api/recordings.html), [Feedback JSON](https://listenbrainz.readthedocs.io/en/latest/users/feedback-json.html).

Listen JSON essentials:

- `track_metadata.artist_name` and `track_metadata.track_name` are required.
- `listened_at` is the playback start time in UNIX UTC; omit for `playing_now`.
- Optional `release_name`; optional `additional_info` with `recording_mbid`, `release_mbid`, `artist_mbids`, `duration_ms`, `tracknumber`, `submission_client`, `submission_client_version`, `media_player`, `music_service`, `origin_url`.
- Submit at half-track or 4 minutes, whichever is earlier ([Core API](https://listenbrainz.readthedocs.io/en/latest/users/api/core.html)).

### Rate limits

- Hard client rule: **no more than one API call per second** ([API index](https://listenbrainz.readthedocs.io/en/latest/users/api/)).
- Rate-limit headers: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset-In` (preferred), `X-RateLimit-Reset`.
- Exceeding returns HTTP `429`.
- Requests with a valid token get higher limits than anonymous requests.
- Limits are server-controlled; use the headers rather than hardcoding.
- Payload limits: 1000 listens/request, 10 MB/request, 10 KB/listen ([Core API constants](https://listenbrainz.readthedocs.io/en/latest/users/api/core.html)).

### Required credentials and who must own them

- **None for the application.** No client ID/secret.
- **User token:** owned by the end user; obtained from ListenBrainz settings; stored in Keychain per account.
- **User-Agent contact:** owned by the Droppy project; should identify the app and a contact URL/email.

This is the best fit for an MIT client: no shared secret exists to leak.

### Edit and delete support

- **Edit:** no. Listens are immutable.
- **Delete:** `POST /1/delete-listen` with `listened_at` and `recording_msid`; deletion is asynchronous (usually shortly after the hour). Droppy must retain the MSID from the `playing_now` response (or resolve it via metadata lookup) if it wants to offer delete later.
- **Feedback reset:** `score: 0` removes love/hate, which is the closest thing to “unlove”.
- **Import:** supported, so Droppy can offer backfill without scraping.

### What parity means for ListenBrainz

Parity = the **reference modern implementation**:

- Playing-now on start; single listen at the threshold.
- Durable import queue for offline/backfill, 1000 per request.
- Love and hate (or at least love + reset); map a single heart to `1` and “clear” to `0`.
- Delete by `listened_at` + `recording_msid`; surface it only when the MSID is known.
- MBID enrichment when tags provide it; optional metadata lookup when they do not.
- Respect 1 req/s and rate-limit headers; identify Droppy in the User-Agent.

## Pleroma

### What Pleroma scrobbling actually is in Pano

Pleroma is not a music service. Pano treats it as a **fediverse account that accepts “Listen” activities** through a deprecated Pleroma extension. Pano’s adapter ([`Pleroma.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/pleroma/Pleroma.kt)):

- Registers an OAuth app **per instance** at `POST {apiRoot}/api/v1/apps` with `client_name`, `redirect_uris`, and scopes `read write`.
- Opens `{apiRoot}/oauth/authorize?client_id=…&redirect_uri=…&response_type=code&scope=read+write`.
- Uses the out-of-band redirect `urn:ietf:wg:oauth:2.0:oob` on desktop; the user copies the code back into Pano ([`LoginScreens.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/onboarding/LoginScreens.kt)).
- Exchanges the code at `{apiRoot}/oauth/token` with `grant_type=authorization_code`, `client_id`, `client_secret`, `redirect_uri`, `code`.
- Stores the access token and API root, and derives the username from the token response’s `me` URL.
- Scrobbles with `POST {apiRoot}/api/v1/pleroma/scrobble`, JSON body `{artist, title, album, album_artist, length}`.
- Reads recent scrobbles with `GET {apiRoot}/api/v1/pleroma/accounts/{username}/scrobbles`.
- Sends **one scrobble per request with a 1-second delay** between items.
- Implements **no now playing, no love/unlove, no delete, no charts, no friends**.

The token response includes `refresh_token` and `expires_in`, but Pano stores only `access_token` and does not refresh. A clean-room client should persist the refresh token or re-authenticate on `401`.

### Official Pleroma contract

The Pleroma API docs mark both endpoints **deprecated** ([Pleroma API](https://docs.pleroma.social/backend/development/API/pleroma_api/)):

| Endpoint | Auth / scope | Contract |
| --- | --- | --- |
| `POST /api/v1/pleroma/scrobble` | Required; `write:scrobbles` (older instances: `write`) | `title` required; `album`, `artist`, `length`, `external_link` optional. Creates a **Listen activity** for the account. |
| `GET /api/v1/pleroma/accounts/:id/scrobbles` | Not required; `read:scrobbles` for authenticated reads | Returns current/recent Listen activities; supports pagination (`max_id`, `min_id`, `limit` in the OpenAPI spec). |

OAuth is standard Pleroma/Mastodon-style: app registration via `POST /api/v1/apps`, authorization code flow, token at `/oauth/token`; Pleroma supports hierarchical scopes and OAuth tokens ([Authentication & Authorization](https://docs.pleroma.social/backend/development/authentication_authorization/), [Pleroma client API](https://api.pleroma.social/)). Pleroma added `read:scrobbles`/`write:scrobbles`; older instances expect the broader `read`/`write` scopes, which is why Pano requests `read write`.

Because the endpoint creates a **Listen activity** (an ActivityPub object), not a private Last.fm-style scrobble row, treat it as a social post. The docs do not describe per-listen privacy controls; Pano sends no visibility parameter. Do not present it as a private listening history.

### Rate limits

Pleroma publishes no client rate limit for scrobbling. Limits are instance-specific. Pano’s 1-second spacing is a sensible floor. Handle `429` and instance error bodies; feature-detect `404`/`403` because scrobbling may be absent or disabled on a given instance.

### Required credentials and who must own them

- **No global app credentials.** The client registers an OAuth app on the user’s instance at runtime; the instance returns `client_id` and `client_secret`.
- **Per-account storage:** API root, client ID/secret, access token (and refresh token if used) in Keychain.
- **User authorization:** the instance user approves the app; the token belongs to that user.
- The client secret is generated per instance and is not a shipped project secret.

Pleroma also supports trusted apps created by the instance admin ([CLI task](https://docs.pleroma.social/backend/administration/CLI_tasks/oauth_app/)), but Droppy should not depend on admin setup.

### Edit and delete support

- **Edit:** none.
- **Delete:** no scrobble-specific delete in the documented API; Pano implements a no-op. The created Listen may be deletable as an ActivityPub activity through instance-specific means, but that is not a portable contract. Do not offer delete.

### What parity means for Pleroma

Parity = **experimental one-way scrobbling**:

- One scrobble per track, 1-second spacing.
- Optional recent-scrobbles read.
- No now playing, love, delete, charts or friends.
- Clearly label it “experimental / deprecated upstream”; hide or disable it when the instance returns `404`.
- Warn that listens may be visible as federated activity.

Pleroma is the lowest-priority adapter. It is not a substitute for Last.fm/Libre.fm/ListenBrainz parity.

## Discord Rich Presence

### Can a droplet open Discord’s local IPC socket?

**Yes, as a normal user-level desktop process.** Discord exposes a local IPC socket, not a network API, for Rich Presence ([Discord RPC docs](https://docs.discord.com/developers/topics/rpc)):

| Platform | Socket path |
| --- | --- |
| Windows | `\\?\pipe\discord-ipc-{n}` |
| Linux/macOS | `${XDG_RUNTIME_DIR}/discord-ipc-{n}`, then `${TMPDIR}`, `${TMP}`, `${TEMP}`, finally `/tmp/discord-ipc-{n}` |

Framing is a 4-byte little-endian opcode, a 4-byte little-endian length, then JSON. The first frame is opcode `0` (`HANDSHAKE`) with `{"v":1,"client_id":"<application id>"}`; Discord replies with opcode `1` (`FRAME`) carrying `READY`. `SET_ACTIVITY` is a `FRAME` command.

### What app registration is required

- Create a **Discord application** at <https://discord.com/developers/applications> and use its **Application ID** as the `client_id`.
- No bot token, client secret or OAuth flow is needed for basic Rich Presence. Discord’s docs explicitly support **Rich Presence without authentication**: set the application ID and update presence while the desktop client is running ([Setting Rich Presence → Rich Presence Without Authentication](https://docs.discord.com/developers/discord-social-sdk/development-guides/setting-rich-presence#rich-presence-without-authentication)).
- The Application ID is public and safe to ship. Never ship a Discord client secret.
- Uploaded Rich Presence assets are optional; up to 300 per app, keys are lowercased, and external image URLs are allowed with the right dimensions ([Setting Rich Presence → Uploading Assets](https://docs.discord.com/developers/discord-social-sdk/development-guides/setting-rich-presence#uploading-assets)).
- The application’s registered name is what Discord displays on the “Playing/Listening” line by default; newer SDKs can override the activity `name`.
- For music, use activity type `Listening` (`2`). `SET_ACTIVITY` accepts Playing (`0`), Listening (`2`), Watching (`3`) and Competing (`5`).

If Droppy later wants full RPC commands (guild/channel access), that requires `AUTHORIZE`/`AUTHENTICATE` and, for unapproved apps, a tester list (up to 50). Presence-only does not. If using the Social SDK’s authenticated `Connect` path instead of direct IPC, it requires the default presence scopes `openid` and `sdk.social_layer_presence`.

### Constraints

- **Desktop Discord client must be running**, not the web client, and as the **same OS user** as Droppy. Pano’s FAQ lists exactly these failure modes, plus Discord’s “Share my activity” privacy setting and not being invisible ([Pano FAQ](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/faq.md)).
- **Desktop only** for this path. Discord’s Social SDK documents Rich Presence on desktop and Android; not iOS, console or web ([Setting Rich Presence](https://docs.discord.com/developers/discord-social-sdk/development-guides/setting-rich-presence)).
- **Sandboxing:** a sandboxed/App Store build may be denied access to the per-user socket path. Verify entitlements or distribute outside the sandbox; this is an OS-level integration risk, not a Discord API guarantee.
- **Activity privacy:** presence is public on the user’s profile; Discord recommends a test account during development ([Rich Presence overview](https://docs.discord.com/developers/platform/rich-presence)).
- **Rate limits:** The current RPC/rate-limit docs do not state a fixed presence-update quota; they say limits vary and clients must honor `Retry-After`/`RetryAfter` ([Rate Limits](https://docs.discord.com/developers/topics/rate-limits), [Social SDK rate limits](https://docs.discord.com/developers/discord-social-sdk/how-to/handle-rate-limits)). Coalesce updates to track/state changes; do not send one per second.
- **Content:** keep `details`/`state` short and single-line; Discord’s best-practices guide explicitly warns about wrapping on the small profile ([Best Practices](https://docs.discord.com/developers/rich-presence/best-practices)).
- **Lifecycle:** clear the activity on pause/stop/quit; otherwise Discord shows a stale track.

### How Pano does it

Pano’s desktop implementation is a useful reference for shape, not code:

- A Rust `discord-rich-presence` client opened from Kotlin/JNI ([`discord_rpc.rs`](https://github.com/kawaiiDango/pano-native-components/blob/2589a4d3831b47b87404e300588dfa8292b84e0c/pano-native-components/src/discord_rpc.rs), [`DiscordRpc.kt`](https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/jvmMain/kotlin/com/arn/scrobble/discordrpc/DiscordRpc.kt)).
- Activity type `Listening`; `details` and `state` are user-formatted lines; timestamps show elapsed/remaining; optional large image (album art URL), small pause icon, buttons and a clickable details URL.
- A single shipped `DISCORD_CLIENT_ID` constant; no secret.
- Reconnect on `NotConnected`/`IPCConnectionFailed`/write errors; debounce updates; clear on pause/stop.

### What parity means for Discord

Presence parity = “show the current track, artist, elapsed/remaining time and album art while playing; clear on stop.” It is not a scrobbling destination, has no history, love or delete, and must degrade silently when Discord is absent. Treat it as an optional, best-effort integration with no server dependency.

## Design implications for Droppy

### Adapter boundary

Model each service as a capability set rather than a uniform “scrobbler”:

```
protocol ScrobbleService {
  capabilities: nowPlaying, scrobble, batch, love, hate, resetFeedback,
                readRecent, delete, import, requiresAppSecret
  authorize() -> Account
  updateNowPlaying(track)
  scrobble([track])
  setFeedback(track, value)
  delete(track)
}
```

The UI should hide unsupported actions instead of showing disabled buttons with no explanation. Pleroma’s “no now playing/love/delete” and Last.fm’s “no delete” are contract facts, not bugs.

### Credential storage

| Item | Keychain? | Scope |
| --- | --- | --- |
| Last.fm API key | Yes / deployment config | Droplet-wide |
| Last.fm shared secret | Yes / deployment config; **never git** | Droplet-wide |
| Last.fm session key | Yes | Per user |
| Libre.fm client key | Config / build constant | Droplet-wide; not sensitive |
| Libre.fm session key | Yes | Per user |
| ListenBrainz token | Yes | Per user |
| Pleroma client ID/secret | Yes | Per instance/account |
| Pleroma access/refresh token | Yes | Per user |
| Discord Application ID | Config / build constant | Droplet-wide; public |

Keychain items should be per service + account, never logged, and excluded from diagnostics. If the droplet supports multiple profiles, do not share session keys across them.

### Queueing and retries

- One durable queue per destination account; preserve order.
- Last.fm: batch up to 50; retry `11`/`16`; re-auth on `9`; surface `26`/`29` as account/app problems.
- Libre.fm: one at a time; retry transient failures; treat missing `library.removeScrobble` as “delete unsupported”.
- ListenBrainz: batch imports up to 1000; respect 1 req/s and `X-RateLimit-Reset-In`; retry `429` after the indicated delay.
- Pleroma: one at a time, 1-second spacing; re-auth on `401`; disable on `404`.
- Never retry a failed now-playing request; it is ephemeral.

### Identity and etiquette

- Send a descriptive `User-Agent` such as `Droppy/<version> (+https://…/contact)` on every service. ListenBrainz may block requests without one; Last.fm and Libre.fm use it for logging/abuse handling.
- Do not scrape. ListenBrainz explicitly says use export for full history, not pagination; Libre.fm blocks automated scraping; Last.fm forbids gathering data outside documented APIs ([Last.fm ToS §2.6](https://www.last.fm/api/tos)).
- Respect each service’s data licence when displaying data: Last.fm requires credit/links; Libre.fm listening data is CC BY 4.0 with username attribution.

### Recommended rollout order

1. **ListenBrainz** — no app credential, cleanest contract; validates the queue, now-playing, feedback and delete paths.
2. **Last.fm** — the baseline users expect; forces the token flow and secret-handling policy.
3. **Libre.fm** — mostly reuse of Last.fm with single-scrobble and delete quirks.
4. **Pleroma** — experimental adapter behind a flag, with deprecation warning.
5. **Discord presence** — optional, independent of scrobbling; ship when the core queue is stable.

## Open questions and risks

- **Live Libre.fm validation.** GNU FM’s final release does not verify API keys or signatures, but Libre.fm runs a separately maintained deployment behind Cloudflare. Confirm the client key/client code process and whether `library.removeScrobble` is enabled before promising delete.
- **Last.fm API account availability.** Registration is an application process tied to a Last.fm account; plan onboarding copy and failure states. Do not assume instant issuance.
- **Last.fm key rotation.** Disabling a key is possible; rotation generally requires contacting Last.fm. A leaked project secret would be painful, which reinforces not shipping one.
- **Pleroma surface area.** The scrobble endpoints are deprecated and may be absent or disabled per instance; the Listen activity’s visibility is instance/default-dependent. Feature-detect and label experimental.
- **ListenBrainz feedback without MBIDs.** Love/hate needs `recording_mbid` or `recording_msid`. Local files without MusicBrainz tags may need the metadata lookup endpoint, or feedback must be unavailable until a `playing_now` listen returns an MSID.
- **Discord sandboxing.** A sandboxed Droppy build may not reach `$TMPDIR/discord-ipc-0`; test the actual distribution format, not just a debug build.

## Sources

### Last.fm

- API introduction — <https://www.last.fm/api/intro>
- Authentication overview — <https://www.last.fm/api/authentication>
- Desktop authentication — <https://www.last.fm/api/desktopauth>
- Authentication spec — <https://www.last.fm/api/authspec>
- Scrobbling 2.0 — <https://www.last.fm/api/scrobbling>
- `track.scrobble` — <https://www.last.fm/api/show/track.scrobble>
- `track.updateNowPlaying` — <https://www.last.fm/api/show/track.updateNowPlaying>
- `track.love` — <https://www.last.fm/api/show/track.love>
- `track.unlove` — <https://www.last.fm/api/show/track.unlove>
- Error codes — <https://www.last.fm/api/errorcodes>
- API Terms of Service — <https://www.last.fm/api/tos>
- Delete scrobbles (API removal) — <https://support.last.fm/t/how-do-i-delete-an-artist-album-track-or-scrobble-from-my-library/213>
- Pano on storing Last.fm credentials — <https://github.com/kawaiiDango/pano-scrobbler/issues/527>
- Last.fm desktop client source (fallback key/secret precedent) — <https://github.com/lastfm/lastfm-desktop/blob/9ae84cf4ab204a92e6953abe14026df70c140519/lib/unicorn/UnicornCoreApplication.cpp>
- Navidrome integration docs — <https://www.navidrome.org/docs/usage/integration/external-services/>
- Navidrome shared-key removal — <https://github.com/navidrome/navidrome/releases/tag/v0.51.0>

### Libre.fm / GNU FM

- Developer documentation — <https://developer.libre.fm>
- Libre.fm fundamentals — <https://github.com/libre-fm/developer/wiki/Libre.fm-fundamentals>
- Libre.fm terms — <https://libre.fm/terms.php>
- Libre.fm help / account waitlist / delete — <https://libre.fm/about.php>
- GNU FM 2.0 API implementation — <https://github.com/foocorp/gnu-fm/blob/25cf8834b66cb4922d51c6fa85ff8556bc361d54/nixtape/2.0/index.php>
- GNU FM browser auth — <https://github.com/foocorp/gnu-fm/blob/25cf8834b66cb4922d51c6fa85ff8556bc361d54/nixtape/api/auth/index.php>
- Pano Libre.fm adapter — <https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/lastfm/GnuFm.kt>

### ListenBrainz

- API index, auth, rate limits, User-Agent — <https://listenbrainz.readthedocs.io/en/latest/users/api/>
- Core endpoints — <https://listenbrainz.readthedocs.io/en/latest/users/api/core.html>
- Submission JSON — <https://listenbrainz.readthedocs.io/en/latest/users/json.html>
- Feedback API — <https://listenbrainz.readthedocs.io/en/latest/users/api/recordings.html>
- Feedback JSON — <https://listenbrainz.readthedocs.io/en/latest/users/feedback-json.html>
- Usage examples — <https://listenbrainz.readthedocs.io/en/latest/users/api-usage.html>

### Pleroma

- Pleroma API (scrobble, deprecation, scopes) — <https://docs.pleroma.social/backend/development/API/pleroma_api/>
- Authentication & Authorization — <https://docs.pleroma.social/backend/development/authentication_authorization/>
- Pleroma client API / OAuth — <https://api.pleroma.social/>
- Trusted OAuth app CLI — <https://docs.pleroma.social/backend/administration/CLI_tasks/oauth_app/>
- Pano Pleroma adapter — <https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/api/pleroma/Pleroma.kt>
- Pano Pleroma login flow — <https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/commonMain/kotlin/com/arn/scrobble/onboarding/LoginScreens.kt>

### Discord

- RPC / IPC sockets, framing, handshake, SET_ACTIVITY — <https://docs.discord.com/developers/topics/rpc>
- Rich Presence overview — <https://docs.discord.com/developers/platform/rich-presence>
- Setting Rich Presence (including without authentication, assets, scopes) — <https://docs.discord.com/developers/discord-social-sdk/development-guides/setting-rich-presence>
- Rich Presence best practices — <https://docs.discord.com/developers/rich-presence/best-practices>
- Rate limits — <https://docs.discord.com/developers/topics/rate-limits>
- Social SDK rate-limit handling — <https://docs.discord.com/developers/discord-social-sdk/how-to/handle-rate-limits>
- Pano native Discord client — <https://github.com/kawaiiDango/pano-native-components/blob/2589a4d3831b47b87404e300588dfa8292b84e0c/pano-native-components/src/discord_rpc.rs>
- Pano desktop Discord integration — <https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/composeApp/src/jvmMain/kotlin/com/arn/scrobble/discordrpc/DiscordRpc.kt>
- Pano Discord FAQ — <https://github.com/kawaiiDango/pano-scrobbler/blob/990154031e761b8e5460a0585fc834b43c9e2d71/faq.md>
