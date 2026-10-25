# In-app user guide inventory

The offline help content is implemented in `Moves/MovesHelp.swift` as the shared
`MovesHelpTopic` library. iPhone and iPad users open it from **Settings →
Documentation**. On macOS, **Help → Moves Help** includes these shared topics and
keeps the Mac-specific import queue and keyboard shortcut guides in
`Mac/MovesMacApp.swift`.

Keep this inventory aligned with the topic IDs, entry points, and platform notes
below. The in-app content is the user-facing guide; this file records its scope
and source locations rather than duplicating the guide text.

| Topic ID | User-facing topic | Platforms | Main feature references |
| --- | --- | --- | --- |
| `startHere` | Start Here | iOS, macOS | `Moves/MovesApp.swift`, `Mac/MovesMacApp.swift` |
| `timeline` | Your Timeline | iOS, macOS (Mac has tailored timeline help) | `Moves/ContentView.swift`, `Moves/MovesTimelineViews.swift`, `Moves/MovesDetailViews.swift`, `Mac/MovesMacApp.swift` |
| `tracking` | Tracking & Battery | iOS, macOS overview; recording on iPhone/Watch only | `Moves/MovesSettingsView.swift`, `Moves/RouteTrackingLiveActivity.swift`, `Moves Watch App/` |
| `places` | Places & Regular Places | iOS, macOS overview | `Moves/MovesKnownLocationsView.swift`, `Moves/MovesDetailViews.swift`, `Moves/OtherVisitsAtPlaceView.swift` |
| `routes` | Routes & Move Mapping | iOS, macOS | `Moves/MovesHelp.swift`, `Moves/MovesHistoryMapView.swift`, `Moves/MovesDetailViews.swift`, `Moves/RouteFileImportConfiguration.swift` |
| `searchAndStatistics` | Search, Statistics & Connections | iOS; overview on macOS | `Moves/MovesStatisticsSearchView.swift` |
| `importing` | Importing Data | iOS, macOS | `Moves/RouteFileImport.swift`, `Moves/RouteFileImportConfiguration.swift`, `Moves/ImportQueueViews.swift`, `Moves/HealthWorkoutRouteImporter.swift` |
| `exportAndBackup` | Export, Backup & Sharing | iOS, macOS | `Moves/MovesSettingsView.swift`, `Moves/DailyTimelineBackup.swift`, `Moves/MovesShareViews.swift`, `Mac/MovesMacApp.swift` |
| `sync` | iCloud Sync & Multiple Devices | iOS, macOS; includes per-device import/export times, deferred status, and privacy-safe diagnostics | `Moves/SyncDiagnostics.swift`, `Moves/CloudDataPresencePublisher.swift`, `Moves/CrossDeviceWorkCoordinator.swift` |
| `integrationsAndPrivacy` | Integrations & Privacy | iOS, macOS overview | `Moves/DawarichSync.swift`, `Moves/MovesSettingsView.swift` |
| `widgetsAndWatch` | Widgets, Shortcuts & Apple Watch | iOS, watchOS; supported widgets/actions only | `Moves/MovesAppIntents.swift`, `Moves Widgets/`, `Moves Watch App/` |
| `troubleshooting` | Troubleshooting & FAQ | iOS, macOS | `Moves/MovesHelp.swift`, `Moves/MovesSettingsView.swift` |

## Accuracy and maintenance

- Describe only released user-facing behavior. `#if DEBUG` Exploration and
  Photos controls are not released capabilities and must not be advertised.
- Check the current UI and implementation when changing a feature. Keep platform
  guidance accurate: iPhone records location; macOS provides browsing and data
  workflows, not native location recording.
- Preserve the transport-mode rules and palette-derived colors in Move Mapping.
  Do not create a second static mapping/color table.
- Distinguish recorded GPS, imported geometry, map-matched display routes, and
  inferred flight connectors. An inferred connector is never recorded GPS.
- Keep help bundled and text-only unless an accessible, privacy-safe static
  illustration is useful. Opening help must not fetch timeline history or
  initialize tracking, import, map, network, or CloudKit work.
- Update this inventory and the shared help content whenever a documented
  feature, setting, permission, platform entry point, or workflow changes.
- Keep the separate Mac help topics for the sidebar, inspector, route import
  queue, Quick Look, and keyboard shortcuts when those workflows change.
