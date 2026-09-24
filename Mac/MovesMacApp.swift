import CoreLocation
import ESADesignKit
import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

@MainActor
private final class MacRouteOpenRouter: ObservableObject {
    static let shared = MacRouteOpenRouter()

    @Published private(set) var revision = 0
    private var pendingURLs: [URL] = []
    private var failedFileNames: [String] = []
    private var recentlyReceivedAt: [String: Date] = [:]

    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let now = Date()
        recentlyReceivedAt = recentlyReceivedAt.filter {
            now.timeIntervalSince($0.value) < 2
        }

        for url in urls where url.isFileURL {
            let sourceIdentifier = url.standardizedFileURL.path
            guard recentlyReceivedAt[sourceIdentifier] == nil else { continue }
            recentlyReceivedAt[sourceIdentifier] = now
            if let stagedURL = RouteFileImporter.copyDroppedItem(at: url) {
                pendingURLs.append(stagedURL)
            } else {
                failedFileNames.append(url.lastPathComponent)
            }
        }
        revision &+= 1
    }

    func drain() -> (urls: [URL], failedFileNames: [String]) {
        defer {
            pendingURLs.removeAll()
            failedFileNames.removeAll()
        }
        return (pendingURLs, failedFileNames)
    }
}

@MainActor
private final class MovesMacAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MacRouteOpenRouter.shared.receive(urls)
    }
}

@main
struct MovesMacApp: App {
    private static let mainWindowID = "moves.main-window"
    private static let aboutWindowID = "moves.about-window"

    @NSApplicationDelegateAdaptor(MovesMacAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private static let cloudKitContainerIdentifier = "iCloud.de.holgerkrupp.Moves"
    private let modelContainer: ModelContainer
#if DEBUG
    private let demoModelContainer: ModelContainer
#endif
    @State private var isDemoMode = false
    @StateObject private var importCoordinator: ImportCoordinator
    @StateObject private var routeFileImporter: RouteFileImporter
    @StateObject private var importedRouteDataSummary: ImportedRouteDataSummaryStore
    @AppStorage(RouteFileImportPreferenceKey.showsMacMenuBarStatus)
    private var showsImportStatusInMenuBar = true

    init() {
        do {
            let container = try Self.makeModelContainer()
            let coordinator = ImportCoordinator()
            let importer = RouteFileImporter(
                modelContext: ModelContext(container),
                importCoordinator: coordinator
            )
            coordinator.attach(routeFileImporter: importer)

            modelContainer = container
#if DEBUG
            let demoContainer = try DemoDataSeeder.makeDemoModelContainer()
            DemoDataSeeder.seedIfNeeded(in: demoContainer)
            demoModelContainer = demoContainer
#endif
            _importCoordinator = StateObject(wrappedValue: coordinator)
            _routeFileImporter = StateObject(wrappedValue: importer)
            _importedRouteDataSummary = StateObject(
                wrappedValue: ImportedRouteDataSummaryStore(modelContainer: container)
            )
        } catch {
            fatalError("Could not create the Moves macOS model container: \(error)")
        }
    }

    static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([DayTimeline.self, VisitPlace.self, KnownLocation.self, MoveSegment.self, LocationSample.self, MovesDeviceProfile.self])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudKitContainerIdentifier))
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    var body: some Scene {
        WindowGroup("Moves", id: Self.mainWindowID) {
            MovesMacBrowser(
                importCoordinator: importCoordinator,
                importer: routeFileImporter,
                importedRouteDataSummary: importedRouteDataSummary,
                isDemoMode: $isDemoMode
            )
        }
#if DEBUG
            .modelContainer(isDemoMode ? demoModelContainer : modelContainer)
#else
            .modelContainer(modelContainer)
#endif
            .environmentObject(importCoordinator)
            .environmentObject(routeFileImporter)
            .defaultSize(width: 1_180, height: 760)
            .commands {
                CommandGroup(after: .windowList) {
                    Button("Open Moves") {
                        openWindow(id: Self.mainWindowID)
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }

                CommandGroup(replacing: .appInfo) {
                    Button("About Moves") {
                        openWindow(id: Self.aboutWindowID)
                    }
                }

                MovesMacCommands()
            }

        Settings {
            MovesMacSettingsView()
                .modelContainer(modelContainer)
                .environmentObject(importCoordinator)
        }
        .defaultSize(width: 880, height: 620)

        Window("About Moves", id: Self.aboutWindowID) {
            MovesMacAboutView()
        }
        .defaultSize(width: 420, height: 390)
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: importMenuBarInsertion) {
            MacImportMenuBarView(
                coordinator: importCoordinator,
                importer: routeFileImporter
            )
        } label: {
            MacImportMenuBarLabel(coordinator: importCoordinator)
        }
        .menuBarExtraStyle(.window)
    }

    private var importMenuBarInsertion: Binding<Bool> {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return .constant(false)
        }
        // MenuBarExtra writes equivalent insertion values back during every AppKit menu update on
        // macOS 27. Feeding those writes into AppStorage invalidates the complete app graph.
        return Binding(
            get: { showsImportStatusInMenuBar },
            set: { _ in }
        )
    }
}

private extension ImportQueueSnapshot {
    var menuBarImportJob: ImportJobRecord? {
        let visibleStates: Set<ImportJobState> = [
            .queued, .acquiring, .parsing, .importing, .postProcessing, .paused
        ]
        return jobs
            .filter { visibleStates.contains($0.state) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }
}

private struct MacImportMenuBarLabel: View {
    @ObservedObject var coordinator: ImportCoordinator

