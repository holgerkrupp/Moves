#if DEBUG
import CoreLocation
import Foundation
import MapKit
import SwiftUI

private struct ExplorationDebugCell: Identifiable, Sendable {
    let cell: FogCell
    let bounds: FogCellGeographicBounds

    var id: UInt64 {
        UInt64(cell.coordinate.y) << 32 | UInt64(cell.coordinate.x)
    }

    var polygonCoordinates: [CLLocationCoordinate2D] {
        return [
            CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west),
            CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.east),
            CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east),
            CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.west)
        ]
    }
}

private struct ExplorationDebugBlock: Identifiable, Sendable {
    let id: FogBlockID
    let layers: Set<ExplorationLayer>
    let revealedCellCount: Int
}

private struct ExplorationDebugSnapshot: Sendable {
    let blocks: [ExplorationDebugBlock]
    let totalBlockCount: Int
    let totalRevealedCellCount: Int
    let layerCellCounts: [ExplorationLayer: Int]
    let shardCount: Int
}

private enum ExplorationDebugSnapshotLoader {
    static func load(rootURL: URL = ExplorationStorageLocations.rootURL) async throws -> ExplorationDebugSnapshot {
        let cache = ExplorationMergedCache(rootURL: rootURL, shardStore: ExplorationShardFileStore(rootURL: rootURL))
        let ids = try await cache.blockIDs()
        let statisticsStore = ExplorationStatisticsStore(rootURL: rootURL)
        // The statistics builder also performs country attribution over every
        // canonical cell. It is deliberately a separate, deeper debug tool;
        // the overview must remain useful immediately after a shard is
        // prepared, when the derived statistics file has just been invalidated.
        let cached = try await statisticsStore.load()
        var blocks: [ExplorationDebugBlock] = []
        blocks.reserveCapacity(min(ids.count, 5_000))
        var basicLayerCellCounts = [ExplorationLayer: Int]()
        var basicRevealedCellCount = 0
        for id in ids.prefix(5_000) {
            try Task.checkCancellation()
            guard let merged = try await cache.readBlock(id) else { continue }
            let visibleBitmap = merged.visibleBitmap()
            let visibleCount = visibleBitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            basicRevealedCellCount += visibleCount
            for layer in merged.layers {
                basicLayerCellCounts[layer.layer, default: 0] += layer.bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            }
            blocks.append(ExplorationDebugBlock(id: id, layers: Set(merged.layers.map(\.layer)), revealedCellCount: visibleCount))
        }
        let shardCount: Int
        if let cached {
            shardCount = cached.sourceShardCount
        } else {
            let shards = try await ExplorationShardFileStore(rootURL: rootURL).allShards()
            shardCount = shards.count
        }
        let layerCellCounts = cached?.layerCellCounts ?? basicLayerCellCounts

        return ExplorationDebugSnapshot(
            blocks: blocks,
            totalBlockCount: ids.count,
            totalRevealedCellCount: cached?.standardCellCount ?? basicRevealedCellCount,
            layerCellCounts: layerCellCounts,
            shardCount: shardCount
        )
    }
}

private enum ExplorationDebugCellLoader {
    static func load(
        rootURL: URL = ExplorationStorageLocations.rootURL,
        maximumCells: Int = 8_000,
        maximumBlocks: Int = 1_000,
        maximumDuration: TimeInterval = 15
    ) async throws -> [ExplorationDebugCell] {
        let cache = ExplorationMergedCache(
            rootURL: rootURL,
            shardStore: ExplorationShardFileStore(rootURL: rootURL)
        )
        let deadline = Date().addingTimeInterval(maximumDuration)
        var cells: [ExplorationDebugCell] = []
        cells.reserveCapacity(min(maximumCells, 10_000))

        let allBlockIDs = try await cache.blockIDs()
        let blockIDs: [FogBlockID]
        if allBlockIDs.count <= maximumBlocks {
            blockIDs = allBlockIDs
        } else {
            // Select blocks across the complete prepared extent. Reading the
            // first N sorted blocks can make a large history look as if only
            // one geographic corner was prepared.
            let blockStride = max(1, Int(ceil(Double(allBlockIDs.count) / Double(maximumBlocks))))
            blockIDs = Swift.stride(from: 0, to: allBlockIDs.count, by: blockStride)
                .prefix(maximumBlocks)
                .map { allBlockIDs[$0] }
        }

        for (blockIndex, id) in blockIDs.enumerated() {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ExplorationDebugMapError.timedOut }
            guard let merged = try await cache.readBlock(id) else { continue }
            let visibleBitmap = merged.visibleBitmap()
            var blockCells: [FogCell] = []
            for localY in 0..<FogBitmapBlock.width {
                for localX in 0..<FogBitmapBlock.width where visibleBitmap.isSet(x: localX, y: localY) {
                    blockCells.append(FogCell(coordinate: FogRasterCoordinate(
                        x: id.x * FogRasterV1.cellsPerBlock + UInt32(localX),
                        y: id.y * FogRasterV1.cellsPerBlock + UInt32(localY)
                    )))
                }
            }

            // Keep the complete geographic extent represented while limiting
            // MapKit to a debug-friendly number of polygons. The source and
            // merged caches remain lossless; this is presentation sampling
            // only.
            let remainingBlocks = max(blockIDs.count - blockIndex, 1)
            let blockBudget = max(1, (maximumCells - cells.count) / remainingBlocks)
            let stride = max(1, Int(ceil(Double(max(blockCells.count, 1)) / Double(blockBudget))))
            for (cellIndex, cell) in blockCells.enumerated() where cellIndex % stride == 0 {
                guard cells.count < maximumCells else { break }
                guard let bounds = try? FogRasterV1.geographicBounds(for: cell) else { continue }
                cells.append(ExplorationDebugCell(cell: cell, bounds: bounds))
            }
            if cells.count >= maximumCells { break }
        }
        return cells
    }
}

