# Entity details and image overrides contract

Status: accepted

The owner accepted these 13 decisions on 2026-11-04 (issue comment
6638938906) for #86. They were implemented in `5cd1fbc` (PR #116); the
implementation is recorded in
`docs/reports/issue-86-entity-details-image-overrides.md`, which follows the
contract and records the later clarification that Loved rows open details
through the History row entry. No deviation from these decisions was found.

1. **Detail content.** Artist, album and track pages each have a local section
   with count, first listen and last listen, plus top tracks on artist and album
   pages. The local section ignores the current connection. A separate service
   section sits below it. Tags and wiki text stay in #89.
2. **Service limits.** With a Last.fm current connection, the service section
   shows `getInfo` facts and the user's play count. With any other connection or
   none, the page shows the local section plus a one-line reason. ListenBrainz
   adds a service link only when the row has an MBID.
3. **Navigation.** Details open in place in the takeover with a back button, as
   track history does, and track history becomes the track page. Closing the
   takeover resets them.
4. **Entry points.** The History row body opens the track, and its menu adds
   artist and album. The chart row body opens that entity.
5. **Palette keys.** Return opens details, Option-Return plays, and
   Command-Return still opens Last.fm. This replaces the Return behaviour in
   #85's decision 5, which reserved it for this ticket.
6. **Image precedence.** Artist: the user's override, then the approximate
   image, then the neutral sleeve. Album: the user's override, captured
   artwork, the Last.fm `album.getInfo` image, then the neutral sleeve.
7. **Where overrides show.** Detail headers, chart rows and palette rows.
   History rows and now playing keep the captured cover.
8. **Override identity and lifetime.** Key overrides on the local chart
   grouping keys, shared across connections. Overrides survive restart, unlink
   and listen deletion, and only the user removes them. They stay out of the
   settings export.
9. **Choosing and removing.** "Change image…" on the detail page opens a
   Settings page with a file picker. Settings also lists every override with
   Remove, and the detail page offers Remove too.
10. **Stored copy.** Re-encode off the capture path into the droplet container,
    downscale it, and add a schema migration. An unreadable file shows the
    neutral sleeve, and Settings offers replace or remove.
11. **Approximate artist image.** Use the first iTunes album result whose
    artist name matches exactly after normalising. If the top results show two
    artist IDs with that name, use the neutral sleeve. Caption the image as
    approximate.
12. **Lookup timing and privacy.** Look up only when an artist page opens, with
    a 15-second timeout. Cache hits for 30 days and retry misses after a day. A
    Settings switch controls lookups, on by default, with a privacy note saying
    artist names go to Apple.
13. **Service data freshness.** Detail reads have no persistent cache. A
    connection change clears and reloads the service section, and late replies
    are ignored.

## Implementation note

The shipped model also starts a lookup when lookups are enabled on an
already-open artist page, and when an artist override is removed, provided no
fresh cache exists (`EntityDetailReadModel.swift`,
`artistImageLookupsSettingChanged` and `removeOverride`). This extends decision
12's page-open trigger; the 15-second timeout and 30-day/1-day cache timings are
unchanged.

## Checks during implementation

- Last.fm and Libre.fm `getInfo` details against primary documentation, and
  whether Libre.fm supports these reads. If it does not, Libre.fm gets the
  one-line reason from decision 2.
- Whether Last.fm artist images are placeholders, which is why decision 6 skips
  them.
- `NSOpenPanel` in the real host. DroppyKit has no open-panel API that the
  supervisor could find, and export uses `NSSavePanel` directly.

## Consequences

- The glossary's Artwork entry says Tracklog never searches a network for
  covers. To keep that true, the implementation adds separate terms for the
  artist image and the image override.
- #93 can reuse the small iTunes client this ticket adds. Its matching rules
  stay its own.
- Tag detail pages stay in #89, although matrix row NP-12 also mentions tags.
- #87 merged after these decisions and added Loved rows. Matrix row NP-12 says
  "reachable from any list", so Loved rows open details through the same entry
  as History rows.
