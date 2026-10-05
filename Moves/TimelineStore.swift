import SwiftData
import Foundation

enum MovesStoreFailureDisposition: String, Codable, Sendable {
    case retryable
    case persistent
    case unknown
}

enum MovesStoreOpenMode: String, Codable, Sendable {
    case cloudKit
    case localFallback
    case unknown

    var title: String {
        switch self {
        case .cloudKit: return "CloudKit"
        case .localFallback: return "Local fallback"
        case .unknown: return "Unknown"
        }
    }
}

struct MovesStoreOpenFailure: Codable, Equatable, Sendable {
    let message: String
    let domain: String?
    let code: Int?
    let disposition: MovesStoreFailureDisposition
    let attemptedMode: MovesStoreOpenMode
    let occurredAt: Date

    init(
        message: String,
        domain: String?,
        code: Int?,
        disposition: MovesStoreFailureDisposition,
        attemptedMode: MovesStoreOpenMode,
        occurredAt: Date
    ) {
        self.message = message
        self.domain = domain
        self.code = code
        self.disposition = disposition
        self.attemptedMode = attemptedMode
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case message, domain, code, disposition, attemptedMode, occurredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        disposition = try container.decode(MovesStoreFailureDisposition.self, forKey: .disposition)
        attemptedMode = try container.decodeIfPresent(MovesStoreOpenMode.self, forKey: .attemptedMode) ?? .unknown
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
    }
}

enum MovesStoreRecovery {
    private static let failureKey = "Moves.storeOpenFailure.v1"

    static var lastFailure: MovesStoreOpenFailure? {
        guard let data = UserDefaults.standard.data(forKey: failureKey) else { return nil }
        return try? JSONDecoder().decode(MovesStoreOpenFailure.self, from: data)
    }

    static func record(
        _ error: Error,
        attemptedMode: MovesStoreOpenMode = .unknown,
        at date: Date = .now
    ) -> MovesStoreOpenFailure {
        let nsError = error as NSError
        let failure = MovesStoreOpenFailure(
            message: privacySafeMessage(error.localizedDescription),
            domain: privacySafeDomain(nsError.domain),
            code: nsError.code == 0 ? nil : nsError.code,
            disposition: classify(error),
            attemptedMode: attemptedMode,
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

    static func diagnosticsReport(
        for failure: MovesStoreOpenFailure,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        buildVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String {
        [
            "Moves store-open diagnostics",
            "App: \(appVersion ?? "Unknown") (\(buildVersion ?? "Unknown"))",
            "OS: \(operatingSystem)",
            "Attempted mode: \(failure.attemptedMode.title)",
            "Disposition: \(failure.disposition.rawValue)",
            "Error: \(failure.message)",
            "Domain/code: \(failure.domain ?? "unknown") / \(failure.code.map(String.init) ?? "unknown")",
            "Occurred: \(failure.occurredAt.ISO8601Format())",
            "No coordinates, route points, account identifiers, tokens, location names, or store paths are included."
        ].joined(separator: "\n")
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

    static func privacySafeMessage(_ message: String) -> String {
        var result = message
        let patterns = [
            #"https?://[^\s]+"#,
            #"file://[^\s]+"#,
            #"/(?:Users|private|var|tmp)/[^\n]+"#,
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"(?i)\b(?:account|user(?:name)?|apple[_ -]?id)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)\b(?:access[_-]?token|auth(?:orization)?|password|secret)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)\b(?:lat(?:itude)?|lon(?:gitude)?|coordinate)\s*[:=]\s*[-+]?\d+(?:\.\d+)?"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
        return result
    }

    private static func privacySafeDomain(_ domain: String) -> String? {
        guard !domain.isEmpty else { return nil }
        let allowed = domain.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        return allowed ? domain : "redacted"
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
    ]

    static var authoritativeSchema: Schema {
        Schema(authoritativeModelTypes)
    }

    /// The complete schema used by the application container. Cache-only
    /// models belong here so SwiftData can validate every configuration, but
    /// they must stay out of `authoritativeSchema` to avoid syncing them.
    static var applicationSchema: Schema {
        Schema(authoritativeModelTypes + [ShareMapAggregate.self])
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
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase? = nil,
        timelineStoreURL: URL? = nil,
        cacheStoreURL: URL? = nil
    ) throws -> ModelContainer {
        let timelineConfiguration = makeConfiguration(
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: cloudKitDatabase,
            storeURL: timelineStoreURL
        )
        let cacheSchema = Schema([ShareMapAggregate.self])
        let cacheConfiguration: ModelConfiguration
        if let cacheStoreURL {
            cacheConfiguration = ModelConfiguration(
                "ShareMapCache",
                schema: cacheSchema,
                url: cacheStoreURL,
                cloudKitDatabase: .none
            )
        } else {
            cacheConfiguration = ModelConfiguration(
                "ShareMapCache",
                schema: cacheSchema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(
            for: applicationSchema,
            configurations: [timelineConfiguration, cacheConfiguration]
        )
    }
}
