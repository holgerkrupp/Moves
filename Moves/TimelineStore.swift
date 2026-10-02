import SwiftData
import Foundation

enum MovesStoreFailureDisposition: String, Codable, Sendable {
    case retryable
    case persistent
    case unknown
}

struct MovesStoreOpenFailure: Codable, Equatable, Sendable {
    let message: String
    let domain: String?
    let code: Int?
    let disposition: MovesStoreFailureDisposition
    let occurredAt: Date
}

enum MovesStoreRecovery {
    private static let failureKey = "Moves.storeOpenFailure.v1"

    static var lastFailure: MovesStoreOpenFailure? {
        guard let data = UserDefaults.standard.data(forKey: failureKey) else { return nil }
        return try? JSONDecoder().decode(MovesStoreOpenFailure.self, from: data)
    }

    static func record(_ error: Error, at date: Date = .now) -> MovesStoreOpenFailure {
        let nsError = error as NSError
        let failure = MovesStoreOpenFailure(
            message: privacySafeMessage(error.localizedDescription),
            domain: nsError.domain.isEmpty ? nil : nsError.domain,
            code: nsError.code == 0 ? nil : nsError.code,
            disposition: classify(error),
            occurredAt: date
        )
        if let data = try? JSONEncoder().encode(failure) {
            UserDefaults.standard.set(data, forKey: failureKey)
        }
        return failure
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: failureKey)
    }

    private static func classify(_ error: Error) -> MovesStoreFailureDisposition {
        let nsError = error as NSError
        let urlCode = URLError.Code(rawValue: nsError.code)
        switch urlCode {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            return .retryable
        default:
            break
        }

        let cocoaCode = CocoaError.Code(rawValue: nsError.code)
        switch cocoaCode {
        case .persistentStoreIncompatibleVersionHash,
             .persistentStoreIncompatibleSchema,
             .persistentStoreOpen,
             .migration:
            return .persistent
        default:
            return .unknown
        }
    }

    private static func privacySafeMessage(_ message: String) -> String {
        message.replacingOccurrences(of: #"\b(?:/Users|/private|/var|/tmp)/\S+"#, with: "<redacted>", options: .regularExpression)
    }
}

/// The single source of truth for the timeline model shared by iPhone and Mac.
///
/// Keep platform-local caches out of this schema. Adding a model here is a
/// CloudKit schema change and must be compatible with the already deployed
/// private container; this type intentionally does not perform migrations or
/// recreate an existing store.
enum MovesTimelineStore {
    static let cloudKitContainerIdentifier = "iCloud.de.holgerkrupp.Moves"
    /// Deployed separately from the SwiftData entities because it is used as a
    /// conditional-save lock record, not as timeline data.
    static let distributedLeaseRecordType = "MovesWorkLease"

    static let authoritativeModelTypes: [any PersistentModel.Type] = [
        DayTimeline.self,
        VisitPlace.self,
        KnownLocation.self,
        MoveSegment.self,
        LocationSample.self,
        MovesDeviceProfile.self,
        CrossDeviceWorkLease.self,
    ]

    static var authoritativeSchema: Schema {
        Schema(authoritativeModelTypes)
    }

    static var authoritativeModelTypeNames: [String] {
        authoritativeModelTypes.map { String(reflecting: $0) }.sorted()
    }

    static func makeConfiguration(
        isStoredInMemoryOnly: Bool = false,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase? = nil,
        storeURL: URL? = nil
    ) -> ModelConfiguration {
        let database = cloudKitDatabase ?? (isStoredInMemoryOnly ? .none : .private(cloudKitContainerIdentifier))
        if let storeURL {
            return ModelConfiguration(
                "MovesTimeline",
                schema: authoritativeSchema,
                url: storeURL,
                cloudKitDatabase: database
            )
        }
        return ModelConfiguration(
            schema: authoritativeSchema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: database
        )
    }

    static func makeContainer(
        isStoredInMemoryOnly: Bool = false,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase? = nil,
        storeURL: URL? = nil,
        additionalConfigurations: [ModelConfiguration] = []
    ) throws -> ModelContainer {
        try ModelContainer(
            for: authoritativeSchema,
            configurations: [
                makeConfiguration(
                    isStoredInMemoryOnly: isStoredInMemoryOnly,
                    cloudKitDatabase: cloudKitDatabase,
                    storeURL: storeURL
                )
            ] + additionalConfigurations
        )
    }

    static func makeApplicationContainer(
        isStoredInMemoryOnly: Bool = false,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase? = nil
    ) throws -> ModelContainer {
        let cacheConfiguration = ModelConfiguration(
            "ShareMapCache",
            schema: Schema([ShareMapAggregate.self]),
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: .none
        )
        return try makeContainer(
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: cloudKitDatabase,
            additionalConfigurations: [cacheConfiguration]
        )
    }
}
