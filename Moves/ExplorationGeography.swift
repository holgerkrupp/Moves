import CoreLocation
import Foundation

private final class ExplorationResourceBundleAnchor: NSObject {}

private func explorationResourceURL(
    named name: String,
    bundle: Bundle
) -> URL? {
    var bundles = [bundle, Bundle(for: ExplorationResourceBundleAnchor.self)]
    bundles.append(contentsOf: Bundle.allBundles)
    bundles.append(contentsOf: Bundle.allFrameworks)
    for candidate in bundles {
        if let url = candidate.url(forResource: name, withExtension: "json") {
            return url
        }
    }
    return nil
}

struct ExplorationCountry: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

enum ExplorationGeographyError: Error, Equatable {
    case missingDataset
    case invalidDataset
}

/// Offline country resolver backed by the vendored Natural Earth admin-0
/// dataset. Country assignment is separate from the Fog raster identity.
struct ExplorationCountryResolver: Sendable {
    let datasetVersion: Int
    let datasetSource: String
    private let countries: [BoundaryCountry]
    private let bucketIndex: [Int: [Int]]

    var availableCountries: [ExplorationCountry] {
        countries
            .map { ExplorationCountry(id: $0.id, name: $0.name) }
            .sorted { $0.id < $1.id }
    }

    /// Returns outer rings for debug/presentation maps. These coordinates are
    /// derived from the boundary dataset; canonical Fog cells remain the
    /// authoritative exploration representation.
    func boundaryRings(for countryID: String) -> [[CLLocationCoordinate2D]] {
        countries
            .filter { $0.id == countryID }
            .flatMap { country in
                country.polygons.compactMap { polygon in
                    guard let outer = polygon.first else { return nil }
                    return outer.compactMap { point in
                        guard point.count >= 2 else { return nil }
                        return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
                    }
                }
            }
    }

    init(data: Data) throws {
        let decoded = try JSONDecoder().decode(BoundaryDataset.self, from: data)
        guard decoded.version == 1, !decoded.countries.isEmpty else { throw ExplorationGeographyError.invalidDataset }
        datasetVersion = decoded.version
        datasetSource = decoded.source
        countries = decoded.countries.map(BoundaryCountry.init)
        var index = [Int: [Int]]()
        for (countryIndex, country) in countries.enumerated() {
            let minLongitudeBucket = Self.bucketCoordinate(country.minLongitude, offset: 180, width: 10, count: 36)
            let maxLongitudeBucket = Self.bucketCoordinate(country.maxLongitude, offset: 180, width: 10, count: 36)
            let minLatitudeBucket = Self.bucketCoordinate(country.minLatitude, offset: 90, width: 10, count: 18)
            let maxLatitudeBucket = Self.bucketCoordinate(country.maxLatitude, offset: 90, width: 10, count: 18)
            for latitudeBucket in minLatitudeBucket...maxLatitudeBucket {
                for longitudeBucket in minLongitudeBucket...maxLongitudeBucket {
                    index[Self.bucketKey(longitude: longitudeBucket, latitude: latitudeBucket), default: []].append(countryIndex)
                }
            }
        }
        bucketIndex = index
    }

    static func bundled(bundle: Bundle = .main) throws -> Self {
        guard let url = explorationResourceURL(named: "ExplorationCountryBoundaries", bundle: bundle) else {
            throw ExplorationGeographyError.missingDataset
        }
        return try Self(data: Data(contentsOf: url))
    }

