import CoreLocation
import Foundation
import os
import SwiftData

enum RegularPlacesSignposting {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "Moves", category: "RegularPlaces")
}

struct RegularPlaceOverview: Sendable {
    struct Candidate: Identifiable, Sendable {
        var id: String { clusterKey }
        let clusterKey: String
        let latitude: Double
        let longitude: Double
        let visitCount: Int
        let totalDuration: TimeInterval
    }

    struct LegacyVisit: Identifiable, Sendable {
        let id: UUID
        let date: Date
        let label: String
    }

    let countsByKnownLocationID: [UUID: Int]
    let unnamedCandidates: [Candidate]
    let legacyCandidateCount: Int
    let initialLegacyCandidates: [LegacyVisit]
}

struct RegularPlaceVisitSummary: Identifiable, Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let arrivalDate: Date
    let departureDate: Date?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct RegularPlaceVisitPage: Sendable {
    let totalCount: Int
    let visits: [RegularPlaceVisitSummary]
}

@ModelActor
actor RegularPlacesWorker {
    private static let batchSize = 500
    private static let candidateLimit = 40
    private static let legacyLimit = 50

    func overview(for knownLocations: [KnownLocationValue]) throws -> RegularPlaceOverview {
        let interval = RegularPlacesSignposting.signposter.beginInterval("OverviewAggregation")
        defer { RegularPlacesSignposting.signposter.endInterval("OverviewAggregation", interval) }
        var counts = Dictionary(uniqueKeysWithValues: knownLocations.map { ($0.id, 0) })
        var clusters: [String: Cluster] = [:]
        var legacy: [RegularPlaceOverview.LegacyVisit] = []
        var legacyCount = 0
        var offset = 0

        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batchSize
            let batch = try modelContext.fetch(descriptor)
            if batch.isEmpty { break }
            for visit in batch {
                let coordinate = visit.coordinate
                for location in knownLocations where location.contains(coordinate) {
                    counts[location.id, default: 0] += 1
                }

                let label = visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let placeName = visit.regularPlaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if label.isEmpty && placeName.isEmpty,
                   visit.latitude.isFinite, visit.longitude.isFinite,
                   (-90...90).contains(visit.latitude), (-180...180).contains(visit.longitude) {
                    let key = "\(Int((visit.latitude * 1_000).rounded()))|\(Int((visit.longitude * 1_000).rounded()))"
                    var cluster = clusters[key] ?? Cluster()
                    cluster.count += 1
                    cluster.latitude += visit.latitude
                    cluster.longitude += visit.longitude
                    cluster.duration += max((visit.departureDate ?? .now).timeIntervalSince(visit.arrivalDate), 0)
                    clusters[key] = cluster
                }

                if visit.regularPlaceID == nil,
                   knownLocations.contains(where: {
                       $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame && !$0.contains(coordinate)
                   }) {
                    legacyCount += 1
                    if legacy.count < Self.legacyLimit {
                        legacy.append(.init(id: visit.id, date: visit.arrivalDate, label: label))
                    }
                }
            }
            offset += batch.count
            if batch.count < Self.batchSize { break }
        }

        let candidates = clusters.compactMap { key, cluster -> RegularPlaceOverview.Candidate? in
            guard cluster.count >= 2 else { return nil }
            return .init(clusterKey: key,
                         latitude: cluster.latitude / Double(cluster.count),
                         longitude: cluster.longitude / Double(cluster.count),
                         visitCount: cluster.count,
                         totalDuration: cluster.duration)
        }.sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.clusterKey < $1.clusterKey
        }

        return RegularPlaceOverview(
            countsByKnownLocationID: counts,
            unnamedCandidates: Array(candidates.prefix(Self.candidateLimit)),
            legacyCandidateCount: legacyCount,
            initialLegacyCandidates: legacy
        )
    }

    func legacyCandidates(offset requestedOffset: Int, limit requestedLimit: Int, knownLocations: [KnownLocationValue]) throws -> [RegularPlaceOverview.LegacyVisit] {
        let offsetLimit = max(requestedOffset, 0)
        let pageLimit = max(requestedLimit, 1)
        var results: [RegularPlaceOverview.LegacyVisit] = []
        var matchOffset = 0
        var fetchOffset = 0
        while results.count < pageLimit {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)])
            descriptor.fetchOffset = fetchOffset
            descriptor.fetchLimit = Self.batchSize
            let batch = try modelContext.fetch(descriptor)
            if batch.isEmpty { break }
            for visit in batch where visit.regularPlaceID == nil {
                let label = visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard knownLocations.contains(where: {
                    $0.name.localizedCaseInsensitiveCompare(label) == .orderedSame && !$0.contains(visit.coordinate)
                }) else { continue }
                if matchOffset >= offsetLimit && results.count < pageLimit {
                    results.append(.init(id: visit.id, date: visit.arrivalDate, label: label))
                }
                matchOffset += 1
            }
            fetchOffset += batch.count
            if batch.count < Self.batchSize { break }
        }
        return results
    }

    func visits(near latitude: Double, longitude: Double, radiusMeters: Double, limit: Int = 75) throws -> RegularPlaceVisitPage {
        let interval = RegularPlacesSignposting.signposter.beginInterval("EditorRegionQuery")
        defer { RegularPlacesSignposting.signposter.endInterval("EditorRegionQuery", interval) }
        let latDelta = min(max(radiusMeters, 0) / 110_000 + 0.002, 1.0)
        let lonScale = max(cos(latitude * .pi / 180), 0.15)
        let lonDelta = min(max(radiusMeters, 0) / (110_000 * lonScale) + 0.002, 180.0)
        let minLat = max(-90, latitude - latDelta)
        let maxLat = min(90, latitude + latDelta)
        let west = longitude - lonDelta
        let east = longitude + lonDelta
        let crossesWest = west < -180
        let crossesEast = east > 180
        let minLon = max(-180, west)
        let maxLon = min(180, east)
        let wrappedWest = west + 360
        let wrappedEast = east - 360
        let predicate = #Predicate<VisitPlace> { visit in
            visit.latitude >= minLat && visit.latitude <= maxLat
                && (crossesWest
                    ? (visit.longitude >= wrappedWest || visit.longitude <= maxLon)
                    : (crossesEast
                        ? (visit.longitude >= minLon || visit.longitude <= wrappedEast)
                        : (visit.longitude >= minLon && visit.longitude <= maxLon)))
        }
        var descriptor = FetchDescriptor<VisitPlace>(predicate: predicate, sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)])
        descriptor.fetchLimit = Self.batchSize
        let center = CLLocation(latitude: latitude, longitude: longitude)
        var summaries: [RegularPlaceVisitSummary] = []
        var totalCount = 0
        var offset = 0
        while true {
            try Task.checkCancellation()
            descriptor.fetchOffset = offset
            let batch = try modelContext.fetch(descriptor)
            for visit in batch where center.distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude)) <= max(radiusMeters, 0) {
                totalCount += 1
                if summaries.count < max(limit, 1) {
                    summaries.append(RegularPlaceVisitSummary(id: visit.id, latitude: visit.latitude, longitude: visit.longitude,
                                                              horizontalAccuracy: visit.horizontalAccuracy,
                                                              arrivalDate: visit.arrivalDate, departureDate: visit.departureDate))
                }
            }
            offset += batch.count
            if batch.count < Self.batchSize { break }
        }
        return RegularPlaceVisitPage(totalCount: totalCount, visits: summaries)
    }

    func reconcile(locationID: UUID, replacedID: UUID?) async throws {
        let interval = RegularPlacesSignposting.signposter.beginInterval("Reconciliation")
        defer { RegularPlacesSignposting.signposter.endInterval("Reconciliation", interval) }
        guard let location = try fetchLocation(id: locationID) else { return }
        let locations = try modelContext.fetch(FetchDescriptor<KnownLocation>())
        var offset = 0
        var changed = 0
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<VisitPlace>(sortBy: [SortDescriptor(\.arrivalDate, order: .forward)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batchSize
            let batch = try modelContext.fetch(descriptor)
            if batch.isEmpty { break }
            for visit in batch {
                let wasAssociated = visit.regularPlaceID == locationID || visit.regularPlaceID == replacedID
                if visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    if wasAssociated { changed += 1 }
                    if visit.regularPlaceID == locationID {
                        visit.regularPlaceName = location.name
                    }
                    continue
                }
                if wasAssociated {
                    visit.regularPlaceID = nil
                    visit.regularPlaceName = nil
                }
                if let match = RegularPlaceMatcher.match(coordinate: visit.coordinate, accuracy: visit.horizontalAccuracy, among: locations),
                   wasAssociated || visit.regularPlaceID == nil {
                    visit.regularPlaceID = match.id
                    visit.regularPlaceName = match.name
                } else if wasAssociated {
                    visit.regularPlaceID = nil
                    visit.regularPlaceName = nil
                }
                changed += 1
            }
            offset += batch.count
            if changed >= Self.batchSize {
                try saveWithSignpost()
                changed = 0
                await Task.yield()
            }
            if batch.count < Self.batchSize { break }
        }
        try saveWithSignpost()
    }

    func delete(locationID: UUID) async throws {
        let interval = RegularPlacesSignposting.signposter.beginInterval("DeletionReconciliation")
        defer { RegularPlacesSignposting.signposter.endInterval("DeletionReconciliation", interval) }
        guard let location = try fetchLocation(id: locationID) else { return }
        let replacements = try modelContext.fetch(FetchDescriptor<KnownLocation>()).filter { $0.id != locationID }
        while true {
            try Task.checkCancellation()
            let predicate = #Predicate<VisitPlace> { visit in visit.regularPlaceID == locationID }
            var descriptor = FetchDescriptor<VisitPlace>(predicate: predicate)
            descriptor.fetchLimit = Self.batchSize
            let batch = try modelContext.fetch(descriptor)
            if batch.isEmpty { break }
            for visit in batch {
                visit.regularPlaceID = nil
                visit.regularPlaceName = nil
                if visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                   let match = RegularPlaceMatcher.match(coordinate: visit.coordinate, accuracy: visit.horizontalAccuracy, among: replacements) {
                    visit.regularPlaceID = match.id
                    visit.regularPlaceName = match.name
                }
            }
            try saveWithSignpost()
            await Task.yield()
        }
        modelContext.delete(location)
        try saveWithSignpost()
    }

    func removeLegacyLabel(visitID: UUID) throws {
        var descriptor = FetchDescriptor<VisitPlace>(predicate: #Predicate<VisitPlace> { visit in visit.id == visitID })
        descriptor.fetchLimit = 1
        guard let visit = try modelContext.fetch(descriptor).first else { return }
        visit.userLabel = nil
        try modelContext.save()
    }

    private func fetchLocation(id: UUID) throws -> KnownLocation? {
        var descriptor = FetchDescriptor<KnownLocation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func saveWithSignpost() throws {
        let interval = RegularPlacesSignposting.signposter.beginInterval("ReconciliationBatchSave")
        defer { RegularPlacesSignposting.signposter.endInterval("ReconciliationBatchSave", interval) }
        try modelContext.save()
    }

    private struct Cluster {
        var count = 0
        var latitude = 0.0
        var longitude = 0.0
        var duration = 0.0
    }
}

struct KnownLocationValue: Sendable, Identifiable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    init(id: UUID, name: String, latitude: Double, longitude: Double, radiusMeters: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }

    init(_ location: KnownLocation) {
        self.init(id: location.id, name: location.name, latitude: location.latitude,
                  longitude: location.longitude, radiusMeters: location.radiusMeters)
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= max(radiusMeters, 0)
    }
}
