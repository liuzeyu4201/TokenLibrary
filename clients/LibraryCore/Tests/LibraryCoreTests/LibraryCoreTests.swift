import Foundation
import PDFKit
import XCTest
@testable import LibraryCore

final class LibraryCoreTests: XCTestCase {
    func testAppearanceLabelsMapAndPersistAcrossReaders() throws {
        XCTAssertEqual(AppearanceStyle.allCases.map(\.rawValue), AppearanceStyle.allLabels)
        XCTAssertEqual(AppearanceStyle.allLabels, ["白天", "夜晚", "跟随系统"])
        XCTAssertEqual(AppearanceStyle.day.mappedScheme, "light")
        XCTAssertEqual(AppearanceStyle.night.mappedScheme, "dark")
        XCTAssertEqual(AppearanceStyle.system.mappedScheme, "unspecified")
        let suite = "tl.appearance.\(UUID().uuidString)"
        let writer = AppearanceStore(suiteName: suite)
        XCTAssertEqual(writer.style, .system)
        writer.style = .night
        XCTAssertEqual(writer.style, .night)
        XCTAssertEqual(writer.style.mappedScheme, "dark")
        let reader = AppearanceStore(suiteName: suite)
        XCTAssertEqual(reader.style, .night)
        XCTAssertEqual(reader.style.rawValue, "夜晚")
        reader.style = .day
        XCTAssertEqual(AppearanceStore(suiteName: suite).style, .day)
        XCTAssertEqual(AppearanceStore(suiteName: suite).style.mappedScheme, "light")
        reader.style = .system
        XCTAssertEqual(AppearanceStore(suiteName: suite).style.rawValue, "跟随系统")
        XCTAssertEqual(AppearanceStore(suiteName: suite).style.mappedScheme, "unspecified")
    }

