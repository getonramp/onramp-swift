import XCTest
@testable import OnRamp

struct CapturedRequest {
    let urlRequest: URLRequest
    let body: Data
}

// Intercepts all requests made through the injected URLSession.
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var captured: [CapturedRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves httpBody into httpBodyStream before handing to URLProtocol.
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n > 0 { bodyData.append(contentsOf: buf[..<n]) }
            }
            stream.close()
        }
        MockURLProtocol.captured.append(CapturedRequest(urlRequest: request, body: bodyData))
        let response = MockURLProtocol.requestHandler?(request)
            ?? (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        client?.urlProtocol(self, didReceive: response.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OnRampTests: XCTestCase {
    private static let host = "https://api.test.example"
    private static let key  = "onr_test_key"

    override func setUp() {
        super.setUp()
        MockURLProtocol.captured = []
        MockURLProtocol.requestHandler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        OnRamp._urlSession = URLSession(configuration: config)
        UserDefaults.standard.removeObject(forKey: "onramp_anonymous_id")
        OnRamp.newSession() // zeroes lastActive so initialize()'s refreshSession() resets stepIndex
        OnRamp.initialize(apiKey: Self.key, host: Self.host)
    }

    // MARK: - Helpers

    private func send(_ block: () -> Void) {
        let exp = expectation(description: "request")
        MockURLProtocol.requestHandler = { req in
            exp.fulfill()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        block()
        waitForExpectations(timeout: 1)
    }

    private func sendN(_ n: Int, _ block: () -> Void) {
        let exp = expectation(description: "\(n) requests")
        exp.expectedFulfillmentCount = n
        MockURLProtocol.requestHandler = { req in
            exp.fulfill()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        block()
        waitForExpectations(timeout: 1)
    }

    private func event(from captured: CapturedRequest) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        return try XCTUnwrap(events.first)
    }

    // MARK: - HTTP shape

    func testStepPostsToCorrectURL() {
        send { OnRamp.step("test") }
        let req = MockURLProtocol.captured.first!.urlRequest
        XCTAssertEqual(req.url?.absoluteString, "\(Self.host)/v1/events")
        XCTAssertEqual(req.httpMethod, "POST")
    }

    func testStepSetsAuthAndContentTypeHeaders() {
        send { OnRamp.step("test") }
        let req = MockURLProtocol.captured.first!.urlRequest
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-onramp-key"), Self.key)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - Event schema

    func testStepBodyContainsRequiredFields() throws {
        send { OnRamp.step("account_created") }
        let ev = try event(from: MockURLProtocol.captured.first!)
        XCTAssertEqual(ev["event_type"] as? String, "step_entered")
        XCTAssertEqual(ev["step_name"] as? String, "account_created")
        XCTAssertEqual(ev["schema_version"] as? String, "1.0")
        XCTAssertEqual(ev["app_key"] as? String, Self.key)
        XCTAssertEqual(ev["platform"] as? String, "ios")
        XCTAssertNotNil(ev["anonymous_id"])
        XCTAssertNotNil(ev["session_id"])
        XCTAssertNotNil(ev["event_id"])
        XCTAssertNotNil(ev["client_timestamp_ms"])
    }

    func testStepPropertiesAreIncluded() throws {
        send { OnRamp.step("signup", properties: ["plan": "free", "source": "invite"]) }
        let ev = try event(from: MockURLProtocol.captured.first!)
        let props = try XCTUnwrap(ev["properties"] as? [String: Any])
        XCTAssertEqual(props["plan"] as? String, "free")
        XCTAssertEqual(props["source"] as? String, "invite")
    }

    func testStepWithoutPropertiesOmitsField() throws {
        send { OnRamp.step("no_props") }
        let ev = try event(from: MockURLProtocol.captured.first!)
        XCTAssertNil(ev["properties"])
    }

    func testAnonymousIdIsValidUUID() throws {
        send { OnRamp.step("test") }
        let ev = try event(from: MockURLProtocol.captured.first!)
        let anonId = try XCTUnwrap(ev["anonymous_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: anonId))
    }

    // MARK: - Step index

    func testStepIndexIncrements() throws {
        sendN(3) { OnRamp.step("a"); OnRamp.step("b"); OnRamp.step("c") }
        let indices = try MockURLProtocol.captured.map { try event(from: $0)["step_index"] as? Int }
        XCTAssertEqual(indices, [0, 1, 2])
    }

    func testNewSessionResetsStepIndex() throws {
        sendN(2) { OnRamp.step("before"); OnRamp.newSession(); OnRamp.step("after") }
        let lastEv = try event(from: MockURLProtocol.captured.last!)
        XCTAssertEqual(lastEv["step_index"] as? Int, 0)
    }

    func testNewSessionRotatesSessionId() throws {
        sendN(2) { OnRamp.step("before"); OnRamp.newSession(); OnRamp.step("after") }
        let id0 = try event(from: MockURLProtocol.captured[0])["session_id"] as? String
        let id1 = try event(from: MockURLProtocol.captured[1])["session_id"] as? String
        XCTAssertNotEqual(id0, id1)
    }

    // MARK: - identify()

    func testIdentifyUsesCorrectEventType() throws {
        send { OnRamp.identify(["userId": "u_123", "email": "a@b.com"]) }
        let ev = try event(from: MockURLProtocol.captured.first!)
        XCTAssertEqual(ev["event_type"] as? String, "identify")
        XCTAssertEqual(ev["step_name"] as? String, "_identify")
    }

    func testIdentifyPassesTraits() throws {
        send { OnRamp.identify(["userId": "u_123", "plan": "pro"]) }
        let ev = try event(from: MockURLProtocol.captured.first!)
        let props = try XCTUnwrap(ev["properties"] as? [String: Any])
        XCTAssertEqual(props["userId"] as? String, "u_123")
        XCTAssertEqual(props["plan"] as? String, "pro")
    }

    // MARK: - initialize()

    func testUsesProductionIngestionHostByDefault() {
        OnRamp.initialize(apiKey: Self.key)
        send { OnRamp.step("test") }
        XCTAssertEqual(
            MockURLProtocol.captured.first?.urlRequest.url?.absoluteString,
            "https://ingest.getonramp.dev/v1/events"
        )
    }

    func testTrailingSlashIsStrippedFromHost() {
        UserDefaults.standard.removeObject(forKey: "onramp_anonymous_id")
        OnRamp.initialize(apiKey: Self.key, host: "\(Self.host)/")
        send { OnRamp.step("test") }
        XCTAssertEqual(MockURLProtocol.captured.first?.urlRequest.url?.absoluteString, "\(Self.host)/v1/events")
    }

    func testAnonymousIdPersistedAcrossInit() throws {
        send { OnRamp.step("first") }
        let id1 = try XCTUnwrap(event(from: MockURLProtocol.captured.first!)["anonymous_id"] as? String)

        // Simulate app restart: re-initialize without clearing UserDefaults.
        MockURLProtocol.captured = []
        OnRamp.initialize(apiKey: Self.key, host: Self.host)
        send { OnRamp.step("second") }
        let id2 = try XCTUnwrap(event(from: MockURLProtocol.captured.first!)["anonymous_id"] as? String)

        XCTAssertEqual(id1, id2)
    }

    func testClearingUserDefaultsGeneratesNewAnonymousId() throws {
        send { OnRamp.step("first") }
        let id1 = try XCTUnwrap(event(from: MockURLProtocol.captured.first!)["anonymous_id"] as? String)

        MockURLProtocol.captured = []
        UserDefaults.standard.removeObject(forKey: "onramp_anonymous_id")
        OnRamp.initialize(apiKey: Self.key, host: Self.host)
        send { OnRamp.step("second") }
        let id2 = try XCTUnwrap(event(from: MockURLProtocol.captured.first!)["anonymous_id"] as? String)

        XCTAssertNotEqual(id1, id2)
    }
}
