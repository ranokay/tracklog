# Core charts prototype

Throwaway HTML model for [Prototype Core charts in the Droppy takeover](https://github.com/ranokay/tracklog/issues/73). The owner selected **Context rail** on 31 October 2026. The [resolution](https://github.com/ranokay/tracklog/issues/73#issuecomment-6545268245) records the accepted layout and shared interactions. Use `?variant=rail` to view the chosen direction. All three variants remain here as the primary source for the comparison.

Open `index.html` directly in a browser, or run this from the repository root:

```sh
open tracklog/prototype/core-charts/index.html
```

There is no server, dependency installation, service request, database, or production import. Use the bottom arrows or keyboard Left/Right to switch layouts. Arrow shortcuts ignore text fields and selects. `?variant=inline`, `?variant=rail`, and `?variant=range` select a layout on opening. The picker is prototype-only and remains on this branch.

| Layout | Axis | Benefit | Cost |
| --- | --- | --- | --- |
| Inline | Controls above the full-width list | Source, period and chart type are visible together | Three complete rows in the initial service fixture |
| Context rail | Source, period and totals beside the list | Five complete rows in the initial service fixture | Narrower title column and more eye travel |
| Range first | Period and supported totals lead the view | Counts are easy to compare while changing period | Four complete rows; weaker when totals are unavailable |

All variants use the same 899 by 558 content rectangle, 52 px sleeves, 68 px rows, and 76 px pinned strip. The surrounding Droppy shell and physical notch are outside the model. On small displays, Fit to view scales the whole rectangle for comparison. Turn it off to inspect actual sizing with horizontal scrolling. The embedded view uses the same behavior.

## Try these paths

- Switch Artists, Albums and Tracks. Switch between service history and On this Mac. The current connection scopes service reads only. It does not change delivery targets.
- Switch Last.fm, ListenBrainz and Libre.fm. Libre.fm falls back to local history and explains why. Week, Month, Year and All time are shared. Today and Custom appear only locally.
- Choose Custom locally. The model replaces the takeover with a separate Settings view. Edit dates, save, then choose Open Charts. Saving stays in Settings. Cancel leaves the previous range unchanged.
- Select each Data state above the model. First load, empty, no connection, failed refresh without data, and saved data after a failed refresh have separate presentations. No connection offers local history and a Settings handoff.
- Select the 22-minute saved-data fixture. Rows appear immediately while an automatic refresh runs. Manual refresh uses the same brief in-memory transition. An offline retry retains the saved rows and their age.
- Use Totals to compare unavailable counts, listens only, and scrobbles plus loves. Unsupported totals are named as unavailable, never shown as zero.
- Change the pinned strip between playing, paused, off and idle. Love and cancel are in-memory actions. History and Charts share their state. Idle hides the strip. Reopen takeover starts at History and retains the chart source and period in this session.

## What this artifact establishes

This is a presentation model with synthetic eight-item lists, source-dependent counts, and scripted loading outcomes. Neutral sleeves stand in for missing artwork. It does not contact services or qualify which totals their APIs can supply. The default totals fixture gives local history and ListenBrainz a listen count and leaves Last.fm totals unavailable. These are comparison fixtures, not a service capability contract. The explicit totals override exists to review every presentation before the contract is settled.

Dates are visible labels in the fixture. Exact local calendar boundaries, time zone, grouping, missing metadata, result limits, real cache identity, stale-response isolation and service-supported totals belong to [Specify the Core charts data and acceptance contract](https://github.com/ranokay/tracklog/issues/74). No graph, rank arrow, grid, detail page, enrichment service, or delivery behavior is introduced here.

State lives in memory. Reopening the takeover preserves source and period during the session; reloading the HTML resets them. Production persistence across launches is already required by the settled source decision and is not implemented by this throwaway artifact. Starting in Charts is a review convenience. Reopen takeover demonstrates the settled History-first entry.

Browser control styling approximates Droppy's dark glass controls using its spacing and radius values. It does not prove SwiftUI rendering, native keyboard or VoiceOver behavior, host dismissal, Settings deep links, capture continuity, real offline persistence, or Store compatibility. The fixture readout makes intended state visible but does not execute capture or delivery.

## Verification

Browser interaction checks exercised all three layouts, every chart type, source/period controls, all seven data fixtures, offline retry, four pinned-strip states, Libre.fm fallback, the Custom Settings handoff, saved chart state on History-first reopen, totals variants, and stale-cache refresh. The browser console reported zero errors and zero warnings. Screenshots in `output/playwright/` capture the three local weekly album lists, saved data after failed refresh, and Custom Settings. This is prototype validation. No native package code changed, so the droplet build, submission gate and live-host qualification were not run.

The full artifact stays on `prototype/core-charts`, with no pull request. The prototype ticket is resolved and its context pointer is in the wayfinder map. Context rail is design input to the separate data-contract ticket and later implementation planning. No prototype code is promoted into production.
