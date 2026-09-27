import Foundation
import XCTest
@testable import LibraryCore

final class ConnectionReliabilityTests: XCTestCase, @unchecked Sendable {
    func testServerAddressNormalizesOriginsAndRejectsAmbiguousInput() throws {
        XCTAssertEqual(try ServerAddress.normalize("  HTTPS://Example.COM:443/\n").absoluteString, "https://example.com")
        XCTAssertEqual(try ServerAddress.normalize("http://localhost:8080/").absoluteString, "http://localhost:8080")
        XCTAssertEqual(try ServerAddress.normalize("http://[::1]:8080/").absoluteString, "http://[::1]:8080")
        for input in ["", "example.com", "ftp://example.com", "https:///example.com", "https://user:pass@example.com",
                      "https://example.com/api/v1", "https://example.com?token=x", "https://example.com#x",
                      "https://exam ple.com", "https://example.com:0", "https://example.com:65536", "https://example.com:",
                      "https://999.1.1.1", "https://bad..host", "https://-host.test", "http://[::::1]"] {
            XCTAssertThrowsError(try ServerAddress.normalize(input), input) { error in
                XCTAssertEqual(SyncFailure.from(error).kind, .invalidAddress)
            }
        }
    }

    func testNetworkFailuresHaveActionableChineseMessagesAndRetryClassification() {
        let cases: [(URLError.Code, SyncFailure.Kind, Bool)] = [
            (.notConnectedToInternet, .offline, true), (.timedOut, .timedOut, true),
            (.cannotConnectToHost, .cannotConnect, true), (.dnsLookupFailed, .cannotConnect, true),
            (.serverCertificateUntrusted, .certificate, false), (.secureConnectionFailed, .certificate, false),
            (.appTransportSecurityRequiresSecureConnection, .insecureConnection, false),
            (.badServerResponse, .invalidResponse, false), (.cancelled, .cancelled, false),
        ]
        for (code, kind, retryable) in cases {
            let failure = SyncFailure.from(URLError(code))
            XCTAssertEqual(failure.kind, kind)
            XCTAssertEqual(failure.isRetryable, retryable)
            XCTAssertFalse(failure.title.isEmpty)
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertFalse(failure.recoverySuggestion?.isEmpty ?? true)
        }
        XCTAssertFalse(SyncFailure.http(code: 401).isRetryable)
        XCTAssertTrue(SyncFailure.http(code: 429).isRetryable)
        XCTAssertTrue(SyncFailure.http(code: 503).isRetryable)
        XCTAssertFalse(SyncFailure.http(code: 422).isRetryable)
    }

    func testEveryHTTPFailureRetainsServerCodeAndRetryAfterForDiagnosis() {
        for code in [400, 401, 403, 408, 409, 410, 422, 429, 500, 502, 503, 504] {
            let failure = SyncFailure.http(code: code, retryAfter: 1, serverCode: "BUSY")
            XCTAssertEqual(failure.statusCode, code)
            XCTAssertEqual(failure.serverCode, "BUSY")
            XCTAssertEqual(failure.retryAfter, 1)
        }
    }

