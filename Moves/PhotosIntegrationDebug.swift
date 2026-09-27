#if DEBUG

import CoreLocation
import Foundation
import Photos
import SwiftData
import SwiftUI

// This entire integration is intentionally debug-only while the PhotoKit
// workflow is being exercised against real libraries. The value types below
// keep PhotoKit and SwiftData objects out of the clustering/matching code.

struct PhotoMetadataRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let creationDate: Date
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?
    let mediaType: Int

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var fingerprint: String {
        [
            String(creationDate.timeIntervalSinceReferenceDate),
            String(latitude ?? .nan),
            String(longitude ?? .nan),
            String(horizontalAccuracy ?? .nan),
            String(mediaType)
        ].joined(separator: "|")
    }
}

struct PhotoVisitCandidate: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let assetIDs: [String]
    let startDate: Date
    let endDate: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var duration: TimeInterval {
        max(endDate.timeIntervalSince(startDate), 0)
    }
}

enum PhotoVisitClusterer {
    struct Configuration: Sendable {
        var maximumClusterDuration: TimeInterval = 2 * 60 * 60
        var maximumCaptureGap: TimeInterval = 45 * 60
        var maximumDistanceFromCentroid: CLLocationDistance = 180
        var maximumTravelSpeed: CLLocationSpeed = 80
        var minimumPhotoCount = 2
    }

    static let configuration = Configuration()

    struct Streaming {
        private var current: Accumulator?
        private var candidates: [PhotoVisitCandidate] = []
        private let configuration: Configuration

        init(configuration: Configuration = PhotoVisitClusterer.configuration) {
            self.configuration = configuration
        }

        mutating func consume(_ record: PhotoMetadataRecord) {
            guard let coordinate = record.coordinate else { return }
            if let existing = current,
               existing.canAppend(record, coordinate: coordinate, configuration: configuration) {
                var updated = existing
                updated.append(record, coordinate: coordinate)
                current = updated
            } else {
                flushCurrent()
                current = Accumulator(record: record, coordinate: coordinate)
            }
        }

        mutating func finish() -> [PhotoVisitCandidate] {
            flushCurrent()
            return candidates
        }

        private mutating func flushCurrent() {
            guard let current else { return }
            appendCandidate(from: current, to: &candidates, minimumPhotoCount: configuration.minimumPhotoCount)
            self.current = nil
        }
    }

    static func cluster(
        _ records: [PhotoMetadataRecord],
        configuration: Configuration = Self.configuration
    ) -> [PhotoVisitCandidate] {
        var streaming = Streaming(configuration: configuration)
        for record in records.sorted(by: { $0.creationDate < $1.creationDate }) {
            streaming.consume(record)
        }
        return streaming.finish()
    }

    private static func appendCandidate(
        from accumulator: Accumulator,
        to candidates: inout [PhotoVisitCandidate],
        minimumPhotoCount: Int
    ) {
        guard accumulator.assetIDs.count >= minimumPhotoCount else { return }
        let id = accumulator.assetIDs.joined(separator: ",")
        candidates.append(PhotoVisitCandidate(
            id: id,
            assetIDs: accumulator.assetIDs,
            startDate: accumulator.startDate,
            endDate: accumulator.endDate,
            latitude: accumulator.latitude / Double(accumulator.assetIDs.count),
            longitude: accumulator.longitude / Double(accumulator.assetIDs.count),
            horizontalAccuracy: accumulator.horizontalAccuracy
        ))
    }

    private struct Accumulator: Sendable {
        var assetIDs: [String]
        var startDate: Date
        var endDate: Date
        var latitude: Double
        var longitude: Double
        var horizontalAccuracy: Double
        var lastCoordinate: CLLocationCoordinate2D

        init(record: PhotoMetadataRecord, coordinate: CLLocationCoordinate2D) {
            assetIDs = [record.id]
            startDate = record.creationDate
            endDate = record.creationDate
            latitude = coordinate.latitude
            longitude = coordinate.longitude
            horizontalAccuracy = max(record.horizontalAccuracy ?? 0, 0)
            lastCoordinate = coordinate
        }

