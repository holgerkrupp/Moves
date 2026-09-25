import CoreLocation
import MapKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct HistoryMapPlaceDTO: Sendable {
    let id: String
    let title: String
    let latitude: Double
    let longitude: Double
    let visitCount: Int
}

@ModelActor
private actor HistoryMapPlaceLoader {
    func load(period: MovesSharePeriod, periodStart: Date) throws -> [HistoryMapPlaceDTO] {
        let places: [VisitPlace]
        if let interval = period.dateInterval(containing: periodStart) {
            let predicate = #Predicate<VisitPlace> { place in
                place.arrivalDate >= interval.start && place.arrivalDate < interval.end
            }
            places = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        } else {
            places = try modelContext.fetch(FetchDescriptor<VisitPlace>())
        }

        struct Accumulator {
            var title: String
            var latitude: Double
            var longitude: Double
            var visitCount: Int
        }
        var grouped = [String: Accumulator]()
        for place in places {
            let latitudeBucket = Int((place.latitude * 10_000).rounded())
            let longitudeBucket = Int((place.longitude * 10_000).rounded())
            let key = "\(latitudeBucket)|\(longitudeBucket)"
            var accumulator = grouped[key] ?? Accumulator(
                title: place.displayTitle,
                latitude: place.latitude,
                longitude: place.longitude,
                visitCount: 0
            )
            accumulator.visitCount += 1
            grouped[key] = accumulator
        }
        return grouped.map { key, value in
            HistoryMapPlaceDTO(
                id: key,
                title: value.title,
                latitude: value.latitude,
                longitude: value.longitude,
                visitCount: value.visitCount
            )
        }
    }
}

