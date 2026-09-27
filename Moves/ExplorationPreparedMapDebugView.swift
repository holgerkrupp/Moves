#if DEBUG
import CoreLocation
import MapKit
import SwiftUI

private struct ExplorationPreparedMapTile: Identifiable, Sendable {
    let id: ExplorationRenderTileID
    let standardCellCount: Int

    var coordinates: [CLLocationCoordinate2D] {
        let scale = Double(1 << Int(id.level))
        let dimension = Double(FogRasterV1.globalCellDimension)
        let minX = Double(id.x) * scale * Double(FogRasterV1.cellsPerBlock)
        let minY = Double(id.y) * scale * Double(FogRasterV1.cellsPerBlock)
        let maxX = minX + scale * Double(FogRasterV1.cellsPerBlock)
        let maxY = minY + scale * Double(FogRasterV1.cellsPerBlock)
        func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: atan(sinh(.pi - 2 * .pi * y / dimension)) * 180 / .pi,
                longitude: x / dimension * 360 - 180
            )
        }
        return [coordinate(x: minX, y: minY), coordinate(x: maxX, y: minY), coordinate(x: maxX, y: maxY), coordinate(x: minX, y: maxY)]
    }
}

struct ExplorationPreparedMapDebugView: View {
    @State private var tiles: [ExplorationPreparedMapTile] = []
    @State private var message: String?
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
        )
    )
    @State private var loadGeneration = UUID()

    var body: some View {
        Group {
            if tiles.isEmpty {
                ContentUnavailableView("No prepared render hierarchy", systemImage: "map", description: Text(message ?? "Rebuild the merged cache from the Preparation tools first."))
            } else {
                Map(position: $position) {
                    ForEach(tiles) { tile in
                        MapPolygon(coordinates: tile.coordinates)
                            .foregroundStyle(.mint.opacity(0.45))
                            .stroke(.mint.opacity(0.75), lineWidth: 0.5)
                    }
                }
                .mapStyle(.standard)
            }
        }
        .navigationTitle("Prepared Hierarchy Map")
        .navigationBarTitleDisplayMode(.inline)
        .onMapCameraChange(frequency: .onEnd) { context in
            let generation = UUID()
            loadGeneration = generation
            Task { await load(region: context.region, generation: generation) }
        }
        .task {
            let generation = UUID()
            loadGeneration = generation
            await load(
                region: MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
                ),
                generation: generation
            )
        }
    }

    private func load(region: MKCoordinateRegion, generation: UUID) async {
        do {
            let hierarchy = ExplorationRenderHierarchy()
            let tileCache = ExplorationRenderTileCache(hierarchy: hierarchy, capacity: 128)
            let level = level(for: region)
            let ids = visibleTileIDs(region: region, level: level, limit: 5_000)
            var loaded: [ExplorationPreparedMapTile] = []
            loaded.reserveCapacity(min(ids.count, 5_000))
            for id in ids {
                guard generation == loadGeneration else { return }
                guard let tile = try await tileCache.read(id) else { continue }
                loaded.append(ExplorationPreparedMapTile(id: id, standardCellCount: tile.standardCellCount))
            }
            guard generation == loadGeneration else { return }
            tiles = loaded
            message = loaded.isEmpty ? "No prepared tiles intersect this viewport." : "Showing \(loaded.count) level \(level) prepared tiles for this viewport."
        } catch {
            message = error.localizedDescription
        }
    }

    private func level(for region: MKCoordinateRegion) -> UInt8 {
        let span = max(region.span.longitudeDelta, region.span.latitudeDelta)
        return switch span {
        case 90...: 10
        case 45..<90: 9
        case 20..<45: 8
        case 10..<20: 7
        case 5..<10: 6
        case 2..<5: 5
        case 1..<2: 4
        case 0.5..<1: 3
        case 0.2..<0.5: 2
        case 0.05..<0.2: 1
        default: 0
        }
    }

    private func visibleTileIDs(
        region: MKCoordinateRegion,
        level: UInt8,
        limit: Int
    ) -> [ExplorationRenderTileID] {
        let dimension = Double(FogRasterV1.globalCellDimension)
        let scale = Double(1 << Int(level)) * Double(FogRasterV1.cellsPerBlock)
        let worldTileCount = Int(ceil(dimension / scale))
        let longitudeSpan = min(max(region.span.longitudeDelta, 0.001), 360)
        let west = region.center.longitude - longitudeSpan / 2
        let east = region.center.longitude + longitudeSpan / 2
        let westX = rasterX(forLongitude: west, dimension: dimension)
        let eastX = rasterX(forLongitude: east, dimension: dimension)
        let minX = Int(floor(min(westX, eastX) / scale))
        let maxX = Int(ceil(max(westX, eastX) / scale))
        let north = min(85.0511287798066, region.center.latitude + region.span.latitudeDelta / 2)
        let south = max(-85.0511287798066, region.center.latitude - region.span.latitudeDelta / 2)
        let northY = rasterY(forLatitude: north, dimension: dimension)
        let southY = rasterY(forLatitude: south, dimension: dimension)
        let minY = Int(floor(min(northY, southY) / scale))
        let maxY = Int(ceil(max(northY, southY) / scale))

        var result = [ExplorationRenderTileID]()
        result.reserveCapacity(min(limit, max(0, maxX - minX) * max(0, maxY - minY)))
        for y in max(0, minY)..<min(worldTileCount, maxY) {
            for x in max(0, minX)..<min(worldTileCount, maxX) {
                result.append(ExplorationRenderTileID(level: level, x: UInt32(x), y: UInt32(y)))
                if result.count == limit { return result }
            }
        }
        return result
    }

    private func rasterX(forLongitude longitude: Double, dimension: Double) -> Double {
        let wrapped = FogRasterV1.normalizedLongitude(longitude)
        return ((wrapped + 180) / 360) * dimension
    }

    private func rasterY(forLatitude latitude: Double, dimension: Double) -> Double {
        let clamped = min(max(latitude, -85.0511287798066), 85.0511287798066)
        let radians = clamped * .pi / 180
        return ((.pi - asinh(tan(radians))) / (2 * .pi)) * dimension
    }
}
#endif