        func canAppend(
            _ record: PhotoMetadataRecord,
            coordinate: CLLocationCoordinate2D,
            configuration: Configuration
        ) -> Bool {
            let gap = record.creationDate.timeIntervalSince(endDate)
            guard gap >= 0,
                  gap <= configuration.maximumCaptureGap,
                  record.creationDate.timeIntervalSince(startDate) <= configuration.maximumClusterDuration else {
                return false
            }

            let lastLocation = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            let newLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let fromLast = lastLocation.distance(from: newLocation)
            let fromCentroid = CLLocation(
                latitude: latitude / Double(assetIDs.count),
                longitude: longitude / Double(assetIDs.count)
            ).distance(from: newLocation)
            let speed = gap > 0 ? fromLast / gap : 0
            return fromCentroid <= configuration.maximumDistanceFromCentroid
                && speed <= configuration.maximumTravelSpeed
        }

        mutating func append(_ record: PhotoMetadataRecord, coordinate: CLLocationCoordinate2D) {
            assetIDs.append(record.id)
            endDate = record.creationDate
            latitude += coordinate.latitude
            longitude += coordinate.longitude
            horizontalAccuracy = min(horizontalAccuracy, max(record.horizontalAccuracy ?? 0, 0))
            lastCoordinate = coordinate
        }
    }
}

struct PhotoScanResult: Sendable {
    let scannedAssetCount: Int
    let locatedAssetCount: Int
    let candidates: [PhotoVisitCandidate]
}

