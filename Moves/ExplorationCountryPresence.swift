import Foundation

/// Compact prepared country presence for day-level navigation. It is derived
/// from dated source shards and never replaces the canonical block cache.
struct ExplorationCountryPresenceEntry: Codable, Equatable, Sendable, Identifiable {
    let dayKey: String
    let date: Date
    let countryCellCounts: [String: Int]
    /// These facts are optional in the first shard format because canonical
    /// bitmap shards do not contain Move/Visit metadata. They are kept in the
    /// index contract so a later preparation revision can add richer facts
    /// without creating a second country-history subsystem.
    let countryMoveCounts: [String: Int]
    let countryVisitCounts: [String: Int]
    let countryDistanceMeters: [String: Double]
    let countryMoveDurations: [String: TimeInterval]
    let countryStatuses: [String: ExplorationTravelStatus]
    let countryProvenance: [String: [ExplorationTravelProvenance]]
    let countryFirstPresence: [String: Date]
    let countryLastPresence: [String: Date]

    var id: String { dayKey }
    var countryIDs: [String] { countryCellCounts.keys.sorted() }

    init(
        dayKey: String,
        date: Date,
        countryCellCounts: [String: Int],
        countryMoveCounts: [String: Int] = [:],
        countryVisitCounts: [String: Int] = [:],
        countryDistanceMeters: [String: Double] = [:],
        countryMoveDurations: [String: TimeInterval] = [:],
        countryStatuses: [String: ExplorationTravelStatus] = [:],
        countryProvenance: [String: [ExplorationTravelProvenance]] = [:],
        countryFirstPresence: [String: Date] = [:],
        countryLastPresence: [String: Date] = [:]
    ) {
        self.dayKey = dayKey
        self.date = date
        self.countryCellCounts = countryCellCounts
        self.countryMoveCounts = countryMoveCounts
        self.countryVisitCounts = countryVisitCounts
        self.countryDistanceMeters = countryDistanceMeters
        self.countryMoveDurations = countryMoveDurations
        self.countryStatuses = countryStatuses
        self.countryProvenance = countryProvenance
        self.countryFirstPresence = countryFirstPresence
        self.countryLastPresence = countryLastPresence
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey, date, countryCellCounts
        case countryMoveCounts, countryVisitCounts, countryDistanceMeters
        case countryMoveDurations, countryStatuses, countryProvenance
        case countryFirstPresence, countryLastPresence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dayKey: try container.decode(String.self, forKey: .dayKey),
            date: try container.decode(Date.self, forKey: .date),
            countryCellCounts: try container.decode([String: Int].self, forKey: .countryCellCounts),
            countryMoveCounts: try container.decodeIfPresent([String: Int].self, forKey: .countryMoveCounts) ?? [:],
            countryVisitCounts: try container.decodeIfPresent([String: Int].self, forKey: .countryVisitCounts) ?? [:],
            countryDistanceMeters: try container.decodeIfPresent([String: Double].self, forKey: .countryDistanceMeters) ?? [:],
            countryMoveDurations: try container.decodeIfPresent([String: TimeInterval].self, forKey: .countryMoveDurations) ?? [:],
            countryStatuses: try container.decodeIfPresent([String: ExplorationTravelStatus].self, forKey: .countryStatuses) ?? [:],
            countryProvenance: try container.decodeIfPresent([String: [ExplorationTravelProvenance]].self, forKey: .countryProvenance) ?? [:],
            countryFirstPresence: try container.decodeIfPresent([String: Date].self, forKey: .countryFirstPresence) ?? [:],
            countryLastPresence: try container.decodeIfPresent([String: Date].self, forKey: .countryLastPresence) ?? [:]
        )
    }
}

struct ExplorationCountryHistorySummary: Codable, Equatable, Sendable, Identifiable {
    let countryID: String
    let matchingDayCount: Int
    let cellCount: Int
    let moveCount: Int
    let visitCount: Int
    let distanceMeters: Double
    let moveDuration: TimeInterval
    let firstPresence: Date?
    let lastPresence: Date?
    let statuses: [ExplorationTravelStatus]
    let provenance: [ExplorationTravelProvenance]

    var id: String { countryID }
}

struct ExplorationCountryPresenceIndex: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let rasterVersion: FogRasterVersion
    let generatedAt: Date
    let includeFlight: Bool
    let entries: [ExplorationCountryPresenceEntry]
}

