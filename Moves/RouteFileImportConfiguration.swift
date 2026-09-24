import Foundation

enum RouteFileImportPreferenceKey {
    static let showsMacMenuBarStatus = "Moves.mac.showsImportStatusInMenuBar"
}

enum RouteFileImportMappingMode: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case automatic
    case dedicatedTransport
    case raw

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic map mapping"
        case .dedicatedTransport: "Use dedicated transport mode"
        case .raw: "Import raw data"
        }
    }
}

enum RouteFileExistingDataPolicy: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case keepExistingData
    case skipDate
    case expandAroundExisting
    case overwriteExisting

    var id: String { rawValue }
    var title: String {
        switch self {
        case .keepExistingData: "Keep existing data and prefer imported route"
        case .skipDate: "Skip dates that already contain data"
        case .expandAroundExisting: "Expand around existing time ranges"
        case .overwriteExisting: "Overwrite existing time ranges"
        }
    }
}

enum RouteFileImportFileHandlingMode: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case oneAtATime
    case stageAll

    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneAtATime: "Copy and import one file at a time"
        case .stageAll: "Copy all files before importing"
        }
    }
}

struct RouteFileImportConfiguration: Codable, Hashable, Sendable {
    var mappingMode: RouteFileImportMappingMode = .automatic
    var dedicatedTransportMode: TransportMode = .unknown
    var existingDataPolicy: RouteFileExistingDataPolicy = .keepExistingData
    var fileHandlingMode: RouteFileImportFileHandlingMode = .oneAtATime

    init(
        mappingMode: RouteFileImportMappingMode = .automatic,
        dedicatedTransportMode: TransportMode = .unknown,
        existingDataPolicy: RouteFileExistingDataPolicy = .keepExistingData,
        fileHandlingMode: RouteFileImportFileHandlingMode = .oneAtATime
    ) {
        self.mappingMode = mappingMode
        self.dedicatedTransportMode = dedicatedTransportMode
        self.existingDataPolicy = existingDataPolicy
        self.fileHandlingMode = fileHandlingMode
    }

    private enum CodingKeys: String, CodingKey {
        case mappingMode, dedicatedTransportMode, existingDataPolicy, fileHandlingMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mappingMode = try container.decodeIfPresent(RouteFileImportMappingMode.self, forKey: .mappingMode) ?? .automatic
        dedicatedTransportMode = try container.decodeIfPresent(TransportMode.self, forKey: .dedicatedTransportMode) ?? .unknown
        existingDataPolicy = try container.decodeIfPresent(RouteFileExistingDataPolicy.self, forKey: .existingDataPolicy) ?? .keepExistingData
        fileHandlingMode = try container.decodeIfPresent(RouteFileImportFileHandlingMode.self, forKey: .fileHandlingMode) ?? .oneAtATime
    }
}
