// Compile with the current PDFAnnotations.swift, PDFKitExport.swift and
// PDFExportSerialization.swift against either the macOS or simulator SDK.
// This SDK harness does not launch the app or access its files/credentials.
import Foundation
import PDFKit

enum StoreError: Error { case notFound }

@main struct ExportSerializationProbe {
    static func main() throws {
        if CommandLine.arguments[1] == "--large" {
            let input = URL(fileURLWithPath: CommandLine.arguments[2])
            let output = URL(fileURLWithPath: CommandLine.arguments[3])
            let source = try Data(contentsOf: input)
            let annotation = PDFTextAnnotation(id: "large-export", type: "comment", pageIndex: 7,
                x: 40, y: 100, width: 300, height: 40, color: "#FFE08A", text: "Large export 研究 🧪")
            let start = Date()
            let result = try PDFExport.exportAnnotated(pdfData: source, annotations: [annotation])
            let elapsed = Date().timeIntervalSince(start)
            try result.write(to: output)
            let document = PDFDocument(data: result)!
            guard document.pageCount == 8,
                  document.page(at: 7)?.annotations.first?.value(forAnnotationKey: .name) as? String == "tokenlibrary:large-export",
                  source == (try Data(contentsOf: input)) else { fatalError("Large-file export failed") }
            print("large bytes=\(source.count) exported=\(result.count) pages=8 seconds=\(elapsed)")
            return
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let baseline = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try Data(contentsOf: input)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: baseline)) as! [String: Any]
        let payload = json["iOS"] as! [String: Any]
        let annotations = try JSONDecoder().decode([PDFTextAnnotation].self,
            from: JSONSerialization.data(withJSONObject: payload["annotations"]!))
        let blob = payload["pdf_blob_id"] as! String
        let once = try PDFExport.exportAnnotated(pdfData: source, annotations: annotations, currentPDFBlobId: blob)
        let twice = try PDFExport.exportAnnotated(pdfData: once, annotations: annotations, currentPDFBlobId: blob)
        let imported = try PDFExport.exportAnnotated(pdfData: once, annotations: [], currentPDFBlobId: "new-import")
        var review = annotations
        review[0].placementState = "needs_review"
        let removed = try PDFExport.exportAnnotated(pdfData: once, annotations: review, currentPDFBlobId: blob)
        for (name, data, expected) in [("once", once, 2), ("twice", twice, 2), ("reimport", imported, 2), ("review", removed, 1)] {
            let output = root.appendingPathComponent(name + ".pdf")
            try data.write(to: output)
            let doc = PDFDocument(data: data)!
            let all = (0..<doc.pageCount).flatMap { doc.page(at: $0)!.annotations }
            let identities = all.compactMap { $0.value(forAnnotationKey: .name) as? String }
            guard all.count == expected, identities.count == expected else {
                fatalError("\(name): annotation identity/count mismatch \(all.count) \(identities)")
            }
            guard doc.string?.contains("Research Anchor Beta") == true else { fatalError("Source text missing") }
            print(name, data.count, identities)
        }
        guard source == (try Data(contentsOf: input)) else { fatalError("Source changed") }
    }
}
