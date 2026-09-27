#if DEBUG
import CoreLocation
import Foundation
import MapKit
import SwiftUI

private struct ExplorationDebugBlock: Identifiable, Sendable {
    let id: FogBlockID
    let layers: Set<ExplorationLayer>
    let revealedCellCount: Int

    var polygonCoordinates: [CLLocationCoordinate2D] {
        let dimension = Double(FogRasterV1.globalCellDimension)
        let minX = Double(id.x * FogRasterV1.cellsPerBlock)
        let minY = Double(id.y * FogRasterV1.cellsPerBlock)
        let maxX = minX + Double(FogRasterV1.cellsPerBlock)
        let maxY = minY + Double(FogRasterV1.cellsPerBlock)

        func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
            let longitude = x / dimension * 360 - 180
            let latitude = atan(sinh(.pi - 2 * .pi * y / dimension)) * 180 / .pi
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        return [
            coordinate(x: minX, y: minY),
            coordinate(x: maxX, y: minY),
            coordinate(x: maxX, y: maxY),
            coordinate(x: minX, y: maxY)
        ]
    }
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
        let derived: ExplorationDerivedStatistics
        if let cached = try await statisticsStore.load() {
            derived = cached
        } else {
            derived = try await Task.detached(priority: .utility) {
                try await ExplorationStatisticsBuilder.rebuild(rootURL: rootURL)
            }.value
        }
        var blocks: [ExplorationDebugBlock] = []
        blocks.reserveCapacity(min(ids.count, 5_000))
        for id in ids.prefix(5_000) {
            try Task.checkCancellation()
            guard let merged = try await cache.readBlock(id) else { continue }
            let visibleCount = merged.visibleBitmap().bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            blocks.append(ExplorationDebugBlock(id: id, layers: Set(merged.layers.map(\.layer)), revealedCellCount: visibleCount))
        }
        let shardCount = derived.sourceShardCount
        let layerCellCounts = derived.layerCellCounts

        return ExplorationDebugSnapshot(
            blocks: blocks,
            totalBlockCount: ids.count,
            totalRevealedCellCount: derived.standardCellCount,
            layerCellCounts: layerCellCounts,
            shardCount: shardCount
        )
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
                            ExplorationDebugMapView(snapshot: snapshot)
                        } label: {
                            Label("Open prepared map", systemImage: "map.fill")
                        }
                        Text("The debug renderer displays up to 5,000 canonical blocks and keeps the full block count above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        NavigationLink {
                            ExplorationPreparedMapDebugView()
                        } label: {
                            Label("Open prepared hierarchy map", systemImage: "square.grid.3x3.fill")
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
                ToolbarItem(placement: .topBarTrailing) {
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
                snapshot = try await ExplorationDebugSnapshotLoader.load()
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
    let snapshot: ExplorationDebugSnapshot
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(snapshot.blocks) { block in
                MapPolygon(coordinates: block.polygonCoordinates)
                    .foregroundStyle(.mint.opacity(block.layers.contains(.importedFog) ? 0.65 : 0.4))
                    .stroke(.mint.opacity(0.8), lineWidth: 0.5)
            }
        }
        .mapStyle(.standard)
        .navigationTitle("Prepared Fog Map")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
