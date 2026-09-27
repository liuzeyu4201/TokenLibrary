import Foundation

public struct LoginResult: Codable, Sendable, Equatable {
    public var sessionToken: String
    public var epoch: String
    public var rootId: String
    public var libraryId: String
    public var deviceId: String
    public init(sessionToken: String, epoch: String, rootId: String, libraryId: String, deviceId: String) {
        self.sessionToken = sessionToken
        self.epoch = epoch
        self.rootId = rootId
        self.libraryId = libraryId
        self.deviceId = deviceId
    }
}

public final class SyncClient: @unchecked Sendable {
    public var baseURL: URL
    public var sessionToken: String?
    public var epoch: String?
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    /// iPhone keeps the catalog only. The file is fetched when that document is opened.
    public var downloadsBodies: Bool
    public var onLibraryPage: (@Sendable () -> Void)?
    public var libraryId: String?
    public var rootId: String?
    private let session: URLSession
    public let requestTimeout: TimeInterval
    private let retryPolicy: SyncRetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(baseURL: URL, deviceId: String = UUID().uuidString.lowercased(), deviceName: String = "client", platform: String = "swift", downloadsBodies: Bool? = nil, session: URLSession = .shared,
                requestTimeout: TimeInterval = 15, retryPolicy: SyncRetryPolicy = SyncRetryPolicy(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }) {
        self.baseURL = baseURL
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        #if os(iOS)
        self.downloadsBodies = downloadsBodies ?? false
        #else
        self.downloadsBodies = downloadsBodies ?? true
        #endif
        self.session = session
        self.requestTimeout = requestTimeout.isFinite ? min(max(requestTimeout, 0.1), 60) : 15
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    @discardableResult
    public func checkReadiness() async throws -> ServerReadiness {
        let req = try request(path: "/health/ready", method: "GET", auth: false)
        let data = try await send(req, retry: true)
        guard let result = try? JSONDecoder().decode(ServerReadiness.self, from: data) else {
            throw SyncFailure.invalidResponse
        }
        guard result.ready else { throw SyncFailure.http(code: 503) }
        return result
    }

    public func login(username: String, password: String) async throws -> LoginResult {
        let body: [String: String] = [
            "username": username, "password": password,
            "deviceId": deviceId, "deviceName": deviceName, "platform": platform,
        ]
        let data = try await post(path: "/api/v1/auth/login", json: body, auth: false)
        struct Envelope: Decodable { let data: LoginResult }
        guard let result = try? JSONDecoder().decode(Envelope.self, from: data).data,
              [result.sessionToken, result.epoch, result.rootId, result.libraryId, result.deviceId]
                .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw SyncFailure.invalidResponse }
        self.sessionToken = result.sessionToken
        self.epoch = result.epoch
        self.deviceId = result.deviceId
        self.libraryId = result.libraryId
        self.rootId = result.rootId
        return result
    }

    public func restoreSession(_ result: LoginResult) {
        sessionToken = result.sessionToken; epoch = result.epoch; deviceId = result.deviceId
        libraryId = result.libraryId; rootId = result.rootId
    }

