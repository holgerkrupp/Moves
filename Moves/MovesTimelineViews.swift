//
//  MovesTimelineViews.swift
//  Raul
//
//  Timeline, map strip, and row rendering extracted from ContentView.
//

import CryptoKit
import Charts
import ESADesignKit
import Foundation
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    @State private var isShowingFullScreenMap = false
    @State private var timelineScrollOffset: CGFloat = 0
    @State private var pendingDeletionEntry: TimelineEntry?
    @State private var deletionErrorMessage = ""
    @State private var isShowingDeletionError = false
    @State private var flightMergeAnchor: MoveSegment?
    @Binding private var mapSelection: TimelineMapSelection?

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        mapSelection: Binding<TimelineMapSelection?> = .constant(nil)
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _mapSelection = mapSelection
        // Do not fault SwiftData relationships while SwiftUI constructs a page. A nearby
        // cache hit is still displayed immediately; misses are loaded by the task below.
        let initialCache = DayTimelinePresentationCacheStore.value(for: dayTimeline.dayKey)
            ?? Self.initialPresentationCache()
        _presentationCache = State(initialValue: initialCache)
    }

    private var liveRouteSnapshot: LiveRouteTrackingSnapshot? {
        liveRouteTrackingSnapshot(for: dayTimeline, captureManager: captureManager)
    }

    private var timelineRows: [TimelineEntryRow] {
        var rows = presentationCache.timelineRows

        if rows.isEmpty, let latestSample = presentationCache.latestSample {
            let entry = TimelineEntry.sample(
                location: latestSample,
                sampleCount: presentationCache.sampleCount,
                resolvedName: provisionalSampleTitle(for: latestSample)
            )
            rows.append(TimelineEntryRow(entry: entry))
        }

        if let liveRouteSnapshot {
            let entry = TimelineEntry.liveRoute(liveRouteSnapshot)
            rows.append(TimelineEntryRow(entry: entry))
        }

        return rows
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

        let timelineRows = entries.map { entry in
            let sources: TimelineMoveSourceFlags
            if case .move(let move) = entry {
                sources = source.sourcesByMoveID[move.id] ?? []
            } else {
                sources = []
            }
            return TimelineEntryRow(
                entry: entry,
                presentation: TimelineRowPresentation(entry: entry, moveSources: sources)
            )
        }

        return DayTimelinePresentationCache(
            timelineRows: timelineRows,
            transportSummaryMetrics: transportSummaryMetrics(for: source.visibleMoves),
            elevationProfile: DayElevationProfileBuilder.build(
                samples: source.visibleSamples.map {
                    DayElevationSample(timestamp: $0.timestamp, elevationMeters: $0.altitude)
                },
                dayStart: dayTimeline.dayStart
            ),
            latestSample: latestSample,
            sampleCount: source.totalSampleCount,
            omittedMoveCount: omittedMoveCount,
            hasImportedRouteData: source.hasImportedRouteData
        )
    }

    private static func initialPresentationCache() -> DayTimelinePresentationCache {
        DayTimelinePresentationCache(
            timelineRows: [],
            transportSummaryMetrics: [],
            elevationProfile: nil,
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
        let valuesByBucket = DayTransportSummaryCalculator.aggregate(moves)

        return DayTransportBucket.allCases.compactMap { bucket in
            let value = valuesByBucket[bucket, default: .zero]
            let distance = value.distanceMeters
            guard distance > 0 else { return nil }

            return DayTransportSummaryMetric(
                id: bucket.rawValue,
                title: bucket.title,
                symbolName: bucket.symbolName,
                tint: bucket.tint,
                duration: value.duration,
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
        .id(dayTimeline.dayKey)
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            guard isActive else { return }
            MovesStartupInstrumentation.event("firstContentViewConstruction")
        }
        .task(id: provisionalSampleLookupKey) {
            await resolveProvisionalSampleTitle()
        }
        .task(id: "presentation|\(presentationRefreshKey)") {
            guard !Task.isCancelled else { return }
            MovesStartupInstrumentation.event("selectedDayPresentationStart")
            if let cached = DayTimelinePresentationCacheStore.value(for: dayTimeline.dayKey) {
                presentationCache = cached
                importedDataStatus = cached.hasImportedRouteData
                MovesStartupInstrumentation.event("selectedDayPresentationEnd")
                markTimelineInteractiveIfNeeded()
                return
            }

            let state = MovesStartupInstrumentation.signposter.beginInterval("selectedDayPresentationFetchAndBuild")
            let source = DayPresentationSourceCache.source(
                for: dayTimeline,
                generation: presentationGeneration
            )
            importedDataStatus = source.hasImportedRouteData
            let cache = Self.makePresentationCache(for: dayTimeline, source: source)
            MovesStartupInstrumentation.signposter.endInterval("selectedDayPresentationFetchAndBuild", state)
            DayTimelinePresentationCacheStore.store(cache, for: dayTimeline.dayKey)
            presentationCache = cache
            MovesStartupInstrumentation.event("selectedDayPresentationEnd")
            markTimelineInteractiveIfNeeded()
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
        .task {
            for await notification in NotificationCenter.default.notifications(
                named: .movesMoveDataDidChange
            ) {
                guard !Task.isCancelled else { return }
                TimelinePresentationCacheInvalidator.invalidate(
                    dayKey: notification.userInfo?[TimelineMutationNotifier.dayKeyUserInfoKey] as? String
                )
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
        .sheet(item: $flightMergeAnchor) { move in
            FlightMergeView(anchor: move)
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .movesPresentFlightMerge) {
                guard !Task.isCancelled else { return }
                if let move = notification.object as? MoveSegment {
                    flightMergeAnchor = move
                }
            }
        }
    }

    private func markTimelineInteractiveIfNeeded() {
        guard isActive else { return }
        MovesStartupMilestone.markFirstTimelineInteractive()
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
                elevationPanel
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
                if horizontalSizeClass != .compact {
                    DayMapStrip(
                        dayTimeline: dayTimeline,
                        isActive: isActive,
                        selection: $mapSelection
                    )
                }

                importedDataReviewButton

                timelinePanel(usesSelection: false)

                elevationPanel

                daySummaryPanel
            }
            .safeAreaPadding(.horizontal, 14)
            .safeAreaPadding(.bottom, 24)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, newOffset in
            timelineScrollOffset = newOffset
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollingHero(
            height: DayMapStrip.collapsedMapHeight,
            enabled: horizontalSizeClass == .compact
        ) {
            DayMapStrip(
                dayTimeline: dayTimeline,
                isActive: isActive,
                selection: $mapSelection,
                fillsAvailableSpace: true,
                usesHeroStyle: true,
                fullScreenMapState: $isShowingFullScreenMap
            )
        }
        .overlay(alignment: .top) {
            if horizontalSizeClass == .compact {
                let buttonOpacity = max(0, 1 - min(timelineScrollOffset / 28, 1))

                VStack {
                    Spacer()

                    HStack {
                        Spacer()
                        TimelineFullScreenMapButton(isFullScreen: $isShowingFullScreenMap)
                            .padding(10)
                            .opacity(buttonOpacity)
                            .allowsHitTesting(buttonOpacity > 0.01)
                            .accessibilityHidden(buttonOpacity <= 0.01)
                    }
                }
                .frame(height: DayMapStrip.collapsedMapHeight)
                .animation(.easeOut(duration: 0.16), value: buttonOpacity <= 0.01)
            }
        }
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

                    elevationPanel

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
    private var elevationPanel: some View {
        if let profile = presentationCache.elevationProfile {
            DayElevationProfileView(dayStart: dayTimeline.dayStart, profile: profile)
                .panelSurface()
        }
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
        let rows = timelineRows

        VStack(spacing: 0) {
            if presentationCache.omittedMoveCount > 0 {
                let moveCount = displayedMoveCount(in: rows)
                Text("Showing the latest \(moveCount) of \(moveCount + presentationCache.omittedMoveCount) routes.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()
            }

            if rows.isEmpty {
                emptyTimelinePanel
            } else if usesSelection {
                selectableTimelineList(rows: rows)
            } else {
                timelineList(rows: rows)
            }
        }
        .panelSurface()
    }

    private func displayedMoveCount(in rows: [TimelineEntryRow]) -> Int {
        rows.reduce(into: 0) { count, row in
            if case .move = row.entry {
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

    private func timelineList(rows: [TimelineEntryRow]) -> some View {
        let lastIndex = rows.count - 1
        return LazyVStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                timelineRow(
                    for: row,
                    isFirst: index == 0,
                    isLast: index == lastIndex
                )
                .timelineDeletionSwipeAction(entry: row.entry) { pendingDeletionEntry = row.entry }
                .timelineContextMenu(entry: row.entry) { pendingDeletionEntry = row.entry }

                if index < lastIndex {
                    Divider()
                        .padding(.leading, 82)
                }
            }
        }
    }

    private func selectableTimelineList(rows: [TimelineEntryRow]) -> some View {
        let lastIndex = rows.count - 1
        return LazyVStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mapSelection = row.entry.mapSelection
                        }
                    } label: {
                        StorylineRow(
                            presentation: row.presentation,
                            isFirst: index == 0,
                            isLast: index == lastIndex
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    timelineDetailLink(for: row)
                }
                .timelineDeletionSwipeAction(entry: row.entry) { pendingDeletionEntry = row.entry }
                .timelineContextMenu(entry: row.entry) { pendingDeletionEntry = row.entry }
                .background {
                    if mapSelection == row.entry.mapSelection {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(row.presentation.iconTint.opacity(0.15))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                    }
                }

                if index < lastIndex {
                    Divider()
                        .padding(.leading, 82)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineDetailLink(for row: TimelineEntryRow) -> some View {
        switch row.entry {
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
    private func timelineRow(for row: TimelineEntryRow, isFirst: Bool, isLast: Bool) -> some View {
        switch row.entry {
        case .place(let place):
            NavigationLink {
                PlaceMapDetailView(place: place)
            } label: {
                StorylineRow(presentation: row.presentation, isFirst: isFirst, isLast: isLast)
            }
            .buttonStyle(.plain)

        case .move(let segment):
            NavigationLink {
                MoveMapDetailView(segment: segment)
            } label: {
                StorylineRow(presentation: row.presentation, isFirst: isFirst, isLast: isLast)
            }
            .buttonStyle(.plain)

        case .liveRoute:
            StorylineRow(presentation: row.presentation, isFirst: isFirst, isLast: isLast)

        case .start:
            StorylineRow(presentation: row.presentation, isFirst: isFirst, isLast: isLast)

        case .sample:
            StorylineRow(presentation: row.presentation, isFirst: isFirst, isLast: isLast)
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
                        do {
                            try modelContext.save()
                            TimelineMutationNotifier.didChange(dayKey: move.dayTimeline?.dayKey, objectID: move.id)
                        } catch {
                            modelContext.rollback()
                        }
                    }
                    .disabled(!move.hasManualRouteCoordinates)

                    Menu("Change Transport", systemImage: "arrow.triangle.branch") {
                        ForEach(TransportMode.allCases) { mode in
                            Button {
                                move.setTransportMode(mode, provenance: .manual)
                                move.clearCachedRouteCoordinates()
                                do {
                                    try modelContext.save()
                                    if let dayKey = move.dayTimeline?.dayKey {
                                        ExplorationIncrementalHooks.enqueueLiveDay(dayKey)
                                    }
                                    TimelineMutationNotifier.didChange(dayKey: move.dayTimeline?.dayKey, objectID: move.id)
                                } catch {
                                    modelContext.rollback()
                                }
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
                Button("Merge into Flight…", systemImage: "arrow.triangle.merge") {
                    NotificationCenter.default.post(name: .movesPresentFlightMerge, object: move)
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
        do {
            try modelContext.save()
            TimelineMutationNotifier.didChange(dayKey: duplicate.dayTimeline?.dayKey, objectID: duplicate.id)
        } catch {
            modelContext.rollback()
        }
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
        do {
            try modelContext.save()
            TimelineMutationNotifier.didChange(dayKey: move.dayTimeline?.dayKey, objectID: move.id)
        } catch {
            modelContext.rollback()
        }
    }

    private func routeCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        move.manualRouteCoordinates ?? MoveRouteGeometry.rawCoordinates(for: move)
    }
}

struct DayElevationSample: Sendable, Equatable {
    let timestamp: Date
    let elevationMeters: Double
}

struct DayElevationPoint: Identifiable, Sendable, Equatable {
    let timestamp: Date
    let elevationMeters: Double

    var id: Date { timestamp }
}

struct DayElevationSegment: Identifiable, Sendable, Equatable {
    let points: [DayElevationPoint]

    var id: String {
        guard let first = points.first, let last = points.last else { return "empty" }
        return "\(first.timestamp.timeIntervalSince1970)-\(last.timestamp.timeIntervalSince1970)"
    }
}

struct DayElevationProfile: Sendable, Equatable {
    let segments: [DayElevationSegment]
    let minimumElevationMeters: Double
    let maximumElevationMeters: Double

    var isEmpty: Bool { segments.allSatisfy { $0.points.isEmpty } }

    var yDomain: ClosedRange<Double> {
        guard minimumElevationMeters < maximumElevationMeters else {
            let padding = max(abs(minimumElevationMeters) * 0.05, 10)
            return (minimumElevationMeters - padding)...(maximumElevationMeters + padding)
        }

        let padding = max((maximumElevationMeters - minimumElevationMeters) * 0.12, 10)
        return (minimumElevationMeters - padding)...(maximumElevationMeters + padding)
    }
}

enum DayElevationProfileBuilder {
    static let defaultMaximumPointCount = 180

    static func build(
        samples: [DayElevationSample],
        dayStart: Date,
        maximumPointCount: Int = defaultMaximumPointCount
    ) -> DayElevationProfile? {
        let dayEnd = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let sorted = samples
            .filter {
                $0.timestamp >= dayStart
                    && $0.timestamp < dayEnd
                    && TimelineElevationRules.isTrustworthy($0.elevationMeters)
            }
            .sorted { $0.timestamp < $1.timestamp }

        guard !sorted.isEmpty else { return nil }

        var deduplicated: [DayElevationSample] = []
        deduplicated.reserveCapacity(sorted.count)
        for sample in sorted {
            if let previous = deduplicated.last,
               sample.timestamp.timeIntervalSince(previous.timestamp)
                    <= TimelineElevationRules.duplicateTimestampTolerance {
                deduplicated[deduplicated.count - 1] = sample
            } else {
                deduplicated.append(sample)
            }
        }

        var rawSegments: [[DayElevationPoint]] = [[]]
        for sample in deduplicated {
            if let previous = rawSegments[rawSegments.count - 1].last,
               sample.timestamp.timeIntervalSince(previous.timestamp) > TimelineElevationRules.maximumProfileGap {
                rawSegments.append([])
            }
            rawSegments[rawSegments.count - 1].append(
                DayElevationPoint(
                    timestamp: sample.timestamp,
                    elevationMeters: sample.elevationMeters
                )
            )
        }

        let nonEmptySegments = rawSegments.filter { !$0.isEmpty }
        guard !nonEmptySegments.isEmpty else { return nil }
        let pointBudget = max(maximumPointCount, nonEmptySegments.count * 2)
        let totalPointCount = nonEmptySegments.reduce(0) { $0 + $1.count }
        var budgets = nonEmptySegments.map { segment in
            max(2, Int((Double(segment.count) / Double(totalPointCount) * Double(pointBudget)).rounded()))
        }
        while budgets.reduce(0, +) > pointBudget {
            guard let index = budgets.indices.max(by: { budgets[$0] < budgets[$1] }), budgets[index] > 2 else {
                break
            }
            budgets[index] -= 1
        }

        let segments = zip(nonEmptySegments, budgets).map { points, budget in
            DayElevationSegment(points: downsample(points, maximumPointCount: min(budget, points.count)))
        }
        let elevations = deduplicated.map(\.elevationMeters)
        return DayElevationProfile(
            segments: segments,
            minimumElevationMeters: elevations.min() ?? 0,
            maximumElevationMeters: elevations.max() ?? 0
        )
    }

    private static func downsample(
        _ points: [DayElevationPoint],
        maximumPointCount: Int
    ) -> [DayElevationPoint] {
        guard points.count > maximumPointCount else { return points }
        if maximumPointCount <= 1 {
            return [points[0]]
        }
        if maximumPointCount == 2 {
            return [points[0], points[points.count - 1]]
        }

        var result = [points[0]]
        let interiorCount = maximumPointCount - 2
        let bucketWidth = Double(points.count - 2) / Double(interiorCount)
        for bucketIndex in 0..<interiorCount {
            let start = 1 + Int(floor(Double(bucketIndex) * bucketWidth))
            let end = min(
                points.count - 1,
                1 + Int(floor(Double(bucketIndex + 1) * bucketWidth))
            )
            let bucket = points[start..<max(start + 1, end)]
            if let minimum = bucket.min(by: { $0.elevationMeters < $1.elevationMeters }) {
                result.append(minimum)
            }
            if let maximum = bucket.max(by: { $0.elevationMeters < $1.elevationMeters }) {
                result.append(maximum)
            }
        }
        result.append(points[points.count - 1])

        var unique = result.sorted { $0.timestamp < $1.timestamp }
        var seen = Set<Date>()
        unique.removeAll { !seen.insert($0.timestamp).inserted }
        if unique.count > maximumPointCount {
            let step = Double(unique.count - 1) / Double(maximumPointCount - 1)
            return (0..<maximumPointCount).map { unique[Int((Double($0) * step).rounded())] }
        }
        return unique
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

struct TimelineMoveSourceFlags: OptionSet, Equatable {
    let rawValue: UInt8

    static let imported = TimelineMoveSourceFlags(rawValue: 1 << 0)
    static let routeTracking = TimelineMoveSourceFlags(rawValue: 1 << 1)
    static let healthWorkout = TimelineMoveSourceFlags(rawValue: 1 << 2)
}

private struct DayPresentationSource {
    typealias MoveSources = TimelineMoveSourceFlags

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

    init(dayTimeline: DayTimeline, loadAll: Bool = false) {
        let loaded = Self.loadRecords(for: dayTimeline, loadAll: loadAll)
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

        for move in visibleMoves where move.usesImportedRoute {
            sourcesByMoveID[move.id, default: []].insert(.imported)
            hasImportedRouteData = true
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

    private static func loadRecords(for dayTimeline: DayTimeline, loadAll: Bool) -> LoadedRecords {
        guard let context = dayTimeline.modelContext else {
            let allMoves = dayTimeline.moves
            let allPlaces = dayTimeline.places
            let allSamples = dayTimeline.samples
            let moves = loadAll
                ? allMoves.sorted { $0.endDate > $1.endDate }
                : Array(allMoves.sorted { $0.endDate > $1.endDate }.prefix(TimelinePresentationLimits.maxLoadedMoves))
            let places = loadAll
                ? allPlaces.sorted { $0.arrivalDate > $1.arrivalDate }
                : Array(allPlaces.sorted { $0.arrivalDate > $1.arrivalDate }.prefix(TimelinePresentationLimits.maxLoadedPlaces))
            let samples = loadAll
                ? allSamples.sorted { $0.timestamp > $1.timestamp }
                : Array(allSamples.sorted { $0.timestamp > $1.timestamp }.prefix(TimelinePresentationLimits.maxLoadedSamples))
            return LoadedRecords(
                places: places,
                moves: moves,
                samples: samples,
                totalMoveCount: allMoves.count,
                totalSampleCount: allSamples.count,
                hasImportedRouteData: samples.contains { $0.source == .fileRouteImport }
                    || moves.contains(where: { $0.importedRouteData != nil }),
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
            MovesStartupInstrumentation.event("todayMoveFetch")
            var moveDescriptor = FetchDescriptor<MoveSegment>(
                predicate: movePredicate,
                sortBy: [SortDescriptor(\MoveSegment.endDate, order: .reverse)]
            )
            if !loadAll {
                moveDescriptor.fetchLimit = TimelinePresentationLimits.maxLoadedMoves + 1
            }

            var placeDescriptor = FetchDescriptor<VisitPlace>(
                predicate: placePredicate,
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
            )
            if !loadAll {
                placeDescriptor.fetchLimit = TimelinePresentationLimits.maxLoadedPlaces + 1
            }

            var sampleDescriptor = FetchDescriptor<LocationSample>(
                predicate: samplePredicate,
                sortBy: [SortDescriptor(\LocationSample.timestamp, order: .reverse)]
            )
            if !loadAll {
                sampleDescriptor.fetchLimit = TimelinePresentationLimits.maxLoadedSamples + 1
            }

            var importedDescriptor = FetchDescriptor<LocationSample>(predicate: importedSamplePredicate)
            importedDescriptor.fetchLimit = 1

            let fetchedMoves = try context.fetch(moveDescriptor)
            MovesStartupInstrumentation.event("todayPlaceFetch")
            let fetchedPlaces = try context.fetch(placeDescriptor)
            MovesStartupInstrumentation.event("todayLocationSampleFetch")
            let fetchedSamples = try context.fetch(sampleDescriptor)
            let moves = loadAll
                ? fetchedMoves
                : Array(fetchedMoves.prefix(TimelinePresentationLimits.maxLoadedMoves))
            let places = loadAll
                ? fetchedPlaces
                : Array(fetchedPlaces.prefix(TimelinePresentationLimits.maxLoadedPlaces))
            let samples = loadAll
                ? fetchedSamples
                : Array(fetchedSamples.prefix(TimelinePresentationLimits.maxLoadedSamples))
            let totalMoveCount = loadAll
                ? try context.fetchCount(FetchDescriptor(predicate: movePredicate))
                : fetchedMoves.count
            let totalSampleCount = loadAll
                ? try context.fetchCount(FetchDescriptor(predicate: samplePredicate))
                : fetchedSamples.count
            let hasImportedSamples = try !context.fetch(importedDescriptor).isEmpty
            let hasImportedRouteData = moves.contains { $0.importedRouteData != nil }
                || hasImportedSamples

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
            // Never fault an unbounded relationship as an error fallback. A
            // subsequent bounded task can retry this page.
            return LoadedRecords(
                places: [],
                moves: [],
                samples: [],
                totalMoveCount: 0,
                totalSampleCount: 0,
                hasImportedRouteData: false,
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
    private static let maximumEntryCount = 2

    static func source(
        for dayTimeline: DayTimeline,
        generation: Int,
        loadAll: Bool = false
    ) -> DayPresentationSource {
        let key = "\(dayTimeline.dayKey)|\(generation)|\(loadAll ? "all" : "bounded")"
        if let entry = entries[key] {
            markRecentlyUsed(key)
            return entry
        }

        let source = DayPresentationSource(dayTimeline: dayTimeline, loadAll: loadAll)
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

    static func remove(dayKey: String) {
        entries = entries.filter { !$0.key.hasPrefix("\(dayKey)|") }
        keysInUseOrder.removeAll { $0.hasPrefix("\(dayKey)|") }
    }

    private static func markRecentlyUsed(_ key: String) {
        keysInUseOrder.removeAll { $0 == key }
        keysInUseOrder.append(key)
    }
}

private struct DayTimelinePresentationCache {
    let timelineRows: [TimelineEntryRow]
    let transportSummaryMetrics: [DayTransportSummaryMetric]
    let elevationProfile: DayElevationProfile?
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

    static func remove(dayKey: String) {
        entries.removeValue(forKey: dayKey)
        keysInUseOrder.removeAll { $0 == dayKey }
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

struct DayTransportSummaryValue: Equatable {
    var duration: TimeInterval = 0
    var distanceMeters: CLLocationDistance = 0

    static let zero = DayTransportSummaryValue()
}

enum DayTransportSummaryCalculator {
    static func aggregate(_ moves: [MoveSegment]) -> [DayTransportBucket: DayTransportSummaryValue] {
        var valuesByBucket: [DayTransportBucket: DayTransportSummaryValue] = [:]

        for move in moves {
            guard let bucket = DayTransportBucket(move.transportMode) else { continue }
            var value = valuesByBucket[bucket, default: .zero]
            value.duration += max(move.timelineDuration, 0)
            value.distanceMeters += max(move.distanceMeters, 0)
            valuesByBucket[bucket] = value
        }

        return valuesByBucket
    }
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
    let rawLocationFixes: [RawLocationFixMarker]
    let latestSampleCoordinate: CLLocationCoordinate2D?
    let routeRefreshKey: String
    let placeRefreshKey: String
    let latestSampleKey: String
}

private struct RawLocationFixMarker: Identifiable {
    let id: String
    let moveID: UUID?
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let horizontalAccuracy: CLLocationAccuracy
    let source: LocationSampleSource

    init(_ sample: LocationSample) {
        id = sample.dedupeKey
        moveID = sample.moveSegment?.id
        coordinate = sample.coordinate
        timestamp = sample.timestamp
        horizontalAccuracy = sample.horizontalAccuracy
        source = sample.source
    }

    var description: String {
        let accuracy = horizontalAccuracy.isFinite && horizontalAccuracy >= 0
            ? "±\(Int(horizontalAccuracy.rounded())) m"
            : "accuracy unavailable"
        return "\(source.displayName), \(timestamp.formatted(date: .abbreviated, time: .standard)), \(accuracy)"
    }
}

@MainActor
private enum DayMapPresentationCacheStore {
    private static var entries: [String: DayMapPresentationCache] = [:]
    private static var keysInUseOrder: [String] = []
    private static let maximumEntryCount = 12

    static func value(for key: String, rawMode: Bool = false) -> DayMapPresentationCache? {
        let cacheKey = key + (rawMode ? "|raw" : "|reconstructed")
        guard let entry = entries[cacheKey] else { return nil }
        markRecentlyUsed(cacheKey)
        return entry
    }

    static func store(_ entry: DayMapPresentationCache, for key: String, rawMode: Bool = false) {
        let cacheKey = key + (rawMode ? "|raw" : "|reconstructed")
        entries[cacheKey] = entry
        markRecentlyUsed(cacheKey)
        while keysInUseOrder.count > maximumEntryCount {
            let oldest = keysInUseOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    static func removeAll() {
        entries.removeAll(keepingCapacity: true)
        keysInUseOrder.removeAll(keepingCapacity: true)
    }

    static func remove(dayKey: String) {
        entries = entries.filter { !$0.key.hasPrefix("\(dayKey)|") }
        keysInUseOrder.removeAll { $0.hasPrefix("\(dayKey)|") }
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
    static func invalidate(dayKey: String?) {
        guard let dayKey else {
            invalidateAll()
            return
        }
        DayPresentationSourceCache.remove(dayKey: dayKey)
        DayTimelinePresentationCacheStore.remove(dayKey: dayKey)
        DayMapPresentationCacheStore.remove(dayKey: dayKey)
        // Snapshot keys include the day but are opaque hashes, so clear this small memory cache.
        DayMapSnapshotCache.removeAll()
    }

    static func invalidateAll() {
        DayPresentationSourceCache.removeAll()
        DayTimelinePresentationCacheStore.removeAll()
        DayMapPresentationCacheStore.removeAll()
        DayMapSnapshotCache.removeAll()
    }
}

private struct TimelineFullScreenMapButton: View {
    private static let animation = Animation.spring(response: 0.42, dampingFraction: 0.86)

    let isFullScreen: Bool
    let action: () -> Void

    init(isFullScreen: Binding<Bool>) {
        self.isFullScreen = isFullScreen.wrappedValue
        self.action = {
            withAnimation(Self.animation) {
                isFullScreen.wrappedValue.toggle()
            }
        }
    }

    init(isFullScreen: Bool, action: @escaping () -> Void) {
        self.isFullScreen = isFullScreen
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .frostedCircle(enabled: true)
        .accessibilityLabel(isFullScreen ? "Shrink map" : "Expand map")
        .help(isFullScreen ? "Shrink map" : "Expand map")
    }
}

struct DayMapStrip: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MapMarkerDisplaySettings.showsBigMarkersKey) private var showsBigMarkers = false
    @AppStorage(TrackingRouteDisplayMode.storageKey) private var routeDisplayMode: TrackingRouteDisplayMode = .reconstructed
    let dayTimeline: DayTimeline
    let isActive: Bool
    @Binding var selection: TimelineMapSelection?
    let fillsAvailableSpace: Bool
    let usesHeroStyle: Bool
    private let externalFullScreenMapState: Binding<Bool>?
    static let collapsedMapHeight: CGFloat = 180
    private static let collapsedMapCornerRadius: CGFloat = 14
    private static let fullScreenMapAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)
    private static let expandedMapVerticalMargin: CGFloat = 150

    @State private var camera: MapCameraPosition
    @State private var mapRegion: MKCoordinateRegion
    @State private var historicalRoutes: [RenderedRoute]
    @State private var presentationCache: DayMapPresentationCache
    @State private var presentationGeneration = 0
    @State private var localIsShowingFullScreenMap = false
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
        guard RawLocationFixPresentation.drawsConnectingGeometry(in: routeDisplayMode) else {
            return presentationCache.rawLocationFixes.map(\.coordinate)
        }
        return historicalRoutes.flatMap { $0.coordinates }
    }

    private var cameraRefreshKey: String {
        let liveKey = liveRouteSnapshot?.id ?? "none"
        return [presentationCache.routeRefreshKey, presentationCache.placeRefreshKey, liveKey, presentationCache.latestSampleKey, routeDisplayMode.rawValue].joined(separator: "|")
    }

    private var presentationRefreshKey: String {
        "\(dayTimeline.dayKey)|\(presentationGeneration)"
    }

    init(
        dayTimeline: DayTimeline,
        isActive: Bool,
        selection: Binding<TimelineMapSelection?> = .constant(nil),
        fillsAvailableSpace: Bool = false,
        usesHeroStyle: Bool = false,
        fullScreenMapState: Binding<Bool>? = nil
    ) {
        self.dayTimeline = dayTimeline
        self.isActive = isActive
        _selection = selection
        self.fillsAvailableSpace = fillsAvailableSpace
        self.usesHeroStyle = usesHeroStyle
        self.externalFullScreenMapState = fullScreenMapState
        let initialPresentation: DayMapPresentationCache
        let rawMode = UserDefaults.standard.string(forKey: TrackingRouteDisplayMode.storageKey) == TrackingRouteDisplayMode.rawOSLocationFixes.rawValue
        if let cached = DayMapPresentationCacheStore.value(for: dayTimeline.dayKey, rawMode: rawMode) {
            initialPresentation = cached
        } else {
            // Do not fetch SwiftData while SwiftUI constructs the first page.
            // The selected-day task below fills the cache after the first frame.
            initialPresentation = Self.initialPresentationCache(coordinate: nil)
        }
        let initialMode = UserDefaults.standard.string(forKey: TrackingRouteDisplayMode.storageKey)
            .flatMap(TrackingRouteDisplayMode.init(rawValue:)) ?? .reconstructed
        let initialRegion = Self.region(for: initialPresentation, mode: initialMode)
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
            .clipShape(
                RoundedRectangle(
                    cornerRadius: usesHeroStyle ? 0 : Self.collapsedMapCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                if !usesHeroStyle {
                    RoundedRectangle(cornerRadius: Self.collapsedMapCornerRadius, style: .continuous)
                        .stroke(MovesPalette.border.opacity(0.8), lineWidth: 1)
                }
            }
            .overlay(alignment: isShowingFullScreenMap ? .topTrailing : .bottomTrailing) {
                if externalFullScreenMapState == nil {
                    TimelineFullScreenMapButton(isFullScreen: fullScreenMapState)
                        .padding(isShowingFullScreenMap ? 18 : 10)
                }
            }
            .shadow(color: .black.opacity(isShowingFullScreenMap ? 0.12 : 0), radius: 18, x: 0, y: 8)
            .animation(Self.fullScreenMapAnimation, value: isShowingFullScreenMap)
            .fullScreenCover(isPresented: fullScreenMapPresentationBinding) {
                fullScreenMapView
            }
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
                let cachedPresentation = DayMapPresentationCacheStore.value(
                    for: dayTimeline.dayKey,
                    rawMode: routeDisplayMode == .rawOSLocationFixes
                )
                    ?? Self.initialPresentationCache(coordinate: nil)
                applyPresentation(cachedPresentation)
                presentationGeneration = 0
            }
            .onChange(of: routeDisplayMode) { _, _ in
                presentationGeneration &+= 1
                DayPresentationSourceCache.removeAll()
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
            .task {
                for await notification in NotificationCenter.default.notifications(
                    named: .movesMoveDataDidChange
                ) {
                    guard !Task.isCancelled else { return }
                    presentationGeneration &+= 1
                    TimelinePresentationCacheInvalidator.invalidate(
                        dayKey: notification.userInfo?[TimelineMutationNotifier.dayKeyUserInfoKey] as? String
                    )
                }
            }
            .task(id: "presentation|\(presentationRefreshKey)") {
                guard !Task.isCancelled else { return }
                MovesStartupInstrumentation.event("selectedDayMapPresentationStart")
                let rawMode = routeDisplayMode == .rawOSLocationFixes
                if let cached = DayMapPresentationCacheStore.value(for: dayTimeline.dayKey, rawMode: rawMode) {
                    applyPresentation(cached)
                    MovesStartupInstrumentation.event("selectedDayMapPresentationEnd")
                    return
                }
                let state = MovesStartupInstrumentation.signposter.beginInterval("selectedDayMapPresentationFetchAndBuild")
                let source = DayPresentationSourceCache.source(
                    for: dayTimeline,
                    generation: presentationGeneration,
                    loadAll: rawMode
                )
                let cache = Self.makePresentationCache(
                    for: dayTimeline,
                    source: source,
                    generation: presentationGeneration,
                    mode: routeDisplayMode
                )
                DayMapPresentationCacheStore.store(
                    cache,
                    for: dayTimeline.dayKey,
                    rawMode: rawMode
                )
                MovesStartupInstrumentation.signposter.endInterval("selectedDayMapPresentationFetchAndBuild", state)
                applyPresentation(cache)
                MovesStartupInstrumentation.event("selectedDayMapPresentationEnd")
            }
            .task(id: "route-matching|\(presentationRefreshKey)|\(isActive ? 1 : 0)|\(routeDisplayMode.rawValue)") {
                guard isActive, RawLocationFixPresentation.schedulesRouteMatching(in: routeDisplayMode), !Task.isCancelled else { return }
                let source = DayPresentationSourceCache.source(
                    for: dayTimeline,
                    generation: presentationGeneration
                )
                captureManager.prepareRouteMatches(
                    for: Self.displayedMoves(from: source)
                )
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

    private var fullScreenMapPresentationBinding: Binding<Bool> {
        Binding(
            get: { fillsAvailableSpace && isShowingFullScreenMap },
            set: { isPresented in
                if !isPresented {
                    fullScreenMapState.wrappedValue = false
                }
            }
        )
    }

    private var fullScreenMapState: Binding<Bool> {
        externalFullScreenMapState ?? $localIsShowingFullScreenMap
    }

    private var isShowingFullScreenMap: Bool {
        fullScreenMapState.wrappedValue
    }

    private var fullScreenMapView: some View {
        ZStack(alignment: .topTrailing) {
            mapView
                .ignoresSafeArea()

            TimelineFullScreenMapButton(isFullScreen: true, action: {
                fullScreenMapState.wrappedValue = false
            })
                .padding(18)
        }
        .background(Color.black)
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
        if routeDisplayMode == .rawOSLocationFixes {
            ForEach(presentationCache.rawLocationFixes) { fix in
                Annotation(fix.description, coordinate: fix.coordinate, anchor: .center) {
                    Button {
                        selection = .sample(fix.id)
                    } label: {
                        Circle()
                            .fill(fix.source == .routeTracking || fix.source == .watchRouteTracking
                                  ? MovesPalette.routeTracking
                                  : MovesPalette.start)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.25), radius: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Location fix: \(fix.description)")
                }
            }

            if let liveRouteSnapshot {
                ForEach(Array(liveRouteSnapshot.coordinates.enumerated()), id: \.offset) { index, coordinate in
                    Annotation("Live OS fix \(index + 1)", coordinate: coordinate, anchor: .center) {
                        Circle()
                            .fill(MovesPalette.routeTracking)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .accessibilityLabel("Live Real Route Tracking location fix \(index + 1)")
                    }
                }
            }
        } else {
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

            ForEach(Array(route.inferredCoordinateSegments.enumerated()), id: \.offset) { _, coordinates in
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        route.shadowTint.opacity(dimsForOtherSelection ? 0.18 : 0.7),
                        style: StrokeStyle(lineWidth: route.shadowLineWidth, dash: [8, 6])
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

        if routeDisplayMode == .reconstructed,
           placeMarkers.isEmpty,
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
            liveCoordinates: liveRouteSnapshot?.coordinates ?? [],
            mode: routeDisplayMode
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
        liveCoordinates: [CLLocationCoordinate2D] = [],
        mode: TrackingRouteDisplayMode = .reconstructed
    ) -> MKCoordinateRegion {
        let displayCoordinates = RawLocationFixPresentation.drawsConnectingGeometry(in: mode)
            ? presentation.routes.flatMap(\.coordinates)
            : presentation.rawLocationFixes.map(\.coordinate)
        let coordinates = displayCoordinates
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
            if routeDisplayMode == .rawOSLocationFixes {
                coordinates = presentationCache.rawLocationFixes
                    .filter { $0.moveID == id }
                    .map(\.coordinate)
            } else {
                coordinates = historicalRoutes.first(where: { $0.id == id.uuidString })?.coordinates ?? []
            }
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
            rawLocationFixes: [],
            latestSampleCoordinate: coordinate,
            routeRefreshKey: "initial",
            placeRefreshKey: "initial",
            latestSampleKey: "initial"
        )
    }

    private static func makePresentationCache(
        for dayTimeline: DayTimeline,
        source: DayPresentationSource,
        generation: Int,
        mode: TrackingRouteDisplayMode
    ) -> DayMapPresentationCache {
        let displayedMoves = displayedMoves(from: source)
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

        let routes = RawLocationFixPresentation.drawsConnectingGeometry(in: mode)
            ? renderedRoutes(source: source, displayedMoves: displayedMoves)
            : []
        let rawLocationFixes = RawLocationFixPresentation.orderedOSFixes(from: source.visibleSamples)
            .map(RawLocationFixMarker.init)

        return DayMapPresentationCache(
            placeMarkers: placeMarkers,
            routes: routes,
            rawLocationFixes: rawLocationFixes,
            latestSampleCoordinate: latestSample?.coordinate,
            routeRefreshKey: "\(dayTimeline.dayKey)|\(generation)",
            placeRefreshKey: placeRefreshKey,
            latestSampleKey: latestSampleKey
        )
    }

    private static func displayedMoves(from source: DayPresentationSource) -> [MoveSegment] {
        TimelinePresentationLimits.selection(
            from: source.visibleMoves,
            maxImportedMoves: TimelinePresentationLimits.maxMapImportedMoves,
            maxTotalMoves: TimelinePresentationLimits.maxMapMoves,
            importedMoveIDs: source.importedMoveIDs
        ).moves
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
    let presentation: TimelineRowPresentation
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(presentation.clockText)
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
                        .fill(presentation.iconTint.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: presentation.iconName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(presentation.iconTint)
                    if presentation.showsHealthSourceBadge {
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
                Text(presentation.titleText)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.92))

                Text(presentation.subtitleText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.72))

                if let tertiary = presentation.tertiaryText {
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

private struct DayElevationProfileView: View {
    let dayStart: Date
    let profile: DayElevationProfile

    private var dayEnd: Date {
        Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Elevation", systemImage: "mountain.2.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                Spacer(minLength: 8)

                Text("High \(elevationText(profile.maximumElevationMeters))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(profile.segments) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Elevation", point.elevationMeters)
                        )
                        .foregroundStyle(MovesPalette.routeTracking)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    }

                    if segment.points.count == 1, let point = segment.points.first {
                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Elevation", point.elevationMeters)
                        )
                        .foregroundStyle(MovesPalette.routeTracking)
                    }
                }
            }
            .chartXScale(domain: dayStart...dayEnd)
            .chartYScale(domain: profile.yDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(MovesPalette.rail)
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(MovesPalette.rail)
                    AxisValueLabel {
                        if let meters = value.as(Double.self) {
                            Text(elevationText(meters))
                        }
                    }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("24-hour elevation profile")
            .accessibilityValue(
                "Highest elevation \(elevationText(profile.maximumElevationMeters))"
            )
        }
    }

    private func elevationText(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

enum TimelineTintKind: Equatable {
    case place
    case move
    case routeTracking
    case healthRoute
    case start

    var color: Color {
        switch self {
        case .place: return MovesPalette.place
        case .move: return MovesPalette.move
        case .routeTracking: return MovesPalette.routeTracking
        case .healthRoute: return MovesPalette.healthRoute
        case .start: return MovesPalette.start
        }
    }
}

struct TimelineRowPresentation: Identifiable, Equatable {
    let id: String
    let clockText: String
    let titleText: String
    let subtitleText: String
    let tertiaryText: String?
    let iconName: String
    let iconTintKind: TimelineTintKind
    let showsHealthSourceBadge: Bool

    var iconTint: Color { iconTintKind.color }

    init(entry: TimelineEntry, moveSources: TimelineMoveSourceFlags = []) {
        id = entry.id

        switch entry {
        case .place(let place):
            clockText = Self.timeString(from: place.arrivalDate)
            titleText = place.displayTitle
            if let departure = place.departureDate {
                subtitleText = "Stayed \(DurationFormatter.text(for: departure.timeIntervalSince(place.arrivalDate)))"
            } else {
                subtitleText = "In progress"
            }
            tertiaryText = nil
            iconName = "mappin.circle.fill"
            iconTintKind = .place
            showsHealthSourceBadge = false

        case .move(let segment):
            let timelineStartDate = segment.timelineStartDate
            clockText = Self.timeString(from: timelineStartDate)
            let start = segment.startPlace?.displayTitle ?? "Unknown start"
            let end = segment.endPlace?.displayTitle ?? "Unknown destination"
            titleText = "\(start) to \(end)"

            let duration = DurationFormatter.text(for: segment.timelineDuration)
            let distance = Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            var subtitleDetails = [segment.transportMode.title, duration, distance]
            if moveSources.contains(.healthWorkout) {
                subtitleDetails.append("Apple Health")
            }
            subtitleText = subtitleDetails.joined(separator: "   ")

            var tertiaryDetails: [String] = []
            if let stepCount = segment.stepCount, stepCount > 0 {
                tertiaryDetails.append("\(stepCount.formatted(.number)) steps")
            }
            if DurationFormatter.showsNonzeroMinutes(for: segment.timelineDuration) {
                let kilometersPerHour = max(segment.distanceMeters, 0) / segment.timelineDuration * 3.6
                tertiaryDetails.append(MovesMeasurementFormatter.speed(kilometersPerHour: kilometersPerHour))
            }
            tertiaryText = tertiaryDetails.isEmpty ? nil : tertiaryDetails.joined(separator: "   ")
            iconName = segment.transportMode.symbolName
            showsHealthSourceBadge = moveSources.contains(.healthWorkout)
            if moveSources.contains(.healthWorkout) {
                iconTintKind = .healthRoute
            } else if moveSources.contains(.routeTracking) {
                iconTintKind = .routeTracking
            } else {
                iconTintKind = .move
            }

        case .liveRoute(let snapshot):
            clockText = Self.timeString(from: snapshot.latestDate)
            titleText = "Live route tracking"
            let duration = DurationFormatter.text(for: snapshot.duration)
            let distance = Measurement(value: max(snapshot.distanceMeters, 0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            subtitleText = snapshot.sampleCount == 0
                ? "Waiting for the first live GPS fix"
                : "\(snapshot.sampleCount) live fixes   \(duration)   \(distance)"
            tertiaryText = snapshot.sampleCount == 0
                ? "Tracking will start as soon as GPS provides the first fix."
                : "Last update \(snapshot.latestDate.formatted(date: .omitted, time: .shortened))"
            iconName = "location.fill.viewfinder"
            iconTintKind = .routeTracking
            showsHealthSourceBadge = false

        case .start(let place, let timestamp):
            clockText = Self.timeString(from: timestamp)
            titleText = "Start at \(place.displayTitle)"
            subtitleText = "Carried over from previous day"
            tertiaryText = nil
            iconName = "sunrise.fill"
            iconTintKind = .start
            showsHealthSourceBadge = false

        case .sample(let location, let sampleCount, let resolvedName):
            clockText = Self.timeString(from: location.timestamp)
            if let resolvedName,
               !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                titleText = resolvedName
            } else {
                titleText = Self.coordinateString(latitude: location.latitude, longitude: location.longitude)
            }
            subtitleText = "In progress"
            tertiaryText = sampleCount == 1
                ? "1 location sample captured"
                : "\(sampleCount) location samples captured"
            iconName = "mappin.circle.fill"
            iconTintKind = .place
            showsHealthSourceBadge = false
        }
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

struct TimelineEntryRow: Identifiable {
    let entry: TimelineEntry
    let presentation: TimelineRowPresentation

    init(entry: TimelineEntry, presentation: TimelineRowPresentation? = nil) {
        self.entry = entry
        self.presentation = presentation ?? TimelineRowPresentation(entry: entry)
    }

    var id: String { presentation.id }
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

#if canImport(UIKit)
@MainActor
final class TimelineScreenshotServiceCoordinator: NSObject, ObservableObject, UIScreenshotServiceDelegate {
    private var currentDayTimeline: DayTimeline?
    private weak var attachedScene: UIWindowScene?
    private weak var attachedScreenshotService: UIScreenshotService?

    func update(dayTimeline: DayTimeline?) {
        currentDayTimeline = dayTimeline
    }

    func attach(to scene: UIWindowScene) {
        guard let screenshotService = scene.screenshotService else { return }

        if attachedScreenshotService !== screenshotService {
            attachedScreenshotService?.delegate = nil
            attachedScreenshotService = screenshotService
        }

        attachedScene = scene
        screenshotService.delegate = self
    }

    func detach() {
        attachedScreenshotService?.delegate = nil
        attachedScreenshotService = nil
        attachedScene = nil
        currentDayTimeline = nil
    }

    func screenshotService(
        _ screenshotService: UIScreenshotService,
        generatePDFRepresentationWithCompletion completionHandler: @escaping (Data?, Int, CGRect) -> Void
    ) {
        guard let dayTimeline = currentDayTimeline else {
            completionHandler(nil, 0, .zero)
            return
        }

        let result = TimelineScreenshotPDFRenderer.render(
            dayTimeline: dayTimeline,
            windowScene: screenshotService.windowScene ?? attachedScene
        )
        completionHandler(result.data, result.currentPageIndex, result.visibleRect)
    }
}

struct TimelineScreenshotServiceHost: UIViewRepresentable {
    let coordinator: TimelineScreenshotServiceCoordinator
    let dayTimeline: DayTimeline?

    func makeUIView(context: Context) -> TimelineScreenshotServiceSceneView {
        let view = TimelineScreenshotServiceSceneView()
        view.coordinator = coordinator
        view.update(dayTimeline: dayTimeline)
        return view
    }

    func updateUIView(_ uiView: TimelineScreenshotServiceSceneView, context: Context) {
        uiView.coordinator = coordinator
        uiView.update(dayTimeline: dayTimeline)
    }

    static func dismantleUIView(_ uiView: TimelineScreenshotServiceSceneView, coordinator: ()) {
        uiView.coordinator?.detach()
    }
}

final class TimelineScreenshotServiceSceneView: UIView {
    weak var coordinator: TimelineScreenshotServiceCoordinator?
    private var currentDayTimeline: DayTimeline?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfPossible()
    }

    func update(dayTimeline: DayTimeline?) {
        currentDayTimeline = dayTimeline
        coordinator?.update(dayTimeline: dayTimeline)
        attachIfPossible()
    }

    private func attachIfPossible() {
        guard let scene = window?.windowScene else { return }
        coordinator?.update(dayTimeline: currentDayTimeline)
        coordinator?.attach(to: scene)
    }
}

private struct TimelineScreenshotPDFSnapshot {
    let dayStart: Date
    let entries: [TimelineEntryRow]
    let sampleCount: Int
}

private struct TimelineScreenshotPDFDocument: View {
    let snapshot: TimelineScreenshotPDFSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Moves Timeline")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                Text(snapshot.dayStart, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Divider()

            if snapshot.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No segments for this day yet.")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    if snapshot.sampleCount > 0 {
                        Text("\(snapshot.sampleCount) location sample\(snapshot.sampleCount == 1 ? "" : "s") captured.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.entries.indices, id: \.self) { index in
                        let row = snapshot.entries[index]
                        StorylineRow(
                            presentation: row.presentation,
                            isFirst: index == 0,
                            isLast: index == snapshot.entries.count - 1
                        )
                        .fixedSize(horizontal: false, vertical: true)

                        if index < snapshot.entries.count - 1 {
                            Divider()
                                .padding(.leading, 82)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .environment(\.colorScheme, .light)
    }
}

@MainActor
private enum TimelineScreenshotPDFRenderer {
    struct Result {
        let data: Data?
        let currentPageIndex: Int
        let visibleRect: CGRect
    }

    static func render(dayTimeline: DayTimeline, windowScene: UIWindowScene?) -> Result {
        let snapshot = makeSnapshot(for: dayTimeline)
        let windowSize = windowScene?.windows.first(where: { $0.isKeyWindow })?.bounds.size
            ?? windowScene?.windows.first?.bounds.size
            ?? CGSize(width: 390, height: 844)
        let pageWidth = max(windowSize.width, 320)
        let pageHeight = max(windowSize.height, 480)
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let hostingController = UIHostingController(
            rootView: TimelineScreenshotPDFDocument(snapshot: snapshot)
        )
        hostingController.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: 1)
        hostingController.view.backgroundColor = .systemBackground
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let fittingSize = hostingController.sizeThatFits(
            in: CGSize(width: pageWidth, height: .greatestFiniteMagnitude)
        )
        let contentHeight = max(fittingSize.height, pageHeight)
        hostingController.view.frame = CGRect(
            x: 0,
            y: 0,
            width: pageWidth,
            height: contentHeight
        )
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let pageCount = max(Int(ceil(contentHeight / pageHeight)), 1)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = try? renderer.pdfData { context in
            for pageIndex in 0..<pageCount {
                context.beginPage()
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: -CGFloat(pageIndex) * pageHeight)
                hostingController.view.layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
            }
        }

        return Result(
            data: data,
            currentPageIndex: 0,
            visibleRect: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        )
    }

    private static func makeSnapshot(for dayTimeline: DayTimeline) -> TimelineScreenshotPDFSnapshot {
        let source = DayPresentationSource(dayTimeline: dayTimeline, loadAll: true)
        let incomingPlaceIDs = Set(source.visibleMoves.compactMap { $0.endPlace?.id })
        let outgoingPlaceIDs = Set(source.visibleMoves.compactMap { $0.startPlace?.id })
        let places = source.visiblePlaces
            .filter { place in
                hasExplicitUserLabel(place)
                    || !(place.departureDate != nil
                        && incomingPlaceIDs.contains(place.id)
                        && outgoingPlaceIDs.contains(place.id)
                        && place.departureDate!.timeIntervalSince(place.arrivalDate) < 5 * 60)
            }
            .map(TimelineEntry.place)
        let moves = source.visibleMoves.map(TimelineEntry.move)
        var entries = (places + moves).sorted { $0.startDate < $1.startDate }

        if let firstMove = source.visibleMoves.min(by: { $0.timelineStartDate < $1.timelineStartDate }),
           let startPlace = firstMove.startPlace,
           !source.visiblePlaces.contains(where: { $0.id == startPlace.id }) {
            let startEntry = TimelineEntry.start(
                place: startPlace,
                timestamp: firstMove.timelineStartDate.addingTimeInterval(-1)
            )
            let firstMoveIndex = entries.firstIndex { entry in
                if case .move(let move) = entry { return move.id == firstMove.id }
                return false
            }
            entries.insert(startEntry, at: firstMoveIndex ?? 0)
        }

        if entries.isEmpty, let latestSample = source.visibleSamples.max(by: { $0.timestamp < $1.timestamp }) {
            entries.append(
                .sample(
                    location: latestSample,
                    sampleCount: source.totalSampleCount,
                    resolvedName: nil
                )
            )
        } else if entries.isEmpty, let carriedOverPlace = source.carriedOverPlace {
            entries.append(.start(place: carriedOverPlace, timestamp: dayTimeline.dayStart))
        }

        let rows = entries.map { entry in
            let sources: TimelineMoveSourceFlags
            if case .move(let move) = entry {
                sources = source.sourcesByMoveID[move.id] ?? []
            } else {
                sources = []
            }
            return TimelineEntryRow(
                entry: entry,
                presentation: TimelineRowPresentation(entry: entry, moveSources: sources)
            )
        }

        return TimelineScreenshotPDFSnapshot(
            dayStart: dayTimeline.dayStart,
            entries: rows,
            sampleCount: source.totalSampleCount
        )
    }

    private static func hasExplicitUserLabel(_ place: VisitPlace) -> Bool {
        !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
#endif
