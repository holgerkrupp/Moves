import Foundation

public enum RouteFileFormat: String, Sendable, CaseIterable {
    case gpx
    case tcx
    case kml
    case geoJSON

    public init?(fileName: String) {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "gpx": self = .gpx
        case "tcx": self = .tcx
        case "kml": self = .kml
        case "geojson", "json": self = .geoJSON
        default: return nil
        }
    }

    public var fileExtension: String {
        switch self {
        case .gpx: "gpx"
        case .tcx: "tcx"
        case .kml: "kml"
        case .geoJSON: "geojson"
        }
    }
}

public enum RouteTransportMode: String, Codable, Hashable, Sendable {
    case unknown
    case walking
    case running
    case cycling
    case automotive
    case plane
}

public struct RouteTrackPoint: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let hasElevation: Bool
    public let timestamp: Date

    public init(latitude: Double, longitude: Double, altitude: Double = 0, hasElevation: Bool = false, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.hasElevation = hasElevation
        self.timestamp = timestamp
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && altitude.isFinite && timestamp.timeIntervalSinceReferenceDate.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct RouteTrack: Codable, Hashable, Sendable {
    public let points: [RouteTrackPoint]
    public let transportMode: RouteTransportMode
    public let hasOriginalTimestamps: Bool
    public let name: String?
    public var startsAfterVisitGap: Bool

    public init(
        points: [RouteTrackPoint],
        transportMode: RouteTransportMode = .unknown,
        hasOriginalTimestamps: Bool,
        name: String? = nil,
        startsAfterVisitGap: Bool = false
    ) {
        self.points = points
        self.transportMode = transportMode
        self.hasOriginalTimestamps = hasOriginalTimestamps
        self.name = name
        self.startsAfterVisitGap = startsAfterVisitGap
    }
}

public struct RouteFileParseLimits: Sendable {
    public var maximumFileBytes: Int
    public var maximumPointCount: Int
    public var maximumTrackCount: Int

    public init(
        maximumFileBytes: Int = 100 * 1024 * 1024,
        maximumPointCount: Int = 500_000,
        maximumTrackCount: Int = 2_000
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumPointCount = maximumPointCount
        self.maximumTrackCount = maximumTrackCount
    }

    public static let quickLook = RouteFileParseLimits()
}

public enum RouteFileParseError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case fileTooLarge(Int)
    case pointLimitExceeded(Int)
    case trackLimitExceeded(Int)
    case malformed(String)
    case emptyRoute

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name): "Unsupported route format: \(name)"
        case .fileTooLarge(let bytes): "Route file is too large (\(bytes) bytes)."
        case .pointLimitExceeded(let count): "Route contains more than \(count) points."
        case .trackLimitExceeded(let count): "Route contains more than \(count) tracks."
        case .malformed(let message): message
        case .emptyRoute: "The route file contains no supported route geometry."
        }
    }
}

public enum RouteFileParser {
    public static func format(forFileName fileName: String) -> RouteFileFormat? {
        RouteFileFormat(fileName: fileName)
    }

    public static func parse(
        data: Data,
        fileName: String,
        limits: RouteFileParseLimits = .quickLook
    ) throws -> [RouteTrack] {
        guard data.count <= limits.maximumFileBytes else { throw RouteFileParseError.fileTooLarge(data.count) }
        guard let format = RouteFileFormat(fileName: fileName) else {
            throw RouteFileParseError.unsupportedFormat(fileName)
        }

        let tracks: [RouteTrack]
        switch format {
        case .gpx, .tcx, .kml:
            tracks = try XMLRouteTrackParser.parse(data: data, fileName: fileName, limits: limits)
        case .geoJSON:
            tracks = try GeoJSONRouteTrackParser.parse(data: data, fileName: fileName, limits: limits)
        }
        return try validate(tracks, limits: limits)
    }

