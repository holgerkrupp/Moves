import CoreGraphics
import Foundation
import QuickLookThumbnailing
import RouteFileKit
import RoutePreviewKit

#if os(macOS)
import AppKit
#endif

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let fileURL = request.fileURL
        let size = request.maximumSize
        Task {
            do {
                try Task.checkCancellation()
                let didAccess = fileURL.startAccessingSecurityScopedResource()
                defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }
                let tracks = try RouteFileParser.parse(url: fileURL)
                #if os(macOS)
                let appearance: RoutePreviewAppearance = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
                #else
                let appearance: RoutePreviewAppearance = .light
                #endif
                #if os(macOS)
                let background: RoutePreviewBackground
                if #available(macOS 15.0, *) {
                    background = .routeOnly
                } else {
                    background = .map
                }
                #else
                let background: RoutePreviewBackground = .map
                #endif
                let sourceData = try Data(contentsOf: fileURL)
                let cachedImage = RoutePreviewCache.image(for: sourceData, appearance: appearance)
                    ?? (appearance == .dark ? RoutePreviewCache.image(for: sourceData, appearance: .light) : nil)
                let image: CGImage
                if let cachedImage {
                    image = cachedImage
                } else {
                    image = try await RoutePreviewRenderer().render(RoutePreviewRequest(
                        tracks: tracks,
                        canvasSize: size,
                        scale: request.scale,
                        appearance: appearance,
                        background: background,
                        pointBudget: max(100, min(1_500, Int(size.width * size.height / 8)))
                    )).image
                }
                try Task.checkCancellation()
                handler(QLThumbnailReply(contextSize: size, drawing: { context in
                    context.draw(image, in: CGRect(origin: .zero, size: size))
                    return true
                }), nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
