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

    init(rootURL: URL, shardStore: ExplorationShardFileStore, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.shardStore = shardStore
        self.fileManager = fileManager
    }

    func readBlock(_ id: FogBlockID) throws -> ExplorationMergedBlock? {
        let url = blockURL(id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decodeBlock(Data(contentsOf: url))
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

    func replaceShard(_ shard: ExplorationShard) async throws {
        try await replaceShards([shard])
    }

    /// Replaces a bounded batch of source shards and rebuilds their affected
    /// canonical blocks once. Importers use this to avoid rebuilding the whole
    /// cache for every Fog tile.
    func replaceShards(_ shards: [ExplorationShard]) async throws {
        guard !shards.isEmpty else { return }
        var affected = Set<FogBlockID>()
        for shard in shards {
            let old = try await shardStore.read(sourceID: shard.sourceID)
            guard try await shardStore.writeIfPreferred(shard) else { continue }
            affected.formUnion((old?.blocks ?? []).map(\.id))
            affected.formUnion(shard.blocks.map(\.id))
        }
        guard !affected.isEmpty else { return }
        try await rebuildBlocks(affected)
        try? await ExplorationStatisticsStore(rootURL: rootURL).remove()
        try? await ExplorationCountryPresenceIndexStore(rootURL: rootURL).remove()
        try? await ExplorationRenderHierarchy(rootURL: rootURL).rebuild(affectedBlocks: affected)
    }

    func removeShard(sourceID: String) async throws {
        guard let old = try await shardStore.remove(sourceID: sourceID) else { return }
        try await rebuildBlocks(Set(old.blocks.map(\.id)))
        try? await ExplorationStatisticsStore(rootURL: rootURL).remove()
        try? await ExplorationCountryPresenceIndexStore(rootURL: rootURL).remove()
        try? await ExplorationRenderHierarchy(rootURL: rootURL).rebuild(affectedBlocks: old.blocks.map(\.id))
    }

    func invalidateBlocks(_ ids: some Sequence<FogBlockID>) throws {
        for id in ids {
            let url = blockURL(id)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    func rebuildBlocks(_ ids: some Sequence<FogBlockID>) async throws {
        let ids = Array(Set(ids)).sorted()
        guard !ids.isEmpty else { return }
        let shards = try await shardStore.allShards()
        var wanted = Set(ids)
        var merged = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()

        for shard in shards {
            for block in shard.blocks where wanted.contains(block.id) {
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
            if let layers = merged[id], !layers.isEmpty {
                let block = ExplorationMergedBlock(id: id, layers: layers.map { ExplorationLayerBitmap(layer: $0.key, bitmap: $0.value) })
                try writeBlock(block)
            } else {
                let url = blockURL(id)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            wanted.remove(id)
        }
    }

    func rebuildAll() async throws {
        let ids = try await shardStore.allShards().flatMap { $0.blocks.map(\.id) }
        try await rebuildBlocks(Set(ids))
        try? await ExplorationStatisticsStore(rootURL: rootURL).remove()
        try? await ExplorationCountryPresenceIndexStore(rootURL: rootURL).remove()
        try? await ExplorationRenderHierarchy(rootURL: rootURL).rebuildAll()
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
        try data.write(to: destination, options: ExplorationFileStorage.atomicWriteOptions)
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
