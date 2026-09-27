import Foundation

struct ExplorationRenderTileID: Codable, Equatable, Hashable, Sendable, Comparable {
    let level: UInt8
    let x: UInt32
    let y: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.level == rhs.level ? (lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y) : lhs.level < rhs.level
    }
}

struct ExplorationRenderTile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let rasterVersion: FogRasterVersion
    let id: ExplorationRenderTileID
    let generatedAt: Date
    let standardCellCount: Int
    let flightCellCount: Int
    let groundCellCount: Int
    let visitCellCount: Int
    let importedFogCellCount: Int
}

/// Device-local, disposable hierarchy used by future map screens. Level zero
/// is one canonical 64x64 block; higher levels aggregate powers of two blocks.
/// It never changes cell identity and is rebuilt from source shards.
actor ExplorationRenderHierarchy {
    static let schemaVersion = 1
    private let rootURL: URL
    private let shardStore: ExplorationShardFileStore

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        self.rootURL = rootURL
        shardStore = ExplorationShardFileStore(rootURL: rootURL)
    }

    func read(_ id: ExplorationRenderTileID) throws -> ExplorationRenderTile? {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExplorationRenderTile.self, from: Data(contentsOf: url))
    }

    func tileIDs(level: UInt8) throws -> [ExplorationRenderTileID] {
        let directory = rootURL.appendingPathComponent("v1/render/level-\(level)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url in
                let values = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                guard values.count == 2, let x = UInt32(values[0]), let y = UInt32(values[1]) else { return nil }
                return ExplorationRenderTileID(level: level, x: x, y: y)
            }
            .sorted()
    }

    func rebuildAll() async throws {
        let shards = try await shardStore.allShards()
        let merged = merge(shards)
        let tiles = aggregate(merged, only: nil)
        try removeAll()
        try write(tiles)
    }

    func rebuild(affectedBlocks: some Sequence<FogBlockID>) async throws {
        let ids = Array(Set(affectedBlocks))
        guard !ids.isEmpty else { return }
        let shards = try await shardStore.allShards()
        let merged = merge(shards)
        let affectedTiles = Set(ids.flatMap { block in
            (0...10).map { level in tileID(for: block, level: level) }
        })
        let tiles = aggregate(merged, only: affectedTiles)
        try write(tiles, replacing: affectedTiles)
    }

    func removeAll() throws {
        let directory = rootURL.appendingPathComponent("v1/render", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func merge(_ shards: [ExplorationShard]) -> [FogBlockID: [ExplorationLayer: FogBitmapBlock]] {
        var result = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()
        for shard in shards {
            for block in shard.blocks {
                for layer in block.layers {
                    if let current = result[block.id]?[layer.layer] {
                        result[block.id]?[layer.layer] = current.union(layer.bitmap)
                    } else {
                        result[block.id, default: [:]][layer.layer] = layer.bitmap
                    }
                }
            }
        }
        return result
    }

    private func aggregate(
        _ blocks: [FogBlockID: [ExplorationLayer: FogBitmapBlock]],
        only requested: Set<ExplorationRenderTileID>?
    ) -> [ExplorationRenderTileID: ExplorationRenderTile] {
        var counts = [ExplorationRenderTileID: [ExplorationLayer: Int]]()
        var standardCounts = [ExplorationRenderTileID: Int]()
        var flightCounts = [ExplorationRenderTileID: Int]()
        for (blockID, layers) in blocks {
            let standardBitmap = layers
                .filter { $0.key != .flight }
                .map(\.value)
                .reduce(try! FogBitmapBlock()) { $0.union($1) }
            let blockStandardCount = standardBitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            let blockFlightCount = layers[.flight]?.bytes.reduce(0) { $0 + $1.nonzeroBitCount } ?? 0
            // Ten levels cover street-scale canonical blocks through a compact
            // world overview (65,536 blocks / 2^10 = 64 tiles per axis).
            for level in 0...10 {
                let id = tileID(for: blockID, level: level)
                guard requested == nil || requested?.contains(id) == true else { continue }
                for (layer, bitmap) in layers {
                    counts[id, default: [:]][layer, default: 0] += bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                }
                standardCounts[id, default: 0] += blockStandardCount
                flightCounts[id, default: 0] += blockFlightCount
            }
        }

        return Dictionary(uniqueKeysWithValues: counts.map { id, layerCounts in
            let ground = layerCounts[.ground, default: 0]
            let visits = layerCounts[.visits, default: 0]
            let imported = layerCounts[.importedFog, default: 0]
            return (id, ExplorationRenderTile(
                schemaVersion: Self.schemaVersion,
                rasterVersion: .fogRasterV1,
                id: id,
                generatedAt: .now,
                standardCellCount: standardCounts[id, default: 0],
                flightCellCount: flightCounts[id, default: 0],
                groundCellCount: ground,
                visitCellCount: visits,
                importedFogCellCount: imported
            ))
        })
    }

    private func tileID(for block: FogBlockID, level: Int) -> ExplorationRenderTileID {
        let scale = UInt32(1 << level)
        return ExplorationRenderTileID(level: UInt8(level), x: block.x / scale, y: block.y / scale)
    }

    private func write(
        _ tiles: [ExplorationRenderTileID: ExplorationRenderTile],
        replacing ids: Set<ExplorationRenderTileID>? = nil
    ) throws {
        let fileManager = FileManager.default
        for id in ids ?? Set(tiles.keys) {
            let url = url(for: id)
            if let tile = tiles[id] {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(tile)
                try data.write(to: url, options: ExplorationFileStorage.atomicWriteOptions)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func url(for id: ExplorationRenderTileID) -> URL {
        rootURL.appendingPathComponent("v1/render/level-\(id.level)/\(id.x)-\(id.y).json")
    }
}

/// Bounded decoded render-tile cache. The on-disk hierarchy remains the
/// disposable source; this actor prevents map presentation from retaining a
/// world-sized decoded tile set while still avoiding repeated file decoding
/// during pan/zoom inspection.
actor ExplorationRenderTileCache {
    private struct Entry {
        let tile: ExplorationRenderTile
        var lastAccess: UInt64
    }

    private let hierarchy: ExplorationRenderHierarchy
    private let capacity: Int
    private var entries: [ExplorationRenderTileID: Entry] = [:]
    private var accessCounter: UInt64 = 0

    init(hierarchy: ExplorationRenderHierarchy = ExplorationRenderHierarchy(), capacity: Int = 128) {
        self.hierarchy = hierarchy
        self.capacity = max(1, capacity)
    }

    func read(_ id: ExplorationRenderTileID) async throws -> ExplorationRenderTile? {
        accessCounter &+= 1
        if var entry = entries[id] {
            entry.lastAccess = accessCounter
            entries[id] = entry
            return entry.tile
        }
        guard let tile = try await hierarchy.read(id) else { return nil }
        entries[id] = Entry(tile: tile, lastAccess: accessCounter)
        evictIfNeeded()
        return tile
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    var count: Int { entries.count }

    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let numberToRemove = entries.count - capacity
        let victims = entries
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
            .prefix(numberToRemove)
            .map(\.key)
        for victim in victims { entries.removeValue(forKey: victim) }
    }
}
