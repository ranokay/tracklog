# Catalogue search and search-and-play contract

Status: accepted

The owner accepted these eight decisions on 2026-11-04 (issue comment
6625541675) for #85. They were implemented in `8fb73ff`; the implementation is
recorded in `docs/reports/issue-85-catalogue-search.md`, which follows the
contract. Decision 5's Return behaviour was later replaced by decision 5 of
ADR-0003, as #86 recorded.

1. **Playback URL schemes.** Allow `http` and `https` only, opened through
   `host.workspace.open`. Do not bypass the host with `NSWorkspace`. DroppyKit
   1.20.1-1 refuses other schemes unless declared, and it documents no way to
   declare one.
2. **Opening the palette.** A search button in the takeover's section bar, an
   item in the shelf overflow menu, and a rebindable shortcut with no default.
   The shortcut adds the `global-shortcuts` capability.
3. **Loved results.** Filter the loved tracks of the current connection when it
   is Last.fm, reading at most 5 pages of 200 per query. Label the group with
   that account and say when the limit was reached. Otherwise the group explains
   why it is unavailable instead of appearing empty.
4. **Keyboard and groups.** The field keeps focus. Up and Down move through
   rows. Return toggles a group header, expands "Show more", or runs the
   primary action on a result row. Esc clears the text and then closes. Groups
   are Artists, Albums, Tracks and Loved, with 5 rows each, collapsible and
   with a "Show more" row. Collapsed state resets on each open.
5. **Primary action on a row.** Search and play when a template is set,
   otherwise open the Last.fm page. Command-Return always opens Last.fm. #86
   may later take over the primary action for entity details.
6. **Query lifecycle.** Wait 300 ms after typing and require at least 2
   characters. Send one request per group, at most 4 at once, with 10 results
   per group and a 15-second timeout. Each group fails separately. A new query
   cancels the old one and ignores any late reply. Closing the panel or
   deactivating stops all work.
7. **URL template.** The placeholder is `{query}` and must appear exactly once.
   No template is set by default. Encode with RFC 3986 unreserved characters,
   so a space becomes `%20`. Queries are the artist name, `artist album`, or
   `artist title`.
8. **Where play appears.** Palette results, History rows, track history, chart
   rows and the now-playing strip menu. With no template set, Play on the
   History, track history, chart and now-playing surfaces opens the Settings
   page. A palette row's primary action opens its Last.fm page instead.

The accepted brief also recorded that the Last.fm method details behind
decisions 3 and 6 still needed checking against its API documentation during
implementation.
