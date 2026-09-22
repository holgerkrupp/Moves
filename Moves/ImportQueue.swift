import Foundation
import Combine

/// Operational state for an import job. These records are deliberately not SwiftData models:
/// queue progress is local device state and must never become part of the CloudKit history schema.
enum ImportJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case acquiring
    case parsing
    case importing
    case postProcessing
    case paused
    case completed
    case needsInformation
    case failed
    case cancelled
}

enum ImportJobPhase: String, Codable, CaseIterable, Sendable {
    case acquiring
    case parsing
    case importing
    case postProcessing
}

struct ImportJobSourceMetadata: Codable, Hashable, Sendable {
    var sourceType: String
    var originalFileNames: [String]
    var sourceIdentifiers: [String]
    var bookmarkData: [Data]

    private enum CodingKeys: String, CodingKey {
        case sourceType, originalFileNames, sourceIdentifiers, bookmarkData
    }

    init(sourceType: String = "route-file", originalFileNames: [String] = [], sourceIdentifiers: [String] = [], bookmarkData: [Data] = []) {
        self.sourceType = sourceType
        self.originalFileNames = originalFileNames
        self.sourceIdentifiers = sourceIdentifiers
        self.bookmarkData = bookmarkData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceType = try container.decodeIfPresent(String.self, forKey: .sourceType) ?? "route-file"
        originalFileNames = try container.decodeIfPresent([String].self, forKey: .originalFileNames) ?? []
        sourceIdentifiers = try container.decodeIfPresent([String].self, forKey: .sourceIdentifiers) ?? []
        bookmarkData = try container.decodeIfPresent([Data].self, forKey: .bookmarkData) ?? []
    }
}

struct ImportJobCounters: Codable, Hashable, Sendable {
    var itemCount: Int = 0
    var completedItemCount: Int = 0
    var routeCount: Int = 0
    var sampleCount: Int = 0
    var failedItemCount: Int = 0

    var progress: Double? {
        guard itemCount > 0 else { return nil }
        return min(max(Double(completedItemCount) / Double(itemCount), 0), 1)
    }
}

struct ImportJobError: Codable, Hashable, Sendable {
    var message: String
    var isRecoverable: Bool
    var occurredAt: Date
}

/// Local-only recovery state. This is intentionally not a SwiftData model: unresolved
/// imports may contain security-scoped source metadata and staged files and must not enter
/// the CloudKit history schema.
enum ImportRecoveryKind: String, Codable, CaseIterable, Sendable {
    case needsInformation
    case failed
}

struct ImportRecoveryItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var originalFileName: String
    var source: ImportJobSourceMetadata
    var stagedPath: String?
    var configuration: RouteFileImportConfiguration
    var kind: ImportRecoveryKind
    var reason: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(), displayName: String, originalFileName: String,
        source: ImportJobSourceMetadata = .init(), stagedPath: String? = nil,
        configuration: RouteFileImportConfiguration = .init(),
        kind: ImportRecoveryKind, reason: String, createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.originalFileName = originalFileName
        self.source = source
        self.stagedPath = stagedPath
        self.configuration = configuration
        self.kind = kind
        self.reason = reason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ImportRecoveryStore: Sendable {
    static let currentVersion = 1
    private struct Envelope: Codable { var version: Int; var items: [ImportRecoveryItem] }
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moves/ImportRecovery.json")
    }

    func load() throws -> [ImportRecoveryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.version <= Self.currentVersion else { throw ImportQueueStoreError.unsupportedVersion(envelope.version) }
        return envelope.items
    }

    func save(_ items: [ImportRecoveryItem]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Envelope(version: Self.currentVersion, items: items)).write(to: fileURL, options: .atomic)
    }
}

