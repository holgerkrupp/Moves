import Foundation

enum ExplorationWorkLane: Int, Codable, CaseIterable, Comparable, Sendable {
    case live = 0
    case synchronizedShard = 1
    case importedHistory = 2
    case historical = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .synchronizedShard: "Synchronized shard"
        case .importedHistory: "Imported history"
        case .historical: "Historical"
        }
    }
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
    var nextEligibleAt: Date?
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
    let delayedCount: Int
    let processingCount: Int
    let staleProcessingCount: Int
    let countsByLane: [ExplorationWorkLane: Int]
    let recentFailures: [ExplorationWorkItem]
}

actor ExplorationWorkQueue {
    static let shared = ExplorationWorkQueue()

    private let url: URL
    private let fairnessURL: URL
    private var loaded = false
    private var items: [String: ExplorationWorkItem] = [:]
    private var consecutivePriorityCompletions = 0

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        self.url = rootURL.appendingPathComponent("v1/work-queue.json")
        self.fairnessURL = rootURL.appendingPathComponent("v1/work-queue-fairness.json")
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
                    existing.nextEligibleAt = nil
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
        let sortedCandidates = items.values
            .filter { $0.state == .queued && ($0.nextEligibleAt.map { $0 <= now } ?? true) }
            .sorted {
                if $0.lane != $1.lane { return $0.lane < $1.lane }
                if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
                return $0.id < $1.id
            }
        var candidates = Array(sortedCandidates.prefix(max(0, maximum)))
        if maximum == 1, consecutivePriorityCompletions >= 4,
           let historical = sortedCandidates.first(where: { $0.lane == .historical }) {
            candidates = [historical]
        }

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
        if let completed = items.removeValue(forKey: itemID) {
            if completed.lane == .historical { consecutivePriorityCompletions = 0 }
            else { consecutivePriorityCompletions = min(4, consecutivePriorityCompletions + 1) }
            try saveFairness()
        }
        try save()
    }

    func shouldAdvanceHistoricalCursor() throws -> Bool {
        try loadIfNeeded()
        return consecutivePriorityCompletions >= 4
    }

    func recordHistoricalCursorProgress() throws {
        try loadIfNeeded()
        guard consecutivePriorityCompletions != 0 else { return }
        consecutivePriorityCompletions = 0
        try saveFairness()
    }

    func retry(_ itemID: String, error: String? = nil, now: Date = .now) throws {
        try loadIfNeeded()
        guard var item = items[itemID] else { return }
        item.state = .queued
        item.leaseUntil = nil
        item.lastError = error
        // Exponential backoff prevents a broken item from consuming every
        // granted window while keeping retries bounded and automatic.
        let delay = min(30 * 24 * 60 * 60, 30 * pow(2, Double(min(max(item.attempts - 1, 0), 20))))
        item.nextEligibleAt = now.addingTimeInterval(delay)
        items[itemID] = item
        try save()
    }

    func deferForProtectedData(_ itemID: String, error: String, now: Date = .now) throws {
        try loadIfNeeded()
        guard var item = items[itemID] else { return }
        item.state = .queued
        item.leaseUntil = nil
        item.lastError = error
        item.nextEligibleAt = now.addingTimeInterval(30 * 60)
        items[itemID] = item
        try save()
    }

    func deferAfterCancellation(_ itemID: String, now: Date = .now) throws {
        try loadIfNeeded()
        guard var item = items[itemID] else { return }
        item.state = .queued
        item.leaseUntil = nil
        item.nextEligibleAt = now.addingTimeInterval(5)
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
            queuedCount: items.values.filter { $0.state == .queued && ($0.nextEligibleAt.map { $0 <= now } ?? true) }.count,
            delayedCount: items.values.filter { $0.state == .queued && ($0.nextEligibleAt.map { $0 > now } ?? false) }.count,
            processingCount: items.values.filter { $0.state == .processing }.count,
            staleProcessingCount: 0,
            countsByLane: counts,
            recentFailures: items.values.filter { $0.lastError != nil }
                .sorted { $0.enqueuedAt > $1.enqueuedAt }.prefix(5).map { $0 }
        )
    }

    func removeAll() throws {
        items.removeAll()
        consecutivePriorityCompletions = 0
        loaded = true
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if FileManager.default.fileExists(atPath: fairnessURL.path) {
            try FileManager.default.removeItem(at: fairnessURL)
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try ExplorationFileStorage.readData(from: url)
        items = try JSONDecoder().decode([String: ExplorationWorkItem].self, from: data)
        if let fairnessData = try? ExplorationFileStorage.readData(from: fairnessURL),
           let value = try? JSONDecoder().decode(Int.self, from: fairnessData) {
            consecutivePriorityCompletions = min(4, max(0, value))
        }
    }

    private func save() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try ExplorationFileStorage.writeAtomically(data, to: url)
    }

    private func saveFairness() throws {
        try FileManager.default.createDirectory(at: fairnessURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ExplorationFileStorage.writeAtomically(try JSONEncoder().encode(consecutivePriorityCompletions), to: fairnessURL)
    }
}

enum ExplorationIncrementalHooks {
    static func enqueueImportedDays(_ dayKeys: some Sequence<String>) {
        let keys = Array(Set(dayKeys))
        guard !keys.isEmpty else { return }
        Task.detached(priority: .utility) {
            try? await ExplorationWorkQueue.shared.enqueue(dayKeys: keys, lane: .importedHistory)
#if !os(macOS)
            await MainActor.run { ExplorationPreparationBackgroundTask.schedule(urgent: true) }
#endif
        }
    }

    static func enqueueLiveDay(_ dayKey: String) {
        guard !dayKey.isEmpty else { return }
        Task.detached(priority: .utility) {
            try? await ExplorationWorkQueue.shared.enqueue(dayKeys: [dayKey], lane: .live)
#if !os(macOS)
            await MainActor.run { ExplorationPreparationBackgroundTask.schedule(urgent: true) }
#endif
        }
    }
}
