import Foundation

struct ExplorationAchievement: Codable, Identifiable, Sendable, Equatable {
    enum ID: String, Codable, CaseIterable, Sendable {
        case firstEvidence
        case tenThousandCells
        case oneHundredThousandCells
        case firstImportedFog
        case tenBaseTiles
        case hundredBaseTiles
    }

    enum Category: String, Codable, CaseIterable, Sendable {
        case coverage
        case interoperability
        case reach
    }

    let id: ID
    let title: String
    let detail: String
    let category: Category
    let progress: Double
    let achieved: Bool
    let unlockedAt: Date?
    let symbolName: String
    let localizationKey: String
    let requiresDatedEvidence: Bool
}

struct ExplorationPassportStamp: Identifiable, Sendable, Equatable {
    let id: String
    let countryID: String
    let countryName: String
    let exploredCellCount: Int
    let exploredAreaSquareMeters: Double
    let evidenceRange: ClosedRange<Date>?
    let status: ExplorationTravelStatus
    let provenance: [ExplorationTravelProvenance]
    let isManualOnly: Bool
    let recipe: ExplorationStampRecipe
}

/// Compact, deterministic instructions for the original procedural passport
/// artwork. The recipe is data, not a rendered asset, so large passports stay
/// cheap and the same stamp remains stable across launches/devices.
struct ExplorationStampRecipe: Codable, Equatable, Sendable {
    enum Shape: String, Codable, Sendable { case circle, oval, ticket, octagon }
    enum Border: String, Codable, Sendable { case solid, double, dashed, segmented }

    let shape: Shape
    let border: Border
    let rotationDegrees: Double
    let inkRed: Double
    let inkGreen: Double
    let inkBlue: Double
    let glyph: String
    let wear: Double
}

private enum ExplorationStampRecipeBuilder {
    static func make(countryID: String, visitIndex: Int, manualOnly: Bool) -> ExplorationStampRecipe {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data("\(countryID)#\(visitIndex)#\(manualOnly ? 1 : 0)".utf8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        func next(_ upperBound: UInt64) -> UInt64 {
            hash = hash &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return hash % upperBound
        }
        let colors: [(Double, Double, Double)] = [
            (0.16, 0.24, 0.48), (0.55, 0.16, 0.18), (0.12, 0.38, 0.31),
            (0.46, 0.28, 0.08), (0.30, 0.20, 0.42)
        ]
        let color = colors[Int(next(UInt64(colors.count)))]
        let shapes: [ExplorationStampRecipe.Shape] = [.circle, .oval, .ticket, .octagon]
        let borders: [ExplorationStampRecipe.Border] = [.solid, .double, .dashed, .segmented]
        let glyphs = ["airplane.departure", "tram.fill", "sailboat.fill", "safari.fill", "star.fill"]
        return ExplorationStampRecipe(
            shape: shapes[Int(next(UInt64(shapes.count)))],
            border: borders[Int(next(UInt64(borders.count)))],
            rotationDegrees: Double(Int(next(11)) - 5),
            inkRed: color.0,
            inkGreen: color.1,
            inkBlue: color.2,
            glyph: glyphs[Int(next(UInt64(glyphs.count)))],
            wear: Double(next(21)) / 100
        )
    }
}

enum ExplorationPassportBuilder {
    static func stamps(_ snapshot: ExplorationDerivedStatistics) -> [ExplorationPassportStamp] {
        stamps(
            countryCellCounts: snapshot.countryCellCounts,
            countryNames: snapshot.countryNames,
            countryAreaSquareMeters: snapshot.countryAreaSquareMeters,
            countryFirstEvidenceDates: snapshot.countryFirstEvidenceDates,
            countryLastEvidenceDates: snapshot.countryLastEvidenceDates,
            countryTravelStatuses: snapshot.countryTravelStatuses,
            countryProvenance: snapshot.countryProvenance,
            firstEvidenceDate: snapshot.firstEvidenceDate,
            lastEvidenceDate: snapshot.lastEvidenceDate
        )
    }

    static func stamps(
        countryCellCounts: [String: Int],
        countryNames: [String: String],
        countryAreaSquareMeters: [String: Double],
        countryFirstEvidenceDates: [String: Date] = [:],
        countryLastEvidenceDates: [String: Date] = [:],
        countryTravelStatuses: [String: ExplorationTravelStatus] = [:],
        countryProvenance: [String: [ExplorationTravelProvenance]] = [:],
        firstEvidenceDate: Date?,
        lastEvidenceDate: Date?
    ) -> [ExplorationPassportStamp] {
        Set(countryCellCounts.keys).union(countryTravelStatuses.keys).sorted().enumerated().compactMap { visitIndex, id in
            guard let name = countryNames[id] else { return nil }
            let range: ClosedRange<Date>?
            if let first = countryFirstEvidenceDates[id] ?? firstEvidenceDate,
               let last = countryLastEvidenceDates[id] ?? lastEvidenceDate {
                range = first...max(first, last)
            } else {
                range = nil
            }
            return ExplorationPassportStamp(
                id: id,
                countryID: id,
                countryName: name,
                exploredCellCount: countryCellCounts[id, default: 0],
                exploredAreaSquareMeters: countryAreaSquareMeters[id, default: 0],
                evidenceRange: range,
                status: countryTravelStatuses[id, default: .notVisited],
                provenance: countryProvenance[id, default: []],
                isManualOnly: countryCellCounts[id] == nil,
                recipe: ExplorationStampRecipeBuilder.make(
                    countryID: id,
                    visitIndex: visitIndex,
                    manualOnly: countryCellCounts[id] == nil
                )
            )
        }
    }
}

enum ExplorationAchievementCatalog {
    private struct Definition: Sendable {
        let id: ExplorationAchievement.ID
        let title: String
        let detail: String
        let category: ExplorationAchievement.Category
        let symbolName: String
        let threshold: Int
        let requiresDatedEvidence: Bool
    }