enum PhotoLibraryMetadataReader {
    static func batches(batchSize: Int = 250) -> AsyncThrowingStream<[PhotoMetadataRecord], Error> {
        let batchSize = max(batchSize, 1)
        return AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                    options.predicate = NSPredicate(format: "creationDate != nil")
                    let assets = PHAsset.fetchAssets(with: options)
                    var batch: [PhotoMetadataRecord] = []
                    batch.reserveCapacity(batchSize)

                    for index in 0..<assets.count {
                        try Task.checkCancellation()
                        let asset = assets.object(at: index)
                        guard let creationDate = asset.creationDate else { continue }
                        let location = asset.location
                        batch.append(PhotoMetadataRecord(
                            id: asset.localIdentifier,
                            creationDate: creationDate,
                            latitude: location?.coordinate.latitude,
                            longitude: location?.coordinate.longitude,
                            horizontalAccuracy: location?.horizontalAccuracy,
                            mediaType: asset.mediaType.rawValue
                        ))
                        if batch.count == batchSize {
                            continuation.yield(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty {
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func read() async throws -> [PhotoMetadataRecord] {
        var records: [PhotoMetadataRecord] = []
        for try await batch in batches() {
            records.append(contentsOf: batch)
        }
        return records
    }

    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

struct PhotosIntegrationState: Codable, Sendable {
    var fingerprints: [String: String] = [:]
    var importedCandidateIDs: Set<String> = []
}

actor PhotosIntegrationStateStore {
    static let shared = PhotosIntegrationStateStore()

    private var cachedState: PhotosIntegrationState?

    func load() throws -> PhotosIntegrationState {
        if let cachedState { return cachedState }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let state = PhotosIntegrationState()
            cachedState = state
            return state
        }
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(PhotosIntegrationState.self, from: data)
        cachedState = state
        return state
    }

    func save(_ state: PhotosIntegrationState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        cachedState = state
    }

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Moves", isDirectory: true)
            .appendingPathComponent("photos-integration-state.json")
    }
}

enum PhotosIntegrationEngine {
    static func scanVisits() async throws -> PhotoScanResult {
        var state = try await PhotosIntegrationStateStore.shared.load()
        var currentIDs = Set<String>()
        var changedIDs = Set<String>()
        var changedFingerprints: [String: String] = [:]
        var scannedAssetCount = 0
        var locatedAssetCount = 0
        var clusterer = PhotoVisitClusterer.Streaming()

        for try await batch in PhotoLibraryMetadataReader.batches() {
            for record in batch {
                scannedAssetCount += 1
                currentIDs.insert(record.id)
                if record.coordinate != nil { locatedAssetCount += 1 }
                if state.fingerprints[record.id] != record.fingerprint {
                    changedIDs.insert(record.id)
                    changedFingerprints[record.id] = record.fingerprint
                }
                clusterer.consume(record)
            }
        }

        state.fingerprints = state.fingerprints.filter { currentIDs.contains($0.key) }
        // The stream is ordered by creation date, but state only needs the
        // identifiers and fingerprints that changed during this pass.
        state.fingerprints.merge(changedFingerprints) { _, new in new }
        try await PhotosIntegrationStateStore.shared.save(state)

        let candidates = clusterer.finish()
            .filter { candidate in
                !state.importedCandidateIDs.contains(candidate.id)
                    || candidate.assetIDs.contains(where: changedIDs.contains)
        }
        return PhotoScanResult(
            scannedAssetCount: scannedAssetCount,
            locatedAssetCount: locatedAssetCount,
            candidates: candidates
        )
    }

    static func markImported(_ candidates: [PhotoVisitCandidate]) async throws {
        var state = try await PhotosIntegrationStateStore.shared.load()
        state.importedCandidateIDs.formUnion(candidates.map(\.id))
        try await PhotosIntegrationStateStore.shared.save(state)
    }
}

enum PhotoLocationConfidence: String, Codable, CaseIterable, Sendable {
    case exact
    case interpolated
    case visit

    var title: String {
        switch self {
        case .exact: "Exact Moves sample"
        case .interpolated: "Interpolated samples"
        case .visit: "Overlapping Visit"
        }
    }
}

struct PhotoLocationProposal: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let creationDate: Date
    let latitude: Double
    let longitude: Double
    let confidence: PhotoLocationConfidence
    let reason: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct PhotoLocationPreview: Sendable {
    let scannedAssetCount: Int
    let alreadyLocatedCount: Int
    let proposals: [PhotoLocationProposal]
    let skippedCount: Int

    var confidenceCounts: [PhotoLocationConfidence: Int] {
        proposals.reduce(into: [:]) { counts, proposal in
            counts[proposal.confidence, default: 0] += 1
        }
    }
}

struct PhotoLocationTimelinePoint: Sendable {
    let date: Date
    let coordinate: CLLocationCoordinate2D
}

enum PhotoLocationMatcher {
    static let maximumSampleWindow: TimeInterval = 15 * 60
    static let exactMatchWindow: TimeInterval = 90
    static let maximumInterpolationGap: TimeInterval = 15 * 60
    static let maximumInterpolationSpeed: CLLocationSpeed = 80
    static let visitWindow: TimeInterval = 20 * 60

    static func match(
        date: Date,
        samples: [PhotoLocationTimelinePoint],
        visits: [PhotoLocationTimelinePoint]
    ) -> PhotoLocationProposal? {
        let ordered = samples.sorted { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        if let exact = ordered.first,
           abs(exact.date.timeIntervalSince(date)) <= exactMatchWindow {
            return proposal(date: date, coordinate: exact.coordinate, confidence: .exact, reason: "A reliable Moves sample is within 90 seconds.")
        }

        let before = samples.filter { $0.date <= date }.max { $0.date < $1.date }
        let after = samples.filter { $0.date >= date }.min { $0.date < $1.date }
        if let before, let after {
            let gap = after.date.timeIntervalSince(before.date)
            let distance = CLLocation(latitude: before.coordinate.latitude, longitude: before.coordinate.longitude)
                .distance(from: CLLocation(latitude: after.coordinate.latitude, longitude: after.coordinate.longitude))
            let speed = gap > 0 ? distance / gap : 0
            if gap > 0, gap <= maximumInterpolationGap, speed <= maximumInterpolationSpeed {
                let fraction = date.timeIntervalSince(before.date) / gap
                let latitude = before.coordinate.latitude + (after.coordinate.latitude - before.coordinate.latitude) * fraction
                let longitude = before.coordinate.longitude + (after.coordinate.longitude - before.coordinate.longitude) * fraction
                return proposal(
                    date: date,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    confidence: .interpolated,
                    reason: "Interpolated between two nearby Moves samples without an implausible gap."
                )
            }
        }

        if let visit = visits.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
           abs(visit.date.timeIntervalSince(date)) <= visitWindow {
            return proposal(date: date, coordinate: visit.coordinate, confidence: .visit, reason: "An existing Moves Visit overlaps the capture time.")
        }
        return nil
    }

    private static func proposal(
        date: Date,
        coordinate: CLLocationCoordinate2D,
        confidence: PhotoLocationConfidence,
        reason: String
    ) -> PhotoLocationProposal {
        PhotoLocationProposal(
            id: UUID().uuidString,
            creationDate: date,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            confidence: confidence,
            reason: reason
        )
    }
}

@ModelActor
actor PhotoLocationMatcherWorker {
    func preview(for records: [PhotoMetadataRecord]) throws -> PhotoLocationPreview {
        let missing = records.filter { $0.coordinate == nil }
        var proposals: [PhotoLocationProposal] = []
        proposals.reserveCapacity(missing.count)

        for record in missing {
            try Task.checkCancellation()
            let lower = record.creationDate.addingTimeInterval(-PhotoLocationMatcher.maximumSampleWindow)
            let upper = record.creationDate.addingTimeInterval(PhotoLocationMatcher.maximumSampleWindow)
            let sampleDescriptor = FetchDescriptor<LocationSample>(
                predicate: #Predicate { sample in
                    sample.timestamp >= lower && sample.timestamp <= upper
                },
                sortBy: [SortDescriptor(\LocationSample.timestamp, order: .forward)]
            )
            let samples = try modelContext.fetch(sampleDescriptor).map {
                PhotoLocationTimelinePoint(date: $0.timestamp, coordinate: $0.coordinate)
            }

            let visitDescriptor = FetchDescriptor<VisitPlace>(
                predicate: #Predicate { place in
                    place.arrivalDate >= lower && place.arrivalDate <= upper
                },
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
            )
            var visits = try modelContext.fetch(visitDescriptor).compactMap { place -> PhotoLocationTimelinePoint? in
                let departure = place.departureDate ?? place.arrivalDate
                guard departure >= lower else { return nil }
                return PhotoLocationTimelinePoint(date: place.arrivalDate, coordinate: place.coordinate)
            }

            var previousVisitDescriptor = FetchDescriptor<VisitPlace>(
                predicate: #Predicate { place in
                    place.arrivalDate < lower
                },
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
            )
            previousVisitDescriptor.fetchLimit = 8
            visits += try modelContext.fetch(previousVisitDescriptor).compactMap { place -> PhotoLocationTimelinePoint? in
                let departure = place.departureDate ?? place.arrivalDate
                guard departure >= lower else { return nil }
                return PhotoLocationTimelinePoint(date: place.arrivalDate, coordinate: place.coordinate)
            }

            if let proposal = PhotoLocationMatcher.match(date: record.creationDate, samples: samples, visits: visits) {
                proposals.append(PhotoLocationProposal(
                    id: record.id,
                    creationDate: proposal.creationDate,
                    latitude: proposal.latitude,
                    longitude: proposal.longitude,
                    confidence: proposal.confidence,
                    reason: proposal.reason
                ))
            }
        }

        return PhotoLocationPreview(
            scannedAssetCount: records.count,
            alreadyLocatedCount: records.count - missing.count,
            proposals: proposals,
            skippedCount: missing.count - proposals.count
        )
    }
}

@MainActor
enum PhotoVisitImporter {
    static func importCandidates(
        _ candidates: [PhotoVisitCandidate],
        into context: ModelContext
    ) throws -> Int {
        var imported = 0
        for candidate in candidates {
            let searchStart = candidate.startDate.addingTimeInterval(-4 * 60 * 60)
            let nearby = try context.fetch(FetchDescriptor<VisitPlace>(
                predicate: #Predicate { place in
                    place.arrivalDate >= searchStart && place.arrivalDate <= candidate.endDate
                },
                sortBy: [SortDescriptor(\VisitPlace.arrivalDate, order: .reverse)]
            )).first { place in
                let placeEnd = place.departureDate ?? place.arrivalDate
                return placeEnd >= candidate.startDate
                    && CLLocation(latitude: place.latitude, longitude: place.longitude)
                        .distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)) <= 180
            }

            if let nearby {
                nearby.departureDate = max(nearby.departureDate ?? nearby.arrivalDate, candidate.endDate)
                nearby.horizontalAccuracy = min(nearby.horizontalAccuracy, candidate.horizontalAccuracy)
                if nearby.comment?.localizedCaseInsensitiveContains("Apple Photos") != true {
                    nearby.comment = [nearby.comment, "Apple Photos: \(candidate.assetIDs.count) asset(s)"].compactMap { $0 }.joined(separator: " · ")
                }
                nearby.provenance = .applePhotos
            } else {
                let place = VisitPlace(
                    arrivalDate: candidate.startDate,
                    departureDate: candidate.endDate,
                    latitude: candidate.latitude,
                    longitude: candidate.longitude,
                    horizontalAccuracy: candidate.horizontalAccuracy,
                    comment: "Imported from Apple Photos: \(candidate.assetIDs.count) asset(s)"
                )
                place.provenance = .applePhotos
                place.dayTimeline = try timeline(for: candidate.startDate, in: context)
                context.insert(place)
                imported += 1
            }
        }
        try context.save()
        return imported
    }

    private static func timeline(for date: Date, in context: ModelContext) throws -> DayTimeline {
        let key = DayTimeline.makeDayKey(for: date)
        if let existing = try context.fetch(FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })).first {
            return existing
        }
        let timeline = DayTimeline(dayStart: date)
        context.insert(timeline)
        return timeline
    }
}

