import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import MapKit
import RouteFileKit

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum RoutePreviewAppearance: Sendable {
    case light
    case dark
}

/// Selects the basemap source used by a preview.
///
/// MapKit is available to the main Moves app, but macOS Quick Look extensions are
/// deliberately prevented from fetching network-backed map tiles. The route-only
/// renderer keeps Quick Look useful on those systems without pretending that a
/// blank MapKit snapshot is a real map.
public enum RoutePreviewBackground: Sendable, Equatable {
    case map
    case routeOnly
}

public struct RoutePreviewRequest: Sendable {
    public let tracks: [RouteTrack]
    public let canvasSize: CGSize
    public let scale: CGFloat
    public let appearance: RoutePreviewAppearance
    public let background: RoutePreviewBackground
    public let pointBudget: Int?

    public init(
        tracks: [RouteTrack],
        canvasSize: CGSize,
        scale: CGFloat = 2,
        appearance: RoutePreviewAppearance = .light,
        background: RoutePreviewBackground = .map,
        pointBudget: Int? = nil
    ) {
        self.tracks = tracks
        self.canvasSize = canvasSize
        self.scale = max(1, scale)
        self.appearance = appearance
        self.background = background
        self.pointBudget = pointBudget
    }
}

public struct RoutePreviewSummary: Sendable, Equatable {
    public let pointCount: Int
    public let trackCount: Int
    public let distanceMeters: Double
    public let duration: TimeInterval?
    public let startDate: Date?
    public let endDate: Date?
    public let minimumElevation: Double?
    public let maximumElevation: Double?
    public let elevationGain: Double?
    public let elevationLoss: Double?
    public let hasOriginalTimestamps: Bool

    public init(
        pointCount: Int,
        trackCount: Int,
        distanceMeters: Double,
        duration: TimeInterval?,
        startDate: Date?,
        endDate: Date?,
        minimumElevation: Double?,
        maximumElevation: Double?,
        elevationGain: Double?,
        elevationLoss: Double?,
        hasOriginalTimestamps: Bool
    ) {
        self.pointCount = pointCount
        self.trackCount = trackCount
        self.distanceMeters = distanceMeters
        self.duration = duration
        self.startDate = startDate
        self.endDate = endDate
        self.minimumElevation = minimumElevation
        self.maximumElevation = maximumElevation
        self.elevationGain = elevationGain
        self.elevationLoss = elevationLoss
        self.hasOriginalTimestamps = hasOriginalTimestamps
    }
}

public struct RoutePreviewResult: @unchecked Sendable {
    public let image: CGImage
    public let summary: RoutePreviewSummary

    public init(image: CGImage, summary: RoutePreviewSummary) {
        self.image = image
        self.summary = summary
    }
}

/// Shared static-preview storage used by the main app and its Quick Look extensions.
/// The main app can ask MapKit for tiles; Quick Look can only consume the image.
public enum RoutePreviewCache {
    public static let applicationGroupIdentifier = "group.de.holgerkrupp.Moves"
    private static let cacheVersion = "v1"

    public static func image(for data: Data, appearance: RoutePreviewAppearance = .light) -> CGImage? {
        guard let url = imageURL(for: data, appearance: appearance),
              let imageData = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func store(_ image: CGImage, for data: Data, appearance: RoutePreviewAppearance = .light) throws {
        guard let url = imageURL(for: data, appearance: appearance) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func imageURL(for data: Data, appearance: RoutePreviewAppearance) -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier) else { return nil }
        let appearanceKey = appearance == .dark ? "dark" : "light"
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return container
            .appendingPathComponent("Library/Caches/MovesRoutePreviews", isDirectory: true)
            .appendingPathComponent(cacheVersion, isDirectory: true)
            .appendingPathComponent("\(digest)-\(appearanceKey).png")
    }
}

public enum RoutePreviewError: LocalizedError, Sendable {
    case noGeometry
    case imageCreationFailed

