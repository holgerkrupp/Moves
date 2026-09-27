import CoreLocation
import Foundation

/// The only canonical leaf grid used by Exploration.
///
/// These values mirror the base raster used by Fog of World: Web Mercator at z=9,
/// 128 64x64 blocks per base tile. The representation is intentionally independent
/// of SwiftData, MapKit rendering, and any future transport.
enum FogRasterVersion: String, Codable, Sendable {
    case fogRasterV1
}

struct FogRasterCoordinate: Hashable, Codable, Sendable, Comparable {
    let x: UInt32
    let y: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}

struct FogCell: Hashable, Codable, Sendable {
    let coordinate: FogRasterCoordinate
}

struct FogBaseTileID: Hashable, Codable, Sendable, Comparable {
    let x: UInt16
    let y: UInt16

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}

/// A block address in global block coordinates. Global blocks are 0...65535 on
/// each axis, which makes this address stable across Fog and Moves storage.
struct FogBlockID: Hashable, Codable, Sendable, Comparable {
    let x: UInt32
    let y: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }

    var baseTile: FogBaseTileID {
        FogBaseTileID(
            x: UInt16(x / FogRasterV1.blocksPerBaseTile),
            y: UInt16(y / FogRasterV1.blocksPerBaseTile)
        )
    }

    var localBlockX: UInt8 {
        UInt8(x % FogRasterV1.blocksPerBaseTile)
    }

    var localBlockY: UInt8 {
        UInt8(y % FogRasterV1.blocksPerBaseTile)
    }
}

struct FogRasterAddress: Hashable, Sendable {
    let cell: FogCell
    let baseTile: FogBaseTileID
    let block: FogBlockID
    let localCellX: UInt8
    let localCellY: UInt8
}

struct FogCellGeographicBounds: Equatable, Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double
}

/// A Fog-compatible 64x64 bitmap. Rows are stored top-to-bottom and each byte is
/// most-significant-bit first: cell x=0 is bit 7, x=7 is bit 0.
struct FogBitmapBlock: Equatable, Sendable {
    static let width = 64
    static let byteCount = 512

    private(set) var bytes: [UInt8]

    init(bytes: [UInt8] = Array(repeating: 0, count: Self.byteCount)) throws {
        guard bytes.count == Self.byteCount else {
            throw FogRasterError.invalidBitmapLength(bytes.count)
        }
        self.bytes = bytes
    }

    init(data: Data) throws {
        try self.init(bytes: Array(data))
    }

    func isSet(x: Int, y: Int) -> Bool {
        guard (0..<Self.width).contains(x), (0..<Self.width).contains(y) else { return false }
        let byteIndex = y * 8 + x / 8
        return bytes[byteIndex] & (1 << (7 - (x % 8))) != 0
    }

    mutating func set(x: Int, y: Int, _ value: Bool = true) {
        guard (0..<Self.width).contains(x), (0..<Self.width).contains(y) else { return }
        let byteIndex = y * 8 + x / 8
        let mask = UInt8(1 << (7 - (x % 8)))
        if value {
            bytes[byteIndex] |= mask
        } else {
            bytes[byteIndex] &= ~mask
        }
    }

    func data() -> Data {
        Data(bytes)
    }

    func union(_ other: Self) -> Self {
        var result = bytes
        for index in result.indices {
            result[index] |= other.bytes[index]
        }
        return try! Self(bytes: result)
    }

    var isEmpty: Bool {
        bytes.allSatisfy { $0 == 0 }
    }
}

enum FogRasterError: Error, Equatable {
    case invalidCoordinate
    case invalidBitmapLength(Int)
    case invalidBlockCoordinate
}

enum FogRasterV1 {
    static let version = FogRasterVersion.fogRasterV1
    static let baseTileZoom = 9
    static let baseTileCount: UInt32 = 512
    static let blocksPerBaseTile: UInt32 = 128
    static let cellsPerBlock: UInt32 = 64
    static let cellsPerBaseTile: UInt32 = blocksPerBaseTile * cellsPerBlock
    static let globalCellDimension: UInt32 = baseTileCount * cellsPerBaseTile
    static let webMercatorMaximumLatitude = 85.0511287798066
    static let earthRadiusMeters = 6_378_137.0

    static func address(for coordinate: CLLocationCoordinate2D) throws -> FogRasterAddress {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            throw FogRasterError.invalidCoordinate
        }

        let longitude = normalizedLongitude(coordinate.longitude)
        let latitude = min(max(coordinate.latitude, -webMercatorMaximumLatitude), webMercatorMaximumLatitude)
        let x = ((longitude + 180) / 360) * Double(globalCellDimension)
        let latitudeRadians = latitude * .pi / 180
        let y = ((.pi - asinh(tan(latitudeRadians))) / (2 * .pi)) * Double(globalCellDimension)

