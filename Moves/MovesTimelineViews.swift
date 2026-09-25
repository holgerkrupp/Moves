//
//  MovesTimelineViews.swift
//  Raul
//
//  Timeline, map strip, and row rendering extracted from ContentView.
//

import Foundation
import CryptoKit
import MapKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    let dayTimeline: DayTimeline
    let isActive: Bool
    @Binding var mapSelection: TimelineMapSelection?

    var body: some View {
        Group {
            if isActive {
                DayTimelinePageContent(
                    dayTimeline: dayTimeline,
                    isActive: isActive,
                    mapSelection: $mapSelection
                )
            } else {
                inactiveState
            }
        }
    }

    private var inactiveState: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 420)
    }
}

struct DayTimelinePageContent: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var undoController: AppUndoController
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    let dayTimeline: DayTimeline
    let isActive: Bool
    private static let transientStopMaximumDuration: TimeInterval = 5 * 60
    private static let provisionalPlaceNameResolver = CLGeocoderPlaceNameResolver()

    @State private var provisionalSampleResolvedTitle: String?
    @State private var provisionalSampleResolvedKey: String?
    @State private var presentationCache: DayTimelinePresentationCache
    @State private var presentationGeneration = 0
    @State private var importedDataStatus: Bool?
    @State private var isReviewingImportedData = false
    @State private var pendingDeletionEntry: TimelineEntry?
    @State private var deletionErrorMessage = ""
    @State private var isShowingDeletionError = false
    @Binding private var mapSelection: TimelineMapSelection?

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        mapSelection: Binding<TimelineMapSelection?> = .constant(nil)
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _mapSelection = mapSelection
        let initialCache: DayTimelinePresentationCache
        if let cached = DayTimelinePresentationCacheStore.value(for: dayTimeline.dayKey) {
            initialCache = cached
        } else {
            let source = DayPresentationSourceCache.source(for: dayTimeline, generation: 0)
            let cache = Self.makePresentationCache(for: dayTimeline, source: source)
            DayTimelinePresentationCacheStore.store(cache, for: dayTimeline.dayKey)
            initialCache = cache
        }
        _presentationCache = State(initialValue: initialCache)
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
                    sampleCount: presentationCache.sampleCount,
                    resolvedName: provisionalSampleTitle(for: latestSample)
                )
            )
        }

        if let liveRouteSnapshot {
            entries.append(.liveRoute(liveRouteSnapshot))
        }

        return entries
    }

    private var presentationRefreshKey: String {
        "\(dayTimeline.dayKey)|\(presentationGeneration)"
    }

    private static func makePresentationCache(
        for dayTimeline: DayTimeline,
        source: DayPresentationSource
    ) -> DayTimelinePresentationCache {
        // Keep the complete import in SwiftData/iCloud, but bound the interactive phone
        // timeline to a recent window. Rendering one row and one map polyline per imported
        // file makes a large history unusable even though the data itself is valid.
        let displayedMoveSelection = TimelinePresentationLimits.selection(
            from: source.visibleMoves,
            maxImportedMoves: TimelinePresentationLimits.maxTimelineImportedMoves,
            maxTotalMoves: TimelinePresentationLimits.maxTimelineMoves,
            importedMoveIDs: source.importedMoveIDs
        )
        let displayedMoves = displayedMoveSelection.moves
        let displayedPlaceIDs = Set(
            displayedMoves.flatMap { [$0.startPlace?.id, $0.endPlace?.id].compactMap { $0 } }
        )
        let incomingPlaceIDs = Set(source.visibleMoves.compactMap { $0.endPlace?.id })
        let outgoingPlaceIDs = Set(source.visibleMoves.compactMap { $0.startPlace?.id })
        let candidatePlaces = displayedMoves.isEmpty
            ? source.visiblePlaces
            : source.visiblePlaces.filter { place in
                displayedPlaceIDs.contains(place.id) || hasExplicitUserLabel(place)
            }

        let places = candidatePlaces
            .filter {
                !shouldHidePlaceFromTimeline(
                    $0,
                    incomingPlaceIDs: incomingPlaceIDs,
                    outgoingPlaceIDs: outgoingPlaceIDs
                )
            }
            .map(TimelineEntry.place)
        let moves = displayedMoves.map(TimelineEntry.move)
        let latestSample = source.visibleSamples.max { $0.timestamp < $1.timestamp }
        var entries = (places + moves).sorted { $0.startDate < $1.startDate }

        if let firstMove = displayedMoves.min(by: { $0.timelineStartDate < $1.timelineStartDate }),
           let startPlace = firstMove.startPlace {
            let hasDayStartPlaceAlready = candidatePlaces.contains(where: { $0.id == startPlace.id })

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

        if entries.isEmpty, let carriedOverPlace = source.carriedOverPlace {
            entries.append(.start(place: carriedOverPlace, timestamp: dayTimeline.dayStart))
        }

        let omittedMoveCount = max(
            displayedMoveSelection.omittedCount,
            source.totalMoveCount - displayedMoves.count
        )

        return DayTimelinePresentationCache(
            timelineEntries: entries,
            transportSummaryMetrics: transportSummaryMetrics(for: source.visibleMoves),
            latestSample: latestSample,
            sampleCount: source.totalSampleCount,
            omittedMoveCount: omittedMoveCount,
            hasImportedRouteData: source.hasImportedRouteData
        )
    }

    private static func initialPresentationCache() -> DayTimelinePresentationCache {
        DayTimelinePresentationCache(
            timelineEntries: [],
            transportSummaryMetrics: [],
            latestSample: nil,
            sampleCount: 0,
            omittedMoveCount: 0,
            hasImportedRouteData: false
        )
    }

    private static func shouldHidePlaceFromTimeline(
        _ place: VisitPlace,
        incomingPlaceIDs: Set<UUID>,
        outgoingPlaceIDs: Set<UUID>
    ) -> Bool {
        if hasExplicitUserLabel(place) {
            return false
        }

        let hasIncomingMove = incomingPlaceIDs.contains(place.id)
        let hasOutgoingMove = outgoingPlaceIDs.contains(place.id)

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
        .task(id: "presentation|\(presentationRefreshKey)") {
            guard !Task.isCancelled else { return }
            if let cached = DayTimelinePresentationCacheStore.value(for: dayTimeline.dayKey) {
                presentationCache = cached
                importedDataStatus = cached.hasImportedRouteData
                return
            }

            let source = DayPresentationSourceCache.source(
                for: dayTimeline,
                generation: presentationGeneration
            )
            importedDataStatus = source.hasImportedRouteData
            let cache = Self.makePresentationCache(for: dayTimeline, source: source)
            DayTimelinePresentationCacheStore.store(cache, for: dayTimeline.dayKey)
            presentationCache = cache
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: .movesLocationSamplesDidChange
            ) {
                guard !Task.isCancelled else { return }
                presentationGeneration &+= 1
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: .movesImportedRouteDataDidChange
            ) {
                guard !Task.isCancelled else { return }
                presentationGeneration &+= 1
            }
        }
        .onChange(of: dayTimeline.dayKey) { _, _ in
            presentationGeneration = 0
            importedDataStatus = nil
            presentationCache = DayTimelinePresentationCacheStore.value(for: dayTimeline.dayKey)
                ?? Self.initialPresentationCache()
            mapSelection = nil
        }
        .sheet(isPresented: $isReviewingImportedData) {
            NavigationStack {
                ImportedRouteDataView(
                    modelContext: modelContext,
                    initialDate: dayTimeline.dayStart
                )
            }
        }
        .confirmationDialog("Delete Entry?", item: $pendingDeletionEntry, titleVisibility: .visible) { entry in
            if case .place(let place) = entry,
               TimelineDeletion.canMergeAdjacentRoutes(for: place) {
                Button("Delete and Merge Routes", role: .destructive) {
                    delete(entry: entry, mergeAdjacentRoutes: true)
                }
            }
            Button("Delete", role: .destructive) { delete(entry: entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the entry from the timeline. You can undo the deletion afterwards.")
        }
        .alert("Could Not Delete Entry", isPresented: $isShowingDeletionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage)
        }
    }

    private var macContent: some View {
        VStack(spacing: 10) {
            DayMapStrip(
                dayTimeline: dayTimeline,
                isActive: isActive,
                selection: $mapSelection
            )

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
        if importedDataStatus == true {
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
        VStack(spacing: 0) {
            if presentationCache.omittedMoveCount > 0 {
                Text("Showing the latest \(displayedMoveCount) of \(displayedMoveCount + presentationCache.omittedMoveCount) routes.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()
            }

            if timelineEntries.isEmpty {
                emptyTimelinePanel
            } else if usesSelection {
                selectableTimelineList
            } else {
                timelineList
            }
        }
        .panelSurface()
    }

    private var displayedMoveCount: Int {
        timelineEntries.reduce(into: 0) { count, entry in
            if case .move = entry {
                count += 1
            }
        }
    }

    private var emptyTimelinePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No segments for this day yet.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))

            if presentationCache.sampleCount > 0 {
                Text("\(presentationCache.sampleCount) location sample\(presentationCache.sampleCount == 1 ? "" : "s") captured. Waiting for the next visit or move.")
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
        LazyVStack(spacing: 0) {
            ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { index, entry in
                timelineRow(
                    for: entry,
                    isFirst: index == 0,
                    isLast: index == timelineEntries.count - 1
                )
                .timelineDeletionSwipeAction(entry: entry) { pendingDeletionEntry = entry }
                .timelineContextMenu(entry: entry) { pendingDeletionEntry = entry }

                if index < timelineEntries.count - 1 {
                    Divider()
                        .padding(.leading, 82)
                }
            }
        }
    }

    private var selectableTimelineList: some View {
        LazyVStack(spacing: 0) {
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
                .timelineDeletionSwipeAction(entry: entry) { pendingDeletionEntry = entry }
                .timelineContextMenu(entry: entry) { pendingDeletionEntry = entry }
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
        return Self.sampleLookupKey(for: latestSample, sampleCount: presentationCache.sampleCount)
    }

    private func provisionalSampleTitle(for sample: LocationSample) -> String? {
        let key = Self.sampleLookupKey(for: sample, sampleCount: presentationCache.sampleCount)
        guard provisionalSampleResolvedKey == key else { return nil }
        return provisionalSampleResolvedTitle
    }

    @MainActor
    private func resolveProvisionalSampleTitle() async {
        guard let latestSample = presentationCache.latestSample else {
            provisionalSampleResolvedKey = nil
            provisionalSampleResolvedTitle = nil
            return
        }

        let key = Self.sampleLookupKey(for: latestSample, sampleCount: presentationCache.sampleCount)
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

    private func delete(entry: TimelineEntry, mergeAdjacentRoutes: Bool = false) {
        do {
            switch entry {
            case .place(let place):
                try TimelineDeletion.delete(
                    place: place,
                    mergeAdjacentRoutes: mergeAdjacentRoutes,
                    in: modelContext,
                    undoManager: undoController.manager
                )
            case .move(let move): try TimelineDeletion.delete(move: move, in: modelContext, undoManager: undoController.manager)
            case .sample(let sample, _, _): try TimelineDeletion.delete(sample: sample, in: modelContext, undoManager: undoController.manager)
            case .liveRoute, .start: return
            }
            mapSelection = nil
        } catch {
            deletionErrorMessage = error.localizedDescription
            isShowingDeletionError = true
        }
    }
}

private extension View {
    @ViewBuilder
    func timelineDeletionSwipeAction(entry: TimelineEntry, action: @escaping () -> Void) -> some View {
        if entry.isDeletable {
            swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: action) {
                    Label("Delete", systemImage: "trash")
                }
            }
        } else {
            self
        }
    }
}

private extension View {
    func timelineContextMenu(entry: TimelineEntry, requestDelete: @escaping () -> Void) -> some View {
        modifier(TimelineEntryContextMenu(entry: entry, requestDelete: requestDelete))
    }
}

/// Keep contextual choices local to the selected activity. This mirrors the
/// discoverable, lightweight actions recommended for context menus while
/// leaving longer editing flows in the detail screen.
private struct TimelineEntryContextMenu: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    let entry: TimelineEntry
    let requestDelete: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            switch entry {
            case .move(let move):
                exportActions(for: move)

                Divider()

                Menu("Activity", systemImage: "figure.walk") {
                    Button("Duplicate Activity", systemImage: "plus.square.on.square") {
                        duplicate(move)
                    }

                    Button("Simplify Route", systemImage: "point.3.connected.trianglepath.dotted") {
                        simplifyRoute(for: move)
                    }
                    .disabled(routeCoordinates(for: move).count < 3)

                    Button("Reset Route Edits", systemImage: "arrow.uturn.backward") {
                        move.clearManualRouteCoordinates()
                        try? modelContext.save()
                    }
                    .disabled(!move.hasManualRouteCoordinates)

                    Menu("Change Transport", systemImage: "arrow.triangle.branch") {
                        ForEach(TransportMode.allCases) { mode in
                            Button {
                                move.transportMode = mode
                                move.clearCachedRouteCoordinates()
                                try? modelContext.save()
                            } label: {
                                Label(mode.title, systemImage: mode.symbolName)
                            }
                        }
                    }

                    Button(move.isExcludedFromConnectionStatistics ? "Include in Statistics" : "Exclude from Statistics", systemImage: "chart.bar") {
                        move.isExcludedFromConnectionStatistics.toggle()
                        try? modelContext.save()
                    }
                }

                Divider()
                Button("Delete Activity", systemImage: "trash", role: .destructive, action: requestDelete)

            case .place(let place):
                exportActions(for: place)
                Divider()
                Button("Delete Place", systemImage: "trash", role: .destructive, action: requestDelete)

            case .sample:
                Button("Delete Sample", systemImage: "trash", role: .destructive, action: requestDelete)

            case .liveRoute, .start:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func exportActions(for move: MoveSegment) -> some View {
        ForEach(TimelineExportFormat.allCases, id: \.self) { format in
            if let payload = TimelineExporter.makePayload(
                move: move,
                format: format,
                fileStem: "moves-\(move.timelineStartDate.formatted(.iso8601.year().month().day()))-\(move.transportMode.rawValue)"
            ) {
                ShareLink(
                    item: TimelineShareFile(data: payload.data, filename: payload.filename),
                    preview: SharePreview(payload.filename)
                ) {
                    Label("Export \(format.title)", systemImage: "doc.badge.arrow.up")
                }
            } else {
                Label("Export \(format.title) unavailable", systemImage: "exclamationmark.triangle")
                    .disabled(true)
            }
        }
    }

    @ViewBuilder
    private func exportActions(for place: VisitPlace) -> some View {
        ForEach(TimelineExportFormat.allCases, id: \.self) { format in
            if let payload = TimelineExporter.makePayload(
                place: place,
                format: format,
                fileStem: "moves-\(place.arrivalDate.formatted(.iso8601.year().month().day()))-place"
            ) {
                ShareLink(
                    item: TimelineShareFile(data: payload.data, filename: payload.filename),
                    preview: SharePreview(payload.filename)
                ) {
                    Label("Export \(format.title)", systemImage: "doc.badge.arrow.up")
                }
            }
        }
    }

    private func duplicate(_ move: MoveSegment) {
        let duplicate = MoveSegment(
            dedupeKey: "manual-duplicate-\(UUID().uuidString)",
            startDate: move.startDate,
            endDate: move.endDate,
            transportMode: move.transportMode,
            distanceMeters: move.distanceMeters,
            stepCount: move.stepCount,
            comment: move.comment
        )
        duplicate.deviceIdentifier = move.deviceIdentifier
        duplicate.startPlace = move.startPlace
        duplicate.endPlace = move.endPlace
        duplicate.dayTimeline = move.dayTimeline

        let route = move.manualRouteCoordinates ?? MoveRouteGeometry.rawCoordinates(for: move)
        if route.count > 1 {
            duplicate.storeManualRouteCoordinates(route)
        }

        modelContext.insert(duplicate)
        try? modelContext.save()
    }

    private func simplifyRoute(for move: MoveSegment) {
        let coordinates = routeCoordinates(for: move)
        guard coordinates.count > 2 else { return }

        // Retain turns that are at least 15 m apart, always keeping both ends.
        // This is intentionally non-destructive: reset returns to the captured route.
        var simplified = [coordinates[0]]
        for coordinate in coordinates.dropFirst().dropLast() {
            if RouteCoordinateOps.distanceMeters(from: simplified[simplified.count - 1], to: coordinate) >= 15 {
                simplified.append(coordinate)
            }
        }
        simplified.append(coordinates[coordinates.count - 1])
        guard simplified.count < coordinates.count else { return }

        move.storeManualRouteCoordinates(simplified)
        try? modelContext.save()
    }

    private func routeCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        move.manualRouteCoordinates ?? MoveRouteGeometry.rawCoordinates(for: move)
    }
}

