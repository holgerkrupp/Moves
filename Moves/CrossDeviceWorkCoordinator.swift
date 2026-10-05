import CloudKit
import CryptoKit
import Foundation
import OSLog
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
        "\(kind):\(partition):v\(version)"
    }
}

/// Compatibility-only SwiftData representation used by migration and local tests.
/// Production coordination uses `MovesWorkLease` records through CloudKit and
/// this model must not be added to `MovesTimelineStore.authoritativeModelTypes`.
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

enum CrossDeviceWorkFailurePolicy: Equatable, Sendable {
    /// Shared work is not started when CloudKit cannot establish exclusivity.
    case deferWork
    /// Only for idempotent work whose duplicate execution has no harmful side effect.
    case allowLocalFallback
}

struct CrossDeviceWorkRetryPolicy: Sendable {
    let maximumAttempts: Int
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    static let `default` = CrossDeviceWorkRetryPolicy(
        maximumAttempts: 3,
        initialDelay: 0.5,
        maximumDelay: 2
    )

    static let none = CrossDeviceWorkRetryPolicy(
        maximumAttempts: 1,
        initialDelay: 0,
        maximumDelay: 0
    )
}

struct CrossDeviceWorkCoordinationFailure: Codable, Equatable, Sendable {
    let operation: String
    let disposition: MovesSyncDiagnostics.ErrorDisposition
    let message: String
    let occurredAt: Date
}

enum CrossDeviceWorkCoordinationError: LocalizedError, Sendable {
    case unavailable(CrossDeviceWorkCoordinationFailure)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Shared work was deferred because cross-device coordination is unavailable."
        }
    }
}

extension Notification.Name {
    static let movesWorkCoordinationHealthDidChange = Notification.Name(
        "Moves.workCoordinationHealthDidChange"
    )
}

enum CrossDeviceWorkCoordinationHealth {
    private static let defaultsKey = "Moves.workCoordinationFailure.v1"
    private static let logger = Logger(
        subsystem: "de.holgerkrupp.Moves",
        category: "WorkCoordination"
    )

    static var lastFailure: CrossDeviceWorkCoordinationFailure? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CrossDeviceWorkCoordinationFailure.self, from: data)
    }

    static func recordFailure(_ error: Error, operation: String, at date: Date = .now) {
        let analysis = CloudKitFailureAnalysis.analyze(error)
        let failure = CrossDeviceWorkCoordinationFailure(
            operation: operation,
            disposition: analysis.disposition,
            message: analysis.message,
            occurredAt: date
        )
        if let data = try? JSONEncoder().encode(failure) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        logger.error(
            "operation=\(operation, privacy: .public) disposition=\(analysis.disposition.rawValue, privacy: .public) message=\(analysis.message, privacy: .public)"
        )
        NotificationCenter.default.post(name: .movesWorkCoordinationHealthDidChange, object: nil)
    }

    static func recordSuccess() {
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: .movesWorkCoordinationHealthDidChange, object: nil)
    }
}

protocol CrossDeviceWorkLeaseStore: Sendable {
    func acquire(
        key: BackgroundWorkKey,
        ownerDeviceIdentifier: String,
        now: Date,
        leaseDuration: TimeInterval,
        completionMarker: String?
    ) async throws -> CrossDeviceWorkClaim

    func renew(
        _ token: CrossDeviceWorkLeaseToken,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> Bool

    func finish(
        _ token: CrossDeviceWorkLeaseToken,
        completed: Bool,
        completionMarker: String?,
        now: Date
    ) async throws
}

/// Coordinates only work whose result or side effect is shared by the account.
/// CloudKit uses conditional server saves, so two replicas cannot both win a
/// missing-record create or a stale-record takeover.
actor CrossDeviceWorkCoordinator {
    static let defaultLeaseDuration: TimeInterval = 15 * 60

    enum Backend {
        case legacySwiftDataForTesting
        case cloudKit
    }

    private let deviceIdentifier: String
    private let leaseStore: any CrossDeviceWorkLeaseStore
    private let retryPolicy: CrossDeviceWorkRetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        modelContainer: ModelContainer,
        deviceIdentifier: String = DeviceIdentityStore.currentIdentifier,
        backend: Backend = .cloudKit,
        retryPolicy: CrossDeviceWorkRetryPolicy = .default
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.retryPolicy = retryPolicy
        self.sleep = { delay in
            guard delay > 0 else { return }
            try await Task.sleep(for: .seconds(delay))
        }
        switch backend {
        case .legacySwiftDataForTesting:
            leaseStore = SwiftDataCrossDeviceWorkLeaseStore(modelContainer: modelContainer)
        case .cloudKit:
            leaseStore = CloudKitCrossDeviceWorkLeaseStore()
        }
    }

