import Foundation

/// Geographic value used at the boundary between canonical Exploration data
/// and a presentation projection. It deliberately avoids persisting MapKit
/// types in shards, caches, or derived statistics.
struct ExplorationGeographicCoordinate: Codable, Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

struct ExplorationProjectionPoint: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double
}

protocol ExplorationMapProjection: Sendable {
    func project(_ coordinate: ExplorationGeographicCoordinate) -> ExplorationProjectionPoint
    func unproject(_ point: ExplorationProjectionPoint) -> ExplorationGeographicCoordinate
}

/// Web Mercator used by the current MapKit presentation adapter. This is a
/// presentation conversion only; it never changes canonical Fog cell identity.
struct ExplorationWebMercatorProjection: ExplorationMapProjection {
    static let maximumLatitude = 85.0511287798066

    func project(_ coordinate: ExplorationGeographicCoordinate) -> ExplorationProjectionPoint {
        let longitude = FogRasterV1.normalizedLongitude(coordinate.longitude)
        let latitude = min(max(coordinate.latitude, -Self.maximumLatitude), Self.maximumLatitude)
        let radians = latitude * .pi / 180
        return ExplorationProjectionPoint(
            x: (longitude + 180) / 360,
            y: (1 - asinh(tan(radians)) / .pi) / 2
        )
    }

    func unproject(_ point: ExplorationProjectionPoint) -> ExplorationGeographicCoordinate {
        let x = point.x - floor(point.x)
        let y = min(max(point.y, 0), 1)
        let longitude = x * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
        return ExplorationGeographicCoordinate(latitude: latitude, longitude: longitude)
    }
}