struct PhotoLocationAuditRecord: Codable, Sendable {
    let assetID: String
    let previousLatitude: Double?
    let previousLongitude: Double?
    let writtenLatitude: Double
    let writtenLongitude: Double
    let confidence: PhotoLocationConfidence
    let method: String
    let writtenAt: Date
}

struct PhotoLocationAuditOperation: Codable, Sendable {
    let id: UUID
    let records: [PhotoLocationAuditRecord]
}

actor PhotoLocationAuditStore {
    static let shared = PhotoLocationAuditStore()

    private var operations: [PhotoLocationAuditOperation]?

    func append(_ operation: PhotoLocationAuditOperation) throws {
        var values = try load()
        values.append(operation)
        operations = values
        try save(values)
    }

    func latest() throws -> PhotoLocationAuditOperation? {
        try load().last
    }

    func removeLatest() throws {
        var values = try load()
        _ = values.popLast()
        operations = values
        try save(values)
    }

    private func load() throws -> [PhotoLocationAuditOperation] {
        if let operations { return operations }
        guard FileManager.default.fileExists(atPath: url.path) else {
            operations = []
            return []
        }
        let values = try JSONDecoder().decode([PhotoLocationAuditOperation].self, from: Data(contentsOf: url))
        operations = values
        return values
    }

    private func save(_ values: [PhotoLocationAuditOperation]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Moves", isDirectory: true)
            .appendingPathComponent("photos-location-audit.json")
    }
}

