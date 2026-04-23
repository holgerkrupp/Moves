import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

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

enum TrackingStatusBannerContext {
    case timeline
    case settings
}

struct TrackingStatusBannerData {
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

struct TrackingStatusBanner: View {
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
func trackingStatusBannerData(
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
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Background tracking is enabled.",
            systemImage: "location.fill",
            tint: MovesPalette.place
        )
    case .authorizedWhenInUse:
        return TrackingStatusBannerData(
            title: captureManager.trackingStatusText,
            message: "Moves can read location while open. Grant Always to keep recording in the background.",
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

struct ContentView: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @EnvironmentObject private var undoController: AppUndoController
    @Environment(\.modelContext) private var modelContext
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
            modelContext.undoManager = undoController.manager
        }
        .onChange(of: dayTimelines.map(\.dayKey)) { _, _ in
            syncSelectedDayIfNeeded()
        }
        .onChange(of: selectedPageIndex) { _, newIndex in
            guard dayTimelines.indices.contains(newIndex) else { return }
            selectedDayKey = dayTimelines[newIndex].dayKey
        }
        .overlay {
            ShakeToUndoDetector(undoManager: undoController.manager) {
                handleShakeToUndo()
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
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

    @MainActor
    private func handleShakeToUndo() {
        let undoManager = undoController.manager
        guard undoManager.canUndo else { return }
        modelContext.undoManager = undoManager

        undoManager.undo()

        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                print("Failed to save undo changes: \(error.localizedDescription)")
            }
        }
    }
}

enum TimelineExportScope {
    case allDays
    case selectedDay
}

enum TimelineExportFormat {
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

struct TimelineExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
}

struct TimelineTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date
}

struct TimelineExportDocument: FileDocument {
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

enum TimelineExporter {
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

struct PanelSurfaceModifier: ViewModifier {
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

struct FrostedCircleModifier: ViewModifier {
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

extension View {
    func panelSurface() -> some View {
        modifier(PanelSurfaceModifier())
    }

    func frostedCircle(enabled: Bool) -> some View {
        modifier(FrostedCircleModifier(enabled: enabled))
    }
}

private struct ShakeToUndoDetector: UIViewRepresentable {
    let undoManager: UndoManager
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeToUndoView {
        let view = ShakeToUndoView()
        view.managedUndoManager = undoManager
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeToUndoView, context: Context) {
        uiView.managedUndoManager = undoManager
        uiView.onShake = onShake
    }
}

private final class ShakeToUndoView: UIView {
    var managedUndoManager: UndoManager?
    var onShake: (() -> Void)?
    private var activeObserver: NSObjectProtocol?

    override var undoManager: UndoManager? {
        managedUndoManager
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.becomeFirstResponderIfPossible()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponderIfPossible()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        becomeFirstResponderIfPossible()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else {
            super.motionEnded(motion, with: event)
            return
        }

        onShake?()
    }

    private func becomeFirstResponderIfPossible() {
        guard window != nil else { return }
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }
}

private extension ProcessInfo {
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
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
            .environmentObject(AppUndoController())
    }
}
