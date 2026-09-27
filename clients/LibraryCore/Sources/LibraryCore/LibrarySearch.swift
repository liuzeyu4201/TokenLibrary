import Foundation
import GRDB
#if canImport(PDFKit)
import PDFKit
#endif

public struct LibrarySearchHit: Sendable, Equatable, Identifiable {
    public let objectId: String
    public let excerpt: String
    public let pageIndex: Int?
    public var id: String { objectId }
}

extension DocumentStore {
    /// One best matching excerpt per document; PDF page indexes are zero-based.
    public func searchDetails(query: String, limit: Int = 100) throws -> [LibrarySearchHit] {
        let tokens = SearchTokenizer.tokens(in: query)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        let expression = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        return try db.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT search_fts.object_id,search_fts.source,c.text
                FROM search_fts JOIN working_documents d ON d.id=search_fts.object_id
                JOIN search_chunks c ON c.object_id=search_fts.object_id AND c.source=search_fts.source
                WHERE search_fts MATCH ? AND d.state='active' ORDER BY search_fts.rank
                """, arguments: [expression])
            var seen = Set<String>(), hits: [LibrarySearchHit] = []
            while let row = try rows.next() {
                let id: String = row["object_id"], source: String = row["source"], text: String = row["text"]
                guard seen.insert(id).inserted else { continue }
                let page = source.hasPrefix("pdf:") ? Int(source.dropFirst(4)) : nil
                hits.append(LibrarySearchHit(objectId: id, excerpt: Self.searchExcerpt(text, query: query, tokens: tokens), pageIndex: page))
                if hits.count >= min(limit, 1_001) { break }
            }
            return hits
        }
    }

    private static func searchExcerpt(_ text: String, query: String, tokens: [String]) -> String {
        let search = [query] + tokens
        let match = search.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        let center = match?.lowerBound ?? text.startIndex
        let start = text.index(center, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(center, offsetBy: 150, limitedBy: text.endIndex) ?? text.endIndex
        let excerpt = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + excerpt + (end < text.endIndex ? "…" : "")
    }
}

enum PDFSearchText {
    static func pages(from data: Data) -> [String] {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        #else
        return [PDFExport.extractText(from: data)]
        #endif
    }
}