enum PhotoLocationWriter {
    struct Result: Sendable {
        let operationID: UUID
        let writtenCount: Int
    }

    static func write(
        proposals: [PhotoLocationProposal],
        markInAlbum: Bool
    ) async throws -> Result {
        let identifiers = proposals.map(\.id)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            assetsByID[asset.localIdentifier] = asset
        }

        let operationID = UUID()
        let writtenAt = Date.now
        let records = proposals.compactMap { proposal -> PhotoLocationAuditRecord? in
            guard assetsByID[proposal.id] != nil else { return nil }
            return PhotoLocationAuditRecord(
                assetID: proposal.id,
                previousLatitude: nil,
                previousLongitude: nil,
                writtenLatitude: proposal.latitude,
                writtenLongitude: proposal.longitude,
                confidence: proposal.confidence,
                method: proposal.reason,
                writtenAt: writtenAt
            )
        }

        for batchStart in stride(from: 0, to: records.count, by: 100) {
            let batch = Array(records[batchStart..<min(batchStart + 100, records.count)])
            try await performChanges {
                for record in batch {
                    guard let asset = assetsByID[record.assetID] else { continue }
                    PHAssetChangeRequest(for: asset).location = CLLocation(
                        latitude: record.writtenLatitude,
                        longitude: record.writtenLongitude
                    )
                }
            }
        }

        if markInAlbum, !records.isEmpty {
            try await addToMovesAlbum(assets: assetsByID, identifiers: records.map(\.assetID))
        }

