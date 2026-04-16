//
//  MovesTimelineViews.swift
//  Raul
//
//  Timeline, map strip, and row rendering extracted from ContentView.
//

import Foundation
import MapKit
import SwiftData
import SwiftUI

struct DayTimelinePage: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    let dayKey: String

    @State private var dayTimeline: DayTimeline?
    @State private var loadErrorMessage: String?

    var body: some View {
        Group {
            if let dayTimeline {
                DayTimelinePageContent(dayTimeline: dayTimeline)
            } else {
                loadingState
            }
        }
        .task(id: dayKey) {
            await loadDayTimeline()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(MovesPalette.routeTracking)

            Text(loadErrorMessage ?? "Loading day")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .panelSurface()
    }

    @MainActor
    private func loadDayTimeline() async {
        let descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { timeline in
                timeline.dayKey == dayKey
            },
            sortBy: [SortDescriptor(\DayTimeline.dayStart, order: .forward)]
        )

        do {
            dayTimeline = try modelContext.fetch(descriptor).first
            loadErrorMessage = dayTimeline == nil ? "Day not found" : nil
        } catch {
            dayTimeline = nil
            loadErrorMessage = "Could not load day"
        }
    }
}

struct DayTimelinePageContent: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    let dayTimeline: DayTimeline
    private static let transientStopMaximumDuration: TimeInterval = 5 * 60

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
    }

    private var timelineEntries: [TimelineEntry] {
        let places = dayTimeline.places
            .filter { !shouldHidePlaceFromTimeline($0) }
            .map(TimelineEntry.place)
        let moves = dayTimeline.moves.map(TimelineEntry.move)
        var entries = (places + moves).sorted { $0.startDate < $1.startDate }

        if let firstMove = dayTimeline.moves.min(by: { $0.timelineStartDate < $1.timelineStartDate }),
           let startPlace = firstMove.startPlace {
            let hasDayStartPlaceAlready = dayTimeline.places.contains(where: { $0.id == startPlace.id })

            if !hasDayStartPlaceAlready {
                let startEntry = TimelineEntry.start(
                    place: startPlace,
                    timestamp: firstMove.timelineStartDate.addingTimeInterval(-1)
                )

                if let firstMoveIndex = entries.firstIndex(where: { entry in
                    if case .move(let move) = entry {
                        return move.id == firstMove.id
                    }
                    return false
                }) {
                    entries.insert(startEntry, at: firstMoveIndex)
                } else {
                    entries.insert(startEntry, at: 0)
                }
            }
        }

        if let liveRouteSnapshot {
            entries.append(.liveRoute(liveRouteSnapshot))
        }

        return entries
    }

    private func shouldHidePlaceFromTimeline(_ place: VisitPlace) -> Bool {
        if hasExplicitUserLabel(place) {
            return false
        }

        let hasIncomingMove = dayTimeline.moves.contains { $0.endPlace?.id == place.id }
        let hasOutgoingMove = dayTimeline.moves.contains { $0.startPlace?.id == place.id }

        if place.departureDate == nil {
            return hasOutgoingMove
        }

        guard let departureDate = place.departureDate else {
            return false
        }

        let duration = departureDate.timeIntervalSince(place.arrivalDate)
        let isShortTransitStop = duration < Self.transientStopMaximumDuration
        return isShortTransitStop && hasIncomingMove && hasOutgoingMove
    }

    private func hasExplicitUserLabel(_ place: VisitPlace) -> Bool {
        !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var transportSummaryMetrics: [DayTransportSummaryMetric] {
        var durationByBucket: [DayTransportBucket: TimeInterval] = [:]
        var distanceByBucket: [DayTransportBucket: CLLocationDistance] = [:]

        for move in dayTimeline.moves {
            guard let bucket = DayTransportBucket(move.transportMode) else { continue }

            durationByBucket[bucket, default: 0] += move.timelineDuration
            distanceByBucket[bucket, default: 0] += max(move.distanceMeters, 0)
        }

        return DayTransportBucket.allCases.map { bucket in
            DayTransportSummaryMetric(
                id: bucket.rawValue,
                title: bucket.title,
                symbolName: bucket.symbolName,
                tint: bucket.tint,
                duration: durationByBucket[bucket, default: 0],
                distanceMeters: distanceByBucket[bucket, default: 0]
            )
        }
    }

    private var hasTransportSummaryData: Bool {
        transportSummaryMetrics.contains {
            $0.duration > 0 || $0.distanceMeters > 0
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                DayMapStrip(dayTimeline: dayTimeline)

                if timelineEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No segments for this day yet.")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))

                        if dayTimeline.samples.count > 0 {
                            Text("\(dayTimeline.samples.count) location sample\(dayTimeline.samples.count == 1 ? "" : "s") captured. Waiting for the next visit or move.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Grant location access above to start recording visits and movement.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelSurface()
                } else {
                    timelineList
                        .panelSurface()
                }

                DayTransportSummaryView(
                    metrics: transportSummaryMetrics,
                    hasData: hasTransportSummaryData
                )
                .panelSurface()
            }
            .padding(.bottom, 24)
        }
    }

    private var timelineList: some View {
        VStack(spacing: 0) {
            ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { index, entry in
                timelineRow(
                    for: entry,
                    isFirst: index == 0,
                    isLast: index == timelineEntries.count - 1
                )

                if index < timelineEntries.count - 1 {
                    Divider()
                        .padding(.leading, 82)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineRow(for entry: TimelineEntry, isFirst: Bool, isLast: Bool) -> some View {
        switch entry {
        case .place(let place):
            NavigationLink {
                PlaceMapDetailView(place: place)
            } label: {
                StorylineRow(entry: entry, isFirst: isFirst, isLast: isLast)
            }
            .buttonStyle(.plain)

        case .move(let segment):
            NavigationLink {
                MoveMapDetailView(segment: segment)
            } label: {
                StorylineRow(entry: entry, isFirst: isFirst, isLast: isLast)
            }
            .buttonStyle(.plain)

        case .liveRoute:
            StorylineRow(entry: entry, isFirst: isFirst, isLast: isLast)

        case .start:
            StorylineRow(entry: entry, isFirst: isFirst, isLast: isLast)
        }
    }
}

struct DayTransportSummaryMetric: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let tint: Color
    let duration: TimeInterval
    let distanceMeters: CLLocationDistance
}

enum DayTransportBucket: String, CaseIterable {
    case automotive
    case cycling
    case walking

    init?(_ mode: TransportMode) {
        switch mode {
        case .automotive:
            self = .automotive
        case .cycling:
            self = .cycling
        case .walking, .running:
            self = .walking
        case .stationary, .unknown:
            return nil
        }
    }

    var title: String {
        switch self {
        case .automotive:
            return "Car"
        case .cycling:
            return "Bike"
        case .walking:
            return "Walking"
        }
    }

    var symbolName: String {
        switch self {
        case .automotive:
            return "car.fill"
        case .cycling:
            return "figure.outdoor.cycle"
        case .walking:
            return "figure.walk"
        }
    }

    var transportMode: TransportMode {
        switch self {
        case .automotive:
            return .automotive
        case .cycling:
            return .cycling
        case .walking:
            return .walking
        }
    }

    var tint: Color {
        switch self {
        case .automotive:
            return Color(red: 0.18, green: 0.47, blue: 0.92)
        case .cycling:
            return Color(red: 0.10, green: 0.63, blue: 0.54)
        case .walking:
            return Color(red: 0.95, green: 0.64, blue: 0.18)
        }
    }
}

struct DayTransportSummaryView: View {
    let metrics: [DayTransportSummaryMetric]
    let hasData: Bool

    private var totalDuration: TimeInterval {
        metrics.reduce(0) { $0 + $1.duration }
    }

    private var totalDistance: CLLocationDistance {
        metrics.reduce(0) { $0 + $1.distanceMeters }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Day Summary")
                .font(.system(size: 17, weight: .bold, design: .rounded))

            if !hasData {
                Text("No movement summary available yet.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metrics) { metric in
                    summaryRow(metric)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("Total")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(DurationFormatter.text(for: totalDuration))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.85))

                    Text(
                        Measurement(value: max(totalDistance, 0), unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road))
                    )
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.85))
                }
            }
        }
    }

    @ViewBuilder
    private func summaryRow(_ metric: DayTransportSummaryMetric) -> some View {
        HStack(spacing: 10) {
            Image(systemName: metric.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 18)

            Text(metric.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(DurationFormatter.text(for: metric.duration))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.82))

            Text(
                Measurement(value: max(metric.distanceMeters, 0), unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            )
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.82))
        }
        .opacity(metric.duration > 0 || metric.distanceMeters > 0 ? 1 : 0.45)
    }
}

