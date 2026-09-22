# Moves

Moves can optionally upload recorded location samples to [Dawarich](https://dawarich.app), [Reitti](https://github.com/dedicatedcode/reitti), [GeoPulse](https://geopulse.cc), [OwnTracks Recorder](https://github.com/owntracks/recorder), and [Traccar](https://www.traccar.org). Configure each destination independently in Settings → Integrations. Cloud and self-hosted URLs are supported, secrets are stored in the iOS Keychain, and local-network HTTP is allowed while remote servers require HTTPS. Automatic uploads only include newly recorded points; uploading existing local history requires a separate confirmation for each destination.

## Siri and Shortcuts

Moves provides App Intents for starting and stopping temporary real-route GPS tracking,
checking tracking status, controlling low-energy background tracking, getting timeline
summaries, and exporting timeline data as GPX, GeoJSON, or CSV. The most common actions
are suggested automatically in Siri and the Shortcuts app.

Example phrases include “Start route tracking with Moves”, “Stop GPS tracking in Moves”,
“What’s my Moves tracking status”, “Summarize my day with Moves”, and “Export my Moves
data”. Export requires device authentication because timeline files contain location data.

The “Toggle Route Tracking” App Shortcut is designed for the iPhone Action button: assign
it in Settings > Action Button > Shortcut to use one press for starting and stopping the
high-accuracy GPS session. Starting tracking also starts a Live Activity with elapsed time,
remaining time, and distance on the Lock Screen and Dynamic Island.

Visited places are donated as App Entities to an app-scoped named Spotlight index. Tapping a
result opens the matching day in Moves. The index includes the place name and visit time,
but deliberately excludes coordinates and comments. On iOS 27, `IndexedEntityQuery`
allows Spotlight to request targeted or full reindexing.

Moves is an iOS app that builds a private day-by-day timeline of where you were and how you moved between places.

It uses on-device location + motion signals and stores timeline data locally with SwiftData, with private iCloud sync through CloudKit enabled for backup and device transfer.

## Features

- Daily timeline with places and move segments
- Transport mode detection (`walking`, `running`, `cycling`, `automotive`, etc.)
- Automatic place naming (reverse geocoding) plus manual place labels
- Map previews for places and routes
- Spotlight search for visited places with deep links back to their timeline day
- AppIntent-configurable Home Screen, Lock Screen, and accessory widgets
- A route-tracking Live Activity for the Lock Screen and Dynamic Island
- Siri, Shortcuts, Spotlight suggestions, and iPhone Action button support through App Intents
- Export from Settings:
  - GPX (`.gpx`)
  - GeoJSON (`.geojson`)
  - CSV (`.csv`, places + moves)
- Background tracking support (visit monitoring + significant location changes)

## Requirements

- Xcode project: `Moves.xcodeproj`
- SwiftUI + SwiftData app
- iOS deployment target in project settings: `26.0`
- Location permission (Always is recommended for background tracking)
- Motion permission (used to improve transport mode inference)

## Getting Started

1. Open `Moves.xcodeproj` in Xcode.
2. Select the `Moves` scheme.
3. Choose an iPhone simulator or a physical device.
4. Build and run.
5. On first launch, allow location access (and motion access when prompted).

## How It Works

- `MovesLocationCaptureManager` starts low-power tracking via:
  - visit monitoring
  - significant location change monitoring
- Captured data is normalized and persisted to SwiftData models:
  - `DayTimeline`
  - `VisitPlace`
  - `MoveSegment`
  - `LocationSample`
- `DefaultTimelineAssembler` links visits and samples into movement segments and infers transport mode.

## Privacy

- Timeline data is stored locally on the device and syncs to the user's private iCloud container when available.
- CloudKit backs up the timeline and restores it on a new device signed into the same Apple ID.
- Export is user-initiated from the in-app Settings screen.

## Project Structure

- `Moves/MovesApp.swift` app entry and model container setup
- `Moves/ContentView.swift` timeline UI, maps, settings, export logic
- `Moves/LocationChange.swift` location capture, motion classification, timeline assembly
- `Moves/VisitedLocation.swift` models and SwiftData repository
- `MovesTests/TimelineAssemblerTests.swift` repository and classifier unit tests

## Data limitations

Transport inference is best-effort. Visit monitoring and significant-location
updates are intentionally sparse, and Core Motion can return an activity that
started before the represented visit-to-visit leg. Moves therefore uses the
available location trace as supporting evidence, but cannot reconstruct every
transport change or guarantee a mode for every leg.

Step totals come from the system pedometer for the move interval. They may be
unavailable when Motion & Fitness access is denied, on devices without
pedometer data, or for imported Health and route files. A later import or sync
that has no step total does not replace steps already stored for the same move.

Health workout route imports preserve route geometry and the workout's declared
activity type; they do not provide a pedometer total unless one is separately
available for the move interval. Imported routes remain authoritative for their
own declared mode and are not reclassified by the sparse-location heuristic.

## Running Tests

Use Xcode (`Product > Test`) with the `MovesTests` target.

If you prefer command line, run tests with `xcodebuild test` using your local Xcode setup and a simulator destination.