    func country(at coordinate: CLLocationCoordinate2D) -> ExplorationCountry? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        let longitude = FogRasterV1.normalizedLongitude(coordinate.longitude)
        let longitudeBucket = Self.bucketCoordinate(longitude, offset: 180, width: 10, count: 36)
        let latitudeBucket = Self.bucketCoordinate(coordinate.latitude, offset: 90, width: 10, count: 18)
        let candidateIndexes = bucketIndex[Self.bucketKey(longitude: longitudeBucket, latitude: latitudeBucket)] ?? []
        let candidates = candidateIndexes.compactMap { countries[$0] }
            .filter { $0.contains(longitude: longitude, latitude: coordinate.latitude) }
        guard let country = candidates.sorted(by: { $0.id < $1.id }).first else { return nil }
        return ExplorationCountry(id: country.id, name: country.name)
    }

    /// Assigns a canonical cell to the country with the largest covered area.
    /// The clipping happens in the same Web-Mercator coordinate space as the
    /// raster, so border cells do not depend on an arbitrary sample grid.
    func country(for cell: FogCell, sampleGrid: Int = 5) throws -> ExplorationCountry? {
        let bounds = try FogRasterV1.geographicBounds(for: cell)
        let candidates = candidateCountries(for: bounds)
        let covered = candidates.compactMap { country -> (ExplorationCountry, Double)? in
            let area = country.coveredArea(in: bounds)
            guard area > 0 else { return nil }
            return (ExplorationCountry(id: country.id, name: country.name), area)
        }
        if let best = covered.sorted(by: { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }).first {
            return best.0
        }
        // Keep the previous deterministic fallback for datasets containing a
        // deliberately incomplete coastline or a disputed sentinel polygon.
        return sampleCountry(in: bounds, grid: max(1, sampleGrid))
    }

    private static func bucketCoordinate(_ value: Double, offset: Double, width: Double, count: Int) -> Int {
        min(max(Int(floor((value + offset) / width)), 0), count - 1)
    }

    private static func bucketKey(longitude: Int, latitude: Int) -> Int {
        latitude * 36 + longitude
    }

    private func candidateCountries(for bounds: FogCellGeographicBounds) -> [BoundaryCountry] {
        let minLongitude = Self.bucketCoordinate(bounds.west, offset: 180, width: 10, count: 36)
        let maxLongitude = Self.bucketCoordinate(bounds.east, offset: 180, width: 10, count: 36)
        let minLatitude = Self.bucketCoordinate(bounds.south, offset: 90, width: 10, count: 18)
        let maxLatitude = Self.bucketCoordinate(bounds.north, offset: 90, width: 10, count: 18)
        let indexes = Set((minLatitude...maxLatitude).flatMap { latitude in
            (minLongitude...maxLongitude).flatMap { longitude in
                bucketIndex[Self.bucketKey(longitude: longitude, latitude: latitude)] ?? []
            }
        })
        return indexes.compactMap { countries[$0] }
    }

    private func sampleCountry(in bounds: FogCellGeographicBounds, grid: Int) -> ExplorationCountry? {
        var counts = [String: (country: ExplorationCountry, count: Int)]()
        for row in 0..<grid {
            for column in 0..<grid {
                let latitude = bounds.south + (bounds.north - bounds.south) * (Double(row) + 0.5) / Double(grid)
                let longitude = bounds.west + (bounds.east - bounds.west) * (Double(column) + 0.5) / Double(grid)
                guard let country = country(at: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else { continue }
                counts[country.id, default: (country, 0)].count += 1
            }
        }
        return counts.values.sorted {
            $0.count == $1.count ? $0.country.id < $1.country.id : $0.count > $1.count
        }.first?.country
    }

    func aggregate(cells: [FogCell], sampleGrid: Int = 5) throws -> [ExplorationCountry: Int] {
        var result = [ExplorationCountry: Int]()
        for cell in cells {
            try Task.checkCancellation()
            if let country = try country(for: cell, sampleGrid: sampleGrid) {
                result[country, default: 0] += 1
            }
        }
        return result
    }

    private struct BoundaryDataset: Decodable {
        let version: Int
        let source: String
        let countries: [BoundaryRecord]
    }

    private struct BoundaryRecord: Decodable {
        let id: String
        let name: String
        let polygons: [[[[Double]]]]
    }

    private struct BoundaryCountry: Sendable {
        let id: String
        let name: String
        let polygons: [[[[Double]]]]
        let minLongitude: Double
        let maxLongitude: Double
        let minLatitude: Double
        let maxLatitude: Double

        init(_ record: BoundaryRecord) {
            // Natural Earth's `-99` sentinel is used for a small number of
            // disputed/special polygons and, in some releases, for France
            // and Norway. Keep the source geometry but normalize the common
            // country identifiers at the resolver boundary.
            id = Self.canonicalID(for: record.name, fallback: record.id)
            name = record.name
            polygons = record.polygons
            let points = record.polygons.flatMap { $0 }.flatMap { $0 }
            minLongitude = points.map { $0[0] }.min() ?? -180
            maxLongitude = points.map { $0[0] }.max() ?? 180
            minLatitude = points.map { $0[1] }.min() ?? -90
            maxLatitude = points.map { $0[1] }.max() ?? 90
        }

        func contains(longitude: Double, latitude: Double) -> Bool {
            guard latitude >= minLatitude, latitude <= maxLatitude,
                  longitude >= minLongitude, longitude <= maxLongitude else { return false }
            return polygons.contains { polygon in
                guard let outer = polygon.first, pointInRing(longitude: longitude, latitude: latitude, ring: outer) else { return false }
                return !polygon.dropFirst().contains { pointInRing(longitude: longitude, latitude: latitude, ring: $0) }
            }
        }

        func coveredArea(in bounds: FogCellGeographicBounds) -> Double {
            guard bounds.north >= minLatitude, bounds.south <= maxLatitude,
                  bounds.east >= minLongitude, bounds.west <= maxLongitude else { return 0 }
            return polygons.reduce(0) { total, polygon in
                guard let outer = polygon.first else { return total }
                let outerArea = projectedClippedRingArea(outer, in: bounds)
                let holeArea = polygon.dropFirst().reduce(0) { $0 + projectedClippedRingArea($1, in: bounds) }
                return total + max(0, outerArea - holeArea)
            }
        }

        private static func canonicalID(for name: String, fallback: String) -> String {
            switch name {
            case "France": return "FR"
            case "Norway": return "NO"
            case "Kosovo": return "XK"
            case "Northern Cyprus": return "XC"
            case "Dhekelia Sovereign Base Area", "Akrotiri Sovereign Base Area": return "CY"
            default: return fallback
            }
        }
    }
}