        let globalX = UInt32(min(max(floor(x), 0), Double(globalCellDimension - 1)))
        let globalY = UInt32(min(max(floor(y), 0), Double(globalCellDimension - 1)))
        let raster = FogRasterCoordinate(x: globalX, y: globalY)
        let cell = FogCell(coordinate: raster)
        let baseTile = FogBaseTileID(
            x: UInt16(globalX / cellsPerBaseTile),
            y: UInt16(globalY / cellsPerBaseTile)
        )
        let block = FogBlockID(x: globalX / cellsPerBlock, y: globalY / cellsPerBlock)
        return FogRasterAddress(
            cell: cell,
            baseTile: baseTile,
            block: block,
            localCellX: UInt8(globalX % cellsPerBlock),
            localCellY: UInt8(globalY % cellsPerBlock)
        )
    }

    static func address(for cell: FogCell) throws -> FogRasterAddress {
        guard cell.coordinate.x < globalCellDimension, cell.coordinate.y < globalCellDimension else {
            throw FogRasterError.invalidBlockCoordinate
        }
        let x = cell.coordinate.x
        let y = cell.coordinate.y
        return FogRasterAddress(
            cell: cell,
            baseTile: FogBaseTileID(x: UInt16(x / cellsPerBaseTile), y: UInt16(y / cellsPerBaseTile)),
            block: FogBlockID(x: x / cellsPerBlock, y: y / cellsPerBlock),
            localCellX: UInt8(x % cellsPerBlock),
            localCellY: UInt8(y % cellsPerBlock)
        )
    }

    static func bitmapBit(for cell: FogCell) throws -> (x: Int, y: Int) {
        let address = try address(for: cell)
        return (Int(address.localCellX), Int(address.localCellY))
    }

    static func geographicBounds(for cell: FogCell) throws -> FogCellGeographicBounds {
        _ = try address(for: cell)
        let x = Double(cell.coordinate.x)
        let y = Double(cell.coordinate.y)
        let dimension = Double(globalCellDimension)
        func latitude(for y: Double) -> Double {
            atan(sinh(.pi - (2 * .pi * y / dimension))) * 180 / .pi
        }
        return FogCellGeographicBounds(
            west: x / dimension * 360 - 180,
            south: latitude(for: y + 1),
            east: (x + 1) / dimension * 360 - 180,
            north: latitude(for: y)
        )
    }

    /// Spherical Earth area of the geographic cell footprint. The canonical
    /// identity remains Web Mercator; this is only for latitude-aware metrics.
    static func areaSquareMeters(for cell: FogCell) throws -> Double {
        _ = try address(for: cell)
        return cellAreaSquareMeters(forGlobalY: cell.coordinate.y)
    }

    static func cellAreaSquareMeters(forGlobalY globalY: UInt32) -> Double {
        let dimension = Double(globalCellDimension)
        let latitude: (Double) -> Double = { y in
            atan(sinh(.pi - (2 * .pi * y / dimension))) * 180 / .pi
        }
        let westToEastRadians = 360.0 / dimension * .pi / 180
        let south = latitude(Double(globalY) + 1) * .pi / 180
        let north = latitude(Double(globalY)) * .pi / 180
        return earthRadiusMeters * earthRadiusMeters * westToEastRadians * (sin(north) - sin(south))
    }

    static func normalizedLongitude(_ longitude: Double) -> Double {
        var result = longitude.truncatingRemainder(dividingBy: 360)
        if result <= -180 { result += 360 }
        if result >= 180 { result -= 360 }
        return result
    }

    /// The same integer line traversal used by the canonical raster boundary. It
    /// operates after coordinate projection, so no second geographic grid is introduced.
    static func cellsAlongLine(from start: FogCell, to end: FogCell) -> [FogCell] {
        var x0 = Int(start.coordinate.x)
        var y0 = Int(start.coordinate.y)
        let x1 = Int(end.coordinate.x)
        let y1 = Int(end.coordinate.y)
        let dx = abs(x1 - x0)
        let sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0)
        let sy = y0 < y1 ? 1 : -1
        var error = dx + dy
        var result: [FogCell] = []
        result.reserveCapacity(max(dx, -dy) + 1)

        while true {
            result.append(FogCell(coordinate: FogRasterCoordinate(x: UInt32(x0), y: UInt32(y0))))
            if x0 == x1 && y0 == y1 { break }
            let twiceError = 2 * error
            if twiceError >= dy {
                error += dy
                x0 += sx
            }
            if twiceError <= dx {
                error += dx
                y0 += sy
            }
        }
        return result
    }
}