    public static func parse(
        url: URL,
        limits: RouteFileParseLimits = .quickLook
    ) throws -> [RouteTrack] {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = resourceValues?.fileSize, size > limits.maximumFileBytes {
            throw RouteFileParseError.fileTooLarge(size)
        }
        guard let format = RouteFileFormat(fileName: url.lastPathComponent) else {
            throw RouteFileParseError.unsupportedFormat(url.lastPathComponent)
        }

        let tracks: [RouteTrack]
        switch format {
        case .gpx, .tcx, .kml:
            guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
            tracks = try XMLRouteTrackParser.parse(stream: stream, fileName: url.lastPathComponent, limits: limits)
        case .geoJSON:
            tracks = try parse(data: Data(contentsOf: url, options: [.mappedIfSafe]), fileName: url.lastPathComponent, limits: limits)
        }
        return try validate(tracks, limits: limits)
    }

    private static func validate(_ tracks: [RouteTrack], limits: RouteFileParseLimits) throws -> [RouteTrack] {
        let filtered = tracks.filter { $0.points.count >= 2 }
        guard !filtered.isEmpty else { throw RouteFileParseError.emptyRoute }
        guard filtered.count <= limits.maximumTrackCount else { throw RouteFileParseError.trackLimitExceeded(limits.maximumTrackCount) }
        let pointCount = filtered.reduce(0) { $0 + $1.points.count }
        guard pointCount <= limits.maximumPointCount else { throw RouteFileParseError.pointLimitExceeded(limits.maximumPointCount) }
        return RouteTrackSegmentation.split(filtered)
    }
}

private enum RouteFileDateParser {
    static func parse(_ value: String) -> Date? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = fractional.date(from: candidate) ?? plain.date(from: candidate) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: candidate) { return date }
        }
        return nil
    }
}

private func inferTransportMode(from fileNameOrText: String) -> RouteTransportMode {
    let value = fileNameOrText.lowercased()
    if value.contains("flight") || value.contains("plane") || value.contains("air") { return .plane }
    if value.contains("bike") || value.contains("cycling") || value.contains("cycle") { return .cycling }
    if value.contains("run") || value.contains("jog") { return .running }
    if value.contains("walk") || value.contains("hike") { return .walking }
    if value.contains("car") || value.contains("drive") || value.contains("auto") { return .automotive }
    return .unknown
}

private enum RouteFilePointMath {
    static let earthRadius = 6_371_000.0