    public func submit(action: String, objectId: String, desired: [String: Any], baseRevision: Int64?, operationId: String? = nil) async throws -> [String: Any] {
        let op = operationId ?? UUID().uuidString.lowercased()
        var env: [String: Any] = [
            "protocolVersion": 1,
            "operationId": op,
            "epoch": epoch ?? "",
            "deviceId": deviceId,
            "objectId": objectId,
            "action": action,
            "desiredSnapshot": desired,
        ]
        if let r = baseRevision {
            env["base"] = ["source": "revision", "revision": r]
        }
        let data = try await post(path: "/api/v1/sync/operations", json: env, auth: true, idem: op)
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncFailure.invalidResponse
        }
        let (status, revision) = try validatedReceipt(result, objectId: objectId, operationId: op)
        let receipt = result["data"] as? [String: Any] ?? result
        if receipt["snapshot"] == nil && needsRemoteState(status: status, revision: revision, baseRevision: baseRevision) { throw SyncFailure.remoteStateRequired }
        return result
    }

    public func flushPending(store: DocumentStore, rootId: String? = nil) async throws {
        try await WorkspaceSyncGate.shared.withPermit(key: store.synchronizationKey) {
            try await self.flushPendingUnlocked(store: store, rootId: rootId)
        }
    }

    func flushPendingUnlocked(store: DocumentStore, rootId: String? = nil) async throws {
        let origin = try ServerAddress.normalize(baseURL.absoluteString).absoluteString
        for queued in try store.pending() {
            try Task.checkCancellation()
            if let rootId, try !store.belongsToRoot(objectId: queued.objectId, rootId: rootId) { continue }
            if queued.state == "needs_edit" { throw try store.rejectionFailure(operationId: queued.operationId) }
            if queued.state == "awaiting_remote", libraryId != nil {
                guard let wire = queued.requestJSON, let envelope = try JSONValue.parse(wire).object,
                      envelope["epoch"]?.string == epoch, envelope["deviceId"]?.string == deviceId,
                      queued.requestOrigin == origin else { throw StoreError.operationContextChanged }
                let snapshot = try await fetchDocument(id: queued.objectId)
                if downloadsBodies { try await downloadAttachments(snapshot: snapshot, store: store) }
                try store.applyAuthoritativeReceipt(snapshot, operation: queued, status: "committed")
                continue
            }
            if queued.requestJSON == nil, libraryId != nil { try await prepareAttachments(objectId: queued.objectId, store: store) }
            guard let op = try store.prepareOperation(queued.operationId, epoch: epoch ?? "", deviceId: deviceId, serverOrigin: origin) else { continue }
            guard let wire = op.requestJSON else { throw SyncFailure.invalidResponse }
            var req = try request(path: "/api/v1/sync/operations", method: "POST", auth: true)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(op.operationId, forHTTPHeaderField: "Idempotency-Key")
            req.httpBody = Data(wire.utf8)
            let data: Data
            do { data = try await send(req, retry: true) }
            catch let failure as SyncFailure where failure.serverCode == "NAME_CONFLICT" || failure.serverCode == "VALIDATION" {
                try store.rejectOperation(op, failure: failure)
                throw failure
            }
            guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SyncFailure.invalidResponse }
            let payload = result["data"] as? [String: Any] ?? result
            if payload["snapshot"] != nil || libraryId != nil {
                try await handleAuthoritativeResponse(result, operation: op, store: store)
            } else { try applyFlushResult(result, op: op, store: store) }
        }
    }

    public func applyFlushResult(_ result: [String: Any], op: PendingOperation, store: DocumentStore) throws {
        let (status, revision) = try validatedReceipt(result, objectId: op.objectId, operationId: op.operationId)
        let payload = result["data"] as? [String: Any] ?? result
        if let raw = payload["snapshot"], let data = try? JSONSerialization.data(withJSONObject: raw), let snapshot = try? JSONDecoder().decode(DocumentSnapshot.self, from: data) {
            try store.applyAuthoritativeReceipt(snapshot, operation: op, status: status, serverConflictIds: payload["conflictIds"] as? [String] ?? [])
            return
        }
        if needsRemoteState(status: status, revision: revision, baseRevision: op.baseRevision) {
            try store.pauseForRemoteFetch(op)
            throw SyncFailure.remoteStateRequired
        }
        try store.acknowledge(op, revision: revision, conflict: status == "conflict")
    }

    private func needsRemoteState(status: String, revision: Int64, baseRevision: Int64?) -> Bool {
        guard let base = baseRevision else { return false }
        if status == "no_change" { return revision > base }
        let (nextRevision, overflow) = base.addingReportingOverflow(1)
        return status == "committed" && !overflow && revision > nextRevision
    }

    public static func parseRevision(_ raw: Any?) -> Int64 {
        if let s = raw as? String, let n = Int64(s) { return n }
        if let raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed),
           let value = try? JSONDecoder().decode(Int64.self, from: data) { return value }
        return 0
    }

    func validatedReceipt(_ result: [String: Any], objectId: String, operationId: String) throws -> (String, Int64) {
        let data = result["data"] as? [String: Any] ?? result
        guard let status = data["status"] as? String, ["committed", "no_change", "conflict"].contains(status),
              Self.parseRevision(data["revision"]) > 0 else { throw SyncFailure.invalidResponse }
        if let returned = data["objectId"], returned as? String != objectId { throw SyncFailure.invalidResponse }
        if let returned = data["operationId"], returned as? String != operationId { throw SyncFailure.invalidResponse }
        return (status, Self.parseRevision(data["revision"]))
    }

    private func post(path: String, json: Any, auth: Bool, idem: String? = nil) async throws -> Data {
        var req = try request(path: path, method: "POST", auth: auth)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idem { req.setValue(idem, forHTTPHeaderField: "Idempotency-Key") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        // Login creates a new session and is intentionally never retried automatically.
        return try await send(req, retry: idem != nil)
    }

    func request(path: String, method: String, auth: Bool) throws -> URLRequest {
        let origin = try ServerAddress.normalize(baseURL.absoluteString)
        var req = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: requestTimeout)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth, let t = sessionToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if auth, let e = epoch { req.setValue(e, forHTTPHeaderField: "X-Library-Epoch") }
        if auth {
            req.setValue(platform, forHTTPHeaderField: "X-Device-Platform")
            req.setValue(deviceName, forHTTPHeaderField: "X-Device-Name")
        }
        return req
    }

    func send(_ req: URLRequest, retry: Bool) async throws -> Data { try await perform(req, retry: retry).0 }

    func perform(_ req: URLRequest, retry: Bool) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            do {
                let (data, resp) = try await session.data(for: req)
                try Task.checkCancellation()
                guard let http = resp as? HTTPURLResponse else { throw SyncFailure.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    let envelope = try? JSONDecoder().decode(JSONValue.self, from: data).object
                    let serverCode = envelope?["error"]?.object?["code"]?.string
                    throw SyncFailure.http(code: http.statusCode, retryAfter: SyncFailure.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")), serverCode: serverCode)
                }
                return (data, http)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                let failure = SyncFailure.from(error)
                guard retry, let delay = retryPolicy.delay(afterAttempt: attempt, failure: failure) else { throw failure }
                try await sleep(delay)
            }
        }
    }
}

/// Retained for callers that reference the previous error type. New requests throw SyncFailure.
public enum SyncError: Error { case http(Int, String) }
