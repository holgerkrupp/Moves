import SwiftUI

@main
struct WatchMovesApp: App {
    @StateObject private var tracker = WatchLocationTracker()

    var body: some Scene {
        WindowGroup {
            WatchMovesContentView()
                .environmentObject(tracker)
        }
    }
}
