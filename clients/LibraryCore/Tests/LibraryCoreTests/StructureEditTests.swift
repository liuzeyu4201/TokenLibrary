import XCTest
@testable import LibraryCore

final class StructureEditTests: XCTestCase {
    private func store() throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("structure-edits-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try DocumentStore(directory: root)
    }
    private func doc(_ id: String, parent: String = "root", kind: DocKind = .md, name: String? = nil, text: String = "body") -> LibraryDocument {
        LibraryDocument(id: id, kind: kind, parentId: parent, name: name ?? (kind == .md ? id + ".md" : id), markdown: text,
            pdfPath: nil, revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
    }

    func testRenameAndMovePreserveLatestBodyMetadataAndFrozenQueue() throws {
        let s = try store()
        try s.saveDocument(doc("target", kind: .folder), enqueue: false)
        try s.saveDocument(doc("note"), enqueue: true)
        let first = try XCTUnwrap(s.pending().first)
        let frozen = try XCTUnwrap(s.prepareOperation(first.operationId, epoch: "epoch", deviceId: "device", serverOrigin: "https://example.test"))
        _ = try s.saveMarkdownEdit(id: "note", baseMarkdown: "body", proposedMarkdown: "latest user text")
        _ = try s.updateCatalog(id: "note") { $0.tags = ["current-tag"] }
        _ = try s.renameDocument(id: "note", to: "new name")
        let moved = try s.moveDocument(id: "note", to: "target")
        XCTAssertEqual(moved.markdown, "latest user text"); XCTAssertEqual(moved.catalog.tags, ["current-tag"])
        XCTAssertEqual(moved.name, "new name.md"); XCTAssertEqual(moved.parentId, "target")
        let operations = try s.pending()
        XCTAssertEqual(operations.first?.requestJSON, frozen.requestJSON)
        let tail = try XCTUnwrap(operations.last)
        XCTAssertEqual(tail.action, "move")
        let payload = try JSONValue.parse(tail.payload).object
        XCTAssertEqual(payload?["markdownSource"]?.string, moved.markdown)
        XCTAssertEqual(payload?["name"]?.string, moved.name); XCTAssertEqual(payload?["parentId"]?.string, moved.parentId)
    }

    func testMoveRejectsInvalidDestinationCyclesTopicsAndOtherRootsAtomically() throws {
        let s = try store()
        let initial = [doc("server-a", parent: "", kind: .folder), doc("server-b", parent: "", kind: .folder),
            doc("folder", parent: "server-a", kind: .folder), doc("child", parent: "folder", kind: .folder),
            doc("file", parent: "server-a"), doc("topic", parent: "server-a", kind: .folder)]
        for item in initial { try s.saveDocument(item, enqueue: false) }
        var topic = try XCTUnwrap(s.loadDocument(id: "topic")); var meta = topic.catalog; meta.category = .topic
        topic.metadataJSON = try meta.json(); try s.saveDocument(topic, enqueue: false)
        for target in ["folder", "child", "topic", "file", "missing", "server-b", "root", ""] {
            XCTAssertThrowsError(try s.moveDocument(id: "folder", to: target), target)
            XCTAssertEqual(try s.loadDocument(id: "folder")?.parentId, "server-a")
        }
        XCTAssertThrowsError(try s.moveDocument(id: "server-a", to: "folder"))
        XCTAssertThrowsError(try s.renameDocument(id: "server-a", to: "other root"))
        XCTAssertTrue(try s.pending().isEmpty)
    }

    func testCaseFoldAndCanonicalUnicodeNamesMatchServerCollisionRules() throws {
        let s = try store()
        try s.saveDocument(doc("one", name: "Straße.md"), enqueue: false)
        try s.saveDocument(doc("two", name: "other.md"), enqueue: false)
        XCTAssertThrowsError(try s.renameDocument(id: "two", to: "STRASSE.md"))
        try s.saveDocument(doc("accent", name: "Café.md"), enqueue: false)
        XCTAssertThrowsError(try s.renameDocument(id: "two", to: "Cafe\u{301}.md"))
        try s.saveDocument(doc("target", kind: .folder), enqueue: false)
        try s.saveDocument(doc("duplicate", parent: "target", name: "STRASSE.md"), enqueue: false)
        XCTAssertThrowsError(try s.moveDocument(id: "one", to: "target"))
        XCTAssertEqual(try s.loadDocument(id: "one")?.parentId, "root")
        XCTAssertTrue(try s.pending().isEmpty)
    }

    func testNameValidationUsesWireByteLimitAndDeletedObjectsStayDeleted() throws {
        let s = try store(); try s.saveDocument(doc("note"), enqueue: false)
        for invalid in [".", "..", "bad/name", "bad\\name", "line\nname", String(repeating: "中", count: 80)] {
            XCTAssertThrowsError(try s.renameDocument(id: "note", to: invalid), invalid)
        }
        let allowed = String(repeating: "a", count: 237) + ".md"
        XCTAssertEqual(try s.renameDocument(id: "note", to: allowed)?.name, allowed)
        try s.trash(id: "note")
        XCTAssertThrowsError(try s.renameDocument(id: "note", to: "new"))
        XCTAssertThrowsError(try s.moveDocument(id: "note", to: "root"))
        XCTAssertEqual(try s.loadDocument(id: "note")?.state, "trashed")
    }

    func testBoundRootIsTrustedBeforeBootstrapButArbitraryMissingParentIsNot() throws {
        let s = try store()
        try s.bindWorkspace(server: "https://library.test", libraryId: "library-one", rootId: "authenticated-root")
        try s.saveDocument(doc("note", parent: "authenticated-root"), enqueue: false)
        try s.saveDocument(doc("folder", parent: "authenticated-root", kind: .folder), enqueue: false)
        XCTAssertEqual(try s.moveDocument(id: "note", to: "folder").parentId, "folder")
        XCTAssertEqual(try s.moveDocument(id: "note", to: "authenticated-root").parentId, "authenticated-root")
        XCTAssertThrowsError(try s.moveDocument(id: "note", to: "root"))
        XCTAssertThrowsError(try s.moveDocument(id: "note", to: "other-missing-root"))
        XCTAssertThrowsError(try s.bindWorkspace(server: "https://library.test", libraryId: "library-one", rootId: "other-root"))
        XCTAssertEqual(try s.syncValue("rootId"), "authenticated-root")
    }

    func testConcurrentStructuralChangesCannotOverwriteEditorChanges() async throws {
        let s = try store(), base = (0..<12).map { "line-\($0)" }.joined(separator: "\n")
        try s.saveDocument(doc("note", text: base), enqueue: false)
        try s.saveDocument(doc("folder", kind: .folder), enqueue: false)
        let sessions = try (0..<12).map { _ in try s.beginMarkdownEdit(id: "note") }
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask {
                do { for i in 0..<15 { _ = try s.renameDocument(id: "note", to: "renamed-\(i)") }; return true }
                catch { return false }
            }
            group.addTask {
                do { for i in 0..<15 { _ = try s.moveDocument(id: "note", to: i % 2 == 0 ? "folder" : "root") }; return true }
                catch { return false }
            }
            for i in 0..<12 {
                let session = sessions[i]; var lines = base.components(separatedBy: "\n"); lines[i] = "edited-\(i)"
                let text = lines.joined(separator: "\n")
                group.addTask { if let result = try? session.save(text), case .saved = result { return true }; return false }
            }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        XCTAssertTrue(results.allSatisfy { $0 })
        let actual = try XCTUnwrap(s.loadDocument(id: "note"))
        XCTAssertEqual(actual.name, "renamed-14.md"); XCTAssertEqual(actual.parentId, "folder")
        XCTAssertEqual(actual.markdown, (0..<12).map { "edited-\($0)" }.joined(separator: "\n"))
        let tail = try XCTUnwrap(s.pending().last), payload = try JSONValue.parse(tail.payload).object
        XCTAssertEqual(payload?["markdownSource"]?.string, actual.markdown)
        XCTAssertEqual(payload?["name"]?.string, actual.name); XCTAssertEqual(payload?["parentId"]?.string, actual.parentId)
    }
}
