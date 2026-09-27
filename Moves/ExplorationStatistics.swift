import Foundation

struct ExplorationDerivedStatistics: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let rasterVersion: FogRasterVersion
    let generatedAt: Date
    let includeFlight: Bool
    let sourceShardCount: Int
    let canonicalBlockCount: Int
    let baseTileCount: Int
    let layerCellCounts: [ExplorationLayer: Int]
    let standardCellCount: Int
    let standardAreaSquareMeters: Double
    let flightAreaSquareMeters: Double
    let datedSourceCount: Int
    let firstEvidenceDate: Date?
    let lastEvidenceDate: Date?
    /// Country coverage is a derived convenience index. Empty dictionaries are
    /// valid when the bundled boundary dataset is unavailable or is being
    /// migrated; the canonical raster remains usable in that case.
    let countryCellCounts: [String: Int]
    let countryNames: [String: String]
    let countryAreaSquareMeters: [String: Double]
    let countryFirstEvidenceDates: [String: Date]
    let countryLastEvidenceDates: [String: Date]
    let regionCellCounts: [String: Int]
    let regionNames: [String: String]
    let regionCountryIDs: [String: String]
    let countryTravelStatuses: [String: ExplorationTravelStatus]
    let countryProvenance: [String: [ExplorationTravelProvenance]]
    let manualTravelEvidenceCount: Int
    let countryContinents: [String: ExplorationContinent]
    let continentCellCounts: [ExplorationContinent: Int]
    let continentAreaSquareMeters: [ExplorationContinent: Double]
    /// Counts are based on canonical raster evidence, not manual travel rows.
    let unMemberCountryCount: Int
    let broaderCountryTerritoryCount: Int
    /// Historical dates for achievements that can be established from dated
    /// source shards. Undated Fog evidence intentionally contributes no date.
    let achievementUnlockDates: [String: Date]

    init(
        schemaVersion: Int,
        rasterVersion: FogRasterVersion,
        generatedAt: Date,
        includeFlight: Bool,
        sourceShardCount: Int,
        canonicalBlockCount: Int,
        baseTileCount: Int,
        layerCellCounts: [ExplorationLayer: Int],
        standardCellCount: Int,
        standardAreaSquareMeters: Double,
        flightAreaSquareMeters: Double,
        datedSourceCount: Int,
        firstEvidenceDate: Date?,
        lastEvidenceDate: Date?,
        countryCellCounts: [String: Int] = [:],
        countryNames: [String: String] = [:],
        countryAreaSquareMeters: [String: Double] = [:],
        countryFirstEvidenceDates: [String: Date] = [:],
        countryLastEvidenceDates: [String: Date] = [:],
        regionCellCounts: [String: Int] = [:],
        regionNames: [String: String] = [:],
        regionCountryIDs: [String: String] = [:],
        countryTravelStatuses: [String: ExplorationTravelStatus] = [:],
        countryProvenance: [String: [ExplorationTravelProvenance]] = [:],
        manualTravelEvidenceCount: Int = 0,
        countryContinents: [String: ExplorationContinent] = [:],
        continentCellCounts: [ExplorationContinent: Int] = [:],
        continentAreaSquareMeters: [ExplorationContinent: Double] = [:],
        unMemberCountryCount: Int = 0,
        broaderCountryTerritoryCount: Int = 0,
        achievementUnlockDates: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.rasterVersion = rasterVersion
        self.generatedAt = generatedAt
        self.includeFlight = includeFlight
        self.sourceShardCount = sourceShardCount
        self.canonicalBlockCount = canonicalBlockCount
        self.baseTileCount = baseTileCount
        self.layerCellCounts = layerCellCounts
        self.standardCellCount = standardCellCount
        self.standardAreaSquareMeters = standardAreaSquareMeters
        self.flightAreaSquareMeters = flightAreaSquareMeters
        self.datedSourceCount = datedSourceCount
        self.firstEvidenceDate = firstEvidenceDate
        self.lastEvidenceDate = lastEvidenceDate
        self.countryCellCounts = countryCellCounts
        self.countryNames = countryNames
        self.countryAreaSquareMeters = countryAreaSquareMeters
        self.countryFirstEvidenceDates = countryFirstEvidenceDates
        self.countryLastEvidenceDates = countryLastEvidenceDates
        self.regionCellCounts = regionCellCounts
        self.regionNames = regionNames
        self.regionCountryIDs = regionCountryIDs
        self.countryTravelStatuses = countryTravelStatuses
        self.countryProvenance = countryProvenance
        self.manualTravelEvidenceCount = manualTravelEvidenceCount
        self.countryContinents = countryContinents
        self.continentCellCounts = continentCellCounts
        self.continentAreaSquareMeters = continentAreaSquareMeters
        self.unMemberCountryCount = unMemberCountryCount
        self.broaderCountryTerritoryCount = broaderCountryTerritoryCount
        self.achievementUnlockDates = achievementUnlockDates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rasterVersion, generatedAt, includeFlight
        case sourceShardCount, canonicalBlockCount, baseTileCount
        case layerCellCounts, standardCellCount, standardAreaSquareMeters
        case flightAreaSquareMeters, datedSourceCount, firstEvidenceDate, lastEvidenceDate
        case countryCellCounts, countryNames, countryAreaSquareMeters
        case countryFirstEvidenceDates, countryLastEvidenceDates
        case regionCellCounts, regionNames, regionCountryIDs
        case countryTravelStatuses, countryProvenance, manualTravelEvidenceCount
        case countryContinents, continentCellCounts, continentAreaSquareMeters
        case unMemberCountryCount, broaderCountryTerritoryCount, achievementUnlockDates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        rasterVersion = try container.decode(FogRasterVersion.self, forKey: .rasterVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        includeFlight = try container.decode(Bool.self, forKey: .includeFlight)
        sourceShardCount = try container.decode(Int.self, forKey: .sourceShardCount)
        canonicalBlockCount = try container.decode(Int.self, forKey: .canonicalBlockCount)
        baseTileCount = try container.decode(Int.self, forKey: .baseTileCount)
        layerCellCounts = try container.decode([ExplorationLayer: Int].self, forKey: .layerCellCounts)
        standardCellCount = try container.decode(Int.self, forKey: .standardCellCount)
        standardAreaSquareMeters = try container.decode(Double.self, forKey: .standardAreaSquareMeters)
        flightAreaSquareMeters = try container.decode(Double.self, forKey: .flightAreaSquareMeters)
        datedSourceCount = try container.decode(Int.self, forKey: .datedSourceCount)
        firstEvidenceDate = try container.decodeIfPresent(Date.self, forKey: .firstEvidenceDate)
        lastEvidenceDate = try container.decodeIfPresent(Date.self, forKey: .lastEvidenceDate)
        countryCellCounts = try container.decodeIfPresent([String: Int].self, forKey: .countryCellCounts) ?? [:]
        countryNames = try container.decodeIfPresent([String: String].self, forKey: .countryNames) ?? [:]
        countryAreaSquareMeters = try container.decodeIfPresent([String: Double].self, forKey: .countryAreaSquareMeters) ?? [:]
        countryFirstEvidenceDates = try container.decodeIfPresent([String: Date].self, forKey: .countryFirstEvidenceDates) ?? [:]
        countryLastEvidenceDates = try container.decodeIfPresent([String: Date].self, forKey: .countryLastEvidenceDates) ?? [:]
        regionCellCounts = try container.decodeIfPresent([String: Int].self, forKey: .regionCellCounts) ?? [:]
        regionNames = try container.decodeIfPresent([String: String].self, forKey: .regionNames) ?? [:]
        regionCountryIDs = try container.decodeIfPresent([String: String].self, forKey: .regionCountryIDs) ?? [:]
        countryTravelStatuses = try container.decodeIfPresent([String: ExplorationTravelStatus].self, forKey: .countryTravelStatuses) ?? [:]
        countryProvenance = try container.decodeIfPresent([String: [ExplorationTravelProvenance]].self, forKey: .countryProvenance) ?? [:]
        manualTravelEvidenceCount = try container.decodeIfPresent(Int.self, forKey: .manualTravelEvidenceCount) ?? 0
        countryContinents = try container.decodeIfPresent([String: ExplorationContinent].self, forKey: .countryContinents) ?? [:]
        continentCellCounts = try container.decodeIfPresent([ExplorationContinent: Int].self, forKey: .continentCellCounts) ?? [:]
        continentAreaSquareMeters = try container.decodeIfPresent([ExplorationContinent: Double].self, forKey: .continentAreaSquareMeters) ?? [:]
        unMemberCountryCount = try container.decodeIfPresent(Int.self, forKey: .unMemberCountryCount) ?? 0
        broaderCountryTerritoryCount = try container.decodeIfPresent(Int.self, forKey: .broaderCountryTerritoryCount) ?? 0
        achievementUnlockDates = try container.decodeIfPresent([String: Date].self, forKey: .achievementUnlockDates) ?? [:]
    }

    var standardAreaSquareKilometers: Double { standardAreaSquareMeters / 1_000_000 }
}

