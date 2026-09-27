#if DEBUG
import Compression
import CryptoKit
import Foundation
import FogOfWorldKit

struct FogDebugImportResult: Sendable {
    let archiveKind: String
    let sourceID: String
    let tileCount: Int
    let blockCount: Int
    let revealedCellCount: Int
}

struct FogDebugExportResult: Sendable {
    let data: Data
    let tileCount: Int
    let blockCount: Int
}

private struct FogImportCheckpoint: Codable, Sendable {
    let schemaVersion: Int
    let sourceID: String
    var completedTileIDs: [Int]
    var updatedAt: Date

    init(sourceID: String, completedTileIDs: [Int] = [], updatedAt: Date = .now) {
        schemaVersion = 1
        self.sourceID = sourceID
        self.completedTileIDs = completedTileIDs.sorted()
        self.updatedAt = updatedAt
    }
}

enum FogDebugImportError: LocalizedError, Equatable {
    case unsupportedArchive
    case invalidArchive
    case invalidArchivePath
    case invalidTileFilename
    case invalidTileID
    case invalidTilePayload
    case invalidBlockChecksum
    case unsupportedCompression
    case inflatedDataTooLarge
    case noBitmapTiles

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive:
            "The selected file is not a supported Fog of the World snapshot or sync archive."
        case .invalidArchive:
            "The Fog archive is malformed or could not be read."
        case .invalidArchivePath:
            "The Fog archive contains an unsafe path."
        case .invalidTileFilename:
            "The Fog archive contains an unrecognized tile filename."
        case .invalidTileID:
            "The Fog archive contains a tile outside the Fog world grid."
        case .invalidTilePayload:
            "The Fog archive contains a malformed tile payload."
        case .invalidBlockChecksum:
            "The Fog archive contains a bitmap block with an invalid popcount checksum."
        case .unsupportedCompression:
            "The Fog archive uses an unsupported compression method."
        case .inflatedDataTooLarge:
            "The Fog archive contains an entry that is too large to import safely."
        case .noBitmapTiles:
            "No Fog bitmap tiles were found in the selected archive."
        }
    }
}

/// DEBUG-only adapter from FogOfWorldKit's native blocks to Moves source shards.
enum FogOfWorldDebugImporter {
    private static let tileWidth = 128
    private static let tileHeaderSize = tileWidth * tileWidth * 2
    private static let bitmapBlockSize = FogBitmapBlock.byteCount
    private static let blockExtraSize = 3
    private static let nativeBlockSize = bitmapBlockSize + blockExtraSize
    private static let maximumInflatedTileSize = 32 * 1024 * 1024
    private static let batchSize = 16

