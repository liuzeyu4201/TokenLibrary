import Foundation
import XCTest
@testable import LibraryCore

final class CatalogTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }
    private func makeStore() throws -> DocumentStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-tests-\(UUID().uuidString)")
        directories.append(url)
        return try DocumentStore(directory: url)
    }
    @discardableResult
    private func seed(_ store: DocumentStore, name: String = "paper.pdf", kind: DocKind = .pdf, parent: String = "root", metadata: String = "{}", path: String? = nil) throws -> LibraryDocument {
        let doc = LibraryDocument(id: UUID().uuidString.lowercased(), kind: kind, parentId: parent, name: name,
                                  markdown: kind == .md ? "# Existing content\n" : "", pdfPath: path,
                                  revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal,
                                  annotationsJSON: "[]", metadataJSON: metadata)
        try store.saveDocument(doc, enqueue: false)
        return doc
    }

    func testShelfColorAppliesToFoldersAndFilesAndClearsWithoutDroppingUnknownMetadata() throws {
        let store = try makeStore()
        let folder = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .folder, parentId: "root", name: "备忘录",
                                     markdown: "", pdfPath: nil, revision: 1, localGeneration: 0, state: "active", purgeAt: nil,
                                     status: .savedLocal, annotationsJSON: "[]", metadataJSON: #"{"future":true}"#)
        try store.saveDocument(folder, enqueue: false)
        let note = try seed(store, name: "笔记.md", kind: .md, metadata: "{}")
        let coloredFolder = try store.setShelfColor(id: folder.id, hex: "#3e6b4f")
        let coloredNote = try store.setShelfColor(id: note.id, hex: "#8C3A4A")
        XCTAssertEqual(coloredFolder.catalog.shelfColor, "#3E6B4F")
        XCTAssertEqual(coloredFolder.name, "备忘录")
        XCTAssertEqual(coloredNote.catalog.shelfColor, "#8C3A4A")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(coloredFolder.metadataJSON.utf8)) as? [String: Any])
        XCTAssertEqual(raw["future"] as? Bool, true)
        XCTAssertEqual(raw["shelfColor"] as? String, "#3E6B4F")
        let queued = try store.pending().filter { $0.objectId == folder.id || $0.objectId == note.id }
        XCTAssertEqual(queued.count, 2)
        XCTAssertTrue(queued.contains { $0.payload.contains("#3E6B4F") })
        let cleared = try store.setShelfColor(id: folder.id, hex: "")
        XCTAssertEqual(cleared.catalog.shelfColor, "")
        XCTAssertThrowsError(try store.setShelfColor(id: note.id, hex: "blue"))
        XCTAssertEqual(try store.loadDocument(id: note.id)?.catalog.shelfColor, "#8C3A4A")
        XCTAssertEqual(CatalogMetadata.decode("{}", kind: .folder).shelfColor, "")
    }

    func testOlderDocumentsDecodeWithoutInventingClassificationOrInbox() throws {
        let pdf = CatalogMetadata.decode("{}", kind: .pdf)
        XCTAssertEqual(pdf.category, .unclassified)
        XCTAssertFalse(pdf.inbox)
        XCTAssertFalse(pdf.archived)
        XCTAssertEqual(CatalogMetadata.decode("{}", kind: .md).category, .note)
        let partial = CatalogMetadata.decode(#"{"title":"中文论文","authors":["机构作者"],"category":"future-kind"}"#, kind: .pdf)
        XCTAssertEqual(partial.title, "中文论文")
        XCTAssertEqual(partial.authors, ["机构作者"])
        XCTAssertEqual(partial.category, .unclassified)
    }

    func testReplacingPDFOriginalKeepsTheItemAndMarksOldCoordinatesForReview() throws {
        let store = try makeStore()
        let original = PDFExport.makeSamplePDF(text: "Original page coordinates belong to this file")
        let revised = PDFExport.makeSamplePDF(text: "Revised pages must not inherit those coordinates")
        let oldAsset = try store.importAttachment(data: original, fileName: "paper.pdf", mime: "application/pdf")
        let oldPath = try store.resolveAttachment(path: oldAsset.path).path
        let annotation = PDFTextAnnotation(type: "highlight", pageIndex: 0, x: 0.1, y: 0.2, width: 0.3, height: 0.05, color: "yellow", text: "old highlight", pdfBlobId: oldAsset.blobId)
        let annotations = String(data: try JSONEncoder().encode([annotation]), encoding: .utf8)!
        var pdf = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .pdf, parentId: "root", name: "paper.pdf",
                                   markdown: "", pdfPath: oldPath, revision: 0, localGeneration: 0, state: "active", purgeAt: nil,
                                   status: .savedLocal, annotationsJSON: annotations, pdfBlobId: oldAsset.blobId)
        var metadata = CatalogMetadata(category: .paper)
        metadata.originalFileHash = oldAsset.sha256
        pdf.metadataJSON = try metadata.json()
        try store.saveDocument(pdf, enqueue: false)
        let note = try store.createCatalogNote(sourceID: pdf.id, quote: "Original page coordinates", pageIndex: 0, fileHash: oldAsset.sha256)
        XCTAssertEqual(FileNames.availableName("paper.pdf", kind: .pdf, takenKeys: ["paper.pdf"]), "paper_1.pdf")

        let outcome = try store.replacePDFOriginal(id: pdf.id, data: revised, fileName: "paper.pdf")

        XCTAssertEqual(outcome.document.id, pdf.id)
        XCTAssertEqual(outcome.document.name, "paper.pdf")
        XCTAssertEqual(outcome.newBlobID, outcome.document.pdfBlobId)
        XCTAssertNotEqual(outcome.newBlobID, oldAsset.blobId)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: oldPath)), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(outcome.document.pdfPath))), revised)
        let saved = try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(outcome.document.annotationsJSON.utf8))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].pdfBlobId, oldAsset.blobId)
        XCTAssertEqual(saved[0].placementState, "needs_review")
        XCTAssertEqual(saved[0].pageIndex, 0)
        XCTAssertTrue(saved[0].needsPlacementReview(for: outcome.newBlobID))
        XCTAssertEqual(try store.catalogSourceState(for: XCTUnwrap(note.catalog.excerpts.first)), .fileChanged)
        XCTAssertEqual(try store.listDocuments().filter { $0.kind == .pdf }.count, 1)
        XCTAssertEqual(outcome.reviewMessage.contains("需要核对"), true)
    }

    func testReplacingPDFUploadsThePreviousLocalBlobBeforeSync() async throws {
        let store = try makeStore()
        let original = PDFExport.makeSamplePDF(text: "Coordinates belong to the first original")
        let revised = PDFExport.makeSamplePDF(text: "The replacement is a different file")
        let oldAsset = try store.importAttachment(data: original, fileName: "paper.pdf", mime: "application/pdf")
        XCTAssertEqual(try store.transfer(blobId: oldAsset.blobId)?.state, "local")
        let annotation = PDFTextAnnotation(type: "highlight", pageIndex: 0, x: 0.1, y: 0.2, width: 0.3, height: 0.05, color: "yellow", text: "old highlight", pdfBlobId: oldAsset.blobId)
        let pdf = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .pdf, parentId: "root", name: "paper.pdf",
                                   markdown: "", pdfPath: try store.resolveAttachment(path: oldAsset.path).path, revision: 0, localGeneration: 0, state: "active", purgeAt: nil,
                                   status: .savedLocal, annotationsJSON: String(decoding: try JSONEncoder().encode([annotation]), as: UTF8.self), pdfBlobId: oldAsset.blobId)
        try store.saveDocument(pdf, enqueue: false)
        let outcome = try store.replacePDFOriginal(id: pdf.id, data: revised, fileName: "revised.pdf")
        XCTAssertEqual(try store.transfer(blobId: oldAsset.blobId)?.state, "local")
        XCTAssertNotEqual(outcome.newBlobID, oldAsset.blobId)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blob-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let scriptURL = directory.appendingPathComponent("uploads.py")
        let logURL = directory.appendingPathComponent("uploads.jsonl")
        let script = """
        import json, sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        logp = sys.argv[1]
        class H(BaseHTTPRequestHandler):
            def _send(self, code, payload):
                raw = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return self.rfile.read(n)
            def _log(self, item):
                with open(logp, "a") as handle:
                    handle.write(json.dumps(item) + "\\n")
            def do_POST(self):
                raw = self._body()
                if self.path == "/api/v1/uploads":
                    body = json.loads(raw)
                    self._log({"path": self.path, "blobId": body["blobId"]})
                    self._send(200, {"data": {"uploadId": body["blobId"], "chunkSize": 1048576, "state": "uploading"}})
                    return
                if self.path.endswith("/complete"):
                    blob = self.path.split("/")[-2]
                    self._log({"path": "complete", "blobId": blob})
                    self._send(200, {"data": {"blobId": blob, "state": "ready"}})
                    return
                self._send(200, {"data": {}})
            def do_GET(self):
                self._send(200, {"data": {"state": "uploading", "chunks": []}})
            def do_PUT(self):
                self._body()
                self._send(200, {"data": {}})
            def log_message(self, *args):
                pass
        httpd = HTTPServer(("127.0.0.1", 0), H)
        print(str(httpd.server_address[1]).ljust(16), flush=True)
        httpd.serve_forever()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, logURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate() }
        let portData = (try? pipe.fileHandleForReading.read(upToCount: 16)) ?? Data()
        let port = try XCTUnwrap(Int(String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, retryPolicy: .none)
        client.sessionToken = "tok"
        client.epoch = UUID().uuidString.lowercased()
        client.libraryId = UUID().uuidString.lowercased()
        try await client.prepareAttachments(objectId: pdf.id, store: store)

        XCTAssertEqual(try store.transfer(blobId: oldAsset.blobId)?.state, "complete")
        XCTAssertEqual(try store.transfer(blobId: outcome.newBlobID)?.state, "complete")
        XCTAssertEqual(try store.loadDocument(id: pdf.id)?.pdfBlobId, outcome.newBlobID)
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let uploaded = lines.filter { $0["path"] == "/api/v1/uploads" }.compactMap { $0["blobId"] }
        XCTAssertEqual(uploaded, [outcome.newBlobID, oldAsset.blobId])
    }

    func testMetadataSurvivesRelaunchAndPreservesUnknownFields() throws {
        let store = try makeStore()
        let doc = try seed(store, metadata: #"{"future":{"nested":true},"year":2020}"#)
        _ = try store.updateCatalog(id: doc.id) {
            $0.category = .paper; $0.title = "分布式系统"; $0.year = nil
            $0.authors = [" Alice ", "Alice", "Bob"]; $0.tags = [" 研究 ", "研究"]
        }
        let loaded = try XCTUnwrap(DocumentStore(directory: store.root).loadDocument(id: doc.id))
        XCTAssertEqual(loaded.name, "paper.pdf", "catalog title must not rename the original")
        XCTAssertEqual(loaded.catalog.authors, ["Alice", "Bob"])
        XCTAssertEqual(loaded.catalog.tags, ["研究"])
        XCTAssertNil(loaded.catalog.year)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(loaded.metadataJSON.utf8)) as? [String: Any])
        XCTAssertEqual((raw["future"] as? [String: Bool])?["nested"], true)
        XCTAssertNil(raw["year"])
        XCTAssertEqual(loaded.status, .pending)
        XCTAssertEqual(try store.pending().count, 1)
    }

    func testTopicMembershipDoesNotMoveOrDuplicateSourceAndArchiveDoesNotCascade() throws {
        let store = try makeStore()
        let source = try seed(store)
        let topicA = try store.createCatalogTopic(name: "研究", parentID: "root")
        let topicB = try store.createCatalogTopic(name: "课程", parentID: "root")
        _ = try store.setCatalogTopic(id: source.id, topicID: topicA.id, included: true)
        _ = try store.setCatalogTopic(id: source.id, topicID: topicB.id, included: true)
        _ = try store.setCatalogTopic(id: source.id, topicID: topicA.id, included: true)
        let assigned = try XCTUnwrap(store.loadDocument(id: source.id))
        XCTAssertEqual(assigned.parentId, source.parentId)
        XCTAssertEqual(Set(assigned.catalog.topicIDs), Set([topicA.id, topicB.id]))
        XCTAssertEqual(try store.listDocuments().filter { $0.kind == .pdf }.count, 1)
        _ = try store.setCatalogArchived(id: topicA.id, archived: true)
        XCTAssertFalse(try XCTUnwrap(store.loadDocument(id: source.id)).catalog.archived)
        _ = try store.setCatalogTopic(id: source.id, topicID: topicA.id, included: false)
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: source.id)).catalog.topicIDs, [topicB.id])
        XCTAssertEqual(try store.catalogDocuments(query: CatalogQuery(topicID: topicB.id)).map(\.id), [source.id])
    }

    func testArchiveKeepsContentOutOfTrashAndRemainsSearchable() throws {
        let store = try makeStore()
        let note = try seed(store, name: "思想.md", kind: .md)
        _ = try store.updateCatalog(id: note.id) { $0.inbox = true; $0.tags = ["长期"] }
        _ = try store.setCatalogArchived(id: note.id, archived: true)
        let archived = try XCTUnwrap(store.loadDocument(id: note.id))
        XCTAssertEqual(archived.state, "active")
        XCTAssertNil(archived.purgeAt)
        XCTAssertFalse(archived.catalog.inbox)
        XCTAssertEqual(archived.markdown, note.markdown)
        XCTAssertTrue(CatalogQuery(text: "长期").matches(archived))
        XCTAssertFalse(CatalogQuery(section: .inbox).matches(archived))
        XCTAssertTrue(CatalogQuery(section: .archived).matches(archived))
        _ = try store.setCatalogArchived(id: note.id, archived: false)
        let restored = try XCTUnwrap(store.loadDocument(id: note.id))
        XCTAssertFalse(restored.catalog.archived)
        XCTAssertNil(restored.catalog.archivedAt)
    }

    func testReadingPositionAllowsRereadingAndKeepsOtherDevice() throws {
        let store = try makeStore()
        let doc = try seed(store)
        _ = try store.recordCatalogReadingPosition(id: doc.id, deviceID: "mac", pageIndex: 29, totalPages: 80, fileHash: "A")
        _ = try store.recordCatalogReadingPosition(id: doc.id, deviceID: "phone", pageIndex: 39, totalPages: 80, fileHash: "A")
        _ = try store.recordCatalogReadingPosition(id: doc.id, deviceID: "mac", pageIndex: 9, totalPages: 80, fileHash: "A")
        let m = try XCTUnwrap(store.loadDocument(id: doc.id)).catalog
        XCTAssertEqual(m.readingPositions.count, 2)
        XCTAssertEqual(m.readingPositions.first { $0.deviceID == "mac" }?.pageIndex, 9)
        XCTAssertEqual(m.readingPositions.first { $0.deviceID == "phone" }?.pageIndex, 39)
        XCTAssertEqual(m.readingStatus, .reading)
        XCTAssertThrowsError(try store.recordCatalogReadingPosition(id: doc.id, deviceID: "mac", pageIndex: 80, totalPages: 80))
        XCTAssertThrowsError(try store.recordCatalogReadingPosition(id: doc.id, deviceID: "mac", pageIndex: -1))
    }

    func testExcerptBodyAndProvenancePersistTogetherAndBacklinkSurvivesRename() throws {
        let store = try makeStore()
        let source = try seed(store)
        _ = try store.updateCatalog(id: source.id) { $0.title = "一篇论文" }
        let note = try store.createCatalogNote(sourceID: source.id, quote: "原文第一行\n原文第二行", comment: "自己的判断", pageIndex: 7)
        XCTAssertTrue(note.markdown.contains("> 原文第一行\n> 原文第二行"))
        XCTAssertTrue(note.markdown.contains("我的笔记："))
        XCTAssertTrue(note.markdown.contains("第 8 页"))
        XCTAssertTrue(note.markdown.contains(source.id))
        XCTAssertEqual(note.catalog.excerpts.first?.sourceID, source.id)
        XCTAssertEqual(try store.catalogBacklinks(to: source.id).map(\.id), [note.id])
        _ = try store.renameDocument(id: source.id, to: "renamed.pdf")
        _ = try store.updateCatalog(id: source.id) { $0.title = "新标题" }
        XCTAssertEqual(try store.catalogBacklinks(to: source.id).map(\.id), [note.id])
        let loaded = try XCTUnwrap(DocumentStore(directory: store.root).loadDocument(id: note.id))
        XCTAssertEqual(loaded.catalog.excerpts.first?.sourceTitle, "一篇论文", "quote keeps source label snapshot")
        XCTAssertEqual(loaded.markdown, note.markdown)
        XCTAssertEqual(try store.pending().filter { $0.objectId == note.id }.count, 1)
    }

    func testRepeatedExcerptOperationIsIdempotentAndArchivedNoteRejectsEditing() throws {
        let store = try makeStore()
        let source = try seed(store)
        let note = try seed(store, name: "note.md", kind: .md)
        let first = try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "citation", excerptID: "stable-operation")
        let retry = try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "citation", excerptID: "stable-operation")
        XCTAssertEqual(first.markdown, retry.markdown)
        XCTAssertEqual(retry.catalog.excerpts.count, 1)
        _ = try store.setCatalogArchived(id: note.id, archived: true)
        XCTAssertThrowsError(try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "new"))
    }

    func testSourceValidationDistinguishesMissingDownloadChangedFileAndTrash() throws {
        let store = try makeStore()
        let file = store.root.appendingPathComponent("source.pdf")
        try Data("original bytes".utf8).write(to: file)
        let source = try seed(store, path: file.path)
        let note = try store.createCatalogNote(sourceID: source.id, quote: "preserved", pageIndex: 3)
        let excerpt = try XCTUnwrap(note.catalog.excerpts.first)
        XCTAssertNotNil(excerpt.fileHash)
        XCTAssertEqual(try store.catalogSourceState(for: excerpt), .available)
        try Data("new bytes".utf8).write(to: file)
        XCTAssertEqual(try store.catalogSourceState(for: excerpt), .fileChanged)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try store.catalogSourceState(for: excerpt), .needsDownload)
        try store.trash(id: source.id)
        XCTAssertEqual(try store.catalogSourceState(for: excerpt), .trashed)
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: note.id)).catalog.excerpts.first?.quote, "preserved")
        var missing = excerpt; missing.sourceID = "nonexistent"
        XCTAssertEqual(try store.catalogSourceState(for: missing), .missing)
    }

    func testRelatedEdgesAreSymmetricWithoutTransitiveInference() throws {
        let store = try makeStore()
        let a = try seed(store, name: "a.pdf"), b = try seed(store, name: "b.pdf"), c = try seed(store, name: "c.pdf")
        _ = try store.setCatalogRelated(id: a.id, targetID: b.id, included: true)
        _ = try store.setCatalogRelated(id: b.id, targetID: a.id, included: true)
        _ = try store.setCatalogRelated(id: b.id, targetID: c.id, included: true)
        XCTAssertEqual(try store.relatedCatalogDocuments(to: a.id).map(\.id), [b.id])
        XCTAssertEqual(Set(try store.relatedCatalogDocuments(to: b.id).map(\.id)), Set([a.id, c.id]))
        _ = try store.setCatalogRelated(id: b.id, targetID: a.id, included: false)
        XCTAssertTrue(try store.relatedCatalogDocuments(to: a.id).isEmpty)
        XCTAssertEqual(try store.relatedCatalogDocuments(to: b.id).map(\.id), [c.id])
    }

    func testCatalogFilterSearchesMetadataQuotesAndDoesNotExposeTrash() throws {
        let store = try makeStore()
        let source = try seed(store)
        let doc = try store.updateCatalog(id: source.id) {
            $0.category = .paper; $0.authors = ["Alice"]; $0.year = 2024
            $0.doi = "10.1000/example"; $0.tags = ["算法"]; $0.title = "共识协议"
        }
        XCTAssertTrue(CatalogQuery(section: .papers, text: "ALICE 共识", tag: "算法", year: 2024).matches(doc))
        XCTAssertTrue(CatalogQuery(text: "10.1000/example").matches(doc))
        XCTAssertFalse(CatalogQuery(section: .books).matches(doc))
        let note = try store.createCatalogNote(sourceID: source.id, quote: "少数派必须等待", comment: "待验证")
        XCTAssertTrue(CatalogQuery(section: .notes, text: "少数派 待验证").matches(note))
        try store.trash(id: source.id)
        XCTAssertFalse(CatalogQuery(text: "Alice").matches(try XCTUnwrap(store.loadDocument(id: source.id))))
    }

    func testCrossLibraryRelationsAndInvalidMetadataCannotMutateSavedDocument() throws {
        let store = try makeStore()
        let doc = try seed(store)
        let otherRoot = try seed(store, kind: .folder, parent: "")
        let other = try seed(store, parent: otherRoot.id)
        let topic = try store.createCatalogTopic(name: "other topic", parentID: otherRoot.id)
        XCTAssertThrowsError(try store.setCatalogTopic(id: doc.id, topicID: topic.id, included: true))
        XCTAssertThrowsError(try store.setCatalogRelated(id: doc.id, targetID: other.id, included: true))
        XCTAssertThrowsError(try store.updateCatalog(id: doc.id) { $0.sourceURL = "javascript:alert(1)" })
        XCTAssertThrowsError(try store.updateCatalog(id: doc.id) { $0.category = .topic })
        XCTAssertThrowsError(try store.updateCatalog(id: doc.id) { $0.year = -1 })
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: doc.id)).metadataJSON, "{}")
    }

    func testNewTopicNamesRemainUniqueWithoutChangingCatalogTitle() throws {
        let store = try makeStore()
        let a = try store.createCatalogTopic(name: "研究", parentID: "root")
        let b = try store.createCatalogTopic(name: "研究", parentID: "root")
        XCTAssertNotEqual(a.name, b.name)
        XCTAssertEqual(a.catalogTitle, b.catalogTitle)
        XCTAssertThrowsError(try store.createCatalogTopic(name: "  ", parentID: "root"))
    }
    func testInspectorEditMergesOnlyDirtyFieldsAndKeepsConcurrentAuthorsDOIAndReading() throws {
        let store = try makeStore(), original = try seed(store)
        let baseline = original.catalog
        var proposed = baseline; proposed.title = "本机标题"
        _ = try store.updateCatalog(id: original.id) { $0.authors = ["远端作者"]; $0.doi = "10.1000/remote"; $0.tags = ["远端标签"] }
        _ = try store.recordCatalogReadingPosition(id: original.id, deviceID: "phone", pageIndex: 9, totalPages: 20)
        let saved = try store.updateCatalog(id: original.id, edit: CatalogMetadataEdit(baseline: baseline, proposed: proposed))
        XCTAssertEqual(saved.catalog.title, "本机标题")
        XCTAssertEqual(saved.catalog.authors, ["远端作者"])
        XCTAssertEqual(saved.catalog.doi, "10.1000/remote")
        XCTAssertEqual(saved.catalog.tags, ["远端标签"])
        XCTAssertEqual(saved.catalog.readingPositions.first?.pageIndex, 9)
        XCTAssertEqual(saved.catalog.readingStatus, .reading)
    }

    func testInspectorSameFieldConflictIsAtomicAndCanBeResolvedByReload() throws {
        let store = try makeStore(), original = try seed(store)
        let baseline = original.catalog
        var proposed = baseline; proposed.title = "本机标题"; proposed.authors = ["本机作者"]
        _ = try store.updateCatalog(id: original.id) { $0.title = "远端标题" }
        let latest = try XCTUnwrap(store.loadDocument(id: original.id))
        let pending = try store.pending()
        XCTAssertThrowsError(try store.updateCatalog(id: original.id, edit: CatalogMetadataEdit(baseline: baseline, proposed: proposed))) { error in
            guard case CatalogError.concurrentMetadata(let fields) = error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(fields, ["标题"])
        }
        XCTAssertEqual(try store.loadDocument(id: original.id), latest)
        XCTAssertEqual(try store.pending(), pending, "a rejected form must not partly save a non-conflicting field")
        let rebased = try store.updateCatalog(id: original.id, edit: CatalogMetadataEdit(baseline: latest.catalog, proposed: proposed))
        XCTAssertEqual(rebased.catalog.title, "本机标题")
        XCTAssertEqual(rebased.catalog.authors, ["本机作者"])
        XCTAssertEqual(proposed.title, "本机标题", "merge must not mutate the retained UI draft")
    }

    func testEqualConcurrentEditAndUnchangedFormDoNotCreateExtraWrites() throws {
        let store = try makeStore(), original = try seed(store)
        var proposed = original.catalog; proposed.title = "相同修改"
        let updated = try store.updateCatalog(id: original.id) { $0.title = "相同修改" }
        let merged = try store.updateCatalog(id: original.id, edit: CatalogMetadataEdit(baseline: original.catalog, proposed: proposed))
        XCTAssertEqual(merged.localGeneration, updated.localGeneration)
        let noop = CatalogMetadataEdit(baseline: merged.catalog, proposed: merged.catalog)
        XCTAssertFalse(noop.isDirty)
        XCTAssertEqual(try store.updateCatalog(id: original.id, edit: noop).localGeneration, merged.localGeneration)
    }

    func testConcurrentCatalogMutationsPreserveEveryIndependentTagAndExcerpt() async throws {
        let store = try makeStore(), source = try seed(store), note = try seed(store, name: "concurrent.md", kind: .md)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    _ = try store.updateCatalog(id: source.id) { $0.tags.append("tag-\(index)") }
                    _ = try store.appendCatalogExcerpt(noteID: note.id, sourceID: source.id, quote: "quote-\(index)", excerptID: "excerpt-\(index)")
                }
            }
            try await group.waitForAll()
        }
        let savedSource = try XCTUnwrap(store.loadDocument(id: source.id))
        let savedNote = try XCTUnwrap(store.loadDocument(id: note.id))
        XCTAssertEqual(Set(savedSource.catalog.tags), Set((0..<32).map { "tag-\($0)" }))
        XCTAssertEqual(savedNote.catalog.excerpts.count, 32)
        for index in 0..<32 { XCTAssertTrue(savedNote.markdown.contains("> quote-\(index)\n")) }
        XCTAssertEqual(savedNote.catalog.sourceIDs, [source.id])
    }

    func testTwoRealServerRootsNeverBecomeTheSameLibrary() throws {
        let store = try makeStore()
        let rootA = try seed(store, name: "library A", kind: .folder, parent: "")
        let rootB = try seed(store, name: "library B", kind: .folder, parent: "")
        let a = try seed(store, name: "A.pdf", parent: rootA.id)
        let b = try seed(store, name: "B.pdf", parent: rootB.id)
        let topic = try store.createCatalogTopic(name: "B topic", parentID: rootB.id)
        XCTAssertThrowsError(try store.setCatalogRelated(id: a.id, targetID: b.id, included: true))
        XCTAssertThrowsError(try store.setCatalogTopic(id: a.id, topicID: topic.id, included: true))
        XCTAssertThrowsError(try store.createCatalogNote(sourceID: a.id, quote: "quote", parentID: rootB.id))
        let same = try store.createCatalogNote(sourceID: b.id, quote: "allowed")
        XCTAssertEqual(same.parentId, rootB.id)
    }

    func testArchivedTopicsHaveRecoverableArchiveEntryAndDoNotChangeMembers() throws {
        let store = try makeStore(), source = try seed(store)
        let topic = try store.createCatalogTopic(name: "completed", parentID: "root")
        _ = try store.setCatalogTopic(id: source.id, topicID: topic.id, included: true)
        let archived = try store.setCatalogArchived(id: topic.id, archived: true)
        XCTAssertFalse(CatalogQuery(section: .topics).matches(archived))
        XCTAssertTrue(CatalogQuery(section: .archived).matches(archived))
        XCTAssertFalse(try XCTUnwrap(store.loadDocument(id: source.id)).catalog.archived)
        _ = try store.setCatalogArchived(id: topic.id, archived: false)
        XCTAssertEqual(try store.catalogDocuments(query: CatalogQuery(section: .topics)).map(\.id), [topic.id])
    }

    func testDeletingTopicPreservesPhysicalChildrenDescendantsAndMemberships() throws {
        let store = try makeStore(), reference = try seed(store, name: "referenced.pdf")
        let topic = try store.createCatalogTopic(name: "topic", parentID: "root")
        _ = try store.setCatalogTopic(id: reference.id, topicID: topic.id, included: true)
        _ = try seed(store, name: "physical.md", kind: .md)
        let child = try seed(store, name: "physical.md", kind: .md, parent: topic.id)
        let folder = try seed(store, name: "inside", kind: .folder, parent: topic.id)
        let grandchild = try seed(store, name: "nested.pdf", parent: folder.id)
        try store.trash(id: topic.id)
        let saved = try XCTUnwrap(store.loadDocument(id: child.id))
        XCTAssertEqual(saved.state, "active")
        XCTAssertEqual(saved.parentId, "root")
        XCTAssertEqual(saved.name, "physical_1.md")
        XCTAssertEqual(saved.markdown, child.markdown)
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: folder.id)).parentId, "root")
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: grandchild.id)).state, "active")
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: grandchild.id)).parentId, folder.id)
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: reference.id)).catalog.topicIDs, [topic.id])
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: reference.id)).state, "active")
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: topic.id)).state, "trashed")
        XCTAssertEqual(try store.pending().last?.action, "trash")
        try store.restore(id: topic.id)
        XCTAssertEqual(try XCTUnwrap(store.loadDocument(id: child.id)).parentId, "root", "restore the topic must not unexpectedly move real files back")
        try store.trash(id: topic.id)
        _ = try store.setCatalogTopic(id: reference.id, topicID: topic.id, included: false)
        XCTAssertTrue(try XCTUnwrap(store.loadDocument(id: reference.id)).catalog.topicIDs.isEmpty)
    }

    func testUnknownNestedFieldsAndEnumValuesSurviveUnrelatedCatalogUpdate() throws {
        let store = try makeStore()
        let raw = #"{"category":"future-kind","readingStatus":"future-status","readingPositions":[{"deviceID":"mac","pageIndex":3,"updatedAt":0,"futurePosition":{"line":4}}],"excerpts":[{"id":"excerpt","sourceID":"source","sourceTitle":"title","quote":"quote","comment":"","createdAt":0,"futureAnchor":[1,2]}]}"#
        let doc = try seed(store, metadata: raw)
        let changed = try store.updateCatalog(id: doc.id) { $0.title = "changed" }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(changed.metadataJSON.utf8)) as? [String: Any])
        XCTAssertEqual(json["category"] as? String, "future-kind")
        XCTAssertEqual(json["readingStatus"] as? String, "future-status")
        XCTAssertEqual(((json["readingPositions"] as? [[String: Any]])?.first?["futurePosition"] as? [String: Int])?["line"], 4)
        XCTAssertEqual((json["excerpts"] as? [[String: Any]])?.first?["futureAnchor"] as? [Int], [1, 2])
    }

    func testExcerptLinksCarryFileVersionAndNewNoteRetryDoesNotDuplicate() throws {
        let store = try makeStore(), source = try seed(store)
        let noteID = UUID().uuidString.lowercased()
        let created = try store.createCatalogNote(sourceID: source.id, quote: "quote", pageIndex: 2, fileHash: "abc123", noteID: noteID)
        let retried = try store.createCatalogNote(sourceID: source.id, quote: "quote", pageIndex: 2, fileHash: "abc123", noteID: noteID)
        XCTAssertEqual(created, retried)
        XCTAssertEqual(try store.catalogBacklinks(to: source.id).count, 1)
        XCTAssertTrue(created.markdown.contains("?page=3&hash=abc123"))
        XCTAssertThrowsError(try store.createCatalogNote(sourceID: source.id, quote: "different", noteID: noteID))
        XCTAssertThrowsError(try store.createCatalogNote(sourceID: source.id, quote: " \n", comment: "\t"))
    }

    func testRepeatedReadingCallbackAvoidsWriteAndUnsafeDisplayTitlesGetSafeNames() throws {
        let store = try makeStore(), source = try seed(store)
        let first = try store.recordCatalogReadingPosition(id: source.id, deviceID: "mac", pageIndex: 2, totalPages: 8, fileHash: "hash")
        let repeatCall = try store.recordCatalogReadingPosition(id: source.id, deviceID: "mac", pageIndex: 2, totalPages: 8, fileHash: "hash")
        XCTAssertEqual(first.localGeneration, repeatCall.localGeneration)
        let topic = try store.createCatalogTopic(name: "理论 / 实践\\笔记", parentID: "root")
        XCTAssertEqual(topic.catalogTitle, "理论 / 实践\\笔记")
        XCTAssertFalse(topic.name.contains("/")); XCTAssertFalse(topic.name.contains("\\"))
        _ = try store.updateCatalog(id: source.id) { $0.title = String(repeating: "长", count: 300) }
        let note = try store.createCatalogNote(sourceID: source.id, quote: "excerpt")
        XCTAssertLessThanOrEqual(note.name.utf8.count, 240)
    }

    func testUnrecognizedKnownFieldShapeIsNotErasedByTitleEdit() throws {
        let store = try makeStore()
        let original = try seed(store, metadata: #"{"authors":{"format":"future","value":"Institution"},"excerpts":[{"futureRepresentation":true}]}"#)
        let updated = try store.updateCatalog(id: original.id) { $0.title = "new title" }
        let fields = try XCTUnwrap(JSONValue.parse(updated.metadataJSON).object)
        XCTAssertEqual(fields["authors"]?.object?["value"]?.string, "Institution")
        XCTAssertEqual(fields["excerpts"]?.array?.first?.object?["futureRepresentation"]?.bool, true)
    }

    func testLegacyPhysicalTopicSourceCreatesNotesOutsideTopic() throws {
        let store = try makeStore()
        let topic = try store.createCatalogTopic(name: "topic", parentID: "root")
        let source = try seed(store, parent: topic.id)
        let note = try store.createCatalogNote(sourceID: source.id, quote: "quote")
        XCTAssertEqual(note.parentId, "root")
        XCTAssertThrowsError(try store.createCatalogNote(sourceID: source.id, quote: "quote", parentID: topic.id))
        XCTAssertThrowsError(try store.createCatalogTopic(name: "nested", parentID: topic.id))
    }

    func testTrustedBoundRootSupportsOfflineCatalogBeforeFirstSnapshot() throws {
        let store = try makeStore()
        let root = UUID().uuidString.lowercased()
        try store.bindWorkspace(server: "https://catalog.invalid", libraryId: "library", rootId: root)
        let source = try seed(store, parent: root)
        let topic = try store.createCatalogTopic(name: "offline topic", parentID: root)
        _ = try store.setCatalogTopic(id: source.id, topicID: topic.id, included: true)
        let note = try store.createCatalogNote(sourceID: source.id, quote: "offline quote")
        XCTAssertEqual(note.parentId, root)
        XCTAssertThrowsError(try store.createCatalogTopic(name: "orphan", parentID: "missing-parent"))
    }

    func testUnversionedLegacyPDFExcerptNeedsPositionVerification() throws {
        let store = try makeStore()
        let path = store.root.appendingPathComponent("downloaded.pdf")
        try Data("downloaded bytes".utf8).write(to: path)
        let source = try seed(store, path: path.path)
        let legacy = CatalogExcerpt(sourceID: source.id, sourceTitle: "old PDF", quote: "quote", pageIndex: 4)
        XCTAssertEqual(try store.catalogSourceState(for: legacy), .unverifiedVersion)
    }

    func testCombinedCatalogFiltersApplyBeforeFullTextMatchesAndOnlyUseAuthorsField() throws {
        let store = try makeStore()
        let source = try seed(store)
        let doc = try store.updateCatalog(id: source.id) {
            $0.category = .paper; $0.authors = ["José García", "Open Research Institute"]
            $0.year = 2020; $0.tags = ["systems"]; $0.topicIDs = ["topic-A", "topic-B"]; $0.readingStatus = .reading
        }
        let filter = CatalogQuery(section: .papers, text: "indexed PDF text", topicID: "topic-B", tag: "systems", readingStatus: .reading,
                                  author: "JOSE garcia", yearFrom: 2019, yearTo: 2021, archive: .active)
        XCTAssertTrue(filter.matches(doc, indexedMatches: [doc.id]))
        XCTAssertFalse(CatalogQuery(text: "indexed PDF text", author: "Different Author").matches(doc, indexedMatches: [doc.id]))
        XCTAssertTrue(CatalogQuery(author: "research institute").matches(doc))
        var copy = doc; copy.markdown = "Different Author wrote this paragraph"
        XCTAssertFalse(CatalogQuery(author: "Different Author").matches(copy), "author filter must not match mentions in body")
        XCTAssertEqual(filter.results(in: [doc], indexedMatches: [doc.id]).map(\.id), [doc.id], "multiple topics must not duplicate a document")
    }

    func testCatalogYearArchiveAndDownloadFiltersExplainMissingValues() throws {
        let store = try makeStore()
        let pending = try seed(store, name: "pending.pdf")
        let localPath = store.root.appendingPathComponent("local.pdf")
        try Data("local original bytes".utf8).write(to: localPath)
        let local = try seed(store, name: "local.pdf", path: localPath.path)
        let note = try seed(store, name: "note.md", kind: .md)
        XCTAssertFalse(CatalogQuery(yearFrom: 2000).matches(pending))
        XCTAssertFalse(CatalogQuery(yearFrom: 2022, yearTo: 2020).matches(pending))
        let archived = try store.setCatalogArchived(id: local.id, archived: true)
        XCTAssertTrue(CatalogQuery().matches(archived), "default still includes archive")
        XCTAssertTrue(CatalogQuery(archive: .archived).matches(archived))
        XCTAssertFalse(CatalogQuery(archive: .active).matches(archived))
        XCTAssertTrue(CatalogQuery(availability: .waitingDownload).matches(pending))
        XCTAssertFalse(CatalogQuery(availability: .onDevice).matches(pending))
        XCTAssertTrue(CatalogQuery(availability: .onDevice).matches(archived))
        XCTAssertTrue(CatalogQuery(availability: .onDevice).matches(note))
        XCTAssertFalse(CatalogQuery(availability: .waitingDownload).matches(note))
        try FileManager.default.removeItem(at: localPath)
        XCTAssertTrue(CatalogQuery(availability: .waitingDownload).matches(archived), "a missing former path is not an available original")
    }

    func testCatalogSortsYearWithUnknownLastAndStableTitlesWithoutChangingRecords() throws {
        let store = try makeStore()
        let a = try seed(store, name: "a.pdf"), b = try seed(store, name: "b.pdf"), unknown = try seed(store, name: "unknown.pdf")
        let old = try store.updateCatalog(id: a.id) { $0.year = 2001; $0.authors = ["Zoe"]; $0.title = "Equal" }
        let new = try store.updateCatalog(id: b.id) { $0.year = 2024; $0.authors = ["Alice"]; $0.title = "Equal" }
        XCTAssertEqual(CatalogQuery().results(in: [unknown, old, new], sort: .yearNewest).map(\.id), [new.id, old.id, unknown.id])
        XCTAssertEqual(CatalogQuery().results(in: [unknown, old, new], sort: .yearOldest).map(\.id), [old.id, new.id, unknown.id])
        XCTAssertEqual(CatalogQuery().results(in: [unknown, old, new], sort: .author).map(\.id), [new.id, old.id, unknown.id])
        let forward = CatalogQuery().results(in: [old, new], sort: .title).map(\.id)
        let reverse = CatalogQuery().results(in: [new, old], sort: .title).map(\.id)
        XCTAssertEqual(forward, reverse, "equal display titles must not jump around on sync reload")
        XCTAssertEqual(try store.loadDocument(id: a.id), old)
    }

    func testCatalogRecentlyReadSortKeepsUnopenedLastWithoutUsingMaximumPage() throws {
        let store = try makeStore()
        let a = try seed(store, name: "a.pdf"), b = try seed(store, name: "b.pdf"), unopened = try seed(store, name: "unopened.pdf")
        let older = try store.updateCatalog(id: a.id) {
            $0.readingPositions = [CatalogReadingPosition(deviceID: "mac", pageIndex: 99, updatedAt: Date(timeIntervalSince1970: 100))]
        }
        let newer = try store.updateCatalog(id: b.id) {
            $0.readingPositions = [CatalogReadingPosition(deviceID: "phone", pageIndex: 2, updatedAt: Date(timeIntervalSince1970: 200))]
        }
        XCTAssertEqual(CatalogQuery().results(in: [older, unopened, newer], sort: .recentReading).map(\.id), [newer.id, older.id, unopened.id])
    }

    func testThousandRecordCatalogFilterAndSortPerformance() throws {
        var documents: [LibraryDocument] = []
        for index in 0..<1000 {
            var metadata = CatalogMetadata(category: index < 900 ? .note : .paper, title: "研究资料 \(index)")
            metadata.authors = [index % 2 == 0 ? "Alice Smith" : "Bob Chen"]
            metadata.year = 2000 + index % 25; metadata.tags = ["distributed systems", "中文研究"]
            metadata.topicIDs = ["topic-one", "topic-two"]
            documents.append(LibraryDocument(id: "item-\(index)", kind: index < 900 ? .md : .pdf, parentId: "root", name: "item-\(index).md",
                                             markdown: "catalog benchmark body", pdfPath: nil, revision: 1, localGeneration: 0, state: "active", purgeAt: nil,
                                             status: .synced, annotationsJSON: "[]", metadataJSON: try metadata.json()))
        }
        let query = CatalogQuery(topicID: "topic-two", tag: "中文研究", author: "Alice", yearFrom: 2010, yearTo: 2020)
        var times: [Double] = []
        for _ in 0..<30 {
            let start = Date()
            let result = query.results(in: documents, sort: .yearNewest)
            times.append(Date().timeIntervalSince(start) * 1000)
            XCTAssertEqual(result.count, 220)
            XCTAssertEqual(Set(result.map(\.id)).count, 220)
        }
        let p95 = times.sorted()[28]
        print("PERFORMANCE catalog_filter_sort_1000_p95_ms=\(String(format: "%.3f", p95)) samples=30 metadata_only=true")
        XCTAssertLessThan(p95, 500, "metadata filtering/sorting must stay within the existing local search latency budget")
    }

}
