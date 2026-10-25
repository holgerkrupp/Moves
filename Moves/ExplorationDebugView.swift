#if DEBUG
import CoreLocation
import Foundation
import MapKit
import SwiftUI

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
    var body: some View {
        ZStack(alignment: .bottom) {
            ExplorationFogMapRepresentable(region: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
            ))
        }
        .navigationTitle("Prepared Fog Map")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
#endif
