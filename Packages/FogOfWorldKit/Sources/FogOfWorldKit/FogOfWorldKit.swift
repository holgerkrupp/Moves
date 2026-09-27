import Compression
import CryptoKit
import Foundation

public enum FogArchiveKind: String, Sendable, Equatable {
    case fwss
    case sync
}

/// Container-level information that is safe to expose without making the
/// Moves target understand Fog's private metadata records. Bitmap decoding is
/// identical for Sync and FWSS; the extra counts let callers decide whether a
/// full-fidelity FWSS round trip is possible.
public struct FogArchiveSummary: Sendable, Equatable {
    public let kind: FogArchiveKind
    public let bitmapEntryCount: Int
    public let metadataEntryCount: Int
    public let hierarchyEntryCount: Int
    public let hashEntryCount: Int
    public let otherEntryCount: Int

    public init(
        kind: FogArchiveKind,
        bitmapEntryCount: Int,
        metadataEntryCount: Int,
        hierarchyEntryCount: Int,
        hashEntryCount: Int,
        otherEntryCount: Int
    ) {
        self.kind = kind
        self.bitmapEntryCount = bitmapEntryCount
        self.metadataEntryCount = metadataEntryCount
        self.hierarchyEntryCount = hierarchyEntryCount
        self.hashEntryCount = hashEntryCount
        self.otherEntryCount = otherEntryCount
    }
}

public struct FogBitmapBlock: Sendable, Equatable, Hashable {
    public static let dimension = 64
    public static let byteCount = 512
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw FogError.invalidBlock }
        self.bytes = bytes
    }

    public init(repeating byte: UInt8 = 0) {
        bytes = Data(repeating: byte, count: Self.byteCount)
    }

    public func contains(x: Int, y: Int) -> Bool {
        guard (0..<Self.dimension).contains(x), (0..<Self.dimension).contains(y) else { return false }
        let index = y * 64 + x
        return (bytes[index / 8] & (0x80 >> (index % 8))) != 0
    }
}

public struct FogBlock: Sendable, Equatable {
    public let tileID: Int
    public let localX: Int
    public let localY: Int
    public let bitmap: FogBitmapBlock

    public init(tileID: Int, localX: Int, localY: Int, bitmap: FogBitmapBlock) {
        self.tileID = tileID
        self.localX = localX
        self.localY = localY
        self.bitmap = bitmap
    }
}

/// Neutral Fog world coordinates. This is deliberately independent from
/// CoreLocation and Moves' persistence types so the package can be reused by
/// import/export tools.
public struct FogWorldCoordinate: Sendable, Equatable, Hashable {
    public let x: UInt32
    public let y: UInt32

    public init(x: UInt32, y: UInt32) {
        self.x = x
        self.y = y
    }
}

public struct FogGeographicCoordinate: Sendable, Equatable {
    public let longitude: Double
    public let latitude: Double

    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
}

public enum FogRaster {
    public static let baseTileZoom = 9
    public static let baseTileCount = 512
    public static let blocksPerBaseTile = 128
    public static let cellsPerBlock = 64
    public static let globalCellDimension = 4_194_304
    public static let webMercatorMaximumLatitude = 85.0511287798066

    public static func worldCoordinate(longitude: Double, latitude: Double) -> FogWorldCoordinate {
        var wrapped = longitude.truncatingRemainder(dividingBy: 360)
        if wrapped <= -180 { wrapped += 360 }
        if wrapped >= 180 { wrapped -= 360 }
        let clamped = min(max(latitude, -webMercatorMaximumLatitude), webMercatorMaximumLatitude)
        let radians = clamped * .pi / 180
        let x = floor(((wrapped + 180) / 360) * Double(globalCellDimension))
        let y = floor(((.pi - asinh(tan(radians))) / (2 * .pi)) * Double(globalCellDimension))
        return FogWorldCoordinate(
            x: UInt32(min(max(x, 0), Double(globalCellDimension - 1))),
            y: UInt32(min(max(y, 0), Double(globalCellDimension - 1)))
        )
    }