    var body: some View {
        let job = coordinator.snapshot.menuBarImportJob
        ImportCircularProgressView(
            progress: job?.counters.progress,
            isActive: job != nil && job?.state != .paused
        )
        .frame(width: 17, height: 17)
        .accessibilityLabel(job == nil ? "No active import" : "Route import progress")
    }
}

private struct MacImportMenuBarView: View {
    @ObservedObject var coordinator: ImportCoordinator
    @ObservedObject var importer: RouteFileImporter
    @State private var isConfirmingStop = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 14) {
                if let job = coordinator.snapshot.menuBarImportJob {
                    activeImport(job, now: timeline.date)
                } else {
                    idleView(now: timeline.date)
                }
            }
            .padding(16)
            .frame(width: 340)
        }
        .confirmationDialog(
            "Stop this import?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop Import", role: .destructive) {
                importer.cancel()
            }
            Button("Keep Importing", role: .cancel) {}
        } message: {
            Text("Progress for the current import will be discarded. Files already imported remain in your timeline.")
        }
    }

    @ViewBuilder
    private func activeImport(_ job: ImportJobRecord, now: Date) -> some View {
        HStack(spacing: 12) {
            ImportCircularProgressView(
                progress: job.counters.progress,
                isActive: job.state != .paused
            )
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(for: job))
                    .font(.headline)
                Text(progressDescription(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if let progress = job.counters.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
        }

        ProgressView(value: job.counters.progress ?? 0)

        HStack(alignment: .top, spacing: 20) {
            timeValue(title: "Current time", value: now.formatted(date: .omitted, time: .standard))
            timeValue(title: "Estimated end", value: estimatedEndDescription(for: job, now: now))
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            let files = job.upcomingFileNames()
            if files.isEmpty {
                Label("Discovering files…", systemImage: "folder.badge.gearshape")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(files.enumerated()), id: \.offset) { index, fileName in
                    HStack(spacing: 8) {
                        Image(systemName: index == 0 ? "play.circle.fill" : "doc")
                            .foregroundStyle(index == 0 ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text(fileName)
                            .font(index == 0 ? .subheadline.weight(.medium) : .subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(index == 0 ? "Current" : "Next")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                let additionalCount = max(
                    job.source.originalFileNames.count - job.counters.completedItemCount - files.count,
                    0
                )
                if additionalCount > 0 {
                    Text("+\(additionalCount.formatted()) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }

        HStack(spacing: 8) {
            Button {
                if job.state == .paused {
                    importer.resume()
                } else {
                    importer.pause()
                }
            } label: {
                Label(job.state == .paused ? "Resume" : "Pause", systemImage: job.state == .paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                isConfirmingStop = true
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func idleView(now: Date) -> some View {
        VStack(spacing: 12) {
            ImportCircularProgressView(progress: nil, isActive: false)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            Text("No active import")
                .font(.headline)
            Text(now.formatted(date: .omitted, time: .standard))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func timeValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusTitle(for job: ImportJobRecord) -> String {
        switch job.state {
        case .queued: "Waiting to import"
        case .acquiring: "Preparing files"
        case .parsing: "Reading route file"
        case .importing: "Importing routes"
        case .postProcessing: "Finishing import"
        case .paused: "Import paused"
        default: "Route import"
        }
    }

    private func progressDescription(for job: ImportJobRecord) -> String {
        guard job.counters.itemCount > 0 else { return importer.importProgressText }
        return "\(job.counters.completedItemCount.formatted()) of \(job.counters.itemCount.formatted()) files"
    }

    private func estimatedEndDescription(for job: ImportJobRecord, now: Date) -> String {
        guard job.state != .paused else { return "Paused" }
        guard let estimate = job.estimatedCompletionDate(at: now) else { return "Calculating…" }
        return estimate.formatted(
            date: Calendar.autoupdatingCurrent.isDate(estimate, inSameDayAs: now) ? .omitted : .abbreviated,
            time: .shortened
        )
    }
}

private enum MovesMacSettingsKey {
    static let hasCompletedOnboarding = "Moves.mac.hasCompletedOnboarding"
    static let showsInspector = "Moves.mac.showsInspector"
    static let showsLargeMapMarkers = "showBigMapMarkers"
    static let selectsLatestDay = "Moves.mac.selectsLatestDay"
    static let showsMapElevation = "Moves.mac.showsMapElevation"
    static let routeLineWidth = "Moves.mac.routeLineWidth"
    static let defaultImportMappingMode = "Moves.mac.defaultImportMappingMode"
    static let defaultImportTransportMode = "Moves.mac.defaultImportTransportMode"
    static let defaultImportExistingDataPolicy = "Moves.mac.defaultImportExistingDataPolicy"
    static let exportIncludesPlaces = "Moves.mac.exportIncludesPlaces"
    static let exportIncludesComments = "Moves.mac.exportIncludesComments"
}

private enum MacTimelineExportScope {
    case selectedDay
    case allDays
}

private enum MacTimelineExportFormat: CaseIterable, Hashable {
    case gpx
    case geoJSON
    case csv

    var title: String {
        switch self {
        case .gpx: "GPX"
        case .geoJSON: "GeoJSON"
        case .csv: "CSV"
        }
    }
}

private struct MovesMacCommandActions {
    let importRoutes: () -> Void
    let showImportQueue: () -> Void
    let showOnboarding: () -> Void
    let selectToday: () -> Void
    let selectOlderDay: () -> Void
    let selectNewerDay: () -> Void
    let showImportedData: () -> Void
    let showFailedImports: () -> Void
    let toggleInspector: () -> Void
    let exportTimeline: (MacTimelineExportFormat, MacTimelineExportScope) -> Void
    let toggleDemoMode: () -> Void
    let canSelectToday: Bool
    let canSelectOlderDay: Bool
    let canSelectNewerDay: Bool
    let canExportSelectedDay: Bool
    let canExportAllDays: Bool
    let isInspectorPresented: Bool
    let isDemoMode: Bool
}

private struct MovesMacCommandActionsKey: FocusedValueKey {
    typealias Value = MovesMacCommandActions
}

private extension FocusedValues {
    var movesMacCommandActions: MovesMacCommandActions? {
        get { self[MovesMacCommandActionsKey.self] }
        set { self[MovesMacCommandActionsKey.self] = newValue }
    }
}

private struct MovesMacCommands: Commands {
    @FocusedValue(\.movesMacCommandActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Route Files…") { actions?.importRoutes() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions == nil)

            Button("Show Import Queue") { actions?.showImportQueue() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        CommandGroup(after: .importExport) {
            Menu("Export Selected Day") {
                Button("GPX…") { actions?.exportTimeline(.gpx, .selectedDay) }
                Button("GeoJSON…") { actions?.exportTimeline(.geoJSON, .selectedDay) }
            }
            .disabled(actions?.canExportSelectedDay != true)

            Menu("Export All History") {
                Button("GPX…") { actions?.exportTimeline(.gpx, .allDays) }
                Button("GeoJSON…") { actions?.exportTimeline(.geoJSON, .allDays) }
                Button("CSV…") { actions?.exportTimeline(.csv, .allDays) }
            }
            .disabled(actions?.canExportAllDays != true)
        }

        CommandGroup(after: .help) {
            Button("Welcome to Moves") { actions?.showOnboarding() }
                .disabled(actions == nil)
        }

        CommandMenu("History") {
            Button("Today") { actions?.selectToday() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions?.canSelectToday != true)

            Divider()

            Button("Previous Day") { actions?.selectOlderDay() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.canSelectOlderDay != true)

            Button("Next Day") { actions?.selectNewerDay() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions?.canSelectNewerDay != true)

            Divider()

            Button("Imported Route Data") { actions?.showImportedData() }
                .disabled(actions == nil)

            Button("Failed Imports") { actions?.showFailedImports() }
                .disabled(actions == nil)
        }

#if DEBUG
        CommandMenu("Developer") {
            Button {
                actions?.toggleDemoMode()
            } label: {
                Label(
                    actions?.isDemoMode == true ? "Disable Demo Mode" : "Enable Demo Mode",
                    systemImage: actions?.isDemoMode == true ? "checkmark.circle.fill" : "play.circle"
                )
            }
            .disabled(actions == nil)
        }
#endif

        CommandGroup(after: .sidebar) {
            Button(actions?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions == nil)
        }
    }
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

private struct MacImportRequest: Identifiable {
    enum Source: Equatable {
        case picker
        case dropped
        case opened
    }

    let id = UUID()
    let source: Source
    let urls: [URL]

    var actionTitle: String {
        switch source {
        case .picker:
            "Choose files, folder, or ZIP"
        case .dropped:
            urls.count == 1 ? "Import Dropped File" : "Import Dropped Items"
        case .opened:
            urls.count == 1 ? "Import Opened File" : "Import Opened Files"
        }
    }

    var actionSystemImage: String {
        source == .picker ? "folder.badge.plus" : "square.and.arrow.down"
    }
}

private struct MovesMacOnboardingPage: Identifiable {
    let id: String
    let title: String
    let message: String
    let details: String
    let systemImage: String
    let appStoreURL: URL?
}

private struct MovesMacOnboardingView: View {
    let onComplete: () -> Void

    @State private var selectedPage = 0

    private let pages = [
        MovesMacOnboardingPage(
            id: "iphone",
            title: "Your timeline starts on iPhone",
            message: "Moves for iPhone records the places you visit and the trips between them.",
            details: "Keep Moves running in the background for low-power daily tracking. Your timeline is stored privately and syncs through iCloud, so it can appear here on your Mac.",
            systemImage: "iphone",
            appStoreURL: URL(string: "https://apps.apple.com/de/app/moves-daily-log/id6762114616?l=en-GB")
        ),
        MovesMacOnboardingPage(
            id: "import",
            title: "Bring in routes from anywhere",
            message: "Add route history from other apps and services with a file import.",
            details: "Choose Import Route Files… from the File menu, drag files onto this window, or open them with Moves. Folders, ZIP archives, JSON, GPX, TCX, KML, and GeoJSON files are supported.",
            systemImage: "square.and.arrow.down",
            appStoreURL: nil
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Welcome to Moves", systemImage: "mappin.and.ellipse")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button("Skip") {
                    onComplete()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            pageView(for: pages[selectedPage])
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(selectedPage + 1) of \(pages.count)")

            HStack {
                if selectedPage > 0 {
                    Button("Back") {
                        withAnimation { selectedPage -= 1 }
                    }
                }

                Spacer()

                Button(selectedPage == pages.count - 1 ? "Start using Moves" : "Continue") {
                    if selectedPage == pages.count - 1 {
                        onComplete()
                    } else {
                        withAnimation { selectedPage += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(28)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 500, idealHeight: 540)
    }

    private func pageView(for page: MovesMacOnboardingPage) -> some View {
        VStack(spacing: 20) {
            Image(systemName: page.systemImage)
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 116, height: 116)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(spacing: 10) {
                Text(page.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(page.message)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)

                Text(page.details)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)

                if let appStoreURL = page.appStoreURL {
                    Link("Moves - daily log on the App Store", destination: appStoreURL)
                        .font(.body.weight(.medium))
                }
            }
        }
        .padding(.horizontal, 28)
    }
}

private enum MovesMacSettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case importDefaults
    case export
    case data
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .importDefaults: "Import"
        case .export: "Export"
        case .data: "Data"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .importDefaults: "square.and.arrow.down"
        case .export: "square.and.arrow.up"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    var searchTerms: String {
        switch self {
        case .general: "workspace window inspector latest day startup"
        case .appearance: "map marker route line elevation"
        case .importDefaults: "route mapping transport overlap existing data progress menu bar pause stop"
        case .export: "gpx geojson csv places comments"
        case .data: "timeline samples moves imports recovery storage"
        case .about: "version privacy application"
        }
    }
}

private struct MovesMacSettingsView: View {
    @EnvironmentObject private var importCoordinator: ImportCoordinator
    @Query private var samples: [LocationSample]
    @Query private var moves: [MoveSegment]
    @Query private var timelines: [DayTimeline]

    @AppStorage(MovesMacSettingsKey.showsInspector) private var showsInspector = true
    @AppStorage(MovesMacSettingsKey.selectsLatestDay) private var selectsLatestDay = true
    @AppStorage(MovesMacSettingsKey.showsLargeMapMarkers) private var showsLargeMapMarkers = false
    @AppStorage(MovesMacSettingsKey.showsMapElevation) private var showsMapElevation = true
    @AppStorage(MovesMacSettingsKey.routeLineWidth) private var routeLineWidth = 4.0
    @AppStorage(MovesMacSettingsKey.defaultImportMappingMode) private var defaultMappingMode = RouteFileImportMappingMode.automatic.rawValue
    @AppStorage(MovesMacSettingsKey.defaultImportTransportMode) private var defaultTransportMode = TransportMode.unknown.rawValue
    @AppStorage(MovesMacSettingsKey.defaultImportExistingDataPolicy) private var defaultExistingDataPolicy = RouteFileExistingDataPolicy.skipDate.rawValue
    @AppStorage(RouteFileImportPreferenceKey.showsMacMenuBarStatus) private var showsImportStatusInMenuBar = true
    @AppStorage(MovesMacSettingsKey.exportIncludesPlaces) private var exportIncludesPlaces = true
    @AppStorage(MovesMacSettingsKey.exportIncludesComments) private var exportIncludesComments = true

    @State private var selection: MovesMacSettingsSection? = .general
    @State private var searchText = ""

    private var filteredSections: [MovesMacSettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MovesMacSettingsSection.allCases }
        return MovesMacSettingsSection.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.searchTerms.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Moves") {
                    ForEach(filteredSections) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .overlay {
                if filteredSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        } detail: {
            NavigationStack {
                detail(for: selection ?? .general)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private func detail(for section: MovesMacSettingsSection) -> some View {
        switch section {
        case .general:
            settingsForm(title: section.title) {
                Section("Workspace") {
                    Toggle("Show inspector", isOn: $showsInspector)
                    Toggle("Select the latest recorded day when opening a window", isOn: $selectsLatestDay)
                }

                Section {
                    Text("Changes apply to open Moves windows and are remembered the next time the app starts.")
                        .foregroundStyle(.secondary)
                }
            }

        case .appearance:
            settingsForm(title: section.title) {
                Section("Map") {
                    Toggle("Show large place markers", isOn: $showsLargeMapMarkers)
                    Toggle("Show realistic map elevation", isOn: $showsMapElevation)
                    LabeledContent("Route line width") {
                        HStack {
                            Slider(value: $routeLineWidth, in: 2...8, step: 1)
                                .frame(width: 180)
                            Text(routeLineWidth, format: .number.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 18, alignment: .trailing)
                        }
                    }
                }

                Section {
                    Text("These options affect day maps throughout the macOS app.")
                        .foregroundStyle(.secondary)
                }
            }

        case .importDefaults:
            settingsForm(title: section.title) {
                Section("Progress") {
                    Toggle("Show import status in the menu bar", isOn: $showsImportStatusInMenuBar)
                    Text("The menu bar item shows the current and upcoming files, progress, the estimated completion time, and controls to pause or stop an import.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Route Mapping") {
                    Picker("Default mapping", selection: $defaultMappingMode) {
                        ForEach(RouteFileImportMappingMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }

                    if defaultMappingMode == RouteFileImportMappingMode.dedicatedTransport.rawValue {
                        Picker("Transport mode", selection: $defaultTransportMode) {
                            ForEach(TransportMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.symbolName).tag(mode.rawValue)
                            }
                        }
                    }
                }

                Section("Existing Timeline Data") {
                    Picker("When imported times overlap", selection: $defaultExistingDataPolicy) {
                        ForEach(RouteFileExistingDataPolicy.allCases) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }
                }

                Section {
                    Text("These defaults preselect the options shown when you import route files. You can still change them for each import.")
                        .foregroundStyle(.secondary)
                }
            }

        case .export:
            settingsForm(title: section.title) {
                Section("Exported Content") {
                    Toggle("Include saved places", isOn: $exportIncludesPlaces)
                    Toggle("Include comments", isOn: $exportIncludesComments)
                }

                Section("Formats") {
                    LabeledContent("GPX", value: "Places and route tracks")
                    LabeledContent("GeoJSON", value: "Point and line features")
                    LabeledContent("CSV", value: "Places and moves table")
                }

                Section {
                    Text("Choose Export Selected Day or Export All History from the File menu to create a file.")
                        .foregroundStyle(.secondary)
                }
            }

        case .data:
            settingsForm(title: section.title) {
                Section("Timeline") {
                    LabeledContent("Recorded days", value: timelines.filter(\.hasRecordedActivity).count.formatted())
                    LabeledContent("Moves", value: moves.count.formatted())
                    LabeledContent("Location samples", value: samples.count.formatted())
                }

                Section("Imports") {
                    LabeledContent("Imported moves", value: moves.filter { $0.samples.contains { $0.source == .fileRouteImport } }.count.formatted())
                    LabeledContent("Imported samples", value: samples.filter { $0.source == .fileRouteImport }.count.formatted())
                    LabeledContent("Active jobs", value: importCoordinator.snapshot.unfinishedJobs.count.formatted())
                    LabeledContent("Needs attention", value: importCoordinator.unresolvedRecoveryCount.formatted())
                }

                Section {
                    Text("Moves stores timeline data in your private iCloud container and keeps imported-route recovery information locally.")
                        .foregroundStyle(.secondary)
                }
            }

        case .about:
            settingsForm(title: section.title) {
                Section {
                    HStack(spacing: 16) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Moves").font(.title2.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 8)

                    CreatedByView(
                        gitURL: URL(string: "https://github.com/holgerkrupp/Moves")
                    )
                    .padding(.vertical, 12)
                }

                Section("Privacy") {
                    Text("Your location history stays in your private app data and iCloud container unless you explicitly import, export, or configure an external service.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func settingsForm<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }

}

private struct MovesMacAboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Moves")
                .font(.title.weight(.semibold))

            CreatedByView(
                gitURL: URL(string: "https://github.com/holgerkrupp/Moves")
            )

            Text("Your location history stays in your private app data and iCloud container unless you explicitly import, export, or configure an external service.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 420)
    }
}

private struct MovesMacBrowser: View {
    @ObservedObject private var importCoordinator: ImportCoordinator
    @ObservedObject private var externalRouteOpenRouter = MacRouteOpenRouter.shared
    @ObservedObject private var importer: RouteFileImporter
    @ObservedObject private var importedRouteDataSummary: ImportedRouteDataSummaryStore
    @Binding private var isDemoMode: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Query(sort: \DayTimeline.dayStart, order: .reverse) private var timelines: [DayTimeline]
    @State private var selection: MacSelection?
    @AppStorage(MovesMacSettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var isInspectorPresented: Bool
    @AppStorage(MovesMacSettingsKey.selectsLatestDay) private var selectsLatestDay = true
    @AppStorage(MovesMacSettingsKey.defaultImportMappingMode) private var defaultImportMappingMode = RouteFileImportMappingMode.automatic.rawValue
    @AppStorage(MovesMacSettingsKey.defaultImportTransportMode) private var defaultImportTransportMode = TransportMode.unknown.rawValue
    @AppStorage(MovesMacSettingsKey.defaultImportExistingDataPolicy) private var defaultImportExistingDataPolicy = RouteFileExistingDataPolicy.skipDate.rawValue
    @AppStorage(MovesMacSettingsKey.exportIncludesPlaces) private var exportIncludesPlaces = true
    @AppStorage(MovesMacSettingsKey.exportIncludesComments) private var exportIncludesComments = true
    @State private var searchText = ""
    @State private var isShowingDatePicker = false
    @State private var isShowingOnboarding = false
    @State private var isShowingImportQueue = false
    @State private var importRequest: MacImportRequest?
    @State private var isShowingFileImporter = false
    @State private var importConfiguration = RouteFileImportConfiguration()
    @State private var isExporting = false
    @State private var exportDocument: MacTimelineExportDocument?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "moves-export"
    @State private var exportMessage = ""
    @State private var isShowingExportMessage = false
    @State private var importErrorMessage: String?
    @State private var isConfirmingEntryDeletion = false
    @State private var isConfirmingDayDeletion = false
    @State private var deletionErrorMessage: String?

    init(
        importCoordinator: ImportCoordinator,
        importer: RouteFileImporter,
        importedRouteDataSummary: ImportedRouteDataSummaryStore,
        isDemoMode: Binding<Bool>
    ) {
        _importCoordinator = ObservedObject(wrappedValue: importCoordinator)
        _importer = ObservedObject(wrappedValue: importer)
        _importedRouteDataSummary = ObservedObject(wrappedValue: importedRouteDataSummary)
        _isDemoMode = isDemoMode
        _isInspectorPresented = State(
            initialValue: UserDefaults.standard.object(forKey: MovesMacSettingsKey.showsInspector) as? Bool ?? true
        )
    }

    private var importedDataSummary: ImportedRouteDataSummary {
        isDemoMode ? .empty : importedRouteDataSummary.summary
    }
    /// The query already contains only lightweight day records. Do not filter it in `body`: even
    /// reading one managed property per item becomes expensive when SwiftUI evaluates this getter
    /// repeatedly while constructing a large sidebar.
    private var recordedTimelines: [DayTimeline] { timelines }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var years: [MacYear] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: sidebarTimelines) { calendar.component(.year, from: $0.dayStart) }
        return grouped.keys.sorted(by: >).map { year in
            let byMonth = Dictionary(grouping: grouped[year, default: []]) { calendar.component(.month, from: $0.dayStart) }
            return MacYear(year: year, months: byMonth.keys.sorted(by: >).map { month in
                MacMonth(year: year, month: month, days: byMonth[month, default: []].sorted { $0.dayStart > $1.dayStart })
            })
        }
    }

    private var recentItems: [MacRecentItem] {
        sidebarTimelines.prefix(8).map { timeline in
            MacRecentItem(id: "day-\(timeline.dayKey)", title: timeline.dayStart.formatted(date: .abbreviated, time: .omitted), subtitle: summary(for: timeline), icon: "calendar", selection: .day(timeline.dayKey))
        }
    }

    private var filteredTimelines: [DayTimeline] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordedTimelines }
        return recordedTimelines.filter { timeline in
            timeline.dayStart.formatted(date: .long, time: .omitted).localizedCaseInsensitiveContains(query) ||
            timeline.places.contains { $0.matches(searchQuery: query) } ||
            timeline.moves.contains { $0.transportMode.title.localizedCaseInsensitiveContains(query) }
        }
    }

    private var sidebarTimelines: [DayTimeline] {
        isSearching ? filteredTimelines : recordedTimelines
    }

    private var selectedTimelineIndex: Int? {
        switch selection {
        case .day(let key):
            recordedTimelines.firstIndex { $0.dayKey == key }
        case .place(let id):
            recordedTimelines.firstIndex { timeline in timeline.places.contains { $0.id == id } }
        case .move(let id):
            recordedTimelines.firstIndex { timeline in timeline.moves.contains { $0.id == id } }
        default:
            nil
        }
    }

    private var todayTimeline: DayTimeline? {
        recordedTimelines.first { Calendar.autoupdatingCurrent.isDateInToday($0.dayStart) }
    }

    private var selectedTimelineForExport: DayTimeline? {
        if let selectedTimelineIndex {
            return recordedTimelines[selectedTimelineIndex]
        }
        return selection == nil ? recordedTimelines.first : nil
    }

    private var canSelectOlderDay: Bool {
        guard let index = selectedTimelineIndex else { return !recordedTimelines.isEmpty }
        return recordedTimelines.indices.contains(index + 1)
    }

    private var canSelectNewerDay: Bool {
        guard let index = selectedTimelineIndex else { return false }
        return recordedTimelines.indices.contains(index - 1)
    }

    var body: some View {
        NavigationSplitView { sidebar } detail: {
            switch selection {
            case .imported:
                ImportedRouteDataView(modelContext: modelContext)
            case .recovery:
                FailedRouteImportsView(importer: importer)
            default:
                MacWorkspace(
                    timelines: recordedTimelines,
                    selection: $selection,
                    searchText: searchText,
                    exportActivity: exportActivity
                )
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search places, moves, or dates")
        .inspector(isPresented: inspectorPresentation) {
            MacInspector(
                selection: selection,
                timelines: timelines,
                requestEntryDeletion: { isConfirmingEntryDeletion = true },
                requestDayDeletion: { isConfirmingDayDeletion = true }
            )
                .inspectorColumnWidth(min: 230, ideal: 280, max: 360)
        }
        .onChange(of: timelines) { _, current in
            if case let .day(key) = selection,
               !current.contains(where: { $0.dayKey == key }) {
                selection = nil
            }
            if selection == nil,
               selectsLatestDay,
               let latest = current.first {
                selection = .day(latest.dayKey)
            }
        }
        .onAppear {
            modelContext.undoManager = undoManager
            if selection == nil, selectsLatestDay, let latest = recordedTimelines.first {
                selection = .day(latest.dayKey)
            }
            if !hasCompletedOnboarding {
                isShowingOnboarding = true
            }
        }
        .task {
            guard importedRouteDataSummary.daySummaries.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            importedRouteDataSummary.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    isShowingDatePicker.toggle()
                } label: {
                    Label(datePickerToolbarTitle, systemImage: "calendar")
                }
                .help("Jump to Date")
                .disabled(recordedTimelines.isEmpty)
                .popover(isPresented: $isShowingDatePicker, arrowEdge: .bottom) {
                    MovesJumpToDateView(
                        dayTimelines: recordedTimelines.sorted { $0.dayStart < $1.dayStart },
                        selectedDate: selectedTimelineForExport?.dayStart ?? .now,
                        onSelectDate: jumpToDate,
                        onDismiss: { isShowingDatePicker = false }
                    )
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ImportQueueToolbarButton(
                    coordinator: importCoordinator,
                    isPresented: $isShowingImportQueue
                )

                Button {
                    toggleInspector()
                } label: {
                    Label(
                        isInspectorPresented ? "Hide Inspector" : "Show Inspector",
                        systemImage: "sidebar.right"
                    )
                }
                .help(isInspectorPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            }

        }
        .focusedSceneValue(
            \.movesMacCommandActions,
            MovesMacCommandActions(
                importRoutes: beginImport,
                showImportQueue: { isShowingImportQueue = true },
                showOnboarding: { isShowingOnboarding = true },
                selectToday: selectToday,
                selectOlderDay: selectOlderDay,
                selectNewerDay: selectNewerDay,
                showImportedData: { selection = .imported },
                showFailedImports: { selection = .recovery },
                toggleInspector: toggleInspector,
                exportTimeline: exportTimeline,
                toggleDemoMode: { isDemoMode.toggle() },
                canSelectToday: todayTimeline != nil,
                canSelectOlderDay: canSelectOlderDay,
                canSelectNewerDay: canSelectNewerDay,
                canExportSelectedDay: selectedTimelineForExport != nil,
                canExportAllDays: !recordedTimelines.isEmpty,
                isInspectorPresented: isInspectorPresented,
                isDemoMode: isDemoMode
            )
        )
        .confirmationDialog("Delete Entry?", isPresented: $isConfirmingEntryDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteSelectedEntry)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected entry from the timeline. You can undo the deletion afterwards.")
        }
        .confirmationDialog("Delete Day?", isPresented: $isConfirmingDayDeletion, titleVisibility: .visible) {
            Button("Delete Day", role: .destructive, action: deleteSelectedDay)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all places, moves, and location samples for the selected day. You can undo the deletion afterwards.")
        }
        .alert(
            "Could Not Delete Data",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deletionErrorMessage = nil }
        } message: {
            Text(deletionErrorMessage ?? "The selected timeline data could not be deleted.")
        }
        .popover(isPresented: $isShowingImportQueue) {
            ImportQueueView(coordinator: importCoordinator)
                .frame(minWidth: 420, minHeight: 420)
        }
        .sheet(isPresented: $isShowingOnboarding) {
            MovesMacOnboardingView {
                hasCompletedOnboarding = true
                isShowingOnboarding = false
            }
        }
        .sheet(item: $importRequest) { request in
            VStack(spacing: 0) {
                if request.source != .picker {
                    Label(
                        request.urls.count == 1
                            ? request.urls[0].lastPathComponent
                            : "\(request.urls.count) items ready to import",
                        systemImage: "doc.badge.arrow.up"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    Divider()
                }

                RouteFileImportOptionsView(
                    configuration: $importConfiguration,
                    actionTitle: request.actionTitle,
                    actionSystemImage: request.actionSystemImage
                ) {
                    importRequest = nil
                    Task { @MainActor in
                        await Task.yield()
                        if request.source == .picker {
                            isShowingFileImporter = true
                        } else {
                            enqueueRouteFiles(request.urls)
                        }
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 600)
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: RouteFileImportContentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                enqueueRouteFiles(urls)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
        // AppKit's delegate is the reliable native-macOS document-open path. Keep the
        // SwiftUI callback as a fallback for launches SwiftUI routes to the scene.
        .onOpenURL { externalRouteOpenRouter.receive([$0]) }
        .dropDestination(for: RouteFileDropItem.self) { items, _ in
            prepareExternalImport(items.map(\.url), source: .dropped)
        }
        .onAppear(perform: consumeExternallyOpenedRouteFiles)
        .onChange(of: externalRouteOpenRouter.revision) { _, _ in
            consumeExternallyOpenedRouteFiles()
        }
        .alert(
            "Couldn’t Import Route Files",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "The selected files could not be opened.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success(let url):
                exportMessage = "Exported to \(url.lastPathComponent)."
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

    private func beginImport() {
        importConfiguration = defaultImportConfiguration
        isShowingImportQueue = false
        importRequest = MacImportRequest(source: .picker, urls: [])
    }

    private func exportTimeline(_ format: MacTimelineExportFormat, scope: MacTimelineExportScope) {
        let days: [DayTimeline]
        let fileStem: String

        switch scope {
        case .selectedDay:
            guard let day = selectedTimelineForExport else {
                exportMessage = "Select a day before exporting."
                isShowingExportMessage = true
                return
            }
            days = [day]
            fileStem = "moves-\(day.dayKey)"
        case .allDays:
            days = recordedTimelines
            fileStem = "moves-all-history"
        }

        guard let payload = MacTimelineExporter.makePayload(
            days: days,
            format: format,
            fileStem: fileStem,
            includesPlaces: exportIncludesPlaces,
            includesComments: exportIncludesComments
        ) else {
            exportMessage = "There is no timeline data available for this export."
            isShowingExportMessage = true
            return
        }

        exportDocument = MacTimelineExportDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isExporting = true
    }

    private func exportActivity(_ selection: MacSelection, _ format: MacTimelineExportFormat) {
        guard let day = selectedDay(for: selection) else { return }
        let payload: MacTimelineExportPayload?

        switch selection {
        case .move(let id):
            payload = day.moves.first(where: { $0.id == id }).flatMap {
                MacTimelineExporter.makePayload(move: $0, format: format, fileStem: "moves-\(day.dayKey)-\($0.transportMode.rawValue)")
            }
        case .place(let id):
            payload = day.places.first(where: { $0.id == id }).flatMap {
                MacTimelineExporter.makePayload(place: $0, format: format, fileStem: "moves-\(day.dayKey)-place")
            }
        default:
            payload = nil
        }

        guard let payload else { return }
        exportDocument = MacTimelineExportDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isExporting = true
    }

    private func exportDay(_ day: DayTimeline, format: MacTimelineExportFormat) {
        guard let payload = MacTimelineExporter.makePayload(
            days: [day],
            format: format,
            fileStem: "moves-\(day.dayKey)",
            includesPlaces: exportIncludesPlaces,
            includesComments: exportIncludesComments
        ) else { return }

        exportDocument = MacTimelineExportDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isExporting = true
    }

    private func selectedDay(for selection: MacSelection) -> DayTimeline? {
        switch selection {
        case .day(let key): timelines.first { $0.dayKey == key }
        case .place(let id): timelines.first { $0.places.contains { $0.id == id } }
        case .move(let id): timelines.first { $0.moves.contains { $0.id == id } }
        default: nil
        }
    }

    private func enqueueRouteFiles(_ urls: [URL]) {
        guard !urls.isEmpty else {
            importErrorMessage = "No route files were selected."
            return
        }
        guard importCoordinator.enqueueRouteFiles(urls, configuration: importConfiguration) else {
            importErrorMessage = importCoordinator.lastErrorMessage ?? "The route-file importer is unavailable."
            return
        }
        isShowingImportQueue = true
    }

    @discardableResult
    private func prepareExternalImport(_ urls: [URL], source: MacImportRequest.Source) -> Bool {
        guard !urls.isEmpty else { return false }
        importConfiguration = defaultImportConfiguration
        isShowingImportQueue = false
        importRequest = MacImportRequest(source: source, urls: urls)
        return true
    }

    private var defaultImportConfiguration: RouteFileImportConfiguration {
        RouteFileImportConfiguration(
            mappingMode: RouteFileImportMappingMode(rawValue: defaultImportMappingMode) ?? .automatic,
            dedicatedTransportMode: TransportMode(rawValue: defaultImportTransportMode) ?? .unknown,
            existingDataPolicy: RouteFileExistingDataPolicy(rawValue: defaultImportExistingDataPolicy) ?? .skipDate
        )
    }

    private func consumeExternallyOpenedRouteFiles() {
        let batch = externalRouteOpenRouter.drain()
        if !batch.urls.isEmpty {
            prepareExternalImport(batch.urls, source: .opened)
        }
        if !batch.failedFileNames.isEmpty {
            importErrorMessage = batch.failedFileNames.count == 1
                ? "\(batch.failedFileNames[0]) could not be opened."
                : "\(batch.failedFileNames.count) route files could not be opened."
        }
    }

    private func selectToday() {
        guard let todayTimeline else { return }
        select(timeline: todayTimeline)
    }

    private func selectOlderDay() {
        let index = selectedTimelineIndex ?? -1
        guard recordedTimelines.indices.contains(index + 1) else { return }
        select(timeline: recordedTimelines[index + 1])
    }

    private func selectNewerDay() {
        guard let index = selectedTimelineIndex,
              recordedTimelines.indices.contains(index - 1) else { return }
        select(timeline: recordedTimelines[index - 1])
    }

    private func select(timeline: DayTimeline) {
        searchText = ""
        selection = .day(timeline.dayKey)
    }

    private var datePickerToolbarTitle: String {
        selectedTimelineForExport?.dayStart.formatted(.dateTime.month(.abbreviated).day()) ?? "Jump to Date"
    }

    private func jumpToDate(_ date: Date) {
        guard !recordedTimelines.isEmpty else { return }

        let calendar = Calendar.autoupdatingCurrent
        let targetStart = calendar.startOfDay(for: date)
        guard let closest = recordedTimelines.min(by: { lhs, rhs in
            let lhsDistance = abs(calendar.startOfDay(for: lhs.dayStart).timeIntervalSince(targetStart))
            let rhsDistance = abs(calendar.startOfDay(for: rhs.dayStart).timeIntervalSince(targetStart))
            return lhsDistance < rhsDistance
        }) else { return }

        select(timeline: closest)
    }

    private var selectedDayForDeletion: DayTimeline? {
        switch selection {
        case .day(let key):
            timelines.first { $0.dayKey == key }
        case .place(let id):
            timelines.first { $0.places.contains { $0.id == id } }
        case .move(let id):
            timelines.first { $0.moves.contains { $0.id == id } }
        default:
            nil
        }
    }

    private func deleteSelectedEntry() {
        guard let selectedDay = selectedDayForDeletion else { return }

        do {
            switch selection {
            case .place(let id):
                guard let place = selectedDay.places.first(where: { $0.id == id }) else { return }
                try TimelineDeletion.delete(place: place, in: modelContext, undoManager: undoManager)
            case .move(let id):
                guard let move = selectedDay.moves.first(where: { $0.id == id }) else { return }
                try TimelineDeletion.delete(move: move, in: modelContext, undoManager: undoManager)
            default:
                return
            }
            selection = .day(selectedDay.dayKey)
        } catch {
            deletionErrorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedDay() {
        guard let selectedDay = selectedDayForDeletion else { return }

        do {
            try TimelineDeletion.delete(day: selectedDay, in: modelContext, undoManager: undoManager)
            selection = nil
        } catch {
            deletionErrorMessage = error.localizedDescription
        }
    }


    private var sidebar: some View {
        List(selection: $selection) {
            if isSearching {
                Section("Search Results") {
                    ForEach(filteredTimelines) { timeline in
                        MacSidebarRow(
                            title: timeline.dayStart.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                            subtitle: summary(for: timeline),
                            systemImage: "calendar.day.timeline.left"
                        )
                        .tag(MacSelection.day(timeline.dayKey))
                    }
                }
            } else {
                Section("Library") {
                    MacSidebarRow(
                        title: "Imported",
                        subtitle: "\(importedDataSummary.moveCount) routes · \(importedDataSummary.sampleCount) samples",
                        systemImage: "arrow.down.to.line.compact"
                    )
                        .tag(MacSelection.imported)
                    MacSidebarRow(title: "Failed Imports", subtitle: recoverySubtitle, systemImage: "exclamationmark.triangle")
                        .tag(MacSelection.recovery)
                }
                Section("Recent") {
                    if recentItems.isEmpty { Text("No recorded days yet").foregroundStyle(.secondary) }
                    else {
                        ForEach(recentItems) { item in
                            MacSidebarRow(title: item.title, subtitle: item.subtitle, systemImage: item.icon)
                                .tag(item.selection)
                        }
                    }
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
        }
        .navigationTitle("Moves")
        .navigationSplitViewColumnWidth(min: 230, ideal: 285, max: 360)
        .contextMenu(forSelectionType: MacSelection.self) { selectedItems in
            if let selection = selectedItems.first,
               case let .day(dayKey) = selection,
               let day = recordedTimelines.first(where: { $0.dayKey == dayKey }) {
                ForEach(MacTimelineExportFormat.allCases, id: \.self) { format in
                    Button("Export \(format.title)", systemImage: "doc.badge.arrow.up") {
                        exportDay(day, format: format)
                    }
                }
                Divider()
                Button("Delete Day", systemImage: "trash", role: .destructive) {
                    self.selection = selection
                    isConfirmingDayDeletion = true
                }
            }
        }
        .overlay {
            if isSearching && filteredTimelines.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if recordedTimelines.isEmpty && importedDataSummary.sampleCount == 0 {
                ContentUnavailableView("No History", systemImage: "map", description: Text("Timeline data shared through your private iCloud container will appear here."))
            }
        }
    }

    private var recoverySubtitle: String {
        let count = importCoordinator.unresolvedRecoveryCount
        guard count > 0 else { return "All imports resolved" }
        let missing = importCoordinator.missingInformationCount
        return missing == count ? "\(count) missing information" : "\(count) unresolved · \(missing) missing information"
    }

    /// `inspector(isPresented:)` alternates writes to its presentation binding during layout on
    /// macOS 27. Accepting those writes invalidates the complete navigation hierarchy in a tight
    /// loop. Treat the binding as an input and let only explicit app actions change the state.
    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { isInspectorPresented },
            set: { _ in }
        )
    }

    private func toggleInspector() {
        isInspectorPresented.toggle()
        UserDefaults.standard.set(isInspectorPresented, forKey: MovesMacSettingsKey.showsInspector)
    }

    private func summary(for timeline: DayTimeline) -> String {
        guard let summary = importedRouteDataSummary.daySummaries[timeline.dayKey] else {
            return "Calculating in background…"
        }
        return "\(summary.placeCount) places · \(summary.moveCount) moves · \(summary.sampleCount) samples"
    }

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
    let exportActivity: (MacSelection, MacTimelineExportFormat) -> Void

    private var selectedDay: DayTimeline? {
        if case let .day(key) = selection { return timelines.first { $0.dayKey == key } }
        if case let .place(id) = selection { return timelines.first { $0.places.contains { $0.id == id } } }
        if case let .move(id) = selection { return timelines.first { $0.moves.contains { $0.id == id } } }
        return timelines.first
    }

    var body: some View {
        workspaceContent
        .navigationTitle(selectedDay?.dayStart.formatted(date: .long, time: .omitted) ?? "History")
        .toolbar { ToolbarItem(placement: .primaryAction) { if !searchText.isEmpty { Text("Filtered").font(.caption).foregroundStyle(.secondary) } } }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if let selectedDay {
            MacDayWorkspace(day: selectedDay, selection: $selection, exportActivity: exportActivity)
        } else {
            ContentUnavailableView("Select a day", systemImage: "calendar", description: Text("Choose a day from the sidebar to browse your location history."))
        }
    }

}

private struct MacDayWorkspace: View {
    let day: DayTimeline
    @Binding var selection: MacSelection?
    let exportActivity: (MacSelection, MacTimelineExportFormat) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    private var coordinates: [CLLocationCoordinate2D] {
        day.places.map(\.coordinate) + day.samples.map(\.coordinate) + day.moves.flatMap { RouteCoordinateStorage.decode($0.manualRouteCoordinatesData ?? $0.routeCacheCoordinatesData) }
    }

    private var initialMapRect: MKMapRect? {
        guard !coordinates.isEmpty else { return nil }
        return .bounding(coordinates: coordinates)
    }

    private var cameraRefreshKey: String {
        let coordinateKey = coordinates.map { "\($0.latitude):\($0.longitude)" }.joined(separator: "|")
        return "\(day.dayKey)|\(coordinateKey)"
    }

    var body: some View {
        VStack(spacing: 0) {
            MacDayMap(day: day, initialVisibleRect: initialMapRect)
                .id(cameraRefreshKey)
                .frame(minHeight: 260, idealHeight: 390, maxHeight: .infinity)
            Divider()
            activityList
        }
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
            .contextMenu(forSelectionType: MacSelection.self) { selectedItems in
                if let selection = selectedItems.first {
                    activityContextMenu(for: selection)
                }
            }
    }

    @ViewBuilder
    private func activityContextMenu(for selection: MacSelection) -> some View {
        switch selection {
        case .place(let id):
            ForEach(MacTimelineExportFormat.allCases, id: \.self) { format in
                Button("Export \(format.title)", systemImage: "doc.badge.arrow.up") {
                    exportActivity(selection, format)
                }
            }
            if let place = day.places.first(where: { $0.id == id }) {
                Divider()
                Button("Delete Place", systemImage: "trash", role: .destructive) {
                    try? TimelineDeletion.delete(place: place, in: modelContext, undoManager: undoManager)
                }
            }
        case .move(let id):
            ForEach(MacTimelineExportFormat.allCases, id: \.self) { format in
                Button("Export \(format.title)", systemImage: "doc.badge.arrow.up") {
                    exportActivity(selection, format)
                }
            }
            if let move = day.moves.first(where: { $0.id == id }) {
                Divider()
                Button("Duplicate Activity", systemImage: "plus.square.on.square") { duplicate(move) }
                Button("Simplify Route", systemImage: "point.3.connected.trianglepath.dotted") { simplifyRoute(for: move) }
                    .disabled(routeCoordinates(for: move).count < 3)
                Button("Reset Route Edits", systemImage: "arrow.uturn.backward") {
                    move.clearManualRouteCoordinates()
                    try? modelContext.save()
                }
                .disabled(!move.hasManualRouteCoordinates)
                Menu("Change Transport", systemImage: "arrow.triangle.branch") {
                    ForEach(TransportMode.allCases) { mode in
                        Button(mode.title) {
                            move.transportMode = mode
                            move.clearCachedRouteCoordinates()
                            try? modelContext.save()
                        }
                    }
                }
                Divider()
                Button("Delete Activity", systemImage: "trash", role: .destructive) {
                    try? TimelineDeletion.delete(move: move, in: modelContext, undoManager: undoManager)
                }
            }
        default:
            EmptyView()
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
        duplicate.dayTimeline = day
        let route = routeCoordinates(for: move)
        if route.count > 1 { duplicate.storeManualRouteCoordinates(route) }
        modelContext.insert(duplicate)
        try? modelContext.save()
    }

    private func simplifyRoute(for move: MoveSegment) {
        let coordinates = routeCoordinates(for: move)
        guard coordinates.count > 2 else { return }
        var simplified = [coordinates[0]]
        for coordinate in coordinates.dropFirst().dropLast() where RouteCoordinateOps.distanceMeters(from: simplified[simplified.count - 1], to: coordinate) >= 15 {
            simplified.append(coordinate)
        }
        simplified.append(coordinates[coordinates.count - 1])
        guard simplified.count < coordinates.count else { return }
        move.storeManualRouteCoordinates(simplified)
        try? modelContext.save()
    }

    private func routeCoordinates(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        move.manualRouteCoordinates ?? MoveRouteGeometry.rawCoordinates(for: move)
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
    private struct MatchedRoute {
        let signature: String
        let coordinates: [CLLocationCoordinate2D]
    }

    let day: DayTimeline
    let initialVisibleRect: MKMapRect?
    @Environment(\.modelContext) private var modelContext
    @State private var showsLargeMapMarkers: Bool
    @State private var showsMapElevation: Bool
    @State private var routeLineWidth: Double
    @State private var matchedRoutes: [UUID: MatchedRoute] = [:]

    init(day: DayTimeline, initialVisibleRect: MKMapRect?) {
        self.day = day
        self.initialVisibleRect = initialVisibleRect
        let defaults = UserDefaults.standard
        _showsLargeMapMarkers = State(
            initialValue: defaults.object(forKey: MovesMacSettingsKey.showsLargeMapMarkers) as? Bool ?? false
        )
        _showsMapElevation = State(
            initialValue: defaults.object(forKey: MovesMacSettingsKey.showsMapElevation) as? Bool ?? true
        )
        _routeLineWidth = State(
            initialValue: (defaults.object(forKey: MovesMacSettingsKey.routeLineWidth) as? NSNumber)?.doubleValue ?? 4
        )
    }

    private var routeMatchingKey: String {
        day.moves.map { move in
            let fallback = MoveRouteGeometry.rawCoordinates(for: move)
            return "\(move.id.uuidString)|\(MoveRouteGeometry.cacheSignature(for: move, fallback: fallback))"
        }
        .joined(separator: ";")
    }

    private var renderedPlaces: [MacNativeMap.Place] {
        day.places.map {
            MacNativeMap.Place(
                id: $0.id,
                title: $0.displayTitle,
                coordinate: $0.coordinate,
                usesLargeMarker: showsLargeMapMarkers
            )
        }
    }

    private var renderedRoutes: [MacNativeMap.Route] {
        day.moves.compactMap { move in
            let route = displayedRoute(for: move)
            if route.count > 1 {
                return MacNativeMap.Route(
                    id: move.id,
                    coordinates: route,
                    color: routeNSColor(move.transportMode),
                    lineWidth: routeLineWidth,
                    isDashed: false
                )
            }
            if let start = move.startPlace?.coordinate, let end = move.endPlace?.coordinate {
                return MacNativeMap.Route(
                    id: move.id,
                    coordinates: [start, end],
                    color: routeNSColor(move.transportMode),
                    lineWidth: max(2, routeLineWidth - 1),
                    isDashed: true
                )
            }
            return nil
        }
    }

    private var renderedContentID: String {
        let resolvedKeys = matchedRoutes.keys.map(\.uuidString).sorted().joined(separator: ",")
        return "\(routeMatchingKey)|\(resolvedKeys)|\(showsLargeMapMarkers)|\(showsMapElevation)|\(routeLineWidth)"
    }

    var body: some View {
        // SwiftUI's Map bridge on macOS 27 repeatedly re-applies an equivalent configuration,
        // invalidating the complete observation graph and leaking memory. The native map wrapper
        // below applies content only when this stable identifier changes.
        MacNativeMap(
            contentID: renderedContentID,
            places: renderedPlaces,
            routes: renderedRoutes,
            initialVisibleRect: initialVisibleRect,
            showsElevation: showsMapElevation
        )
        .overlay(alignment: .topLeading) {
            Label("\(day.places.count) places · \(day.moves.count) moves", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.caption.weight(.medium)).padding(8).background(.regularMaterial, in: Capsule()).padding(12)
        }
        .task(id: routeMatchingKey) {
            await resolveRoutes()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshMapSettings()
        }
    }

    private func refreshMapSettings() {
        let defaults = UserDefaults.standard
        let largeMarkers = defaults.object(forKey: MovesMacSettingsKey.showsLargeMapMarkers) as? Bool ?? false
        let elevation = defaults.object(forKey: MovesMacSettingsKey.showsMapElevation) as? Bool ?? true
        let lineWidth = (defaults.object(forKey: MovesMacSettingsKey.routeLineWidth) as? NSNumber)?.doubleValue ?? 4
        if showsLargeMapMarkers != largeMarkers { showsLargeMapMarkers = largeMarkers }
        if showsMapElevation != elevation { showsMapElevation = elevation }
        if routeLineWidth != lineWidth { routeLineWidth = lineWidth }
    }

    private func displayedRoute(for move: MoveSegment) -> [CLLocationCoordinate2D] {
        if let manualRoute = move.manualRouteCoordinates {
            return manualRoute
        }

        let fallback = MoveRouteGeometry.rawCoordinates(for: move)
        let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
        if let resolved = matchedRoutes[move.id], resolved.signature == signature {
            return resolved.coordinates
        }
        return move.cachedRouteCoordinates(for: signature) ?? fallback
    }

    @MainActor
    private func resolveRoutes() async {
        var resolved: [UUID: MatchedRoute] = [:]

        for move in day.moves {
            guard !Task.isCancelled else { return }
            let fallback = MoveRouteGeometry.rawCoordinates(for: move)
            let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
            let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
            resolved[move.id] = MatchedRoute(signature: signature, coordinates: coordinates)
        }

        guard !Task.isCancelled else { return }
        matchedRoutes = resolved

        if modelContext.hasChanges {
            try? modelContext.save()
        }
    }
}

private struct MacNativeMap: NSViewRepresentable {
    struct Place {
        let id: UUID
        let title: String
        let coordinate: CLLocationCoordinate2D
        let usesLargeMarker: Bool
    }

    struct Route {
        let id: UUID
        let coordinates: [CLLocationCoordinate2D]
        let color: NSColor
        let lineWidth: CGFloat
        let isDashed: Bool
    }

    private final class PlaceAnnotation: NSObject, MKAnnotation {
        let id: UUID
        let title: String?
        let coordinate: CLLocationCoordinate2D
        let usesLargeMarker: Bool

        init(place: Place) {
            id = place.id
            title = place.title
            coordinate = place.coordinate
            usesLargeMarker = place.usesLargeMarker
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        struct RouteStyle {
            let color: NSColor
            let lineWidth: CGFloat
            let isDashed: Bool
        }

        var appliedContentID: String?
        var routeStyles: [ObjectIdentifier: RouteStyle] = [:]

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? PlaceAnnotation else { return nil }
            let identifier = "MovesPlaceMarker"
            let marker = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            marker.annotation = annotation
            marker.markerTintColor = .systemBlue
            marker.glyphImage = NSImage(
                systemSymbolName: annotation.usesLargeMarker ? "mappin.circle.fill" : "mappin",
                accessibilityDescription: annotation.title
            )
            marker.canShowCallout = true
            return marker
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            if let style = routeStyles[ObjectIdentifier(polyline)] {
                renderer.strokeColor = style.color
                renderer.lineWidth = style.lineWidth
                if style.isDashed { renderer.lineDashPattern = [6, 5] }
            }
            return renderer
        }
    }

    let contentID: String
    let places: [Place]
    let routes: [Route]
    let initialVisibleRect: MKMapRect?
    let showsElevation: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        guard context.coordinator.appliedContentID != contentID else { return }
        context.coordinator.appliedContentID = contentID

        mapView.preferredConfiguration = MKStandardMapConfiguration(
            elevationStyle: showsElevation ? .realistic : .flat
        )
        mapView.removeAnnotations(mapView.annotations)
        mapView.removeOverlays(mapView.overlays)
        context.coordinator.routeStyles.removeAll(keepingCapacity: true)

        mapView.addAnnotations(places.map(PlaceAnnotation.init))
        for route in routes where route.coordinates.count > 1 {
            let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
            context.coordinator.routeStyles[ObjectIdentifier(polyline)] = .init(
                color: route.color,
                lineWidth: route.lineWidth,
                isDashed: route.isDashed
            )
            mapView.addOverlay(polyline)
        }

        if let initialVisibleRect {
            mapView.setVisibleMapRect(initialVisibleRect, animated: false)
        }
    }
}

private struct MacInspector: View {
    let selection: MacSelection?
    let timelines: [DayTimeline]
    let requestEntryDeletion: () -> Void
    let requestDayDeletion: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var transportModeSaveError: String?

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
        .alert("Could Not Change Transport Mode", isPresented: Binding(
            get: { transportModeSaveError != nil },
            set: { if !$0 { transportModeSaveError = nil } }
        )) {
            Button("OK", role: .cancel) { transportModeSaveError = nil }
        } message: {
            Text(transportModeSaveError ?? "")
        }
    }

    private func dayInspector(_ day: DayTimeline) -> some View {
        Form {
            Section("Day") { LabeledContent("Date", value: day.dayStart.formatted(date: .long, time: .omitted)); LabeledContent("Day key", value: day.dayKey) }
            Section("Activity") { LabeledContent("Places", value: day.places.count.formatted()); LabeledContent("Moves", value: day.moves.count.formatted()); LabeledContent("Samples", value: day.samples.count.formatted()) }
            Section("Record") { LabeledContent("Created", value: day.createdAt.formatted(date: .abbreviated, time: .shortened)) }
            Section("Actions") {
                Button("Delete Day", systemImage: "trash", role: .destructive, action: requestDayDeletion)
            }
        }
    }

    private func placeInspector(_ place: VisitPlace) -> some View {
        Form {
            Section("Place") { Text(place.displayTitle).font(.headline); LabeledContent("Arrived", value: place.arrivalDate.formatted(date: .long, time: .shortened)); if let departure = place.departureDate { LabeledContent("Departed", value: departure.formatted(date: .omitted, time: .shortened)) } }
            Section("Location") { LabeledContent("Latitude", value: place.latitude.formatted(.number.precision(.fractionLength(5)))); LabeledContent("Longitude", value: place.longitude.formatted(.number.precision(.fractionLength(5)))); LabeledContent("Accuracy", value: "±\(MovesMeasurementFormatter.accuracy(meters: place.horizontalAccuracy))") }
            if let comment = place.comment, !comment.isEmpty { Section("Comment") { Text(comment) } }
            Section("Record") { LabeledContent("ID", value: place.id.uuidString) }
            Section("Actions") {
                Button("Delete Entry", systemImage: "trash", role: .destructive, action: requestEntryDeletion)
            }
        }
    }

    private func moveInspector(_ move: MoveSegment) -> some View {
        Form {
            Section("Move") {
                Label(move.transportMode.title, systemImage: move.transportMode.symbolName).font(.headline)
                Picker("Transport", selection: Binding(
                    get: { move.transportMode },
                    set: { setTransportMode($0, for: move) }
                )) {
                    ForEach(TransportMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                LabeledContent("Started", value: move.timelineStartDate.formatted(date: .long, time: .shortened))
                LabeledContent("Duration", value: formatDuration(move.timelineDuration))
                LabeledContent("Distance", value: formatDistance(move.distanceMeters))
            }
            Section("Route") { LabeledContent("Samples", value: move.samples.count.formatted()); LabeledContent("Source", value: move.usesHealthWorkoutRoute ? "Health workout route" : move.usesHighAccuracyRouteTracking ? "Route tracking" : "Location history"); if let start = move.startPlace { LabeledContent("From", value: start.displayTitle) }; if let end = move.endPlace { LabeledContent("To", value: end.displayTitle) } }
            if let comment = move.comment, !comment.isEmpty { Section("Comment") { Text(comment) } }
            Section("Record") { LabeledContent("ID", value: move.id.uuidString) }
            Section("Actions") {
                Button("Delete Entry", systemImage: "trash", role: .destructive, action: requestEntryDeletion)
            }
        }
    }

    private func setTransportMode(_ mode: TransportMode, for move: MoveSegment) {
        guard move.transportMode != mode else { return }

        let previousMode = move.transportMode
        let previousCacheSignature = move.routeCacheSignature
        let previousCacheCoordinates = move.routeCacheCoordinatesData
        let previousManualCoordinates = move.manualRouteCoordinatesData

        move.transportMode = mode
        move.clearCachedRouteCoordinates()
        move.clearManualRouteCoordinates()

        do {
            try modelContext.save()
        } catch {
            move.transportMode = previousMode
            move.routeCacheSignature = previousCacheSignature
            move.routeCacheCoordinatesData = previousCacheCoordinates
            move.manualRouteCoordinatesData = previousManualCoordinates
            transportModeSaveError = error.localizedDescription
        }
    }
}

private struct MacTimelineExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.xml, .json, .commaSeparatedText]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct MacTimelineExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
}

private struct MacTimelineTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date
}

private enum MacTimelineExporter {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func makePayload(
        days: [DayTimeline],
        format: MacTimelineExportFormat,
        fileStem: String,
        includesPlaces: Bool,
        includesComments: Bool
    ) -> MacTimelineExportPayload? {
        guard !days.isEmpty else { return nil }
        let orderedDays = days.sorted { $0.dayStart < $1.dayStart }
        let data: Data?
        let contentType: UTType
        let fileExtension: String

        switch format {
        case .gpx:
            data = gpxData(for: orderedDays, includesPlaces: includesPlaces, includesComments: includesComments)
            contentType = .xml
            fileExtension = "gpx"
        case .geoJSON:
            data = geoJSONData(for: orderedDays, includesPlaces: includesPlaces, includesComments: includesComments)
            contentType = .json
            fileExtension = "geojson"
        case .csv:
            data = csvData(for: orderedDays, includesPlaces: includesPlaces, includesComments: includesComments)
            contentType = .commaSeparatedText
            fileExtension = "csv"
        }

        guard let data else { return nil }
        return MacTimelineExportPayload(
            data: data,
            filename: "\(fileStem).\(fileExtension)",
            contentType: contentType
        )
    }

    static func makePayload(move: MoveSegment, format: MacTimelineExportFormat, fileStem: String) -> MacTimelineExportPayload? {
        let title = "\(move.startPlace?.displayTitle ?? "Unknown start") to \(move.endPlace?.displayTitle ?? "Unknown destination")"
        let points = routePoints(for: move)
        let data: Data?

        switch format {
        case .gpx:
            guard points.count > 1 else { return nil }
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"Moves\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(xmlEscaped(title))</name><type>\(xmlEscaped(move.transportMode.title))</type><trkseg>"
            for point in points {
                xml += "<trkpt lat=\"\(coordinateString(point.latitude))\" lon=\"\(coordinateString(point.longitude))\"><time>\(iso8601.string(from: point.timestamp))</time></trkpt>"
            }
            data = (xml + "</trkseg></trk></gpx>").data(using: .utf8)
        case .geoJSON:
            guard points.count > 1 else { return nil }
            let feature: [String: Any] = [
                "type": "Feature",
                "geometry": ["type": "LineString", "coordinates": points.map { [$0.longitude, $0.latitude] }],
                "properties": ["record_type": "move", "title": title, "day_key": move.dayTimeline?.dayKey ?? "", "transport_mode": move.transportMode.rawValue, "start_time": iso8601.string(from: move.timelineStartDate), "end_time": iso8601.string(from: move.endDate), "distance_meters": move.distanceMeters],
            ]
            data = try? JSONSerialization.data(withJSONObject: feature, options: [.prettyPrinted, .sortedKeys])
        case .csv:
            let row = ["record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude,comment", ["move", iso8601.string(from: move.timelineStartDate), iso8601.string(from: move.endDate), csvEscaped(title), move.dayTimeline?.dayKey ?? "", move.transportMode.rawValue, String(format: "%.2f", move.distanceMeters), move.stepCount.map(String.init) ?? "", "", "", csvEscaped(move.comment ?? "")].joined(separator: ",")].joined(separator: "\n")
            data = row.data(using: .utf8)
        }

        return singlePayload(data, format: format, fileStem: fileStem)
    }

    static func makePayload(place: VisitPlace, format: MacTimelineExportFormat, fileStem: String) -> MacTimelineExportPayload? {
        let data: Data?
        switch format {
        case .gpx:
            data = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"Moves\" xmlns=\"http://www.topografix.com/GPX/1/1\"><wpt lat=\"\(coordinateString(place.latitude))\" lon=\"\(coordinateString(place.longitude))\"><name>\(xmlEscaped(place.displayTitle))</name><time>\(iso8601.string(from: place.arrivalDate))</time></wpt></gpx>".data(using: .utf8)
        case .geoJSON:
            let feature: [String: Any] = ["type": "Feature", "geometry": ["type": "Point", "coordinates": [place.longitude, place.latitude]], "properties": ["record_type": "place", "title": place.displayTitle, "day_key": place.dayTimeline?.dayKey ?? "", "arrival_time": iso8601.string(from: place.arrivalDate)]]
            data = try? JSONSerialization.data(withJSONObject: feature, options: [.prettyPrinted, .sortedKeys])
        case .csv:
            let row = ["record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude,comment", ["place", iso8601.string(from: place.arrivalDate), place.departureDate.map(iso8601.string(from:)) ?? "", csvEscaped(place.displayTitle), place.dayTimeline?.dayKey ?? "", "", "", "", coordinateString(place.latitude), coordinateString(place.longitude), csvEscaped(place.comment ?? "")].joined(separator: ",")].joined(separator: "\n")
            data = row.data(using: .utf8)
        }
        return singlePayload(data, format: format, fileStem: fileStem)
    }

    private static func singlePayload(_ data: Data?, format: MacTimelineExportFormat, fileStem: String) -> MacTimelineExportPayload? {
        guard let data else { return nil }
        let extensionAndType: (String, UTType) = switch format {
        case .gpx: ("gpx", .xml)
        case .geoJSON: ("geojson", .json)
        case .csv: ("csv", .commaSeparatedText)
        }
        return MacTimelineExportPayload(data: data, filename: "\(fileStem).\(extensionAndType.0)", contentType: extensionAndType.1)
    }

    private static func gpxData(
        for days: [DayTimeline],
        includesPlaces: Bool,
        includesComments: Bool
    ) -> Data? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Moves" xmlns="http://www.topografix.com/GPX/1/1">
        """

        for day in days {
            if includesPlaces {
                for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) {
                    xml += """

                      <wpt lat="\(coordinateString(place.latitude))" lon="\(coordinateString(place.longitude))">
                        <name>\(xmlEscaped(place.displayTitle))</name>
                        <time>\(iso8601.string(from: place.arrivalDate))</time>
                    """
                    if includesComments, let comment = place.comment, !comment.isEmpty {
                        xml += "\n    <desc>\(xmlEscaped(comment))</desc>"
                    }
                    xml += "\n  </wpt>"
                }
            }

            let moves = day.moves.sorted { $0.timelineStartDate < $1.timelineStartDate }
            let tracks = moves.map { ($0, routePoints(for: $0)) }.filter { $0.1.count > 1 }
            guard !tracks.isEmpty else { continue }

            xml += """

              <trk>
                <name>\(xmlEscaped(day.dayKey))</name>
            """

            for (move, points) in tracks {
                xml += "\n    <trkseg>"
                for (index, point) in points.enumerated() {
                    xml += "\n      <trkpt lat=\"\(coordinateString(point.latitude))\" lon=\"\(coordinateString(point.longitude))\">"
                    if let elevation = point.elevation, elevation.isFinite {
                        xml += "\n        <ele>\(String(format: "%.2f", elevation))</ele>"
                    }
                    xml += "\n        <time>\(iso8601.string(from: point.timestamp))</time>"
                    if includesComments, index == 0, let comment = move.comment, !comment.isEmpty {
                        xml += "\n        <desc>\(xmlEscaped(comment))</desc>"
                    }
                    xml += "\n      </trkpt>"
                }
                xml += "\n    </trkseg>"
            }

            xml += "\n  </trk>"
        }

        xml += "\n</gpx>"
        return xml.data(using: .utf8)
    }

    private static func geoJSONData(
        for days: [DayTimeline],
        includesPlaces: Bool,
        includesComments: Bool
    ) -> Data? {
        var features: [[String: Any]] = []

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) where includesPlaces {
                var properties: [String: Any] = [
                    "record_type": "place",
                    "title": place.displayTitle,
                    "arrival_time": iso8601.string(from: place.arrivalDate),
                    "day_key": day.dayKey,
                ]
                if let departure = place.departureDate {
                    properties["departure_time"] = iso8601.string(from: departure)
                }
                if includesComments, let comment = place.comment, !comment.isEmpty {
                    properties["comment"] = comment
                }
                features.append([
                    "type": "Feature",
                    "geometry": ["type": "Point", "coordinates": [place.longitude, place.latitude]],
                    "properties": properties,
                ])
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let coordinates = routePoints(for: move).map { [$0.longitude, $0.latitude] }
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
                if let stepCount = move.stepCount { properties["step_count"] = stepCount }
                if includesComments, let comment = move.comment, !comment.isEmpty { properties["comment"] = comment }
                features.append([
                    "type": "Feature",
                    "geometry": ["type": "LineString", "coordinates": coordinates],
                    "properties": properties,
                ])
            }
        }

        return try? JSONSerialization.data(
            withJSONObject: ["type": "FeatureCollection", "features": features],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func csvData(
        for days: [DayTimeline],
        includesPlaces: Bool,
        includesComments: Bool
    ) -> Data? {
        var rows = ["record_type,start_time,end_time,title,day_key,transport_mode,distance_meters,step_count,latitude,longitude,comment"]

        for day in days {
            for place in day.places.sorted(by: { $0.arrivalDate < $1.arrivalDate }) where includesPlaces {
                rows.append([
                    "place",
                    iso8601.string(from: place.arrivalDate),
                    place.departureDate.map(iso8601.string(from:)) ?? "",
                    csvEscaped(place.displayTitle),
                    day.dayKey,
                    "", "", "",
                    coordinateString(place.latitude),
                    coordinateString(place.longitude),
                    csvEscaped(includesComments ? (place.comment ?? "") : ""),
                ].joined(separator: ","))
            }

            for move in day.moves.sorted(by: { $0.timelineStartDate < $1.timelineStartDate }) {
                let title = "\(move.startPlace?.displayTitle ?? "Unknown start") to \(move.endPlace?.displayTitle ?? "Unknown destination")"
                rows.append([
                    "move",
                    iso8601.string(from: move.timelineStartDate),
                    iso8601.string(from: move.endDate),
                    csvEscaped(title),
                    day.dayKey,
                    move.transportMode.rawValue,
                    String(format: "%.2f", move.distanceMeters),
                    move.stepCount.map(String.init) ?? "",
                    "", "",
                    csvEscaped(includesComments ? (move.comment ?? "") : ""),
                ].joined(separator: ","))
            }
        }

        return rows.joined(separator: "\n").data(using: .utf8)
    }

    private static func routePoints(for move: MoveSegment) -> [MacTimelineTrackPoint] {
        let samples = move.samples.sorted { $0.timestamp < $1.timestamp }
        if samples.count > 1 {
            return samples.map {
                MacTimelineTrackPoint(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    elevation: $0.altitude,
                    timestamp: $0.timestamp
                )
            }
        }

        var coordinates = RouteCoordinateStorage.decode(
            move.manualRouteCoordinatesData ?? move.routeCacheCoordinatesData
        )
        if coordinates.count < 2,
           let start = move.startPlace?.coordinate,
           let end = move.endPlace?.coordinate {
            coordinates = [start, end]
        }
        guard coordinates.count > 1 else { return [] }

        let duration = max(move.endDate.timeIntervalSince(move.timelineStartDate), 0)
        return coordinates.enumerated().map { index, coordinate in
            let fraction = Double(index) / Double(coordinates.count - 1)
            return MacTimelineTrackPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                elevation: nil,
                timestamp: move.timelineStartDate.addingTimeInterval(duration * fraction)
            )
        }
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
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

private func routeNSColor(_ mode: TransportMode) -> NSColor {
    switch mode {
    case .walking, .running: .systemGreen
    case .cycling: .systemOrange
    case .train: .systemPurple
    case .plane: .systemPink
    case .boat: .systemTeal
    case .stationary: .systemGray
    default: .systemBlue
    }
}

private func formatDistance(_ meters: Double) -> String { MovesMeasurementFormatter.distance(meters: meters) }

private func formatDuration(_ duration: TimeInterval) -> String {
    DurationFormatter.text(for: duration)
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
