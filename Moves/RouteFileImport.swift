import CoreLocation
import BackgroundTasks
import Compression
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RouteFileImportReport {
    let fileCount: Int
    let routeCount: Int
    let sampleCount: Int
    let failedFileCount: Int
}

struct FailedRouteImport: Codable, Identifiable, Hashable {
    let id: UUID
    let originalFileName: String
    let storedFileName: String
    let sourceImportIdentifier: String
    let createdAt: Date
    let reason: String
    let configuration: RouteFileImportConfiguration
}

struct ImportedRouteDataFilter {
    var startDate: Date?
    var endDate: Date?
    var transportMode: TransportMode?

    func includes(_ date: Date) -> Bool {
        (startDate == nil || date >= startDate!) && (endDate == nil || date <= endDate!)
    }
}

struct ImportedRouteDataReport {
    let sampleCount: Int
    let moveCount: Int
}

extension DayTimeline {
    var hasImportedRouteData: Bool {
        samples.contains { $0.source == .fileRouteImport }
            || moves.contains { move in
                move.samples.contains { $0.source == .fileRouteImport }
            }
    }
}

@MainActor
final class ImportedRouteDataManager: ObservableObject {
    @Published private(set) var report = ImportedRouteDataReport(sampleCount: 0, moveCount: 0)
    @Published private(set) var isRemoving = false

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func refresh(using filter: ImportedRouteDataFilter) {
        do {
            let (samples, moves) = try matchingData(for: filter)
            report = ImportedRouteDataReport(sampleCount: samples.count, moveCount: moves.count)
        } catch {
            report = ImportedRouteDataReport(sampleCount: 0, moveCount: 0)
        }
    }

    func remove(using filter: ImportedRouteDataFilter) throws {
        isRemoving = true
        defer { isRemoving = false }
        let (samples, moves) = try matchingData(for: filter)
        try removeImportedRouteRecords(samples: samples, moves: moves, from: modelContext)
        refresh(using: filter)
        NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
    }

    private func matchingData(for filter: ImportedRouteDataFilter) throws -> ([LocationSample], [MoveSegment]) {
        let importedSamples = try modelContext.fetch(FetchDescriptor<LocationSample>()).filter {
            $0.source == .fileRouteImport && filter.includes($0.timestamp)
        }
        let importedIDs = Set(importedSamples.map(\.dedupeKey))
        let allMoves = try modelContext.fetch(FetchDescriptor<MoveSegment>())
        let moves = allMoves.filter { move in
            let modeMatches = filter.transportMode == nil || move.transportMode == filter.transportMode
            return modeMatches && move.samples.contains { importedIDs.contains($0.dedupeKey) }
        }
        guard filter.transportMode != nil else { return (importedSamples, moves) }
        let modeSampleIDs = Set(moves.flatMap(\.samples).filter { $0.source == .fileRouteImport }.map(\.dedupeKey))
        return (importedSamples.filter { modeSampleIDs.contains($0.dedupeKey) }, moves)
    }
}

struct ImportedRoutePreview: Identifiable, Hashable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let transportMode: TransportMode
    let distanceMeters: Double
    let sampleCount: Int

    var title: String {
        "\(transportMode.title) · \(String(format: "%.1f", distanceMeters / 1_000)) km"
    }
}

@MainActor
final class ImportedRoutePreviewStore: ObservableObject {
    @Published private(set) var routes: [ImportedRoutePreview] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func reload(
        startDate: Date?,
        endDate: Date?,
        transportMode: TransportMode?,
        minimumDistance: Double?,
        minimumPoints: Int?,
        searchText: String?,
        sortDescending: Bool
    ) {
        do {
            let search = searchText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            routes = try modelContext.fetch(FetchDescriptor<MoveSegment>())
                .filter { move in
                    let imported = move.samples.filter { $0.source == .fileRouteImport }
                    guard !imported.isEmpty else { return false }
                    guard transportMode == nil || move.transportMode == transportMode else { return false }
                    guard startDate == nil || move.endDate >= startDate! else { return false }
                    guard endDate == nil || move.startDate <= endDate! else { return false }
                    guard minimumDistance == nil || move.distanceMeters >= minimumDistance! else { return false }
                    guard minimumPoints == nil || imported.count >= minimumPoints! else { return false }
                    guard search.isEmpty || move.transportMode.title.lowercased().contains(search) else { return false }
                    return true
                }
                .map { move in
                    ImportedRoutePreview(
                        id: move.id,
                        startDate: move.startDate,
                        endDate: move.endDate,
                        transportMode: move.transportMode,
                        distanceMeters: move.distanceMeters,
                        sampleCount: move.samples.filter { $0.source == .fileRouteImport }.count
                    )
                }
                .sorted { sortDescending ? $0.startDate > $1.startDate : $0.startDate < $1.startDate }
            errorMessage = nil
        } catch {
            routes = []
            errorMessage = error.localizedDescription
        }
    }

    func remove(routeIDs: Set<UUID>) throws {
        isWorking = true
        defer { isWorking = false }
        let moves = try modelContext.fetch(FetchDescriptor<MoveSegment>()).filter { routeIDs.contains($0.id) }
        let importedSamples = moves.flatMap(\.samples).filter { $0.source == .fileRouteImport }
        try removeImportedRouteRecords(samples: importedSamples, moves: moves, from: modelContext)
        NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
    }
}

