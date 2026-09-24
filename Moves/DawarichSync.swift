//
//  DawarichSync.swift
//  Moves
//
//  Optional export of Moves location samples to supported location-history
//  servers. The filename is retained so existing project references keep working.
//

import CoreLocation
import Foundation
import Security
import SwiftData
import SwiftUI

enum LocationService: String, CaseIterable, Identifiable, Codable {
    case dawarich
    case reitti
    case geoPulse
    case ownTracksRecorder
    case traccar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dawarich: return "Dawarich"
        case .reitti: return "Reitti"
        case .geoPulse: return "GeoPulse"
        case .ownTracksRecorder: return "OwnTracks Recorder"
        case .traccar: return "Traccar"
        }
    }

    var systemImage: String {
        switch self {
        case .dawarich: return "location.fill.viewfinder"
        case .reitti: return "point.topleft.down.to.point.bottomright.curvepath"
        case .geoPulse: return "waveform.path.ecg"
        case .ownTracksRecorder: return "record.circle"
        case .traccar: return "location.circle"
        }
    }

    var documentationURL: URL {
        switch self {
        case .dawarich:
            return URL(string: "https://dawarich.app/docs/getting-started/track-your-location/")!
        case .reitti:
            return URL(string: "https://www.dedicatedcode.com/projects/reitti/5.0/integrations/mobile-apps/#owntracks-setup")!
        case .geoPulse:
            return URL(string: "https://geopulse.cc/docs/user-guide/gps-sources/owntracks")!
        case .ownTracksRecorder:
            return URL(string: "https://github.com/owntracks/recorder#http-mode")!
        case .traccar:
            return URL(string: "https://www.traccar.org/protocols/")!
        }
    }

    var serverPlaceholder: String {
        switch self {
        case .dawarich: return "https://dawarich.example.com"
        case .reitti: return "https://reitti.example.com"
        case .geoPulse: return "https://geopulse.example.com"
        case .ownTracksRecorder: return "https://recorder.example.com"
        case .traccar: return "https://traccar.example.com:5144"
        }
    }

    var setupHelp: String {
        switch self {
        case .dawarich:
            return "Use the API key from Dawarich Account → API access."
        case .reitti:
            return "Use a Reitti API token that is attached to the destination device."
        case .geoPulse:
            return "Use the username and password from a GeoPulse OwnTracks location source."
        case .ownTracksRecorder:
            return "The tracking username and device select the OwnTracks topic. Basic authentication is optional and is commonly provided by a reverse proxy."
        case .traccar:
            return "Enter the full Traccar OwnTracks protocol URL (normally port 5144) and the device's unique identifier."
        }
    }

    var uploadNote: String {
        switch self {
        case .dawarich:
            return "Moves sends the route shown on its map for completed moves, plus raw points that are not part of a move. Dawarich deduplicates matching points."
        case .reitti, .geoPulse:
            return "Moves sends mapped routes and unattached raw points through this server's OwnTracks-compatible endpoint."
        case .ownTracksRecorder, .traccar:
            return "Moves sends mapped routes and unattached raw points through the OwnTracks protocol. Repeating a full-history upload may create duplicates, depending on the server."
        }
    }
}

enum DawarichServerKind: String, CaseIterable, Identifiable, Codable {
    case cloud
    case selfHosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: return "Dawarich Cloud"
        case .selfHosted: return "Self-hosted"
        }
    }
}

struct LocationServiceConfiguration: Equatable {
    static let dawarichCloudURL = URL(string: "https://my.dawarich.app")!

    let service: LocationService
    let baseURL: URL

    static func make(
        service: LocationService,
        dawarichServerKind: DawarichServerKind = .selfHosted,
        customURL: String
    ) throws -> Self {
        if service == .dawarich, dawarichServerKind == .cloud {
            return Self(service: service, baseURL: dawarichCloudURL)
        }

        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty else {
            throw LocationServiceError.invalidServerURL(service)
        }

        if scheme == "http", !isLocalHost(host) {
            throw LocationServiceError.insecureRemoteServer(service)
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        guard let url = components.url else {
            throw LocationServiceError.invalidServerURL(service)
        }
        return Self(service: service, baseURL: url)
    }

    func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        if lowercased == "localhost" || lowercased.hasSuffix(".local") || !lowercased.contains(".") {
            return true
        }
        if lowercased == "::1" || lowercased.hasPrefix("fc") || lowercased.hasPrefix("fd") || lowercased.hasPrefix("fe80:") {
            return true
        }

        let octets = lowercased.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

enum LocationServiceError: LocalizedError {
    case invalidServerURL(LocationService)
    case insecureRemoteServer(LocationService)
    case missingCredential(LocationService, String)
    case notConfigured(LocationService)
    case keychain(OSStatus)
    case invalidResponse(LocationService)
    case server(LocationService, statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL(let service):
            return "Enter a complete \(service.title) server URL, including https://."
        case .insecureRemoteServer(let service):
            return "Remote \(service.title) servers must use HTTPS. HTTP is only allowed for local-network hosts."
        case .missingCredential(let service, let field):
            return "Enter the \(field) for \(service.title)."
        case .notConfigured(let service):
            return "Connect to \(service.title) first."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not access the saved credentials (\(detail))."
        case .invalidResponse(let service):
            return "The server returned an invalid response. Check that this is a \(service.title) endpoint."
        case .server(let service, let statusCode, let message):
            if statusCode == 401 || statusCode == 403 {
                return "\(service.title) rejected the saved credentials."
            }
            if let message, !message.isEmpty {
                return "\(service.title) returned HTTP \(statusCode): \(message)"
            }
            return "\(service.title) returned HTTP \(statusCode)."
        }
    }
}

struct LocationServiceCredentials: Codable, Equatable {
    var token = ""
    var username = ""
    var password = ""
}

struct LocationServiceConnectionInput: Equatable {
    var dawarichServerKind: DawarichServerKind = .selfHosted
    var serverURL = ""
    var token = ""
    var username = ""
    var password = ""
    var trackingUsername = ""
    var deviceID = ""
}

private enum LocationServiceKeychain {
    static let serviceName = "de.holgerkrupp.Moves.location-services"
    static let legacyDawarichServiceName = "de.holgerkrupp.Moves.dawarich"

