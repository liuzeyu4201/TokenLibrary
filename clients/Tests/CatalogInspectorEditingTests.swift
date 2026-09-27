import Foundation
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class CatalogInspectorEditingTests: XCTestCase {
    private func fixture() throws -> (DocumentStore, LibraryDocument) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-leaving-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        var metadata = CatalogMetadata(category: .paper, title: "原始标题")
        metadata.authors = ["原作者"]; metadata.year = 2024
        let doc = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .md, parentId: "root", name: "paper.md", markdown: "正文\n",
            pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal,
            annotationsJSON: "[]", metadataJSON: try metadata.json())
        try store.saveDocument(doc, enqueue: false)
        return (store, doc)
    }

    func testSaveBeforeOpeningSourceMergesFreshRemoteFieldsAndPreservesDestination() throws {
        let (store, doc) = try fixture()
        var form = CatalogInspectorDraft(doc.catalog), navigation = CatalogInspectorNavigation()
        form.metadata.title = "我的标题"; form.tags = "书籍， 研究"
        _ = try store.updateCatalog(id: doc.id) { $0.authors = ["远端作者"]; $0.doi = "10.1/fresh" }
        XCTAssertNil(navigation.request(.source(doc, 2, "pdf-version"), dirty: form.isDirty))
        let result = try navigation.resolve(.save) { _ = try form.save(id: doc.id, kind: doc.kind, store: store) }
        guard case .source(let target, let page, let hash) = result else { return XCTFail("Saved source navigation was lost") }
        XCTAssertEqual(target.id, doc.id); XCTAssertEqual(page, 2); XCTAssertEqual(hash, "pdf-version")
        let loaded = try XCTUnwrap(store.loadDocument(id: doc.id))
        XCTAssertEqual(loaded.catalog.title, "我的标题"); XCTAssertEqual(loaded.catalog.authors, ["远端作者"])
        XCTAssertEqual(loaded.catalog.doi, "10.1/fresh"); XCTAssertEqual(loaded.catalog.tags, ["书籍", "研究"])
        XCTAssertFalse(form.isDirty); XCTAssertNil(navigation.pending)
    }

    func testConflictWhileLeavingKeepsDraftAndCannotNavigateUntilExplicitDiscard() throws {
        let (store, doc) = try fixture()
        var form = CatalogInspectorDraft(doc.catalog), navigation = CatalogInspectorNavigation()
        form.authors = "本机未保存作者"
        _ = try store.updateCatalog(id: doc.id) { $0.authors = ["远端修改作者"] }
        let queue = try store.pending()
        XCTAssertNil(navigation.request(.done, dirty: form.isDirty))
        XCTAssertThrowsError(try navigation.resolve(.save) { _ = try form.save(id: doc.id, kind: doc.kind, store: store) })
        XCTAssertNotNil(navigation.pending); XCTAssertTrue(form.isDirty); XCTAssertEqual(form.authors, "本机未保存作者")
        XCTAssertEqual(try store.pending(), queue)
        XCTAssertNil(try navigation.resolve(.cancel) { XCTFail("Cancel must never save") })
        XCTAssertTrue(form.isDirty)
        XCTAssertNil(navigation.request(.done, dirty: form.isDirty))
        guard case .done = try navigation.resolve(.discard, save: { XCTFail("Discard must never save") }) else { return XCTFail("Discard did not leave") }
        XCTAssertEqual(try store.loadDocument(id: doc.id)?.catalog.authors, ["远端修改作者"])
    }

    func testValidationAndDiskFailureKeepDraftThenRetrySavesOnce() throws {
        let (store, doc) = try fixture()
        var form = CatalogInspectorDraft(doc.catalog), navigation = CatalogInspectorNavigation()
        form.year = "不是年份"; form.metadata.abstract = "我的简介"
        XCTAssertNil(navigation.request(.document(doc), dirty: form.isDirty))
        XCTAssertThrowsError(try navigation.resolve(.save) { _ = try form.save(id: doc.id, kind: doc.kind, store: store) })
        form.year = "2026"
        try store.db.write { try $0.execute(sql: "CREATE TRIGGER reject_catalog_leave BEFORE INSERT ON pending_operations BEGIN SELECT RAISE(ABORT,'disk failure'); END") }
        XCTAssertThrowsError(try navigation.resolve(.save) { _ = try form.save(id: doc.id, kind: doc.kind, store: store) })
        XCTAssertEqual(try store.loadDocument(id: doc.id)?.catalog.year, 2024)
        XCTAssertTrue(form.isDirty); XCTAssertEqual(form.metadata.abstract, "我的简介"); XCTAssertNotNil(navigation.pending)
        try store.db.write { try $0.execute(sql: "DROP TRIGGER reject_catalog_leave") }
        XCTAssertNotNil(try navigation.resolve(.save) { _ = try form.save(id: doc.id, kind: doc.kind, store: store) })
        XCTAssertEqual(try store.pending().count, 1); XCTAssertFalse(form.isDirty)
        XCTAssertNotNil(navigation.request(.done, dirty: form.isDirty))
        XCTAssertNil(navigation.pending)
    }

    func testExcerptAlreadyCommittedIsKeptWhenBibliographyLeaveIsCancelledOrDiscarded() throws {
        let (store, source) = try fixture()
        var form = CatalogInspectorDraft(source.catalog), navigation = CatalogInspectorNavigation()
        form.metadata.title = "还没保存的书名"
        let note = try store.createCatalogNote(sourceID: source.id, quote: "引用原文")
        XCTAssertNil(navigation.request(.document(note), dirty: form.isDirty))
        XCTAssertNil(try navigation.resolve(.cancel, save: { XCTFail("Must not save") }))
        XCTAssertEqual(try store.loadDocument(id: note.id)?.catalog.excerpts.count, 1)
        XCTAssertTrue(form.isDirty)
        XCTAssertNil(navigation.request(.document(note), dirty: form.isDirty))
        guard case .document(let opened) = try navigation.resolve(.discard, save: { XCTFail("Must not save") }) else { return XCTFail("Missing note destination") }
        XCTAssertEqual(opened.id, note.id)
        XCTAssertEqual(try store.loadDocument(id: source.id)?.catalog.title, "原始标题")
        XCTAssertEqual(try store.catalogBacklinks(to: source.id).map(\.id), [note.id])
    }
}