    public static func geographicCoordinate(for coordinate: FogWorldCoordinate) -> FogGeographicCoordinate {
        let dimension = Double(globalCellDimension)
        let longitude = Double(coordinate.x) / dimension * 360 - 180
        let latitude = atan(sinh(.pi - 2 * .pi * Double(coordinate.y) / dimension)) * 180 / .pi
        return FogGeographicCoordinate(longitude: longitude, latitude: latitude)
    }

    public static func tileID(for coordinate: FogWorldCoordinate) -> Int {
        let tileX = Int(coordinate.x) / (blocksPerBaseTile * cellsPerBlock)
        let tileY = Int(coordinate.y) / (blocksPerBaseTile * cellsPerBlock)
        return tileY * baseTileCount + tileX
    }

    public static func blockAddress(for coordinate: FogWorldCoordinate) -> (tileID: Int, localX: Int, localY: Int) {
        let tileID = tileID(for: coordinate)
        let blockX = Int(coordinate.x / UInt32(cellsPerBlock))
        let blockY = Int(coordinate.y / UInt32(cellsPerBlock))
        return (tileID, blockX % blocksPerBaseTile, blockY % blocksPerBaseTile)
    }
}

public enum FogError: Error, Equatable {
    case invalidArchive
    case unsupportedCompression
    case invalidEntry
    case invalidBlock
    case invalidChecksum
    case invalidTileName
    case invalidTileID
    case noBitmapEntries
    case outputTooLarge
}

/// A deliberately small, streaming-friendly native Fog boundary. Moves owns
/// its canonical raster and source shards; this package owns native archive
/// details such as ZIP entries, zlib tiles, headers, checksums, and filenames.
public struct FogArchiveReader: Sendable {
    private let data: Data
    private let entries: [ZipEntry]
    public let summary: FogArchiveSummary

    public init(data: Data) throws {
        self.data = data
        let archive = ZipArchive(data: data)
        let allEntries = try archive.entries()
        self.entries = allEntries.filter(\.isBitmap)
        guard !entries.isEmpty else { throw FogError.noBitmapEntries }
        let kind = entries.first?.kind ?? .sync
        summary = FogArchiveSummary(
            kind: kind,
            bitmapEntryCount: entries.count,
            metadataEntryCount: allEntries.filter { $0.isMetadata }.count,
            hierarchyEntryCount: allEntries.filter { $0.isHierarchy }.count,
            hashEntryCount: allEntries.filter { $0.isHash }.count,
            otherEntryCount: allEntries.filter { !$0.isBitmap && !$0.isMetadata && !$0.isHierarchy && !$0.isHash }.count
        )
    }

    public var kind: FogArchiveKind { entries.first?.kind ?? .sync }

