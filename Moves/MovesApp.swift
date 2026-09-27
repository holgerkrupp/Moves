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
        ExplorationPreparationBackgroundTask.register()
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

    @StateObject private var runtime = MovesAppRuntime()

    init() {
        SyncMonitor.default.startMonitoring()
    }

    nonisolated static func makeModelContainer() throws -> ModelContainer {
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
        if ProcessInfo.processInfo.environment["MOVES_TEST_IN_MEMORY"] == "1" {
            // The macOS test host otherwise opens the user's real SwiftData
            // store before the test process connects. Keeping this switch
            // environment-driven leaves production storage unchanged while
            // making background/indexing tests isolated and repeatable.
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
        } else {
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
        }

        let container = try ModelContainer(
            for: schema,
            configurations: [modelConfiguration, cacheConfiguration]
        )

        return container
    }

    nonisolated static func ensureCurrentDayExists(in container: ModelContainer) throws {
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
                if let container = runtime.container {
                    readyContent(container: container)
                } else {
                    Color.clear
                }
            }
            .animation(.default, value: runtime.isReady)
            .task {
                await runtime.prepare()
            }
        }
        #if targetEnvironment(macCatalyst)
        .windowResizability(.contentSize)
        #endif
        .defaultSize(width: 1_100, height: 760)
        .commands {
            MovesCommands()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            startActiveServices()
        }
    }

    private func readyContent(container: ModelContainer) -> some View {
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
        .modelContainer(container)
        .environmentObject(runtime.captureManager!)
        .environmentObject(runtime.undoController)
        .environmentObject(runtime.healthWorkoutRouteAutoImporter!)
        .environmentObject(runtime.cloudDataPresencePublisher!)
        .environmentObject(runtime.locationServiceSyncManager!)
        .environmentObject(runtime.multiDevicePresenceManager!)
        .environmentObject(runtime.importCoordinator!)
        .environmentObject(runtime.routeFileImporter!)
        .environmentObject(runtime.routeWatchFolderManager!)
        .environmentObject(runtime.importedRouteDataSummary!)
        .task {
            startActiveServices()
        }
    }

    private func startActiveServices() {
        guard scenePhase == .active, runtime.isReady, !runtime.didStartActiveServices else { return }
        runtime.didStartActiveServices = true

        DailyTimelineBackup.scheduleNextRun()
        ShareMapAggregateBackgroundTask.scheduleNextRun()
        RouteFileImportBackgroundTask.schedule()
        RouteWatchFolderBackgroundTask.schedule()
        ExplorationPreparationBackgroundTask.schedule()
        runtime.routeWatchFolderManager?.scanIfNeeded()

        guard let captureManager = runtime.captureManager,
              let multiDevicePresenceManager = runtime.multiDevicePresenceManager,
              let healthWorkoutRouteAutoImporter = runtime.healthWorkoutRouteAutoImporter,
              let cloudDataPresencePublisher = runtime.cloudDataPresencePublisher,
              let locationServiceSyncManager = runtime.locationServiceSyncManager,
              let container = runtime.container else { return }

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
            await ImportedTransportModeRefinement.run(in: container)
        }
    }
}

@MainActor
final class MovesAppRuntime: ObservableObject {
    let undoController = AppUndoController()

    @Published private(set) var container: ModelContainer?
    @Published private(set) var isReady = false
    var didStartActiveServices = false

    private(set) var captureManager: MovesLocationCaptureManager?
    private(set) var watchRouteInbox: WatchRouteInbox?
    private(set) var healthWorkoutRouteAutoImporter: HealthWorkoutRouteAutoImportManager?
    private(set) var cloudDataPresencePublisher: MovesCloudDataPresencePublisher?
    private(set) var locationServiceSyncManager: LocationServiceSyncManager?
    private(set) var multiDevicePresenceManager: MultiDevicePresenceManager?
    private(set) var importCoordinator: ImportCoordinator?
    private(set) var routeFileImporter: RouteFileImporter?
    private(set) var routeWatchFolderManager: RouteWatchFolderManager?
    private(set) var importedRouteDataSummary: ImportedRouteDataSummaryStore?

    private var prepareTask: Task<Void, Never>?

    func prepare() async {
        guard !isReady else { return }
        if let prepareTask {
            await prepareTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let container = try await Task.detached(priority: .userInitiated) {
                    try MovesApp.makeModelContainer()
                }.value

                #if !targetEnvironment(macCatalyst)
                try await Task.detached(priority: .utility) {
                    try MovesApp.ensureCurrentDayExists(in: container)
                }.value
                #endif

                #if targetEnvironment(simulator) && DEBUG
                DemoDataSeeder.seedIfNeeded(in: container)
                #endif

                let captureManager = MovesLocationCaptureManager(modelContainer: container)
                let watchRouteInbox = WatchRouteInbox(modelContainer: container)
                let healthWorkoutRouteAutoImporter = HealthWorkoutRouteAutoImportManager(modelContainer: container)
                let cloudDataPresencePublisher = MovesCloudDataPresencePublisher(modelContainer: container)
                let locationServiceSyncManager = LocationServiceSyncManager(modelContainer: container)
                let multiDevicePresenceManager = MultiDevicePresenceManager(modelContainer: container)
                let importCoordinator = ImportCoordinator()
                let routeFileImporter = RouteFileImporter(
                    modelContext: ModelContext(container),
                    importCoordinator: importCoordinator
                )
                importCoordinator.attach(routeFileImporter: routeFileImporter)

                self.container = container
                self.captureManager = captureManager
                self.watchRouteInbox = watchRouteInbox
                self.healthWorkoutRouteAutoImporter = healthWorkoutRouteAutoImporter
                self.cloudDataPresencePublisher = cloudDataPresencePublisher
                self.locationServiceSyncManager = locationServiceSyncManager
                self.multiDevicePresenceManager = multiDevicePresenceManager
                self.importCoordinator = importCoordinator
                self.routeFileImporter = routeFileImporter
                self.routeWatchFolderManager = RouteWatchFolderManager(importer: routeFileImporter)
                self.importedRouteDataSummary = ImportedRouteDataSummaryStore(modelContainer: container)

                MovesIntentRuntime.shared.configure(
                    modelContainer: container,
                    captureManager: captureManager
                )
                MovesAppShortcuts.updateAppShortcutParameters()
                isReady = true
            } catch {
                // Keep the loading UI alive. A transient iCloud/SQLite open failure should
                // not turn into a launch crash; a future scene activation can retry.
                prepareTask = nil
            }
        }
        prepareTask = task
        await task.value
        prepareTask = nil
    }
}

extension ProcessInfo {
    var isRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
