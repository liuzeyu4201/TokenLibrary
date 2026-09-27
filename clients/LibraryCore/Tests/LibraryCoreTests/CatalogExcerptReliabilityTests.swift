import Foundation
import XCTest
@testable import LibraryCore

final class CatalogExcerptReliabilityTests: XCTestCase {
    private func fixture() throws -> (DocumentStore, LibraryDocument, LibraryDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("excerpt-reliability-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(directory: root)
        func document(_ kind: DocKind, _ name: String) -> LibraryDocument {
            LibraryDocument(id: UUID().uuidString.lowercased(), kind: kind, parentId: "root", name: name, markdown: "original", pdfPath: nil,
                revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]")
        }
        let source = document(.pdf, "source.pdf"), note = document(.md, "note.md")
        try store.saveDocument(source, enqueue: false); try store.saveDocument(note, enqueue: false)
        return (store, source, note)
    }

    func testStableExcerptIDRejectsDifferentPayloadWithoutChangingBodyMetadataOrQueue() throws {
        let (store, source, note) = try fixture()
        let saved = try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "quote", comment: "comment", pageIndex: 2, fileHash: "original-hash", excerptID: "stable")
        let pending = try store.pending()
        let variations: [(String, String, String, Int?, String?)] = [
            ("different-source", "quote", "comment", 2, "original-hash"),
            (source.id, "changed quote", "comment", 2, "original-hash"),
            (source.id, "quote", "changed comment", 2, "original-hash"),
            (source.id, "quote", "comment", nil, "original-hash"),
            (source.id, "quote", "comment", 2, "different-hash")
        ]
        for (sourceID, quote, comment, page, hash) in variations {
            XCTAssertThrowsError(try store.appendCatalogExcerpt(noteID: note.id, sourceID: sourceID, quote: quote, comment: comment, pageIndex: page, fileHash: hash, excerptID: "stable")) { error in
                guard case CatalogError.excerptOperationConflict = error else { return XCTFail("Wrong error: \(error)") }
            }
            XCTAssertEqual(try store.loadDocument(id: note.id), saved)
            XCTAssertEqual(try store.pending(), pending)
        }
    }

    func testNewNoteStableIDRejectsDifferentExplicitFileVersion() throws {
        let (store, source, _) = try fixture(), id = UUID().uuidString.lowercased()
        let saved = try store.createCatalogNote(sourceID: source.id, quote: "quote", pageIndex: 1, fileHash: "version-one", noteID: id)
        let pending = try store.pending()
        XCTAssertThrowsError(try store.createCatalogNote(sourceID: source.id, quote: "quote", pageIndex: 1, fileHash: "version-two", noteID: id)) { error in
            guard case CatalogError.excerptOperationConflict = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try store.loadDocument(id: id), saved)
        XCTAssertEqual(try store.pending(), pending)
    }

    func testAutoCapturedVersionIsReusedAfterSourceDisappears() throws {
        let (store, original, note) = try fixture()
        let url = store.root.appendingPathComponent("original.pdf")
        try PDFExport.makeSamplePDF(text: "source excerpt").write(to: url)
        var source = original; source.pdfPath = url.path; try store.saveDocument(source, enqueue: false)
        let appended = try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "quote", pageIndex: 0, excerptID: "stable")
        let created = try store.createCatalogNote(sourceID: source.id, quote: "quote", pageIndex: 0, noteID: "stable-note")
        XCTAssertNotNil(appended.catalog.excerpts.first?.fileHash)
        try FileManager.default.removeItem(at: url); try store.trash(id: source.id)
        let pending = try store.pending()
        XCTAssertEqual(try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "quote", pageIndex: 0, excerptID: "stable"), appended)
        XCTAssertEqual(try store.createCatalogNote(sourceID: source.id, quote: "quote", pageIndex: 0, noteID: "stable-note"), created)
        XCTAssertEqual(try store.pending(), pending)
    }

    func testFailedQueueWriteRollsBackExcerptAndSameIDRetryCommitsOnce() throws {
        let (store, source, note) = try fixture()
        try store.db.write { try $0.execute(sql: "CREATE TRIGGER reject_excerpt_queue BEFORE INSERT ON pending_operations BEGIN SELECT RAISE(ABORT,'injected disk write failure'); END") }
        XCTAssertThrowsError(try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "quote", excerptID: "stable"))
        XCTAssertEqual(try store.loadDocument(id: note.id)?.markdown, "original")
        XCTAssertTrue(try store.loadDocument(id: note.id)?.catalog.excerpts.isEmpty == true)
        XCTAssertTrue(try store.pending().isEmpty)
        try store.db.write { try $0.execute(sql: "DROP TRIGGER reject_excerpt_queue") }
        _ = try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "quote", excerptID: "stable")
        _ = try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "quote", excerptID: "stable")
        XCTAssertEqual(try store.loadDocument(id: note.id)?.catalog.excerpts.count, 1)
        XCTAssertEqual(try store.pending().count, 1)
    }
}
