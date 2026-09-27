#if DEBUG
import Foundation
import MapKit
import SwiftUI

private struct ExplorationInsightsSnapshot: Sendable {
    let revealedCells: Int
    let standardAreaSquareMeters: Double
    let flightAreaSquareMeters: Double
    let layerCells: [ExplorationLayer: Int]
    let blockCount: Int
    let baseTileCount: Int
    let sourceCount: Int
    let datedSourceCount: Int
    let firstEvidenceDate: Date?
    let lastEvidenceDate: Date?
    let countryCellCounts: [String: Int]
    let countryNames: [String: String]
    let countryAreaSquareMeters: [String: Double]
    let countryFirstEvidenceDates: [String: Date]
    let countryLastEvidenceDates: [String: Date]
    let countryContinents: [String: ExplorationContinent]
    let regionCellCounts: [String: Int]
    let regionNames: [String: String]
    let regionCountryIDs: [String: String]
    let countryTravelStatuses: [String: ExplorationTravelStatus]
    let countryProvenance: [String: [ExplorationTravelProvenance]]
    let manualTravelEvidenceCount: Int
    let continentCellCounts: [ExplorationContinent: Int]
    let continentAreaSquareMeters: [ExplorationContinent: Double]
    let unMemberCountryCount: Int
    let broaderCountryTerritoryCount: Int
    let achievements: [ExplorationAchievement]

    var shareText: String {
        "Moves Exploration\nRevealed cells: \(revealedCells)\nExplored area: \(explorationAreaText(standardAreaSquareMeters))\nCanonical blocks: \(blockCount)\nFog base tiles: \(baseTileCount)\nCountries with evidence: \(countryCellCounts.count)\nSource shards: \(sourceCount)"
    }

    var passportShareText: String {
        let countries = countryCellCounts.keys.sorted().compactMap { countryNames[$0] }.joined(separator: ", ")
        return "Moves Exploration passport\nCountries with canonical evidence: \(countryCellCounts.count)\nExplored area: \(explorationAreaText(standardAreaSquareMeters))\n\(countries)"
    }

    var achievementShareText: String {
        let unlocked = achievements.filter(\.achieved).map(\.title).joined(separator: ", ")
        return "Moves Exploration milestones\nUnlocked: \(unlocked.isEmpty ? "None yet" : unlocked)"
    }
}

private func explorationAreaText(_ squareMeters: Double) -> String {
    Measurement(value: squareMeters / 1_000_000, unit: UnitArea.squareKilometers)
        .formatted(.measurement(width: .abbreviated, usage: .general))
}

