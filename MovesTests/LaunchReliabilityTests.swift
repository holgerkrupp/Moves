import Foundation
import SwiftData
import UIKit
import XCTest
@testable import Moves

@MainActor
final class LaunchReliabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MovesStoreRecovery.clear()
    }

    override func tearDown() {
        MovesStoreRecovery.clear()
        super.tearDown()
    }

    func testApplicationSchemaContainsAuthoritativeAndCacheModels() {
        let applicationNames = Set(MovesTimelineStore.applicationSchema.entities.map(\.name))
        let authoritativeNames = Set(MovesTimelineStore.authoritativeSchema.entities.map(\.name))

        XCTAssertTrue(applicationNames.contains("ShareMapAggregate"))
        XCTAssertFalse(authoritativeNames.contains("ShareMapAggregate"))
        XCTAssertTrue(authoritativeNames.isSubset(of: applicationNames))
    }

    func testInMemoryApplicationContainerOpensWithSeparateLocalCache() throws {
        let container = try MovesTimelineStore.makeApplicationContainer(isStoredInMemoryOnly: true)

        assertApplicationConfigurations(container)
        let context = ModelContext(container)
        context.insert(makeAggregate())
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ShareMapAggregate>()), 1)
    }

    func testCloudKitDisabledApplicationContainerOpens() throws {
        let container = try MovesTimelineStore.makeApplicationContainer(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none
        )

        assertApplicationConfigurations(container)
        let timelineConfiguration = try XCTUnwrap(configuration(
            containing: "DayTimeline",
            in: container
        ))
        XCTAssertTrue(String(reflecting: timelineConfiguration.cloudKitDatabase).contains("_none: true"))
    }

    func testProductionStyleCloudKitApplicationContainerOpensWithoutUsingRealStore() throws {
        try withTemporaryStoreDirectory { directory in
            let container = try MovesTimelineStore.makeApplicationContainer(
                cloudKitDatabase: .private(MovesTimelineStore.cloudKitContainerIdentifier),
                timelineStoreURL: directory.appendingPathComponent("timeline.store"),
                cacheStoreURL: directory.appendingPathComponent("cache.store")
            )

            assertApplicationConfigurations(container)
            let timelineConfiguration = try XCTUnwrap(configuration(
                containing: "DayTimeline",
                in: container
            ))
            let cloudDescription = String(reflecting: timelineConfiguration.cloudKitDatabase)
            XCTAssertTrue(cloudDescription.contains("_none: false"))
            XCTAssertTrue(cloudDescription.contains(MovesTimelineStore.cloudKitContainerIdentifier))
        }
    }

    func testContainerRejectsConfigurationModelMissingFromTopLevelSchema() {
        let timelineConfiguration = MovesTimelineStore.makeConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none
        )
        let cacheConfiguration = ModelConfiguration(
            "ShareMapCache",
            schema: Schema([ShareMapAggregate.self]),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        XCTAssertThrowsError(try ModelContainer(
            for: MovesTimelineStore.authoritativeSchema,
            configurations: [timelineConfiguration, cacheConfiguration]
        ))
    }

    func testDiagnosticsInitializationDoesNotReadTimeline() async throws {
        let container = try makeInMemoryContainer()
        let tracker = InvocationTracker()
        let defaults = makeIsolatedDefaults()
        let diagnostics = MovesSyncDiagnostics(
            modelContainer: container,
            userDefaults: defaults,
            notificationCenter: NotificationCenter(),
            snapshotLoader: {
                await tracker.recordCall()
                return Self.emptySnapshot()
            }
        )

        await Task.yield()
        let callCount = await tracker.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(diagnostics.latestSnapshot)
    }

    func testDiagnosticsLargeHistoryEventuallyProducesCorrectBoundedSnapshot() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let newestDate = Date(timeIntervalSince1970: 1_900_000_000)
        let historyStart = newestDate.addingTimeInterval(-4_100 * 24 * 60 * 60)
        let rowCount = 1_250

        for index in 0..<rowCount {
            let date = historyStart.addingTimeInterval(Double(index) * 24 * 60 * 60)
            let place = VisitPlace(
                arrivalDate: date,
                departureDate: date.addingTimeInterval(30 * 60),
                latitude: 0,
                longitude: 0,
                horizontalAccuracy: 10
            )
            place.createdAt = date
            context.insert(place)

            let move = MoveSegment(
                dedupeKey: "large-history-\(index)",
                startDate: date,
                endDate: date.addingTimeInterval(20 * 60),
                transportMode: .walking,
                distanceMeters: 1_000,
                stepCount: nil
            )
            move.createdAt = index == rowCount - 1 ? newestDate : date
            context.insert(move)
        }
        try context.save()

        let diagnostics = MovesSyncDiagnostics(
            modelContainer: container,
            observationDebounce: .milliseconds(1),
            userDefaults: makeIsolatedDefaults(),
            notificationCenter: NotificationCenter()
        )
        XCTAssertNil(diagnostics.latestSnapshot)
        diagnostics.startObservingTimeline()

        let observedLargeHistory = await waitUntil { diagnostics.latestSnapshot != nil }
        XCTAssertTrue(observedLargeHistory)
        let snapshot = try XCTUnwrap(diagnostics.latestSnapshot)
        XCTAssertEqual(snapshot.placeCount, rowCount)
        XCTAssertEqual(snapshot.moveCount, rowCount)
        XCTAssertEqual(snapshot.newestCreatedAt, newestDate)
        XCTAssertEqual(MovesSyncDiagnosticsSnapshotLoader.newestFetchLimit, 1)
    }

    func testTimelineNotificationBurstsCoalesce() async throws {
        let container = try makeInMemoryContainer()
        let center = NotificationCenter()
        let tracker = InvocationTracker()
        let diagnostics = MovesSyncDiagnostics(
            modelContainer: container,
            observationDebounce: .milliseconds(60),
            userDefaults: makeIsolatedDefaults(),
            notificationCenter: center,
            snapshotLoader: {
                let count = await tracker.recordCall()
                return MovesSyncTimelineSnapshot(
                    observedAt: Date(),
                    placeCount: count,
                    moveCount: count,
                    newestCreatedAt: nil
                )
            }
        )
        diagnostics.startObservingTimeline()
        let observedInitialSnapshot = await waitUntil { await tracker.callCount == 1 }
        XCTAssertTrue(observedInitialSnapshot)

        for _ in 0..<30 {
            center.post(name: .movesTimelineDidChange, object: nil)
        }

        let observedCoalescedSnapshot = await waitUntil { await tracker.callCount == 2 }
        XCTAssertTrue(observedCoalescedSnapshot)
        try await Task.sleep(for: .milliseconds(150))
        let callCount = await tracker.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(diagnostics.latestSnapshot?.placeCount, 2)
    }

    func testDiagnosticsCancellationDoesNotBlockSuspension() async throws {
        let container = try makeInMemoryContainer()
        let center = NotificationCenter()
        let tracker = CancellationTracker()
        let diagnostics = MovesSyncDiagnostics(
            modelContainer: container,
            userDefaults: makeIsolatedDefaults(),
            notificationCenter: center,
            snapshotLoader: {
                await tracker.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return Self.emptySnapshot()
                } catch {
                    await tracker.markCancelled()
                    throw error
                }
            }
        )
        diagnostics.startObservingTimeline()
        let didStart = await waitUntil { await tracker.started }
        XCTAssertTrue(didStart)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        let didCancel = await waitUntil { await tracker.cancelled }
        XCTAssertTrue(didCancel)
        XCTAssertNil(diagnostics.latestSnapshot)
    }

    func testRuntimePublishesReadyBeforeDiagnosticsObservationCompletes() async throws {
        let container = try makeInMemoryContainer()
        let tracker = CancellationTracker()
        let runtime = MovesAppRuntime(
            applicationContainerFactory: { container },
            localFallbackContainerFactory: { container },
            initializesServices: false,
            diagnosticsFactory: { modelContainer in
                MovesSyncDiagnostics(
                    modelContainer: modelContainer,
                    userDefaults: self.makeIsolatedDefaults(),
                    notificationCenter: NotificationCenter(),
                    snapshotLoader: {
                        await tracker.markStarted()
                        try await Task.sleep(for: .seconds(30))
                        return Self.emptySnapshot()
                    }
                )
            }
        )

        await runtime.prepare()

        XCTAssertEqual(runtime.preparationState, .ready)
        XCTAssertTrue(runtime.isReady)
        XCTAssertIdentical(runtime.container, container)
        let didStart = await waitUntil { await tracker.started }
        XCTAssertTrue(didStart)
        XCTAssertNil(runtime.syncDiagnostics?.latestSnapshot)
    }

    func testNormalStartupDoesNotUseFallback() async throws {
        let container = try makeInMemoryContainer()
        let fallbackCalls = LockedCounter()
        let runtime = makeRuntime(
            applicationContainerFactory: { container },
            localFallbackContainerFactory: {
                fallbackCalls.increment()
                return container
            }
        )

        await runtime.prepare()

        XCTAssertEqual(runtime.preparationState, .ready)
        XCTAssertTrue(runtime.isReady)
        XCTAssertEqual(fallbackCalls.value, 0)
        XCTAssertNil(runtime.storeOpenFailure)
    }

    func testCloudKitFailureWithLocalFallbackStillOpensAppInDegradedMode() async throws {
        let container = try makeInMemoryContainer()
        let runtime = makeRuntime(
            applicationContainerFactory: { throw TestStoreError.cloudKitUnavailable },
            localFallbackContainerFactory: { container }
        )

        await runtime.prepare()

        XCTAssertEqual(runtime.preparationState, .ready)
        XCTAssertTrue(runtime.isReady)
        XCTAssertIdentical(runtime.container, container)
        XCTAssertEqual(runtime.storeOpenFailure?.attemptedMode, .cloudKit)
    }

    func testBothStoreOpenAttemptsFailAndReplaceLoadingState() async {
        let runtime = makeRuntime(
            applicationContainerFactory: { throw TestStoreError.cloudKitUnavailable },
            localFallbackContainerFactory: { throw TestStoreError.localStoreUnavailable }
        )

        await runtime.prepare()

        guard case .failed(let failure) = runtime.preparationState else {
            return XCTFail("A completed failed startup must leave the launch placeholder state")
        }
        XCTAssertFalse(runtime.isReady)
        XCTAssertNil(runtime.container)
        XCTAssertEqual(failure.attemptedMode, .localFallback)
    }

    func testUserRetryCanTransitionFailureToReady() async throws {
        let container = try makeInMemoryContainer()
        let primaryFactory = RetryContainerFactory(successfulContainer: container)
        let fallbackCalls = LockedCounter()
        let runtime = makeRuntime(
            applicationContainerFactory: { try primaryFactory.make() },
            localFallbackContainerFactory: {
                fallbackCalls.increment()
                throw TestStoreError.localStoreUnavailable
            }
        )

        await runtime.prepare()
        guard case .failed = runtime.preparationState else {
            return XCTFail("The first attempt should fail")
        }

        await runtime.retryPreparation()

        XCTAssertEqual(runtime.preparationState, .ready)
        XCTAssertTrue(runtime.isReady)
        XCTAssertIdentical(runtime.container, container)
        XCTAssertEqual(primaryFactory.callCount, 2)
        XCTAssertEqual(fallbackCalls.value, 1)
    }

    func testRepeatedRetryFailureIsUserBoundedAndDoesNotLoop() async throws {
        let primaryCalls = LockedCounter()
        let fallbackCalls = LockedCounter()
        let runtime = makeRuntime(
            applicationContainerFactory: {
                primaryCalls.increment()
                throw TestStoreError.cloudKitUnavailable
            },
            localFallbackContainerFactory: {
                fallbackCalls.increment()
                throw TestStoreError.localStoreUnavailable
            }
        )

        await runtime.prepare()
        await runtime.retryPreparation()
        try await Task.sleep(for: .milliseconds(100))

        guard case .failed = runtime.preparationState else {
            return XCTFail("Repeated failure should remain actionable")
        }
        XCTAssertEqual(primaryCalls.value, 2)
        XCTAssertEqual(fallbackCalls.value, 2)
    }

    func testStoreOpenDiagnosticsArePrivacySafe() {
        let privateMessage = """
        Failed /Users/alice/Library/Application Support/Moves/store.sqlite
        https://example.com/user/42
        access_token=topsecret
        latitude=48.137 longitude=11.575
        account=alice@example.com
        """
        let error = NSError(
            domain: "Moves.Store",
            code: URLError.timedOut.rawValue,
            userInfo: [NSLocalizedDescriptionKey: privateMessage]
        )
        let failure = MovesStoreRecovery.record(
            error,
            attemptedMode: .localFallback,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let report = MovesStoreRecovery.diagnosticsReport(
            for: failure,
            appVersion: "3.2",
            buildVersion: "42",
            operatingSystem: "TestOS 1.0"
        )

        XCTAssertTrue(report.contains("3.2 (42)"))
        XCTAssertTrue(report.contains("TestOS 1.0"))
        XCTAssertTrue(report.contains("Local fallback"))
        XCTAssertTrue(report.contains("Moves.Store / -1001"))
        XCTAssertFalse(report.contains("alice"))
        XCTAssertFalse(report.contains("example.com"))
        XCTAssertFalse(report.contains("topsecret"))
        XCTAssertFalse(report.contains("alice@example.com"))
        XCTAssertFalse(report.contains("48.137"))
        XCTAssertFalse(report.contains("11.575"))
    }

    private func assertApplicationConfigurations(
        _ container: ModelContainer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let applicationNames = Set(container.schema.entities.map(\.name))
        XCTAssertTrue(applicationNames.contains("ShareMapAggregate"), file: file, line: line)

        let timeline = configuration(containing: "DayTimeline", in: container)
        let cache = configuration(containing: "ShareMapAggregate", in: container)
        XCTAssertNotNil(timeline, file: file, line: line)
        XCTAssertNotNil(cache, file: file, line: line)
        XCTAssertEqual(
            Set(timeline?.schema?.entities.map(\.name) ?? []),
            Set(MovesTimelineStore.authoritativeSchema.entities.map(\.name)),
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(cache?.schema?.entities.map(\.name) ?? []),
            ["ShareMapAggregate"],
            file: file,
            line: line
        )
        XCTAssertTrue(
            String(reflecting: cache?.cloudKitDatabase as Any).contains("_none: true"),
            file: file,
            line: line
        )
    }

    private func configuration(
        containing entityName: String,
        in container: ModelContainer
    ) -> ModelConfiguration? {
        container.configurations.first { configuration in
            configuration.schema?.entities.contains { $0.name == entityName } == true
        }
    }

    private func withTemporaryStoreDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovesLaunchReliability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeAggregate() -> ShareMapAggregate {
        ShareMapAggregate(
            periodKey: "year:2026",
            period: .year,
            periodStart: Date(timeIntervalSince1970: 1_800_000_000),
            sourceSignature: "test",
            tracksData: Data()
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        try MovesTimelineStore.makeApplicationContainer(isStoredInMemoryOnly: true)
    }

    private func makeRuntime(
        applicationContainerFactory: @escaping MovesAppRuntime.ContainerFactory,
        localFallbackContainerFactory: @escaping MovesAppRuntime.ContainerFactory
    ) -> MovesAppRuntime {
        MovesAppRuntime(
            applicationContainerFactory: applicationContainerFactory,
            localFallbackContainerFactory: localFallbackContainerFactory,
            initializesServices: false,
            diagnosticsFactory: { container in
                MovesSyncDiagnostics(
                    modelContainer: container,
                    userDefaults: self.makeIsolatedDefaults(),
                    notificationCenter: NotificationCenter(),
                    snapshotLoader: { Self.emptySnapshot() }
                )
            }
        )
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "MovesLaunchReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    nonisolated private static func emptySnapshot() -> MovesSyncTimelineSnapshot {
        MovesSyncTimelineSnapshot(
            observedAt: Date(),
            placeCount: 0,
            moveCount: 0,
            newestCreatedAt: nil
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private enum TestStoreError: LocalizedError {
    case cloudKitUnavailable
    case localStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: return "CloudKit is temporarily unavailable."
        case .localStoreUnavailable: return "The local store could not be opened."
        }
    }
}

private actor InvocationTracker {
    private(set) var callCount = 0

    @discardableResult
    func recordCall() -> Int {
        callCount += 1
        return callCount
    }
}

private actor CancellationTracker {
    private(set) var started = false
    private(set) var cancelled = false

    func markStarted() {
        started = true
    }

    func markCancelled() {
        cancelled = true
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class RetryContainerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let successfulContainer: ModelContainer
    private var calls = 0

    init(successfulContainer: ModelContainer) {
        self.successfulContainer = successfulContainer
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func make() throws -> ModelContainer {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if call == 1 {
            throw TestStoreError.cloudKitUnavailable
        }
        return successfulContainer
    }
}