    static func importArchive(
        at url: URL,
        rootURL: URL = ExplorationStorageLocations.rootURL
    ) async throws -> FogDebugImportResult {
        let archiveData = try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
        try Task.checkCancellation()

        let sourceDigest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        let reader = try FogArchiveReader(data: archiveData)
        let sourcePrefix = "fog:\(sourceDigest)"
        let shardStore = ExplorationShardFileStore(rootURL: rootURL)
        let cache = ExplorationMergedCache(rootURL: rootURL, shardStore: shardStore)
        let checkpointURL = rootURL.appendingPathComponent("v1/imports/\(sourceDigest).json")
        var checkpoint = try loadCheckpoint(at: checkpointURL) ?? FogImportCheckpoint(sourceID: sourcePrefix)
        var completedTileIDs = Set(checkpoint.completedTileIDs)
        func persistCheckpoint() throws {
            checkpoint.completedTileIDs = completedTileIDs.sorted()
            checkpoint.updatedAt = .now
            let directory = checkpointURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(checkpoint)
            try data.write(to: checkpointURL, options: ExplorationFileStorage.atomicWriteOptions)
        }

        var batch: [ExplorationShard] = []
        batch.reserveCapacity(batchSize)
        var batchTileIDs = [Int]()
        var tileCount = 0
        var seenTileCount = 0
        var blockCount = 0
        var revealedCellCount = 0

        var currentTileID: Int?
        var currentTileBlocks: [ExplorationShardBlock] = []
        var skipCurrentTile = false
        func flushTile() async throws {
            guard let currentTileID, !currentTileBlocks.isEmpty else { return }
            if completedTileIDs.contains(currentTileID) || skipCurrentTile {
                completedTileIDs.insert(currentTileID)
                try persistCheckpoint()
                currentTileBlocks.removeAll(keepingCapacity: true)
                return
            }
            batch.append(ExplorationShard(sourceID: "\(sourcePrefix):tile:\(currentTileID)", revision: 1, blocks: currentTileBlocks))
            batchTileIDs.append(currentTileID)
            currentTileBlocks.removeAll(keepingCapacity: true)
            if batch.count == batchSize {
                try await cache.replaceShards(batch)
                completedTileIDs.formUnion(batchTileIDs)
                try persistCheckpoint()
                batch.removeAll(keepingCapacity: true)
                batchTileIDs.removeAll(keepingCapacity: true)
            }
        }

        for try await nativeBlock in try reader.blocks() {
            try Task.checkCancellation()
            if currentTileID != nativeBlock.tileID {
                try await flushTile()
                currentTileID = nativeBlock.tileID
                seenTileCount += 1
                let existingSourceID = "\(sourcePrefix):tile:\(nativeBlock.tileID)"
                let alreadyStored = (try? await shardStore.read(sourceID: existingSourceID)) != nil
                skipCurrentTile = completedTileIDs.contains(nativeBlock.tileID) || alreadyStored
                if !skipCurrentTile { tileCount += 1 }
            }
            if skipCurrentTile { continue }
            let bitmap = try FogBitmapBlock(bytes: Array(nativeBlock.bitmap.bytes))
            currentTileBlocks.append(ExplorationShardBlock(
                id: FogBlockID(
                    x: UInt32((nativeBlock.tileID % 512) * tileWidth + nativeBlock.localX),
                    y: UInt32((nativeBlock.tileID / 512) * tileWidth + nativeBlock.localY)
                ),
                layers: [ExplorationLayerBitmap(layer: .importedFog, bitmap: bitmap)]
            ))
            blockCount += 1
            revealedCellCount += nativeBlock.bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
        }
        try await flushTile()
        if !batch.isEmpty {
            try await cache.replaceShards(batch)
            completedTileIDs.formUnion(batchTileIDs)
            try persistCheckpoint()
        }
        guard seenTileCount > 0 else { throw FogDebugImportError.noBitmapTiles }

        return FogDebugImportResult(
            archiveKind: reader.kind == .sync ? "Fog sync archive" : "Fog FWSS archive",
            sourceID: sourcePrefix,
            tileCount: tileCount,
            blockCount: blockCount,
            revealedCellCount: revealedCellCount
        )
    }

    private static func loadCheckpoint(at url: URL) throws -> FogImportCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let checkpoint = try JSONDecoder().decode(FogImportCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.schemaVersion == 1 else { return nil }
        return checkpoint
    }

    static func exportSyncArchive(
        rootURL: URL = ExplorationStorageLocations.rootURL,
        includeFlights: Bool = false
    ) async throws -> FogDebugExportResult {
        let (nativeBlocks, blockCount) = try await exportableNativeBlocks(rootURL: rootURL, includeFlights: includeFlights)
        return FogDebugExportResult(
            data: try FogArchiveWriter.makeSyncArchive(blocks: nativeBlocks),
            tileCount: Set(nativeBlocks.map(\.tileID)).count,
            blockCount: blockCount
        )
    }

    static func exportFWSSArchive(
        rootURL: URL = ExplorationStorageLocations.rootURL,
        includeFlights: Bool = false
    ) async throws -> FogDebugExportResult {
        let (nativeBlocks, blockCount) = try await exportableNativeBlocks(rootURL: rootURL, includeFlights: includeFlights)
        return FogDebugExportResult(
            data: try FogArchiveWriter.makeFWSSArchive(blocks: nativeBlocks),
            tileCount: Set(nativeBlocks.map(\.tileID)).count,
            blockCount: blockCount
        )
    }