    static func load(for service: LocationService) throws -> LocationServiceCredentials? {
        if let data = try loadData(serviceName: serviceName, account: service.rawValue) {
            return try? JSONDecoder().decode(LocationServiceCredentials.self, from: data)
        }

        if service == .dawarich,
           let legacyData = try loadData(serviceName: legacyDawarichServiceName, account: "api-key"),
           let token = String(data: legacyData, encoding: .utf8) {
            return LocationServiceCredentials(token: token)
        }
        return nil
    }

    static func save(_ credentials: LocationServiceCredentials, for service: LocationService) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: service.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw LocationServiceError.keychain(updateStatus) }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw LocationServiceError.keychain(addStatus) }
    }

    static func remove(for service: LocationService) throws {
        let queries: [[String: Any]] = [
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: service.rawValue,
            ],
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyDawarichServiceName,
                kSecAttrAccount as String: "api-key",
            ],
        ]
        for query in service == .dawarich ? queries : [queries[0]] {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LocationServiceError.keychain(status)
            }
        }
    }

    private static func loadData(serviceName: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LocationServiceError.keychain(status) }
        return result as? Data
    }
}

struct LocationExportSample {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
    let speedMetersPerSecond: Double?
    let timestamp: Date

    init(_ sample: LocationSample) {
        latitude = sample.latitude
        longitude = sample.longitude
        altitude = sample.altitude.isFinite ? sample.altitude : nil
        horizontalAccuracy = sample.horizontalAccuracy >= 0 ? sample.horizontalAccuracy : nil
        speedMetersPerSecond = sample.speed >= 0 ? sample.speed : nil
        timestamp = sample.timestamp
    }

    init(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speedMetersPerSecond = speedMetersPerSecond
        self.timestamp = timestamp
    }
}

enum MappedRouteExport {
    /// Converts the route drawn by Moves into timestamped points understood by
    /// location-history services. MapKit geometry has no timestamps, so time is
    /// distributed by distance along the route between the move's endpoints.
    static func samples(
        coordinates: [CLLocationCoordinate2D],
        startDate: Date,
        endDate: Date
    ) -> [LocationExportSample] {
        let validCoordinates = RouteCoordinateOps.dedupeSequentialCoordinates(
            coordinates.filter { coordinate in
                CLLocationCoordinate2DIsValid(coordinate)
                    && coordinate.latitude.isFinite
                    && coordinate.longitude.isFinite
            },
            minimumDistanceMeters: 0.5
        )
        guard validCoordinates.count > 1, endDate > startDate else { return [] }

        var cumulativeDistances: [CLLocationDistance] = [0]
        cumulativeDistances.reserveCapacity(validCoordinates.count)
        for pair in zip(validCoordinates, validCoordinates.dropFirst()) {
            cumulativeDistances.append(
                cumulativeDistances[cumulativeDistances.count - 1]
                    + RouteCoordinateOps.distanceMeters(from: pair.0, to: pair.1)
            )
        }

        let totalDistance = cumulativeDistances.last ?? 0
        let duration = endDate.timeIntervalSince(startDate)
        let averageSpeed = totalDistance > 0 ? totalDistance / duration : nil

        return zip(validCoordinates, cumulativeDistances).enumerated().map { index, element in
            let (coordinate, distance) = element
            let fraction = totalDistance > 0
                ? distance / totalDistance
                : Double(index) / Double(validCoordinates.count - 1)
            return LocationExportSample(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                speedMetersPerSecond: averageSpeed,
                timestamp: startDate.addingTimeInterval(duration * fraction)
            )
        }
    }
}

struct DawarichLocationFeature: Encodable {
    struct Geometry: Encodable {
        let type = "Point"
        let coordinates: [Double]
    }