actor ExplorationCountryPresenceIndexStore {
    private let rootURL: URL
    private let url: URL

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        self.rootURL = rootURL
        url = rootURL.appendingPathComponent("v1/derived/country-presence.json")
    }

    func load() throws -> ExplorationCountryPresenceIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExplorationCountryPresenceIndex.self, from: Data(contentsOf: url))
    }

    func save(_ index: ExplorationCountryPresenceIndex) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: url, options: ExplorationFileStorage.atomicWriteOptions)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Compact country summaries for list/detail screens. This reads the
    /// prepared index only; it never opens Move, Visit, or LocationSample
    /// models and does not enumerate raster cells.
    func countrySummaries() throws -> [ExplorationCountryHistorySummary] {
        guard let index = try load() else { return [] }
        var values = [String: SummaryAccumulator]()
        for entry in index.entries {
            for countryID in entry.countryIDs {
                var value = values[countryID] ?? SummaryAccumulator()
                value.matchingDayCount += 1
                value.cellCount += entry.countryCellCounts[countryID, default: 0]
                value.moveCount += entry.countryMoveCounts[countryID, default: 0]
                value.visitCount += entry.countryVisitCounts[countryID, default: 0]
                value.distanceMeters += entry.countryDistanceMeters[countryID, default: 0]
                value.moveDuration += entry.countryMoveDurations[countryID, default: 0]
                if let date = entry.countryFirstPresence[countryID] {
                    value.firstPresence = min(value.firstPresence ?? date, date)
                } else {
                    value.firstPresence = min(value.firstPresence ?? entry.date, entry.date)
                }
                if let date = entry.countryLastPresence[countryID] {
                    value.lastPresence = max(value.lastPresence ?? date, date)
                } else {
                    value.lastPresence = max(value.lastPresence ?? entry.date, entry.date)
                }
                value.statuses.formUnion([entry.countryStatuses[countryID, default: .visited]])
                value.provenance.formUnion(entry.countryProvenance[countryID, default: [.recorded]])
                values[countryID] = value
            }
        }
        return values.map { countryID, value in
            ExplorationCountryHistorySummary(
                countryID: countryID,
                matchingDayCount: value.matchingDayCount,
                cellCount: value.cellCount,
                moveCount: value.moveCount,
                visitCount: value.visitCount,
                distanceMeters: value.distanceMeters,
                moveDuration: value.moveDuration,
                firstPresence: value.firstPresence,
                lastPresence: value.lastPresence,
                statuses: value.statuses.sorted { $0.rank < $1.rank },
                provenance: value.provenance.sorted { $0.rawValue < $1.rawValue }
            )
        }.sorted { $0.countryID < $1.countryID }
    }

    /// Returns only the prepared day keys for one country in chronological order.
    func dayKeys(for countryID: String) throws -> [String] {
        guard let index = try load() else { return [] }
        return index.entries
            .filter { $0.countryCellCounts[countryID] != nil }
            .sorted { $0.date == $1.date ? $0.dayKey < $1.dayKey : $0.date < $1.date }
            .map(\.dayKey)
    }

    func presence(for countryID: String, dayKey: String) throws -> ExplorationCountryPresenceEntry? {
        guard let index = try load() else { return nil }
        return index.entries.first { $0.dayKey == dayKey && $0.countryCellCounts[countryID] != nil }
    }

    /// Replaces the dated entry contributed by one source shard. Preparation
    /// calls this after an atomic shard/cache replacement, so a revised day
    /// cannot leave stale country presence behind and no complete index scan is
    /// needed for normal incremental work.
    func update(with shard: ExplorationShard, includeFlight: Bool = false) throws {
        guard let date = shard.logicalStart ?? shard.logicalEnd else { return }
        guard let resolver = try? ExplorationCountryResolver.bundled() else { return }

        let dayKey = Self.dayKey(for: date)
        var visibleByBlock = [FogBlockID: FogBitmapBlock]()
        var importedByBlock = [FogBlockID: FogBitmapBlock]()
        for block in shard.blocks {
            var visible = try FogBitmapBlock()
            for layer in block.layers where includeFlight || layer.layer != .flight {
                visible = visible.union(layer.bitmap)
                if layer.layer == .importedFog {
                    importedByBlock[block.id] = layer.bitmap
                }
            }
            visibleByBlock[block.id] = visible
        }

        var counts = [String: Int]()
        var provenance = [String: Set<ExplorationTravelProvenance>]()
        for (blockID, bitmap) in visibleByBlock {
            let imported = importedByBlock[blockID]
            for row in 0..<FogBitmapBlock.width {
                for column in 0..<FogBitmapBlock.width where bitmap.isSet(x: column, y: row) {
                    let cell = FogCell(coordinate: FogRasterCoordinate(
                        x: blockID.x * FogRasterV1.cellsPerBlock + UInt32(column),
                        y: blockID.y * FogRasterV1.cellsPerBlock + UInt32(row)
                    ))
                    guard let country = try resolver.country(for: cell, sampleGrid: 3) else { continue }
                    counts[country.id, default: 0] += 1
                    provenance[country.id, default: []].insert(
                        imported?.isSet(x: column, y: row) == true ? .imported : .recorded
                    )
                }
            }
        }

        let entry = ExplorationCountryPresenceEntry(
            dayKey: dayKey,
            date: date,
            countryCellCounts: counts,
            countryStatuses: counts.mapValues { _ in .visited },
            countryProvenance: provenance.mapValues { $0.sorted { $0.rawValue < $1.rawValue } },
            countryFirstPresence: counts.mapValues { _ in date },
            countryLastPresence: counts.mapValues { _ in date }
        )
        var index = try load() ?? ExplorationCountryPresenceIndex(
            schemaVersion: ExplorationCountryPresenceIndex.schemaVersion,
            rasterVersion: .fogRasterV1,
            generatedAt: .now,
            includeFlight: includeFlight,
            entries: []
        )
        let entries = index.entries.filter { $0.dayKey != dayKey } + (counts.isEmpty ? [] : [entry])
        index = ExplorationCountryPresenceIndex(
            schemaVersion: ExplorationCountryPresenceIndex.schemaVersion,
            rasterVersion: .fogRasterV1,
            generatedAt: .now,
            includeFlight: includeFlight,
            entries: entries.sorted { $0.date == $1.date ? $0.dayKey < $1.dayKey : $0.date < $1.date }
        )
        try save(index)
    }

    /// Builds only from dated source shards. Undated Fog imports intentionally
    /// have no invented day and therefore do not appear in this index.
    func rebuild(includeFlight: Bool = false) async throws -> ExplorationCountryPresenceIndex {
        guard let resolver = try? ExplorationCountryResolver.bundled() else {
            let empty = ExplorationCountryPresenceIndex(
                schemaVersion: ExplorationCountryPresenceIndex.schemaVersion,
                rasterVersion: .fogRasterV1,
                generatedAt: .now,
                includeFlight: includeFlight,
                entries: []
            )
            try save(empty)
            return empty
        }

        let shards = try await ExplorationShardFileStore(rootURL: rootURL).allShards()
        struct DayAccumulator {
            var date: Date
            var counts: [String: Int]
            var provenance: [String: Set<ExplorationTravelProvenance>]
        }
        var byDay = [String: DayAccumulator]()
        for shard in shards where shard.logicalStart != nil || shard.logicalEnd != nil {
            try Task.checkCancellation()
            let date = shard.logicalStart ?? shard.logicalEnd!
            let dayKey = Self.dayKey(for: date)
            var visibleByBlock = [FogBlockID: FogBitmapBlock]()
            for block in shard.blocks {
                var visible = try FogBitmapBlock()
                for layer in block.layers where includeFlight || layer.layer != .flight {
                    visible = visible.union(layer.bitmap)
                }
                visibleByBlock[block.id] = visible
            }

            var accumulator = byDay[dayKey] ?? DayAccumulator(date: date, counts: [:], provenance: [:])
            for (blockID, bitmap) in visibleByBlock {
                let importedBitmap = shard.blocks.first(where: { $0.id == blockID })?.bitmap(for: .importedFog)
                for row in 0..<FogBitmapBlock.width {
                    for column in 0..<FogBitmapBlock.width where bitmap.isSet(x: column, y: row) {
                        let cell = FogCell(coordinate: FogRasterCoordinate(
                            x: blockID.x * FogRasterV1.cellsPerBlock + UInt32(column),
                            y: blockID.y * FogRasterV1.cellsPerBlock + UInt32(row)
                        ))
                        guard let country = try resolver.country(for: cell, sampleGrid: 3) else { continue }
                        accumulator.counts[country.id, default: 0] += 1
                        accumulator.provenance[country.id, default: []].insert(
                            importedBitmap?.isSet(x: column, y: row) == true ? .imported : .recorded
                        )
                    }
                }
            }
            accumulator.date = min(accumulator.date, date)
            byDay[dayKey] = accumulator
        }

        var entries = [ExplorationCountryPresenceEntry]()
        entries.reserveCapacity(byDay.count)
        for (dayKey, value) in byDay {
            entries.append(ExplorationCountryPresenceEntry(
                dayKey: dayKey,
                date: value.date,
                countryCellCounts: value.counts,
                countryStatuses: value.counts.mapValues { _ in .visited },
                countryProvenance: value.provenance.mapValues { $0.sorted { $0.rawValue < $1.rawValue } },
                countryFirstPresence: value.counts.mapValues { _ in value.date },
                countryLastPresence: value.counts.mapValues { _ in value.date }
            ))
        }
        entries.sort { lhs, rhs in
            lhs.date == rhs.date ? lhs.dayKey < rhs.dayKey : lhs.date < rhs.date
        }
        let index = ExplorationCountryPresenceIndex(
            schemaVersion: ExplorationCountryPresenceIndex.schemaVersion,
            rasterVersion: .fogRasterV1,
            generatedAt: .now,
            includeFlight: includeFlight,
            entries: entries
        )
        try save(index)
        return index
    }

    private static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private struct SummaryAccumulator {
        var matchingDayCount = 0
        var cellCount = 0
        var moveCount = 0
        var visitCount = 0
        var distanceMeters = 0.0
        var moveDuration = TimeInterval.zero
        var firstPresence: Date?
        var lastPresence: Date?
        var statuses = Set<ExplorationTravelStatus>()
        var provenance = Set<ExplorationTravelProvenance>()
    }
}
