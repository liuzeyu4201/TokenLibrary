import Foundation

extension SyncClient {
    /// Every page and receipt is durable independently; concurrent entry points serialize per workspace.
    public func synchronize(store: DocumentStore, rootId requestedRoot: String? = nil) async throws -> SyncSummary {
        try await WorkspaceSyncGate.shared.withPermit(key: store.synchronizationKey) {
            try await self.synchronizeUnlocked(store: store, rootId: requestedRoot)
        }
    }

    private func synchronizeUnlocked(store: DocumentStore, rootId requestedRoot: String?) async throws -> SyncSummary {
        guard sessionToken != nil, let epoch, let libraryId else { throw SyncFailure.http(code: 401) }
        let origin = try ServerAddress.normalize(baseURL.absoluteString).absoluteString
        try store.bindWorkspace(server: origin, libraryId: libraryId, rootId: rootId)
        var summary = SyncSummary()
        if try store.syncValue("initialized") != "1" || store.syncValue("epoch") != epoch {
            summary.downloaded += try await bootstrap(store: store, epoch: epoch)
        }
        let before = try await pullChanges(store: store, epoch: epoch)
        summary.downloaded += before.downloaded; summary.deleted += before.deleted
        let pendingBefore = try store.pending().count
        try await flushPendingUnlocked(store: store, rootId: requestedRoot ?? rootId)
        summary.uploaded = max(0, pendingBefore - (try store.pending().count))
        let after = try await pullChanges(store: store, epoch: epoch)
        summary.downloaded += after.downloaded; summary.deleted += after.deleted
        try await fetchConflictMaterials(store: store)
        try store.pruneAcknowledgedOperations()
        summary.conflicts = try store.conflicts().count
        summary.cursor = store.syncCursor
        return summary
    }

