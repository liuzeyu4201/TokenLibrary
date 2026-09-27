import XCTest
import GRDB
@testable import LibraryCore

final class EditorEditTests: XCTestCase {
    private func makeStore() throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-edits-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try DocumentStore(directory: root)
    }

    private func document(id: String = "note", kind: DocKind = .md, parent: String = "root", markdown: String = "first\nsecond\nthird") -> LibraryDocument {
        LibraryDocument(id: id, kind: kind, parentId: parent, name: kind == .pdf ? "paper.pdf" : kind == .folder ? id : "note.md",
            markdown: markdown, pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil,
            status: .savedLocal, annotationsJSON: "[]")
    }

    private func annotation(id: String = "a", text: String = "annotation") -> PDFTextAnnotation {
        PDFTextAnnotation(id: id, type: "comment", pageIndex: 0, x: 10, y: 20, width: 100, height: 30, color: "#FFFF00", text: text)
    }

    func testTwoOpenEditorsMergeIndependentChangesAndQueueCanonicalBody() throws {
        let store = try makeStore(), original = document()
        try store.saveDocument(original, enqueue: false)
        let left = try store.beginMarkdownEdit(id: original.id), right = try store.beginMarkdownEdit(id: original.id)
        _ = try left.save("FIRST\nsecond\nthird")
        let saved = try right.save("first\nsecond\nTHIRD")
        guard case .saved(let text, let doc) = saved else { return XCTFail("Independent edits must merge") }
        XCTAssertEqual(text, "FIRST\nsecond\nTHIRD"); XCTAssertEqual(doc.markdown, text)
        let queue = try store.pending()
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(try JSONValue.parse(queue[0].payload).object?["markdownSource"]?.string, text)
        XCTAssertEqual(try store.search(query: "THIRD"), [original.id])
    }

    func testExplicitBaseHandlesNextKeystrokesBasedOnSubmittedNotCanonicalText() throws {
        let store = try makeStore(); try store.saveDocument(document(), enqueue: false)
        let editor = try store.beginMarkdownEdit(id: "note")
        _ = try store.updateMarkdown(id: "note", markdown: "FIRST\nsecond\nthird")
        _ = try editor.save(baseMarkdown: editor.initialMarkdown, proposedMarkdown: "first\nsecond\nTHIRD")
        let result = try editor.save(baseMarkdown: "first\nsecond\nTHIRD", proposedMarkdown: "first\nsecond\nTHIRD typed")
        guard case .saved(let markdown, _) = result else { return XCTFail("Queued keystrokes should merge") }
        XCTAssertEqual(markdown, "FIRST\nsecond\nTHIRD typed")
    }

    func testOverlappingEditsStayDurableAndSameSessionUpdatesOneDraft() throws {
        let store = try makeStore(); try store.saveDocument(document(), enqueue: false)
        let editor = try store.beginMarkdownEdit(id: "note")
        _ = try store.updateMarkdown(id: "note", markdown: "remote\nsecond\nthird")
        guard case .conflict(let canonical, let firstID) = try editor.save("local\nsecond\nthird") else { return XCTFail("Expected conflict") }
        XCTAssertEqual(canonical, "remote\nsecond\nthird")
        guard case .conflict(_, let nextID) = try editor.save("local typed\nsecond\nthird") else { return XCTFail("Expected retained conflict") }
        XCTAssertEqual(firstID, nextID)
        let reopened = try DocumentStore(directory: store.root)
        let drafts = try reopened.editorDrafts()
        XCTAssertEqual(drafts.count, 1); XCTAssertEqual(drafts[0].proposedMarkdown, "local typed\nsecond\nthird")
        XCTAssertEqual(try reopened.loadDocument(id: "note")?.markdown, canonical)
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(reopened.pending().last).payload).object?["markdownSource"]?.string, canonical)
        let copy = try reopened.recoverEditorDraftAsCopy(id: firstID, parentId: "root")
        XCTAssertNotEqual(copy.id, "note"); XCTAssertEqual(copy.markdown, drafts[0].proposedMarkdown)
        XCTAssertTrue(try reopened.editorDrafts().isEmpty)
        XCTAssertEqual(try reopened.loadDocument(id: "note")?.markdown, canonical)
    }

    func testLateEditAfterTrashAndPurgeNeverRevivesOriginal() throws {
        let store = try makeStore(); try store.saveDocument(document(), enqueue: false)
        let editor = try store.beginMarkdownEdit(id: "note")
        try store.trash(id: "note")
        guard case .conflict(_, let draftID) = try editor.save("late edit") else { return XCTFail("Trash must retain a draft") }
        XCTAssertEqual(try store.loadDocument(id: "note")?.state, "trashed")
        XCTAssertEqual(try store.loadDocument(id: "note")?.markdown, editor.initialMarkdown)
        _ = try store.purgeExpired(now: .distantFuture)
        _ = try editor.save("last keystroke after purge")
        XCTAssertNil(try store.loadDocument(id: "note"))
        let reopened = try DocumentStore(directory: store.root)
        let copy = try reopened.recoverEditorDraftAsCopy(id: draftID, parentId: "root")
        XCTAssertNotEqual(copy.id, "note"); XCTAssertEqual(copy.markdown, "last keystroke after purge")
        XCTAssertNil(try reopened.loadDocument(id: "note"))
        XCTAssertEqual(copy.state, "active")
    }

    func testSessionRemainsBoundToItsOriginalStoreAcrossWorkspaceSwitch() throws {
        let first = try makeStore(), second = try makeStore()
        try first.saveDocument(document(markdown: "first workspace"), enqueue: false)
        try second.saveDocument(document(markdown: "other workspace"), enqueue: false)
        let oldEditor = try first.beginMarkdownEdit(id: "note")
        _ = try oldEditor.save("old webview final keystroke")
        XCTAssertEqual(try first.loadDocument(id: "note")?.markdown, "old webview final keystroke")
        XCTAssertEqual(try second.loadDocument(id: "note")?.markdown, "other workspace")
    }

    func testRemoteTombstoneRetainedForPendingConflictDoesNotAcceptLateEditorWrites() throws {
        let store = try makeStore(); try store.saveDocument(document(), enqueue: true)
        let editor = try store.beginMarkdownEdit(id: "note")
        try store.db.write { db in try store.applyTombstone("note", db: db) }
        // Sync retains this row for its earlier unsent work, but the remote ID
        // is already dead. New editor input belongs in a recovery draft only.
        XCTAssertNotNil(try store.loadDocument(id: "note"))
        guard case .conflict(_, let draftID) = try editor.save("late after remote delete") else { return XCTFail("Expected draft") }
        XCTAssertEqual(try store.loadDocument(id: "note")?.markdown, editor.initialMarkdown)
        XCTAssertEqual(try store.editorDrafts().first?.id, draftID)
        let copy = try store.recoverEditorDraftAsCopy(id: draftID, parentId: "root")
        XCTAssertNotEqual(copy.id, "note"); XCTAssertEqual(copy.markdown, "late after remote delete")
    }

    func testRecoveryPreservesRelativeAttachmentsAndPortableExport() throws {
        let store = try makeStore()
        let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let asset = try store.importAttachment(data: bytes, fileName: "photo.png", mime: "image/png")
        try store.saveDocument(document(markdown: "base"), enqueue: false)
        let editor = try store.beginMarkdownEdit(id: "note")
        _ = try store.updateMarkdown(id: "note", markdown: "remote")
        let proposed = "my work\n![](\(asset.path))"
        guard case .conflict(_, let id) = try editor.save(proposed) else { return XCTFail("Expected draft") }
        let copy = try store.recoverEditorDraftAsCopy(id: id, parentId: "root")
        XCTAssertEqual(copy.markdown, proposed)
        XCTAssertEqual(try Data(contentsOf: store.resolveAttachment(path: asset.path)), bytes)
        let exported = try store.exportPortableMarkdown(id: copy.id)
        XCTAssertTrue(exported.isArchive)
        XCTAssertNotNil(exported.data.range(of: Data(asset.path.utf8)))
        XCTAssertNotNil(exported.data.range(of: bytes))
    }

    func testFailedQueueInsertRollsBackBodyAndSearchChanges() throws {
        let store = try makeStore(); try store.saveDocument(document(), enqueue: false)
        try store.db.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_queue BEFORE INSERT ON pending_operations BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END")
        }
        XCTAssertThrowsError(try store.saveMarkdownEdit(id: "note", baseMarkdown: "first\nsecond\nthird", proposedMarkdown: "unique replacement"))
        XCTAssertEqual(try store.loadDocument(id: "note")?.markdown, "first\nsecond\nthird")
        XCTAssertTrue(try store.pending().isEmpty); XCTAssertTrue(try store.search(query: "replacement").isEmpty)
    }

    func testConcurrentIndependentEditorsDoNotLoseUpdates() async throws {
        let store = try makeStore()
        let original = (0..<16).map { "line-\($0)" }.joined(separator: "\n")
        try store.saveDocument(document(markdown: original), enqueue: false)
        let sessions = try (0..<16).map { _ in try store.beginMarkdownEdit(id: "note") }
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<16 {
                let session = sessions[index]
                var lines = original.components(separatedBy: "\n"); lines[index] = "edited-\(index)"
                let proposed = lines.joined(separator: "\n")
                group.addTask {
                    guard let result = try? session.save(proposed) else { return false }
                    if case .saved = result { return true }; return false
                }
            }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(try store.loadDocument(id: "note")?.markdown, (0..<16).map { "edited-\($0)" }.joined(separator: "\n"))
        XCTAssertTrue(try store.editorDrafts().isEmpty)
    }

    func testPDFIndependentEditsMergeAndOverlappingEditsPersistDraft() throws {
        let store = try makeStore(); var pdf = document(kind: .pdf)
        pdf.pdfBlobId = "blob-one"; pdf.pdfPath = "/tmp/synthetic-pdf-one.pdf"
        pdf.annotationsJSON = String(decoding: try JSONEncoder().encode([annotation()]), as: UTF8.self)
        try store.saveDocument(pdf, enqueue: false)
        let first = try store.savePDFAnnotationEdit(id: pdf.id, expectedPDFBlobId: pdf.pdfBlobId, expectedPDFPath: pdf.pdfPath,
            base: [annotation()], proposed: [annotation(text: "remote edit")])
        let second = try store.savePDFAnnotationEdit(id: pdf.id, expectedPDFBlobId: pdf.pdfBlobId, expectedPDFPath: pdf.pdfPath,
            base: [annotation()], proposed: [annotation(), annotation(id: "b")])
        XCTAssertEqual(second.map(\.id), ["a", "b"]); XCTAssertEqual(second.first?.text, "remote edit")
        for text in ["local edit", "local continued"] {
            XCTAssertThrowsError(try store.savePDFAnnotationEdit(id: pdf.id, expectedPDFBlobId: pdf.pdfBlobId, expectedPDFPath: pdf.pdfPath,
                base: [annotation()], proposed: [annotation(text: text)])) { error in
                guard case EditorEditError.annotationConflict = error else { return XCTFail("Unexpected error \(error)") }
            }
        }
        let drafts = try store.editorDrafts()
        XCTAssertEqual(drafts.count, 1); XCTAssertEqual(drafts[0].proposedAnnotations.first?.text, "local continued")
        let actual = try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(XCTUnwrap(store.loadDocument(id: pdf.id)).annotationsJSON.utf8))
        XCTAssertEqual(actual, second); XCTAssertEqual(first.first?.text, "remote edit")
    }

    func testPDFReplacementCannotReceiveOldAnnotationsAndDraftRecoversOldFile() throws {
        let store = try makeStore(); var pdf = document(kind: .pdf)
        let originalPath = store.root.appendingPathComponent("old.pdf").path
        try PDFExport.makeSamplePDF(text: "old source").write(to: URL(fileURLWithPath: originalPath))
        pdf.pdfBlobId = "old-blob"; pdf.pdfPath = originalPath; try store.saveDocument(pdf, enqueue: false)
        pdf.pdfBlobId = "new-blob"; pdf.pdfPath = store.root.appendingPathComponent("new.pdf").path
        try store.saveDocument(pdf, enqueue: false)
        XCTAssertThrowsError(try store.savePDFAnnotationEdit(id: pdf.id, expectedPDFBlobId: "old-blob", expectedPDFPath: originalPath,
            base: [], proposed: [annotation()])) { error in
                guard case EditorEditError.pdfChanged = error else { return XCTFail("Unexpected error \(error)") }
            }
        XCTAssertEqual(try store.loadDocument(id: pdf.id)?.annotationsJSON, "[]")
        let draft = try XCTUnwrap(store.editorDrafts().first)
        let reopened = try DocumentStore(directory: store.root)
        let recovered = try reopened.recoverEditorDraftAsCopy(id: draft.id, parentId: "root")
        XCTAssertEqual(recovered.pdfBlobId, "old-blob"); XCTAssertEqual(recovered.pdfPath, originalPath)
        XCTAssertEqual(try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(recovered.annotationsJSON.utf8)), [annotation()])
        XCTAssertEqual(try reopened.loadDocument(id: pdf.id)?.pdfBlobId, "new-blob")
    }

    func testPDFDraftSurvivesMissingFileRecoveryAndCanBeDiscardedExplicitly() throws {
        let store = try makeStore(); var pdf = document(kind: .pdf)
        pdf.pdfBlobId = "new"; try store.saveDocument(pdf, enqueue: false)
        XCTAssertThrowsError(try store.savePDFAnnotationEdit(id: pdf.id, expectedPDFBlobId: "old", expectedPDFPath: "/nonexistent/test.pdf", base: [], proposed: [annotation()]))
        let id = try XCTUnwrap(store.editorDrafts().first?.id)
        XCTAssertThrowsError(try store.recoverEditorDraftAsCopy(id: id, parentId: "root"))
        XCTAssertEqual(try store.editorDrafts().count, 1)
        try store.discardEditorDraft(id: id)
        XCTAssertTrue(try store.editorDrafts().isEmpty)
    }

    func testPDFVersionDraftRecoveryHashesRecoveredBytesAndPreservesOtherMetadata() throws {
        let store = try makeStore()
        let oldBytes = PDFExport.makeSamplePDF(text: "Original version retained for the old annotation")
        let newBytes = PDFExport.makeSamplePDF(text: "Replacement version must keep its own identity")
        let old = try store.importAttachment(data: oldBytes, fileName: "original.pdf", mime: "application/pdf")
        let replacement = try store.importAttachment(data: newBytes, fileName: "replacement.pdf", mime: "application/pdf")
        var pdf = document(id: UUID().uuidString.lowercased(), kind: .pdf)
        pdf.pdfBlobId = replacement.blobId
        pdf.pdfPath = try store.resolveAttachment(path: replacement.path).path
        pdf.metadataJSON = try JSONValue.object([
            "category": .string("paper"), "title": .string("Latest bibliography"),
            "authors": .array([.string("Author retained")]), "year": .number(2026),
            "originalFileHash": .string(replacement.sha256),
            "futureCatalogField": .object(["keep": .array([.string("unknown"), .number(7)])])
        ]).jsonString()
        try store.saveDocument(pdf, enqueue: false)
        let originalCurrent = try XCTUnwrap(store.loadDocument(id: pdf.id))
        let oldPath = try store.resolveAttachment(path: old.path).path
        let proposed = [annotation(text: "Unsaved text on the original version")]
        XCTAssertThrowsError(try store.savePDFAnnotationEdit(id: pdf.id,
            expectedPDFBlobId: old.blobId, expectedPDFPath: oldPath, base: [], proposed: proposed)) {
            guard case EditorEditError.pdfChanged = $0 else { return XCTFail("Expected stale-version draft") }
        }
        let draft = try XCTUnwrap(store.editorDrafts().first)
        // A persisted draft created from the latest document can contain the
        // replacement's metadata. Reopening must still recover the old bytes.
        let reopened = try DocumentStore(directory: store.root)
        let copy = try reopened.recoverEditorDraftAsCopy(id: draft.id, parentId: "root")
        XCTAssertEqual(copy.pdfBlobId, old.blobId)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(copy.pdfPath))), oldBytes)
        XCTAssertEqual(copy.catalog.originalFileHash, old.sha256)
        var expectedMetadata = try XCTUnwrap(JSONValue.parse(originalCurrent.metadataJSON).object)
        expectedMetadata["originalFileHash"] = .string(old.sha256)
        XCTAssertEqual(try JSONValue.parse(copy.metadataJSON).object, expectedMetadata)
        XCTAssertEqual(try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(copy.annotationsJSON.utf8)), proposed)
        XCTAssertEqual(try reopened.loadDocument(id: pdf.id), originalCurrent)
        XCTAssertTrue(try reopened.editorDrafts().isEmpty)
        let queue = try reopened.pending()
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.objectId, copy.id)
        XCTAssertNotEqual(copy.id, pdf.id)
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(queue.first?.payload)).object?["metadata"]?.object?["originalFileHash"]?.string, old.sha256)
    }

    func testMultipleDisjointLineEditsAndBoundaryInsertsMergeWithoutReordering() {
        XCTAssertEqual(EditorMarkdownMerge.merge(base: "a\nb\nc\nd\ne", local: "A\nb\nc\nd\nE", remote: "a\nb\nC\nd\ne"), "A\nb\nC\nd\nE")
        XCTAssertEqual(EditorMarkdownMerge.merge(base: "a\nb\nc", local: "a\ninsert\nb\nc", remote: "a\nB\nc"), "a\ninsert\nB\nc")
        XCTAssertEqual(EditorMarkdownMerge.merge(base: "a\nb\nc", local: "a\nb\ninsert\nc", remote: "a\nB\nc"), "a\nB\ninsert\nc")
        XCTAssertNil(EditorMarkdownMerge.merge(base: "a\nb", local: "a\nleft\nb", remote: "a\nright\nb"))
        XCTAssertNil(EditorMarkdownMerge.merge(base: "a\nb\nc", local: "a\nc", remote: "a\nB\nc"))
    }

    func testLargeReplacementsUseBoundedConservativeMergeAndKeepBothDraftMaterials() throws {
        let store = try makeStore()
        let base = (0..<10_000).map { "base-\($0)" }.joined(separator: "\n")
        let remote = (0..<10_000).map { "remote-\($0)" }.joined(separator: "\n")
        let proposed = (0..<10_000).map { "local-\($0)" }.joined(separator: "\n")
        try store.saveDocument(document(markdown: base), enqueue: false)
        let session = try store.beginMarkdownEdit(id: "note")
        _ = try store.updateMarkdown(id: "note", markdown: remote)
        guard case .conflict(_, let draftID) = try session.save(proposed) else { return XCTFail("Competing replacement must remain a draft") }
        let draft = try XCTUnwrap(store.editorDrafts().first)
        XCTAssertEqual(draft.id, draftID); XCTAssertEqual(draft.baseMarkdown, base)
        XCTAssertEqual(draft.proposedMarkdown, proposed); XCTAssertEqual(draft.currentMarkdown, remote)
        XCTAssertEqual(try store.loadDocument(id: "note")?.markdown, remote)
    }

    func testHierarchyKeepsRealRootsSeparateAndRejectsBrokenAncestry() {
        let docs = [document(id: "server-a", kind: .folder, parent: ""), document(id: "server-b", kind: .folder, parent: ""),
            document(id: "a", parent: "server-a"), document(id: "b", parent: "server-b"), document(id: "local", parent: "root"),
            document(id: "broken", parent: "missing"), document(id: "cycle-a", kind: .folder, parent: "cycle-b"),
            document(id: "cycle-b", kind: .folder, parent: "cycle-a"), document(id: "bad-parent", parent: "a")]
        XCTAssertEqual(LibraryHierarchy.rootID(for: "server-a", documents: docs), "server-a")
        XCTAssertEqual(LibraryHierarchy.rootID(for: "a", documents: docs), "server-a")
        XCTAssertEqual(LibraryHierarchy.rootID(for: "b", documents: docs), "server-b")
        XCTAssertEqual(LibraryHierarchy.rootID(for: "local", documents: docs), "root")
        XCTAssertEqual(LibraryHierarchy.rootID(for: "root", documents: docs), "root")
        for id in ["broken", "cycle-a", "missing", "bad-parent", ""] { XCTAssertNil(LibraryHierarchy.rootID(for: id, documents: docs), id) }
    }
}
