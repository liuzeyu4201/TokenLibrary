import Foundation
import PDFKit
import CoreText
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// A real FreeText annotation with a portable appearance, not a flattened page.
/// Some PDFKit versions omit /Length in embedded FreeText font streams. Glyph
/// outlines avoid that serializer path while keeping the Unicode /Contents and
/// stable /NM annotation identity. Color glyphs use a bounded appearance image.
private final class PortableFreeTextAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.minX, y: bounds.minY)
        let localBounds = CGRect(origin: .zero, size: bounds.size)
        context.clip(to: localBounds)
        context.setFillColor(color.cgColor)
        context.fill(localBounds)
        let font = CTFontCreateUIFontForLanguage(.system, 12, nil)!
        let text = NSAttributedString(string: contents ?? "", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let inset = min(3, min(bounds.width, bounds.height) / 4)
        let textBounds = localBounds.insetBy(dx: inset, dy: inset)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
            CFRange(), CGPath(rect: textBounds, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        let outlines = CGMutablePath()
        var needsRasterAppearance = false
        for (index, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                for n in 0..<count {
                    if let path = CTFontCreatePathForGlyph(runFont, glyphs[n], nil) {
                        outlines.addPath(path, transform: CGAffineTransform(
                            translationX: origins[index].x + positions[n].x,
                            y: origins[index].y + positions[n].y))
                    } else {
                        // A space has no path and no ink. A color emoji has ink
                        // but no outline; preserve it in an image appearance.
                        var glyph = glyphs[n]
                        let ink = CTFontGetBoundingRectsForGlyphs(runFont, .default, &glyph, nil, 1)
                        if !ink.isEmpty { needsRasterAppearance = true }
                    }
                }
            }
        }
        if needsRasterAppearance {
            let scale = min(3, 2048 / max(bounds.width, bounds.height))
            let width = max(1, Int(ceil(bounds.width * scale)))
            let height = max(1, Int(ceil(bounds.height * scale)))
            if let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                bitmap.scaleBy(x: scale, y: scale)
                CTFrameDraw(frame, bitmap)
                if let image = bitmap.makeImage() { context.draw(image, in: localBounds); return }
            }
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(outlines)
        context.fillPath()
    }
}

private final class ManagedHighlightAnnotation: PDFAnnotation {}

public enum PDFExport {
    public static func exportAnnotated(pdfData: Data, annotations: [PDFTextAnnotation], currentPDFBlobId: String? = nil) throws -> Data {
        guard let doc = PDFDocument(data: pdfData) else { throw StoreError.notFound }
        replaceManaged(in: doc, annotations: annotations, currentPDFBlobId: currentPDFBlobId)
        let identities = PDFExportSerialization.identities(in: doc)
        guard let out = doc.dataRepresentation() else { throw StoreError.notFound }
        return try PDFExportSerialization.finish(out, identities: identities)
    }

    private static let identityKey = PDFAnnotationKey.name
    private static let identityPrefix = "tokenlibrary:"

