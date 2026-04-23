//
//  MovesRouteSupport.swift
//  Raul
//
//  Shared route rendering helpers used by timeline and detail views.
//

import Foundation
import SwiftUI
import MapKit
import UIKit

enum MovesPalette {
    static let backgroundTop = Color(uiColor: .systemGroupedBackground)
    static let backgroundBottom = Color(uiColor: .secondarySystemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemBackground)
    static let border = Color(uiColor: .separator).opacity(0.45)
    static let rail = Color(uiColor: .separator).opacity(0.75)
    static let textFieldBackground = Color(uiColor: .tertiarySystemBackground)
    static let frostedFill = Color(uiColor: .tertiarySystemFill)
    static let place = Color(red: 0.18, green: 0.68, blue: 0.47)
    static let move = Color(red: 0.16, green: 0.52, blue: 0.93)
    static let start = Color(red: 0.95, green: 0.64, blue: 0.18)
    static let routeTracking = Color(red: 0.02, green: 0.69, blue: 0.78)
}

enum DurationFormatter {
    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func text(for duration: TimeInterval) -> String {
        formatter.string(from: max(duration, 0)) ?? "0m"
    }
}

struct LiveRouteTrackingSnapshot {
    let startDate: Date
    let latestDate: Date
    let sampleCount: Int
    let distanceMeters: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]

    var id: String {
        [
            Int(startDate.timeIntervalSince1970.rounded()),
            Int(latestDate.timeIntervalSince1970.rounded()),
            sampleCount,
            Int(distanceMeters.rounded())
        ]
        .map(String.init)
        .joined(separator: "|")
    }

    var duration: TimeInterval {
        max(latestDate.timeIntervalSince(startDate), 0)
    }
}

struct RenderedRoute: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let usesHighAccuracyRouteTracking: Bool
    let transportMode: TransportMode

    var shadowCoordinates: [CLLocationCoordinate2D] {
        guard transportMode == .plane,
              let start = coordinates.first,
              let end = coordinates.last else {
            return []
        }
        return [start, end]
    }

    var tint: Color {
        if usesHighAccuracyRouteTracking {
            return MovesPalette.routeTracking
        }

        switch transportMode {
        case .train:
            return Color(red: 0.09, green: 0.58, blue: 0.68)
        case .plane:
            return Color(red: 0.26, green: 0.50, blue: 0.89)
        default:
            return MovesPalette.move
        }
    }

    var shadowTint: Color {
        tint.opacity(0.32)
    }

    var lineWidth: CGFloat {
        if usesHighAccuracyRouteTracking {
            return 5
        }

        switch transportMode {
        case .plane:
            return 4.5
        case .train:
            return 4.25
        default:
            return 4
        }
    }

    var shadowLineWidth: CGFloat {
        transportMode == .plane ? 2.5 : 0
    }
}

struct RouteCoordinateStoragePoint: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RouteCoordinateStorage {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> Data? {
        let payload = coordinates.map(RouteCoordinateStoragePoint.init)
        return try? encoder.encode(payload)
    }

    static func decode(_ data: Data?) -> [CLLocationCoordinate2D] {
        guard let data else { return [] }

        guard let payload = try? decoder.decode([RouteCoordinateStoragePoint].self, from: data) else {
            return []
        }

        return payload.map(\.coordinate)
    }
}

@MainActor
func liveRouteTrackingSnapshot(
    for dayTimeline: DayTimeline,
    captureManager: MovesLocationCaptureManager
) -> LiveRouteTrackingSnapshot? {
    guard let endsAt = captureManager.temporaryRouteTrackingEndsAt, endsAt > .now else {
        return nil
    }

    let sortedSamples = dayTimeline.samples.sorted(by: { $0.timestamp < $1.timestamp })
    let preferredSamples = sortedSamples.preferredRouteDisplaySamples

    let liveSamples = liveRouteSessionSamples(
        from: preferredSamples,
        startedAt: captureManager.temporaryRouteTrackingStartedAt
    )

    let startDate = captureManager.temporaryRouteTrackingStartedAt
        ?? liveSamples.first?.timestamp
        ?? captureManager.lastCaptureAt
        ?? endsAt
    let latestDate = liveSamples.last?.timestamp ?? captureManager.lastCaptureAt ?? startDate
    let anchorCoordinate = liveRouteAnchorCoordinate(for: dayTimeline, startDate: startDate)

    var coordinates = liveSamples.map(\.coordinate)
    if let anchorCoordinate {
        coordinates.insert(anchorCoordinate, at: 0)
    }

    coordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
        coordinates,
        minimumDistanceMeters: 4
    )

    return LiveRouteTrackingSnapshot(
        startDate: startDate,
        latestDate: latestDate,
        sampleCount: liveSamples.count,
        distanceMeters: routeDistance(for: coordinates),
        coordinates: coordinates
    )
}

