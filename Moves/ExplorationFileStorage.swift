import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum ExplorationFileStorage {
#if os(iOS) || os(tvOS) || os(watchOS)
    static let protectionClass = FileProtectionType.completeUntilFirstUserAuthentication
#endif

    static var atomicWriteOptions: Data.WritingOptions {
#if os(iOS) || os(tvOS) || os(watchOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
#else
        [.atomic]
#endif
    }

    static var protectedWriteOptions: Data.WritingOptions {
#if os(iOS) || os(tvOS) || os(watchOS)
        [.completeFileProtectionUntilFirstUserAuthentication]
#else
        []
#endif
    }

    static func applyProtection(to url: URL, fileManager: FileManager = .default) throws {
#if os(iOS) || os(tvOS) || os(watchOS)
        try fileManager.setAttributes([.protectionKey: protectionClass], ofItemAtPath: url.path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let actual = attributes[.protectionKey] as? FileProtectionType,
              actual == protectionClass else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.lastPathComponent])
        }
#endif
    }

    static func writeAtomically(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: atomicWriteOptions)
        try applyProtection(to: url, fileManager: fileManager)
        try applyProtection(to: url.deletingLastPathComponent(), fileManager: fileManager)
    }

    static func readData(from url: URL, attemptedInBackground: Bool = false) throws -> Data {
        do {
            let data = try Data(contentsOf: url)
            resolveProtectedFailure(for: url)
            return data
        }
        catch {
            if isProtectedDataFailure(error) {
                let nsError = error as NSError
                let available: Bool
#if canImport(UIKit)
                available = UIApplication.shared.isProtectedDataAvailable
#else
                available = true
#endif
                UserDefaults.standard.set([
                    "pathComponent": url.lastPathComponent,
                    "domain": nsError.domain,
                    "code": nsError.code,
                    "protectionClass": ((try? FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]).map { String(describing: $0) }) ?? "unavailable",
                    "protectedDataAvailable": available,
                    "attemptedInBackground": attemptedInBackground || UserDefaults.standard.bool(forKey: "Moves.exploration.bg.isProcessing"),
                    "timestamp": Date.now,
                    "runID": UserDefaults.standard.string(forKey: "Moves.exploration.bg.activeRunID") ?? "",
                    "resolved": false
                ], forKey: "Moves.exploration.protectedReadFailure")
                throw ProtectedDataUnavailableError(pathComponent: url.lastPathComponent, domain: nsError.domain, code: nsError.code)
            }
            throw error
        }
    }

    static func isProtectedDataFailure(_ error: Error) -> Bool {
        let value = error as NSError
        return value.code == NSFileReadNoPermissionError
            || value.code == NSFileWriteNoPermissionError
            || (value.domain == NSCocoaErrorDomain && value.code == 257)
    }

    private static func resolveProtectedFailure(for url: URL) {
        guard var failure = UserDefaults.standard.dictionary(forKey: "Moves.exploration.protectedReadFailure"),
              failure["pathComponent"] as? String == url.lastPathComponent else { return }
        failure["resolved"] = true
        failure["resolvedAt"] = Date.now
        UserDefaults.standard.set(failure, forKey: "Moves.exploration.protectedReadFailure")
    }
}

struct ProtectedDataUnavailableError: Error, LocalizedError, Sendable {
    let pathComponent: String
    let domain: String
    let code: Int
    var errorDescription: String? { "Exploration file access is deferred until protected data is available (\(pathComponent), \(domain) \(code))." }
}

/// Idempotently upgrades only the app-owned Exploration subtree. The cursor is
/// held in preferences so migration can resume even if an Exploration file is
/// unavailable before first unlock. User-selected Fog archives are outside it.
enum ExplorationFileProtectionMigration {
    static let version = 2
    static let batchSize = 96
    private static var stateKey: String { "Moves.exploration.protectionMigration.v\(version).state" }
    private static func inventoryURL(root: URL) -> URL { root.appendingPathComponent("v1/protection-migration-v2.json") }

    struct Status: Codable, Sendable, Equatable {
        var version = ExplorationFileProtectionMigration.version
        var categories: [String: Int] = [:]
        var candidateEntries = 0
        var migratedFiles = 0
        var remainingEntries: Int?
        var lastAttemptAt: Date?
        var lastSuccessfulRunAt: Date?
        var lastError: String?
        var lastErrorPathComponent: String?
        var effectiveProtectionClass: String?
        var deferredForProtectedData = false
        var isComplete = false
    }

    private struct State: Codable {
        var inventory: [String]
        var cursor = 0
        var status: Status
    }

#if os(iOS) || os(tvOS) || os(watchOS)
    struct BatchResult {
        let cursor: Int
        let changedPaths: [String]
        let effectiveProtectionClass: String?
    }

