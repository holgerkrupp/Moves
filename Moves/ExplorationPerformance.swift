import Foundation
import OSLog

enum ExplorationPerformance {
    private static let signposter = OSSignposter(subsystem: "de.holgerkrupp.Moves", category: "Exploration")

    static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
#if DEBUG
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
#endif
        return try operation()
    }
}