    private static func exportableNativeBlocks(
        rootURL: URL,
        includeFlights: Bool
    ) async throws -> (blocks: [FogBlock], blockCount: Int) {
        let shardStore = ExplorationShardFileStore(rootURL: rootURL)
        let shards = try await shardStore.allShards()
        var mergedBlocks = [FogBlockID: FogBitmapBlock]()

        for shard in shards {
            try Task.checkCancellation()
            for block in shard.blocks {
                for layer in block.layers {
                    if layer.layer == .flight && !includeFlights { continue }
                    guard layer.layer != .flight || includeFlights else { continue }
                    if let current = mergedBlocks[block.id] {
                        mergedBlocks[block.id] = current.union(layer.bitmap)
                    } else {
                        mergedBlocks[block.id] = layer.bitmap
                    }
                }
            }
        }

        var nativeBlocks: [FogBlock] = []
        nativeBlocks.reserveCapacity(mergedBlocks.count)
        for (id, bitmap) in mergedBlocks {
            let tileX = Int(id.x / FogRasterV1.blocksPerBaseTile)
            let tileY = Int(id.y / FogRasterV1.blocksPerBaseTile)
            let tileID = tileY * 512 + tileX
            let localX = Int(id.x % FogRasterV1.blocksPerBaseTile)
            let localY = Int(id.y % FogRasterV1.blocksPerBaseTile)
            nativeBlocks.append(FogBlock(
                tileID: tileID,
                localX: localX,
                localY: localY,
                bitmap: try FogOfWorldKit.FogBitmapBlock(bytes: Data(bitmap.bytes))
            ))
        }
        guard !nativeBlocks.isEmpty else { throw FogDebugImportError.noBitmapTiles }
        return (nativeBlocks, mergedBlocks.count)
    }

    fileprivate static func inflate(_ data: Data, maximumSize: Int) throws -> Data {
        let emptyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let emptySource = UnsafePointer<UInt8>(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
        defer {
            emptyDestination.deallocate()
            emptySource.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: emptyDestination,
            dst_size: 0,
            src_ptr: emptySource,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw FogDebugImportError.invalidTilePayload
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        return try data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw FogDebugImportError.invalidTilePayload
            }
            stream.src_ptr = source
            stream.src_size = data.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                guard output.count + produced <= maximumSize else {
                    throw FogDebugImportError.inflatedDataTooLarge
                }
                output.append(buffer, count: produced)
                try Task.checkCancellation()
                if status == COMPRESSION_STATUS_END { return output }
                if status == COMPRESSION_STATUS_ERROR ||
                    (stream.src_size == 0 && produced == 0) {
                    throw FogDebugImportError.invalidTilePayload
                }
            }
        }
    }

    private static func deflate(_ data: Data) throws -> Data {
        let emptyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let emptySource = UnsafePointer<UInt8>(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
        defer {
            emptyDestination.deallocate()
            emptySource.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: emptyDestination,
            dst_size: 0,
            src_ptr: emptySource,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw FogDebugImportError.invalidTilePayload
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        return try data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw FogDebugImportError.invalidTilePayload
            }
            stream.src_ptr = source
            stream.src_size = data.count
            var output = Data()
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: bufferSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { return output }
                if status == COMPRESSION_STATUS_ERROR {
                    throw FogDebugImportError.invalidTilePayload
                }
            }
        }
    }

    private static func encodeNativeTile(blocks: [Int: FogBitmapBlock]) throws -> Data {
        var data = Data(repeating: 0, count: tileHeaderSize)
        let sortedBlocks = blocks.sorted(by: { $0.key < $1.key })
        for (rank, item) in sortedBlocks.enumerated() {
            let index = item.key
            guard index >= 0, index < tileWidth * tileWidth else {
                throw FogDebugImportError.invalidTilePayload
            }
            appendUInt16LE(UInt16(rank + 1), to: &data, at: index * 2)
        }

        for bitmap in sortedBlocks.map(\.value) {
            data.append(contentsOf: bitmap.bytes)
            let count = bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            data.append(0)
            data.append(UInt8(((count * 2 + 1) >> 8) & 0xff))
            data.append(UInt8((count * 2 + 1) & 0xff))
        }
        return data
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8(value >> 8)
    }

    private static func makeStoredZip(files: [(String, Data)]) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()
        for (path, contents) in files {
            let name = Data(path.utf8)
            let offset = archive.count
            let checksum = crc32(contents)
            appendUInt32LE(0x04034b50, to: &archive)
            appendUInt16LE(20, to: &archive)
            appendUInt16LE(0, to: &archive)
            appendUInt16LE(0, to: &archive)
            appendUInt16LE(0, to: &archive)
            appendUInt16LE(0, to: &archive)
            appendUInt32LE(checksum, to: &archive)
            appendUInt32LE(UInt32(contents.count), to: &archive)
            appendUInt32LE(UInt32(contents.count), to: &archive)
            appendUInt16LE(UInt16(name.count), to: &archive)
            appendUInt16LE(0, to: &archive)
            archive.append(name)
            archive.append(contents)

            appendUInt32LE(0x02014b50, to: &centralDirectory)
            appendUInt16LE(20, to: &centralDirectory)
            appendUInt16LE(20, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt32LE(checksum, to: &centralDirectory)
            appendUInt32LE(UInt32(contents.count), to: &centralDirectory)
            appendUInt32LE(UInt32(contents.count), to: &centralDirectory)
            appendUInt16LE(UInt16(name.count), to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory)
            appendUInt32LE(0, to: &centralDirectory)
            appendUInt32LE(UInt32(offset), to: &centralDirectory)
            centralDirectory.append(name)
        }
        let centralOffset = archive.count
        archive.append(centralDirectory)
        appendUInt32LE(0x06054b50, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt16LE(0, to: &archive)
        appendUInt16LE(UInt16(files.count), to: &archive)
        appendUInt16LE(UInt16(files.count), to: &archive)
        appendUInt32LE(UInt32(centralDirectory.count), to: &archive)
        appendUInt32LE(UInt32(centralOffset), to: &archive)
        appendUInt16LE(0, to: &archive)
        return archive
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8(value >> 24))
    }

    private static func crc32(_ data: Data) -> UInt32 {
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
}

