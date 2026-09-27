import Foundation
import GRDB
import PDFKit
import XCTest
@testable import LibraryCore

final class PDFTextCacheTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func extract(_ data: Data) -> [String] {
            lock.withLock { count += 1 }
            guard let pdf = PDFDocument(data: data) else { return [] }
            return (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        }
        var value: Int { lock.withLock { count } }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-text-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func open(_ root: URL, _ counter: Counter) throws -> DocumentStore {
        try DocumentStore(directory: root, pdfPageTextExtractor: { counter.extract($0) })
    }
    private func pdf(_ store: DocumentStore, id: String = "paper", text: String = "OriginalCacheAnchor") throws -> LibraryDocument {
        let asset = try store.importAttachment(data: PDFExport.makeSamplePDF(text: text), fileName: "paper.pdf", mime: "application/pdf")
        let doc = LibraryDocument(id: id, kind: .pdf, parentId: "root", name: id + ".pdf", markdown: "",
            pdfPath: try store.resolveAttachment(path: asset.path).path, revision: 7, localGeneration: 0,
            state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]", metadataJSON: "{\"custom\":{\"kept\":true}}", pdfBlobId: asset.blobId)
        try store.saveDocument(doc, enqueue: false)
        return try XCTUnwrap(store.loadDocument(id: id))
    }
    private func cacheCount(_ store: DocumentStore) throws -> Int {
        try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pdf_page_text_cache")! }
    }
    private func chunkIDs(_ store: DocumentStore) throws -> [Int64] {
        try store.db.read { try Int64.fetchAll($0, sql: "SELECT id FROM search_chunks ORDER BY id") }
    }

