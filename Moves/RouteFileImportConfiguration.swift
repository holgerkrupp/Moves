import Foundation

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
    case skipDate
    case expandAroundExisting
    case overwriteExisting

    var id: String { rawValue }
    var title: String {
        switch self {
        case .skipDate: "Skip dates that already contain data"
        case .expandAroundExisting: "Expand around existing time ranges"
        case .overwriteExisting: "Overwrite existing time ranges"
        }
    }
}

struct RouteFileImportConfiguration: Codable, Hashable, Sendable {
    var mappingMode: RouteFileImportMappingMode = .automatic
    var dedicatedTransportMode: TransportMode = .unknown
    var existingDataPolicy: RouteFileExistingDataPolicy = .skipDate
}