    struct Properties: Encodable {
        let timestamp: String
        let altitude: Double?
        let horizontalAccuracy: Double?
        let speed: Double?
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case timestamp
            case altitude
            case horizontalAccuracy = "horizontal_accuracy"
            case speed
            case deviceID = "device_id"
        }
    }

    let type = "Feature"
    let geometry: Geometry
    let properties: Properties

    fileprivate init(sample: LocationExportSample, deviceID: String) {
        geometry = Geometry(coordinates: [sample.longitude, sample.latitude])
        properties = Properties(
            timestamp: LocationServiceAPIClient.iso8601String(from: sample.timestamp),
            altitude: sample.altitude,
            horizontalAccuracy: sample.horizontalAccuracy,
            speed: sample.speedMetersPerSecond,
            deviceID: deviceID
        )
    }

    init(sample: LocationSample, deviceID: String) {
        self.init(sample: LocationExportSample(sample), deviceID: deviceID)
    }
}

struct DawarichUploadPayload: Encodable {
    let locations: [DawarichLocationFeature]
}

struct OwnTracksLocationPayload: Encodable {
    let type = "location"
    let latitude: Double
    let longitude: Double
    let timestamp: Int64
    let altitude: Double?
    let accuracy: Double?
    let velocity: Double?
    let deviceID: String?
    let topic: String?

    enum CodingKeys: String, CodingKey {
        case type = "_type"
        case latitude = "lat"
        case longitude = "lon"
        case timestamp = "tst"
        case altitude = "alt"
        case accuracy = "acc"
        case velocity = "vel"
        case deviceID = "tid"
        case topic
    }

    fileprivate init(sample: LocationExportSample, deviceID: String?, topic: String? = nil) {
        latitude = sample.latitude
        longitude = sample.longitude
        timestamp = Int64(sample.timestamp.timeIntervalSince1970)
        altitude = sample.altitude
        accuracy = sample.horizontalAccuracy
        velocity = sample.speedMetersPerSecond.map { $0 * 3.6 }
        self.deviceID = deviceID
        self.topic = topic
    }

    init(sample: LocationSample, deviceID: String?, topic: String? = nil) {
        self.init(sample: LocationExportSample(sample), deviceID: deviceID, topic: topic)
    }
}

struct LocationServiceAPIClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testConnection(
        configuration: LocationServiceConfiguration,
        credentials: LocationServiceCredentials,
        trackingUsername: String,
        deviceID: String
    ) async throws -> String? {
        switch configuration.service {
        case .dawarich:
            var components = URLComponents(url: configuration.endpoint("api/v1/points"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "per_page", value: "1"),
                URLQueryItem(name: "slim", value: "true"),
            ]
            guard let url = components?.url else { throw LocationServiceError.invalidServerURL(.dawarich) }
            var request = request(url: url, bearerToken: credentials.token)
            request.httpMethod = "GET"
            let (_, response) = try await session.data(for: request)
            let http = try validate(response: response, data: nil, service: .dawarich)
            return http.value(forHTTPHeaderField: "X-Dawarich-Version")

        case .reitti:
            var request = request(url: configuration.endpoint("api/v1/ingest/owntracks"), bearerToken: credentials.token)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"_type":"cmd"}"#.utf8)
            let (data, response) = try await session.data(for: request)
            _ = try validate(response: response, data: data, service: .reitti)
            return nil

        case .geoPulse:
            // GeoPulse deliberately skips authentication for non-location OwnTracks
            // messages, so its read-only health endpoint verifies the server here.
            var request = request(url: configuration.endpoint("api/health"))
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)
            _ = try validate(response: response, data: data, service: .geoPulse)
            return nil

        case .ownTracksRecorder:
            var request = request(url: configuration.endpoint("api/0/version"), basic: credentials)
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)
            _ = try validate(response: response, data: data, service: .ownTracksRecorder)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object["version"] as? String
            }
            return nil

        case .traccar:
            // A non-location OwnTracks message reaches the protocol decoder but
            // is not persisted, making this a side-effect-free reachability test.
            var request = request(url: configuration.baseURL)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"_type":"cmd"}"#.utf8)
            let (data, response) = try await session.data(for: request)
            _ = try validate(response: response, data: data, service: .traccar)
            return nil
        }
    }

    fileprivate func upload(
        _ samples: [LocationExportSample],
        configuration: LocationServiceConfiguration,
        credentials: LocationServiceCredentials,
        trackingUsername: String,
        deviceID: String
    ) async throws {
        switch configuration.service {
        case .dawarich:
            let payload = DawarichUploadPayload(
                locations: samples.map { DawarichLocationFeature(sample: $0, deviceID: deviceID) }
            )
            var request = request(url: configuration.endpoint("api/v1/points"), bearerToken: credentials.token)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await session.data(for: request)
            _ = try validate(response: response, data: data, service: .dawarich)

        case .reitti:
            for sample in samples {
                let payload = OwnTracksLocationPayload(sample: sample, deviceID: nil)
                var request = request(url: configuration.endpoint("api/v1/ingest/owntracks"), bearerToken: credentials.token)
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder().encode(payload)
                let (data, response) = try await session.data(for: request)
                _ = try validate(response: response, data: data, service: .reitti)
            }

        case .geoPulse:
            for sample in samples {
                let payload = OwnTracksLocationPayload(sample: sample, deviceID: nil)
                var request = request(url: configuration.endpoint("api/owntracks"), basic: credentials)
                request.setValue(deviceID, forHTTPHeaderField: "X-Limit-D")
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder().encode(payload)
                let (data, response) = try await session.data(for: request)
                _ = try validate(response: response, data: data, service: .geoPulse)
            }

        case .ownTracksRecorder:
            for sample in samples {
                let topic = "owntracks/\(trackingUsername)/\(deviceID)"
                let payload = OwnTracksLocationPayload(sample: sample, deviceID: nil, topic: topic)
                var request = request(url: configuration.endpoint("pub"), basic: credentials)
                request.setValue(trackingUsername, forHTTPHeaderField: "X-Limit-U")
                request.setValue(deviceID, forHTTPHeaderField: "X-Limit-D")
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder().encode(payload)
                let (data, response) = try await session.data(for: request)
                _ = try validate(response: response, data: data, service: .ownTracksRecorder)
            }

        case .traccar:
            for sample in samples {
                let payload = OwnTracksLocationPayload(sample: sample, deviceID: deviceID)
                var request = request(url: configuration.baseURL)
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder().encode(payload)
                let (data, response) = try await session.data(for: request)
                _ = try validate(response: response, data: data, service: .traccar)
            }
        }
    }

    private func request(
        url: URL,
        bearerToken: String? = nil,
        basic credentials: LocationServiceCredentials? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        } else if let credentials, !credentials.username.isEmpty {
            let value = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(response: URLResponse, data: Data?, service: LocationService) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw LocationServiceError.invalidResponse(service)
        }
        guard (200...299).contains(response.statusCode) else {
            var message: String?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = object["message"] as? String ?? object["error"] as? String
            }
            throw LocationServiceError.server(service, statusCode: response.statusCode, message: message)
        }
        return response
    }

    static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct LocationServiceRuntimeState: Equatable {
    var isSyncing = false
    var isTestingConnection = false
    var isConfigured = false
    var automaticSyncEnabled = false
    var lastSuccessfulSyncAt: Date?
    var lastMessage = ""
    var lastOperationFailed = false
}

