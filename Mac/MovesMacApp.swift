import CoreLocation
import MapKit
import SwiftData
import SwiftUI

#if os(macOS)
@main
struct MovesMacApp: App {
    private static let cloudKitContainerIdentifier = "iCloud.de.holgerkrupp.Moves"
    private let modelContainer: ModelContainer
    @StateObject private var importCoordinator = ImportCoordinator()

    init() {
        do { modelContainer = try Self.makeModelContainer() }
        catch { fatalError("Could not create the Moves macOS model container: \(error)") }
    }

    static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([DayTimeline.self, VisitPlace.self, KnownLocation.self, MoveSegment.self, LocationSample.self, MovesDeviceProfile.self])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudKitContainerIdentifier))
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    var body: some Scene {
        WindowGroup("Moves") {
            MovesMacBrowser(modelContainer: modelContainer, importCoordinator: importCoordinator)
        }
            .modelContainer(modelContainer)
            .environmentObject(importCoordinator)
            .defaultSize(width: 1_180, height: 760)
            .commands {
                CommandGroup(after: .sidebar) {
                    Button("Toggle Inspector") { NotificationCenter.default.post(name: .movesMacToggleInspector, object: nil) }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
    }
}

private extension Notification.Name {
    static let movesMacToggleInspector = Notification.Name("Moves.mac.toggleInspector")
}

private enum MacSelection: Hashable {
    case day(String), place(UUID), move(UUID), imported, recovery
}

private struct MacYear: Identifiable {
    let year: Int
    let months: [MacMonth]
    var id: Int { year }
}

private struct MacMonth: Identifiable {
    let year: Int
    let month: Int
    let days: [DayTimeline]
    var id: String { "\(year)-\(month)" }
}

private struct MacRecentItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let selection: MacSelection
}

private struct MovesMacBrowser: View {
    @ObservedObject private var importCoordinator: ImportCoordinator
    @StateObject private var importer: RouteFileImporter
    @Environment(\.modelContext) private var modelContext
    @Query private var allSamples: [LocationSample]
    @Query private var allMoves: [MoveSegment]
    @Query(sort: \DayTimeline.dayStart, order: .reverse) private var timelines: [DayTimeline]
    @State private var selection: MacSelection?
    @State private var isInspectorPresented = true
    @State private var searchText = ""
    @State private var isShowingImportQueue = false

    init(modelContainer: ModelContainer, importCoordinator: ImportCoordinator) {
        _importCoordinator = ObservedObject(wrappedValue: importCoordinator)
        _importer = StateObject(wrappedValue: RouteFileImporter(
            modelContext: ModelContext(modelContainer), importCoordinator: importCoordinator
        ))
    }

    private var importedSampleCount: Int { allSamples.filter { $0.source == .fileRouteImport }.count }
    private var importedMoveCount: Int { allMoves.filter { $0.samples.contains { $0.source == .fileRouteImport } }.count }