func liveRouteSessionSamples(
    from preferredSamples: [LocationSample],
    startedAt: Date?
) -> [LocationSample] {
    guard !preferredSamples.isEmpty else { return [] }

    if let startedAt {
        return preferredSamples.filter { $0.timestamp >= startedAt }
    }

    guard let lastSample = preferredSamples.last else {
        return []
    }

    let maximumGap: TimeInterval = 90 * 60
    var sessionSamples: [LocationSample] = [lastSample]
    var previousSample = lastSample

    for sample in preferredSamples.dropLast().reversed() {
        let gap = previousSample.timestamp.timeIntervalSince(sample.timestamp)
        if gap > maximumGap {
            break
        }

        sessionSamples.insert(sample, at: 0)
        previousSample = sample
    }

    return sessionSamples
}

func liveRouteAnchorCoordinate(
    for dayTimeline: DayTimeline,
    startDate: Date
) -> CLLocationCoordinate2D? {
    let sortedPlaces = dayTimeline.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
    if let anchorPlace = sortedPlaces.last(where: { $0.arrivalDate <= startDate }) {
        return anchorPlace.coordinate
    }
    return sortedPlaces.last?.coordinate
}

func routeDistance(for coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    guard coordinates.count > 1 else { return 0 }

    return zip(coordinates, coordinates.dropFirst()).reduce(0) { partialResult, pair in
        partialResult + RouteCoordinateOps.distanceMeters(from: pair.0, to: pair.1)
    }
}

enum MapRegionFactory {
    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latitudeDelta = max((maxLat - minLat) * 1.5, 0.01)
        let longitudeDelta = max((maxLon - minLon) * 1.5, 0.01)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

enum MoveRouteGeometry {
    private static let routeMatchingVersion = "route-v2"

    static func rawCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        let sampleCoordinates = move.samples.preferredRouteDisplaySamples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map(\.coordinate)

        var coordinates: [CLLocationCoordinate2D] = []
        if let start = move.startPlace?.coordinate {
            coordinates.append(start)
        }
        coordinates.append(contentsOf: sampleCoordinates)
        if let end = move.endPlace?.coordinate {
            coordinates.append(end)
        }

        return RouteCoordinateOps.dedupeSequentialCoordinates(
            coordinates,
            minimumDistanceMeters: 6
        )
    }

    static func cacheSignature(for move: MoveSegment, fallback: [CLLocationCoordinate2D]) -> String {
        var components: [String] = [
            routeMatchingVersion,
            move.id.uuidString,
            move.transportMode.rawValue,
            String(Int(move.timelineStartDate.timeIntervalSince1970.rounded())),
            String(Int(move.endDate.timeIntervalSince1970.rounded())),
            String(fallback.count)
        ]

        components.reserveCapacity(components.count + fallback.count)
        components.append(contentsOf: fallback.map { coordinate in
            let latitude = Int((coordinate.latitude * 10_000).rounded())
            let longitude = Int((coordinate.longitude * 10_000).rounded())
            return "\(latitude):\(longitude)"
        })

        return components.joined(separator: "|")
    }

    static func cacheKey(for move: MoveSegment, fallback: [CLLocationCoordinate2D]) -> Int {
        var hasher = Hasher()
        hasher.combine(routeMatchingVersion)
        hasher.combine(move.id)
        hasher.combine(move.transportMode.rawValue)
        hasher.combine(Int(move.timelineStartDate.timeIntervalSince1970.rounded()))
        hasher.combine(Int(move.endDate.timeIntervalSince1970.rounded()))
        hasher.combine(fallback.count)

        for coordinate in fallback {
            hasher.combine(Int((coordinate.latitude * 10_000).rounded()))
            hasher.combine(Int((coordinate.longitude * 10_000).rounded()))
        }

        return hasher.finalize()
    }
}

extension MoveSegment {
    var routeDisplayTint: Color {
        usesHighAccuracyRouteTracking ? MovesPalette.routeTracking : MovesPalette.move
    }
}

enum RouteCoordinateOps {
    static func dedupeSequentialCoordinates(
        _ coordinates: [CLLocationCoordinate2D],
        minimumDistanceMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }

        var deduped: [CLLocationCoordinate2D] = [first]
        deduped.reserveCapacity(coordinates.count)

