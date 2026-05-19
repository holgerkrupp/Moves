import Foundation
import WidgetKit
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

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

struct TimelineWidgetRoutePoint: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

#if canImport(CoreLocation)
    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
#endif
}

struct TimelineWidgetSnapshot: Codable, Hashable {
    let generatedAt: Date
    let dayKey: String
    let dayTitle: String
    let totalDistanceMeters: Double
    let visitedLocationCount: Int
    let moveCount: Int
    let transportMetrics: [TimelineWidgetTransportMetric]
    let routePoints: [TimelineWidgetRoutePoint]

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
        ],
        routePoints: []
    )

    var primaryTransportMetric: TimelineWidgetTransportMetric? {
        transportMetrics.max { $0.distanceMeters < $1.distanceMeters }
    }
}

enum TimelineWidgetSnapshotStore {
    private static let encoder = JSONEncoder()
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

    static func save(_ snapshot: TimelineWidgetSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        MovesWidgetSharedStore.userDefaults.set(data, forKey: MovesWidgetSharedStore.snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()

        #if os(iOS)
        TimelineWidgetSnapshotPhoneRelay.sendToWatch(data)
        #endif
    }
}

#if os(iOS)
enum TimelineWidgetSnapshotPhoneRelay {
    static func sendToWatch(_ data: Data) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated else { return }

        try? session.updateApplicationContext([
            MovesWidgetSharedStore.snapshotKey: data
        ])
    }
}
#endif

extension TimelineWidgetSnapshot {
    static func make(from dayTimeline: DayTimeline) -> TimelineWidgetSnapshot {
        var distanceByMode: [TransportMode: Double] = [:]

        for move in dayTimeline.moves {
            let aggregatedMode = aggregatedDisplayMode(for: move.transportMode)
            distanceByMode[aggregatedMode, default: 0] += max(move.distanceMeters, 0)
        }

        let metrics = distanceByMode
            .map { mode, distance in
                TimelineWidgetTransportMetric(
                    id: mode.rawValue,
                    title: mode.title,
                    symbolName: mode.symbolName,
                    colorAssetName: MovesPalette.transportColorAssetName(for: mode),
                    distanceMeters: distance
                )
            }
            .sorted {
                if $0.distanceMeters != $1.distanceMeters {
                    return $0.distanceMeters > $1.distanceMeters
                }
                return $0.title < $1.title
            }

        let totalDistance = metrics.reduce(0) { $0 + $1.distanceMeters }
        let routePoints = compressedRoutePoints(for: dayTimeline, limit: 320)

        return TimelineWidgetSnapshot(
            generatedAt: .now,
            dayKey: dayTimeline.dayKey,
            dayTitle: dayTimeline.dayStart.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
            totalDistanceMeters: totalDistance,
            visitedLocationCount: dayTimeline.uniqueLocationCount,
            moveCount: dayTimeline.moves.count,
            transportMetrics: metrics,
            routePoints: routePoints
        )
    }

    private static func aggregatedDisplayMode(for mode: TransportMode) -> TransportMode {
        switch mode {
        case .walking, .running:
            return .walking
        default:
            return mode
        }
    }

    private static func compressedRoutePoints(
        for dayTimeline: DayTimeline,
        limit: Int
    ) -> [TimelineWidgetRoutePoint] {
        let rawCoordinates: [CLLocationCoordinate2D] = dayTimeline.moves
            .sorted { $0.startDate < $1.startDate }
            .flatMap { move in
                let fallback = MoveRouteGeometry.rawCoordinates(for: move)
                let signature = MoveRouteGeometry.cacheSignature(for: move, fallback: fallback)
                return move.cachedRouteCoordinates(for: signature) ?? fallback
            }

        guard !rawCoordinates.isEmpty else { return [] }
        let stride = max(rawCoordinates.count / max(limit, 1), 1)
        let sampled = rawCoordinates.enumerated().compactMap { index, coordinate in
            index.isMultiple(of: stride) ? coordinate : nil
        }
        return sampled.map(TimelineWidgetRoutePoint.init)
    }
}
