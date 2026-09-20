# Moves on iPhone Duo

Analysis date: 2026-09-14. This plan applies Apple’s iPhone Duo HIG to the current SwiftUI/MapKit timeline app.

Revision 2026-09-14 (second pass): re-read the published HIG page and added layout options per surface, control ownership, bar-free map surfaces, an explicit open/close transition contract, and the conditional reserved regions — including the Dynamic Island expansion that the route-tracking Live Activity causes. Nothing from the first pass was removed.

Revision 2026-09-19: added implementation details from Apple’s new preparation technology overview, including container-specific bar behavior, toolbar APIs, arrangement-hosting cautions, and pose-by-pose validation.

## Recommendation in one sentence

Keep the timeline’s single-screen continuity on the outer display, and replace the current phone-landscape heuristics with fold-aware map/content arrangements that naturally become side by side in book poses and map-above-controls in tabletop poses.

## Device and platform baseline

| Surface | Hardware size | Pixels | Early @3x layout target | Size-class guidance |
| --- | --- | --- | --- | --- |
| Outer display | 5.4-inch | 1398 × 2034 | about 466 × 678 pt | Compact-width iPhone experience |
| Inner display | 7.6-inch | 1878 × 2670 | about 626 × 890 pt or 890 × 626 pt after rotation | Regular width and regular height |

The point values are derived planning sizes, not Apple-published viewport contracts. Read the scene’s actual proposal, safe-area insets, and reserved regions. The vertical system bar, cameras, fold, and Split View can all make the usable rectangle smaller and asymmetric.

Build with iOS 27.1 SDK to opt into full inner-display layout and the system’s vertical bars. Keep the current iOS 26 deployment target with guarded fallbacks.

## Apple rules that drive this plan

- Build for compact and regular size classes across a continuous range of sizes. Don’t detect six poses and swap six layouts.
- The inner display is regular in both dimensions and doesn’t honor supported interface orientations in the traditional way. Use size classes and view geometry, not orientation assumptions.
- The active fold is a division reserved region. Interactive controls and indivisible map overlays must avoid it.
- Standard navigation, lists, scroll views, sheets, alerts, and menus adapt automatically. Use an arrangement for custom map/control splits.
- A split arrangement follows aspect and fold: side by side when wider than tall, top/bottom when taller. An overlay arrangement preserves a foreground/background relationship and moves the layers to separate regions when partially folded.
- In tabletop pose, the upper region is best for content viewed at a distance and the lower region for touch controls.
- Hinge angle is suitable for optional effects, not layout. Layout should respond to proposals and reserved regions.

## Current code assessment

- `LandscapeLayoutSettings.isLandscapePhone` in `Moves/ContentView.swift` checks `UIDevice.current.userInterfaceIdiom == .phone && size.width > size.height`. Duo is still a phone, so it enters this custom branch whenever the inner display is wide, but the branch has no knowledge of the fold.
- `LandscapeSplitView` is a custom `HStack` with a fixed 300–390 point control pane. It is reused by the day timeline and place/move details. This is an excellent semantic map/control split, but it can place the fold through either pane and won’t change to top/bottom in tabletop use.
- `DayTimelinePageContent` uses a map + timeline split in wide geometry and a single scrolling map/timeline/summary stack otherwise.
- `PlaceMapDetailView` and `MoveMapDetailView` use a map with a bottom control overlay in portrait and `LandscapeSplitView` in landscape. That existing ZStack/HStack behavior maps directly to Apple’s overlay/split arrangement choices.
- The root timeline uses standard `NavigationStack`, a page-style `TabView` for days, sheets, and standard toolbar placements. This should adapt well if state stays above layout switches.
- `MoveMapDetailView` places transport mode in a principal toolbar item and wraps Health, Share, route editing, and Delete inside one `HStack` toolbar item. That custom group is likely to be inflexible in a vertical bar.
- Maps already occupy flexible space, but custom annotations, edit handles, status panels, and bottom overlays need explicit fold checks.

## Layout by display and pose

