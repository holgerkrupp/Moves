import Foundation

enum MovesWidgetSharedStore {
    static let appGroupIdentifier = "group.de.holgerkrupp.Moves"
    static let snapshotKey = "Moves.widgetSnapshot.v1"

    static var userDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

struct TimelineWidgetTransportMetric: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let colorAssetName: String
    let distanceMeters: Double
}

struct TimelineWidgetSnapshot: Codable, Hashable {
    let generatedAt: Date
    let dayKey: String
    let dayTitle: String
    let totalDistanceMeters: Double
    let visitedLocationCount: Int
    let moveCount: Int
    let transportMetrics: [TimelineWidgetTransportMetric]

    static let placeholder = TimelineWidgetSnapshot(
        generatedAt: .now,
        dayKey: "today",
        dayTitle: "Today",
        totalDistanceMeters: 5_240,
        visitedLocationCount: 4,
        moveCount: 6,
        transportMetrics: [
            TimelineWidgetTransportMetric(
                id: "walking",
                title: "On Foot",
                symbolName: "figure.walk",
                colorAssetName: "MovesTransportWalking",
                distanceMeters: 1_120
            ),
            TimelineWidgetTransportMetric(
                id: "cycling",
                title: "Cycling",
                symbolName: "figure.outdoor.cycle",
                colorAssetName: "MovesTransportCycling",
                distanceMeters: 4_120
            )
        ]
    )

    var primaryTransportMetric: TimelineWidgetTransportMetric? {
        transportMetrics.max { $0.distanceMeters < $1.distanceMeters }
    }
}

enum TimelineWidgetSnapshotStore {
    private static let decoder = JSONDecoder()

    static func load() -> TimelineWidgetSnapshot {
        guard let data = MovesWidgetSharedStore.userDefaults.data(
            forKey: MovesWidgetSharedStore.snapshotKey
        ),
              let snapshot = try? decoder.decode(TimelineWidgetSnapshot.self, from: data) else {
            return .placeholder
        }

        return snapshot
    }
}
