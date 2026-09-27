import Foundation
import SwiftData

enum BackgroundWorkScope: String, Codable, Sendable {
    case deviceLocal
    case accountShared
}

struct BackgroundWorkKey: Hashable, Codable, Sendable {
    let kind: String
    let partition: String
    let version: Int

    var identifier: String {
        "(kind):(partition):v(version)"
    }
}

@Model
final class CrossDeviceWorkLease {
    var workKey: String = ""
    var scopeRawValue: String = BackgroundWorkScope.accountShared.rawValue
    var ownerDeviceIdentifier: String = ""
    var acquiredAt: Date = Date(timeIntervalSince1970: 0)
    var leaseExpiresAt: Date = Date(timeIntervalSince1970: 0)
    var lastUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    var algorithmVersion: Int = 1
    var completionMarker: String?
    var completedAt: Date?

    init(
        workKey: String,
        scope: BackgroundWorkScope,
        ownerDeviceIdentifier: String,
        acquiredAt: Date,
        leaseExpiresAt: Date,
        algorithmVersion: Int
    ) {
        self.workKey = workKey
        self.scopeRawValue = scope.rawValue
        self.ownerDeviceIdentifier = ownerDeviceIdentifier
        self.acquiredAt = acquiredAt
        self.leaseExpiresAt = leaseExpiresAt
        self.lastUpdatedAt = acquiredAt
        self.algorithmVersion = algorithmVersion
    }
}

struct CrossDeviceWorkLeaseToken: Equatable, Sendable {
    let workKey: String
    let ownerDeviceIdentifier: String
    let acquiredAt: Date
    let leaseExpiresAt: Date
    let scope: BackgroundWorkScope
}

enum CrossDeviceWorkSkipReason: String, Sendable {
    case leaseHeld
    case alreadyCompleted
}

enum CrossDeviceWorkClaim: Sendable {
    case acquired(CrossDeviceWorkLeaseToken)
    case skipped(CrossDeviceWorkSkipReason)
}

/// Coordinates only work whose result or side effect is shared by the account.
/// Device-local jobs should use the same key vocabulary with `.deviceLocal`; no
/// CloudKit lease row is created for those jobs.
actor CrossDeviceWorkCoordinator {
    static let defaultLeaseDuration: TimeInterval = 15 * 60

    private let modelContainer: ModelContainer
    private let deviceIdentifier: String

    init(
        modelContainer: ModelContainer,
        deviceIdentifier: String = DeviceIdentityStore.currentIdentifier
    ) {
        self.modelContainer = modelContainer
        self.deviceIdentifier = deviceIdentifier
    }

    func acquire(
        key: BackgroundWorkKey,
        scope: BackgroundWorkScope,
        now: Date = .now,
        leaseDuration: TimeInterval = CrossDeviceWorkCoordinator.defaultLeaseDuration
    ) throws -> CrossDeviceWorkClaim {
        let token = CrossDeviceWorkLeaseToken(
            workKey: key.identifier,
            ownerDeviceIdentifier: deviceIdentifier,
            acquiredAt: now,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            scope: scope
        )

        guard scope == .accountShared else {
            return .acquired(token)
        }

        let context = ModelContext(modelContainer)
        let workKey = key.identifier
        var descriptor = FetchDescriptor<CrossDeviceWorkLease>(
            predicate: #Predicate { lease in
                lease.workKey == workKey
            }
        )
        descriptor.fetchLimit = 1

        if let lease = try context.fetch(descriptor).first {
            if lease.completedAt != nil {
                return .skipped(.alreadyCompleted)
            }

            if lease.leaseExpiresAt > now {
                return .skipped(.leaseHeld)
            }

            // A stale owner can always be replaced. The old token cannot finish
            // this lease because acquiredAt changes on takeover.
            lease.ownerDeviceIdentifier = deviceIdentifier
            lease.acquiredAt = now
            lease.leaseExpiresAt = token.leaseExpiresAt
            lease.lastUpdatedAt = now
            lease.algorithmVersion = key.version
        } else {
            context.insert(
                CrossDeviceWorkLease(
                    workKey: key.identifier,
                    scope: scope,
                    ownerDeviceIdentifier: deviceIdentifier,
                    acquiredAt: now,
                    leaseExpiresAt: token.leaseExpiresAt,
                    algorithmVersion: key.version
                )
            )
        }

        try context.save()
        return .acquired(token)
    }

    func renew(
        _ token: CrossDeviceWorkLeaseToken,
        now: Date = .now,
        leaseDuration: TimeInterval = CrossDeviceWorkCoordinator.defaultLeaseDuration
    ) throws -> Bool {
        guard token.scope == .accountShared else { return true }
        let context = ModelContext(modelContainer)
        let workKey = token.workKey
        var descriptor = FetchDescriptor<CrossDeviceWorkLease>(
            predicate: #Predicate { lease in
                lease.workKey == workKey
            }
        )
        descriptor.fetchLimit = 1
        guard let lease = try context.fetch(descriptor).first,
              lease.ownerDeviceIdentifier == token.ownerDeviceIdentifier,
              lease.acquiredAt == token.acquiredAt,
              lease.completedAt == nil else {
            return false
        }

        lease.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
        lease.lastUpdatedAt = now
        try context.save()
        return true
    }

    func finish(
        _ token: CrossDeviceWorkLeaseToken,
        completed: Bool,
        completionMarker: String? = nil,
        now: Date = .now
    ) throws {
        guard token.scope == .accountShared else { return }
        let context = ModelContext(modelContainer)
        let workKey = token.workKey
        var descriptor = FetchDescriptor<CrossDeviceWorkLease>(
            predicate: #Predicate { lease in
                lease.workKey == workKey
            }
        )
        descriptor.fetchLimit = 1
        guard let lease = try context.fetch(descriptor).first,
              lease.ownerDeviceIdentifier == token.ownerDeviceIdentifier,
              lease.acquiredAt == token.acquiredAt else {
            return
        }

        lease.leaseExpiresAt = now
        lease.lastUpdatedAt = now
        lease.completedAt = completed ? now : nil
        lease.completionMarker = completed ? completionMarker : nil
        try context.save()
    }
}