    public var errorDescription: String? {
        switch self {
        case .noGeometry: "The route has no drawable geometry."
        case .imageCreationFailed: "The route preview image could not be created."
        }
    }
}

public enum RoutePreviewGeometry {
    public struct Segment: Sendable, Equatable {
        public let points: [RouteTrackPoint]

        public init(points: [RouteTrackPoint]) { self.points = points }
    }

    public static func segments(for tracks: [RouteTrack], pointBudget: Int? = nil) -> [Segment] {
        let all = tracks.flatMap { splitDateline($0.points) }
        guard let pointBudget, pointBudget > 0 else { return all.map(Segment.init) }
        let perSegmentBudget = max(2, pointBudget / max(1, all.count))
        return all.map { Segment(points: simplify($0, maximumCount: perSegmentBudget)) }
    }

    public static func simplify(_ points: [RouteTrackPoint], maximumCount: Int) -> [RouteTrackPoint] {
        guard points.count > maximumCount, maximumCount >= 2 else { return points }
        var unwrapped = [(Double, Double)]()
        unwrapped.reserveCapacity(points.count)
        var previousLongitude: Double?
        for point in points {
            var longitude = point.longitude
            if let previousLongitude {
                while longitude - previousLongitude > 180 { longitude -= 360 }
                while longitude - previousLongitude < -180 { longitude += 360 }
            }
            unwrapped.append((longitude, point.latitude))
            previousLongitude = longitude
        }

        var keep = Array(repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        let tolerance = max(0.000001, boundingDiagonal(unwrapped) / Double(maximumCount * 2))
        let toleranceSquared = tolerance * tolerance
        while let (start, end) = stack.popLast() {
            guard end - start > 1 else { continue }
            var greatestDistance = toleranceSquared
            var greatestIndex: Int?
            for index in (start + 1)..<end {
                let distance = perpendicularDistanceSquared(unwrapped[index], from: unwrapped[start], to: unwrapped[end])
                if distance > greatestDistance { greatestDistance = distance; greatestIndex = index }
            }
            if let greatestIndex {
                keep[greatestIndex] = true
                stack.append((start, greatestIndex)); stack.append((greatestIndex, end))
            }
        }

        var result = points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
        if result.count > maximumCount {
            result = stride(from: 0, to: result.count, by: max(1, Int(ceil(Double(result.count - 1) / Double(maximumCount - 1))))).map { result[$0] }
            if result.last != points.last { result.append(points.last!) }
        }
        return result
    }

    public static func splitDateline(_ points: [RouteTrackPoint]) -> [[RouteTrackPoint]] {
        guard points.count > 1 else { return points.isEmpty ? [] : [points] }
        var result: [[RouteTrackPoint]] = [[points[0]]]
        for point in points.dropFirst() {
            let previous = result[result.count - 1].last!
            if abs(point.longitude - previous.longitude) > 180 {
                result.append([point])
            } else {
                result[result.count - 1].append(point)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    public static func fittedRegion(for tracks: [RouteTrack], padding: Double = 1.18) -> MKCoordinateRegion? {
        let points = tracks.flatMap(\.points)
        guard let first = points.first else { return nil }
        var minLatitude = first.latitude, maxLatitude = first.latitude
        for point in points.dropFirst() {
            minLatitude = min(minLatitude, point.latitude); maxLatitude = max(maxLatitude, point.latitude)
        }
        let latitudeDelta = max(0.01, (maxLatitude - minLatitude) * padding)
        let sortedLongitudes = points.map { normalizedLongitude($0.longitude) }.sorted()
        var largestGap = 0.0
        var largestGapIndex = 0
        for index in sortedLongitudes.indices {
            let next = index == sortedLongitudes.index(before: sortedLongitudes.endIndex) ? sortedLongitudes[0] + 360 : sortedLongitudes[index + 1]
            let gap = next - sortedLongitudes[index]
            if gap > largestGap { largestGap = gap; largestGapIndex = index }
        }
        let startIndex = sortedLongitudes.index(after: largestGapIndex) == sortedLongitudes.endIndex
            ? sortedLongitudes.startIndex
            : sortedLongitudes.index(after: largestGapIndex)
        let startLongitude = sortedLongitudes[startIndex]
        let rawLongitudeDelta = max(0.01, 360 - largestGap)
        let longitudeDelta = min(360, rawLongitudeDelta * padding)
        let centerLongitude = normalizedLongitude(startLongitude + rawLongitudeDelta / 2)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: min(180, latitudeDelta), longitudeDelta: longitudeDelta)
        )
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    private static func boundingDiagonal(_ points: [(Double, Double)]) -> Double {
        guard let first = points.first else { return 1 }
        var minX = first.0, maxX = first.0, minY = first.1, maxY = first.1
        for point in points.dropFirst() { minX = min(minX, point.0); maxX = max(maxX, point.0); minY = min(minY, point.1); maxY = max(maxY, point.1) }
        return hypot(maxX - minX, maxY - minY)
    }

    private static func perpendicularDistanceSquared(_ point: (Double, Double), from start: (Double, Double), to end: (Double, Double)) -> Double {
        let dx = end.0 - start.0, dy = end.1 - start.1
        guard dx != 0 || dy != 0 else { return pow(point.0 - start.0, 2) + pow(point.1 - start.1, 2) }
        let t = max(0, min(1, ((point.0 - start.0) * dx + (point.1 - start.1) * dy) / (dx * dx + dy * dy)))
        let x = start.0 + t * dx, y = start.1 + t * dy
        return pow(point.0 - x, 2) + pow(point.1 - y, 2)
    }
}

public enum RoutePreviewSummaries {
    public static func summary(for tracks: [RouteTrack]) -> RoutePreviewSummary {
        let points = tracks.flatMap(\.points)
        let distance = tracks.reduce(0) { partial, track in
            partial + zip(track.points, track.points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        }
        let originalTracks = tracks.filter(\.hasOriginalTimestamps)
        let dates = originalTracks.flatMap { $0.points.map(\.timestamp) }.sorted()
        let elevations = points.filter(\.hasElevation).map(\.altitude).filter { $0.isFinite }
        var gain = 0.0, loss = 0.0
        for track in tracks {
            for (a, b) in zip(track.points, track.points.dropFirst()) {
                guard a.hasElevation && b.hasElevation else { continue }
                let delta = b.altitude - a.altitude
                if delta > 0 { gain += delta } else { loss += -delta }
            }
        }
        let minElevation = elevations.min(), maxElevation = elevations.max()
        return RoutePreviewSummary(
            pointCount: points.count,
            trackCount: tracks.count,
            distanceMeters: distance,
            duration: dates.count >= 2 ? dates.last!.timeIntervalSince(dates.first!) : nil,
            startDate: dates.first,
            endDate: dates.last,
            minimumElevation: minElevation,
            maximumElevation: maxElevation,
            elevationGain: elevations.isEmpty ? nil : gain,
            elevationLoss: elevations.isEmpty ? nil : loss,
            hasOriginalTimestamps: !originalTracks.isEmpty
        )
    }

    private static func distance(_ a: RouteTrackPoint, _ b: RouteTrackPoint) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(h)))
    }
}

public actor RoutePreviewRenderer {
    private struct SnapshotBox: @unchecked Sendable {
        let value: MKMapSnapshotter.Snapshot
    }

    public init() {}

    public func render(_ request: RoutePreviewRequest) async throws -> RoutePreviewResult {
        try Task.checkCancellation()
        let segments = RoutePreviewGeometry.segments(for: request.tracks, pointBudget: request.pointBudget ?? defaultBudget(for: request.canvasSize))
        guard !segments.isEmpty else { throw RoutePreviewError.noGeometry }
        let region = RoutePreviewGeometry.fittedRegion(for: request.tracks) ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        )

        if request.background == .routeOnly {
            guard let image = drawRouteOnly(segments: segments, region: region, size: request.canvasSize, scale: request.scale, appearance: request.appearance) else {
                throw RoutePreviewError.imageCreationFailed
            }
            return RoutePreviewResult(image: image, summary: RoutePreviewSummaries.summary(for: request.tracks))
        }

        let snapshot = try await mapSnapshot(
            region: region,
            size: request.canvasSize,
            appearance: request.appearance
        ).value
        try Task.checkCancellation()
        guard let baseImage = cgImage(from: snapshot.image) else { throw RoutePreviewError.imageCreationFailed }
        guard let image = draw(baseImage: baseImage, snapshot: snapshot, segments: segments, size: request.canvasSize, scale: request.scale, appearance: request.appearance) else {
            throw RoutePreviewError.imageCreationFailed
        }
        return RoutePreviewResult(image: image, summary: RoutePreviewSummaries.summary(for: request.tracks))
    }