private func pointInRing(longitude: Double, latitude: Double, ring: [[Double]]) -> Bool {
    guard ring.count >= 3 else { return false }
    var inside = false
    var previous = ring[ring.count - 1]
    for current in ring {
        let intersects = ((current[1] > latitude) != (previous[1] > latitude))
            && longitude < (previous[0] - current[0]) * (latitude - current[1]) / (previous[1] - current[1]) + current[0]
        if intersects { inside.toggle() }
        previous = current
    }
    return inside
}

struct ExplorationAdministrativeRegion: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let countryID: String
    let name: String
}

/// Offline first-level administrative resolver. It uses the same deterministic
/// cell sampling policy as country attribution and remains independent from the
/// canonical raster identity.
struct ExplorationAdministrativeRegionResolver: Sendable {
    private let regions: [BoundaryRegion]
    private let bucketIndex: [Int: [Int]]

    init(data: Data) throws {
        let decoded = try JSONDecoder().decode(BoundaryDataset.self, from: data)
        guard decoded.version == 1, !decoded.regions.isEmpty else { throw ExplorationGeographyError.invalidDataset }
        regions = decoded.regions.map(BoundaryRegion.init)
        var index = [Int: [Int]]()
        for (regionIndex, region) in regions.enumerated() {
            let minLon = Self.bucketCoordinate(region.minLongitude, offset: 180, width: 10, count: 36)
            let maxLon = Self.bucketCoordinate(region.maxLongitude, offset: 180, width: 10, count: 36)
            let minLat = Self.bucketCoordinate(region.minLatitude, offset: 90, width: 10, count: 18)
            let maxLat = Self.bucketCoordinate(region.maxLatitude, offset: 90, width: 10, count: 18)
            for latitude in minLat...maxLat {
                for longitude in minLon...maxLon {
                    index[Self.bucketKey(longitude: longitude, latitude: latitude), default: []].append(regionIndex)
                }
            }
        }
        bucketIndex = index
    }

    static func bundled(bundle: Bundle = .main) throws -> Self {
        guard let url = explorationResourceURL(named: "ExplorationAdministrativeBoundaries", bundle: bundle) else {
            throw ExplorationGeographyError.missingDataset
        }
        return try Self(data: Data(contentsOf: url))
    }

    var availableRegions: [ExplorationAdministrativeRegion] {
        regions.map { ExplorationAdministrativeRegion(id: $0.id, countryID: $0.countryID, name: $0.name) }
            .sorted { $0.id < $1.id }
    }

