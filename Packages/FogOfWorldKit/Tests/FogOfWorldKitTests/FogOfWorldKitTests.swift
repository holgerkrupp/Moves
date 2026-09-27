import Foundation
import Testing
@testable import FogOfWorldKit

@Test func bitmapIsMSBFirst() throws {
    var data = Data(repeating: 0, count: FogBitmapBlock.byteCount)
    data[0] = 0x80
    let block = try FogBitmapBlock(bytes: data)
    #expect(block.contains(x: 0, y: 0))
    #expect(!block.contains(x: 1, y: 0))
}

@Test func syncArchiveRoundTripsOneBlock() async throws {
    var data = Data(repeating: 0, count: FogBitmapBlock.byteCount)
    data[0] = 0x80
    let bitmap = try FogBitmapBlock(bytes: data)
    let archive = try FogArchiveWriter.makeSyncArchive(blocks: [FogBlock(tileID: 0, localX: 0, localY: 0, bitmap: bitmap)])
    let reader = try FogArchiveReader(data: archive)
    #expect(reader.summary == FogArchiveSummary(
        kind: .sync,
        bitmapEntryCount: 1,
        metadataEntryCount: 0,
        hierarchyEntryCount: 0,
        hashEntryCount: 0,
        otherEntryCount: 0
    ))
    let decoded = try await reader.decodeAllBlocks()
    #expect(decoded == [FogBlock(tileID: 0, localX: 0, localY: 0, bitmap: bitmap)])
}

@Test func sparseHeaderPreservesBlockCoordinatesAndTileIdentity() async throws {
    var firstData = Data(repeating: 0, count: FogBitmapBlock.byteCount)
    firstData[0] = 0x80
    var secondData = Data(repeating: 0, count: FogBitmapBlock.byteCount)
    secondData[511] = 0x01
    let first = try FogBitmapBlock(bytes: firstData)
    let second = try FogBitmapBlock(bytes: secondData)
    let input = [
        FogBlock(tileID: 12_345, localX: 0, localY: 0, bitmap: first),
        FogBlock(tileID: 12_345, localX: 127, localY: 127, bitmap: second)
    ]
    let archive = try FogArchiveWriter.makeSyncArchive(blocks: input)
    let decoded = try await FogArchiveReader(data: archive).decodeAllBlocks()
    #expect(decoded == input)
}

@Test func rasterCoordinatesMatchFogWorldProjection() {
    #expect(FogRaster.worldCoordinate(longitude: 0, latitude: 0) == FogWorldCoordinate(x: 2_097_152, y: 2_097_152))
    #expect(FogRaster.worldCoordinate(longitude: 180, latitude: 0) == FogWorldCoordinate(x: 0, y: 2_097_152))
    let munich = FogRaster.worldCoordinate(longitude: 11.5755, latitude: 48.1374)
    #expect(munich == FogWorldCoordinate(x: 2_232_016, y: 1_455_604))
    #expect(FogRaster.blockAddress(for: munich).tileID == 177 * 512 + 272)
}

@Test func fwssArchiveIncludesBitmapHashMetadataAndHierarchy() async throws {
    var data = Data(repeating: 0, count: FogBitmapBlock.byteCount)
    data[0] = 0x80
    let bitmap = try FogBitmapBlock(bytes: data)
    let archive = try FogArchiveWriter.makeFWSSArchive(
        blocks: [FogBlock(tileID: 0, localX: 0, localY: 0, bitmap: bitmap)]
    )
    let reader = try FogArchiveReader(data: archive)
    #expect(reader.summary.kind == .fwss)
    #expect(reader.summary.bitmapEntryCount == 1)
    #expect(reader.summary.hashEntryCount == 1)
    #expect(reader.summary.metadataEntryCount == 2)
    #expect(reader.summary.hierarchyEntryCount == 15)
    #expect(try await reader.decodeAllBlocks() == [FogBlock(tileID: 0, localX: 0, localY: 0, bitmap: bitmap)])
}

@Test func zipPayloadChecksumIsValidated() async throws {
    let bitmap = FogBitmapBlock(repeating: 0x80)
    let archive = try FogArchiveWriter.makeSyncArchive(
        blocks: [FogBlock(tileID: 0, localX: 0, localY: 0, bitmap: bitmap)]
    )
    var corrupt = archive
    let nameLength = Data("Sync/81dclhwjxd".utf8).count
    corrupt[30 + nameLength + 7] ^= 0x01
    do {
        _ = try await FogArchiveReader(data: corrupt).decodeAllBlocks()
        Issue.record("expected a ZIP checksum failure")
    } catch let error as FogError {
        #expect(error == .invalidChecksum)
    }
}
