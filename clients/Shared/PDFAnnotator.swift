import Foundation
import PDFKit
import LibraryCore

enum PDFPageInputError: LocalizedError, Equatable {
    case noPages
    case outOfRange(Int)
    var errorDescription:String? {
        switch self {
        case .noPages: return "PDF 页面尚未准备好，请稍后重试。"
        case .outOfRange(let total): return "请输入 1 至 \(total) 之间的整数页码；当前阅读位置未改变。"
        }
    }
}

enum PDFPageInput {
    static func pageIndex(_ input:String,totalPages:Int)->Result<Int,PDFPageInputError> {
        guard totalPages>0 else { return .failure(.noPages) }
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.utf8.allSatisfy({ (48...57).contains($0) }),
              let page=Int(text),page>=1,page<=totalPages else { return .failure(.outOfRange(totalPages)) }
        return .success(page-1)
    }
}

struct PDFReadingSource: Equatable {
    let identity: String
    let fileHash: String?
    let pageCount: Int
    let instanceID = UUID()
    static func identity(for document: LibraryDocument) -> String {
        document.id + "|" + (document.pdfBlobId ?? "") + "|" + (document.pdfPath ?? "")
    }
}

struct PDFReadingNavigation: Equatable {
    let id = UUID()
    let sourceIdentity: String
    let fileHash: String
    let pageIndex: Int
    func matches(_ source: PDFReadingSource) -> Bool {
        sourceIdentity == source.identity && fileHash == source.fileHash
    }
}

struct PDFReadingEvent {
    let source: PDFReadingSource
    let pageIndex: Int
}

/// PDFKit can reset its visible page while UIKit installs its first nonzero
/// viewport. A navigation acknowledgement needs an attached, stable layout and
/// two observations of the requested page, rather than merely one main-queue hop.
struct PDFInitialLayoutNavigation {
    let targetPage:Int
    private(set) var completed=false
    private var confirmations=0
    private var viewport:CGSize?
    static func isReady(size:CGSize,attached:Bool)->Bool {
        attached && size.width.isFinite && size.height.isFinite && size.width>0 && size.height>0
    }
    mutating func observe(page:Int?,size:CGSize,attached:Bool)->Bool {
        guard !completed else { return false }
        guard Self.isReady(size:size,attached:attached) else { confirmations=0;viewport=nil;return false }
        if viewport != size { confirmations=0;viewport=size }
        guard page == targetPage else { confirmations=0;return false }
        confirmations+=1
        completed=confirmations>=2
        return completed
    }
}

/// Reading policy independent of PDFView notifications and SwiftUI lifecycle.
/// Only verified matching versions restore positions. Loading a default page
/// does not count as an intentional navigation or update its reading timestamp.
struct PDFReadingState {
    private(set) var source: PDFReadingSource?
    private(set) var pageIndex = 0
    private(set) var suggestion: CatalogReadingPosition?
    private var pendingInitialNavigation = false
    private var dismissed = Set<PositionKey>()
    private struct PositionKey: Hashable {
        let deviceID: String
        let fileHash: String?
        let pageIndex: Int
        let updatedAt: Date
        init(_ position: CatalogReadingPosition) {
            deviceID=position.deviceID;fileHash=position.fileHash;pageIndex=position.pageIndex;updatedAt=position.updatedAt
        }
    }

    mutating func load(source: PDFReadingSource, positions: [CatalogReadingPosition], deviceID: String,
                       navigation: PDFReadingNavigation?) -> Int {
        if self.source?.identity != source.identity || self.source?.fileHash != source.fileHash { dismissed=[] }
        self.source=source
        let local=matching(positions).first { $0.deviceID == deviceID }
        pendingInitialNavigation=navigation?.matches(source) == true
        let requested=pendingInitialNavigation ? navigation!.pageIndex : (local?.pageIndex ?? 0)
        pageIndex=min(max(0,requested),max(0,source.pageCount-1))
        refresh(positions:positions,deviceID:deviceID)
        return pageIndex
    }

    mutating func installed(source: PDFReadingSource) -> PDFReadingEvent? {
        guard self.source == source,pendingInitialNavigation else { return nil }
        pendingInitialNavigation=false
        return visit(pageIndex,source:source)
    }

    mutating func visit(_ index: Int, source: PDFReadingSource) -> PDFReadingEvent? {
        guard self.source == source,index >= 0,index < source.pageCount else { return nil }
        pageIndex=index
        if suggestion?.pageIndex == index { suggestion=nil }
        guard source.fileHash != nil else { return nil }
        return PDFReadingEvent(source:source,pageIndex:index)
    }

    mutating func refresh(positions: [CatalogReadingPosition], deviceID: String) {
        let valid=matching(positions)
        let local=valid.first { $0.deviceID == deviceID }
        suggestion=valid.filter {
            $0.deviceID != deviceID && $0.pageIndex != pageIndex &&
            (local == nil || $0.updatedAt > local!.updatedAt) && !dismissed.contains(PositionKey($0))
        }.max { left,right in
            left.updatedAt == right.updatedAt ? left.deviceID < right.deviceID : left.updatedAt < right.updatedAt
        }
    }

    mutating func dismiss(_ position: CatalogReadingPosition) {
        dismissed.insert(PositionKey(position))
        if suggestion == position { suggestion=nil }
    }

