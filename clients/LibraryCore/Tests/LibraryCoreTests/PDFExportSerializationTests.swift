import XCTest
import PDFKit
@testable import LibraryCore

final class PDFExportSerializationTests: XCTestCase {
    private let contents = "text with (parentheses), \\ and fake 6 0 R >> /NM (wrong)"
    private let stream = "% fake xref\n% 6 0 obj << /NM (not an annotation) >>\nBT /F1 12 Tf 40 700 Td (original searchable text) Tj ET\n"

    private func string(_ text: String) -> String {
        "(" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)") + ")"
    }
    private func fixture(missingSlot: Bool = true, referencedMissing: Bool = false, directAnnotations: Bool = false, duplicate: Bool = false) -> Data {
        let annotation = "<< /Type /Annot /Subtype /FreeText /Rect [40 500 240 530] /Contents \(string(contents)) /DA (0 g /Helvetica 12 Tf) >>"
        var objects = [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots \(directAnnotations ? "[\(annotation)]" : "8 0 R") >>",
            4: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
            5: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            7: annotation,
            8: "[7 0 R]",
        ]
        if duplicate { objects[8] = "[7 0 R 9 0 R]"; objects[9] = annotation }
        if referencedMissing { objects[1] = "<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R >>" }
        var data = Data("%PDF-1.4\n".utf8), offsets: [Int: Int] = [:]
        for id in objects.keys.sorted() {
            offsets[id] = data.count
            data.append(Data("\(id) 0 obj\n\(objects[id]!)\nendobj\n".utf8))
        }
        let xref = data.count
        let size = (objects.keys.max() ?? 0) + 1
        data.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for id in 1..<size {
            data.append(Data(String(format: "%010d 00000 %@ \n", offsets[id] ?? 0, offsets[id] != nil || missingSlot ? "n" : "f").utf8))
        }
        data.append(Data("trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
    private func identities(_ name: String = "tokenlibrary:测试 (one) \\ 🧪") -> [[PDFExportSerialization.Identity]] {
        [[.init(index: 0, name: name, type: "FreeText", contents: contents,
                bounds: CGRect(x: 40, y: 500, width: 200, height: 30))]]
    }
    private func verifyOffsets(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = try XCTUnwrap(data.range(of: Data("startxref\n".utf8), options: .backwards), file: file, line: line)
        let ending = String(decoding: data[marker.upperBound...], as: UTF8.self)
        let offset = try XCTUnwrap(Int(ending.split(separator: "\n")[0]), file: file, line: line)
        let table = String(decoding: data[offset...], as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(table[0], "xref", file: file, line: line)
        let count = try XCTUnwrap(Int(table[1].split(separator: " ")[1]))
        for id in 0..<count {
            let fields = table[2 + id].split(separator: " ")
            if fields[2] == "n" {
                let start = try XCTUnwrap(Int(fields[0]))
                XCTAssertGreaterThan(start, 0, file: file, line: line)
                XCTAssertTrue(data[start...].starts(with: Data("\(id) \(Int(fields[1])!) obj".utf8)), file: file, line: line)
            }
        }
        XCTAssertEqual(table[8].split(separator: " ")[2], "f", "Unused object 6 must be free", file: file, line: line)
    }

    func testRepairsUnreferencedZeroSlotAndRestoresUnicodeIdentityWithoutTouchingStreams() throws {
        let source = fixture()
        let output = try PDFExportSerialization.finish(source, identities: identities())
        try verifyOffsets(output)
        let document = try XCTUnwrap(PDFDocument(data: output))
        XCTAssertEqual(document.page(at: 0)?.annotations.first?.value(forAnnotationKey: .name) as? String, identities()[0][0].name)
        XCTAssertEqual(document.page(at: 0)?.annotations.first?.contents, contents)
        XCTAssertTrue(output.range(of: Data(stream.utf8)) != nil)
        XCTAssertTrue(document.string?.contains("original searchable text") == true)
        XCTAssertEqual(try PDFExportSerialization.finish(output, identities: identities()), output)
    }
    func testDirectAnnotationDictionaryAndIndirectAnnotationArrayBothWork() throws {
        for direct in [true, false] {
            let output = try PDFExportSerialization.finish(fixture(directAnnotations: direct), identities: identities())
            try verifyOffsets(output)
            XCTAssertEqual(PDFDocument(data: output)?.page(at: 0)?.annotations.first?.value(forAnnotationKey: .name) as? String, identities()[0][0].name)
        }
    }
    func testReferencedMissingObjectFailsInsteadOfPublishingContentLoss() {
        XCTAssertThrowsError(try PDFExportSerialization.finish(fixture(referencedMissing: true), identities: identities()))
    }
    func testAnnotationMismatchDoesNotAssignIdentityToWrongMaterial() {
        let mismatch = PDFExportSerialization.Identity(index: 0, name: "tokenlibrary:wrong", type: "Highlight", contents: contents,
                                                       bounds: CGRect(x: 40, y: 500, width: 200, height: 30))
        XCTAssertThrowsError(try PDFExportSerialization.finish(fixture(), identities: [[mismatch]]))
    }
    func testMalformedIndexedObjectAndUnsupportedIndexFailClearly() throws {
        var data = fixture()
        let object = try XCTUnwrap(data.range(of: Data("7 0 obj".utf8)))
        data.replaceSubrange(object, with: Data("9 0 obj".utf8))
        XCTAssertThrowsError(try PDFExportSerialization.finish(data, identities: identities()))
        XCTAssertThrowsError(try PDFExportSerialization.finish(Data("%PDF-1.7\nstartxref\n0\n%%EOF".utf8), identities: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("原文件与批注仍保留"))
        }
    }
    func testExistingOriginalIdentityIsPreservedAndConflictingIdentityIsRejected() throws {
        let first = try PDFExportSerialization.finish(fixture(missingSlot: false), identities: identities("original vendor annotation"))
        XCTAssertEqual(try PDFExportSerialization.finish(first, identities: identities("original vendor annotation")), first)
        XCTAssertThrowsError(try PDFExportSerialization.finish(first, identities: identities("tokenlibrary:someone-else")))
    }
    func testIdenticalLookingAnnotationsKeepDistinctStableIdentities() throws {
        var expected = identities("original vendor annotation")
        expected[0].append(.init(index: 1, name: "tokenlibrary:second", type: "FreeText", contents: contents,
                                bounds: CGRect(x: 40, y: 500, width: 200, height: 30)))
        let output = try PDFExportSerialization.finish(fixture(duplicate: true), identities: expected)
        let names = PDFDocument(data: output)?.page(at: 0)?.annotations.compactMap { $0.value(forAnnotationKey: .name) as? String }
        XCTAssertEqual(names, ["original vendor annotation", "tokenlibrary:second"])
        try verifyOffsets(output)
    }
    func testIncorrectStreamLengthIsRejectedWithoutSearchingForFakeSyntax() throws {
        var data = fixture()
        let length = try XCTUnwrap(data.range(of: Data("/Length \(stream.utf8.count)".utf8)))
        data.replaceSubrange(length, with: Data("/Length \(stream.utf8.count - 2)".utf8))
        XCTAssertThrowsError(try PDFExportSerialization.finish(data, identities: identities()))
    }
    func testPageTreeCycleFailsWithinBoundedTraversal() throws {
        var data = fixture()
        let kids = try XCTUnwrap(data.range(of: Data("/Kids [3 0 R]".utf8)))
        data.replaceSubrange(kids, with: Data("/Kids [2 0 R]".utf8))
        XCTAssertThrowsError(try PDFExportSerialization.finish(data, identities: identities()))
    }
    func testTruncatedTrailerFailsRatherThanGuessingACompleteFile() {
        let data = fixture().dropLast(6)
        XCTAssertThrowsError(try PDFExportSerialization.finish(Data(data), identities: identities()))
    }
}