| Configuration | Proposed Moves layout | Fold behavior |
| --- | --- | --- |
| Closed, outer display | Keep the current day header and page-style timeline. Use a compact map strip above timeline entries and transport summary. | Preserve selected day, page position, map selection, live tracking state, and open detail while opening. |
| Fully open, inner landscape | Timeline: large map plus selected timeline/list pane. Place/Move detail: map plus controls. Prefer a system split arrangement or a regular-width navigation split where the content hierarchy supports it. | The map and controls become stable semantic panes; don’t size the control pane from total width alone. |
| Fully open, inner portrait | Use map above timeline/controls or a bounded overlay card. Standard navigation bars remain horizontal. | Avoid turning portrait into a stretched one-column dashboard; keep readable content width and full feature access. |
| Partially folded like a book | One usable region for map, the other for places/moves or edit controls. Selection on the list highlights the corresponding map feature. | The fold is the gutter. Map pins, selected-route affordances, text fields, and buttons never intersect it. |
| Tabletop/laptop pose | Upper region: map/route visualization and passive tracking status. Lower region: place/move editing, route tools, day navigation, and tracking controls. | This is the strongest use case for a top/bottom split or an overlay arrangement displaced into separate regions. |
| Standing/tent/edge poses | Favor the map or timeline based on the active task, with a discoverable standard control to reveal the companion pane. | Avoid custom centered banners and selection callouts that can land at the fold. |
| Split View multitasking | Collapse to the existing single-column timeline/detail as width narrows. | Every intermediate width must work; preserve the current day and active route rather than rebuilding the page. |

## Layout options per surface

The pose table says what should happen. These are the containers that can produce it, so the choice is deliberate rather than a leftover of the current landscape heuristic.

### Day timeline

| Option | Container | When it is right | Cost |
| --- | --- | --- | --- |
| T1 — split arrangement | Primary: map. Secondary: timeline entries and transport summary. | The recommended inner-display default. Horizontal split when the region is wider than tall, vertical when taller, and one pane per usable region in a book or tabletop pose, with no pose detection at all. | Needs the selection relationship between list and map to be explicit. |
| T2 — map header above a scrolling timeline | The outer display and narrow Split View widths. This is close to the current compact behaviour. | Keep it as the compact form and the iOS 26 fallback. | The map is small; recentre and zoom must stay easy. |
| T3 — full-bleed map with an overlay card | A map-first reading of the day, where the timeline is a card over the map. | Attractive on the inner display in portrait, and it maps directly to an overlay arrangement: flat puts the card over the map, a partial fold moves map and card into separate regions. | The card must never be the only way to reach a control. |

A split arrangement can be limited to a single axis. Use that rather than writing pose checks: if the timeline is unreadable stacked under a short map, constrain the day-timeline arrangement to the horizontal axis and let the system fall back to a single pane when the region cannot host both.

### Place and Move detail

| Option | Container | When it is right |
| --- | --- | --- |
| D1 — overlay arrangement | Primary: control card. Secondary: map. | Matches today’s compact design directly. Flat keeps the card over the map; a partial fold moves the card and the map into separate regions with no new layout code. An overlay arrangement can also collapse its secondary view when the card should stand alone. |
| D2 — split arrangement | Map and controls as peers. | Route editing, where the map needs maximum area and the tools must stay permanently visible rather than floating over the thing being edited. |
| D3 — `LandscapeSplitView` as-is | iOS 26 fallback. | Keep it, but derive the pane width from what both panes need rather than from a 300–390 point constant applied to any wide scene. |

### Map surfaces and bars

The HIG allows a full-width layout for visual interfaces where bars are not necessary, and it explicitly allows the mixed form: a background or header spanning the full width while scrollable content stays inset. For Moves that reads as:

- The map layer spans the full display, under the bar and to the edges, because context benefits from it.
- Every interactive or readable overlay — annotations, route handles, the selection callout, tracking banners, recentre and compass controls — stays inside the safe area, clear of the vertical bar, the camera regions, and the active fold.
- A dedicated full-screen map mode with no bars is legitimate for viewing a route at a distance in a tabletop or tent pose, provided the same actions remain reachable elsewhere, since functionality must be equal across poses.

### Navigation workspaces

Use a standard two-column `NavigationSplitView` for the app-level hierarchy whenever the scene has a regular horizontal size class. This is separate from the map/timeline arrangement inside the detail column: standard navigation owns date or statistics selection, while the detail retains its map and content layout.

- Timeline sidebar: show the 60 most recent dates in descending order. Each `List` row has a full date plus a concise, text-first summary: places, moves, and total distance; a day without activity says so plainly. Selecting a row binds to `selectedDayKey`, which remains authoritative for the compact pager and the detail column.
- Timeline detail: retain the existing day header, map/timeline view, route controls, and navigation destinations. The sidebar date picker is the standard path to older dates.
- Statistics & Search sidebar: replace the compact segmented picker with standard rows for Statistics, Search Visits, and Connections. Keep the chosen section's existing cards, visit search field, and connection controls in the detail column; do not add a third nested split solely for search results.
- Compact scenes retain the page-style day pager and the statistics segmented picker. This makes the new navigation additive rather than a different iPhone app.

