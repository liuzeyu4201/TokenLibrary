import Foundation
import GRDB
import XCTest
@testable import LibraryCore

final class SearchPerformanceTests: XCTestCase {
    func testThousandDocumentsMixedLanguageSearchP95() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(directory: directory)
        for index in 0..<1_000 {
            try store.localSaveOffline(markdown: "个人图书馆研究资料 Swift SQLite 第\(index)篇 内容摘要 alpha beta gamma", id: "note-\(index)", name: "资料\(index).md", parentId: "root")
        }
        var timings: [Double] = []
        for index in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let hits = try store.searchDetails(query: index.isMultiple(of: 2) ? "图书 Swift" : "资料 999", limit: 50)
            timings.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            XCTAssertFalse(hits.isEmpty)
        }
        timings.sort()
        let p95 = timings[94]
        print("PERFORMANCE search_1000_p95_ms=\(String(format: "%.3f", p95)) samples=100 result_limit=50")
        XCTAssertLessThan(p95, 1_000, "Search should remain interactive on 1,000 documents")
    }

    func testReadingPositionUsesCachedPDFPagesAndKeepsIndexStable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ExtractionCounter()
        let store = try DocumentStore(directory: directory, pdfPageTextExtractor: { _ in counter.increment(); return ["First page introduction", "第二页全文 NeedleMarker 数据库"] })
        let data = PDFExport.makeSamplePDF(text: "cache source")
        let asset = try store.importAttachment(data: data, fileName: "paper.pdf", mime: "application/pdf")
        let id = UUID().uuidString.lowercased()
        let doc = LibraryDocument(id: id, kind: .pdf, parentId: "root", name: "论文.pdf", markdown: "", pdfPath: try store.resolveAttachment(path: asset.path).path, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]", pdfBlobId: asset.blobId)
        try store.saveDocument(doc, enqueue: true)
        let originalRows = try store.db.read { try Int64.fetchAll($0, sql: "SELECT id FROM search_chunks WHERE object_id=? ORDER BY id", arguments: [id]) }
        var timings: [Double] = []
        for page in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try store.recordCatalogReadingPosition(id: id, deviceID: "performance-device", pageIndex: page, totalPages: 100)
            timings.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        XCTAssertEqual(counter.value, 1, "PDF is extracted once, not for each reading-position save")
        XCTAssertEqual(try store.db.read { try Int64.fetchAll($0, sql: "SELECT id FROM search_chunks WHERE object_id=? ORDER BY id", arguments: [id]) }, originalRows)
        let hit = try XCTUnwrap(store.searchDetails(query: "NeedleMarker").first)
        XCTAssertEqual(hit.objectId, id); XCTAssertEqual(hit.pageIndex, 1)
        XCTAssertTrue(hit.excerpt.contains("第二页全文"))
        XCTAssertTrue(try store.searchDetails(query: "performance-device").isEmpty, "Private reading-position bookkeeping is not searchable content")
        let reopened = try DocumentStore(directory: directory, pdfPageTextExtractor: { _ in counter.increment(); return [] })
        _ = try reopened.recordCatalogReadingPosition(id: id, deviceID: "performance-device", pageIndex: 99)
        XCTAssertEqual(counter.value, 1, "Page cache survives process/store restart")
        timings.sort()
        print("PERFORMANCE pdf_reading_save_p95_ms=\(String(format: "%.3f", timings[94])) samples=100 extractions=\(counter.value)")
    }
}

private final class ExtractionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
