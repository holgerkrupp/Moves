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
import UIKit

enum MapMarkerDisplaySettings {
    static let showsBigMarkersKey = "showBigMapMarkers"
}

struct MapLocationDot: View {
    let tint: Color
    var isSelected = false

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Circle()
                            .stroke(tint, lineWidth: 3)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 3, x: 0, y: 1)
            }

            Circle()
                .fill(tint)
                .frame(width: isSelected ? 12 : 8, height: isSelected ? 12 : 8)
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
        }
    }
}

enum TimelineMapSelection: Equatable {
    case place(UUID)
    case move(UUID)
    case liveRoute(String)
    case sample(String)
}

struct DayTimelinePage: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    let dayKey: String
    let isActive: Bool
    @Binding var mapSelection: TimelineMapSelection?

    @State private var dayTimeline: DayTimeline?
    @State private var loadErrorMessage: String?

    var body: some View {
        Group {
            if isActive, let dayTimeline {
                DayTimelinePageContent(
                    dayTimeline: dayTimeline,
                    isActive: isActive,
                    mapSelection: $mapSelection
                )
            } else if isActive {
                loadingState
            } else {
                inactiveState
            }
        }
        .task(id: pageLoadKey) {
            await syncDayTimelineForActivation()
        }
    }

    private var pageLoadKey: String {
        "\(dayKey)|\(isActive ? "active" : "inactive")"
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

    private var inactiveState: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 420)
            .onAppear {
                releaseLoadedDay()
            }
    }

    @MainActor
    private func syncDayTimelineForActivation() async {
        guard isActive else {
            releaseLoadedDay()
            return
        }

        await loadDayTimeline()
    }

    @MainActor
    private func releaseLoadedDay() {
        dayTimeline = nil
        loadErrorMessage = nil
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
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    let dayTimeline: DayTimeline
    let isActive: Bool
    private static let transientStopMaximumDuration: TimeInterval = 5 * 60
    private static let provisionalPlaceNameResolver = CLGeocoderPlaceNameResolver()

    @State private var provisionalSampleResolvedTitle: String?
    @State private var provisionalSampleResolvedKey: String?
    @State private var presentationCache: DayTimelinePresentationCache
    @State private var isReviewingImportedData = false
    @Binding private var mapSelection: TimelineMapSelection?

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        mapSelection: Binding<TimelineMapSelection?> = .constant(nil)
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _mapSelection = mapSelection
        _presentationCache = State(initialValue: Self.makePresentationCache(for: dayTimeline))
    }

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
    }

    private var timelineEntries: [TimelineEntry] {
        var entries = presentationCache.timelineEntries

        if entries.isEmpty, let latestSample = presentationCache.latestSample {
            entries.append(
                .sample(
                    location: latestSample,
                    sampleCount: presentationCache.sortedSamples.count,
                    resolvedName: provisionalSampleTitle(for: latestSample)
                )
            )
        }

        if let liveRouteSnapshot {
            entries.append(.liveRoute(liveRouteSnapshot))
        }

        return entries
    }

    private var deviceResolution: MultiDeviceDayResolution {
        MultiDeviceTimelineResolver.resolve(samples: dayTimeline.samples)
    }

    private var presentationRefreshKey: String {
        let places = dayTimeline.places.map { place in
            "place:\(place.id.uuidString):\(place.arrivalDate.timeIntervalSinceReferenceDate):\(place.departureDate?.timeIntervalSinceReferenceDate ?? -1):\(place.userLabel ?? ""):\(place.autoLabel ?? "")"
        }
        let moves = dayTimeline.moves.map { move in
            "move:\(move.id.uuidString):\(move.timelineStartDate.timeIntervalSinceReferenceDate):\(move.endDate.timeIntervalSinceReferenceDate):\(move.transportModeRawValue):\(move.deviceIdentifier)"
        }
        let samples = dayTimeline.samples.map { sample in
            "sample:\(sample.dedupeKey):\(sample.timestamp.timeIntervalSinceReferenceDate):\(sample.latitude):\(sample.longitude):\(sample.deviceIdentifier)"
        }
        return (places + moves + samples).sorted().joined(separator: "|")
    }

    private static func makePresentationCache(for dayTimeline: DayTimeline) -> DayTimelinePresentationCache {
        let resolution = MultiDeviceTimelineResolver.resolve(samples: dayTimeline.samples)
        let visiblePlaces = dayTimeline.places.filter { resolution.includes($0.deviceIdentifier) }
        let visibleMoves = dayTimeline.moves.filter { resolution.includes($0.deviceIdentifier) }
        let places = visiblePlaces
            .filter { !shouldHidePlaceFromTimeline($0) }
            .map(TimelineEntry.place)
        let moves = visibleMoves.map(TimelineEntry.move)
        let samples = dayTimeline.samples
            .filter { resolution.includes($0.deviceIdentifier) }
            .sorted(by: { $0.timestamp < $1.timestamp })
        var entries = (places + moves).sorted { $0.startDate < $1.startDate }

        if let firstMove = visibleMoves.min(by: { $0.timelineStartDate < $1.timelineStartDate }),
           let startPlace = firstMove.startPlace {
            let hasDayStartPlaceAlready = visiblePlaces.contains(where: { $0.id == startPlace.id })

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

        if entries.isEmpty, let carriedOverPlace = dayTimeline.carriedOverPlace {
            entries.append(.start(place: carriedOverPlace, timestamp: dayTimeline.dayStart))
        }

        return DayTimelinePresentationCache(
            timelineEntries: entries,
            transportSummaryMetrics: transportSummaryMetrics(for: visibleMoves),
            sortedSamples: samples
        )
    }

    private static func shouldHidePlaceFromTimeline(_ place: VisitPlace) -> Bool {
        guard let dayTimeline = place.dayTimeline else { return false }

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

    private static func hasExplicitUserLabel(_ place: VisitPlace) -> Bool {
        !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var transportSummaryMetrics: [DayTransportSummaryMetric] {
        presentationCache.transportSummaryMetrics
    }

    private var transportSummaryRefreshKey: String {
        dayTimeline.moves
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { move in
                let start = move.timelineStartDate.timeIntervalSinceReferenceDate
                let end = move.endDate.timeIntervalSinceReferenceDate
                return "\(move.id.uuidString)|\(move.transportModeRawValue)|\(start)|\(end)|\(move.distanceMeters)"
            }
            .joined(separator: ",")
    }

    private static func transportSummaryMetrics(for moves: [MoveSegment]) -> [DayTransportSummaryMetric] {
        var durationByBucket: [DayTransportBucket: TimeInterval] = [:]
        var distanceByBucket: [DayTransportBucket: CLLocationDistance] = [:]

        for move in moves {
            guard let bucket = DayTransportBucket(move.transportMode) else { continue }

            durationByBucket[bucket, default: 0] += move.timelineDuration
            distanceByBucket[bucket, default: 0] += max(move.distanceMeters, 0)
        }

        return DayTransportBucket.allCases.compactMap { bucket in
            let distance = distanceByBucket[bucket, default: 0]
            guard distance > 0 else { return nil }

            return DayTransportSummaryMetric(
                id: bucket.rawValue,
                title: bucket.title,
                symbolName: bucket.symbolName,
                tint: bucket.tint,
                duration: durationByBucket[bucket, default: 0],
                distanceMeters: distance
            )
        }
    }

    private var hasTransportSummaryData: Bool {
        !transportSummaryMetrics.isEmpty
    }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            macContent
            #else
            GeometryReader { proxy in
                if LandscapeLayoutSettings.isLandscapePhone(proxy.size) {
                    landscapeContent
                } else {
                    portraitContent
                }
            }
            #endif
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .task(id: provisionalSampleLookupKey) {
            await resolveProvisionalSampleTitle()
        }
        .onChange(of: dayTimeline.dayKey) { _, _ in
            presentationCache = Self.makePresentationCache(for: dayTimeline)
            mapSelection = nil
        }
        .onChange(of: presentationRefreshKey) { _, _ in
            presentationCache = Self.makePresentationCache(for: dayTimeline)
        }
        .onChange(of: transportSummaryRefreshKey) { _, _ in
            presentationCache = Self.makePresentationCache(for: dayTimeline)
        }
        .sheet(isPresented: $isReviewingImportedData) {
            NavigationStack {
                ImportedRouteDataView(
                    modelContext: modelContext,
                    initialDate: dayTimeline.dayStart
                )
            }
        }
    }

    private var macContent: some View {
        VStack(spacing: 10) {
            DayMapStrip(
                dayTimeline: dayTimeline,
                isActive: isActive,
                selection: $mapSelection
            )

            MultiDeviceActivityBanner(resolution: deviceResolution)

            importedDataReviewButton

            ScrollView {
                timelinePanel(usesSelection: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaPadding(.horizontal, 14)
        .safeAreaInset(edge: .bottom, spacing: 10) {
            daySummaryPanel
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }

    private var portraitContent: some View {
        ScrollView {
            VStack(spacing: 10) {
                DayMapStrip(
                    dayTimeline: dayTimeline,
                    isActive: isActive,
                    selection: $mapSelection
                )

                MultiDeviceActivityBanner(resolution: deviceResolution)

                importedDataReviewButton

                timelinePanel(usesSelection: false)

                daySummaryPanel
            }
            .safeAreaPadding(.horizontal, 14)
            .safeAreaPadding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var landscapeContent: some View {
        LandscapeSplitView {
            DayMapStrip(
                dayTimeline: dayTimeline,
                isActive: isActive,
                selection: $mapSelection,
                fillsAvailableSpace: true
            )
        } controlPane: {
            ScrollView {
                VStack(spacing: 10) {
                    HStack {
                        Text("Places & Moves")
                            .font(.system(size: 17, weight: .bold, design: .rounded))

                        Spacer()

                        LandscapePaneSideButton()
                    }
                    .padding(.horizontal, 4)

                    timelinePanel(usesSelection: true)

                    MultiDeviceActivityBanner(resolution: deviceResolution)

                    importedDataReviewButton

                    daySummaryPanel
                }
                .safeAreaPadding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .safeAreaPadding(.horizontal, 14)
    }

    private var daySummaryPanel: some View {
        DayTransportSummaryView(
            metrics: transportSummaryMetrics,
            hasData: hasTransportSummaryData
        )
        .panelSurface()
    }

    @ViewBuilder
    private var importedDataReviewButton: some View {
        if dayTimeline.hasImportedRouteData {
            Button {
                isReviewingImportedData = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(MovesPalette.routeTracking)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Review imported data")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Review or delete imported routes for this day")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .panelSurface()
        }
    }

    @ViewBuilder
    private func timelinePanel(usesSelection: Bool) -> some View {
        if timelineEntries.isEmpty {
            emptyTimelinePanel
        } else if usesSelection {
            selectableTimelineList
                .panelSurface()
        } else {
            timelineList
                .panelSurface()
        }
    }

    private var emptyTimelinePanel: some View {
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

    private var selectableTimelineList: some View {
        VStack(spacing: 0) {
            ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mapSelection = entry.mapSelection
                        }
                    } label: {
                        StorylineRow(
                            entry: entry,
                            isFirst: index == 0,
                            isLast: index == timelineEntries.count - 1
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    timelineDetailLink(for: entry)
                }
                .background {
                    if mapSelection == entry.mapSelection {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(entry.iconTint.opacity(0.15))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                    }
                }

                if index < timelineEntries.count - 1 {
                    Divider()
                        .padding(.leading, 82)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineDetailLink(for entry: TimelineEntry) -> some View {
        switch entry {
        case .place(let place):
            NavigationLink {
                PlaceMapDetailView(place: place)
            } label: {
                detailChevron
            }
            .buttonStyle(.plain)

        case .move(let move):
            NavigationLink {
                MoveMapDetailView(segment: move)
            } label: {
                detailChevron
            }
            .buttonStyle(.plain)

        case .liveRoute, .start, .sample:
            EmptyView()
        }
    }

    private var detailChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Open details")
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

        case .sample:
            StorylineRow(entry: entry, isFirst: isFirst, isLast: isLast)
        }
    }

    private var provisionalSampleLookupKey: String {
        guard let latestSample = presentationCache.latestSample else { return "none" }
        return Self.sampleLookupKey(for: latestSample, sampleCount: presentationCache.sortedSamples.count)
    }

    private func provisionalSampleTitle(for sample: LocationSample) -> String? {
        let key = Self.sampleLookupKey(for: sample, sampleCount: presentationCache.sortedSamples.count)
        guard provisionalSampleResolvedKey == key else { return nil }
        return provisionalSampleResolvedTitle
    }

    @MainActor
    private func resolveProvisionalSampleTitle() async {
        let samples = presentationCache.sortedSamples
        guard let latestSample = presentationCache.latestSample else {
            provisionalSampleResolvedKey = nil
            provisionalSampleResolvedTitle = nil
            return
        }

        let key = Self.sampleLookupKey(for: latestSample, sampleCount: samples.count)
        provisionalSampleResolvedKey = key
        provisionalSampleResolvedTitle = nil

        guard latestSample.horizontalAccuracy > 0, latestSample.horizontalAccuracy <= 250 else {
            return
        }

        let resolved = await Self.provisionalPlaceNameResolver.resolveName(for: latestSample.coordinate)
        guard provisionalSampleResolvedKey == key else { return }
        provisionalSampleResolvedTitle = resolved?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sampleLookupKey(for sample: LocationSample, sampleCount: Int) -> String {
        let timestamp = Int(sample.timestamp.timeIntervalSince1970.rounded())
        return "\(sample.dedupeKey)|\(timestamp)|\(sampleCount)"
    }
}

private struct DayTimelinePresentationCache {
    let timelineEntries: [TimelineEntry]
    let transportSummaryMetrics: [DayTransportSummaryMetric]
    let sortedSamples: [LocationSample]

    var latestSample: LocationSample? {
        sortedSamples.last
    }
}

private struct MultiDeviceActivityBanner: View {
    let resolution: MultiDeviceDayResolution

    var body: some View {
        if resolution.kind == .independentJourneys {
            Label {
                Text("Another iPhone recorded a separate trip today. This timeline is showing this phone's journey.")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
            }
            .foregroundStyle(MovesPalette.routeTracking)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .panelSurface()
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
    case walking
    case swimming
    case cycling
    case automotive
    case motorcycle
    case train
    case plane
    case boat

    init?(_ mode: TransportMode) {
        switch mode {
        case .walking, .running:
            self = .walking
        case .swimming:
            self = .swimming
        case .cycling:
            self = .cycling
        case .automotive:
            self = .automotive
        case .motorcycle:
            self = .motorcycle
        case .train:
            self = .train
        case .plane:
            self = .plane
        case .boat:
            self = .boat
        case .stationary, .unknown:
            return nil
        }
    }

    var title: String {
        switch self {
        case .walking:
            return "Walking"
        case .swimming:
            return "Swimming"
        case .cycling:
            return "Bike"
        case .automotive:
            return "Car"
        case .motorcycle:
            return "Motorcycle"
        case .train:
            return "Train"
        case .plane:
            return "Plane"
        case .boat:
            return "Boat"
        }
    }

    var symbolName: String {
        switch self {
        case .walking:
            return "figure.walk"
        case .swimming:
            return "figure.pool.swim"
        case .cycling:
            return "figure.outdoor.cycle"
        case .automotive:
            return "car.fill"
        case .motorcycle:
            return "motorcycle.fill"
        case .train:
            return "tram.fill"
        case .plane:
            return "airplane"
        case .boat:
            return "sailboat.fill"
        }
    }

    var transportMode: TransportMode {
        switch self {
        case .walking:
            return .walking
        case .swimming:
            return .swimming
        case .cycling:
            return .cycling
        case .automotive:
            return .automotive
        case .motorcycle:
            return .motorcycle
        case .train:
            return .train
        case .plane:
            return .plane
        case .boat:
            return .boat
        }
    }

    var tint: Color {
        MovesPalette.transport(transportMode)
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

private struct DayMapPresentationCache {
    let placeMarkers: [PlaceMarker]
    let latestSampleCoordinate: CLLocationCoordinate2D?
    let routeRefreshKey: String
    let placeRefreshKey: String
    let latestSampleKey: String
}

private struct DayMapRouteCacheEntry {
    let routes: [RenderedRoute]
    let isFullyMatched: Bool
}

@MainActor
private enum DayMapRouteCache {
    private static var entries: [String: DayMapRouteCacheEntry] = [:]
    private static var keysInUseOrder: [String] = []
    private static let maximumEntryCount = 18

    static func routes(for key: String) -> DayMapRouteCacheEntry? {
        guard let entry = entries[key] else { return nil }
        markRecentlyUsed(key)
        return entry
    }

    static func store(_ routes: [RenderedRoute], for key: String, isFullyMatched: Bool) {
        if let existing = entries[key], existing.isFullyMatched, !isFullyMatched {
            markRecentlyUsed(key)
            return
        }

        entries[key] = DayMapRouteCacheEntry(routes: routes, isFullyMatched: isFullyMatched)
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private static func markRecentlyUsed(_ key: String) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }

    private static func trimIfNeeded() {
        while keysInUseOrder.count > maximumEntryCount {
            let oldest = keysInUseOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

struct DayMapStrip: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false
    let dayTimeline: DayTimeline
    let isActive: Bool
    @Binding var selection: TimelineMapSelection?
    let fillsAvailableSpace: Bool
    private var deviceResolution: MultiDeviceDayResolution {
        MultiDeviceTimelineResolver.resolve(samples: dayTimeline.samples)
    }
    private static let collapsedMapHeight: CGFloat = 180
    private static let collapsedMapCornerRadius: CGFloat = 14
    private static let fullScreenMapAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)
    private static let expandedMapVerticalMargin: CGFloat = 150

    @State private var camera: MapCameraPosition
    @State private var mapRegion: MKCoordinateRegion
    @State private var historicalRoutes: [RenderedRoute]
    @State private var presentationCache: DayMapPresentationCache
    @State private var isShowingFullScreenMap = false
    @State private var collapsedSnapshotImage: UIImage?

    private var placeMarkers: [PlaceMarker] {
        presentationCache.placeMarkers
    }

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
    }

    private var latestSampleCoordinate: CLLocationCoordinate2D? {
        presentationCache.latestSampleCoordinate
    }

    private var historicalRouteCoordinates: [CLLocationCoordinate2D] {
        historicalRoutes.flatMap { $0.coordinates }
    }

    private var historicalRouteRefreshKey: String {
        presentationCache.routeRefreshKey
    }

    private var cameraRefreshKey: String {
        let liveKey = liveRouteSnapshot?.id ?? "none"
        return [presentationCache.routeRefreshKey, presentationCache.placeRefreshKey, liveKey, presentationCache.latestSampleKey].joined(separator: "|")
    }

    private var presentationRefreshKey: String {
        let places = dayTimeline.places.map { place in
            "place:\(place.id.uuidString):\(place.arrivalDate.timeIntervalSinceReferenceDate):\(place.departureDate?.timeIntervalSinceReferenceDate ?? -1):\(place.userLabel ?? ""):\(place.autoLabel ?? "")"
        }
        let moves = dayTimeline.moves.map { move in
            "move:\(move.id.uuidString):\(move.timelineStartDate.timeIntervalSinceReferenceDate):\(move.endDate.timeIntervalSinceReferenceDate):\(move.transportModeRawValue):\(move.deviceIdentifier)"
        }
        let samples = dayTimeline.samples.map { sample in
            "sample:\(sample.dedupeKey):\(sample.timestamp.timeIntervalSinceReferenceDate):\(sample.latitude):\(sample.longitude):\(sample.deviceIdentifier)"
        }
        return (places + moves + samples).sorted().joined(separator: "|")
    }

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        selection: Binding<TimelineMapSelection?> = .constant(nil),
        fillsAvailableSpace: Bool = false,
        deviceResolution: MultiDeviceDayResolution? = nil
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _selection = selection
        self.fillsAvailableSpace = fillsAvailableSpace
        let resolvedDeviceResolution = deviceResolution ?? MultiDeviceTimelineResolver.resolve(samples: dayTimeline.samples)

        let cache = Self.makePresentationCache(for: dayTimeline, resolution: resolvedDeviceResolution)
        let cachedRoutes = DayMapRouteCache.routes(for: cache.routeRefreshKey)
        let renderedRoutes = cachedRoutes?.routes ?? Self.renderedRoutes(for: dayTimeline, resolution: resolvedDeviceResolution)
        let allCoordinates = Self.allCoordinates(
            for: dayTimeline,
            routeCoordinates: renderedRoutes.flatMap { $0.coordinates },
            liveRouteCoordinates: [],
            resolution: resolvedDeviceResolution
        )
        let cameraCoordinates = allCoordinates.isEmpty
            ? cache.latestSampleCoordinate.map { [$0] } ?? []
            : allCoordinates
        let initialRegion = MapRegionFactory.region(for: cameraCoordinates)
        _camera = State(initialValue: .region(initialRegion))
        _mapRegion = State(initialValue: initialRegion)
        _historicalRoutes = State(initialValue: renderedRoutes)
        _presentationCache = State(initialValue: cache)
    }

    var body: some View {
        activeMapView
            .frame(
                maxWidth: .infinity,
                maxHeight: fillsAvailableSpace ? .infinity : nil
            )
            .frame(height: fillsAvailableSpace ? nil : (isShowingFullScreenMap ? Self.expandedMapHeight : Self.collapsedMapHeight))
            .clipShape(RoundedRectangle(cornerRadius: Self.collapsedMapCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.collapsedMapCornerRadius, style: .continuous)
                    .stroke(MovesPalette.border.opacity(0.8), lineWidth: 1)
            }
            .overlay(alignment: isShowingFullScreenMap ? .topTrailing : .bottomTrailing) {
                if !fillsAvailableSpace {
                    fullScreenToggleButton(isFullScreen: isShowingFullScreenMap)
                        .padding(isShowingFullScreenMap ? 18 : 10)
                }
            }
            .shadow(color: .black.opacity(isShowingFullScreenMap ? 0.12 : 0), radius: 18, x: 0, y: 8)
            .animation(Self.fullScreenMapAnimation, value: isShowingFullScreenMap)
            .task(id: "\(historicalRouteRefreshKey)|\(isActive ? 1 : 0)") {
                guard isActive else { return }
                await refreshHistoricalRouteCoordinates()
            }
            .task(id: cameraRefreshKey) {
                refreshCamera()
            }
            .onChange(of: selection) { _, newSelection in
                refreshCamera(for: newSelection)
            }
            .onChange(of: dayTimeline.dayKey) { _, _ in
                presentationCache = Self.makePresentationCache(for: dayTimeline, resolution: deviceResolution)
            }
            .onChange(of: presentationRefreshKey) { _, _ in
                presentationCache = Self.makePresentationCache(for: dayTimeline, resolution: deviceResolution)
            }
    }

    @ViewBuilder
    private var activeMapView: some View {
        if fillsAvailableSpace || isShowingFullScreenMap {
            mapView
        } else {
            collapsedMapSnapshotView
        }
    }

    private var mapView: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            mapContent
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
    }

    private var collapsedMapSnapshotView: some View {
        GeometryReader { proxy in
            let size = CGSize(
                width: max(proxy.size.width, 1),
                height: Self.collapsedMapHeight
            )

            ZStack {
                if let collapsedSnapshotImage {
                    Image(uiImage: collapsedSnapshotImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(MovesPalette.card.opacity(0.72))

                    ProgressView()
                        .tint(MovesPalette.routeTracking)
                }
            }
            .task(id: collapsedSnapshotRefreshKey(for: size)) {
                await refreshCollapsedSnapshot(size: size)
            }
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        ForEach(historicalRoutes) { route in
            let isSelected = isSelectedRoute(route)
            let dimsForOtherSelection = selection != nil && !isSelected

            if route.shadowCoordinates.count > 1 {
                MapPolyline(coordinates: route.shadowCoordinates)
                    .stroke(
                        route.shadowTint.opacity(dimsForOtherSelection ? 0.2 : 1),
                        lineWidth: isSelected ? route.shadowLineWidth + 4 : route.shadowLineWidth
                    )
            }

            ForEach(Array(route.coordinateSegments.enumerated()), id: \.offset) { _, coordinates in
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        route.tint.opacity(dimsForOtherSelection ? 0.28 : 0.95),
                        lineWidth: isSelected ? route.lineWidth + 4 : route.lineWidth
                    )
            }
        }

        if let liveRouteSnapshot,
           liveRouteSnapshot.coordinates.count > 1 {
            MapPolyline(coordinates: liveRouteSnapshot.coordinates)
                .stroke(
                    MovesPalette.routeTracking.opacity(selection != nil && !isLiveRouteSelected ? 0.28 : 0.95),
                    lineWidth: isLiveRouteSelected ? 9 : 5
                )
        }

        ForEach(placeMarkers) { marker in
            let isSelected = selection == .place(marker.id)

            if showsBigMarkers && !isSelected {
                Marker(marker.title, coordinate: marker.coordinate)
                    .tint(MovesPalette.place)
            } else {
                Annotation(marker.title, coordinate: marker.coordinate, anchor: .center) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = .place(marker.id)
                        }
                    } label: {
                        MapLocationDot(tint: MovesPalette.place, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(marker.title)
                }
            }
        }

        if placeMarkers.isEmpty,
           historicalRouteCoordinates.isEmpty,
           (liveRouteSnapshot?.coordinates.isEmpty ?? true),
           let latestSampleCoordinate {
            if showsBigMarkers {
                Marker("Captured location", coordinate: latestSampleCoordinate)
                    .tint(liveRouteSnapshot == nil ? MovesPalette.start : MovesPalette.routeTracking)
            } else {
                Annotation("Captured location", coordinate: latestSampleCoordinate, anchor: .center) {
                    MapLocationDot(
                        tint: liveRouteSnapshot == nil ? MovesPalette.start : MovesPalette.routeTracking,
                        isSelected: isSampleSelected
                    )
                }
            }
        }
    }

    private func isSelectedRoute(_ route: RenderedRoute) -> Bool {
        guard case .move(let id) = selection else { return false }
        return route.id == id.uuidString
    }

    private var isLiveRouteSelected: Bool {
        guard case .liveRoute = selection else { return false }
        return true
    }

    private var isSampleSelected: Bool {
        guard case .sample = selection else { return false }
        return true
    }

    private func fullScreenToggleButton(isFullScreen: Bool) -> some View {
        Button {
            withAnimation(Self.fullScreenMapAnimation) {
                isShowingFullScreenMap = !isFullScreen
            }
        } label: {
            Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frostedCircle(enabled: true)
        .accessibilityLabel(isFullScreen ? "Shrink map" : "Expand map")
        .help(isFullScreen ? "Shrink map" : "Expand map")
    }

    private static var expandedMapHeight: CGFloat {
        max(360, windowBounds.height - expandedMapVerticalMargin)
    }

    private var collapsedSnapshotRouteKey: String {
        historicalRoutes.map { route in
            let first = route.coordinates.first
            let last = route.coordinates.last
            let firstKey = first.map { "\(Int(($0.latitude * 10_000).rounded())):\(Int(($0.longitude * 10_000).rounded()))" } ?? "none"
            let lastKey = last.map { "\(Int(($0.latitude * 10_000).rounded())):\(Int(($0.longitude * 10_000).rounded()))" } ?? "none"

            return "\(route.id)|\(route.coordinates.count)|\(route.shadowCoordinates.count)|\(firstKey)|\(lastKey)"
        }
        .joined(separator: ",")
    }

    private func collapsedSnapshotRefreshKey(for size: CGSize) -> String {
        [
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(Int(Self.screenScale.rounded()))",
            presentationCache.routeRefreshKey,
            presentationCache.placeRefreshKey,
            presentationCache.latestSampleKey,
            liveRouteSnapshot?.id ?? "none",
            showsBigMarkers ? "big" : "small",
            collapsedSnapshotRouteKey
        ]
        .joined(separator: "|")
    }

    @MainActor
    private func refreshCollapsedSnapshot(size: CGSize) async {
        guard !isShowingFullScreenMap, size.width > 1, size.height > 1 else { return }

        do {
            let image = try await Self.makeCollapsedSnapshot(
                region: mapRegion,
                size: size,
                scale: Self.screenScale,
                routes: historicalRoutes,
                liveRouteSnapshot: liveRouteSnapshot,
                placeMarkers: placeMarkers,
                latestSampleCoordinate: latestSampleCoordinate,
                showsBigMarkers: showsBigMarkers
            )

            guard !Task.isCancelled else { return }
            collapsedSnapshotImage = image
        } catch {
            guard !Task.isCancelled else { return }
            collapsedSnapshotImage = nil
        }
    }

    private static func makeCollapsedSnapshot(
        region: MKCoordinateRegion,
        size: CGSize,
        scale: CGFloat,
        routes: [RenderedRoute],
        liveRouteSnapshot: LiveRouteTrackingSnapshot?,
        placeMarkers: [PlaceMarker],
        latestSampleCoordinate: CLLocationCoordinate2D?,
        showsBigMarkers: Bool
    ) async throws -> UIImage {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await withCheckedThrowingContinuation { continuation in
            snapshotter.start { snapshot, error in
                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
        }

        return renderCollapsedSnapshotOverlay(
            snapshot: snapshot,
            routes: routes,
            liveRouteSnapshot: liveRouteSnapshot,
            placeMarkers: placeMarkers,
            latestSampleCoordinate: latestSampleCoordinate,
            showsBigMarkers: showsBigMarkers
        )
    }

    private static func renderCollapsedSnapshotOverlay(
        snapshot: MKMapSnapshotter.Snapshot,
        routes: [RenderedRoute],
        liveRouteSnapshot: LiveRouteTrackingSnapshot?,
        placeMarkers: [PlaceMarker],
        latestSampleCoordinate: CLLocationCoordinate2D?,
        showsBigMarkers: Bool
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: snapshot.image.size, format: format).image { _ in
            snapshot.image.draw(at: .zero)

            for route in routes {
                strokeRoute(
                    route.shadowCoordinates,
                    in: snapshot,
                    color: UIColor(route.shadowTint),
                    lineWidth: route.shadowLineWidth
                )
                strokeRoute(
                    route.coordinates,
                    in: snapshot,
                    color: UIColor(route.tint).withAlphaComponent(0.95),
                    lineWidth: route.lineWidth
                )
            }

            if let liveRouteSnapshot {
                strokeRoute(
                    liveRouteSnapshot.coordinates,
                    in: snapshot,
                    color: UIColor(MovesPalette.routeTracking).withAlphaComponent(0.95),
                    lineWidth: 5
                )
            }

            for marker in placeMarkers {
                drawMarker(
                    at: snapshot.point(for: marker.coordinate),
                    in: snapshot.image.size,
                    tint: UIColor(MovesPalette.place),
                    isLarge: showsBigMarkers
                )
            }

            if placeMarkers.isEmpty,
               routes.flatMap(\.coordinates).isEmpty,
               (liveRouteSnapshot?.coordinates.isEmpty ?? true),
               let latestSampleCoordinate {
                drawMarker(
                    at: snapshot.point(for: latestSampleCoordinate),
                    in: snapshot.image.size,
                    tint: UIColor(liveRouteSnapshot == nil ? MovesPalette.start : MovesPalette.routeTracking),
                    isLarge: showsBigMarkers
                )
            }
        }
    }

    private static func strokeRoute(
        _ coordinates: [CLLocationCoordinate2D],
        in snapshot: MKMapSnapshotter.Snapshot,
        color: UIColor,
        lineWidth: CGFloat
    ) {
        guard coordinates.count > 1 else { return }

        let path = UIBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = lineWidth

        for (index, coordinate) in coordinates.enumerated() {
            let point = snapshot.point(for: coordinate)
            if index == 0
                || RouteCoordinateOps.crossesAntimeridian(
                    from: coordinates[index - 1],
                    to: coordinate
                ) {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        color.setStroke()
        path.stroke()
    }

    private static func drawMarker(
        at point: CGPoint,
        in size: CGSize,
        tint: UIColor,
        isLarge: Bool
    ) {
        let diameter: CGFloat = isLarge ? 14 : 8
        let radius = diameter / 2
        let drawingBounds = CGRect(
            x: -diameter,
            y: -diameter,
            width: size.width + diameter * 2,
            height: size.height + diameter * 2
        )
        guard drawingBounds.contains(point) else { return }

        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: diameter,
            height: diameter
        )
        let path = UIBezierPath(ovalIn: rect)
        tint.setFill()
        path.fill()

        UIColor.white.setStroke()
        path.lineWidth = isLarge ? 2 : 1.5
        path.stroke()
    }

    private static var windowBounds: CGRect {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        if let windowScene = windowScenes.first(where: { $0.activationState == .foregroundActive }) {
            return windowScene.windows.first(where: { $0.isKeyWindow })?.bounds
                ?? windowScene.windows.first?.bounds
                ?? windowScene.screen.bounds
        }

        if let windowScene = windowScenes.first {
            return windowScene.windows.first(where: { $0.isKeyWindow })?.bounds
                ?? windowScene.windows.first?.bounds
                ?? windowScene.screen.bounds
        }

        return CGRect(x: 0, y: 0, width: 393, height: 852)
    }

    private static var screenScale: CGFloat {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        if let windowScene = windowScenes.first(where: { $0.activationState == .foregroundActive }) {
            return windowScene.screen.scale
        }

        return windowScenes.first?.screen.scale ?? 2
    }

    @MainActor
    private func refreshHistoricalRouteCoordinates() async {
        if let cached = DayMapRouteCache.routes(for: historicalRouteRefreshKey), cached.isFullyMatched {
            historicalRoutes = cached.routes
            refreshCamera(for: selection)
            return
        }

        let sortedMoves = dayTimeline.moves
            .filter { deviceResolution.includes($0.deviceIdentifier) }
            .sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
        var renderedRoutes: [RenderedRoute] = []
        renderedRoutes.reserveCapacity(sortedMoves.count)

        for move in sortedMoves {
            let matched = await RoadRouteMatcher.matchedCoordinates(for: move)
            renderedRoutes.append(
                RenderedRoute(
                    id: move.id.uuidString,
                    coordinates: matched,
                    usesHighAccuracyRouteTracking: move.usesHighAccuracyRouteTracking,
                    usesHealthWorkoutRoute: move.usesHealthWorkoutRoute,
                    transportMode: move.transportMode
                )
            )
        }

        historicalRoutes = renderedRoutes
        DayMapRouteCache.store(renderedRoutes, for: historicalRouteRefreshKey, isFullyMatched: true)
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                print("Failed to persist matched route cache: \(error.localizedDescription)")
            }
        }
        refreshCamera(for: selection)
    }

    @MainActor
    private func refreshCamera() {
        let liveCoordinates = liveRouteSnapshot?.coordinates ?? []
        let allCoordinates = Self.allCoordinates(
            for: dayTimeline,
            routeCoordinates: historicalRouteCoordinates,
            liveRouteCoordinates: liveCoordinates,
            resolution: deviceResolution
        )
        let cameraCoordinates = allCoordinates.isEmpty
            ? presentationCache.latestSampleCoordinate.map { [$0] } ?? []
            : allCoordinates

        if !cameraCoordinates.isEmpty {
            let region = MapRegionFactory.region(for: cameraCoordinates)
            mapRegion = region
            camera = .region(region)
        }
    }

    @MainActor
    private func refreshCamera(for selection: TimelineMapSelection?) {
        let coordinates: [CLLocationCoordinate2D]

        switch selection {
        case .place(let id):
            coordinates = placeMarkers.first(where: { $0.id == id }).map { [$0.coordinate] } ?? []
        case .move(let id):
            coordinates = historicalRoutes.first(where: { $0.id == id.uuidString })?.coordinates ?? []
        case .liveRoute:
            coordinates = liveRouteSnapshot?.coordinates ?? []
        case .sample:
            coordinates = latestSampleCoordinate.map { [$0] } ?? []
        case nil:
            refreshCamera()
            return
        }

        guard !coordinates.isEmpty else { return }
        let region = MapRegionFactory.region(for: coordinates)
        mapRegion = region
        camera = .region(region)
    }

    private static func renderedRoutes(
        for dayTimeline: DayTimeline,
        resolution: MultiDeviceDayResolution
    ) -> [RenderedRoute] {
        let renderedRoutes = dayTimeline.moves
            .filter { resolution.includes($0.deviceIdentifier) }
            .sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
            .map { move in
                let fallback = MoveRouteGeometry.rawCoordinates(for: move)
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)

                return RenderedRoute(
                    id: move.id.uuidString,
                    coordinates: move.manualRouteCoordinates ?? move.cachedRouteCoordinates(for: signature) ?? fallback,
                    usesHighAccuracyRouteTracking: move.usesHighAccuracyRouteTracking,
                    usesHealthWorkoutRoute: move.usesHealthWorkoutRoute,
                    transportMode: move.transportMode
                )
            }
        DayMapRouteCache.store(
            renderedRoutes,
            for: routeRefreshKey(for: dayTimeline, resolution: resolution),
            isFullyMatched: false
        )
        return renderedRoutes
    }

    private static func allCoordinates(
        for dayTimeline: DayTimeline,
        routeCoordinates: [CLLocationCoordinate2D],
        liveRouteCoordinates: [CLLocationCoordinate2D],
        resolution: MultiDeviceDayResolution
    ) -> [CLLocationCoordinate2D] {
        let placeCoordinates = mapPlaces(for: dayTimeline, resolution: resolution).map(\.coordinate)
        return routeCoordinates + liveRouteCoordinates + placeCoordinates
    }

    private static func latestSampleCoordinate(
        for dayTimeline: DayTimeline,
        resolution: MultiDeviceDayResolution
    ) -> CLLocationCoordinate2D? {
        dayTimeline.samples
            .filter { resolution.includes($0.deviceIdentifier) }
            .sorted(by: { $0.timestamp < $1.timestamp })
            .last?
            .coordinate
    }

    private static func makePresentationCache(
        for dayTimeline: DayTimeline,
        resolution: MultiDeviceDayResolution
    ) -> DayMapPresentationCache {
        let sortedPlaces = mapPlaces(for: dayTimeline, resolution: resolution)
        let placeMarkers = sortedPlaces.map {
            PlaceMarker(id: $0.id, title: $0.displayTitle, coordinate: $0.coordinate)
        }
        let placeRefreshKey = sortedPlaces.map { place in
            let arrival = Int(place.arrivalDate.timeIntervalSince1970.rounded())
            let departure = Int((place.departureDate ?? place.arrivalDate).timeIntervalSince1970.rounded())
            return "\(place.id.uuidString)|\(arrival)|\(departure)"
        }
        .joined(separator: ",")

        let sortedSamples = dayTimeline.samples
            .filter { resolution.includes($0.deviceIdentifier) }
            .sorted(by: { $0.timestamp < $1.timestamp })
        let latestSample = sortedSamples.last
        let latestSampleKey = latestSample.map { sample in
            "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
        } ?? "none"

        return DayMapPresentationCache(
            placeMarkers: placeMarkers,
            latestSampleCoordinate: latestSample?.coordinate,
            routeRefreshKey: routeRefreshKey(for: dayTimeline, resolution: resolution),
            placeRefreshKey: placeRefreshKey,
            latestSampleKey: latestSampleKey
        )
    }

    private static func mapPlaces(
        for dayTimeline: DayTimeline,
        resolution: MultiDeviceDayResolution
    ) -> [VisitPlace] {
        let routePlaces = dayTimeline.moves.filter { resolution.includes($0.deviceIdentifier) }.flatMap { move in
            [move.startPlace, move.endPlace].compactMap { $0 }
        }
        var placesByID: [UUID: VisitPlace] = [:]

        for place in dayTimeline.displayPlaces.filter({ resolution.includes($0.deviceIdentifier) }) + routePlaces {
            placesByID[place.id] = place
        }

        return placesByID.values.sorted(by: { $0.arrivalDate < $1.arrivalDate })
    }

    private static func routeRefreshKey(
        for dayTimeline: DayTimeline,
        resolution: MultiDeviceDayResolution
    ) -> String {
        let sortedMoves = dayTimeline.moves
            .filter { resolution.includes($0.deviceIdentifier) }
            .sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
        return sortedMoves.map { move in
            let start = Int(move.timelineStartDate.timeIntervalSince1970.rounded())
            let end = Int(move.endDate.timeIntervalSince1970.rounded())
            let sampleKey = Self.refreshSampleKey(for: move.samples)

            return "\(move.id.uuidString)|\(move.transportMode.rawValue)|\(start)|\(end)|\(sampleKey)|\(routeStateKey(for: move))"
        }
        .joined(separator: ",")
    }

    private static func routeStateKey(for move: MoveSegment) -> String {
        if let manualData = move.manualRouteCoordinatesData {
            var hasher = Hasher()
            hasher.combine(manualData.count)
            hasher.combine(manualData)
            return "manual:\(hasher.finalize())"
        }

        return "calculated:\(move.routeCacheSignature ?? "none")"
    }

    private static func refreshSampleKey(for samples: [LocationSample]) -> String {
        samples
            .sorted(by: { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                if lhs.dedupeKey != rhs.dedupeKey { return lhs.dedupeKey < rhs.dedupeKey }
                if lhs.sourceRawValue != rhs.sourceRawValue { return lhs.sourceRawValue < rhs.sourceRawValue }
                if lhs.latitude != rhs.latitude { return lhs.latitude < rhs.latitude }
                return lhs.longitude < rhs.longitude
            })
            .map { sample in
                "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
            }
            .joined(separator: ",")
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
                    if entry.showsHealthSourceBadge {
                        Circle()
                            .fill(MovesPalette.healthRoute)
                            .frame(width: 8, height: 8)
                            .overlay {
                                Circle()
                                    .stroke(MovesPalette.card, lineWidth: 1)
                            }
                            .offset(x: 8, y: -8)
                    }
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
    case sample(location: LocationSample, sampleCount: Int, resolvedName: String?)

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
        case .sample(let location, _, _):
            return "sample-\(location.dedupeKey)-\(location.timestamp.timeIntervalSince1970)"
        }
    }

    var mapSelection: TimelineMapSelection {
        switch self {
        case .place(let place):
            return .place(place.id)
        case .move(let segment):
            return .move(segment.id)
        case .liveRoute(let snapshot):
            return .liveRoute(snapshot.id)
        case .start(let place, _):
            return .place(place.id)
        case .sample(let location, _, _):
            return .sample(location.dedupeKey)
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
        case .sample(let location, _, _):
            return location.timestamp
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
        case .sample(let location, _, _):
            return Self.timeString(from: location.timestamp)
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
        case .sample:
            return "mappin.circle.fill"
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
        case .sample:
            return MovesPalette.place
        }
    }

    var showsHealthSourceBadge: Bool {
        switch self {
        case .move(let segment):
            return segment.usesHealthWorkoutRoute
        default:
            return false
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
        case .sample(let location, _, let resolvedName):
            if let resolvedName,
               !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resolvedName
            }
            return Self.coordinateString(
                latitude: location.latitude,
                longitude: location.longitude
            )
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
            var details = [segment.transportMode.title, duration, distance]
            if segment.usesHealthWorkoutRoute {
                details.append("Apple Health")
            }
            return details.joined(separator: "   ")
        case .liveRoute(let snapshot):
            let duration = DurationFormatter.text(for: snapshot.duration)
            let distance = Measurement(value: max(snapshot.distanceMeters, 0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))

            if snapshot.sampleCount == 0 {
                return "Waiting for the first live GPS fix"
            }

            return "\(snapshot.sampleCount) live fixes   \(duration)   \(distance)"
        case .sample:
            return "In progress"
        }
    }

    var tertiaryText: String? {
        switch self {
        case .move(let segment):
            var details: [String] = []

            if let stepCount = segment.stepCount, stepCount > 0 {
                details.append("\(stepCount.formatted(.number)) steps")
            }

            if let averageSpeed = Self.averageSpeedText(for: segment) {
                details.append(averageSpeed)
            }

            return details.isEmpty ? nil : details.joined(separator: "   ")
        case .liveRoute(let snapshot):
            if snapshot.sampleCount == 0 {
                return "Tracking will start as soon as GPS provides the first fix."
            }
            return "Last update \(snapshot.latestDate.formatted(date: .omitted, time: .shortened))"
        case .sample(_, let sampleCount, _):
            if sampleCount == 1 {
                return "1 location sample captured"
            }
            return "\(sampleCount) location samples captured"
        default:
            return nil
        }
    }

    private static func averageSpeedText(for segment: MoveSegment) -> String? {
        guard segment.timelineDuration > 0 else { return nil }

        let kilometersPerHour = max(segment.distanceMeters, 0) / segment.timelineDuration * 3.6
        let formattedSpeed = kilometersPerHour.formatted(.number.precision(.fractionLength(1)))
        return "\(formattedSpeed) km/h"
    }

    private static func timeString(from date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private static func coordinateString(latitude: Double, longitude: Double) -> String {
        let latitudeText = String(format: "%.5f", latitude)
        let longitudeText = String(format: "%.5f", longitude)
        return "\(latitudeText), \(longitudeText)"
    }
}

struct PlaceMarker: Identifiable {
    let id: UUID
    let title: String
    let coordinate: CLLocationCoordinate2D
}