struct ImportJobRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var source: ImportJobSourceMetadata
    var stagedPath: String?
    var configuration: RouteFileImportConfiguration
    var state: ImportJobState
    var phase: ImportJobPhase?
    var counters: ImportJobCounters
    var createdAt: Date
    var updatedAt: Date
    var lastError: ImportJobError?

    init(
        id: UUID = UUID(),
        displayName: String,
        source: ImportJobSourceMetadata = .init(),
        stagedPath: String? = nil,
        configuration: RouteFileImportConfiguration = .init(),
        state: ImportJobState = .queued,
        phase: ImportJobPhase? = .acquiring,
        counters: ImportJobCounters = .init(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastError: ImportJobError? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.stagedPath = stagedPath
        self.configuration = configuration
        self.state = state
        self.phase = phase
        self.counters = counters
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}

struct ImportQueueSnapshot: Equatable, Sendable {
    var jobs: [ImportJobRecord]

    var aggregateProgress: Double? {
        let active = jobs.filter { $0.state != .cancelled }
        guard !active.isEmpty else { return nil }
        let known = active.compactMap { $0.counters.progress }
        guard known.count == active.count else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    var unfinishedJobs: [ImportJobRecord] {
        jobs.filter { ![.completed, .cancelled].contains($0.state) }
    }

    var hasVisibleWork: Bool { !unfinishedJobs.isEmpty }
}

/// JSON-backed local queue. `fileURL` is injectable so persistence and migration can be tested
/// without touching the user's Application Support directory.
struct ImportQueueStore: Sendable {
    static let currentVersion = 1
    private struct Envelope: Codable {
        var version: Int
        var jobs: [ImportJobRecord]
    }

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moves/ImportQueue.json")
    }

    func load() throws -> [ImportJobRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version <= Self.currentVersion else { throw ImportQueueStoreError.unsupportedVersion(envelope.version) }
        return envelope.jobs.map(Self.restoreInterruptedJob)
    }

    func save(_ jobs: [ImportJobRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(version: Self.currentVersion, jobs: jobs))
        try data.write(to: fileURL, options: .atomic)
    }

    func append(_ job: ImportJobRecord) throws {
        var jobs = try load()
        jobs.append(job)
        try save(jobs)
    }

    func remove(id: UUID) throws {
        try save(try load().filter { $0.id != id })
    }

    private static func restoreInterruptedJob(_ job: ImportJobRecord) -> ImportJobRecord {
        guard job.state == .acquiring || job.state == .parsing || job.state == .importing || job.state == .postProcessing else {
            return job
        }
        var restored = job
        restored.state = .paused
        restored.updatedAt = .now
        return restored
    }
}

enum ImportQueueStoreError: LocalizedError, Sendable {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Import queue version \(version) is newer than this app supports."
        }
    }
}

/// Main-actor UI facade. It only coordinates durable records; parsing, staging, and SwiftData
/// work belong to a worker supplied by the importer and must not be added here.
@MainActor
final class ImportCoordinator: ObservableObject {
    @Published private(set) var snapshot: ImportQueueSnapshot
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var recoveryItems: [ImportRecoveryItem]

    private let store: ImportQueueStore
    private let recoveryStore: ImportRecoveryStore

    init(store: ImportQueueStore = ImportQueueStore(), recoveryStore: ImportRecoveryStore = ImportRecoveryStore()) {
        self.store = store
        self.recoveryStore = recoveryStore
        var restoredJobs: [ImportJobRecord] = []
        do {
            restoredJobs = try store.load()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        snapshot = ImportQueueSnapshot(jobs: restoredJobs)
        recoveryItems = (try? recoveryStore.load()) ?? []
    }

    var jobs: [ImportJobRecord] { snapshot.jobs }

    var aggregateProgress: Double? {
        snapshot.aggregateProgress
    }

    @discardableResult
    func enqueue(_ job: ImportJobRecord) throws -> UUID {
        snapshot.jobs.append(job)
        try persist()
        return job.id
    }

    func update(_ job: ImportJobRecord) throws {
        guard let index = snapshot.jobs.firstIndex(where: { $0.id == job.id }) else { return }
        snapshot.jobs[index] = job
        try persist()
    }

    func pause(id: UUID) throws { try transition(id: id, to: .paused) }
    func resume(id: UUID) throws { try transition(id: id, to: .queued) }
    func cancel(id: UUID) throws { try transition(id: id, to: .cancelled) }
    func retry(id: UUID) throws { try transition(id: id, to: .queued, clearError: true) }

    func addRecovery(_ item: ImportRecoveryItem) throws {
        recoveryItems.removeAll { $0.id == item.id }
        recoveryItems.append(item)
        try recoveryStore.save(recoveryItems)
    }

    func updateRecovery(_ item: ImportRecoveryItem) throws {
        guard let index = recoveryItems.firstIndex(where: { $0.id == item.id }) else { return }
        recoveryItems[index] = item
        try recoveryStore.save(recoveryItems)
    }

    func removeRecovery(id: UUID) throws {
        recoveryItems.removeAll { $0.id == id }
        try recoveryStore.save(recoveryItems)
    }

    private func transition(id: UUID, to state: ImportJobState, clearError: Bool = false) throws {
        guard let index = snapshot.jobs.firstIndex(where: { $0.id == id }) else { return }
        snapshot.jobs[index].state = state
        snapshot.jobs[index].updatedAt = .now
        if clearError { snapshot.jobs[index].lastError = nil }
        try persist()
    }

    private func persist() throws {
        do {
            try store.save(jobs)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }
}
