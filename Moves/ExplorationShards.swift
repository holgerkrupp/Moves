import Foundation

enum ExplorationLayer: UInt8, CaseIterable, Codable, Sendable {
    case ground = 0
    case visits = 1
    case flight = 2
    case importedFog = 3
}

struct ExplorationLayerBitmap: Equatable, Sendable {
    let layer: ExplorationLayer
    let bitmap: FogBitmapBlock
}

struct ExplorationShardBlock: Equatable, Sendable {
    let id: FogBlockID
    let layers: [ExplorationLayerBitmap]

    init(id: FogBlockID, layers: [ExplorationLayerBitmap]) {
        self.id = id
        self.layers = layers.sorted { $0.layer.rawValue < $1.layer.rawValue }
    }

    func bitmap(for layer: ExplorationLayer) -> FogBitmapBlock? {
        layers.first { $0.layer == layer }?.bitmap
    }
}

struct ExplorationShard: Equatable, Sendable {
    static let schemaVersion: UInt16 = 1
    static let rasterVersion = FogRasterVersion.fogRasterV1

    let sourceID: String
    let revision: UInt64
    let logicalStart: Date?
    let logicalEnd: Date?
    let blocks: [ExplorationShardBlock]

    init(
        sourceID: String,
        revision: UInt64,
        logicalStart: Date? = nil,
        logicalEnd: Date? = nil,
        blocks: [ExplorationShardBlock]
    ) {
        self.sourceID = sourceID
        self.revision = revision
        self.logicalStart = logicalStart
        self.logicalEnd = logicalEnd
        self.blocks = blocks.sorted { $0.id < $1.id }
    }
}

enum ExplorationShardError: Error, Equatable {
    case invalidMagic
    case unsupportedSchema(UInt16)
    case unsupportedRaster(String)
    case truncated
    case invalidUTF8
    case invalidSourceID
    case invalidBlockCoordinate
    case duplicateBlock
    case duplicateLayer
    case invalidChecksum
    case invalidBlockCount
    case invalidLayerMask
}

enum ExplorationShardCodec {
    private static let magic = Data("MVEXPLR1".utf8)
    private static let maximumBlockCount: UInt32 = 1_000_000

    static func encode(_ shard: ExplorationShard) throws -> Data {
        guard !shard.sourceID.isEmpty, shard.sourceID.utf8.count <= UInt16.max else {
            throw ExplorationShardError.invalidSourceID
        }
        guard shard.blocks.count <= Int(maximumBlockCount) else {
            throw ExplorationShardError.invalidBlockCount
        }

        var data = magic
        appendUInt16(ExplorationShard.schemaVersion, to: &data)
        appendString(FogRasterVersion.fogRasterV1.rawValue, to: &data)
        appendString(shard.sourceID, to: &data)
        appendUInt64(shard.revision, to: &data)
        appendDate(shard.logicalStart, to: &data)
        appendDate(shard.logicalEnd, to: &data)
        appendUInt32(UInt32(shard.blocks.count), to: &data)

        var previousID: FogBlockID?
        for block in shard.blocks {
            guard block.id.x < FogRasterV1.globalCellDimension / FogRasterV1.cellsPerBlock,
                  block.id.y < FogRasterV1.globalCellDimension / FogRasterV1.cellsPerBlock else {
                throw ExplorationShardError.invalidBlockCoordinate
            }
            if previousID == block.id { throw ExplorationShardError.duplicateBlock }
            previousID = block.id
            appendUInt32(block.id.x, to: &data)
            appendUInt32(block.id.y, to: &data)

            var layerMask: UInt8 = 0
            var seenLayers = Set<ExplorationLayer>()
            for layer in block.layers {
                if !seenLayers.insert(layer.layer).inserted { throw ExplorationShardError.duplicateLayer }
                layerMask |= 1 << layer.layer.rawValue
            }
            data.append(layerMask)
            for layer in ExplorationLayer.allCases where layerMask & (1 << layer.rawValue) != 0 {
                guard let bitmap = block.bitmap(for: layer) else { throw ExplorationShardError.duplicateLayer }
                data.append(contentsOf: bitmap.bytes)
            }
        }
        appendUInt32(crc32(data), to: &data)
        return data
    }