struct DayMapStrip: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    let dayTimeline: DayTimeline

    @State private var camera: MapCameraPosition
    @State private var historicalRoutes: [RenderedRoute]

    private var placeMarkers: [PlaceMarker] {
        dayTimeline.places
            .sorted(by: { $0.arrivalDate < $1.arrivalDate })
            .map { PlaceMarker(id: $0.id, title: $0.displayTitle, coordinate: $0.coordinate) }
    }

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
    }

    private var latestSampleCoordinate: CLLocationCoordinate2D? {
        dayTimeline.samples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .last?
            .coordinate
    }

    private var historicalRouteCoordinates: [CLLocationCoordinate2D] {
        historicalRoutes.flatMap { $0.coordinates }
    }

    private var historicalRouteRefreshKey: String {
        let sortedMoves = dayTimeline.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
        return sortedMoves.map { move in
            let start = Int(move.timelineStartDate.timeIntervalSince1970.rounded())
            let end = Int(move.endDate.timeIntervalSince1970.rounded())
            let sampleKey = move.samples.map { sample in
                "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
            }
            .joined(separator: ",")

            return "\(move.id.uuidString)|\(move.transportMode.rawValue)|\(start)|\(end)|\(sampleKey)"
        }
        .joined(separator: ",")
    }

    private var cameraRefreshKey: String {
        let sortedPlaces = dayTimeline.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
        let placeKey = sortedPlaces.map { place in
            let arrival = Int(place.arrivalDate.timeIntervalSince1970.rounded())
            let departure = Int((place.departureDate ?? place.arrivalDate).timeIntervalSince1970.rounded())
            return "\(place.id.uuidString)|\(arrival)|\(departure)"
        }
        .joined(separator: ",")

        let latestSampleKey = dayTimeline.samples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .last
            .map { sample in
                "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
            }
            ?? "none"

        let liveKey = liveRouteSnapshot?.id ?? "none"
        return [historicalRouteRefreshKey, placeKey, liveKey, latestSampleKey].joined(separator: "|")
    }

    init(dayTimeline: DayTimeline) {
        self.dayTimeline = dayTimeline

        let renderedRoutes = Self.renderedRoutes(for: dayTimeline)
        let allCoordinates = Self.allCoordinates(
            for: dayTimeline,
            routeCoordinates: renderedRoutes.flatMap { $0.coordinates },
            liveRouteCoordinates: []
        )
        let cameraCoordinates = allCoordinates.isEmpty
            ? Self.latestSampleCoordinate(for: dayTimeline).map { [$0] } ?? []
            : allCoordinates
        _camera = State(initialValue: .region(MapRegionFactory.region(for: cameraCoordinates)))
        _historicalRoutes = State(initialValue: renderedRoutes)
    }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(historicalRoutes) { route in
                if route.coordinates.count > 1 {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(route.tint.opacity(0.95), lineWidth: route.lineWidth)
                }
            }

            if let liveRouteSnapshot,
               liveRouteSnapshot.coordinates.count > 1 {
                MapPolyline(coordinates: liveRouteSnapshot.coordinates)
                    .stroke(MovesPalette.routeTracking.opacity(0.95), lineWidth: 5)
            }

            ForEach(placeMarkers) { marker in
                Marker(marker.title, coordinate: marker.coordinate)
                    .tint(MovesPalette.place)
            }

            if placeMarkers.isEmpty,
               historicalRouteCoordinates.isEmpty,
               (liveRouteSnapshot?.coordinates.isEmpty ?? true),
               let latestSampleCoordinate {
                Marker("Captured location", coordinate: latestSampleCoordinate)
                    .tint(liveRouteSnapshot == nil ? MovesPalette.start : MovesPalette.routeTracking)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MovesPalette.border.opacity(0.8), lineWidth: 1)
        }
        .task(id: historicalRouteRefreshKey) {
            await refreshHistoricalRouteCoordinates()
        }
        .task(id: cameraRefreshKey) {
            refreshCamera()
        }
    }

    @MainActor
    private func refreshHistoricalRouteCoordinates() async {
        let sortedMoves = dayTimeline.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
        var renderedRoutes: [RenderedRoute] = []
        renderedRoutes.reserveCapacity(sortedMoves.count)

        for move in sortedMoves {
            let matched = await RoadRouteMatcher.matchedCoordinates(for: move)
            renderedRoutes.append(
                RenderedRoute(
                    id: move.id.uuidString,
                    coordinates: matched,
                    usesHighAccuracyRouteTracking: move.usesHighAccuracyRouteTracking
                )
            )
        }

        historicalRoutes = renderedRoutes
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                print("Failed to persist matched route cache: \(error.localizedDescription)")
            }
        }
        refreshCamera()
    }

    @MainActor
    private func refreshCamera() {
        let liveCoordinates = liveRouteSnapshot?.coordinates ?? []
        let allCoordinates = Self.allCoordinates(
            for: dayTimeline,
            routeCoordinates: historicalRouteCoordinates,
            liveRouteCoordinates: liveCoordinates
        )
        let cameraCoordinates = allCoordinates.isEmpty
            ? Self.latestSampleCoordinate(for: dayTimeline).map { [$0] } ?? []
            : allCoordinates

        if !cameraCoordinates.isEmpty {
            camera = .region(MapRegionFactory.region(for: cameraCoordinates))
        }
    }

    private static func renderedRoutes(for dayTimeline: DayTimeline) -> [RenderedRoute] {
        dayTimeline.moves
            .sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
            .map { move in
                let fallback = MoveRouteGeometry.rawCoordinates(for: move)
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)

                return RenderedRoute(
                    id: move.id.uuidString,
                    coordinates: move.cachedRouteCoordinates(for: signature) ?? fallback,
                    usesHighAccuracyRouteTracking: move.usesHighAccuracyRouteTracking
                )
            }
    }

    private static func allCoordinates(
        for dayTimeline: DayTimeline,
        routeCoordinates: [CLLocationCoordinate2D],
        liveRouteCoordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        let placeCoordinates = dayTimeline.places.map(\.coordinate)
        return routeCoordinates + liveRouteCoordinates + placeCoordinates
    }

    private static func latestSampleCoordinate(for dayTimeline: DayTimeline) -> CLLocationCoordinate2D? {
        dayTimeline.samples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .last?
            .coordinate
    }
}