        try await PhotoLocationAuditStore.shared.append(PhotoLocationAuditOperation(id: operationID, records: records))
        return Result(operationID: operationID, writtenCount: records.count)
    }

    static func undoLastWrite() async throws -> (restored: Int, skipped: Int) {
        guard let operation = try await PhotoLocationAuditStore.shared.latest() else {
            return (0, 0)
        }
        let identifiers = operation.records.map(\.assetID)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            assetsByID[asset.localIdentifier] = asset
        }

        let matching = operation.records.filter { record in
            guard let current = assetsByID[record.assetID]?.location else { return false }
            return abs(current.coordinate.latitude - record.writtenLatitude) < 0.00001
                && abs(current.coordinate.longitude - record.writtenLongitude) < 0.00001
        }
        let skipped = operation.records.count - matching.count
        try await performChanges {
            for record in matching {
                guard let asset = assetsByID[record.assetID] else { continue }
                let location: CLLocation?
                if let latitude = record.previousLatitude, let longitude = record.previousLongitude {
                    location = CLLocation(latitude: latitude, longitude: longitude)
                } else {
                    location = nil
                }
                PHAssetChangeRequest(for: asset).location = location
            }
        }
        try await PhotoLocationAuditStore.shared.removeLatest()
        return (matching.count, skipped)
    }

    private static func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private static func addToMovesAlbum(
        assets: [String: PHAsset],
        identifiers: [String]
    ) async throws {
        let album: PHAssetCollection
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: PHFetchOptions()
        )
        var existing: PHAssetCollection?
        for index in 0..<collections.count {
            let candidate = collections.object(at: index)
            if candidate.localizedTitle == "Moves – Location Added" {
                existing = candidate
                break
            }
        }
        if let existing {
            album = existing
        } else {
            var placeholder: PHObjectPlaceholder?
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Moves – Location Added").placeholderForCreatedAssetCollection
                }) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume() }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            }
            guard let placeholder else { return }
            let createdCollections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [placeholder.localIdentifier],
                options: nil
            )
            guard createdCollections.count > 0 else {
                return
            }
            album = createdCollections.object(at: 0)
        }

        let selectedAssets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard selectedAssets.count > 0 else { return }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(selectedAssets)
        }
    }
}

@MainActor
final class PhotosIntegrationDebugCoordinator: ObservableObject {
    @Published var statusMessage = "Photos integration is disabled until you explicitly grant access."
    @Published var isWorking = false
    @Published var authorizationStatus = PhotoLibraryMetadataReader.authorizationStatus()
    @Published var visitScan: PhotoScanResult?
    @Published var locationPreview: PhotoLocationPreview?
    @Published var shouldConfirmLocationWrite = false
    @Published var markWrittenAssetsInAlbum = true

    func requestAccess() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            authorizationStatus = await PhotoLibraryMetadataReader.requestAuthorization()
            isWorking = false
            statusMessage = authorizationStatus == .authorized || authorizationStatus == .limited
                ? "Photos metadata access is enabled."
                : "Photos access was not granted."
        }
    }

    func scanVisits() {
        guard isAuthorized, !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                visitScan = try await PhotosIntegrationEngine.scanVisits()
                statusMessage = "Photo visit candidates are ready for review."
            } catch {
                statusMessage = "Photo scan failed: \(error.localizedDescription)"
            }
        }
    }

    func importVisits(context: ModelContext) {
        guard let visitScan, !visitScan.candidates.isEmpty, !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let count = try PhotoVisitImporter.importCandidates(visitScan.candidates, into: context)
                try await PhotosIntegrationEngine.markImported(visitScan.candidates)
                statusMessage = "Imported \(count) new Photos visit(s); nearby Moves visits were enriched."
                self.visitScan = nil
            } catch {
                statusMessage = "Photo visit import failed: \(error.localizedDescription)"
            }
        }
    }

    func prepareLocationPreview(container: ModelContainer) {
        guard isAuthorized, !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let records = try await PhotoLibraryMetadataReader.read()
                let worker = PhotoLocationMatcherWorker(modelContainer: container)
                locationPreview = try await worker.preview(for: records)
                statusMessage = "Location proposals are ready for review."
            } catch {
                statusMessage = "Photo location matching failed: \(error.localizedDescription)"
            }
        }
    }

    func writeLocations() {
        guard let preview = locationPreview, !preview.proposals.isEmpty, !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let result = try await PhotoLocationWriter.write(
                    proposals: preview.proposals,
                    markInAlbum: markWrittenAssetsInAlbum
                )
                statusMessage = "Wrote locations to \(result.writtenCount) asset(s). The operation is auditable and reversible."
                locationPreview = nil
            } catch {
                statusMessage = "Photo location write failed: \(error.localizedDescription)"
            }
        }
    }

    func undoLastWrite() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let result = try await PhotoLocationWriter.undoLastWrite()
                statusMessage = result.restored == 0 && result.skipped == 0
                    ? "There is no audited Photos write to undo."
                    : "Undid \(result.restored) location(s); skipped \(result.skipped) asset(s) changed after the write."
            } catch {
                statusMessage = "Undo failed: \(error.localizedDescription)"
            }
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }
}

