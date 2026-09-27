import Foundation
import GRDB
import XCTest
@testable import LibraryCore

final class QueueReliabilityTests: XCTestCase, @unchecked Sendable {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
    }

    private func create(_ store: DocumentStore, id: String = "object", parent: String = "root", body: String = "first") throws {
        try store.localSaveOffline(markdown: body, id: id, name: "note.md", parentId: parent)
    }

    private func freeze(_ store: DocumentStore, _ id: String) throws -> PendingOperation {
        try XCTUnwrap(store.prepareOperation(id, epoch: "epoch", deviceId: "device", serverOrigin: "https://library.invalid"))
    }

    func testMutableTailCoalescesButFrozenPayloadAndBaseNeverChange() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        let firstID = try XCTUnwrap(store.pending().first?.operationId)
        _ = try store.updateMarkdown(id: "object", markdown: "before send")
        XCTAssertEqual(try store.pending().count, 1)
        XCTAssertEqual(try store.pending().first?.operationId, firstID)
        let frozen = try freeze(store, firstID)
        _ = try store.updateMarkdown(id: "object", markdown: "new edit")
        let secondID = try XCTUnwrap(store.pending().last?.operationId)
        XCTAssertNotEqual(secondID, firstID)
        _ = try store.updateMarkdown(id: "object", markdown: "latest edit")
        XCTAssertEqual(try store.pending().count, 2)
        XCTAssertEqual(try store.pending().last?.operationId, secondID)
        XCTAssertEqual(try freeze(store, firstID), frozen)

        try store.acknowledge(frozen, revision: 1, conflict: false)
        XCTAssertEqual(try store.loadDocument(id: "object")?.markdown, "latest edit")
        XCTAssertEqual(try store.loadDocument(id: "object")?.status, .pending)
        XCTAssertEqual(try store.pending().count, 1)
        let next = try freeze(store, secondID)
        XCTAssertEqual(next.action, "updateDocument")
        XCTAssertEqual(next.baseRevision, 1)
        XCTAssertTrue(next.payload.contains("latest edit"))

        try store.acknowledge(next, revision: 2, conflict: false)
        // A delayed duplicate receipt must not lower revision or change the later completion.
        try store.acknowledge(frozen, revision: 1, conflict: false)
        XCTAssertTrue(try store.isFullySynced(id: "object"))
        XCTAssertEqual(try store.loadDocument(id: "object")?.revision, 2)
    }

    func testFrozenUpdateSurvivesRestartWithExactBaseAndWireBytes() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        var store: DocumentStore? = try DocumentStore(directory: path)
        try create(store!)
        let created = try freeze(store!, XCTUnwrap(store!.pending().first?.operationId))
        try store!.acknowledge(created, revision: 5, conflict: false)
        _ = try store!.updateMarkdown(id: "object", markdown: "update")
        let frozen = try freeze(store!, XCTUnwrap(store!.pending().first?.operationId))
        XCTAssertEqual(frozen.baseRevision, 5)
        _ = try store!.updateMarkdown(id: "object", markdown: "after timeout")
        store = nil
        let reopened = try DocumentStore(directory: path)
        let replay = try freeze(reopened, frozen.operationId)
        XCTAssertEqual(replay, frozen)
        XCTAssertEqual(replay.baseRevision, 5)
        XCTAssertEqual(try reopened.pending().count, 2)
        XCTAssertEqual(try reopened.loadDocument(id: "object")?.markdown, "after timeout")
    }

    func testStaleUIRevisionCannotDowngradeAcknowledgedRevision() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        var staleSnapshot = try XCTUnwrap(store.loadDocument(id: "object"))
        let frozen = try freeze(store, XCTUnwrap(store.pending().first?.operationId))
        try store.acknowledge(frozen, revision: 5, conflict: false)
        staleSnapshot.markdown = "edited from stale UI"
        try store.saveDocument(staleSnapshot, enqueue: true)
        XCTAssertEqual(try store.loadDocument(id: "object")?.revision, 5)
        let next = try freeze(store, XCTUnwrap(store.pending().first?.operationId))
        XCTAssertEqual(next.action, "updateDocument")
        XCTAssertEqual(next.baseRevision, 5)
    }

    func testFrozenOperationRejectsDifferentEpochOriginOrDevice() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        let frozen = try freeze(store, XCTUnwrap(store.pending().first?.operationId))
        for (epoch, device, origin) in [("other", "device", "https://library.invalid"), ("epoch", "other", "https://library.invalid"), ("epoch", "device", "https://other.invalid")] {
            XCTAssertThrowsError(try store.prepareOperation(frozen.operationId, epoch: epoch, deviceId: device, serverOrigin: origin)) { error in
                XCTAssertEqual(SyncFailure.from(error).kind, .conflict)
            }
        }
        XCTAssertEqual(try freeze(store, frozen.operationId), frozen)
    }

    func testStaleUnfrozenReceiptCannotClearChangedDraft() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        let old = try XCTUnwrap(store.pending().first)
        _ = try store.updateMarkdown(id: "object", markdown: "newer")
        XCTAssertThrowsError(try store.acknowledge(old, revision: 1, conflict: false))
        XCTAssertEqual(try store.pending().count, 1)
        XCTAssertEqual(try store.loadDocument(id: "object")?.markdown, "newer")
    }

    func testConflictBlocksLaterOperationAndRemainsVisibleAfterFurtherEdits() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        let frozen = try freeze(store, XCTUnwrap(store.pending().first?.operationId))
        _ = try store.updateMarkdown(id: "object", markdown: "later")
        let later = try XCTUnwrap(store.pending().last)
        try store.acknowledge(frozen, revision: 3, conflict: true)
        XCTAssertNil(try store.prepareOperation(later.operationId, epoch: "epoch", deviceId: "device", serverOrigin: "https://library.invalid"))
        _ = try store.updateMarkdown(id: "object", markdown: "still local")
        XCTAssertEqual(try store.loadDocument(id: "object")?.status, .conflict)
        XCTAssertFalse(try store.isFullySynced(id: "object"))
    }

    func testTrashRestoreBoundaryPreservesOperationOrder() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        try store.trash(id: "object")
        try store.restore(id: "object")
        _ = try store.updateMarkdown(id: "object", markdown: "restored edit")
        let queue = try store.pending()
        XCTAssertEqual(queue.map(\.action), ["createMarkdown", "trash", "restore", "createMarkdown"])
        XCTAssertTrue(queue[0].payload.contains("first"))
        XCTAssertTrue(queue[3].payload.contains("restored edit"))
        XCTAssertNil(try store.prepareOperation(queue[3].operationId, epoch: "epoch", deviceId: "device", serverOrigin: "https://library.invalid"))
    }

    func testV1MigrationPreservesDocumentsAndPendingOperations() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        var store: DocumentStore? = try DocumentStore(directory: path)
        try create(store!, body: "existing v1 document")
        let operationID = try XCTUnwrap(store!.pending().first?.operationId)
        // Reproduce the original v1 schema with real persisted content, then reopen through the migrator.
        try store!.db.write { db in
            try db.execute(sql: """
                DROP INDEX pending_by_object_state;
                ALTER TABLE pending_operations DROP COLUMN base_revision;
                ALTER TABLE pending_operations DROP COLUMN request_json;
                ALTER TABLE pending_operations DROP COLUMN request_origin;
                ALTER TABLE pending_operations DROP COLUMN frozen_generation;
                DELETE FROM grdb_migrations WHERE identifier='v2-frozen-operations';
                """)
        }
        store = nil
        let migrated = try DocumentStore(directory: path)
        XCTAssertEqual(try migrated.loadDocument(id: "object")?.markdown, "existing v1 document")
        XCTAssertEqual(try migrated.pending().first?.operationId, operationID)
        XCTAssertNotNil(try freeze(migrated, operationID).requestJSON)
    }

    func testParentChainIsolationHandlesTrashMissingParentsAndCycles() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store, id: "folder", parent: "remote-root")
        try create(store, id: "remote-note", parent: "folder")
        try create(store, id: "local-note", parent: "root")
        try create(store, id: "missing", parent: "unknown")
        try create(store, id: "cycle-a", parent: "cycle-b")
        try create(store, id: "cycle-b", parent: "cycle-a")
        try store.trash(id: "remote-note")
        XCTAssertTrue(try store.belongsToRoot(objectId: "remote-note", rootId: "remote-root"))
        for id in ["local-note", "missing", "cycle-a", "cycle-b"] {
            XCTAssertFalse(try store.belongsToRoot(objectId: id, rootId: "remote-root"))
        }
        XCTAssertFalse(try store.belongsToRoot(objectId: "local-note", rootId: ""))
    }

    func testEditDuringSuspendedHTTPSubmitKeepsNewOperationPending() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        let gate = DeferredResponse()
        let connection = TestConnection([.deferred(gate, 200, #"{"data":{"status":"committed","revision":"1"}}"#),
                                         .http(200, #"{"data":{"status":"committed","revision":"2"}}"#)])
        connection.client.epoch = "epoch"
        let first = Task { try await connection.client.flushPending(store: store) }
        await fulfillment(of: [gate.started], timeout: 3)
        _ = try store.updateMarkdown(id: "object", markdown: "typed while sending")
        XCTAssertEqual(try store.pending().count, 2)
        gate.release()
        try await first.value
        XCTAssertEqual(try store.loadDocument(id: "object")?.markdown, "typed while sending")
        XCTAssertEqual(try store.loadDocument(id: "object")?.status, .pending)
        XCTAssertEqual(try store.pending().count, 1)
        try await connection.client.flushPending(store: store)
        XCTAssertTrue(try store.isFullySynced(id: "object"))
        let requests = connection.stub.requests
        XCTAssertNotEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        let secondBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(secondBody["action"] as? String, "updateDocument")
        XCTAssertEqual((secondBody["base"] as? [String: Any])?["revision"] as? Int, 1)
    }

    func testCreateInFlightThenMoveAndEditSendsMoveWithLatestBody() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store)
        let gate = DeferredResponse()
        let connection = TestConnection([.deferred(gate, 200, #"{"data":{"status":"committed","revision":"1"}}"#),
                                         .http(200, #"{"data":{"status":"committed","revision":"2"}}"#)])
        connection.client.epoch = "epoch"
        let first = Task { try await connection.client.flushPending(store: store) }
        await fulfillment(of: [gate.started], timeout: 3)
        var moved = try XCTUnwrap(store.loadDocument(id: "object"))
        moved.parentId = "target-folder"
        try store.saveDocument(moved, enqueue: true)
        _ = try store.updateMarkdown(id: "object", markdown: "body after move")
        gate.release()
        try await first.value
        try await connection.client.flushPending(store: store)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(connection.stub.requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "move")
        let desired = try XCTUnwrap(body["desiredSnapshot"] as? [String: Any])
        XCTAssertEqual(desired["parentId"] as? String, "target-folder")
        XCTAssertEqual(desired["markdownSource"] as? String, "body after move")
        XCTAssertTrue(try store.isFullySynced(id: "object"))
    }

    func testFolderRenameDuringCreationBecomesRename() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        let folder = LibraryDocument(id: "folder", kind: .folder, parentId: "root", name: "old", markdown: "", pdfPath: nil,
                                     revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
        try store.saveDocument(folder, enqueue: true)
        let first = try freeze(store, XCTUnwrap(store.pending().first?.operationId))
        _ = try store.renameDocument(id: "folder", to: "new")
        try store.acknowledge(first, revision: 1, conflict: false)
        let next = try freeze(store, XCTUnwrap(store.pending().first?.operationId))
        XCTAssertEqual(next.action, "rename")
        XCTAssertEqual(next.baseRevision, 1)
        XCTAssertTrue(next.payload.contains("new"))
    }

    func testMoveIntentSurvivesContentAndRenameWithoutPriorFrozenSnapshot() throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        var document = LibraryDocument(id: "object", kind: .md, parentId: "root", name: "old.md", markdown: "old", pdfPath: nil,
                                       revision: 3, localGeneration: 0, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
        try store.saveDocument(document, enqueue: false)
        document.parentId = "target"
        try store.saveDocument(document, enqueue: true)
        _ = try store.renameDocument(id: "object", to: "new")
        _ = try store.updateMarkdown(id: "object", markdown: "new body")
        let operation = try freeze(store, XCTUnwrap(store.pending().first?.operationId))
        XCTAssertEqual(operation.action, "move")
        XCTAssertTrue(operation.payload.contains("target"))
        XCTAssertTrue(operation.payload.contains("new.md"))
        XCTAssertTrue(operation.payload.contains("new body"))
    }

    func testUnknownRemoteMergePausesWithoutAcknowledgingAndSurvivesRestart() async throws {
        for (status, revision) in [("committed", 5), ("no_change", 4)] {
            let path = directory()
            defer { try? FileManager.default.removeItem(at: path) }
            var store: DocumentStore? = try DocumentStore(directory: path)
            try create(store!)
            let created = try freeze(store!, XCTUnwrap(store!.pending().first?.operationId))
            try store!.acknowledge(created, revision: 3, conflict: false)
            _ = try store!.updateMarkdown(id: "object", markdown: "local edit")
            let first = try freeze(store!, XCTUnwrap(store!.pending().first?.operationId))
            _ = try store!.updateMarkdown(id: "object", markdown: "later local edit")
            let connection = TestConnection([])
            XCTAssertThrowsError(try connection.client.applyFlushResult(["data": ["status": status, "revision": revision]], op: first, store: store!)) { error in
                XCTAssertEqual(SyncFailure.from(error).kind, .remoteStateRequired)
                XCTAssertTrue(SyncFailure.from(error).isRetryable) // Full sync now fetches authority and safely resumes.
            }
            XCTAssertEqual(try store!.loadDocument(id: "object")?.revision, 3)
            XCTAssertEqual(try store!.loadDocument(id: "object")?.markdown, "later local edit")
            XCTAssertFalse(try store!.isFullySynced(id: "object"))
            store = nil
            let reopened = try DocumentStore(directory: path)
            let pending = try reopened.pending()
            XCTAssertEqual(pending.count, 2)
            XCTAssertEqual(pending.first?.state, "awaiting_remote")
            XCTAssertEqual(pending.first?.requestJSON, first.requestJSON)
            XCTAssertNil(try reopened.prepareOperation(pending[1].operationId, epoch: "epoch", deviceId: "device", serverOrigin: "https://library.invalid"))
            do {
                try await connection.client.flushPending(store: reopened)
                XCTFail("must stay paused")
            } catch { XCTAssertEqual(SyncFailure.from(error).kind, .remoteStateRequired) }
            XCTAssertEqual(connection.stub.requests.count, 0)
        }
    }

    func test503AndRestartResendExactFrozenEnvelope() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        var store: DocumentStore? = try DocumentStore(directory: path)
        try create(store!)
        let connection = TestConnection([.http(503, "{}", ["Retry-After": "30"]), .http(200, #"{"data":{"status":"committed","revision":"1"}}"#)])
        connection.client.epoch = "epoch"
        do {
            try await connection.client.flushPending(store: store!)
            XCTFail("expected maintenance")
        } catch { XCTAssertEqual(SyncFailure.from(error).kind, .serviceUnavailable) }
        let wire = try XCTUnwrap(store!.pending().first?.requestJSON)
        store = nil
        let reopened = try DocumentStore(directory: path)
        let resumedClient = SyncClient(baseURL: connection.client.baseURL, deviceId: connection.client.deviceId, session: connection.session)
        resumedClient.epoch = "epoch"
        try await resumedClient.flushPending(store: reopened)
        XCTAssertEqual(connection.stub.requests.count, 2)
        XCTAssertEqual(connection.stub.requests.first?.httpBody, connection.stub.requests.last?.httpBody)
        XCTAssertEqual(connection.stub.requests.last?.httpBody, Data(wire.utf8))
        XCTAssertTrue(try reopened.isFullySynced(id: "object"))
    }

    func testCancellationAndOfflineFailureKeepFrozenRequestForRetry() async throws {
        for code in [URLError.Code.cancelled, .notConnectedToInternet] {
            let path = directory()
            defer { try? FileManager.default.removeItem(at: path) }
            let store = try DocumentStore(directory: path)
            try create(store)
            let connection = TestConnection([.error(URLError(code)), .http(200, #"{"data":{"status":"committed","revision":"1"}}"#)])
            let client = SyncClient(baseURL: connection.client.baseURL, deviceId: "device", session: connection.session, retryPolicy: .none)
            client.epoch = "epoch"
            do {
                try await client.flushPending(store: store)
                XCTFail("expected failure")
            } catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(SyncFailure.from(error).kind, .offline) }
            }
            let frozen = try XCTUnwrap(store.pending().first)
            XCTAssertNotNil(frozen.requestJSON)
            XCTAssertEqual(try store.loadDocument(id: "object")?.status, .pending)
            try await client.flushPending(store: store)
            XCTAssertEqual(connection.stub.requests.first?.httpBody, connection.stub.requests.last?.httpBody)
            XCTAssertEqual(connection.stub.requests.last?.value(forHTTPHeaderField: "Idempotency-Key"), frozen.operationId)
            XCTAssertTrue(try store.isFullySynced(id: "object"))
        }
    }

    func testFilteredFlushLeavesOtherRootUntouched() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try DocumentStore(directory: path)
        try create(store, id: "local-note", parent: "root")
        try create(store, id: "remote-note", parent: "remote-root")
        let connection = TestConnection([.http(200, #"{"data":{"status":"committed","revision":"1","objectId":"remote-note"}}"#)])
        connection.client.epoch = "epoch"
        try await connection.client.flushPending(store: store, rootId: "remote-root")
        XCTAssertEqual(connection.stub.requests.count, 1)
        let remaining = try store.pending()
        XCTAssertEqual(remaining.map(\.objectId), ["local-note"])
        XCTAssertNil(remaining.first?.requestJSON)
        XCTAssertTrue(try store.isFullySynced(id: "remote-note"))
    }
}
