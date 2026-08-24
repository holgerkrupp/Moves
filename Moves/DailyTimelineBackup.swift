import BackgroundTasks
import Foundation
import SwiftData

enum DailyTimelineBackupFormat: String, CaseIterable, Identifiable {
    case gpx
    case geoJSON
    case csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpx: "GPX (.gpx)"
        case .geoJSON: "GeoJSON (.geojson)"
        case .csv: "CSV (.csv)"
        }
    }

    var timelineExportFormat: TimelineExportFormat {
        switch self {
        case .gpx: .gpx
        case .geoJSON: .geoJSON
        case .csv: .csv
        }
    }
}

enum DailyTimelineBackupError: LocalizedError {
    case iCloudDriveUnavailable
    case destinationDirectoryUnavailable
    case noTimeline(for: Date)
    case couldNotCreateExport
    case fileWasNotWritten
    case couldNotScheduleBackgroundRun(String)

    var errorDescription: String? {
        switch self {
        case .iCloudDriveUnavailable:
            "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive, then try again."
        case .destinationDirectoryUnavailable:
            "Moves could not create its iCloud Drive backup folder."
        case .noTimeline(let date):
            "No timeline is available for \(date.formatted(date: .abbreviated, time: .omitted))."
        case .couldNotCreateExport:
            "Moves could not create the backup file."
        case .fileWasNotWritten:
            "Moves created the backup folder, but the backup file could not be written."
        case .couldNotScheduleBackgroundRun(let reason):
            "Moves could not schedule the nightly backup: \(reason)"
        }
    }
}

enum DailyTimelineBackup {
    static let taskIdentifier = "de.holgerkrupp.Moves.dailyTimelineBackup"
    static let isEnabledKey = "Moves.dailyTimelineBackup.isEnabled"
    static let formatKey = "Moves.dailyTimelineBackup.format"
    static let usesMonthlyFoldersKey = "Moves.dailyTimelineBackup.usesMonthlyFolders"
    static let cloudContainerIdentifier = "iCloud.de.holgerkrupp.Moves"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: isEnabledKey)
    }

    /// Writes yesterday's timeline into the app's iCloud Drive folder.
    ///
    /// Resolving the ubiquity container is a blocking call that can take seconds on
    /// its first use, so the whole job runs off the main thread.
    @discardableResult
    static func saveYesterday(
        in modelContainer: ModelContainer,
        userDefaults: UserDefaults = .standard,
        now: Date = .now
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try writeYesterday(in: modelContainer, userDefaults: userDefaults, now: now)
        }.value
    }

    private static func writeYesterday(
        in modelContainer: ModelContainer,
        userDefaults: UserDefaults,
        now: Date
    ) throws -> URL {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let dayKey = DayTimeline.makeDayKey(for: yesterday)
        let destinationDirectory = try ensureDestinationDirectory(
            for: yesterday,
            userDefaults: userDefaults
        )
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<DayTimeline>(
            predicate: #Predicate { $0.dayKey == dayKey }
        )
        guard let day = try context.fetch(descriptor).first else {
            throw DailyTimelineBackupError.noTimeline(for: yesterday)
        }

        let format = DailyTimelineBackupFormat(
            rawValue: userDefaults.string(forKey: formatKey) ?? "gpx"
        ) ?? .gpx
        guard let payload = TimelineExporter.makePayload(
            days: [day],
            format: format.timelineExportFormat,
            fileStem: "Moves-\(dayKey)"
        ) else {
            throw DailyTimelineBackupError.couldNotCreateExport
        }

        let destination = destinationDirectory.appendingPathComponent(payload.filename)
        try writeCoordinated(payload.data, to: destination)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw DailyTimelineBackupError.fileWasNotWritten
        }
        return destination
    }

    /// Writes through `NSFileCoordinator` so iCloud picks the file up for upload
    /// instead of racing with our own write.
    private static func writeCoordinated(_ data: Data, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    /// Creates and returns the app's visible iCloud Drive backup folder.
    ///
    /// Never call this from the main thread: `url(forUbiquityContainerIdentifier:)`
    /// blocks until the container is available.
    @discardableResult
    static func ensureDestinationDirectory(
        for date: Date,
        userDefaults: UserDefaults = .standard
    ) throws -> URL {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.url(
            forUbiquityContainerIdentifier: cloudContainerIdentifier
        ) else {
            throw DailyTimelineBackupError.iCloudDriveUnavailable
        }

        // `Documents` is the only part of the container iCloud Drive shows to the
        // user, and it already appears there under the container's display name.
        var directory = containerURL
            .appendingPathComponent("Documents", isDirectory: true)

        if userDefaults.bool(forKey: usesMonthlyFoldersKey) {
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else {
                throw DailyTimelineBackupError.destinationDirectoryUnavailable
            }
            directory = directory
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DailyTimelineBackupError.destinationDirectoryUnavailable
        }
        return directory
    }

    /// Returns the error that prevented scheduling, or `nil` on success.
    @discardableResult
    static func scheduleNextRun() -> Error? {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        guard isEnabled() else { return nil }

        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = nextRunDate()
        do {
            try BGTaskScheduler.shared.submit(request)
            return nil
        } catch {
            return DailyTimelineBackupError.couldNotScheduleBackgroundRun(
                (error as NSError).localizedDescription
            )
        }
    }

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handle(task: task as! BGProcessingTask)
        }
    }

    private static func handle(task: BGProcessingTask) {
        scheduleNextRun()

        let work = Task {
            guard isEnabled() else {
                task.setTaskCompleted(success: true)
                return
            }
            do {
                let container = try await MainActor.run { try MovesApp.makeModelContainer() }
                _ = try await saveYesterday(in: container)
                task.setTaskCompleted(success: true)
            } catch {
                // The next scheduled run will retry; iCloud may be temporarily unavailable.
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func nextRunDate(now: Date = .now) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 0, minute: 5, second: 0, of: tomorrow) ?? tomorrow
    }
}
