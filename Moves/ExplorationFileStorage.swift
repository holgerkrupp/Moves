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
        do { return try Data(contentsOf: url) }
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
                    "attemptedInBackground": attemptedInBackground || UserDefaults.standard.bool(forKey: "Moves.exploration.bg.isProcessing")
                ], forKey: "Moves.exploration.protectedReadFailure")
                throw ProtectedDataUnavailableError(pathComponent: url.lastPathComponent, domain: nsError.domain, code: nsError.code)
            }
            throw error
        }
    }

    static func isProtectedDataFailure(_ error: Error) -> Bool {
#if canImport(UIKit)
        if !UIApplication.shared.isProtectedDataAvailable { return true }
#endif
        let value = error as NSError
        return value.code == NSFileReadNoPermissionError
            || value.code == NSFileWriteNoPermissionError
            || (value.domain == NSCocoaErrorDomain && value.code == 257)
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
    static let version = 1
    static let batchSize = 64
    private static var cursorKey: String { "Moves.exploration.protectionMigration.v\(version).cursor" }
    private static var completeKey: String { "Moves.exploration.protectionMigration.v\(version).complete" }

    @discardableResult
    static func run(rootURL: URL = ExplorationStorageLocations.rootURL, defaults: UserDefaults = .standard) throws -> Bool {
#if os(iOS) || os(tvOS) || os(watchOS)
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        let standardized = rootURL.standardizedFileURL
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let allowedRoot = applicationSupport.appendingPathComponent("Moves/Exploration", isDirectory: true).standardizedFileURL
        guard standardized == allowedRoot else { return false }
        if defaults.bool(forKey: completeKey) { return true }
        let fm = FileManager.default
        try fm.createDirectory(at: standardized, withIntermediateDirectories: true)
        try ExplorationFileStorage.applyProtection(to: standardized)
        let rootPrefix = standardized.path + "/"
        let enumerator = fm.enumerator(at: standardized, includingPropertiesForKeys: nil)
        var paths: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            paths.append(item)
        }
        paths.sort { $0.path < $1.path }
        let cursor = defaults.string(forKey: cursorKey) ?? ""
        let batch = paths.filter { String($0.path.dropFirst(rootPrefix.count)) > cursor }.prefix(batchSize)
        var lastPath = cursor
        for url in batch {
            try ExplorationFileStorage.applyProtection(to: url)
            lastPath = String(url.path.dropFirst(rootPrefix.count))
        }
        if batch.count < batchSize {
            defaults.set(true, forKey: completeKey)
            defaults.removeObject(forKey: cursorKey)
            return true
        }
        defaults.set(lastPath, forKey: cursorKey)
        return false
#else
        _ = rootURL; _ = defaults
        return true
#endif
    }
}
