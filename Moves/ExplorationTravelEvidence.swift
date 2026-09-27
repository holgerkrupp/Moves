import Foundation

enum ExplorationTravelProvenance: String, Codable, CaseIterable, Sendable, Hashable {
    case recorded
    case manual
    case imported
}

enum ExplorationTravelStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case notVisited
    case transit
    case visited
    case lived

    var rank: Int {
        switch self {
        case .notVisited: 0
        case .transit: 1
        case .visited: 2
        case .lived: 3
        }
    }
}

struct ExplorationManualTravelEvidence: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let countryID: String
    let countryName: String
    let status: ExplorationTravelStatus
    let date: Date?
    let note: String?
    let provenance: ExplorationTravelProvenance

    init(
        id: UUID = UUID(),
        countryID: String,
        countryName: String,
        status: ExplorationTravelStatus,
        date: Date? = nil,
        note: String? = nil,
        provenance: ExplorationTravelProvenance = .manual
    ) {
        self.id = id
        self.countryID = countryID
        self.countryName = countryName
        self.status = status
        self.date = date
        self.note = note
        self.provenance = provenance
    }
}

actor ExplorationTravelEvidenceStore {
    private let url: URL

    init(rootURL: URL = ExplorationStorageLocations.rootURL) {
        url = rootURL.appendingPathComponent("v1/travel-evidence.json")
    }

    func load() throws -> [ExplorationManualTravelEvidence] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ExplorationManualTravelEvidence].self, from: Data(contentsOf: url))
    }

    func save(_ records: [ExplorationManualTravelEvidence]) throws {
        let normalized = records.sorted {
            if $0.countryID != $1.countryID { return $0.countryID < $1.countryID }
            if $0.date != $1.date { return ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(normalized).write(to: url, options: ExplorationFileStorage.atomicWriteOptions)
    }

    func upsert(_ record: ExplorationManualTravelEvidence) throws {
        var records = try load()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try save(records)
    }

    func remove(id: UUID) throws {
        try save(try load().filter { $0.id != id })
    }

    func removeAll() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
