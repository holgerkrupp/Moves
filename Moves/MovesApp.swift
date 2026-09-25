//
//  MovesApp.swift
//  Moves
//
//  Created by Holger Krupp on 23.07.24.
//

import SwiftUI
import SwiftData
import AppIntents
import CloudKitSyncMonitor
#if canImport(UIKit)
import UIKit
#endif
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
        RouteFileImportBackgroundTask.register()
        RouteWatchFolderBackgroundTask.register()
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

struct MovesCommandActions {
    let showSettings: () -> Void
    let chooseDate: () -> Void
    let selectToday: () -> Void
    let selectOlderDay: () -> Void
    let selectNewerDay: () -> Void
    let canSelectOlderDay: Bool
    let canSelectNewerDay: Bool
}

private struct MovesCommandActionsKey: FocusedValueKey {
    typealias Value = MovesCommandActions
}

extension FocusedValues {
    var movesCommandActions: MovesCommandActions? {
        get { self[MovesCommandActionsKey.self] }
        set { self[MovesCommandActionsKey.self] = newValue }
    }
}

struct MovesCommands: Commands {
    @FocusedValue(\.movesCommandActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                actions?.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(actions == nil)
        }

        CommandMenu("Timeline") {
            Button("Today") {
                actions?.selectToday()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Choose Date…") {
                actions?.chooseDate()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button("Previous Day") {
                actions?.selectOlderDay()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(actions?.canSelectOlderDay != true)

            Button("Next Day") {
                actions?.selectNewerDay()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(actions?.canSelectNewerDay != true)
        }
    }
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
    @StateObject private var importCoordinator: ImportCoordinator
    @StateObject private var routeFileImporter: RouteFileImporter
    @StateObject private var routeWatchFolderManager: RouteWatchFolderManager
    @StateObject private var importedRouteDataSummary: ImportedRouteDataSummaryStore

    init() {
        SyncMonitor.default.startMonitoring()

        do {
            let container = try Self.makeModelContainer()
            #if !targetEnvironment(macCatalyst)
            try Self.ensureCurrentDayExists(in: container)
            #endif
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
            let importCoordinator = ImportCoordinator()
            let routeFileImporter = RouteFileImporter(
                modelContext: ModelContext(container),
                importCoordinator: importCoordinator
            )
            importCoordinator.attach(routeFileImporter: routeFileImporter)
            _importCoordinator = StateObject(wrappedValue: importCoordinator)
            _routeFileImporter = StateObject(wrappedValue: routeFileImporter)
            _routeWatchFolderManager = StateObject(
                wrappedValue: RouteWatchFolderManager(importer: routeFileImporter)
            )
            _importedRouteDataSummary = StateObject(
                wrappedValue: ImportedRouteDataSummaryStore(modelContainer: container)
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

        #if targetEnvironment(simulator) && DEBUG
        DemoDataSeeder.seedIfNeeded(in: container)
        #endif

        return container
    }

    static func ensureCurrentDayExists(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let todayStart = Calendar.current.startOfDay(for: .now)
        let todayKey = DayTimeline.makeDayKey(for: todayStart)
        var descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { day in
                day.dayKey == todayKey
            }
        )
        descriptor.fetchLimit = 1

        guard try context.fetch(descriptor).isEmpty else { return }
        context.insert(DayTimeline(dayStart: todayStart))
        try context.save()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if targetEnvironment(macCatalyst)
                ContentView()
                    .frame(
                        minWidth: 720,
                        maxWidth: .infinity,
                        minHeight: 520,
                        maxHeight: .infinity
                    )
                #else
                ContentView()
                #endif
            }
                .environmentObject(captureManager)
                .environmentObject(undoController)
                .environmentObject(healthWorkoutRouteAutoImporter)
                .environmentObject(cloudDataPresencePublisher)
                .environmentObject(locationServiceSyncManager)
                .environmentObject(multiDevicePresenceManager)
                .environmentObject(importCoordinator)
                .environmentObject(routeFileImporter)
                .environmentObject(routeWatchFolderManager)
                .environmentObject(importedRouteDataSummary)
        }
        .modelContainer(sharedModelContainer)
        #if targetEnvironment(macCatalyst)
        .windowResizability(.contentSize)
        #endif
        .defaultSize(width: 1_100, height: 760)
        .commands {
            MovesCommands()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                DailyTimelineBackup.scheduleNextRun()
                ShareMapAggregateBackgroundTask.scheduleNextRun()
                RouteFileImportBackgroundTask.schedule()
                RouteWatchFolderBackgroundTask.schedule()
                routeWatchFolderManager.scanIfNeeded()
                Task {
                    if captureManager.isLocationTrackingAvailable {
                        multiDevicePresenceManager.refreshPresence()
                        await captureManager.start()
                        await captureManager.refreshHistoricalBackfill()
                    }
                    healthWorkoutRouteAutoImporter.refreshInterruptedHistoricalImportState()
                    await healthWorkoutRouteAutoImporter.startIfNeeded()
                    await cloudDataPresencePublisher.publishNow()
                    await locationServiceSyncManager.syncNewSamplesIfEnabled()
                }
                Task(priority: .utility) {
                    await ImportedTransportModeRefinement.run(in: sharedModelContainer)
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