@MainActor
final class LocationServiceSyncManager: ObservableObject {
    @Published private(set) var states: [LocationService: LocationServiceRuntimeState] = [:]

    private let modelContainer: ModelContainer
    private let defaults: UserDefaults
    private let client: LocationServiceAPIClient
    private var notificationObserver: NSObjectProtocol?
    private var resyncRequested: Set<LocationService> = []
    private static let batchSize = 100
    private static let moveFetchBatchSize = 100

    init(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard,
        client: LocationServiceAPIClient = LocationServiceAPIClient()
    ) {
        self.modelContainer = modelContainer
        self.defaults = defaults
        self.client = client
        migrateLegacyDawarichDefaultsIfNeeded()
        reloadSettings()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .movesLocationSamplesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncNewSamplesIfEnabled()
            }
        }
    }

    func state(for service: LocationService) -> LocationServiceRuntimeState {
        states[service] ?? LocationServiceRuntimeState()
    }

    func connectionInput(for service: LocationService) -> LocationServiceConnectionInput {
        let credentials = (try? LocationServiceKeychain.load(for: service)) ?? nil
        return LocationServiceConnectionInput(
            dawarichServerKind: DawarichServerKind(
                rawValue: defaults.string(forKey: key(service, "serverKind")) ?? ""
            ) ?? (service == .dawarich ? .cloud : .selfHosted),
            serverURL: defaults.string(forKey: key(service, "serverURL")) ?? "",
            token: "",
            username: credentials?.username ?? "",
            password: "",
            trackingUsername: defaults.string(forKey: key(service, "trackingUsername")) ?? "moves",
            deviceID: defaults.string(forKey: key(service, "deviceID")) ?? defaultDeviceID(for: service)
        )
    }

    func connectionSummary(for service: LocationService) -> String {
        guard state(for: service).isConfigured else { return "Not connected" }
        if service == .dawarich,
           connectionInput(for: service).dawarichServerKind == .cloud {
            return "Dawarich Cloud"
        }
        return currentConfiguration(for: service)?.baseURL.host ?? "Connected"
    }

    func hasStoredSecret(for service: LocationService) -> Bool {
        guard let credentials = (try? LocationServiceKeychain.load(for: service)) ?? nil else { return false }
        switch service {
        case .dawarich, .reitti: return !credentials.token.isEmpty
        case .geoPulse: return !credentials.password.isEmpty
        case .ownTracksRecorder: return !credentials.password.isEmpty
        case .traccar: return false
        }
    }

    func reloadSettings() {
        var newStates = states
        for service in LocationService.allCases {
            var state = newStates[service] ?? LocationServiceRuntimeState()
            state.isConfigured = isConfigurationComplete(for: service)
            state.automaticSyncEnabled = defaults.bool(forKey: key(service, "automaticSync"))
            state.lastSuccessfulSyncAt = defaults.object(forKey: key(service, "lastSuccess")) as? Date
            newStates[service] = state
        }
        states = newStates
    }

    func connect(service: LocationService, input: LocationServiceConnectionInput) async throws -> String? {
        let configuration = try LocationServiceConfiguration.make(
            service: service,
            dawarichServerKind: input.dawarichServerKind,
            customURL: input.serverURL
        )
        let credentials = try resolvedCredentials(service: service, input: input)
        let trackingUsername = try required(input.trackingUsername, named: "tracking username", for: service, when: service == .ownTracksRecorder)
        let deviceID = try required(input.deviceID, named: "device identifier", for: service, when: [.geoPulse, .ownTracksRecorder, .traccar].contains(service))

        updateState(for: service) { $0.isTestingConnection = true }
        defer { updateState(for: service) { $0.isTestingConnection = false } }
        let version = try await client.testConnection(
            configuration: configuration,
            credentials: credentials,
            trackingUsername: trackingUsername,
            deviceID: deviceID
        )

        let previousURL = currentConfiguration(for: service)?.baseURL
        try LocationServiceKeychain.save(credentials, for: service)
        defaults.set(input.dawarichServerKind.rawValue, forKey: key(service, "serverKind"))
        defaults.set(input.serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key(service, "serverURL"))
        defaults.set(trackingUsername, forKey: key(service, "trackingUsername"))
        defaults.set(deviceID, forKey: key(service, "deviceID"))
        if previousURL != configuration.baseURL {
            defaults.set(Date.now, forKey: key(service, "uploadCursor"))
        }
        reloadSettings()
        updateState(for: service) {
            $0.lastOperationFailed = false
            if service == .geoPulse {
                $0.lastMessage = "Connected to GeoPulse. Credentials will be verified with the first upload."
            } else {
                $0.lastMessage = version.map { "Connected to \(service.title) \($0)." } ?? "Connected to \(service.title)."
            }
        }
        return version
    }

    func disconnect(_ service: LocationService) throws {
        try LocationServiceKeychain.remove(for: service)
        for suffix in ["serverKind", "serverURL", "trackingUsername", "deviceID", "automaticSync", "uploadCursor", "lastSuccess"] {
            defaults.removeObject(forKey: key(service, suffix))
        }
        reloadSettings()
        updateState(for: service) {
            $0.lastOperationFailed = false
            $0.lastMessage = "Disconnected from \(service.title)."
        }
    }

    func setAutomaticSyncEnabled(_ enabled: Bool, for service: LocationService) {
        if enabled, defaults.object(forKey: key(service, "uploadCursor")) == nil {
            defaults.set(Date.now, forKey: key(service, "uploadCursor"))
        }
        defaults.set(enabled, forKey: key(service, "automaticSync"))
        reloadSettings()
        if enabled {
            Task { await syncNewSamplesIfEnabled(service) }
        }
    }

    func syncNewSamplesIfEnabled(_ requestedService: LocationService? = nil) async {
        let services = requestedService.map { [$0] } ?? LocationService.allCases
        reloadSettings()
        for service in services where state(for: service).automaticSyncEnabled && state(for: service).isConfigured {
            await performSync(service: service, allHistory: false)
        }
    }

    func syncNewSamplesNow(_ service: LocationService) async {
        guard state(for: service).isConfigured else {
            record(error: LocationServiceError.notConfigured(service), for: service)
            return
        }
        await performSync(service: service, allHistory: false)
    }

    func syncAllHistory(_ service: LocationService) async {
        guard state(for: service).isConfigured else {
            record(error: LocationServiceError.notConfigured(service), for: service)
            return
        }
        await performSync(service: service, allHistory: true)
    }

    private func performSync(service: LocationService, allHistory: Bool) async {
        guard !state(for: service).isSyncing else {
            resyncRequested.insert(service)
            return
        }

        updateState(for: service) { $0.isSyncing = true }
        resyncRequested.remove(service)
        defer {
            updateState(for: service) { $0.isSyncing = false }
            if resyncRequested.remove(service) != nil, state(for: service).automaticSyncEnabled {
                Task { await syncNewSamplesIfEnabled(service) }
            }
        }

        do {
            guard let configuration = currentConfiguration(for: service) else {
                throw LocationServiceError.notConfigured(service)
            }
            let credentials = try LocationServiceKeychain.load(for: service) ?? LocationServiceCredentials()
            let input = connectionInput(for: service)
            let originalCursor = defaults.object(forKey: key(service, "uploadCursor")) as? Date
            let cursor = allHistory ? Date.distantPast : (originalCursor ?? Date.now)
            let upperBound = Date.now
            var uploadedCount = 0

            uploadedCount += try await uploadMappedRoutes(
                createdAfter: cursor,
                createdThrough: upperBound,
                configuration: configuration,
                credentials: credentials,
                input: input
            )
            uploadedCount += try await uploadUnattachedSamples(
                createdAfter: cursor,
                createdThrough: upperBound,
                configuration: configuration,
                credentials: credentials,
                input: input
            )

            defaults.set(max(originalCursor ?? Date.distantPast, upperBound), forKey: key(service, "uploadCursor"))
            let completedAt = Date.now
            defaults.set(completedAt, forKey: key(service, "lastSuccess"))
            updateState(for: service) {
                $0.lastSuccessfulSyncAt = completedAt
                $0.lastOperationFailed = false
                $0.lastMessage = uploadedCount == 0
                    ? "\(service.title) is up to date."
                    : "Uploaded \(uploadedCount) route/location point\(uploadedCount == 1 ? "" : "s") to \(service.title)."
            }
        } catch {
            record(error: error, for: service)
        }
    }

    private func uploadMappedRoutes(
        createdAfter cursor: Date,
        createdThrough upperBound: Date,
        configuration: LocationServiceConfiguration,
        credentials: LocationServiceCredentials,
        input: LocationServiceConnectionInput
    ) async throws -> Int {
        var candidateMoveIDs: Set<UUID> = []
        var fetchOffset = 0

        while true {
            let modelContext = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<MoveSegment>(
                predicate: #Predicate { move in
                    move.createdAt > cursor && move.createdAt <= upperBound
                },
                sortBy: [SortDescriptor(\MoveSegment.createdAt, order: .forward)]
            )
            descriptor.fetchLimit = Self.moveFetchBatchSize
            descriptor.fetchOffset = fetchOffset
            let moves = try modelContext.fetch(descriptor)
            guard !moves.isEmpty else { break }
            candidateMoveIDs.formUnion(moves.map(\.id))
            fetchOffset += moves.count
            if moves.count < Self.moveFetchBatchSize { break }
        }

        // A detailed import can attach new samples to a move that already existed.
        // Include those moves even though their original creation date is older
        // than the upload cursor.
        if cursor != Date.distantPast {
            fetchOffset = 0
            while true {
                let modelContext = ModelContext(modelContainer)
                var descriptor = FetchDescriptor<LocationSample>(
                    predicate: #Predicate { sample in
                        sample.createdAt > cursor
                            && sample.createdAt <= upperBound
                            && sample.moveSegment != nil
                    },
                    sortBy: [SortDescriptor(\LocationSample.createdAt, order: .forward)]
                )
                descriptor.fetchLimit = Self.batchSize
                descriptor.fetchOffset = fetchOffset
                let samples = try modelContext.fetch(descriptor)
                guard !samples.isEmpty else { break }
                candidateMoveIDs.formUnion(samples.compactMap { $0.moveSegment?.id })
                fetchOffset += samples.count
                if samples.count < Self.batchSize { break }
            }
        }

        guard !candidateMoveIDs.isEmpty else { return 0 }

        let modelContext = ModelContext(modelContainer)
        let moves = try modelContext.fetch(FetchDescriptor<MoveSegment>())
            .filter { candidateMoveIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.timelineStartDate != rhs.timelineStartDate {
                    return lhs.timelineStartDate < rhs.timelineStartDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var uploadedCount = 0

        for move in moves {
            let coordinates = await RoadRouteMatcher.matchedCoordinates(for: move)
            let routeSamples = MappedRouteExport.samples(
                coordinates: coordinates,
                startDate: move.timelineStartDate,
                endDate: move.endDate
            )
            if routeSamples.isEmpty {
                uploadedCount += try await uploadInBatches(
                    move.samples
                        .sorted(by: { $0.timestamp < $1.timestamp })
                        .map(LocationExportSample.init),
                    configuration: configuration,
                    credentials: credentials,
                    input: input
                )
            } else {
                uploadedCount += try await uploadInBatches(
                    routeSamples,
                    configuration: configuration,
                    credentials: credentials,
                    input: input
                )
            }
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }

        return uploadedCount
    }

    private func uploadUnattachedSamples(
        createdAfter cursor: Date,
        createdThrough upperBound: Date,
        configuration: LocationServiceConfiguration,
        credentials: LocationServiceCredentials,
        input: LocationServiceConnectionInput
    ) async throws -> Int {
        var fetchOffset = 0
        var uploadedCount = 0

        while true {
            let modelContext = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<LocationSample>(
                predicate: #Predicate { sample in
                    sample.createdAt > cursor
                        && sample.createdAt <= upperBound
                        && sample.moveSegment == nil
                },
                sortBy: [SortDescriptor(\LocationSample.createdAt, order: .forward)]
            )
            descriptor.fetchLimit = Self.batchSize
            descriptor.fetchOffset = fetchOffset
            let samples = try modelContext.fetch(descriptor)
            guard !samples.isEmpty else { break }

            uploadedCount += try await uploadInBatches(
                samples.map(LocationExportSample.init),
                configuration: configuration,
                credentials: credentials,
                input: input
            )
            fetchOffset += samples.count
            if samples.count < Self.batchSize { break }
        }

        return uploadedCount
    }

    private func uploadInBatches(
        _ samples: [LocationExportSample],
        configuration: LocationServiceConfiguration,
        credentials: LocationServiceCredentials,
        input: LocationServiceConnectionInput
    ) async throws -> Int {
        for startIndex in stride(from: 0, to: samples.count, by: Self.batchSize) {
            let endIndex = min(startIndex + Self.batchSize, samples.count)
            try await client.upload(
                Array(samples[startIndex..<endIndex]),
                configuration: configuration,
                credentials: credentials,
                trackingUsername: input.trackingUsername,
                deviceID: input.deviceID
            )
        }
        return samples.count
    }

    private func currentConfiguration(for service: LocationService) -> LocationServiceConfiguration? {
        let input = connectionInput(for: service)
        return try? LocationServiceConfiguration.make(
            service: service,
            dawarichServerKind: input.dawarichServerKind,
            customURL: input.serverURL
        )
    }

    private func isConfigurationComplete(for service: LocationService) -> Bool {
        guard currentConfiguration(for: service) != nil else { return false }
        let credentials = (try? LocationServiceKeychain.load(for: service)) ?? nil
        let input = connectionInput(for: service)
        switch service {
        case .dawarich, .reitti:
            return credentials.map { !$0.token.isEmpty } ?? false
        case .geoPulse:
            return credentials.map { !$0.username.isEmpty && !$0.password.isEmpty } ?? false
                && !input.deviceID.isEmpty
        case .ownTracksRecorder:
            return !input.trackingUsername.isEmpty && !input.deviceID.isEmpty
        case .traccar:
            return !input.deviceID.isEmpty
        }
    }

    private func resolvedCredentials(
        service: LocationService,
        input: LocationServiceConnectionInput
    ) throws -> LocationServiceCredentials {
        let saved = try LocationServiceKeychain.load(for: service) ?? LocationServiceCredentials()
        switch service {
        case .dawarich, .reitti:
            let token = input.token.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = token.isEmpty ? saved.token : token
            return LocationServiceCredentials(
                token: try required(resolved, named: service == .dawarich ? "API key" : "API token", for: service),
                username: "",
                password: ""
            )
        case .geoPulse:
            let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = input.password.isEmpty ? saved.password : input.password
            return LocationServiceCredentials(
                token: "",
                username: try required(username, named: "OwnTracks username", for: service),
                password: try required(password, named: "OwnTracks password", for: service)
            )
        case .ownTracksRecorder:
            let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = input.password.isEmpty ? saved.password : input.password
            return LocationServiceCredentials(token: "", username: username, password: password)
        case .traccar:
            return LocationServiceCredentials()
        }
    }

    private func required(
        _ value: String,
        named field: String,
        for service: LocationService,
        when condition: Bool = true
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if condition, trimmed.isEmpty {
            throw LocationServiceError.missingCredential(service, field)
        }
        return trimmed
    }

    private func defaultDeviceID(for service: LocationService) -> String {
        guard [.dawarich, .geoPulse, .ownTracksRecorder].contains(service) else { return "" }
        let sharedKey = "Moves.locationServices.generatedDeviceID"
        if let existing = defaults.string(forKey: sharedKey), !existing.isEmpty { return existing }
        let value = "Moves-iOS-\(UUID().uuidString)"
        defaults.set(value, forKey: sharedKey)
        return value
    }

    private func key(_ service: LocationService, _ suffix: String) -> String {
        "Moves.locationServices.\(service.rawValue).\(suffix)"
    }

    private func updateState(for service: LocationService, _ update: (inout LocationServiceRuntimeState) -> Void) {
        var value = state(for: service)
        update(&value)
        states[service] = value
    }

    private func record(error: Error, for service: LocationService) {
        updateState(for: service) {
            $0.lastOperationFailed = true
            $0.lastMessage = error.localizedDescription
        }
    }

    private func migrateLegacyDawarichDefaultsIfNeeded() {
        let mappings = [
            ("Moves.dawarich.serverKind", key(.dawarich, "serverKind")),
            ("Moves.dawarich.customServerURL", key(.dawarich, "serverURL")),
            ("Moves.dawarich.automaticSync", key(.dawarich, "automaticSync")),
            ("Moves.dawarich.uploadCursor", key(.dawarich, "uploadCursor")),
            ("Moves.dawarich.lastSuccess", key(.dawarich, "lastSuccess")),
            ("Moves.dawarich.deviceID", key(.dawarich, "deviceID")),
        ]
        for (oldKey, newKey) in mappings where defaults.object(forKey: newKey) == nil {
            if let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
        }
    }
}