struct FogDecodedBlock: Sendable {
    let localX: Int
    let localY: Int
    let bitmap: FogBitmapBlock
    let revealedCellCount: Int
}

struct FogDecodedTile: Sendable {
    let tileID: Int
    let tileX: Int
    let tileY: Int
    let blocks: [FogDecodedBlock]
}

enum FogNativeTileDecoder {
    private static let tileWidth = 128
    private static let tileHeaderSize = tileWidth * tileWidth * 2
    private static let nativeBlockSize = FogBitmapBlock.byteCount + 3

    /// Decodes the inflated native Fog bitmap tile payload. Kept internal so
    /// privacy-safe synthetic payload tests can validate tile/block alignment.
    static func decodeInflated(filename: String, data: Data) throws -> FogDecodedTile {
        let tileID = try decodeTileID(filename)
        guard data.count >= tileHeaderSize else { throw FogDebugImportError.invalidTilePayload }

        let tileX = tileID % 512
        let tileY = tileID / 512
        var blocks: [FogDecodedBlock] = []
        for index in 0..<(tileWidth * tileWidth) {
            let blockIndex = readUInt16LE(data, at: index * 2)
            guard blockIndex != 0 else { continue }
            let offset = tileHeaderSize + (Int(blockIndex) - 1) * nativeBlockSize
            guard offset >= tileHeaderSize, offset + nativeBlockSize <= data.count else {
                throw FogDebugImportError.invalidTilePayload
            }

            let bitmapData = Data(data[offset..<(offset + FogBitmapBlock.byteCount)])
            let bitmap = try FogBitmapBlock(data: bitmapData)
            let extraOffset = offset + FogBitmapBlock.byteCount
            let storedScore = UInt16(data[extraOffset + 1]) << 8 | UInt16(data[extraOffset + 2])
            let actualCount = bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            let storedCount = Int(storedScore & 0x3fff) >> 1
            guard storedCount == actualCount || (storedScore == 0 && actualCount == 0) else {
                throw FogDebugImportError.invalidBlockChecksum
            }

            blocks.append(
                FogDecodedBlock(
                    localX: index % tileWidth,
                    localY: index / tileWidth,
                    bitmap: bitmap,
                    revealedCellCount: actualCount
                )
            )
        }
        return FogDecodedTile(tileID: tileID, tileX: tileX, tileY: tileY, blocks: blocks)
    }

    static func filename(forTileID tileID: Int) throws -> String {
        guard (0..<(512 * 512)).contains(tileID) else {
            throw FogDebugImportError.invalidTileID
        }
        let mask = Array("olhwjsktri")
        let checksumMask = Array("eizxdwknmo")
        let digits = String(tileID).compactMap { Int(String($0)) }
        let idPart = digits.map { String(mask[$0]) }.joined()
        let checksumPart = digits.map { String(checksumMask[$0]) }.joined()
        let md5 = Insecure.MD5.hash(data: Data(String(tileID).utf8))
            .prefix(2)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(md5)\(idPart)\(String(checksumPart.suffix(2)))"
    }