enum TimelinePresentationLimits {
    /// Imported data remains fully available in SwiftData. These limits only bound the
    /// interactive phone surfaces (rows, markers, and polylines).
    static let maxLoadedMoves = 240
    static let maxLoadedPlaces = 240
    static let maxLoadedSamples = 4_000
    static let maxRouteSamplesPerMove = 500
    static let maxTimelineImportedMoves = 120
    static let maxTimelineMoves = 180
    static let maxMapImportedMoves = 60
    static let maxMapMoves = 100
    static let maxMapPlaceMarkers = 160

    struct MoveSelection {
        let moves: [MoveSegment]
        let omittedCount: Int
    }

    static func selection(
        from moves: [MoveSegment],
        maxImportedMoves: Int,
        maxTotalMoves: Int,
        importedMoveIDs: Set<UUID>? = nil
    ) -> MoveSelection {
        let importedMoves = moves.filter { move in
            importedMoveIDs?.contains(move.id) ?? move.usesImportedRoute
        }
        let importedIDs: Set<UUID>

        if importedMoves.count > maxImportedMoves {
            importedIDs = Set(
                importedMoves
                    .sorted { $0.timelineStartDate > $1.timelineStartDate }
                    .prefix(maxImportedMoves)
                    .map(\.id)
            )
        } else {
            importedIDs = Set(importedMoves.map(\.id))
        }

        var retained = moves.filter { move in
            let isImported = importedMoveIDs?.contains(move.id) ?? move.usesImportedRoute
            return !isImported || importedIDs.contains(move.id)
        }

        if retained.count > maxTotalMoves {
            let retainedIDs = Set(
                retained
                    .sorted { $0.timelineStartDate > $1.timelineStartDate }
                    .prefix(maxTotalMoves)
                    .map(\.id)
            )
            retained = retained.filter { retainedIDs.contains($0.id) }
        }

        return MoveSelection(
            moves: retained,
            omittedCount: max(0, moves.count - retained.count)
        )
    }