struct PhotosIntegrationDebugView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator = PhotosIntegrationDebugCoordinator()

    var body: some View {
        List {
            Section {
                Label(coordinator.statusMessage, systemImage: coordinator.isAuthorized ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(coordinator.isAuthorized ? .green : .secondary)

                if !coordinator.isAuthorized {
                    Button("Enable Photos Metadata Access") {
                        coordinator.requestAccess()
                    }
                }
            } header: {
                Text("Explicit access")
            } footer: {
                Text("Moves reads PhotoKit metadata only. It does not download originals, and enabling this debug tool never changes Photos.")
            }

            Section("Photos → Moves") {
                Button("Scan Photo Locations") {
                    coordinator.scanVisits()
                }
                .disabled(!coordinator.isAuthorized || coordinator.isWorking)

                if let visitScan = coordinator.visitScan {
                    LabeledContent("Assets scanned", value: visitScan.scannedAssetCount.formatted())
                    LabeledContent("Assets with locations", value: visitScan.locatedAssetCount.formatted())
                    LabeledContent("Candidate Visits", value: visitScan.candidates.count.formatted())

                    if !visitScan.candidates.isEmpty {
                        Button("Import Candidate Visits") {
                            coordinator.importVisits(context: modelContext)
                        }
                        .disabled(coordinator.isWorking)
                    }
                }
            }

            Section("Moves → Photos") {
                Button("Prepare Location Preview") {
                    coordinator.prepareLocationPreview(container: modelContext.container)
                }
                .disabled(!coordinator.isAuthorized || coordinator.isWorking)

                if let preview = coordinator.locationPreview {
                    LabeledContent("Assets scanned", value: preview.scannedAssetCount.formatted())
                    LabeledContent("Already located", value: preview.alreadyLocatedCount.formatted())
                    LabeledContent("Proposed locations", value: preview.proposals.count.formatted())
                    LabeledContent("Skipped / ambiguous", value: preview.skippedCount.formatted())

                    ForEach(PhotoLocationConfidence.allCases, id: \.self) { confidence in
                        LabeledContent(confidence.title, value: (preview.confidenceCounts[confidence] ?? 0).formatted())
                    }

                    Toggle("Add written assets to Moves album", isOn: $coordinator.markWrittenAssetsInAlbum)
                    Button("Review and Write Proposed Locations") {
                        coordinator.shouldConfirmLocationWrite = true
                    }
                    .disabled(preview.proposals.isEmpty || coordinator.isWorking)
                }
            }

            Section("Audit") {
                Button("Undo Last Moves Photo Write", role: .destructive) {
                    coordinator.undoLastWrite()
                }
                .disabled(coordinator.isWorking)

                Text("Undo only clears locations that still exactly match what Moves wrote. Later edits in Photos are preserved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Photos Debug")
        .overlay {
            if coordinator.isWorking {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog(
            "Write Photo Locations?",
            isPresented: $coordinator.shouldConfirmLocationWrite,
            titleVisibility: .visible
        ) {
            Button("Write Proposed Locations") {
                coordinator.writeLocations()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only photos without existing locations will be changed. The preview will be written in one PhotoKit operation and audited for safe undo.")
        }
    }
}

#endif