/// An interactive history map that keeps the user's camera framing when it is exported.
struct MovesHistoryMapView: View {
    fileprivate enum Display: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case routes = "Routes"
        case heatMap = "Heat Map"
        case fog = "Fog Map"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .standard: "map"
            case .routes: "point.topleft.down.to.point.bottomright.curvepath"
            case .heatMap: "flame.fill"
            case .fog: "cloud.fog"
            }
        }
    }

    private enum BaseMap: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case imagery = "Satellite"
        case hybrid = "Hybrid"

        var id: Self { self }

        var swiftUIStyle: MapStyle {
            switch self {
            case .standard:
                .standard(elevation: .flat, emphasis: .muted)
            case .imagery:
                .imagery(elevation: .realistic)
            case .hybrid:
                .hybrid(elevation: .realistic)
            }
        }

        var snapshotType: MKMapType {
            switch self {
            case .standard: .standard
            case .imagery: .satellite
            case .hybrid: .hybrid
            }
        }
    }

    fileprivate struct Track: Identifiable {
        let id: UUID
        let transportMode: TransportMode
        let coordinates: [CLLocationCoordinate2D]
        let usesDetailedRoute: Bool
    }

    fileprivate struct Place: Identifiable {
        let id: String
        let title: String
        let coordinate: CLLocationCoordinate2D
        let visitCount: Int
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var importedRouteDataSummary: ImportedRouteDataSummaryStore

    private let dayTimelines: [DayTimeline]
    @State private var selectedPeriod: MovesSharePeriod = .day
    @State private var selectedDate: Date
    @State private var display: Display = .standard
    @State private var baseMap: BaseMap = .standard
    @State private var tracks: [Track] = []
    @State private var dataRevision = 0
    @State private var isLoadingTracks = false
    @State private var cacheBuildProgress: Double?
    @State private var camera: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion
    @State private var isShowingDatePicker = false
    @State private var isPreparingShareImage = false
    @State private var shareImage: UIImage?
    @State private var isShowingShareSheet = false

    init(dayTimelines: [DayTimeline], initialDate: Date) {
        self.dayTimelines = dayTimelines
        _selectedDate = State(initialValue: initialDate)
        let region = MapRegionFactory.region(for: [])
        _camera = State(initialValue: .region(region))
        _visibleRegion = State(initialValue: region)
    }

    private var selectedPeriodStart: Date {
        selectedPeriod.start(for: selectedDate)
    }

    private var selectedTimelines: [DayTimeline] {
        guard selectedPeriod != .forever else { return dayTimelines }
        return dayTimelines.filter {
            selectedPeriod.contains($0.dayStart, periodStart: selectedPeriodStart)
        }
    }

    @State private var places: [Place] = []

    private var allCoordinates: [CLLocationCoordinate2D] {
        tracks.flatMap(\.coordinates) + places.map(\.coordinate)
    }

    private var planeEndpoints: [CLLocationCoordinate2D] {
        tracks.flatMap { track -> [CLLocationCoordinate2D] in
            guard track.transportMode == .plane,
                  !track.usesDetailedRoute,
                  let start = track.coordinates.first,
                  let end = track.coordinates.last else {
                return []
            }
            return [start, end]
        }
    }

    private var canMoveToNextPeriod: Bool {
        selectedPeriod != .forever && selectedPeriodStart < selectedPeriod.start(for: .now)
    }

    var body: some View {
        map
            .navigationTitle("History Map")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Base Map", selection: $baseMap) {
                            ForEach(BaseMap.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Label("Map Style", systemImage: "map.fill")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await createShareImage() }
                    } label: {
                        if isPreparingShareImage {
                            ProgressView()
                        } else {
                            Label("Share Map Image", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isPreparingShareImage || (tracks.isEmpty && places.isEmpty))
                }
            }
            .task(id: dataRefreshKey) {
                await loadTracks()
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: .movesLocationSamplesDidChange) {
                    guard !Task.isCancelled else { return }
                    dataRevision &+= 1
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: .movesImportedRouteDataDidChange) {
                    guard !Task.isCancelled else { return }
                    dataRevision &+= 1
                }
            }
            .sheet(isPresented: $isShowingDatePicker) {
                MovesJumpToDateView(
                    daySummaries: importedRouteDataSummary.daySummaries,
                    selectedDate: selectedDate,
                    onSelectDate: { selectedDate = $0 },
                    onDismiss: { isShowingDatePicker = false }
                )
            }
            .sheet(isPresented: $isShowingShareSheet, onDismiss: { shareImage = nil }) {
                if let shareImage {
                    MovesActivityView(activityItems: [shareImage])
                }
            }
    }

    private var dataRefreshKey: String {
        return "\(selectedPeriod.rawValue)|\(selectedPeriodStart.timeIntervalSinceReferenceDate)|\(dataRevision)"
    }

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom, .rotate, .pitch]) {
            ForEach(tracks) { track in
                let coordinates = displayedCoordinates(for: track)
                ForEach(Array(RouteCoordinateOps.mapPolylineSegments(coordinates).enumerated()), id: \.offset) { _, segment in
                    if display == .fog {
                        MapPolyline(coordinates: segment)
                            .stroke(.white.opacity(0.62), lineWidth: 5)
                        MapPolyline(coordinates: segment)
                            .stroke(routeTint(for: track.transportMode), lineWidth: 2.5)
                    } else {
                        MapPolyline(coordinates: segment)
                            .stroke(
                                display == .heatMap
                                    ? Color.orange.opacity(0.22)
                                    : routeTint(for: track.transportMode).opacity(0.86),
                                lineWidth: display == .heatMap ? 2 : 4
                            )
                    }
                }
            }

            ForEach(Array(planeEndpoints.enumerated()), id: \.offset) { _, coordinate in
                Annotation("", coordinate: coordinate) {
                    Circle()
                        .fill(display == .fog ? Color.yellow : MovesPalette.move)
                        .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                        .frame(width: display == .fog ? 8 : 10, height: display == .fog ? 8 : 10)
                        .accessibilityLabel("Flight endpoint")
                }
            }

            if display == .standard {
                ForEach(places) { place in
                    Annotation(place.title, coordinate: place.coordinate, anchor: .bottom) {
                        VStack(spacing: 1) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, MovesPalette.place)
                            if place.visitCount > 1 {
                                Text(place.visitCount.formatted())
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                        .accessibilityLabel("\(place.title), \(place.visitCount) visits")
                    }
                }
            } else if display == .heatMap {
                ForEach(places) { place in
                    Annotation(place.title, coordinate: place.coordinate) {
                        HeatMapDot(intensity: heatIntensity(for: place))
                            .accessibilityLabel("\(place.title), \(place.visitCount) visits")
                    }
                }
            }
        }
        .mapStyle(display == .fog ? .imagery(elevation: .realistic) : baseMap.swiftUIStyle)
        .overlay {
            if display == .fog {
                Color.black.opacity(0.46)
                    .allowsHitTesting(false)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Display", selection: $display) {
                ForEach(Display.allCases) { option in
                    Label(option.rawValue, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Picker("Timeframe", selection: $selectedPeriod) {
                ForEach(MovesSharePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 14) {
                Button {
                    selectedDate = selectedPeriod.adding(-1, to: selectedPeriodStart)
                } label: {
                    Label("Previous \(selectedPeriod.singularTitle)", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(selectedPeriod == .forever)

                Button {
                    isShowingDatePicker = true
                } label: {
                    Label(selectedPeriod.label(for: selectedPeriodStart), systemImage: "calendar")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPeriod == .forever)

                Button {
                    selectedDate = selectedPeriod.adding(1, to: selectedPeriodStart)
                } label: {
                    Label("Next \(selectedPeriod.singularTitle)", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveToNextPeriod)
            }

            if isLoadingTracks {
                VStack(spacing: 5) {
                    if let cacheBuildProgress {
                        ProgressView(value: cacheBuildProgress) {
                            Text("Building optimized map cache…")
                        } currentValueLabel: {
                            Text(cacheBuildProgress, format: .percent.precision(.fractionLength(0)))
                        }
                        .font(.caption)
                    } else {
                        ProgressView("Preparing routes…")
                            .font(.caption)
                    }
                }
            } else {
                Text("\(tracks.count) moves · \(places.reduce(0) { $0 + $1.visitCount }) visits · Drag and zoom to frame your image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    @MainActor
    private func loadTracks() async {
        isLoadingTracks = true
        cacheBuildProgress = nil
        defer {
            isLoadingTracks = false
            cacheBuildProgress = nil
        }

        let period = selectedPeriod
        let periodStart = selectedPeriodStart
        let selectedDays = selectedTimelines
        let container = modelContext.container

        if let loadedPlaces = try? await HistoryMapPlaceLoader(modelContainer: container)
            .load(period: period, periodStart: periodStart), !Task.isCancelled {
            places = loadedPlaces.map {
                Place(
                    id: $0.id,
                    title: $0.title,
                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    visitCount: $0.visitCount
                )
            }
            .sorted { $0.visitCount > $1.visitCount }
        }

        func cachedTracks() -> [ShareMapAggregateTrack]? {
            let cacheContext = ModelContext(container)
            return ShareMapAggregateStore.cachedTracks(
                for: period,
                periodStart: periodStart,
                timelines: selectedDays,
                in: cacheContext
            )
        }

        var sourceTracks: [ShareMapAggregateTrack]?
        if ShareMapAggregateStore.supports(period) {
            sourceTracks = cachedTracks()
            if sourceTracks == nil {
                cacheBuildProgress = 0
                await ShareMapAggregateBuilder.refresh(
                    period: period,
                    periodStart: periodStart,
                    in: container,
                    progress: { progress in
                        Task { @MainActor in
                            cacheBuildProgress = progress
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                sourceTracks = cachedTracks()
            }
        }

        guard !Task.isCancelled else { return }
        if let sourceTracks {
            tracks = sourceTracks.map {
                Track(
                    id: $0.id,
                    transportMode: $0.transportMode,
                    coordinates: $0.coordinates,
                    usesDetailedRoute: $0.usesDetailedRoute
                )
            }
        } else {
            tracks = selectedDays.flatMap(\.moves).compactMap { move in
                let fallback = MoveRouteGeometry.rawCoordinates(for: move)
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
                let coordinates = move.manualRouteCoordinates
                    ?? move.cachedRouteCoordinates(for: signature)
                    ?? fallback
                guard coordinates.count > 1 else { return nil }
                return Track(
                    id: move.id,
                    transportMode: move.transportMode,
                    coordinates: downsampled(coordinates, maximumCount: period == .forever ? 60 : 240),
                    usesDetailedRoute: move.usesHighAccuracyRouteTracking
                )
            }
        }

        let region = MapRegionFactory.region(for: allCoordinates)
        visibleRegion = region
        camera = .region(region)
    }

    @MainActor
    private func createShareImage() async {
        isPreparingShareImage = true
        defer { isPreparingShareImage = false }
        shareImage = await HistoryMapImageRenderer.render(
            region: visibleRegion,
            tracks: tracks,
            places: places,
            display: display,
            mapType: display == .fog ? .satellite : baseMap.snapshotType,
            title: selectedPeriod.label(for: selectedPeriodStart)
        )
        if shareImage != nil {
            isShowingShareSheet = true
        }
    }

    private func routeTint(for mode: TransportMode) -> Color {
        if display == .fog {
            return Color(red: 0.96, green: 1.0, blue: 0.58)
        }
        return switch mode {
        case .stationary, .walking, .running, .cycling, .automotive, .motorcycle, .unknown:
            MovesPalette.move
        case .swimming, .train, .plane, .boat:
            MovesPalette.transport(mode)
        }
    }

    private func heatIntensity(for place: Place) -> CGFloat {
        let maximum = max(places.map(\.visitCount).max() ?? 1, 1)
        return MovesShareHeatScale.intensity(frequency: place.visitCount, maximum: maximum)
    }

    private func displayedCoordinates(for track: Track) -> [CLLocationCoordinate2D] {
        // Long-distance jumps make a world map misleading. Keep their endpoints
        // visible, but never draw a straight route across countries or oceans.
        track.transportMode == .plane && !track.usesDetailedRoute ? [] : track.coordinates
    }

    private func downsampled(_ coordinates: [CLLocationCoordinate2D], maximumCount: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximumCount, maximumCount > 1 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            coordinates[min(Int((Double(index) * step).rounded()), coordinates.count - 1)]
        }
    }
}

private struct HeatMapDot: View {
    let intensity: CGFloat

    var body: some View {
        let size = 28 + intensity * 42
        Circle()
            .fill(
                RadialGradient(
                    colors: [.red.opacity(0.95), .orange.opacity(0.55), .yellow.opacity(0.12), .clear],
                    center: .center,
                    startRadius: 1,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
    }
}

private enum HistoryMapImageRenderer {
    static func render(
        region: MKCoordinateRegion,
        tracks: [MovesHistoryMapView.Track],
        places: [MovesHistoryMapView.Place],
        display: MovesHistoryMapView.Display,
        mapType: MKMapType,
        title: String
    ) async -> UIImage? {
        let size = CGSize(width: 1_600, height: 1_100)
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.mapType = mapType
        options.showsBuildings = mapType != .satellite

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            let cgContext = context.cgContext

            if display == .fog {
                cgContext.setFillColor(UIColor.black.withAlphaComponent(0.52).cgColor)
                cgContext.fill(CGRect(origin: .zero, size: size))
            }

            for track in tracks where (track.transportMode != .plane || track.usesDetailedRoute) && track.coordinates.count > 1 {
                let path = UIBezierPath()
                for (index, coordinate) in track.coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    if index == 0
                        || RouteCoordinateOps.crossesAntimeridian(
                            from: track.coordinates[index - 1],
                            to: coordinate
                        ) {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                cgContext.addPath(path.cgPath)
                let color = display == .heatMap
                    ? UIColor.systemOrange.withAlphaComponent(0.25)
                    : display == .fog
                        ? UIColor(red: 0.96, green: 1.0, blue: 0.58, alpha: 1)
                    : transportColor(for: track.transportMode)
                if display == .fog {
                    cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.62).cgColor)
                    cgContext.setLineWidth(10)
                    cgContext.setLineCap(.round)
                    cgContext.setLineJoin(.round)
                    cgContext.strokePath()
                    cgContext.addPath(path.cgPath)
                }
                cgContext.setStrokeColor(color.cgColor)
                cgContext.setLineWidth(display == .heatMap ? 4 : (display == .fog ? 5 : 7))
                cgContext.setLineCap(.round)
                cgContext.setLineJoin(.round)
                cgContext.strokePath()
            }

            for track in tracks where track.transportMode == .plane && !track.usesDetailedRoute {
                for coordinate in [track.coordinates.first, track.coordinates.last].compactMap({ $0 }) {
                    let point = snapshot.point(for: coordinate)
                    let radius: CGFloat = display == .fog ? 6 : 7
                    cgContext.setFillColor(
                        (display == .fog ? UIColor.systemYellow : UIColor.systemTeal).cgColor
                    )
                    cgContext.fillEllipse(in: CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                    cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
                    cgContext.setLineWidth(2)
                    cgContext.strokeEllipse(in: CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                }
            }

            if display == .standard {
                for place in places {
                    let point = snapshot.point(for: place.coordinate)
                    let radius: CGFloat = place.visitCount > 1 ? 14 : 10
                    cgContext.setFillColor(UIColor.systemTeal.cgColor)
                    cgContext.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                    cgContext.setStrokeColor(UIColor.white.cgColor)
                    cgContext.setLineWidth(4)
                    cgContext.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                }
            } else if display == .heatMap {
                let maximum = max(places.map(\.visitCount).max() ?? 1, 1)
                for place in places {
                    let point = snapshot.point(for: place.coordinate)
                    let intensity = MovesShareHeatScale.intensity(frequency: place.visitCount, maximum: maximum)
                    let radius = 20 + intensity * 55
                    let colors = [
                        UIColor.systemRed.withAlphaComponent(0.88).cgColor,
                        UIColor.systemOrange.withAlphaComponent(0.45).cgColor,
                        UIColor.systemYellow.withAlphaComponent(0.05).cgColor,
                        UIColor.clear.cgColor
                    ] as CFArray
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 0.7, 1]) {
                        cgContext.drawRadialGradient(
                            gradient,
                            startCenter: point,
                            startRadius: 0,
                            endCenter: point,
                            endRadius: radius,
                            options: .drawsAfterEndLocation
                        )
                    }
                }
            }

            let labelRect = CGRect(x: 34, y: 34, width: size.width - 68, height: 62)
            UIColor.black.withAlphaComponent(0.54).setFill()
            UIBezierPath(roundedRect: labelRect, cornerRadius: 18).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            ("Moves · " + title).draw(in: labelRect.insetBy(dx: 18, dy: 12), withAttributes: attributes)
        }
    }

    private static func transportColor(for mode: TransportMode) -> UIColor {
        switch mode {
        case .plane: .systemIndigo
        case .train: .systemPurple
        case .boat, .swimming: .systemBlue
        case .walking, .running: .systemGreen
        case .cycling: .systemMint
        case .automotive: .systemOrange
        case .motorcycle: .systemOrange
        case .stationary, .unknown: .systemTeal
        }
    }
}
