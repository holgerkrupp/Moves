#if DEBUG
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ExplorationPreparationDebugView: View {
    @AppStorage(ExplorationPreparation.isEnabledKey) private var preparationIsEnabled = false
    @State private var statistics: ExplorationPreparationStatistics?
    @State private var queueSnapshot: ExplorationWorkQueueSnapshot?
    @State private var errorMessage: String?
    @State private var isConfirmingReset = false
    @State private var isResetting = false
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
                        debugRow("Processing work", queueSnapshot.processingCount.formatted())
                        if queueSnapshot.staleProcessingCount > 0 {
                            debugRow("Stale leases", queueSnapshot.staleProcessingCount.formatted())
                        }
                    }
                } else {
                    Text("No preparation checkpoint has been written yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Projection") {
                if let statistics {
                    if let startedAt = statistics.checkpoint.startedAt {
                        debugRow("Started", startedAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    if let elapsed = statistics.elapsed {
                        debugRow("Elapsed", formatDuration(elapsed))
                    }

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
                .disabled(isResetting)

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
        .navigationBarTitleDisplayMode(.inline)
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
            errorMessage = nil
        } catch {
            errorMessage = "Could not read preparation checkpoint: \(error.localizedDescription)"
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
                fogImportMessage = "\(result.archiveKind): \(result.tileCount.formatted()) tiles, \(result.blockCount.formatted()) blocks, \(result.revealedCellCount.formatted()) revealed cells. Source \(result.sourceID)."
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
