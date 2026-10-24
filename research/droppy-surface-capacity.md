# How much UI a Droplet can present

Research for [#3](https://github.com/ranokay/pano-scrobbler-droppy/issues/3), against DroppyKit 1.21.0 as
documented on 2026-09-09, the harness that ships with it, and the Store droplets in
[`droppyformac1/droplets`](https://gitlab.com/droppyformac1/droplets).

## Verdict

A six-section music app **does** fit inside Droppy, but not as a desktop-style app window. The shape that fits is:

- **one takeover** (expanded surface) as the app's screen — ~900 × 558 points of content on a 14-inch MacBook Pro,
  one at a time, pointer-only;
- **one shelf widget** as the always-there card — up to 480 pt tall, min 352/370 wide, one row of 1–4 widgets;
- **Droppy's Settings window** as the app's configuration and CRUD tree — a 380–900 pt column, unlimited nested
  pages, full keyboard, Back/Forward history, toolbar pills;
- **the live activity** for at-a-glance status (37 pt, 70/120 pt wings) and **HUDs** for transient feedback;
- **one droplet-owned `NSPanel`** if — and only if — a real text field is required (search). That escape hatch is
  real and shipped (DropClip, DockDoor), but every shipped example is palette-sized, not an app window.

The ceiling is **not** too low for a Droppy-native app. It **is** too low for a persistent multi-pane window with a
sidebar, and for anything that needs two app surfaces visible at once.

---

## 1. The surfaces, with their real numbers

| Surface | Protocol | Size | How many | Lifetime | Keyboard |
| --- | --- | --- | --- | --- | --- |
| Shelf widget | `ShelfWidgetProviding` | height 48–480 (93 default), solo min 352 (notch) / 370 (island); width opens to the card | one shelf row (solo, or 2–4 grouped) | shelf open; closes on pointer-leave / outside click unless held | yes, only with `.keyboardFocusable` |
| Expanded surface | `ExpandedSurfaceProviding` | 352×93 default; ceiling 66 % of the display less chrome | **one, globally** | until dismissed; outside click, swipe, auto-collapse, pre-emption, display change | **no supported path** |
| Settings pane + pages | `SettingsPaneProviding`, `SettingsPagesProviding` | column 380–900 pt wide, 20 pt insets, scrolls | pane + unlimited pages, arbitrary depth | Settings window | full AppKit |
| Droplet-owned panel | none (AppKit + `DroppyPanelSurface`) | whatever you set; clamp to the screen yourself | as many as you like | yours to manage | yes (you own `canBecomeKey`) |
| Live activity | `LiveActivityProviding` | 37 pt row; 70 pt wing at rest, 120 pt interactive; island 150/240 | **one compact seat** | while published; hides when the shelf opens | 24 pt controls only |
| HUD | `HUDPresenting` | strip = notch + 2×70 (or 150); card = notch + 2×120 (or 240), 59 pt default content height | one HUD slot | `duration`, or until replaced/dismissed | no |
| Menu bar extra | `MenuBarExtraProviding` | host-owned Command Center tile + detail | one tile | while declared | host-owned |

Sources: [DroppyKit surfaces](https://getdroppy.app/docs/droppykit),
[shelf widgets](https://getdroppy.app/docs/droppykit/shelf-widgets),
[expanded surfaces](https://getdroppy.app/docs/droppykit/expanded-surfaces),
[settings panes](https://getdroppy.app/docs/droppykit/settings-panes),
[live activities](https://getdroppy.app/docs/droppykit/live-activities),
[host support](https://getdroppy.app/docs/droppykit/host-support).

### The expanded-surface ceiling, computed

The host clamps to `maximumSize`, which the harness derives the same way the app does:
66 % of the display's visible frame, less the shelf's chrome and the 1.5 pt slot gutter
([`HarnessWindow.swift:1029–1057`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKitHarness/HarnessWindow.swift#L1029)).
Chrome on a notch is 47 pt top (37 pt cutout + 10), 48 pt per side, 16 pt bottom
([`NotchShellShape.swift:140,197`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/DesignSystem/NotchShellShape.swift#L140)).

| Display (visible frame) | Default | Ceiling, notch | Ceiling, island |
| --- | --- | --- | --- |
| 14″ MBP (1512 × 945) | 352 × 93 | **≈ 899 × 558** | ≈ 963 × 589 |
| 16″ MBP (1728 × 1117) | 352 × 93 | **≈ 1041 × 671** | ≈ 1106 × 702 |

These are **content** sizes: the host adds the shell around them, so a 558 pt answer is 558 pt of drawable area
([expanded surfaces](https://getdroppy.app/docs/droppykit/expanded-surfaces)). The height clamp has no meaningful floor
(the harness clamps to `max(answer, 0)`), so a takeover can be a short strip; width never goes below the 352/370
standard. A takeover is "a shelf, not a window"
([`HarnessWindow.swift:1043`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKitHarness/HarnessWindow.swift#L1043)).

For scale: 899 × 558 is roughly a 900 × 560 window. At 12–13 pt type and 36–44 pt rows that is 12–15 list rows;
a 4-column collage at ~150 pt tiles fits comfortably; a 300 pt-tall chart with a header and a legend fits.

### What "one at a time" means

`DropletNotchSurfaceService.expandedState` returns a single `current` presentation
([`DropletServices.swift:418`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/Services/DropletServices.swift#L418)),
and `preempted` is a dismissal reason ("another surface took the shelf, or the same droplet presented again")
([`ExpandedSurfaceProviding.swift:205`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/Capabilities/ExpandedSurfaceProviding.swift#L205)).
Two droplet takeovers cannot coexist, and neither can a takeover plus a `solo` shelf widget view. Section switching
must happen *inside* the one surface — which is what `floatingNavLane` implies: Droppy's own expanded surfaces carry
a navigation lane along the bottom edge, and a droplet may keep it or suppress it and draw its own
([`ExpandedSurfaceProviding.swift:46–90`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/Capabilities/ExpandedSurfaceProviding.swift#L46)).

### Keyboard is the sharpest limit

There is no documented way to type into a takeover. The only text-input promotion the SDK exposes is on shelf
widgets: declare `ShelfWidgetFocusPolicy.keyboardFocusable`, and the host makes the shelf panel key on mount or on
`requestKeyboardFocus()` — "accepted only while one of this droplet's widgets is on the expanded shelf and that
widget declared `keyboardFocusable`"
([shelf service](https://getdroppy.app/docs/droppykit/api/droplet-shelf-service#request-keyboard-focus)).
`ExpandedSurfaceContext` carries no focus state or request, and the takeover descriptor has no focus policy. Treat a
takeover as pointer-only. A search field therefore cannot live in the app's main screen.

### Lifetime and dismissal

A takeover stays up until: the droplet dismisses it, the user collapses the shelf, another surface pre-empts it, the
display goes away, the shelf is switched off, or host policy ends it
([dismissal reasons](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/Capabilities/ExpandedSurfaceProviding.swift#L205)).
Outside-click and swipe-to-close are on by default; `expandedSurfaceSize` is re-asked after every state broadcast
(at most ~4/s) so the surface can grow or shrink live, and a broadcast never dismisses it.

`ExpandedSurfaceHostSuppression.takeover` turns off every escape hatch at once and is explicitly review-sensitive:
"a surface that traps someone is worse than one that closes early", and "a takeover with no close affordance and no
host dismissal path is a shelf the user cannot get rid of, and review rejects it"
([expanded surfaces](https://getdroppy.app/docs/droppykit/expanded-surfaces),
[`ExpandedSurfaceProviding.swift:80`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/Capabilities/ExpandedSurfaceProviding.swift#L80)).
For a reading/browsing app the right set is usually `.autoCollapse` + `.shelfWidgets` (and maybe `.outsideClickDismissal`
only with a visible close button), not `.takeover`.

The shelf widget has the complementary trick: `setHoldsOpen(true)` keeps the shelf up — including over a full-screen
app — while one of your widgets is on it, and Droppy draws its own close affordance while the hold counts
([shelf service](https://getdroppy.app/docs/droppykit/api/droplet-shelf-service#set-holds-open-_)).

### Settings is deeper than it looks

The Settings content column resolves from the live window: base width minus the sidebar, floor 380 pt, cap 900 pt
([`SettingsChrome.swift:99–109`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/DesignSystem/SettingsChrome.swift#L99)).
Within it:

- **Pages are unlimited and nest.** `makeSettingsPage(id:)` is asked for whatever id a link or
  `openSettingsPage(_:title:)` names, and "a page can link to further pages the same way"
  ([SettingsPagesProviding](https://getdroppy.app/docs/droppykit/api/settings-pages-providing)).
- **History is Droppy's.** `goBackInSettings()` steps back one level, per call, with the parent page's title restored
  ([workspace service](https://getdroppy.app/docs/droppykit/api/droplet-workspace-service#go-back-in-settings)).
- **Each page gets a toolbar cluster** — button, menu, switch, search field, or a glass pill around a control of your
  own — since 1.18.0. It must stay narrow: "a text pill or two, a round one and a switch"; overflow goes to AppKit's
  overflow menu whole ([settings panes](https://getdroppy.app/docs/droppykit/settings-panes#a-page-s-controls-in-the-toolbar)).
- **Settings search** can surface your rows via `settingsSearchEntries`.

DropClip is the proof of depth: seven top-level pages plus per-action, per-extension and per-AI-preset pages, all
rendered as pages of Droppy's Settings. It encodes a navigation path as a page id (`path:general/action/xyz`) and calls
`goBackInSettings()` once per level
([`DropClipSettingsNavigation.swift:23–49`](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/Droppy/DropClipSettingsNavigation.swift#L23)).
That is the cheapest way to get a real hierarchical app UI in Droppy today.

The limits are stylistic, not structural: no page header of your own, no bar of buttons on the page, Droppy's rows and
controls only, sentence case, `.bordered` buttons. A page that reads as a second app is sent back.

### `DroppyPanelSurface` is not a panel service

This matters for the surface map. `DroppyPanelSurface` is **a background material** — Droppy's launcher glass, or
`.regularMaterial` outside Droppy — that you put behind a panel you created yourself
([API](https://getdroppy.app/docs/droppykit/api/droppy-panel-surface),
[`DroppyPanelSurface.swift`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/DesignSystem/DroppyPanelSurface.swift)).
There is no `DropletPanelService`: no host-managed panel size, count, stacking or lifecycle. What the SDK adds is:

- `DroppyPanelActivation.begin(for:returningTo:)` — makes Droppy active and the panel key while it is up, and hands the
  foreground back on `finish()`; without it, a non-activating panel gets mouse-move events only intermittently while
  Droppy is in the background ([API](https://getdroppy.app/docs/droppykit/api/droppy-panel-activation)).
- `DroppyKitSurfaceBridge.panelSurfaceProvider` — the host's glass behind your content.
- The `launcher` capability and catalog bridge, if the panel is a command palette.

Everything else is ordinary AppKit, and yours to tear down in `deactivate()`.

## 2. Store precedent

| Droplet | What it proves | What it does not prove |
| --- | --- | --- |
| **DropClip** | A droplet can own a floating `NSPanel` (`.nonactivatingPanel`, `.popUpMenu` level, `canJoinAllSpaces` + `fullScreenAuxiliary`) and put Droppy's glass behind it. A deep Settings tree (7+ page families, nested editors) is acceptable as the app's settings UI. | Not an app window: the bar caps at 312 pt, the search palette is 340 pt wide with 6 rows. Its panel is summoned and dismissed, never persistent. |
| **DockDoor** | A droplet can own the *entire* feature surface as panels: a hover preview panel, a full preview window, a search window — sized to content and clamped to `screen.visibleFrame`, over the Dock, non-activating. Ten settings pages behind it. | The panel is a transient hover artifact, not a 900 × 600 document window. It also carries a GPL-3.0 exception; not a licence precedent. |
| **Sales** | A dense data widget is viable: 460 pt solo card, content-derived height, total + comparison + sparkline + per-store breakdown. Charts on the shelf are real. | No takeover at all: its "whole day" view is the shelf widget. Dense ≠ large. |

Sources:
[DropClip panel](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/UI/Popup/PopupPanel.swift#L66),
[DropClip metrics](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dropclip/Sources/DropClip/UI/Popup/PopupMetrics.swift#L112),
[DockDoor panel](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/Sources/DockDoor/Views/Hover%20Window/Shared%20Components/SharedPreviewWindowCoordinator.swift#L83),
[DockDoor pages](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/dockdoor/Sources/DockDoor/DockDoorSettings.swift#L17),
[Sales widget](https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/sales/Sources/Sales/SalesWidget.swift#L27).

Read together: **the panel escape hatch is sanctioned for palette-shaped, summoned surfaces.** No Store droplet ships a
persistent multi-pane app window, and the design guidelines call a droplet that reads as "a foreign window bolted onto
the notch" the most common reason a submission is sent back
([design](https://getdroppy.app/docs/droppykit/design)).

## 3. Recommended surface map

| Section | Surface | Why |
| --- | --- | --- |
| **Now Playing** | Shelf widget (solo, ~440 × 200–260, `.fixed`) | Artwork, title/artist, progress, scrobble state and transport controls all fit; Droppy's own media widget is this shape. `setHoldsOpen` while a scrobble session runs if it must survive pointer-leave. |
| **Live status** | Live activity | "Now scrobbling" / "Queued" in 37 pt, with honest priority. Hides when the shelf opens; never the only control surface. |
| **Track detail** (bio, album, similar) | Expanded surface, presented from the widget | Needs the 900 pt canvas; image + text + a couple of actions. No typing, so it is read-and-tap. |
| **History** | Expanded surface, section 1 of the takeover | 12–15 rows per screen with day headers, scrolls, tap opens track detail. Suppress `.autoCollapse`, keep outside-click with a visible close. |
| **Charts** | Expanded surface, section 2 | Charts need width; a 300 pt plot plus header/legend/range pills fits 899 × 558. A sparkline belongs in the widget (Sales precedent). |
| **Collage** | Expanded surface, section 3 | 4 columns × ~150 pt tiles fit; tap a tile for the album. Export/share is a toolbar-free action row at the bottom. |
| **Friends** | Expanded surface, section 4 (list ↔ profile) — or Settings pages if it is management-heavy | Two-pane or push-style inside the takeover works at this width; it needs no keyboard. |
| **Search** | **Palette panel** (`NSPanel` + `DroppyPanelSurface` + `DroppyPanelActivation`), opened by a global shortcut — or a `.keyboardFocusable` shelf widget as the no-window fallback | The only surface that accepts typing *and* shows results. This is exactly what the launcher/panel API is for, and both precedents are palettes. |
| **Accounts** (Last.fm, ListenBrainz, Libre.fm, Pleroma) | Settings pane + one page per service | Secrets in Keychain, service-specific fields, connect/disconnect/refresh. Typing and confirmation dialogs work here natively. |
| **Edits & blocks** | Settings pages (list → editor), toolbar `+`/menu, `goBackInSettings()` | CRUD with rules, confirmation dialogs and long lists is what Settings pages are best at. DropClip proves the depth. |
| **Scrobble events / errors** | HUD (card for actionable failures, strip for confirmations) | Transient feedback, no navigation. Do not put retry logic behind a HUD alone; the shelf widget and Settings hold the durable state. |
| **Menu bar tile** | Skip initially | Symbol + title tile with a detail view; no size control, no Store precedent (no published droplet declares `menu-bar`). It is a launcher entry, not a canvas. |

### What that costs

- **Section switching is internal**, not window management: one segmented control or Droppy's `floatingNavLane`, and the
  takeover keeps its identity while the content changes. Do not present a new surface per section — presentation identity
  matters, and re-presenting pre-empts.
- **Search is a second surface**, so it cannot be open *beside* History. That is acceptable for a palette; it is not
  acceptable if the design wants a persistent search sidebar.
- **Nothing is persistent except the shelf widget.** The takeover is summoned; History position, scroll offset and filters
  must live in the droplet's model and be restored on next present.

## 4. Hard limits, in one list

1. **Takeover width floor 352 / 370**, height floor 0; ceiling 66 % of the display less chrome.
2. **One takeover at a time**, globally, across all droplets.
3. **No supported keyboard path in a takeover.** No focus policy, no focus request, no documented key handling.
4. **Takeover dismissal is the default**; suppressing it is allowed only with your own visible way out.
5. **Shelf widget height is clamped to 48–480**; a taller design is refused, not scrolled.
6. **The shelf is one row**, 2–4 widgets grouped; there is no second row for droplet widgets.
7. **Live activity is one seat**, compact only (`makeExpanded` is not mounted), and loses the notch to any Droppy
   activity; external droplets do not hold the companion pill today.
8. **HUD is one slot**, no keyboard, auto-dismissing.
9. **Settings column is 380–900 pt**, the toolbar cluster is intentionally tiny, and a page must look native.
10. **A droplet panel has no host management**: you own level, key status, screen clamping, focus return and teardown.
11. **Everything runs on Droppy's main actor**; a blocking call in a takeover is a frozen notch.

## 5. If the ceiling is too low

It is too low for exactly two ambitions, and both have an answer:

- **"A real window with a sidebar, 1200 pt wide."** Not available as a Droppy surface. The nearest legitimate thing is a
  droplet-owned panel sized to ~900 × 600, which is a new pattern in the Store and will be reviewed against the "foreign
  window" rule. It is not forbidden — DockDoor's full preview window is large — but it is a design argument you have to
  win, not a default.
- **"Two app surfaces visible at once"** (e.g. History beside Now Playing). Not possible with SDK surfaces. Either compose
  both inside the one takeover, or accept a panel (which can be persistent, because you own it) plus the notch for status.

The largest *safe* UI, then, is: **takeover ≈ 900 × 558 with internal section navigation, a 480 pt-tall shelf widget, and
a deep Settings tree** — with an optional palette panel for typing. That is enough for Now Playing, History, Charts,
Collage, Search and Friends, provided every section is a view inside the takeover rather than a window of its own.

## 6. Open questions this research does not settle

- Whether a persistent droplet panel (as opposed to a summoned one) passes Store review; no droplet ships one.
- Whether the 66 % ceiling holds on very large displays or is additionally capped (the formula is only visible in the
  harness, which mirrors the host).
- Whether a takeover can ever become key in a future DroppyKit; today the SDK exposes no path, so designs must not assume it.
- HUD slot behaviour with two different ids in flight (the harness models a single `currentHUD`; the docs only specify
  same-id replacement).

## Sources

Primary:

- [DroppyKit guide](https://getdroppy.app/docs/droppykit) · [API index](https://getdroppy.app/docs/droppykit/api)
- [Shelf widgets](https://getdroppy.app/docs/droppykit/shelf-widgets) · [Expanded surfaces](https://getdroppy.app/docs/droppykit/expanded-surfaces) ·
  [Settings panes](https://getdroppy.app/docs/droppykit/settings-panes) · [Live activities](https://getdroppy.app/docs/droppykit/live-activities) ·
  [Launchers](https://getdroppy.app/docs/droppykit/launchers) · [Host support](https://getdroppy.app/docs/droppykit/host-support) ·
  [Design](https://getdroppy.app/docs/droppykit/design) · [Good citizen](https://getdroppy.app/docs/droppykit/good-citizen) ·
  [Harness](https://getdroppy.app/docs/droppykit/harness) · [Submitting](https://getdroppy.app/docs/droppykit/submitting)
- SDK source: [`DroppyShellMetrics`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/DesignSystem/NotchShellShape.swift),
  [`DroppySettingsLayoutMetrics`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/DesignSystem/SettingsChrome.swift),
  [`DroppyLiveActivityMetrics`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/DesignSystem/LiveActivityMetrics.swift),
  [`ExpandedSurfaceProviding`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/Capabilities/ExpandedSurfaceProviding.swift),
  [`DroppyPanelSurface`](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKit/DesignSystem/DroppyPanelSurface.swift),
  [harness ceiling](https://gitlab.com/droppyformac1/droppykit/-/blob/main/Sources/DroppyKitHarness/HarnessWindow.swift)
- Store: [repository](https://gitlab.com/droppyformac1/droplets) · [DropClip](https://gitlab.com/droppyformac1/droplets/-/tree/main/droplets/dropclip) ·
  [DockDoor](https://gitlab.com/droppyformac1/droplets/-/tree/main/droplets/dockdoor) · [Sales](https://gitlab.com/droppyformac1/droplets/-/tree/main/droplets/sales)
