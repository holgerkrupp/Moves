import CloudKit
import SwiftData
import XCTest
@testable import Moves

final class CrossDeviceWorkCoordinatorTests: XCTestCase {
    func testOnlyOneDeviceClaimsAnActiveSharedLease() async throws {
        let container = try makeContainer()
        let first = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "phone", backend: .legacySwiftDataForTesting)
        let second = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "mac", backend: .legacySwiftDataForTesting)
        let key = BackgroundWorkKey(kind: "test", partition: "same-range", version: 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let firstClaim = try await first.acquire(key: key, scope: .accountShared, now: now)
        guard case .acquired(let lease) = firstClaim else {
            return XCTFail("The first eligible device should acquire the lease")
        }

        let secondClaim = try await second.acquire(key: key, scope: .accountShared, now: now)
        guard case .skipped(.leaseHeld) = secondClaim else {
            return XCTFail("A second device must not claim an active lease")
        }

        let renewed = try await first.renew(lease, now: now.addingTimeInterval(60))
        XCTAssertTrue(renewed)
    }

    func testCompletedWorkAndExpiredLeasesCanBeDistinguished() async throws {
        let container = try makeContainer()
        let first = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "phone", backend: .legacySwiftDataForTesting)
        let second = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "mac", backend: .legacySwiftDataForTesting)
        let key = BackgroundWorkKey(kind: "test", partition: "versioned", version: 2)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let completedClaim = try await first.acquire(key: key, scope: .accountShared, now: now)
        guard case .acquired(let completedLease) = completedClaim else {
            return XCTFail("Expected an initial claim")
        }
        try await first.finish(completedLease, completed: true, completionMarker: "high-water-1", now: now)

        let completedAgain = try await second.acquire(key: key, scope: .accountShared, now: now.addingTimeInterval(1))
        guard case .skipped(.alreadyCompleted) = completedAgain else {
            return XCTFail("Completed work should not be repeated for the same versioned key")
        }

        let expiringKey = BackgroundWorkKey(kind: "test", partition: "takeover", version: 1)
        let expiringClaim = try await first.acquire(
            key: expiringKey,
            scope: .accountShared,
            now: now,
            leaseDuration: 10
        )
        guard case .acquired = expiringClaim else {
            return XCTFail("Expected a short-lived claim")
        }

        let takeover = try await second.acquire(
            key: expiringKey,
            scope: .accountShared,
            now: now.addingTimeInterval(11)
        )
        guard case .acquired = takeover else {
            return XCTFail("A stale lease should be taken over")
        }
    }

    func testACompletedLeaseCanBeReopenedForANewerHighWaterMarker() async throws {
        let container = try makeContainer()
        let coordinator = CrossDeviceWorkCoordinator(
            modelContainer: container,
            deviceIdentifier: "phone",
            backend: .legacySwiftDataForTesting
        )
        let key = BackgroundWorkKey(kind: "externalSync", partition: "hour-1", version: 1)
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)

        guard case .acquired(let firstLease) = try await coordinator.acquire(
            key: key,
            scope: .accountShared,
            now: firstDate,
            completionMarker: "point-1"
        ) else {
            return XCTFail("Expected the first marker to acquire")
        }
        try await coordinator.finish(
            firstLease,
            completed: true,
            completionMarker: "point-1",
            now: firstDate
        )

        guard case .acquired = try await coordinator.acquire(
            key: key,
            scope: .accountShared,
            now: firstDate.addingTimeInterval(1),
            completionMarker: "point-2"
        ) else {
            return XCTFail("A newer high-water marker must not be suppressed by the old completion")
        }
    }

    func testBackgroundWorkKeyIdentifierIncludesAllKeyParts() {
        XCTAssertEqual(
            BackgroundWorkKey(kind: "kind", partition: "partition", version: 3).identifier,
            "kind:partition:v3"
        )
    }

    func testAuthoritativeStoreCanBeOpenedAgainAfterAnExistingStoreUpgrade() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovesStoreUpgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("timeline.store")
        let oldSchema = Schema(MovesTimelineStore.authoritativeModelTypes + [CrossDeviceWorkLease.self])
        let oldConfiguration = ModelConfiguration(
            "MovesTimeline",
            schema: oldSchema,
            url: storeURL,
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none
        )
        let first = try ModelContainer(for: oldSchema, configurations: [oldConfiguration])
        let context = ModelContext(first)
        context.insert(CrossDeviceWorkLease(
            workKey: "existing:v1",
            scope: .accountShared,
            ownerDeviceIdentifier: "phone",
            acquiredAt: .now,
            leaseExpiresAt: .now.addingTimeInterval(60),
            algorithmVersion: 1
        ))
        try context.save()

        _ = try MovesTimelineStore.makeContainer(
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none,
            storeURL: storeURL
        )
        XCTAssertFalse(MovesTimelineStore.authoritativeSchema.entities.contains {
            $0.name == "CrossDeviceWorkLease"
        })
    }

    func testDeviceLocalWorkDoesNotCreateACloudKitLease() async throws {
        let container = try makeContainer()
        let coordinator = CrossDeviceWorkCoordinator(
            modelContainer: container,
            deviceIdentifier: "phone",
            backend: .legacySwiftDataForTesting
        )
        let key = BackgroundWorkKey(kind: "explorationCache", partition: "tile-1", version: 1)

        guard case .acquired = try await coordinator.acquire(key: key, scope: .deviceLocal) else {
            return XCTFail("Device-local work should always be locally eligible")
        }

        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CrossDeviceWorkLease>()).isEmpty)
    }

    func testTransientLeaseFailureRetriesAreBoundedAndUnsafeWorkIsDeferred() async {
        let store = FailingLeaseStore(error: LeaseTestError.networkUnavailable)
        let delays = RetryDelayRecorder()
        let coordinator = CrossDeviceWorkCoordinator(
            deviceIdentifier: "phone",
            leaseStore: store,
            retryPolicy: CrossDeviceWorkRetryPolicy(
                maximumAttempts: 3,
                initialDelay: 0.25,
                maximumDelay: 1
            ),
            sleep: { delay in await delays.record(delay) }
        )

        do {
            _ = try await coordinator.acquire(
                key: BackgroundWorkKey(kind: "unsafeUpload", partition: "range", version: 1),
                scope: .accountShared
            )
            XCTFail("Unsafe shared work must be deferred when no lease can be established")
        } catch is CrossDeviceWorkCoordinationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let acquireAttempts = await store.acquireAttempts
        let recordedDelays = await delays.values
        XCTAssertEqual(acquireAttempts, 3)
        XCTAssertEqual(recordedDelays, [0.25, 0.5])
    }

    func testIdempotentWorkCanExplicitlyFallBackWithoutRetryingPersistentFailure() async throws {
        let store = FailingLeaseStore(error: LeaseTestError.productionSchemaMissing)
        let coordinator = CrossDeviceWorkCoordinator(
            deviceIdentifier: "phone",
            leaseStore: store,
            retryPolicy: CrossDeviceWorkRetryPolicy(
                maximumAttempts: 3,
                initialDelay: 0,
                maximumDelay: 0
            ),
            sleep: { _ in }
        )

        let claim = try await coordinator.acquire(
            key: BackgroundWorkKey(kind: "idempotentMaintenance", partition: "all", version: 1),
            scope: .accountShared,
            failurePolicy: .allowLocalFallback
        )
        guard case .acquired(let token) = claim else {
            return XCTFail("Explicitly safe work should receive a local fallback token")
        }

        XCTAssertEqual(token.scope, .deviceLocal)
        let acquireAttempts = await store.acquireAttempts
        XCTAssertEqual(acquireAttempts, 1)
        try await coordinator.finish(token, completed: true)
        let finishAttempts = await store.finishAttempts
        XCTAssertEqual(finishAttempts, 0)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([CrossDeviceWorkLease.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private enum LeaseTestError: Error, CustomNSError, LocalizedError, Sendable {
    case networkUnavailable
    case productionSchemaMissing

    static var errorDomain: String { CKErrorDomain }

    var errorCode: Int {
        switch self {
        case .networkUnavailable: return CKError.Code.networkUnavailable.rawValue
        case .productionSchemaMissing: return CKError.Code.serverRejectedRequest.rawValue
        }
    }

    var errorDescription: String? {
        switch self {
        case .networkUnavailable: return "The network is unavailable."
        case .productionSchemaMissing: return "Cannot create new type MovesWorkLease in production schema"
        }
    }
}

private actor FailingLeaseStore: CrossDeviceWorkLeaseStore {
    private let error: LeaseTestError
    private(set) var acquireAttempts = 0
    private(set) var finishAttempts = 0

    init(error: LeaseTestError) {
        self.error = error
    }

    func acquire(
        key: BackgroundWorkKey,
        ownerDeviceIdentifier: String,
        now: Date,
        leaseDuration: TimeInterval,
        completionMarker: String?
    ) async throws -> CrossDeviceWorkClaim {
        acquireAttempts += 1
        throw error
    }

    func renew(
        _ token: CrossDeviceWorkLeaseToken,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> Bool {
        throw error
    }

    func finish(
        _ token: CrossDeviceWorkLeaseToken,
        completed: Bool,
        completionMarker: String?,
        now: Date
    ) async throws {
        finishAttempts += 1
        throw error
    }
}

private actor RetryDelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }
}
