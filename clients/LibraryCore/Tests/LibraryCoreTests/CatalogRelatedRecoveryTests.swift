import Foundation
import XCTest
@testable import LibraryCore

final class CatalogRelatedRecoveryTests: XCTestCase {
    private func fixture() throws -> (DocumentStore, LibraryDocument, LibraryDocument, LibraryDocument) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-relations-trash-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        func document(_ name: String, parent: String = "root", kind: DocKind = .md) throws -> LibraryDocument {
            let doc = LibraryDocument(id: UUID().uuidString.lowercased(), kind: kind, parentId: parent, name: name,
                markdown: "原文正文\n", pdfPath: nil, revision: 4, localGeneration: 0, state: "active", purgeAt: nil,
                status: .synced, annotationsJSON: "[]", metadataJSON: #"{"future":{"keep":true},"category":"note"}"#)
            try store.saveDocument(doc, enqueue: false)
            return doc
        }
        let active = try document("active.md"), folder = try document("Folder", kind: .folder)
        var target = try document("target.md", parent: folder.id), source = active
        func relatedJSON(_ ids: [String]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["future": ["keep": true], "category": "note", "relatedIDs": ids]), as: UTF8.self)
        }
        target.metadataJSON = try relatedJSON([source.id])
        source.metadataJSON = try relatedJSON([target.id, "already-purged"])
        try store.saveDocument(target, enqueue: false); try store.saveDocument(source, enqueue: false)
        return (store, source, target, folder)
    }

    func testRemovingLegacyReverseEdgeFromTrashedChildIsAtomicAndDoesNotRestoreOrLoseUnknownMetadata() throws {
        let (store, source, target, folder) = try fixture()
        try store.trash(id: folder.id)
        let before = try XCTUnwrap(store.loadDocument(id: target.id))
        _ = try store.setCatalogRelated(id: source.id, targetID: target.id, included: false)
        let after = try XCTUnwrap(store.loadDocument(id: target.id))
        XCTAssertEqual(after.state, "trashed"); XCTAssertEqual(after.purgeAt, before.purgeAt)
        XCTAssertEqual(after.parentId, before.parentId); XCTAssertEqual(after.name, before.name); XCTAssertEqual(after.markdown, before.markdown)
        XCTAssertTrue(after.catalog.relatedIDs.isEmpty)
        XCTAssertEqual(try store.loadDocument(id: source.id)?.catalog.relatedIDs, ["already-purged"])
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(after.metadataJSON.utf8)) as? [String: Any])
        XCTAssertEqual((raw["future"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(try store.pending().filter { $0.objectId == target.id }.map(\.action), ["updateDocument"])
        try store.restore(id: folder.id)
        XCTAssertEqual(try store.loadDocument(id: target.id)?.state, "active")
        XCTAssertFalse(try store.relatedCatalogDocuments(to: source.id).contains { $0.id == target.id })
        _ = try store.setCatalogRelated(id: source.id, targetID: "already-purged", included: false)
        XCTAssertTrue(try XCTUnwrap(store.loadDocument(id: source.id)).catalog.relatedIDs.isEmpty)
    }

    func testFrozenTrashEnvelopeIsPreservedAndRemovalQueuesAfterIt() throws {
        let (store, source, target, _) = try fixture()
        try store.trash(id: target.id)
        let trash = try XCTUnwrap(store.pending().first { $0.action == "trash" })
        let frozen = try XCTUnwrap(store.prepareOperation(trash.operationId, epoch: "epoch", deviceId: "device", serverOrigin: "https://example.test"))
        _ = try store.setCatalogRelated(id: source.id, targetID: target.id, included: false)
        let operations = try store.pending().filter { $0.objectId == target.id }
        XCTAssertEqual(operations.map(\.action), ["trash", "updateDocument"])
        XCTAssertEqual(operations[0].requestJSON, frozen.requestJSON)
        XCTAssertEqual(operations[0].payload, frozen.payload)
        XCTAssertNil(try store.prepareOperation(operations[1].operationId, epoch: "epoch", deviceId: "device", serverOrigin: "https://example.test"))
        XCTAssertEqual(try JSONValue.parse(operations[1].payload).object?["state"]?.string, "trashed")
    }

    func testQueueFailureRollsBackBothDirectionsIncludingTrashedTarget() throws {
        let (store, source, target, folder) = try fixture()
        try store.trash(id: folder.id)
        let beforeSource = try store.loadDocument(id: source.id), beforeTarget = try store.loadDocument(id: target.id), beforeQueue = try store.pending()
        try store.db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_related_source BEFORE INSERT ON pending_operations WHEN NEW.object_id='\(source.id)' BEGIN SELECT RAISE(ABORT,'write failure'); END")
        }
        XCTAssertThrowsError(try store.setCatalogRelated(id: source.id, targetID: target.id, included: false))
        XCTAssertEqual(try store.loadDocument(id: source.id), beforeSource)
        XCTAssertEqual(try store.loadDocument(id: target.id), beforeTarget)
        XCTAssertEqual(try store.pending(), beforeQueue)
    }
}
