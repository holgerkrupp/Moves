# Quick Look route previews

Moves ships two isolated app extensions for GPX, TCX, KML, and GeoJSON files:

- `Moves Quick Look Preview` provides a static map preview with local route metadata.
- `Moves Quick Look Thumbnails` provides a compact map thumbnail.

Both extensions use `Packages/RouteFileKit` and never initialize SwiftData, CloudKit, location services, or the import queue. Generic JSON, XML, ZIP, and folder types are intentionally not included in either extension's `QLSupportedContentTypes` declaration.

## Map tiles on macOS

macOS Quick Look extensions are sandboxed from network-backed services, including MapKit tile fetching. The `com.apple.security.network.client` entitlement does not change that boundary. On current macOS releases, MapKit can therefore return a beige tile grid while local route overlays still render. The preview intentionally switches to a local route-only canvas on macOS 15 and later and tells the user to open the file in Moves for the full Apple Maps background. This avoids making a network request from Quick Look or silently sending route-location data to a third-party tile service.

The main Moves app remains the supported place for full MapKit rendering. When a route is opened with Moves, the app renders a light static map and stores it in the shared application-group cache, keyed by the route contents. A later Quick Look request can consume that image without network access. Routes that have not been opened in Moves yet use the local route-only fallback.

The macOS targets are sandboxed and signed with read-only user-selected-file entitlements. This is required for PlugInKit to register the embedded extensions in Finder.

## Resource limits

`RouteFileParseLimits.quickLook` currently accepts files up to 100 MiB, retains at most 500,000 parsed points, and renders at most 8,000 display points for a full preview or 1,500 for a thumbnail. Display simplification is deterministic and preserves segment endpoints and dateline boundaries; summary statistics use the full parsed tracks.

Inputs that exceed a file, point, or track limit fail as a normal Quick Look error. Malformed XML/JSON and valid files with no supported route geometry also fail without touching the Moves store.

## Verification

The pure parser/geometry suite can be run with:

```sh
swift test --package-path Packages/RouteFileKit
```

The Xcode project builds the macOS and iOS/iPadOS extension variants through the `Moves Quick Look Preview` scheme. On-device Finder, Files, iCloud Drive, and File Provider validation remains environment-dependent; Quick Look receives and reads the file URL supplied by the system and does not use provider-specific download APIs.

After installing a new app build, verify registration with `pluginkit -m -Avvv -i de.holgerkrupp.Moves.quicklook.preview` and `pluginkit -m -Avvv -i de.holgerkrupp.Moves.quicklook.thumbnails`.
