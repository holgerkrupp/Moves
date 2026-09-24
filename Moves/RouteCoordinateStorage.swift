import CoreLocation
import Foundation

struct RouteCoordinateStoragePoint: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RouteCoordinateStorage {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> Data? {
        try? encoder.encode(
            RouteCoordinateOps.validCoordinates(coordinates).map(RouteCoordinateStoragePoint.init)
        )
    }

    static func decode(_ data: Data?) -> [CLLocationCoordinate2D] {
        guard let data,
              let payload = try? decoder.decode([RouteCoordinateStoragePoint].self, from: data) else {
            return []
        }
        return RouteCoordinateOps.validCoordinates(payload.map(\.coordinate))
    }
}

extension Notification.Name {
    static let movesLocationSamplesDidChange = Notification.Name("Moves.locationSamplesDidChange")
    static let movesImportedRouteDataDidChange = Notification.Name("Moves.importedRouteDataDidChange")
}