    private var years: [MacYear] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: timelines) { calendar.component(.year, from: $0.dayStart) }
        return grouped.keys.sorted(by: >).map { year in
            let byMonth = Dictionary(grouping: grouped[year, default: []]) { calendar.component(.month, from: $0.dayStart) }
            return MacYear(year: year, months: byMonth.keys.sorted(by: >).map { month in
                MacMonth(year: year, month: month, days: byMonth[month, default: []].sorted { $0.dayStart > $1.dayStart })
            })
        }
    }

    private var recentItems: [MacRecentItem] {
        timelines.prefix(8).map { timeline in
            MacRecentItem(id: "day-\(timeline.dayKey)", title: timeline.dayStart.formatted(date: .abbreviated, time: .omitted), subtitle: summary(for: timeline), icon: "calendar", selection: .day(timeline.dayKey))
        }
    }

    private var filteredTimelines: [DayTimeline] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return timelines }
        return timelines.filter { timeline in
            timeline.dayStart.formatted(date: .long, time: .omitted).localizedCaseInsensitiveContains(query) ||
            timeline.places.contains { $0.displayTitle.localizedCaseInsensitiveContains(query) } ||
            timeline.moves.contains { $0.transportMode.title.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationSplitView { sidebar } detail: {
            switch selection {
            case .imported:
                ImportedRouteDataView(modelContext: modelContext)
            case .recovery:
                FailedRouteImportsView(importer: importer)
            default:
                MacWorkspace(timelines: filteredTimelines, selection: $selection, searchText: searchText)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search places, moves, or dates")
        .inspector(isPresented: $isInspectorPresented) {
            MacInspector(selection: selection, timelines: timelines)
                .inspectorColumnWidth(min: 230, ideal: 280, max: 360)
        }
        .onReceive(NotificationCenter.default.publisher(for: .movesMacToggleInspector)) { _ in isInspectorPresented.toggle() }
        .onChange(of: timelines) { _, current in
            if case let .day(key) = selection, !current.contains(where: { $0.dayKey == key }) { selection = nil }
        }
        .toolbar {
            ToolbarItem {
                ImportQueueToolbarButton(
                    coordinator: importCoordinator,
                    isPresented: $isShowingImportQueue
                )
            }
        }
        .popover(isPresented: $isShowingImportQueue) {
            ImportQueueView(coordinator: importCoordinator)
                .frame(minWidth: 420, minHeight: 420)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                MacSidebarRow(title: "Imported", subtitle: "\(importedMoveCount) routes · \(importedSampleCount) samples", systemImage: "arrow.down.to.line.compact")
                    .tag(MacSelection.imported)
                MacSidebarRow(title: "Failed Imports", subtitle: recoverySubtitle, systemImage: "exclamationmark.triangle")
                    .tag(MacSelection.recovery)
            }
            Section("Recent") {
                if recentItems.isEmpty { Text("No recorded days yet").foregroundStyle(.secondary) }
                else { ForEach(recentItems) { item in MacSidebarRow(title: item.title, subtitle: item.subtitle, systemImage: item.icon).tag(item.selection) } }
            }
            Section("History") {
                ForEach(years) { year in
                    DisclosureGroup {
                        ForEach(year.months) { month in
                            DisclosureGroup {
                                ForEach(month.days) { timeline in
                                    MacSidebarRow(title: timeline.dayStart.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()), subtitle: summary(for: timeline), systemImage: "calendar.day.timeline.left")
                                        .tag(MacSelection.day(timeline.dayKey))
                                }
                            } label: {
                                Label(DateFormatter().monthSymbols[month.month - 1], systemImage: "calendar")
                            }
                        }
                    } label: { Label(String(year.year), systemImage: "calendar.badge.clock") }
                }
            }
        }
        .navigationTitle("Moves")
        .navigationSplitViewColumnWidth(min: 230, ideal: 285, max: 360)
        .overlay {
            if timelines.isEmpty && importedSampleCount == 0 { ContentUnavailableView("No History", systemImage: "map", description: Text("Timeline data shared through your private iCloud container will appear here.")) }
        }
    }

    private var recoverySubtitle: String {
        let count = importCoordinator.unresolvedRecoveryCount
        guard count > 0 else { return "All imports resolved" }
        let missing = importCoordinator.missingInformationCount
        return missing == count ? "\(count) missing information" : "\(count) unresolved · \(missing) missing information"
    }

    private func summary(for timeline: DayTimeline) -> String { "\(timeline.places.count) places · \(timeline.moves.count) moves · \(timeline.samples.count) samples" }
}

private struct MacSidebarRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: { Image(systemName: systemImage).foregroundStyle(.tint) }
            .padding(.vertical, 2)
    }
}

private struct MacWorkspace: View {
    let timelines: [DayTimeline]
    @Binding var selection: MacSelection?
    let searchText: String

    private var selectedDay: DayTimeline? {
        if case let .day(key) = selection { return timelines.first { $0.dayKey == key } }
        if case let .place(id) = selection { return timelines.first { $0.places.contains { $0.id == id } } }
        if case let .move(id) = selection { return timelines.first { $0.moves.contains { $0.id == id } } }
        return timelines.first
    }