        for coordinate in coordinates.dropFirst() {
            if distanceMeters(from: deduped[deduped.count - 1], to: coordinate) < minimumDistanceMeters {
                continue
            }
            deduped.append(coordinate)
        }

        if deduped.count == 1,
           let last = coordinates.last,
           distanceMeters(from: first, to: last) > 0 {
            deduped.append(last)
        }

        return deduped
    }

    static func sampleAnchors(
        from coordinates: [CLLocationCoordinate2D],
        maximumCount: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else {
            return coordinates
        }

        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        var anchors: [CLLocationCoordinate2D] = []
        anchors.reserveCapacity(maximumCount)

        for index in 0..<maximumCount {
            let rawIndex = Int((Double(index) * step).rounded(.toNearestOrAwayFromZero))
            anchors.append(coordinates[min(rawIndex, coordinates.count - 1)])
        }

        return dedupeSequentialCoordinates(anchors, minimumDistanceMeters: 25)
    }

    static func append(_ coordinates: [CLLocationCoordinate2D], to route: inout [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }

        if route.isEmpty {
            route.append(contentsOf: coordinates)
            return
        }

        let first = coordinates[coordinates.startIndex]
        if let last = route.last, distanceMeters(from: last, to: first) < 4 {
            route.append(contentsOf: coordinates.dropFirst())
            return
        }

        route.append(contentsOf: coordinates)
    }

    static func distanceMeters(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }
}

enum PlaneRouteGeometry {
    static func arcCoordinates(from fallback: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let start = fallback.first, let end = fallback.last else {
            return fallback
        }

        guard RouteCoordinateOps.distanceMeters(from: start, to: end) > 15 else {
            return [start, end]
        }

        return arcCoordinates(from: start, to: end)
    }

    private static func arcCoordinates(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let latitudeDelta = end.latitude - start.latitude
        let longitudeDelta = end.longitude - start.longitude
        let vectorLength = max(hypot(latitudeDelta, longitudeDelta), 0.0001)

        let midpoint = CLLocationCoordinate2D(
            latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2
        )

        let perpendicular = CLLocationCoordinate2D(
            latitude: -longitudeDelta / vectorLength,
            longitude: latitudeDelta / vectorLength
        )

        let span = max(abs(latitudeDelta), abs(longitudeDelta))
        let curvature = min(max(span * 0.35, 0.02), 5.5)
        let preferredVerticalDirection = midpoint.latitude >= 0 ? 1.0 : -1.0
        let bendSign = (perpendicular.latitude * preferredVerticalDirection) >= 0 ? 1.0 : -1.0

        var controlLatitude = midpoint.latitude + (perpendicular.latitude * curvature * bendSign)
        let controlLongitude = midpoint.longitude + (perpendicular.longitude * curvature * bendSign)

        // Keep the arch consistently above the shadow line in the north and below in the south.
        if (controlLatitude - midpoint.latitude) * preferredVerticalDirection <= 0 {
            controlLatitude = midpoint.latitude + (preferredVerticalDirection * max(curvature * 0.28, 0.012))
        }

        controlLatitude = min(max(controlLatitude, -85), 85)

        let control = CLLocationCoordinate2D(
            latitude: controlLatitude,
            longitude: controlLongitude
        )

        let pointCount = max(min(Int(span * 14), 84), 28)
        return (0...pointCount).map { index in
            let t = Double(index) / Double(pointCount)
            let inverseT = 1 - t

            let latitude =
                (inverseT * inverseT * start.latitude) +
                (2 * inverseT * t * control.latitude) +
                (t * t * end.latitude)

            let longitude =
                (inverseT * inverseT * start.longitude) +
                (2 * inverseT * t * control.longitude) +
                (t * t * end.longitude)

            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
}

@MainActor
enum RoadRouteMatcher {
    private static let memo = RouteMatchMemo()

    static func matchedCoordinates(for move: MoveSegment) async -> [CLLocationCoordinate2D] {
        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let cacheKey = MoveRouteGeometry.cacheKey(for: move, fallback: fallback)
        let cacheSignature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)

        if move.usesHighAccuracyRouteTracking {
            let coordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
                fallback,
                minimumDistanceMeters: 4
            )
            await memo.store(coordinates, for: cacheKey)
            move.storeCachedRouteCoordinates(coordinates, signature: cacheSignature)
            return coordinates
        }

        if let cached = move.cachedRouteCoordinates(for: cacheSignature) {
            await memo.store(cached, for: cacheKey)
            return cached
        }

        if let cached = await memo.cached(for: cacheKey) {
            move.storeCachedRouteCoordinates(cached, signature: cacheSignature)
            return cached
        }

        if let task = await memo.inFlightTask(for: cacheKey) {
            let coordinates = await task.value
            move.storeCachedRouteCoordinates(coordinates, signature: cacheSignature)
            return coordinates
        }

        let transportMode = move.transportMode
        let task = Task.detached(priority: .utility) {
            await resolveCoordinates(fallback: fallback, transportMode: transportMode)
        }
        await memo.setInFlightTask(task, for: cacheKey)

        let coordinates = await task.value
        await memo.setInFlightTask(nil, for: cacheKey)
        await memo.store(coordinates, for: cacheKey)
        move.storeCachedRouteCoordinates(coordinates, signature: cacheSignature)
        return coordinates
    }

