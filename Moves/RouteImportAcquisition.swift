import Compression
import CryptoKit
import Foundation

struct RouteImportAcquisitionConfiguration: Sendable {
    /// Keep a generous file-count bound for exports that store every route in a separate
    /// file. The byte limit remains the primary disk-space safeguard.
    var maximumStagedFiles: Int = 25_000
    var maximumStagedBytes: Int64 = 512 * 1024 * 1024

    init(maximumStagedFiles: Int = 25_000, maximumStagedBytes: Int64 = 512 * 1024 * 1024) {
        self.maximumStagedFiles = maximumStagedFiles
        self.maximumStagedBytes = maximumStagedBytes
    }
}

struct RouteImportAcquisitionResult: Sendable {
    let files: [URL]
    let sourceNames: [String]
    let sourceIdentifiers: [String]
    let bookmarkData: [Data]
    let accessRoots: [RouteImportAccessRoot]
    let filesAreStaged: Bool
}

enum RouteImportAcquisitionDisposition: Sendable, Equatable {
    case removeStagedFile
    case retainStagedFile
}

struct RouteImportAcquiredFile: Sendable {
    let url: URL
    let displayName: String
    let sourceIdentifier: String
    let isStaged: Bool
    let accessRoot: RouteImportAccessRoot?
}

struct RouteImportAcquisitionSummary: Sendable {
    let sourceNames: [String]
    let sourceIdentifiers: [String]
    let bookmarkData: [Data]
    let accessRoots: [RouteImportAccessRoot]
    let discoveredFileCount: Int
    let filesAreStaged: Bool
}

private struct RouteImportZipEntry {
    let path: String
    let nameURL: URL
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int64
    let localHeaderOffset: UInt64
}

struct RouteImportAccessRoot: Codable, Hashable, Sendable {
    let path: String
    let bookmarkData: Data?
}

enum RouteImportAcquisitionError: LocalizedError, Sendable, Equatable {
    case sourceUnavailable(String)
    case stagingFileLimitExceeded(maximum: Int)
    case stagingByteLimitExceeded(maximum: Int64)
    case invalidArchive

    var isRecoverable: Bool { true }

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let source):
            return "The selected source is unavailable. Reconnect it or select it again: \(source)"
        case .stagingFileLimitExceeded(let maximum):
            return "This route import contains more than \(maximum.formatted()) supported files. Select a smaller folder."
        case .stagingByteLimitExceeded(let maximum):
            let formatted = ByteCountFormatter.string(fromByteCount: maximum, countStyle: .file)
            return "This route import needs more than \(formatted) of temporary space. Select fewer or smaller files."
        case .invalidArchive:
            return "The route archive is invalid or uses an unsupported compression format."
        }
    }
}

