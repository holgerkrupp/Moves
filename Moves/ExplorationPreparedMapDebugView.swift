#if DEBUG
import CoreLocation
import CoreGraphics
import ImageIO
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Actor-owned, bounded provider shared by one persistent MapKit overlay.
/// MapKit requests georeferenced XYZ tiles directly from the same Web Mercator
/// world used by FogRasterV1; camera movement never changes the overlay frame.
struct ExplorationFogPresentationStyle: Sendable, Equatable {
    var fogOpacity: UInt8
    /// Width of the antialiased transition around a mask edge, as a fraction
    /// of coverage. This affects only presentation alpha, not canonical cells.
    var edgeTransition: Double

    static let `default` = ExplorationFogPresentationStyle(fogOpacity: 160, edgeTransition: 0.2)
}

actor ExplorationFogTileProvider {
    private struct Key: Hashable { let z: Int; let x: Int; let y: Int; let flight: Bool }
    private struct Entry { let data: Data; var access: UInt64 }
    private let cache: ExplorationRenderTileCache
    private let mergedCache: ExplorationMergedCache
    private let hierarchy: ExplorationRenderHierarchy
    private let capacity: Int
    private var images: [Key: Entry] = [:]
    private var access: UInt64 = 0
    private var checkedRecovery = false
    private var includeFlights = false
    private var requestGeneration: UInt64 = 0
    private let style: ExplorationFogPresentationStyle

    init(
        rootURL: URL = ExplorationStorageLocations.rootURL,
        capacity: Int = 96,
        style: ExplorationFogPresentationStyle = .default
    ) {
        let hierarchy = ExplorationRenderHierarchy(rootURL: rootURL)
        self.hierarchy = hierarchy
        cache = ExplorationRenderTileCache(hierarchy: hierarchy, capacity: capacity)
        mergedCache = ExplorationMergedCache(rootURL: rootURL, shardStore: ExplorationShardFileStore(rootURL: rootURL))
        self.capacity = max(1, capacity)
        self.style = style
    }

    func setIncludeFlights(_ value: Bool) {
        guard includeFlights != value else { return }
        includeFlights = value
        images.removeAll(keepingCapacity: true)
        Task { await cache.removeAll() }
    }

    func currentRequestGeneration() -> UInt64 { requestGeneration }

    func cancelObsoleteRequests() { requestGeneration &+= 1 }

    func tileData(x rawX: Int, y rawY: Int, z: Int, generation: UInt64) async throws -> Data {
        try check(generation)
        if !checkedRecovery {
            checkedRecovery = true
            do {
                try await mergedCache.retryDirtyRenderTiles()
            } catch {
                checkedRecovery = false
                throw error
            }
        }
        try check(generation)
        let zoom = min(max(z, 0), 22)
        let dimension = 1 << zoom
        let x = ((rawX % dimension) + dimension) % dimension
        let y = min(max(rawY, 0), dimension - 1)
        if zoom >= 13 {
            try await backfillVisibleRenderTileIfNeeded(x: x, y: y, z: zoom, generation: generation)
        }
        let key = Key(z: zoom, x: x, y: y, flight: includeFlights)
        access &+= 1
        if var entry = images[key] {
            entry.access = access
            images[key] = entry
            return entry.data
        }

        let selection = try await coverageFor(x: x, y: y, z: zoom, includeFlights: includeFlights, generation: generation)
        try check(generation)
        let data = Self.png(mask: selection.mask, crop: selection.crop, style: style)
        images[key] = Entry(data: data, access: access)
        if images.count > capacity {
            let removeCount = images.count - capacity
            for victim in images.sorted(by: { $0.value.access < $1.value.access }).prefix(removeCount).map(\.key) {
                images.removeValue(forKey: victim)
            }
        }
        return data
    }

    func invalidate() {
        images.removeAll(keepingCapacity: true)
        Task { await cache.removeAll() }
    }

    private struct Selection { let mask: Data?; let crop: CGRect }

    /// Older prepared installs may have canonical merged blocks but no render
    /// pyramid yet. Materialize only the requested neighborhood tile from
    /// those blocks; never enumerate the source history when opening the map.
    private func backfillVisibleRenderTileIfNeeded(x: Int, y: Int, z: Int, generation: UInt64) async throws {
        let renderID: ExplorationRenderTileID
        let blockOriginX: Int
        let blockOriginY: Int
        let blockSide: Int
        if z <= 16 {
            let level = 16 - z
            renderID = ExplorationRenderTileID(level: UInt8(level), x: UInt32(x), y: UInt32(y))
            blockSide = 1 << level
            blockOriginX = x * blockSide
            blockOriginY = y * blockSide
        } else {
            let extra = z - 16
            blockOriginX = x >> extra
            blockOriginY = y >> extra
            blockSide = 1
            renderID = ExplorationRenderTileID(level: 0, x: UInt32(blockOriginX), y: UInt32(blockOriginY))
        }
        if try await cache.read(renderID) != nil { return }
        try check(generation)

        var blockIDs = [FogBlockID]()
        blockIDs.reserveCapacity(blockSide * blockSide)
        for offsetY in 0..<blockSide {
            for offsetX in 0..<blockSide {
                blockIDs.append(FogBlockID(x: UInt32(blockOriginX + offsetX), y: UInt32(blockOriginY + offsetY)))
            }
        }
        let existing = try await mergedCache.renderBlocks(blockIDs)
        try check(generation)
        guard !existing.isEmpty else { return }
        try await hierarchy.rebuild(affectedBlocks: existing.keys, cache: mergedCache)
        try check(generation)
        await cache.removeAll()
    }

    private func coverageFor(x: Int, y: Int, z: Int, includeFlights: Bool, generation: UInt64) async throws -> Selection {
        if z > 16 {
            let extra = z - 16
            let blockX = UInt32(x >> extra), blockY = UInt32(y >> extra)
            let subX = x % (1 << extra), subY = y % (1 << extra)
            let crop = CGRect(x: Double(subX) / Double(1 << extra), y: Double(subY) / Double(1 << extra),
                              width: 1 / Double(1 << extra), height: 1 / Double(1 << extra))
            let tile = try await cache.read(ExplorationRenderTileID(level: 0, x: blockX, y: blockY))
            try check(generation)
            return Selection(mask: tile.map { includeFlights ? Self.combined($0.standardMask, $0.flightMask) : $0.standardMask }, crop: crop)
        }

        var level = 16 - z
        var tileX = UInt32(x), tileY = UInt32(y)
        var divisions = 1
        while level <= 16 {
            let id = ExplorationRenderTileID(level: UInt8(level), x: tileX, y: tileY)
            if let tile = try await cache.read(id) {
                try check(generation)
                let offsetX = x % divisions
                let offsetY = y % divisions
                let crop = CGRect(x: Double(offsetX) / Double(divisions), y: Double(offsetY) / Double(divisions),
                                  width: 1 / Double(divisions), height: 1 / Double(divisions))
                return Selection(mask: includeFlights ? Self.combined(tile.standardMask, tile.flightMask) : tile.standardMask, crop: crop)
            }
            try check(generation)
            level += 1
            tileX /= 2
            tileY /= 2
            divisions *= 2
        }
        return Selection(mask: nil, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func check(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
    }

    private static func combined(_ standard: Data, _ flight: Data) -> Data {
        guard standard.count == 4096, flight.count == 4096 else { return Data(repeating: 0, count: 4096) }
        return Data(zip(standard, flight).map { max($0.0, $0.1) })
    }

    private static func png(mask: Data?, crop: CGRect, style: ExplorationFogPresentationStyle) -> Data {
        let side = 256
        let coverage = mask.map(Array.init) ?? [UInt8](repeating: 0, count: 4096)
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        func sample(_ u: Double, _ v: Double) -> Double {
            guard coverage.count == 4096 else { return 0 }
            let sx = min(max((crop.minX + u * crop.width) * 64 - 0.5, 0), 63)
            let sy = min(max((crop.minY + v * crop.height) * 64 - 0.5, 0), 63)
            let x0 = Int(sx), y0 = Int(sy), x1 = min(x0 + 1, 63), y1 = min(y0 + 1, 63)
            let fx = sx - Double(x0), fy = sy - Double(y0)
            let a = Double(coverage[y0 * 64 + x0]) * (1 - fx) + Double(coverage[y0 * 64 + x1]) * fx
            let b = Double(coverage[y1 * 64 + x0]) * (1 - fx) + Double(coverage[y1 * 64 + x1]) * fx
            return a * (1 - fy) + b * fy
        }
        for y in 0..<side {
            for x in 0..<side {
                let covered = sample((Double(x) + 0.5) / Double(side), (Double(y) + 0.5) / Double(side))
                let index = (y * side + x) * 4
                let normalized = covered / 255
                let transition = min(max(style.edgeTransition, 0.001), 1)
                let lower = 0.5 - transition / 2
                let t = min(max((normalized - lower) / transition, 0), 1)
                let smoothCoverage = t * t * (3 - 2 * t)
                rgba[index + 3] = UInt8((Double(style.fogOpacity) * (1 - smoothCoverage)).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return Data()
        }
        let output = NSMutableData()
        guard let pngDestination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(pngDestination, image, nil)
        guard CGImageDestinationFinalize(pngDestination) else { return Data() }
        return output as Data
    }
}

private final class ExplorationFogMKTileOverlay: MKTileOverlay, @unchecked Sendable {
    let provider: ExplorationFogTileProvider
    init(provider: ExplorationFogTileProvider) {
        self.provider = provider
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 22
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        Task {
            do {
                let generation = await provider.currentRequestGeneration()
                result(try await provider.tileData(x: path.x, y: path.y, z: path.z, generation: generation), nil)
            } catch {
                // Missing/corrupt derived data is fogged safely while the
                // durable hierarchy retry path repairs the artifact.
                result(ExplorationFogTileProvider.fogFallbackData, nil)
            }
        }
    }
}

private extension ExplorationFogTileProvider {
    static var fogFallbackData: Data {
        png(mask: nil, crop: CGRect(x: 0, y: 0, width: 1, height: 1), style: .default)
    }
}

#if os(iOS)
struct ExplorationFogMapRepresentable: UIViewRepresentable {
    let region: MKCoordinateRegion
    var includeFlights = false
    var satellite = false
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.mapType = satellite ? .satellite : .standard
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        map.setRegion(region, animated: false)
        map.delegate = context.coordinator
        context.coordinator.install(on: map, includeFlights: includeFlights)
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        map.mapType = satellite ? .satellite : .standard
        context.coordinator.install(on: map, includeFlights: includeFlights)
    }
    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        private var overlay: ExplorationFogMKTileOverlay?
        private var tileRenderer: MKTileOverlayRenderer?
        private var updateObserver: NSObjectProtocol?
        private var currentFlights = false
        deinit { if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) } }
        func install(on map: MKMapView, includeFlights: Bool) {
            if overlay == nil {
                let overlay = ExplorationFogMKTileOverlay(provider: ExplorationFogTileProvider())
                self.overlay = overlay
                map.addOverlay(overlay, level: .aboveLabels)
                updateObserver = NotificationCenter.default.addObserver(forName: .explorationRenderTilesDidUpdate, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        let provider = self?.overlay?.provider
                        await provider?.invalidate()
                        self?.tileRenderer?.reloadData()
                    }
                }
            }
            if currentFlights != includeFlights {
                currentFlights = includeFlights
                let provider = overlay?.provider
                Task { @MainActor [weak self] in
                    await provider?.setIncludeFlights(includeFlights)
                    self?.tileRenderer?.reloadData()
                }
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                tileRenderer = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let provider = overlay?.provider
            Task { await provider?.cancelObsoleteRequests() }
        }
    }
}
#elseif os(macOS)
struct ExplorationFogMapRepresentable: NSViewRepresentable {
    let region: MKCoordinateRegion
    var includeFlights = false
    var satellite = false
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.mapType = satellite ? .satellite : .standard
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        map.setRegion(region, animated: false)
        map.delegate = context.coordinator
        context.coordinator.install(on: map, includeFlights: includeFlights)
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) {
        map.mapType = satellite ? .satellite : .standard
        context.coordinator.install(on: map, includeFlights: includeFlights)
    }
    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        private var overlay: ExplorationFogMKTileOverlay?
        private var tileRenderer: MKTileOverlayRenderer?
        private var updateObserver: NSObjectProtocol?
        private var currentFlights = false
        deinit { if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) } }
        func install(on map: MKMapView, includeFlights: Bool) {
            if overlay == nil {
                let overlay = ExplorationFogMKTileOverlay(provider: ExplorationFogTileProvider())
                self.overlay = overlay
                map.addOverlay(overlay, level: .aboveLabels)
                updateObserver = NotificationCenter.default.addObserver(forName: .explorationRenderTilesDidUpdate, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        let provider = self?.overlay?.provider
                        await provider?.invalidate()
                        self?.tileRenderer?.reloadData()
                    }
                }
            }
            if currentFlights != includeFlights {
                currentFlights = includeFlights
                let provider = overlay?.provider
                Task { @MainActor [weak self] in
                    await provider?.setIncludeFlights(includeFlights)
                    self?.tileRenderer?.reloadData()
                }
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                tileRenderer = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let provider = overlay?.provider
            Task { await provider?.cancelObsoleteRequests() }
        }
    }
}
#endif

struct ExplorationPreparedMapDebugView: View {
    @State private var includeFlights = false
    @State private var satellite = false
    @State private var message: String?
    var body: some View {
        ZStack(alignment: .bottom) {
            ExplorationFogMapRepresentable(region: initialRegion, includeFlights: includeFlights, satellite: satellite)
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Include flights", isOn: $includeFlights)
                    .toggleStyle(.switch)
                Picker("Map style", selection: $satellite) {
                    Text("Standard").tag(false)
                    Text("Satellite").tag(true)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 240)
            .frame(maxHeight: .infinity, alignment: .topTrailing)
            .padding()
            if let message {
                Text(message)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Prepared Fog Map")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            message = "Fog is anchored to map tiles. Unprepared areas remain fogged."
        }
    }

    private var initialRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
        )
    }
}
#endif
