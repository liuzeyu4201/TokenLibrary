import Foundation
import GRDB

extension DocumentStore {
    func rejectOperation(_ operation: PendingOperation, failure: SyncFailure) throws {
        try db.write { db in
            guard let stored = try String.fetchOne(db, sql: "SELECT request_json FROM pending_operations WHERE operation_id=? AND state='pending'", arguments: [operation.operationId]), stored == operation.requestJSON,
                  let code = failure.serverCode, let status = failure.statusCode else { throw StoreError.staleOperation }
            try db.execute(sql: "UPDATE pending_operations SET state='needs_edit' WHERE operation_id=?", arguments: [operation.operationId])
            try db.execute(sql: "INSERT OR REPLACE INTO operation_rejections(operation_id,http_status,error_code) VALUES (?,?,?)", arguments: [operation.operationId,status,code])
        }
    }

    func rejectionFailure(operationId: String) throws -> SyncFailure {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT http_status,error_code FROM operation_rejections WHERE operation_id=?", arguments: [operationId]) else { return SyncFailure.invalidResponse }
            return SyncFailure.http(code: row["http_status"], serverCode: row["error_code"])
        }
    }

    public func bindWorkspace(server: String, libraryId: String, rootId: String? = nil) throws {
        try db.write { db in
            var values = [("server", server), ("libraryId", libraryId)]
            if let rootId {
                guard !rootId.isEmpty else { throw StoreError.operationContextChanged }
                values.append(("rootId", rootId))
            }
            for (key, value) in values {
                if let old = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key=?", arguments: [key]), old != value { throw StoreError.operationContextChanged }
                try db.execute(sql: "INSERT OR REPLACE INTO sync_state(key,value) VALUES (?,?)", arguments: [key, value])
            }
        }
    }

    public func syncValue(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key=?", arguments: [key]) }
    }
    public var syncCursor: Int64 { (try? syncValue("cursor")).flatMap(Int64.init) ?? 0 }

    public func remoteSnapshot(id: String) throws -> DocumentSnapshot? {
        try db.read { db in
            guard let text = try String.fetchOne(db, sql: "SELECT snapshot_json FROM remote_documents WHERE id=?", arguments: [id]) else { return nil }
            return try JSONValue.parse(text).object
        }
    }

    public func conflicts() throws -> [LibraryConflict] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_conflicts WHERE state='open' OR state LIKE 'resolving:%' ORDER BY created_at").map {
                LibraryConflict(id: $0["id"], objectId: $0["object_id"], serverId: $0["server_id"], kind: $0["kind"], baseJSON: $0["base_json"], localJSON: $0["local_json"], remoteJSON: $0["remote_json"], revision: $0["revision"], state: $0["state"])
            }
        }
    }

    /// All documents, tombstones, indexes and the cursor for this page commit together.
    public func applyRemoteBatch(_ snapshots: [DocumentSnapshot], deletedIds: [String], cursor: Int64, epoch: String, fullSnapshot: Bool = false) throws {
        try db.write { db in
            let oldCursor = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key='cursor'").flatMap(Int64.init) ?? 0
            guard fullSnapshot || cursor >= oldCursor else { throw SyncFailure.invalidResponse }
            var removed = Set(deletedIds)
            if fullSnapshot {
                let present = Set(snapshots.compactMap { $0["id"]?.string })
                let known = Set(try String.fetchAll(db, sql: "SELECT id FROM remote_documents"))
                removed.formUnion(known.subtracting(present))
                if let previousEpoch = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key='epoch'"), previousEpoch != epoch {
                    let changed = try Row.fetchAll(db, sql: "SELECT DISTINCT d.* FROM working_documents d JOIN pending_operations p ON p.object_id=d.id WHERE p.state IN ('pending','awaiting_remote','needs_edit')")
                    for row in changed {
                        let document = mapDoc(row)
                        let base = try String.fetchOne(db, sql: "SELECT snapshot_json FROM remote_documents WHERE id=?", arguments: [document.id]).flatMap { try JSONValue.parse($0).object } ?? [:]
                        let remote = snapshots.first { $0["id"]?.string == document.id } ?? ["id": .string(document.id),"state": .string("purged")]
                        try recordConflict(objectId: document.id, kind: "epoch_changed", base: base, local: document.syncSnapshot, remote: remote, revision: remote["revision"]?.int64 ?? 0, db: db)
                    }
                    try db.execute(sql: "DELETE FROM remote_documents")
                }
            }
            for snapshot in snapshots { try applyPulled(snapshot, db: db) }
            for id in removed { try applyTombstone(id, db: db) }
            for (key, value) in [("cursor", String(cursor)), ("epoch", epoch), ("initialized", "1")] {
                try db.execute(sql: "INSERT OR REPLACE INTO sync_state(key,value) VALUES (?,?)", arguments: [key, value])
            }
        }
    }

    func applyPulled(_ snapshot: DocumentSnapshot, db: Database) throws {
        guard let id = snapshot["id"]?.string, let revision = snapshot["revision"]?.int64, revision > 0 else { throw SyncFailure.invalidResponse }
        let priorText = try String.fetchOne(db, sql: "SELECT snapshot_json FROM remote_documents WHERE id=?", arguments: [id])
        let prior = try priorText.flatMap { try JSONValue.parse($0).object }
        if let priorRevision = prior?["revision"]?.int64, priorRevision > revision { return }
        let current = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
        try writeRemote(snapshot, db: db)
        guard let current else { try writeWorking(snapshot, prior: nil, status: .synced, db: db); return }
        let outstanding = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND state IN ('pending','awaiting_remote','needs_edit','conflict')", arguments: [id]) ?? 0
        let open = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_conflicts WHERE object_id=? AND state='open'", arguments: [id]) ?? 0
        if outstanding == 0 && open == 0 { try writeWorking(snapshot, prior: current, status: .synced, db: db); return }
        let frozen = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND request_json IS NOT NULL AND state IN ('pending','awaiting_remote','needs_edit','conflict')", arguments: [id]) ?? 0
        // Frozen requests still use their original base; their authoritative receipt will rebase newer edits.
        if frozen > 0 || open > 0 { return }
        guard let prior else {
            if current.revision == 0 { return }
            try recordConflict(objectId: id, kind: "missing_base", base: [:], local: current.syncSnapshot, remote: snapshot, revision: revision, db: db)
            return
        }
        let merged = SnapshotMerger.merge(base: prior, local: current.syncSnapshot, remote: snapshot)
        if merged.hasConflict {
            try recordConflict(objectId: id, kind: "pull_merge", base: prior, local: current.syncSnapshot, remote: snapshot, revision: revision, db: db)
        } else {
            let updated = try writeWorking(merged.snapshot, prior: current, status: .pending, db: db)
            try rewriteMutableTail(updated, db: db)
        }
    }

    /// Install the authoritative server result, then rebase only edits made after the frozen request.
    public func applyAuthoritativeReceipt(_ snapshot: DocumentSnapshot, operation: PendingOperation, status: String, serverConflictIds: [String] = []) throws {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_operations WHERE operation_id=?", arguments: [operation.operationId]),
                  ["pending", "awaiting_remote"].contains(row["state"] as String) else { return }
            guard (row["request_json"] as String?) == operation.requestJSON,
                  let revision = snapshot["revision"]?.int64, snapshot["id"]?.string == operation.objectId else { throw SyncFailure.invalidResponse }
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [operation.objectId]).map(mapDoc) else { throw StoreError.notFound }
            let oldRemote = try String.fetchOne(db, sql: "SELECT snapshot_json FROM remote_documents WHERE id=?", arguments: [operation.objectId]).flatMap { try JSONValue.parse($0).object } ?? current.syncSnapshot
            var submitted = oldRemote
            let desired = try JSONValue.parse(operation.payload).object ?? [:]
            for (key, value) in desired { submitted[key] = value }
            if operation.action == "trash" { submitted["state"] = .string("trashed") }
            if operation.action == "restore" { submitted["state"] = .string("active") }
            try writeRemote(snapshot, db: db)
            if status == "conflict" {
                for id in serverConflictIds.isEmpty ? [UUID().uuidString.lowercased()] : serverConflictIds {
                    try recordConflict(objectId: operation.objectId, kind: "server", base: oldRemote, local: current.syncSnapshot, remote: snapshot, revision: revision, id: id, serverId: serverConflictIds.contains(id) ? id : nil, db: db)
                }
                return
            }
            try db.execute(sql: "UPDATE pending_operations SET state='sent' WHERE operation_id=?", arguments: [operation.operationId])
            try db.execute(sql: "UPDATE sync_conflicts SET state='resolved' WHERE object_id=? AND state=?", arguments: [operation.objectId,"resolving:" + operation.operationId])
            if operation.action == "resolveConflicts" || operation.action == "resolveLocal" {
                try db.execute(sql: "UPDATE sync_conflicts SET state='resolved' WHERE object_id=?", arguments: [operation.objectId])
            }
            let later = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND state='pending'", arguments: [operation.objectId]) ?? 0
            let changed = current.localGeneration > (operation.frozenGeneration ?? current.localGeneration) || later > 0
            if !changed { try writeWorking(snapshot, prior: current, status: .synced, db: db); return }
            let merged = SnapshotMerger.merge(base: submitted, local: current.syncSnapshot, remote: snapshot)
            if merged.hasConflict {
                try recordConflict(objectId: operation.objectId, kind: "inflight_merge", base: submitted, local: current.syncSnapshot, remote: snapshot, revision: revision, db: db)
            } else {
                let updated = try writeWorking(merged.snapshot, prior: current, status: .pending, db: db)
                try rewriteMutableTail(updated, db: db)
            }
        }
    }

    public func saveConflictMaterials(id: String, base: DocumentSnapshot, local: DocumentSnapshot, remote: DocumentSnapshot, revision: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE sync_conflicts SET base_json=?, local_json=?, remote_json=?, revision=? WHERE id=?",
                           arguments: [try JSONValue.object(base).jsonString(), try JSONValue.object(local).jsonString(), try JSONValue.object(remote).jsonString(), revision, id])
        }
    }

    public func queueConflictResolution(_ conflict: LibraryConflict, selected: DocumentSnapshot, latest: DocumentSnapshot, epoch: String, deviceId: String, serverOrigin: String) throws -> PendingOperation {
        try db.write { db in
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [conflict.objectId]).map(mapDoc),
                  let revision = latest["revision"]?.int64 else { throw StoreError.notFound }
            var desired = selected
            desired["id"] = .string(conflict.objectId); desired["revision"] = .string(String(revision))
            let serverIDs = try String.fetchAll(db, sql: "SELECT server_id FROM sync_conflicts WHERE object_id=? AND server_id IS NOT NULL AND state<>'resolved'", arguments: [conflict.objectId])
            var action = "updateDocument"
            if !serverIDs.isEmpty { action = "resolveConflicts" }
            else if desired["parentId"] != latest["parentId"] { action = "move" }
            else if desired["name"] != latest["name"] { action = "rename" }
            let id = UUID().uuidString.lowercased()
            var wire: DocumentSnapshot = ["protocolVersion": .integer(1),"operationId": .string(id),"epoch": .string(epoch),"deviceId": .string(deviceId),"objectId": .string(conflict.objectId),"action": .string(action),"desiredSnapshot": .object(desired),"base": .object(["source": .string("revision"),"revision": .integer(revision)])]
            if !serverIDs.isEmpty { wire["resolution"] = .object(["conflictIds": .array(serverIDs.map(JSONValue.string)),"revision": .integer(revision)]) }
            try writeRemote(latest, db: db)
            let resolving = try writeWorking(desired, prior: current, status: .pending, db: db)
            // writeWorking already advances the local generation. Freeze that
            // exact value so its receipt does not invent an intervening edit.
            let generation = resolving.localGeneration
            try db.execute(sql: "UPDATE pending_operations SET state='superseded' WHERE object_id=? AND state IN ('pending','awaiting_remote','needs_edit','conflict')", arguments: [conflict.objectId])
            try db.execute(sql: "UPDATE sync_conflicts SET state=? WHERE object_id=? AND state<>'resolved'", arguments: ["resolving:" + id,conflict.objectId])
            let payload = try JSONValue.object(desired).jsonString(), request = try JSONValue.object(wire).jsonString()
            try db.execute(sql: "INSERT INTO pending_operations(operation_id,action,object_id,payload,state,created_at,base_revision,request_json,request_origin,frozen_generation) VALUES (?,?,?,?,'pending',?,?,?,?,?)",
                           arguments: [id,action,conflict.objectId,payload,ISO8601DateFormatter().string(from: Date()),revision,request,serverOrigin,generation])
            return PendingOperation(operationId: id, action: action, objectId: conflict.objectId, payload: payload, state: "pending", baseRevision: revision, requestJSON: request, requestOrigin: serverOrigin, frozenGeneration: generation)
        }
    }

    func hasConfirmedMissingConflict(_ conflict: LibraryConflict, epoch: String) throws -> Bool {
        try db.read { db in
            guard try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key='epoch'") == epoch,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM remote_documents WHERE id=?", arguments: [conflict.objectId]) == 0,
                  let row = try Row.fetchOne(db, sql: "SELECT kind,remote_json FROM sync_conflicts WHERE id=? AND object_id=? AND state='open'", arguments: [conflict.id, conflict.objectId]),
                  ["epoch_changed", "deleted"].contains(row["kind"] as String),
                  let remote = try JSONValue.parse(row["remote_json"] as String).object else { return false }
            return remote["id"]?.string == conflict.objectId && remote["state"]?.string == "purged"
        }
    }

    public func resolveDeletedConflict(_ conflict: LibraryConflict, keepLocal: Bool, markdown: String? = nil, rootId: String) throws {
        try db.write { db in
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [conflict.objectId]).map(mapDoc) else { throw StoreError.notFound }
            if keepLocal {
                var snapshot = current.syncSnapshot
                let id = UUID().uuidString.lowercased()
                snapshot["id"] = .string(id); snapshot["revision"] = .string("0"); snapshot["state"] = .string("active")
                snapshot["parentId"] = .string(rootId)
                snapshot["name"] = .string("恢复副本-" + current.name)
                if let markdown { snapshot["markdownSource"] = .string(markdown) }
                let copy = try writeWorking(snapshot, prior: nil, status: .pending, db: db)
                try db.execute(sql: "INSERT INTO pending_operations(operation_id,action,object_id,payload,state,created_at) VALUES (?,?,?,?,'pending',?)", arguments: [UUID().uuidString.lowercased(),Self.syncAction(kind: copy.kind, revision: 0),id,encodePayload(copy),ISO8601DateFormatter().string(from: Date())])
            }
            try db.execute(sql: "UPDATE sync_conflicts SET state='resolved' WHERE object_id=?", arguments: [conflict.objectId])
            try db.execute(sql: "UPDATE pending_operations SET state='superseded' WHERE object_id=? AND state IN ('pending','awaiting_remote','needs_edit','conflict')", arguments: [conflict.objectId])
            try db.execute(sql: "DELETE FROM working_documents WHERE id=?", arguments: [conflict.objectId])
            try db.execute(sql: "DELETE FROM search_chunks WHERE object_id=?", arguments: [conflict.objectId])
            try db.execute(sql: "DELETE FROM search_index_state WHERE object_id=?", arguments: [conflict.objectId])
            try db.execute(sql: "DELETE FROM search_fts WHERE object_id=?", arguments: [conflict.objectId])
        }
    }

    func recordConflict(objectId: String, kind: String, base: DocumentSnapshot, local: DocumentSnapshot, remote: DocumentSnapshot, revision: Int64, id: String = UUID().uuidString.lowercased(), serverId: String? = nil, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO sync_conflicts(id,object_id,server_id,kind,base_json,local_json,remote_json,revision,state,created_at) VALUES (?,?,?,?,?,?,?,?,'open',?)",
                       arguments: [id, objectId, serverId, kind, try JSONValue.object(base).jsonString(), try JSONValue.object(local).jsonString(), try JSONValue.object(remote).jsonString(), revision, ISO8601DateFormatter().string(from: Date())])
        try db.execute(sql: "UPDATE pending_operations SET state='conflict' WHERE object_id=? AND state IN ('pending','awaiting_remote','needs_edit')", arguments: [objectId])
        try db.execute(sql: "UPDATE working_documents SET status=? WHERE id=?", arguments: [SyncStatus.conflict.rawValue, objectId])
    }

    func writeRemote(_ snapshot: DocumentSnapshot, db: Database) throws {
        guard let id = snapshot["id"]?.string, let revision = snapshot["revision"]?.int64 else { throw SyncFailure.invalidResponse }
        try db.execute(sql: "INSERT INTO remote_documents(id,revision,snapshot_json) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,snapshot_json=excluded.snapshot_json",
                       arguments: [id, revision, try JSONValue.object(snapshot).jsonString()])
        try db.execute(sql: "DELETE FROM remote_tombstones WHERE id=?", arguments: [id])
    }

    @discardableResult
    func writeWorking(_ snapshot: DocumentSnapshot, prior: LibraryDocument?, status: SyncStatus, db: Database) throws -> LibraryDocument {
        guard let id = snapshot["id"]?.string, let kindName = snapshot["kind"]?.string, let kind = DocKind(rawValue: kindName),
              let name = snapshot["name"]?.string, let revision = snapshot["revision"]?.int64 else { throw SyncFailure.invalidResponse }
        let blob = snapshot["pdfBlobId"]?.string
        let localPDF = try blob.flatMap { try String.fetchOne(db, sql: "SELECT local_path FROM blob_transfers WHERE blob_id=?", arguments: [$0]) }
        let annotations = (snapshot["annotations"]?.array ?? []).map { value -> JSONValue in
            guard var object = value.object else { return value }
            if let geometry = object["geometry"]?.object { for (key, val) in geometry { object[key] = val } }
            return .object(object)
        }
        let purge = snapshot["purgeAt"]?.string.flatMap { value -> Date? in
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        let doc = LibraryDocument(id: id, kind: kind, parentId: snapshot["parentId"]?.string ?? "", name: name,
                                  markdown: snapshot["markdownSource"]?.string ?? "", pdfPath: localPDF.map { root.appendingPathComponent($0).path } ?? (blob == prior?.pdfBlobId ? prior?.pdfPath : nil),
                                  revision: revision, localGeneration: prior.map { $0.localGeneration + 1 } ?? 0, state: snapshot["state"]?.string ?? "active", purgeAt: purge, status: status,
                                  annotationsJSON: try JSONValue.array(annotations).jsonString(), metadataJSON: try (snapshot["metadata"] ?? .object([:])).jsonString(),
                                  assetsJSON: try (snapshot["assets"] ?? .array([])).jsonString(), pdfBlobId: blob)
        try db.execute(sql: """
            INSERT INTO working_documents(id,kind,parent_id,name,markdown,pdf_path,revision,local_generation,state,purge_at,status,annotations_json,updated_at,metadata_json,assets_json,pdf_blob_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,parent_id=excluded.parent_id,name=excluded.name,markdown=excluded.markdown,pdf_path=excluded.pdf_path,revision=excluded.revision,local_generation=working_documents.local_generation+1,state=excluded.state,purge_at=excluded.purge_at,status=excluded.status,annotations_json=excluded.annotations_json,metadata_json=excluded.metadata_json,assets_json=excluded.assets_json,pdf_blob_id=excluded.pdf_blob_id,updated_at=excluded.updated_at
            """, arguments: [doc.id,doc.kind.rawValue,doc.parentId,doc.name,doc.markdown,doc.pdfPath,doc.revision,doc.localGeneration,doc.state,doc.purgeAt.map { ISO8601DateFormatter().string(from: $0) },doc.status.rawValue,doc.annotationsJSON,ISO8601DateFormatter().string(from: Date()),doc.metadataJSON,doc.assetsJSON,doc.pdfBlobId])
        if let batch = snapshot["trashBatchId"] {
            try db.execute(sql: "UPDATE working_documents SET trash_batch_id=? WHERE id=?", arguments: [batch.string,doc.id])
        }
        try reindex(doc, db: db)
        return doc
    }

    func rewriteMutableTail(_ doc: LibraryDocument, db: Database) throws {
        let payload = encodePayload(doc)
        if let operation = try String.fetchOne(db, sql: "SELECT operation_id FROM pending_operations WHERE object_id=? AND state='pending' AND request_json IS NULL ORDER BY rowid DESC LIMIT 1", arguments: [doc.id]) {
            try db.execute(sql: "UPDATE pending_operations SET payload=? WHERE operation_id=?", arguments: [payload, operation])
        } else {
            try db.execute(sql: "INSERT INTO pending_operations(operation_id,action,object_id,payload,state,created_at) VALUES (?,'updateDocument',?,?,'pending',?)",
                           arguments: [UUID().uuidString.lowercased(),doc.id,payload,ISO8601DateFormatter().string(from: Date())])
        }
    }

    func applyTombstone(_ id: String, db: Database) throws {
        let current = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
        let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND state IN ('pending','awaiting_remote','needs_edit','conflict')", arguments: [id]) ?? 0
        if let current, pending > 0 {
            let base = try String.fetchOne(db, sql: "SELECT snapshot_json FROM remote_documents WHERE id=?", arguments: [id]).flatMap { try JSONValue.parse($0).object } ?? [:]
            try recordConflict(objectId: id, kind: "deleted", base: base, local: current.syncSnapshot, remote: ["id": .string(id),"state": .string("purged")], revision: current.revision, db: db)
        } else {
            try db.execute(sql: "DELETE FROM working_documents WHERE id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM search_chunks WHERE object_id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM search_index_state WHERE object_id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM search_fts WHERE object_id=?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM remote_documents WHERE id=?", arguments: [id])
        try db.execute(sql: "INSERT OR REPLACE INTO remote_tombstones(id,deleted_at) VALUES (?,?)", arguments: [id,ISO8601DateFormatter().string(from: Date())])
    }
}
