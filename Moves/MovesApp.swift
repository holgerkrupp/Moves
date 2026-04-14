//
//  MovesApp.swift
//  Moves
//
//  Created by Holger Krupp on 23.07.24.
//

import SwiftUI
import SwiftData

@main
struct MovesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private static let cloudKitContainerIdentifier = "iCloud.de.holgerkrupp.Moves"

    private let sharedModelContainer: ModelContainer
    @StateObject private var captureManager: MovesLocationCaptureManager

    init() {
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
        )

        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
            self.sharedModelContainer = container
            _captureManager = StateObject(
                wrappedValue: MovesLocationCaptureManager(modelContainer: container)
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(captureManager)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await captureManager.start()
                    await captureManager.refreshHistoricalBackfill()
                }
            }
        }
    }
}