    static func decode(_ data: Data) throws -> ExplorationShard {
        guard data.count >= magic.count + 2 + 4 else { throw ExplorationShardError.truncated }
        let payload = Data(data.dropLast(4))
        let expectedChecksum = readUInt32(from: data, at: data.count - 4)
        guard crc32(payload) == expectedChecksum else { throw ExplorationShardError.invalidChecksum }

        var reader = DataReader(data: payload)
        guard try reader.readData(count: magic.count) == magic else { throw ExplorationShardError.invalidMagic }
        let schema = try reader.readUInt16()
        guard schema == ExplorationShard.schemaVersion else { throw ExplorationShardError.unsupportedSchema(schema) }
        let raster = try reader.readString()
        guard raster == FogRasterVersion.fogRasterV1.rawValue else { throw ExplorationShardError.unsupportedRaster(raster) }
        let sourceID = try reader.readString()
        guard !sourceID.isEmpty else { throw ExplorationShardError.invalidSourceID }
        let revision = try reader.readUInt64()
        let logicalStart = try reader.readDate()
        let logicalEnd = try reader.readDate()
        let blockCount = try reader.readUInt32()
        guard blockCount <= maximumBlockCount else { throw ExplorationShardError.invalidBlockCount }

        var blocks: [ExplorationShardBlock] = []
        blocks.reserveCapacity(Int(blockCount))
        var previousID: FogBlockID?
        for _ in 0..<blockCount {
            let id = FogBlockID(x: try reader.readUInt32(), y: try reader.readUInt32())
            guard id.x < FogRasterV1.globalCellDimension / FogRasterV1.cellsPerBlock,
                  id.y < FogRasterV1.globalCellDimension / FogRasterV1.cellsPerBlock else {
                throw ExplorationShardError.invalidBlockCoordinate
            }
            if previousID == id { throw ExplorationShardError.duplicateBlock }
            previousID = id
            let layerMask = try reader.readByte()
            guard layerMask & ~UInt8((1 << ExplorationLayer.allCases.count) - 1) == 0 else {
                throw ExplorationShardError.invalidLayerMask
            }
            var layers: [ExplorationLayerBitmap] = []
            for layer in ExplorationLayer.allCases where layerMask & (1 << layer.rawValue) != 0 {
                layers.append(ExplorationLayerBitmap(layer: layer, bitmap: try FogBitmapBlock(data: reader.readData(count: FogBitmapBlock.byteCount))))
            }
            blocks.append(ExplorationShardBlock(id: id, layers: layers))
        }
        guard reader.isAtEnd else { throw ExplorationShardError.truncated }
        return ExplorationShard(sourceID: sourceID, revision: revision, logicalStart: logicalStart, logicalEnd: logicalEnd, blocks: blocks)
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let stringData = Data(value.utf8)
        appendUInt16(UInt16(stringData.count), to: &data)
        data.append(stringData)
    }

    private static func appendDate(_ value: Date?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        appendUInt64(value.map { $0.timeIntervalSince1970.bitPattern } ?? 0, to: &data)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8(value >> 24))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        let bytes = Array(data[offset..<offset + 4])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
}

private struct DataReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw ExplorationShardError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else { throw ExplorationShardError.truncated }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.index(bytes.startIndex, offsetBy: 1)]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return UInt32(bytes[bytes.startIndex])
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 1)]) << 8
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 2)]) << 16
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 3)]) << 24
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.enumerated().reduce(UInt64(0)) { partial, item in
            partial | UInt64(item.element) << UInt64(item.offset * 8)
        }
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt16())
        guard let string = String(data: try readData(count: length), encoding: .utf8) else {
            throw ExplorationShardError.invalidUTF8
        }
        return string
    }

    mutating func readDate() throws -> Date? {
        let hasValue = try readByte()
        let bits = try readUInt64()
        return hasValue == 0 ? nil : Date(timeIntervalSince1970: Double(bitPattern: bits))
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

private func lexicographicallyPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
    for (left, right) in zip(lhs, rhs) where left != right {
        return left < right
    }
    return lhs.count < rhs.count
}

actor ExplorationShardFileStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func read(sourceID: String) throws -> ExplorationShard? {
        let url = try url(for: sourceID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try ExplorationShardCodec.decode(Data(contentsOf: url))
    }

    func allShards() throws -> [ExplorationShard] {
        let directory = rootURL.appendingPathComponent("v1/sources", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "exploration" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { try ExplorationShardCodec.decode(Data(contentsOf: $0)) }
    }

    func write(_ shard: ExplorationShard, failBeforeReplacement: Bool = false) throws {
        let data = try ExplorationShardCodec.encode(shard)
        _ = try ExplorationShardCodec.decode(data)
        let destination = try url(for: shard.sourceID)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: ExplorationFileStorage.protectedWriteOptions)
        if failBeforeReplacement {
            throw CocoaError(.fileWriteUnknown)
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    /// Applies a shard received from another producer without allowing an old
    /// revision to resurrect deleted cells. Equal revisions use the encoded
    /// bytes as a deterministic tie-break so two devices converge even when a
    /// transport delivers conflicting content for the same generation.
    @discardableResult
    func writeIfPreferred(_ shard: ExplorationShard) throws -> Bool {
        let incoming = try ExplorationShardCodec.encode(shard)
        _ = try ExplorationShardCodec.decode(incoming)
        if let existing = try read(sourceID: shard.sourceID) {
            if existing.revision > shard.revision { return false }
            if existing.revision == shard.revision {
                let current = try ExplorationShardCodec.encode(existing)
                if !lexicographicallyPrecedes(incoming, current) { return false }
            }
        }
        try write(shard)
        return true
    }

    @discardableResult
    func remove(sourceID: String) throws -> ExplorationShard? {
        let existing = try read(sourceID: sourceID)
        if existing != nil { try fileManager.removeItem(at: try url(for: sourceID)) }
        return existing
    }

    private func url(for sourceID: String) throws -> URL {
        guard !sourceID.isEmpty else { throw ExplorationShardError.invalidSourceID }
        let encoded = Data(sourceID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return rootURL.appendingPathComponent("v1/sources", isDirectory: true).appendingPathComponent(encoded).appendingPathExtension("exploration")
    }
}