    private func defaultBudget(for size: CGSize) -> Int { max(250, min(8_000, Int(size.width * size.height / 16))) }

    @MainActor
    private func mapSnapshot(region: MKCoordinateRegion, size: CGSize, appearance: RoutePreviewAppearance) async throws -> SnapshotBox {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.mapType = appearance == .dark ? .mutedStandard : .standard
        #if os(macOS)
        options.appearance = appearance == .dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        #endif
        return SnapshotBox(value: try await MKMapSnapshotter(options: options).start())
    }

    private func drawRouteOnly(
        segments: [RoutePreviewGeometry.Segment],
        region: MKCoordinateRegion,
        size: CGSize,
        scale: CGFloat,
        appearance: RoutePreviewAppearance
    ) -> CGImage? {
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let backgroundColor: CGColor
        let gridColor: CGColor
        let textColor: CGColor
        if appearance == .dark {
            backgroundColor = CGColor(red: 0.08, green: 0.10, blue: 0.13, alpha: 1)
            gridColor = CGColor(red: 0.18, green: 0.22, blue: 0.28, alpha: 1)
            textColor = CGColor(red: 0.70, green: 0.76, blue: 0.84, alpha: 1)
        } else {
            backgroundColor = CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1)
            gridColor = CGColor(red: 0.84, green: 0.87, blue: 0.92, alpha: 1)
            textColor = CGColor(red: 0.30, green: 0.35, blue: 0.43, alpha: 1)
        }
        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let gridStep = max(24, Int(64 * scale))
        context.setStrokeColor(gridColor)
        context.setLineWidth(max(1, scale))
        for x in stride(from: 0, through: width, by: gridStep) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: gridStep) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()

        context.setFillColor(textColor)
        let font = CTFontCreateWithName("SFProText-Regular" as CFString, max(11, 12 * scale), nil)
        let label = NSAttributedString(
            string: "Map tiles unavailable in Quick Look",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
            ]
        )
        let line = CTLineCreateWithAttributedString(label)
        context.textPosition = CGPoint(x: 18 * scale, y: CGFloat(height) - 26 * scale)
        CTLineDraw(line, context)

        context.setLineCap(.round)
        context.setLineJoin(.round)
        let routeColor = appearance == .dark
            ? CGColor(red: 0.35, green: 0.85, blue: 1, alpha: 1)
            : CGColor(red: 0.06, green: 0.28, blue: 0.95, alpha: 1)
        for segment in segments {
            guard segment.points.count >= 2 else { continue }
            let path = CGMutablePath()
            for (index, point) in segment.points.enumerated() {
                let projected = project(point, in: region, size: size, scale: scale)
                if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
            }
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: appearance == .dark ? 0 : 1, alpha: 0.9))
            context.setLineWidth(max(5, 5 * scale))
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(routeColor)
            context.setLineWidth(max(2.5, 2.5 * scale))
            context.strokePath()
        }
        if let first = segments.first?.points.first {
            drawMarker(first, in: context, region: region, size: size, scale: scale, color: CGColor(red: 0.1, green: 0.75, blue: 0.3, alpha: 1))
        }
        if let last = segments.last?.points.last {
            drawMarker(last, in: context, region: region, size: size, scale: scale, color: CGColor(red: 0.9, green: 0.15, blue: 0.12, alpha: 1))
        }
        return context.makeImage()
    }

    private func project(_ point: RouteTrackPoint, in region: MKCoordinateRegion, size: CGSize, scale: CGFloat) -> CGPoint {
        let longitudeDelta = max(0.000001, region.span.longitudeDelta)
        let latitudeDelta = max(0.000001, region.span.latitudeDelta)
        var longitude = point.longitude
        while longitude - region.center.longitude > 180 { longitude -= 360 }
        while longitude - region.center.longitude < -180 { longitude += 360 }
        let x = ((longitude - region.center.longitude) / longitudeDelta + 0.5) * size.width * scale
        let y = (0.5 - (point.latitude - region.center.latitude) / latitudeDelta) * size.height * scale
        return CGPoint(x: x, y: y)
    }

    private func drawMarker(_ point: RouteTrackPoint, in context: CGContext, region: MKCoordinateRegion, size: CGSize, scale: CGFloat, color: CGColor) {
        let center = project(point, in: region, size: size, scale: scale)
        let radius = 5.5 * scale
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fillEllipse(in: CGRect(x: center.x - radius - 2, y: center.y - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2))
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func draw(baseImage: CGImage, snapshot: MKMapSnapshotter.Snapshot, segments: [RoutePreviewGeometry.Segment], size: CGSize, scale: CGFloat, appearance: RoutePreviewAppearance) -> CGImage? {
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round); context.setLineJoin(.round)
        let routeColor = (appearance == .dark ? CGColor(red: 0.35, green: 0.85, blue: 1, alpha: 1) : CGColor(red: 0.06, green: 0.28, blue: 0.95, alpha: 1))
        for segment in segments {
            guard segment.points.count >= 2 else { continue }
            let path = CGMutablePath()
            for (index, point) in segment.points.enumerated() {
                let mapPoint = snapshot.point(for: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                let cgPoint = CGPoint(x: mapPoint.x * scale, y: (size.height - mapPoint.y) * scale)
                if index == 0 { path.move(to: cgPoint) } else { path.addLine(to: cgPoint) }
            }
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.86)); context.setLineWidth(max(5, 5 * scale)); context.strokePath()
            context.addPath(path); context.setStrokeColor(routeColor); context.setLineWidth(max(2.5, 2.5 * scale)); context.strokePath()
        }
        if let first = segments.first?.points.first { drawMarker(first, in: context, snapshot: snapshot, size: size, scale: scale, color: CGColor(red: 0.1, green: 0.75, blue: 0.3, alpha: 1)) }
        if let last = segments.last?.points.last, segments.count > 0 { drawMarker(last, in: context, snapshot: snapshot, size: size, scale: scale, color: CGColor(red: 0.9, green: 0.15, blue: 0.12, alpha: 1)) }
        return context.makeImage()
    }

    private func drawMarker(_ point: RouteTrackPoint, in context: CGContext, snapshot: MKMapSnapshotter.Snapshot, size: CGSize, scale: CGFloat, color: CGColor) {
        let mapPoint = snapshot.point(for: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
        let center = CGPoint(x: mapPoint.x * scale, y: (size.height - mapPoint.y) * scale)
        let radius = 5.5 * scale
        context.setFillColor(CGColor(gray: 1, alpha: 0.95)); context.fillEllipse(in: CGRect(x: center.x - radius - 2, y: center.y - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2))
        context.setFillColor(color); context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func cgImage(from image: Any) -> CGImage? {
        #if os(macOS)
        guard let image = image as? NSImage else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return (image as? UIImage)?.cgImage
        #endif
    }
}
