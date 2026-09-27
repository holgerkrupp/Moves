import SwiftData
import XCTest
@testable import Moves

final class CrossDeviceWorkCoordinatorTests: XCTestCase {
    func testOnlyOneDeviceClaimsAnActiveSharedLease() async throws {
        let container = try makeContainer()
        let first = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "phone")
        let second = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "mac")
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
        let first = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "phone")
        let second = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "mac")
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

    func testDeviceLocalWorkDoesNotCreateACloudKitLease() async throws {
        let container = try makeContainer()
        let coordinator = CrossDeviceWorkCoordinator(modelContainer: container, deviceIdentifier: "phone")
        let key = BackgroundWorkKey(kind: "explorationCache", partition: "tile-1", version: 1)

        guard case .acquired = try await coordinator.acquire(key: key, scope: .deviceLocal) else {
            return XCTFail("Device-local work should always be locally eligible")
        }

        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CrossDeviceWorkLease>()).isEmpty)
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
