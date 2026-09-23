import Compression
import Foundation

struct RouteImportAcquisitionConfiguration: Sendable {
    var maximumStagedFiles: Int = 512
    var maximumStagedBytes: Int64 = 512 * 1024 * 1024

    init(maximumStagedFiles: Int = 512, maximumStagedBytes: Int64 = 512 * 1024 * 1024) {
        self.maximumStagedFiles = maximumStagedFiles
        self.maximumStagedBytes = maximumStagedBytes
    }
}

struct RouteImportAcquisitionResult: Sendable {
    let files: [URL]
    let sourceNames: [String]
    let sourceIdentifiers: [String]
    let bookmarkData: [Data]
}

enum RouteImportAcquisitionError: LocalizedError, Sendable, Equatable {
    case sourceUnavailable(String)
    case stagingLimitExceeded
    case invalidArchive

    var isRecoverable: Bool { true }

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let source):
            return "The selected source is unavailable. Reconnect it or select it again: \(source)"
        case .stagingLimitExceeded:
            return "The selected route import is too large to stage safely. Select fewer or smaller files."
        case .invalidArchive:
            return "The route archive is invalid or uses an unsupported compression format."
        }
    }
}

/// Acquires picker/File Provider URLs into app-owned storage before parsing begins.
/// The limits are deliberately enforced before each copy, so a partial staging directory
/// can be safely removed and a job can be retried without touching the source.
struct RouteImportAcquirer {
    let stagingDirectory: URL
    let configuration: RouteImportAcquisitionConfiguration
    let fileManager: FileManager

    init(
        stagingDirectory: URL,
        configuration: RouteImportAcquisitionConfiguration = .init(),
        fileManager: FileManager = .default
    ) {
        self.stagingDirectory = stagingDirectory
        self.configuration = configuration
        self.fileManager = fileManager
    }

    func acquire(urls: [URL]) throws -> RouteImportAcquisitionResult {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var files: [URL] = []
        var sourceNames: [String] = []
        var sourceIdentifiers: [String] = []
        var bookmarks: [Data] = []
        var seen = Set<String>()
        var stagedBytes: Int64 = 0
        var succeeded = false
        // Keep partial staging on failure. The recovery UI can retry from it or let the
        // user choose the source again; cleanup is explicit through Discard.
        defer { _ = succeeded }

        for source in urls.sorted(by: stableURLOrder) {
            let resolved = try resolve(source)
            let didAccess = resolved.url.startAccessingSecurityScopedResource()
            defer { if didAccess { resolved.url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory) else {
                throw RouteImportAcquisitionError.sourceUnavailable(source.path)
            }

            let candidates: [(URL, Data?)]
            if isDirectory.boolValue {
                candidates = try enumerate(directory: resolved.url).map { ($0, nil) }
            } else if resolved.url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame {
                candidates = try extract(zip: resolved.url)
            } else if isSupportedRouteFile(resolved.url) {
                candidates = [(resolved.url, nil)]
            } else {
                candidates = []
            }

            for (candidate, archiveData) in candidates {
                let identity = candidate.standardizedFileURL.resolvingSymlinksInPath().path
                guard seen.insert(identity).inserted else { continue }
                let dataSize: Int64
                if let archiveData {
                    dataSize = Int64(archiveData.count)
                } else {
                    dataSize = Int64(try fileSize(candidate))
                }
                guard files.count < configuration.maximumStagedFiles,
                      stagedBytes <= configuration.maximumStagedBytes - dataSize else {
                    throw RouteImportAcquisitionError.stagingLimitExceeded
                }

                let destination = stagingDirectory.appendingPathComponent(
                    String(format: "%06d-%@", files.count, safeFileName(candidate.lastPathComponent))
                )
                if let archiveData {
                    try archiveData.write(to: destination, options: .atomic)
                } else {
                    do { try fileManager.copyItem(at: candidate, to: destination) }
                    catch { throw RouteImportAcquisitionError.sourceUnavailable(candidate.path) }
                }
                files.append(destination)
                stagedBytes += dataSize
                sourceNames.append(candidate.lastPathComponent)
            }

            sourceIdentifiers.append(resolved.url.path)
            if let bookmark = resolved.bookmark { bookmarks.append(bookmark) }
        }

        succeeded = true
        return RouteImportAcquisitionResult(
            files: files,
            sourceNames: sourceNames,
            sourceIdentifiers: sourceIdentifiers,
            bookmarkData: bookmarks
        )
    }

    private struct ResolvedSource {
        let url: URL
        let bookmark: Data?
    }

    private func resolve(_ source: URL) throws -> ResolvedSource {
        // A URL can be passed directly by tests and by older callers. For picker URLs,
        // resolving a bookmark is best-effort because File Provider URLs may not vend one.
        if let data = try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return ResolvedSource(url: resolved, bookmark: data)
            }
        }
        return ResolvedSource(url: source, bookmark: try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    private func enumerate(directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { throw RouteImportAcquisitionError.sourceUnavailable(directory.path) }
        return enumerator.compactMap { $0 as? URL }
            .filter { isSupportedRouteFile($0) }
            .sorted(by: stableURLOrder)
    }

    private func fileSize(_ url: URL) throws -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else {
            throw RouteImportAcquisitionError.sourceUnavailable(url.path)
        }
        return size
    }