    var body: some View {
        Group {
            if let selectedDay { MacDayWorkspace(day: selectedDay, selection: $selection) }
            else { ContentUnavailableView("Select a day", systemImage: "calendar", description: Text("Choose a day from the sidebar to browse your location history.")) }
        }
        .navigationTitle(selectedDay?.dayStart.formatted(date: .long, time: .omitted) ?? "History")
        .toolbar { ToolbarItem(placement: .primaryAction) { if !searchText.isEmpty { Text("Filtered").font(.caption).foregroundStyle(.secondary) } } }
    }
}

private struct MacDayWorkspace: View {
    let day: DayTimeline
    @Binding var selection: MacSelection?
    @State private var camera: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        day.places.map(\.coordinate) + day.samples.map(\.coordinate) + day.moves.flatMap { RouteCoordinateStorage.decode($0.manualRouteCoordinatesData ?? $0.routeCacheCoordinatesData) }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacDayMap(day: day, camera: $camera).frame(minHeight: 260, idealHeight: 390, maxHeight: .infinity)
            Divider()
            activityList
        }
        .onAppear { camera = .rect(MKMapRect.bounding(coordinates: coordinates)) }
    }

    private var activityList: some View {
        Table(of: MacActivityRow.self, selection: $selection) {
            TableColumn("Time") { row in Text(row.time).monospacedDigit() }.width(min: 68, ideal: 92)
            TableColumn("Activity") { row in Label(row.title, systemImage: row.icon) }
            TableColumn("Details") { row in Text(row.details).foregroundStyle(.secondary) }
            TableColumn("Metadata") { row in Text(row.metadata).foregroundStyle(.secondary) }
        } rows: { ForEach(rows) { row in TableRow(row) } }
            .frame(minHeight: 185, idealHeight: 235)
            .padding(.top, 8)
            .overlay { if rows.isEmpty { ContentUnavailableView("No activity", systemImage: "location.slash") } }
    }

    private var rows: [MacActivityRow] {
        let places = day.places.map { place in
            MacActivityRow(time: place.arrivalDate.formatted(date: .omitted, time: .shortened), title: place.displayTitle, icon: "mappin.and.ellipse", details: place.departureDate.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Still here", metadata: place.comment ?? "Visit", selection: .place(place.id), sortDate: place.arrivalDate)
        }
        let moves = day.moves.map { move in
            MacActivityRow(time: move.timelineStartDate.formatted(date: .omitted, time: .shortened), title: move.transportMode.title, icon: move.transportMode.symbolName, details: "\(formatDistance(move.distanceMeters)) · \(formatDuration(move.timelineDuration))", metadata: move.comment ?? "\(move.samples.count) samples", selection: .move(move.id), sortDate: move.timelineStartDate)
        }
        return (places + moves).sorted { $0.sortDate < $1.sortDate }
    }
}

private struct MacActivityRow: Identifiable, Hashable {
    var id: MacSelection { selection }
    let time: String, title: String, icon: String, details: String, metadata: String
    let selection: MacSelection
    let sortDate: Date
}

private struct MacDayMap: View {
    let day: DayTimeline
    @Binding var camera: MapCameraPosition