    static func routeSamples(from samples: [LocationSample], limit: Int = maxRouteSamplesPerMove) -> [LocationSample] {
        guard limit > 1, samples.count > limit else { return samples }

        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let lastIndex = ordered.count - 1
        let step = Double(lastIndex) / Double(limit - 1)

        return (0..<limit).map { index in
            ordered[Int((Double(index) * step).rounded())]
        }
    }
}

private struct DayPresentationSource {
    struct MoveSources: OptionSet {
        let rawValue: UInt8

        static let imported = MoveSources(rawValue: 1 << 0)
        static let routeTracking = MoveSources(rawValue: 1 << 1)
        static let healthWorkout = MoveSources(rawValue: 1 << 2)
    }

    let resolution: MultiDeviceDayResolution
    let visiblePlaces: [VisitPlace]
    let visibleMoves: [MoveSegment]
    let visibleSamples: [LocationSample]
    let samplesByMoveID: [UUID: [LocationSample]]
    let sourcesByMoveID: [UUID: MoveSources]
    let importedMoveIDs: Set<UUID>
    let hasImportedRouteData: Bool
    let totalMoveCount: Int
    let totalSampleCount: Int
    let carriedOverPlace: VisitPlace?

    init(dayTimeline: DayTimeline) {
        let loaded = Self.loadRecords(for: dayTimeline)
        let samples = loaded.samples
        let resolution = MultiDeviceTimelineResolver.resolve(samples: samples)
        let visibleSamples = samples.filter { resolution.includes($0.deviceIdentifier) }
        let visibleMoves = loaded.moves.filter { resolution.includes($0.deviceIdentifier) }
        let visiblePlaces = loaded.places.filter { resolution.includes($0.deviceIdentifier) }

        var samplesByMoveID: [UUID: [LocationSample]] = [:]
        var sourcesByMoveID: [UUID: MoveSources] = [:]
        var hasImportedRouteData = false

        for sample in visibleSamples {
            if sample.source == .fileRouteImport {
                hasImportedRouteData = true
            }
            guard let moveID = sample.moveSegment?.id else { continue }
            samplesByMoveID[moveID, default: []].append(sample)

            if sample.source.isRouteTrack {
                sourcesByMoveID[moveID, default: []].insert(.routeTracking)
            }
            switch sample.source {
            case .fileRouteImport:
                sourcesByMoveID[moveID, default: []].insert(.imported)
            case .healthWorkoutRoute:
                sourcesByMoveID[moveID, default: []].insert(.healthWorkout)
            default:
                break
            }
        }

        for (moveID, moveSamples) in samplesByMoveID {
            samplesByMoveID[moveID] = TimelinePresentationLimits.routeSamples(from: moveSamples)
        }

        self.resolution = resolution
        self.visiblePlaces = visiblePlaces
        self.visibleMoves = visibleMoves
        self.visibleSamples = visibleSamples
        self.samplesByMoveID = samplesByMoveID
        self.sourcesByMoveID = sourcesByMoveID
        self.importedMoveIDs = Set(
            sourcesByMoveID.compactMap { id, sources in
                sources.contains(.imported) ? id : nil
            }
        )
        self.hasImportedRouteData = hasImportedRouteData || loaded.hasImportedRouteData
        self.totalMoveCount = loaded.totalMoveCount
        self.totalSampleCount = loaded.totalSampleCount
        self.carriedOverPlace = loaded.carriedOverPlace
    }