Do not place the fold-aware `ArrangementView` inside either `NavigationSplitView` or a sidebar `List`. It belongs at the root of the selected day/detail content, with scrolling hosted by its child panes.

## Concrete changes

### 1. Replace `isLandscapePhone` with a layout policy

Do not interpret `width > height` as “landscape phone.” It conflates a flat inner display, a partially folded device, Split View, and other resizable scenes.

On iOS 27.1, make map/control layout a content arrangement:

- Day timeline: primary map; secondary timeline plus transport summary; split style.
- Place and Move details: primary map; secondary control card; overlay style if the compact design should remain map-with-card, or split style if both panes are peers.
- Keep the containing `NavigationStack` outside `ArrangementView`.

Use the existing portrait and `LandscapeSplitView` code only as the iOS 26 fallback. For the fallback, base the choice on the proposed space needed by both panes, not idiom or interface orientation.

### 2. Choose split versus overlay deliberately

For the day timeline, neither the map nor places/moves list should obscure the other during browsing, so a split arrangement is the clearest choice.

For place/move details, the current compact experience is a control card over a map. That maps to an overlay arrangement:

- flat/compact: control card in front of the map;
- partial fold: map and card move into separate usable regions;
- query `overlayArrangementZIndex` only to reduce or expand the card’s presentation, not to infer a pose.

If route editing needs maximum map area and permanent tools, use split instead. Keep the choice task-based rather than device-based.

### 3. Keep map content edge to edge and controls safe

Let the map background fill the display where it improves context, but keep these inside safe/reserved geometry:

- `MapLocationDot` selection halo and tappable annotations;
- manual route waypoints and drag handles;
- tracking banners, place fields, transport picker, share/edit/delete controls;
- scale/compass controls if custom positioned;
- the selected route’s contextual card.

The map can continue visually beneath the fold, but never require reading a label or manipulating a route at the folding region. When fitting camera regions, calculate from usable regions so important route endpoints aren’t centered under the fold.

### 4. Make the timeline’s selection relationship explicit

The wide `DayTimelinePageContent` already enables selection between the list and map. Preserve `mapSelection` while geometry changes. A fold/open transition must not clear the selected place, move, live route, or sample.

Consider lifting `mapSelection` to the day page or a scene-local model if replacing the layout container causes it to reset. Keep `selectedDayKey` authoritative; derive `selectedPageIndex` from it after data changes so a fold during CloudKit refresh doesn’t jump to a different date.

### 5. Rebuild the detail toolbar for vertical bars

- Keep Back/Close at the top of the vertical axis.
- Use separate toolbar items or a real `ToolbarItemGroup` for Health, Share, Edit Route, and Delete instead of one custom `HStack`.
- Give every item a `Label` containing symbol and title. The system can show the symbol vertically and the title in overflow.
- Give tracking start/stop and active editing high visibility; Share and Health can overflow; destructive Delete should remain discoverable without displacing the core editing action.
- The transport-mode control is contextual to the route, so keep it close to route controls if the principal placement cannot fit the vertical axis.
- Replace any app-owned generic ellipsis with the iOS 27.1 system overflow menu.

### 6. Treat tracking as durable state, not layout state

Opening, closing, rotating, or partially folding must not interrupt `MovesLocationCaptureManager`, route collection, Live Activity updates, uploads, or map calculation. Keep those services independent of view identity.

Persist or lift scene-local UI state that should survive a shell replacement:

- selected day/date-picker target;
- selected map/timeline entry;
- current map camera where preserving it is helpful;
- open place/move detail and unsaved label/comment/manual-route edits;
- open route-tracking settings and tracking duration choice;
- share-gallery date range.

Avoid saving every continuous fold update. State changes should be semantic and low frequency.

### 7. Keep each control with the content it affects

The HIG asks that controls belonging to a content area other than the trailing one stay with that area, using the controls above Mail’s message list as the example. Moves has a clean split once two panes are visible:

- Map-owned: recentre, map style, pitch and zoom affordances, route-edit handles, and the selected-route callout. These belong on or beside the map pane, not in the trailing vertical bar.
- Timeline-owned: day navigation, the date picker, and any entry filtering. These belong above the timeline pane, because they act on the list.
- Item-owned: transport mode, Health, Share, Edit Route, and Delete. These belong to the detail pane’s own toolbar. Transport mode in particular is contextual to the route being viewed, so proximity matters more than its current principal placement.