    func requestJSON(path: String, method: String = "GET", query: [String: String] = [:], body: JSONValue? = nil, retry: Bool = true) async throws -> DocumentSnapshot {
        var req = try request(path: path, method: method, auth: true)
        if !query.isEmpty {
            guard var parts = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) else { throw SyncFailure.invalidAddress }
            parts.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
            req.url = parts.url
        }
        if let body { req.httpBody = try body.encoded(); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data = try await send(req, retry: retry)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data).object, let payload = root["data"]?.object else { throw SyncFailure.invalidResponse }
        return payload
    }

    func bootstrap(store: DocumentStore, epoch: String) async throws -> Int {
        for attempt in 0..<2 {
            do { return try await bootstrapAttempt(store: store, epoch: epoch) }
            catch let failure as SyncFailure where [404,410].contains(failure.statusCode ?? 0) && attempt == 0 {
                try Task.checkCancellation()
                // Expired frozen pages never clear the existing library/cursor; obtain one new snapshot.
            }
        }
        throw SyncFailure.invalidResponse
    }

    private func bootstrapAttempt(store: DocumentStore, epoch: String) async throws -> Int {
        var page = try await requestJSON(path: "/api/v1/sync/snapshots", method: "POST", body: .object(["limit": .integer(100)]), retry: false)
        guard let id = page["snapshotId"]?.string, UUID(uuidString: id) != nil, let atSeq = page["atSeq"]?.int64,
              page["epoch"]?.string == epoch else { throw SyncFailure.invalidResponse }
        var snapshots: [DocumentSnapshot] = []
        var present = Set<String>()
        var cursor = "0"
        // iPhone applies each catalog page immediately and never asks for file
        // bytes here. Mac still waits until every body is stored, then commits
        // the snapshot in one transaction.
        let epochRestart = downloadsBodies ? false : (try store.prepareEpochChange(epoch))
        while true {
            try Task.checkCancellation()
            guard page["snapshotId"]?.string == id, page["epoch"]?.string == epoch, page["atSeq"]?.int64 == atSeq,
                  let items = page["items"]?.array, let hasMore = page["hasMore"]?.bool else { throw SyncFailure.invalidResponse }
            var pageSnapshots: [DocumentSnapshot] = []
            for item in items {
                let snapshot = try normalizedSnapshot(item)
                pageSnapshots.append(snapshot)
                if let itemID = snapshot["id"]?.string { present.insert(itemID) }
            }
            if downloadsBodies {
                snapshots.append(contentsOf: pageSnapshots)
            } else {
                try store.applyRemoteSnapshotPage(pageSnapshots)
                if epochRestart { try store.adoptEpochConflictRemotes(pageSnapshots) }
                onLibraryPage?()
            }
            if !hasMore { break }
            guard let next = page["nextCursor"]?.string, next != cursor else { throw SyncFailure.invalidResponse }
            cursor = next
            page = try await requestJSON(path: "/api/v1/sync/snapshots/\(id)", query: ["after": cursor, "limit": "100"])
        }
        if downloadsBodies {
            for snapshot in snapshots { try await downloadAttachments(snapshot: snapshot, store: store) }
            try store.applyRemoteBatch(snapshots, deletedIds: [], cursor: atSeq, epoch: epoch, fullSnapshot: true)
            return snapshots.count
        }
        try store.finishRemoteSnapshot(presentIds: present, cursor: atSeq, epoch: epoch)
        onLibraryPage?()
        return present.count
    }

    func pullChanges(store: DocumentStore, epoch: String) async throws -> SyncSummary {
        var result = SyncSummary()
        var cursor = store.syncCursor
        while true {
            try Task.checkCancellation()
            let page = try await requestJSON(path: "/api/v1/sync/changes", query: ["after": String(cursor), "limit": "100"])
            guard page["epoch"]?.string == epoch, let changes = page["changes"]?.array,
                  let next = page["nextCursor"]?.int64, next >= cursor, let hasMore = page["hasMore"]?.bool else { throw SyncFailure.invalidResponse }
            var snapshots: [DocumentSnapshot] = [], deleted: [String] = []
            var last = cursor
            for change in changes {
                guard let event = change.object, let seq = event["seq"]?.int64, seq > last,
                      let objects = event["objects"]?.array, let removed = event["deletedIds"]?.array else { throw SyncFailure.invalidResponse }
                last = seq
                for item in objects { snapshots.append(try normalizedSnapshot(item)) }
                for id in removed { guard let value = id.string else { throw SyncFailure.invalidResponse }; deleted.append(value) }
            }
            guard last == next, !hasMore || next > cursor else { throw SyncFailure.invalidResponse }
            if downloadsBodies {
                for snapshot in snapshots { try await downloadAttachments(snapshot: snapshot, store: store) }
            }
            try store.applyRemoteBatch(snapshots, deletedIds: deleted, cursor: next, epoch: epoch)
            if !downloadsBodies { onLibraryPage?() }
            result.downloaded += snapshots.count; result.deleted += deleted.count
            cursor = next
            if !hasMore { break }
        }
        result.cursor = cursor
        return result
    }

    func normalizedSnapshot(_ value: JSONValue) throws -> DocumentSnapshot {
        guard let item = value.object else { throw SyncFailure.invalidResponse }
        var snapshot = item["snapshot"]?.object ?? item
        if snapshot["id"] == nil { snapshot["id"] = item["id"] }
        if snapshot["revision"] == nil { snapshot["revision"] = item["revision"] }
        guard let id = snapshot["id"]?.string, UUID(uuidString: id) != nil, let revision = snapshot["revision"]?.int64, revision > 0,
              let kind = snapshot["kind"]?.string, DocKind(rawValue: kind) != nil, snapshot["name"]?.string != nil else { throw SyncFailure.invalidResponse }
        if let metadata = snapshot["metadata"], metadata.object == nil { throw SyncFailure.invalidResponse }
        return snapshot
    }

    public func fetchDocument(id: String) async throws -> DocumentSnapshot {
        guard UUID(uuidString: id) != nil else { throw SyncFailure.invalidResponse }
        let payload = try await requestJSON(path: "/api/v1/objects/\(id)")
        guard let value = payload["snapshot"] else { throw SyncFailure.invalidResponse }
        return try normalizedSnapshot(value)
    }

    public func resolveConflict(_ conflict: LibraryConflict, resolution: ConflictResolution, store: DocumentStore) async throws {
        try await WorkspaceSyncGate.shared.withPermit(key: store.synchronizationKey) {
            try await self.resolveConflictUnlocked(conflict, resolution: resolution, store: store)
        }
    }

    private func resolveConflictUnlocked(_ conflict: LibraryConflict, resolution: ConflictResolution, store: DocumentStore) async throws {
        guard let epoch, let rootId else { throw SyncFailure.http(code: 401) }
        let latest: DocumentSnapshot
        do { latest = try await fetchDocument(id: conflict.objectId) }
        catch let failure as SyncFailure {
            // A post-backup object has no row or tombstone in the restored server:
            // its authenticated lookup returns NOT_FOUND rather than GONE. Require
            // the completed current-epoch snapshot to have independently confirmed
            // this conflict's absence; an arbitrary/proxy 404 must not discard data.
            if failure.statusCode != 410 {
                guard failure.statusCode == 404, failure.serverCode == "NOT_FOUND",
                      try store.hasConfirmedMissingConflict(conflict, epoch: epoch) else { throw failure }
            }
            let keep: Bool, markdown: String?
            switch resolution { case .remote: keep = false; markdown = nil; case .local: keep = true; markdown = nil; case .customMarkdown(let value): keep = true; markdown = value }
            try store.resolveDeletedConflict(conflict, keepLocal: keep, markdown: markdown, rootId: rootId)
            try await flushPendingUnlocked(store: store, rootId: rootId)
            return
        }
        if downloadsBodies { try await downloadAttachments(snapshot: latest, store: store) }
        var selected = try store.loadDocument(id: conflict.objectId)?.syncSnapshot ?? JSONValue.parse(conflict.localJSON).object ?? latest
        switch resolution {
        case .remote: selected = latest
        case .local: break
        case .customMarkdown(let markdown): selected["markdownSource"] = .string(markdown)
        }
        _ = try store.queueConflictResolution(conflict, selected: selected, latest: latest, epoch: epoch, deviceId: deviceId, serverOrigin: ServerAddress.normalize(baseURL.absoluteString).absoluteString)
        try await flushPendingUnlocked(store: store, rootId: rootId)
    }

    func fetchConflictMaterials(store: DocumentStore) async throws {
        for conflict in try store.conflicts() {
            guard let id = conflict.serverId, UUID(uuidString: id) != nil else { continue }
            var materials: [String: DocumentSnapshot] = [:]
            for role in ["base", "local", "remote"] {
                let response = try await requestJSON(path: "/api/v1/conflicts/\(id)/materials/\(role)")
                guard let snapshot = response["snapshot"]?.object ?? response["bytes"]?.object else { throw SyncFailure.invalidResponse }
                materials[role] = snapshot
            }
            try store.saveConflictMaterials(id: conflict.id, base: materials["base"] ?? [:], local: materials["local"] ?? [:], remote: materials["remote"] ?? [:], revision: conflict.revision)
        }
    }

    func handleAuthoritativeResponse(_ result: [String: Any], operation: PendingOperation, store: DocumentStore) async throws {
        _ = try validatedReceipt(result, objectId: operation.objectId, operationId: operation.operationId)
        let data = try JSONSerialization.data(withJSONObject: result)
        guard let envelope = try JSONDecoder().decode(JSONValue.self, from: data).object else { throw SyncFailure.invalidResponse }
        let payload = envelope["data"]?.object ?? envelope
        guard let status = payload["status"]?.string, ["committed","no_change","conflict"].contains(status) else { throw SyncFailure.invalidResponse }
        let snapshot: DocumentSnapshot
        if let returned = payload["snapshot"] { snapshot = try normalizedSnapshot(returned) }
        else { snapshot = try await fetchDocument(id: operation.objectId) }
        guard snapshot["id"]?.string == operation.objectId else { throw SyncFailure.invalidResponse }
        if downloadsBodies { try await downloadAttachments(snapshot: snapshot, store: store) }
        let conflictIDs = payload["conflictIds"]?.array?.compactMap(\.string) ?? []
        try store.applyAuthoritativeReceipt(snapshot, operation: operation, status: status, serverConflictIds: conflictIDs)
    }
}