    private struct LoadedRecords {
        let places: [VisitPlace]
        let moves: [MoveSegment]
        let samples: [LocationSample]
        let totalMoveCount: Int
        let totalSampleCount: Int
        let hasImportedRouteData: Bool
        let carriedOverPlace: VisitPlace?
    }

    private static func loadRecords(for dayTimeline: DayTimeline) -> LoadedRecords {
        guard let context = dayTimeline.modelContext else {
            let allMoves = dayTimeline.moves
            let allPlaces = dayTimeline.places
            let allSamples = dayTimeline.samples
            let moves = Array(
                allMoves.sorted { $0.endDate > $1.endDate }
                    .prefix(TimelinePresentationLimits.maxLoadedMoves)
            )
            let places = Array(
                allPlaces.sorted { $0.arrivalDate > $1.arrivalDate }
                    .prefix(TimelinePresentationLimits.maxLoadedPlaces)
            )
            let samples = Array(
                allSamples.sorted { $0.timestamp > $1.timestamp }
                    .prefix(TimelinePresentationLimits.maxLoadedSamples)
            )
            return LoadedRecords(
                places: places,
                moves: moves,
                samples: samples,
                totalMoveCount: allMoves.count,
                totalSampleCount: allSamples.count,
                hasImportedRouteData: samples.contains { $0.source == .fileRouteImport },
                carriedOverPlace: nil
            )
        }

        let dayStart = dayTimeline.dayStart
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let importedSource = LocationSampleSource.fileRouteImport.rawValue

        let movePredicate = #Predicate<MoveSegment> { move in
            move.startDate < dayEnd && move.endDate >= dayStart
        }
        let placePredicate = #Predicate<VisitPlace> { place in
            place.arrivalDate >= dayStart && place.arrivalDate < dayEnd
        }
        let samplePredicate = #Predicate<LocationSample> { sample in
            sample.timestamp >= dayStart && sample.timestamp < dayEnd
        }
        let importedSamplePredicate = #Predicate<LocationSample> { sample in
            sample.timestamp >= dayStart && sample.timestamp < dayEnd
                && sample.sourceRawValue == importedSource
        }

        do {
            var moveDescriptor = FetchDescriptor<MoveSegment>(
                predicate: movePredicate,
                sortBy: [SortDescriptor(\MoveSegment.endDate, order: .reverse)]
            )
            moveDescriptor.fetchLimit = TimelinePresentationLimits.maxLoadedMoves

            var placeDescriptor = FetchDescriptor<VisitPlace>(
                predicate: placePredicate,
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
            )
            placeDescriptor.fetchLimit = TimelinePresentationLimits.maxLoadedPlaces

            var sampleDescriptor = FetchDescriptor<LocationSample>(
                predicate: samplePredicate,
                sortBy: [SortDescriptor(\LocationSample.timestamp, order: .reverse)]
            )
            sampleDescriptor.fetchLimit = TimelinePresentationLimits.maxLoadedSamples

            var importedDescriptor = FetchDescriptor<LocationSample>(predicate: importedSamplePredicate)
            importedDescriptor.fetchLimit = 1

            let moves = try context.fetch(moveDescriptor)
            let places = try context.fetch(placeDescriptor)
            let samples = try context.fetch(sampleDescriptor)
            let totalMoveCount = try context.fetchCount(FetchDescriptor(predicate: movePredicate))
            let totalSampleCount = try context.fetchCount(FetchDescriptor(predicate: samplePredicate))
            let hasImportedRouteData = try !context.fetch(importedDescriptor).isEmpty

            var carriedOverPlace: VisitPlace?
            if moves.isEmpty, places.isEmpty, totalSampleCount == 0 {
                var carriedDescriptor = FetchDescriptor<VisitPlace>(
                    predicate: #Predicate { place in
                        place.arrivalDate < dayStart
                    },
                    sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
                )
                carriedDescriptor.fetchLimit = 1
                carriedOverPlace = try context.fetch(carriedDescriptor).first
            }

            return LoadedRecords(
                places: places,
                moves: moves,
                samples: samples,
                totalMoveCount: totalMoveCount,
                totalSampleCount: totalSampleCount,
                hasImportedRouteData: hasImportedRouteData,
                carriedOverPlace: carriedOverPlace
            )
        } catch {
            // Preserve a usable page if an older store cannot execute one of the bounded
            // predicates. This path is intentionally capped as well.
            let allMoves = dayTimeline.moves
            let allPlaces = dayTimeline.places
            let allSamples = dayTimeline.samples
            let moves = Array(allMoves.prefix(TimelinePresentationLimits.maxLoadedMoves))
            let places = Array(allPlaces.prefix(TimelinePresentationLimits.maxLoadedPlaces))
            let samples = Array(allSamples.prefix(TimelinePresentationLimits.maxLoadedSamples))
            return LoadedRecords(
                places: places,
                moves: moves,
                samples: samples,
                totalMoveCount: allMoves.count,
                totalSampleCount: allSamples.count,
                hasImportedRouteData: samples.contains { $0.source == .fileRouteImport },
                carriedOverPlace: nil
            )
        }
    }
}

