//
//  MovesApp.swift
//  Moves
//
//  Created by Holger Krupp on 23.07.24.
//

import SwiftUI
import SwiftData
import AppIntents
import UIKit
import UserNotifications

final class MovesAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.applicationSupportsShakeToEdit = true
        UNUserNotificationCenter.current().delegate = self
        DailyTimelineBackup.registerBackgroundTask()
        ShareMapAggregateBackgroundTask.register()
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
    @StateObject private var watchRouteInbox: WatchRouteInbox
    @StateObject private var healthWorkoutRouteAutoImporter: HealthWorkoutRouteAutoImportManager
    @StateObject private var cloudDataPresencePublisher: MovesCloudDataPresencePublisher
    @StateObject private var locationServiceSyncManager: LocationServiceSyncManager
    @StateObject private var multiDevicePresenceManager: MultiDevicePresenceManager

    init() {
        do {
            let container = try Self.makeModelContainer()
            let captureManager = MovesLocationCaptureManager(modelContainer: container)
            self.sharedModelContainer = container
            _captureManager = StateObject(
                wrappedValue: captureManager
            )
            _watchRouteInbox = StateObject(
                wrappedValue: WatchRouteInbox(modelContainer: container)
            )
            _healthWorkoutRouteAutoImporter = StateObject(
                wrappedValue: HealthWorkoutRouteAutoImportManager(modelContainer: container)
            )
            _cloudDataPresencePublisher = StateObject(
                wrappedValue: MovesCloudDataPresencePublisher(modelContainer: container)
            )
            _locationServiceSyncManager = StateObject(
                wrappedValue: LocationServiceSyncManager(modelContainer: container)
            )
            _multiDevicePresenceManager = StateObject(
                wrappedValue: MultiDevicePresenceManager(modelContainer: container)
            )
            MovesIntentRuntime.shared.configure(
                modelContainer: container,
                captureManager: captureManager
            )
            MovesAppShortcuts.updateAppShortcutParameters()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    static func makeModelContainer() throws -> ModelContainer {
        let timelineSchema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            KnownLocation.self,
            MoveSegment.self,
            LocationSample.self,
            MovesDeviceProfile.self,
        ])
        let cacheSchema = Schema([ShareMapAggregate.self])
        let schema = Schema([
            DayTimeline.self,
            VisitPlace.self,
            KnownLocation.self,
            MoveSegment.self,
            LocationSample.self,
            MovesDeviceProfile.self,
            ShareMapAggregate.self,
        ])

        let modelConfiguration: ModelConfiguration
        let cacheConfiguration: ModelConfiguration
        #if targetEnvironment(simulator)
        modelConfiguration = ModelConfiguration(
            schema: timelineSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        cacheConfiguration = ModelConfiguration(
            "ShareMapCache",
            schema: cacheSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        #else
        modelConfiguration = ModelConfiguration(
            schema: timelineSchema,
            cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
        )
        cacheConfiguration = ModelConfiguration(
            "ShareMapCache",
            schema: cacheSchema,
            cloudKitDatabase: .none
        )
        #endif

        let container = try ModelContainer(
            for: schema,
            configurations: [modelConfiguration, cacheConfiguration]
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
                .environmentObject(healthWorkoutRouteAutoImporter)
                .environmentObject(cloudDataPresencePublisher)
                .environmentObject(locationServiceSyncManager)
                .environmentObject(multiDevicePresenceManager)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                DailyTimelineBackup.scheduleNextRun()
                ShareMapAggregateBackgroundTask.scheduleNextRun()
                Task {
                    multiDevicePresenceManager.refreshPresence()
                    await captureManager.start()
                    await captureManager.refreshHistoricalBackfill()
                    healthWorkoutRouteAutoImporter.refreshInterruptedHistoricalImportState()
                    await healthWorkoutRouteAutoImporter.startIfNeeded()
                    await cloudDataPresencePublisher.publishNow()
                    await locationServiceSyncManager.syncNewSamplesIfEnabled()
                }
                Task(priority: .utility) {
                    await ShareMapAggregateBuilder.refreshAll(in: sharedModelContainer)
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
