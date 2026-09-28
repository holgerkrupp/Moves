import Foundation

enum ExplorationWorkLane: Int, Codable, Comparable, Sendable {
    case live = 0
    case synchronizedShard = 1
    case importedHistory = 2
    case historical = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ExplorationWorkState: String, Codable, Sendable {
    case queued
    case processing
}

struct ExplorationWorkItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let dayKey: String
    var lane: ExplorationWorkLane
    var state: ExplorationWorkState = .queued
    var enqueuedAt: Date
    var leaseUntil: Date?
    var attempts = 0
    var lastError: String?

    init(dayKey: String, lane: ExplorationWorkLane, now: Date = .now) {
        self.id = "day:\(dayKey)"
        self.dayKey = dayKey
        self.lane = lane
        self.enqueuedAt = now
    }
}

struct ExplorationWorkQueueSnapshot: Sendable, Equatable {
    let queuedCount: Int
    let processingCount: Int
    let staleProcessingCount: Int
    let countsByLane: [ExplorationWorkLane: Int]
}

actor ExplorationWorkQueue {
    static let shared = ExplorationWorkQueue()

    private let url: URL
    private var loaded = false
    private var items: [String: ExplorationWorkItem] = [:]

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        self.url = rootURL.appendingPathComponent("v1/work-queue.json")
    }

    func enqueue(dayKeys: some Sequence<String>, lane: ExplorationWorkLane) throws {
        try loadIfNeeded()
        let now = Date.now
        for dayKey in Set(dayKeys).sorted() where !dayKey.isEmpty {
            let id = "day:\(dayKey)"
            if var existing = items[id] {
                // A newly imported/live day must be promoted ahead of old history,
                // but a queued item already being processed keeps its lease.
                if existing.state == .queued || lane < existing.lane {
                    existing.lane = min(existing.lane, lane)
                    existing.enqueuedAt = now
                    existing.lastError = nil
                    items[id] = existing
                }
            } else {
                items[id] = ExplorationWorkItem(dayKey: dayKey, lane: lane, now: now)
            }
        }
        try save()
    }

    func recoverExpired(now: Date = .now) throws -> Int {
        try loadIfNeeded()
        var recovered = 0
        for id in items.keys {
            guard var item = items[id], item.state == .processing else { continue }
            guard let leaseUntil = item.leaseUntil, leaseUntil <= now else { continue }
            item.state = .queued
            item.leaseUntil = nil
            items[id] = item
            recovered += 1
        }
        if recovered > 0 { try save() }
        return recovered
    }

    func claim(
        maximum: Int = 1,
        leaseDuration: TimeInterval = 15 * 60,
        now: Date = .now
    ) throws -> [ExplorationWorkItem] {
        try loadIfNeeded()
        _ = try recoverExpired(now: now)
        let candidates = items.values
            .filter { $0.state == .queued }
            .sorted {
                if $0.lane != $1.lane { return $0.lane < $1.lane }
                if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
                return $0.id < $1.id
            }
            .prefix(max(0, maximum))

        var claimed: [ExplorationWorkItem] = []
        for candidate in candidates {
            guard var item = items[candidate.id] else { continue }
            item.state = .processing
            item.leaseUntil = now.addingTimeInterval(leaseDuration)
            item.attempts += 1
            item.lastError = nil
            items[item.id] = item
            claimed.append(item)
        }
        if !claimed.isEmpty { try save() }
        return claimed
    }

    func complete(_ itemID: String) throws {
        try loadIfNeeded()
        items.removeValue(forKey: itemID)
        try save()
    }

    func retry(_ itemID: String, error: String? = nil) throws {
        try loadIfNeeded()
        guard var item = items[itemID] else { return }
        item.state = .queued
        item.leaseUntil = nil
        item.lastError = error
        items[itemID] = item
        try save()
    }

    func snapshot(now: Date = .now) throws -> ExplorationWorkQueueSnapshot {
        try loadIfNeeded()
        // A process termination can leave a leased item behind. Reading the
        // debug view is also a recovery opportunity; reporting the item as
        // stale without re-queuing it would make the queue look permanently
        // blocked until another worker happened to claim it.
        _ = try recoverExpired(now: now)
        var counts = [ExplorationWorkLane: Int]()
        for item in items.values { counts[item.lane, default: 0] += 1 }
        return ExplorationWorkQueueSnapshot(
            queuedCount: items.values.filter { $0.state == .queued }.count,
            processingCount: items.values.filter { $0.state == .processing }.count,
            staleProcessingCount: 0,
            countsByLane: counts
        )
    }

    func removeAll() throws {
        items.removeAll()
        loaded = true
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        items = try JSONDecoder().decode([String: ExplorationWorkItem].self, from: data)
    }

    private func save() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: url, options: ExplorationFileStorage.atomicWriteOptions)
    }
}

enum ExplorationIncrementalHooks {
    static func enqueueImportedDays(_ dayKeys: some Sequence<String>) {
        let keys = Array(Set(dayKeys))
        guard !keys.isEmpty else { return }
        Task.detached(priority: .utility) {
            try? await ExplorationWorkQueue.shared.enqueue(dayKeys: keys, lane: .importedHistory)
#if !os(macOS)
            await MainActor.run { ExplorationPreparationBackgroundTask.schedule() }
#endif
        }
    }

    static func enqueueLiveDay(_ dayKey: String) {
        guard !dayKey.isEmpty else { return }
        Task.detached(priority: .utility) {
            try? await ExplorationWorkQueue.shared.enqueue(dayKeys: [dayKey], lane: .live)
#if !os(macOS)
            await MainActor.run { ExplorationPreparationBackgroundTask.schedule() }
#endif
        }
    }
}
