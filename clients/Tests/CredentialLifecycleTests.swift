import Foundation
import XCTest
@testable import LibraryCore
@testable import LibraryUI

private actor DelayedCredentials: SessionCredentialStore {
    var stored: SavedLibrarySession?
    var loadCount = 0
    var saveCount = 0
    var deleteCount = 0
    var delayLoad = true
    var delayedSaveTokens: Set<String> = []
    var delayedDeleteTokens: Set<String> = []
    private var loadContinuation: CheckedContinuation<SavedLibrarySession?, Error>?
    private var saves: [String: CheckedContinuation<Void, Error>] = [:]
    private var deletes: [String: CheckedContinuation<Void, Never>] = [:]
    func configure(delayLoad: Bool = true, saves: Set<String> = [], deletes: Set<String> = []) {
        self.delayLoad = delayLoad; delayedSaveTokens = saves; delayedDeleteTokens = deletes
    }
    func load(server: URL, interactionAllowed: Bool) async throws -> SavedLibrarySession? {
        loadCount += 1
        if delayLoad { return try await withCheckedThrowingContinuation { loadContinuation = $0 } }
        return stored
    }
    func save(_ session: SavedLibrarySession, server: URL) async throws {
        saveCount += 1
        // Model a system write whose completion notification can arrive late.
        stored = session
        if delayedSaveTokens.contains(session.login.sessionToken) {
            try await withCheckedThrowingContinuation { saves[session.login.sessionToken] = $0 }
        }
    }
    func delete(server: URL, matchingSessionToken: String) async throws {
        deleteCount += 1
        if delayedDeleteTokens.contains(matchingSessionToken) {
            await withCheckedContinuation { deletes[matchingSessionToken] = $0 }
        }
        if stored?.login.sessionToken == matchingSessionToken { stored = nil }
    }
    func finishLoad(_ result: Result<SavedLibrarySession?, Error>) { loadContinuation?.resume(with: result); loadContinuation = nil }
    func finishSave(_ token: String, error: Error? = nil) {
        let continuation = saves.removeValue(forKey: token)
        if let error { stored = nil; continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
    func finishDelete(_ token: String) { deletes.removeValue(forKey: token)?.resume() }
}

@MainActor
final class CredentialLifecycleTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL
        let suite: String
        let preferences: UserDefaults
        let urlSession: URLSession
        let access = DelayedCredentials()
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-model-" + UUID().uuidString)
            suite = "credential-model-" + UUID().uuidString
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CredentialLoginProtocol.self]
            urlSession = URLSession(configuration: config)
            CredentialLoginProtocol.reset()
        }
        func model(restore: Bool) throws -> AppModel {
            let session = urlSession
            return try AppModel(directory: directory, preferences: preferences, restoreSavedSession: restore,
                credentials: access, makeClient: { url, device in SyncClient(baseURL: url, deviceId: device, session: session, retryPolicy: .none) })
        }
        func clean() {
            urlSession.invalidateAndCancel(); preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func seedConnected() throws -> LibraryDocument {
            preferences.set("https://credentials.invalid", forKey: "connection.server")
            preferences.set("library-1", forKey: "connection.libraryId")
            preferences.set("root", forKey: "connection.rootId")
            let store = try LibraryWorkspaceManager(baseDirectory: directory).store(server: URL(string: "https://credentials.invalid")!, libraryId: "library-1")
            let folder = LibraryDocument(id: "folder", kind: .folder, parentId: "root", name: "Research", markdown: "", pdfPath: nil,
                revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
            try store.saveDocument(folder, enqueue: false)
            let note = LibraryDocument(id: "note", kind: .md, parentId: folder.id, name: "draft.md", markdown: "unsent work", pdfPath: nil,
                revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
            try store.saveDocument(note, enqueue: true)
            return note
        }
    }

    private func saved(_ token: String = "token-1", library: String = "library-1") -> SavedLibrarySession {
        SavedLibrarySession(username: "synthetic", login: LoginResult(sessionToken: token, epoch: "epoch", rootId: "root", libraryId: library, deviceId: "test"))
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Timed out waiting for controlled credential operation")
    }

    func testDelayedRestoreLeavesOfflineLibraryEditableAndKeepsSelection() async throws {
        let f = try Fixture(); defer { f.clean() }
        let note = try f.seedConnected(), model = try f.model(restore: true)
        XCTAssertTrue(model.offlineAccess); XCTAssertTrue(model.restoringSession)
        XCTAssertNotNil(model.credentialNotice); XCTAssertNil(model.session)
        let originalStore = model.store
        model.openDocument(note)
        _ = try model.store.updateMarkdown(id: note.id, markdown: "typed while Keychain waits")
        model.reload()
        try await wait { await f.access.loadCount == 1 }
        await f.access.finishLoad(.success(saved()))
        try await wait { model.session != nil }
        XCTAssertTrue(model.store === originalStore)
        XCTAssertEqual(model.currentFolder, "folder"); XCTAssertEqual(model.selectedId, note.id)
        XCTAssertEqual(model.selected?.markdown, "typed while Keychain waits")
        XCTAssertEqual(try model.store.pending().count, 1)
        XCTAssertFalse(model.restoringSession); XCTAssertNil(model.credentialNotice)
        model.showLocalLibrary()
    }

    func testLateRestoreCannotLeaveChosenLocalLibraryOrReplaceAnotherSession() async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.seedConnected(); let model = try f.model(restore: true)
        try await wait { await f.access.loadCount == 1 }
        model.showLocalLibrary(); model.newNote()
        let selection = model.selectedId, store = model.store
        model.session = saved("new-session", library: "different").login
        await f.access.finishLoad(.success(saved()))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.store === store); XCTAssertTrue(model.isLocalWorkspace)
        XCTAssertEqual(model.selectedId, selection); XCTAssertEqual(model.session?.sessionToken, "new-session")
        XCTAssertFalse(model.restoringSession); XCTAssertNil(model.credentialNotice)
    }

    func testUseOfflineCancelsWaitingRestoreWithoutErasingLocalResultOrAcceptingLateSession() async throws {
        let f=try Fixture();defer { f.clean() }
        let note=try f.seedConnected(),model=try f.model(restore:true)
        try await wait { await f.access.loadCount == 1 }
        model.openDocument(note)
        let store=model.store,queue=try store.pending()
        model.banner="文件已导出。"
        model.reportLocal("导入",message:"保留本机错误")
        let localError=model.localOperationError
        model.useOffline()
        XCTAssertTrue(model.offlineAccess);XCTAssertFalse(model.restoringSession)
        XCTAssertFalse(model.connectionBusy);XCTAssertNil(model.credentialNotice)
        XCTAssertEqual(model.banner,"文件已导出。")
        XCTAssertEqual(model.localOperationError,localError)
        await f.access.finishLoad(.success(saved()))
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertNil(model.session);XCTAssertNil(model.client)
        XCTAssertTrue(model.store === store);XCTAssertEqual(model.selectedId,note.id)
        XCTAssertEqual(try store.pending(),queue)
        XCTAssertEqual(model.banner,"文件已导出。")
    }

    func testRestoreFailureIsVisibleWithoutDiscardingQueueOrAutomaticRetries() async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.seedConnected(); let model = try f.model(restore: true)
        let queue = try model.store.pending()
        try await wait { await f.access.loadCount == 1 }
        await f.access.finishLoad(.failure(SessionVaultError.status(-25293)))
        try await wait { !model.restoringSession }
        XCTAssertTrue(model.offlineAccess); XCTAssertNotNil(model.connectionError)
        XCTAssertEqual(try model.store.pending(), queue)
        for _ in 0..<5 { model.reload(); model.requestSync() }
        try await Task.sleep(for: .milliseconds(20))
        let count = await f.access.loadCount; XCTAssertEqual(count, 1)
        XCTAssertNil(model.session)
    }

    func testFailedCredentialSaveNeverClaimsLoginOrChangesLibrary() async throws {
        let f = try Fixture(); defer { f.clean() }
        await f.access.configure(delayLoad: false, saves: ["token-1"])
        let model = try f.model(restore: false), originalStore = model.store
        model.server = "https://credentials.invalid"; model.password = "synthetic"
        let login = Task { await model.login() }
        try await wait { await f.access.saveCount == 1 }
        XCTAssertTrue(model.connectionBusy); XCTAssertNotNil(model.credentialNotice)
        await f.access.finishSave("token-1", error: SessionVaultError.status(-25293))
        await login.value
        XCTAssertNil(model.session); XCTAssertTrue(model.store === originalStore)
        XCTAssertNotNil(model.connectionError); XCTAssertFalse(model.connectionBusy)
        XCTAssertNil(model.credentialNotice)
    }

    func testCancelledSaveLateCompletionCannotReplaceNewLoginOrDeleteItsCredentials() async throws {
        let f = try Fixture(); defer { f.clean() }
        await f.access.configure(delayLoad: false, saves: ["token-1"])
        let model = try f.model(restore: false)
        model.server = "https://credentials.invalid"; model.password = "synthetic"
        let old = Task { await model.login() }
        try await wait { await f.access.saveCount == 1 }
        model.cancelConnection()
        XCTAssertFalse(model.connectionBusy); XCTAssertNil(model.credentialNotice)
        XCTAssertNil(model.session)
        await model.login()
        XCTAssertEqual(model.session?.sessionToken, "token-2")
        let store = model.store
        await f.access.finishSave("token-1")
        await old.value
        try await wait { await f.access.deleteCount == 1 }
        XCTAssertEqual(model.session?.sessionToken, "token-2"); XCTAssertTrue(model.store === store)
        let retained = await f.access.stored; XCTAssertEqual(retained?.login.sessionToken, "token-2")
        XCTAssertFalse(model.connectionBusy)
        model.showLocalLibrary()
    }

    func testLateLogoutCannotDeleteOrOverwriteSubsequentLogin() async throws {
        let f = try Fixture(); defer { f.clean() }
        await f.access.configure(delayLoad: false, deletes: ["token-1"])
        let model = try f.model(restore: false)
        model.server = "https://credentials.invalid"; model.password = "synthetic"
        await model.login(); XCTAssertEqual(model.session?.sessionToken, "token-1")
        model.logout()
        XCTAssertNil(model.session); XCTAssertTrue(model.offlineAccess)
        try await wait { await f.access.deleteCount == 1 }
        model.cancelConnection(); model.password = "synthetic"
        await model.login(); XCTAssertEqual(model.session?.sessionToken, "token-2")
        let store = model.store, banner = model.banner
        await f.access.finishDelete("token-1")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.store === store); XCTAssertEqual(model.session?.sessionToken, "token-2")
        XCTAssertEqual(model.banner, banner)
        let retained = await f.access.stored; XCTAssertEqual(retained?.login.sessionToken, "token-2")
        model.showLocalLibrary()
    }
}

private final class CredentialLoginProtocol: URLProtocol, @unchecked Sendable {
    private final class Counter: @unchecked Sendable { let lock = NSLock(); var value = 0 }
    private static let counter = Counter()
    static func reset() { counter.lock.withLock { counter.value = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if request.url?.path.hasSuffix("/login") == true {
            let n = Self.counter.lock.withLock { Self.counter.value += 1; return Self.counter.value }
            body = Data("{\"data\":{\"sessionToken\":\"token-\(n)\",\"epoch\":\"epoch\",\"rootId\":\"root\",\"libraryId\":\"library-\(n)\",\"deviceId\":\"test\"}}".utf8)
        } else { body = Data("{}".utf8) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