    static func distance(_ a: RouteTrackPoint, _ b: RouteTrackPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

private enum RouteTrackSegmentation {
    static func split(_ tracks: [RouteTrack]) -> [RouteTrack] {
        var result: [RouteTrack] = []
        for track in tracks {
            var current = [track.points[0]]
            for point in track.points.dropFirst() {
                let previous = current[current.count - 1]
                let duration = point.timestamp.timeIntervalSince(previous.timestamp)
                let distance = RouteFilePointMath.distance(previous, point)
                if duration >= 15 * 60 && distance <= 5_000 && distance / duration <= 1 {
                    if current.count >= 2 {
                        result.append(RouteTrack(points: current, transportMode: track.transportMode,
                                                 hasOriginalTimestamps: track.hasOriginalTimestamps,
                                                 name: track.name, startsAfterVisitGap: result.isEmpty && track.startsAfterVisitGap))
                    }
                    current = [point]
                } else {
                    current.append(point)
                }
            }
            if current.count >= 2 {
                result.append(RouteTrack(points: current, transportMode: track.transportMode,
                                         hasOriginalTimestamps: track.hasOriginalTimestamps, name: track.name))
            }
        }
        result.sort { ($0.points.first?.timestamp ?? .distantFuture) < ($1.points.first?.timestamp ?? .distantFuture) }
        if result.count > 1 {
            for index in result.indices.dropFirst() {
                let previous = result[index - 1].points.last!
                let next = result[index].points.first!
                result[index].startsAfterVisitGap = next.timestamp.timeIntervalSince(previous.timestamp) >= 15 * 60
            }
        }
        return result
    }
}

private final class XMLRouteTrackParser: NSObject, XMLParserDelegate {
    private struct ParsedTrack {
        var points: [RouteTrackPoint]
        var hasOriginalTimestamps: Bool
        var name: String?
    }

    private var tracks: [ParsedTrack] = []
    private var currentTrack: [RouteTrackPoint] = []
    private var currentTrackUsesFallbackTimestamp = false
    private var kmlPointTrack: [RouteTrackPoint] = []
    private var kmlPointTrackUsesFallbackTimestamp = false
    private var kmlLineTracks: [ParsedTrack] = []
    private var gxTrackTimes: [Date] = []
    private var gxTrackPoints: [RouteTrackPoint] = []
    private var gxTrackUsesFallbackTimestamp = false
    private var currentCoordinate: (latitude: Double, longitude: Double)?
    private var currentAltitude: Double?
    private var currentTimestamp: Date?
    private var placemarkNameTimestamp: Date?
    private var pendingKMLPointCoordinate: (latitude: Double, longitude: Double)?
    private var pendingKMLPointAltitude: Double?
    private var pendingName: String?
    private var currentText = ""
    private var fallbackTimestamp = Date()
    private var transportMode: RouteTransportMode
    private var isInsideKMLPoint = false
    private var isInsideKMLLineString = false
    private var isInsideGXTrack = false
    private var isInsideKMLPlacemark = false
    private let limits: RouteFileParseLimits

    private init(fileName: String, limits: RouteFileParseLimits) {
        transportMode = inferTransportMode(from: fileName)
        self.limits = limits
    }

    static func parse(data: Data, fileName: String, limits: RouteFileParseLimits) throws -> [RouteTrack] {
        try parse(parser: XMLParser(data: data), fileName: fileName, limits: limits)
    }

    static func parse(stream: InputStream, fileName: String, limits: RouteFileParseLimits) throws -> [RouteTrack] {
        try parse(parser: XMLParser(stream: stream), fileName: fileName, limits: limits)
    }

    private static func parse(parser: XMLParser, fileName: String, limits: RouteFileParseLimits) throws -> [RouteTrack] {
        let delegate = XMLRouteTrackParser(fileName: fileName, limits: limits)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? RouteFileParseError.malformed("Malformed XML route file.") }
        delegate.finalizeCurrentTrack()
        delegate.finalizeKMLGeometry()
        return delegate.tracks.map {
            RouteTrack(points: $0.points, transportMode: delegate.transportMode,
                       hasOriginalTimestamps: $0.hasOriginalTimestamps, name: $0.name)
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentText = ""
        let name = localName(elementName)
        if name == "trkseg" || (name == "Track" && !elementName.hasPrefix("gx:")) { finalizeCurrentTrack() }
        if name == "Placemark" {
            isInsideKMLPlacemark = true; currentTimestamp = nil; placemarkNameTimestamp = nil
            pendingKMLPointCoordinate = nil; pendingKMLPointAltitude = nil; pendingName = nil
        }
        if name == "Point" { isInsideKMLPoint = true }
        else if name == "LineString" { isInsideKMLLineString = true }
        else if name == "Track", elementName.hasPrefix("gx:") {
            isInsideGXTrack = true; gxTrackTimes.removeAll(keepingCapacity: true); gxTrackPoints.removeAll(keepingCapacity: true)
        }
        if name == "trkpt" {
            if let lat = Double(attributeDict["lat"] ?? ""), let lon = Double(attributeDict["lon"] ?? "") {
                currentCoordinate = (lat, lon)
            }
            currentAltitude = nil; currentTimestamp = nil
        }
        if name == "Trackpoint" || name == "Position" { currentCoordinate = nil; currentAltitude = nil; currentTimestamp = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = localName(elementName)
        defer { currentText = "" }
        switch name {
        case "lat", "LatitudeDegrees": if let value = Double(text) { currentCoordinate = (value, currentCoordinate?.longitude ?? 0) }
        case "lon", "LongitudeDegrees": if let value = Double(text) { currentCoordinate = (currentCoordinate?.latitude ?? 0, value) }
        case "ele", "AltitudeMeters": currentAltitude = Double(text)
        case "time", "Time", "begin": currentTimestamp = RouteFileDateParser.parse(text)
        case "when":
            if let date = RouteFileDateParser.parse(text) { isInsideGXTrack ? gxTrackTimes.append(date) : (currentTimestamp = date) }
        case "trkpt", "Trackpoint": appendCurrentPointIfPossible()
        case "coordinates": appendKMLCoordinates(text)
        case "coord" where isInsideGXTrack: appendGXCoordinate(text)
        case "name", "desc", "description":
            if transportMode == .unknown { transportMode = inferTransportMode(from: text) }
            if name == "name" {
                pendingName = text
                if isInsideKMLPlacemark { placemarkNameTimestamp = RouteFileDateParser.parse(text) }
            }
        case "Point": isInsideKMLPoint = false
        case "LineString": isInsideKMLLineString = false
        case "Track" where elementName.hasPrefix("gx:"): finalizeGXTrack(); isInsideGXTrack = false
        case "Placemark": finalizeKMLPlacemarkPoint(); isInsideKMLPlacemark = false
        case "trkseg", "Track": finalizeCurrentTrack()
        default: break
        }
    }

    private func appendCurrentPointIfPossible() {
        guard let coordinate = currentCoordinate else { return }
        let timestampWasOriginal = currentTimestamp != nil
        let timestamp = currentTimestamp ?? fallbackTimestamp
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        append(RouteTrackPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: currentAltitude ?? 0,
                               hasElevation: currentAltitude != nil, timestamp: timestamp), to: &currentTrack)
        currentTrackUsesFallbackTimestamp = currentTrackUsesFallbackTimestamp || !timestampWasOriginal
        currentCoordinate = nil; currentAltitude = nil; currentTimestamp = nil
    }

    private func appendKMLCoordinates(_ text: String) {
        let values = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).compactMap { chunk -> (Double, Double, Double)? in
            let parts = chunk.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 2 else { return nil }
            return (parts[1], parts[0], parts.count > 2 ? parts[2] : 0)
        }
        if isInsideKMLPoint, let first = values.first {
            pendingKMLPointCoordinate = (first.0, first.1); pendingKMLPointAltitude = first.2
        } else if isInsideKMLLineString, values.count >= 2 {
            let points = values.map { value in
                let date = fallbackTimestamp; fallbackTimestamp = date.addingTimeInterval(1)
                return RouteTrackPoint(latitude: value.0, longitude: value.1, altitude: value.2,
                                       hasElevation: value.2 != 0, timestamp: date)
            }
            kmlLineTracks.append(ParsedTrack(points: points, hasOriginalTimestamps: false, name: pendingName))
        }
    }

    private func finalizeKMLPlacemarkPoint() {
        guard let coordinate = pendingKMLPointCoordinate else { return }
        let timestamp = currentTimestamp ?? placemarkNameTimestamp ?? fallbackTimestamp
        let original = currentTimestamp != nil || placemarkNameTimestamp != nil
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        kmlPointTrack.append(RouteTrackPoint(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                             altitude: pendingKMLPointAltitude ?? 0,
                                             hasElevation: pendingKMLPointAltitude != nil, timestamp: timestamp))
        kmlPointTrackUsesFallbackTimestamp = kmlPointTrackUsesFallbackTimestamp || !original
        currentTimestamp = nil; placemarkNameTimestamp = nil; pendingKMLPointCoordinate = nil; pendingKMLPointAltitude = nil
    }

    private func appendGXCoordinate(_ text: String) {
        let values = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
        guard values.count >= 2 else { return }
        let original = gxTrackTimes.indices.contains(gxTrackPoints.count)
        let timestamp = original ? gxTrackTimes[gxTrackPoints.count] : fallbackTimestamp
        fallbackTimestamp = timestamp.addingTimeInterval(1)
        gxTrackPoints.append(RouteTrackPoint(latitude: values[1], longitude: values[0], altitude: values.count > 2 ? values[2] : 0,
                                             hasElevation: values.count > 2, timestamp: timestamp))
        gxTrackUsesFallbackTimestamp = gxTrackUsesFallbackTimestamp || !original
    }

    private func finalizeGXTrack() {
        if gxTrackPoints.count >= 2 { tracks.append(ParsedTrack(points: gxTrackPoints, hasOriginalTimestamps: !gxTrackUsesFallbackTimestamp, name: pendingName)) }
        gxTrackTimes.removeAll(keepingCapacity: true); gxTrackPoints.removeAll(keepingCapacity: true); gxTrackUsesFallbackTimestamp = false
    }

    private func finalizeCurrentTrack() {
        guard currentTrack.count >= 2 else { currentTrack.removeAll(keepingCapacity: true); currentTrackUsesFallbackTimestamp = false; return }
        tracks.append(ParsedTrack(points: currentTrack.sorted { $0.timestamp < $1.timestamp }, hasOriginalTimestamps: !currentTrackUsesFallbackTimestamp, name: pendingName))
        currentTrack.removeAll(keepingCapacity: true); currentTrackUsesFallbackTimestamp = false
    }

    private func finalizeKMLGeometry() {
        guard !tracks.contains(where: { $0.points.count >= 2 }) else { return }
        let stitched = stitchContiguous(kmlLineTracks)
        if kmlPointTrack.count >= (stitched.map(\.points.count).max() ?? 0), kmlPointTrack.count >= 2 {
            tracks.append(ParsedTrack(points: kmlPointTrack.sorted { $0.timestamp < $1.timestamp }, hasOriginalTimestamps: !kmlPointTrackUsesFallbackTimestamp, name: pendingName))
        } else { tracks.append(contentsOf: stitched.filter { $0.points.count >= 2 }) }
    }

    private func stitchContiguous(_ lines: [ParsedTrack]) -> [ParsedTrack] {
        var result: [ParsedTrack] = []
        for line in lines where line.points.count >= 2 {
            guard var current = result.popLast() else { result.append(line); continue }
            if RouteFilePointMath.distance(current.points.last!, line.points.first!) <= 100 {
                current.points.append(contentsOf: line.points.dropFirst()); current.hasOriginalTimestamps = current.hasOriginalTimestamps && line.hasOriginalTimestamps; result.append(current)
            } else { result.append(current); result.append(line) }
        }
        return result
    }

    private func append(_ point: RouteTrackPoint, to points: inout [RouteTrackPoint]) {
        guard points.count < limits.maximumPointCount else { return }
        guard point.isValid else { return }
        points.append(point)
    }

    private func localName(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
}

private enum GeoJSONRouteTrackParser {
    static func parse(data: Data, fileName: String, limits: RouteFileParseLimits) throws -> [RouteTrack] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RouteFileParseError.malformed("GeoJSON root must be an object.") }
        let mode = inferTransportMode(from: fileName)
        var tracks: [RouteTrack] = []
        if object["type"] as? String == "FeatureCollection", let features = object["features"] as? [[String: Any]] {
            for feature in features {
                if let geometry = feature["geometry"] as? [String: Any], let type = geometry["type"] as? String {
                    tracks.append(contentsOf: parseGeometry(geometry, type: type, mode: mode))
                }
            }
        } else if object["type"] as? String == "Feature",
                  let geometry = object["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String {
            tracks.append(contentsOf: parseGeometry(geometry, type: type, mode: mode))
        } else if let type = object["type"] as? String {
            tracks.append(contentsOf: parseGeometry(object, type: type, mode: mode))
        }
        guard !tracks.isEmpty else { throw RouteFileParseError.emptyRoute }
        return tracks
    }

    private static func parseGeometry(_ geometry: [String: Any], type: String, mode: RouteTransportMode) -> [RouteTrack] {
        switch type {
        case "LineString":
            let points = points(from: geometry["coordinates"] as? [[Double]])
            return points.count >= 2 ? [RouteTrack(points: points, transportMode: mode, hasOriginalTimestamps: false)] : []
        case "MultiLineString":
            guard let lines = geometry["coordinates"] as? [[[Double]]] else { return [] }
            return lines.map { points(from: $0) }.filter { $0.count >= 2 }.map { RouteTrack(points: $0, transportMode: mode, hasOriginalTimestamps: false) }
        default: return []
        }
    }

    private static func points(from line: [[Double]]?) -> [RouteTrackPoint] {
        let start = Date()
        return (line ?? []).enumerated().compactMap { index, point in
            guard point.count >= 2 else { return nil }
            let candidate = RouteTrackPoint(latitude: point[1], longitude: point[0], altitude: point.count > 2 ? point[2] : 0,
                                            hasElevation: point.count > 2, timestamp: start.addingTimeInterval(TimeInterval(index)))
            return candidate.isValid ? candidate : nil
        }
    }
}