private enum ExplorationInsightsLoader {
    static func load(
        rootURL: URL = ExplorationStorageLocations.rootURL,
        includeFlight: Bool
    ) async throws -> ExplorationInsightsSnapshot {
        if let cached = try await ExplorationStatisticsStore(rootURL: rootURL).load(),
           cached.includeFlight == includeFlight {
            let achievementState = try? await ExplorationAchievementStore(rootURL: rootURL).load()
            return ExplorationInsightsSnapshot(
                revealedCells: cached.standardCellCount,
                standardAreaSquareMeters: cached.standardAreaSquareMeters,
                flightAreaSquareMeters: cached.flightAreaSquareMeters,
                layerCells: cached.layerCellCounts,
                blockCount: cached.canonicalBlockCount,
                baseTileCount: cached.baseTileCount,
                sourceCount: cached.sourceShardCount,
                datedSourceCount: cached.datedSourceCount,
                firstEvidenceDate: cached.firstEvidenceDate,
                lastEvidenceDate: cached.lastEvidenceDate,
            countryCellCounts: cached.countryCellCounts,
            countryNames: cached.countryNames,
            countryAreaSquareMeters: cached.countryAreaSquareMeters,
            countryFirstEvidenceDates: cached.countryFirstEvidenceDates,
                countryLastEvidenceDates: cached.countryLastEvidenceDates,
                countryContinents: cached.countryContinents,
            regionCellCounts: cached.regionCellCounts,
            regionNames: cached.regionNames,
            regionCountryIDs: cached.regionCountryIDs,
                countryTravelStatuses: cached.countryTravelStatuses,
                countryProvenance: cached.countryProvenance,
                manualTravelEvidenceCount: cached.manualTravelEvidenceCount,
                continentCellCounts: cached.continentCellCounts,
                continentAreaSquareMeters: cached.continentAreaSquareMeters,
                unMemberCountryCount: cached.unMemberCountryCount,
                broaderCountryTerritoryCount: cached.broaderCountryTerritoryCount,
                achievements: achievementState?.achievements ?? ExplorationAchievementCatalog.evaluate(cached)
            )
        }
        let derived = try await Task.detached(priority: .utility) {
            try await ExplorationStatisticsBuilder.rebuild(rootURL: rootURL, includeFlight: includeFlight)
        }.value
        let achievementState = try? await ExplorationAchievementStore(rootURL: rootURL).load()
        return ExplorationInsightsSnapshot(
            revealedCells: derived.standardCellCount,
            standardAreaSquareMeters: derived.standardAreaSquareMeters,
            flightAreaSquareMeters: derived.flightAreaSquareMeters,
            layerCells: derived.layerCellCounts,
            blockCount: derived.canonicalBlockCount,
            baseTileCount: derived.baseTileCount,
            sourceCount: derived.sourceShardCount,
            datedSourceCount: derived.datedSourceCount,
            firstEvidenceDate: derived.firstEvidenceDate,
            lastEvidenceDate: derived.lastEvidenceDate,
            countryCellCounts: derived.countryCellCounts,
            countryNames: derived.countryNames,
            countryAreaSquareMeters: derived.countryAreaSquareMeters,
            countryFirstEvidenceDates: derived.countryFirstEvidenceDates,
            countryLastEvidenceDates: derived.countryLastEvidenceDates,
            countryContinents: derived.countryContinents,
            regionCellCounts: derived.regionCellCounts,
            regionNames: derived.regionNames,
            regionCountryIDs: derived.regionCountryIDs,
            countryTravelStatuses: derived.countryTravelStatuses,
            countryProvenance: derived.countryProvenance,
            manualTravelEvidenceCount: derived.manualTravelEvidenceCount,
            continentCellCounts: derived.continentCellCounts,
            continentAreaSquareMeters: derived.continentAreaSquareMeters,
            unMemberCountryCount: derived.unMemberCountryCount,
            broaderCountryTerritoryCount: derived.broaderCountryTerritoryCount,
            achievements: achievementState?.achievements ?? ExplorationAchievementCatalog.evaluate(derived)
        )

        /*
        let shards = try await ExplorationShardFileStore(rootURL: rootURL).allShards()
        var merged = [FogBlockID: [ExplorationLayer: FogBitmapBlock]]()
        var baseTiles = Set<FogBaseTileID>()
        var layerCells = [ExplorationLayer: Int]()
        var firstDate: Date?
        var lastDate: Date?
        var datedSourceCount = 0

        for shard in shards {
            try Task.checkCancellation()
            if shard.logicalStart != nil || shard.logicalEnd != nil { datedSourceCount += 1 }
            if let date = shard.logicalStart { firstDate = min(firstDate ?? date, date) }
            if let date = shard.logicalEnd { lastDate = max(lastDate ?? date, date) }
            for block in shard.blocks {
                baseTiles.insert(block.id.baseTile)
                for layer in block.layers {
                    if let current = merged[block.id]?[layer.layer] {
                        merged[block.id]?[layer.layer] = current.union(layer.bitmap)
                    } else {
                        merged[block.id, default: [:]][layer.layer] = layer.bitmap
                    }
                }
            }
        }

        var revealedCells = 0
        for layers in merged.values {
            var visible = try FogBitmapBlock()
            for (layer, bitmap) in layers {
                layerCells[layer, default: 0] += bitmap.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                if includeFlight || layer != .flight { visible = visible.union(bitmap) }
            }
            revealedCells += visible.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
        }

        return ExplorationInsightsSnapshot(
            revealedCells: revealedCells,
            layerCells: layerCells,
            blockCount: merged.count,
            baseTileCount: baseTiles.count,
            sourceCount: shards.count,
            datedSourceCount: datedSourceCount,
            firstEvidenceDate: firstDate,
            lastEvidenceDate: lastDate
        )
        */
    }
}

struct ExplorationInsightsDebugView: View {
    @State private var snapshot: ExplorationInsightsSnapshot?
    @State private var errorMessage: String?
    @AppStorage("Moves.exploration.includeFlightInStandardCoverage") private var includeFlight = false