/// Removes the complete footprint of a file import. Earlier cleanup deleted samples and moves
/// but left their generated endpoint places and empty day containers behind.
private func removeImportedRouteRecords(
    samples: [LocationSample],
    moves: [MoveSegment],
    from modelContext: ModelContext
) throws {
    let movesToDelete = moves.filter { move in
        move.samples.isEmpty || move.samples.allSatisfy { $0.source == .fileRouteImport }
    }
    let moveIDsToDelete = Set(movesToDelete.map(\.id))
    let endpointPlaces = Dictionary(
        movesToDelete
            .flatMap { [$0.startPlace, $0.endPlace].compactMap { $0 } }
            .map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let affectedDayKeys = Set(
        samples.compactMap { $0.dayTimeline?.dayKey }
            + movesToDelete.compactMap { $0.dayTimeline?.dayKey }
            + endpointPlaces.values.compactMap { $0.dayTimeline?.dayKey }
    )

    let remainingMoves = try modelContext.fetch(FetchDescriptor<MoveSegment>())
        .filter { !moveIDsToDelete.contains($0.id) }
    let protectedPlaceIDs = Set(remainingMoves.flatMap { move in
        [move.startPlace?.id, move.endPlace?.id].compactMap { $0 }
    })

    samples.forEach(modelContext.delete)
    movesToDelete.forEach(modelContext.delete)
    try modelContext.save()

    for place in endpointPlaces.values where !protectedPlaceIDs.contains(place.id) {
        let hasUserContent = !(place.userLabel?.isEmpty ?? true) || !(place.comment?.isEmpty ?? true)
        if !hasUserContent {
            modelContext.delete(place)
        }
    }
    try modelContext.save()

    let affectedTimelines = try modelContext.fetch(FetchDescriptor<DayTimeline>())
        .filter { affectedDayKeys.contains($0.dayKey) && !$0.hasRecordedActivity }
    affectedTimelines.forEach(modelContext.delete)
    try modelContext.save()

    let repository = SwiftDataTimelineRepository(modelContext: modelContext)
    _ = try repository.mergeDuplicateDayTimelines()
}

struct ImportedRouteDataView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: ImportedRoutePreviewStore
    @State private var filterByDate = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var endDate = Date.now
    @State private var selectedMode = "all"
    @State private var minimumDistance = ""
    @State private var minimumPoints = ""
    @State private var searchText = ""
    @State private var sortDescending = true
    @State private var selectedIDs = Set<UUID>()
    @State private var confirmation: RemovalTarget?
    @State private var message = ""
    @State private var showingMessage = false

    private enum RemovalTarget: Identifiable, Equatable {
        case selected, filtered
        var id: String { String(describing: self) }
    }

    init(modelContext: ModelContext, initialDate: Date? = nil) {
        _store = StateObject(wrappedValue: ImportedRoutePreviewStore(modelContext: modelContext))
        if let initialDate {
            let dayStart = Calendar.current.startOfDay(for: initialDate)
            _filterByDate = State(initialValue: true)
            _startDate = State(initialValue: dayStart)
            _endDate = State(initialValue: dayStart)
            _sortDescending = State(initialValue: false)
        }
    }

    var body: some View {
        List {
            Section("Filters") {
                Toggle("Limit by date", isOn: $filterByDate)
                if filterByDate {
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                    DatePicker("To", selection: $endDate, displayedComponents: .date)
                }
                Picker("Transport mode", selection: $selectedMode) {
                    Text("All modes").tag("all")
                    ForEach(TransportMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                TextField("Minimum distance (km)", text: $minimumDistance)
                    .keyboardType(.decimalPad)
                TextField("Minimum imported points", text: $minimumPoints)
                    .keyboardType(.numberPad)
                TextField("Search mode", text: $searchText)
                Picker("Sort", selection: $sortDescending) {
                    Text("Newest first").tag(true)
                    Text("Oldest first").tag(false)
                }
            }

            Section {
                HStack {
                    Text("\(store.routes.count) matching route(s)")
                    Spacer()
                    Button(selectedIDs.count == store.routes.count ? "Clear selection" : "Select all") {
                        selectedIDs = selectedIDs.count == store.routes.count ? [] : Set(store.routes.map(\.id))
                    }
                }
                if store.routes.isEmpty {
                    ContentUnavailableView("No imported routes", systemImage: "line.3.horizontal.decrease.circle", description: Text("Adjust the filters to preview imported data."))
                } else {
                    ForEach(store.routes) { route in
                        ImportedRoutePreviewRow(route: route, isSelected: selectedIDs.contains(route.id)) {
                            if selectedIDs.contains(route.id) { selectedIDs.remove(route.id) }
                            else { selectedIDs.insert(route.id) }
                        }
                    }
                }
            } header: {
                Text("Preview")
            }

            Section("Remove") {
                Button("Remove selected (\(selectedIDs.count))", role: .destructive) {
                    confirmation = .selected
                }
                .disabled(selectedIDs.isEmpty || store.isWorking)
                Button("Remove all filtered routes", role: .destructive) {
                    confirmation = .filtered
                }
                .disabled(store.routes.isEmpty || store.isWorking)
                Text("Imported GPS samples and routes with no remaining non-imported samples are removed, together with their unused generated endpoint places and empty days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Manage Imported Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { reload() }
        .onChange(of: filterByDate) { _, _ in reload() }
        .onChange(of: startDate) { _, _ in reload() }
        .onChange(of: endDate) { _, _ in reload() }
        .onChange(of: selectedMode) { _, _ in reload() }
        .onChange(of: minimumDistance) { _, _ in reload() }
        .onChange(of: minimumPoints) { _, _ in reload() }
        .onChange(of: searchText) { _, _ in reload() }
        .onChange(of: sortDescending) { _, _ in reload() }
        .alert("Remove imported routes?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("Remove", role: .destructive) {
                let ids = confirmation == .selected ? selectedIDs : Set(store.routes.map(\.id))
                do {
                    try store.remove(routeIDs: ids)
                    selectedIDs.subtract(ids)
                    message = "Removed imported data from \(ids.count) route(s)."
                } catch {
                    message = "Could not remove imported data: \(error.localizedDescription)"
                }
                confirmation = nil
                showingMessage = true
                reload()
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text("This also removes unused generated endpoint places and empty imported days. Non-imported samples are preserved.")
        }
        .alert("Imported Data", isPresented: $showingMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    private func reload() {
        let calendar = Calendar.current
        let start = filterByDate ? calendar.startOfDay(for: startDate) : nil
        let end = filterByDate ? calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) : nil
        store.reload(
            startDate: start,
            endDate: end,
            transportMode: selectedMode == "all" ? nil : TransportMode(rawValue: selectedMode),
            minimumDistance: Double(minimumDistance.replacingOccurrences(of: ",", with: ".")).map { $0 * 1_000 },
            minimumPoints: Int(minimumPoints),
            searchText: searchText,
            sortDescending: sortDescending
        )
        selectedIDs = selectedIDs.intersection(Set(store.routes.map(\.id)))
    }
}

private struct ImportedRoutePreviewRow: View {
    let route: ImportedRoutePreview
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.title).font(.body.weight(.medium))
                    Text("\(route.startDate.formatted(date: .abbreviated, time: .shortened)) · \(route.sampleCount) imported points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: route.transportMode.symbolName)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum RouteFileImportState: String, Codable {
    case idle, running, paused, completed, failed
}

private struct PersistedRouteFileImport: Codable {
    var files: [String]
    var nextIndex: Int
    var importedFileCount: Int
    var routeCount: Int
    var sampleCount: Int
    var failedFileCount: Int?
    var skipExistingDates: Bool
    var mappingModeRawValue: String?
    var dedicatedTransportModeRawValue: String?
    var existingDataPolicyRawValue: String?
    var state: RouteFileImportState
    var updatedAt: Date

    var configuration: RouteFileImportConfiguration {
        RouteFileImportConfiguration(
            mappingMode: RouteFileImportMappingMode(rawValue: mappingModeRawValue ?? "automatic") ?? .automatic,
            dedicatedTransportMode: TransportMode(rawValue: dedicatedTransportModeRawValue ?? "unknown") ?? .unknown,
            existingDataPolicy: RouteFileExistingDataPolicy(rawValue: existingDataPolicyRawValue ?? (skipExistingDates ? "skipDate" : "expandAroundExisting")) ?? .skipDate
        )
    }
}

private enum RouteFileImportStore {
    static let stateKey = "Moves.routeFileImport.state"
    static let failedImportsKey = "Moves.routeFileImport.failedImports"
    static let taskIdentifier = "de.holgerkrupp.Moves.routeFileImport"

    static var state: PersistedRouteFileImport? {
        get {
            guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
            return try? JSONDecoder().decode(PersistedRouteFileImport.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: stateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: stateKey)
            }
        }
    }

    static var failedImports: [FailedRouteImport] {
        get {
            guard let data = UserDefaults.standard.data(forKey: failedImportsKey) else { return [] }
            return (try? JSONDecoder().decode([FailedRouteImport].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: failedImportsKey)
            }
        }
    }

    static var stagingDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moves/RouteImport", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }


    static var failedImportsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moves/FailedRouteImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

@MainActor
final class RouteFileImporter: ObservableObject {
    @Published private(set) var state: RouteFileImportState = .idle
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: RouteFileImportReport?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var importPhase = ""
    @Published private(set) var failedImports: [FailedRouteImport]
    @Published private(set) var resolvingFailedImportID: UUID?

    private let modelContainer: ModelContainer
    /// Compatibility facade for the existing Settings UI. Durable queue records are owned by
    /// ImportCoordinator; this class remains responsible only for presenting route-file progress
    /// while its worker is migrated incrementally.
    let importCoordinator: ImportCoordinator
    private var activeJobID: UUID?
    private var importTask: Task<Void, Never>?
    private var shouldPause = false

    convenience init(modelContext: ModelContext) {
        self.init(modelContext: modelContext, importCoordinator: ImportCoordinator())
    }

    init(modelContext: ModelContext, importCoordinator: ImportCoordinator) {
        self.modelContainer = modelContext.container
        self.importCoordinator = importCoordinator
        self.failedImports = RouteFileImportStore.failedImports
        let persistedState = RouteFileImportStore.state?.state ?? .idle
        state = persistedState == .running ? .paused : persistedState
        if persistedState == .running, var persisted = RouteFileImportStore.state {
            persisted.state = .paused
            RouteFileImportStore.state = persisted
        }
        migrateLegacyQueueStateIfNeeded()
    }

    private func migrateLegacyQueueStateIfNeeded() {
        guard importCoordinator.jobs.isEmpty, let persisted = RouteFileImportStore.state else { return }
        let job = ImportJobRecord(
            displayName: "Route file import",
            source: ImportJobSourceMetadata(
                originalFileNames: persisted.files.map { URL(fileURLWithPath: $0).lastPathComponent },
                sourceIdentifiers: persisted.files
            ),
            stagedPath: RouteFileImportStore.stagingDirectory.path,
            configuration: persisted.configuration,
            state: persisted.state == .running ? .paused : .queued,
            phase: .importing,
            counters: ImportJobCounters(
                itemCount: persisted.files.count,
                completedItemCount: persisted.nextIndex,
                routeCount: persisted.routeCount,
                sampleCount: persisted.sampleCount,
                failedItemCount: persisted.failedFileCount ?? 0
            ),
            updatedAt: persisted.updatedAt
        )
        _ = try? importCoordinator.enqueue(job)
    }

    var isImporting: Bool { state == .running }
    var canResume: Bool { state == .paused || state == .failed || (state == .idle && RouteFileImportStore.state != nil) }

    func start(urls: [URL], configuration: RouteFileImportConfiguration) {
        guard !isImporting else { return }
        state = .running
        importProgress = 0
        importPhase = "Preparing files"
        importTask?.cancel()
        let initialJob = ImportJobRecord(
            displayName: urls.count == 1 ? urls[0].lastPathComponent : "Route file import",
            source: ImportJobSourceMetadata(
                originalFileNames: urls.map(\.lastPathComponent),
                sourceIdentifiers: urls.map(\.path)
            ),
            stagedPath: RouteFileImportStore.stagingDirectory.path,
            configuration: configuration,
            state: .acquiring,
            phase: .acquiring
        )
        activeJobID = try? importCoordinator.enqueue(initialJob)
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let acquisition = try await self.prepareFiles(urls)
                let files = acquisition.files
                guard !files.isEmpty else { throw RouteFileImportError.noFiles }
                if let activeJobID, var job = self.importCoordinator.jobs.first(where: { $0.id == activeJobID }) {
                    job.displayName = files.count == 1 ? files[0].lastPathComponent : "Route file import (\(files.count) files)"
                    job.source.originalFileNames = acquisition.sourceNames
                    job.source.sourceIdentifiers = acquisition.sourceIdentifiers
                    job.source.bookmarkData = acquisition.bookmarkData
                    job.counters.itemCount = files.count
                    job.updatedAt = .now
                    try? self.importCoordinator.update(job)
                }
                let persisted = PersistedRouteFileImport(
                    files: files.map(\.path), nextIndex: 0, importedFileCount: 0,
                    routeCount: 0, sampleCount: 0, failedFileCount: 0,
                    skipExistingDates: configuration.existingDataPolicy == .skipDate,
                    mappingModeRawValue: configuration.mappingMode.rawValue,
                    dedicatedTransportModeRawValue: configuration.dedicatedTransportMode.rawValue,
                    existingDataPolicyRawValue: configuration.existingDataPolicy.rawValue,
                    state: .running, updatedAt: .now
                )
                RouteFileImportStore.state = persisted
                RouteFileImportBackgroundTask.schedule()
                await self.runPersistedImport()
            } catch is CancellationError {
            } catch {
                self.state = .failed
                self.lastErrorMessage = error.localizedDescription
                if let activeJobID, var job = self.importCoordinator.jobs.first(where: { $0.id == activeJobID }) {
                    job.state = error is RouteImportAcquisitionError ? .needsInformation : .failed
                    job.lastError = ImportJobError(message: error.localizedDescription, isRecoverable: true, occurredAt: .now)
                    job.updatedAt = .now
                    try? self.importCoordinator.update(job)
                }
            }
        }
    }

    func start(urls: [URL], skipExistingDates: Bool) {
        start(
            urls: urls,
            configuration: RouteFileImportConfiguration(
                existingDataPolicy: skipExistingDates ? .skipDate : .expandAroundExisting
            )
        )
    }

    func resume() {
        guard !isImporting, let persisted = RouteFileImportStore.state,
              persisted.nextIndex < persisted.files.count else { return }
        importTask?.cancel()
        importTask = Task { [weak self] in await self?.runPersistedImport() }
    }

    func resumeAndWait() async {
        if !isImporting { resume() }
        await importTask?.value
    }

    func pause() {
        guard isImporting else { return }
        shouldPause = true
        if let activeJobID { try? importCoordinator.pause(id: activeJobID) }
        importProgressText = "Pausing…"
    }

    func restart() {
        guard let persisted = RouteFileImportStore.state else { return }
        shouldPause = true
        importTask?.cancel()
        var restarted = persisted
        restarted.nextIndex = 0
        restarted.importedFileCount = 0
        restarted.routeCount = 0
        restarted.sampleCount = 0
        restarted.failedFileCount = 0
        restarted.state = .paused
        RouteFileImportStore.state = restarted
        state = .paused
        importProgress = 0
        importProgressText = "Ready to restart"
    }

    func cancel() {
        importTask?.cancel()
        importTask = nil
        try? FileManager.default.removeItem(at: RouteFileImportStore.stagingDirectory)
        RouteFileImportStore.state = nil
        if let activeJobID { try? importCoordinator.cancel(id: activeJobID) }
        activeJobID = nil
        state = .idle
        importProgress = nil
        importProgressText = ""
    }

    private func runPersistedImport() async {
        guard var persisted = RouteFileImportStore.state else { return }
        shouldPause = false
        state = .running
        importPhase = "Importing route data"
        persisted.state = .running
        RouteFileImportStore.state = persisted
        updateActiveJob { job in
            job.state = .importing
            job.phase = .importing
            job.updatedAt = .now
        }
        let context = ModelContext(modelContainer)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        do {
            while persisted.nextIndex < persisted.files.count {
                try Task.checkCancellation()
                if shouldPause { throw RouteFileImportError.paused }
                await Task.yield()
                let url = URL(fileURLWithPath: persisted.files[persisted.nextIndex])
                importProgressText = "Importing \(persisted.nextIndex + 1) of \(persisted.files.count): \(url.lastPathComponent)"
                let parsedDTOs = try await Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try RouteTrackParserWorker.parse(url: url)
                }.value
                try Task.checkCancellation()
                let tracks = parsedDTOs.map { $0.makeImportedTrack() }
                if tracks.contains(where: { !$0.hasOriginalTimestamps }) {
                    try quarantineFailedImport(url, configuration: persisted.configuration)
                    persisted.failedFileCount = (persisted.failedFileCount ?? 0) + 1
                } else {
                    let result = try await importTracks(
                        tracks,
                        configuration: persisted.configuration,
                        context: context,
                        repository: repository
                    )
                    persisted.routeCount += result.routeCount
                    persisted.sampleCount += result.sampleCount
                }
                persisted.nextIndex += 1
                persisted.importedFileCount = persisted.nextIndex
                persisted.updatedAt = .now
                RouteFileImportStore.state = persisted
                importProgress = Double(persisted.nextIndex) / Double(max(persisted.files.count, 1))
                updateActiveJob { job in
                    job.state = .importing
                    job.phase = .importing
                    job.counters.completedItemCount = persisted.importedFileCount
                    job.counters.routeCount = persisted.routeCount
                    job.counters.sampleCount = persisted.sampleCount
                    job.counters.failedItemCount = persisted.failedFileCount ?? 0
                    job.updatedAt = .now
                }
            }
            try repository.saveIfNeeded()
            importPhase = "Naming imported places (throttled)"
            try await geocodeImportedPlaces(in: context)
            try repository.saveIfNeeded()
            lastReport = RouteFileImportReport(
                fileCount: persisted.importedFileCount,
                routeCount: persisted.routeCount,
                sampleCount: persisted.sampleCount,
                failedFileCount: persisted.failedFileCount ?? 0
            )
            lastErrorMessage = nil
            state = .completed
            if let activeJobID, var job = importCoordinator.jobs.first(where: { $0.id == activeJobID }) {
                job.state = .completed
                job.phase = .postProcessing
                job.counters.completedItemCount = job.counters.itemCount
                job.counters.routeCount = persisted.routeCount
                job.counters.sampleCount = persisted.sampleCount
                job.counters.failedItemCount = persisted.failedFileCount ?? 0
                job.updatedAt = .now
                try? importCoordinator.update(job)
            }
            RouteFileImportStore.state = nil
            try? FileManager.default.removeItem(at: RouteFileImportStore.stagingDirectory)
            if (persisted.failedFileCount ?? 0) > 0 {
                importProgressText = "Import complete · \(persisted.failedFileCount ?? 0) awaiting a date"
            } else {
                importProgressText = "Import complete"
            }
            importPhase = "Complete"
        } catch RouteFileImportError.paused {
            persisted.state = .paused
            persisted.updatedAt = .now
            RouteFileImportStore.state = persisted
            RouteFileImportBackgroundTask.schedule()
            state = .paused
            if let activeJobID { try? importCoordinator.pause(id: activeJobID) }
            importProgressText = "Import paused"
            importPhase = "Paused — progress saved"
        } catch is CancellationError {
            persisted.state = .paused
            RouteFileImportStore.state = persisted
            RouteFileImportBackgroundTask.schedule()
            state = .paused
            if let activeJobID { try? importCoordinator.pause(id: activeJobID) }
            importPhase = "Paused — progress saved"
        } catch {
            persisted.state = .failed
            RouteFileImportStore.state = persisted
            state = .failed
            if let activeJobID, var job = importCoordinator.jobs.first(where: { $0.id == activeJobID }) {
                job.state = .failed
                job.lastError = ImportJobError(message: error.localizedDescription, isRecoverable: true, occurredAt: .now)
                job.updatedAt = .now
                try? importCoordinator.update(job)
            }
            lastErrorMessage = error.localizedDescription
            importPhase = "Import failed"
        }
    }

    private func updateActiveJob(_ update: (inout ImportJobRecord) -> Void) {
        guard let activeJobID,
              var job = importCoordinator.jobs.first(where: { $0.id == activeJobID }) else { return }
        update(&job)
        try? importCoordinator.update(job)
    }

    func resolveFailedImport(_ id: UUID, targetDate: Date) async throws {
        guard resolvingFailedImportID == nil,
              let failedImport = failedImports.first(where: { $0.id == id }) else { return }
        resolvingFailedImportID = id
        defer { resolvingFailedImportID = nil }

        let url = RouteFileImportStore.failedImportsDirectory
            .appendingPathComponent(failedImport.storedFileName)
        let parsedDTOs = try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try RouteTrackParserWorker.parse(url: url)
        }.value
        let tracks = parsedDTOs.map { $0.makeImportedTrack() }
        guard !tracks.isEmpty else { throw RouteFileImportError.noRouteGeometry }

        let retargetedTracks = retarget(tracks, to: targetDate)
        let context = ModelContext(modelContainer)
        let repository = SwiftDataTimelineRepository(modelContext: context)
        let result = try await importTracks(
            retargetedTracks,
            configuration: failedImport.configuration,
            context: context,
            repository: repository
        )
        guard result.routeCount > 0 else {
            throw RouteFileImportError.noRoutesImportedForSelectedDate
        }
        try repository.saveIfNeeded()
        removeFailedImport(id, deleteFile: true)
        NotificationCenter.default.post(name: .movesLocationSamplesDidChange, object: nil)
    }

    func discardFailedImport(_ id: UUID) {
        removeFailedImport(id, deleteFile: true)
    }

    private func importTracks(
        _ tracks: [ImportedRouteTrack],
        configuration: RouteFileImportConfiguration,
        context: ModelContext,
        repository: SwiftDataTimelineRepository
    ) async throws -> (routeCount: Int, sampleCount: Int) {
        var routeCount = 0
        var sampleCount = 0
        var previousImportedMove: MoveSegment?
        let chronologicalTracks = tracks.sorted {
            ($0.locations.first?.timestamp ?? .distantFuture) < ($1.locations.first?.timestamp ?? .distantFuture)
        }
        for track in chronologicalTracks where track.locations.count >= 2 {
            try Task.checkCancellation()
            if configuration.existingDataPolicy == .skipDate,
               try hasExistingData(for: track.locations, in: context) {
                previousImportedMove = nil
                continue
            }

            let mode = configuration.mappingMode == .dedicatedTransport
                ? configuration.dedicatedTransportMode
                : (configuration.mappingMode == .raw ? .unknown : track.transportMode)
            var chunks = [track.locations]
            if configuration.existingDataPolicy == .expandAroundExisting {
                chunks = try expandedImportChunks(for: track.locations, in: context)
            } else if configuration.existingDataPolicy == .overwriteExisting {
                try removeExistingData(overlapping: track.locations, in: context)
            }
            let importsWholeTrack = chunks.count == 1
                && chunks.first?.count == track.locations.count

            var lastMoveInTrack: MoveSegment?
            for (chunkIndex, chunk) in chunks.enumerated() where chunk.count >= 2 {
                await Task.yield()
                let precedingVisit = importsWholeTrack && chunkIndex == 0 && track.startsAfterVisitGap
                    ? previousImportedMove?.endPlace
                    : nil
                let move = try repository.importRouteTrack(
                    locations: chunk,
                    source: .fileRouteImport,
                    transportMode: mode,
                    resolvePlaceNames: false,
                    continuingFrom: precedingVisit
                )
                if let move {
                    if configuration.mappingMode != .raw {
                        _ = await RoadRouteMatcher.matchedCoordinates(for: move)
                    }
                    routeCount += 1
                    sampleCount += chunk.count
                    lastMoveInTrack = move
                }
            }
            previousImportedMove = importsWholeTrack ? lastMoveInTrack : nil
        }
        return (routeCount, sampleCount)
    }

    private func quarantineFailedImport(
        _ url: URL,
        configuration: RouteFileImportConfiguration
    ) throws {
        let sourceIdentifier = url.lastPathComponent
        guard !failedImports.contains(where: { $0.sourceImportIdentifier == sourceIdentifier }) else {
            return
        }

        let id = UUID()
        let originalFileName = Self.originalFileName(fromStagedName: url.lastPathComponent)
        let storedFileName = id.uuidString + "-" + originalFileName
        let destination = RouteFileImportStore.failedImportsDirectory
            .appendingPathComponent(storedFileName)
        try FileManager.default.copyItem(at: url, to: destination)
        let failedImport = FailedRouteImport(
            id: id,
            originalFileName: originalFileName,
            storedFileName: storedFileName,
            sourceImportIdentifier: sourceIdentifier,
            createdAt: .now,
            reason: "No reliable timestamp could be matched to every route point.",
            configuration: configuration
        )
        failedImports.append(failedImport)
        RouteFileImportStore.failedImports = failedImports
    }

    private func removeFailedImport(_ id: UUID, deleteFile: Bool) {
        guard let failedImport = failedImports.first(where: { $0.id == id }) else { return }
        if deleteFile {
            let url = RouteFileImportStore.failedImportsDirectory
                .appendingPathComponent(failedImport.storedFileName)
            try? FileManager.default.removeItem(at: url)
        }
        failedImports.removeAll { $0.id == id }
        RouteFileImportStore.failedImports = failedImports
    }

    private func retarget(
        _ tracks: [ImportedRouteTrack],
        to targetDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ImportedRouteTrack] {
        guard let earliest = tracks.flatMap(\.locations).map(\.timestamp).min(),
              let targetNoon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: targetDate)) else {
            return ImportedRouteTrackSegmentation.split(tracks)
        }
        let offset = targetNoon.timeIntervalSince(earliest)
        return tracks.map { track in
            ImportedRouteTrack(
                locations: track.locations.map { location in
                    CLLocation(
                        coordinate: location.coordinate,
                        altitude: location.altitude,
                        horizontalAccuracy: location.horizontalAccuracy,
                        verticalAccuracy: location.verticalAccuracy,
                        course: location.course,
                        speed: location.speed,
                        timestamp: location.timestamp.addingTimeInterval(offset)
                    )
                },
                transportMode: track.transportMode,
                hasOriginalTimestamps: true,
                startsAfterVisitGap: track.startsAfterVisitGap
            )
        }
    }

    private static func originalFileName(fromStagedName name: String) -> String {
        guard name.count > 37 else { return name }
        let separatorIndex = name.index(name.startIndex, offsetBy: 36)
        let possibleUUID = String(name[..<separatorIndex])
        guard UUID(uuidString: possibleUUID) != nil,
              name[separatorIndex] == "-" else { return name }
        return String(name[name.index(after: separatorIndex)...])
    }

    private func hasExistingData(for locations: [CLLocation], in context: ModelContext) throws -> Bool {
        let dayKeys = Set(locations.map { DayTimeline.makeDayKey(for: $0.timestamp) })
        let timelines = try context.fetch(FetchDescriptor<DayTimeline>())
        return timelines.contains { dayKeys.contains($0.dayKey) && $0.hasRecordedActivity }
    }

    private func occupiedIntervals(in context: ModelContext) throws -> [(Date, Date)] {
        try context.fetch(FetchDescriptor<MoveSegment>()).map { ($0.startDate, $0.endDate) }
    }

    private func expandedImportChunks(for locations: [CLLocation], in context: ModelContext) throws -> [[CLLocation]] {
        let intervals = try occupiedIntervals(in: context)
        let available = locations.filter { location in
            !intervals.contains { location.timestamp >= $0.0 && location.timestamp <= $0.1 }
        }
        guard !available.isEmpty else { return [] }
        var chunks: [[CLLocation]] = [[]]
        for location in available {
            if let previous = chunks.last?.last,
               location.timestamp.timeIntervalSince(previous.timestamp) > 10 * 60 {
                chunks.append([])
            }
            chunks[chunks.count - 1].append(location)
        }
        return chunks.filter { $0.count >= 2 }
    }

    private func removeExistingData(overlapping locations: [CLLocation], in context: ModelContext) throws {
        guard let start = locations.map(\.timestamp).min(), let end = locations.map(\.timestamp).max() else { return }
        let moves = try context.fetch(FetchDescriptor<MoveSegment>()).filter {
            $0.startDate <= end && $0.endDate >= start
        }
        let samples = try context.fetch(FetchDescriptor<LocationSample>()).filter {
            $0.timestamp >= start && $0.timestamp <= end
        }
        moves.forEach(context.delete)
        samples.forEach(context.delete)
        try context.save()
    }

    private func geocodeImportedPlaces(in context: ModelContext) async throws {
        let places: [VisitPlace]
        do {
            let importedMoveIDs = Set(
                try context.fetch(FetchDescriptor<MoveSegment>())
                    .filter { $0.samples.contains { $0.source == .fileRouteImport } }
                    .map(\.id)
            )
            places = try context.fetch(FetchDescriptor<VisitPlace>()).filter { place in
                let hasImportedMove = place.dayTimeline?.moves.contains { importedMoveIDs.contains($0.id) } == true
                let hasLabel = !(place.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(place.autoLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                return hasImportedMove && !hasLabel && place.horizontalAccuracy <= 180
            }
        } catch {
            return
        }

        guard !places.isEmpty else {
            importProgressText = "No place names need geocoding"
            return
        }

        let resolver = CLGeocoderPlaceNameResolver()
        for (index, place) in places.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: .milliseconds(1_500))
            }
            try Task.checkCancellation()
            if shouldPause { throw RouteFileImportError.paused }
            importProgressText = "Naming place \(index + 1) of \(places.count) (rate-limited)"
            if let name = await resolver.resolveName(for: place.coordinate) {
                place.autoLabel = name
                try? context.save()
            }
        }
    }

    private func prepareFiles(_ urls: [URL]) async throws -> RouteImportAcquisitionResult {
        let directory = RouteFileImportStore.stagingDirectory
        try? FileManager.default.removeItem(at: directory)
        let result = try RouteImportAcquirer(stagingDirectory: directory).acquire(urls: urls)
        return result
    }

    private func collectSupportedFiles(in directory: URL) throws -> [URL] {
        let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        return urls.filter(isSupportedRouteFile).map { url in
            let destination = RouteFileImportStore.stagingDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: destination)
            return destination
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func extractZip(_ url: URL, into directory: URL) throws -> [URL] {
        let data = try Data(contentsOf: url)
        var cursor = 0
        var files: [URL] = []
        while cursor + 46 <= data.count {
            guard data.uint32LE(at: cursor) == 0x02014B50 else { break }
            let method = data.uint16LE(at: cursor + 10)
            let compressedSize = Int(data.uint32LE(at: cursor + 20))
            let nameLength = Int(data.uint16LE(at: cursor + 28))
            let extraLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let localOffset = Int(data.uint32LE(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw RouteFileImportError.invalidArchive }
            let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""
            cursor = nameStart + nameLength + extraLength + commentLength
            let nameURL = URL(fileURLWithPath: name)
            guard isSupportedRouteFile(nameURL), !name.hasSuffix("/"), isSafeArchivePath(name) else {
                if name.hasPrefix("/") || name.split(separator: "/").contains("..") { throw RouteFileImportError.invalidArchive }
                continue
            }
            guard localOffset + 30 <= data.count, data.uint32LE(at: localOffset) == 0x04034B50 else { throw RouteFileImportError.invalidArchive }
            let localNameLength = Int(data.uint16LE(at: localOffset + 26))
            let localExtraLength = Int(data.uint16LE(at: localOffset + 28))
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            guard payloadStart + compressedSize <= data.count else { throw RouteFileImportError.invalidArchive }
            let compressed = Data(data[payloadStart..<(payloadStart + compressedSize)])
            let contents: Data
            switch method {
            case 0: contents = compressed
            case 8: contents = try inflateZipDeflate(compressed)
            default: throw RouteFileImportError.invalidArchive
            }
            let safeName = name.replacingOccurrences(of: "/", with: "-")
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + safeName)
            try contents.write(to: destination, options: .atomic)
            files.append(destination)
        }
        return files
    }

    private func inflateZipDeflate(_ data: Data) throws -> Data {
        let maximumInflatedEntrySize = 128 * 1024 * 1024
        let emptyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let emptySource = UnsafePointer<UInt8>(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
        defer {
            emptyDestination.deallocate()
            emptySource.deallocate()
        }
        var stream = compression_stream(dst_ptr: emptyDestination, dst_size: 0, src_ptr: emptySource, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw RouteFileImportError.invalidArchive
        }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        return try data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw RouteFileImportError.invalidArchive
            }
            stream.src_ptr = source
            stream.src_size = data.count
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                guard output.count + produced <= maximumInflatedEntrySize else {
                    throw RouteFileImportError.invalidArchive
                }
                output.append(buffer, count: produced)
                try Task.checkCancellation()
                if status == COMPRESSION_STATUS_ERROR { throw RouteFileImportError.invalidArchive }
                if status == COMPRESSION_STATUS_END { break }
                if stream.src_size == 0 && stream.dst_size == bufferSize { break }
            } while true
            return output
        }
    }

    private func isSupportedRouteFile(_ url: URL) -> Bool {
        ["gpx", "tcx", "kml", "geojson", "json"].contains(url.pathExtension.lowercased())
    }

    private func isSafeArchivePath(_ name: String) -> Bool {
        !name.hasPrefix("/") && !name.split(separator: "/").contains("..")
    }

    private enum RouteFileImportError: LocalizedError {
        case noFiles, paused, invalidArchive
        case noRouteGeometry
        case noRoutesImportedForSelectedDate

        var errorDescription: String? {
            switch self {
            case .noFiles:
                "No supported route files were found."
            case .paused:
                ""
            case .invalidArchive:
                "The ZIP archive could not be opened."
            case .noRouteGeometry:
                "The saved file no longer contains readable route geometry."
            case .noRoutesImportedForSelectedDate:
                "No route was imported for that date. The selected date may already contain timeline data under the original import policy."
            }
        }
    }

    // Kept for compatibility with callers from older screens.
    func importFiles(urls: [URL]) async { start(urls: urls, skipExistingDates: false); await importTask?.value }

    static func loadDroppedURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self, returning: [URL].self) { group in
            for provider in providers {
                group.addTask {
                    await Self.loadDroppedURL(from: provider)
                }
            }

            var urls: [URL] = []
            for await url in group {
                if let url { urls.append(url) }
            }
            return urls
        }
    }

    private static func loadDroppedURL(from provider: NSItemProvider) async -> URL? {
        if let sourceURL = await loadDroppedFileURL(from: provider) {
            return copyDroppedItem(at: sourceURL)
        }

        // File providers do not consistently advertise `public.file-url`. Finder,
        // iCloud Drive, and third-party providers can instead vend only the file's
        // content type. Try every representation that the provider offers and copy
        // it while the temporary representation is still valid.
        for typeIdentifier in provider.registeredTypeIdentifiers where typeIdentifier != UTType.fileURL.identifier {
            if let url = await loadDroppedFileRepresentation(
                from: provider,
                typeIdentifier: typeIdentifier
            ) {
                return url
            }
        }

        return nil
    }

    private static func loadDroppedFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { url, _ in
                continuation.resume(returning: url.flatMap(copyDroppedItem(at:)))
            }
        }
    }

    private static func loadDroppedFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let path = item as? String {
                    url = URL(string: path).flatMap { $0.isFileURL ? $0 : nil }
                        ?? URL(fileURLWithPath: path)
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    nonisolated static func copyDroppedItem(at sourceURL: URL) -> URL? {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let dropDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovesDrop-\(UUID().uuidString)", isDirectory: true)
        let fileName = sourceURL.lastPathComponent.isEmpty
            ? UUID().uuidString
            : sourceURL.lastPathComponent
        let destination = dropDirectory.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(
                at: dropDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func loadTracks(from url: URL) throws -> [ImportedRouteTrack] {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let lowercasedName = url.lastPathComponent.lowercased()
        if lowercasedName.hasSuffix(".gpx") || lowercasedName.hasSuffix(".tcx") || lowercasedName.hasSuffix(".kml") {
            return try XMLRouteTrackParser.parse(data: data, fileName: url.lastPathComponent)
        }

        if lowercasedName.hasSuffix(".geojson") || lowercasedName.hasSuffix(".json") {
            return try GeoJSONRouteTrackParser.parse(data: data, fileName: url.lastPathComponent)
        }

        // Last resort: try XML first, then GeoJSON.
        if let xmlTracks = try? XMLRouteTrackParser.parse(data: data, fileName: url.lastPathComponent),
           !xmlTracks.isEmpty {
            return xmlTracks
        }
        if let geoJSONTracks = try? GeoJSONRouteTrackParser.parse(data: data, fileName: url.lastPathComponent),
           !geoJSONTracks.isEmpty {
            return geoJSONTracks
        }

        throw NSError(
            domain: "Moves.RouteFileImport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported route format in \(url.lastPathComponent)."]
        )
    }
}

struct RouteFileImportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var configuration: RouteFileImportConfiguration
    let actionTitle: String
    let actionSystemImage: String
    let continueAction: () -> Void

    init(
        configuration: Binding<RouteFileImportConfiguration>,
        actionTitle: String = "Choose files, folder, or ZIP",
        actionSystemImage: String = "folder.badge.plus",
        continueAction: @escaping () -> Void
    ) {
        _configuration = configuration
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.continueAction = continueAction
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ImportOptionsCard(
                        title: "Route mapping",
                        subtitle: "Choose how imported coordinates become routes on your timeline.",
                        systemImage: "map"
                    ) {
                        VStack(spacing: 10) {
                            ForEach(RouteFileImportMappingMode.allCases) { mode in
                                ImportOptionChoice(
                                    title: mode.title,
                                    description: mappingDescription(for: mode),
                                    systemImage: mappingSymbol(for: mode),
                                    isSelected: configuration.mappingMode == mode
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        configuration.mappingMode = mode
                                    }
                                }
                            }

                            if configuration.mappingMode == .dedicatedTransport {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Dedicated transport mode")
                                        .font(.subheadline.weight(.semibold))
                                    Picker("Transport mode", selection: $configuration.dedicatedTransportMode) {
                                        ForEach(TransportMode.allCases) { mode in
                                            Label(mode.title, systemImage: mode.symbolName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .padding(.top, 2)
                            }
                        }
                    }

                    ImportOptionsCard(
                        title: "Existing data behaviour",
                        subtitle: "Choose what happens when imported times overlap your timeline.",
                        systemImage: "calendar"
                    ) {
                        VStack(spacing: 10) {
                            ForEach(RouteFileExistingDataPolicy.allCases) { policy in
                                ImportOptionChoice(
                                    title: policy.title,
                                    description: existingDataDescription(for: policy),
                                    systemImage: existingDataSymbol(for: policy),
                                    isSelected: configuration.existingDataPolicy == policy
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        configuration.existingDataPolicy = policy
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        continueAction()
                    } label: {
                        Label(actionTitle, systemImage: actionSystemImage)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(MovesPalette.routeTracking, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: MovesPalette.routeTracking.opacity(0.25), radius: 10, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(16)
            }
            .background {
                LinearGradient(
                    colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Import Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func mappingDescription(for mode: RouteFileImportMappingMode) -> String {
        switch mode {
        case .automatic:
            "Uses the filename and route metadata to choose a mode. Detailed flight tracks keep their recorded path instead of becoming an arc."
        case .dedicatedTransport:
            "Treats every imported route as the selected mode while keeping the detailed path supplied by the file."
        case .raw:
            "Stores the original GPS points without road or flight map matching."
        }
    }

    private func existingDataDescription(for policy: RouteFileExistingDataPolicy) -> String {
        switch policy {
        case .skipDate:
            "If a date has timeline data, the route is skipped."
        case .expandAroundExisting:
            "Existing move time ranges are excluded. Remaining points are imported as separate route chunks."
        case .overwriteExisting:
            "Existing moves and samples overlapping each imported route are removed before importing it."
        }
    }

    private func mappingSymbol(for mode: RouteFileImportMappingMode) -> String {
        switch mode {
        case .automatic: "wand.and.stars"
        case .dedicatedTransport: "airplane"
        case .raw: "point.3.connected.trianglepath.dotted"
        }
    }

    private func existingDataSymbol(for policy: RouteFileExistingDataPolicy) -> String {
        switch policy {
        case .skipDate: "calendar.badge.exclamationmark"
        case .expandAroundExisting: "arrow.left.and.right"
        case .overwriteExisting: "arrow.triangle.2.circlepath"
        }
    }
}

private struct ImportOptionsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MovesPalette.routeTracking)
                    .frame(width: 34, height: 34)
                    .background(MovesPalette.routeTracking.opacity(0.12), in: Circle())
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ImportOptionChoice: View {
    let title: String
    let description: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? MovesPalette.routeTracking : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        (isSelected ? MovesPalette.routeTracking : Color.secondary).opacity(0.12),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? MovesPalette.routeTracking : .secondary)
            }
            .padding(12)
            .background(
                isSelected ? MovesPalette.routeTracking.opacity(0.10) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? MovesPalette.routeTracking.opacity(0.45) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

enum RouteFileImportBackgroundTask {
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: RouteFileImportStore.taskIdentifier, using: nil) { task in
            let work = Task { @MainActor in
                defer { task.setTaskCompleted(success: true) }
                guard let processing = task as? BGProcessingTask else { return }
                do {
                    let container = try MovesApp.makeModelContainer()
                    let importer = RouteFileImporter(modelContext: ModelContext(container))
                    await importer.resumeAndWait()
                    processing.expirationHandler = { importer.pause() }
                } catch {
                    task.setTaskCompleted(success: false)
                }
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: RouteFileImportStore.taskIdentifier)
        guard RouteFileImportStore.state != nil else { return }
        let request = BGProcessingTaskRequest(identifier: RouteFileImportStore.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct RouteFileImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var importer: RouteFileImporter
    @State private var isShowingFileImporter = false
    @State private var importMessage = ""
    @State private var isShowingImportMessage = false
    @State private var skipExistingDates = true
    @StateObject private var dataManager: ImportedRouteDataManager
    @State private var filterByDate = false
    @State private var filterStartDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var filterEndDate = Date.now
    @State private var selectedTransportMode = "all"
    @State private var isConfirmingRemoval = false
    @State private var removalMessage = ""
    @State private var isShowingRemovalMessage = false

    init(importer: RouteFileImporter, modelContext: ModelContext) {
        self.importer = importer
        _dataManager = StateObject(wrappedValue: ImportedRouteDataManager(modelContext: modelContext))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                RouteImportCard(title: "Route Files") {
                    RouteImportActionRow(
                        title: importer.isImporting ? "Importing route files..." : "Import route files",
                        systemImage: "square.and.arrow.down",
                        isDisabled: importer.isImporting
                    ) {
                        isShowingFileImporter = true
                    }

                    if importer.state != .idle {
                        if let progress = importer.importProgress {
                            ProgressView(value: progress)
                                .tint(MovesPalette.routeTracking)
                        } else {
                            ProgressView()
                                .tint(MovesPalette.routeTracking)
                        }

                        if !importer.importProgressText.isEmpty {
                            Text(importer.importProgressText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button(importer.isImporting ? "Pause" : "Resume") {
                                importer.isImporting ? importer.pause() : importer.resume()
                            }
                            .disabled(importer.state == .completed)
                            Button("Restart") { importer.restart() }
                            Button("Cancel", role: .destructive) { importer.cancel() }
                        }
                    }

                    Toggle("Skip dates that already contain data", isOn: $skipExistingDates)

                    Text("Supports individual files, folders, and ZIP archives. Duplicate points are merged automatically. Imports can continue in the background and resume after an interruption.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    NavigationLink {
                        FailedRouteImportsView(importer: importer)
                    } label: {
                        Label(
                            "Failed Imports (\(importer.failedImports.count))",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                    }
                    .buttonStyle(.bordered)

                    ImportedRouteDataManagementView(
                        manager: dataManager,
                        filterByDate: $filterByDate,
                        startDate: $filterStartDate,
                        endDate: $filterEndDate,
                        selectedTransportMode: $selectedTransportMode,
                        isConfirmingRemoval: $isConfirmingRemoval,
                        removalMessage: $removalMessage,
                        isShowingRemovalMessage: $isShowingRemovalMessage
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("File Route Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: RouteFileImportContentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    importer.start(urls: urls, skipExistingDates: skipExistingDates)
                    await importer.resumeAndWait()
                    if let report = importer.lastReport {
                        importMessage = "Imported \(report.routeCount) route(s) from \(report.fileCount) file(s), covering \(report.sampleCount) GPS point(s)." + (report.failedFileCount > 0 ? " \(report.failedFileCount) file(s) need a target date in Failed Imports." : "")
                    } else {
                        importMessage = importer.lastErrorMessage ?? "No route data was imported."
                    }
                    isShowingImportMessage = true
                }
            case .failure(let error):
                importMessage = "File import failed: \(error.localizedDescription)"
                isShowingImportMessage = true
            }
        }
        .alert("File Route Import", isPresented: $isShowingImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
        .alert("Remove imported data?", isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) {
                do {
                    try dataManager.remove(using: currentFilter)
                    removalMessage = "Removed the matching imported route data."
                } catch {
                    removalMessage = "Could not remove imported data: \(error.localizedDescription)"
                }
                isShowingRemovalMessage = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes imported GPS samples, route moves that contain no remaining samples, and their unused generated endpoint places. Empty imported days are removed too. Phone, watch, and Health samples are kept.")
        }
        .alert("Imported Route Data", isPresented: $isShowingRemovalMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
        .task {
            dataManager.refresh(using: currentFilter)
        }
        .onChange(of: filterByDate) { _, _ in refreshDataManagement() }
        .onChange(of: filterStartDate) { _, _ in refreshDataManagement() }
        .onChange(of: filterEndDate) { _, _ in refreshDataManagement() }
        .onChange(of: selectedTransportMode) { _, _ in refreshDataManagement() }
    }

    private var currentFilter: ImportedRouteDataFilter {
        ImportedRouteDataFilter(
            startDate: filterByDate ? Calendar.current.startOfDay(for: filterStartDate) : nil,
            endDate: filterByDate ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: filterEndDate) : nil,
            transportMode: selectedTransportMode == "all" ? nil : TransportMode(rawValue: selectedTransportMode)
        )
    }

    private func refreshDataManagement() {
        dataManager.refresh(using: currentFilter)
    }
}

struct FailedRouteImportsView: View {
    @ObservedObject var importer: RouteFileImporter
    @State private var targetDates: [UUID: Date] = [:]
    @State private var message = ""
    @State private var isShowingMessage = false
    @State private var pendingDiscard: FailedRouteImport?

    var body: some View {
        List {
            if importer.failedImports.isEmpty {
                ContentUnavailableView(
                    "No Failed Imports",
                    systemImage: "checkmark.circle",
                    description: Text("Files with ambiguous or missing timestamps will appear here before any timeline data is written.")
                )
            } else {
                ForEach(importer.failedImports) { failedImport in
                    Section {
                        DatePicker(
                            "Target date",
                            selection: targetDateBinding(for: failedImport.id),
                            displayedComponents: .date
                        )

                        Button {
                            importFailed(failedImport)
                        } label: {
                            if importer.resolvingFailedImportID == failedImport.id {
                                HStack {
                                    ProgressView()
                                    Text("Importing…")
                                }
                            } else {
                                Label("Import on selected date", systemImage: "calendar.badge.checkmark")
                            }
                        }
                        .disabled(importer.resolvingFailedImportID != nil)

                        Button("Discard saved import", role: .destructive) {
                            pendingDiscard = failedImport
                        }
                        .disabled(importer.resolvingFailedImportID != nil)
                    } header: {
                        Text(failedImport.originalFileName)
                    } footer: {
                        Text(failedImport.reason)
                    }
                }
            }
        }
        .navigationTitle("Failed Imports")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Failed Imports", isPresented: $isShowingMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
        .confirmationDialog(
            "Discard this saved import?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if let id = pendingDiscard?.id {
                    importer.discardFailedImport(id)
                }
                pendingDiscard = nil
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("The quarantined file will be deleted. No timeline data has been written from it.")
        }
    }

    private func targetDateBinding(for id: UUID) -> Binding<Date> {
        Binding(
            get: { targetDates[id] ?? .now },
            set: { targetDates[id] = $0 }
        )
    }

    private func importFailed(_ failedImport: FailedRouteImport) {
        let targetDate = targetDates[failedImport.id] ?? .now
        Task { @MainActor in
            do {
                try await importer.resolveFailedImport(failedImport.id, targetDate: targetDate)
                message = "Imported \(failedImport.originalFileName) on \(targetDate.formatted(date: .long, time: .omitted))."
            } catch {
                message = error.localizedDescription
            }
            isShowingMessage = true
        }
    }
}

struct ImportedRouteDataManagementView: View {
    @ObservedObject var manager: ImportedRouteDataManager
    @Binding var filterByDate: Bool
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var selectedTransportMode: String
    @Binding var isConfirmingRemoval: Bool
    @Binding var removalMessage: String
    @Binding var isShowingRemovalMessage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Manage imported data")
                .font(.headline)
            Toggle("Filter by date", isOn: $filterByDate)
            if filterByDate {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                DatePicker("To", selection: $endDate, displayedComponents: .date)
            }
            Picker("Transport", selection: $selectedTransportMode) {
                Text("All modes").tag("all")
                ForEach(TransportMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text("Matching imported samples: \(manager.report.sampleCount) · routes: \(manager.report.moveCount)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Button("Remove matching imported data", role: .destructive) {
                isConfirmingRemoval = true
            }
            .disabled(manager.isRemoving || manager.report.sampleCount == 0)
        }
    }
}

private struct RouteImportCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

private struct RouteImportActionRow: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : MovesPalette.routeTracking)

                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

enum RouteFileImportContentTypes {
    static let allowed: [UTType] = [
        .folder,
        .archive,
        .xml,
        .json,
        UTType(filenameExtension: "gpx") ?? .xml,
        UTType(filenameExtension: "tcx") ?? .xml,
        UTType(filenameExtension: "kml") ?? .xml,
        UTType(filenameExtension: "geojson") ?? .json
    ]

}

struct RouteFileDropItem: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { receivedFile in
            guard let stagedURL = RouteFileImporter.copyDroppedItem(at: receivedFile.file) else {
                throw CocoaError(.fileReadUnknown)
            }
            return RouteFileDropItem(url: stagedURL)
        }
    }
}

struct ImportedRouteTrack {
    let locations: [CLLocation]
    let transportMode: TransportMode
    let hasOriginalTimestamps: Bool
    var startsAfterVisitGap: Bool = false
}

/// The parser boundary deliberately contains only value types.  In particular, CLLocation is
/// Foundation/UIKit state and must not cross the worker task boundary.
struct RouteTrackPointDTO: Sendable, Hashable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
}

struct RouteTrackDTO: Sendable {
    let points: [RouteTrackPointDTO]
    let transportMode: TransportMode
    let hasOriginalTimestamps: Bool
    var startsAfterVisitGap = false

    func makeImportedTrack() -> ImportedRouteTrack {
        ImportedRouteTrack(
            locations: points.map {
                CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    altitude: $0.altitude,
                    horizontalAccuracy: 5,
                    verticalAccuracy: $0.altitude == 0 ? -1 : 5,
                    course: -1,
                    speed: -1,
                    timestamp: $0.timestamp
                )
            },
            transportMode: transportMode,
            hasOriginalTimestamps: hasOriginalTimestamps,
            startsAfterVisitGap: startsAfterVisitGap
        )
    }
}

private enum RouteTrackParserWorker {
    private static let pointChunkSize = 4_096

    static func parse(url: URL) throws -> [RouteTrackDTO] {
        let name = url.lastPathComponent
        let lowercasedName = name.lowercased()
        if lowercasedName.hasSuffix(".gpx") || lowercasedName.hasSuffix(".tcx") || lowercasedName.hasSuffix(".kml") {
            return try XMLRouteTrackParser.parse(url: url, fileName: name).flatMap {
                chunk(RouteTrackDTO(points: $0.locations.map {
                    RouteTrackPointDTO(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                                       altitude: $0.altitude, timestamp: $0.timestamp)
                }, transportMode: $0.transportMode, hasOriginalTimestamps: $0.hasOriginalTimestamps
                ))
            }
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if lowercasedName.hasSuffix(".geojson") || lowercasedName.hasSuffix(".json") {
            return try GeoJSONRouteTrackParser.parse(data: data, fileName: name).flatMap { track in
                chunk(RouteTrackDTO(points: track.locations.map {
                    RouteTrackPointDTO(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                                       altitude: $0.altitude, timestamp: $0.timestamp)
                }, transportMode: track.transportMode, hasOriginalTimestamps: track.hasOriginalTimestamps,
                    startsAfterVisitGap: track.startsAfterVisitGap
                ))
            }
        }
        return []
    }

    private static func chunk(_ track: RouteTrackDTO) -> [RouteTrackDTO] {
        guard track.points.count > pointChunkSize else { return [track] }
        return stride(from: 0, to: track.points.count, by: pointChunkSize).compactMap { start in
            let end = min(start + pointChunkSize, track.points.count)
            guard end - start >= 2 else { return nil }
            return RouteTrackDTO(points: Array(track.points[start..<end]),
                                 transportMode: track.transportMode,
                                 hasOriginalTimestamps: track.hasOriginalTimestamps,
                                 startsAfterVisitGap: start == 0 && track.startsAfterVisitGap)
        }
    }
}

private enum ImportedRouteTrackSegmentation {
    static func split(_ tracks: [ImportedRouteTrack]) -> [ImportedRouteTrack] {
        var result: [ImportedRouteTrack] = []

        for track in tracks {
            let ordered = track.locations.sorted { $0.timestamp < $1.timestamp }
            guard ordered.count >= 2 else { continue }
            var current: [CLLocation] = [ordered[0]]

            for location in ordered.dropFirst() {
                if let previous = current.last, isVisitGap(from: previous, to: location) {
                    if current.count >= 2 {
                        result.append(ImportedRouteTrack(
                            locations: current,
                            transportMode: track.transportMode,
                            hasOriginalTimestamps: track.hasOriginalTimestamps,
                            startsAfterVisitGap: result.isEmpty ? track.startsAfterVisitGap : false
                        ))
                    }
                    current = [location]
                    continue
                }
                current.append(location)
            }

            if current.count >= 2 {
                result.append(ImportedRouteTrack(
                    locations: current,
                    transportMode: track.transportMode,
                    hasOriginalTimestamps: track.hasOriginalTimestamps
                ))
            }
        }

        result.sort {
            ($0.locations.first?.timestamp ?? .distantFuture) < ($1.locations.first?.timestamp ?? .distantFuture)
        }
        guard result.count > 1 else { return result }
        for index in result.indices.dropFirst() {
            guard let previous = result[index - 1].locations.last,
                  let next = result[index].locations.first else { continue }
            result[index].startsAfterVisitGap = isVisitGap(from: previous, to: next)
        }
        return result
    }

    static func isVisitGap(from previous: CLLocation, to next: CLLocation) -> Bool {
        let duration = next.timestamp.timeIntervalSince(previous.timestamp)
        guard duration >= 15 * 60 else { return false }
        let distance = previous.distance(from: next)
        return distance <= 5_000 && distance / duration <= 1
    }
}

private enum GeoJSONRouteTrackParser {
    static func parse(data: Data, fileName: String) throws -> [ImportedRouteTrack] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var tracks: [ImportedRouteTrack] = []
        let mode = inferTransportMode(from: fileName)

        if let type = object["type"] as? String, type == "FeatureCollection",
           let features = object["features"] as? [[String: Any]] {
            for feature in features {
                guard let geometry = feature["geometry"] as? [String: Any],
                      let geometryType = geometry["type"] as? String else { continue }
                tracks.append(contentsOf: parseGeometry(geometry, type: geometryType, transportMode: mode))
            }
            return tracks
        }

        if let type = object["type"] as? String {
            tracks.append(contentsOf: parseGeometry(object, type: type, transportMode: mode))
        }

        return ImportedRouteTrackSegmentation.split(tracks)
    }

    private static func parseGeometry(_ geometry: [String: Any], type: String, transportMode: TransportMode) -> [ImportedRouteTrack] {
        switch type {
        case "LineString":
            let locations = locationsFromCoordinates(geometry["coordinates"])
            return locations.count >= 2 ? [ImportedRouteTrack(
                locations: locations,
                transportMode: transportMode,
                hasOriginalTimestamps: false
            )] : []
        case "MultiLineString":
            guard let lines = geometry["coordinates"] as? [[[Double]]] else { return [] }
            return lines.compactMap { line in
                let locations = locationsFromLine(line)
                return locations.count >= 2 ? ImportedRouteTrack(
                    locations: locations,
                    transportMode: transportMode,
                    hasOriginalTimestamps: false
                ) : nil
            }
        default:
            return []
        }
    }

    private static func locationsFromCoordinates(_ coordinates: Any?) -> [CLLocation] {
        guard let line = coordinates as? [[Double]] else { return [] }
        return locationsFromLine(line)
    }

    private static func locationsFromLine(_ line: [[Double]]) -> [CLLocation] {
        let start = Date()
        return line.enumerated().compactMap { index, point in
            guard point.count >= 2 else { return nil }
            let timestamp = start.addingTimeInterval(TimeInterval(index))
            let altitude = point.count > 2 ? point[2] : 0
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point[1], longitude: point[0]),
                altitude: altitude,
                horizontalAccuracy: 5,
                verticalAccuracy: altitude == 0 ? -1 : 5,
                course: -1,
                speed: -1,
                timestamp: timestamp
            )
        }
    }
}

final class XMLRouteTrackParser: NSObject, XMLParserDelegate {
    private struct ParsedTrack {
        var locations: [CLLocation]
        var hasOriginalTimestamps: Bool
    }

    private var tracks: [ParsedTrack] = []
    private var currentTrack: [CLLocation] = []
    private var currentTrackUsesFallbackTimestamp = false
    private var kmlPointTrack: [CLLocation] = []
    private var kmlPointTrackUsesFallbackTimestamp = false
    private var kmlLineTracks: [ParsedTrack] = []
    private var gxTrackTimes: [Date] = []
    private var gxTrackLocations: [CLLocation] = []
    private var gxTrackUsesFallbackTimestamp = false
    private var currentCoordinate: CLLocationCoordinate2D?
    private var currentAltitude: Double?
    private var currentTimestamp: Date?
    private var placemarkNameTimestamp: Date?
    private var pendingKMLPointCoordinate: CLLocationCoordinate2D?
    private var pendingKMLPointAltitude: Double?
    private var currentText = ""
    private var fallbackTimestamp = Date()
    private var transportMode: TransportMode
    private var isInsideKMLPoint = false
    private var isInsideKMLLineString = false
    private var isInsideGXTrack = false
    private var isInsideKMLPlacemark = false

    init(fileName: String) {
        self.transportMode = inferTransportMode(from: fileName)
    }

    static func parse(data: Data, fileName: String) throws -> [ImportedRouteTrack] {
        let parser = XMLParser(data: data)
        let delegate = XMLRouteTrackParser(fileName: fileName)
        parser.delegate = delegate
        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            return []
        }

        delegate.finalizeCurrentTrack()
        delegate.finalizeKMLGeometry()
        let parsedTracks = delegate.tracks
            .filter { $0.locations.count >= 2 }
            .map { ImportedRouteTrack(
                locations: $0.locations,
                transportMode: delegate.transportMode,
                hasOriginalTimestamps: $0.hasOriginalTimestamps
            ) }
        return ImportedRouteTrackSegmentation.split(parsedTracks)
    }

    static func parse(url: URL, fileName: String) throws -> [ImportedRouteTrack] {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        let parser = XMLParser(stream: stream)
        let delegate = XMLRouteTrackParser(fileName: fileName)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        delegate.finalizeCurrentTrack()
        delegate.finalizeKMLGeometry()
        let parsedTracks = delegate.tracks
            .filter { $0.locations.count >= 2 }
            .map { ImportedRouteTrack(locations: $0.locations, transportMode: delegate.transportMode,
                                      hasOriginalTimestamps: $0.hasOriginalTimestamps) }
        return ImportedRouteTrackSegmentation.split(parsedTracks)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        let name = localName(elementName)

        if name == "trkseg" || (name == "Track" && !elementName.hasPrefix("gx:")) {
            finalizeCurrentTrack()
        }

        if name == "Placemark" {
            isInsideKMLPlacemark = true
            currentTimestamp = nil
            placemarkNameTimestamp = nil
            pendingKMLPointCoordinate = nil
            pendingKMLPointAltitude = nil
        }

        if name == "Point" {
            isInsideKMLPoint = true
        } else if name == "LineString" {
            isInsideKMLLineString = true
        } else if name == "Track", elementName.hasPrefix("gx:") {
            isInsideGXTrack = true
            gxTrackTimes.removeAll(keepingCapacity: true)
            gxTrackLocations.removeAll(keepingCapacity: true)
        }

        if name == "trkpt" {
            if let latString = attributeDict["lat"],
               let lonString = attributeDict["lon"],
               let latitude = Double(latString),
               let longitude = Double(lonString) {
                currentCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            currentAltitude = nil
            currentTimestamp = nil
        }

        if name == "Trackpoint" || name == "Position" {
            currentCoordinate = nil
            currentAltitude = nil
            currentTimestamp = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = localName(elementName)
        defer { currentText = "" }

        switch name {
        case "lat", "LatitudeDegrees":
            if let latitude = Double(text) {
                currentCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: currentCoordinate?.longitude ?? 0)
            }
        case "lon", "LongitudeDegrees":
            if let longitude = Double(text) {
                currentCoordinate = CLLocationCoordinate2D(latitude: currentCoordinate?.latitude ?? 0, longitude: longitude)
            }
        case "ele", "AltitudeMeters":
            currentAltitude = Double(text)
        case "time", "Time", "begin":
            currentTimestamp = parseDate(text)
        case "when":
            if let timestamp = parseDate(text) {
                if isInsideGXTrack {
                    gxTrackTimes.append(timestamp)
                } else {
                    currentTimestamp = timestamp
                }
            }
        case "trkpt", "Trackpoint":
            appendCurrentPointIfPossible()
        case "coordinates":
            appendKMLCoordinates(text)
        case "coord" where isInsideGXTrack:
            appendGXCoordinate(text)
        case "name", "desc", "description":
            if transportMode == .unknown {
                transportMode = inferTransportMode(from: text)
            }
            if name == "name", isInsideKMLPlacemark, placemarkNameTimestamp == nil {
                placemarkNameTimestamp = parseDate(text)
            }
        case "Point":
            isInsideKMLPoint = false
        case "LineString":
            isInsideKMLLineString = false
        case "Track" where elementName.hasPrefix("gx:"):
            finalizeGXTrack()
            isInsideGXTrack = false
        case "Placemark":
            finalizeKMLPlacemarkPoint()
            isInsideKMLPlacemark = false
        case "trkseg", "Track":
            finalizeCurrentTrack()
        default:
            break
        }
    }

    private func appendCurrentPointIfPossible() {
        guard let coordinate = currentCoordinate else { return }
        if currentTimestamp == nil {
            currentTrackUsesFallbackTimestamp = true
        }
        let timestamp = currentTimestamp ?? fallbackTimestamp
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        let altitude = currentAltitude ?? 0
        let location = CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: altitude == 0 ? -1 : 5,
            course: -1,
            speed: -1,
            timestamp: timestamp
        )
        currentTrack.append(location)
        currentCoordinate = nil
        currentAltitude = nil
        currentTimestamp = nil
    }

    private func appendKMLCoordinates(_ text: String) {
        let coordinateValues = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .compactMap { chunk -> (longitude: Double, latitude: Double, altitude: Double)? in
                let values = chunk.split(separator: ",").compactMap { Double($0) }
                guard values.count >= 2 else { return nil }
                return (values[0], values[1], values.count > 2 ? values[2] : 0)
            }

        if isInsideKMLPoint {
            if let values = coordinateValues.first {
                pendingKMLPointCoordinate = CLLocationCoordinate2D(
                    latitude: values.latitude,
                    longitude: values.longitude
                )
                pendingKMLPointAltitude = values.altitude
            }
        } else if isInsideKMLLineString, coordinateValues.count >= 2 {
            let locations = coordinateValues.map { values -> CLLocation in
                let timestamp = fallbackTimestamp
                fallbackTimestamp = timestamp.addingTimeInterval(1)
                return makeLocation(
                    longitude: values.longitude,
                    latitude: values.latitude,
                    altitude: values.altitude,
                    timestamp: timestamp
                )
            }
            // A LineString has geometry but no per-point time axis. Even a placemark-level
            // timestamp cannot safely place each coordinate on the personal timeline.
            kmlLineTracks.append(ParsedTrack(
                locations: locations,
                hasOriginalTimestamps: false
            ))
        }
    }

    private func finalizeKMLPlacemarkPoint() {
        guard let coordinate = pendingKMLPointCoordinate else { return }
        let originalTimestamp = currentTimestamp ?? placemarkNameTimestamp
        if originalTimestamp == nil {
            kmlPointTrackUsesFallbackTimestamp = true
        }
        let timestamp = originalTimestamp ?? fallbackTimestamp
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        kmlPointTrack.append(makeLocation(
            longitude: coordinate.longitude,
            latitude: coordinate.latitude,
            altitude: pendingKMLPointAltitude ?? 0,
            timestamp: timestamp
        ))
        currentTimestamp = nil
        placemarkNameTimestamp = nil
        pendingKMLPointCoordinate = nil
        pendingKMLPointAltitude = nil
    }

    private func appendGXCoordinate(_ text: String) {
        let values = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
        guard values.count >= 2 else { return }
        let index = gxTrackLocations.count
        let hasOriginalTimestamp = gxTrackTimes.indices.contains(index)
        if !hasOriginalTimestamp {
            gxTrackUsesFallbackTimestamp = true
        }
        let timestamp = hasOriginalTimestamp ? gxTrackTimes[index] : fallbackTimestamp
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        gxTrackLocations.append(makeLocation(
            longitude: values[0],
            latitude: values[1],
            altitude: values.count > 2 ? values[2] : 0,
            timestamp: timestamp
        ))
    }

    private func finalizeGXTrack() {
        if gxTrackLocations.count >= 2 {
            tracks.append(ParsedTrack(
                locations: gxTrackLocations,
                hasOriginalTimestamps: !gxTrackUsesFallbackTimestamp
            ))
        }
        gxTrackTimes.removeAll(keepingCapacity: true)
        gxTrackLocations.removeAll(keepingCapacity: true)
        gxTrackUsesFallbackTimestamp = false
    }

    private func finalizeCurrentTrack() {
        guard currentTrack.count >= 2 else {
            currentTrack.removeAll(keepingCapacity: true)
            currentTrackUsesFallbackTimestamp = false
            return
        }

        tracks.append(ParsedTrack(
            locations: currentTrack.sorted(by: { $0.timestamp < $1.timestamp }),
            hasOriginalTimestamps: !currentTrackUsesFallbackTimestamp
        ))
        currentTrack.removeAll(keepingCapacity: true)
        currentTrackUsesFallbackTimestamp = false
    }

    private func finalizeKMLGeometry() {
        // Some flight exporters store the same route both as timestamped Point
        // placemarks and as many tiny LineStrings. Keep one detailed route.
        guard !tracks.contains(where: { $0.locations.count >= 2 }) else { return }
        let stitchedLines = stitchContiguous(kmlLineTracks)
        if kmlPointTrack.count >= (stitchedLines.map(\.locations.count).max() ?? 0),
           kmlPointTrack.count >= 2 {
            tracks.append(ParsedTrack(
                locations: kmlPointTrack.sorted(by: { $0.timestamp < $1.timestamp }),
                hasOriginalTimestamps: !kmlPointTrackUsesFallbackTimestamp
            ))
        } else {
            tracks.append(contentsOf: stitchedLines.filter { $0.locations.count >= 2 })
        }
    }

    private func stitchContiguous(_ lineTracks: [ParsedTrack]) -> [ParsedTrack] {
        var result: [ParsedTrack] = []
        for line in lineTracks where line.locations.count >= 2 {
            guard var current = result.popLast() else {
                result.append(line)
                continue
            }
            if let end = current.locations.last,
               let start = line.locations.first,
               end.distance(from: start) <= 100 {
                current.locations.append(contentsOf: line.locations.dropFirst())
                current.hasOriginalTimestamps = current.hasOriginalTimestamps && line.hasOriginalTimestamps
                result.append(current)
            } else {
                result.append(current)
                result.append(line)
            }
        }
        return result
    }

    private func makeLocation(
        longitude: Double,
        latitude: Double,
        altitude: Double,
        timestamp: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: altitude == 0 ? -1 : 5,
            course: -1,
            speed: -1,
            timestamp: timestamp
        )
    }

    private func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }
}

private extension Array where Element == URL {
    var uniqueForImport: [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []
        for url in self {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(url)
        }
        return ordered
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(uint16LE(at: offset)) | (UInt32(uint16LE(at: offset + 2)) << 16)
    }
}

private func parseDate(_ value: String) -> Date? {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let date = ISO8601DateFormatter.withFractional.date(from: candidate) {
        return date
    }
    if let date = ISO8601DateFormatter.withoutFractional.date(from: candidate) {
        return date
    }
    for formatter in RouteImportDateFormatters.all {
        if let date = formatter.date(from: candidate) { return date }
    }
    return nil
}

private enum RouteImportDateFormatters {
    static let all: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss 'UTC'",
        "yyyy-MM-dd HH:mm 'UTC'",
        "yyyy-MM-dd HH:mm:ss ZZZZZ",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy/MM/dd HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

func inferTransportMode(from fileName: String) -> TransportMode {
    let name = fileName.lowercased()
    if name.contains("run") || name.contains("jog") {
        return .running
    }
    if name.contains("ride") || name.contains("bike") || name.contains("cycle") {
        return .cycling
    }
    if name.contains("swim") || name.contains("pool") || name.contains("openwater") {
        return .swimming
    }
    if name.contains("walk") || name.contains("hike") {
        return .walking
    }
    if name.contains("train") {
        return .train
    }
    if name.contains("boat") || name.contains("ferry") {
        return .boat
    }
    if name.contains("flight") || name.contains("plane") || name.contains("aircraft")
        || name.contains("airport") || name.contains("flightradar") {
        return .plane
    }
    let flightDesignatorPattern = #"(?i)(^|[^A-Z0-9])[A-Z]{2,3}\s?\d{2,4}([^A-Z0-9]|$)"#
    if name.range(of: flightDesignatorPattern, options: .regularExpression) != nil {
        return .plane
    }
    if name.contains("drive") || name.contains("car") {
        return .automotive
    }
    return .unknown
}