    func testRepeatedContainerMovesReusePagesAndPreserveFrozenQueueAndIndex() throws {
        let parent = try directory(), counter = Counter()
        var store = try open(parent.appendingPathComponent("first"), counter)
        var original = try pdf(store)
        try store.saveDocument(original, enqueue: true)
        try store.db.write { try $0.execute(sql: "UPDATE pending_operations SET request_json='frozen',request_origin='https://example.invalid',frozen_generation=1") }
        original = try XCTUnwrap(store.loadDocument(id: original.id))
        let queue = try store.pending(), rows = try chunkIDs(store)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(original.pdfPath)))
        for index in 1...3 {
            let oldRoot = store.root, next = parent.appendingPathComponent("container-\(index)")
            try store.db.close(); try FileManager.default.moveItem(at: oldRoot, to: next)
            store = try open(next, counter)
            let current = try XCTUnwrap(store.loadDocument(id: original.id))
            var expected = original; expected.pdfPath = current.pdfPath
            XCTAssertEqual(current, expected)
            XCTAssertEqual(try store.pending(), queue)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(current.pdfPath))), bytes)
            XCTAssertEqual(counter.value, 1, "Container paths do not change PDF content identity")
            XCTAssertEqual(try cacheCount(store), 1)
            XCTAssertEqual(try chunkIDs(store), rows, "Relocation does not rewrite unchanged FTS rows")
            XCTAssertEqual(try store.search(query: "OriginalCacheAnchor"), [original.id])
        }
    }

    func testFileMtimeSizeAndBlobChangesInvalidateWhileMetadataReusesPages() throws {
        let root = try directory(), counter = Counter(), store = try open(root, counter)
        var doc = try pdf(store)
        let path = URL(fileURLWithPath: try XCTUnwrap(doc.pdfPath))
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path.path)
        try store.saveDocument(doc, enqueue: false)
        XCTAssertEqual(counter.value, 2)
        doc.pdfBlobId = UUID().uuidString.lowercased()
        try store.saveDocument(doc, enqueue: false)
        XCTAssertEqual(counter.value, 3)
        try PDFExport.makeSamplePDF(text: "ReplacementCacheAnchor with changed byte size").write(to: path)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path.path)
        try store.saveDocument(doc, enqueue: false)
        XCTAssertEqual(counter.value, 4, "Size changes must invalidate even with the old timestamp")
        doc.name = "renamed.pdf"
        try store.saveDocument(doc, enqueue: false)
        XCTAssertEqual(counter.value, 4)
        XCTAssertEqual(try cacheCount(store), 1, "Old file-version caches have no remaining references")
        XCTAssertEqual(try store.search(query: "ReplacementCacheAnchor"), [doc.id])
        XCTAssertTrue(try store.search(query: "OriginalCacheAnchor").isEmpty)
    }

    func testSharedCacheSurvivesOnePurgeAndDraftRecoveryDoesNotNeedHistoricalCache() throws {
        let root = try directory(), counter = Counter(), store = try open(root, counter)
        let first = try pdf(store, id: "first")
        var second = first; second.id = "second"; second.name = "second.pdf"
        try store.saveDocument(second, enqueue: false)
        XCTAssertEqual(counter.value, 1)
        try store.trash(id: first.id)
        XCTAssertEqual(try store.purgeExpired(now: Date().addingTimeInterval(100 * 86_400)), 1)
        XCTAssertEqual(try cacheCount(store), 1, "The other document still references these pages")
        try store.trash(id: second.id)
        let annotation = PDFTextAnnotation(id: "retained", type: "comment", pageIndex: 0, x: 1, y: 1, width: 20, height: 10, color: "#FFFF00", text: "Recovered after purge")
        XCTAssertThrowsError(try store.savePDFAnnotationEdit(id: second.id, expectedPDFBlobId: second.pdfBlobId,
            expectedPDFPath: second.pdfPath, base: [], proposed: [annotation]))
        let draft = try XCTUnwrap(store.editorDrafts().first)
        XCTAssertEqual(try store.purgeExpired(now: Date().addingTimeInterval(100 * 86_400)), 1)
        XCTAssertEqual(try cacheCount(store), 0, "Unreferenced extracted text is disposable")
        XCTAssertEqual(try store.editorDrafts().first, draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(second.pdfPath)))
        let copy = try store.recoverEditorDraftAsCopy(id: draft.id, parentId: "root")
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(try cacheCount(store), 1)
        XCTAssertEqual(try store.search(query: "OriginalCacheAnchor"), [copy.id])
        XCTAssertEqual(try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(copy.annotationsJSON.utf8)), [annotation])
    }

    func testIdenticalRelativePathBlobSizeAndMtimeAreIsolatedByLibrary() throws {
        let parent = try directory(), counter = Counter()
        let blob = UUID().uuidString.lowercased(), relative = "media/shared.pdf"
        let bodies = [PDFExport.makeSamplePDF(text: "LibraryAlpha"), PDFExport.makeSamplePDF(text: "LibraryBravo")]
        XCTAssertEqual(bodies[0].count, bodies[1].count)
        for index in 0...1 {
            let store = try open(parent.appendingPathComponent("library-\(index)"), counter)
            let body = bodies[index]
            let asset = LibraryAsset(blobId: blob, path: relative, sha256: BlobIntegrity.sha256(body), size: Int64(body.count), mime: "application/pdf")
            try store.installAttachment(data: body, asset: asset)
            let path = try store.resolveAttachment(path: relative)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: path.path)
            let doc = LibraryDocument(id: "same", kind: .pdf, parentId: "root", name: "same.pdf", markdown: "", pdfPath: path.path,
                revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]", pdfBlobId: blob)
            try store.saveDocument(doc, enqueue: false)
            XCTAssertEqual(try store.search(query: index == 0 ? "LibraryAlpha" : "LibraryBravo"), [doc.id])
            XCTAssertTrue(try store.search(query: index == 0 ? "LibraryBravo" : "LibraryAlpha").isEmpty)
        }
        XCTAssertEqual(counter.value, 2)
    }

    func testRelocationRepairsMissingSearchRowsUsingCachedTextWithoutExtractingAgain() throws {
        let parent = try directory(), counter = Counter(), old = parent.appendingPathComponent("old")
        var store = try open(old, counter)
        let doc = try pdf(store)
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM search_chunks WHERE source LIKE 'pdf:%'")
            try db.execute(sql: "DELETE FROM search_fts WHERE source LIKE 'pdf:%'")
        }
        let moved = parent.appendingPathComponent("moved")
        try store.db.close(); try FileManager.default.moveItem(at: old, to: moved)
        store = try open(moved, counter)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try cacheCount(store), 1)
        XCTAssertEqual(try store.search(query: "OriginalCacheAnchor"), [doc.id])
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_chunks WHERE source='pdf:0'") }, 1)
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_fts WHERE source='pdf:0'") }, 1)
    }

    func testTemporaryDirectoryAliasAndUnavailableOriginalKeepCacheReferencesAccurate() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("pdf-cache-alias-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        var store = try open(root, counter)
        let doc = try pdf(store)
        let path = URL(fileURLWithPath: try XCTUnwrap(doc.pdfPath))
        let bytes = try Data(contentsOf: path)
        let rows = try chunkIDs(store)
        try store.db.close()
        store = try open(URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")), counter)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try chunkIDs(store), rows)
        try FileManager.default.removeItem(at: path)
        try store.saveDocument(doc, enqueue: false)
        XCTAssertEqual(try cacheCount(store), 0)
        XCTAssertTrue(try store.search(query: "OriginalCacheAnchor").isEmpty)
        try bytes.write(to: path)
        try store.saveDocument(doc, enqueue: false)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(try cacheCount(store), 1)
        XCTAssertEqual(try store.search(query: "OriginalCacheAnchor"), [doc.id])
    }

    func testLegacyOpaqueCacheIsRebuiltOnceAndOrphansAreRemoved() throws {
        let parent = try directory(), counter = Counter(), root = parent.appendingPathComponent("old")
        var store = try open(root, counter)
        let doc = try pdf(store)
        try store.db.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS pdf_page_text_cache_refs")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v11-stable-pdf-text-cache'")
            try db.execute(sql: "UPDATE pdf_page_text_cache SET identity='legacy-opaque-absolute-path-key'")
            try db.execute(sql: "INSERT INTO pdf_page_text_cache(identity,pages_json) VALUES ('old-unused','[\"stale\"]')")
        }
        try store.db.close(); store = try open(root, counter)
        XCTAssertEqual(counter.value, 2, "Opaque legacy caches are rebuilt once rather than guessed")
        XCTAssertEqual(try cacheCount(store), 1)
        XCTAssertEqual(try store.search(query: "OriginalCacheAnchor"), [doc.id])
        let next = parent.appendingPathComponent("new")
        try store.db.close(); try FileManager.default.moveItem(at: root, to: next)
        store = try open(next, counter)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(try cacheCount(store), 1)
        XCTAssertTrue(try store.pending().isEmpty)
    }
}