    func region(at coordinate: CLLocationCoordinate2D) -> ExplorationAdministrativeRegion? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        let longitude = FogRasterV1.normalizedLongitude(coordinate.longitude)
        let key = Self.bucketKey(
            longitude: Self.bucketCoordinate(longitude, offset: 180, width: 10, count: 36),
            latitude: Self.bucketCoordinate(coordinate.latitude, offset: 90, width: 10, count: 18)
        )
        let candidates = (bucketIndex[key] ?? []).compactMap { regions[$0] }
            .filter { $0.contains(longitude: longitude, latitude: coordinate.latitude) }
            .sorted { $0.id < $1.id }
        guard let region = candidates.first else { return nil }
        return ExplorationAdministrativeRegion(id: region.id, countryID: region.countryID, name: region.name)
    }

    func region(for cell: FogCell, sampleGrid: Int = 5) throws -> ExplorationAdministrativeRegion? {
        let bounds = try FogRasterV1.geographicBounds(for: cell)
        let minLongitude = Self.bucketCoordinate(bounds.west, offset: 180, width: 10, count: 36)
        let maxLongitude = Self.bucketCoordinate(bounds.east, offset: 180, width: 10, count: 36)
        let minLatitude = Self.bucketCoordinate(bounds.south, offset: 90, width: 10, count: 18)
        let maxLatitude = Self.bucketCoordinate(bounds.north, offset: 90, width: 10, count: 18)
        let indexes = Set((minLatitude...maxLatitude).flatMap { latitude in
            (minLongitude...maxLongitude).flatMap { longitude in
                bucketIndex[Self.bucketKey(longitude: longitude, latitude: latitude)] ?? []
            }
        })
        let covered = indexes.compactMap { index -> (ExplorationAdministrativeRegion, Double)? in
            let region = regions[index]
            let area = region.coveredArea(in: bounds)
            guard area > 0 else { return nil }
            return (ExplorationAdministrativeRegion(id: region.id, countryID: region.countryID, name: region.name), area)
        }
        if let best = covered.sorted(by: { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }).first {
            return best.0
        }
        var counts = [String: (region: ExplorationAdministrativeRegion, count: Int)]()
        let grid = max(1, sampleGrid)
        for row in 0..<grid {
            for column in 0..<grid {
                let latitude = bounds.south + (bounds.north - bounds.south) * (Double(row) + 0.5) / Double(grid)
                let longitude = bounds.west + (bounds.east - bounds.west) * (Double(column) + 0.5) / Double(grid)
                guard let region = region(at: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else { continue }
                counts[region.id, default: (region, 0)].count += 1
            }
        }
        return counts.values.sorted {
            $0.count == $1.count ? $0.region.id < $1.region.id : $0.count > $1.count
        }.first?.region
    }

    private struct BoundaryDataset: Decodable {
        let version: Int
        let source: String
        let regions: [BoundaryRecord]
    }

    private struct BoundaryRecord: Decodable {
        let id: String
        let countryID: String
        let name: String
        let polygons: [[[[Double]]]]
    }

    private struct BoundaryRegion: Sendable {
        let id: String
        let countryID: String
        let name: String
        let polygons: [[[[Double]]]]
        let minLongitude: Double
        let maxLongitude: Double
        let minLatitude: Double
        let maxLatitude: Double

        init(_ record: BoundaryRecord) {
            id = record.id
            countryID = record.countryID
            name = record.name
            polygons = record.polygons
            let points = record.polygons.flatMap { $0 }.flatMap { $0 }
            minLongitude = points.map { $0[0] }.min() ?? -180
            maxLongitude = points.map { $0[0] }.max() ?? 180
            minLatitude = points.map { $0[1] }.min() ?? -90
            maxLatitude = points.map { $0[1] }.max() ?? 90
        }

        func contains(longitude: Double, latitude: Double) -> Bool {
            guard latitude >= minLatitude, latitude <= maxLatitude,
                  longitude >= minLongitude, longitude <= maxLongitude else { return false }
            return polygons.contains { polygon in
                guard let outer = polygon.first, pointInRing(longitude: longitude, latitude: latitude, ring: outer) else { return false }
                return !polygon.dropFirst().contains { pointInRing(longitude: longitude, latitude: latitude, ring: $0) }
            }
        }

        func coveredArea(in bounds: FogCellGeographicBounds) -> Double {
            guard bounds.north >= minLatitude, bounds.south <= maxLatitude,
                  bounds.east >= minLongitude, bounds.west <= maxLongitude else { return 0 }
            return polygons.reduce(0) { total, polygon in
                guard let outer = polygon.first else { return total }
                let outerArea = projectedClippedRingArea(outer, in: bounds)
                let holeArea = polygon.dropFirst().reduce(0) { $0 + projectedClippedRingArea($1, in: bounds) }
                return total + max(0, outerArea - holeArea)
            }
        }
    }

    private static func bucketCoordinate(_ value: Double, offset: Double, width: Double, count: Int) -> Int {
        min(max(Int(floor((value + offset) / width)), 0), count - 1)
    }

    private static func bucketKey(longitude: Int, latitude: Int) -> Int { latitude * 36 + longitude }
}

