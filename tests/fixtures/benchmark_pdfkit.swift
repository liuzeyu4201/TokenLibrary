import Foundation
import PDFKit
import AppKit
import CryptoKit
import Darwin

// Standalone SDK acceptance probe. It does not launch or drive any application.
// Run one input per process so max RSS belongs to that single fixture workload.
// Compile with the repository's PDFAnnotations.swift and PDFKitExport.swift.
// This minimal shim replaces the unrelated persistence module's error type.
enum StoreError: Error { case notFound }
enum ProbeError: Error { case invalid(String) }
func require(_ condition: Bool, _ text: String) throws {
    if !condition { throw ProbeError.invalid(text) }
}
func elapsed<T>(_ block: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try block()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
func peakRSS() -> Int64 {
    var usage = rusage()
    _ = getrusage(0, &usage) // Darwin RUSAGE_SELF, ru_maxrss is bytes on macOS.
    return Int64(usage.ru_maxrss)
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func stats(_ values: [Double]) -> [String: Any] {
    let sorted = values.sorted()
    return ["samples_ms": values, "median_ms": sorted[sorted.count / 2],
            "p95_ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]]
}

func runProbe() throws {
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: benchmark_pdfkit <input.pdf> <output-directory>\n", stderr)
    exit(2)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let name = input.deletingPathExtension().lastPathComponent
let scanned = name == "scanned-no-text"
let large = name == "large-near-50mb"
let expectedPages = scanned ? 1 : (large ? 8 : 3)
let english = large ? "reproducible sensor noise observation" : "Research Anchor Beta:"
let chinese = large ? "大文件检索锚点" : "研究锚点乙"
let beforeRSS = peakRSS()
let (source, sourceReadMS) = try elapsed { try Data(contentsOf: input, options: .mappedIfSafe) }
let (originalHash, hashMS) = elapsed { digest(source) }
var openTimes: [Double] = [], textTimes: [Double] = [], searchTimes: [Double] = []
var extractedCount = 0, englishCount = 0, chineseCount = 0
for _ in 0..<5 {
    try autoreleasepool {
        let (possiblePDF, openMS) = elapsed { PDFDocument(url: input) }
        guard let document = possiblePDF else { throw ProbeError.invalid("PDFKit cannot open input") }
        try require(document.pageCount == expectedPages, "Unexpected page count")
        let (content, textMS) = elapsed { document.string ?? "" }
        let (matches, searchMS) = elapsed {
            (document.findString(english, withOptions: .caseInsensitive),
             document.findString(chinese, withOptions: []))
        }
        extractedCount = content.count
        englishCount = matches.0.count
        chineseCount = matches.1.count
        if scanned {
            try require(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Raster PDF has text layer")
            try require(document.findString("RasterOnlyAnchor", withOptions: []).isEmpty, "Raster text was falsely searchable")
        } else {
            try require(englishCount == (large ? 8 : 1), "English text selection/search failed")
            try require(chineseCount == (large ? 8 : 1), "Chinese text selection/search failed")
        }
        openTimes.append(openMS); textTimes.append(textMS); searchTimes.append(searchMS)
    }
}
guard let document = PDFDocument(url: input), document.page(at: 0) != nil else {
    throw ProbeError.invalid("Cannot reopen input")
}
var renderedBytes = 0
let (_, renderMS) = try elapsed {
    for index in 0..<document.pageCount {
        try autoreleasepool {
            guard let page = document.page(at: index),
                  let data = page.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox).tiffRepresentation else {
                throw ProbeError.invalid("Page render failed")
            }
            renderedBytes += data.count
        }
    }
}
let (_, annotationMS) = try elapsed {
    var annotations: [PDFTextAnnotation] = []
    if !scanned {
        guard let selection = document.findString(english, withOptions: .caseInsensitive).first,
              let page = selection.pages.first else { throw ProbeError.invalid("No selectable highlight target") }
        let bounds = selection.bounds(for: page)
        try require(bounds.width > 0 && bounds.height > 0, "Selection geometry empty")
        annotations.append(PDFTextAnnotation(id: "fixture-highlight", type: "highlight",
            pageIndex: document.index(for: page), x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: bounds.height, color: "#FFE08A", text: "Synthetic acceptance highlight"))
    }
    annotations.append(PDFTextAnnotation(id: "fixture-comment", type: "comment", pageIndex: 0,
        x: 60, y: 68, width: 490, height: 60, color: "#EDF7EF",
        text: "文字备注、读书研究 📚 ✅\nEnglish research comment - original bytes preserved."))
    PDFExport.apply(to: document, annotations: annotations)
}
let exportedURL = outputDirectory.appendingPathComponent(name + "-annotated.pdf")
let (exported, serializeMS) = try elapsed {
    guard let data = document.dataRepresentation() else { throw ProbeError.invalid("Annotated PDF serialization failed") }
    return data
}
let (_, writeMS) = try elapsed { try exported.write(to: exportedURL, options: .atomic) }
let (_, verificationMS) = try elapsed {
    guard let reopened = PDFDocument(url: exportedURL) else { throw ProbeError.invalid("Export cannot reopen") }
    try require(reopened.pageCount == expectedPages, "Export changed page count")
    var tags = Set<String>()
    for index in 0..<reopened.pageCount {
        for annotation in reopened.page(at: index)?.annotations ?? [] {
            if let tag = annotation.value(forAnnotationKey: .name) as? String { tags.insert(tag) }
        }
    }
    try require(tags.contains("tokenlibrary:fixture-comment"), "Export lost comment")
    if !scanned {
        try require(tags.contains("tokenlibrary:fixture-highlight"), "Export lost highlight")
        try require(reopened.findString(english, withOptions: .caseInsensitive).count == (large ? 8 : 1), "Export lost searchable English")
        try require(reopened.findString(chinese, withOptions: []).count == (large ? 8 : 1), "Export lost searchable Chinese")
    }
    let unchanged = try Data(contentsOf: input, options: .mappedIfSafe)
    try require(digest(unchanged) == originalHash, "Original PDF bytes were modified")
}
let result: [String: Any] = [
    "input": input.path, "source_bytes": source.count, "source_sha256": originalHash,
    "page_count": expectedPages, "text_characters": extractedCount, "english_matches": englishCount,
    "chinese_matches": chineseCount, "source_read_ms": sourceReadMS, "sha256_ms": hashMS,
    "open": stats(openTimes), "full_text": stats(textTimes), "two_language_search": stats(searchTimes),
    "render_all_pages_ms": renderMS, "rendered_tiff_bytes": renderedBytes,
    "annotation_ms": annotationMS, "export_serialize_ms": serializeMS, "export_write_ms": writeMS,
    "export_verify_ms": verificationMS, "export_bytes": exported.count,
    "export_path": exportedURL.path, "export_sha256": digest(exported),
    "max_rss_bytes_before": beforeRSS, "max_rss_bytes_process": peakRSS(),
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "measurement_note": "macOS PDFKit SDK only; 5 sequential warm-cache samples; process peak RSS includes frameworks, rasterization and output data; not app UI, phone, storage or network throughput.",
    "verified_original_unchanged": true, "verified_export_annotations": true
]
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent(name + "-metrics.json"), options: .atomic)
print(String(decoding: json, as: UTF8.self))

}
@main struct PDFKitBenchmark {
    static func main() {
        do { try runProbe() } catch { fputs("PDFKit probe failed: " + String(describing: error) + "\n", stderr); exit(1) }
    }
}