    private func matching(_ positions: [CatalogReadingPosition]) -> [CatalogReadingPosition] {
        guard let source,let hash=source.fileHash else { return [] }
        return positions.filter { $0.fileHash == hash && $0.pageIndex >= 0 && $0.pageIndex < source.pageCount }
    }
}

/// Capture before assigning the document to PDFView. PDFKit can add Live Text
/// on demand; those transient OCR results are outside the library's text index.
struct PDFOriginalTextIndex {
    let pages: [String]
    init(document: PDFDocument) {
        pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }
    var hasText: Bool { pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    func hasText(on index: Int) -> Bool { pages.indices.contains(index) && !pages[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func contains(_ selection: PDFSelection, in document: PDFDocument) -> Bool {
        guard !selection.pages.isEmpty else { return false }
        return selection.pages.allSatisfy { page in
            let index = document.index(for: page)
            guard hasText(on: index) else { return false }
            let original = pages[index] as NSString, current = (page.string ?? "") as NSString
            let count = selection.numberOfTextRanges(on: page)
            guard count > 0 else { return false }
            return (0..<count).allSatisfy { item in
                let range = selection.range(at: item, on: page)
                guard range.location != NSNotFound, range.length > 0,
                      range.location <= original.length, range.length <= original.length - range.location,
                      range.location <= current.length, range.length <= current.length - range.location else { return false }
                return original.substring(with: range) == current.substring(with: range)
            }
        }
    }
    func selections(in document: PDFDocument, query: String) -> [PDFSelection] {
        guard !query.isEmpty else { return [] }
        var result: [PDFSelection] = []
        for (index, text) in pages.enumerated() {
            guard let page = document.page(at: index) else { continue }
            let original = text as NSString
            var remaining = NSRange(location: 0, length: original.length)
            while remaining.length > 0 {
                let range = original.range(of: query, options: [.caseInsensitive], range: remaining)
                guard range.location != NSNotFound, range.length > 0 else { break }
                if let selection = page.selection(for: range), contains(selection, in: document) { result.append(selection) }
                let end = NSMaxRange(range)
                remaining = NSRange(location: end, length: original.length - end)
            }
        }
        return result
    }
}

/// PDFKit highlight + text comment only. No ink / pencil / handwriting tools.
public enum PDFAnnotator {
    public static func addHighlight(document: PDFDocument, pageIndex: Int, bounds: CGRect) {
        PDFExport.apply(to: document, annotations: [
            PDFTextAnnotation(type: "highlight", pageIndex: pageIndex, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, color: "#FFE08A", text: ""),
        ])
    }

    public static func addComment(document: PDFDocument, pageIndex: Int, bounds: CGRect, text: String) {
        PDFExport.apply(to: document, annotations: [
            PDFTextAnnotation(type: "comment", pageIndex: pageIndex, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, color: "#007aff", text: text),
        ])
    }

    /// Text highlighting always requires an actual text selection.
    @MainActor
    public static func highlight(in view: PDFView) -> [PDFTextAnnotation] {
        guard view.document != nil else { return [] }
        let records: [PDFTextAnnotation]
        if let sel = view.currentSelection, !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records = PDFExport.records(from: sel, type: "highlight", color: "#FFE08A", text: "")
        } else {
            return []
        }
        guard !records.isEmpty else { return [] }
        return records
    }

    /// Place a text comment on the current selection, or the middle of the current page.
    @MainActor
    public static func comment(in view: PDFView, text: String) -> [PDFTextAnnotation] {
        guard let doc = view.document else { return [] }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = body.isEmpty ? "备注" : body
        let records: [PDFTextAnnotation]
        if let sel = view.currentSelection, sel.pages.isEmpty == false {
            let fromSel = PDFExport.records(from: sel, type: "comment", color: "#007AFF", text: note)
            records = fromSel.isEmpty ? fallbackComment(in: view, doc: doc, text: note) : fromSel
        } else {
            records = fallbackComment(in: view, doc: doc, text: note)
        }
        guard !records.isEmpty else { return [] }
        return records
    }

    public static func export(document: PDFDocument) -> Data? {
        document.dataRepresentation()
    }

    public static var supportsHandwriting: Bool { false }

    @MainActor
    private static func fallbackComment(in view: PDFView, doc: PDFDocument, text: String) -> [PDFTextAnnotation] {
        guard let page = view.currentPage ?? doc.page(at: 0) else { return [] }
        var record = PDFExport.fallbackComment(on: page, in: doc, text: text)
        let viewBounds = view.bounds
        if viewBounds.width > 8, viewBounds.height > 8 {
            let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
            let pagePoint = view.convert(center, to: page)
            let crop = page.bounds(for: .cropBox)
            if crop.contains(pagePoint) {
                record.x = min(max(pagePoint.x - 40, crop.minX + 8), crop.maxX - 80)
                record.y = min(max(pagePoint.y - 12, crop.minY + 8), crop.maxY - 36)
            }
        }
        return [record]
    }

    @MainActor
    private static func refresh(_ view: PDFView) {
        view.layoutDocumentView()
        #if os(iOS)
        view.setNeedsDisplay()
        #endif
        if let page = view.currentPage {
            view.go(to: page)
        }
    }
}