@MainActor
private enum DayPresentationSourceCache {
    private static var entries: [String: DayPresentationSource] = [:]
    private static var keysInUseOrder: [String] = []
    /// This cache only coordinates the timeline and map tasks for the active day. The compact
    /// presentation caches below retain the reusable result without pinning every sample model.
    private static let maximumEntryCount = 1

    static func source(for dayTimeline: DayTimeline, generation: Int) -> DayPresentationSource {
        let key = "\(dayTimeline.dayKey)|\(generation)"
        if let entry = entries[key] {
            markRecentlyUsed(key)
            return entry
        }

        let source = DayPresentationSource(dayTimeline: dayTimeline)
        entries[key] = source
        markRecentlyUsed(key)
        while keysInUseOrder.count > maximumEntryCount {
            entries.removeValue(forKey: keysInUseOrder.removeFirst())
        }
        return source
    }

    static func removeAll() {
        entries.removeAll(keepingCapacity: true)
        keysInUseOrder.removeAll(keepingCapacity: true)
    }

    private static func markRecentlyUsed(_ key: String) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }
}

private struct DayTimelinePresentationCache {
    let timelineEntries: [TimelineEntry]
    let transportSummaryMetrics: [DayTransportSummaryMetric]
    let latestSample: LocationSample?
    let sampleCount: Int
    let omittedMoveCount: Int
    let hasImportedRouteData: Bool
}

@MainActor
private enum DayTimelinePresentationCacheStore {
    private static var entries: [String: DayTimelinePresentationCache] = [:]
    private static var keysInUseOrder: [String] = []
    private static let maximumEntryCount = 12

    static func value(for key: String) -> DayTimelinePresentationCache? {
        guard let entry = entries[key] else { return nil }
        markRecentlyUsed(key)
        return entry
    }

    static func store(_ entry: DayTimelinePresentationCache, for key: String) {
        entries[key] = entry
        markRecentlyUsed(key)
        while keysInUseOrder.count > maximumEntryCount {
            let oldest = keysInUseOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    static func removeAll() {
        entries.removeAll(keepingCapacity: true)
        keysInUseOrder.removeAll(keepingCapacity: true)
    }

    private static func markRecentlyUsed(_ key: String) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
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
    let routes: [RenderedRoute]
    let latestSampleCoordinate: CLLocationCoordinate2D?
    let routeRefreshKey: String
    let placeRefreshKey: String
    let latestSampleKey: String
}

@MainActor
private enum DayMapPresentationCacheStore {
    private static var entries: [String: DayMapPresentationCache] = [:]
    private static var keysInUseOrder: [String] = []
    private static let maximumEntryCount = 12

    static func value(for key: String) -> DayMapPresentationCache? {
        guard let entry = entries[key] else { return nil }
        markRecentlyUsed(key)
        return entry
    }

    static func store(_ entry: DayMapPresentationCache, for key: String) {
        entries[key] = entry
        markRecentlyUsed(key)
        while keysInUseOrder.count > maximumEntryCount {
            let oldest = keysInUseOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    static func removeAll() {
        entries.removeAll(keepingCapacity: true)
        keysInUseOrder.removeAll(keepingCapacity: true)
    }

    private static func markRecentlyUsed(_ key: String) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }
}

@MainActor
private enum DayMapSnapshotCache {
    private static let diskCacheVersion = "v1"
    private static let maximumDiskEntryCount = 24
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func image(for key: String) async -> UIImage? {
        if let image = cache.object(forKey: key as NSString) {
            return image
        }

        let fileURL = diskFileURL(for: key)
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: fileURL.path)
        }.value
        guard let image else { return nil }
        storeInMemory(image, for: key)
        return image
    }

    static func store(_ image: UIImage, for key: String) {
        storeInMemory(image, for: key)
        let fileURL = diskFileURL(for: key)
        let diskEntryLimit = maximumDiskEntryCount

        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard let data = image.pngData() else { return }
                try data.write(to: fileURL, options: .atomic)
                pruneDiskCache(
                    in: fileURL.deletingLastPathComponent(),
                    fileManager: fileManager,
                    maximumEntryCount: diskEntryLimit
                )
            } catch {
                // A disk cache miss only means MapKit renders the snapshot again next time.
            }
        }
    }

    private static func storeInMemory(_ image: UIImage, for key: String) {
        let pixelCost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: pixelCost)
    }

    static func removeAll() {
        cache.removeAllObjects()
    }

    private static func diskFileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("DayMapSnapshots", isDirectory: true)
            .appendingPathComponent(diskCacheVersion, isDirectory: true)
            .appendingPathComponent("\(digest).png")
    }

    nonisolated private static func pruneDiskCache(
        in directory: URL,
        fileManager: FileManager,
        maximumEntryCount: Int
    ) {
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ), files.count > maximumEntryCount else { return }

        let newestFirst = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: resourceKeys).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: resourceKeys).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for staleFile in newestFirst.dropFirst(maximumEntryCount) {
            try? fileManager.removeItem(at: staleFile)
        }
    }
}