private enum ExplorationDebugMapError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Loading prepared cells timed out. The prepared cache may still be rebuilding; try opening the map again shortly."
    }
}

struct ExplorationDebugView: View {
    @State private var snapshot: ExplorationDebugSnapshot?
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Overview") {
                    if let snapshot {
                        metric("Revealed cells", snapshot.totalRevealedCellCount.formatted())
                        metric("Canonical blocks", snapshot.totalBlockCount.formatted())
                        metric("Source shards", snapshot.shardCount.formatted())
                        metric("Rendered blocks", snapshot.blocks.count.formatted())
                    } else if isRefreshing {
                        ProgressView("Loading prepared Exploration data…")
                    } else {
                        Text("No prepared Exploration data is available.")
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if let snapshot {
                    Section("Evidence layers") {
                        ForEach(ExplorationLayer.allCases, id: \.self) { layer in
                            metric(layerTitle(layer), snapshot.layerCellCounts[layer, default: 0].formatted() + " cells")
                        }
                    }

                    Section("Fog map") {
                        NavigationLink {
                            ExplorationPreparedMapDebugView()
                        } label: {
                            Label("Open prepared map", systemImage: "map.fill")
                        }
                        Text("Uses the prebuilt render hierarchy, so opening the map does not scan every canonical cell. The hierarchy is derived from the lossless source shards and merged cache.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        NavigationLink {
                            ExplorationDebugMapView()
                        } label: {
                            Label("Open exact-cell diagnostic map", systemImage: "square.grid.3x3.fill")
                        }
                    }
                }

                Section("Tools") {
                    NavigationLink {
                        ExplorationInsightsDebugView()
                    } label: {
                        Label("Statistics, passport, and milestones", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink {
                        ExplorationPreparationDebugView()
                    } label: {
                        Label("Preparation, import, and export", systemImage: "gearshape.2.fill")
                    }
                }
            }
            .navigationTitle("Exploration Debug")
            .toolbar {
                ToolbarItem {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
            }
        }
        .task {
            refresh()
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            defer { isRefreshing = false }
            do {
                snapshot = try await Task.detached(priority: .utility) {
                    try await ExplorationDebugSnapshotLoader.load()
                }.value
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Could not load prepared Exploration data: \(error.localizedDescription)"
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func layerTitle(_ layer: ExplorationLayer) -> String {
        switch layer {
        case .ground: "Ground"
        case .visits: "Visits"
        case .flight: "Flight"
        case .importedFog: "Imported Fog"
        }
    }
}

private struct ExplorationDebugMapView: View {
    @State private var position: MapCameraPosition = .automatic
    @State private var cells: [ExplorationDebugCell] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
    )

    var body: some View {
        ZStack {
            Map(position: $position) {
                ForEach(unexploredTileIDs, id: \.self) { id in
                    MapPolygon(coordinates: explorationTileCoordinates(for: id))
                        .foregroundStyle(.black.opacity(0.58))
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))

            if isLoading {
                ProgressView("Loading prepared cells…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if cells.isEmpty {
                Text("No prepared canonical cells are available yet.")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("Prepared Fog Map")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .task {
            // SwiftUI can cancel a view task while a navigation transition is
            // settling. Always clear the loading state; otherwise a cancelled
            // load leaves this screen showing an endless spinner.
            defer { isLoading = false }
            do {
                cells = try await Task.detached(priority: .utility) {
                    try await ExplorationDebugCellLoader.load()
                }.value
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Could not load prepared cells: \(error.localizedDescription)"
            }
        }
    }

    private var unexploredTileIDs: [ExplorationRenderTileID] {
        let level = explorationMapLevel(for: visibleRegion)
        let visibleIDs = explorationVisibleTileIDs(region: visibleRegion, level: level, limit: 3_000)
        let scale = UInt32(1 << Int(level))
        let exploredIDs = Set(cells.compactMap { cell -> ExplorationRenderTileID? in
            guard let address = try? FogRasterV1.address(for: cell.cell) else { return nil }
            return ExplorationRenderTileID(
                level: level,
                x: address.block.x / scale,
                y: address.block.y / scale
            )
        })
        return visibleIDs.filter { !exploredIDs.contains($0) }
    }
}
#endif
