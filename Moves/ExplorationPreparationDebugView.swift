#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ExplorationPreparationDebugView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(ExplorationPreparation.isEnabledKey) private var preparationIsEnabled = false
    @State private var statistics: ExplorationPreparationStatistics?
    @State private var queueSnapshot: ExplorationWorkQueueSnapshot?
    @State private var migrationStatus = ExplorationFileProtectionMigration.status()
    @State private var diagnosticCopied = false
    @State private var errorMessage: String?
    @State private var sliceMessage: String?
    @State private var isConfirmingReset = false
    @State private var isResetting = false
    @State private var isRunningSlice = false
    @State private var isRunningCatchUp = false
    @State private var catchUpTask: Task<Void, Never>?
    @State private var isRebuildingCache = false
    @State private var isShowingFogImporter = false
    @State private var isImportingFog = false
    @State private var fogImportMessage: String?
    @State private var isExportingFog = false
    @State private var fogExportDocument: FogDebugExportDocument?
    @State private var isShowingFogExporter = false
    @State private var includeFlightsInFogExport = false
    @State private var exportAsFWSS = false

    private let checkpointStore = ExplorationPreparationCheckpointStore()

    var body: some View {
        List {
            Section("Preparation") {
                Toggle("Enable hidden preparation", isOn: $preparationIsEnabled)
                    .onChange(of: preparationIsEnabled) { _, enabled in
                        if enabled {
                            ExplorationPreparationBackgroundTask.schedule()
                        }
                    }
                Text("This switch is DEBUG-only. It enables bounded background preparation for testing and never exposes Exploration navigation in a release build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { @MainActor in
                        await runOnePreparationSlice()
                    }
                } label: {
                    Label(
                        isRunningSlice ? "Running preparation slice…" : "Run one preparation slice",
                        systemImage: "play.fill"
                    )
                }
                .disabled(isRunningSlice || isResetting || isRebuildingCache)

                Button {
                    startCatchUp()
                } label: {
                    Label(isRunningCatchUp ? "Catch-up running…" : "Prepare historical map now", systemImage: "bolt.fill")
                }
                .disabled(isRunningSlice || isRunningCatchUp || isResetting || isRebuildingCache)

                if isRunningCatchUp {
                    Button(role: .cancel) {
                        catchUpTask?.cancel()
                    } label: {
                        Label("Stop catch-up", systemImage: "stop.fill")
                    }
                }

                Text("Processes at most one bounded DayTimeline work unit. This does not enable automatic background scheduling.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let sliceMessage {
                    Text(sliceMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let statistics {
                    debugRow("State", stateText(for: statistics.checkpoint.readiness))
                    debugRow("Processed", processedText(for: statistics))
                    debugRow("Remaining", remainingText(for: statistics))

                    if let fraction = statistics.progressFraction {
                        ProgressView(value: fraction)
                            .accessibilityLabel("Preparation progress")
                            .accessibilityValue(processedText(for: statistics))
                    }

                    if let processedThroughDayKey = statistics.checkpoint.processedThroughDayKey {
                        debugRow("Processed through", processedThroughDayKey)
                    }

                    if let queueSnapshot {
                        debugRow("Queued work", queueSnapshot.queuedCount.formatted())
                        debugRow("Delayed / backoff", queueSnapshot.delayedCount.formatted())
                        debugRow("Processing work", queueSnapshot.processingCount.formatted())
                        ForEach(ExplorationWorkLane.allCases, id: \.self) { lane in
                            debugRow("\(lane.title) lane", (queueSnapshot.countsByLane[lane] ?? 0).formatted())
                        }
                        if queueSnapshot.staleProcessingCount > 0 {
                            debugRow("Stale leases", queueSnapshot.staleProcessingCount.formatted())
                        }
                        ForEach(queueSnapshot.recentFailures, id: \.id) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Last failure · \(item.dayKey) · \(item.lane.title) · attempt \(item.attempts)")
                                Text(item.lastError ?? "Unknown error")
                                    .foregroundStyle(.secondary)
                                if let retry = item.nextEligibleAt {
                                    Text("Retry eligible \(retry.formatted(date: .abbreviated, time: .shortened))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.footnote)
                        }
                    }
                } else {
                    Text("No preparation checkpoint has been written yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Background scheduler") {
                let defaults = UserDefaults.standard
                Button {
                    copyDiagnosticReport()
                } label: {
                    Label(diagnosticCopied ? "Diagnostic report copied" : "Copy sanitized diagnostic report", systemImage: "doc.on.doc")
                }
                if let data = defaults.data(forKey: "Moves.exploration.preparation.lastStage"),
                   let event = try? JSONDecoder().decode(ExplorationStageDebugRecord.self, from: data) {
                    debugRow("Last preparation stage", [event.stage, event.dayKey, event.lane, event.routeCount.map { "\($0) routes" }].compactMap { $0 }.joined(separator: " · "))
                    debugRow("Stage correlation", "\(event.context) · run \(event.runID ?? "foreground") · slice \(event.sliceID ?? "unknown") · #\(event.sequence)")
                    if let ended = event.endedAt {
                        let duration = event.durationMilliseconds.map { formatDuration($0 / 1_000) }
                            ?? formatDuration(ended.timeIntervalSince(event.startedAt))
                        debugRow("Stage duration", "\(duration) · P95 \(percentile95(defaults.array(forKey: "Moves.exploration.preparation.stageDurations.\(event.stage)")))")
                    } else {
                        debugRow("Stage status", "Started \(event.startedAt.formatted(date: .abbreviated, time: .shortened)); no completion recorded")
                    }
                    if let error = event.error { debugRow("Stage error", error) }
                }
                if let failure = defaults.dictionary(forKey: "Moves.exploration.protectedReadFailure") {
                    let component = failure["pathComponent"] as? String ?? "unknown file"
                    let domain = failure["domain"] as? String ?? "unknown error"
                    let code = failure["code"] as? Int ?? 0
                    let protection = failure["protectionClass"] as? String ?? "unknown class"
                    let available = failure["protectedDataAvailable"] as? Bool ?? false
                    let background = failure["attemptedInBackground"] as? Bool ?? false
                    let timestamp = (failure["timestamp"] as? Date)?.formatted(date: .abbreviated, time: .shortened) ?? "time unknown"
                    let runID = failure["runID"] as? String ?? ""
                    let resolved = failure["resolved"] as? Bool ?? false
                    debugRow("Protected file access", "\(component) · \(domain) \(code) · \(protection) · at \(timestamp) · run \(runID.isEmpty ? "unknown" : runID) · resolved \(resolved) · data available: \(available) · background: \(background)")
                }
                let runs = (try? JSONDecoder().decode([ExplorationBGRunDiagnostic].self, from: defaults.data(forKey: "Moves.exploration.bg.runs") ?? Data())) ?? []
                debugRow("Last BG execution", runs.last.map { "\($0.outcome.rawValue) · \($0.startedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "No grant recorded")
                debugRow("Last scheduling decision", defaults.string(forKey: "Moves.exploration.bg.lastScheduleDecision") ?? "None recorded")
                if let submitError = defaults.string(forKey: "Moves.exploration.bg.lastSubmitError") { debugRow("Submission error", submitError) }
                if let advanceAt = defaults.object(forKey: "Moves.exploration.lastSuccessfulHistoricalAdvanceAt") as? Date {
                    debugRow("Last historical advance", "\(defaults.string(forKey: "Moves.exploration.lastSuccessfulHistoricalAdvanceDay") ?? "unknown") · \(advanceAt.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    debugRow("Last historical advance", "None recorded")
                }
                debugRow("Active worker runtime", runs.last(where: { $0.outcome == .running }).map { formatDuration($0.runtime) } ?? "Not active")
                if let date = defaults.object(forKey: "Moves.exploration.bg.lastStart") as? Date {
                    debugRow("Last BG start", date.formatted(date: .abbreviated, time: .shortened))
                }
                if let date = defaults.object(forKey: "Moves.exploration.bg.pendingDate") as? Date {
                    debugRow("Pending earliest", date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    debugRow("Pending request", "None recorded")
                }
                if let date = defaults.object(forKey: "Moves.exploration.bg.lastExpiration") as? Date {
                    debugRow("Last expiration", date.formatted(date: .abbreviated, time: .shortened))
                }
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    debugRow("Resource gate", "Low Power Mode")
                } else if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                    debugRow("Resource gate", "Thermal state: \(ProcessInfo.processInfo.thermalState)")
                } else if defaults.bool(forKey: "Moves.routeImport.isActive") {
                    debugRow("Resource gate", "Route import active")
                }
                debugRow("Migration", "v\(migrationStatus.version) · \(migrationStatus.migratedFiles) files changed / \(migrationStatus.candidateEntries) entries · \(migrationStatus.remainingEntries.map(String.init) ?? "unknown") entries remaining · complete \(migrationStatus.isComplete)")
                debugRow("Migration protection", migrationStatus.effectiveProtectionClass ?? "Not measured")
                if let migrationError = migrationStatus.lastError { debugRow("Migration error", migrationError) }
#if canImport(UIKit)
                debugRow("Background App Refresh", UIApplication.shared.backgroundRefreshStatus == .available ? "Available" : "Unavailable")
#endif
            }

            Section("Projection") {
                if let statistics {
                    if let startedAt = statistics.checkpoint.startedAt {
                        debugRow("Started", startedAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    if let elapsed = statistics.elapsed {
                        debugRow("Wall time since first attempt", formatDuration(elapsed))
                    }
                    debugRow("Worker runtime", formatDuration(statistics.checkpoint.successfulRuntime))

                    if let averageDaysPerHour = statistics.averageDaysPerHour {
                        debugRow("Average", "\(averageDaysPerHour.formatted(.number.precision(.fractionLength(2)))) days/hour")
                    }

                    if let estimatedCompletionDate = statistics.estimatedCompletionDate {
                        debugRow("Projected finish", estimatedCompletionDate.formatted(date: .abbreviated, time: .shortened))
                    } else if statistics.remainingDayCount == 0, statistics.checkpoint.totalDayCount != nil {
                        debugRow("Projected finish", "Complete")
                    } else {
                        Text("A finish projection appears after the first completed day.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("The projection starts when the first preparation slice runs.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Checkpoint") {
                if let statistics {
                    debugRow("Prepared shards", statistics.checkpoint.preparedShardCount.formatted())
                    debugRow("Last update", statistics.checkpoint.updatedAt.formatted(date: .abbreviated, time: .standard))
                    debugRow("Currently processing", statistics.checkpoint.isProcessing ? "Yes" : "No")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Danger zone") {
                Button {
                    Task { await rebuildCache() }
                } label: {
                    Label(
                        isRebuildingCache ? "Rebuilding cache…" : "Rebuild merged cache",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(isRebuildingCache || isResetting)

                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    Label(
                        isResetting ? "Deleting…" : "Delete all preparation data",
                        systemImage: "trash"
                    )
                }
                .disabled(isResetting || isRunningSlice || isRunningCatchUp)

                Text("Deletes source shards, the merged cache, and the preparation checkpoint. Moves history is not deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Fog import testing") {
                Button {
                    isShowingFogImporter = true
                } label: {
                    Label(
                        isImportingFog ? "Importing Fog data…" : "Import Fog of the World data…",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .disabled(isImportingFog)

                if isImportingFog {
                    ProgressView()
                }

                if let fogImportMessage {
                    Text(fogImportMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Imports revealed bitmap coverage only. It does not create routes, visits, dates, or trips.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Fog export testing") {
                Toggle("Include flight layer", isOn: $includeFlightsInFogExport)

                Button {
                    exportFogData(asFWSS: false)
                } label: {
                    Label(
                        isExportingFog ? "Preparing Fog export…" : "Export Fog Sync archive…",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .disabled(isExportingFog)

                Button {
                    exportFogData(asFWSS: true)
                } label: {
                    Label(
                        isExportingFog ? "Preparing Fog export…" : "Export Fog FWSS snapshot…",
                        systemImage: "archivebox"
                    )
                }
                .disabled(isExportingFog)

                Text("Exports canonical blocks directly into Fog-compatible Sync or FWSS structures. Moves provenance and dates are not included; FWSS metadata is generated from the exported coverage.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Exploration Prep")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            await refreshLoop()
        }
        .confirmationDialog(
            "Delete all Exploration preparation data?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Task {
                    await resetAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all prepared shards, merged blocks, and progress. Your Moves timeline remains untouched.")
        }
        .fileImporter(
            isPresented: $isShowingFogImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "fwss") ?? .data,
                UTType(filenameExtension: "zip") ?? .archive,
                .data
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importFogData(from: url)
            case .failure(let error):
                fogImportMessage = "Fog import was not selected: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isShowingFogExporter,
            document: fogExportDocument,
            contentType: UTType(filenameExtension: "zip") ?? .archive,
            defaultFilename: exportAsFWSS ? "moves-exploration.fwss" : "moves-exploration-sync.zip"
        ) { result in
            switch result {
            case .success(let url):
                fogImportMessage = "Fog export saved to \(url.lastPathComponent)."
            case .failure(let error):
                fogImportMessage = "Fog export failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
        }
    }

    private func refresh() async {
        do {
            let checkpoint = try await checkpointStore.load()
            statistics = ExplorationPreparationStatistics(checkpoint: checkpoint)
            queueSnapshot = try await ExplorationWorkQueue.shared.snapshot()
            migrationStatus = ExplorationFileProtectionMigration.status()
            errorMessage = nil
        } catch {
            errorMessage = "Could not read preparation checkpoint: \(error.localizedDescription)"
        }
    }

    private func copyDiagnosticReport() {
        let report = ExplorationDiagnosticReport.make(
            checkpoint: statistics?.checkpoint,
            queue: queueSnapshot,
            migration: migrationStatus
        )
#if canImport(UIKit)
        UIPasteboard.general.string = report
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
#endif
        diagnosticCopied = true
    }

    private func runOnePreparationSlice() async {
        guard !isRunningSlice else { return }
        isRunningSlice = true
        sliceMessage = "Preparing one bounded history slice…"
        errorMessage = nil
        defer { isRunningSlice = false }

        do {
            let result = try await ExplorationPreparation.runSlice(in: modelContext.container)
            statistics = ExplorationPreparationStatistics(checkpoint: result.checkpoint)
            queueSnapshot = try await ExplorationWorkQueue.shared.snapshot()
            if result.daysProcessed == 0 {
                sliceMessage = "No unprepared DayTimeline work unit is available."
            } else {
                sliceMessage = "Prepared \(result.daysProcessed.formatted()) day, \(result.routesProcessed.formatted()) route(s), and \(result.blocksWritten.formatted()) block(s)."
            }
        } catch is CancellationError {
            sliceMessage = "Preparation slice cancelled. It can be run again safely."
        } catch {
            sliceMessage = nil
            errorMessage = "Could not run preparation slice: \(error.localizedDescription)"
        }
    }

    private func startCatchUp() {
        guard !isRunningCatchUp else { return }
        isRunningCatchUp = true
        sliceMessage = "Preparing bounded catch-up batches…"
        catchUpTask = Task { @MainActor in
            defer {
                isRunningCatchUp = false
                catchUpTask = nil
            }
            do {
                let results = try await ExplorationPreparation.runBackgroundWindow(
                    in: modelContext.container,
                    maximumDays: 64,
                    maximumDuration: 10 * 60
                )
                await refresh()
                let completed = results.reduce(0) { $0 + $1.daysProcessed }
                sliceMessage = "Catch-up committed \(completed.formatted()) day(s). Run again to continue."
            } catch is CancellationError {
                await refresh()
                sliceMessage = "Catch-up stopped. Completed checkpoints can resume on the next run."
            } catch {
                await refresh()
                errorMessage = "Catch-up could not continue: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func debugRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func stateText(for readiness: ExplorationReadiness) -> String {
        switch readiness {
        case .notStarted: "Not started"
        case .preparing: "Preparing"
        case .partiallyReady: "Partially ready"
        case .ready: "Ready"
        case .needsRebuild: "Needs rebuild"
        }
    }

    private func processedText(for statistics: ExplorationPreparationStatistics) -> String {
        guard let totalDayCount = statistics.checkpoint.totalDayCount else {
            return statistics.processedDayCount.formatted()
        }
        return "\(statistics.processedDayCount.formatted()) / \(totalDayCount.formatted()) days"
    }

    private func remainingText(for statistics: ExplorationPreparationStatistics) -> String {
        guard let remainingDayCount = statistics.remainingDayCount else { return "Unknown" }
        return "\(remainingDayCount.formatted()) days"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "—"
    }

    private func resetAll() async {
        isResetting = true
        defer { isResetting = false }

        do {
            try await checkpointStore.removeAllPreparationData()
            try await ExplorationWorkQueue.shared.removeAll()
            preparationIsEnabled = false
            statistics = nil
            errorMessage = nil
        } catch {
            errorMessage = "Could not delete preparation data: \(error.localizedDescription)"
        }
    }

    private func rebuildCache() async {
        isRebuildingCache = true
        defer { isRebuildingCache = false }
        do {
            let store = ExplorationShardFileStore(rootURL: ExplorationStorageLocations.rootURL)
            let cache = ExplorationMergedCache(rootURL: ExplorationStorageLocations.rootURL, shardStore: store)
            try await cache.rebuildAll()
            fogImportMessage = "Merged cache rebuilt from source shards."
        } catch {
            errorMessage = "Could not rebuild merged cache: \(error.localizedDescription)"
        }
    }

    private func importFogData(from url: URL) {
        guard !isImportingFog else { return }
        isImportingFog = true
        fogImportMessage = "Reading and merging Fog bitmap tiles…"
        let hasSecurityScope = url.startAccessingSecurityScopedResource()

        Task { @MainActor in
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
                isImportingFog = false
            }

            do {
                let result = try await FogOfWorldDebugImporter.importArchive(at: url)
                fogImportMessage = "\(result.archiveKind): \(result.tileCount.formatted()) tiles, \(result.blockCount.formatted()) blocks, \(result.revealedCellCount.formatted()) revealed cells. Source \(result.sourceID). This coverage is undated and does not change historical day progress."
            } catch is CancellationError {
                fogImportMessage = "Fog import cancelled."
            } catch {
                fogImportMessage = "Fog import failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportFogData(asFWSS: Bool) {
        guard !isExportingFog else { return }
        isExportingFog = true
        exportAsFWSS = asFWSS
        fogImportMessage = asFWSS ? "Packing canonical blocks into a Fog FWSS snapshot…" : "Packing canonical blocks into a Fog sync archive…"
        Task { @MainActor in
            defer { isExportingFog = false }
            do {
                let result: FogDebugExportResult
                if asFWSS {
                    result = try await FogOfWorldDebugImporter.exportFWSSArchive(includeFlights: includeFlightsInFogExport)
                } else {
                    result = try await FogOfWorldDebugImporter.exportSyncArchive(includeFlights: includeFlightsInFogExport)
                }
                fogExportDocument = FogDebugExportDocument(data: result.data)
                isShowingFogExporter = true
                let format = asFWSS ? "FWSS snapshot" : "Sync archive"
                fogImportMessage = "Prepared \(result.tileCount.formatted()) tiles and \(result.blockCount.formatted()) blocks for \(format)."
            } catch {
                fogImportMessage = "Fog export failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct ExplorationStageDebugRecord: Decodable {
    let stage: String
    let runID: String?
    let sliceID: String?
    let sequence: Int
    let context: String
    let dayKey: String?
    let routeCount: Int?
    let lane: String?
    let itemID: String?
    let startedAt: Date
    let endedAt: Date?
    let durationMilliseconds: Double?
    let error: String?
}

private func percentile95(_ rawValues: Any?) -> String {
    let values = (rawValues as? [Double] ?? []).sorted()
    guard !values.isEmpty else { return "—" }
    let index = min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)
    return String(format: "%.0f ms", values[index])
}

struct FogDebugExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "zip") ?? .archive]
    }

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
#endif