    init(
        deviceIdentifier: String,
        leaseStore: any CrossDeviceWorkLeaseStore,
        retryPolicy: CrossDeviceWorkRetryPolicy = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            guard delay > 0 else { return }
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.leaseStore = leaseStore
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    func acquire(
        key: BackgroundWorkKey,
        scope: BackgroundWorkScope,
        now: Date = .now,
        leaseDuration: TimeInterval = CrossDeviceWorkCoordinator.defaultLeaseDuration,
        completionMarker: String? = nil,
        failurePolicy: CrossDeviceWorkFailurePolicy = .deferWork
    ) async throws -> CrossDeviceWorkClaim {
        guard scope == .accountShared else {
            return .acquired(
                CrossDeviceWorkLeaseToken(
                    workKey: key.identifier,
                    ownerDeviceIdentifier: deviceIdentifier,
                    acquiredAt: now,
                    leaseExpiresAt: now.addingTimeInterval(leaseDuration),
                    scope: scope
                )
            )
        }

        do {
            let claim = try await withBoundedRetry {
                try await self.leaseStore.acquire(
                    key: key,
                    ownerDeviceIdentifier: self.deviceIdentifier,
                    now: now,
                    leaseDuration: leaseDuration,
                    completionMarker: completionMarker
                )
            }
            CrossDeviceWorkCoordinationHealth.recordSuccess()
            return claim
        } catch {
            CrossDeviceWorkCoordinationHealth.recordFailure(error, operation: "acquire", at: now)
            if failurePolicy == .allowLocalFallback {
                return .acquired(
                    CrossDeviceWorkLeaseToken(
                        workKey: key.identifier,
                        ownerDeviceIdentifier: deviceIdentifier,
                        acquiredAt: now,
                        leaseExpiresAt: now.addingTimeInterval(leaseDuration),
                        scope: .deviceLocal
                    )
                )
            }
            throw coordinationError(for: error, operation: "acquire", at: now)
        }
    }

    func renew(
        _ token: CrossDeviceWorkLeaseToken,
        now: Date = .now,
        leaseDuration: TimeInterval = CrossDeviceWorkCoordinator.defaultLeaseDuration
    ) async throws -> Bool {
        guard token.scope == .accountShared else { return true }
        do {
            let renewed = try await withBoundedRetry {
                try await self.leaseStore.renew(token, now: now, leaseDuration: leaseDuration)
            }
            CrossDeviceWorkCoordinationHealth.recordSuccess()
            return renewed
        } catch {
            CrossDeviceWorkCoordinationHealth.recordFailure(error, operation: "renew", at: now)
            throw coordinationError(for: error, operation: "renew", at: now)
        }
    }

    func finish(
        _ token: CrossDeviceWorkLeaseToken,
        completed: Bool,
        completionMarker: String? = nil,
        now: Date = .now
    ) async throws {
        guard token.scope == .accountShared else { return }
        do {
            try await withBoundedRetry {
                try await self.leaseStore.finish(
                    token,
                    completed: completed,
                    completionMarker: completionMarker,
                    now: now
                )
            }
            CrossDeviceWorkCoordinationHealth.recordSuccess()
        } catch {
            CrossDeviceWorkCoordinationHealth.recordFailure(error, operation: "finish", at: now)
            throw coordinationError(for: error, operation: "finish", at: now)
        }
    }

    private func withBoundedRetry<T: Sendable>(
        body: @Sendable () async throws -> T
    ) async throws -> T {
        let attempts = max(1, retryPolicy.maximumAttempts)
        var delay = retryPolicy.initialDelay
        for attempt in 1...attempts {
            do {
                return try await body()
            } catch {
                guard attempt < attempts,
                      CloudKitFailureAnalysis.analyze(error).disposition == .retryable else {
                    throw error
                }
                try await sleep(delay)
                delay = min(max(delay * 2, retryPolicy.initialDelay), retryPolicy.maximumDelay)
            }
        }
        preconditionFailure("Bounded retry must either return or throw")
    }

    private func coordinationError(
        for error: Error,
        operation: String,
        at date: Date
    ) -> CrossDeviceWorkCoordinationError {
        let analysis = CloudKitFailureAnalysis.analyze(error)
        return .unavailable(
            CrossDeviceWorkCoordinationFailure(
                operation: operation,
                disposition: analysis.disposition,
                message: analysis.message,
                occurredAt: date
            )
        )
    }
}

private struct SwiftDataCrossDeviceWorkLeaseStore: CrossDeviceWorkLeaseStore {
    let modelContainer: ModelContainer

