import Foundation
import PDFKit
import XCTest
@testable import LibraryCore

final class PDFImportValidationTests: XCTestCase {
    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    func testPasswordRequiredIsDistinctFromCorruptionAndDoesNotModifyOriginal() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("locked.pdf")
            let document = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "synthetic protected source")))
            XCTAssertTrue(document.write(to: url, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]))
            let original = try Data(contentsOf: url)
            XCTAssertTrue(try XCTUnwrap(PDFDocument(data: original)).isLocked)
            XCTAssertThrowsError(try PDFImportValidation.read(url: url)) { XCTAssertEqual($0 as? PDFImportError, .passwordRequired) }
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertFalse(PDFImportError.passwordRequired.localizedDescription.contains("损坏"))
        }
    }

    func testReadableEncryptedPDFIsAcceptedWithOriginalBytes() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("owner-only.pdf")
            let document = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "readable encrypted source")))
            XCTAssertTrue(document.write(to: url, withOptions: [.ownerPasswordOption: "owner"]))
            let original = try Data(contentsOf: url)
            let reopened = try XCTUnwrap(PDFDocument(data: original))
            XCTAssertTrue(reopened.isEncrypted)
            XCTAssertFalse(reopened.isLocked)
            XCTAssertEqual(try PDFImportValidation.read(url: url), original)
        }
    }

    func testCorruptEmptyAndZeroPagePDFRejectWithoutPasswordAdvice() throws {
        let emptyPDF = Data("%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\ntrailer << /Root 1 0 R /Size 3 >>\n%%EOF".utf8)
        for data in [Data(), Data("not a PDF".utf8), emptyPDF] {
            XCTAssertThrowsError(try PDFImportValidation.validate(data: data)) { XCTAssertEqual($0 as? PDFImportError, .corrupt) }
        }
        XCTAssertFalse(PDFImportError.corrupt.localizedDescription.contains("密码"))
    }

    func testMissingAndDirectoryInputsHaveActionableReadFailure() throws {
        try withDirectory { directory in
            for url in [directory, directory.appendingPathComponent("missing.pdf")] {
                XCTAssertThrowsError(try PDFImportValidation.read(url: url)) { XCTAssertEqual($0 as? PDFImportError, .unreadable) }
            }
        }
    }

    func testFiftyMillionByteBoundaryUsesActualReadablePDF() throws {
        try withDirectory { directory in
            // A real referenced text stream, with no appended bytes after EOF.
            let limit = PDFImportValidation.maximumByteCount
            var textLength = limit - PDFExport.makeSamplePDF(text: "").count
            var data = PDFExport.makeSamplePDF(text: String(repeating: "a", count: textLength))
            textLength += limit - data.count
            data = PDFExport.makeSamplePDF(text: String(repeating: "a", count: textLength))
            XCTAssertEqual(data.count, 50_000_000)
            let url = directory.appendingPathComponent("boundary.pdf")
            try data.write(to: url)
            XCTAssertEqual(try PDFImportValidation.read(url: url), data)
            let oversized = PDFExport.makeSamplePDF(text: String(repeating: "a", count: textLength + 1))
            XCTAssertEqual(oversized.count, 50_000_001)
            XCTAssertEqual(PDFDocument(data: oversized)?.pageCount, 1)
            try oversized.write(to: url)
            XCTAssertThrowsError(try PDFImportValidation.read(url: url)) { XCTAssertEqual($0 as? PDFImportError, .tooLarge) }
            XCTAssertThrowsError(try PDFImportValidation.validate(data: oversized)) { XCTAssertEqual($0 as? PDFImportError, .tooLarge) }
        }
    }
}
