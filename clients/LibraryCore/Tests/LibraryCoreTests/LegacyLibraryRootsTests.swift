import Foundation
import XCTest
@testable import LibraryCore

final class LegacyLibraryRootsTests: XCTestCase {
    private func store() throws -> DocumentStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-roots-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try DocumentStore(directory: directory)
    }
    private func doc(_ id: String = UUID().uuidString.lowercased(), parent: String = "root", kind: DocKind = .md, name: String = "笔记.md", body: String = "未提交正文") -> LibraryDocument {
        LibraryDocument(id: id, kind: kind, parentId: parent, name: name, markdown: kind == .md ? body : "", pdfPath: nil,
            revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
    }

    func testExplicitRecordedRootMakesMixedLegacyLibraryVisibleWithoutRewritingDocumentsOrQueue() throws {
        let s = try store(), root = UUID().uuidString.lowercased(), unknown = UUID().uuidString.lowercased()
        let local = doc(), folder = doc(parent: root, kind: .folder, name: "论文"), child = doc(parent: folder.id), orphan = doc(parent: unknown)
        for item in [local, folder, child, orphan] { try s.saveDocument(item, enqueue: true) }
        let first = try XCTUnwrap(s.pending().first)
        _ = try s.prepareOperation(first.operationId, epoch: "legacy-epoch", deviceId: "device", serverOrigin: "https://old.test")
        let documents = try s.listDocuments(includeTrashed: true), pending = try s.pending()
        XCTAssertNil(try s.legacyLibraryInventory().rootID(for: child.id))
        try s.registerLegacyLibraryRoot(rootID: root, server: "https://old.test", libraryID: "old-library")
        let inventory = try s.legacyLibraryInventory()
        XCTAssertEqual(inventory.rootIDs, ["root", root].sorted())
        XCTAssertEqual(inventory.rootID(for: root), root)
        XCTAssertEqual(inventory.rootID(for: folder.id), root)
        XCTAssertEqual(inventory.rootID(for: child.id), root)
        XCTAssertEqual(inventory.rootID(for: local.id), "root")
        XCTAssertNil(inventory.rootID(for: unknown))
        XCTAssertEqual(inventory.unresolvedDocumentIDs, [orphan.id])
        XCTAssertEqual(try s.listDocuments(includeTrashed: true), documents)
        XCTAssertEqual(try s.pending(), pending)
        for key in ["server", "libraryId", "rootId", "epoch", "cursor"] { XCTAssertNil(try s.syncValue(key)) }
        let reopened = try DocumentStore(directory: s.root)
        try reopened.registerLegacyLibraryRoot(rootID: root, server: "https://old.test/", libraryID: "old-library")
        XCTAssertEqual(try reopened.legacyLibraryInventory(), inventory)
        XCTAssertEqual(try reopened.pending(), pending)
    }

    func testUnknownParentsCyclesAndFilesUsedAsParentsAreNeverTrusted() throws {
        let s = try store(), known = UUID().uuidString.lowercased(), unknown = UUID().uuidString.lowercased()
        try s.registerLegacyLibraryRoot(rootID: known)
        let ordinary = doc("file", parent: known)
        let invalid = [doc("orphan", parent: unknown), doc("under-file", parent: ordinary.id),
                       doc("cycle-a", parent: "cycle-b", kind: .folder), doc("cycle-b", parent: "cycle-a", kind: .folder),
                       doc("empty-parent-file", parent: "")]
        for item in [ordinary] + invalid { try s.saveDocument(item, enqueue: false) }
        let inventory = try s.legacyLibraryInventory()
        XCTAssertEqual(inventory.unresolvedDocumentIDs, invalid.map(\.id).sorted())
        XCTAssertEqual(inventory.rootID(for: ordinary.id), known)
        XCTAssertFalse(inventory.rootIDs.contains(unknown))
        XCTAssertThrowsError(try s.createDocument(doc(parent: unknown)))
        XCTAssertThrowsError(try s.moveDocument(id: ordinary.id, to: unknown))
    }

    func testRegistrationRejectsGuessedInvalidIDsAndExistingNonRootNodes() throws {
        let s = try store()
        for id in ["", "root", "missing-folder", "..", " \(UUID().uuidString)"] {
            XCTAssertThrowsError(try s.registerLegacyLibraryRoot(rootID: id))
        }
        let file = doc(), nested = doc(kind: .folder, name: "folder")
        for item in [file, nested] { try s.saveDocument(item, enqueue: true) }
        let before = try s.pending()
        XCTAssertThrowsError(try s.registerLegacyLibraryRoot(rootID: file.id))
        XCTAssertThrowsError(try s.registerLegacyLibraryRoot(rootID: nested.id))
        XCTAssertThrowsError(try s.registerLegacyLibraryRoot(rootID: UUID().uuidString, server: "not an origin"))
        XCTAssertEqual(try s.legacyLibraryInventory().rootIDs, ["root"])
        XCTAssertEqual(try s.pending(), before)
    }

    func testBoundWorkspaceIdentityCannotBeChangedOrExpandedByLegacyHint() throws {
        let s = try store(), root = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        try s.bindWorkspace(server: "https://bound.test", libraryId: "library", rootId: root)
        try s.saveDocument(doc("old-local"), enqueue: false)
        try s.saveDocument(doc("current", parent: root), enqueue: false)
        for (id, server, library) in [(other, "https://bound.test", "library"), (root, "https://other.test", "library"), (root, "https://bound.test", "other")] {
            XCTAssertThrowsError(try s.registerLegacyLibraryRoot(rootID: id, server: server, libraryID: library))
        }
        try s.registerLegacyLibraryRoot(rootID: root, server: "https://bound.test", libraryID: "library")
        XCTAssertEqual(try s.legacyLibraryInventory().rootID(for: "current"), root)
        XCTAssertEqual(try s.syncValue("server"), "https://bound.test")
        XCTAssertEqual(try s.syncValue("libraryId"), "library")
        XCTAssertEqual(try s.syncValue("rootId"), root)
        XCTAssertThrowsError(try s.createDocument(doc(parent: "root")))
        XCTAssertThrowsError(try s.moveDocument(id: "current", to: "root"))
        XCTAssertEqual(try s.createDocument(doc(parent: root)).parentId, root)
    }

    func testRegisteredRootAllowsSameLibraryCreateCatalogMoveAndDraftRecovery() throws {
        let s = try store(), root = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        try s.registerLegacyLibraryRoot(rootID: root)
        try s.registerLegacyLibraryRoot(rootID: other)
        let note = try s.createDocument(doc(parent: root)), folder = try s.createDocument(doc(parent: root, kind: .folder, name: "资料"))
        XCTAssertEqual(try s.moveDocument(id: note.id, to: folder.id).parentId, folder.id)
        XCTAssertEqual(try s.moveDocument(id: note.id, to: root).parentId, root)
        XCTAssertThrowsError(try s.moveDocument(id: note.id, to: other))
        let topic = try s.createCatalogTopic(name: "研究", parentID: root)
        _ = try s.setCatalogTopic(id: note.id, topicID: topic.id, included: true)
        XCTAssertEqual(try s.loadDocument(id: note.id)?.catalog.topicIDs, [topic.id])
        let second = try s.createCatalogTopic(name: "另一个库的研究", parentID: other)
        XCTAssertThrowsError(try s.setCatalogTopic(id: note.id, topicID: second.id, included: true))
        let session = try s.beginMarkdownEdit(id: note.id)
        _ = try s.saveMarkdownEdit(id: note.id, baseMarkdown: note.markdown, proposedMarkdown: "远端修改")
        guard case .conflict = try session.save("保留的草稿") else { return XCTFail("Expected retained recovery draft") }
        let draft = try XCTUnwrap(s.editorDrafts().first)
        let recovered = try s.recoverEditorDraftAsCopy(id: draft.id, parentId: root)
        XCTAssertEqual(recovered.parentId, root)
        XCTAssertEqual(recovered.markdown, "保留的草稿")
        XCTAssertEqual(try s.loadDocument(id: note.id)?.markdown, "远端修改")
        XCTAssertTrue(try s.editorDrafts().isEmpty)
    }

    func testMixedLegacyCopyIncludesEveryTrustedRootAndPreservesOriginalBytesQueueAndUnknownOrphans() throws {
        let source = try store(), target = try store(), missingRoot = UUID().uuidString.lowercased(), orphanRoot = UUID().uuidString.lowercased()
        let realRoot = doc(parent: "", kind: .folder, name: "真实根")
        let asset = try source.importAttachment(data: Data("original image bytes".utf8), fileName: "image.png", mime: "image/png")
        let local = doc(body: "![图片](\(asset.path))"), old = doc(parent: missingRoot), real = doc(parent: realRoot.id), orphan = doc(parent: orphanRoot)
        for item in [realRoot, local, old, real, orphan] { try source.saveDocument(item, enqueue: true) }
        try source.registerLegacyLibraryRoot(rootID: missingRoot, server: "https://old.test")
        let before = try source.listDocuments(includeTrashed: true), queue = try source.pending()
        let inventory = try source.legacyLibraryInventory()
        var copied: [String: String] = [:]
        for root in inventory.rootIDs {
            let result = try target.importLocalLibrary(from: source, sourceRootID: root, targetRootID: "root")
            copied.merge(result.documentIDMap, uniquingKeysWith: { first, _ in first })
        }
        XCTAssertEqual(Set(copied.keys), Set([local.id, old.id, real.id]))
        XCTAssertEqual(inventory.unresolvedDocumentIDs, [orphan.id])
        XCTAssertEqual(try target.listDocuments().count, 3)
        XCTAssertEqual(try source.listDocuments(includeTrashed: true), before)
        XCTAssertEqual(try source.pending(), queue)
        XCTAssertEqual(try Data(contentsOf: source.resolveAttachment(path: asset.path)), Data("original image bytes".utf8))
        XCTAssertNotNil(try source.loadDocument(id: orphan.id))
        let copiedNote = try XCTUnwrap(target.loadDocument(id: XCTUnwrap(copied[local.id])))
        let copiedAsset = try XCTUnwrap(JSONValue.parse(copiedNote.assetsJSON).array?.first?.object?["path"]?.string)
        XCTAssertEqual(try Data(contentsOf: target.resolveAttachment(path: copiedAsset)), Data("original image bytes".utf8))
    }

    func testCorruptRegistrationAndLaterNonRootCollisionDoNotCreateTrustedRoots() throws {
        let s = try store(), root = UUID().uuidString.lowercased(), malformed = UUID().uuidString.lowercased()
        try s.registerLegacyLibraryRoot(rootID: root)
        try s.db.write { db in
            try db.execute(sql: "INSERT INTO sync_state(key,value) VALUES (?,?)", arguments: ["legacy.root." + malformed, "{broken}"])
        }
        let child = doc(parent: root), wrongNode = doc(root, parent: "unknown", kind: .folder)
        try s.saveDocument(child, enqueue: false); try s.saveDocument(wrongNode, enqueue: false)
        let inventory = try s.legacyLibraryInventory()
        XCTAssertEqual(inventory.rootIDs, ["root"])
        XCTAssertEqual(Set(inventory.unresolvedDocumentIDs), [child.id, wrongNode.id])
        XCTAssertThrowsError(try s.createDocument(doc(parent: root)))
    }
}