On the outer display there is a single content area and everything folds into one vertical bar, which is correct. The distinction only starts to matter once the inner display shows the map and a list at once.

### 8. Reduce text-only bar buttons and drop the custom HStack

Labels that contain text stay in a horizontal bar; only symbols move to the vertical axis. Two consequences for the detail screen:

- The single toolbar item wrapping Health, Share, Edit Route, and Delete in an `HStack` is opaque to the system. It cannot be prioritised, split, or overflowed item by item, and it will not lay out sensibly on a vertical axis. Replace it with separate items or a real `ToolbarItemGroup`.
- Give each item a `Label` with both a symbol and a title. The symbol is what appears on the vertical axis; the title is what appears in the overflow menu, so it is required even for icon-only items.
- Keep Back or Close at the top of the vertical axis, followed by the prominent action. That is the standard placement order, and it is what makes the app feel native here.
- Do not override the default placement to force the bar horizontal again.

## Reserved-region integration

Use division and occlusion regions only around custom map content:

```swift
GeometryReader { proxy in
    let fold = proxy.reservedRegions(kind: .division).first?.frame
    let cameras = proxy.reservedRegions(kind: .occlusion).map(\.frame)
    MovesMapLayout(size: proxy.size, fold: fold, occlusions: cameras)
}
```

The fold’s division region is active only while folded and zero-width while flat. Query inactive regions only for high-level planning. Use `onHingeChange` only for an optional visual treatment, such as subtly reducing map pitch during folding; reset the effect when the hinge isn’t partially open.

## The open and close transition

The pose table describes states. This section describes the event between them.

### Promotion and demotion

| Outer display (compact) | Inner display (regular) | Rule on transition |
| --- | --- | --- |
| Day timeline, nothing selected | Map plus timeline for the same day | The day is identified by `selectedDayKey`, never by page index. Derive the page index from the key afterwards. |
| Day timeline with a pushed place or move | Map plus detail pane for that item, with the item selected on the map | The push becomes the selection, and the map keeps or gently adjusts its camera rather than re-fitting from scratch. |
| Place detail with the control card open | Overlay arrangement, or the card in its own usable region | The card’s scroll position, editing state, and unsaved label or comment survive. |
| Route editing in progress | Same editing session in the detail or map pane | Waypoints, undo stack, and the in-progress route are untouched. |
| Share or settings sheet presented | Same sheet, repositioned away from the fold | The selected date range and options survive. |

### What may move and what may not

- May change: whether the map and list are side by side, stacked, or overlaid; the map’s visible area within reason; the bar axis; the size of the control pane.
- May not change: the selected day, the selected place or move, the tracking state, the map’s centre of interest, unsaved edits, or which field has focus.
- Re-fit the map camera to the new usable region rather than keeping a literal camera rectangle. Fit from the route’s coordinates so its endpoints do not end up centred under the fold, but do not animate a long camera flight just because the device moved; the HIG asks for small adjustments, not rearrangement.

### Interactions that are in flight when the device moves

- A map pan or pinch in progress when the region resizes. Gesture translation is measured against a view whose bounds are changing. Resolve gestures against the current proposal on every update, and prefer ending a gesture cleanly over applying stale deltas.
- A route waypoint being dragged. The handle must stay under the finger in the new geometry or the gesture must end at its last committed position. It must never drop the waypoint into the folding region.
- Active route tracking. `MovesLocationCaptureManager`, the Live Activity, distance and duration accumulation, and any upload continue uninterrupted. A fold is a layout event and must not touch the capture pipeline.
- Focus in a place label or comment field survives only if the field’s identity is stable across the container swap.

## Reserved regions that come and go

Three of the four regions are conditional, so a correct layout can become wrong with no navigation at all. Moves is the app in this set where this matters most, because its Live Activity is active precisely during its core task.

| Region | When present | What Moves must do |
| --- | --- | --- |
| Outer front-facing camera | Always, on the outer display | Never pin custom chrome to the top of the vertical axis. |
| Dynamic Island expansion | While a Live Activity is running | `MovesRouteTrackingLiveActivityWidget` runs for the whole of a tracking session, so on the outer display the camera region is expanded for most of the time the app is actually in use. The top of the vertical axis grows accordingly. Any custom banner, day header, or map overlay that assumed a fixed top inset will be clipped while tracking. Lay out from the live safe area and test the tracking case specifically, not just the idle case. |
| Inner front-facing camera | Only while the camera is active | Moves does not use the camera. Do not reserve space for it. |
| Folding region | Only while partially open | Zero-width when flat. Use the active frame to form the gutter between map and list, and to decide whether both panes still clear their minimums. |