@MainActor
enum TimelinePresentationCacheInvalidator {
    static func invalidateAll() {
        DayPresentationSourceCache.removeAll()
        DayTimelinePresentationCacheStore.removeAll()
        DayMapPresentationCacheStore.removeAll()
        DayMapSnapshotCache.removeAll()
    }
}

struct DayMapStrip: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false
    let dayTimeline: DayTimeline
    let isActive: Bool
    @Binding var selection: TimelineMapSelection?
    let fillsAvailableSpace: Bool
    private static let collapsedMapHeight: CGFloat = 180
    private static let collapsedMapCornerRadius: CGFloat = 14
    private static let fullScreenMapAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)
    private static let expandedMapVerticalMargin: CGFloat = 150

    @State private var camera: MapCameraPosition
    @State private var mapRegion: MKCoordinateRegion
    @State private var historicalRoutes: [RenderedRoute]
    @State private var presentationCache: DayMapPresentationCache
    @State private var presentationGeneration = 0
    @State private var isShowingFullScreenMap = false
    @State private var collapsedSnapshotImage: UIImage?
    @State private var collapsedSnapshotKey: String?

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

    private var cameraRefreshKey: String {
        let liveKey = liveRouteSnapshot?.id ?? "none"
        return [presentationCache.routeRefreshKey, presentationCache.placeRefreshKey, liveKey, presentationCache.latestSampleKey].joined(separator: "|")
    }

    private var presentationRefreshKey: String {
        "\(dayTimeline.dayKey)|\(presentationGeneration)"
    }

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        selection: Binding<TimelineMapSelection?> = .constant(nil),
        fillsAvailableSpace: Bool = false
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _selection = selection
        self.fillsAvailableSpace = fillsAvailableSpace
        let initialPresentation: DayMapPresentationCache
        if let cached = DayMapPresentationCacheStore.value(for: dayTimeline.dayKey) {
            initialPresentation = cached
        } else {
            let source = DayPresentationSourceCache.source(for: dayTimeline, generation: 0)
            let cache = Self.makePresentationCache(
                for: dayTimeline,
                source: source,
                generation: 0
            )
            DayMapPresentationCacheStore.store(cache, for: dayTimeline.dayKey)
            initialPresentation = cache
        }
        let initialRegion = Self.region(for: initialPresentation)
        _camera = State(initialValue: .region(initialRegion))
        _mapRegion = State(initialValue: initialRegion)
        _historicalRoutes = State(initialValue: initialPresentation.routes)
        _presentationCache = State(initialValue: initialPresentation)
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
            .task(id: "\(cameraRefreshKey)|\(dayTimeline.dayKey)|\(isActive ? 1 : 0)") {
                guard isActive else { return }
                refreshCamera()
            }
            .onChange(of: isActive) { _, isNowActive in
                guard isNowActive else { return }
                refreshCamera(for: selection)
            }
            .onChange(of: selection) { _, newSelection in
                refreshCamera(for: newSelection)
            }
            .onChange(of: dayTimeline.dayKey) { _, _ in
                let cachedPresentation = DayMapPresentationCacheStore.value(for: dayTimeline.dayKey)
                    ?? Self.initialPresentationCache(coordinate: nil)
                applyPresentation(cachedPresentation)
                presentationGeneration = 0
            }
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: .movesLocationSamplesDidChange
                ) {
                    guard !Task.isCancelled else { return }
                    presentationGeneration &+= 1
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: .movesImportedRouteDataDidChange
                ) {
                    guard !Task.isCancelled else { return }
                    presentationGeneration &+= 1
                }
            }
            .task(id: "presentation|\(presentationRefreshKey)") {
                guard !Task.isCancelled else { return }
                if let cached = DayMapPresentationCacheStore.value(for: dayTimeline.dayKey) {
                    applyPresentation(cached)
                    return
                }
                let source = DayPresentationSourceCache.source(
                    for: dayTimeline,
                    generation: presentationGeneration
                )
                let cache = Self.makePresentationCache(
                    for: dayTimeline,
                    source: source,
                    generation: presentationGeneration
                )
                DayMapPresentationCacheStore.store(
                    cache,
                    for: dayTimeline.dayKey
                )
                applyPresentation(cache)
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
        GeometryReader { proxy in
            if proxy.size.width > 1, proxy.size.height > 1 {
                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    mapContent
                }
            } else {
                Color.clear
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
    }

    private var collapsedMapSnapshotView: some View {
        GeometryReader { proxy in
            let size = CGSize(width: proxy.size.width, height: proxy.size.height)

            ZStack {
                let refreshKey = collapsedSnapshotRefreshKey(for: size)
                if let collapsedSnapshotImage, collapsedSnapshotKey == refreshKey {
                    Image(uiImage: collapsedSnapshotImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Map(position: $camera, interactionModes: []) {
                        mapContent
                    }
                        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                        .allowsHitTesting(false)
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
                    .tint(MovesPalette.place.opacity(selection == nil ? 1 : 0.35))
            } else {
                Annotation(marker.title, coordinate: marker.coordinate, anchor: .center) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = .place(marker.id)
                        }
                    } label: {
                        MapLocationDot(tint: MovesPalette.place, isSelected: isSelected)
                            .opacity(selection != nil && !isSelected ? 0.35 : 1)
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
            mapRegionSnapshotKey,
            presentationCache.routeRefreshKey,
            presentationCache.placeRefreshKey,
            presentationCache.latestSampleKey,
            liveRouteSnapshot?.id ?? "none",
            selectionRefreshKey,
            colorScheme == .dark ? "dark" : "light",
            Locale.current.identifier,
            showsBigMarkers ? "big" : "small",
            collapsedSnapshotRouteKey
        ]
        .joined(separator: "|")
    }

    private var mapRegionSnapshotKey: String {
        let latitude = Int((mapRegion.center.latitude * 100_000).rounded())
        let longitude = Int((mapRegion.center.longitude * 100_000).rounded())
        let latitudeDelta = Int((mapRegion.span.latitudeDelta * 100_000).rounded())
        let longitudeDelta = Int((mapRegion.span.longitudeDelta * 100_000).rounded())
        return "\(latitude):\(longitude):\(latitudeDelta):\(longitudeDelta)"
    }

    @MainActor
    private func refreshCollapsedSnapshot(size: CGSize) async {
        guard !isShowingFullScreenMap, size.width > 1, size.height > 1 else { return }
        guard presentationCache.routeRefreshKey != "initial" else { return }
        let cacheKey = collapsedSnapshotRefreshKey(for: size)
        if let cachedImage = await DayMapSnapshotCache.image(for: cacheKey) {
            collapsedSnapshotImage = cachedImage
            collapsedSnapshotKey = cacheKey
            return
        }

        // Give the already-visible live map first access to MapKit's tile pipeline. Snapshot
        // generation then runs as a background cache fill instead of competing at first paint.
        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        if let cachedImage = await DayMapSnapshotCache.image(for: cacheKey) {
            collapsedSnapshotImage = cachedImage
            collapsedSnapshotKey = cacheKey
            return
        }

        do {
            let image = try await Self.makeCollapsedSnapshot(
                region: mapRegion,
                size: size,
                scale: Self.screenScale,
                routes: historicalRoutes,
                liveRouteSnapshot: liveRouteSnapshot,
                placeMarkers: placeMarkers,
                latestSampleCoordinate: latestSampleCoordinate,
                showsBigMarkers: showsBigMarkers,
                userInterfaceStyle: colorScheme == .dark ? .dark : .light,
                selection: selection
            )

            guard !Task.isCancelled else { return }
            DayMapSnapshotCache.store(image, for: cacheKey)
            collapsedSnapshotImage = image
            collapsedSnapshotKey = cacheKey
        } catch {
            guard !Task.isCancelled else { return }
            collapsedSnapshotImage = nil
            collapsedSnapshotKey = nil
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
        showsBigMarkers: Bool,
        userInterfaceStyle: UIUserInterfaceStyle,
        selection: TimelineMapSelection?
    ) async throws -> UIImage {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale
        options.traitCollection = UITraitCollection(userInterfaceStyle: userInterfaceStyle)

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()

        return renderCollapsedSnapshotOverlay(
            snapshot: snapshot,
            routes: routes,
            liveRouteSnapshot: liveRouteSnapshot,
            placeMarkers: placeMarkers,
            latestSampleCoordinate: latestSampleCoordinate,
            showsBigMarkers: showsBigMarkers,
            selection: selection
        )
    }

    private static func renderCollapsedSnapshotOverlay(
        snapshot: MKMapSnapshotter.Snapshot,
        routes: [RenderedRoute],
        liveRouteSnapshot: LiveRouteTrackingSnapshot?,
        placeMarkers: [PlaceMarker],
        latestSampleCoordinate: CLLocationCoordinate2D?,
        showsBigMarkers: Bool,
        selection: TimelineMapSelection?
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: snapshot.image.size, format: format).image { _ in
            snapshot.image.draw(at: .zero)

            for route in routes {
                let isSelected: Bool
                if case .move(let selectedID) = selection {
                    isSelected = route.id == selectedID.uuidString
                } else {
                    isSelected = false
                }
                let dimsForOtherSelection = selection != nil && !isSelected
                strokeRoute(
                    route.shadowCoordinates,
                    in: snapshot,
                    color: UIColor(route.shadowTint).withAlphaComponent(dimsForOtherSelection ? 0.2 : 1),
                    lineWidth: isSelected ? route.shadowLineWidth + 4 : route.shadowLineWidth
                )
                strokeRoute(
                    route.coordinates,
                    in: snapshot,
                    color: UIColor(route.tint).withAlphaComponent(dimsForOtherSelection ? 0.28 : 0.95),
                    lineWidth: isSelected ? route.lineWidth + 4 : route.lineWidth
                )
            }

            if let liveRouteSnapshot {
                let isSelected: Bool
                if case .liveRoute = selection { isSelected = true } else { isSelected = false }
                strokeRoute(
                    liveRouteSnapshot.coordinates,
                    in: snapshot,
                    color: UIColor(MovesPalette.routeTracking).withAlphaComponent(selection != nil && !isSelected ? 0.28 : 0.95),
                    lineWidth: isSelected ? 9 : 5
                )
            }

            for marker in placeMarkers {
                let isSelected = selection == .place(marker.id)
                drawMarker(
                    at: snapshot.point(for: marker.coordinate),
                    in: snapshot.image.size,
                    tint: UIColor(MovesPalette.place),
                    isLarge: showsBigMarkers,
                    isSelected: isSelected,
                    isDimmed: selection != nil && !isSelected
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
                    isLarge: showsBigMarkers,
                    isSelected: selection != nil,
                    isDimmed: false
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
        isLarge: Bool,
        isSelected: Bool,
        isDimmed: Bool
    ) {
        let diameter: CGFloat = isSelected ? 14 : (isLarge ? 14 : 8)
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
        tint.withAlphaComponent(isDimmed ? 0.32 : 1).setFill()
        path.fill()

        UIColor.white.setStroke()
        path.lineWidth = isLarge ? 2 : 1.5
        path.stroke()

        if isSelected {
            let ringRect = rect.insetBy(dx: -5, dy: -5)
            let ring = UIBezierPath(ovalIn: ringRect)
            UIColor.white.withAlphaComponent(0.96).setStroke()
            ring.lineWidth = 3
            ring.stroke()
            tint.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private var selectionRefreshKey: String {
        switch selection {
        case .place(let id): return "place:\(id.uuidString)"
        case .move(let id): return "move:\(id.uuidString)"
        case .liveRoute(let id): return "live:\(id)"
        case .sample(let id): return "sample:\(id)"
        case nil: return "none"
        }
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
    private func applyPresentation(_ presentation: DayMapPresentationCache) {
        let region = Self.region(
            for: presentation,
            liveCoordinates: liveRouteSnapshot?.coordinates ?? []
        )

        // Commit the camera before exposing the route refresh key. Otherwise the snapshot
        // task can cache a correctly drawn route over MapKit's default Cupertino region.
        mapRegion = region
        camera = .region(region)
        historicalRoutes = presentation.routes
        presentationCache = presentation
    }

    private static func region(
        for presentation: DayMapPresentationCache,
        liveCoordinates: [CLLocationCoordinate2D] = []
    ) -> MKCoordinateRegion {
        let coordinates = presentation.routes.flatMap(\.coordinates)
            + liveCoordinates
            + presentation.placeMarkers.map(\.coordinate)
        let cameraCoordinates = coordinates.isEmpty
            ? presentation.latestSampleCoordinate.map { [$0] } ?? []
            : coordinates
        return MapRegionFactory.region(for: cameraCoordinates)
    }

    @MainActor
    private func refreshCamera() {
        let liveCoordinates = liveRouteSnapshot?.coordinates ?? []
        let allCoordinates = historicalRouteCoordinates
            + liveCoordinates
            + placeMarkers.map(\.coordinate)
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
        source: DayPresentationSource,
        displayedMoves: [MoveSegment]
    ) -> [RenderedRoute] {
        displayedMoves
            .sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
            .map { move in
                let sources = source.sourcesByMoveID[move.id] ?? []
                let fallback = MoveRouteGeometry.rawCoordinates(
                    for: move,
                    samples: source.samplesByMoveID[move.id] ?? [],
                    usesHealthWorkoutRoute: sources.contains(.healthWorkout)
                )
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)

                return RenderedRoute(
                    id: move.id.uuidString,
                    coordinates: move.manualRouteCoordinates ?? move.cachedRouteCoordinates(for: signature) ?? fallback,
                    usesHighAccuracyRouteTracking: sources.contains(.routeTracking),
                    usesHealthWorkoutRoute: sources.contains(.healthWorkout),
                    transportMode: move.transportMode
                )
            }
    }

    private static func initialPresentationCache(
        coordinate: CLLocationCoordinate2D?
    ) -> DayMapPresentationCache {
        DayMapPresentationCache(
            placeMarkers: [],
            routes: [],
            latestSampleCoordinate: coordinate,
            routeRefreshKey: "initial",
            placeRefreshKey: "initial",
            latestSampleKey: "initial"
        )
    }

    private static func makePresentationCache(
        for dayTimeline: DayTimeline,
        source: DayPresentationSource,
        generation: Int
    ) -> DayMapPresentationCache {
        let displayedMoves = TimelinePresentationLimits.selection(
            from: source.visibleMoves,
            maxImportedMoves: TimelinePresentationLimits.maxMapImportedMoves,
            maxTotalMoves: TimelinePresentationLimits.maxMapMoves,
            importedMoveIDs: source.importedMoveIDs
        ).moves
        let sortedPlaces = mapPlaces(
            for: dayTimeline,
            source: source,
            displayedMoves: displayedMoves
        )
        let placeMarkers = sortedPlaces.map {
            PlaceMarker(id: $0.id, title: $0.displayTitle, coordinate: $0.coordinate)
        }
        let placeRefreshKey = sortedPlaces.map { place in
            let arrival = Int(place.arrivalDate.timeIntervalSince1970.rounded())
            let departure = Int((place.departureDate ?? place.arrivalDate).timeIntervalSince1970.rounded())
            return "\(place.id.uuidString)|\(arrival)|\(departure)"
        }
        .joined(separator: ",")

        let latestSample = source.visibleSamples
            .filter { CLLocationCoordinate2DIsValid($0.coordinate) }
            .max(by: { $0.timestamp < $1.timestamp })
        let latestSampleKey = latestSample.map { sample in
            "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
        } ?? "none"

        let routes = renderedRoutes(source: source, displayedMoves: displayedMoves)

        return DayMapPresentationCache(
            placeMarkers: placeMarkers,
            routes: routes,
            latestSampleCoordinate: latestSample?.coordinate,
            routeRefreshKey: "\(dayTimeline.dayKey)|\(generation)",
            placeRefreshKey: placeRefreshKey,
            latestSampleKey: latestSampleKey
        )
    }

    private static func mapPlaces(
        for dayTimeline: DayTimeline,
        source: DayPresentationSource,
        displayedMoves: [MoveSegment]
    ) -> [VisitPlace] {
        let routePlaces = displayedMoves.flatMap { move in
            [move.startPlace, move.endPlace].compactMap { $0 }
        }
        var placesByID: [UUID: VisitPlace] = [:]
        let dayPlaces = source.visiblePlaces.isEmpty
            ? [source.carriedOverPlace].compactMap { $0 }
            : source.visiblePlaces

        for place in dayPlaces + routePlaces {
            placesByID[place.id] = place
        }

        let sortedPlaces = placesByID.values
            .filter { CLLocationCoordinate2DIsValid($0.coordinate) }
            .sorted(by: { $0.arrivalDate < $1.arrivalDate })

        guard sortedPlaces.count > TimelinePresentationLimits.maxMapPlaceMarkers else {
            return sortedPlaces
        }
        return Array(sortedPlaces.suffix(TimelinePresentationLimits.maxMapPlaceMarkers))
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

    var isDeletable: Bool {
        switch self {
        case .place, .move, .sample: true
        case .liveRoute, .start: false
        }
    }

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
        guard DurationFormatter.showsNonzeroMinutes(for: segment.timelineDuration) else {
            return nil
        }

        let kilometersPerHour = max(segment.distanceMeters, 0) / segment.timelineDuration * 3.6
        return MovesMeasurementFormatter.speed(kilometersPerHour: kilometersPerHour)
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