/// Enumerates picker/File Provider URLs and, when requested, copies them into app-owned
/// storage. One-at-a-time imports retain source access and defer each copy until parsing.
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

    func acquire(urls: [URL], stageFiles: Bool = true) throws -> RouteImportAcquisitionResult {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var files: [URL] = []
        var sourceNames: [String] = []
        var sourceIdentifiers: [String] = []
        var bookmarks: [Data] = []
        var accessRoots: [RouteImportAccessRoot] = []
        var seen = Set<String>()
        var stagedBytes: Int64 = 0
        var succeeded = false
        // Keep partial staging on failure. The recovery UI can retry from it or let the
        // user choose the source again; cleanup is explicit through Discard.
        defer { _ = succeeded }

        for source in urls.sorted(by: stableURLOrder) {
            try Task.checkCancellation()
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
                try Task.checkCancellation()
                let identity = candidate.standardizedFileURL.resolvingSymlinksInPath().path
                guard seen.insert(identity).inserted else { continue }
                let dataSize: Int64
                if let archiveData {
                    dataSize = Int64(archiveData.count)
                } else {
                    dataSize = Int64(try fileSize(candidate))
                }
                guard files.count < configuration.maximumStagedFiles else {
                    throw RouteImportAcquisitionError.stagingFileLimitExceeded(
                        maximum: configuration.maximumStagedFiles
                    )
                }
                guard dataSize <= configuration.maximumStagedBytes,
                      !stageFiles || stagedBytes <= configuration.maximumStagedBytes - dataSize else {
                    throw RouteImportAcquisitionError.stagingByteLimitExceeded(
                        maximum: configuration.maximumStagedBytes
                    )
                }

                if stageFiles {
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
                } else {
                    // The importer will acquire access, copy, process, and remove this file
                    // immediately. ZIP imports use the all-at-once path because their entries
                    // do not have independent source URLs.
                    guard archiveData == nil else { throw RouteImportAcquisitionError.invalidArchive }
                    files.append(candidate)
                }
                sourceNames.append(candidate.lastPathComponent)
            }

            sourceIdentifiers.append(resolved.url.path)
            if let bookmark = resolved.bookmark { bookmarks.append(bookmark) }
            accessRoots.append(RouteImportAccessRoot(path: resolved.url.path, bookmarkData: resolved.bookmark))
        }

        succeeded = true
        return RouteImportAcquisitionResult(
            files: files,
            sourceNames: sourceNames,
            sourceIdentifiers: sourceIdentifiers,
            bookmarkData: bookmarks,
            accessRoots: accessRoots,
            filesAreStaged: stageFiles
        )
    }

    /// Streams the selected source set through a bounded staging window. The callback is
    /// awaited before the next source is admitted, so at most one staged route file (or ZIP
    /// entry) is live for the normal importer. Folder enumeration may retain lightweight URL
    /// metadata for deterministic ordering, but route contents are never accumulated.
    func process(
        urls: [URL],
        stageFiles: Bool,
        onFile: @Sendable (RouteImportAcquiredFile) async throws -> RouteImportAcquisitionDisposition
    ) async throws -> RouteImportAcquisitionSummary {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var sourceNames: [String] = []
        var sourceIdentifiers: [String] = []
        var bookmarks: [Data] = []
        var accessRoots: [RouteImportAccessRoot] = []
        var seen = Set<String>()
        var sequence = 0

        for source in urls.sorted(by: stableURLOrder) {
            try Task.checkCancellation()
            let resolved = try resolve(source)
            let didAccess = resolved.url.startAccessingSecurityScopedResource()
            defer { if didAccess { resolved.url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory) else {
                throw RouteImportAcquisitionError.sourceUnavailable(source.path)
            }

            if resolved.url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame {
                if let bookmark = resolved.bookmark { bookmarks.append(bookmark) }
                accessRoots.append(RouteImportAccessRoot(path: resolved.url.path, bookmarkData: resolved.bookmark))
                guard stageFiles else { throw RouteImportAcquisitionError.invalidArchive }
                let entries = try zipEntries(in: resolved.url)
                for entry in entries {
                    try Task.checkCancellation()
                    let sourceIdentifier = resolved.url.path + "::" + entry.path
                    guard seen.insert(sourceIdentifier).inserted else { continue }
                    guard sequence < configuration.maximumStagedFiles else {
                        throw RouteImportAcquisitionError.stagingFileLimitExceeded(
                            maximum: configuration.maximumStagedFiles
                        )
                    }
                    guard entry.uncompressedSize <= configuration.maximumStagedBytes else {
                        throw RouteImportAcquisitionError.stagingByteLimitExceeded(
                            maximum: configuration.maximumStagedBytes
                        )
                    }
                    let fileURL = stagingDirectory.appendingPathComponent(
                        String(format: "%06d-%@", sequence, safeFileName(entry.nameURL.lastPathComponent))
                    )
                    try extract(entry: entry, from: resolved.url, to: fileURL)
                    sequence += 1
                    sourceNames.append(entry.nameURL.lastPathComponent)
                    sourceIdentifiers.append(sourceIdentifier)
                    let disposition = try await onFile(RouteImportAcquiredFile(
                        url: fileURL,
                        displayName: entry.nameURL.lastPathComponent,
                        sourceIdentifier: sourceIdentifier,
                        isStaged: true,
                        accessRoot: RouteImportAccessRoot(path: resolved.url.path, bookmarkData: resolved.bookmark)
                    ))
                    if disposition == .removeStagedFile {
                        try? fileManager.removeItem(at: fileURL)
                    }
                }
                continue
            }

            let candidates: [(URL, Data?, String)]
            if isDirectory.boolValue {
                candidates = try enumerate(directory: resolved.url).map { ($0, nil, $0.path) }
            } else if isSupportedRouteFile(resolved.url) {
                candidates = [(resolved.url, nil, resolved.url.path)]
            } else {
                candidates = []
            }

            if let bookmark = resolved.bookmark { bookmarks.append(bookmark) }
            accessRoots.append(RouteImportAccessRoot(path: resolved.url.path, bookmarkData: resolved.bookmark))

            for (candidate, archiveData, sourceIdentifier) in candidates {
                try Task.checkCancellation()
                let identity = sourceIdentifier
                guard seen.insert(identity).inserted else { continue }

                let dataSize: Int64
                if let archiveData {
                    dataSize = Int64(archiveData.count)
                } else {
                    dataSize = Int64(try fileSize(candidate))
                }
                guard sequence < configuration.maximumStagedFiles else {
                    throw RouteImportAcquisitionError.stagingFileLimitExceeded(
                        maximum: configuration.maximumStagedFiles
                    )
                }
                guard dataSize <= configuration.maximumStagedBytes else {
                    throw RouteImportAcquisitionError.stagingByteLimitExceeded(
                        maximum: configuration.maximumStagedBytes
                    )
                }

                let fileURL: URL
                if stageFiles {
                    fileURL = stagingDirectory.appendingPathComponent(
                        String(format: "%06d-%@", sequence, safeFileName(candidate.lastPathComponent))
                    )
                    if let archiveData {
                        try archiveData.write(to: fileURL, options: .atomic)
                    } else {
                        do { try fileManager.copyItem(at: candidate, to: fileURL) }
                        catch { throw RouteImportAcquisitionError.sourceUnavailable(candidate.path) }
                    }
                } else {
                    guard archiveData == nil else { throw RouteImportAcquisitionError.invalidArchive }
                    fileURL = candidate
                }
                sequence += 1
                sourceNames.append(candidate.lastPathComponent)
                sourceIdentifiers.append(sourceIdentifier)

                let disposition: RouteImportAcquisitionDisposition
                do {
                    disposition = try await onFile(RouteImportAcquiredFile(
                        url: fileURL,
                        displayName: candidate.lastPathComponent,
                        sourceIdentifier: sourceIdentifier,
                        isStaged: stageFiles,
                        accessRoot: RouteImportAccessRoot(path: resolved.url.path, bookmarkData: resolved.bookmark)
                    ))
                } catch {
                    // A paused/cancelled import must be able to resume from the item that was
                    // admitted but not committed. Keep its staged copy for that checkpoint.
                    throw error
                }
                if stageFiles, disposition == .removeStagedFile {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }

        return RouteImportAcquisitionSummary(
            sourceNames: sourceNames,
            sourceIdentifiers: sourceIdentifiers,
            bookmarkData: bookmarks,
            accessRoots: accessRoots,
            discoveredFileCount: sequence,
            filesAreStaged: stageFiles
        )
    }

    private struct ResolvedSource {
        let url: URL
        let bookmark: Data?
    }

    private func resolve(_ source: URL) throws -> ResolvedSource {
        // A URL can be passed directly by tests and by older callers. For picker URLs,
        // resolving a bookmark is best-effort because File Provider URLs may not vend one.
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
#if os(macOS)
        let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
        let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
#else
        let creationOptions: URL.BookmarkCreationOptions = []
        let resolutionOptions: URL.BookmarkResolutionOptions = []
#endif
        let bookmark = try? source.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        // Keep an explicitly supplied file URL stable. Resolving a local bookmark can change
        // /var to /private/var, which makes source identities look different across launches;
        // the bookmark is still retained for later recovery.
        if !source.isFileURL, let data = bookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return ResolvedSource(url: resolved, bookmark: data)
            }
        }
        return ResolvedSource(
            url: source,
            bookmark: bookmark
        )
    }

    private func enumerate(directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { throw RouteImportAcquisitionError.sourceUnavailable(directory.path) }
        let resolvedRootPath = directory.resolvingSymlinksInPath().path
        return enumerator.compactMap { item -> URL? in
            guard let itemURL = item as? URL, isSupportedRouteFile(itemURL) else { return nil }
            let resolvedItemPath = itemURL.resolvingSymlinksInPath().path
            guard resolvedItemPath.hasPrefix(resolvedRootPath + "/") else { return itemURL }
            let relativePath = String(resolvedItemPath.dropFirst(resolvedRootPath.count + 1))
            return directory.appendingPathComponent(relativePath)
        }
            .sorted(by: stableURLOrder)
    }

    private func zipEntries(in url: URL) throws -> [RouteImportZipEntry] {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw RouteImportAcquisitionError.sourceUnavailable(url.path) }
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailSize)
        guard let tail = try handle.read(upToCount: Int(tailSize)), tail.count >= 22 else {
            throw RouteImportAcquisitionError.invalidArchive
        }
        var eocdOffset: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.uint32LE(at: offset) == 0x06054B50 {
                eocdOffset = offset
                break
            }
        }
        guard let eocdOffset else { throw RouteImportAcquisitionError.invalidArchive }
        let entryCount = Int(tail.uint16LE(at: eocdOffset + 10))
        let centralSize = Int(tail.uint32LE(at: eocdOffset + 12))
        let centralOffset = UInt64(tail.uint32LE(at: eocdOffset + 16))
        guard centralSize >= 0, centralOffset + UInt64(centralSize) <= fileSize else {
            throw RouteImportAcquisitionError.invalidArchive
        }
        try handle.seek(toOffset: centralOffset)
        guard let central = try handle.read(upToCount: centralSize), central.count == centralSize else {
            throw RouteImportAcquisitionError.invalidArchive
        }
        var cursor = 0
        var entries: [RouteImportZipEntry] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= central.count, central.uint32LE(at: cursor) == 0x02014B50 else {
                throw RouteImportAcquisitionError.invalidArchive
            }
            let flags = central.uint16LE(at: cursor + 8)
            let method = central.uint16LE(at: cursor + 10)
            let compressedSize = Int(central.uint32LE(at: cursor + 20))
            let uncompressedSize = Int64(central.uint32LE(at: cursor + 24))
            let nameLength = Int(central.uint16LE(at: cursor + 28))
            let extraLength = Int(central.uint16LE(at: cursor + 30))
            let commentLength = Int(central.uint16LE(at: cursor + 32))
            let localOffset = UInt64(central.uint32LE(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= central.count else {
                throw RouteImportAcquisitionError.invalidArchive
            }
            let name = String(data: central[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""
            cursor = nameStart + nameLength + extraLength + commentLength
            let nameURL = URL(fileURLWithPath: name)
            guard flags & 0x1 == 0, isSafeArchivePath(name), !name.hasSuffix("/"),
                  isSupportedRouteFile(nameURL) else {
                if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                    throw RouteImportAcquisitionError.invalidArchive
                }
                continue
            }
            guard method == 0 || method == 8,
                  localOffset + 30 <= fileSize else {
                throw RouteImportAcquisitionError.invalidArchive
            }
            entries.append(RouteImportZipEntry(
                path: name,
                nameURL: nameURL,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func extract(entry: RouteImportZipEntry, from archive: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        try input.seek(toOffset: entry.localHeaderOffset)
        guard let localHeader = try input.read(upToCount: 30), localHeader.count == 30,
              localHeader.uint32LE(at: 0) == 0x04034B50 else {
            throw RouteImportAcquisitionError.invalidArchive
        }
        let nameLength = Int(localHeader.uint16LE(at: 26))
        let extraLength = Int(localHeader.uint16LE(at: 28))
        let payloadOffset = entry.localHeaderOffset + UInt64(30 + nameLength + extraLength)
        guard payloadOffset + UInt64(entry.compressedSize) <= (try input.seekToEnd()) else {
            throw RouteImportAcquisitionError.invalidArchive
        }
        try input.seek(toOffset: payloadOffset)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        switch entry.method {
        case 0:
            var remaining = entry.compressedSize
            while remaining > 0 {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else {
                    throw RouteImportAcquisitionError.invalidArchive
                }
                try output.write(contentsOf: chunk)
                remaining -= chunk.count
            }
        case 8:
            try inflate(entrySize: entry.compressedSize, input: input, output: output)
        default:
            throw RouteImportAcquisitionError.invalidArchive
        }
    }

    private func inflate(entrySize: Int, input: FileHandle, output: FileHandle) throws {
        let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { empty.deallocate() }
        var stream = compression_stream(dst_ptr: empty, dst_size: 0, src_ptr: empty, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw RouteImportAcquisitionError.invalidArchive
        }
        defer { compression_stream_destroy(&stream) }
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { outputBuffer.deallocate() }
        var remaining = entrySize
        var ended = false
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else {
                throw RouteImportAcquisitionError.invalidArchive
            }
            remaining -= chunk.count
            try chunk.withUnsafeBytes { rawBuffer in
                guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    throw RouteImportAcquisitionError.invalidArchive
                }
                stream.src_ptr = source
                stream.src_size = chunk.count
                while stream.src_size > 0 {
                    stream.dst_ptr = outputBuffer
                    stream.dst_size = 64 * 1024
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let status = compression_stream_process(&stream, flags)
                    let produced = 64 * 1024 - stream.dst_size
                    if produced > 0 { try output.write(contentsOf: Data(bytes: outputBuffer, count: produced)) }
                    if status == COMPRESSION_STATUS_ERROR { throw RouteImportAcquisitionError.invalidArchive }
                    if status == COMPRESSION_STATUS_END { ended = true; break }
                }
            }
            if ended { break }
        }
        while !ended {
            stream.src_ptr = UnsafePointer(empty)
            stream.src_size = 0
            stream.dst_ptr = outputBuffer
            stream.dst_size = 64 * 1024
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = 64 * 1024 - stream.dst_size
            if produced > 0 { try output.write(contentsOf: Data(bytes: outputBuffer, count: produced)) }
            if status == COMPRESSION_STATUS_ERROR { throw RouteImportAcquisitionError.invalidArchive }
            if status == COMPRESSION_STATUS_END { ended = true }
            if produced == 0 && status != COMPRESSION_STATUS_END { throw RouteImportAcquisitionError.invalidArchive }
        }
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

    private func isSafeArchivePath(_ name: String) -> Bool {
        !name.hasPrefix("/") && !name.split(separator: "/").contains("..") && !name.contains("\\")
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

struct ImportFingerprintRecord: Codable, Hashable, Sendable {
    let digest: String
    let byteCount: Int64
    let originalFileName: String
    let checkpointID: UUID
    let completedAt: Date
}

/// Durable exact-content ledger. It is intentionally local operational state and is updated
/// only after the corresponding SwiftData import/checkpoint has succeeded.
struct ImportFingerprintLedger: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moves/ImportFingerprints.json")
    }

    func load() throws -> [ImportFingerprintRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ImportFingerprintRecord].self, from: Data(contentsOf: fileURL))
    }

    func record(_ record: ImportFingerprintRecord) throws {
        var records = try load()
        records.removeAll { $0.digest == record.digest && $0.byteCount == record.byteCount }
        records.append(record)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }

    func matching(digest: String, byteCount: Int64) throws -> ImportFingerprintRecord? {
        try load().last { $0.digest == digest && $0.byteCount == byteCount }
    }
}

enum RouteImportFingerprinting {
    static func hash(file url: URL) throws -> (digest: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            count += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, count)
    }
}
