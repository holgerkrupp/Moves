import Foundation

extension Notification.Name {
    static let explorationRenderTilesDidUpdate = Notification.Name("Moves.ExplorationRenderTilesDidUpdate")
}

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
    /// Stable content generation used by decoded tile caches to detect replacement.
    let generation: UInt64
    let standardCellCount: Int
    let flightCellCount: Int
    let groundCellCount: Int
    let visitCellCount: Int
    let importedFogCellCount: Int
    /// 64x64 grayscale coverage. Leaf values are 0 or 255 from the canonical
    /// union; parent values are area averaged to preserve sparse route coverage.
    let standardMask: Data
    let flightMask: Data
}

/// Device-local, disposable hierarchy used by the DEBUG map overlay. Level zero
/// is one canonical 64x64 block; higher levels aggregate powers of two blocks.
/// It never changes cell identity and is rebuilt from source shards.
actor ExplorationRenderHierarchy {
    static let schemaVersion = 2
    private static let maskSide = 64
    private static let maskByteCount = maskSide * maskSide
    private let rootURL: URL
    private let shardStore: ExplorationShardFileStore

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        self.rootURL = rootURL
        shardStore = ExplorationShardFileStore(rootURL: rootURL)
    }

    func read(_ id: ExplorationRenderTileID) throws -> ExplorationRenderTile? {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try ExplorationFileStorage.readData(from: url)
        do {
            let tile = try JSONDecoder().decode(ExplorationRenderTile.self, from: data)
            guard tile.schemaVersion == Self.schemaVersion,
                  tile.rasterVersion == .fogRasterV1,
                  tile.id == id,
                  tile.standardMask.count == Self.maskByteCount,
                  tile.flightMask.count == Self.maskByteCount else {
                try markLeafDirtyIfNeeded(id)
                return nil
            }
            return tile
        } catch {
            // Derived artifacts are disposable. A malformed or old artifact is
            // unavailable and can be rebuilt from the canonical cache.
            try markLeafDirtyIfNeeded(id)
            return nil
        }
    }

    private func markLeafDirtyIfNeeded(_ id: ExplorationRenderTileID) throws {
        guard id.level == 0 else { return }
        try markDirty([FogBlockID(x: id.x, y: id.y)])
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
        let changedIDs = shards.flatMap { $0.blocks.map(\.id) }
        try markDirty(changedIDs)
        try removeAll()
        let leaves = try makeLeaves(merged)
        try write(leaves)
        var levelTiles = leaves
        for level in 1...16 {
            let parents = Set(levelTiles.keys.map { ExplorationRenderTileID(level: UInt8(level), x: $0.x / 2, y: $0.y / 2) })
            var next = [ExplorationRenderTileID: ExplorationRenderTile]()
            for id in parents.sorted() {
                if let tile = makeParent(id, children: levelTiles) { next[id] = tile }
            }
            try write(next)
            levelTiles = next
        }
        try clearDirty(try loadDirty())
        NotificationCenter.default.post(name: .explorationRenderTilesDidUpdate, object: nil)
    }

    func rebuild(affectedBlocks: some Sequence<FogBlockID>, cache: ExplorationMergedCache, deadline: ContinuousClock.Instant? = nil) async throws {
        try check(deadline)
        let ids = Array(Set(affectedBlocks))
        guard !ids.isEmpty else { return }
        let merged = try await cache.renderBlocks(ids)
        try check(deadline)
        var changed = [ExplorationRenderTileID: ExplorationRenderTile]()
        for blockID in ids.sorted() {
            try check(deadline)
            let id = tileID(for: blockID, level: 0)
            if let layers = merged[blockID], let tile = makeLeaf(id, layers: layers) {
                changed[id] = tile
            } else {
                try remove(id)
            }
        }
        try write(changed, deadline: deadline)

        var childIDs = Set(ids.map { tileID(for: $0, level: 0) })
        for level in 1...16 {
            try check(deadline)
            let parentIDs = Set(childIDs.map { ExplorationRenderTileID(level: UInt8(level), x: $0.x / 2, y: $0.y / 2) })
            var parentTiles = [ExplorationRenderTileID: ExplorationRenderTile]()
            for parentID in parentIDs.sorted() {
                try check(deadline)
                var children = [ExplorationRenderTileID: ExplorationRenderTile]()
                for dy in 0...1 {
                    for dx in 0...1 {
                        let childID = ExplorationRenderTileID(level: UInt8(level - 1), x: parentID.x * 2 + UInt32(dx), y: parentID.y * 2 + UInt32(dy))
                        if let changedTile = changed[childID] { children[childID] = changedTile }
                        else if let child = try read(childID) { children[childID] = child }
                    }
                }
                if let parent = makeParent(parentID, children: children) {
                    parentTiles[parentID] = parent
                } else {
                    try remove(parentID)
                }
            }
            try write(parentTiles, deadline: deadline)
            changed = parentTiles
            childIDs = parentIDs
        }
        try clearDirty(ids)
        NotificationCenter.default.post(name: .explorationRenderTilesDidUpdate, object: nil)
    }

    /// Durable retry inventory. Canonical shards remain authoritative if a
    /// derived write is interrupted; the next cache maintenance pass can retry.
    func markDirty(_ ids: some Sequence<FogBlockID>) throws {
        let url = dirtyURL
        var values = Set(try loadDirty().map { "\($0.x)-\($0.y)" })
        values.formUnion(ids.map { "\($0.x)-\($0.y)" })
        try ExplorationFileStorage.writeAtomically(try JSONEncoder().encode(values.sorted()), to: url)
    }

    func dirtyBlocks() throws -> [FogBlockID] {
        try loadDirty().sorted()
    }

    func clearDirtyBlocks(_ ids: [FogBlockID]) throws { try clearDirty(ids) }

    private var dirtyURL: URL { rootURL.appendingPathComponent("v1/render/dirty-blocks.json") }

    private func loadDirty() throws -> [FogBlockID] {
        guard FileManager.default.fileExists(atPath: dirtyURL.path) else { return [] }
        let values = try JSONDecoder().decode([String].self, from: ExplorationFileStorage.readData(from: dirtyURL))
        return values.compactMap { value in
            let pieces = value.split(separator: "-")
            guard pieces.count == 2, let x = UInt32(pieces[0]), let y = UInt32(pieces[1]) else { return nil }
            return FogBlockID(x: x, y: y)
        }
    }

    private func clearDirty(_ ids: [FogBlockID]) throws {
        let remaining = Set(try loadDirty().filter { !Set(ids).contains($0) }.map { "\($0.x)-\($0.y)" })
        if remaining.isEmpty {
            if FileManager.default.fileExists(atPath: dirtyURL.path) { try FileManager.default.removeItem(at: dirtyURL) }
        } else {
            try ExplorationFileStorage.writeAtomically(try JSONEncoder().encode(remaining.sorted()), to: dirtyURL)
        }
    }

    func removeAll() throws {
        let directory = rootURL.appendingPathComponent("v1/render", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where child.lastPathComponent != "dirty-blocks.json" {
            try FileManager.default.removeItem(at: child)
        }
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

    private func makeLeaves(_ blocks: [FogBlockID: [ExplorationLayer: FogBitmapBlock]]) throws -> [ExplorationRenderTileID: ExplorationRenderTile] {
        var result = [ExplorationRenderTileID: ExplorationRenderTile]()
        for (blockID, layers) in blocks {
            let id = tileID(for: blockID, level: 0)
            if let tile = makeLeaf(id, layers: layers) { result[id] = tile }
        }
        return result
    }

    private func makeLeaf(_ id: ExplorationRenderTileID, layers: [ExplorationLayer: FogBitmapBlock]) -> ExplorationRenderTile? {
        var standard = try! FogBitmapBlock()
        for (layer, bitmap) in layers where layer != .flight { standard = standard.union(bitmap) }
        let flight = layers[.flight] ?? (try! FogBitmapBlock())
        let groundCount = layers[.ground]?.bytes.reduce(0) { $0 + $1.nonzeroBitCount } ?? 0
        let visitCount = layers[.visits]?.bytes.reduce(0) { $0 + $1.nonzeroBitCount } ?? 0
        let importedCount = layers[.importedFog]?.bytes.reduce(0) { $0 + $1.nonzeroBitCount } ?? 0
        let standardCount = standard.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
        let flightCount = flight.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
        guard standardCount + flightCount > 0 else { return nil }
        return tile(id, standardMask: coverageMask(standard), flightMask: coverageMask(flight),
                    standardCount: standardCount, flightCount: flightCount,
                    groundCount: groundCount, visitCount: visitCount, importedCount: importedCount,
                    generation: hash(coverageMask(standard) + coverageMask(flight)))
    }

    private func makeParent(_ id: ExplorationRenderTileID, children: [ExplorationRenderTileID: ExplorationRenderTile]) -> ExplorationRenderTile? {
        guard !children.isEmpty else { return nil }
        var standard = [UInt8](repeating: 0, count: Self.maskByteCount)
        var flight = [UInt8](repeating: 0, count: Self.maskByteCount)
        var standardCount = 0, flightCount = 0, groundCount = 0, visitCount = 0, importedCount = 0
        for (childID, child) in children {
            let quadrantX = Int(childID.x & 1) * 32
            let quadrantY = Int(childID.y & 1) * 32
            mergeDownsampled(Data(child.standardMask), into: &standard, offsetX: quadrantX, offsetY: quadrantY)
            mergeDownsampled(Data(child.flightMask), into: &flight, offsetX: quadrantX, offsetY: quadrantY)
            standardCount += child.standardCellCount
            flightCount += child.flightCellCount
            groundCount += child.groundCellCount
            visitCount += child.visitCellCount
            importedCount += child.importedFogCellCount
        }
        let generation = children.keys.sorted().reduce(UInt64(1469598103934665603)) { partial, childID in
            guard let child = children[childID] else { return partial }
            let components = [UInt64(childID.x), UInt64(childID.y), child.generation]
            return components.reduce(partial) { ($0 ^ $1) &* 1099511628211 }
        }
        return tile(id, standardMask: Data(standard), flightMask: Data(flight),
                    standardCount: standardCount, flightCount: flightCount,
                    groundCount: groundCount, visitCount: visitCount, importedCount: importedCount,
                    generation: generation)
    }

    private func tile(_ id: ExplorationRenderTileID, standardMask: Data, flightMask: Data,
                      standardCount: Int, flightCount: Int, groundCount: Int, visitCount: Int, importedCount: Int,
                      generation: UInt64) -> ExplorationRenderTile {
        ExplorationRenderTile(schemaVersion: Self.schemaVersion, rasterVersion: .fogRasterV1, id: id,
                              generation: generation, standardCellCount: standardCount, flightCellCount: flightCount,
                              groundCellCount: groundCount, visitCellCount: visitCount, importedFogCellCount: importedCount,
                              standardMask: standardMask, flightMask: flightMask)
    }

    private func mergeDownsampled(_ source: Data, into target: inout [UInt8], offsetX: Int, offsetY: Int) {
        let bytes = [UInt8](source)
        guard bytes.count == Self.maskByteCount else { return }
        for y in 0..<32 {
            for x in 0..<32 {
                let sum = Int(bytes[(y * 2) * 64 + x * 2]) + Int(bytes[(y * 2) * 64 + x * 2 + 1])
                    + Int(bytes[(y * 2 + 1) * 64 + x * 2]) + Int(bytes[(y * 2 + 1) * 64 + x * 2 + 1])
                let averageCoverage = (sum + 2) / 4
                // Preserve a faint minimum visibility cue for a sparse route
                // at world scale. Counts remain exact and this is presentation
                // coverage only, never canonical or statistical evidence.
                target[(offsetY + y) * 64 + offsetX + x] = UInt8(max(averageCoverage, sum == 0 ? 0 : 64))
            }
        }
    }

    private func coverageMask(_ bitmap: FogBitmapBlock) -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.maskByteCount)
        for y in 0..<64 {
            for x in 0..<64 where bitmap.isSet(x: x, y: y) { bytes[y * 64 + x] = 255 }
        }
        return Data(bytes)
    }

    private func hash(_ data: Data) -> UInt64 {
        data.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    private func remove(_ id: ExplorationRenderTileID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func tileID(for block: FogBlockID, level: Int) -> ExplorationRenderTileID {
        let scale = UInt32(1 << level)
        return ExplorationRenderTileID(level: UInt8(level), x: block.x / scale, y: block.y / scale)
    }

    private func write(
        _ tiles: [ExplorationRenderTileID: ExplorationRenderTile],
        deadline: ContinuousClock.Instant? = nil
    ) throws {
        let fileManager = FileManager.default
        for id in tiles.keys.sorted() {
            try check(deadline)
            let url = url(for: id)
            if let tile = tiles[id] {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(tile)
                try ExplorationFileStorage.writeAtomically(data, to: url)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func url(for id: ExplorationRenderTileID) -> URL {
        rootURL.appendingPathComponent("v1/render/level-\(id.level)/\(id.x)-\(id.y).json")
    }

    private func check(_ deadline: ContinuousClock.Instant?) throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw CancellationError() }
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
    private var updateObserver: NSObjectProtocol?

    init(hierarchy: ExplorationRenderHierarchy = ExplorationRenderHierarchy(), capacity: Int = 128) {
        self.hierarchy = hierarchy
        self.capacity = max(1, capacity)
    }

    deinit { if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) } }

    func read(_ id: ExplorationRenderTileID) async throws -> ExplorationRenderTile? {
        observeUpdatesIfNeeded()
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

    private func observeUpdatesIfNeeded() {
        guard updateObserver == nil else { return }
        updateObserver = NotificationCenter.default.addObserver(forName: .explorationRenderTilesDidUpdate, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.removeAll() }
        }
    }
}
