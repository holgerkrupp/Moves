import CoreLocation
import XCTest
@testable import Moves

final class LocationServiceSyncTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testAllRequestedServicesAreAvailable() {
        XCTAssertEqual(
            Set(LocationService.allCases),
            Set([.dawarich, .reitti, .geoPulse, .ownTracksRecorder, .traccar])
        )
    }

    func testCloudUsesHostedDawarichURL() throws {
        let configuration = try LocationServiceConfiguration.make(
            service: .dawarich,
            dawarichServerKind: .cloud,
            customURL: ""
        )

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://my.dawarich.app")
        XCTAssertEqual(
            configuration.endpoint("api/v1/points").absoluteString,
            "https://my.dawarich.app/api/v1/points"
        )
    }

    func testSelfHostedURLKeepsPortAndPath() throws {
        let configuration = try LocationServiceConfiguration.make(
            service: .reitti,
            customURL: "https://example.com:8443/reitti/"
        )

        XCTAssertEqual(
            configuration.endpoint("api/v1/ingest/owntracks").absoluteString,
            "https://example.com:8443/reitti/api/v1/ingest/owntracks"
        )
    }

    func testLocalHTTPIsAllowed() throws {
        let configuration = try LocationServiceConfiguration.make(
            service: .geoPulse,
            customURL: "http://192.168.1.20:3000"
        )
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://192.168.1.20:3000")
    }

    func testRemoteHTTPIsRejected() {
        XCTAssertThrowsError(
            try LocationServiceConfiguration.make(
                service: .traccar,
                customURL: "http://example.com:5144"
            )
        ) { error in
            guard case LocationServiceError.insecureRemoteServer(.traccar) = error else {
                return XCTFail("Expected insecureRemoteServer, got \(error)")
            }
        }
    }

    func testLocationSampleEncodesAsDawarichGeoJSON() throws {
        let payload = DawarichUploadPayload(
            locations: [DawarichLocationFeature(sample: makeSample(), deviceID: "Moves-test")]
        )

        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let locations = try XCTUnwrap(object["locations"] as? [[String: Any]])
        let feature = try XCTUnwrap(locations.first)
        let geometry = try XCTUnwrap(feature["geometry"] as? [String: Any])
        let coordinates = try XCTUnwrap(geometry["coordinates"] as? [Double])
        let properties = try XCTUnwrap(feature["properties"] as? [String: Any])

        XCTAssertEqual(feature["type"] as? String, "Feature")
        XCTAssertEqual(geometry["type"] as? String, "Point")
        XCTAssertEqual(coordinates, [13.405, 52.52])
        XCTAssertEqual(properties["horizontal_accuracy"] as? Double, 7)
        XCTAssertEqual(properties["device_id"] as? String, "Moves-test")
        XCTAssertEqual(properties["speed"] as? Double, 4.5)
        XCTAssertNotNil(properties["timestamp"] as? String)
    }

    func testLocationSampleEncodesAsOwnTracksJSON() throws {
        let payload = OwnTracksLocationPayload(
            sample: makeSample(),
            deviceID: "moves-device",
            topic: "owntracks/moves/moves-device"
        )
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["_type"] as? String, "location")
        XCTAssertEqual(object["lat"] as? Double, 52.52)
        XCTAssertEqual(object["lon"] as? Double, 13.405)
        XCTAssertEqual(object["acc"] as? Double, 7)
        XCTAssertEqual(try XCTUnwrap(object["vel"] as? Double), 16.2, accuracy: 0.001)
        XCTAssertEqual(object["tid"] as? String, "moves-device")
        XCTAssertEqual(object["topic"] as? String, "owntracks/moves/moves-device")
    }

    func testMappedRouteExportUsesDisplayedCoordinatesAndMoveTimeRange() throws {
        let start = Date(timeIntervalSince1970: 1_735_000_000)
        let end = start.addingTimeInterval(120)
        let coordinates = [
            CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050),
            CLLocationCoordinate2D(latitude: 52.5210, longitude: 13.4050),
            CLLocationCoordinate2D(latitude: 52.5230, longitude: 13.4050),
        ]

        let samples = MappedRouteExport.samples(
            coordinates: coordinates,
            startDate: start,
            endDate: end
        )

        XCTAssertEqual(samples.count, coordinates.count)
        XCTAssertEqual(samples.map(\.latitude), coordinates.map(\.latitude))
        XCTAssertEqual(samples.map(\.longitude), coordinates.map(\.longitude))
        XCTAssertEqual(try XCTUnwrap(samples.first).timestamp, start)
        XCTAssertEqual(try XCTUnwrap(samples.last).timestamp, end)
        XCTAssertEqual(samples[1].timestamp.timeIntervalSince(start), 40, accuracy: 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(samples[1].speedMetersPerSecond), 0)
    }

    func testMappedRouteExportRejectsInvalidOrZeroDurationRoutes() {
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let coordinates = [
            CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
            CLLocationCoordinate2D(latitude: 52.53, longitude: 13.415),
        ]

        XCTAssertTrue(
            MappedRouteExport.samples(
                coordinates: coordinates,
                startDate: now,
                endDate: now
            ).isEmpty
        )
        XCTAssertTrue(
            MappedRouteExport.samples(
                coordinates: [CLLocationCoordinate2D(latitude: .nan, longitude: 13.405)],
                startDate: now,
                endDate: now.addingTimeInterval(60)
            ).isEmpty
        )
    }

    func testReittiConnectionUsesDeviceTokenEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/base/api/v1/ingest/owntracks")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.httpMethod, "POST")
            return (Data("[]".utf8), 200, [:])
        }
        let configuration = try LocationServiceConfiguration.make(service: .reitti, customURL: "https://example.com/base")

        _ = try await client.testConnection(
            configuration: configuration,
            credentials: LocationServiceCredentials(token: "secret"),
            trackingUsername: "",
            deviceID: ""
        )
    }

    func testGeoPulseConnectionUsesHealthEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            XCTAssertEqual(request.httpMethod, "GET")
            return (Data(#"{"status":"UP"}"#.utf8), 200, [:])
        }
        let configuration = try LocationServiceConfiguration.make(service: .geoPulse, customURL: "https://example.com")

        _ = try await client.testConnection(
            configuration: configuration,
            credentials: LocationServiceCredentials(username: "user", password: "pass"),
            trackingUsername: "",
            deviceID: "phone"
        )
    }

    func testOwnTracksRecorderConnectionUsesVersionAndBasicAuth() async throws {
        let expectedAuth = "Basic " + Data("proxy:password".utf8).base64EncodedString()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/recorder/api/0/version")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuth)
            return (Data(#"{"version":"0.9.8"}"#.utf8), 200, [:])
        }
        let configuration = try LocationServiceConfiguration.make(
            service: .ownTracksRecorder,
            customURL: "https://example.com/recorder"
        )

        let version = try await client.testConnection(
            configuration: configuration,
            credentials: LocationServiceCredentials(username: "proxy", password: "password"),
            trackingUsername: "moves",
            deviceID: "phone"
        )
        XCTAssertEqual(version, "0.9.8")
    }

    func testTraccarConnectionUsesConfiguredProtocolURLWithoutAddingAPath() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com:5144/owntracks")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (Data(), 200, [:])
        }
        let configuration = try LocationServiceConfiguration.make(
            service: .traccar,
            customURL: "https://example.com:5144/owntracks"
        )

        _ = try await client.testConnection(
            configuration: configuration,
            credentials: LocationServiceCredentials(),
            trackingUsername: "",
            deviceID: "123456"
        )
    }

    private func makeSample() -> LocationSample {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
            altitude: 42,
            horizontalAccuracy: 7,
            verticalAccuracy: 3,
            course: 90,
            speed: 4.5,
            timestamp: Date(timeIntervalSince1970: 1_735_000_000.125)
        )
        return LocationSample(location: location, source: .routeTracking, dedupeKey: "sample")
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (Data, Int, [String: String])
    ) -> LocationServiceAPIClient {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return LocationServiceAPIClient(session: URLSession(configuration: configuration))
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, Int, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, statusCode, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
