import Foundation
import XCTest
@testable import LibraryCore

final class TrashRecoveryTests: XCTestCase {
    private func store() throws -> DocumentStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("trash-recovery-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return try DocumentStore(directory: path)
    }
    private func document(_ name: String, parent: String = "root", kind: DocKind = .md) -> LibraryDocument {
        LibraryDocument(id: UUID().uuidString.lowercased(), kind: kind, parentId: parent, name: name, markdown: kind == .folder ? "" : "preserved body", pdfPath: nil,
            revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
    }

    func testSelectedSubtreeRestoresToRootWithoutRestoringParentSiblingOrOlderTrash() throws {
        let store = try store(), outer = document("outer", kind: .folder)
        let nested = document("nested", parent: outer.id, kind: .folder), sibling = document("sibling.md", parent: outer.id)
        let leaf = document("leaf.md", parent: nested.id), old = document("old.md", parent: nested.id)
        for item in [outer, nested, sibling, leaf, old] { try store.saveDocument(item, enqueue: false) }
        try store.trash(id: old.id); try store.trash(id: outer.id)
        try store.restore(id: nested.id)
        XCTAssertEqual(try store.loadDocument(id: nested.id)?.parentId, "root")
        XCTAssertEqual(try store.loadDocument(id: nested.id)?.state, "active")
        XCTAssertEqual(try store.loadDocument(id: leaf.id)?.state, "active")
        XCTAssertEqual(try store.loadDocument(id: leaf.id)?.parentId, nested.id)
        for id in [outer.id, sibling.id, old.id] { XCTAssertEqual(try store.loadDocument(id: id)?.state, "trashed") }
        XCTAssertEqual(try store.search(query: "preserved"), [leaf.id])
        try store.restore(id: outer.id)
        XCTAssertEqual(try store.loadDocument(id: sibling.id)?.state, "active")
        XCTAssertEqual(try store.loadDocument(id: old.id)?.state, "trashed")
        XCTAssertEqual(try store.loadDocument(id: nested.id)?.parentId, "root")
    }

    func testRestoreNameCollisionUsesSuffixInLocalStateAndDurableRequest() throws {
        let store = try store(), item = document("Paper.md")
        try store.saveDocument(item, enqueue: false); try store.trash(id: item.id)
        try store.saveDocument(document("PAPER.md"), enqueue: false)
        try store.saveDocument(document("Paper_1.md"), enqueue: false)
        try store.restore(id: item.id)
        XCTAssertEqual(try store.loadDocument(id: item.id)?.name, "Paper_2.md")
        let operation = try XCTUnwrap(store.pending().last)
        let payload = try JSONValue.parse(operation.payload).object
        XCTAssertEqual(operation.action, "restore")
        XCTAssertEqual(payload?["parentId"]?.string, "root")
        XCTAssertEqual(payload?["name"]?.string, "Paper_2.md")
        let pending = try store.pending()
        try store.restore(id: item.id)
        XCTAssertEqual(try store.pending(), pending)
    }

    func testMissingParentUsesBoundRootButDoesNotGuessMixedLegacyRoot() throws {
        let bound = try store(), rootID = UUID().uuidString.lowercased()
        try bound.bindWorkspace(server: "https://example.invalid", libraryId: "library", rootId: rootID)
        var orphan = document("orphan.md", parent: UUID().uuidString.lowercased())
        orphan.state = "trashed"; orphan.purgeAt = Date().addingTimeInterval(60)
        try bound.saveDocument(orphan, enqueue: false)
        try bound.restore(id: orphan.id)
        XCTAssertEqual(try bound.loadDocument(id: orphan.id)?.parentId, rootID)
        let mixed = try store()
        try mixed.registerLegacyLibraryRoot(rootID: UUID().uuidString.lowercased())
        try mixed.saveDocument(orphan, enqueue: false)
        XCTAssertThrowsError(try mixed.restore(id: orphan.id))
        XCTAssertEqual(try mixed.loadDocument(id: orphan.id)?.state, "trashed")
        XCTAssertTrue(try mixed.pending().isEmpty)
    }

    func testExpiredOrForeignRootRestoreLeavesDocumentsUntouched() throws {
        let store = try store(), rootID = UUID().uuidString.lowercased()
        try store.bindWorkspace(server: "https://example.invalid", libraryId: "library", rootId: rootID)
        var foreignRoot = document("foreign", parent: "", kind: .folder)
        foreignRoot.state = "active"
        var item = document("foreign.md", parent: foreignRoot.id)
        item.state = "trashed"; item.purgeAt = Date().addingTimeInterval(60)
        try store.saveDocument(foreignRoot, enqueue: false); try store.saveDocument(item, enqueue: false)
        let savedItem = try store.loadDocument(id: item.id)
        XCTAssertThrowsError(try store.restore(id: item.id))
        var expired = document("expired.md", parent: rootID)
        expired.state = "trashed"; expired.purgeAt = Date().addingTimeInterval(-60)
        try store.saveDocument(expired, enqueue: false)
        let savedExpired = try store.loadDocument(id: expired.id)
        XCTAssertThrowsError(try store.restore(id: expired.id))
        XCTAssertEqual(try store.loadDocument(id: item.id), savedItem)
        XCTAssertEqual(try store.loadDocument(id: expired.id), savedExpired)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testQueueFailureRollsBackEntireRestoredSubtree() throws {
        let store = try store(), folder = document("folder", kind: .folder), leaf: LibraryDocument
        leaf = document("leaf.md", parent: folder.id)
        try store.saveDocument(folder, enqueue: false); try store.saveDocument(leaf, enqueue: false)
        try store.trash(id: folder.id)
        let before = try store.listDocuments(includeTrashed: true), pending = try store.pending()
        try store.db.write { try $0.execute(sql: "CREATE TRIGGER fail_restore BEFORE INSERT ON pending_operations WHEN NEW.action='restore' BEGIN SELECT RAISE(ABORT,'disk failure'); END") }
        XCTAssertThrowsError(try store.restore(id: folder.id))
        XCTAssertEqual(try store.listDocuments(includeTrashed: true), before)
        XCTAssertEqual(try store.pending(), pending)
    }
}
