import XCTest
import ImageIO
@testable import LibraryCore

final class LibraryExportTests: XCTestCase {
    private func png() throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 255, count: 16) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    func testZIPIsReadableBySystemArchiveAndContainsRelativeMedia() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try DocumentStore(directory:directory)
        let image=try png()
        let asset=try store.importAttachment(data:image,fileName:"image.png",mime:"image/png")
        let document=LibraryDocument(id:UUID().uuidString.lowercased(),kind:.md,parentId:"root",name:"研究.md",markdown:"# 研究\n\n![image](\(asset.path))",pdfPath:nil,revision:0,localGeneration:0,state:"active",purgeAt:nil,status:.pending,annotationsJSON:"[]")
        try store.saveDocument(document,enqueue:true)
        let output=try store.exportPortableMarkdown(id:document.id)
        XCTAssertTrue(output.isArchive);XCTAssertEqual(output.filename,"研究.zip")
        let archive=directory.appendingPathComponent("export.zip");try output.data.write(to:archive)
        #if os(macOS)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");process.arguments=["-t",archive.path]
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
        try process.run();process.waitUntilExit()
        let report=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        XCTAssertEqual(process.terminationStatus,0,report)
        XCTAssertTrue(report.contains(asset.path));XCTAssertTrue(report.contains("metadata.json"))
        #endif
        XCTAssertEqual(try Data(contentsOf:store.resolveAttachment(path:asset.path)),image)
    }
    func testSimpleMarkdownRemainsPlainFileAndMissingMediaFailsExplicitly() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try DocumentStore(directory:directory)
        var doc=LibraryDocument(id:"note",kind:.md,parentId:"root",name:"note.md",markdown:"# test\n",pdfPath:nil,revision:0,localGeneration:0,state:"active",purgeAt:nil,status:.pending,annotationsJSON:"[]")
        try store.saveDocument(doc,enqueue:true)
        let output=try store.exportPortableMarkdown(id:doc.id)
        XCTAssertFalse(output.isArchive);XCTAssertEqual(String(decoding:output.data,as:UTF8.self),doc.markdown)
        doc.markdown += "![missing](media/missing.png)";try store.saveDocument(doc,enqueue:true)
        XCTAssertThrowsError(try store.exportPortableMarkdown(id:doc.id))
    }
    #if os(macOS)
    private func unzip(_ data: Data, entry: String, in directory: URL) throws -> Data {
        let archive = directory.appendingPathComponent("export-" + UUID().uuidString + ".zip")
        try data.write(to: archive)
        let extracted = directory.appendingPathComponent("extracted-" + UUID().uuidString)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let report = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, report)
        return try Data(contentsOf: extracted.appendingPathComponent(entry))
    }

    func testOfflineLegacyImageIsBundledAndRewrittenOnlyInExportedRenderedReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        let image = try png()
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(image as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        let asset = try store.importAttachment(data: image, fileName: "original.png", mime: "image/png")
        let legacy = "library-asset://" + asset.blobId
        let code = "\n\n```md\n![example](library-asset://missing)\n```\n"
        let document = LibraryDocument(id: "legacy", kind: .md, parentId: "root", name: "legacy.md", markdown: "![原图](\(legacy))" + code,
            pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
        try store.saveDocument(document, enqueue: true)
        let before = try store.loadDocument(id: document.id), queue = try store.pending()
        let output = try store.exportPortableMarkdown(id: document.id)
        XCTAssertTrue(output.isArchive)
        let exported = String(decoding: try unzip(output.data, entry: "legacy.md", in: directory), as: UTF8.self)
        XCTAssertTrue(exported.contains("](\(asset.path))")); XCTAssertTrue(exported.hasSuffix(code))
        XCTAssertEqual(try unzip(output.data, entry: asset.path, in: directory), image)
        XCTAssertEqual(try store.loadDocument(id: document.id), before); XCTAssertEqual(try store.pending(), queue)
    }

    func testSourceGuideIsReadableWithoutOriginalLibraryAndAvoidsNoteNameCollision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        let quote = "引用原文\n```md\n![literal](media/not-an-asset.png)\n```", comment = "我的观点与原文不同。"
        let excerpt = CatalogExcerpt(sourceID: "missing-original", sourceTitle: "原文书籍", quote: quote, comment: comment, pageIndex: 7, fileHash: "source-version-hash")
        var catalog = CatalogMetadata(category: .note); catalog.excerpts = [excerpt]; catalog.sourceIDs = [excerpt.sourceID]
        let body = "# 阅读笔记\n\n> 引用原文\n\n我的笔记：\n\n\(comment)\n\n来源：[原文书籍 · 第 8 页](tokenlibrary://document/missing-original?page=8&hash=source-version-hash)\n"
        let document = LibraryDocument(id: "note", kind: .md, parentId: "root", name: "来源说明.md", markdown: body,
            pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]", metadataJSON: try catalog.json())
        try store.saveDocument(document, enqueue: true)
        let before = try store.loadDocument(id: document.id), queue = try store.pending()
        let output = try store.exportPortableMarkdown(id: document.id)
        let guide = String(decoding: try unzip(output.data, entry: "来源说明_1.md", in: directory), as: UTF8.self)
        XCTAssertTrue(guide.contains("原文书籍")); XCTAssertTrue(guide.contains("第 8 页")); XCTAssertTrue(guide.contains(quote)); XCTAssertTrue(guide.contains(comment))
        XCTAssertTrue(guide.contains("来源 PDF/其他文档未随包复制")); XCTAssertTrue(guide.contains("不能保证在其他阅读器跳到原文"))
        XCTAssertTrue(try MarkdownReferences(guide).mediaReferences.isEmpty, "Quoted Markdown must remain literal")
        let exported = String(decoding: try unzip(output.data, entry: "来源说明.md", in: directory), as: UTF8.self)
        XCTAssertTrue(exported.hasPrefix(body)); XCTAssertTrue(exported.contains("[来源、页码与摘录记录](来源说明_1.md)"))
        XCTAssertTrue(exported.contains("普通 Markdown 阅读器无法据此打开原 PDF"))
        XCTAssertEqual(try unzip(output.data, entry: "metadata.json", in: directory), Data(document.metadataJSON.utf8))
        XCTAssertEqual(try store.loadDocument(id: document.id), before); XCTAssertEqual(try store.pending(), queue)
    }

    func testApplicationLinksWithoutCatalogSnapshotStillExplainExternalLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        let document = LibraryDocument(id: "legacy-link", kind: .md, parentId: "root", name: "legacy.md", markdown: "[来源](tokenlibrary://document/legacy)",
            pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]")
        try store.saveDocument(document, enqueue: false)
        let output = try store.exportPortableMarkdown(id: document.id)
        XCTAssertTrue(output.isArchive)
        let guide = String(decoding: try unzip(output.data, entry: "来源说明.md", in: directory), as: UTF8.self)
        XCTAssertTrue(guide.contains("没有独立的来源快照"))
    }
    #endif

    func testZIPRejectsTraversalAndDuplicateEntries() {
        XCTAssertThrowsError(try PortableZIP.encode([("../outside",Data())]))
        XCTAssertThrowsError(try PortableZIP.encode([("a",Data()),("a",Data())]))
        XCTAssertEqual(PortableZIP.crc32(Data("123456789".utf8)),0xcbf43926)
    }
}
