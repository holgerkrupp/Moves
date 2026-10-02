import CoreGraphics
import CoreText
import Foundation
import RouteFileKit
import RoutePreviewKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import Quartz
#else
import QuickLook
#endif

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        try Task.checkCancellation()
        let didAccess = request.fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { request.fileURL.stopAccessingSecurityScopedResource() } }

        let tracks = try RouteFileParser.parse(url: request.fileURL)
        #if os(macOS)
        let appearance: RoutePreviewAppearance = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        #else
        let appearance: RoutePreviewAppearance = .light
        #endif
        let size = CGSize(width: 900, height: 560)
        let renderer = RoutePreviewRenderer()
        #if os(macOS)
        // macOS Quick Look extensions cannot fetch MapKit tiles. On macOS 15 and
        // later MapKit returns the route overlay over its empty beige tile grid,
        // so use the deterministic local renderer instead.
        let background: RoutePreviewBackground
        if #available(macOS 15.0, *) {
            background = .routeOnly
        } else {
            background = .map
        }
        #else
        let background: RoutePreviewBackground = .map
        #endif
        let sourceData = try Data(contentsOf: request.fileURL)
        let cachedImage = RoutePreviewCache.image(for: sourceData, appearance: appearance)
            ?? (appearance == .dark ? RoutePreviewCache.image(for: sourceData, appearance: .light) : nil)
        let result: RoutePreviewResult
        if let cachedImage {
            result = RoutePreviewResult(image: cachedImage, summary: RoutePreviewSummaries.summary(for: tracks))
        } else {
            result = try await renderer.render(RoutePreviewRequest(
                tracks: tracks,
                canvasSize: size,
                scale: 1,
                appearance: appearance,
                background: background,
                pointBudget: 8_000
            ))
        }
        try Task.checkCancellation()

        let contentSize = CGSize(width: 900, height: 700)
        return QLPreviewReply(contextSize: contentSize, isBitmap: true) { context, _ in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: contentSize))
            context.draw(result.image, in: CGRect(x: 0, y: 140, width: 900, height: 560))
            Self.drawMetadata(
                fileName: request.fileURL.lastPathComponent,
                format: RouteFileParser.format(forFileName: request.fileURL.lastPathComponent)?.fileExtension ?? "route",
                summary: result.summary,
                usesRouteOnlyBackground: cachedImage == nil && background == .routeOnly,
                in: context
            )
        }
    }

    private static func drawMetadata(fileName: String, format: String, summary: RoutePreviewSummary, usesRouteOnlyBackground: Bool, in context: CGContext) {
        let title = "Moves Route Preview"
        let details = [
            fileName,
            "Format: \(format.uppercased())",
            "Distance: \(Measurement(value: summary.distanceMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated)))",
            "Points: \(summary.pointCount)" + (summary.trackCount > 1 ? "  •  Tracks: \(summary.trackCount)" : ""),
            summary.hasOriginalTimestamps ? "Recorded: \(summary.startDate?.formatted(date: .abbreviated, time: .shortened) ?? "") – \(summary.endDate?.formatted(date: .abbreviated, time: .shortened) ?? "")" : "Recorded timestamps unavailable",
            summary.minimumElevation.map { "Elevation: \(Int($0.rounded()))–\(Int((summary.maximumElevation ?? $0).rounded())) m" } ?? "",
            usesRouteOnlyBackground ? "Open in Moves for the full Apple Maps background" : ""
        ].filter { !$0.isEmpty }
        drawText(title, at: CGPoint(x: 24, y: 112), size: 22, bold: true, in: context)
        for (index, line) in details.enumerated() {
            drawText(line, at: CGPoint(x: 24, y: 88 - CGFloat(index) * 18), size: index == 0 ? 15 : 12, bold: index == 0, in: context)
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool, in context: CGContext) {
        let font = CTFontCreateWithName((bold ? "SFProDisplay-Semibold" : "SFProDisplay-Regular") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
