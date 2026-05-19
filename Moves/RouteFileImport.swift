import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RouteFileImportReport {
    let fileCount: Int
    let routeCount: Int
    let sampleCount: Int
}

@MainActor
final class RouteFileImporter: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressText = ""
    @Published private(set) var lastReport: RouteFileImportReport?
    @Published private(set) var lastErrorMessage: String?

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func importFiles(urls: [URL]) async {
        guard !isImporting else { return }
        let securityScopedURLs = urls.uniqueForImport
        guard !securityScopedURLs.isEmpty else {
            lastErrorMessage = "No files selected."
            return
        }

        isImporting = true
        importProgress = 0
        importProgressText = "Preparing import..."
        defer {
            isImporting = false
            importProgress = nil
            importProgressText = ""
        }

        do {
            let repository = SwiftDataTimelineRepository(modelContext: modelContext)
            var routeCount = 0
            var sampleCount = 0

            for (index, url) in securityScopedURLs.enumerated() {
                importProgressText = "Importing \(index + 1) of \(securityScopedURLs.count): \(url.lastPathComponent)"
                let fileTracks = try loadTracks(from: url)
                for track in fileTracks where track.locations.count >= 2 {
                    _ = try repository.importRouteTrack(
                        locations: track.locations,
                        source: .fileRouteImport,
                        transportMode: track.transportMode
                    )
                    routeCount += 1
                    sampleCount += track.locations.count
                }

                importProgress = Double(index + 1) / Double(securityScopedURLs.count)
            }

            try repository.saveIfNeeded()
            lastReport = RouteFileImportReport(
                fileCount: securityScopedURLs.count,
                routeCount: routeCount,
                sampleCount: sampleCount
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func loadTracks(from url: URL) throws -> [ImportedRouteTrack] {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let lowercasedName = url.lastPathComponent.lowercased()
        if lowercasedName.hasSuffix(".gpx") || lowercasedName.hasSuffix(".tcx") || lowercasedName.hasSuffix(".kml") {
            return try XMLRouteTrackParser.parse(data: data, fileName: url.lastPathComponent)
        }

        if lowercasedName.hasSuffix(".geojson") || lowercasedName.hasSuffix(".json") {
            return try GeoJSONRouteTrackParser.parse(data: data, fileName: url.lastPathComponent)
        }

        // Last resort: try XML first, then GeoJSON.
        if let xmlTracks = try? XMLRouteTrackParser.parse(data: data, fileName: url.lastPathComponent),
           !xmlTracks.isEmpty {
            return xmlTracks
        }
        if let geoJSONTracks = try? GeoJSONRouteTrackParser.parse(data: data, fileName: url.lastPathComponent),
           !geoJSONTracks.isEmpty {
            return geoJSONTracks
        }

        throw NSError(
            domain: "Moves.RouteFileImport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported route format in \(url.lastPathComponent)."]
        )
    }
}

struct RouteFileImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer: RouteFileImporter
    @State private var isShowingFileImporter = false
    @State private var importMessage = ""
    @State private var isShowingImportMessage = false

    init(modelContext: ModelContext) {
        _importer = StateObject(wrappedValue: RouteFileImporter(modelContext: modelContext))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                RouteImportCard(title: "Route Files") {
                    RouteImportActionRow(
                        title: importer.isImporting ? "Importing route files..." : "Import route files",
                        systemImage: "square.and.arrow.down",
                        isDisabled: importer.isImporting
                    ) {
                        isShowingFileImporter = true
                    }

                    if importer.isImporting {
                        if let progress = importer.importProgress {
                            ProgressView(value: progress)
                                .tint(MovesPalette.routeTracking)
                        } else {
                            ProgressView()
                                .tint(MovesPalette.routeTracking)
                        }

                        if !importer.importProgressText.isEmpty {
                            Text(importer.importProgressText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Supports GPX, TCX, KML, and GeoJSON route files. You can select one or multiple files at once. Duplicate points are merged automatically, and imported route tracks are preferred over less accurate phone/watch samples.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle("File Route Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: RouteFileImportContentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    await importer.importFiles(urls: urls)
                    if let report = importer.lastReport {
                        importMessage = "Imported \(report.routeCount) route(s) from \(report.fileCount) file(s), covering \(report.sampleCount) GPS point(s)."
                    } else {
                        importMessage = importer.lastErrorMessage ?? "No route data was imported."
                    }
                    isShowingImportMessage = true
                }
            case .failure(let error):
                importMessage = "File import failed: \(error.localizedDescription)"
                isShowingImportMessage = true
            }
        }
        .alert("File Route Import", isPresented: $isShowingImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
    }
}

private struct RouteImportCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

private struct RouteImportActionRow: View {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : MovesPalette.routeTracking)

                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private enum RouteFileImportContentTypes {
    static let allowed: [UTType] = [
        .xml,
        .json,
        UTType(filenameExtension: "gpx") ?? .xml,
        UTType(filenameExtension: "tcx") ?? .xml,
        UTType(filenameExtension: "kml") ?? .xml,
        UTType(filenameExtension: "geojson") ?? .json
    ]
}

private struct ImportedRouteTrack {
    let locations: [CLLocation]
    let transportMode: TransportMode
}

private enum GeoJSONRouteTrackParser {
    static func parse(data: Data, fileName: String) throws -> [ImportedRouteTrack] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var tracks: [ImportedRouteTrack] = []
        let mode = inferTransportMode(from: fileName)

        if let type = object["type"] as? String, type == "FeatureCollection",
           let features = object["features"] as? [[String: Any]] {
            for feature in features {
                guard let geometry = feature["geometry"] as? [String: Any],
                      let geometryType = geometry["type"] as? String else { continue }
                tracks.append(contentsOf: parseGeometry(geometry, type: geometryType, transportMode: mode))
            }
            return tracks
        }

        if let type = object["type"] as? String {
            tracks.append(contentsOf: parseGeometry(object, type: type, transportMode: mode))
        }

        return tracks
    }

    private static func parseGeometry(_ geometry: [String: Any], type: String, transportMode: TransportMode) -> [ImportedRouteTrack] {
        switch type {
        case "LineString":
            let locations = locationsFromCoordinates(geometry["coordinates"])
            return locations.count >= 2 ? [ImportedRouteTrack(locations: locations, transportMode: transportMode)] : []
        case "MultiLineString":
            guard let lines = geometry["coordinates"] as? [[[Double]]] else { return [] }
            return lines.compactMap { line in
                let locations = locationsFromLine(line)
                return locations.count >= 2 ? ImportedRouteTrack(locations: locations, transportMode: transportMode) : nil
            }
        default:
            return []
        }
    }

    private static func locationsFromCoordinates(_ coordinates: Any?) -> [CLLocation] {
        guard let line = coordinates as? [[Double]] else { return [] }
        return locationsFromLine(line)
    }

    private static func locationsFromLine(_ line: [[Double]]) -> [CLLocation] {
        let start = Date()
        return line.enumerated().compactMap { index, point in
            guard point.count >= 2 else { return nil }
            let timestamp = start.addingTimeInterval(TimeInterval(index))
            let altitude = point.count > 2 ? point[2] : 0
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point[1], longitude: point[0]),
                altitude: altitude,
                horizontalAccuracy: 5,
                verticalAccuracy: altitude == 0 ? -1 : 5,
                course: -1,
                speed: -1,
                timestamp: timestamp
            )
        }
    }
}

