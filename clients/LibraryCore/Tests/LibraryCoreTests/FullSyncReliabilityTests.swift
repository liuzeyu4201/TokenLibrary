import Foundation
import GRDB
import XCTest
@testable import LibraryCore

final class FullSyncReliabilityTests: XCTestCase, @unchecked Sendable {
    private let epoch = "epoch-one"
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("full-sync-\(UUID().uuidString)") }
    private func snapshot(id: String = UUID().uuidString.lowercased(), revision: Int64 = 1, body: String = "alpha\nbeta\ngamma", parent: String = "root", kind: String = "md", name: String = "笔记.md", pdfBlobId: String? = nil) -> DocumentSnapshot {
        var value: DocumentSnapshot = ["id": .string(id), "revision": .integer(revision), "kind": .string(kind), "name": .string(name), "parentId": .string(parent), "state": .string("active"), "markdownSource": .string(body), "metadata": .object([:]), "assets": .array([])]
        if let pdfBlobId { value["pdfBlobId"] = .string(pdfBlobId) }
        return value
    }
    private func response(_ data: DocumentSnapshot) throws -> String { try JSONValue.object(["data": .object(data)]).jsonString() }
    private func page(_ items: [DocumentSnapshot], id: String, cursor: Int64, more: Bool, at: Int64 = 42, libraryEpoch: String? = nil) -> DocumentSnapshot {
        ["snapshotId": .string(id), "epoch": .string(libraryEpoch ?? epoch), "atSeq": .integer(at), "items": .array(items.map(JSONValue.object)), "nextCursor": .string(String(cursor)), "hasMore": .bool(more)]
    }
    private func freeze(_ store: DocumentStore) throws -> PendingOperation {
        try XCTUnwrap(store.prepareOperation(XCTUnwrap(store.pending().first).operationId, epoch: epoch, deviceId: "device", serverOrigin: "https://library.invalid"))
    }

    func testBootstrapPagesCommitTogetherAndResumeAfterFailure() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), first = snapshot(), second = snapshot()
        let id = UUID().uuidString.lowercased()
        let broken = TestConnection([.http(200, try response(page([first], id: id, cursor: 1, more: true))), .http(410, "{}")])
        do { _ = try await broken.client.bootstrap(store: store, epoch: epoch); XCTFail("expired page must fail") } catch {}
        XCTAssertEqual(try store.listDocuments().count, 0)
        XCTAssertEqual(store.syncCursor, 0)
        XCTAssertNil(try store.syncValue("initialized"))
        let healthy = TestConnection([.http(200, try response(page([first], id: id, cursor: 1, more: true))), .http(200, try response(page([second], id: id, cursor: 2, more: false)))])
        let count = try await healthy.client.bootstrap(store: store, epoch: epoch)
        XCTAssertEqual(count, 2); XCTAssertEqual(store.syncCursor, 42)
        XCTAssertEqual(try store.listDocuments().count, 2)
        XCTAssertTrue(healthy.stub.requests[1].url!.query!.contains("after=1"))
        let reopened = try DocumentStore(directory: root)
        XCTAssertEqual(reopened.syncCursor, 42); XCTAssertEqual(try reopened.listDocuments().count, 2)
    }

    func testCatalogPageIsReadableBeforeTheSnapshotFinishesAndSkipsFiles() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root)
        let folder = snapshot(kind: "folder", name: "数学")
        let blob = UUID().uuidString.lowercased()
        let pdf = snapshot(body: "", kind: "pdf", name: "论文.pdf", pdfBlobId: blob)
        let gate = DeferredResponse()
        let id = UUID().uuidString.lowercased()
        let connection = TestConnection([
            .http(200, try response(page([folder], id: id, cursor: 1, more: true))),
            .deferred(gate, 200, try response(page([pdf], id: id, cursor: 2, more: false))),
        ], downloadsBodies: false)
        let task = Task { try await connection.client.bootstrap(store: store, epoch: epoch) }
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(try store.listDocuments().count, 1)
        XCTAssertEqual(store.syncCursor, 0)
        XCTAssertNil(try store.syncValue("initialized"))
        XCTAssertFalse(connection.stub.requests.contains { $0.url?.path.contains("/blobs/") == true })
        gate.release()
        let count = try await task.value
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.syncCursor, 42)
        XCTAssertEqual(try store.syncValue("initialized"), "1")
        XCTAssertNil(try store.loadDocument(id: XCTUnwrap(pdf["id"]?.string))?.pdfPath)
        XCTAssertFalse(connection.stub.requests.contains { $0.url?.path.contains("/blobs/") == true })
    }

    func testCatalogFailureKeepsTheVisiblePageWithoutAdvancingTheCursor() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), first = snapshot()
        let id = UUID().uuidString.lowercased()
        let broken = TestConnection([
            .http(200, try response(page([first], id: id, cursor: 1, more: true))),
            .http(410, "{}"),
        ], downloadsBodies: false)
        do { _ = try await broken.client.bootstrap(store: store, epoch: epoch); XCTFail("expired page must fail") } catch {}
        XCTAssertEqual(try store.listDocuments().count, 1)
        XCTAssertEqual(store.syncCursor, 0)
        XCTAssertNil(try store.syncValue("initialized"))
    }

    func testFullSyncKeepsTheCatalogHiddenUntilTheFileArrives() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root)
        let bytes = Data("pdf-bytes".utf8)
        let blob = UUID().uuidString.lowercased()
        let pdf = snapshot(body: "", kind: "pdf", name: "论文.pdf", pdfBlobId: blob)
        let gate = DeferredResponse()
        let id = UUID().uuidString.lowercased()
        let connection = TestConnection([
            .http(200, try response(page([pdf], id: id, cursor: 1, more: false))),
            .deferred(gate, 200, String(decoding: bytes, as: UTF8.self), ["X-Content-SHA256": BlobIntegrity.sha256(bytes)]),
        ], downloadsBodies: true)
        let task = Task { try await connection.client.bootstrap(store: store, epoch: epoch) }
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertTrue(try store.listDocuments().isEmpty)
        XCTAssertTrue(connection.stub.requests[1].url!.path.contains("/blobs/\(blob)"))
        gate.release()
        let count = try await task.value
        XCTAssertEqual(count, 1)
        let saved = try XCTUnwrap(store.loadDocument(id: XCTUnwrap(pdf["id"]?.string)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(saved.pdfPath))), bytes)
    }

    func testOpenedDocumentDownloadsOnlyItsOwnFile() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), blob = UUID().uuidString.lowercased()
        let bytes = Data("correct".utf8)
        var doc = snapshot()
        doc["assets"] = .array([.object(["blobId": .string(blob), "path": .string("media/\(blob).png"), "sha256": .string(BlobIntegrity.sha256(bytes)), "size": .integer(Int64(bytes.count))])])
        let event: DocumentSnapshot = ["seq": .integer(1), "objects": .array([.object(doc)]), "deletedIds": .array([])]
        let changes: DocumentSnapshot = ["epoch": .string(epoch), "changes": .array([.object(event)]), "nextCursor": .integer(1), "hasMore": .bool(false)]
        let connection = TestConnection([
            .http(200, try response(changes)),
            .http(200, String(decoding: bytes, as: UTF8.self), ["X-Content-SHA256": BlobIntegrity.sha256(bytes)]),
        ], downloadsBodies: false)
        _ = try await connection.client.pullChanges(store: store, epoch: epoch)
        XCTAssertEqual(connection.stub.requests.count, 1)
        let document = try XCTUnwrap(store.loadDocument(id: XCTUnwrap(doc["id"]?.string)))
        let fetched = try await connection.client.downloadOpenedDocument(document, store: store)
        XCTAssertTrue(fetched)
        XCTAssertEqual(connection.stub.requests.count, 2)
        XCTAssertTrue(connection.stub.requests[1].url!.path.contains("/blobs/\(blob)"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.assetURL(id: blob))), bytes)
        let again = try await connection.client.downloadOpenedDocument(document, store: store)
        XCTAssertFalse(again)
        XCTAssertEqual(connection.stub.requests.count, 2)
    }

    func testCatalogEpochRestartKeepsUnsentEdits() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), initial = snapshot(revision: 10)
        let id = try XCTUnwrap(initial["id"]?.string)
        try store.applyRemoteBatch([initial], deletedIds: [], cursor: 100, epoch: epoch, fullSnapshot: true)
        _ = try store.updateMarkdown(id: id, markdown: "unsent before reset")
        _ = try freeze(store)
        let restored = snapshot(id: id, revision: 2, body: "restored archive")
        let connection = TestConnection([
            .http(200, try response(page([restored], id: UUID().uuidString.lowercased(), cursor: 1, more: false, at: 5, libraryEpoch: "epoch-two"))),
        ], downloadsBodies: false)
        let count = try await connection.client.bootstrap(store: store, epoch: "epoch-two")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.syncCursor, 5)
        XCTAssertEqual(try store.remoteSnapshot(id: id)?["revision"]?.int64, 2)
        XCTAssertEqual(try store.loadDocument(id: id)?.markdown, "unsent before reset")
        let conflict = try XCTUnwrap(store.conflicts().first)
        XCTAssertEqual(conflict.kind, "epoch_changed")
        XCTAssertTrue(conflict.remoteJSON.contains("restored archive"))
    }

    func testInvalidDocumentRollsBackWholePageAndCursor() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), first = snapshot()
        var invalid = snapshot(); invalid.removeValue(forKey: "name")
        XCTAssertThrowsError(try store.applyRemoteBatch([first, invalid], deletedIds: [], cursor: 9, epoch: epoch))
        XCTAssertNil(try store.loadDocument(id: XCTUnwrap(first["id"]?.string)))
        XCTAssertEqual(store.syncCursor, 0)
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM remote_documents") }, 0)
    }

    func testTombstonePreservesDirtyContentAndPersistsConflictAfterRestart() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), first = snapshot(), clean = snapshot()
        let id = try XCTUnwrap(first["id"]?.string), cleanID = try XCTUnwrap(clean["id"]?.string)
        try store.applyRemoteBatch([first, clean], deletedIds: [], cursor: 1, epoch: epoch)
        _ = try store.updateMarkdown(id: id, markdown: "offline changes")
        try store.applyRemoteBatch([], deletedIds: [id, cleanID], cursor: 2, epoch: epoch)
        let reopened = try DocumentStore(directory: root)
        XCTAssertEqual(reopened.syncCursor, 2)
        XCTAssertEqual(try reopened.loadDocument(id: id)?.markdown, "offline changes")
        XCTAssertNil(try reopened.loadDocument(id: cleanID))
        XCTAssertEqual(try reopened.conflicts().first?.kind, "deleted")
        XCTAssertEqual(try reopened.db.read { try String.fetchOne($0, sql: "SELECT state FROM pending_operations WHERE object_id=?", arguments: [id]) }, "conflict")
        try reopened.resolveDeletedConflict(XCTUnwrap(reopened.conflicts().first), keepLocal: true, rootId: "recovery-root")
        let recovered = try XCTUnwrap(reopened.listDocuments().first)
        XCTAssertNotEqual(recovered.id, id); XCTAssertEqual(recovered.markdown, "offline changes")
        XCTAssertEqual(recovered.parentId, "recovery-root")
        XCTAssertEqual(try reopened.pending().map(\.action), ["createMarkdown"])
    }

    func testAuthoritativeReceiptRebasesLaterEditOnMergedServerText() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), initial = snapshot()
        let id = try XCTUnwrap(initial["id"]?.string)
        try store.applyRemoteBatch([initial], deletedIds: [], cursor: 1, epoch: epoch)
        _ = try store.updateMarkdown(id: id, markdown: "ALPHA\nbeta\ngamma")
        let sent = try freeze(store)
        _ = try store.updateMarkdown(id: id, markdown: "ALPHA\nBETA\ngamma")
        let remote = snapshot(id: id, revision: 3, body: "ALPHA\nbeta\nGAMMA")
        try store.applyAuthoritativeReceipt(remote, operation: sent, status: "committed")
        XCTAssertEqual(try store.loadDocument(id: id)?.markdown, "ALPHA\nBETA\nGAMMA")
        XCTAssertEqual(try store.loadDocument(id: id)?.revision, 3)
        let next = try freeze(store)
        XCTAssertEqual(next.baseRevision, 3); XCTAssertNotEqual(next.operationId, sent.operationId)
        XCTAssertEqual(try JSONValue.parse(next.payload).object?["markdownSource"]?.string, "ALPHA\nBETA\nGAMMA")
        XCTAssertTrue(try store.conflicts().isEmpty)
    }

    func testOverlappingInflightEditPersistsMaterialsAndResolutionIsFrozen() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), initial = snapshot()
        let id = try XCTUnwrap(initial["id"]?.string)
        try store.applyRemoteBatch([initial], deletedIds: [], cursor: 1, epoch: epoch)
        _ = try store.updateMarkdown(id: id, markdown: "submitted")
        let sent = try freeze(store)
        _ = try store.updateMarkdown(id: id, markdown: "later local")
        let remote = snapshot(id: id, revision: 3, body: "server merged")
        try store.applyAuthoritativeReceipt(remote, operation: sent, status: "committed")
        let reopened = try DocumentStore(directory: root), conflict = try XCTUnwrap(reopened.conflicts().first)
        XCTAssertEqual(conflict.kind, "inflight_merge")
        XCTAssertTrue(conflict.localJSON.contains("later local")); XCTAssertTrue(conflict.remoteJSON.contains("server merged"))
        let selected = try XCTUnwrap(reopened.loadDocument(id: id)).syncSnapshot
        let resolution = try reopened.queueConflictResolution(conflict, selected: selected, latest: remote, epoch: epoch, deviceId: "device", serverOrigin: "https://library.invalid")
        XCTAssertNotNil(resolution.requestJSON); XCTAssertEqual(resolution.baseRevision, 3)
        XCTAssertEqual(resolution.frozenGeneration, try reopened.loadDocument(id: id)?.localGeneration,
                       "Resolving a conflict must freeze the generation actually written, not manufacture a later edit")
        XCTAssertTrue(try reopened.conflicts().first!.state.hasPrefix("resolving:"))
        try reopened.applyAuthoritativeReceipt(snapshot(id: id, revision: 4, body: "later local"), operation: resolution, status: "committed")
        XCTAssertTrue(try reopened.conflicts().isEmpty); XCTAssertTrue(try reopened.isFullySynced(id: id))
    }

    func testEpochResetAcceptsLowerRemoteRevisionAndKeepsOldEditsForResolution() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), initial = snapshot(revision: 10)
        let id = try XCTUnwrap(initial["id"]?.string)
        try store.applyRemoteBatch([initial], deletedIds: [], cursor: 100, epoch: epoch, fullSnapshot: true)
        _ = try store.updateMarkdown(id: id, markdown: "unsent before reset")
        _ = try freeze(store)
        try store.applyRemoteBatch([snapshot(id: id, revision: 2, body: "restored archive")], deletedIds: [], cursor: 5, epoch: "epoch-two", fullSnapshot: true)
        XCTAssertEqual(store.syncCursor, 5)
        XCTAssertEqual(try store.remoteSnapshot(id: id)?["revision"]?.int64, 2)
        XCTAssertEqual(try store.loadDocument(id: id)?.markdown, "unsent before reset")
        XCTAssertEqual(try store.conflicts().first?.kind, "epoch_changed")
    }

    func testAttachmentDownloadRejectsCorruptionAndDoesNotAdvanceCursor() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), blob = UUID().uuidString.lowercased()
        var doc = snapshot()
        doc["assets"] = .array([.object(["blobId": .string(blob), "path": .string("media/\(blob).png"), "sha256": .string(BlobIntegrity.sha256(Data("correct".utf8))), "size": .integer(7)])])
        let event: DocumentSnapshot = ["seq": .integer(1), "objects": .array([.object(doc)]), "deletedIds": .array([])]
        let changes: DocumentSnapshot = ["epoch": .string(epoch), "changes": .array([.object(event)]), "nextCursor": .integer(1), "hasMore": .bool(false)]
        let connection = TestConnection([.http(200, try response(changes)), .http(200, "corrupt", ["X-Content-SHA256": BlobIntegrity.sha256(Data("corrupt".utf8))])])
        do { _ = try await connection.client.pullChanges(store: store, epoch: epoch); XCTFail("corrupt blob must fail") } catch { XCTAssertTrue(error is TransferError) }
        XCTAssertEqual(store.syncCursor, 0); XCTAssertTrue(try store.listDocuments().isEmpty)
        XCTAssertNil(try store.assetURL(id: blob))
    }

    func testUploadResumesRecordedChunksAfterRestartAndHashesRemainingChunk() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), upload = UUID().uuidString.lowercased()
        let bytes = Data(repeating: 65, count: 1_048_576) + Data("last chunk".utf8)
        let asset = try store.importAttachment(data: bytes, fileName: "large.png", mime: "image/png")
        try store.updateTransfer(asset, uploadId: upload, state: "uploading")
        let reopened = try DocumentStore(directory: root)
        let connection = TestConnection([.http(200, try response(["state": .string("uploading"), "chunks": .array([.integer(0)])])), .http(200, "{}"), .http(200, try response(["blobId": .string(asset.blobId), "state": .string("ready")]))])
        try await connection.client.uploadAttachment(asset, store: reopened)
        let requests = connection.stub.requests
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[1].httpMethod, "PUT")
        XCTAssertTrue(requests[1].url!.path.hasSuffix("chunks/1"))
        XCTAssertEqual(requests[1].httpBody, Data("last chunk".utf8))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Chunk-SHA256"), BlobIntegrity.sha256(Data("last chunk".utf8)))
        XCTAssertEqual(try reopened.transfer(blobId: asset.blobId)?.state, "complete")
    }

    func testAttachmentGenerationCheckNeverOverwritesNewerEditorText() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root)
        try store.localSaveOffline(markdown: "old", id: "note", name: "note.md", parentId: "root")
        var prepared = try XCTUnwrap(store.loadDocument(id: "note"))
        prepared.markdown = "rewritten old asset"
        _ = try store.updateMarkdown(id: "note", markdown: "latest typed text")
        XCTAssertFalse(try store.saveDocumentIfCurrent(prepared, expectedGeneration: prepared.localGeneration))
        XCTAssertEqual(try store.loadDocument(id: "note")?.markdown, "latest typed text")
    }

    func testAnnotationDeletionConflictsOnlyWithConcurrentEditAndMetadataNullIsDistinct() {
        let annotation: JSONValue = .object(["id": .string("annotation"), "text": .string("old")])
        let edited: JSONValue = .object(["id": .string("annotation"), "text": .string("new")])
        let base: DocumentSnapshot = ["annotations": .array([annotation]), "metadata": .object(["author": .string("old")])]
        let deleted: DocumentSnapshot = ["annotations": .array([]), "metadata": .object(["author": .null])]
        let unchanged = SnapshotMerger.merge(base: base, local: deleted, remote: base)
        XCTAssertFalse(unchanged.hasConflict); XCTAssertEqual(unchanged.snapshot["annotations"], .array([]))
        let remote: DocumentSnapshot = ["annotations": .array([edited]), "metadata": .object([:])]
        let conflict = SnapshotMerger.merge(base: base, local: deleted, remote: remote)
        XCTAssertTrue(conflict.conflictingFields.contains("annotations.annotation"))
        XCTAssertTrue(conflict.conflictingFields.contains("metadata.author"))
    }

    func testWorkspaceIsolationAndLegacyDocumentDecode() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = LibraryWorkspaceManager(baseDirectory: root), one = URL(string: "https://one.invalid")!, two = URL(string: "https://two.invalid")!
        let first = try manager.store(server: one, libraryId: "library")
        try first.localSaveOffline(markdown: "private to one", id: "note", name: "note.md", parentId: "root")
        XCTAssertTrue(try manager.store(server: two, libraryId: "library").listDocuments().isEmpty)
        XCTAssertTrue(try manager.store(server: one, libraryId: "other-library").listDocuments().isEmpty)
        XCTAssertTrue(try manager.localStore().listDocuments().isEmpty)
        XCTAssertThrowsError(try first.bindWorkspace(server: two.absoluteString, libraryId: "library"))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(first.loadDocument(id: "note")))) as! [String: Any]
        for key in ["metadataJSON", "assetsJSON", "pdfBlobId"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(LibraryDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.metadataJSON, "{}"); XCTAssertEqual(old.assetsJSON, "[]"); XCTAssertNil(old.pdfBlobId)
    }

    func testLegacyAwaitingRemoteRecoversAutomaticallyWithAuthoritativeFetch() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), initial = snapshot()
        let id = try XCTUnwrap(initial["id"]?.string)
        try store.applyRemoteBatch([initial], deletedIds: [], cursor: 1, epoch: epoch)
        _ = try store.updateMarkdown(id: id, markdown: "ALPHA\nbeta\ngamma")
        let remote = snapshot(id: id, revision: 3, body: "ALPHA\nbeta\nGAMMA")
        let connection = TestConnection([.http(200, try response(["snapshot": .object(remote)]))])
        connection.client.epoch = epoch; connection.client.libraryId = "library"
        let queued = try XCTUnwrap(store.pending().first)
        let sent = try XCTUnwrap(store.prepareOperation(queued.operationId, epoch: epoch, deviceId: connection.client.deviceId, serverOrigin: connection.client.baseURL.absoluteString))
        try store.pauseForRemoteFetch(sent)
        let reopened = try DocumentStore(directory: root)
        try await connection.client.flushPending(store: reopened)
        XCTAssertTrue(try reopened.pending().isEmpty)
        XCTAssertEqual(try reopened.loadDocument(id: id)?.markdown, "ALPHA\nbeta\nGAMMA")
        XCTAssertTrue(try reopened.isFullySynced(id: id))
        XCTAssertEqual(connection.stub.requests.map(\.httpMethod), ["GET"])
    }

    func testPulledTrashBatchRestoresChildrenOfflineButPreservesIndependentTrash() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root), folderID = UUID().uuidString.lowercased()
        var folder = snapshot(id: folderID), child = snapshot(parent: folderID), independent = snapshot(parent: folderID)
        folder["kind"] = .string("folder")
        for key in ["state", "trashBatchId"] {
            let value = JSONValue.string(key == "state" ? "trashed" : "shared-batch")
            folder[key] = value; child[key] = value; independent[key] = value
        }
        independent["trashBatchId"] = .string("independent-batch")
        try store.applyRemoteBatch([folder, child, independent], deletedIds: [], cursor: 3, epoch: epoch)
        try store.restore(id: folderID)
        XCTAssertEqual(try store.loadDocument(id: XCTUnwrap(child["id"]?.string))?.state, "active")
        XCTAssertEqual(try store.loadDocument(id: XCTUnwrap(independent["id"]?.string))?.state, "trashed")
    }

    func testNameRejectionSurvivesRestartAndUserRenameCreatesNewOperation() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root)
        try store.localSaveOffline(markdown: "never lose this content", id: "note", name: "taken.md", parentId: "root")
        let connection = TestConnection([.http(409, #"{"error":{"code":"NAME_CONFLICT"}}"#), .http(200, #"{"data":{"status":"committed","revision":"1"}}"#)])
        connection.client.epoch = epoch
        do { try await connection.client.flushPending(store: store); XCTFail("must surface rejected name") }
        catch { XCTAssertEqual(SyncFailure.from(error).serverCode, "NAME_CONFLICT") }
        let rejected = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(rejected.state, "needs_edit")
        let reopened = try DocumentStore(directory: root)
        do { try await connection.client.flushPending(store: reopened); XCTFail("unchanged invalid request must wait for edit") } catch {}
        XCTAssertEqual(connection.stub.requests.count, 1)
        _ = try reopened.renameDocument(id: "note", to: "new name")
        let changed = try XCTUnwrap(reopened.pending().first)
        XCTAssertNotEqual(changed.operationId, rejected.operationId)
        try await connection.client.flushPending(store: reopened)
        XCTAssertEqual(try reopened.loadDocument(id: "note")?.markdown, "never lose this content")
        XCTAssertTrue(try reopened.isFullySynced(id: "note"))
        XCTAssertNotEqual(connection.stub.requests[0].value(forHTTPHeaderField: "Idempotency-Key"), connection.stub.requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testIndependentReadingPositionsMergeByDeviceAndExcerptsByID() {
        let base: DocumentSnapshot = ["metadata": .object(["readingPositions": .array([]), "excerpts": .array([])])]
        let a: JSONValue = .object(["deviceID": .string("a"), "pageIndex": .integer(2)])
        let b: JSONValue = .object(["deviceID": .string("b"), "pageIndex": .integer(5)])
        let excerpt: JSONValue = .object(["id": .string("quote"), "quote": .string("source")])
        let local: DocumentSnapshot = ["metadata": .object(["readingPositions": .array([a]), "excerpts": .array([excerpt])])]
        let remote: DocumentSnapshot = ["metadata": .object(["readingPositions": .array([b]), "excerpts": .array([])])]
        let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
        XCTAssertFalse(result.hasConflict)
        XCTAssertEqual(result.snapshot["metadata"]?.object?["readingPositions"]?.array?.count, 2)
        XCTAssertEqual(result.snapshot["metadata"]?.object?["excerpts"]?.array, [excerpt])
    }
}
