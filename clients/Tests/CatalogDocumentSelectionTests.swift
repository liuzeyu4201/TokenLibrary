import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class CatalogDocumentSelectionTests: XCTestCase {
    private func document(_ id: String, kind: DocKind = .md, parent: String = "root", name: String? = nil,
                          title: String = "", state: String = "active", archived: Bool = false,
                          related: [String] = [], sourceIDs: [String] = [], authors: [String] = [],
                          originalFilename: String = "", category: CatalogCategory = .note) throws -> LibraryDocument {
        var metadata = CatalogMetadata()
        metadata.title = title; metadata.archived = archived; metadata.relatedIDs = related
        metadata.sourceIDs = sourceIDs; metadata.authors = authors; metadata.originalFilename = originalFilename
        metadata.category = category
        return LibraryDocument(id: id, kind: kind, parentId: parent, name: name ?? id + ".md", markdown: "",
                               pdfPath: nil, revision: 0, localGeneration: 0, state: state, purgeAt: nil,
                               status: .savedLocal, annotationsJSON: "[]", metadataJSON: try metadata.json())
    }

    func testRelatedSelectionExcludesBothDirectionsButKeepsArchivedReadableSources() throws {
        let source = try document("source", related: ["forward"])
        let documents = try [source, document("forward"), document("reverse", related: [source.id]),
                             document("trashed", state: "trashed"), document("folder", kind: .folder),
                             document("archived", archived: true), document("new", kind: .pdf)]
        let candidates = CatalogDocumentSelection.candidates(in: documents, source: source, purpose: .related)
        XCTAssertEqual(Set(candidates.map(\.id)), ["archived", "new"])
        XCTAssertTrue(try XCTUnwrap(candidates.first { $0.id == "archived" }).archived)
    }

    func testExcerptTargetsAllowMoreExcerptsInExistingNoteAndRejectReadOnlyTargets() throws {
        let source = try document("source")
        let documents = try [source, document("existing-note", sourceIDs: [source.id]), document("plain-note"),
                             document("archived", archived: true), document("pdf", kind: .pdf),
                             document("folder", kind: .folder), document("deleted", state: "trashed")]
        let candidates = CatalogDocumentSelection.candidates(in: documents, source: source, purpose: .excerptNote)
        XCTAssertEqual(Set(candidates.map(\.id)), ["existing-note", "plain-note"])
        let changed = try document("plain-note", archived: true)
        let refreshed = CatalogDocumentSelection.candidates(in: [source, changed], source: source, purpose: .excerptNote)
        XCTAssertFalse(refreshed.contains { $0.id == "plain-note" }, "A selection snapshot cannot keep an archived target eligible.")
    }

    func testSearchDistinguishesSameTitleAndFilenameByFolderAuthorOriginalNameAndType() throws {
        let source = try document("source")
        let systems = try document("systems", kind: .folder, name: "系统研究")
        let archive = try document("archive", kind: .folder, parent: systems.id, name: "Archive")
        let literature = try document("literature", kind: .folder, name: "文学")
        let first = try document("a", kind: .pdf, parent: archive.id, name: "page-1.pdf", title: "阅读材料",
                                 authors: ["Émilie"], originalFilename: "original-study.pdf", category: .paper)
        let second = try document("b", kind: .pdf, parent: literature.id, name: "page-1.pdf", title: "阅读材料", category: .book)
        let candidates = CatalogDocumentSelection.candidates(in: [source, systems, archive, literature, second, first], source: source, purpose: .related)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first { $0.id == "a" }?.folderPath, "资料库 / 系统研究 / Archive")
        XCTAssertEqual(candidates.first { $0.id == "b" }?.filename, "page-1.pdf")
        for query in ["系统研究 page-1", "ARCHIVE 论文", "emilie", "original-study", "阅读材料\n论文\tPDF"] {
            XCTAssertEqual(CatalogDocumentSelection.matching(candidates, query: query).map(\.id), ["a"], query)
        }
        XCTAssertEqual(CatalogDocumentSelection.matching(candidates, query: "文学 书籍").map(\.id), ["b"])
        XCTAssertTrue(CatalogDocumentSelection.matching(candidates, query: "文学 论文").isEmpty)
        XCTAssertEqual(CatalogDocumentSelection.matching(candidates, query: "  \n").count, 2)
    }

    func testIncompleteOrCyclicFolderPathsDoNotPretendToBeTheLibraryRoot() throws {
        let source = try document("source")
        let a = try document("a", kind: .folder, parent: "b", name: "A")
        let b = try document("b", kind: .folder, parent: "a", name: "B")
        let cyclic = try document("cyclic", parent: a.id)
        let missing = try document("missing", parent: "not-loaded")
        let root = try document("server-root", kind: .folder, parent: "", name: "研究库")
        let realRootChild = try document("server-child", parent: root.id)
        let candidates = CatalogDocumentSelection.candidates(in: [source, a, b, cyclic, missing, root, realRootChild], source: source, purpose: .related)
        XCTAssertTrue(candidates.isEmpty, "Unknown, cyclic and different real roots must never be offered as selectable targets.")
        let sameRoot = CatalogDocumentSelection.candidates(in: [root, realRootChild, try document("sibling", parent: root.id)], source: realRootChild, purpose: .related)
        XCTAssertEqual(sameRoot.map(\.id), ["sibling"])
        XCTAssertEqual(sameRoot.first?.folderPath, "资料库 / 研究库")
    }

    func testSearchIncludesCandidatesBeyondFiveHundredAndOrderingIsStable() throws {
        let source = try document("source")
        var documents = try (0..<623).map { index in
            try document("id-\(index)", name: "page-\(index).md", title: "共同标题", authors: index == 622 ? ["唯一本作者"] : [])
        }
        let first = CatalogDocumentSelection.candidates(in: documents, source: source, purpose: .related)
        documents.reverse()
        let second = CatalogDocumentSelection.candidates(in: documents, source: source, purpose: .related)
        XCTAssertEqual(first.count, 623)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(CatalogDocumentSelection.matching(first, query: "唯一本作者").map(\.id), ["id-622"])
        XCTAssertEqual(CatalogDocumentSelection.matching(first, query: "page-622.md").map(\.id), ["id-622"])
    }
    func testRegisteredLegacyRootCandidatesStayInsideCurrentLibraryAndRefreshAfterMove() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-selection-roots-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        let rootA = UUID().uuidString.lowercased(), rootB = UUID().uuidString.lowercased()
        try store.registerLegacyLibraryRoot(rootID: rootA)
        try store.registerLegacyLibraryRoot(rootID: rootB)
        let source = try document("source", parent: rootA)
        let sibling = try document("sibling", parent: rootA)
        let folder = try document("folder", kind: .folder, parent: rootA)
        let nested = try document("nested", parent: folder.id)
        let topic = try document("topic", kind: .folder, parent: rootA, category: .topic)
        let otherTopic = try document("other-topic", kind: .folder, parent: rootB, category: .topic)
        let others = try [document("other", parent: rootB), document("local"), document("orphan", parent: "unrecorded")]
        let documents = [source, sibling, folder, nested, topic, otherTopic] + others
        for doc in documents { try store.saveDocument(doc, enqueue: false) }
        let inventory = try store.legacyLibraryInventory()
        for purpose in [CatalogDocumentSelectionPurpose.related, .excerptNote] {
            let candidates = CatalogDocumentSelection.candidates(in: documents, source: source, purpose: purpose, inventory: inventory)
            XCTAssertEqual(Set(candidates.map(\.id)), [sibling.id, nested.id])
            XCTAssertEqual(candidates.first { $0.id == sibling.id }?.folderPath, "资料库")
        }
        let scope = CatalogLibraryScope(documents: documents, inventory: inventory)
        XCTAssertTrue(scope.contains(topic.id, alongside: source.id)); XCTAssertFalse(scope.contains(otherTopic.id, alongside: source.id))
        var moved = sibling; moved.parentId = rootB
        let changed = documents.filter { $0.id != sibling.id } + [moved]
        let current = CatalogDocumentSelection.candidates(in: changed, source: source, purpose: .excerptNote, inventory: inventory)
        XCTAssertFalse(current.contains { $0.id == sibling.id }, "Even a stale inventory must resolve the current document hierarchy.")
        XCTAssertTrue(CatalogDocumentSelection.candidates(in: documents, source: source, purpose: .related).isEmpty,
                      "Without explicit root evidence, missing parent IDs are not assumed to be library roots.")
    }

    func testUnavailableRelatedEntriesRemainRemovableAfterTrashOrPurge() throws {
        let source = try document("source", related: ["trashed", "purged"])
        let trash = try document("trashed", state: "trashed", related: [source.id])
        let incoming = try document("incoming", state: "trashed", related: [source.id])
        let entries = CatalogRelatedEntry.entries(source: source, documents: [source, trash, incoming])
        XCTAssertEqual(Set(entries.map(\.id)), ["trashed", "purged", "incoming"])
        XCTAssertNil(entries.first { $0.id == "purged" }?.document)
        XCTAssertEqual(entries.first { $0.id == "trashed" }?.document?.state, "trashed")
        XCTAssertEqual(entries.filter { $0.id == "trashed" }.count, 1)
    }

}