    private static func decodeTileID(_ filename: String) throws -> Int {
        let characters = Array(filename)
        guard characters.count >= 6 else { throw FogDebugImportError.invalidTileFilename }
        let suffixLength = characters.count == 6 ? 1 : 2
        let idCharacters = characters.dropFirst(4).dropLast(suffixLength)
        let mask = Array("olhwjsktri")
        var digits = ""
        for character in idCharacters {
            guard let digit = mask.firstIndex(of: character) else {
                throw FogDebugImportError.invalidTileFilename
            }
            digits.append(String(digit))
        }
        guard let tileID = Int(digits), tileID >= 0, tileID < 512 * 512 else {
            throw FogDebugImportError.invalidTileID
        }
        return tileID
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
}

private struct FogZipEntry: Sendable {
    let path: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int

    var basename: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

private struct FogZipSelection: Sendable {
    let kind: String
    let entries: [FogZipEntry]
}

private struct FogZipArchive: Sendable {
    let data: Data
    let entries: [FogZipEntry]

    init(data: Data) throws {
        self.data = data
        guard let endOffset = Self.findEndOfCentralDirectory(in: data) else {
            throw FogDebugImportError.invalidArchive
        }
        let centralDirectorySize = Int(Self.readUInt32LE(data, at: endOffset + 12))
        let centralDirectoryOffset = Int(Self.readUInt32LE(data, at: endOffset + 16))
        let entryCount = Int(Self.readUInt16LE(data, at: endOffset + 10))
        guard centralDirectoryOffset >= 0,
              centralDirectorySize >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw FogDebugImportError.invalidArchive
        }

        var cursor = centralDirectoryOffset
        var parsed: [FogZipEntry] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  Self.readUInt32LE(data, at: cursor) == 0x02014b50 else {
                throw FogDebugImportError.invalidArchive
            }
            let method = Self.readUInt16LE(data, at: cursor + 10)
            let compressedSize = Int(Self.readUInt32LE(data, at: cursor + 20))
            let uncompressedSize = Int(Self.readUInt32LE(data, at: cursor + 24))
            let nameLength = Int(Self.readUInt16LE(data, at: cursor + 28))
            let extraLength = Int(Self.readUInt16LE(data, at: cursor + 30))
            let commentLength = Int(Self.readUInt16LE(data, at: cursor + 32))
            let localHeaderOffset = Int(Self.readUInt32LE(data, at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count,
                  let path = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
                throw FogDebugImportError.invalidArchive
            }
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw FogDebugImportError.invalidArchivePath
            }
            parsed.append(
                FogZipEntry(
                    path: path,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = parsed
    }

    func bitmapEntries() throws -> FogZipSelection {
        let files = entries.filter { !$0.path.hasSuffix("/") && !$0.basename.isEmpty }
        let fwss = files.filter { $0.path.lowercased().contains("model/*/") }
        if !fwss.isEmpty {
            return FogZipSelection(kind: "FWSS snapshot", entries: fwss)
        }
        let sync = files.filter { $0.path.lowercased().contains("sync/") }
        if !sync.isEmpty {
            return FogZipSelection(kind: "Fog sync archive", entries: sync)
        }
        throw FogDebugImportError.unsupportedArchive
    }

    func data(for entry: FogZipEntry) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset >= 0, offset + 30 <= data.count,
              Self.readUInt32LE(data, at: offset) == 0x04034b50 else {
            throw FogDebugImportError.invalidArchive
        }
        let nameLength = Int(Self.readUInt16LE(data, at: offset + 26))
        let extraLength = Int(Self.readUInt16LE(data, at: offset + 28))
        let payloadStart = offset + 30 + nameLength + extraLength
        guard entry.compressedSize >= 0,
              payloadStart >= 0,
              payloadStart + entry.compressedSize <= data.count else {
            throw FogDebugImportError.invalidArchive
        }
        let compressed = Data(data[payloadStart..<(payloadStart + entry.compressedSize)])
        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else { throw FogDebugImportError.invalidArchive }
            return compressed
        case 8:
            return try FogOfWorldDebugImporter.inflate(compressed, maximumSize: 32 * 1024 * 1024)
        default:
            throw FogDebugImportError.unsupportedCompression
        }
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        let minimumSize = 22
        guard data.count >= minimumSize else { return nil }
        let start = max(0, data.count - 65_557)
        for offset in stride(from: data.count - minimumSize, through: start, by: -1) {
            if readUInt32LE(data, at: offset) == 0x06054b50 {
                return offset
            }
        }
        return nil
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
#endif
