import CoreLocation
import Foundation
import SwiftData

/// A visit row safe to move between the SwiftData worker and presentation actors.
struct RegularPlaceVisitDTO: Identifiable, Sendable, Hashable {
    let id: UUID
    let arrivalDate: Date
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let userLabel: String?
    let autoLabel: String?
    let comment: String?
    let regularPlaceID: UUID?
    let regularPlaceName: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ visit: VisitPlace) {
        id = visit.id
        arrivalDate = visit.arrivalDate
        departureDate = visit.departureDate
        latitude = visit.latitude
        longitude = visit.longitude
        horizontalAccuracy = visit.horizontalAccuracy
        userLabel = visit.userLabel
        autoLabel = visit.autoLabel
        comment = visit.comment
        regularPlaceID = visit.regularPlaceID
        regularPlaceName = visit.regularPlaceName
    }
}

struct RegularPlacePage: Sendable {
    let visits: [RegularPlaceVisitDTO]
    let nextOffset: Int
    let hasMore: Bool
}

struct RegularPlaceDefinitionDTO: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    init(_ location: KnownLocation) {
        id = location.id
        name = location.name
        latitude = location.latitude
        longitude = location.longitude
        radiusMeters = location.radiusMeters
    }

    init(id: UUID, name: String, latitude: Double, longitude: Double, radiusMeters: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RegularPlaceSummaryDTO: Sendable, Identifiable {
    let id: String
    let title: String
    let latitude: Double
    let longitude: Double
    let visitCount: Int
    let totalDuration: TimeInterval
    let latestArrivalDate: Date
}

struct RegularPlaceVisitCountDTO: Sendable, Identifiable {
    var id: UUID { regularPlaceID }
    let regularPlaceID: UUID
    let count: Int
}

struct RegularPlaceSettingsSnapshotDTO: Sendable {
    let summaries: [RegularPlaceSummaryDTO]
    let counts: [RegularPlaceVisitCountDTO]
    let legacyCandidates: RegularPlacePage
}

enum RegularPlaceQueryError: Error {
    case invalidCoordinateOrRadius
}

/// Owns all historical Regular Place queries and reconciliation on a background
/// SwiftData context. Only value snapshots cross the actor boundary.
@ModelActor
actor RegularPlaceQueryWorker {
    private let batchSize = 400
    private static let maximumQueryRadiusMeters = 20_100_000.0
    private var cachedSettingsSnapshot: (definitions: [RegularPlaceDefinitionDTO], value: RegularPlaceSettingsSnapshotDTO)?
    private(set) var settingsSnapshotCalculationCount = 0

    func settingsSnapshot(definitions: [RegularPlaceDefinitionDTO]) throws -> RegularPlaceSettingsSnapshotDTO {
        if let cachedSettingsSnapshot, cachedSettingsSnapshot.definitions == definitions {
            return cachedSettingsSnapshot.value
        }
        let value = RegularPlaceSettingsSnapshotDTO(
            summaries: try frequentUnnamedSummaries(),
            counts: try counts(for: definitions),
            legacyCandidates: try legacyLabelCandidates(definitions: definitions, offset: 0, limit: 100)
        )
        settingsSnapshotCalculationCount += 1
        cachedSettingsSnapshot = (definitions, value)
        return value
    }

    func invalidateSettingsSnapshot() {
        cachedSettingsSnapshot = nil
    }

    func visits(regularPlaceID: UUID, offset: Int = 0, limit: Int = 50) throws -> RegularPlacePage {
        let predicate = #Predicate<VisitPlace> { $0.regularPlaceID == regularPlaceID }
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse), SortDescriptor(\.id)]
        )
        return try page(descriptor: &descriptor, offset: offset, limit: limit)
    }

    @discardableResult
    func assignSelectedVisit(visitID: UUID, to definition: RegularPlaceDefinitionDTO) throws -> Bool {
        try Self.validate(latitude: definition.latitude, longitude: definition.longitude, radiusMeters: definition.radiusMeters)
        let predicate = #Predicate<VisitPlace> { $0.id == visitID }
        var descriptor = FetchDescriptor<VisitPlace>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let visit = try modelContext.fetch(descriptor).first,
              contains(visit, in: definition) else { return false }
        let changed = visit.regularPlaceID != definition.id || visit.regularPlaceName != definition.name
        guard changed else { return true }
        visit.regularPlaceID = definition.id
        visit.regularPlaceName = definition.name
        let dayKey = Self.dayKey(for: visit)
        try modelContext.save()
        Self.postVisitChanges(dayKeys: [dayKey], objectID: visit.id)
        return true
    }

    /// One globally ordered page containing the authoritative identity matches
    /// plus unclassified historical visits accurately inside the saved place.
    func historyVisits(
        regularPlaceID: UUID,
        definition: RegularPlaceDefinitionDTO,
        offset: Int = 0,
        limit: Int = 50
    ) throws -> RegularPlacePage {
        try Self.validate(latitude: definition.latitude, longitude: definition.longitude, radiusMeters: definition.radiusMeters)
        let id = regularPlaceID
        let minLatitude = max(-90, definition.latitude - max(definition.radiusMeters, 0) / 110_574)
        let maxLatitude = min(90, definition.latitude + max(definition.radiusMeters, 0) / 110_574)
        let lonScale = max(abs(cos(definition.latitude * .pi / 180)), 0.01)
        let lonDelta = min(max(definition.radiusMeters, 0) / (111_320 * lonScale), 180)
        let rawMinLongitude = definition.longitude - lonDelta
        let rawMaxLongitude = definition.longitude + lonDelta
        let predicate: Predicate<VisitPlace>
        if rawMinLongitude < -180 {
            let wrappedMinLongitude = rawMinLongitude + 360
            predicate = #Predicate<VisitPlace> {
                $0.regularPlaceID == id || (
                    $0.regularPlaceID == nil && $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                        && ($0.longitude >= wrappedMinLongitude || $0.longitude <= rawMaxLongitude)
                )
            }
        } else if rawMaxLongitude > 180 {
            let wrappedMaxLongitude = rawMaxLongitude - 360
            predicate = #Predicate<VisitPlace> {
                $0.regularPlaceID == id || (
                    $0.regularPlaceID == nil && $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                        && ($0.longitude >= rawMinLongitude || $0.longitude <= wrappedMaxLongitude)
                )
            }
        } else {
            predicate = #Predicate<VisitPlace> {
                $0.regularPlaceID == id || (
                    $0.regularPlaceID == nil && $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                        && $0.longitude >= rawMinLongitude && $0.longitude <= rawMaxLongitude
                )
            }
        }
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse), SortDescriptor(\.id)]
        )
        let wantedOffset = max(offset, 0)
        let wantedLimit = max(limit, 1)
        var candidateOffset = 0
        var matchingOffset = 0
        var result: [RegularPlaceVisitDTO] = []
        while result.count < wantedLimit + 1 {
            try Task.checkCancellation()
            descriptor.fetchOffset = candidateOffset
            descriptor.fetchLimit = batchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for visit in batch {
                let matchesIdentity = visit.regularPlaceID == regularPlaceID
                let matchesArea = visit.regularPlaceID == nil && contains(visit, in: definition)
                guard matchesIdentity || matchesArea else { continue }
                if matchingOffset < wantedOffset { matchingOffset += 1; continue }
                result.append(RegularPlaceVisitDTO(visit))
                if result.count == wantedLimit + 1 { break }
            }
            candidateOffset += batch.count
            if batch.count < batchSize { break }
        }
        let hasMore = result.count > wantedLimit
        if hasMore { result.removeLast() }
        return RegularPlacePage(visits: result, nextOffset: wantedOffset + result.count, hasMore: hasMore)
    }

    /// Spatial candidates are bounded in the database first. Exact distance and
    /// observation uncertainty are checked before applying the requested offset.
    func visits(
        nearLatitude latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        offset: Int = 0,
        limit: Int = 50
    ) throws -> RegularPlacePage {
        try Self.validate(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
        let radius = max(radiusMeters, 0)
        let latDelta = radius / 110_574
        let lonScale = max(abs(cos(latitude * .pi / 180)), 0.01)
        let lonDelta = min(radius / (111_320 * lonScale), 180)
        let minLatitude = max(-90, latitude - latDelta)
        let maxLatitude = min(90, latitude + latDelta)
        let rawMinLongitude = longitude - lonDelta
        let rawMaxLongitude = longitude + lonDelta
        let predicate: Predicate<VisitPlace>
        if rawMinLongitude < -180 {
            let wrappedMinLongitude = rawMinLongitude + 360
            predicate = #Predicate<VisitPlace> {
                $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                    && ($0.longitude >= wrappedMinLongitude || $0.longitude <= rawMaxLongitude)
            }
        } else if rawMaxLongitude > 180 {
            let wrappedMaxLongitude = rawMaxLongitude - 360
            predicate = #Predicate<VisitPlace> {
                $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                    && ($0.longitude >= rawMinLongitude || $0.longitude <= wrappedMaxLongitude)
            }
        } else {
            predicate = #Predicate<VisitPlace> {
                $0.latitude >= minLatitude && $0.latitude <= maxLatitude
                    && $0.longitude >= rawMinLongitude && $0.longitude <= rawMaxLongitude
            }
        }
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse), SortDescriptor(\.id)]
        )
        let requestedOffset = max(offset, 0)
        let requestedLimit = max(limit, 1)
        var exactMatchOffset = 0
        var values: [RegularPlaceVisitDTO] = []
        var candidateOffset = 0
        while values.count < requestedLimit + 1 {
            try Task.checkCancellation()
            descriptor.fetchOffset = candidateOffset
            descriptor.fetchLimit = batchSize
            let candidates = try modelContext.fetch(descriptor)
            guard !candidates.isEmpty else { break }
            for visit in candidates {
                let accuracy = visit.horizontalAccuracy
                guard accuracy.isFinite, accuracy >= 0 else { continue }
                let distance = CLLocation(latitude: latitude, longitude: longitude)
                    .distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude))
                // Keep the accuracy disk within the requested place area.
                guard distance + accuracy <= radius else { continue }
                if exactMatchOffset < requestedOffset {
                    exactMatchOffset += 1
                    continue
                }
                values.append(RegularPlaceVisitDTO(visit))
                if values.count == requestedLimit + 1 { break }
            }
            candidateOffset += candidates.count
            if candidates.count < batchSize { break }
        }
        let hasMore = values.count > requestedLimit
        if hasMore { values.removeLast() }
        return RegularPlacePage(visits: values, nextOffset: requestedOffset + values.count, hasMore: hasMore)
    }

    func counts(for definitions: [RegularPlaceDefinitionDTO]) throws -> [RegularPlaceVisitCountDTO] {
        try definitions.map { definition in
            try Task.checkCancellation()
            try Self.validate(latitude: definition.latitude, longitude: definition.longitude, radiusMeters: definition.radiusMeters)
            var total = 0
            try forEachSpatialCandidate(centerLatitude: definition.latitude,
                                        longitude: definition.longitude,
                                        radiusMeters: definition.radiusMeters) { visit in
                guard visit.horizontalAccuracy.isFinite, visit.horizontalAccuracy >= 0 else { return }
                let distance = CLLocation(latitude: definition.latitude, longitude: definition.longitude)
                    .distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude))
                if distance + visit.horizontalAccuracy <= max(definition.radiusMeters, 0) { total += 1 }
            }
            return RegularPlaceVisitCountDTO(regularPlaceID: definition.id, count: total)
        }
    }

    func frequentUnnamedSummaries(minimumVisits: Int = 2, limit: Int = 50) throws -> [RegularPlaceSummaryDTO] {
        struct Accumulator {
            var latitude: Double
            var longitude: Double
            var count = 0
            var duration: TimeInterval = 0
            var latest = Date.distantPast
        }
        var groups: [String: Accumulator] = [:]
        try forEachVisitBatch { visit in
            guard visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  visit.regularPlaceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)),
                  visit.horizontalAccuracy.isFinite, visit.horizontalAccuracy >= 0 else { return }
            // ~100 m buckets keep this summary stable and inexpensive while avoiding
            // treating every noisy GPS coordinate as a distinct place.
            let key = "\(Int((visit.latitude * 1_000).rounded()))|\(Int((visit.longitude * 1_000).rounded()))"
            var value = groups[key] ?? Accumulator(latitude: visit.latitude, longitude: visit.longitude)
            value.count += 1
            value.duration += max((visit.departureDate ?? visit.arrivalDate).timeIntervalSince(visit.arrivalDate), 0)
            value.latest = max(value.latest, visit.arrivalDate)
            groups[key] = value
        }
        return groups.compactMap { key, value in
            guard value.count >= max(minimumVisits, 1) else { return nil }
            return RegularPlaceSummaryDTO(
                id: "unnamed:\(key)",
                title: "\(value.latitude.formatted(.number.precision(.fractionLength(3)))), \(value.longitude.formatted(.number.precision(.fractionLength(3))))",
                latitude: value.latitude,
                longitude: value.longitude,
                visitCount: value.count,
                totalDuration: value.duration,
                latestArrivalDate: value.latest
            )
        }.sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            if $0.latestArrivalDate != $1.latestArrivalDate { return $0.latestArrivalDate > $1.latestArrivalDate }
            return $0.id < $1.id
        }.prefix(max(limit, 0)).map { $0 }
    }

    func legacyLabelCandidates(
        definitions: [RegularPlaceDefinitionDTO],
        offset: Int = 0,
        limit: Int = 50
    ) throws -> RegularPlacePage {
        for definition in definitions {
            try Self.validate(latitude: definition.latitude, longitude: definition.longitude, radiusMeters: definition.radiusMeters)
        }
        let candidates = definitions.filter { !$0.name.isEmpty }
        let predicate = #Predicate<VisitPlace> { $0.regularPlaceID == nil && $0.userLabel != nil }
        var descriptor = FetchDescriptor<VisitPlace>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse), SortDescriptor(\.id)]
        )
        var seen = 0
        var result: [RegularPlaceVisitDTO] = []
        var scanOffset = 0
        let wantedOffset = max(offset, 0)
        let wantedLimit = max(limit, 1)
        while result.count < wantedLimit + 1 {
            try Task.checkCancellation()
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = batchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for visit in batch where candidates.contains(where: { definition in
                guard visit.userLabel?.localizedCaseInsensitiveCompare(definition.name) == .orderedSame else { return false }
                return !contains(visit, in: definition)
            }) {
                if seen < wantedOffset { seen += 1; continue }
                result.append(RegularPlaceVisitDTO(visit))
                if result.count == wantedLimit + 1 { break }
            }
            scanOffset += batch.count
            if batch.count < batchSize { break }
        }
        let hasMore = result.count > wantedLimit
        if hasMore { result.removeLast() }
        return RegularPlacePage(visits: result, nextOffset: wantedOffset + result.count, hasMore: hasMore)
    }

    /// Reconciles in bounded deterministic batches. User labels and comments are
    /// never changed; they remain authoritative over automatic classification.
    func reconcile(
        location: RegularPlaceDefinitionDTO,
        replacedID: UUID? = nil,
        previousDefinition: RegularPlaceDefinitionDTO? = nil,
        definitions: [RegularPlaceDefinitionDTO],
        batchSize requestedBatchSize: Int = 300,
        cancelAfterMutationsForTesting: Int? = nil,
        cancelAfterCommittedBatchesForTesting: Int? = nil
    ) throws -> Int {
        try Self.validate(latitude: location.latitude, longitude: location.longitude, radiusMeters: location.radiusMeters)
        if let previousDefinition {
            try Self.validate(latitude: previousDefinition.latitude, longitude: previousDefinition.longitude,
                              radiusMeters: previousDefinition.radiusMeters)
        }
        for definition in definitions {
            try Self.validate(latitude: definition.latitude, longitude: definition.longitude, radiusMeters: definition.radiusMeters)
        }
        let locations = definitions.filter { $0.id != replacedID || $0.id == location.id }
        let definitionsToUse = locations.contains(where: { $0.id == location.id }) ? locations : locations + [location]
        let pageSize = min(max(requestedBatchSize, 1), 1_000)
        var changedCount = 0
        var changedDayKeys = Set<String>()
        var committedBatchCount = 0
        defer {
            if changedCount > 0 { Self.postVisitChanges(dayKeys: changedDayKeys) }
        }
        let old = previousDefinition ?? location
        let oldLongitudeRadius = min(max(old.radiusMeters, 0) / (111_320 * max(abs(cos(old.latitude * .pi / 180)), 0.01)), 180)
        let newLongitudeRadius = min(max(location.radiusMeters, 0) / (111_320 * max(abs(cos(location.latitude * .pi / 180)), 0.01)), 180)
        let oldMinLatitude = max(-90, old.latitude - max(old.radiusMeters, 0) / 110_574)
        let oldMaxLatitude = min(90, old.latitude + max(old.radiusMeters, 0) / 110_574)
        let newMinLatitude = max(-90, location.latitude - max(location.radiusMeters, 0) / 110_574)
        let newMaxLatitude = min(90, location.latitude + max(location.radiusMeters, 0) / 110_574)
        let oldRawMinLongitude = old.longitude - oldLongitudeRadius
        let oldRawMaxLongitude = old.longitude + oldLongitudeRadius
        let newRawMinLongitude = location.longitude - newLongitudeRadius
        let newRawMaxLongitude = location.longitude + newLongitudeRadius
        let oldCrossesDateline = oldRawMinLongitude < -180 || oldRawMaxLongitude > 180
        let newCrossesDateline = newRawMinLongitude < -180 || newRawMaxLongitude > 180
        let oldMinLongitude = max(-180, oldRawMinLongitude)
        let oldMaxLongitude = min(180, oldRawMaxLongitude)
        let newMinLongitude = max(-180, newRawMinLongitude)
        let newMaxLongitude = min(180, newRawMaxLongitude)
        let currentID = location.id
        let oldID = replacedID ?? location.id
        var cursor: (arrivalDate: Date, id: UUID)?
        var totalMutationCount = 0
        while true {
            try Task.checkCancellation()
            let cursorDate = cursor?.arrivalDate ?? .distantPast
            let cursorID = cursor?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let hasCursor = cursor != nil
            let predicate: Predicate<VisitPlace>
            if oldCrossesDateline && newCrossesDateline {
                predicate = #Predicate<VisitPlace> {
                    ($0.regularPlaceID == currentID || $0.regularPlaceID == oldID
                        || ($0.latitude >= oldMinLatitude && $0.latitude <= oldMaxLatitude)
                        || ($0.latitude >= newMinLatitude && $0.latitude <= newMaxLatitude))
                        && (!hasCursor || $0.arrivalDate > cursorDate || ($0.arrivalDate == cursorDate && $0.id > cursorID))
                }
            } else if oldCrossesDateline {
                predicate = #Predicate<VisitPlace> {
                    ($0.regularPlaceID == currentID || $0.regularPlaceID == oldID
                        || ($0.latitude >= oldMinLatitude && $0.latitude <= oldMaxLatitude)
                        || ($0.latitude >= newMinLatitude && $0.latitude <= newMaxLatitude
                            && $0.longitude >= newMinLongitude && $0.longitude <= newMaxLongitude))
                        && (!hasCursor || $0.arrivalDate > cursorDate || ($0.arrivalDate == cursorDate && $0.id > cursorID))
                }
            } else if newCrossesDateline {
                predicate = #Predicate<VisitPlace> {
                    ($0.regularPlaceID == currentID || $0.regularPlaceID == oldID
                        || ($0.latitude >= oldMinLatitude && $0.latitude <= oldMaxLatitude
                            && $0.longitude >= oldMinLongitude && $0.longitude <= oldMaxLongitude)
                        || ($0.latitude >= newMinLatitude && $0.latitude <= newMaxLatitude))
                        && (!hasCursor || $0.arrivalDate > cursorDate || ($0.arrivalDate == cursorDate && $0.id > cursorID))
                }
            } else {
                predicate = #Predicate<VisitPlace> {
                    ($0.regularPlaceID == currentID || $0.regularPlaceID == oldID
                        || ($0.latitude >= oldMinLatitude && $0.latitude <= oldMaxLatitude
                            && $0.longitude >= oldMinLongitude && $0.longitude <= oldMaxLongitude)
                        || ($0.latitude >= newMinLatitude && $0.latitude <= newMaxLatitude
                            && $0.longitude >= newMinLongitude && $0.longitude <= newMaxLongitude))
                        && (!hasCursor || $0.arrivalDate > cursorDate || ($0.arrivalDate == cursorDate && $0.id > cursorID))
                }
            }
            var descriptor = FetchDescriptor<VisitPlace>(predicate: predicate,
                sortBy: [SortDescriptor(\.arrivalDate), SortDescriptor(\.id)])
            descriptor.fetchLimit = pageSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }
            var batchChangedCount = 0
            var batchChangedDayKeys = Set<String>()
            do {
                for visit in batch {
                    try Task.checkCancellation()
                    let previousID = visit.regularPlaceID
                    let previousName = visit.regularPlaceName
                    let hasManualLabel = visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    if hasManualLabel {
                        if visit.regularPlaceID == location.id, visit.regularPlaceName != location.name {
                            visit.regularPlaceName = location.name
                        }
                    } else {
                        if previousID == location.id || previousID == replacedID {
                            visit.regularPlaceID = nil
                            visit.regularPlaceName = nil
                        }
                        if let match = RegularPlaceMatcher.match(coordinate: visit.coordinate,
                                                                accuracy: visit.horizontalAccuracy,
                                                                among: definitionsToUse) {
                            visit.regularPlaceID = match.id
                            visit.regularPlaceName = match.name
                        }
                    }
                    if previousID != visit.regularPlaceID || previousName != visit.regularPlaceName {
                        batchChangedCount += 1
                        batchChangedDayKeys.insert(Self.dayKey(for: visit))
                        totalMutationCount += 1
                        if totalMutationCount == cancelAfterMutationsForTesting {
                            throw CancellationError()
                        }
                    }
                }
                try modelContext.save()
                changedCount += batchChangedCount
                changedDayKeys.formUnion(batchChangedDayKeys)
            } catch {
                modelContext.rollback()
                throw error
            }
            committedBatchCount += 1
            if committedBatchCount == cancelAfterCommittedBatchesForTesting { throw CancellationError() }
            if let last = batch.last { cursor = (last.arrivalDate, last.id) }
            if batch.count < pageSize { break }
        }
        return changedCount
    }

    func remove(locationID: UUID, definitions: [RegularPlaceDefinitionDTO], batchSize requestedBatchSize: Int = 300,
                cancelAfterMutationsForTesting: Int? = nil,
                cancelAfterCommittedBatchesForTesting: Int? = nil) throws -> Int {
        for definition in definitions {
            try Self.validate(latitude: definition.latitude, longitude: definition.longitude, radiusMeters: definition.radiusMeters)
        }
        let pageSize = min(max(requestedBatchSize, 1), 1_000)
        var changedCount = 0
        var changedDayKeys = Set<String>()
        var totalMutationCount = 0
        var committedBatchCount = 0
        defer {
            if changedCount > 0 { Self.postVisitChanges(dayKeys: changedDayKeys) }
        }
        while true {
            try Task.checkCancellation()
            let predicate = #Predicate<VisitPlace> { $0.regularPlaceID == locationID }
            var descriptor = FetchDescriptor<VisitPlace>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.arrivalDate), SortDescriptor(\.id)]
            )
            descriptor.fetchLimit = pageSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }
            var batchChangedCount = 0
            var batchChangedDayKeys = Set<String>()
            do {
                for visit in batch {
                    try Task.checkCancellation()
                    guard visit.regularPlaceID == locationID else { continue }
                    batchChangedDayKeys.insert(Self.dayKey(for: visit))
                    visit.regularPlaceID = nil
                    visit.regularPlaceName = nil
                    if visit.userLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                       let match = RegularPlaceMatcher.match(coordinate: visit.coordinate,
                                                             accuracy: visit.horizontalAccuracy,
                                                             among: definitions) {
                        visit.regularPlaceID = match.id
                        visit.regularPlaceName = match.name
                    }
                    batchChangedCount += 1
                    totalMutationCount += 1
                    if totalMutationCount == cancelAfterMutationsForTesting {
                        throw CancellationError()
                    }
                }
                try modelContext.save()
                changedCount += batchChangedCount
                changedDayKeys.formUnion(batchChangedDayKeys)
            } catch {
                modelContext.rollback()
                throw error
            }
            committedBatchCount += 1
            if committedBatchCount == cancelAfterCommittedBatchesForTesting { throw CancellationError() }
            if batch.count < pageSize { break }
        }
        return changedCount
    }

    private static func dayKey(for visit: VisitPlace) -> String {
        visit.dayTimeline?.dayKey ?? DayTimeline.makeDayKey(for: visit.arrivalDate)
    }

    private static func postVisitChanges(dayKeys: Set<String>, objectID: UUID? = nil) {
        guard !dayKeys.isEmpty else { return }
        NotificationCenter.default.post(
            name: .movesVisitedPlaceDidChange,
            object: objectID,
            userInfo: ["dayKeys": dayKeys.sorted()]
        )
    }

    private func page(descriptor: inout FetchDescriptor<VisitPlace>, offset: Int, limit: Int) throws -> RegularPlacePage {
        descriptor.fetchOffset = max(offset, 0)
        descriptor.fetchLimit = max(limit, 1) + 1
        let rows = try modelContext.fetch(descriptor)
        let hasMore = rows.count > max(limit, 1)
        return RegularPlacePage(visits: rows.prefix(max(limit, 1)).map(RegularPlaceVisitDTO.init),
                                nextOffset: max(offset, 0) + min(rows.count, max(limit, 1)),
                                hasMore: hasMore)
    }

    private func forEachVisitBatch(_ body: (VisitPlace) throws -> Void) throws {
        var offset = 0
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<VisitPlace>(
                sortBy: [SortDescriptor(\.arrivalDate), SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = batchSize
            let visits = try modelContext.fetch(descriptor)
            guard !visits.isEmpty else { return }
            for visit in visits { try body(visit) }
            offset += visits.count
            if visits.count < batchSize { return }
        }
    }

    private func forEachSpatialCandidate(
        centerLatitude latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        body: (VisitPlace) throws -> Void
    ) throws {
        let radius = max(radiusMeters, 0)
        let latDelta = radius / 110_574
        let lonScale = max(abs(cos(latitude * .pi / 180)), 0.01)
        let lonDelta = min(radius / (111_320 * lonScale), 180)
        let lowLat = max(-90, latitude - latDelta), highLat = min(90, latitude + latDelta)
        let rawLowLon = longitude - lonDelta, rawHighLon = longitude + lonDelta
        let predicate: Predicate<VisitPlace>
        if rawLowLon < -180 {
            let wrappedLowLon = rawLowLon + 360
            predicate = #Predicate<VisitPlace> {
                $0.latitude >= lowLat && $0.latitude <= highLat
                    && ($0.longitude >= wrappedLowLon || $0.longitude <= rawHighLon)
            }
        } else if rawHighLon > 180 {
            let wrappedHighLon = rawHighLon - 360
            predicate = #Predicate<VisitPlace> {
                $0.latitude >= lowLat && $0.latitude <= highLat
                    && ($0.longitude >= rawLowLon || $0.longitude <= wrappedHighLon)
            }
        } else {
            predicate = #Predicate<VisitPlace> {
                $0.latitude >= lowLat && $0.latitude <= highLat
                    && $0.longitude >= rawLowLon && $0.longitude <= rawHighLon
            }
        }
        var offset = 0
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<VisitPlace>(predicate: predicate, sortBy: [SortDescriptor(\.arrivalDate)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = batchSize
            let visits = try modelContext.fetch(descriptor)
            guard !visits.isEmpty else { return }
            for visit in visits { try body(visit) }
            offset += visits.count
            if visits.count < batchSize { return }
        }
    }

    private func contains(_ visit: VisitPlace, in definition: RegularPlaceDefinitionDTO) -> Bool {
        guard CLLocationCoordinate2DIsValid(visit.coordinate), visit.horizontalAccuracy.isFinite,
              visit.horizontalAccuracy >= 0 else { return false }
        let distance = CLLocation(latitude: definition.latitude, longitude: definition.longitude)
            .distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude))
        return distance + visit.horizontalAccuracy <= max(definition.radiusMeters, 0)
    }

    private static func validate(latitude: Double, longitude: Double, radiusMeters: Double) throws {
        guard latitude.isFinite, longitude.isFinite, radiusMeters.isFinite,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
              radiusMeters >= 0, radiusMeters <= maximumQueryRadiusMeters else {
            throw RegularPlaceQueryError.invalidCoordinateOrRadius
        }
    }
}

extension RegularPlaceMatcher {
    static func match(
        coordinate: CLLocationCoordinate2D,
        accuracy: CLLocationAccuracy,
        among definitions: [RegularPlaceDefinitionDTO]
    ) -> RegularPlaceDefinitionDTO? {
        guard CLLocationCoordinate2DIsValid(coordinate), accuracy.isFinite, accuracy >= 0 else { return nil }
        return definitions.compactMap { definition -> (RegularPlaceDefinitionDTO, CLLocationDistance)? in
            let distance = CLLocation(latitude: definition.latitude, longitude: definition.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard distance + accuracy <= max(definition.radiusMeters, 0) else { return nil }
            return (definition, distance)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.first?.0
    }
}
