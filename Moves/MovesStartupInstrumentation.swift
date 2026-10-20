import Foundation
import OSLog

enum MovesStartupInstrumentation {
    static let signposter = OSSignposter(
        subsystem: "de.holgerkrupp.Moves",
        category: "Startup"
    )

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
        #if DEBUG
        let eventName = String(describing: name)
        let key = "Moves.startup.counter.\(eventName)"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        UserDefaults.standard.set(ProcessInfo.processInfo.systemUptime, forKey: "Moves.startup.time.\(eventName)")
        #endif
    }

    #if DEBUG
    static func beginLaunch() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("Moves.startup.counter.") || key.hasPrefix("Moves.startup.time.") {
            defaults.removeObject(forKey: key)
        }
        event("appInit")
    }
    #endif
}