    private static func resolveCoordinates(
        fallback: [CLLocationCoordinate2D],
        transportMode: TransportMode
    ) async -> [CLLocationCoordinate2D] {
        guard fallback.count > 1 else {
            return fallback
        }

        if transportMode == .plane {
            return PlaneRouteGeometry.arcCoordinates(from: fallback)
        }

        guard let transportType = mapTransportType(for: transportMode) else {
            return fallback
        }

        let anchors = RouteCoordinateOps.sampleAnchors(
            from: fallback,
            maximumCount: anchorLimit(for: transportMode)
        )
        guard anchors.count > 1 else {
            return fallback
        }

        var matchedCoordinates: [CLLocationCoordinate2D] = []
        var matchedSegmentCount = 0

        for pair in zip(anchors, anchors.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let segmentDistance = RouteCoordinateOps.distanceMeters(from: start, to: end)

            if segmentDistance < minimumMatchDistance(for: transportMode) {
                RouteCoordinateOps.append([start, end], to: &matchedCoordinates)
                continue
            }

            if let snappedSegment = await routeSegment(
                from: start,
                to: end,
                transportType: transportType
            ) {
                matchedSegmentCount += 1
                RouteCoordinateOps.append(snappedSegment, to: &matchedCoordinates)
            } else {
                RouteCoordinateOps.append([start, end], to: &matchedCoordinates)
            }
        }

        return matchedSegmentCount > 0
            ? RouteCoordinateOps.dedupeSequentialCoordinates(
                matchedCoordinates,
                minimumDistanceMeters: 6
            )
            : fallback
    }

    private static func routeSegment(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = mapItem(for: start)
        request.destination = mapItem(for: end)
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return nil }
            let coordinates = route.polyline.allCoordinates
            return coordinates.count > 1 ? coordinates : nil
        } catch {
            return nil
        }
    }

    private static func mapItem(for coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #unavailable(iOS 26.0) {
            return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return MKMapItem(location: location, address: nil)
    }

    private static func mapTransportType(for mode: TransportMode) -> MKDirectionsTransportType? {
        switch mode {
        case .automotive:
            return .automobile
        case .walking, .running:
            return .walking
        case .cycling:
            return .cycling
        case .train:
            return .transit
        case .plane:
            return nil
        case .stationary, .unknown:
            return nil
        }
    }

    private static func minimumMatchDistance(for mode: TransportMode) -> CLLocationDistance {
        switch mode {
        case .walking, .running:
            return 25
        case .cycling:
            return 35
        case .automotive:
            return 60
        case .train:
            return 90
        case .plane:
            return 120
        case .stationary, .unknown:
            return 60
        }
    }

    private static func anchorLimit(for mode: TransportMode) -> Int {
        switch mode {
        case .walking, .running:
            return 6
        case .cycling:
            return 6
        case .automotive:
            return 4
        case .train:
            return 5
        case .plane:
            return 2
        case .stationary, .unknown:
            return 4
        }
    }
}

actor RouteMatchMemo {
    private var cache: [Int: [CLLocationCoordinate2D]] = [:]
    private var inFlightTasks: [Int: Task<[CLLocationCoordinate2D], Never>] = [:]

    func cached(for key: Int) -> [CLLocationCoordinate2D]? {
        cache[key]
    }

    func store(_ coordinates: [CLLocationCoordinate2D], for key: Int) {
        cache[key] = coordinates
    }

    func inFlightTask(for key: Int) -> Task<[CLLocationCoordinate2D], Never>? {
        inFlightTasks[key]
    }

    func setInFlightTask(_ task: Task<[CLLocationCoordinate2D], Never>?, for key: Int) {
        inFlightTasks[key] = task
    }
}

extension MKPolyline {
    var allCoordinates: [CLLocationCoordinate2D] {
        guard pointCount > 0 else { return [] }

        var coordinates = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