    var body: some View {
        List {
            if let snapshot {
                Section("Exploration statistics") {
                    metric("Revealed cells", snapshot.revealedCells.formatted())
                    metric("Explored area", areaText(snapshot.standardAreaSquareMeters))
                    metric("Flight area (separate)", areaText(snapshot.flightAreaSquareMeters))
                    metric("Canonical blocks", snapshot.blockCount.formatted())
                    metric("Fog base tiles", snapshot.baseTileCount.formatted())
                    metric("Source shards", snapshot.sourceCount.formatted())
                    metric("Dated sources", snapshot.datedSourceCount.formatted())
                }

                Section("Evidence") {
                    ForEach(ExplorationLayer.allCases, id: \.self) { layer in
                        metric(layerName(layer), snapshot.layerCells[layer, default: 0].formatted())
                    }
                    if let firstEvidenceDate = snapshot.firstEvidenceDate {
                        metric("First dated evidence", firstEvidenceDate.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let lastEvidenceDate = snapshot.lastEvidenceDate {
                        metric("Last dated evidence", lastEvidenceDate.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                Section("Countries") {
                    NavigationLink {
                        ExplorationManualTravelDebugView()
                    } label: {
                        Label("Edit manual travel evidence", systemImage: "pencil.and.list.clipboard")
                    }
                    NavigationLink {
                        ExplorationPassportDebugView(stamps: ExplorationPassportBuilder.stamps(
                            countryCellCounts: snapshot.countryCellCounts,
                            countryNames: snapshot.countryNames,
                            countryAreaSquareMeters: snapshot.countryAreaSquareMeters,
                            countryFirstEvidenceDates: snapshot.countryFirstEvidenceDates,
                            countryLastEvidenceDates: snapshot.countryLastEvidenceDates,
                            countryTravelStatuses: snapshot.countryTravelStatuses,
                            countryProvenance: snapshot.countryProvenance,
                            firstEvidenceDate: snapshot.firstEvidenceDate,
                            lastEvidenceDate: snapshot.lastEvidenceDate
                        ))
                    } label: {
                        Label("Open country passport", systemImage: "book.closed.fill")
                    }
                    NavigationLink {
                        ExplorationCountryMapDebugView(
                            countryIDs: Set(snapshot.countryCellCounts.keys).union(snapshot.countryTravelStatuses.keys),
                            countryCellCounts: snapshot.countryCellCounts,
                            countryNames: snapshot.countryNames
                        )
                    } label: {
                        Label("Open visited-country map", systemImage: "globe.europe.africa.fill")
                    }
                    metric("Countries with evidence", snapshot.countryCellCounts.count.formatted())
                    metric("UN member countries", snapshot.unMemberCountryCount.formatted())
                    metric("Territories / broader entities", snapshot.broaderCountryTerritoryCount.formatted())
                    metric("Regions with evidence", snapshot.regionCellCounts.count.formatted())
                    metric("Manual travel records", snapshot.manualTravelEvidenceCount.formatted())
                    if snapshot.countryCellCounts.isEmpty {
                        Text("Country attribution is not ready yet, or the offline boundary dataset was unavailable during the last rebuild.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.countryCellCounts.keys.sorted {
                            let left = snapshot.countryCellCounts[$0, default: 0]
                            let right = snapshot.countryCellCounts[$1, default: 0]
                            return left == right ? $0 < $1 : left > right
                        }.prefix(10), id: \.self) { id in
                            NavigationLink {
                                ExplorationCountryDetailDebugView(
                                    countryID: id,
                                    countryName: snapshot.countryNames[id] ?? id,
                                    continent: snapshot.countryContinents[id] ?? .other,
                                    cellCount: snapshot.countryCellCounts[id, default: 0],
                                    areaSquareMeters: snapshot.countryAreaSquareMeters[id, default: 0],
                                    firstEvidenceDate: snapshot.countryFirstEvidenceDates[id],
                                    lastEvidenceDate: snapshot.countryLastEvidenceDates[id],
                                    travelStatus: snapshot.countryTravelStatuses[id, default: .notVisited],
                                    provenance: snapshot.countryProvenance[id, default: []]
                                )
                            } label: {
                                HStack {
                                    Text(snapshot.countryNames[id] ?? id)
                                    Spacer()
                                    Text(snapshot.countryCellCounts[id, default: 0].formatted())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if snapshot.countryCellCounts.count > 10 {
                            Text("Showing the ten largest entries in this debug summary.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Continents") {
                    if snapshot.continentCellCounts.isEmpty {
                        Text("No continent attribution is available yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ExplorationContinent.allCases.filter { snapshot.continentCellCounts[$0] != nil }, id: \.self) { continent in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(continent.rawValue)
                                    Spacer()
                                    Text(snapshot.continentCellCounts[continent, default: 0].formatted())
                                        .foregroundStyle(.secondary)
                                }
                                Text(areaText(snapshot.continentAreaSquareMeters[continent, default: 0]))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Country and continent grouping is a presentation policy layered over the canonical raster; it does not change cell addresses.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Policy") {
                    Toggle("Include flight in normal coverage", isOn: $includeFlight)
                    Text("Flight evidence remains stored separately. The toggle only changes the derived coverage total and future statistics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Administrative regions") {
                    if snapshot.regionCellCounts.isEmpty {
                        Text("No first-level region evidence is available yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.regionCellCounts.keys.sorted {
                            let left = snapshot.regionCellCounts[$0, default: 0]
                            let right = snapshot.regionCellCounts[$1, default: 0]
                            return left == right ? $0 < $1 : left > right
                        }.prefix(10), id: \.self) { id in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(snapshot.regionNames[id] ?? id)
                                    Text(snapshot.regionCountryIDs[id] ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(snapshot.regionCellCounts[id, default: 0].formatted())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Milestones") {
                    ForEach(snapshot.achievements) { achievement in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(achievement.title, systemImage: achievement.achieved ? achievement.symbolName : "circle")
                                .foregroundStyle(achievement.achieved ? .green : .secondary)
                                .help(achievement.detail)
                            Text(achievement.localizationKey)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            if let unlockedAt = achievement.unlockedAt {
                                Text("Unlocked \(unlockedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: achievement.progress)
                        }
                    }
                }

                Section("Debug sharing") {
                    ShareLink(item: snapshot.shareText) {
                        Label("Share statistics", systemImage: "square.and.arrow.up")
                    }
                    ShareLink(item: snapshot.passportShareText) {
                        Label("Share country passport summary", systemImage: "book.closed")
                    }
                    ShareLink(item: snapshot.achievementShareText) {
                        Label("Share achievement summary", systemImage: "seal")
                    }
                    Text("This shares aggregate debug numbers only. It does not share route geometry or source shards.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                ProgressView("Loading statistics…")
            }
        }
        .navigationTitle("Exploration Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: includeFlight) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        do {
            snapshot = try await ExplorationInsightsLoader.load(includeFlight: includeFlight)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "Could not calculate Exploration statistics: \(error.localizedDescription)"
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private func areaText(_ squareMeters: Double) -> String {
        explorationAreaText(squareMeters)
    }

    private func layerName(_ layer: ExplorationLayer) -> String {
        switch layer {
        case .ground: "Ground"
        case .visits: "Visits"
        case .flight: "Flight"
        case .importedFog: "Imported Fog"
        }
    }
}

private struct ExplorationPassportDebugView: View {
    let stamps: [ExplorationPassportStamp]

    var body: some View {
        List {
            if stamps.isEmpty {
                ContentUnavailableView("No country stamps yet", systemImage: "book.closed", description: Text("Rebuild prepared statistics after canonical blocks are available."))
            } else {
                ForEach(stamps) { stamp in
                    VStack(alignment: .leading, spacing: 8) {
                        ExplorationStampCard(stamp: stamp)
                        Text("\(stamp.exploredCellCount.formatted()) cells · \(areaText(stamp.exploredAreaSquareMeters))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Status: \(stamp.status.rawValue) · \(stamp.provenance.map(\.rawValue).joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let range = stamp.evidenceRange {
                            Text("Evidence: \(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) – \(range.upperBound.formatted(date: .abbreviated, time: .omitted))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(stamp.isManualOnly ? "Manual travel evidence; no raster cells were fabricated." : "Canonical evidence and travel status are kept separate.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Debug Passport")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func areaText(_ squareMeters: Double) -> String {
        Measurement(value: squareMeters / 1_000_000, unit: UnitArea.squareKilometers)
            .formatted(.measurement(width: .abbreviated, usage: .general))
    }
}

private struct ExplorationCountryDetailDebugView: View {
    let countryID: String
    let countryName: String
    let continent: ExplorationContinent
    let cellCount: Int
    let areaSquareMeters: Double
    let firstEvidenceDate: Date?
    let lastEvidenceDate: Date?
    let travelStatus: ExplorationTravelStatus
    let provenance: [ExplorationTravelProvenance]

    var body: some View {
        List {
            Section("Country") {
                LabeledContent("Name", value: countryName)
                LabeledContent("ISO / source ID", value: countryID)
                LabeledContent("Continent", value: continent.rawValue)
                LabeledContent("Travel status", value: travelStatus.rawValue.capitalized)
            }
            Section("Canonical evidence") {
                LabeledContent("Explored cells", value: cellCount.formatted())
                LabeledContent("Explored area", value: explorationAreaText(areaSquareMeters))
                if let firstEvidenceDate {
                    LabeledContent("First dated evidence", value: firstEvidenceDate.formatted(date: .abbreviated, time: .omitted))
                }
                if let lastEvidenceDate {
                    LabeledContent("Last dated evidence", value: lastEvidenceDate.formatted(date: .abbreviated, time: .omitted))
                }
                NavigationLink("Show matching dated days") {
                    ExplorationCountryPresenceDebugView(countryID: countryID, countryName: countryName)
                }
            }
            Section("Provenance") {
                if provenance.isEmpty {
                    Text("No provenance was recorded for this entry.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(provenance, id: \.self) { item in
                        Text(item.rawValue.capitalized)
                    }
                }
            }
            Text("This debug detail is derived from the prepared snapshot. It does not fabricate route history or change the canonical raster.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(countryName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExplorationCountryMapShape: Identifiable {
    let id: String
    let name: String
    let cellCount: Int
    let rings: [[ExplorationGeographicCoordinate]]
}

private struct ExplorationCountryMapDebugView: View {
    let countryIDs: Set<String>
    let countryCellCounts: [String: Int]
    let countryNames: [String: String]
    @State private var shapes: [ExplorationCountryMapShape] = []
    @State private var errorMessage: String?
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
        )
    )

    var body: some View {
        Group {
            if shapes.isEmpty {
                ContentUnavailableView("No country boundaries", systemImage: "globe", description: Text(errorMessage ?? "No prepared country attribution is available yet."))
            } else {
                Map(position: $position) {
                    ForEach(shapes) { shape in
                        ForEach(Array(shape.rings.enumerated()), id: \.offset) { _, ring in
                            MapPolygon(coordinates: ring.map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
                            .foregroundStyle(.mint.opacity(0.22))
                            .stroke(.mint.opacity(0.7), lineWidth: 0.5)
                        }
                    }
                }
                .mapStyle(.standard)
                .overlay(alignment: .bottom) {
                    Text("Showing \(shapes.count) attributed countries; color represents prepared evidence presence, not political ownership.")
                        .font(.footnote)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            }
        }
        .navigationTitle("Visited Countries")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        let ids = countryIDs.sorted()
        do {
            shapes = try await Task.detached(priority: .utility) {
                let resolver = try ExplorationCountryResolver.bundled()
                return ids.compactMap { id -> ExplorationCountryMapShape? in
                    let rings = resolver.boundaryRings(for: id).map { ring in
                        ring.map { ExplorationGeographicCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
                    }
                    guard !rings.isEmpty else { return nil }
                    return ExplorationCountryMapShape(
                        id: id,
                        name: countryNames[id] ?? id,
                        cellCount: countryCellCounts[id, default: 0],
                        rings: rings
                    )
                }
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ExplorationCountryPresenceDebugView: View {
    let countryID: String
    let countryName: String
    @State private var entries: [ExplorationCountryPresenceEntry] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if entries.isEmpty {
                Text(errorMessage ?? "No dated country presence is prepared yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                            .font(.headline)
                        Text("Matching prepared day: \(entry.dayKey)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Canonical cells in this country: \(entry.countryCellCounts[countryID, default: 0].formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("\(countryName) Days")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let store = ExplorationCountryPresenceIndexStore()
            if try await store.load() == nil {
                _ = try await store.rebuild()
            }
            let dayKeys = try await store.dayKeys(for: countryID)
            entries = try await withThrowingTaskGroup(of: ExplorationCountryPresenceEntry?.self) { group in
                for dayKey in dayKeys {
                    group.addTask { try await store.presence(for: countryID, dayKey: dayKey) }
                }
                var values = [ExplorationCountryPresenceEntry]()
                for try await value in group {
                    if let value { values.append(value) }
                }
                return values.sorted { $0.date == $1.date ? $0.dayKey < $1.dayKey : $0.date < $1.date }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ExplorationStampCard: View {
    let stamp: ExplorationPassportStamp

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                stampShape
                    .stroke(
                        ink,
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: recipe.border == .dashed ? [3, 2] : recipe.border == .segmented ? [7, 2] : []
                        )
                    )
                    .frame(width: 76, height: 76)
                    .rotationEffect(.degrees(recipe.rotationDegrees))
                VStack(spacing: 1) {
                    Image(systemName: recipe.glyph)
                        .font(.caption)
                    Text(stamp.countryID)
                        .font(.caption2.weight(.bold))
                    Text(stamp.status.rawValue.uppercased())
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(ink)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(stamp.countryName)
                    .font(.headline)
                Text(stamp.provenance.map(\.rawValue).joined(separator: " · ").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recipe: ExplorationStampRecipe { stamp.recipe }

    private var ink: Color {
        Color(red: recipe.inkRed, green: recipe.inkGreen, blue: recipe.inkBlue)
            .opacity(0.72 + recipe.wear * 0.2)
    }

    private var stampShape: AnyShape {
        switch recipe.shape {
        case .circle: return AnyShape(Circle())
        case .oval: return AnyShape(Capsule())
        case .ticket: return AnyShape(RoundedRectangle(cornerRadius: 12))
        case .octagon:
            return AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct ExplorationManualTravelDebugView: View {
    @State private var countries: [ExplorationCountry] = []
    @State private var records: [ExplorationManualTravelEvidence] = []
    @State private var selectedCountryID = ""
    @State private var selectedStatus: ExplorationTravelStatus = .visited
    @State private var note = ""
    @State private var date = Date.now
    @State private var hasDate = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Add manual evidence") {
                if countries.isEmpty {
                    Text("Country dataset unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Country", selection: $selectedCountryID) {
                        ForEach(countries) { country in
                            Text(country.name).tag(country.id)
                        }
                    }
                    Picker("Status", selection: $selectedStatus) {
                        ForEach(ExplorationTravelStatus.allCases, id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(status)
                        }
                    }
                    Toggle("Date known", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                    }
                    TextField("Note (optional)", text: $note)
                    Button("Add manual record") {
                        addRecord()
                    }
                    .disabled(selectedCountryID.isEmpty)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section("Saved records") {
                if records.isEmpty {
                    Text("No manual travel records.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.countryName).font(.headline)
                            Text("\(record.status.rawValue.capitalized) · \(record.date?.formatted(date: .abbreviated, time: .omitted) ?? "date unknown")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let note = record.note, !note.isEmpty {
                                Text(note).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                remove(record)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Manual Travel")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let resolvedCountries = try await Task.detached(priority: .utility) {
                try ExplorationCountryResolver.bundled().availableCountries
            }.value
            countries = resolvedCountries
            if selectedCountryID.isEmpty { selectedCountryID = countries.first?.id ?? "" }
            records = try await ExplorationTravelEvidenceStore().load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addRecord() {
        guard let country = countries.first(where: { $0.id == selectedCountryID }) else { return }
        let record = ExplorationManualTravelEvidence(
            countryID: country.id,
            countryName: country.name,
            status: selectedStatus,
            date: hasDate ? date : nil,
            note: note.isEmpty ? nil : note
        )
        Task {
            do {
                let store = ExplorationTravelEvidenceStore()
                try await store.upsert(record)
                try await ExplorationStatisticsStore().remove()
                await MainActor.run {
                    records.append(record)
                    note = ""
                    hasDate = false
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func remove(_ record: ExplorationManualTravelEvidence) {
        Task {
            do {
                try await ExplorationTravelEvidenceStore().remove(id: record.id)
                try await ExplorationStatisticsStore().remove()
                await MainActor.run { records.removeAll { $0.id == record.id } }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}
#endif
