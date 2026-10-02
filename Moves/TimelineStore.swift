import SwiftData

/// The single source of truth for the timeline model shared by iPhone and Mac.
///
/// Keep platform-local caches out of this schema. Adding a model here is a
/// CloudKit schema change and must be compatible with the already deployed
/// private container; this type intentionally does not perform migrations or
/// recreate an existing store.
enum MovesTimelineStore {
    static let cloudKitContainerIdentifier = "iCloud.de.holgerkrupp.Moves"

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

    static func makeConfiguration(
        isStoredInMemoryOnly: Bool = false,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase? = nil
    ) -> ModelConfiguration {
        let database = cloudKitDatabase ?? (isStoredInMemoryOnly ? .none : .private(cloudKitContainerIdentifier))
        return ModelConfiguration(
            schema: authoritativeSchema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: database
        )
    }

    static func makeContainer(
        isStoredInMemoryOnly: Bool = false,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase? = nil,
        additionalConfigurations: [ModelConfiguration] = []
    ) throws -> ModelContainer {
        try ModelContainer(
            for: authoritativeSchema,
            configurations: [
                makeConfiguration(
                    isStoredInMemoryOnly: isStoredInMemoryOnly,
                    cloudKitDatabase: cloudKitDatabase
                )
            ] + additionalConfigurations
        )
    }
}
