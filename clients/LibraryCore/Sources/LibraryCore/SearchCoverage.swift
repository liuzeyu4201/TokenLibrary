import Foundation
import GRDB

public struct LibrarySearchCoverage:Equatable,Sendable {
    public var documents:Int
    public var searchableText:Int
    public var waitingDownload:Int
    public var waitingIndex:Int
    public var pdfWithoutText:Int
    public var summary:String {
        var parts=["本机正文可检索 \(searchableText)/\(documents) 项"]
        if waitingDownload>0 { parts.append("\(waitingDownload) 份 PDF 尚未下载") }
        if waitingIndex>0 { parts.append("\(waitingIndex) 项待索引或文件待检查") }
        if pdfWithoutText>0 { parts.append("\(pdfWithoutText) 份 PDF 无文字层") }
        return parts.joined(separator:"；")+"。标题和资料信息也参与搜索。"
    }
}

extension DocumentStore {
    public func searchCoverage() throws -> LibrarySearchCoverage {
        try db.read { db in
            let rows=try Row.fetchAll(db,sql:"""
                SELECT d.id,d.kind,d.pdf_path,s.signature,
                  COUNT(c.id) AS page_count,
                  COALESCE(MAX(LENGTH(TRIM(c.text))),0) AS text_length
                FROM working_documents d
                LEFT JOIN search_index_state s ON s.object_id=d.id
                LEFT JOIN search_chunks c ON c.object_id=d.id AND c.source LIKE 'pdf:%'
                WHERE d.state='active' AND d.kind != 'folder'
                GROUP BY d.id
                """)
            var result=LibrarySearchCoverage(documents:rows.count,searchableText:0,waitingDownload:0,waitingIndex:0,pdfWithoutText:0)
            for row in rows {
                let indexed=(row["signature"] as String?) != nil
                if (row["kind"] as String) != DocKind.pdf.rawValue {
                    if indexed { result.searchableText+=1 } else { result.waitingIndex+=1 }
                    continue
                }
                guard let path=row["pdf_path"] as String?,FileManager.default.isReadableFile(atPath:path) else {
                    result.waitingDownload+=1;continue
                }
                guard indexed,(row["page_count"] as Int)>0 else { result.waitingIndex+=1;continue }
                if (row["text_length"] as Int)>0 { result.searchableText+=1 }
                else { result.pdfWithoutText+=1 }
            }
            return result
        }
    }
}
