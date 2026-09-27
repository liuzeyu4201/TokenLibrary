import XCTest
import GRDB
@testable import LibraryCore

final class AttachmentPathTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        // Exercise macOS's real /tmp -> /private/tmp alias without touching any
        // pre-existing library. The whole tree is unique to this test.
        let url = URL(fileURLWithPath: "/private/tmp/tokenlibrary-attachment-path-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func alternate(_ url: URL) -> URL {
        let path = url.path
        return URL(fileURLWithPath: path.hasPrefix("/private/tmp/") ? String(path.dropFirst("/private".count)) : "/private" + path)
    }

    private func asset(path: String, bytes: Data) -> LibraryAsset {
        LibraryAsset(blobId: UUID().uuidString.lowercased(), path: path,
                     sha256: BlobIntegrity.sha256(bytes), size: Int64(bytes.count), mime: "image/png")
    }

    func testFirstAttachmentUnderPrivateTmpBeforeMediaExists() throws {
        let root = try temporaryRoot().appendingPathComponent("library"), store = try DocumentStore(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("media").path))
        let bytes = Data("first attachment bytes".utf8)
        let saved = try store.importAttachment(data: bytes, fileName: "diagram.png", mime: "image/png")
        XCTAssertTrue(saved.path.hasPrefix("media/"))
        XCTAssertEqual(try Data(contentsOf: store.resolveAttachment(path: saved.path)), bytes)
        XCTAssertEqual(try store.transfer(blobId: saved.blobId)?.asset.path, saved.path)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testAbsoluteAliasesResolveToSameFileBeforeAndAfterFirstSave() throws {
        let root = try temporaryRoot().appendingPathComponent("library"), store = try DocumentStore(directory: alternate(root))
        let path = "media/nested/first.png", bytes = Data("same physical file".utf8)
        let relative = try store.resolveAttachment(path: path)
        XCTAssertEqual(try store.resolveAttachment(path: root.appendingPathComponent(path).path), relative)
        XCTAssertEqual(try store.resolveAttachment(path: alternate(root).appendingPathComponent(path).path), relative)
        try store.installAttachment(data: bytes, asset: asset(path: path, bytes: bytes))
        XCTAssertEqual(try store.resolveAttachment(path: path), relative)
        XCTAssertEqual(try Data(contentsOf: store.resolveAttachment(path: root.appendingPathComponent(path).path)), bytes)
        XCTAssertEqual(try Data(contentsOf: store.resolveAttachment(path: alternate(root).appendingPathComponent(path).path)), bytes)
    }

    func testRegisterAttachmentKeepsPortableRelativePathAcrossAliases() throws {
        let root = try temporaryRoot().appendingPathComponent("library"), store = try DocumentStore(directory: root)
        let file = root.appendingPathComponent("media/imported.png"), bytes = Data("register original bytes".utf8)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let saved = try store.registerAttachment(path: alternate(file).path, mime: "image/png")
        XCTAssertEqual(saved.path, "media/imported.png")
        XCTAssertEqual(saved.sha256, BlobIntegrity.sha256(bytes))
        XCTAssertEqual(try store.registerAttachment(path: file.path, mime: "image/png").blobId, saved.blobId)
        XCTAssertEqual(try Data(contentsOf: store.resolveAttachment(path: saved.path)), bytes)
    }

    func testRegistrationThroughSymbolicLibraryRootKeepsRelativePath() throws {
        let base = try temporaryRoot(), physical = base.appendingPathComponent("physical-long-library-name")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let store = try DocumentStore(directory: alias), bytes = Data("symbolic library root".utf8)
        let file = physical.appendingPathComponent("media/original.png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let saved = try store.registerAttachment(path: file.path, mime: "image/png")
        XCTAssertEqual(saved.path, "media/original.png")
        XCTAssertEqual(try Data(contentsOf: store.resolveAttachment(path: saved.path)), bytes)
    }

    func testMissingNestedDirectoriesSurviveReopeningThroughOtherAlias() throws {
        let root = try temporaryRoot().appendingPathComponent("library"), store = try DocumentStore(directory: root)
        let bytes = Data("new nested attachment".utf8), saved = asset(path: "media/new/nested/source.png", bytes: Data("new nested attachment".utf8))
        try store.installAttachment(data: bytes, asset: saved)
        try store.db.close()
        let reopened = try DocumentStore(directory: alternate(root))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.assetURL(id: saved.blobId))), bytes)
        XCTAssertEqual(try reopened.transfer(blobId: saved.blobId)?.asset.path, saved.path)
        XCTAssertTrue(try reopened.pending().isEmpty)
    }

    func testOutsideAndDanglingSymlinksAreRejectedBeforeAnyWrite() throws {
        let base = try temporaryRoot(), root = base.appendingPathComponent("library"), outside = base.appendingPathComponent("outside")
        let store = try DocumentStore(directory: root), bytes = Data("must stay inside".utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        for (name, destination) in [("escape", outside), ("dangling", outside.appendingPathComponent("not-created"))] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("media/" + name), withDestinationURL: destination)
            let saved = asset(path: "media/" + name + "/new.png", bytes: bytes)
            XCTAssertThrowsError(try store.installAttachment(data: bytes, asset: saved)) { error in
                XCTAssertEqual(error as? TransferError, .invalidPath)
            }
            XCTAssertNil(try store.transfer(blobId: saved.blobId))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testInternalSymlinkResolvesAndRegistersCanonicalRelativePath() throws {
        let root = try temporaryRoot().appendingPathComponent("library"), store = try DocumentStore(directory: root)
        let actual = root.appendingPathComponent("media/actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("media/shortcut"), withDestinationURL: alternate(actual))
        let bytes = Data("internal link".utf8), saved = asset(path: "media/shortcut/image.png", bytes: Data("internal link".utf8))
        try store.installAttachment(data: bytes, asset: saved)
        XCTAssertEqual(try Data(contentsOf: actual.appendingPathComponent("image.png")), bytes)
        let registered = try store.registerAttachment(path: saved.path, mime: "image/png")
        XCTAssertEqual(registered.path, "media/actual/image.png")
        XCTAssertEqual(try Data(contentsOf: store.resolveAttachment(path: registered.path)), bytes)
    }

    func testTraversalSiblingPrefixAndLibraryRootAreRejected() throws {
        let base = try temporaryRoot(), root = base.appendingPathComponent("library"), store = try DocumentStore(directory: root)
        let sibling = base.appendingPathComponent("library-other")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        for path in ["../library-other/file.png", sibling.appendingPathComponent("file.png").path, root.path, "."] {
            XCTAssertThrowsError(try store.resolveAttachment(path: path)) { error in
                XCTAssertEqual(error as? TransferError, .invalidPath)
            }
        }
    }
}