    private func isSupportedRouteFile(_ url: URL) -> Bool {
        ["gpx", "tcx", "kml", "geojson", "json"].contains(url.pathExtension.lowercased())
    }

    private func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }

    private func stableURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path.localizedStandardCompare(rhs.standardizedFileURL.path) == .orderedAscending
    }

    private func extract(zip: URL) throws -> [(URL, Data?)] {
        let data: Data
        do { data = try Data(contentsOf: zip) } catch { throw RouteImportAcquisitionError.sourceUnavailable(zip.path) }
        // ZIP files start with local file records; the central directory lives near the end.
        // Locate the end-of-central-directory record first instead of assuming that the first
        // bytes are a central-directory entry.
        guard data.count >= 22 else { throw RouteImportAcquisitionError.invalidArchive }
        let earliestEOCDOffset = max(0, data.count - 65_557)
        var endOfCentralDirectoryOffset: Int?
        for offset in stride(from: data.count - 22, through: earliestEOCDOffset, by: -1) {
            if data.uint32LE(at: offset) == 0x06054B50 {
                endOfCentralDirectoryOffset = offset
                break
            }
        }
        guard let endOfCentralDirectoryOffset else { throw RouteImportAcquisitionError.invalidArchive }

        let entryCount = Int(data.uint16LE(at: endOfCentralDirectoryOffset + 10))
        let centralDirectorySize = Int(data.uint32LE(at: endOfCentralDirectoryOffset + 12))
        var cursor = Int(data.uint32LE(at: endOfCentralDirectoryOffset + 16))
        guard cursor >= 0,
              centralDirectorySize <= data.count,
              cursor <= data.count - centralDirectorySize else {
            throw RouteImportAcquisitionError.invalidArchive
        }

        var result: [(URL, Data?)] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  data.uint32LE(at: cursor) == 0x02014B50 else {
                throw RouteImportAcquisitionError.invalidArchive
            }
            let flags = data.uint16LE(at: cursor + 8)
            let method = data.uint16LE(at: cursor + 10)
            let compressedSize = Int(data.uint32LE(at: cursor + 20))
            let nameLength = Int(data.uint16LE(at: cursor + 28))
            let extraLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let localOffset = Int(data.uint32LE(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw RouteImportAcquisitionError.invalidArchive }
            let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""
            cursor = nameStart + nameLength + extraLength + commentLength
            let nameURL = URL(fileURLWithPath: name)
            guard isSupportedRouteFile(nameURL), !name.hasSuffix("/") else { continue }
            guard flags & 0x1 == 0 else { throw RouteImportAcquisitionError.invalidArchive }
            guard localOffset + 30 <= data.count, data.uint32LE(at: localOffset) == 0x04034B50 else { throw RouteImportAcquisitionError.invalidArchive }
            let localNameLength = Int(data.uint16LE(at: localOffset + 26))
            let localExtraLength = Int(data.uint16LE(at: localOffset + 28))
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            guard payloadStart + compressedSize <= data.count else { throw RouteImportAcquisitionError.invalidArchive }
            let compressed = Data(data[payloadStart..<(payloadStart + compressedSize)])
            let contents: Data
            switch method {
            case 0: contents = compressed
            case 8: contents = try inflate(compressed)
            default: throw RouteImportAcquisitionError.invalidArchive
            }
            result.append((nameURL, contents))
        }
        return result.sorted { stableURLOrder($0.0, $1.0) }
    }

    private func inflate(_ data: Data) throws -> Data {
        var destination = Data(count: max(data.count * 4, 1))
        while true {
            let status = destination.withUnsafeMutableBytes { output in
                data.withUnsafeBytes { input in
                    compression_decode_buffer(
                        output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if status > 0 { return destination.prefix(status) }
            if destination.count > 64 * 1024 * 1024 { throw RouteImportAcquisitionError.invalidArchive }
            destination.append(Data(repeating: 0, count: destination.count))
        }
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(uint16LE(at: offset)) | (UInt32(uint16LE(at: offset + 2)) << 16)
    }
}