private final class XMLRouteTrackParser: NSObject, XMLParserDelegate {
    private var tracks: [[CLLocation]] = []
    private var currentTrack: [CLLocation] = []
    private var currentCoordinate: CLLocationCoordinate2D?
    private var currentAltitude: Double?
    private var currentTimestamp: Date?
    private var currentElement = ""
    private var currentText = ""
    private var fallbackTimestamp = Date()
    private let transportMode: TransportMode

    init(fileName: String) {
        self.transportMode = inferTransportMode(from: fileName)
    }

    static func parse(data: Data, fileName: String) throws -> [ImportedRouteTrack] {
        let parser = XMLParser(data: data)
        let delegate = XMLRouteTrackParser(fileName: fileName)
        parser.delegate = delegate
        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            return []
        }

        delegate.finalizeCurrentTrack()
        return delegate.tracks
            .filter { $0.count >= 2 }
            .map { ImportedRouteTrack(locations: $0, transportMode: delegate.transportMode) }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        if elementName == "trkseg" || elementName == "Track" || elementName == "Placemark" {
            finalizeCurrentTrack()
        }

        if elementName == "trkpt" {
            if let latString = attributeDict["lat"],
               let lonString = attributeDict["lon"],
               let latitude = Double(latString),
               let longitude = Double(lonString) {
                currentCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            currentAltitude = nil
            currentTimestamp = nil
        }

        if elementName == "Trackpoint" || elementName == "Position" {
            currentCoordinate = nil
            currentAltitude = nil
            currentTimestamp = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { currentText = "" }

        switch elementName {
        case "lat", "LatitudeDegrees":
            if let latitude = Double(text) {
                currentCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: currentCoordinate?.longitude ?? 0)
            }
        case "lon", "LongitudeDegrees":
            if let longitude = Double(text) {
                currentCoordinate = CLLocationCoordinate2D(latitude: currentCoordinate?.latitude ?? 0, longitude: longitude)
            }
        case "ele", "AltitudeMeters":
            currentAltitude = Double(text)
        case "time", "Time":
            currentTimestamp = parseDate(text)
        case "trkpt", "Trackpoint":
            appendCurrentPointIfPossible()
        case "coordinates":
            appendKMLCoordinates(text)
        case "trkseg", "Track", "Placemark":
            finalizeCurrentTrack()
        default:
            break
        }
    }

