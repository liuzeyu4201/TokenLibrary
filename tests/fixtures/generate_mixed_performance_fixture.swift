// Standalone SDK fixture/measurement harness. No App, network or credentials.
// Usage: generator NEW_TEMP_DIRECTORY EXISTING_SYNTHETIC_PDF_FIXTURE_DIRECTORY
import Foundation
import CryptoKit
import GRDB
import LibraryCore

@main struct MixedPerformanceFixture {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Fixture generation failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("/") else {
            throw NSError(domain: "MixedPerformanceFixture", code: 1)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let resolved = output.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(output.lastPathComponent).path
        guard resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/tmp/"),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "MixedPerformanceFixture.RefusingExistingOrNonTemporaryDirectory", code: 2)
        }
        let shortPDF = try Data(contentsOf: fixtures.appendingPathComponent("research-three-pages.pdf"))
        let largePDF = try Data(contentsOf: fixtures.appendingPathComponent("large-near-50mb.pdf"))
        let image = try Data(contentsOf: fixtures.appendingPathComponent("fixture-diagram.png"))
        guard shortPDF.starts(with: Data("%PDF-".utf8)), largePDF.starts(with: Data("%PDF-".utf8)),
              largePDF.count > 49_000_000, largePDF.count <= 50_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func identifier(_ number: Int) -> String { String(format: "f1900000-0000-4000-8000-%012d", number) }
        func elapsed(_ start: Double) -> Double { (CFAbsoluteTimeGetCurrent() - start) * 1000 }
        func statistics(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            return ["samplesMS": values, "count": values.count,
                    "p50MS": sorted[max(0, Int(ceil(Double(sorted.count) * 0.5)) - 1)],
                    "p95MS": sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)], "maxMS": sorted.last!]
        }
        let constructionStart = CFAbsoluteTimeGetCurrent()
        let store = try DocumentStore(directory: output)
        let chart = try store.importAttachment(data: image, fileName: "synthetic-chart.png", mime: "image/png")
        var media: [[String: Any]] = [["blobID": chart.blobId, "path": chart.path, "bytes": image.count, "sha256": sha(image)]]
        var pdfSaveTimes: [Double] = [], markdownSaveTimes: [Double] = []
        for index in 0..<14 {
            var metadata = CatalogMetadata(category: index < 10 ? .unclassified : .topic,
                                           title: index < 10 ? "分组 \(index)" : "专题 \(index - 10)")
            metadata.tags = ["mixed1000"]
            let doc = LibraryDocument(id: identifier(index + 1), kind: .folder, parentId: "root",
                name: metadata.title, markdown: "", pdfPath: nil, revision: 1, localGeneration: 0,
                state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]", metadataJSON: try metadata.json())
            try store.saveDocument(doc, enqueue: false)
        }
        for index in 0..<200 {
            // 199 separate files intentionally share the synthetic three-page content.
            // This exercises actual PDFKit extraction per distinct path/blob, not a mocked extractor.
            let bytes = index == 199 ? largePDF : shortPDF
            let started = CFAbsoluteTimeGetCurrent()
            let asset = try store.importAttachment(data: bytes, fileName: "原件-\(index).pdf", mime: "application/pdf")
            var metadata = CatalogMetadata(category: index < 100 ? .book : .paper,
                                           title: String(format: index < 100 ? "合成书籍 %03d" : "合成论文 %03d", index))
            metadata.authors = ["合成作者 \(index % 20)"]; metadata.year = 2000 + index % 27
            metadata.tags = ["mixed1000", index.isMultiple(of: 2) ? "中文研究" : "Swift"]
            metadata.topicIDs = [identifier(11 + index % 4)]
            metadata.originalFileHash = sha(bytes); metadata.originalFilename = "原件-\(index).pdf"
            let doc = LibraryDocument(id: identifier(1_000 + index), kind: .pdf, parentId: identifier(1 + index % 10),
                name: "原件-\(index).pdf", markdown: "", pdfPath: try store.resolveAttachment(path: asset.path).path,
                revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal,
                annotationsJSON: "[]", metadataJSON: try metadata.json(), pdfBlobId: asset.blobId)
            try store.saveDocument(doc, enqueue: false)
            pdfSaveTimes.append(elapsed(started))
            media.append(["blobID": asset.blobId, "path": asset.path, "bytes": bytes.count, "sha256": sha(bytes)])
        }
        for index in 0..<800 {
            var metadata = CatalogMetadata(category: .note, title: String(format: "合成笔记 %04d", index))
            metadata.authors = ["合成作者 \(index % 20)"]; metadata.year = 2000 + index % 27
            metadata.tags = ["mixed1000", index.isMultiple(of: 2) ? "中文研究" : "Swift"]
            metadata.topicIDs = [identifier(11 + index % 4)]
            metadata.archived = index.isMultiple(of: 13)
            var markdown = "# \(metadata.title)\n\nMixedCorpusNeedle 个人图书馆资料 Swift SQLite，第 \(index) 篇。\n\n"
            markdown += String(repeating: "这一段完全合成的研究笔记包含中文、English、数字 2026，测试真实文本长度与排版。\n\n", count: index < 700 ? 6 : 320)
            let hasChart = index.isMultiple(of: 8)
            if hasChart {
                markdown += "![合成示意图](\(chart.path))\n\n```mermaid\ngraph LR\n  阅读 --> 摘录 --> 复习\n```\n\n行内公式 $E=mc^2$。\n\n"
            }
            markdown += String(format: "NoteTailMarker%05d\n", index)
            let assets = hasChart ? String(decoding: try JSONEncoder().encode([chart]), as: UTF8.self) : "[]"
            let doc = LibraryDocument(id: identifier(2_000 + index), kind: .md, parentId: identifier(1 + index % 10),
                name: String(format: "笔记-%04d.md", index), markdown: markdown, pdfPath: nil,
                revision: 1, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal,
                annotationsJSON: "[]", metadataJSON: try metadata.json(), assetsJSON: assets)
            let started = CFAbsoluteTimeGetCurrent()
            try store.saveDocument(doc, enqueue: false)
            markdownSaveTimes.append(elapsed(started))
        }
        let constructionMS = elapsed(constructionStart)
        let documents = try store.listDocuments(includeTrashed: true)
        let coverage = try store.searchCoverage()
        guard documents.count == 1014, coverage.documents == 1000, coverage.searchableText == 1000,
              try store.pending().isEmpty else { throw CocoaError(.coderInvalidValue) }
        let queries: [(String, Int)] = [("Research Anchor Beta", 199), ("MixedCorpusNeedle", 800),
            ("Large PDF Anchor 7", 1), ("NoteTailMarker00799", 1), ("AbsentMixedCorpusNeedle", 0)]
        var measurements: [[String: Any]] = []
        for (query, expected) in queries {
            var pipelineTimes: [Double] = [], detailedTimes: [Double] = []
            for _ in 0..<20 {
                let start = CFAbsoluteTimeGetCurrent()
                let indexed = Set(try store.search(query: query))
                _ = try store.searchCoverage()
                let results = CatalogQuery(text: query).results(in: documents, indexedMatches: indexed)
                pipelineTimes.append(elapsed(start))
                guard results.count == expected else { throw NSError(domain: "UnexpectedCatalogCount.\(query).\(results.count)", code: 3) }
                let detailsStart = CFAbsoluteTimeGetCurrent()
                let hits = try store.searchDetails(query: query, limit: 1000)
                detailedTimes.append(elapsed(detailsStart))
                guard hits.count == expected else { throw NSError(domain: "UnexpectedFTSCount.\(query).\(hits.count)", code: 4) }
            }
            measurements.append(["query": query, "expectedDocuments": expected,
                "catalogPipeline": statistics(pipelineTimes), "detailedFTS": statistics(detailedTimes)])
        }
        var reloadTimes: [Double] = []
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try store.listDocuments(includeTrashed: true)
            _ = try store.legacyLibraryInventory()
            reloadTimes.append(elapsed(start))
        }
        let cachedPages = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_chunks WHERE source LIKE 'pdf:%'") ?? 0 }
        let bindings = try store.db.read { try String.fetchAll($0, sql: "SELECT key FROM sync_state WHERE key IN ('server','libraryId','rootId','sessionToken')") }
        guard cachedPages == 605, bindings.isEmpty else { throw CocoaError(.coderInvalidValue) }
        _ = try store.db.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        let proof: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date()), "directory": output.path,
            "scope": "Synthetic offline SDK fixture and warm-query timings; no native UI, network, credentials or real user data.",
            "documents": 1000, "markdown": 800, "pdf": 200, "folders": 10, "topics": 4,
            "bodyDistribution": "700 short Markdown, 100 long Markdown; 100 include one shared chart/Mermaid/LaTeX. 199 separate PDF blobs reuse the same real three-page synthetic content; one real 49.7MB eight-page PDF.",
            "indexedPDFPages": cachedPages, "pendingOperations": 0, "serverBindings": bindings,
            "constructionIncludingRealIndexMS": constructionMS, "pdfImportAndIndex": statistics(pdfSaveTimes),
            "markdownSaveAndIndex": statistics(markdownSaveTimes), "storeReadAndInventory": statistics(reloadTimes),
            "queries": measurements, "media": media, "databaseSHA256": sha(try Data(contentsOf: output.appendingPathComponent("library.sqlite"))),
            "largePDFDocumentID": identifier(1199), "longMarkdownDocumentID": identifier(2799),
            "nativeAppLaunched": false, "coldIndexInNativeAppMeasured": false]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output.appendingPathComponent("performance-manifest.json"))
        print("Prepared \(output.path): 1,000 real-body documents, 605 PDF text pages, 0 pending operations; SDK measurements only.")
    }
}