    func tempStore() throws -> DocumentStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID().uuidString)")
        return try DocumentStore(directory: url)
    }

    func testSaveAndRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-relaunch-\(UUID().uuidString)")
        let id = UUID().uuidString.lowercased()
        do {
            let store = try DocumentStore(directory: dir)
            try store.localSaveOffline(markdown: "# hello 三方合并\n", id: id, name: "a.md", parentId: "root")
        }
        let store = try DocumentStore(directory: dir)
        let doc = try store.loadDocument(id: id)
        XCTAssertEqual(doc?.markdown, "# hello 三方合并\n")
        XCTAssertEqual(doc?.status, .pending)
    }

    func testOfflineQueuePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-q-\(UUID().uuidString)")
        let id = UUID().uuidString.lowercased()
        do {
            let store = try DocumentStore(directory: dir)
            try store.localSaveOffline(markdown: "offline", id: id, name: "b.md", parentId: "root")
            XCTAssertFalse(try store.pending().isEmpty)
            XCTAssertEqual(try store.pending().first?.action, "createMarkdown")
        }
        let store = try DocumentStore(directory: dir)
        XCTAssertEqual(try store.pending().count, 1)
        XCTAssertEqual(try store.pending().first?.objectId, id)
        XCTAssertEqual(try store.pending().first?.action, "createMarkdown")
    }

    func testSearchUnsyncedMarkdown() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "这篇讲三方合并与公式 $a+b$", id: id, name: "note.md", parentId: "root")
        let hits = try store.search(query: "三方合并")
        XCTAssertTrue(hits.contains(id), "unsynced markdown must be searchable, hits=\(hits)")
    }

    func testNoOCRClaim() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        let doc = LibraryDocument(id: id, kind: .pdf, parentId: "root", name: "scan.pdf", markdown: "", pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]")
        try store.saveDocument(doc, enqueue: false)
        let hits = try store.search(query: "发票号码隐藏文字")
        XCTAssertFalse(hits.contains(id))
    }

    func testTrashRestoreAndPurge() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "x", id: id, name: "t.md", parentId: "root")
        try store.trash(id: id)
        XCTAssertEqual(try store.loadDocument(id: id)?.state, "trashed")
        try store.restore(id: id)
        XCTAssertEqual(try store.loadDocument(id: id)?.state, "active")
        try store.trash(id: id)
        let past = Date().addingTimeInterval(-31 * 24 * 3600)
        try store.db.write { db in
            try db.execute(sql: "UPDATE working_documents SET purge_at=? WHERE id=?", arguments: [
                ISO8601DateFormatter().string(from: past), id,
            ])
        }
        XCTAssertEqual(try store.purgeExpired(now: Date()), 1)
        XCTAssertNil(try store.loadDocument(id: id))
    }

    func testConflictNotSynced() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "c", id: id, name: "c.md", parentId: "root")
        try store.markConflict(id: id)
        XCTAssertFalse(try store.isFullySynced(id: id))
    }

    func testTokenizerCJKAndCamel() {
        let t = SearchTokenizer.tokens(in: "三方合并 PDFKit v2")
        XCTAssertTrue(t.contains("三方") || t.contains("三"))
        XCTAssertTrue(t.contains("pdfkit") || t.contains("pdf") || t.contains("kit"))
    }

    func testPDFAnnotationMergeAndReplace() {
        let a = PDFTextAnnotation(id: "a", type: "highlight", pageIndex: 0, x: 1, y: 1, width: 2, height: 2, color: "#ff0", text: "t")
        let b = PDFTextAnnotation(id: "b", type: "comment", pageIndex: 1, x: 1, y: 1, width: 2, height: 2, color: "#f00", text: "c")
        let (merged, conflict) = PDFMerge.mergeAdds(base: [], local: [a], remote: [b])
        XCTAssertFalse(conflict)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(PDFMerge.replaceConflict(baseBlob: "1", localBlob: "2", remoteBlob: "3"))
        XCTAssertFalse(PDFMerge.replaceConflict(baseBlob: "1", localBlob: "1", remoteBlob: "2"))
    }

    func testExportContainsSource() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "```mermaid\ngraph TD\nA-->B\n```\n$a+b$", id: id, name: "e.md", parentId: "root")
        let data = try store.exportMarkdown(id: id)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("mermaid"))
        XCTAssertTrue(s.contains("$a+b$"))
        let pdf = PDFExport.makeSamplePDF(text: "RFC UUID body")
        let exported = try PDFExport.exportAnnotated(pdfData: pdf, annotations: [
            PDFTextAnnotation(type: "highlight", pageIndex: 0, x: 70, y: 710, width: 120, height: 20, color: "#ff0", text: "这段"),
            PDFTextAnnotation(type: "comment", pageIndex: 0, x: 70, y: 680, width: 160, height: 24, color: "#f00", text: "这段与实验结论不一致"),
        ])
        XCTAssertTrue(PDFExport.containsHighlight(orCommentIn: exported, comment: "这段与实验结论不一致"))
        XCTAssertTrue(exported.starts(with: Data("%PDF".utf8)))
    }

    func testPDFHighlightAndCommentLandOnVisiblePage() throws {
        let data = PDFExport.makeSamplePDF(text: "Hello highlight target")
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
            return XCTFail("sample PDF must parse")
        }
        XCTAssertEqual(page.annotations.count, 0)
        let highlight = PDFExport.fallbackHighlight(on: page, in: doc)
        let comment = PDFExport.fallbackComment(on: page, in: doc, text: "这段与实验结论不一致")
        let crop = page.bounds(for: PDFDisplayBox.cropBox)
        XCTAssertTrue(crop.intersects(CGRect(x: highlight.x, y: highlight.y, width: highlight.width, height: highlight.height)))
        XCTAssertTrue(crop.intersects(CGRect(x: comment.x, y: comment.y, width: comment.width, height: comment.height)))
        PDFExport.apply(to: doc, annotations: [highlight, comment])
        XCTAssertGreaterThanOrEqual(page.annotations.count, 2)
        XCTAssertTrue(page.annotations.contains { $0.type == "Highlight" || $0.type == "highlight" })
        XCTAssertTrue(page.annotations.contains { ($0.contents ?? "").contains("这段与实验结论不一致") })
        PDFExport.apply(to: doc, annotations: [
            PDFTextAnnotation(type: "highlight", pageIndex: 0, x: 0, y: 5000, width: 80, height: 16, color: "#ff0", text: ""),
        ])
        XCTAssertTrue(page.annotations.contains { crop.intersects($0.bounds) })
    }

    func testAppendAnnotationsKeepsFileName() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        let pdf = PDFExport.makeSamplePDF(text: "ann")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).pdf")
        try pdf.write(to: path)
        let doc = LibraryDocument(
            id: id, kind: .pdf, parentId: "root", name: "实验记录.pdf", markdown: "", pdfPath: path.path,
            revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]"
        )
        try store.saveDocument(doc, enqueue: true)
        let extra = [
            PDFTextAnnotation(type: "highlight", pageIndex: 0, x: 72, y: 710, width: 120, height: 18, color: "#FFE08A", text: ""),
            PDFTextAnnotation(type: "comment", pageIndex: 0, x: 72, y: 680, width: 160, height: 24, color: "#007AFF", text: "这段与实验结论不一致"),
        ]
        let saved = try store.appendAnnotations(id: id, extra: extra)
        XCTAssertEqual(saved?.name, "实验记录.pdf")
        let loaded = try JSONDecoder().decode([PDFTextAnnotation].self, from: Data((saved?.annotationsJSON ?? "[]").utf8))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.last?.text, "这段与实验结论不一致")
        let again = try store.appendAnnotations(id: id, extra: [
            PDFTextAnnotation(type: "comment", pageIndex: 0, x: 80, y: 640, width: 120, height: 24, color: "#007AFF", text: "第二条"),
        ])
        let all = try JSONDecoder().decode([PDFTextAnnotation].self, from: Data((again?.annotationsJSON ?? "[]").utf8))
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(try store.loadDocument(id: id)?.name, "实验记录.pdf")
    }

    func testPDFBodySearchUsesExtractedText() throws {
        let store = try tempStore()
        let pdf = PDFExport.makeSamplePDF(text: "UUIDv4 searchable-token-xyz")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).pdf")
        try pdf.write(to: path)
        let id = UUID().uuidString.lowercased()
        let doc = LibraryDocument(id: id, kind: .pdf, parentId: "root", name: "rfc.pdf", markdown: "", pdfPath: path.path, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]")
        try store.saveDocument(doc, enqueue: false)
        let hits = try store.search(query: "searchable-token-xyz")
        XCTAssertTrue(hits.contains(id), "PDF extractable text must be searchable, hits=\(hits)")
    }

    func testRenameMoveDeleteEnqueueRealActions() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "hi", id: id, name: "未命名.md", parentId: "root")
        XCTAssertEqual(try store.pending().first?.action, "createMarkdown")
        var doc = try store.loadDocument(id: id)!
        doc.revision = 2
        try store.saveDocument(doc, enqueue: false)
        doc.name = FileNames.stored("日记", kind: .md)
        try store.saveDocument(doc, enqueue: true)
        XCTAssertEqual(try store.loadDocument(id: id)?.name, "日记.md")
        XCTAssertEqual(try store.pending().first { $0.objectId == id }?.action, "rename")
        XCTAssertTrue((try store.pending().first { $0.objectId == id }?.payload.contains("日记.md")) == true)

        let folder = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .folder, parentId: "root", name: "夹", markdown: "", pdfPath: nil, revision: 2, localGeneration: 1, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
        try store.saveDocument(folder, enqueue: false)
        var moved = try store.loadDocument(id: id)!
        moved.parentId = folder.id
        try store.saveDocument(moved, enqueue: true)
        XCTAssertEqual(try store.loadDocument(id: id)?.parentId, folder.id)
        XCTAssertEqual(try store.pending().first { $0.objectId == id }?.action, "move")

        try store.trash(id: id)
        XCTAssertEqual(try store.loadDocument(id: id)?.state, "trashed")
        XCTAssertEqual(try store.pending().first { $0.action == "trash" }?.objectId, id)
        try store.restore(id: id)
        XCTAssertEqual(try store.loadDocument(id: id)?.state, "active")
    }

    func testRenameThenContentSaveKeepsNewFileName() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "# old\n", id: id, name: "未命名.md", parentId: "root")
        let renamed = try store.renameDocument(id: id, to: "会议纪要")
        XCTAssertEqual(renamed?.name, "会议纪要.md")
        XCTAssertEqual(try store.loadDocument(id: id)?.name, "会议纪要.md")
        let after = try store.updateMarkdown(id: id, markdown: "# new body\n")
        XCTAssertEqual(after?.name, "会议纪要.md")
        XCTAssertEqual(after?.markdown, "# new body\n")
        XCTAssertEqual(try store.loadDocument(id: id)?.name, "会议纪要.md")
        XCTAssertEqual(try store.pending().first { $0.objectId == id }?.payload.contains("会议纪要.md"), true)
        let pdfId = UUID().uuidString.lowercased()
        let pdf = LibraryDocument(
            id: pdfId, kind: .pdf, parentId: "root", name: "a.pdf", markdown: "", pdfPath: nil,
            revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]"
        )
        try store.saveDocument(pdf, enqueue: true)
        XCTAssertEqual(try store.renameDocument(id: pdfId, to: "白皮书")?.name, "白皮书.pdf")
        let folderId = UUID().uuidString.lowercased()
        let folder = LibraryDocument(
            id: folderId, kind: .folder, parentId: "root", name: "夹", markdown: "", pdfPath: nil,
            revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]"
        )
        try store.saveDocument(folder, enqueue: true)
        XCTAssertEqual(try store.renameDocument(id: folderId, to: "项目")?.name, "项目")
        XCTAssertEqual(try store.renameDocument(id: id, to: "会议纪要.md")?.name, "会议纪要.md")
    }

    func testFileNamesKeepsExtensionRules() {
        XCTAssertEqual(FileNames.stored("日记", kind: .md), "日记.md")
        XCTAssertEqual(FileNames.stored("日记.md", kind: .md), "日记.md")
        XCTAssertEqual(FileNames.editingBase("日记.md", kind: .md), "日记")
        XCTAssertEqual(FileNames.stored("资料", kind: .folder), "资料")
        XCTAssertEqual(FileNames.stored("a", kind: .pdf), "a.pdf")
        XCTAssertEqual(FileNames.stored("  ", kind: .md), "未命名.md")
    }

    func testFoldersSortBeforeFilesAndCycleCheck() {
        let folder = LibraryDocument(id: "f", kind: .folder, parentId: "root", name: "B夹", markdown: "", pdfPath: nil, revision: 1, localGeneration: 1, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
        let file = LibraryDocument(id: "n", kind: .md, parentId: "root", name: "A.md", markdown: "", pdfPath: nil, revision: 1, localGeneration: 1, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
        let nested = LibraryDocument(id: "c", kind: .folder, parentId: "f", name: "子", markdown: "", pdfPath: nil, revision: 1, localGeneration: 1, state: "active", purgeAt: nil, status: .synced, annotationsJSON: "[]")
        let sorted = [file, folder].sorted(by: LibraryDocument.folderFirst)
        XCTAssertEqual(sorted.map(\.id), ["f", "n"])
        XCTAssertTrue(folder.isAncestor(of: nested, in: [folder, nested, file]))
        XCTAssertFalse(nested.isAncestor(of: folder, in: [folder, nested, file]))
    }

    func testNoteBlocksRoundTripAndInsertAtFocus() {
        let md = "hello\n\n<!--tl:image id=\"img1\"-->\n![pic](/tmp/a.png)\n<!--/tl:image-->\n\n<!--tl:voice id=\"v1\" duration=\"1.5\"-->\n[voice](/tmp/a.m4a)\n<!--/tl:voice-->"
        let blocks = NoteBlockCodec.parse(md)
        XCTAssertEqual(blocks.map(\.kind), [.text, .image, .voice])
        XCTAssertEqual(blocks[0].text.contains("hello"), true)
        XCTAssertEqual(blocks[1].path, "/tmp/a.png")
        XCTAssertEqual(blocks[2].duration, 1.5)
        let back = NoteBlockCodec.serialize(blocks)
        let again = NoteBlockCodec.parse(back)
        XCTAssertEqual(again.map(\.kind), blocks.map(\.kind))
        var list = [NoteBlock(id: "a", kind: .text, text: "a")]
        NoteBlockCodec.insert(NoteBlock(id: "b", kind: .image, text: "i", path: "x"), into: &list, after: "a")
        XCTAssertEqual(list.map(\.id), ["a", "b"])
        XCTAssertEqual(NoteBlockCodec.parse("").count, 1)
        let withCap = NoteBlockCodec.serialize([
            NoteBlock(id: "img1", kind: .image, text: "这是配文", path: "media/a.png"),
            NoteBlock(id: "v1", kind: .voice, text: "会议备注", path: "media/a.m4a", duration: 2),
        ])
        let parsedCap = NoteBlockCodec.parse(withCap)
        XCTAssertEqual(parsedCap[0].text, "这是配文")
        XCTAssertEqual(parsedCap[1].text, "会议备注")
        var order = [
            NoteBlock(id: "a", kind: .text, text: "a"),
            NoteBlock(id: "b", kind: .text, text: "b"),
            NoteBlock(id: "c", kind: .text, text: "c"),
        ]
        NoteBlockCodec.move(&order, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(order.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(NoteBlockCodec.parse(NoteBlockCodec.serialize(order)).map(\.id), order.map(\.id))
    }

    func testDemoSeedCreatesBrowsableLibrary() throws {
        let store = try tempStore()
        try DemoLibrary.seedIfEmpty(store)
        let all = try store.listDocuments(includeTrashed: true)
        XCTAssertGreaterThanOrEqual(all.filter { $0.kind == .folder && $0.state == "active" }.count, 5)
        XCTAssertTrue(all.contains { $0.name == "三方合并规则.md" && $0.markdown.contains("mermaid") })
        XCTAssertTrue(all.contains { $0.name == "Mermaid 同步流程.md" && $0.status == .conflict })
        XCTAssertTrue(all.contains { $0.name == "旧同步笔记.md" && $0.state == "trashed" })
        XCTAssertTrue(all.contains { $0.name == "RFC9562.pdf" && ($0.pdfPath?.isEmpty == false) })
        let hits = try store.search(query: "三方合并")
        XCTAssertFalse(hits.isEmpty)
        try DemoLibrary.seedIfEmpty(store)
        XCTAssertEqual(try store.listDocuments(includeTrashed: true).count, all.count)
    }

    func testNewDocumentEnqueuesCreateNotUpdate() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "n", id: id, name: "n.md", parentId: "root")
        XCTAssertEqual(try store.pending().first?.action, "createMarkdown")
        let folder = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .folder, parentId: "root", name: "夹", markdown: "", pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
        try store.saveDocument(folder, enqueue: true)
        XCTAssertTrue(try store.pending().contains { $0.action == "createFolder" })
        let pdf = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .pdf, parentId: "root", name: "a.pdf", markdown: "", pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
        try store.saveDocument(pdf, enqueue: true)
        XCTAssertTrue(try store.pending().contains { $0.action == "createPDF" })
        var existing = try store.loadDocument(id: id)!
        existing.revision = 4
        existing.markdown = "edited"
        try store.saveDocument(existing, enqueue: true)
        XCTAssertEqual(try store.pending().first { $0.objectId == id }?.action, "updateDocument")
    }

    func testEditorBundleFindsPackagedDistOrEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eb-\(UUID().uuidString).bundle")
        let res = root.appendingPathComponent("Contents/Resources/dist")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try "<html></html>".write(to: res.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>test.editorbundle</string>
        <key>CFBundlePackageType</key><string>BNDL</string>
        </dict></plist>
        """
        try plist.write(to: root.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: root.path) else {
            XCTFail("bundle")
            return
        }
        let url = EditorBundle.indexHTML(in: bundle)
        XCTAssertEqual(url?.lastPathComponent, "index.html")
        XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, "dist")
    }

    func testApplyFlushResultConflictStaysUnsynced() throws {
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "c", id: id, name: "c.md", parentId: "root")
        let op = try store.pending().first!
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1")!)
        try client.applyFlushResult(["data": ["status": "conflict", "revision": "3"]], op: op, store: store)
        XCTAssertEqual(try store.loadDocument(id: id)?.status, .conflict)
        XCTAssertFalse(try store.isFullySynced(id: id))
        XCTAssertEqual(try store.pending().first?.state ?? "conflict", "conflict")
    }

    func testFlushPendingCreatesOnHTTPServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let py = dir.appendingPathComponent("stub.py")
        let log = dir.appendingPathComponent("req.json")
        let script = """
        import json, sys, threading
        from http.server import BaseHTTPRequestHandler, HTTPServer
        logp = sys.argv[1]
        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0))
                body = json.loads(self.rfile.read(n))
                open(logp, 'w').write(json.dumps(body))
                action = body.get('action', '')
                code = 201 if action.startswith('create') else 200
                payload = {'data': {'status': 'committed', 'objectId': body.get('objectId'), 'revision': '7', 'conflictIds': []}}
                raw = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            def log_message(self, *args):
                pass
        httpd = HTTPServer(('127.0.0.1', 0), H)
        print(str(httpd.server_address[1]).ljust(16), flush=True)
        httpd.handle_request()
        """
        try script.write(to: py, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [py.path, log.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let portData = (try? pipe.fileHandleForReading.read(upToCount: 16)) ?? Data()
        let portStr = String(data: portData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let port = Int(portStr) else {
            XCTFail("no port \(portStr)")
            return
        }
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "from-client", id: id, name: "n.md", parentId: "root")
        XCTAssertEqual(try store.pending().first?.action, "createMarkdown")
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        client.sessionToken = "tok"
        client.epoch = "ep"
        client.deviceId = UUID().uuidString.lowercased()
        try await client.flushPending(store: store)
        let recorded = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(recorded.contains("createMarkdown"), recorded)
        XCTAssertTrue(recorded.contains(id), recorded)
        let doc = try store.loadDocument(id: id)
        XCTAssertEqual(doc?.status, .synced)
        XCTAssertEqual(doc?.revision, 7)
        proc.terminate()
    }

    func testFlushPendingConflictFromHTTP() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("http-c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let py = dir.appendingPathComponent("stub.py")
        let script = """
        import json, sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0))
                body = json.loads(self.rfile.read(n))
                raw = json.dumps({'data': {'status': 'conflict', 'objectId': body.get('objectId'), 'revision': '3', 'conflictIds': ['c']}}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            def log_message(self, *args):
                pass
        httpd = HTTPServer(('127.0.0.1', 0), H)
        print(str(httpd.server_address[1]).ljust(16), flush=True)
        httpd.handle_request()
        """
        try script.write(to: py, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [py.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let portData = (try? pipe.fileHandleForReading.read(upToCount: 16)) ?? Data()
        let portStr = String(data: portData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let port = Int(portStr) else {
            XCTFail("no port")
            return
        }
        let store = try tempStore()
        let id = UUID().uuidString.lowercased()
        try store.localSaveOffline(markdown: "c", id: id, name: "c.md", parentId: "root")
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        client.sessionToken = "tok"
        client.epoch = "ep"
        try await client.flushPending(store: store)
        XCTAssertEqual(try store.loadDocument(id: id)?.status, .conflict)
        XCTAssertFalse(try store.isFullySynced(id: id))
        proc.terminate()
    }
}
