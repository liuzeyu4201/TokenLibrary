import XCTest
import PDFKit
import AppKit
@testable import LibraryUI
@testable import LibraryCore

@MainActor
final class PDFOriginalTextTests: XCTestCase {
    func testSearchUsesOriginalCharactersAndExcludesRasterPages() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "Anchor alpha\nAnchor beta")))
        let image = NSImage(size: NSSize(width: 400, height: 150))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 400, height: 150).fill()
        ("RasterOnlyAnchor" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let raster = try XCTUnwrap(PDFPage(image: image))
        pdf.insert(raster, at: pdf.pageCount)
        let index = PDFOriginalTextIndex(document: pdf)
        XCTAssertTrue(index.hasText); XCTAssertTrue(index.hasText(on: 0)); XCTAssertFalse(index.hasText(on: 1))
        XCTAssertTrue(index.selections(in: pdf, query: "RasterOnlyAnchor").isEmpty)
        XCTAssertTrue(index.selections(in: pdf, query: "").isEmpty)
        let matches = index.selections(in: pdf, query: "anchor")
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.allSatisfy { $0.string?.lowercased() == "anchor" && $0.pages.first === pdf.page(at: 0) })
        XCTAssertTrue(matches.allSatisfy { index.contains($0, in: pdf) })
    }
}
