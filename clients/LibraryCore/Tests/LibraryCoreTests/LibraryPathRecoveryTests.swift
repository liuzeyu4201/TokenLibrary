import XCTest
import GRDB
@testable import LibraryCore

final class LibraryPathRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-relocation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func open(_ root: URL) throws -> DocumentStore {
        try DocumentStore(directory: root, pdfPageTextExtractor: { data in [String(decoding: data, as: UTF8.self)] })
    }

    private func pdf(_ store: DocumentStore, id: String = "paper", registered: Bool = true) throws -> LibraryDocument {
        let bytes = Data("Relocated searchable source \(id)".utf8)
        let path: String, blob: String?
        if registered {
            let asset = try store.importAttachment(data: bytes, fileName: "source.pdf", mime: "application/pdf")
            path = try store.resolveAttachment(path: asset.path).path; blob = asset.blobId
        } else {
            path = store.root.appendingPathComponent(id + ".pdf").path; blob = nil
            try bytes.write(to: URL(fileURLWithPath: path))
        }
        let doc = LibraryDocument(id: id, kind: .pdf, parentId: "root", name: id + ".pdf", markdown: "", pdfPath: path,
            revision: 7, localGeneration: 12, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]",
            metadataJSON: "{\"custom\":\"preserve\"}", pdfBlobId: blob)
        try store.saveDocument(doc, enqueue: false)
        return try XCTUnwrap(store.loadDocument(id: id))
    }

    private func move(_ store: DocumentStore, to root: URL) throws -> DocumentStore {
        try store.db.close()
        try FileManager.default.moveItem(at: store.root, to: root)
        return try open(root)
    }

    func testSandboxUpgradeRestoresPDFSearchAndPreservesFrozenQueueAndDocumentIdentity() throws {
        let parent = try directory(), store = try open(parent.appendingPathComponent("old-container"))
        var document = try pdf(store)
        document.annotationsJSON = "[{\"id\":\"retained\"}]"
        try store.saveDocument(document, enqueue: true)
        try store.db.write { db in
            try db.execute(sql: "UPDATE pending_operations SET request_json='frozen-request',request_origin='https://example.invalid',base_revision=7,frozen_generation=13")
        }
        document = try XCTUnwrap(store.loadDocument(id: document.id))
        let queue = try store.pending(), transfer = try XCTUnwrap(store.transfer(blobId: XCTUnwrap(document.pdfBlobId)))
        let relocated = try move(store, to: parent.appendingPathComponent("new-container"))
        var expected = document; expected.pdfPath = relocated.root.appendingPathComponent(transfer.asset.path).path
        XCTAssertEqual(try relocated.loadDocument(id: document.id), expected)
        XCTAssertEqual(try relocated.pending(), queue)
        XCTAssertEqual(try relocated.transfer(blobId: transfer.asset.blobId)?.state, transfer.state)
        XCTAssertTrue(try FileManager.default.isReadableFile(atPath: XCTUnwrap(relocated.assetURL(id: transfer.asset.blobId)).path))
        XCTAssertEqual(try relocated.searchCoverage().waitingDownload, 0)
        XCTAssertEqual(try relocated.searchCoverage().searchableText, 1)
        XCTAssertEqual(try relocated.search(query: "searchable"), [document.id])
        let again = try open(relocated.root)
        XCTAssertEqual(try again.loadDocument(id: document.id), expected)
        XCTAssertEqual(try again.pending(), queue)
    }

    func testLegacyLibraryWithoutMarkerRecoversFromRegisteredBlobAndRepairsMissingSearchIndex() throws {
        let parent = try directory(), store = try open(parent.appendingPathComponent("old"))
        let registered = try pdf(store), local = try pdf(store, id: "unprepared", registered: false)
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM sync_state WHERE key='local.library_root_path'")
            try db.execute(sql: "DELETE FROM search_chunks WHERE source LIKE 'pdf:%'")
            try db.execute(sql: "DELETE FROM search_fts WHERE source LIKE 'pdf:%'")
        }
        let relocated = try move(store, to: parent.appendingPathComponent("new"))
        XCTAssertEqual(try relocated.searchCoverage().searchableText, 2)
        XCTAssertEqual(try relocated.loadDocument(id: local.id)?.pdfPath, relocated.root.appendingPathComponent("unprepared.pdf").path)
        XCTAssertTrue(try XCTUnwrap(relocated.loadDocument(id: registered.id)?.pdfPath).hasPrefix(relocated.root.path + "/"))
        XCTAssertTrue(try relocated.pending().isEmpty)
    }

    func testRootMarkerHandlesUnuploadedPDFAndRepeatedMoves() throws {
        let parent = try directory(), store = try open(parent.appendingPathComponent("first"))
        let document = try pdf(store, registered: false)
        let second = try move(store, to: parent.appendingPathComponent("second"))
        let third = try move(second, to: parent.appendingPathComponent("third"))
        XCTAssertEqual(try third.loadDocument(id: document.id)?.pdfPath, third.root.appendingPathComponent("paper.pdf").path)
        XCTAssertEqual(try third.searchCoverage().searchableText, 1)
        XCTAssertTrue(try third.pending().isEmpty)
    }

    func testOldVersionDraftAfterSourcePurgeStillRecoversCorrectFileAfterMove() throws {
        let parent = try directory(), store = try open(parent.appendingPathComponent("old"))
        let document = try pdf(store, registered: false)
        let annotation = PDFTextAnnotation(id: "a", type: "comment", pageIndex: 0, x: 1, y: 1, width: 10, height: 10, color: "#FFFF00", text: "retained old edition")
        try store.db.write { db in try db.execute(sql: "DELETE FROM working_documents WHERE id=?", arguments: [document.id]) }
        XCTAssertThrowsError(try store.savePDFAnnotationEdit(id: document.id, expectedPDFBlobId: nil,
            expectedPDFPath: document.pdfPath, base: [], proposed: [annotation]))
        let before = try XCTUnwrap(store.editorDrafts().first)
        let relocated = try move(store, to: parent.appendingPathComponent("new"))
        let draft = try XCTUnwrap(relocated.editorDrafts().first)
        XCTAssertEqual(draft.id, before.id); XCTAssertEqual(draft.createdAt, before.createdAt)
        XCTAssertEqual(draft.updatedAt, before.updatedAt); XCTAssertEqual(draft.proposedAnnotations, before.proposedAnnotations)
        XCTAssertEqual(draft.expectedPDFPath, relocated.root.appendingPathComponent("paper.pdf").path)
        let recovered = try relocated.recoverEditorDraftAsCopy(id: draft.id, parentId: "root")
        XCTAssertEqual(recovered.pdfPath, draft.expectedPDFPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(recovered.pdfPath))), Data("Relocated searchable source paper".utf8))
        XCTAssertNil(try relocated.loadDocument(id: document.id))
    }

    func testRecoveryDoesNotReadSymlinkEscapesOrGuessExternalFileBasenames() throws {
        let parent = try directory(), store = try open(parent.appendingPathComponent("old"))
        let missing = try pdf(store, id: "missing", registered: false)
        let escaped = try pdf(store, id: "escaped", registered: false)
        let outside = parent.appendingPathComponent("outside.pdf")
        try Data("private external source".utf8).write(to: outside)
        try FileManager.default.removeItem(atPath: XCTUnwrap(missing.pdfPath))
        try FileManager.default.removeItem(atPath: XCTUnwrap(escaped.pdfPath))
        try FileManager.default.createSymbolicLink(atPath: XCTUnwrap(escaped.pdfPath), withDestinationPath: outside.path)
        var external = escaped; external.id = "external"; external.pdfPath = outside.path
        try store.saveDocument(external, enqueue: false)
        let relocated = try move(store, to: parent.appendingPathComponent("new"))
        XCTAssertEqual(try relocated.loadDocument(id: missing.id)?.pdfPath, missing.pdfPath)
        XCTAssertEqual(try relocated.loadDocument(id: escaped.id)?.pdfPath, escaped.pdfPath)
        XCTAssertEqual(try relocated.loadDocument(id: external.id)?.pdfPath, outside.path)
        XCTAssertEqual(try relocated.searchCoverage().waitingDownload, 2)
        XCTAssertTrue(try relocated.pending().isEmpty)
    }

    func testReplacementPDFAndRecoverableOldVersionRemainDistinctAfterUpgrade() throws {
        let parent = try directory(), store = try open(parent.appendingPathComponent("old"))
        let old = try pdf(store)
        let newerAsset = try store.importAttachment(data: Data("new edition".utf8), fileName: "new.pdf", mime: "application/pdf")
        var current = old; current.pdfBlobId = newerAsset.blobId
        current.pdfPath = try store.resolveAttachment(path: newerAsset.path).path
        try store.saveDocument(current, enqueue: false)
        let annotation = PDFTextAnnotation(id: "a", type: "comment", pageIndex: 0, x: 1, y: 1, width: 10, height: 10, color: "#FFFF00", text: "old edition only")
        XCTAssertThrowsError(try store.savePDFAnnotationEdit(id: old.id, expectedPDFBlobId: old.pdfBlobId,
            expectedPDFPath: old.pdfPath, base: [], proposed: [annotation]))
        try store.db.write { db in try db.execute(sql: "DELETE FROM sync_state WHERE key='local.library_root_path'") }
        let relocated = try move(store, to: parent.appendingPathComponent("new"))
        let draft = try XCTUnwrap(relocated.editorDrafts().first)
        XCTAssertEqual(draft.originalDocument?.pdfPath, draft.expectedPDFPath)
        XCTAssertEqual(draft.originalDocument?.pdfBlobId, old.pdfBlobId)
        let copy = try relocated.recoverEditorDraftAsCopy(id: draft.id, parentId: "root")
        XCTAssertEqual(copy.pdfBlobId, old.pdfBlobId)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(copy.pdfPath))), Data("Relocated searchable source paper".utf8))
        let latest = try XCTUnwrap(relocated.loadDocument(id: old.id))
        XCTAssertEqual(latest.pdfBlobId, newerAsset.blobId); XCTAssertEqual(latest.annotationsJSON, "[]")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(latest.pdfPath))), Data("new edition".utf8))
    }

    func testSameBlobIDInTwoLibrariesNeverUsesOtherLibraryFile() throws {
        let parent = try directory(), oldContainer = parent.appendingPathComponent("old")
        let first = try open(oldContainer.appendingPathComponent("library-A"))
        let second = try open(oldContainer.appendingPathComponent("library-B"))
        let blob = UUID().uuidString.lowercased(), path = "media/shared.pdf"
        for (store, text) in [(first, "alpha library only"), (second, "beta library only")] {
            let data = Data(text.utf8)
            let asset = LibraryAsset(blobId: blob, path: path, sha256: BlobIntegrity.sha256(data), size: Int64(data.count), mime: "application/pdf")
            try store.installAttachment(data: data, asset: asset)
            let document = LibraryDocument(id: "paper", kind: .pdf, parentId: "root", name: "paper.pdf", markdown: "",
                pdfPath: try store.resolveAttachment(path: path).path, revision: 3, localGeneration: 1, state: "active",
                purgeAt: nil, status: .synced, annotationsJSON: "[]", pdfBlobId: blob)
            try store.saveDocument(document, enqueue: false)
            try store.db.write { db in try db.execute(sql: "DELETE FROM sync_state WHERE key='local.library_root_path'") }
            try store.db.close()
        }
        let newContainer = parent.appendingPathComponent("new")
        try FileManager.default.moveItem(at: oldContainer, to: newContainer)
        for (name, expected, absent) in [("library-A", "alpha library only", "beta"), ("library-B", "beta library only", "alpha")] {
            let store = try open(newContainer.appendingPathComponent(name))
            let document = try XCTUnwrap(store.loadDocument(id: "paper"))
            XCTAssertEqual(document.pdfPath, store.root.appendingPathComponent(path).path)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(document.pdfPath))), Data(expected.utf8))
            XCTAssertTrue(try store.search(query: absent).isEmpty)
            XCTAssertEqual(try store.searchCoverage().searchableText, 1)
            XCTAssertTrue(try store.pending().isEmpty)
        }
    }
}