private struct ExplorationProjectedPoint {
    var x: Double
    var y: Double
}

private func projectedClippedRingArea(_ ring: [[Double]], in bounds: FogCellGeographicBounds) -> Double {
    guard ring.count >= 3 else { return 0 }
    let centerLongitude = (bounds.west + bounds.east) / 2
    let southY = mercatorY(bounds.south)
    let northY = mercatorY(bounds.north)
    var polygon = ring.compactMap { point -> ExplorationProjectedPoint? in
        guard point.count >= 2, point[0].isFinite, point[1].isFinite else { return nil }
        var longitude = FogRasterV1.normalizedLongitude(point[0])
        while longitude - centerLongitude > 180 { longitude -= 360 }
        while longitude - centerLongitude < -180 { longitude += 360 }
        return ExplorationProjectedPoint(x: longitude, y: mercatorY(point[1]))
    }
    guard polygon.count >= 3 else { return 0 }
    polygon = clip(polygon, edge: { $0.x >= bounds.west }, intersection: { intersection($0, $1, axis: .x, value: bounds.west) })
    polygon = clip(polygon, edge: { $0.x <= bounds.east }, intersection: { intersection($0, $1, axis: .x, value: bounds.east) })
    polygon = clip(polygon, edge: { $0.y >= southY }, intersection: { intersection($0, $1, axis: .y, value: southY) })
    polygon = clip(polygon, edge: { $0.y <= northY }, intersection: { intersection($0, $1, axis: .y, value: northY) })
    guard polygon.count >= 3 else { return 0 }
    var area = 0.0
    for index in polygon.indices {
        let next = polygon[(index + 1) % polygon.count]
        area += polygon[index].x * next.y - next.x * polygon[index].y
    }
    return abs(area) / 2
}

private enum ProjectionAxis { case x, y }

private func clip(
    _ polygon: [ExplorationProjectedPoint],
    edge: (ExplorationProjectedPoint) -> Bool,
    intersection: (ExplorationProjectedPoint, ExplorationProjectedPoint) -> ExplorationProjectedPoint
) -> [ExplorationProjectedPoint] {
    guard let first = polygon.last else { return [] }
    var result = [ExplorationProjectedPoint]()
    var previous = first
    var previousInside = edge(previous)
    for current in polygon {
        let currentInside = edge(current)
        if currentInside != previousInside {
            result.append(intersection(previous, current))
        }
        if currentInside { result.append(current) }
        previous = current
        previousInside = currentInside
    }
    return result
}

private func intersection(
    _ first: ExplorationProjectedPoint,
    _ second: ExplorationProjectedPoint,
    axis: ProjectionAxis,
    value: Double
) -> ExplorationProjectedPoint {
    let denominator = axis == .x ? second.x - first.x : second.y - first.y
    guard abs(denominator) > .ulpOfOne else { return first }
    let fraction = (value - (axis == .x ? first.x : first.y)) / denominator
    return ExplorationProjectedPoint(
        x: first.x + (second.x - first.x) * fraction,
        y: first.y + (second.y - first.y) * fraction
    )
}

private func mercatorY(_ latitude: Double) -> Double {
    let clamped = min(max(latitude, -FogRasterV1.webMercatorMaximumLatitude), FogRasterV1.webMercatorMaximumLatitude)
    return log(tan(.pi / 4 + clamped * .pi / 360))
}
