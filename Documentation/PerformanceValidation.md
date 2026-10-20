# Timeline and map performance validation

This document records reproducible validation steps for the startup, Timeline,
day-map, and History Map performance work tracked by #176–#180.

## Environment and evidence

Source-level and automated validation can run in CI and on a developer Mac.
Cold/warm launch latency, frame hitches, MapKit tile contention, and peak memory
need a physical iPhone with a representative local store. No device traces or
before/after measurements are checked into this change unless they were captured
on hardware; do not infer performance numbers from simulator runs.

On 2026-10-20, the focused iOS Simulator run on iPhone 18 Pro (iOS 27.0)
passed 14 tests across `DayMapSnapshotCacheTests`,
`HistoryMapScalabilityTests`, `TimelineDayPresentationStagingTests`, and
`TimelineDayNavigationWorkerTests`. The `Moves` scheme built for generic iOS
Simulator and generic macOS destinations. Physical-device p50/p95 and hitch
measurements remain outstanding.

## Build and test

Discover the current schemes and destinations before running these commands:

```sh
xcodebuild -list -project Moves.xcodeproj
xcodebuild -showdestinations -scheme Moves -project Moves.xcodeproj
```

Run the focused test classes for launch reliability, day navigation, selected-day
presentation, snapshot invalidation, and History Map aggregation first. Then run
the full `MovesTests` suite on an iOS Simulator and build the `Moves` scheme for
both `generic/platform=iOS` and `generic/platform=macOS`. Record Xcode version,
destination, test command, and result. The `Moves Mac` scheme currently has no
configured build action in this checkout, so use the main scheme for the macOS
build.

## Physical-device procedure

Use one ordinary database and one large database containing at least ten years
of activity and 10,000 imported route files. Keep the same device, OS build,
power mode, network condition, and database for before/after runs. Do not include
coordinates, visit labels, or other location data in diagnostic logs.

For each database, collect at least 10 cold launches and 10 warm launches. Use
the existing startup signposts to record tap-to-first-usable-Today, container
open, minimum-state ready, first Timeline rows, and map-ready intervals. Report
p50 and p95, plus main-thread stalls over 16.7 ms. Repeat with network disabled
and with pending CloudKit changes where test accounts allow.

In Instruments, use Time Profiler, SwiftUI, Core Animation Hitches, SwiftData /
Core Data fetch and fault events, and Allocations. Record:

- main-thread fetch/fault duration and count during launch and day changes;
- first useful Timeline row and first correct map overlay;
- snapshot memory/disk cache hit rate and MapKit snapshot job count;
- frame hitch count while scrolling, swiping days, opening the full-screen map,
  and panning/zooming History Map;
- peak resident memory and overlay/coordinate counts for day, month, year, and
  all-time views.

Exercise rapid date switching, midnight boundaries, tracking, import and
Exploration processing, CloudKit updates, edit/delete invalidation, background
and foreground transitions, full-screen map dismissal, and repeated History Map
period changes. Verify that cancelled requests do not publish stale content.

## Fixture scale

Automated tests should use deterministic in-memory SwiftData fixtures with a
small empty case, sparse multi-year case, dense day, and large case representing
4,000+ day records and 10,000+ imported route records. Keep route payloads
synthetic and avoid real location history. The large fixture validates bounded
querying, cancellation, aggregate correctness, and memory-sensitive caps; it is
not a substitute for device profiling.
