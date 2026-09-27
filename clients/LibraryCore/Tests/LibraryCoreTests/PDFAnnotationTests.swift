import XCTest
import PDFKit
@testable import LibraryCore

final class PDFAnnotationTests: XCTestCase {
    private func annotation(_ id: String = "a", text: String = "note") -> PDFTextAnnotation {
        PDFTextAnnotation(id: id, type: "comment", pageIndex: 0, x: 72, y: 660, width: 140, height: 32, color: "#FF0000", text: text)
    }
    func testDeletionPropagatesAndDeleteVersusEditConflicts() {
        let a = annotation()
        XCTAssertEqual(PDFMerge.mergeAdds(base: [a], local: [], remote: [a]).merged, [])
        XCTAssertFalse(PDFMerge.mergeAdds(base: [a], local: [], remote: [a]).conflict)
        XCTAssertEqual(PDFMerge.mergeAdds(base: [a], local: [a], remote: []).merged, [])
        XCTAssertTrue(PDFMerge.mergeAdds(base: [a], local: [], remote: [annotation(text: "remote edit")]).conflict)
    }
    func testIndependentEditsAndDeletesMergeWithoutResurrecting() {
        let a = annotation(), b = annotation("b"), c = annotation("c")
        let result = PDFMerge.mergeAdds(base: [a,b], local: [annotation(text: "edited"),b], remote: [a,c])
        XCTAssertFalse(result.conflict)
        XCTAssertEqual(result.merged.map(\.id), ["a","c"])
        XCTAssertEqual(result.merged.first?.text, "edited")
    }
    func testOverlayRefreshDeletesOnlyManagedAnnotationsAndExportIsIdempotent() throws {
        let original = PDFExport.makeSamplePDF(text: "selection target")
        let pdf = try XCTUnwrap(PDFDocument(data: original))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let existing = PDFAnnotation(bounds: CGRect(x: 30,y: 30,width: 100,height: 30), forType: .text, withProperties: nil)
        existing.contents = "original annotation"; page.addAnnotation(existing)
        // PDFKit creates a Popup companion for an original Text annotation.
        // Both original objects must survive refreshing our managed overlay.
        let originalCount=page.annotations.count
        PDFExport.apply(to: pdf, annotations: [annotation()])
        PDFExport.apply(to: pdf, annotations: [annotation(text: "updated")])
        XCTAssertEqual(page.annotations.count, originalCount + 1)
        XCTAssertTrue(page.annotations.contains { $0.contents == "updated" })
        let once = try XCTUnwrap(pdf.dataRepresentation())
        let twice = try PDFExport.exportAnnotated(pdfData: once, annotations: [annotation(text: "updated")])
        let reopened=try XCTUnwrap(PDFDocument(data:twice)?.page(at:0))
        XCTAssertEqual(reopened.annotations.filter { ($0.value(forAnnotationKey:.name) as? String)?.hasPrefix("tokenlibrary:") == true }.count,1)
        XCTAssertTrue(reopened.annotations.contains { $0.contents == "original annotation" })
        PDFExport.replaceManaged(in: pdf, annotations: [])
        XCTAssertEqual(page.annotations.count, originalCount)
        XCTAssertEqual(page.annotations[0].contents, "original annotation")
        XCTAssertEqual(original, PDFExport.makeSamplePDF(text: "selection target"))
    }
    func testInvalidAnnotationCoordinatesAndPageDoNotCrashOrAdd() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "sample")))
        var negative = annotation(); negative.pageIndex = -1
        var nan = annotation("nan"); nan.x = .nan
        var badSize = annotation("badSize"); badSize.width = 0
        PDFExport.apply(to: pdf, annotations: [negative,nan,badSize])
        XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 0)
    }
    func testSelectionRetainsQuotedText() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "quote from source")))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5)))
        let records = PDFExport.records(from: selection, type: "highlight", color: "#FFE08A", text: "")
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(records.first?.text, "quote")
        XCTAssertEqual(records.first?.pageIndex, 0)
    }

    func testUnicodeCommentsHavePortableAppearanceAndKeepOriginalText() throws {
        let source = PDFExport.makeSamplePDF(text: "selectable original source")
        for text in ["English research comment", "文字备注、读书研究", "读书研究 📚 ✅ English"] {
            var note = annotation(text: text); note.width = 400; note.height = 50
            let result = try PDFExport.exportAnnotated(pdfData: source, annotations: [note])
            let reopened = try XCTUnwrap(PDFDocument(data: result))
            XCTAssertTrue((reopened.string ?? "").contains("selectable original source"))
            let exported = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
            XCTAssertEqual(exported.contents, text)
            XCTAssertEqual(exported.type, "FreeText")
            XCTAssertEqual(exported.value(forAnnotationKey: .name) as? String, "tokenlibrary:a")
            let provider = try XCTUnwrap(CGDataProvider(data: result as CFData))
            let pdf = try XCTUnwrap(CGPDFDocument(provider))
            let dictionary = try XCTUnwrap(pdf.page(at: 1)?.dictionary)
            var annotations: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
            var object: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &object))
            var appearanceString: CGPDFStringRef?
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(object), "DA", &appearanceString),
                          "Default appearance must be a PDF String, not PDFKit's invalid Name")
            var appearance: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(object), "AP", &appearance))
            var normal: CGPDFStreamRef?
            XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(appearance), "N", &normal))
            var resources: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(CGPDFStreamGetDictionary(try XCTUnwrap(normal))), "Resources", &resources))
            var fonts: CGPDFDictionaryRef?
            let hasFonts = CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Font", &fonts)
            XCTAssertFalse(hasFonts && fonts.map { CGPDFDictionaryGetCount($0) > 0 } == true,
                           "Our appearance must not contain broken PDFKit embedded font streams")
        }
        XCTAssertEqual(source, PDFExport.makeSamplePDF(text: "selectable original source"))
    }

    func testPlacementStateRoundTripLegacyAndFileVersionSafety() throws {
        let legacyJSON = ##"{"id":"legacy","type":"comment","pageIndex":0,"x":72,"y":660,"width":140,"height":32,"color":"#FF0000","text":"legacy note"}"##
        let legacy = try JSONDecoder().decode(PDFTextAnnotation.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.placementState, "attached")
        XCTAssertFalse(legacy.needsPlacementReview(for: "new"))
        var old = annotation("old"); old.pdfBlobId = "old"
        var current = annotation("current"); current.pdfBlobId = "new"
        var review = annotation("review"); review.pdfBlobId = "new"; review.placementState = "needs_review"
        var unknown = annotation("unknown"); unknown.placementState = "future-state"
        XCTAssertTrue(old.needsPlacementReview(for: nil))
        XCTAssertEqual(try JSONDecoder().decode(PDFTextAnnotation.self, from: JSONEncoder().encode(review)), review)
        let source = PDFExport.makeSamplePDF(text: "replacement PDF")
        let pdf = try XCTUnwrap(PDFDocument(data: source))
        PDFExport.apply(to: pdf, annotations: [old], currentPDFBlobId: "old")
        XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 1)
        PDFExport.replaceManaged(in: pdf, annotations: [old, current, review, unknown, legacy], currentPDFBlobId: "new")
        let ids = Set(pdf.page(at: 0)!.annotations.compactMap { $0.value(forAnnotationKey: .name) as? String })
        XCTAssertEqual(ids, ["tokenlibrary:current", "tokenlibrary:legacy"])
        // Re-exporting an already annotated PDF must also remove stale managed
        // objects from its original page, not merely skip adding them again.
        var legacyReview = legacy; legacyReview.placementState = "needs_review"
        let exported = try PDFExport.exportAnnotated(pdfData: try XCTUnwrap(pdf.dataRepresentation()),
            annotations: [old, current, review, legacyReview], currentPDFBlobId: "different")
        XCTAssertEqual(PDFDocument(data: exported)?.page(at: 0)?.annotations.count, 0)
    }

    func testRefreshingManagedAnnotationKeepsStableObjectAndRemovesDuplicates() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExport.makeSamplePDF(text: "source")))
        PDFExport.replaceManaged(in: pdf, annotations: [annotation()])
        let originalObject = try XCTUnwrap(pdf.page(at: 0)?.annotations.first)
        PDFExport.replaceManaged(in: pdf, annotations: [annotation(text: "updated")])
        XCTAssertTrue(pdf.page(at: 0)?.annotations.first === originalObject)
        XCTAssertEqual(originalObject.contents, "updated")
        let duplicate = PDFAnnotation(bounds: originalObject.bounds, forType: .freeText, withProperties: nil)
        duplicate.setValue("tokenlibrary:a", forAnnotationKey: .name)
        pdf.page(at: 0)?.addAnnotation(duplicate)
        PDFExport.replaceManaged(in: pdf, annotations: [annotation(text: "updated")])
        XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 1)
        PDFExport.replaceManaged(in: pdf, annotations: [])
        XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 0)
    }

    func testExportedHighlightQuadPointsMatchSelectedPageCoordinates() throws {
        let source = PDFExport.makeSamplePDF(text: "visible highlight selection")
        let pdf = try XCTUnwrap(PDFDocument(data: source))
        let selection = try XCTUnwrap(pdf.findString("highlight", withOptions: []).first)
        let records = PDFExport.records(from: selection, type: "highlight", color: "#FFE08A", text: "")
        let record = try XCTUnwrap(records.first)
        let result = try PDFExport.exportAnnotated(pdfData: source, annotations: records)
        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: result as CFData))))
        var array: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.page(at: 1)?.dictionary), "Annots", &array))
        var annotationDictionary: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(array), 0, &annotationDictionary))
        var points: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(annotationDictionary), "QuadPoints", &points))
        let expected = [record.x, record.y + record.height, record.x + record.width, record.y + record.height,
                        record.x, record.y, record.x + record.width, record.y]
        for (index, target) in expected.enumerated() {
            var value: CGPDFReal = 0
            XCTAssertTrue(CGPDFArrayGetNumber(try XCTUnwrap(points), index, &value))
            XCTAssertEqual(value, target, accuracy: 0.001)
        }
    }

    func testReimportingOwnExportKeepsItsOriginalAnnotations() throws {
        let source = PDFExport.makeSamplePDF(text: "original highlighted text")
        let sourceDocument = try XCTUnwrap(PDFDocument(data: source))
        let selection = try XCTUnwrap(sourceDocument.findString("highlighted", withOptions: []).first)
        let highlight = PDFExport.records(from: selection, type: "highlight", color: "#FFE08A", text: "")
        let originalAnnotations = highlight + [annotation("original-note", text: "原件的原有注释")]
        let originalExport = try PDFExport.exportAnnotated(pdfData: source, annotations: originalAnnotations)
        // Importing this PDF makes its entire content, including TokenLibrary
        // annotations, immutable original material for a new document.
        let reimport = try XCTUnwrap(PDFDocument(data: originalExport))
        PDFExport.replaceManaged(in: reimport, annotations: [])
        XCTAssertEqual(reimport.page(at: 0)?.annotations.count, 2)
        PDFExport.replaceManaged(in: reimport, annotations: [annotation("new", text: "new overlay")])
        XCTAssertEqual(reimport.page(at: 0)?.annotations.count, 3)
        PDFExport.replaceManaged(in: reimport, annotations: [])
        XCTAssertEqual(reimport.page(at: 0)?.annotations.count, 2)
        let exportedAgain = try PDFExport.exportAnnotated(pdfData: originalExport, annotations: [])
        let final = try XCTUnwrap(PDFDocument(data: exportedAgain)?.page(at: 0))
        XCTAssertEqual(final.annotations.count, 2)
        XCTAssertTrue(final.annotations.contains { $0.contents == "原件的原有注释" })
    }
}