    func testShortServerBusyRetriesSameOperationAndPreservesLongMaintenanceCode() async throws {
        let busy = TestConnection([.http(503, #"{"error":{"code":"BUSY"}}"#, ["Retry-After": "1"]),
            .http(200, #"{"data":{"status":"committed","revision":"1","operationId":"stable-op"}}"#)])
        _ = try await busy.client.submit(action: "createFolder", objectId: "object", desired: [:], baseRevision: nil, operationId: "stable-op")
        XCTAssertEqual(busy.stub.delays, [1])
        XCTAssertEqual(busy.stub.requests.count, 2)
        XCTAssertEqual(busy.stub.requests.first?.httpBody, busy.stub.requests.last?.httpBody)
        XCTAssertEqual(busy.stub.requests.last?.value(forHTTPHeaderField: "Idempotency-Key"), "stable-op")
        let maintenance = TestConnection([.http(503, #"{"error":{"code":"MAINTENANCE"}}"#, ["Retry-After": "30"])])
        do { _ = try await maintenance.client.checkReadiness(); XCTFail("Expected maintenance") }
        catch { XCTAssertEqual(SyncFailure.from(error).serverCode, "MAINTENANCE"); XCTAssertEqual(SyncFailure.from(error).retryAfter, 30) }
        XCTAssertEqual(maintenance.stub.requests.count, 1)
        XCTAssertTrue(maintenance.stub.delays.isEmpty)
    }

    func testRetryAfterParsesSecondsAndHTTPDateWithoutRetryingBeforeServerWindow() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(SyncFailure.parseRetryAfter("30", now: now), 30)
        XCTAssertEqual(SyncFailure.parseRetryAfter("Thu, 01 Jan 1970 00:00:30 GMT", now: now), 30)
        XCTAssertEqual(SyncFailure.parseRetryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now: now.addingTimeInterval(10)), 0)
        XCTAssertNil(SyncFailure.parseRetryAfter("-1", now: now))
        XCTAssertNil(SyncFailure.parseRetryAfter("garbage", now: now))
        XCTAssertNil(SyncRetryPolicy().delay(afterAttempt: 1, failure: .http(code: 503, retryAfter: 30)))
        XCTAssertEqual(SyncRetryPolicy().delay(afterAttempt: 1, failure: .http(code: 429, retryAfter: 1)), 1)
    }

    func testReadinessUsesGETTimeoutAndExposesMaintenanceWithoutCredentials() async throws {
        let connection = TestConnection([.http(200, #"{"ready":true,"maintenance":true}"#)], timeout: 4)
        connection.client.sessionToken = "private-token"
        connection.client.epoch = "private-epoch"
        let ready = try await connection.client.checkReadiness()
        XCTAssertTrue(ready.ready)
        XCTAssertTrue(ready.maintenance)
        let request = try XCTUnwrap(connection.stub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/health/ready")
        XCTAssertEqual(request.timeoutInterval, 4)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Library-Epoch"))
    }

    func testReadinessRejectsSuccessfulHTMLAndInvalidJSON() async {
        for body in ["<html>proxy</html>", "{}", #"{"ready":"true","maintenance":false}"#] {
            let connection = TestConnection([.http(200, body)])
            do {
                try await connection.client.checkReadiness()
                XCTFail("accepted malformed response")
            } catch { XCTAssertEqual(SyncFailure.from(error).kind, .invalidResponse) }
            XCTAssertEqual(connection.stub.requests.count, 1)
        }
    }

    func testLogin401NeverRetriesOrReplacesSession() async {
        let connection = TestConnection([.http(401, "{}")])
        connection.client.sessionToken = "existing"
        do {
            _ = try await connection.client.login(username: "test", password: "invalid")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(SyncFailure.from(error).kind, .unauthorized)
            XCTAssertFalse(SyncFailure.from(error).isRetryable)
        }
        XCTAssertEqual(connection.stub.requests.count, 1)
        XCTAssertEqual(connection.client.sessionToken, "existing")
        XCTAssertEqual(connection.stub.delays, [])
    }

    func testProtocolUnsupportedLoginExplainsUpgradeAndDoesNotRetryOrReplaceSession() async {
        let connection = TestConnection([.http(426,
            #"{"error":{"code":"PROTOCOL_UNSUPPORTED","message":"unsupported protocol version"}}"#,
            ["Retry-After": "1"])])
        connection.client.sessionToken = "existing-session"
        connection.client.epoch = "existing-epoch"
        do {
            _ = try await connection.client.login(username: "synthetic", password: "synthetic")
            XCTFail("Unsupported protocol must reject login")
        } catch {
            let failure = SyncFailure.from(error)
            XCTAssertEqual(failure.title, "客户端与服务器版本不兼容")
            XCTAssertTrue(failure.message.contains("本机资料和待提交修改仍然保留"))
            XCTAssertTrue(failure.recoverySuggestion?.contains("更新客户端或服务器至相互兼容的版本后，再重新连接") == true)
            XCTAssertEqual(failure.statusCode, 426)
            XCTAssertEqual(failure.serverCode, "PROTOCOL_UNSUPPORTED")
            XCTAssertEqual(failure.retryAfter, 1)
            XCTAssertFalse(failure.isRetryable)
        }
        XCTAssertEqual(connection.stub.requests.count, 1)
        XCTAssertEqual(connection.stub.requests.first?.url?.path, "/api/v1/auth/login")
        XCTAssertTrue(connection.stub.delays.isEmpty)
        XCTAssertEqual(connection.client.sessionToken, "existing-session")
        XCTAssertEqual(connection.client.epoch, "existing-epoch")
    }

    func testProtocolUnsupportedFlushRetainsContentAndFrozenRequestAcrossExplicitRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        let body = "# Version mismatch\n\n中文和未提交正文仍应保留。\n"
        try store.localSaveOffline(markdown: body, id: "version-note", name: "version.md", parentId: "root")
        let response = StubResponse.http(426, #"{"error":{"code":"PROTOCOL_UNSUPPORTED","message":"unsupported protocol version"}}"#, ["Retry-After":"0"])
        let connection = TestConnection([response, response])
        connection.client.sessionToken = "synthetic-session"
        connection.client.epoch = "synthetic-epoch"
        let queued = try XCTUnwrap(store.pending().first)
        let frozen = try XCTUnwrap(store.prepareOperation(queued.operationId, epoch: "synthetic-epoch",
            deviceId: connection.client.deviceId, serverOrigin: connection.client.baseURL.absoluteString))
        let original = try XCTUnwrap(store.loadDocument(id: "version-note"))
        for expectedRequestCount in 1...2 {
            do {
                try await connection.client.flushPending(store: store, rootId: "root")
                XCTFail("Unsupported protocol must not acknowledge the operation")
            } catch {
                let failure = SyncFailure.from(error)
                XCTAssertEqual(failure.title, "客户端与服务器版本不兼容")
                XCTAssertFalse(failure.isRetryable)
            }
            XCTAssertEqual(connection.stub.requests.count, expectedRequestCount, "Only explicit calls may send again")
            XCTAssertTrue(connection.stub.delays.isEmpty)
            XCTAssertEqual(try store.pending(), [frozen])
            XCTAssertEqual(try store.loadDocument(id: "version-note"), original)
            let request = try XCTUnwrap(connection.stub.requests.last)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), frozen.operationId)
            XCTAssertEqual(request.httpBody, Data(try XCTUnwrap(frozen.requestJSON).utf8))
        }
        XCTAssertTrue(try store.conflicts().isEmpty)
        XCTAssertTrue(try store.editorDrafts().isEmpty)
    }

    func testUnknown426AndOtherStatusWithProtocolCodeKeepGenericHTTPFailure() async {
        for (status, body, code) in [
            (426, #"{"error":{"code":"UNKNOWN_UPGRADE","message":"another reason"}}"#, "UNKNOWN_UPGRADE" as String?),
            (426, #"{"error":{"message":"upgrade required"}}"#, nil),
            (426, "not json", nil),
            (400, #"{"error":{"code":"PROTOCOL_UNSUPPORTED"}}"#, "PROTOCOL_UNSUPPORTED"),
        ] {
            let connection = TestConnection([.http(status, body)])
            do { _ = try await connection.client.checkReadiness(); XCTFail("Expected HTTP rejection") }
            catch {
                let failure = SyncFailure.from(error)
                XCTAssertEqual(failure.title, "服务器拒绝了请求")
                XCTAssertEqual(failure.statusCode, status)
                XCTAssertEqual(failure.serverCode, code)
                XCTAssertFalse(failure.isRetryable)
            }
            XCTAssertEqual(connection.stub.requests.count, 1)
            XCTAssertTrue(connection.stub.delays.isEmpty)
        }
    }

    func testLoginRejectsIncompletePayloadAndAcceptsCodableSession() async throws {
        for body in [#"{"data":{}}"#, #"{"data":{"sessionToken":"","epoch":"e","rootId":"r","libraryId":"l","deviceId":"d"}}"#] {
            let connection = TestConnection([.http(200, body)])
            do {
                _ = try await connection.client.login(username: "test", password: "test")
                XCTFail("accepted invalid login")
            } catch { XCTAssertEqual(SyncFailure.from(error).kind, .invalidResponse) }
            XCTAssertNil(connection.client.sessionToken)
        }
        let connection = TestConnection([.http(200, #"{"data":{"sessionToken":"s","epoch":"e","rootId":"r","libraryId":"l","deviceId":"d"}}"#)])
        let session = try await connection.client.login(username: "test", password: "test")
        XCTAssertEqual(session.sessionToken, "s")
        XCTAssertEqual(connection.client.epoch, "e")
        XCTAssertEqual(connection.client.deviceId, "d")
        XCTAssertEqual(try JSONDecoder().decode(LoginResult.self, from: JSONEncoder().encode(session)), session)
    }

    func testIdempotentSubmitRetriesExactRequestAndOperationID() async throws {
        let connection = TestConnection([
            .error(URLError(.networkConnectionLost)),
            .http(429, "{}", ["Retry-After": "1"]),
            .http(200, #"{"data":{"status":"committed","revision":"7","objectId":"object","operationId":"stable-op"}}"#),
        ])
        connection.client.sessionToken = "session"
        connection.client.epoch = "epoch"
        _ = try await connection.client.submit(action: "createMarkdown", objectId: "object", desired: ["markdownSource": "hello"], baseRevision: nil, operationId: "stable-op")
        let requests = connection.stub.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(connection.stub.delays, [0.35, 1])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "stable-op")
            XCTAssertEqual(request.httpBody, requests.first?.httpBody)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["operationId"] as? String, "stable-op")
        }
    }

    func testGeneratedOperationIDAlsoStaysStableAcrossRetries() async throws {
        let connection = TestConnection([.http(502, "{}"), .http(200, #"{"data":{"status":"committed","revision":"1"}}"#)])
        _ = try await connection.client.submit(action: "createFolder", objectId: "object", desired: [:], baseRevision: nil)
        let requests = connection.stub.requests
        XCTAssertEqual(requests.count, 2)
        let operationID = try XCTUnwrap(requests.first?.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNotNil(UUID(uuidString: operationID))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Idempotency-Key"), operationID)
        XCTAssertEqual(requests.first?.httpBody, requests.last?.httpBody)
    }

    func testRetryLimitAndLongRetryAfterAreExposedToCaller() async {
        let connection = TestConnection(Array(repeating: .error(URLError(.timedOut)), count: 3))
        do {
            try await connection.client.checkReadiness()
            XCTFail("expected timeout")
        } catch { XCTAssertEqual(SyncFailure.from(error).kind, .timedOut) }
        XCTAssertEqual(connection.stub.requests.count, 3)
        XCTAssertEqual(connection.stub.delays, [0.35, 0.7])

        let maintenance = TestConnection([.http(503, "{}", ["Retry-After": "30"])])
        do {
            try await maintenance.client.checkReadiness()
            XCTFail("expected maintenance")
        } catch {
            XCTAssertEqual(SyncFailure.from(error).kind, .serviceUnavailable)
            XCTAssertEqual(SyncFailure.from(error).retryAfter, 30)
        }
        XCTAssertEqual(maintenance.stub.requests.count, 1)
        XCTAssertEqual(maintenance.stub.delays, [])
    }

    func testTransportAndBackoffCancellationAreNotConvertedOrRetried() async {
        for connection in [TestConnection([.error(URLError(.cancelled))]),
                           TestConnection([.http(503, "{}")], cancelSleep: true)] {
            do {
                try await connection.client.checkReadiness()
                XCTFail("expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(connection.stub.requests.count, 1)
        }
    }

    func testInvalidReceiptDoesNotClearPendingOrChangeRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        try store.localSaveOffline(markdown: "local", id: "object", name: "note.md", parentId: "root")
        let operation = try XCTUnwrap(store.pending().first)
        let client = SyncClient(baseURL: URL(string: "https://example.invalid")!)
        let receipts: [[String: Any]] = [
            [:], ["status": "unknown", "revision": "1"], ["status": "committed"],
            ["status": "committed", "revision": true], ["status": "committed", "revision": 1.5],
            ["status": "committed", "revision": "-1"], ["status": "committed", "revision": "999999999999999999999999"],
            ["status": "committed", "revision": "1", "objectId": "other"],
            ["status": "committed", "revision": "1", "operationId": "other"],
        ]
        for receipt in receipts {
            XCTAssertThrowsError(try client.applyFlushResult(["data": receipt], op: operation, store: store)) { error in
                XCTAssertEqual(SyncFailure.from(error).kind, .invalidResponse)
            }
            XCTAssertEqual(try store.pending().count, 1)
            XCTAssertEqual(try store.loadDocument(id: "object")?.revision, 0)
        }
        try client.applyFlushResult(["data": ["status": "committed", "revision": "7"]], op: operation, store: store)
        XCTAssertEqual(try store.pending().count, 0)
        XCTAssertEqual(try store.loadDocument(id: "object")?.revision, 7)
    }
}

enum StubResponse {
    case http(Int, String, [String: String] = [:])
    case error(URLError)
    case deferred(DeferredResponse, Int, String, [String: String] = [:])
}

final class DeferredResponse: @unchecked Sendable {
    let started = XCTestExpectation(description: "request started")
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    func register(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { self.completion = completion }
        started.fulfill()
    }
    func release() {
        let reply = lock.withLock { let reply = completion; completion = nil; return reply }
        reply?()
    }
}

final class LockedStub: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [StubResponse]
    private var captured: [URLRequest] = []
    private var sleeps: [TimeInterval] = []
    init(_ responses: [StubResponse]) { self.responses = responses }
    var requests: [URLRequest] { lock.withLock { captured } }
    var delays: [TimeInterval] { lock.withLock { sleeps } }
    func recordSleep(_ value: TimeInterval) { lock.withLock { sleeps.append(value) } }
    func next(_ original: URLRequest) -> StubResponse {
        var request = original
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            request.httpBody = data
        }
        return lock.withLock {
            captured.append(request)
            return responses.isEmpty ? .error(URLError(.badServerResponse)) : responses.removeFirst()
        }
    }
}

private final class StubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [String: LockedStub] = [:]
    func set(_ stub: LockedStub?, for host: String) { lock.withLock { stubs[host] = stub } }
    func get(_ host: String) -> LockedStub? { lock.withLock { stubs[host] } }
}

private final class ConnectionURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = StubRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = Self.registry.get(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch stub.next(request) {
        case let .http(code, body, headers):
            respond(url: url, code: code, body: body, headers: headers)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .deferred(gate, code, body, headers):
            gate.register { self.respond(url: url, code: code, body: body, headers: headers) }
        }
    }
    private func respond(url: URL, code: Int, body: String, headers: [String: String]) {
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TestConnection: @unchecked Sendable {
    let stub: LockedStub
    let client: SyncClient
    private let host: String
    let session: URLSession
    init(_ responses: [StubResponse], timeout: TimeInterval = 15, cancelSleep: Bool = false, downloadsBodies: Bool? = nil) {
        let stub = LockedStub(responses)
        self.stub = stub
        host = UUID().uuidString.lowercased() + ".invalid"
        ConnectionURLProtocol.registry.set(stub, for: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = SyncClient(baseURL: URL(string: "https://\(host)")!, downloadsBodies: downloadsBodies, session: session, requestTimeout: timeout, sleep: { delay in
            stub.recordSleep(delay)
            if cancelSleep { throw CancellationError() }
            try Task.checkCancellation()
        })
    }
    deinit {
        session.invalidateAndCancel()
        ConnectionURLProtocol.registry.set(nil, for: host)
    }
}