    /// Refresh our overlay without removing annotations in the original PDF.
    public static func replaceManaged(in doc: PDFDocument, annotations: [PDFTextAnnotation], currentPDFBlobId: String? = nil) {
        let visibleIDs = Set(annotations.filter { !$0.needsPlacementReview(for: currentPDFBlobId) }.map { identityPrefix + $0.id })
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            // An imported PDF may itself be an earlier TokenLibrary export.
            // Its baked-in annotation objects are original material, even if
            // their names have our prefix. Only session overlays are removable
            // by omission; explicit metadata IDs are reconciled by apply().
            for annotation in page.annotations where
                (annotation is PortableFreeTextAnnotation || annotation is ManagedHighlightAnnotation)
                && !visibleIDs.contains(annotation.value(forAnnotationKey: identityKey) as? String ?? "") {
                page.removeAnnotation(annotation)
            }
        }
        apply(to: doc, annotations: annotations, currentPDFBlobId: currentPDFBlobId)
    }

    public static func apply(to doc: PDFDocument, annotations: [PDFTextAnnotation], currentPDFBlobId: String? = nil) {
        for a in annotations {
            let identity = identityPrefix + a.id
            let valid = !a.needsPlacementReview(for: currentPDFBlobId)
                && a.pageIndex >= 0 && a.pageIndex < doc.pageCount
                && [a.x, a.y, a.width, a.height].allSatisfy({ $0.isFinite })
                && a.width > 0 && a.height > 0 && ["highlight", "comment"].contains(a.type)
            var existing: PDFAnnotation?
            // Keep the same managed object across SwiftUI updates. Removing and
            // readding every overlay can leave stale PDFView accessibility views.
            for index in 0..<doc.pageCount {
                guard let oldPage = doc.page(at: index) else { continue }
                for old in oldPage.annotations where old.value(forAnnotationKey: identityKey) as? String == identity {
                    let compatible = a.type == "highlight" ? old is ManagedHighlightAnnotation : old is PortableFreeTextAnnotation
                    if valid && index == a.pageIndex && compatible && existing == nil { existing = old }
                    else { oldPage.removeAnnotation(old) }
                }
            }
            guard valid,
                  [a.x, a.y, a.width, a.height].allSatisfy({ $0.isFinite }),
                  let page = doc.page(at: a.pageIndex) else { continue }
            let bounds = clampedBounds(CGRect(x: a.x, y: a.y, width: a.width, height: a.height), on: page)
            let ann = existing ?? (a.type == "highlight"
                ? ManagedHighlightAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                : PortableFreeTextAnnotation(bounds: bounds, forType: .freeText, withProperties: nil))
            ann.bounds = bounds
            ann.setValue(identity, forAnnotationKey: identityKey)
            ann.contents = a.text
            ann.color = annotationColor(a.color)
            if a.type == "highlight" {
                ann.quadrilateralPoints = quadPoints(for: bounds)
            } else {
                #if os(iOS)
                ann.font = UIFont(name: "Helvetica", size: 12)
                ann.fontColor = .black
                #else
                ann.font = NSFont(name: "Helvetica", size: 12)
                ann.fontColor = .black
                #endif
                // Starting with a color operator prevents PDFKit treating /DA
                // as a PDF Name; the specification requires a PDF String.
                ann.setValue("0 g /Helvetica 12 Tf", forAnnotationKey: .defaultAppearance)
                let border = PDFBorder()
                border.lineWidth = 1
                ann.border = border
            }
            if existing == nil { page.addAnnotation(ann) }
        }
    }

    #if os(iOS)
    private static func annotationColor(_ hex: String) -> UIColor {
        let rgb = colorComponents(hex)
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.8)
    }
    #else
    private static func annotationColor(_ hex: String) -> NSColor {
        let rgb = colorComponents(hex)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.8)
    }
    #endif

    private static func colorComponents(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var source = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if source.count == 3 { source = source.map { "\($0)\($0)" }.joined() }
        let value = source.count == 6 ? UInt32(source, radix: 16) ?? 0xFFE08A : 0xFFE08A
        return (CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
    }

    public static func records(from selection: PDFSelection, type: String, color: String, text: String) -> [PDFTextAnnotation] {
        var out: [PDFTextAnnotation] = []
        // One rectangle per selected line avoids highlighting the entire block
        // between lines in multi-line or multi-column selections.
        let selections = type == "highlight" ? selection.selectionsByLine() : [selection]
        for line in selections {
            for page in line.pages {
                guard let document = page.document else { continue }
                let idx = document.index(for: page)
                let b = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                guard !b.isNull, b.width > 1, b.height > 1 else { continue }
                out.append(PDFTextAnnotation(
                    type: type, pageIndex: idx,
                    x: b.minX, y: b.minY, width: b.width, height: b.height,
                    color: color, text: text.isEmpty ? (line.string ?? "") : text
                ))
            }
        }
        return out
    }

    public static func fallbackHighlight(on page: PDFPage, in doc: PDFDocument) -> PDFTextAnnotation {
        let crop = page.bounds(for: .cropBox)
        let idx = max(doc.index(for: page), 0)
        let probes = [
            CGPoint(x: crop.minX + 72, y: crop.maxY - 72),
            CGPoint(x: crop.midX, y: crop.maxY - 72),
            CGPoint(x: crop.minX + 72, y: crop.midY),
        ]
        for p in probes {
            if let sel = page.selectionForLine(at: p) {
                let b = sel.bounds(for: page)
                if b.width > 4, b.height > 4, crop.intersects(b) {
                    return PDFTextAnnotation(
                        type: "highlight", pageIndex: idx,
                        x: b.minX, y: b.minY, width: b.width, height: max(b.height, 12),
                        color: "#FFE08A", text: ""
                    )
                }
            }
        }
        let rect = CGRect(
            x: crop.minX + 36,
            y: max(crop.maxY - 96, crop.minY + 24),
            width: min(280, max(crop.width - 72, 24)),
            height: 18
        )
        return PDFTextAnnotation(
            type: "highlight", pageIndex: idx,
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
            color: "#FFE08A", text: ""
        )
    }

    public static func fallbackComment(on page: PDFPage, in doc: PDFDocument, text: String) -> PDFTextAnnotation {
        let crop = page.bounds(for: .cropBox)
        let idx = max(doc.index(for: page), 0)
        let height: CGFloat = 36
        let width = min(280, max(crop.width - 48, 48))
        let rect = CGRect(
            x: crop.minX + 24,
            y: min(max(crop.midY - 18, crop.minY + 8), crop.maxY - height - 8),
            width: width,
            height: height
        )
        return PDFTextAnnotation(
            type: "comment", pageIndex: idx,
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
            color: "#007AFF", text: text
        )
    }

    public static func clampedBounds(_ raw: CGRect, on page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        var rect = CGRect(x: raw.minX, y: raw.minY, width: max(raw.width, 12), height: max(raw.height, 12))
        if crop.intersects(rect) { return rect }
        rect.origin.x = min(max(rect.origin.x, crop.minX + 8), max(crop.maxX - rect.width - 8, crop.minX + 8))
        rect.origin.y = min(max(rect.origin.y, crop.minY + 8), max(crop.maxY - rect.height - 8, crop.minY + 8))
        if crop.intersects(rect) { return rect }
        return CGRect(x: crop.minX + 36, y: max(crop.midY - 10, crop.minY + 8), width: min(240, max(crop.width - 48, 12)), height: 22)
    }

    public static func quadPoints(for bounds: CGRect) -> [NSValue] {
        // PDFKit adds the annotation origin when serializing /QuadPoints.
        // Passing page coordinates here double-translates the highlight.
        [
            pointValue(CGPoint(x: 0, y: bounds.height)),
            pointValue(CGPoint(x: bounds.width, y: bounds.height)),
            pointValue(CGPoint(x: 0, y: 0)),
            pointValue(CGPoint(x: bounds.width, y: 0)),
        ]
    }

    public static func pointValue(_ point: CGPoint) -> NSValue {
        #if os(macOS)
        NSValue(point: NSPoint(x: point.x, y: point.y))
        #else
        NSValue(cgPoint: point)
        #endif
    }

    public static func extractText(from data: Data) -> String {
        guard let doc = PDFDocument(data: data) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount {
            out += doc.page(at: i)?.string ?? ""
            out += "\n"
        }
        return out
    }

    public static func makeSamplePDF(text: String) -> Data {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        let stream = "BT /F1 18 Tf 72 720 Td (\(escaped)) Tj ET\n"
        let objects: [String] = [
            "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n",
            "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n",
            "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj\n",
            "4 0 obj << /Length \(stream.utf8.count) >> stream\n\(stream)endstream\nendobj\n",
            "5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n",
        ]
        var body = "%PDF-1.4\n"
        var offsets: [Int] = [0]
        for obj in objects {
            offsets.append(body.utf8.count)
            body += obj
        }
        let xrefStart = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n"
        body += "0000000000 65535 f \n"
        for off in offsets.dropFirst() {
            body += String(format: "%010d 00000 n \n", off)
        }
        body += "trailer << /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n"
        return Data(body.utf8)
    }

    public static func containsHighlight(orCommentIn data: Data, comment: String) -> Bool {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return false }
        for ann in page.annotations {
            if ann.type == "Highlight" || ann.type == "highlight" { return true }
            if (ann.contents ?? "").contains(comment) { return true }
        }
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        return raw.contains(comment)
    }
}