struct LocationServiceSettingsView: View {
    @EnvironmentObject private var syncManager: LocationServiceSyncManager
    let service: LocationService

    @State private var input = LocationServiceConnectionInput()
    @State private var isShowingHistoryConfirmation = false
    @State private var isShowingDisconnectConfirmation = false
    @State private var alertMessage = ""
    @State private var isShowingAlert = false

    private var state: LocationServiceRuntimeState { syncManager.state(for: service) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                SettingsCard(title: "Server") {
                    serverFields
                    credentialFields

                    Button { connect() } label: {
                        Label(
                            state.isTestingConnection ? "Testing…" : "Test and Save Connection",
                            systemImage: state.isConfigured ? "checkmark.icloud" : "link"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(state.isTestingConnection || state.isSyncing)

                    Link("Open \(service.title) setup documentation", destination: service.documentationURL)
                        .font(.system(size: 12, weight: .medium, design: .rounded))

                    Text(service.setupHelp)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text("URLs may include a port or path. HTTPS is required outside your local network; local HTTP hosts are supported.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "Uploads") {
                    Toggle(
                        "Automatically upload new points",
                        isOn: Binding(
                            get: { state.automaticSyncEnabled },
                            set: { syncManager.setAutomaticSyncEnabled($0, for: service) }
                        )
                    )
                    .disabled(!state.isConfigured)

                    Button { Task { await syncManager.syncNewSamplesNow(service) } } label: {
                        Label("Upload New Points Now", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.isConfigured || state.isSyncing)
                    .padding(.vertical, 5)

                    Button { isShowingHistoryConfirmation = true } label: {
                        Label("Upload All Local History", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.isConfigured || state.isSyncing)
                    .padding(.vertical, 5)

                    if state.isSyncing {
                        ProgressView("Uploading routes and location points…")
                    }

                    if !state.lastMessage.isEmpty {
                        Text(state.lastMessage)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(state.lastOperationFailed ? Color.red : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let lastSync = state.lastSuccessfulSyncAt {
                        Text("Last successful upload \(lastSync.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Text(service.uploadNote)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if state.isConfigured {
                    SettingsCard(title: "Connection") {
                        Button(role: .destructive) { isShowingDisconnectConfirmation = true } label: {
                            Label("Disconnect \(service.title)", systemImage: "link.badge.minus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isSyncing || state.isTestingConnection)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background {
            LinearGradient(
                colors: [MovesPalette.backgroundTop, MovesPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(service.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            syncManager.reloadSettings()
            input = syncManager.connectionInput(for: service)
        }
        .confirmationDialog(
            "Upload All Location History?",
            isPresented: $isShowingHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Upload All History") { Task { await syncManager.syncAllHistory(service) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every mapped route and location point stored in Moves will be sent to \(service.title). Repeating this action may create duplicate points if the server does not deduplicate them.")
        }
        .confirmationDialog(
            "Disconnect \(service.title)?",
            isPresented: $isShowingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved server and credentials will be removed. Data already uploaded to \(service.title) is not deleted.")
        }
        .alert(service.title, isPresented: $isShowingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private var serverFields: some View {
        if service == .dawarich {
            Picker("Server", selection: $input.dawarichServerKind) {
                ForEach(DawarichServerKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if input.dawarichServerKind == .cloud {
                LabeledContent("Server", value: LocationServiceConfiguration.dawarichCloudURL.absoluteString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            } else {
                serverURLField
            }
        } else {
            serverURLField
        }
    }

    @ViewBuilder
    private var serverURLField: some View {
        #if os(iOS)
        TextField(service.serverPlaceholder, text: $input.serverURL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        #else
        TextField(service.serverPlaceholder, text: $input.serverURL)
            .autocorrectionDisabled()
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        #endif
    }

    @ViewBuilder
    private var credentialFields: some View {
        switch service {
        case .dawarich, .reitti:
            secretField(
                syncManager.hasStoredSecret(for: service)
                    ? "Leave blank to keep saved \(service == .dawarich ? "API key" : "API token")"
                    : (service == .dawarich ? "API key" : "API token"),
                text: $input.token
            )

        case .geoPulse:
            standardField("OwnTracks username", text: $input.username, isUsername: true)
            secretField(
                syncManager.hasStoredSecret(for: service) ? "Leave blank to keep saved password" : "OwnTracks password",
                text: $input.password
            )
            standardField("Device identifier", text: $input.deviceID)

        case .ownTracksRecorder:
            standardField("Tracking username", text: $input.trackingUsername, isUsername: true)
            standardField("Device identifier", text: $input.deviceID)
            standardField("Basic auth username (optional)", text: $input.username, isUsername: true)
            secretField(
                syncManager.hasStoredSecret(for: service) ? "Leave blank to keep saved Basic auth password" : "Basic auth password (optional)",
                text: $input.password
            )

        case .traccar:
            standardField("Traccar device unique identifier", text: $input.deviceID)
        }
    }

    @ViewBuilder
    private func standardField(
        _ placeholder: String,
        text: Binding<String>,
        isUsername: Bool = false
    ) -> some View {
        #if os(iOS)
        if isUsername {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        } else {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        #else
        TextField(placeholder, text: text)
            .autocorrectionDisabled()
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        #endif
    }

    @ViewBuilder
    private func secretField(_ placeholder: String, text: Binding<String>) -> some View {
        #if os(iOS)
        SecureField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        #else
        SecureField(placeholder, text: text)
            .autocorrectionDisabled()
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        #endif
    }

    private func connect() {
        Task {
            do {
                _ = try await syncManager.connect(service: service, input: input)
                input.token = ""
                input.password = ""
            } catch {
                alertMessage = error.localizedDescription
                isShowingAlert = true
            }
        }
    }

    private func disconnect() {
        do {
            try syncManager.disconnect(service)
            input = syncManager.connectionInput(for: service)
        } catch {
            alertMessage = error.localizedDescription
            isShowingAlert = true
        }
    }
}
