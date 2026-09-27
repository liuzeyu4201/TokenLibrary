import Foundation
import XCTest
import PDFKit
@testable import LibraryCore

final class WorkspaceTransferTests: XCTestCase, @unchecked Sendable {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("workspace-transfer-\(UUID().uuidString)") }
    private func doc(id: String = UUID().uuidString.lowercased(), kind: DocKind = .md, parent: String = "root", name: String = "文献.md", body: String = "正文") -> LibraryDocument {
        LibraryDocument(id: id, kind: kind, parentId: parent, name: name, markdown: body, pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
    }

    func testImportCopiesConflictingIDsAttachmentsTopicsAndTrashWithoutChangingSource() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DocumentStore(directory: directory.appendingPathComponent("source"))
        let target = try DocumentStore(directory: directory.appendingPathComponent("target"))
        let folder = doc(kind: .folder, name: "主题"), note = doc(parent: folder.id), trashed = doc(parent: folder.id, name: "回收.md")
        let bytes = Data("attachment bytes".utf8), asset = try source.importAttachment(data: bytes, fileName: "image.png", mime: "image/png")
        var attached = note
        attached.markdown = "![扫描](library-asset://\(asset.blobId))"
        attached.metadataJSON = try JSONValue.object(["topicIDs": .array([.string(folder.id)])]).jsonString()
        try source.saveDocument(folder, enqueue: true); try source.saveDocument(attached, enqueue: true); try source.saveDocument(trashed, enqueue: true)
        try source.trash(id: trashed.id)
        // Collisions copy under a new ID; existing target content remains untouched.
        try target.saveDocument(doc(id: folder.id, kind: .folder, parent: "remote-root", name: "主题"), enqueue: false)
        let before = try source.listDocuments(includeTrashed: true), pending = try source.pending()
        let result = try target.importLocalLibrary(from: source, sourceRootID: "root", targetRootID: "remote-root")
        XCTAssertEqual(result.importedDocuments, 3); XCTAssertEqual(result.importedAttachments, 1)
        let folderID = try XCTUnwrap(result.documentIDMap[folder.id])
        XCTAssertNotEqual(folderID, folder.id)
        XCTAssertEqual(result.documentIDMap[note.id], note.id)
        let imported = try XCTUnwrap(target.loadDocument(id: note.id))
        XCTAssertEqual(imported.parentId, folderID); XCTAssertTrue(imported.metadataJSON.contains(folderID))
        XCTAssertFalse(imported.markdown.contains("library-asset://"))
        let descriptor = try XCTUnwrap(JSONValue.parse(imported.assetsJSON).array?.first?.object)
        XCTAssertEqual(try Data(contentsOf: target.resolveAttachment(path: XCTUnwrap(descriptor["path"]?.string))), bytes)
        XCTAssertEqual(try target.loadDocument(id: trashed.id)?.state, "trashed")
        XCTAssertEqual(try XCTUnwrap(target.loadDocument(id: folderID)).name, "主题_1")
        XCTAssertEqual(try source.listDocuments(includeTrashed: true), before)
        XCTAssertEqual(try source.pending(), pending)
        XCTAssertEqual(try Data(contentsOf: source.resolveAttachment(path: asset.path)), bytes)
        XCTAssertEqual(try target.pending().count, 4)
    }

    func testImportNamesUseCaseFoldAndRespectUTF8LimitWithSuffix() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DocumentStore(directory: directory.appendingPathComponent("source")), target = try DocumentStore(directory: directory.appendingPathComponent("target"))
        let longName = String(repeating: "研", count: 79) + ".md"
        let long = doc(name: longName), folded = doc(name: "Straße.md")
        for item in [long, folded] { try source.saveDocument(item, enqueue: true) }
        for name in [longName, "STRASSE.md", "Straße_1.md"] { try target.saveDocument(doc(name: name), enqueue: true) }
        let result = try target.importLocalLibrary(from: source, sourceRootID: "root", targetRootID: "root")
        let copied = try XCTUnwrap(target.loadDocument(id: XCTUnwrap(result.documentIDMap[long.id])))
        XCTAssertLessThanOrEqual(copied.name.utf8.count, 240)
        XCTAssertTrue(copied.name.hasSuffix("_1.md"))
        XCTAssertEqual(try target.loadDocument(id: XCTUnwrap(result.documentIDMap[folded.id]))?.name, "Straße_2.md")
        let names = try target.listDocuments().map { FileNames.comparisonKey($0.name) }
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testImportRebindsExcerptAndRenderedLinksWhenSourceIDCollides() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DocumentStore(directory: directory.appendingPathComponent("source")), target = try DocumentStore(directory: directory.appendingPathComponent("target"))
        let paper = doc(kind: .pdf, name: "paper.pdf", body: "")
        try source.saveDocument(paper, enqueue: false)
        var note = try source.createCatalogNote(sourceID: paper.id, quote: "保留原文", comment: "保留评论", pageIndex: 2, fileHash: "stable-file-hash")
        let link = "tokenlibrary://document/\(paper.id)?page=3&hash=stable-file-hash"
        let otherID = UUID().uuidString.lowercased(), other = "tokenlibrary://document/\(otherID)?page=1"
        note.markdown += "\n[引用][source]\n\n[source]: \(link)\n\n`[代码](\(link))`\n\n```md\n[示例](\(link))\n```\n\n[其他](\(other))\n"
        var metadata = try XCTUnwrap(JSONValue.parse(note.metadataJSON).object)
        var excerpts = try XCTUnwrap(metadata["excerpts"]?.array)
        var excerpt = try XCTUnwrap(excerpts[0].object)
        excerpt["futureField"] = .object(["keep": .bool(true)])
        excerpts[0] = .object(excerpt); metadata["excerpts"] = .array(excerpts)
        note.metadataJSON = try JSONValue.object(metadata).jsonString()
        try source.saveDocument(note, enqueue: true)
        let unrelated = doc(id: paper.id, name: "existing.md", body: "existing unrelated content")
        try target.saveDocument(unrelated, enqueue: false)
        let before = try source.listDocuments(includeTrashed: true), pending = try source.pending()
        let result = try target.importLocalLibrary(from: source, sourceRootID: "root", targetRootID: "root")
        let copiedID = try XCTUnwrap(result.documentIDMap[paper.id])
        XCTAssertNotEqual(copiedID, paper.id)
        let copiedNote = try XCTUnwrap(target.loadDocument(id: XCTUnwrap(result.documentIDMap[note.id])))
        XCTAssertEqual(copiedNote.catalog.sourceIDs, [copiedID])
        XCTAssertEqual(copiedNote.catalog.excerpts.first?.sourceID, copiedID)
        XCTAssertEqual(copiedNote.catalog.excerpts.first?.fileHash, "stable-file-hash")
        XCTAssertEqual(copiedNote.catalog.excerpts.first?.quote, "保留原文")
        XCTAssertEqual(copiedNote.catalog.excerpts.first?.comment, "保留评论")
        let links = try MarkdownReferences(copiedNote.markdown).references.map(\.destination)
        XCTAssertEqual(links.filter { $0 == "tokenlibrary://document/\(copiedID)?page=3&hash=stable-file-hash" }.count, 2)
        XCTAssertFalse(links.contains(link)); XCTAssertTrue(links.contains(other))
        XCTAssertTrue(copiedNote.markdown.contains("`[代码](\(link))`"))
        XCTAssertTrue(copiedNote.markdown.contains("```md\n[示例](\(link))\n```"))
        XCTAssertEqual(try JSONValue.parse(copiedNote.metadataJSON).object?["excerpts"]?.array?.first?.object?["futureField"], .object(["keep": .bool(true)]))
        XCTAssertEqual(try target.loadDocument(id: paper.id), unrelated)
        XCTAssertEqual(try target.catalogBacklinks(to: copiedID).map(\.id), [copiedNote.id])
        XCTAssertTrue(try target.catalogBacklinks(to: paper.id).isEmpty)
        XCTAssertEqual(try source.listDocuments(includeTrashed: true), before)
        XCTAssertEqual(try source.pending(), pending)
    }

    func testCopiedPDFOnlyRebindsPlacementsValidForOriginalAndPreservesUnknownJSON() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        for knownSource in [true, false] {
            let source = try DocumentStore(directory: directory.appendingPathComponent("source-\(knownSource)")), target = try DocumentStore(directory: directory.appendingPathComponent("target-\(knownSource)"))
            let asset = try source.importAttachment(data: PDFExport.makeSamplePDF(text: "same original bytes"), fileName: "paper.pdf", mime: "application/pdf")
            var document = doc(kind: .pdf, name: "paper.pdf", body: "")
            document.pdfPath = try source.resolveAttachment(path: asset.path).path
            document.pdfBlobId = knownSource ? asset.blobId : nil
            let states: [(String, String?, String?)] = [("current", asset.blobId, nil), ("legacy", nil, nil), ("older", "other-version", "attached"), ("review", asset.blobId, "needs_review"), ("future", asset.blobId, "unknown_state")]
            document.annotationsJSON = try JSONValue.array(states.map { id, blob, placement in
                var object: [String: JSONValue] = ["id": .string(id), "type": .string("comment"), "pageIndex": .integer(0), "x": .integer(10), "y": .integer(10), "width": .integer(60), "height": .integer(20), "color": .string("#FF0000"), "text": .string(id), "futureField": .object(["keep": .bool(true)])]
                if let blob { object["pdfBlobId"] = .string(blob) }
                if let placement { object["placementState"] = .string(placement) }
                return .object(object)
            }).jsonString()
            try source.saveDocument(document, enqueue: true)
            let result = try target.importLocalLibrary(from: source, sourceRootID: "root", targetRootID: "root")
            let copied = try XCTUnwrap(target.loadDocument(id: XCTUnwrap(result.documentIDMap[document.id])))
            let values = try XCTUnwrap(JSONValue.parse(copied.annotationsJSON).array)
            for value in values {
                let object = try XCTUnwrap(value.object), id = try XCTUnwrap(object["id"]?.string)
                XCTAssertEqual(object["futureField"], .object(["keep": .bool(true)]))
                if id == "legacy" || (knownSource && id == "current") { XCTAssertEqual(object["pdfBlobId"]?.string, copied.pdfBlobId) }
                else { XCTAssertEqual(object["placementState"]?.string, "needs_review"); XCTAssertNotEqual(object["pdfBlobId"]?.string, copied.pdfBlobId) }
            }
            let annotations = try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(copied.annotationsJSON.utf8))
            XCTAssertEqual(annotations.filter { !$0.needsPlacementReview(for: copied.pdfBlobId) }.count, knownSource ? 2 : 1)
            XCTAssertEqual(try source.loadDocument(id: document.id)?.annotationsJSON, document.annotationsJSON)
        }
    }

    func testFailedImportLeavesSourceAndTargetDocumentsUnchanged() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DocumentStore(directory: directory.appendingPathComponent("source")), target = try DocumentStore(directory: directory.appendingPathComponent("target"))
        let document = doc(body: "![](media/missing.png)")
        try source.saveDocument(document, enqueue: true)
        XCTAssertThrowsError(try target.importLocalLibrary(from: source, sourceRootID: "root", targetRootID: "remote-root"))
        XCTAssertTrue(try target.listDocuments(includeTrashed: true).isEmpty)
        XCTAssertEqual(try source.loadDocument(id: document.id)?.markdown, document.markdown)
        XCTAssertEqual(try source.pending().count, 1)
    }

    func testFolderRestorePreservesPreviouslyTrashedChildAndSearchUsesFTS() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        let folder = doc(kind: .folder, name: "研究主题"), active = doc(parent: folder.id, body: "个人图书馆 Swift SQLite"), oldTrash = doc(parent: folder.id, name: "旧文献.md")
        for item in [folder, active, oldTrash] { try store.saveDocument(item, enqueue: true) }
        XCTAssertEqual(try store.search(query: "馆 swift"), [active.id])
        try store.trash(id: oldTrash.id); try store.trash(id: folder.id)
        XCTAssertTrue(try store.search(query: "馆 swift").isEmpty)
        try store.restore(id: folder.id)
        XCTAssertEqual(try store.loadDocument(id: oldTrash.id)?.state, "trashed")
        XCTAssertEqual(try store.search(query: "图书 swift"), [active.id])
    }

    func testGateSerializesSameWorkspaceAllowsOthersAndCancelledWaiterNeverRuns() async throws {
        let gate = WorkspaceSyncGate(), entered = expectation(description: "first entered"), otherEntered = expectation(description: "other workspace")
        let release = GateTestLatch(), log = GateTestLog()
        let first = Task {
            try await gate.withPermit(key: "same") {
                entered.fulfill(); await log.append("first-start"); await release.wait(); await log.append("first-end")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let cancelled = Task { try await gate.withPermit(key: "same") { await log.append("cancelled-must-not-run") } }
        cancelled.cancel()
        let second = Task { try await gate.withPermit(key: "same") { await log.append("second") } }
        try await gate.withPermit(key: "different") { otherEntered.fulfill() }
        await fulfillment(of: [otherEntered], timeout: 2)
        await release.release()
        try await first.value; try await second.value
        do { try await cancelled.value; XCTFail("waiting cancellation must propagate") } catch { XCTAssertTrue(error is CancellationError) }
        let events = await log.events
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }
}

private actor GateTestLatch {
    private var ready = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !ready { await withCheckedContinuation { continuation = $0 } } }
    func release() { ready = true; continuation?.resume(); continuation = nil }
}
private actor GateTestLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}
