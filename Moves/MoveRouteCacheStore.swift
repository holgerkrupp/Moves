import CoreLocation
import Foundation

/// Device-local mirror for rebuildable route-render output.
///
/// Automatically road-matched geometry is also stored on `MoveSegment` so it can
/// sync through CloudKit. This disposable cache avoids decoding the synced value
/// repeatedly and remains useful while a newly computed value is waiting to sync.
final class MoveRouteCacheStore {
    static let shared = MoveRouteCacheStore()

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        let base = directoryURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = base.appendingPathComponent("MovesRouteCache", isDirectory: true)
        try? fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    func load(moveID: UUID, signature: String) -> [CLLocationCoordinate2D]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(moveID: moveID, signature: signature)) else {
            return nil
        }
        return RouteCoordinateStorage.decode(data)
    }

    func store(_ coordinates: [CLLocationCoordinate2D], moveID: UUID, signature: String) {
        guard !coordinates.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let data = RouteCoordinateStorage.encode(coordinates) else { return }
        try? data.write(to: fileURL(moveID: moveID, signature: signature), options: .atomic)
    }

    func remove(moveID: UUID, signature: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let signature {
            try? fileManager.removeItem(at: fileURL(moveID: moveID, signature: signature))
            return
        }

        let prefix = "\(moveID.uuidString)-"
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func fileURL(moveID: UUID, signature: String) -> URL {
        let encodedSignature = Data(signature.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directoryURL.appendingPathComponent("\(moveID.uuidString)-\(encodedSignature).routecache")
    }
}