## Implementation order

1. Build with Xcode 27.1 and capture current behavior on all Device Hub poses.
2. Replace the `UIDevice`/aspect heuristic in the shared map-control container with an availability-guarded arrangement.
3. Preserve day and map selection across layout-container changes.
4. Add reserved-region-aware map fitting and interactive overlay placement.
5. Split and prioritize toolbar items for the vertical bar.
6. Tune tabletop typography and control sizes for viewing distance without making other poses oversized.

## Verification matrix

- Snapshot planning sizes: 466 × 678, 678 × 466, 626 × 890, and 890 × 626 points. These do not simulate the fold.
- In Device Hub, open, close, rotate, and slowly fold while viewing today, an older day, a selected place, and a selected move.
- Repeat while real route tracking is active. Confirm location capture, timer, distance, Live Activity, and auto-stop state continue uninterrupted.
- Tabletop: confirm the map is readable above and all editing/tracking controls are reachable below.
- Book: confirm list selection and map selection stay synchronized and no annotation/button/drag handle intersects the fold.
- Test the largest accessibility text sizes, VoiceOver traversal, Reduce Motion, right-to-left layout, and asymmetric safe areas.
- Test Split View beside another app at all divider positions, including manual route editing and share/settings sheets.
- Confirm sheets, alerts, confirmation dialogs, and popovers choose a usable region and don’t cover the active editing target.

### Additional checks from the second pass

- Start route tracking on the outer display and confirm the expanded Dynamic Island never covers the day header, tracking banner, or map controls.
- Fold and unfold repeatedly during an active tracking session. Distance, duration, Live Activity content, and auto-stop behaviour are unaffected.
- Begin a map pan and a waypoint drag, then fold mid-gesture. The map does not jump and the waypoint does not land in the folding region.
- Open the device with a place detail pushed. The item becomes the detail pane and stays selected on the map; closing re-pushes the same item.
- Confirm map controls stay with the map pane and day navigation stays with the timeline pane once both are visible.
- Verify the detail toolbar’s actions are individually prioritised and appear by name in the overflow menu.
- Check the map re-fits to the new usable region without a long camera animation, and without centring a route endpoint under the fold.

## Technology-overview refinements (2026-09-19)

Apple’s preparation overview clarifies where vertical bars actually appear. A detail bar in a multi-column split view can be vertical, while sidebar/content bars remain horizontal; inspector bars are horizontal. On the outer display, detail sheets default to vertical bars. On the inner display, centered and leading sheets have horizontal bars, but trailing sheets have vertical ones. Check every route/place sheet and popover in its actual placement. Use `toolbarVerticalEdge` for any custom map-control offset, not a width or orientation guess; use `presentationPlacement(_:)` or `toolbarVerticalBehavior(_:)` only when a particular sheet needs a deliberate placement or opt-out.

The current `HStack` of Health, Share, Edit Route, and Delete is especially important to replace: Apple says a custom-view toolbar item cannot appear vertically, just as a title-only item cannot. Give each action an icon and title, use `axisBehavior(_:)` and `visibilityPriority(_:)`, put infrequent/destructive actions in `ToolbarOverflowMenu`, and reserve `.topBarPinnedTrailing` for a prominent Done. Let the map itself extend under a vertical bar with `backgroundExtensionEffect()` if useful, but keep tracking status, route labels, compass, and recenter controls inside the safe area.

Do not place the proposed map/timeline or map/control `ArrangementView` inside the timeline `ScrollView`, a `List`, or a nested split view: the overview warns that this can make one child inaccessible. Arrange peer content at the detail root below `NavigationStack`, with scrolling inside a child pane. Split style yields side-by-side in wide space and top/bottom in tall space; overlay style keeps the control card above the map when flat and separates them at an active fold. If the host clips either child, retain the existing responsive HStack/VStack plus reserved-region handling. Rotate the phone in closed, flat-open, book, tabletop, and tent poses while testing route detail sheets, popovers, and an active tracking Live Activity.

## Sources

- [Preparing your app for iPhone Duo — Technology Overview](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- [Designing for iPhone Duo — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [iPhone Duo technical specifications](https://www.apple.com/iphone-duo/specs/)
- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)
- [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
