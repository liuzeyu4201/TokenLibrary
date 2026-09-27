import XCTest
import GRDB
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LibraryCore

final class MarkdownImportTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (DocumentStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-import-" + UUID().uuidString, isDirectory: true)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (try DocumentStore(directory: directory.appendingPathComponent("library")), source)
    }
    private func png() throws -> Data {
        let pixels = Data(repeating: 255, count: 16)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func wav() -> Data {
        let samples = 4410, payload = samples * 2
        var bytes = Data("RIFF".utf8)
        func u32(_ value: Int) { for shift in stride(from: 0, through: 24, by: 8) { bytes.append(UInt8((value >> shift) & 255)) } }
        func u16(_ value: Int) { bytes.append(UInt8(value & 255)); bytes.append(UInt8((value >> 8) & 255)) }
        u32(payload + 36); bytes.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(44100); u32(88200); u16(2); u16(16); bytes.append(Data("data".utf8)); u32(payload)
        bytes.append(Data(repeating: 0, count: payload)); return bytes
    }
    @discardableResult private func write(_ data: Data, _ path: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file); return file
    }
    private func importText(_ text: String, from source: URL, into store: DocumentStore, name: String = "note.md", parent: String = "root") throws -> MarkdownImportResult {
        let file = try write(Data(text.utf8), name, in: source)
        return try store.importMarkdownFile(url: file, parentID: parent)
    }
    private func assertNoImport(_ store: DocumentStore, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try store.listDocuments(includeTrashed: true).isEmpty, file: file, line: line)
        XCTAssertTrue(try store.pending().isEmpty, file: file, line: line)
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM blob_transfers") }, 0, file: file, line: line)
        let media = store.root.appendingPathComponent("media")
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: media.path).isEmpty) ?? true, file: file, line: line)
    }

    func testImportsActualImageAndVoiceBytesMetadataAndQueueTogether() throws {
        let (store, source) = try fixture(), image = try png(), voice = wav()
        try write(image, "media/picture.png", in: source); try write(voice, "audio/recording.wav", in: source)
        let original = "# 中文笔记\n\n![图](media/picture.png)\n\n[voice](audio/recording.wav)\n"
        let result = try importText(original, from: source, into: store)
        XCTAssertTrue(result.warnings.isEmpty); XCTAssertEqual(result.document.catalog.category, .note); XCTAssertTrue(result.document.catalog.inbox)
        XCTAssertEqual(result.document.catalog.originalFilename, "note.md")
        XCTAssertEqual(result.document.catalog.originalFileHash, BlobIntegrity.sha256(Data(original.utf8)))
        XCTAssertNotNil(result.document.catalog.importedAt)
        let references = try MarkdownReferences(result.document.markdown).references
        XCTAssertEqual(references.count, 2); XCTAssertTrue(references.allSatisfy { $0.destination.hasPrefix("media/") })
        let imported = try references.map { try Data(contentsOf: store.resolveAttachment(path: $0.destination)) }
        XCTAssertTrue(imported.contains(image)); XCTAssertTrue(imported.contains(voice))
        XCTAssertEqual(try JSONValue.parse(result.document.assetsJSON).array?.count, 2)
        XCTAssertEqual(try store.pending().count, 1)
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(store.pending().first).payload).object?["assets"]?.array?.count, 2)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("note.md")), Data(original.utf8))
    }

    func testReferenceCollapsedShortcutAngleAndEscapedSyntaxDeduplicateSameFile() throws {
        let (store, source) = try fixture(); try write(png(), "images/图 (1).png", in: source)
        let original = #"""
        中文 before ![inline](<images/图 (1).png> "title") after.
        ![full][photo]
        ![photo][]
        ![photo]
        ![escaped](images/图%20\(1\).png)

        [photo]: <images/图 (1).png> "reference title"
        """#
        let result = try importText(original, from: source, into: store)
        let references = try MarkdownReferences(result.document.markdown).references
        XCTAssertEqual(references.count, 5); XCTAssertEqual(Set(references.map(\.destination)).count, 1)
        XCTAssertEqual(try JSONValue.parse(result.document.assetsJSON).array?.count, 1)
        XCTAssertTrue(result.document.markdown.hasPrefix("中文 before "))
        XCTAssertTrue(result.document.markdown.contains(" after."))
        XCTAssertTrue(result.document.markdown.contains("[photo]: <images/图 (1).png> \"reference title\""))
        XCTAssertFalse(result.document.markdown.contains("![photo][]"))
    }

    func testCodeEscapesUnusedDefinitionsAndOrdinarySecretsAreNeverRead() throws {
        let (store, source) = try fixture()
        let original = #"""
        ```md
        ![fake](media/missing.png)
        [voice](media/missing.wav)
        ```

        `![inline example](media/missing.png)`

            ![indented](media/missing.png)

        \![escaped](media/missing.png)

        [unused]: media/missing.png
        [private config](.env)
        [paper](paper.pdf)
        [note](other.md)
        """#
        let result = try importText(original, from: source, into: store)
        XCTAssertEqual(result.document.markdown, original)
        XCTAssertEqual(try JSONValue.parse(result.document.assetsJSON).array?.count, 0)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertFalse(try store.exportPortableMarkdown(id: result.document.id).isArchive, "Code examples must not become export dependencies")
    }

    func testNestedLinkedImageChangesOnlyTheImageAndPreservesCRLFUnicodeSource() throws {
        let (store, source) = try fixture(); try write(png(), "图.png", in: source)
        let prefix = "# 标题\r\n\r\n前缀 ", suffix = " 后缀\r\n\r\n$$\\int_0^1 x dx$$\r\n"
        let original = prefix + "[![图](图.png)](https://example.invalid/reference)" + suffix
        let result = try importText(original, from: source, into: store)
        XCTAssertTrue(result.document.markdown.hasPrefix(prefix + "[!"))
        XCTAssertTrue(result.document.markdown.hasSuffix("](https://example.invalid/reference)" + suffix))
        XCTAssertEqual(try JSONValue.parse(result.document.assetsJSON).array?.count, 1)
    }

    func testRemoteMediaAndOrdinaryRelativeLinksRemainUnfetchedWithWarnings() throws {
        let (store, source) = try fixture()
        let text = "![remote](https://127.0.0.1:1/unreachable.png)\n[voice](https://127.0.0.1:1/missing.wav)\n[config](../.env)\n<img src=\"local.png\">"
        let result = try importText(text, from: source, into: store)
        XCTAssertEqual(result.document.markdown, text)
        XCTAssertEqual(try JSONValue.parse(result.document.assetsJSON).array?.count, 0)
        XCTAssertEqual(result.warnings.count, 3)
    }

    func testMissingInvalidOrUnsupportedMediaLeavesNoDocumentFilesOrQueue() throws {
        for name in ["missing.png", "broken.png", "secret.env", "broken.wav"] {
            let (store, source) = try fixture()
            try write(png(), "good.png", in: source)
            if name.hasPrefix("broken") { try write(Data("not media".utf8), name, in: source) }
            let link = name.hasSuffix("wav") ? "[voice](\(name))" : "![bad](\(name))"
            XCTAssertThrowsError(try importText("![good](good.png)\n\(link)", from: source, into: store))
            try assertNoImport(store)
        }
    }

    func testPathTraversalAbsoluteFileURLAndEscapingSymlinkAreRejected() throws {
        let (store, source) = try fixture()
        let outside = source.deletingLastPathComponent().appendingPathComponent("outside.png")
        try png().write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape.png"), withDestinationURL: outside)
        for path in ["../outside.png", "%2e%2e/outside.png", outside.path, outside.absoluteString, "escape.png"] {
            XCTAssertThrowsError(try importText("![image](\(path))", from: source, into: store), path)
            try assertNoImport(store)
        }
    }

    func testSafeInternalSymlinkAndPercentEncodedSpaceResolveToOneAsset() throws {
        let (store, source) = try fixture(); let image = try write(png(), "images/a b.png", in: source)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("alias.png"), withDestinationURL: image)
        let result = try importText("![one](images/a%20b.png)\n![two](alias.png)", from: source, into: store)
        XCTAssertEqual(try JSONValue.parse(result.document.assetsJSON).array?.count, 1)
        XCTAssertEqual(Set(try MarkdownReferences(result.document.markdown).references.map(\.destination)).count, 1)
    }

    func testUnreadableModeAndInvalidUTF8DoNotMakeFakeCompleteDocument() throws {
        let (store, source) = try fixture()
        let invalid = try write(Data([0xff,0xfe,0xff]), "invalid.md", in: source)
        XCTAssertThrowsError(try store.importMarkdownFile(url: invalid, parentID: "root")); try assertNoImport(store)
        let image = try write(png(), "private.png", in: source)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: image.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path) }
        XCTAssertThrowsError(try importText("![private](private.png)", from: source, into: store)) { error in
            XCTAssertTrue(error.localizedDescription.contains("访问权限"))
        }
        try assertNoImport(store)
    }

    func testDatabaseFailureRollsBackCreationAndStagedAttachments() throws {
        let (store, source) = try fixture(); try write(png(), "picture.png", in: source)
        try store.db.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_asset BEFORE INSERT ON blob_transfers BEGIN SELECT RAISE(ABORT, 'test disk failure'); END")
        }
        XCTAssertThrowsError(try importText("![picture](picture.png)", from: source, into: store))
        try assertNoImport(store)
    }

    func testOversizeSourceAndAttachmentAreRejectedBeforeReadingTheirBodies() throws {
        let (store, source) = try fixture()
        let hugeNote = try write(Data(), "huge.md", in: source)
        let sourceHandle = try FileHandle(forWritingTo: hugeNote)
        try sourceHandle.truncate(atOffset: 50_000_001); try sourceHandle.close()
        XCTAssertThrowsError(try store.importMarkdownFile(url: hugeNote, parentID: "root")) { error in
            guard case MarkdownImportError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let hugeImage = try write(png(), "huge.png", in: source)
        let imageHandle = try FileHandle(forWritingTo: hugeImage)
        try imageHandle.truncate(atOffset: 50_000_001); try imageHandle.close()
        XCTAssertThrowsError(try importText("![huge](huge.png)", from: source, into: store)) { error in
            guard case MarkdownImportError.imageTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try assertNoImport(store)
    }

    func testImageSizeUsesServerTwentyMegabyteLimit() throws {
        let (store, source) = try fixture()
        let image = try write(png(), "picture.png", in: source)
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: 20_000_001); try handle.close()
        XCTAssertThrowsError(try importText("![oversized image](picture.png)", from: source, into: store)) { error in
            guard case MarkdownImportError.imageTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("20 MB"))
        }
        try assertNoImport(store)
    }

    func testBOMMultibytePrefixAndMathRemainByteExactOutsideReferences() throws {
        let (store, source) = try fixture(); try write(png(), "picture.png", in: source)
        let prefix = "\u{FEFF}中文 🧑🏽‍💻 ", suffix = " 结束\n\n$\\alpha + \\beta$\n\n$$\n\\int_0^1 x^2 dx\n$$\n"
        let result = try importText(prefix + "![image](picture.png)" + suffix, from: source, into: store)
        XCTAssertTrue(result.document.markdown.hasPrefix(prefix), "Actual: \(result.document.markdown.debugDescription), expected: \(prefix.debugDescription)")
        XCTAssertTrue(result.document.markdown.hasSuffix(suffix))
        XCTAssertEqual(try MarkdownReferences(result.document.markdown).mediaReferences.count, 1)
    }

    func testClassicMacNewlinesAndTabsDoNotShiftAttachmentRanges() throws {
        let (store, source) = try fixture(); try write(png(), "picture.png", in: source)
        let prefix = "# 标题\r\r中文\t", suffix = " 尾部\r"
        let result = try importText(prefix + "![image](picture.png)" + suffix, from: source, into: store)
        XCTAssertTrue(result.document.markdown.hasPrefix(prefix))
        XCTAssertTrue(result.document.markdown.hasSuffix(suffix))
    }

    func testAudioContainerCannotMasqueradeAsDifferentExtension() throws {
        let (store, source) = try fixture(); try write(wav(), "recording.mp3", in: source)
        XCTAssertThrowsError(try importText("[recording](recording.mp3)", from: source, into: store)) { error in
            guard case MarkdownImportError.invalidMedia = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try assertNoImport(store)
    }

    func testRealHTTPImportedImageAndAudioRoundTripWithoutCodeOrPrivateLinkReads() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["TEST_TOKENLIBRARY_URL"], let url = URL(string: address),
              ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? ""),
              let username = environment["TEST_TOKENLIBRARY_USER"], let password = environment["TEST_TOKENLIBRARY_PASSWORD"] else {
            throw XCTSkip("Requires an explicitly configured isolated localhost service")
        }
        let (aStore, source) = try fixture(), (bStore, _) = try fixture()
        let a = SyncClient(baseURL: url), b = SyncClient(baseURL: url)
        let login = try await a.login(username: username, password: password)
        _ = try await b.login(username: username, password: password)
        _ = try await a.synchronize(store: aStore)
        let picture = try png(), voice = wav()
        try write(picture, "picture.png", in: source); try write(voice, "voice.wav", in: source)
        let literal = "```md\n![not an attachment](media/missing.png)\n```"
        let sourceText = "![photo](picture.png)\n[voice](voice.wav)\n\n" + literal + "\n\n[config](.env)\n"
        let imported = try importText(sourceText, from: source, into: aStore, name: "import-\(UUID().uuidString).md", parent: login.rootId)
        _ = try await a.synchronize(store: aStore); _ = try await b.synchronize(store: bStore)
        let received = try XCTUnwrap(bStore.loadDocument(id: imported.document.id))
        XCTAssertEqual(received.markdown, imported.document.markdown)
        XCTAssertTrue(received.markdown.contains(literal)); XCTAssertTrue(received.markdown.contains("[config](.env)"))
        let media = try MarkdownReferences(received.markdown).mediaReferences
        XCTAssertEqual(media.count, 2)
        let contents = try media.map { try Data(contentsOf: bStore.resolveAttachment(path: $0.destination)) }
        XCTAssertTrue(contents.contains(picture)); XCTAssertTrue(contents.contains(voice))
        XCTAssertEqual(try JSONValue.parse(received.assetsJSON).array?.count, 2)
        XCTAssertTrue(try bStore.exportPortableMarkdown(id: received.id).isArchive)
        XCTAssertTrue(try aStore.pending().isEmpty)
    }

    func testCrossWorkspaceCopyAndPortableExportIgnoreCodeOnlyMedia() throws {
        let (store, source) = try fixture(); try write(png(), "picture.png", in: source)
        let code = "```md\n![example](media/never-present.png)\n```"
        let imported = try importText("![image](picture.png)\n\n" + code, from: source, into: store)
        let (destination, _) = try fixture()
        let copied = try destination.importLocalLibrary(from: store, sourceRootID: "root", targetRootID: "root")
        XCTAssertEqual(copied.importedAttachments, 1)
        let copy = try XCTUnwrap(destination.listDocuments().first)
        XCTAssertTrue(copy.markdown.contains(code))
        XCTAssertTrue(try destination.exportPortableMarkdown(id: copy.id).isArchive)
        XCTAssertTrue(try store.exportPortableMarkdown(id: imported.document.id).isArchive)
    }
}
