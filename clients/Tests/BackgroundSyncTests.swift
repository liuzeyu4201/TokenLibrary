import Foundation
import XCTest
@testable import LibraryCore
@testable import LibraryUI

private actor BackgroundCredentials: SessionCredentialStore {
    var reads = 0
    var interactionFlags: [Bool] = []
    var deletes = 0
    private var pending: CheckedContinuation<SavedLibrarySession?, Error>?
    func load(server: URL, interactionAllowed: Bool) async throws -> SavedLibrarySession? {
        reads += 1; interactionFlags.append(interactionAllowed)
        // Deliberately ignores cancellation, like a system call already begun.
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func save(_ session: SavedLibrarySession, server: URL) async throws { XCTFail("Background refresh must not save credentials") }
    func delete(server: URL, matchingSessionToken: String) async throws { deletes += 1 }
    func finish(_ result: Result<SavedLibrarySession?, Error>) { pending?.resume(with: result); pending = nil }
}

private final class BackgroundHTTP: URLProtocol, @unchecked Sendable {
    final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var status = 200
        var stall = false
        private var requests = 0
        private var stops = 0
        var counts: (Int, Int) { lock.withLock { (requests, stops) } }
        func start() -> (Int, Bool) { lock.withLock { requests += 1; return (status, stall) } }
        func stop() { lock.withLock { stops += 1 } }
        func configure(status: Int = 200, stall: Bool = false) { lock.withLock { self.status = status; self.stall = stall } }
    }
    private final class Registry: @unchecked Sendable { let lock = NSLock(); var values: [String: Probe] = [:] }
    private static let registry = Registry()
    static func register(_ probe: Probe?, host: String) { registry.lock.withLock { registry.values[host] = probe } }
    private var probe: Probe? { Self.registry.lock.withLock { Self.registry.values[request.url!.host!] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let probe else { return }
        let (status, stall) = probe.start()
        guard !stall else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let json = status == 200 ? "{\"data\":{\"epoch\":\"epoch\",\"changes\":[],\"nextCursor\":0,\"hasMore\":false}}" : "{\"error\":{\"code\":\"SESSION_EXPIRED\",\"message\":\"synthetic\"}}"
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { probe?.stop() }
}

@MainActor
final class BackgroundSyncTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL
        let suite: String
        let preferences: UserDefaults
        let server: URL
        let urlSession: URLSession
        let access = BackgroundCredentials()
        let probe = BackgroundHTTP.Probe()
        let store: DocumentStore
        let previousSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        init() throws {
            let id = UUID().uuidString.lowercased()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("background-sync-" + id)
            suite = "background-sync-" + id
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            server = URL(string: "https://" + id + ".invalid")!
            preferences.set(server.absoluteString, forKey: "connection.server")
            preferences.set("library", forKey: "connection.libraryId")
            preferences.set("root", forKey: "connection.rootId")
            preferences.set("device", forKey: "connection.deviceId")
            store = try LibraryWorkspaceManager(baseDirectory: directory).store(server: server, libraryId: "library")
            try store.bindWorkspace(server: server.absoluteString, libraryId: "library", rootId: "root")
            try store.applyRemoteBatch([], deletedIds: [], cursor: 0, epoch: "epoch", fullSnapshot: true)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BackgroundHTTP.self]
            urlSession = URLSession(configuration: config)
            BackgroundHTTP.register(probe, host: server.host!)
            preferences.set(previousSuccess.timeIntervalSince1970, forKey: successKey)
        }
        var successKey: String { "sync.lastSuccess." + BlobIntegrity.sha256(Data(store.root.standardizedFileURL.path.utf8)) }
        var success: Date? { (preferences.object(forKey: successKey) as? TimeInterval).map(Date.init(timeIntervalSince1970:)) }
        func saved(library: String = "library") -> SavedLibrarySession {
            SavedLibrarySession(username: "synthetic", login: LoginResult(sessionToken: "synthetic-token", epoch: "epoch", rootId: "root", libraryId: library, deviceId: "device"))
        }
        func run(credentialWait: Duration = .seconds(2), timeBudget: Duration = .seconds(3)) async -> BackgroundSyncOutcome {
            let session = urlSession
            return await AppModel.synchronizeInBackground(directory: directory, preferences: preferences, credentials: access,
                credentialWait: credentialWait, timeBudget: timeBudget,
                makeClient: { url, device in SyncClient(baseURL: url, deviceId: device, session: session, retryPolicy: .none) })
        }
        func queueNote() throws -> [PendingOperation] {
            _ = try store.createDocument(LibraryDocument(id: "note", kind: .md, parentId: "root", name: "offline.md", markdown: "must remain", pdfPath: nil,
                revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]"))
            return try store.pending()
        }
        func clean() {
            urlSession.invalidateAndCancel(); BackgroundHTTP.register(nil, host: server.host!)
            preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory)
        }
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Controlled background operation did not reach its checkpoint")
    }

    func testAwaitsNoninteractiveRestoreRunsExactlyOnceAndRecordsOnlyItsWorkspace() async throws {
        let f = try Fixture(); defer { f.clean() }
        let foreground = try AppModel(directory: f.directory, preferences: f.preferences, restoreSavedSession: false)
        foreground.newNote(); let selection = foreground.selectedId, foregroundStore = foreground.store
        let task = Task { await f.run() }
        try await wait { await f.access.reads == 1 }
        XCTAssertEqual(f.probe.counts.0, 0); XCTAssertEqual(f.success, f.previousSuccess)
        await f.access.finish(.success(f.saved()))
        let result = await task.value
        guard case let .synchronized(root, at) = result else { return XCTFail("Expected completed sync, received \(result)") }
        XCTAssertEqual(root, f.store.root)
        XCTAssertEqual(try XCTUnwrap(f.success).timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertGreaterThan(at, f.previousSuccess)
        let flags = await f.access.interactionFlags; XCTAssertEqual(flags, [false])
        // One real synchronize does two changes reads. No detached foreground
        // requestSync should wake after its 500ms debounce.
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(f.probe.counts.0, 2)
        foreground.reload()
        XCTAssertTrue(foreground.store === foregroundStore); XCTAssertEqual(foreground.selectedId, selection)
        XCTAssertNil(foreground.lastSyncAt); XCTAssertEqual(try foreground.store.pending().count, 1)
        foreground.store = f.store; foreground.reload()
        XCTAssertEqual(try XCTUnwrap(foreground.lastSyncAt).timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testMissingAndDeniedCredentialsDoNotSyncOrChangeSuccessOrQueue() async throws {
        for denied in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let queue = try f.queueNote(), task = Task { await f.run() }
            try await wait { await f.access.reads == 1 }
            await f.access.finish(denied ? .failure(SessionVaultError.status(-25308)) : .success(nil))
            let result = await task.value
            XCTAssertEqual(result, denied ? .credentialsUnavailable : .noSavedSession)
            XCTAssertEqual(f.probe.counts.0, 0); XCTAssertEqual(f.success, f.previousSuccess)
            XCTAssertEqual(try f.store.pending(), queue)
        }
    }

    func testCredentialDeadlineReturnsWithoutWaitingForSystemAndIgnoresLateRead() async throws {
        let f = try Fixture(); defer { f.clean() }
        let queue = try f.queueNote(), started = ContinuousClock.now
        let task = Task { await f.run(credentialWait: .milliseconds(60)) }
        try await wait { await f.access.reads == 1 }
        let result = await task.value
        XCTAssertEqual(result, .credentialsTimedOut); XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        await f.access.finish(.success(f.saved()))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.probe.counts.0, 0); XCTAssertEqual(f.success, f.previousSuccess)
        XCTAssertEqual(try f.store.pending(), queue)
    }

    func testCancellationDuringCredentialWaitReturnsBeforeLateSystemRead() async throws {
        let f = try Fixture(); defer { f.clean() }
        let task = Task { await f.run() }
        try await wait { await f.access.reads == 1 }
        task.cancel()
        let result = await task.value; XCTAssertEqual(result, .cancelled)
        await f.access.finish(.success(f.saved()))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.probe.counts.0, 0); XCTAssertEqual(f.success, f.previousSuccess)
    }

    func testChangedSavedLibraryDoesNotBindOrOpenAnotherWorkspace() async throws {
        let f = try Fixture(); defer { f.clean() }
        let task = Task { await f.run() }
        try await wait { await f.access.reads == 1 }
        await f.access.finish(.success(f.saved(library: "replacement")))
        let result = await task.value; XCTAssertEqual(result, .configurationChanged)
        XCTAssertEqual(f.probe.counts.0, 0); XCTAssertEqual(f.success, f.previousSuccess)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("Libraries").path).count, 1)
    }

    func testExpiredSessionDefersToForegroundWithoutDeletingCredentialsOrQueue() async throws {
        let f = try Fixture(); defer { f.clean() }
        let queue = try f.queueNote(); f.probe.configure(status: 401)
        let task = Task { await f.run() }
        try await wait { await f.access.reads == 1 }; await f.access.finish(.success(f.saved()))
        let result = await task.value; XCTAssertEqual(result, .requiresLogin)
        XCTAssertEqual(f.probe.counts.0, 1); XCTAssertEqual(f.success, f.previousSuccess)
        XCTAssertEqual(try f.store.pending(), queue)
        let deletes = await f.access.deletes; XCTAssertEqual(deletes, 0)
    }

    func testOverallDeadlineCancelsActiveHTTPAndDoesNotRecordSuccess() async throws {
        let f = try Fixture(); defer { f.clean() }
        let queue = try f.queueNote(); f.probe.configure(stall: true)
        let task = Task { await f.run(timeBudget: .milliseconds(150)) }
        try await wait { await f.access.reads == 1 }; await f.access.finish(.success(f.saved()))
        try await wait { f.probe.counts.0 == 1 }
        let result = await task.value; XCTAssertEqual(result, .deferred)
        try await wait { f.probe.counts.1 == 1 }
        XCTAssertEqual(f.success, f.previousSuccess); XCTAssertEqual(try f.store.pending(), queue)
    }

    func testSystemCancellationStopsHTTPAndReleasesWorkspaceForNextRefresh() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.probe.configure(stall: true)
        let task = Task { await f.run() }
        try await wait { await f.access.reads == 1 }; await f.access.finish(.success(f.saved()))
        try await wait { f.probe.counts.0 == 1 }; task.cancel()
        let result = await task.value; XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(f.success, f.previousSuccess)
        f.probe.configure()
        let retry = Task { await f.run() }
        try await wait { await f.access.reads == 2 }; await f.access.finish(.success(f.saved()))
        let retried = await retry.value
        guard case .synchronized = retried else { return XCTFail("Cancelled refresh held the workspace: \(retried)") }
        XCTAssertEqual(f.probe.counts.0, 3)
    }
}
