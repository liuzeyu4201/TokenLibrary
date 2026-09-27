import Foundation
import GRDB
import XCTest
@testable import LibraryCore

final class MissingObjectConflictTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let directory: URL
        let store: DocumentStore
        let id: String
        let rootID: String
        let oldOperation: PendingOperation
        let body: String
        let media: LibraryAsset
    }

    private func fixture(connection: TestConnection) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-epoch-\(UUID())")
        let store = try DocumentStore(directory: directory)
        let id = UUID().uuidString.lowercased(), rootID = UUID().uuidString.lowercased()
        let media = try store.importAttachment(data: Data("synthetic image bytes".utf8), fileName: "image.png", mime: "image/png")
        let root: DocumentSnapshot = ["id": .string(rootID), "kind": .string("folder"), "name": .string("Root"), "parentId": .string(""), "revision": .integer(1), "state": .string("active")]
        let doc = LibraryDocument(id: id, kind: .md, parentId: rootID, name: "备份后新增.md", markdown: "原文\n\n![合成图](\(media.path))\n", pdfPath: nil, revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]", metadataJSON: #"{"category":"note","unknown":{"keep":true}}"#, assetsJSON: try JSONValue.array([.object(["blobId": .string(media.blobId), "path": .string(media.path), "sha256": .string(media.sha256), "size": .integer(media.size)])]).jsonString())
        try store.applyRemoteBatch([root, doc.syncSnapshot], deletedIds: [], cursor: 2, epoch: "before", fullSnapshot: true)
        let body = doc.markdown + "本机完整输入 🧪\n"
        _ = try store.updateMarkdown(id: id, markdown: body)
        let operation = try XCTUnwrap(store.prepareOperation(XCTUnwrap(store.pending().first).operationId, epoch: "before", deviceId: connection.client.deviceId, serverOrigin: connection.client.baseURL.absoluteString))
        try store.applyRemoteBatch([root], deletedIds: [], cursor: 1, epoch: "restored", fullSnapshot: true)
        connection.client.sessionToken = "synthetic-token"
        connection.client.epoch = "restored"
        connection.client.rootId = rootID
        // No libraryId: these transport tests use a minimal valid receipt. The real
        // PG/HTTP restore probe covers authenticated attachment preparation/receipt.
        return Fixture(directory: directory, store: store, id: id, rootID: rootID, oldOperation: operation, body: body, media: media)
    }

    private func assertHistory(_ f: Fixture, state: String) throws {
        let row = try XCTUnwrap(f.store.db.read { try Row.fetchOne($0, sql: "SELECT * FROM pending_operations WHERE operation_id=?", arguments: [f.oldOperation.operationId]) })
        XCTAssertEqual(row["state"] as String, state)
        XCTAssertEqual(row["request_json"] as String?, f.oldOperation.requestJSON)
        XCTAssertEqual(row["payload"] as String, f.oldOperation.payload)
        XCTAssertEqual(try Data(contentsOf: f.store.resolveAttachment(path: f.media.path)), Data("synthetic image bytes".utf8))
        let materials = try f.store.db.read { try String.fetchAll($0, sql: "SELECT local_json FROM sync_conflicts WHERE object_id=?", arguments: [f.id]) }
        XCTAssertFalse(materials.isEmpty)
        for material in materials { XCTAssertEqual(try JSONValue.parse(material).object?["markdownSource"]?.string, f.body) }
    }

    func testFormalMissing404RecoversLocalAsNewObjectAndKeepsFrozenHistory() async throws {
        let connection = TestConnection([.http(404, #"{"error":{"code":"NOT_FOUND","message":"object"}}"#), .http(200, #"{"data":{"status":"committed","revision":"1"}}"#)])
        let f = try fixture(connection: connection); defer { try? FileManager.default.removeItem(at: f.directory) }
        let conflicts = try f.store.conflicts()
        XCTAssertEqual(Set(conflicts.map(\.kind)), ["epoch_changed", "deleted"])
        try await connection.client.resolveConflict(XCTUnwrap(conflicts.first { $0.kind == "epoch_changed" }), resolution: .local, store: f.store)
        XCTAssertNil(try f.store.loadDocument(id: f.id))
        let copy = try XCTUnwrap(f.store.listDocuments().first { $0.kind == .md })
        XCTAssertNotEqual(copy.id, f.id); XCTAssertEqual(copy.markdown, f.body)
        XCTAssertEqual(copy.parentId, f.rootID)
        XCTAssertTrue(copy.metadataJSON.contains("unknown")); XCTAssertTrue(copy.assetsJSON.contains(f.media.blobId))
        XCTAssertTrue(try f.store.conflicts().isEmpty); XCTAssertTrue(try f.store.pending().isEmpty)
        try assertHistory(f, state: "superseded")
        XCTAssertEqual(connection.stub.requests.map(\.httpMethod), ["GET", "POST"])
        let wire = try JSONValue.parse(String(decoding: XCTUnwrap(connection.stub.requests.last?.httpBody), as: UTF8.self)).object
        XCTAssertEqual(wire?["action"]?.string, "createMarkdown")
        XCTAssertEqual(wire?["epoch"]?.string, "restored")
        XCTAssertEqual(wire?["objectId"]?.string, copy.id)
        XCTAssertNotEqual(wire?["operationId"]?.string, f.oldOperation.operationId)
    }

    func testFormalMissing404RemoteChoiceResolvesAllMaterialsWithoutSendingOldRequest() async throws {
        let connection = TestConnection([.http(404, #"{"error":{"code":"NOT_FOUND"}}"#)])
        let f = try fixture(connection: connection); defer { try? FileManager.default.removeItem(at: f.directory) }
        try await connection.client.resolveConflict(XCTUnwrap(f.store.conflicts().first { $0.kind == "deleted" }), resolution: .remote, store: f.store)
        XCTAssertNil(try f.store.loadDocument(id: f.id))
        XCTAssertTrue(try f.store.conflicts().isEmpty); XCTAssertTrue(try f.store.pending().isEmpty)
        XCTAssertEqual(connection.stub.requests.count, 1)
        try assertHistory(f, state: "superseded")
    }

    func testUnconfirmed404AndStaleEpochPreserveEveryLocalMaterial() async throws {
        for scenario in ["proxy", "other-code", "wrong-epoch", "remote-present"] {
            let response = scenario == "proxy" ? "<html>Not Found</html>" : scenario == "other-code" ? #"{"error":{"code":"OTHER"}}"# : #"{"error":{"code":"NOT_FOUND"}}"#
            let connection = TestConnection([.http(404, response)])
            let f = try fixture(connection: connection); defer { try? FileManager.default.removeItem(at: f.directory) }
            let conflict = try XCTUnwrap(f.store.conflicts().first)
            if scenario == "wrong-epoch" { connection.client.epoch = "another" }
            if scenario == "remote-present" {
                let snapshot = try XCTUnwrap(f.store.loadDocument(id: f.id)).syncSnapshot
                try await f.store.db.write { db in try f.store.writeRemote(snapshot, db: db) }
            }
            let before = try f.store.conflicts()
            do { try await connection.client.resolveConflict(conflict, resolution: .local, store: f.store); XCTFail("\(scenario) must not classify absence") }
            catch { XCTAssertEqual(SyncFailure.from(error).statusCode, 404, scenario) }
            XCTAssertEqual(try f.store.loadDocument(id: f.id)?.markdown, f.body, scenario)
            XCTAssertEqual(try f.store.conflicts(), before, scenario)
            XCTAssertEqual(connection.stub.requests.count, 1, scenario)
            try assertHistory(f, state: "conflict")
        }
    }

    func testMissingCustomCopyPersistsAcrossFailedUploadAndReopen() async throws {
        let connection = TestConnection([.http(404, #"{"error":{"code":"NOT_FOUND"}}"#), .http(503, #"{"error":{"code":"BUSY"}}"#)], cancelSleep: true)
        let f = try fixture(connection: connection); defer { try? FileManager.default.removeItem(at: f.directory) }
        let merged = f.body + "明确自定义合并\n"
        do { try await connection.client.resolveConflict(XCTUnwrap(f.store.conflicts().first), resolution: .customMarkdown(merged), store: f.store); XCTFail("503 upload must remain pending") }
        catch {}
        let reopened = try DocumentStore(directory: f.directory)
        let copy = try XCTUnwrap(reopened.listDocuments().first { $0.kind == .md })
        XCTAssertEqual(copy.markdown, merged)
        XCTAssertNotEqual(copy.id, f.id)
        XCTAssertEqual(try reopened.pending().map(\.objectId), [copy.id])
        XCTAssertEqual(try reopened.pending().first?.action, "createMarkdown")
        XCTAssertTrue(try reopened.conflicts().isEmpty)
        try assertHistory(f, state: "superseded")
    }
}
