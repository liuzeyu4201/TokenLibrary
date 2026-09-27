import Foundation
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class CatalogActionFeedbackTests: XCTestCase {
    private func storeAndSource() throws -> (DocumentStore, LibraryDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-feedback-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root)
        let source = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .md, parentId: "root", name: "source.md", markdown: "quote",
            pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]")
        try store.saveDocument(source, enqueue: false)
        return (store, source)
    }

    func testCommittedExcerptStaysSuccessfulWhenUIReadFailsAndOnlyRefreshNeedsRetry() throws {
        let (store, source) = try storeAndSource(), id = UUID().uuidString.lowercased()
        let result = try CatalogActionFeedback.save({
            try store.createCatalogNote(sourceID: source.id, quote: "quote", noteID: id)
        }, refresh: { throw CocoaError(.fileReadNoPermission) })
        XCTAssertEqual(result.value.id, id)
        XCTAssertNotNil(result.refreshError)
        XCTAssertEqual(try store.loadDocument(id: id)?.catalog.excerpts.count, 1)
        let pending = try store.pending()
        // The visible refresh action performs only a read, never another write.
        XCTAssertNotNil(try store.loadDocument(id: source.id))
        XCTAssertEqual(try store.pending(), pending)
        XCTAssertEqual(try store.catalogBacklinks(to: source.id).count, 1)
    }

    func testWriteFailureNeverRefreshesAndOriginalIntentCanRetryOnce() throws {
        let (store, source) = try storeAndSource(), id = UUID().uuidString.lowercased()
        var refreshed = false
        try store.db.write { try $0.execute(sql: "CREATE TRIGGER reject_feedback_queue BEFORE INSERT ON pending_operations BEGIN SELECT RAISE(ABORT,'injected disk failure'); END") }
        XCTAssertThrowsError(try CatalogActionFeedback.save({
            try store.createCatalogNote(sourceID: source.id, quote: "quote", noteID: id)
        }, refresh: { refreshed = true }))
        XCTAssertFalse(refreshed); XCTAssertNil(try store.loadDocument(id: id)); XCTAssertTrue(try store.pending().isEmpty)
        try store.db.write { try $0.execute(sql: "DROP TRIGGER reject_feedback_queue") }
        let result = try CatalogActionFeedback.save({
            try store.createCatalogNote(sourceID: source.id, quote: "quote", noteID: id)
        }, refresh: { refreshed = true })
        XCTAssertEqual(result.value.id, id); XCTAssertNil(result.refreshError); XCTAssertTrue(refreshed)
        XCTAssertEqual(try store.pending().count, 1)
    }
}
