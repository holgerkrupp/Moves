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
        do {
            let container = try Self.makeModelContainer()
            self.sharedModelContainer = container
            _captureManager = StateObject(
                wrappedValue: MovesLocationCaptureManager(modelContainer: container)
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    private static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            MoveSegment.self,
            LocationSample.self,
        ])

        let modelConfiguration: ModelConfiguration
        #if targetEnvironment(simulator)
        modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        #else
        modelConfiguration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
        )
        #endif

        let container = try ModelContainer(
            for: schema,
            configurations: [modelConfiguration]
        )

        #if targetEnvironment(simulator)
        SimulatorDemoDataSeeder.seedIfNeeded(in: container)
        #endif

        return container
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

extension ProcessInfo {
    var isRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
