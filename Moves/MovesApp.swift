//
//  MovesApp.swift
//  Moves
//
//  Created by Holger Krupp on 23.07.24.
//

import SwiftUI
import SwiftData
import UIKit
import UserNotifications

final class MovesAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.applicationSupportsShakeToEdit = true
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
final class AppUndoController: ObservableObject {
    let manager = UndoManager()
}

@main
struct MovesApp: App {
    @UIApplicationDelegateAdaptor(MovesAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private static let cloudKitContainerIdentifier = "iCloud.de.holgerkrupp.Moves"

    private let sharedModelContainer: ModelContainer
    @StateObject private var undoController = AppUndoController()
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
                .environmentObject(undoController)
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