    func acquire(
        key: BackgroundWorkKey,
        ownerDeviceIdentifier: String,
        now: Date,
        leaseDuration: TimeInterval,
        completionMarker: String?
    ) async throws -> CrossDeviceWorkClaim {
        let token = CrossDeviceWorkLeaseToken(
            workKey: key.identifier,
            ownerDeviceIdentifier: ownerDeviceIdentifier,
            acquiredAt: now,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            scope: .accountShared
        )
        let context = ModelContext(modelContainer)
        let workKey = key.identifier
        var descriptor = FetchDescriptor<CrossDeviceWorkLease>(
            predicate: #Predicate { lease in lease.workKey == workKey }
        )
        descriptor.fetchLimit = 1

        if let lease = try context.fetch(descriptor).first {
            if lease.completedAt != nil,
               completionMarker == nil || lease.completionMarker == completionMarker {
                return .skipped(.alreadyCompleted)
            }
            if lease.leaseExpiresAt > now {
                return .skipped(.leaseHeld)
            }

            lease.ownerDeviceIdentifier = ownerDeviceIdentifier
            lease.acquiredAt = now
            lease.leaseExpiresAt = token.leaseExpiresAt
            lease.lastUpdatedAt = now
            lease.algorithmVersion = key.version
            lease.completedAt = nil
            lease.completionMarker = nil
        } else {
            context.insert(
                CrossDeviceWorkLease(
                    workKey: key.identifier,
                    scope: .accountShared,
                    ownerDeviceIdentifier: ownerDeviceIdentifier,
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
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> Bool {
        let context = ModelContext(modelContainer)
        guard let lease = try fetch(token.workKey, in: context),
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
        completionMarker: String?,
        now: Date
    ) async throws {
        let context = ModelContext(modelContainer)
        guard let lease = try fetch(token.workKey, in: context),
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

    private func fetch(
        _ workKey: String,
        in context: ModelContext
    ) throws -> CrossDeviceWorkLease? {
        var descriptor = FetchDescriptor<CrossDeviceWorkLease>(
            predicate: #Predicate { lease in lease.workKey == workKey }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

private struct CloudKitCrossDeviceWorkLeaseStore: CrossDeviceWorkLeaseStore {
    private static let maxConflictRetries = 4
    private let database: CKDatabase

    init(container: CKContainer = CKContainer(identifier: MovesTimelineStore.cloudKitContainerIdentifier)) {
        database = container.privateCloudDatabase
    }

    func acquire(
        key: BackgroundWorkKey,
        ownerDeviceIdentifier: String,
        now: Date,
        leaseDuration: TimeInterval,
        completionMarker: String?
    ) async throws -> CrossDeviceWorkClaim {
        let token = CrossDeviceWorkLeaseToken(
            workKey: key.identifier,
            ownerDeviceIdentifier: ownerDeviceIdentifier,
            acquiredAt: now,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            scope: .accountShared
        )
        let recordID = Self.recordID(for: key.identifier)

        for _ in 0..<Self.maxConflictRetries {
            do {
                let record = try await database.record(for: recordID)
                if record["completedAt"] as? Date != nil,
                   completionMarker == nil || record["completionMarker"] as? String == completionMarker {
                    return .skipped(.alreadyCompleted)
                }
                if let expires = record["leaseExpiresAt"] as? Date, expires > now {
                    return .skipped(.leaseHeld)
                }

                Self.populate(
                    record,
                    key: key,
                    ownerDeviceIdentifier: ownerDeviceIdentifier,
                    acquiredAt: now,
                    leaseExpiresAt: token.leaseExpiresAt,
                    completedAt: nil,
                    completionMarker: nil
                )
                do {
                    _ = try await database.save(record)
                    return .acquired(token)
                } catch let error as CKError where error.code == .serverRecordChanged {
                    continue
                }
            } catch let error as CKError where error.code == .unknownItem {
                let record = CKRecord(
                    recordType: MovesTimelineStore.distributedLeaseRecordType,
                    recordID: recordID
                )
                Self.populate(
                    record,
                    key: key,
                    ownerDeviceIdentifier: ownerDeviceIdentifier,
                    acquiredAt: now,
                    leaseExpiresAt: token.leaseExpiresAt,
                    completedAt: nil,
                    completionMarker: nil
                )
                do {
                    _ = try await database.save(record)
                    return .acquired(token)
                } catch let saveError as CKError where saveError.code == .serverRecordChanged {
                    continue
                }
            }
        }

        throw CKError(.serverRecordChanged)
    }

    func renew(
        _ token: CrossDeviceWorkLeaseToken,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> Bool {
        let recordID = Self.recordID(for: token.workKey)
        do {
            let record = try await database.record(for: recordID)
            guard record["ownerDeviceIdentifier"] as? String == token.ownerDeviceIdentifier,
                  record["acquiredAt"] as? Date == token.acquiredAt,
                  record["completedAt"] == nil else { return false }
            record["leaseExpiresAt"] = now.addingTimeInterval(leaseDuration) as CKRecordValue
            record["lastUpdatedAt"] = now as CKRecordValue
            _ = try await database.save(record)
            return true
        } catch let error as CKError where error.code == .unknownItem || error.code == .serverRecordChanged {
            return false
        }
    }

    func finish(
        _ token: CrossDeviceWorkLeaseToken,
        completed: Bool,
        completionMarker: String?,
        now: Date
    ) async throws {
        let recordID = Self.recordID(for: token.workKey)
        do {
            let record = try await database.record(for: recordID)
            guard record["ownerDeviceIdentifier"] as? String == token.ownerDeviceIdentifier,
                  record["acquiredAt"] as? Date == token.acquiredAt else { return }
            record["leaseExpiresAt"] = now as CKRecordValue
            record["lastUpdatedAt"] = now as CKRecordValue
            record["completedAt"] = completed ? now as CKRecordValue : nil
            record["completionMarker"] = completed ? completionMarker as CKRecordValue? : nil
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .serverRecordChanged {
            return
        }
    }

    private static func recordID(for workKey: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(workKey.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: name)
    }

    private static func populate(
        _ record: CKRecord,
        key: BackgroundWorkKey,
        ownerDeviceIdentifier: String,
        acquiredAt: Date,
        leaseExpiresAt: Date,
        completedAt: Date?,
        completionMarker: String?
    ) {
        record["workKey"] = key.identifier as CKRecordValue
        record["scopeRawValue"] = BackgroundWorkScope.accountShared.rawValue as CKRecordValue
        record["ownerDeviceIdentifier"] = ownerDeviceIdentifier as CKRecordValue
        record["acquiredAt"] = acquiredAt as CKRecordValue
        record["leaseExpiresAt"] = leaseExpiresAt as CKRecordValue
        record["lastUpdatedAt"] = acquiredAt as CKRecordValue
        record["algorithmVersion"] = key.version as CKRecordValue
        record["completedAt"] = completedAt as CKRecordValue?
        record["completionMarker"] = completionMarker as CKRecordValue?
    }
}
