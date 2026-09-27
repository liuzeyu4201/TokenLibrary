import Foundation
import PDFKit
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class PDFImportModelTests: XCTestCase {
    private func withModel(_ test: (AppModel, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-import-model-\(UUID().uuidString)")
        let suite = "app.tokenlibrary.pdf-import-model.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = try AppModel(directory: directory, preferences: preferences, restoreSavedSession: false)
        try test(model, directory)
    }

    func testRejectedPDFsPreserveSelectionDocumentsQueueAndMediaWithDistinctMessages() throws {
        try withModel { model, directory in
            model.newNote()
            let previousSelection = try XCTUnwrap(model.selectedId)
            let previousDocuments = model.documents.map(\.id)
            let previousQueue = try model.store.pending().count
            let media = model.store.root.appendingPathComponent("media")
            let previousMedia = (try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []

            let corrupt = directory.appendingPathComponent("corrupt.pdf")
            try Data("not a PDF".utf8).write(to: corrupt)
            let locked = directory.appendingPathComponent("locked.pdf")
            let document = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "protected")))
            XCTAssertTrue(document.write(to: locked, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]))
            let oversized = directory.appendingPathComponent("oversized.pdf")
            try Data().write(to: oversized)
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(PDFImportValidation.maximumByteCount + 1))
            try handle.close()
            let missing = directory.appendingPathComponent("missing.pdf")

            for (url, error) in [(corrupt, PDFImportError.corrupt), (locked, .passwordRequired), (oversized, .tooLarge), (missing, .unreadable)] {
                model.dismissLocalOperationError()
                model.importFile(url: url)
                XCTAssertEqual(model.localOperationError, "导入失败：\(error.localizedDescription)")
                XCTAssertNil(model.connectionError, "local import failure is not a connection failure")
                XCTAssertEqual(model.documents.map(\.id), previousDocuments)
                XCTAssertEqual(model.selectedId, previousSelection)
                XCTAssertEqual(try model.store.pending().count, previousQueue)
                XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? [], previousMedia)
            }
        }
    }

    func testReadableEncryptedPDFImportsWithoutRewritingItsBytes() throws {
        try withModel { model, directory in
            let url = directory.appendingPathComponent("readable-encrypted.pdf")
            let source = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "owner restricted synthetic source")))
            XCTAssertTrue(source.write(to: url, withOptions: [.ownerPasswordOption: "owner"]))
            let original = try Data(contentsOf: url)
            let reopened = try XCTUnwrap(PDFDocument(data: original))
            XCTAssertTrue(reopened.isEncrypted)
            XCTAssertFalse(reopened.isLocked)
            model.importFile(url: url)
            XCTAssertNil(model.localOperationError)
            XCTAssertNil(model.connectionError)
            let imported = try XCTUnwrap(model.selected)
            XCTAssertEqual(imported.kind, .pdf)
            XCTAssertEqual(imported.catalog.originalFileHash, BlobIntegrity.sha256(original))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(imported.pdfPath))), original)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(model.documents.count, 1)
            XCTAssertEqual(try model.store.pending().count, 1)
        }
    }
}
