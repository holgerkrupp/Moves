import Foundation

struct ExplorationMergedBlock: Equatable, Sendable {
    let id: FogBlockID
    let layers: [ExplorationLayerBitmap]

    init(id: FogBlockID, layers: [ExplorationLayerBitmap]) {
        self.id = id
        self.layers = layers.sorted { $0.layer.rawValue < $1.layer.rawValue }
    }

    func bitmap(for layer: ExplorationLayer) -> FogBitmapBlock? {
        layers.first { $0.layer == layer }?.bitmap
    }

    func visibleBitmap(includeFlight: Bool = false) -> FogBitmapBlock {
        layers
            .filter { includeFlight || $0.layer != .flight }
            .map(\.bitmap)
            .reduce(try! FogBitmapBlock()) { $0.union($1) }
    }
}

enum ExplorationCacheError: Error, Equatable {
    case invalidMagic
    case invalidChecksum
    case truncated
    case invalidBlock
}

/// Device-local, disposable merged cache. Source shards remain the replaceable
/// evidence; this actor only materializes their current union for cheap reads.
actor ExplorationMergedCache {
    private static let magic = Data("MVECACHE1".utf8)
    private let rootURL: URL
    private let shardStore: ExplorationShardFileStore
    private let fileManager: FileManager

    private struct PendingBlockID: Codable, Equatable {
        let x: UInt32
        let y: UInt32
        var value: FogBlockID { FogBlockID(x: x, y: y) }
        init(_ value: FogBlockID) { x = value.x; y = value.y }
    }

    private struct PendingPreparationMerge: Codable {
        let sourceID: String
        let revision: UInt64
        let blockIDs: [PendingBlockID]
        var mergeCursor = 0
        var renderCursor = 0
        var countryIndexComplete = false
    }

    init(rootURL: URL, shardStore: ExplorationShardFileStore, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.shardStore = shardStore
        self.fileManager = fileManager
    }

    func readBlock(_ id: FogBlockID) throws -> ExplorationMergedBlock? {
        let url = blockURL(id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decodeBlock(ExplorationFileStorage.readData(from: url))
    }

    func blockIDs() throws -> [FogBlockID] {
        let directory = rootURL.appendingPathComponent("v1/blocks", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url in
                let values = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                guard values.count == 2,
                      let x = UInt32(values[0]),
                      let y = UInt32(values[1]) else { return nil }
                return FogBlockID(x: x, y: y)
            }
            .sorted()
    }

    func mergeShard(_ shard: ExplorationShard) async throws {
        try await replaceShard(shard)
    }

    func replaceShard(_ shard: ExplorationShard, updateCountryPresence: Bool = true, deadline: ContinuousClock.Instant? = nil) async throws {
        if deadline != nil {
            try await replacePreparationShard(shard, updateCountryPresence: updateCountryPresence, deadline: deadline)
            return
        }
        try await replaceShards([shard], updateCountryPresence: updateCountryPresence, deadline: deadline)
    }

    func pendingPreparationShard(sourceID: String) throws -> ExplorationShard? {
        guard try loadPending(sourceID: sourceID) != nil else { return nil }
        return try ExplorationShardCodec.decode(ExplorationFileStorage.readData(from: pendingShardURL(for: sourceID)))
    }

    func markCountryPresenceComplete(sourceID: String, revision: UInt64) throws {
        guard var pending = try loadPending(sourceID: sourceID), pending.revision == revision else { return }
        pending.countryIndexComplete = true
        try savePending(pending, to: pendingURL(for: sourceID))
    }

    func finalizePreparationMerge(sourceID: String, revision: UInt64) throws {
        guard let pending = try loadPending(sourceID: sourceID),
              pending.revision == revision,
              pending.countryIndexComplete else { return }
        let url = pendingURL(for: sourceID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        let shardURL = pendingShardURL(for: sourceID)
        if fileManager.fileExists(atPath: shardURL.path) { try fileManager.removeItem(at: shardURL) }
    }

    private func replacePreparationShard(_ shard: ExplorationShard, updateCountryPresence: Bool, deadline: ContinuousClock.Instant?) async throws {
        try check(deadline)
        let pendingURL = pendingURL(for: shard.sourceID)
        var pending: PendingPreparationMerge
        if let existing = try loadPending(sourceID: shard.sourceID), existing.revision == shard.revision {
            pending = existing
        } else {
            let old = try await shardStore.read(sourceID: shard.sourceID)
            let blockIDs = Set((old?.blocks ?? []).map(\.id) + shard.blocks.map(\.id)).sorted().map(PendingBlockID.init)
            try ExplorationFileStorage.writeAtomically(try ExplorationShardCodec.encode(shard), to: pendingShardURL(for: shard.sourceID))
            pending = PendingPreparationMerge(
                sourceID: shard.sourceID,
                revision: shard.revision,
                blockIDs: blockIDs
            )
            try savePending(pending, to: pendingURL)
        }

        try await ExplorationRenderHierarchy(rootURL: rootURL).markDirty(pending.blockIDs.map(\.value))
        _ = try await shardStore.writeIfPreferred(shard, deadline: deadline)
        while pending.mergeCursor < pending.blockIDs.count {
            try check(deadline)
            try await rebuildBlocks([pending.blockIDs[pending.mergeCursor].value], deadline: deadline)
            pending.mergeCursor += 1
            try savePending(pending, to: pendingURL)
        }
        let hierarchy = ExplorationRenderHierarchy(rootURL: rootURL)
        while pending.renderCursor < pending.blockIDs.count {
            try check(deadline)
            try await hierarchy.rebuild(affectedBlocks: [pending.blockIDs[pending.renderCursor].value], cache: self, deadline: deadline)
            pending.renderCursor += 1
            try savePending(pending, to: pendingURL)
        }
        if updateCountryPresence, !pending.countryIndexComplete {
            try check(deadline)
            try await ExplorationCountryPresenceIndexStore(rootURL: rootURL).update(with: shard, deadline: deadline)
            pending.countryIndexComplete = true
            try savePending(pending, to: pendingURL)
        }
        try await ExplorationStatisticsStore(rootURL: rootURL).remove()
        if updateCountryPresence, fileManager.fileExists(atPath: pendingURL.path) { try fileManager.removeItem(at: pendingURL) }
        if updateCountryPresence {
            let shardURL = pendingShardURL(for: shard.sourceID)
            if fileManager.fileExists(atPath: shardURL.path) { try fileManager.removeItem(at: shardURL) }
        }
    }

    private func loadPending(sourceID: String) throws -> PendingPreparationMerge? {
        let url = pendingURL(for: sourceID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PendingPreparationMerge.self, from: ExplorationFileStorage.readData(from: url))
    }

    private func savePending(_ pending: PendingPreparationMerge, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try ExplorationFileStorage.writeAtomically(try JSONEncoder().encode(pending), to: url)
    }

    private func pendingURL(for sourceID: String) -> URL {
        let encoded = Data(sourceID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return rootURL.appendingPathComponent("v1/derived/pending-\(encoded).json")
    }

    private func pendingShardURL(for sourceID: String) -> URL {
        pendingURL(for: sourceID).deletingPathExtension().appendingPathExtension("shard")
    }

    /// Replaces a bounded batch of source shards and rebuilds their affected
    /// canonical blocks once. Importers use this to avoid rebuilding the whole
    /// cache for every Fog tile.
    func replaceShards(_ shards: [ExplorationShard], updateCountryPresence: Bool = true, deadline: ContinuousClock.Instant? = nil) async throws {
        guard !shards.isEmpty else { return }
        try await retryDirtyRenderTiles(deadline: deadline)
        var affected = Set<FogBlockID>()
        var rebuildAffected = Set<FogBlockID>()
        var appendOnly = [ExplorationShard]()
        var accepted = [ExplorationShard]()
        for shard in shards {
            try check(deadline)
            let old = try await shardStore.read(sourceID: shard.sourceID)
            let candidateBlocks = Set((old?.blocks ?? []).map(\.id) + shard.blocks.map(\.id))
            try await ExplorationRenderHierarchy(rootURL: rootURL).markDirty(candidateBlocks)
            guard try await shardStore.writeIfPreferred(shard) else { continue }
            accepted.append(shard)
            if old == nil { appendOnly.append(shard) }
            affected.formUnion((old?.blocks ?? []).map(\.id))
            affected.formUnion(shard.blocks.map(\.id))
            if old != nil {
                rebuildAffected.formUnion((old?.blocks ?? []).map(\.id))
                rebuildAffected.formUnion(shard.blocks.map(\.id))
            }
        }
        guard !affected.isEmpty else { return }
        if !rebuildAffected.isEmpty { try await rebuildBlocks(rebuildAffected, deadline: deadline) }
        if !appendOnly.isEmpty { try await appendShardsToBlocks(appendOnly, deadline: deadline) }
        try? await ExplorationStatisticsStore(rootURL: rootURL).remove()
        if updateCountryPresence {
            let countryIndex = ExplorationCountryPresenceIndexStore(rootURL: rootURL)
            for shard in accepted where shard.logicalStart != nil || shard.logicalEnd != nil {
                try await countryIndex.update(with: shard)
            }
        }
        try check(deadline)
        try await ExplorationRenderHierarchy(rootURL: rootURL).rebuild(affectedBlocks: affected, cache: self, deadline: deadline)
    }

    func removeShard(sourceID: String) async throws {
        guard let old = try await shardStore.read(sourceID: sourceID) else { return }
        let hierarchy = ExplorationRenderHierarchy(rootURL: rootURL)
        try await hierarchy.markDirty(old.blocks.map(\.id))
        guard try await shardStore.remove(sourceID: sourceID) != nil else { return }
        try await rebuildBlocks(Set(old.blocks.map(\.id)))
        try? await ExplorationStatisticsStore(rootURL: rootURL).remove()
        try? await ExplorationCountryPresenceIndexStore(rootURL: rootURL).removeDay(for: old)
        try await hierarchy.rebuild(affectedBlocks: old.blocks.map(\.id), cache: self)
    }

    func invalidateBlocks(_ ids: some Sequence<FogBlockID>) throws {
        for id in ids {
            let url = blockURL(id)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    func rebuildBlocks(_ ids: some Sequence<FogBlockID>, deadline: ContinuousClock.Instant? = nil) async throws {
        let ids = Array(Set(ids)).sorted()
        guard !ids.isEmpty else { return }
        var merged = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()
        for id in ids {
            try check(deadline)
            let sourceIDs = try await shardStore.sourceIDs(containing: id)
            for sourceID in sourceIDs {
                try check(deadline)
                guard let shard = try await shardStore.read(sourceID: sourceID),
                      let block = shard.blocks.first(where: { $0.id == id }) else { continue }
                for layer in block.layers {
                    if let current = merged[block.id]?[layer.layer] {
                        merged[block.id]?[layer.layer] = current.union(layer.bitmap)
                    } else {
                        merged[block.id, default: [:]][layer.layer] = layer.bitmap
                    }
                }
            }
        }

        try fileManager.createDirectory(at: rootURL.appendingPathComponent("v1/blocks", isDirectory: true), withIntermediateDirectories: true)
        for id in ids {
            try check(deadline)
            if let layers = merged[id], !layers.isEmpty {
                let block = ExplorationMergedBlock(id: id, layers: layers.map { ExplorationLayerBitmap(layer: $0.key, bitmap: $0.value) })
                try writeBlock(block)
            } else {
                let url = blockURL(id)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
        }
    }

    private func appendShardsToBlocks(_ shards: [ExplorationShard], deadline: ContinuousClock.Instant? = nil) async throws {
        var blocksByID = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()
        for shard in shards {
            try check(deadline)
            for block in shard.blocks {
                try check(deadline)
                if blocksByID[block.id] == nil, let existing = try readBlock(block.id) {
                    blocksByID[block.id] = Dictionary(uniqueKeysWithValues: existing.layers.map { ($0.layer, $0.bitmap) })
                }
                for layer in block.layers {
                    if let existing = blocksByID[block.id]?[layer.layer] {
                        blocksByID[block.id]?[layer.layer] = existing.union(layer.bitmap)
                    } else {
                        blocksByID[block.id, default: [:]][layer.layer] = layer.bitmap
                    }
                }
            }
        }
        for (id, layers) in blocksByID {
            try check(deadline)
            try writeBlock(ExplorationMergedBlock(id: id, layers: layers.map { ExplorationLayerBitmap(layer: $0.key, bitmap: $0.value) }))
        }
    }

    func renderBlocks(_ ids: some Sequence<FogBlockID>) throws -> [FogBlockID: [ExplorationLayer: FogBitmapBlock]] {
        var result = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()
        for id in Set(ids) {
            guard let block = try readBlock(id) else { continue }
            result[id] = Dictionary(uniqueKeysWithValues: block.layers.map { ($0.layer, $0.bitmap) })
        }
        return result
    }

    func rebuildAll() async throws {
        let ids = try await shardStore.allShards().flatMap { $0.blocks.map(\.id) }
        try await rebuildBlocks(Set(ids))
        try? await ExplorationStatisticsStore(rootURL: rootURL).remove()
        try? await ExplorationCountryPresenceIndexStore(rootURL: rootURL).remove()
        try await ExplorationRenderHierarchy(rootURL: rootURL).rebuildAll()
    }

    /// Replays durable render dirtiness after cancellation or process exit.
    /// This touches only affected canonical blocks and their hierarchy branches.
    func retryDirtyRenderTiles(deadline: ContinuousClock.Instant? = nil) async throws {
        let hierarchy = ExplorationRenderHierarchy(rootURL: rootURL)
        let dirty = try await hierarchy.dirtyBlocks()
        guard !dirty.isEmpty else { return }
        try check(deadline)
        try await rebuildBlocks(dirty, deadline: deadline)
        try await hierarchy.rebuild(affectedBlocks: dirty, cache: self, deadline: deadline)
    }

    private func writeBlock(_ block: ExplorationMergedBlock) throws {
        var data = Self.magic
        appendUInt32(block.id.x, to: &data)
        appendUInt32(block.id.y, to: &data)
        var mask: UInt8 = 0
        for layer in block.layers { mask |= 1 << layer.layer.rawValue }
        data.append(mask)
        for layer in ExplorationLayer.allCases where mask & (1 << layer.rawValue) != 0 {
            data.append(contentsOf: block.bitmap(for: layer)!.bytes)
        }
        appendUInt32(crc32(data), to: &data)
        let destination = blockURL(block.id)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ExplorationFileStorage.writeAtomically(data, to: destination)
    }

    private func decodeBlock(_ data: Data) throws -> ExplorationMergedBlock {
        guard data.count >= Self.magic.count + 9 else { throw ExplorationCacheError.truncated }
        let payload = Data(data.dropLast(4))
        let actual = readUInt32(data, at: data.count - 4)
        guard crc32(payload) == actual else { throw ExplorationCacheError.invalidChecksum }
        var reader = CacheReader(data: payload)
        guard try reader.readData(Self.magic.count) == Self.magic else { throw ExplorationCacheError.invalidMagic }
        let id = FogBlockID(x: try reader.readUInt32(), y: try reader.readUInt32())
        let mask = try reader.readByte()
        var layers: [ExplorationLayerBitmap] = []
        for layer in ExplorationLayer.allCases where mask & (1 << layer.rawValue) != 0 {
            layers.append(ExplorationLayerBitmap(layer: layer, bitmap: try FogBitmapBlock(data: reader.readData(FogBitmapBlock.byteCount))))
        }
        guard reader.isAtEnd else { throw ExplorationCacheError.truncated }
        return ExplorationMergedBlock(id: id, layers: layers)
    }

    private func blockURL(_ id: FogBlockID) -> URL {
        rootURL.appendingPathComponent("v1/blocks", isDirectory: true).appendingPathComponent("\(id.x)-\(id.y).block")
    }

    private func check(_ deadline: ContinuousClock.Instant?) throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw CancellationError() }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8(value >> 24))
    }
}

private struct CacheReader {
    let data: Data
    var offset = 0
    var isAtEnd: Bool { offset == data.count }

    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else { throw ExplorationCacheError.truncated }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func readByte() throws -> UInt8 {
        let value = try readData(1)
        return value[value.startIndex]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(4)
        return UInt32(bytes[bytes.startIndex])
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 1)]) << 8
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 2)]) << 16
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 3)]) << 24
    }
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask: UInt32 = (crc & 1) == 0 ? 0 : 0xedb88320
            crc = (crc >> 1) ^ mask
        }
    }
    return ~crc
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = Array(data[offset..<offset + 4])
    return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
}