    private static let definitions: [Definition] = [
        Definition(id: .firstEvidence, title: "First evidence", detail: "Reveal the first canonical cell.", category: .coverage, symbolName: "sparkles", threshold: 1, requiresDatedEvidence: false),
        Definition(id: .tenThousandCells, title: "10,000 cells", detail: "Reveal 10,000 standard cells.", category: .coverage, symbolName: "square.grid.3x3.fill", threshold: 10_000, requiresDatedEvidence: false),
        Definition(id: .oneHundredThousandCells, title: "100,000 cells", detail: "Reveal 100,000 standard cells.", category: .coverage, symbolName: "globe.europe.africa.fill", threshold: 100_000, requiresDatedEvidence: false),
        Definition(id: .firstImportedFog, title: "Fog bridge", detail: "Import the first Fog evidence cell.", category: .interoperability, symbolName: "cloud.fill", threshold: 1, requiresDatedEvidence: false),
        Definition(id: .tenBaseTiles, title: "Ten regions", detail: "Reach ten canonical Fog base tiles.", category: .reach, symbolName: "map.fill", threshold: 10, requiresDatedEvidence: false),
        Definition(id: .hundredBaseTiles, title: "World sampler", detail: "Reach one hundred canonical Fog base tiles.", category: .reach, symbolName: "globe.americas.fill", threshold: 100, requiresDatedEvidence: false)
    ]

    static func evaluate(standardCellCount: Int, importedCellCount: Int, baseTileCount: Int) -> [ExplorationAchievement] {
        definitions.map { definition in
            let value: Int
            switch definition.id {
            case .firstEvidence, .tenThousandCells, .oneHundredThousandCells: value = standardCellCount
            case .firstImportedFog: value = importedCellCount
            case .tenBaseTiles, .hundredBaseTiles: value = baseTileCount
            }
            return achievement(definition, value: value)
        }
    }

    private static func achievement(
        _ definition: Definition,
        value: Int,
        unlockedAt: Date? = nil
    ) -> ExplorationAchievement {
        ExplorationAchievement(
            id: definition.id,
            title: definition.title,
            detail: definition.detail,
            category: definition.category,
            progress: min(max(Double(value) / Double(definition.threshold), 0), 1),
            achieved: value >= definition.threshold,
            unlockedAt: unlockedAt,
            symbolName: definition.symbolName,
            localizationKey: "exploration.achievement.\(definition.id.rawValue)",
            requiresDatedEvidence: definition.requiresDatedEvidence
        )
    }

    static func evaluate(_ snapshot: ExplorationDerivedStatistics) -> [ExplorationAchievement] {
        let evaluated = evaluate(
            standardCellCount: snapshot.standardCellCount,
            importedCellCount: snapshot.layerCellCounts[.importedFog, default: 0],
            baseTileCount: snapshot.baseTileCount
        )
        return evaluated.map { achievement in
            let date = snapshot.achievementUnlockDates[achievement.id.rawValue]
            return ExplorationAchievement(
                id: achievement.id,
                title: achievement.title,
                detail: achievement.detail,
                category: achievement.category,
                progress: achievement.progress,
                achieved: achievement.achieved,
                unlockedAt: date,
                symbolName: achievement.symbolName,
                localizationKey: achievement.localizationKey,
                requiresDatedEvidence: achievement.requiresDatedEvidence
            )
        }
    }
}

struct ExplorationAchievementState: Codable, Equatable, Sendable {
    let generatedAt: Date
    let achievements: [ExplorationAchievement]
}

actor ExplorationAchievementStore {
    private let url: URL

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        url = rootURL.appendingPathComponent("v1/derived/achievements.json")
    }

    func load() throws -> ExplorationAchievementState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExplorationAchievementState.self, from: Data(contentsOf: url))
    }

    func refresh(from snapshot: ExplorationDerivedStatistics) throws -> ExplorationAchievementState {
        let previous = try load()
        let previousDates = Dictionary(uniqueKeysWithValues: (previous?.achievements ?? []).map { ($0.id, $0.unlockedAt) })
        let evaluated = ExplorationAchievementCatalog.evaluate(snapshot).map { achievement in
            let historicalDate: Date?
            if let previousDate = previousDates[achievement.id] ?? nil {
                historicalDate = previousDate
            } else if achievement.achieved, achievement.id == .firstEvidence {
                historicalDate = snapshot.achievementUnlockDates[achievement.id.rawValue] ?? snapshot.firstEvidenceDate
            } else {
                historicalDate = snapshot.achievementUnlockDates[achievement.id.rawValue]
            }
            return ExplorationAchievement(
                id: achievement.id,
                title: achievement.title,
                detail: achievement.detail,
                category: achievement.category,
                progress: achievement.progress,
                achieved: achievement.achieved,
                unlockedAt: historicalDate,
                symbolName: achievement.symbolName,
                localizationKey: achievement.localizationKey,
                requiresDatedEvidence: achievement.requiresDatedEvidence
            )
        }
        let result = ExplorationAchievementState(generatedAt: .now, achievements: evaluated)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: url, options: ExplorationFileStorage.atomicWriteOptions)
        return result
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