actor ExplorationStatisticsStore {
    private let url: URL

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        url = rootURL.appendingPathComponent("v1/derived/statistics.json")
    }

    func load() throws -> ExplorationDerivedStatistics? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExplorationDerivedStatistics.self, from: Data(contentsOf: url))
    }

    func save(_ snapshot: ExplorationDerivedStatistics) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: ExplorationFileStorage.atomicWriteOptions)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

enum ExplorationStatisticsBuilder {
    static func rebuild(
        rootURL: URL = ExplorationStorageLocations.rootURL,
        includeFlight: Bool = false
    ) async throws -> ExplorationDerivedStatistics {
        let shards = try await ExplorationShardFileStore(rootURL: rootURL).allShards()
        var merged = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()
        var datedSourceCount = 0
        var firstEvidenceDate: Date?
        var lastEvidenceDate: Date?
        for shard in shards {
            try Task.checkCancellation()
            if shard.logicalStart != nil || shard.logicalEnd != nil { datedSourceCount += 1 }
            if let date = shard.logicalStart { firstEvidenceDate = min(firstEvidenceDate ?? date, date) }
            if let date = shard.logicalEnd { lastEvidenceDate = max(lastEvidenceDate ?? date, date) }
            for block in shard.blocks {
                for layer in block.layers {
                    if let current = merged[block.id]?[layer.layer] {
                        merged[block.id]?[layer.layer] = current.union(layer.bitmap)
                    } else {
                        merged[block.id, default: [:]][layer.layer] = layer.bitmap
                    }
                }
            }
        }

        var layerCellCounts = [ExplorationLayer: Int]()
        var standardCellCount = 0
        var standardArea = 0.0
        var flightArea = 0.0
        for (id, layers) in merged {
            for (layer, bitmap) in layers {
                for byte in bitmap.bytes { layerCellCounts[layer, default: 0] += byte.nonzeroBitCount }
            }
            for row in 0..<FogBitmapBlock.width {
                let globalY = id.y * FogRasterV1.cellsPerBlock + UInt32(row)
                let area = FogRasterV1.cellAreaSquareMeters(forGlobalY: globalY)
                var standardRow = 0
                var flightRow = 0
                for column in 0..<8 {
                    let byteIndex = row * 8 + column
                    var standardByte: UInt8 = 0
                    for layer in layers where includeFlight || layer.key != .flight {
                        standardByte |= layer.value.bytes[byteIndex]
                    }
                    standardRow += standardByte.nonzeroBitCount
                    if let flight = layers[.flight] { flightRow += flight.bytes[byteIndex].nonzeroBitCount }
                }
                standardCellCount += standardRow
                standardArea += Double(standardRow) * area
                flightArea += Double(flightRow) * area
            }
        }

        var countryCellCounts = [String: Int]()
        var countryNames = [String: String]()
        var countryAreaSquareMeters = [String: Double]()
        var countryFirstEvidenceDates = [String: Date]()
        var countryLastEvidenceDates = [String: Date]()
        var regionCellCounts = [String: Int]()
        var regionNames = [String: String]()
        var regionCountryIDs = [String: String]()
        var countryProvenance = [String: Set<ExplorationTravelProvenance>]()
        if let resolver = try? ExplorationCountryResolver.bundled() {
            let regionResolver = try? ExplorationAdministrativeRegionResolver.bundled()
            for (id, layers) in merged {
                try Task.checkCancellation()
                var visible = try FogBitmapBlock()
                for (layer, bitmap) in layers where includeFlight || layer != .flight {
                    visible = visible.union(bitmap)
                }
                for row in 0..<FogBitmapBlock.width {
                    for column in 0..<FogBitmapBlock.width where visible.isSet(x: column, y: row) {
                        let cell = FogCell(coordinate: FogRasterCoordinate(
                            x: id.x * FogRasterV1.cellsPerBlock + UInt32(column),
                            y: id.y * FogRasterV1.cellsPerBlock + UInt32(row)
                        ))
                        guard let country = try resolver.country(for: cell, sampleGrid: 3) else { continue }
                        countryCellCounts[country.id, default: 0] += 1
                        countryNames[country.id] = country.name
                        countryAreaSquareMeters[country.id, default: 0] += FogRasterV1.cellAreaSquareMeters(forGlobalY: cell.coordinate.y)
                        if let regionResolver, let region = try? regionResolver.region(for: cell, sampleGrid: 3) {
                            regionCellCounts[region.id, default: 0] += 1
                            regionNames[region.id] = region.name
                            regionCountryIDs[region.id] = region.countryID
                        }
                        for (layer, bitmap) in layers where layer != .flight && bitmap.isSet(x: column, y: row) {
                            countryProvenance[country.id, default: []].insert(layer == .importedFog ? .imported : .recorded)
                        }
                    }
                }
            }
        }

        // Dates belong to source evidence, not to the merged cache. Attribute
        // only dated shards here so a replaced/deleted source cannot leave a
        // stale country date behind.
        if let resolver = try? ExplorationCountryResolver.bundled() {
            for shard in shards {
                guard shard.logicalStart != nil || shard.logicalEnd != nil else { continue }
                var shardBlocks = [FogBlockID: FogBitmapBlock]()
                for block in shard.blocks {
                    var visible = try! FogBitmapBlock()
                    for layer in block.layers where (includeFlight || layer.layer != .flight) {
                        visible = visible.union(layer.bitmap)
                    }
                    shardBlocks[block.id] = visible
                }
                for (id, visible) in shardBlocks {
                    for row in 0..<FogBitmapBlock.width {
                        for column in 0..<FogBitmapBlock.width where visible.isSet(x: column, y: row) {
                            let cell = FogCell(coordinate: FogRasterCoordinate(
                                x: id.x * FogRasterV1.cellsPerBlock + UInt32(column),
                                y: id.y * FogRasterV1.cellsPerBlock + UInt32(row)
                            ))
                            guard let country = try resolver.country(for: cell, sampleGrid: 3) else { continue }
                            if let date = shard.logicalStart {
                                countryFirstEvidenceDates[country.id] = min(countryFirstEvidenceDates[country.id] ?? date, date)
                            }
                            if let date = shard.logicalEnd {
                                countryLastEvidenceDates[country.id] = max(countryLastEvidenceDates[country.id] ?? date, date)
                            }
                        }
                    }
                }
            }
        }

        let manualEvidence = try await ExplorationTravelEvidenceStore(rootURL: rootURL).load()
        var countryTravelStatuses = [String: ExplorationTravelStatus]()
        for (countryID, provenance) in countryProvenance where provenance.contains(.recorded) {
            countryTravelStatuses[countryID] = .visited
        }
        for record in manualEvidence {
            countryNames[record.countryID] = record.countryName
            countryProvenance[record.countryID, default: []].insert(record.provenance)
            if let date = record.date {
                countryFirstEvidenceDates[record.countryID] = min(countryFirstEvidenceDates[record.countryID] ?? date, date)
                countryLastEvidenceDates[record.countryID] = max(countryLastEvidenceDates[record.countryID] ?? date, date)
            }
            if let existing = countryTravelStatuses[record.countryID], existing.rank >= record.status.rank {
                continue
            }
            countryTravelStatuses[record.countryID] = record.status
        }

        var countryContinents = [String: ExplorationContinent]()
        var continentCellCounts = [ExplorationContinent: Int]()
        var continentAreaSquareMeters = [ExplorationContinent: Double]()
        for countryID in countryCellCounts.keys {
            let continent = ExplorationGeopoliticalPolicy.continent(for: countryID)
            countryContinents[countryID] = continent
            continentCellCounts[continent, default: 0] += countryCellCounts[countryID, default: 0]
            continentAreaSquareMeters[continent, default: 0] += countryAreaSquareMeters[countryID, default: 0]
        }

        let unMemberCountryCount = countryCellCounts.keys.count(where: {
            ExplorationGeopoliticalPolicy.isUNMember(countryID: $0)
        })
        let broaderCountryTerritoryCount = countryCellCounts.keys.count(where: {
            ExplorationGeopoliticalPolicy.isBroaderEntity(countryID: $0)
        })

        // Build retroactive achievement dates from dated shards only. This is
        // intentionally separate from the merged snapshot: an undated Fog
        // import may unlock a coverage threshold, but it cannot invent the
        // date on which that threshold was reached.
        var datedStandardBlocks = [FogBlockID: FogBitmapBlock]()
        var datedImportedBlocks = [FogBlockID: FogBitmapBlock]()
        var datedBaseTiles = Set<FogBaseTileID>()
        var datedStandardCount = 0
        var datedImportedCount = 0
        var achievementUnlockDates = [String: Date]()
        let datedShards = shards
            .filter { $0.logicalStart != nil || $0.logicalEnd != nil }
            .sorted { ($0.logicalStart ?? $0.logicalEnd ?? .distantPast) < ($1.logicalStart ?? $1.logicalEnd ?? .distantPast) }
        for shard in datedShards {
            try Task.checkCancellation()
            for block in shard.blocks {
                var standard = datedStandardBlocks[block.id] ?? (try! FogBitmapBlock())
                var imported = datedImportedBlocks[block.id] ?? (try! FogBitmapBlock())
                for layer in block.layers {
                    if layer.layer == .flight { continue }
                    let before = standard
                    standard = standard.union(layer.bitmap)
                    datedStandardCount += standard.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                        - before.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                    if layer.layer == .importedFog {
                        let importedBefore = imported
                        imported = imported.union(layer.bitmap)
                        datedImportedCount += imported.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                            - importedBefore.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                    }
                }
                datedStandardBlocks[block.id] = standard
                datedImportedBlocks[block.id] = imported
                datedBaseTiles.insert(block.id.baseTile)
            }
            guard let date = shard.logicalStart ?? shard.logicalEnd else { continue }
            let values: [(String, Bool)] = [
                (ExplorationAchievement.ID.firstEvidence.rawValue, datedStandardCount >= 1),
                (ExplorationAchievement.ID.tenThousandCells.rawValue, datedStandardCount >= 10_000),
                (ExplorationAchievement.ID.oneHundredThousandCells.rawValue, datedStandardCount >= 100_000),
                (ExplorationAchievement.ID.firstImportedFog.rawValue, datedImportedCount >= 1),
                (ExplorationAchievement.ID.tenBaseTiles.rawValue, datedBaseTiles.count >= 10),
                (ExplorationAchievement.ID.hundredBaseTiles.rawValue, datedBaseTiles.count >= 100)
            ]
            for (id, achieved) in values where achieved && achievementUnlockDates[id] == nil {
                achievementUnlockDates[id] = date
            }
        }

        let snapshot = ExplorationDerivedStatistics(
            schemaVersion: ExplorationDerivedStatistics.schemaVersion,
            rasterVersion: .fogRasterV1,
            generatedAt: .now,
            includeFlight: includeFlight,
            sourceShardCount: shards.count,
            canonicalBlockCount: merged.count,
            baseTileCount: Set(merged.keys.map(\.baseTile)).count,
            layerCellCounts: layerCellCounts,
            standardCellCount: standardCellCount,
            standardAreaSquareMeters: standardArea,
            flightAreaSquareMeters: flightArea,
            datedSourceCount: datedSourceCount,
            firstEvidenceDate: firstEvidenceDate,
            lastEvidenceDate: lastEvidenceDate,
            countryCellCounts: countryCellCounts,
            countryNames: countryNames,
            countryAreaSquareMeters: countryAreaSquareMeters,
            countryFirstEvidenceDates: countryFirstEvidenceDates,
            countryLastEvidenceDates: countryLastEvidenceDates,
            regionCellCounts: regionCellCounts,
            regionNames: regionNames,
            regionCountryIDs: regionCountryIDs,
            countryTravelStatuses: countryTravelStatuses,
            countryProvenance: countryProvenance.mapValues { $0.sorted { $0.rawValue < $1.rawValue } },
            manualTravelEvidenceCount: manualEvidence.count,
            countryContinents: countryContinents,
            continentCellCounts: continentCellCounts,
            continentAreaSquareMeters: continentAreaSquareMeters,
            unMemberCountryCount: unMemberCountryCount,
            broaderCountryTerritoryCount: broaderCountryTerritoryCount,
            achievementUnlockDates: achievementUnlockDates
        )
        try await ExplorationStatisticsStore(rootURL: rootURL).save(snapshot)
        _ = try? await ExplorationCountryPresenceIndexStore(rootURL: rootURL).rebuild(includeFlight: includeFlight)
        _ = try? await ExplorationAchievementStore(rootURL: rootURL).refresh(from: snapshot)
        return snapshot
    }
}