    public func blocks() throws -> AsyncThrowingStream<FogBlock, Error> {
        let archiveData = data
        let archiveEntries = entries
        return AsyncThrowingStream { continuation in
            Task.detached(priority: .utility) {
                do {
                    let archive = ZipArchive(data: archiveData)
                    for entry in archiveEntries {
                        try Task.checkCancellation()
                        let payload = try archive.data(for: entry)
                        let inflated = try inflate(payload, maximumSize: 32 * 1024 * 1024)
                        for block in try NativeTile.decode(filename: entry.basename, data: inflated) {
                            continuation.yield(block)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func decodeAllBlocks() async throws -> [FogBlock] {
        var result: [FogBlock] = []
        for try await block in try blocks() { result.append(block) }
        return result
    }

    /// Decodes one already-inflated native Fog tile. This is exposed for
    /// compatibility fixtures and tests; archive/container handling remains
    /// inside FogOfWorldKit rather than in the Moves app target.
    public static func decodeInflatedTile(filename: String, data: Data) throws -> [FogBlock] {
        try NativeTile.decode(filename: filename, data: data)
    }
}

public enum FogArchiveWriter {
    public static func makeSyncArchive(blocks: some Sequence<FogBlock>) throws -> Data {
        var grouped = [Int: [Int: FogBitmapBlock]]()
        for block in blocks {
            guard (0..<128).contains(block.localX), (0..<128).contains(block.localY), (0..<512 * 512).contains(block.tileID) else {
                throw FogError.invalidTileID
            }
            grouped[block.tileID, default: [:]][block.localX + block.localY * 128] = block.bitmap
        }
        var files: [(String, Data)] = []
        for tileID in grouped.keys.sorted() {
            let raw = try NativeTile.encode(tileID: tileID, blocks: grouped[tileID] ?? [:])
            files.append(("Sync/\(try NativeTile.filename(forTileID: tileID))", try deflate(raw)))
        }
        guard !files.isEmpty else { throw FogError.noBitmapEntries }
        return try makeStoredZip(files: files)
    }

    /// Writes a Fog FWSS snapshot containing the canonical base bitmap tiles,
    /// hash tiles, tile-presence index, metadata record, and deterministic
    /// downsampled `Model/~` hierarchy. Moves-only provenance is intentionally
    /// not represented: FWSS stores binary revealed coverage.
    public static func makeFWSSArchive(blocks: some Sequence<FogBlock>) throws -> Data {
        var grouped = [Int: [Int: FogBitmapBlock]]()
        for block in blocks {
            guard (0..<128).contains(block.localX),
                  (0..<128).contains(block.localY),
                  (0..<512 * 512).contains(block.tileID) else {
                throw FogError.invalidTileID
            }
            grouped[block.tileID, default: [:]][block.localX + block.localY * 128] = block.bitmap
        }
        guard !grouped.isEmpty else { throw FogError.noBitmapEntries }

        var files = [(String, Data)]()
        var tileIndex = Data(repeating: 0, count: 32_768)
        var pending = [FogSnapshotTile]()
        var totalAreaSquareMeters = 0.0

        for tileID in grouped.keys.sorted() {
            let tileX = tileID % FogRaster.baseTileCount
            let tileY = tileID / FogRaster.baseTileCount
            let base = FogSnapshotTile(
                x: tileX,
                y: tileY,
                z: 9,
                blocks: grouped[tileID, default: [:]].mapValues { Data($0.bytes) }
            )
            let bitmapName = try NativeTile.snapshotFilename(x: tileX, y: tileY, z: 9, kind: .bitmap)
            let hashName = try NativeTile.snapshotFilename(x: tileX, y: tileY, z: 9, kind: .hash)
            files.append(("Model/*/\(bitmapName)", try deflate(try NativeTile.encodeSparse(base.blocks, kind: .bitmap))))
            files.append(("Model/#/\(hashName)", try deflate(try NativeTile.encodeSparse(base.blocks, kind: .hash))))

            // The FWSS presence bitmap is row-major by base-tile ID, not a
            // per-row bitmap. Its bit order is least-significant-bit first,
            // matching Fog Machine's tile-presence probe.
            let tileIndexOffset = tileID / 8
            tileIndex[tileIndexOffset] |= UInt8(1 << (tileID % 8))
            totalAreaSquareMeters += NativeTile.tileRowAreaSquareMeters(tileY) * Double(NativeTile.pixelCount(base.blocks)) / Double(FogRaster.blocksPerBaseTile * FogRaster.blocksPerBaseTile * FogRaster.cellsPerBlock * FogRaster.cellsPerBlock)
            pending.append(base)
        }

        while !pending.isEmpty {
            var next = [String: FogSnapshotTile]()
            for tile in pending.sorted() {
                if tile.z <= 8, tile.z >= -6, !tile.blocks.isEmpty {
                    let name = try NativeTile.snapshotFilename(x: tile.x, y: tile.y, z: tile.z, kind: .layer)
                    files.append(("Model/~/\(name)", try deflate(try NativeTile.encodeSparse(tile.blocks, kind: .layer))))
                }
                guard tile.z > -6 else { continue }
                let parent = FogSnapshotTile(x: tile.x / 2, y: tile.y / 2, z: tile.z - 1, blocks: [:])
                let key = parent.key
                var mutableParent = next[key] ?? parent
                NativeTile.mergeDownsampled(child: tile, into: &mutableParent)
                next[key] = mutableParent
            }
            pending = next.values.sorted()
        }

        files.append(("Model/#/01abfc750a", try deflate(NativeTile.snapshotMetadata(totalAreaSquareMeters))))
        files.append(("Model/#/3389dae361", try deflate(tileIndex)))
        return try makeStoredZip(files: files)
    }
}

private struct ZipEntry: Sendable {
    let name: String
    let method: UInt16
    let checksum: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let dataOffset: Int
    let kind: FogArchiveKind
    var basename: String { URL(fileURLWithPath: name).lastPathComponent }
    var isBitmap: Bool {
        switch kind {
        case .sync: return name.hasPrefix("Sync/") && !name.hasSuffix("/")
        case .fwss: return name.range(of: "^Model/\\*/[^/]+$", options: .regularExpression) != nil
        }
    }
    var isMetadata: Bool {
        guard name.hasPrefix("Model/#/") else { return false }
        return !isHash
    }
    var isHierarchy: Bool { name == "Model/~" || name.hasPrefix("Model/~/") }
    var isHash: Bool {
        guard name.hasPrefix("Model/#/") else { return false }
        let basename = URL(fileURLWithPath: name).lastPathComponent
        return basename != "01abfc750a" && basename != "3389dae361"
    }
}

private struct ZipArchive: Sendable {
    let data: Data

    func entries() throws -> [ZipEntry] {
        var result: [ZipEntry] = []
        var offset = 0
        while offset + 30 <= data.count {
            guard readUInt32(at: offset) == 0x04034b50 else { break }
            let method = readUInt16(at: offset + 8)
            let checksum = readUInt32(at: offset + 14)
            let compressedSize = Int(readUInt32(at: offset + 18))
            let uncompressedSize = Int(readUInt32(at: offset + 22))
            let nameLength = Int(readUInt16(at: offset + 26))
            let extraLength = Int(readUInt16(at: offset + 28))
            let nameStart = offset + 30
            let end = nameStart + nameLength + extraLength + compressedSize
            guard end <= data.count else { throw FogError.invalidArchive }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            guard !name.contains(".."), !name.hasPrefix("/") else { throw FogError.invalidArchive }
            let kind: FogArchiveKind?
            if name.hasPrefix("Sync/") { kind = .sync }
            else if name.hasPrefix("Model/") { kind = .fwss }
            else { kind = nil }
            if let kind {
                result.append(ZipEntry(name: name, method: method, checksum: checksum, compressedSize: compressedSize, uncompressedSize: uncompressedSize, dataOffset: nameStart + nameLength + extraLength, kind: kind))
            }
            offset = end
        }
        return result
    }

    func data(for entry: ZipEntry) throws -> Data {
        let end = entry.dataOffset + entry.compressedSize
        guard end <= data.count else { throw FogError.invalidArchive }
        let payload = Data(data[entry.dataOffset..<end])
        let decoded: Data
        switch entry.method {
        case 0: decoded = payload
        case 8: decoded = try inflate(payload, maximumSize: max(entry.uncompressedSize, 32 * 1024 * 1024))
        default: throw FogError.unsupportedCompression
        }
        guard decoded.count == entry.uncompressedSize, crc32(decoded) == entry.checksum else {
            throw FogError.invalidChecksum
        }
        return decoded
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private func readUInt32(at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
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

private enum NativeTile {
    static let tileWidth = 128
    static let headerSize = 32_768
    static let blockSize = 515
    static let idMask = Array("olhwjsktri")
    static let checksumMask = Array("eizxdwknmo")

    static func decode(filename: String, data: Data) throws -> [FogBlock] {
        guard data.count >= headerSize, filename.count >= 2 else { throw FogError.invalidTileName }
        let tileID = try decodeTileID(filename)
        var blocks: [FogBlock] = []
        for headerIndex in 0..<(tileWidth * tileWidth) {
            let blockIndex = Int(readUInt16(data, at: headerIndex * 2))
            guard blockIndex != 0 else { continue }
            let offset = headerSize + (blockIndex - 1) * blockSize
            guard offset >= headerSize, offset + blockSize <= data.count else { throw FogError.invalidEntry }
            let bitmap = try FogBitmapBlock(bytes: Data(data[offset..<(offset + 512)]))
            let storedScore = UInt16(data[offset + 513]) << 8 | UInt16(data[offset + 514])
            let actualCount = bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            let storedCount = Int(storedScore & 0x3fff) >> 1
            guard storedCount == actualCount || (storedScore == 0 && actualCount == 0) else { throw FogError.invalidChecksum }
            blocks.append(FogBlock(tileID: tileID, localX: headerIndex % tileWidth, localY: headerIndex / tileWidth, bitmap: bitmap))
        }
        return blocks
    }

    static func encode(tileID: Int, blocks: [Int: FogBitmapBlock]) throws -> Data {
        guard (0..<512 * 512).contains(tileID) else { throw FogError.invalidTileID }
        var header = Data(repeating: 0, count: headerSize)
        var records = Data()
        for index in blocks.keys.sorted() {
            guard (0..<(tileWidth * tileWidth)).contains(index), let bitmap = blocks[index] else { continue }
            let recordIndex = records.count / blockSize + 1
            guard recordIndex <= Int(UInt16.max) else { throw FogError.outputTooLarge }
            let headerOffset = index * 2
            header[headerOffset] = UInt8(recordIndex & 0xff)
            header[headerOffset + 1] = UInt8(recordIndex >> 8)
            records.append(bitmap.bytes)
            records.append(0)
            let score = UInt16(bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount } * 2 + 1)
            records.append(UInt8(score >> 8))
            records.append(UInt8(score & 0xff))
        }
        var data = header
        data.append(records)
        return data
    }

    enum SnapshotFilenameKind { case bitmap, hash, layer }

    static func snapshotFilename(x: Int, y: Int, z: Int, kind: SnapshotFilenameKind) throws -> String {
        guard z <= 9, z >= -6 else { throw FogError.invalidTileID }
        let widths = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 4096]
        let filenameZ = max(z, 0)
        guard filenameZ < widths.count, x >= 0, y >= 0, x < widths[filenameZ], y < widths[filenameZ] else {
            throw FogError.invalidTileID
        }
        let id = widths[filenameZ] * y + x
        let typeOffset: Int
        switch kind {
        case .bitmap, .layer: typeOffset = 0
        case .hash: typeOffset = 74
        }
        let checksumInput = id + 9 - z + typeOffset
        let idPart = String(id).compactMap { Int(String($0)) }.map { String(idMask[$0]) }.joined()
        let checksum = ((checksumInput % 100) + 100) % 100
        let suffix = String(checksumMask[checksum / 10]) + String(checksumMask[checksum % 10])
        let prefix = md5Hex(Data(String(checksumInput).utf8)).prefix(4)
        return "\(prefix)\(idPart)\(suffix)"
    }

    static func encodeSparse(_ blocks: [Int: Data], kind: SnapshotFilenameKind) throws -> Data {
        var header = Data(repeating: 0, count: headerSize)
        var records = Data()
        var recordIndex = 1
        for index in blocks.keys.sorted() {
            guard (0..<(tileWidth * tileWidth)).contains(index), let bitmap = blocks[index], bitmap.count == FogBitmapBlock.byteCount else {
                throw FogError.invalidBlock
            }
            guard recordIndex <= Int(UInt16.max) else { throw FogError.outputTooLarge }
            header[index * 2] = UInt8(recordIndex & 0xff)
            header[index * 2 + 1] = UInt8(recordIndex >> 8)
            records.append(bitmap)
            switch kind {
            case .bitmap:
                let score = UInt16(bitmap.reduce(0) { $0 + $1.nonzeroBitCount } * 2 + 1)
                records.append(0)
                records.append(UInt8(score >> 8))
                records.append(UInt8(score & 0xff))
            case .hash:
                let count = bitmap.reduce(0) { $0 + $1.nonzeroBitCount }
                records.append(35)
                records.append(UInt8(192 + (count >> 8)))
                records.append(UInt8(count & 0xff))
            case .layer:
                // Fog Machine's hierarchy serializer stores layer records as
                // the raw 512-byte bitmap with no bitmap/hash trailer.
                break
            }
            recordIndex += 1
        }
        var result = header
        result.append(records)
        return result
    }

    static func mergeDownsampled(child: FogSnapshotTile, into parent: inout FogSnapshotTile) {
        let right = child.x % 2 != 0
        let bottom = child.y % 2 != 0
        let blockXOffset = right ? 64 : 0
        let blockYOffset = bottom ? 64 : 0
        for (sourceIndex, sourceBlock) in child.blocks.sorted(by: { $0.key < $1.key }) {
            let sourceX = sourceIndex % tileWidth
            let sourceY = sourceIndex / tileWidth
            let quadrantRight = sourceX % 2 != 0
            let quadrantBottom = sourceY % 2 != 0
            let destX = sourceX / 2 + blockXOffset
            let destY = sourceY / 2 + blockYOffset
            let destIndex = destX + destY * tileWidth
            var destination = parent.blocks[destIndex] ?? Data(repeating: 0, count: FogBitmapBlock.byteCount)
            for sourceOffset in 0..<sourceBlock.count {
                let byte = sourceBlock[sourceOffset]
                guard byte != 0 else { continue }
                var nibble: UInt8 = 0
                for pair in 0..<4 {
                    if byte & (0b1100_0000 >> (pair * 2)) != 0 {
                        nibble |= UInt8(1 << (3 - pair))
                    }
                }
                let sourceByteX = sourceOffset % 8
                let sourceYInBlock = sourceOffset / 8
                let destOffset = (quadrantRight ? 4 : 0) + sourceByteX / 2 + 8 * ((quadrantBottom ? 32 : 0) + sourceYInBlock / 2)
                if sourceByteX % 2 == 0 {
                    destination[destOffset] |= nibble << 4
                } else {
                    destination[destOffset] |= nibble
                }
            }
            parent.blocks[destIndex] = destination
        }
    }

    static func pixelCount(_ blocks: [Int: Data]) -> Int {
        blocks.values.reduce(0) { total, data in total + data.reduce(0) { $0 + $1.nonzeroBitCount } }
    }

    static func tileRowAreaSquareMeters(_ y: Int) -> Double {
        let normalizedY = min(y, FogRaster.baseTileCount - 1 - y)
        let latitude: (Double) -> Double = { tileY in
            atan(sinh(.pi * (1 - (2 * tileY) / Double(FogRaster.baseTileCount))))
        }
        let north = latitude(Double(normalizedY))
        let south = latitude(Double(normalizedY + 1))
        return 6_378_137.0 * 6_378_137.0 * (2 * .pi / Double(FogRaster.baseTileCount)) * abs(sin(north) - sin(south))
    }

    static func snapshotMetadata(_ totalAreaSquareMeters: Double) -> Data {
        var data = Data(repeating: 0, count: 4_012)
        var shiftCount = 0
        var area = UInt64(max(0, floor(totalAreaSquareMeters)) * 10_000)
        let threshold: UInt64 = 1 << 44
        while area < threshold && shiftCount < 44 {
            area = min(UInt64.max / 2, area * 2)
            shiftCount += 1
        }
        for byte in 0..<8 { data[5 + byte] = UInt8((area >> UInt64(byte * 8)) & 0xff) }
        let metadata = 17_056 - (shiftCount << 4)
        let encoded = UInt16(metadata)
        data[10] = UInt8(encoded & 0xff)
        data[11] = UInt8(encoded >> 8)
        data[0] = 2
        return data
    }

    static func filename(forTileID tileID: Int) throws -> String {
        guard (0..<512 * 512).contains(tileID) else { throw FogError.invalidTileID }
        let digits = String(tileID).compactMap { Int(String($0)) }
        let idPart = digits.map { String(idMask[$0]) }.joined()
        let checksumPart = digits.map { String(checksumMask[$0]) }.joined()
        let md5 = md5Hex(Data(String(tileID).utf8)).prefix(4)
        return "\(md5)\(idPart)\(String(checksumPart.suffix(2)))"
    }

    private static func decodeTileID(_ name: String) throws -> Int {
        let characters = Array(name)
        guard characters.count >= 6 else { throw FogError.invalidTileName }
        let suffixLength = characters.count == 6 ? 1 : 2
        let idCharacters = characters.dropFirst(4).dropLast(suffixLength)
        var digits = ""
        for character in idCharacters {
            guard let digit = idMask.firstIndex(of: character) else { throw FogError.invalidTileName }
            digits.append(String(digit))
        }
        guard let tileID = Int(digits), (0..<512 * 512).contains(tileID) else { throw FogError.invalidTileID }
        let syncName = try filename(forTileID: tileID)
        let fwssName = try snapshotFilename(x: tileID % FogRaster.baseTileCount, y: tileID / FogRaster.baseTileCount, z: 9, kind: .bitmap)
        guard syncName == name || fwssName == name else { throw FogError.invalidTileName }
        return tileID
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
}

private struct FogSnapshotTile: Sendable, Equatable, Comparable {
    let x: Int
    let y: Int
    let z: Int
    var blocks: [Int: Data]

    var key: String { "\(z):\(y):\(x)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.z == rhs.z ? (lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y) : lhs.z > rhs.z
    }
}

private func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).prefix(2).map { String(format: "%02x", $0) }.joined()
}

private func inflate(_ data: Data, maximumSize: Int) throws -> Data {
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    let source = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer { destination.deallocate(); source.deallocate() }
    var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: source, src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw FogError.invalidArchive }
    defer { compression_stream_destroy(&stream) }
    let bufferSize = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    return try data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw FogError.invalidArchive }
        stream.src_ptr = base
        stream.src_size = data.count
        var output = Data()
        while true {
            stream.dst_ptr = buffer
            stream.dst_size = bufferSize
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = bufferSize - stream.dst_size
            guard output.count + produced <= maximumSize else { throw FogError.outputTooLarge }
            output.append(buffer, count: produced)
            if status == COMPRESSION_STATUS_END { return output }
            if status == COMPRESSION_STATUS_ERROR || (stream.src_size == 0 && produced == 0) { throw FogError.invalidArchive }
        }
    }
}

private func deflate(_ data: Data) throws -> Data {
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    let source = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer { destination.deallocate(); source.deallocate() }
    var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: source, src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw FogError.invalidArchive }
    defer { compression_stream_destroy(&stream) }
    let bufferSize = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    return try data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw FogError.invalidArchive }
        stream.src_ptr = base
        stream.src_size = data.count
        var output = Data()
        while true {
            stream.dst_ptr = buffer
            stream.dst_size = bufferSize
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            output.append(buffer, count: bufferSize - stream.dst_size)
            if status == COMPRESSION_STATUS_END { return output }
            if status == COMPRESSION_STATUS_ERROR { throw FogError.invalidArchive }
        }
    }
}

private func makeStoredZip(files: [(String, Data)]) throws -> Data {
    var output = Data()
    var central = Data()
    for (name, payload) in files {
        let nameData = Data(name.utf8)
        let offset = output.count
        let checksum = crc32(payload)
        output.append(contentsOf: le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(checksum) + le32(UInt32(payload.count)) + le32(UInt32(payload.count)) + le16(UInt16(nameData.count)) + le16(0))
        output.append(nameData); output.append(payload)
        central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(checksum) + le32(UInt32(payload.count)) + le32(UInt32(payload.count)) + le16(UInt16(nameData.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(UInt32(offset)))
        central.append(nameData)
    }
    let centralOffset = output.count
    output.append(central)
    output.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(UInt16(files.count)) + le16(UInt16(files.count)) + le32(UInt32(central.count)) + le32(UInt32(centralOffset)) + le16(0))
    return output
}

private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8)] }
private func le32(_ value: UInt32) -> [UInt8] { le16(UInt16(value & 0xffff)) + le16(UInt16(value >> 16)) }
