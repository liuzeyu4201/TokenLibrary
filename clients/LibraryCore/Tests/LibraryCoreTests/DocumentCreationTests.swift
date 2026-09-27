import XCTest
import GRDB
@testable import LibraryCore

final class DocumentCreationTests: XCTestCase {
    private func store() throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-creation-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try DocumentStore(directory: root)
    }
    private func doc(_ id: String = UUID().uuidString.lowercased(), parent: String = "root", kind: DocKind = .md, name: String = "新笔记.md") -> LibraryDocument {
        LibraryDocument(id: id, kind: kind, parentId: parent, name: name, markdown: kind == .md ? "new content" : "",
            pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]")
    }

    func testStaleDeletedParentCannotCreateOrEnqueueOrphan() throws {
        let s = try store()
        let parent = try s.createDocument(doc("folder", kind: .folder, name: "folder"))
        try s.trash(id: parent.id)
        let before = try s.pending()
        XCTAssertThrowsError(try s.createDocument(doc("child", parent: parent.id)))
        XCTAssertNil(try s.loadDocument(id: "child")); XCTAssertEqual(try s.pending(), before)
    }

    func testCreationRejectsMissingFileTopicAndInactiveAncestorContainers() throws {
        let s = try store()
        try s.saveDocument(doc("file"), enqueue: false)
        var topic = doc("topic", kind: .folder, name: "topic")
        var metadata = topic.catalog; metadata.category = .topic; topic.metadataJSON = try metadata.json()
        try s.saveDocument(topic, enqueue: false)
        var ancestor = doc("ancestor", kind: .folder, name: "ancestor"); ancestor.state = "trashed"
        try s.saveDocument(ancestor, enqueue: false)
        try s.saveDocument(doc("subfolder", parent: "ancestor", kind: .folder, name: "subfolder"), enqueue: false)
        try s.saveDocument(doc("legacy-topic-folder", parent: "topic", kind: .folder, name: "legacy"), enqueue: false)
        for parent in ["missing", "file", "topic", "subfolder", "legacy-topic-folder", ""] {
            XCTAssertThrowsError(try s.createDocument(doc(parent: parent)), parent)
        }
        XCTAssertTrue(try s.pending().isEmpty)
    }

    func testCreationHonorsBoundRootBeforeBootstrapAndRejectsOtherLibrary() throws {
        let s = try store()
        try s.bindWorkspace(server: "https://library.test", libraryId: "library", rootId: "trusted-root")
        let created = try s.createDocument(doc("new-note", parent: "trusted-root"))
        XCTAssertEqual(created.parentId, "trusted-root"); XCTAssertEqual(created.status, .pending)
        XCTAssertThrowsError(try s.createDocument(doc(parent: "root")))
        try s.saveDocument(doc("other-root", parent: "", kind: .folder, name: "other"), enqueue: false)
        XCTAssertThrowsError(try s.createDocument(doc(parent: "other-root")))
        XCTAssertThrowsError(try s.createDocument(doc("trusted-root", parent: "trusted-root")))
    }

    func testNewIDCannotOverwriteExistingOrReuseDeletedIdentity() throws {
        let s = try store(); let existing = try s.createDocument(doc("existing", name: "original.md"))
        let before = try s.pending()
        XCTAssertThrowsError(try s.createDocument(doc("existing", name: "replacement.md")))
        XCTAssertEqual(try s.loadDocument(id: "existing"), existing); XCTAssertEqual(try s.pending(), before)
        try s.db.write { db in
            try db.execute(sql: "INSERT INTO remote_tombstones(id,deleted_at) VALUES ('deleted','2026-09-26T00:00:00Z')")
        }
        XCTAssertThrowsError(try s.createDocument(doc("deleted")))
        XCTAssertNil(try s.loadDocument(id: "deleted"))
    }

    func testNamesDeduplicateCasefoldUnicodeAndPreserveExtensionWithinByteLimit() throws {
        let s = try store()
        _ = try s.createDocument(doc(name: "Straße.md"))
        XCTAssertEqual(try s.createDocument(doc(name: "STRASSE.md")).name, "STRASSE_1.md")
        _ = try s.createDocument(doc(name: "Café.md"))
        XCTAssertEqual(try s.createDocument(doc(name: "Cafe\u{301}.md")).name, "Cafe\u{301}_1.md")
        let fullName = String(repeating: "中", count: 79) + ".md"
        _ = try s.createDocument(doc(name: fullName))
        let suffix = try s.createDocument(doc(name: fullName))
        XCTAssertTrue(suffix.name.hasSuffix("_1.md")); XCTAssertLessThanOrEqual(suffix.name.utf8.count, 240)
        XCTAssertTrue(FileNames.isValidStoredName(suffix.name))
        _ = try s.createDocument(doc(kind: .folder, name: "Project.2026"))
        XCTAssertEqual(try s.createDocument(doc(kind: .folder, name: "Project.2026")).name, "Project.2026_1")
        let before = try s.pending().count
        XCTAssertThrowsError(try s.createDocument(doc(name: "strasse.md"), deduplicateName: false))
        XCTAssertEqual(try s.pending().count, before)
    }

    func testConcurrentSameNameCreatesHaveDistinctIDsAndNames() async throws {
        let s = try store()
        let documents = (0..<16).map { _ in doc(name: "same.md") }
        let results = await withTaskGroup(of: LibraryDocument?.self, returning: [LibraryDocument].self) { group in
            for document in documents { group.addTask { try? s.createDocument(document) } }
            var output: [LibraryDocument] = []; for await value in group { if let value { output.append(value) } }; return output
        }
        XCTAssertEqual(results.count, 16); XCTAssertEqual(Set(results.map(\.id)).count, 16)
        XCTAssertEqual(Set(results.map { FileNames.comparisonKey($0.name) }).count, 16)
        XCTAssertEqual(try s.pending().count, 16)
        XCTAssertTrue(try s.pending().allSatisfy { $0.action == "createMarkdown" })
    }

    func testConcurrentFolderTrashAndCreateNeverLeavesAnActiveOrphan() async throws {
        let s = try store()
        for index in 0..<12 {
            let parentID = "folder-\(index)", childID = "child-\(index)"
            _ = try s.createDocument(doc(parentID, kind: .folder, name: parentID))
            let child = doc(childID, parent: parentID)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? s.createDocument(child) }
                group.addTask { try? s.trash(id: parentID) }
            }
            XCTAssertEqual(try s.loadDocument(id: parentID)?.state, "trashed")
            if let created = try s.loadDocument(id: childID) { XCTAssertEqual(created.state, "trashed") }
        }
    }
}