    var body: some View {
        Map(position: $camera) {
            ForEach(day.places) { place in
                Annotation(place.displayTitle, coordinate: place.coordinate, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                }
            }
            ForEach(day.moves) { move in
                let route = RouteCoordinateStorage.decode(move.manualRouteCoordinatesData ?? move.routeCacheCoordinatesData)
                if route.count > 1 { MapPolyline(coordinates: route).stroke(routeColor(move.transportMode), lineWidth: 4) }
                else if let start = move.startPlace?.coordinate, let end = move.endPlace?.coordinate { MapPolyline(coordinates: [start, end]).stroke(routeColor(move.transportMode), style: StrokeStyle(lineWidth: 3, dash: [6, 5])) }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .overlay(alignment: .topLeading) {
            Label("\(day.places.count) places · \(day.moves.count) moves", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.caption.weight(.medium)).padding(8).background(.regularMaterial, in: Capsule()).padding(12)
        }
    }
}

private struct MacInspector: View {
    let selection: MacSelection?
    let timelines: [DayTimeline]

    private var selectedPlace: VisitPlace? { guard case let .place(id) = selection else { return nil }; return timelines.flatMap(\.places).first { $0.id == id } }
    private var selectedMove: MoveSegment? { guard case let .move(id) = selection else { return nil }; return timelines.flatMap(\.moves).first { $0.id == id } }
    private var selectedDay: DayTimeline? { guard case let .day(key) = selection else { return nil }; return timelines.first { $0.dayKey == key } }

    var body: some View {
        Group {
            if let selectedPlace { placeInspector(selectedPlace) }
            else if let selectedMove { moveInspector(selectedMove) }
            else if let selectedDay { dayInspector(selectedDay) }
            else { ContentUnavailableView("Nothing Selected", systemImage: "sidebar.right", description: Text("Select a day or activity to inspect its metadata.")) }
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dayInspector(_ day: DayTimeline) -> some View {
        Form {
            Section("Day") { LabeledContent("Date", value: day.dayStart.formatted(date: .long, time: .omitted)); LabeledContent("Day key", value: day.dayKey) }
            Section("Activity") { LabeledContent("Places", value: day.places.count.formatted()); LabeledContent("Moves", value: day.moves.count.formatted()); LabeledContent("Samples", value: day.samples.count.formatted()) }
            Section("Record") { LabeledContent("Created", value: day.createdAt.formatted(date: .abbreviated, time: .shortened)) }
        }
    }

    private func placeInspector(_ place: VisitPlace) -> some View {
        Form {
            Section("Place") { Text(place.displayTitle).font(.headline); LabeledContent("Arrived", value: place.arrivalDate.formatted(date: .long, time: .shortened)); if let departure = place.departureDate { LabeledContent("Departed", value: departure.formatted(date: .omitted, time: .shortened)) } }
            Section("Location") { LabeledContent("Latitude", value: place.latitude.formatted(.number.precision(.fractionLength(5)))); LabeledContent("Longitude", value: place.longitude.formatted(.number.precision(.fractionLength(5)))); LabeledContent("Accuracy", value: "±\(place.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))) m") }
            if let comment = place.comment, !comment.isEmpty { Section("Comment") { Text(comment) } }
            Section("Record") { LabeledContent("ID", value: place.id.uuidString) }
        }
    }

    private func moveInspector(_ move: MoveSegment) -> some View {
        Form {
            Section("Move") { Label(move.transportMode.title, systemImage: move.transportMode.symbolName).font(.headline); LabeledContent("Started", value: move.timelineStartDate.formatted(date: .long, time: .shortened)); LabeledContent("Duration", value: formatDuration(move.timelineDuration)); LabeledContent("Distance", value: formatDistance(move.distanceMeters)) }
            Section("Route") { LabeledContent("Samples", value: move.samples.count.formatted()); LabeledContent("Source", value: move.usesHealthWorkoutRoute ? "Health workout route" : move.usesHighAccuracyRouteTracking ? "Route tracking" : "Location history"); if let start = move.startPlace { LabeledContent("From", value: start.displayTitle) }; if let end = move.endPlace { LabeledContent("To", value: end.displayTitle) } }
            if let comment = move.comment, !comment.isEmpty { Section("Comment") { Text(comment) } }
            Section("Record") { LabeledContent("ID", value: move.id.uuidString) }
        }
    }
}

private func routeColor(_ mode: TransportMode) -> Color {
    switch mode { case .walking, .running: .green; case .cycling: .orange; case .train: .purple; case .plane: .pink; case .boat: .teal; case .stationary: .gray; default: .blue }
}

private func formatDistance(_ meters: Double) -> String { meters >= 1_000 ? "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km" : "\(meters.formatted(.number.precision(.fractionLength(0)))) m" }

private func formatDuration(_ duration: TimeInterval) -> String {
    let formatter = DateComponentsFormatter(); formatter.unitsStyle = .abbreviated; formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute] : [.minute]
    return formatter.string(from: duration) ?? "—"
}

private extension MKMapRect {
    static func bounding(coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        guard let first = coordinates.first else { return MKMapRect.world }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() { rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0))) }
        return rect.isNull || rect.isEmpty ? rect.insetBy(dx: -10_000, dy: -10_000) : rect.insetBy(dx: -max(rect.size.width * 0.15, 10_000), dy: -max(rect.size.height * 0.15, 10_000))
    }
}

extension View {
    func panelSurface() -> some View {
        padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
#endif