    static func migrateBatch(
        inventory: [String],
        cursor: Int,
        root: URL,
        limit: Int = batchSize,
        fileManager: FileManager = .default
    ) throws -> BatchResult {
        let end = min(inventory.count, max(cursor, 0) + max(limit, 0))
        var changedPaths = [String]()
        var effectiveClass: String?
        for path in inventory[max(cursor, 0)..<end] {
            let url = root.appendingPathComponent(path)
            let priorAttributes = try? fileManager.attributesOfItem(atPath: url.path)
            let oldProtection = priorAttributes?[.protectionKey] as? FileProtectionType
            try ExplorationFileStorage.applyProtection(to: url, fileManager: fileManager)
            if let actual = try fileManager.attributesOfItem(atPath: url.path)[.protectionKey] {
                effectiveClass = String(describing: actual)
            }
            if oldProtection != ExplorationFileStorage.protectionClass,
               (priorAttributes?[.type] as? FileAttributeType) != .typeDirectory {
                changedPaths.append(path)
            }
        }
        return BatchResult(cursor: end, changedPaths: changedPaths, effectiveProtectionClass: effectiveClass)
    }
#endif

    static func status(defaults: UserDefaults = .standard) -> Status {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return Status() }
        return state.status
    }

    @discardableResult
    static func run(rootURL: URL = ExplorationStorageLocations.rootURL, defaults: UserDefaults = .standard) throws -> Bool {
#if os(iOS) || os(tvOS) || os(watchOS)
        var state = loadState(defaults: defaults)
        state.status.lastAttemptAt = .now
        state.status.deferredForProtectedData = !UIApplication.shared.isProtectedDataAvailable
        guard UIApplication.shared.isProtectedDataAvailable else {
            save(state, defaults: defaults)
            return false
        }
        let standardized = rootURL.standardizedFileURL
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let allowedRoot = applicationSupport.appendingPathComponent("Moves/Exploration", isDirectory: true).standardizedFileURL
        guard standardized == allowedRoot else { return false }
        if state.status.isComplete {
            resolveLegacyProtectedReadFailure(defaults: defaults, completedAt: state.status.lastSuccessfulRunAt ?? .now)
            return true
        }
        let fm = FileManager.default
        try fm.createDirectory(at: standardized, withIntermediateDirectories: true)
        try ExplorationFileStorage.applyProtection(to: standardized)
        if state.inventory.isEmpty {
            state.inventory = try prioritizedInventory(root: standardized, fileManager: fm)
            try ExplorationFileStorage.writeAtomically(try JSONEncoder().encode(state.inventory), to: inventoryURL(root: standardized))
            state.status.candidateEntries = state.inventory.count
            state.status.remainingEntries = state.inventory.count
        }
        do {
            let batch = try migrateBatch(inventory: state.inventory, cursor: state.cursor, root: standardized, fileManager: fm)
            state.cursor = batch.cursor
            state.status.effectiveProtectionClass = batch.effectiveProtectionClass ?? state.status.effectiveProtectionClass
            for path in batch.changedPaths {
                state.status.migratedFiles += 1
                state.status.categories[category(for: path), default: 0] += 1
            }
        } catch {
            state.status.lastError = error.localizedDescription
            state.status.lastErrorPathComponent = (error as NSError).userInfo[NSFilePathErrorKey] as? String
            state.status.remainingEntries = max(0, state.inventory.count - state.cursor)
            save(state, defaults: defaults)
            throw error
        }
        state.status.remainingEntries = max(0, state.inventory.count - state.cursor)
        state.status.lastSuccessfulRunAt = .now
        state.status.lastError = nil
        state.status.lastErrorPathComponent = nil
        state.status.isComplete = state.cursor >= state.inventory.count
        if state.status.isComplete {
            // Catch files created after inventory capture before setting the
            // durable completion marker.
            var legacyPaths: [String] = []
            if let enumerator = fm.enumerator(at: standardized, includingPropertiesForKeys: nil) {
                while let url = enumerator.nextObject() as? URL {
                    if url == inventoryURL(root: standardized) { continue }
                    let actual = try? fm.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
                    if actual != ExplorationFileStorage.protectionClass {
                        legacyPaths.append(String(url.path.dropFirst((standardized.path + "/").count)))
                    }
                }
            }
            if !legacyPaths.isEmpty {
                state.inventory = legacyPaths
                state.cursor = 0
                state.status.candidateEntries += legacyPaths.count
                state.status.remainingEntries = legacyPaths.count
                state.status.isComplete = false
                try ExplorationFileStorage.writeAtomically(try JSONEncoder().encode(legacyPaths), to: inventoryURL(root: standardized))
            }
        }
        if state.status.isComplete {
            resolveLegacyProtectedReadFailure(defaults: defaults, completedAt: state.status.lastSuccessfulRunAt ?? .now)
        }
        save(state, defaults: defaults)
        return state.status.isComplete
#else
        _ = rootURL; _ = defaults
        return true
#endif
    }

    private static func loadState(defaults: UserDefaults) -> State {
        if let data = defaults.data(forKey: stateKey), let state = try? JSONDecoder().decode(State.self, from: data) { return state }
        if let data = try? Data(contentsOf: inventoryURL(root: ExplorationStorageLocations.rootURL)), let inventory = try? JSONDecoder().decode([String].self, from: data) {
            return State(inventory: inventory, status: Status())
        }
        return State(inventory: [], status: Status())
    }

    private static func save(_ state: State, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }

    private static func resolveLegacyProtectedReadFailure(defaults: UserDefaults, completedAt: Date) {
        guard var failure = defaults.dictionary(forKey: "Moves.exploration.protectedReadFailure"),
              let protection = failure["protectionClass"] as? String,
              protection.contains("FileProtectionComplete"),
              !protection.contains("UntilFirstUserAuthentication") else { return }
        let eventDate = failure["timestamp"] as? Date
        guard eventDate == nil || eventDate! <= completedAt else { return }
        failure["resolved"] = true
        failure["resolvedAt"] = completedAt
        failure["resolution"] = "protection migration verified"
        defaults.set(failure, forKey: "Moves.exploration.protectedReadFailure")
    }

    static func prioritizedInventory(root: URL, fileManager: FileManager = .default) throws -> [String] {
        let prefix = root.path + "/"
        var categories: [[URL]] = []
        let sourceDirectory = root.appendingPathComponent("v1/sources", isDirectory: true)
        categories.append((try? fileManager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "exploration" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? [])
        let essentialNames = ["v1/preparation.json", "v1/work-queue.json", "v1/work-queue-fairness.json", "v1/source-index.json", "v1/source-index.pending"]
        categories.append(essentialNames.map { root.appendingPathComponent($0) }.filter { fileManager.fileExists(atPath: $0.path) })
        let queuedAssets = queuedDerivedURLs(root: root, fileManager: fileManager)
        categories.append(queuedAssets)
        var remaining: [URL] = []
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                if url == inventoryURL(root: root) { continue }
                remaining.append(url)
            }
        }
        let prioritized = Set(categories.flatMap { $0.map(\.standardizedFileURL) })
        categories.append(remaining.filter { !prioritized.contains($0.standardizedFileURL) }.sorted { $0.path < $1.path })
        return categories.flatMap { $0 }.map { String($0.standardizedFileURL.path.dropFirst(prefix.count)) }
    }

    private static func queuedDerivedURLs(root: URL, fileManager: FileManager) -> [URL] {
        let queueURL = root.appendingPathComponent("v1/work-queue.json")
        guard let data = try? Data(contentsOf: queueURL),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        let sourceDirectory = root.appendingPathComponent("v1/sources", isDirectory: true)
        let blockDirectory = root.appendingPathComponent("v1/blocks", isDirectory: true)
        var result = [URL]()
        for value in values.values {
            guard let dayKey = value["dayKey"] as? String else { continue }
            let sourceID = "day:\(dayKey)"
            let filename = Data(sourceID.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "") + ".exploration"
            let encodedID = Data(sourceID.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
            for suffix in ["json", "shard"] {
                let pending = root.appendingPathComponent("v1/derived/pending-\(encodedID).\(suffix)")
                if fileManager.fileExists(atPath: pending.path) { result.append(pending) }
            }
            let sourceURL = sourceDirectory.appendingPathComponent(filename)
            guard let sourceData = try? Data(contentsOf: sourceURL),
                  let shard = try? ExplorationShardCodec.decode(sourceData) else { continue }
            for block in shard.blocks {
                let blockURL = blockDirectory.appendingPathComponent("\(block.id.x)-\(block.id.y).block")
                if fileManager.fileExists(atPath: blockURL.path) { result.append(blockURL) }
                for level in 0...10 {
                    let scale = UInt32(1 << level)
                    let tile = root.appendingPathComponent("v1/render/level-\(level)/\(block.id.x / scale)-\(block.id.y / scale).json")
                    if fileManager.fileExists(atPath: tile.path) { result.append(tile) }
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func category(for path: String) -> String {
        if path.hasPrefix("v1/sources/") { return "sources" }
        if ["v1/preparation.json", "v1/work-queue.json", "v1/work-queue-fairness.json", "v1/source-index.json", "v1/source-index.pending"].contains(path) { return "metadata" }
        if path.hasPrefix("v1/blocks/") { return "blocks" }
        if path.hasPrefix("v1/render/") { return "render" }
        return "other"
    }
}