struct StorylineRow: View {
    let entry: TimelineEntry
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(entry.clockText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 10)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : MovesPalette.rail)
                    .frame(width: 2, height: 12)

                ZStack {
                    Circle()
                        .fill(entry.iconTint.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: entry.iconName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(entry.iconTint)
                }

                Rectangle()
                    .fill(isLast ? Color.clear : MovesPalette.rail)
                    .frame(width: 2)
                    .frame(minHeight: 28, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 26)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.titleText)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.92))

                Text(entry.subtitleText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.72))

                if let tertiary = entry.tertiaryText {
                    Text(tertiary)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum TimelineEntry: Identifiable {
    case place(VisitPlace)
    case move(MoveSegment)
    case liveRoute(LiveRouteTrackingSnapshot)
    case start(place: VisitPlace, timestamp: Date)

    var id: String {
        switch self {
        case .place(let place):
            return "place-\(place.id.uuidString)"
        case .move(let segment):
            return "move-\(segment.id.uuidString)"
        case .liveRoute(let snapshot):
            return "live-\(snapshot.id)"
        case .start(let place, let timestamp):
            return "start-\(place.id.uuidString)-\(timestamp.timeIntervalSince1970)"
        }
    }

    var startDate: Date {
        switch self {
        case .place(let place):
            return place.arrivalDate
        case .move(let segment):
            return segment.timelineStartDate
        case .liveRoute(let snapshot):
            return snapshot.latestDate
        case .start(_, let timestamp):
            return timestamp
        }
    }

    var clockText: String {
        switch self {
        case .place(let place):
            return Self.timeString(from: place.arrivalDate)
        case .move(let segment):
            return Self.timeString(from: segment.timelineStartDate)
        case .liveRoute(let snapshot):
            return Self.timeString(from: snapshot.latestDate)
        case .start(_, let timestamp):
            return Self.timeString(from: timestamp)
        }
    }

    var iconName: String {
        switch self {
        case .place:
            return "mappin.circle.fill"
        case .move(let segment):
            return segment.transportMode.symbolName
        case .liveRoute:
            return "location.fill.viewfinder"
        case .start:
            return "sunrise.fill"
        }
    }

    var iconTint: Color {
        switch self {
        case .place:
            return MovesPalette.place
        case .move(let segment):
            return segment.routeDisplayTint
        case .liveRoute:
            return MovesPalette.routeTracking
        case .start:
            return MovesPalette.start
        }
    }

    var titleText: String {
        switch self {
        case .start(let place, _):
            return "Start at \(place.displayTitle)"
        case .place(let place):
            return place.displayTitle
        case .move(let segment):
            let start = segment.startPlace?.displayTitle ?? "Unknown start"
            let end = segment.endPlace?.displayTitle ?? "Unknown destination"
            return "\(start) to \(end)"
        case .liveRoute:
            return "Live route tracking"
        }
    }

    var subtitleText: String {
        switch self {
        case .start:
            return "Carried over from previous day"

        case .place(let place):
            guard let departure = place.departureDate else {
                return "In progress"
            }
            return "Stayed \(DurationFormatter.text(for: departure.timeIntervalSince(place.arrivalDate)))"

        case .move(let segment):
            let duration = DurationFormatter.text(for: segment.timelineDuration)
            let distance = Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            return "\(segment.transportMode.title)   \(duration)   \(distance)"
        case .liveRoute(let snapshot):
            let duration = DurationFormatter.text(for: snapshot.duration)
            let distance = Measurement(value: max(snapshot.distanceMeters, 0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))

            if snapshot.sampleCount == 0 {
                return "Waiting for the first live GPS fix"
            }

            return "\(snapshot.sampleCount) live fixes   \(duration)   \(distance)"
        }
    }

    var tertiaryText: String? {
        switch self {
        case .move(let segment):
            if let stepCount = segment.stepCount {
                return "\(stepCount) steps"
            }
            return nil
        case .liveRoute(let snapshot):
            if snapshot.sampleCount == 0 {
                return "Tracking will start as soon as GPS provides the first fix."
            }
            return "Last update \(snapshot.latestDate.formatted(date: .omitted, time: .shortened))"
        default:
            return nil
        }
    }

    private static func timeString(from date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

struct PlaceMarker: Identifiable {
    let id: UUID
    let title: String
    let coordinate: CLLocationCoordinate2D
}
