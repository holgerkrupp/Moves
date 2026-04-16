import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers
import UIKit

private enum MovesPalette {
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

private enum TrackingPromptAction {
    case requestAuthorization
    case openSettings
}

private struct TrackingPermissionPrompt {
    let title: String
    let message: String
    let buttonTitle: String?
    let action: TrackingPromptAction?
}

private enum TrackingStatusBannerContext {
    case timeline
    case settings
}

private struct TrackingStatusBannerData {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    let buttonTitle: String?
    let buttonRole: ButtonRole?

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        buttonTitle: String? = nil,
        buttonRole: ButtonRole? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.buttonTitle = buttonTitle
        self.buttonRole = buttonRole
    }
}

private struct TrackingStatusBanner: View {
    let data: TrackingStatusBannerData
    let buttonAction: (() -> Void)?

    init(
        data: TrackingStatusBannerData,
        buttonAction: (() -> Void)? = nil
    ) {
        self.data = data
        self.buttonAction = buttonAction
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: data.systemImage)
                .foregroundStyle(data.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Text(data.message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let buttonTitle = data.buttonTitle,
               let buttonAction {
                Button(buttonTitle, role: data.buttonRole) {
                    buttonAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

@MainActor
private func trackingStatusBannerData(
    for captureManager: MovesLocationCaptureManager,
    context: TrackingStatusBannerContext
) -> TrackingStatusBannerData? {
    if captureManager.isDemoMode {
        return nil
    }

    if let lastErrorMessage = captureManager.lastErrorMessage {
        return TrackingStatusBannerData(
            title: "Location tracking error",
            message: lastErrorMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }

    if let endsAt = captureManager.temporaryRouteTrackingEndsAt,
       endsAt > .now {
        switch captureManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return TrackingStatusBannerData(
                title: "Real route tracking on",
                message: temporaryRouteTrackingBannerMessage(
                    for: captureManager,
                    context: context
                ),
                systemImage: "location.fill.viewfinder",
                tint: MovesPalette.routeTracking,
                buttonTitle: context == .timeline ? "Turn off now" : nil,
                buttonRole: context == .timeline ? .destructive : nil
            )
        case .notDetermined, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    guard context == .settings else {
        return nil
    }

    switch captureManager.authorizationStatus {
    case .authorizedAlways:
        let message: String
        if let lastCaptureAt = captureManager.lastCaptureAt {
            message = "Last location received at \(lastCaptureAt.formatted(date: .omitted, time: .shortened))."
        } else {
            message = "Background tracking is enabled and waiting for the first location fix."
        }

        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: message,
            systemImage: "location.fill",
            tint: MovesPalette.place
        )
    case .authorizedWhenInUse:
        let message: String
        if let lastCaptureAt = captureManager.lastCaptureAt {
            message = "Last location received at \(lastCaptureAt.formatted(date: .omitted, time: .shortened))."
        } else {
            message = "Moves can read location while open. Grant Always to keep recording in the background."
        }

        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: message,
            systemImage: "location.fill",
            tint: MovesPalette.start
        )
    case .notDetermined:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Open Moves to allow location access and start recording.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .denied:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Enable location in Settings if you want Moves to record visits and movement.",
            systemImage: "location.slash",
            tint: .secondary
        )
    case .restricted:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "This device does not allow location access for Moves.",
            systemImage: "lock.fill",
            tint: .secondary
        )
    @unknown default:
        return TrackingStatusBannerData(
            title: "Unknown location state",
            message: "Moves could not determine the current location permission state.",
            systemImage: "questionmark.circle",
            tint: .secondary
        )
    }
}

@MainActor
private func temporaryRouteTrackingBannerMessage(
    for captureManager: MovesLocationCaptureManager,
    context: TrackingStatusBannerContext
) -> String {
    let durationText = captureManager.temporaryRouteTrackingDuration.availabilityText
    let autoStopText = temporaryRouteTrackingAutoStopText(for: captureManager)

    switch captureManager.authorizationStatus {
    case .authorizedAlways:
        switch context {
        case .timeline:
            return "Frequent GPS updates are enabled \(durationText). Battery use is higher.\(autoStopText)"
        case .settings:
            return "Frequent GPS updates are enabled \(durationText). Battery use is higher and Moves will switch back automatically.\(autoStopText)"
        }
    case .authorizedWhenInUse:
        switch context {
        case .timeline:
            return "Frequent GPS updates are enabled \(durationText) while Moves is open. Battery use is higher. Always is needed for background tracking.\(autoStopText)"
        case .settings:
            return "Frequent GPS updates are enabled \(durationText) while Moves is open. Battery use is higher. Always is needed for background tracking.\(autoStopText)"
        }
    case .notDetermined, .denied, .restricted:
        switch context {
        case .timeline:
            return "Frequent GPS updates are ready once location access is allowed."
        case .settings:
            return "Frequent GPS updates are ready once location access is allowed."
        }
    @unknown default:
        return "Frequent GPS updates are enabled."
    }
}

@MainActor
private func temporaryRouteTrackingAutoStopText(
    for captureManager: MovesLocationCaptureManager
) -> String {
    let stopAtBatteryFifty = captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery
    let stopInLowPowerMode = captureManager.temporaryRouteTrackingStopsInLowPowerMode

    switch (stopAtBatteryFifty, stopInLowPowerMode) {
    case (true, true):
        return " It will also stop if battery reaches 50% or Low Power Mode turns on."
    case (true, false):
        return " It will also stop if battery reaches 50%."
    case (false, true):
        return " It will also stop if Low Power Mode turns on."
    case (false, false):
        return ""
    }
}

private struct LiveRouteTrackingSnapshot {
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

private struct RenderedRoute: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let usesHighAccuracyRouteTracking: Bool

    var tint: Color {
        usesHighAccuracyRouteTracking ? MovesPalette.routeTracking : MovesPalette.move
    }

    var lineWidth: CGFloat {
        usesHighAccuracyRouteTracking ? 5 : 4
    }
}

@MainActor
private func liveRouteTrackingSnapshot(
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

private func liveRouteSessionSamples(
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

private func liveRouteAnchorCoordinate(
    for dayTimeline: DayTimeline,
    startDate: Date
) -> CLLocationCoordinate2D? {
    let sortedPlaces = dayTimeline.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
    if let anchorPlace = sortedPlaces.last(where: { $0.arrivalDate <= startDate }) {
        return anchorPlace.coordinate
    }
    return sortedPlaces.last?.coordinate
}

private func routeDistance(for coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    guard coordinates.count > 1 else { return 0 }

    return zip(coordinates, coordinates.dropFirst()).reduce(0) { partialResult, pair in
        partialResult + RouteCoordinateOps.distanceMeters(from: pair.0, to: pair.1)
    }
}

struct ContentView: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @Environment(\.openURL) private var openURL

    @Query(sort: \DayTimeline.dayStart, order: .forward)
    private var dayTimelines: [DayTimeline]

    @State private var selectedDayKey = ""
    @State private var selectedPageIndex = 0
    @State private var isShowingSettings = false

    private var selectedDay: DayTimeline? {
        guard dayTimelines.indices.contains(selectedPageIndex) else { return nil }
        return dayTimelines[selectedPageIndex]
    }

    private var canGoOlder: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex > 0
    }

    private var canGoNewer: Bool {
        dayTimelines.indices.contains(selectedPageIndex) && selectedPageIndex < dayTimelines.count - 1
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background

                VStack(spacing: 12) {
                    if let trackingPermissionPrompt {
                        trackingPermissionBanner(trackingPermissionPrompt)
                    }

                    if let bannerData = trackingStatusBannerData(
                        for: captureManager,
                        context: .timeline
                    ) {
                        TrackingStatusBanner(
                            data: bannerData,
                            buttonAction: {
                                captureManager.disableTemporaryRouteTracking()
                            }
                        )
                    }

                    if dayTimelines.isEmpty {
                        emptyState
                    } else {
                        dayHeader

                        TabView(selection: $selectedPageIndex) {
                            ForEach(Array(dayTimelines.enumerated()), id: \.element.dayKey) { index, day in
                                DayTimelinePage(dayKey: day.dayKey)
                                    .tag(index)
                                    
                            }
                        }
                        .ignoresSafeArea()
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                
            }
            
            .navigationTitle("Moves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await captureManager.refreshHistoricalBackfill() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh timeline")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            MovesSettingsView(
                dayTimelines: dayTimelines,
                selectedDayKey: selectedDayKey,
                captureManager: captureManager
            )
        }
        .task {
            guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
            await captureManager.start()
        }
        .onAppear {
            syncSelectedDayIfNeeded()
        }
        .onChange(of: dayTimelines.map(\.dayKey)) { _, _ in
            syncSelectedDayIfNeeded()
        }
        .onChange(of: selectedPageIndex) { _, newIndex in
            guard dayTimelines.indices.contains(newIndex) else { return }
            selectedDayKey = dayTimelines[newIndex].dayKey
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func trackingPermissionBanner(_ prompt: TrackingPermissionPrompt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "location.circle.fill")
                .foregroundStyle(MovesPalette.start)

            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Text(prompt.message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let buttonTitle = prompt.buttonTitle,
               let action = prompt.action {
                Button(buttonTitle) {
                    performTrackingPromptAction(action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .panelSurface()
    }

    private var dayHeader: some View {
        HStack(spacing: 10) {
            Button {
                selectOlderDay()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoOlder)
            .disabled(!canGoOlder)

            VStack(spacing: 2) {
                if let selectedDay {
                    Text(selectedDay.dayStart, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.92))

                    Text("\(selectedDay.uniqueLocationCount) places   \(selectedDay.moves.count) moves")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                selectNewerDay()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .frostedCircle(enabled: canGoNewer)
            .disabled(!canGoNewer)
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.slash.circle")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)

            Text("No timeline yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Keep Moves running in the background. Visits and movement segments appear as iOS records them.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .panelSurface()
    }

    private var trackingPermissionPrompt: TrackingPermissionPrompt? {
        if captureManager.isDemoMode {
            return nil
        }

        switch captureManager.authorizationStatus {
        case .notDetermined:
            return TrackingPermissionPrompt(
                title: "Enable location tracking",
                message: "Moves needs location access to record your timeline. We will ask for While Using first, then immediately request Always for background tracking.",
                buttonTitle: "Allow Location Access",
                action: .requestAuthorization
            )
        case .authorizedWhenInUse:
            return TrackingPermissionPrompt(
                title: "Allow Always for background tracking",
                message: "We can already read your location while the app is open. Tap below to switch to Always so Moves can keep recording in the background.",
                buttonTitle: "Continue to Always",
                action: .requestAuthorization
            )
        case .denied:
            return TrackingPermissionPrompt(
                title: "Location access is off",
                message: "Moves needs location access to record visits and movement. Open Settings to allow it.",
                buttonTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            return TrackingPermissionPrompt(
                title: "Location access is restricted",
                message: "This device does not allow location access for Moves.",
                buttonTitle: nil,
                action: nil
            )
        case .authorizedAlways:
            return nil
        @unknown default:
            return nil
        }
    }

    private func performTrackingPromptAction(_ action: TrackingPromptAction) {
        switch action {
        case .requestAuthorization:
            captureManager.requestTrackingAuthorization()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }

    private func syncSelectedDayIfNeeded() {
        guard !dayTimelines.isEmpty else {
            selectedPageIndex = 0
            selectedDayKey = ""
            return
        }

        if selectedDayKey.isEmpty {
            selectedPageIndex = dayTimelines.count - 1
            selectedDayKey = dayTimelines[selectedPageIndex].dayKey
            return
        }

        if let selectedIndex = dayTimelines.firstIndex(where: { $0.dayKey == selectedDayKey }) {
            selectedPageIndex = selectedIndex
            return
        }

        if dayTimelines.indices.contains(selectedPageIndex) {
            selectedDayKey = dayTimelines[selectedPageIndex].dayKey
            return
        }

        selectedPageIndex = dayTimelines.count - 1
        selectedDayKey = dayTimelines[selectedPageIndex].dayKey
    }

    private func selectOlderDay() {
        let nextIndex = selectedPageIndex - 1
        guard dayTimelines.indices.contains(nextIndex) else { return }
        selectedPageIndex = nextIndex
    }

    private func selectNewerDay() {
        let nextIndex = selectedPageIndex + 1
        guard dayTimelines.indices.contains(nextIndex) else { return }
        selectedPageIndex = nextIndex
    }
}

private struct DayTimelinePage: View {
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

private struct DayTimelinePageContent: View {
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

private struct DayTransportSummaryMetric: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let tint: Color
    let duration: TimeInterval
    let distanceMeters: CLLocationDistance
}

private enum DayTransportBucket: String, CaseIterable {
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

private struct DayTransportSummaryView: View {
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

private struct DayMapStrip: View {
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
                RenderedRoute(
                    id: move.id.uuidString,
                    coordinates: MoveRouteGeometry.rawCoordinates(for: move),
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

private struct StorylineRow: View {
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

private enum TimelineEntry: Identifiable {
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

private struct PlaceMapDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var place: VisitPlace

    @State private var camera: MapCameraPosition
    @State private var draftLabel: String

    init(place: VisitPlace) {
        self.place = place
        _draftLabel = State(initialValue: place.userLabel ?? place.autoLabel ?? "")
        _camera = State(initialValue: .region(
            MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        ))
    }

    var body: some View {
        Map(position: $camera) {
            Marker(place.displayTitle, coordinate: place.coordinate)
                .tint(MovesPalette.place)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .navigationTitle("Place")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(place.displayTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Arrived \(place.arrivalDate, format: .dateTime.hour().minute())")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.75))

                if let autoLabel = place.autoLabel,
                   (place.userLabel?.isEmpty ?? true) {
                    Text("Auto-detected: \(autoLabel)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    TextField("Label (Home, Work...)", text: $draftLabel)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MovesPalette.textFieldBackground.opacity(0.92))
                        )
                        .onSubmit(saveLabel)

                    Button("Save") {
                        saveLabel()
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    QuickLabelButton(label: "Home") {
                        draftLabel = "Home"
                        saveLabel()
                    }
                    QuickLabelButton(label: "Work") {
                        draftLabel = "Work"
                        saveLabel()
                    }
                    QuickLabelButton(label: "Gym") {
                        draftLabel = "Gym"
                        saveLabel()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .panelSurface()
            .padding(12)
        }
    }

    private func saveLabel() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            place.userLabel = nil
        } else {
            place.userLabel = trimmed
            place.autoLabel = nil
        }

        do {
            try modelContext.save()
        } catch {
            print("Failed to save place label: \(error.localizedDescription)")
        }
    }
}

private struct QuickLabelButton: View {
    let label: String
    var action: () -> Void

    var body: some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}

private struct MoveMapDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var segment: MoveSegment

    @State private var camera: MapCameraPosition
    @State private var routeCoordinates: [CLLocationCoordinate2D]

    private var routeRefreshKey: String {
        let start = Int(segment.timelineStartDate.timeIntervalSince1970.rounded())
        let end = Int(segment.endDate.timeIntervalSince1970.rounded())
        let sampleKey = segment.samples.map { sample in
            "\(Int(sample.timestamp.timeIntervalSince1970.rounded()))|\(sample.sourceRawValue)|\(Int((sample.latitude * 10_000).rounded()))|\(Int((sample.longitude * 10_000).rounded()))"
        }
        .joined(separator: ",")

        return "\(segment.id.uuidString)|\(segment.transportMode.rawValue)|\(start)|\(end)|\(sampleKey)"
    }

    init(segment: MoveSegment) {
        self.segment = segment
        let all = MoveRouteGeometry.rawCoordinates(for: segment)

        _camera = State(initialValue: .region(MapRegionFactory.region(for: all)))
        _routeCoordinates = State(initialValue: all)
    }

    var body: some View {
        Map(position: $camera) {
            if let start = segment.startPlace?.coordinate {
                Marker("Start", coordinate: start)
                    .tint(MovesPalette.place)
            }

            if routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(segment.routeDisplayTint, lineWidth: 5)
            }

            if let end = segment.endPlace?.coordinate {
                Marker("End", coordinate: end)
                    .tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .navigationTitle("Move")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Transport mode", selection: transportBucketSelection) {
                    Image(systemName: DayTransportBucket.walking.symbolName)
                        .tag(DayTransportBucket.walking)
                    Image(systemName: DayTransportBucket.cycling.symbolName)
                        .tag(DayTransportBucket.cycling)
                    Image(systemName: DayTransportBucket.automotive.symbolName)
                        .tag(DayTransportBucket.automotive)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 156)
            }
        }
        .task(id: routeRefreshKey) {
            routeCoordinates = await RoadRouteMatcher.matchedCoordinates(for: segment)
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(moveRouteTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(segment.transportMode.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("\(DurationFormatter.text(for: segment.timelineDuration))   \(Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .panelSurface()
            .padding(12)
        }
    }

    private var moveRouteTitle: String {
        let start = segment.startPlace?.displayTitle ?? "Unknown start"
        let end = segment.endPlace?.displayTitle ?? "Unknown destination"
        return "\(start) to \(end)"
    }

    private var transportBucketSelection: Binding<DayTransportBucket> {
        Binding(
            get: { DayTransportBucket(segment.transportMode) ?? .walking },
            set: { newBucket in
                let newMode = newBucket.transportMode
                guard segment.transportMode != newMode else { return }

                let previousMode = segment.transportMode
                segment.transportMode = newMode

                do {
                    try modelContext.save()
                } catch {
                    segment.transportMode = previousMode
                    print("Failed to save move transport mode: \(error.localizedDescription)")
                }
            }
        )
    }
}

private struct PlaceMarker: Identifiable {
    let id: UUID
    let title: String
    let coordinate: CLLocationCoordinate2D
}

private enum DurationFormatter {
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

private enum MapRegionFactory {
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

private enum MoveRouteGeometry {
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

    static func cacheKey(for move: MoveSegment, fallback: [CLLocationCoordinate2D]) -> Int {
        var hasher = Hasher()
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

private extension MoveSegment {
    var routeDisplayTint: Color {
        usesHighAccuracyRouteTracking ? MovesPalette.routeTracking : MovesPalette.move
    }
}

private enum RouteCoordinateOps {
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

@MainActor
private enum RoadRouteMatcher {
    private static var cache: [Int: [CLLocationCoordinate2D]] = [:]

    static func matchedCoordinates(for move: MoveSegment) async -> [CLLocationCoordinate2D] {
        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let cacheKey = MoveRouteGeometry.cacheKey(for: move, fallback: fallback)

        if let cached = cache[cacheKey] {
            return cached
        }

        guard fallback.count > 1, let transportType = mapTransportType(for: move.transportMode) else {
            cache[cacheKey] = fallback
            return fallback
        }

        let anchors = RouteCoordinateOps.sampleAnchors(
            from: fallback,
            maximumCount: anchorLimit(for: move.transportMode)
        )
        guard anchors.count > 1 else {
            cache[cacheKey] = fallback
            return fallback
        }

        var matchedCoordinates: [CLLocationCoordinate2D] = []
        var matchedSegmentCount = 0

        for pair in zip(anchors, anchors.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let segmentDistance = RouteCoordinateOps.distanceMeters(from: start, to: end)

            if segmentDistance < minimumMatchDistance(for: move.transportMode) {
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

        let finalized = matchedSegmentCount > 0
            ? RouteCoordinateOps.dedupeSequentialCoordinates(
                matchedCoordinates,
                minimumDistanceMeters: 6
            )
            : fallback

        cache[cacheKey] = finalized
        return finalized
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
        case .stationary, .unknown:
            return 60
        }
    }

    private static func anchorLimit(for mode: TransportMode) -> Int {
        switch mode {
        case .walking, .running:
            return 14
        case .cycling:
            return 12
        case .automotive:
            return 8
        case .stationary, .unknown:
            return 8
        }
    }
}

private extension MKPolyline {
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

private struct MovesSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let dayTimelines: [DayTimeline]
    let selectedDayKey: String
    @ObservedObject var captureManager: MovesLocationCaptureManager

    @State private var routeTrackingDuration: TemporaryRouteTrackingDuration
    @State private var isExporting = false
    @State private var exportDocument: TimelineExportDocument?
    @State private var exportContentType: UTType = .xml
    @State private var exportFilename = "moves-export"
    @State private var exportMessage = ""
    @State private var isShowingExportMessage = false

    init(
        dayTimelines: [DayTimeline],
        selectedDayKey: String,
        captureManager: MovesLocationCaptureManager
    ) {
        self.dayTimelines = dayTimelines
        self.selectedDayKey = selectedDayKey
        _captureManager = ObservedObject(wrappedValue: captureManager)
        _routeTrackingDuration = State(initialValue: captureManager.temporaryRouteTrackingDuration)
    }
    
    private var selectedDay: DayTimeline? {
        dayTimelines.first(where: { $0.dayKey == selectedDayKey })
    }

    private var selectedDayExportLabel: String {
        if let selectedDay {
            return localizedExportDateString(selectedDay.dayStart)
        }
        return "Selected Day"
    }

    private func localizedExportDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM y")
        return formatter.string(from: date)
    }

    private var dayCount: Int {
        dayTimelines.count
    }

    private var placeCount: Int {
        dayTimelines.reduce(0) { $0 + $1.places.count }
    }

    private var moveCount: Int {
        dayTimelines.reduce(0) { $0 + $1.moves.count }
    }

    private var sampleCount: Int {
        dayTimelines.reduce(0) { $0 + $1.samples.count }
    }

    private var routeTrackingStopsAtBatteryFiftyBinding: Binding<Bool> {
        Binding(
            get: { captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery },
            set: { newValue in
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: newValue,
                    stopsInLowPowerMode: captureManager.temporaryRouteTrackingStopsInLowPowerMode
                )
            }
        )
    }

    private var routeTrackingStopsInLowPowerModeBinding: Binding<Bool> {
        Binding(
            get: { captureManager.temporaryRouteTrackingStopsInLowPowerMode },
            set: { newValue in
                captureManager.updateTemporaryRouteTrackingAutoStopRules(
                    stopsAtFiftyPercentBattery: captureManager.temporaryRouteTrackingStopsAtFiftyPercentBattery,
                    stopsInLowPowerMode: newValue
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let bannerData = trackingStatusBannerData(
                    for: captureManager,
                    context: .settings
                ) {
                    Section {
                        TrackingStatusBanner(data: bannerData)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }

                if !captureManager.isDemoMode {
                    Section("Real Route Tracking") {
                        Text("Use frequent GPS updates for the actual route when you need more detail. Battery use increases while this is on.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        if captureManager.authorizationStatus == .authorizedAlways ||
                            captureManager.authorizationStatus == .authorizedWhenInUse {
                            Picker("Duration", selection: $routeTrackingDuration) {
                                ForEach(TemporaryRouteTrackingDuration.allCases) { duration in
                                    Text(duration.title)
                                        .tag(duration)
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle("Turn off at 50% battery", isOn: routeTrackingStopsAtBatteryFiftyBinding)
                            Toggle("Turn off in Low Power Mode", isOn: routeTrackingStopsInLowPowerModeBinding)

                            Text("These safeguards can end the session early if power gets tight.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)

                            Button {
                                captureManager.enableTemporaryRouteTracking(duration: routeTrackingDuration)
                            } label: {
                                Label(
                                    captureManager.temporaryRouteTrackingEndsAt == nil
                                    ? "Enable real route tracking"
                                    : "Update route tracking",
                                    systemImage: "location.fill.viewfinder"
                                )
                            }

                            if let endsAt = captureManager.temporaryRouteTrackingEndsAt,
                               endsAt > .now {
                                Text("Auto-off \(captureManager.temporaryRouteTrackingDuration.availabilityText).")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)

                                Button("Turn off now", role: .destructive) {
                                    captureManager.disableTemporaryRouteTracking()
                                }
                            }

                            if captureManager.authorizationStatus == .authorizedWhenInUse {
                                Text("Always location access is needed to keep this running in the background.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Grant location access first to use this feature.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Data Summary") {
                    LabeledContent("Days", value: "\(dayCount)")
                    LabeledContent("Places", value: "\(placeCount)")
                    LabeledContent("Moves", value: "\(moveCount)")
                    LabeledContent("Samples", value: "\(sampleCount)")
                }

                Section("GPX Export") {
                    Button {
                        export(.gpx, scope: .selectedDay)
                    } label: {
                        Label("\(selectedDayExportLabel) (.gpx)", systemImage: "calendar")
                    }
                    .disabled(selectedDay == nil)

                    Button {
                        export(.gpx, scope: .allDays)
                    } label: {
                        Label("All Days (.gpx)", systemImage: "calendar.badge.clock")
                    }
                    .disabled(dayTimelines.isEmpty)
                }

                Section("Other Formats") {
                    Button {
                        export(.geoJSON, scope: .selectedDay)
                    } label: {
                        Label("\(selectedDayExportLabel) (.geojson)", systemImage: "map")
                    }
                    .disabled(selectedDay == nil)

                    Button {
                        export(.geoJSON, scope: .allDays)
                    } label: {
                        Label("All Days (.geojson)", systemImage: "map.fill")
                    }
                    .disabled(dayTimelines.isEmpty)

                    Button {
                        export(.csv, scope: .allDays)
                    } label: {
                        Label("All Days Places+Moves (.csv)", systemImage: "tablecells")
                    }
                    .disabled(dayTimelines.isEmpty)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: captureManager.temporaryRouteTrackingDuration) { _, newValue in
                routeTrackingDuration = newValue
            }
        }
        CreatedByView()
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success(let url):
                exportMessage = "Exported to \(url.lastPathComponent)"
            case .failure(let error):
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
            isShowingExportMessage = true
        }
            .alert("Export", isPresented: $isShowingExportMessage) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportMessage)
            }
    }

    private func export(_ format: TimelineExportFormat, scope: TimelineExportScope) {
        let days: [DayTimeline]
        let scopeName: String

        switch scope {
        case .allDays:
            days = dayTimelines
            scopeName = "all-days"

        case .selectedDay:
            guard let selectedDay else {
                exportMessage = "No day selected for export."
                isShowingExportMessage = true
                return
            }
            days = [selectedDay]
            scopeName = selectedDay.dayKey
        }

        guard !days.isEmpty else {
            exportMessage = "No timeline data available yet."
            isShowingExportMessage = true
            return
        }

        guard let payload = TimelineExporter.makePayload(
            days: days,
            format: format,
            fileStem: "moves-\(scopeName)"
        ) else {
            exportMessage = "Could not build export file."
            isShowingExportMessage = true
            return
        }

        exportDocument = TimelineExportDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isExporting = true
    }
}

private enum TimelineExportScope {
    case allDays
    case selectedDay
}

private enum TimelineExportFormat {
    case gpx
    case geoJSON
    case csv

    var contentType: UTType {
        switch self {
        case .gpx:
            return .xml
        case .geoJSON:
            return .json
        case .csv:
            return .commaSeparatedText
        }
    }

    var fileExtension: String {
        switch self {
        case .gpx:
            return "gpx"
        case .geoJSON:
            return "geojson"
        case .csv:
            return "csv"
        }
    }
}

private struct TimelineExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
}

private struct TimelineTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date
}

private struct TimelineExportDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.xml, .json, .commaSeparatedText]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum TimelineExporter {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func makePayload(
        days: [DayTimeline],
        format: TimelineExportFormat,
        fileStem: String
    ) -> TimelineExportPayload? {
        let orderedDays = days.sorted(by: { $0.dayStart < $1.dayStart })

        let exportData: Data?
        switch format {
        case .gpx:
            exportData = gpxData(for: orderedDays)
        case .geoJSON:
            exportData = geoJSONData(for: orderedDays)
        case .csv:
            exportData = csvData(for: orderedDays)
        }

        guard let exportData else { return nil }
        return TimelineExportPayload(
            data: exportData,
            filename: "\(fileStem).\(format.fileExtension)",
            contentType: format.contentType
        )
    }

    private static func gpxData(for days: [DayTimeline]) -> Data? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves iOS Rebuild" xmlns="http://www.topografix.com/GPX/1/1">
        """

        for day in days {
            let sortedPlaces = day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate })
            for place in sortedPlaces {
                xml += """
                
                  <wpt lat="\(coordinateString(place.latitude))" lon="\(coordinateString(place.longitude))">
                    <name>\(xmlEscaped(place.displayTitle))</name>
                    <time>\(iso8601.string(from: place.arrivalDate))</time>
                  </wpt>
                """
            }

            let sortedMoves = day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate })
            guard !sortedMoves.isEmpty else { continue }

            xml += """
            
              <trk>
                <name>\(xmlEscaped(day.dayKey))</name>
            """

            for move in sortedMoves {
                let points = routePoints(for: move)
                guard points.count > 1 else { continue }

                xml += """
                
                    <trkseg>
                """

                for point in points {
                    xml += """
                    
                      <trkpt lat="\(coordinateString(point.latitude))" lon="\(coordinateString(point.longitude))">
                    """

                    if let elevation = point.elevation, elevation.isFinite {
                        xml += """
                        
                            <ele>\(elevationString(elevation))</ele>
                        """
                    }

                    xml += """
                    
                        <time>\(iso8601.string(from: point.timestamp))</time>
                      </trkpt>
                    """
                }

                xml += """
                
                    </trkseg>
                """
            }

            xml += """
            
              </trk>
            """
        }

        xml += """
        
        </gpx>
        """

        return xml.data(using: .utf8)
    }

    private static func geoJSONData(for days: [DayTimeline]) -> Data? {
        var features: [[String: Any]] = []

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) {
                var properties: [String: Any] = [
                    "record_type": "place",
                    "title": place.displayTitle,
                    "arrival_time": iso8601.string(from: place.arrivalDate),
                    "day_key": day.dayKey,
                ]

                if let departureDate = place.departureDate {
                    properties["departure_time"] = iso8601.string(from: departureDate)
                }
                if let userLabel = place.userLabel, !userLabel.isEmpty {
                    properties["user_label"] = userLabel
                }
                if let autoLabel = place.autoLabel, !autoLabel.isEmpty {
                    properties["auto_label"] = autoLabel
                }

                let geometry: [String: Any] = [
                    "type": "Point",
                    "coordinates": [place.longitude, place.latitude],
                ]

                features.append([
                    "type": "Feature",
                    "geometry": geometry,
                    "properties": properties,
                ])
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let points = routePoints(for: move)
                let coordinates = points.map { [$0.longitude, $0.latitude] }
                guard coordinates.count > 1 else { continue }

                var properties: [String: Any] = [
                    "record_type": "move",
                    "day_key": day.dayKey,
                    "transport_mode": move.transportMode.rawValue,
                    "start_time": iso8601.string(from: move.timelineStartDate),
                    "end_time": iso8601.string(from: move.endDate),
                    "distance_meters": move.distanceMeters,
                    "start_place": move.startPlace?.displayTitle ?? "Unknown start",
                    "end_place": move.endPlace?.displayTitle ?? "Unknown destination",
                ]

                if let stepCount = move.stepCount {
                    properties["step_count"] = stepCount
                }

                let geometry: [String: Any] = [
                    "type": "LineString",
                    "coordinates": coordinates,
                ]

                features.append([
                    "type": "Feature",
                    "geometry": geometry,
                    "properties": properties,
                ])
            }
        }

        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "features": features,
        ]

        return try? JSONSerialization.data(
            withJSONObject: collection,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func csvData(for days: [DayTimeline]) -> Data? {
        var rows: [String] = []
        rows.append("record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude")

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) {
                rows.append(
                    [
                        "place",
                        iso8601.string(from: place.arrivalDate),
                        place.departureDate.map(iso8601.string(from:)) ?? "",
                        csvEscaped(place.displayTitle),
                        day.dayKey,
                        "",
                        "",
                        "",
                        coordinateString(place.latitude),
                        coordinateString(place.longitude),
                    ].joined(separator: ",")
                )
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let title = "\(move.startPlace?.displayTitle ?? "Unknown start") to \(move.endPlace?.displayTitle ?? "Unknown destination")"
                rows.append(
                    [
                        "move",
                        iso8601.string(from: move.timelineStartDate),
                        iso8601.string(from: move.endDate),
                        csvEscaped(title),
                        day.dayKey,
                        move.transportMode.rawValue,
                        String(format: "%.2f", move.distanceMeters),
                        move.stepCount.map(String.init) ?? "",
                        "",
                        "",
                    ].joined(separator: ",")
                )
            }
        }

        return rows.joined(separator: "\n").data(using: .utf8)
    }

    private static func routePoints(for move: MoveSegment) -> [TimelineTrackPoint] {
        var points: [TimelineTrackPoint] = []
        points.reserveCapacity(move.samples.count + 2)

        if let startPlace = move.startPlace {
            points.append(
                TimelineTrackPoint(
                    latitude: startPlace.latitude,
                    longitude: startPlace.longitude,
                    elevation: nil,
                    timestamp: move.timelineStartDate
                )
            )
        }

        let sortedSamples = move.samples
            .preferredRouteDisplaySamples
            .sorted(by: { $0.timestamp < $1.timestamp })
        for sample in sortedSamples {
            points.append(
                TimelineTrackPoint(
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    elevation: sample.altitude,
                    timestamp: sample.timestamp
                )
            )
        }

        if let endPlace = move.endPlace {
            points.append(
                TimelineTrackPoint(
                    latitude: endPlace.latitude,
                    longitude: endPlace.longitude,
                    elevation: nil,
                    timestamp: move.endDate
                )
            )
        }

        let sortedPoints = points.sorted(by: { $0.timestamp < $1.timestamp })
        return dedupeSequentialPoints(in: sortedPoints)
    }

    private static func dedupeSequentialPoints(in points: [TimelineTrackPoint]) -> [TimelineTrackPoint] {
        guard !points.isEmpty else { return [] }

        var deduped: [TimelineTrackPoint] = []
        deduped.reserveCapacity(points.count)

        var previousKey: String?
        for point in points {
            let key = "\(Int(point.timestamp.timeIntervalSince1970.rounded()))|\(coordinateString(point.latitude))|\(coordinateString(point.longitude))"
            if key == previousKey { continue }
            deduped.append(point)
            previousKey = key
        }

        return deduped
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func elevationString(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private struct PanelSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MovesPalette.card.opacity(colorScheme == .dark ? 0.88 : 0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(MovesPalette.border, lineWidth: 1)
                    }
            }
    }
}

private struct FrostedCircleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(enabled ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.55))
            .background {
                Circle()
                    .fill(
                        MovesPalette.frostedFill.opacity(
                            enabled
                                ? (colorScheme == .dark ? 0.95 : 1.0)
                                : (colorScheme == .dark ? 0.55 : 0.75)
                        )
                    )
                    .overlay {
                        Circle()
                            .stroke(MovesPalette.border.opacity(enabled ? 0.9 : 0.7), lineWidth: 1)
                    }
                    .glassEffect(.regular, in: Circle())
            }
    }
}

private extension View {
    func panelSurface() -> some View {
        modifier(PanelSurfaceModifier())
    }

    func frostedCircle(enabled: Bool) -> some View {
        modifier(FrostedCircleModifier(enabled: enabled))
    }
}

private extension ProcessInfo {
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

#Preview {
    let configuration = ModelConfiguration(
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    let container = try! ModelContainer(
        for: DayTimeline.self,
        VisitPlace.self,
        MoveSegment.self,
        LocationSample.self,
        configurations: configuration
    )

    ContentView()
        .modelContainer(container)
        .environmentObject(MovesLocationCaptureManager(modelContainer: container))
}