    private func appendCurrentPointIfPossible() {
        guard let coordinate = currentCoordinate else { return }
        let timestamp = currentTimestamp ?? fallbackTimestamp
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        let altitude = currentAltitude ?? 0
        let location = CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: altitude == 0 ? -1 : 5,
            course: -1,
            speed: -1,
            timestamp: timestamp
        )
        currentTrack.append(location)
        currentCoordinate = nil
        currentAltitude = nil
        currentTimestamp = nil
    }

    private func appendKMLCoordinates(_ text: String) {
        let coordinateChunks = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        for chunk in coordinateChunks {
            let values = chunk.split(separator: ",").compactMap { Double($0) }
            guard values.count >= 2 else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: values[1], longitude: values[0])
            let altitude = values.count > 2 ? values[2] : 0
            let location = CLLocation(
                coordinate: coordinate,
                altitude: altitude,
                horizontalAccuracy: 5,
                verticalAccuracy: altitude == 0 ? -1 : 5,
                course: -1,
                speed: -1,
                timestamp: fallbackTimestamp
            )
            fallbackTimestamp = fallbackTimestamp.addingTimeInterval(1)
            currentTrack.append(location)
        }
    }

    private func finalizeCurrentTrack() {
        guard currentTrack.count >= 2 else {
            currentTrack.removeAll(keepingCapacity: true)
            return
        }

        tracks.append(currentTrack.sorted(by: { $0.timestamp < $1.timestamp }))
        currentTrack.removeAll(keepingCapacity: true)
    }
}

private extension Array where Element == URL {
    var uniqueForImport: [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []
        for url in self {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(url)
        }
        return ordered
    }
}

private func parseDate(_ value: String) -> Date? {
    if let date = ISO8601DateFormatter.withFractional.date(from: value) {
        return date
    }
    if let date = ISO8601DateFormatter.withoutFractional.date(from: value) {
        return date
    }
    return nil
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private func inferTransportMode(from fileName: String) -> TransportMode {
    let name = fileName.lowercased()
    if name.contains("run") || name.contains("jog") {
        return .running
    }
    if name.contains("ride") || name.contains("bike") || name.contains("cycle") {
        return .cycling
    }
    if name.contains("swim") || name.contains("pool") || name.contains("openwater") {
        return .swimming
    }
    if name.contains("walk") || name.contains("hike") {
        return .walking
    }
    if name.contains("train") {
        return .train
    }
    if name.contains("boat") || name.contains("ferry") {
        return .boat
    }
    if name.contains("flight") || name.contains("plane") {
        return .plane
    }
    if name.contains("drive") || name.contains("car") {
        return .automotive
    }
    return .unknown
}
