# Moves

Moves is an iOS app that builds a private day-by-day timeline of where you were and how you moved between places.

It uses on-device location + motion signals and stores timeline data locally with SwiftData.

## Features

- Daily timeline with places and move segments
- Transport mode detection (`walking`, `running`, `cycling`, `automotive`, etc.)
- Automatic place naming (reverse geocoding) plus manual place labels
- Map previews for places and routes
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

- Timeline data is stored locally on the device (SwiftData).
- No server sync is implemented in this project.
- Export is user-initiated from the in-app Settings screen.

## Project Structure

- `Moves/MovesApp.swift` app entry and model container setup
- `Moves/ContentView.swift` timeline UI, maps, settings, export logic
- `Moves/LocationChange.swift` location capture, motion classification, timeline assembly
- `Moves/VisitedLocation.swift` models and SwiftData repository
- `MovesTests/TimelineAssemblerTests.swift` repository and classifier unit tests

## Running Tests

Use Xcode (`Product > Test`) with the `MovesTests` target.

If you prefer command line, run tests with `xcodebuild test` using your local Xcode setup and a simulator destination.
