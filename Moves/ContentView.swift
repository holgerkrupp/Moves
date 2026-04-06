import SwiftUI
import SwiftData
import MapKit

struct ContentView: View {
    @EnvironmentObject private var captureManager: MovesLocationCaptureManager
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \DayTimeline.dayStart, order: .reverse) private var dayTimelines: [DayTimeline]

    @State private var selectedDayKey = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.81, green: 0.90, blue: 1.0),
                        Color(red: 0.84, green: 0.96, blue: 0.88),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.28))
                    .frame(width: 260, height: 260)
                    .blur(radius: 18)
                    .offset(x: -130, y: -240)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.blue.opacity(colorScheme == .dark ? 0.08 : 0.16))
                    .frame(width: 230, height: 230)
                    .blur(radius: 30)
                    .offset(x: 170, y: 280)
                    .allowsHitTesting(false)

                VStack(spacing: 14) {
                    trackingStatusCard

                    if dayTimelines.isEmpty {
                        emptyState
                    } else {
                        daySelector

                        TabView(selection: $selectedDayKey) {
                            ForEach(dayTimelines) { day in
                                DayTimelinePage(dayTimeline: day)
                                    .tag(day.dayKey)
                                    .padding(.top, 4)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .automatic))
                    }
                }
                .padding(16)
            }
            .navigationTitle("Moves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await captureManager.refreshHistoricalBackfill() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh timeline with a one-shot location sample")
                }
            }
        }
        .task {
            guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
            await captureManager.start()
            await captureManager.refreshHistoricalBackfill()
        }
        .onAppear {
            syncSelectedDayIfNeeded()
        }
        .onChange(of: dayTimelines.map(\.dayKey)) { _, _ in
            syncSelectedDayIfNeeded()
        }
    }

    private var trackingStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(captureManager.trackingStatusText, systemImage: statusSymbolName)
                .font(.headline)

            if let lastCaptureAt = captureManager.lastCaptureAt {
                Text("Last sample: \(lastCaptureAt, format: .dateTime.hour().minute())")
                    .font(.subheadline)
                    .foregroundStyle(secondaryTextColor)
            }

            if let lastErrorMessage = captureManager.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .movesGlassCardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.slash.circle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(secondaryTextColor)

            Text("No timeline yet")
                .font(.title3.weight(.semibold))

            Text("Keep Moves running in the background. Visits and movement segments appear automatically as iOS records them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(secondaryTextColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .movesGlassCardStyle()
    }

    private var daySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dayTimelines) { day in
                    let isSelected = selectedDayKey == day.dayKey

                    Button {
                        withAnimation(.snappy) {
                            selectedDayKey = day.dayKey
                        }
                    } label: {
                        Text(day.dayStart, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(primaryTextColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                                    .glassEffect()
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var statusSymbolName: String {
        switch captureManager.authorizationStatus {
        case .authorizedAlways:
            return "location.fill"
        case .authorizedWhenInUse:
            return "location"
        case .notDetermined:
            return "location.circle"
        case .restricted, .denied:
            return "exclamationmark.triangle.fill"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black.opacity(0.88)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.75) : .black.opacity(0.65)
    }

    private func syncSelectedDayIfNeeded() {
        guard let firstKey = dayTimelines.first?.dayKey else {
            selectedDayKey = ""
            return
        }

        if !dayTimelines.contains(where: { $0.dayKey == selectedDayKey }) {
            selectedDayKey = firstKey
        }
    }
}

private struct DayTimelinePage: View {
    let dayTimeline: DayTimeline

    private var timelineEntries: [TimelineEntry] {
        let places = dayTimeline.places.map(TimelineEntry.place)
        let moves = dayTimeline.moves.map(TimelineEntry.move)
        return (places + moves).sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summaryCard

                if timelineEntries.isEmpty {
                    Text("No segments for this day yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .movesGlassCardStyle()
                } else {
                    ForEach(timelineEntries) { entry in
                        switch entry {
                        case .place(let place):
                            NavigationLink {
                                PlaceMapDetailView(place: place)
                            } label: {
                                PlaceCard(place: place)
                            }
                            .buttonStyle(.plain)

                        case .move(let segment):
                            NavigationLink {
                                MoveMapDetailView(segment: segment)
                            } label: {
                                MoveCard(segment: segment)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var summaryCard: some View {
        HStack {
            Label("\(dayTimeline.places.count) places", systemImage: "mappin.and.ellipse")
            Spacer()
            Label("\(dayTimeline.moves.count) moves", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
        }
        .font(.subheadline.weight(.medium))
        .movesGlassCardStyle()
    }
}

private enum TimelineEntry: Identifiable {
    case place(VisitPlace)
    case move(MoveSegment)

    var id: String {
        switch self {
        case .place(let place):
            return "place-\(place.id.uuidString)"
        case .move(let segment):
            return "move-\(segment.id.uuidString)"
        }
    }

    var startDate: Date {
        switch self {
        case .place(let place):
            return place.arrivalDate
        case .move(let segment):
            return segment.startDate
        }
    }
}

private struct PlaceCard: View {
    let place: VisitPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(place.displayTitle, systemImage: "mappin.circle.fill")
                .font(.headline)

            HStack {
                Text("Arrive")
                Spacer()
                Text(place.arrivalDate, format: .dateTime.hour().minute())
            }
            .font(.subheadline)

            HStack {
                Text("Stay")
                Spacer()
                Text(stayText)
            }
            .font(.subheadline)
            .foregroundStyle(Color.primary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .movesGlassCardStyle()
    }

    private var stayText: String {
        guard let departure = place.departureDate else { return "In progress" }
        return DurationFormatter.text(for: departure.timeIntervalSince(place.arrivalDate))
    }
}

private struct MoveCard: View {
    let segment: MoveSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(segment.transportMode.title, systemImage: segment.transportMode.symbolName)
                .font(.headline)

            HStack {
                Text("Duration")
                Spacer()
                Text(DurationFormatter.text(for: segment.endDate.timeIntervalSince(segment.startDate)))
            }
            .font(.subheadline)

            HStack {
                Text("Distance")
                Spacer()
                Text(distanceText)
            }
            .font(.subheadline)

            if let stepCount = segment.stepCount {
                HStack {
                    Text("Steps")
                    Spacer()
                    Text("\(stepCount)")
                }
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .movesGlassCardStyle()
    }

    private var distanceText: String {
        Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

private struct PlaceMapDetailView: View {
    let place: VisitPlace

    @State private var camera: MapCameraPosition

    init(place: VisitPlace) {
        self.place = place
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
        }
        .navigationTitle("Place")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(place.displayTitle)
                    .font(.headline)
                Text("Arrived \(place.arrivalDate, format: .dateTime.hour().minute())")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .movesGlassCardStyle()
            .padding(12)
        }
    }
}

private struct MoveMapDetailView: View {
    let segment: MoveSegment

    @State private var camera: MapCameraPosition

    private var routeCoordinates: [CLLocationCoordinate2D] {
        let sampleCoordinates = segment.samples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map(\.coordinate)

        var coordinates: [CLLocationCoordinate2D] = []
        if let start = segment.startPlace?.coordinate {
            coordinates.append(start)
        }
        coordinates.append(contentsOf: sampleCoordinates)
        if let end = segment.endPlace?.coordinate {
            coordinates.append(end)
        }
        return coordinates
    }

    init(segment: MoveSegment) {
        self.segment = segment

        let coordinates = segment.samples
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map(\.coordinate)

        var all = coordinates
        if let start = segment.startPlace?.coordinate { all.insert(start, at: 0) }
        if let end = segment.endPlace?.coordinate { all.append(end) }

        _camera = State(initialValue: .region(MapRegionFactory.region(for: all)))
    }

    var body: some View {
        Map(position: $camera) {
            if let start = segment.startPlace?.coordinate {
                Marker("Start", coordinate: start)
                    .tint(.green)
            }

            if routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(.blue, lineWidth: 5)
            }

            if let end = segment.endPlace?.coordinate {
                Marker("End", coordinate: end)
                    .tint(.red)
            }
        }
        .navigationTitle("Move")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(segment.transportMode.title)
                    .font(.headline)
                Text("\(DurationFormatter.text(for: segment.endDate.timeIntervalSince(segment.startDate))) • \(Measurement(value: max(segment.distanceMeters, 0), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .movesGlassCardStyle()
            .padding(12)
        }
    }
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

private struct MovesGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black.opacity(0.9))
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.40))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(
                                colorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.7),
                                lineWidth: 1
                            )
                    }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: 12, y: 4)
            }
    }
}

private extension View {
    func movesGlassCardStyle() -> some View {
        modifier(MovesGlassCardModifier())
    }
}

private extension ProcessInfo {
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

#Preview {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
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
