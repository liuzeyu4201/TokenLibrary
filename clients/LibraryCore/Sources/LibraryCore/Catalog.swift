import Foundation
import CryptoKit
import GRDB
import PDFKit

public enum CatalogCategory: String, Codable, CaseIterable, Sendable {
    case book, paper, note, topic, unclassified
    public var title: String {
        switch self {
        case .book: return "书籍"
        case .paper: return "论文"
        case .note: return "笔记"
        case .topic: return "专题"
        case .unclassified: return "待分类"
        }
    }
    public var symbol: String {
        switch self {
        case .book: return "books.vertical"
        case .paper: return "doc.text.magnifyingglass"
        case .note: return "note.text"
        case .topic: return "square.stack.3d.up"
        case .unclassified: return "doc"
        }
    }
}

public enum CatalogReadingStatus: String, Codable, CaseIterable, Sendable {
    case toRead, reading, finished, reference
    public var title: String {
        switch self {
        case .toRead: return "待读"
        case .reading: return "在读"
        case .finished: return "已读"
        case .reference: return "仅作参考"
        }
    }
}

public struct CatalogReadingPosition: Codable, Equatable, Sendable, Identifiable {
    public var deviceID: String
    public var pageIndex: Int
    public var totalPages: Int?
    public var fileHash: String?
    public var updatedAt: Date
    public var id: String { deviceID }
    public init(deviceID: String, pageIndex: Int, totalPages: Int? = nil, fileHash: String? = nil, updatedAt: Date = Date()) {
        self.deviceID = deviceID
        self.pageIndex = pageIndex
        self.totalPages = totalPages
        self.fileHash = fileHash
        self.updatedAt = updatedAt
    }
    public var summary: String {
        if let totalPages, totalPages > 0 { return "第 \(pageIndex + 1) / \(totalPages) 页" }
        return "第 \(pageIndex + 1) 页"
    }
}

public struct CatalogExcerpt: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceID: String
    public var sourceTitle: String
    public var quote: String
    public var comment: String
    public var pageIndex: Int?
    public var fileHash: String?
    public var annotationID: String?
    public var createdAt: Date
    public init(id: String = UUID().uuidString.lowercased(), sourceID: String, sourceTitle: String, quote: String, comment: String = "", pageIndex: Int? = nil, fileHash: String? = nil, annotationID: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.quote = quote
        self.comment = comment
        self.pageIndex = pageIndex
        self.fileHash = fileHash
        self.annotationID = annotationID
        self.createdAt = createdAt
    }
    public var sourceLabel: String {
        sourceTitle + (pageIndex.map { " · 第 \($0 + 1) 页" } ?? "")
    }
}

/// Optional metadata augments existing documents; PDF/Markdown and object identity remain unchanged.
/// Missing fields decode independently, allowing old clients and partially populated records.
public struct CatalogMetadata: Codable, Equatable, Sendable {
    public var version = 1
    public var category: CatalogCategory = .unclassified
    public var title: String = ""
    public var authors: [String] = []
    public var year: Int?
    public var isbn: String = ""
    public var doi: String = ""
    public var publication: String = ""
    public var sourceURL: String = ""
    public var abstract: String = ""
    public var topicIDs: [String] = []
    public var tags: [String] = []
    public var inbox = false
    public var archived = false
    public var archivedAt: Date?
    public var readingStatus: CatalogReadingStatus = .toRead
    public var readingPositions: [CatalogReadingPosition] = []
    public var sourceIDs: [String] = []
    public var relatedIDs: [String] = []
    public var excerpts: [CatalogExcerpt] = []
    public var originalFilename: String = ""
    public var originalFileHash: String?
    public var importedAt: Date?

    public init(category: CatalogCategory = .unclassified, title: String = "", inbox: Bool = false) {
        self.category = category
        self.title = title
        self.inbox = inbox
    }

    private enum CodingKeys: String, CodingKey {
        case version, category, title, authors, year, isbn, doi, publication, sourceURL, abstract
        case topicIDs, tags, inbox, archived, archivedAt, readingStatus, readingPositions
        case sourceIDs, relatedIDs, excerpts, originalFilename, originalFileHash, importedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        category = (try? c.decode(CatalogCategory.self, forKey: .category)) ?? .unclassified
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        authors = (try? c.decode([String].self, forKey: .authors)) ?? []
        year = try? c.decode(Int.self, forKey: .year)
        isbn = (try? c.decode(String.self, forKey: .isbn)) ?? ""
        doi = (try? c.decode(String.self, forKey: .doi)) ?? ""
        publication = (try? c.decode(String.self, forKey: .publication)) ?? ""
        sourceURL = (try? c.decode(String.self, forKey: .sourceURL)) ?? ""
        abstract = (try? c.decode(String.self, forKey: .abstract)) ?? ""
        topicIDs = (try? c.decode([String].self, forKey: .topicIDs)) ?? []
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        inbox = (try? c.decode(Bool.self, forKey: .inbox)) ?? false
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        archivedAt = try? c.decode(Date.self, forKey: .archivedAt)
        readingStatus = (try? c.decode(CatalogReadingStatus.self, forKey: .readingStatus)) ?? .toRead
        readingPositions = (try? c.decode([CatalogReadingPosition].self, forKey: .readingPositions)) ?? []
        sourceIDs = (try? c.decode([String].self, forKey: .sourceIDs)) ?? []
        relatedIDs = (try? c.decode([String].self, forKey: .relatedIDs)) ?? []
        excerpts = (try? c.decode([CatalogExcerpt].self, forKey: .excerpts)) ?? []
        originalFilename = (try? c.decode(String.self, forKey: .originalFilename)) ?? ""
        originalFileHash = try? c.decode(String.self, forKey: .originalFileHash)
        importedAt = try? c.decode(Date.self, forKey: .importedAt)
    }

    public static func decode(_ json: String, kind: DocKind) -> CatalogMetadata {
        var value = (try? JSONDecoder().decode(Self.self, from: Data(json.utf8))) ?? Self()
        if kind == .md && value.category == .unclassified { value.category = .note }
        return value
    }

    /// Preserve extension keys owned by newer clients. Optional fields removed by this client
    /// must be removed from the original dictionary, rather than inadvertently resurrected.
    public func json(preserving original: String = "{}") throws -> String {
        var fields = (try? JSONSerialization.jsonObject(with: Data(original.utf8))) as? [String: Any] ?? [:]
        let data = try JSONEncoder().encode(self)
        var known = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // Fields introduced by a newer client also survive inside stable-ID records.
        for (key, identity, optionals) in [("readingPositions", "deviceID", ["totalPages", "fileHash"]),
                                          ("excerpts", "id", ["pageIndex", "fileHash", "annotationID"])] {
            let originals = fields[key] as? [[String: Any]] ?? []
            if let records = known[key] as? [[String: Any]] {
                known[key] = records.map { record -> [String: Any] in
                    var merged = originals.first { ($0[identity] as? String) == (record[identity] as? String) } ?? [:]
                    for optional in optionals { merged.removeValue(forKey: optional) }
                    merged.merge(record) { _, new in new }
                    return merged
                }
            }
        }
        let optional = ["year", "archivedAt", "originalFileHash", "importedAt"]
        for key in optional { fields.removeValue(forKey: key) }
        fields.merge(known) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Patch only fields this edit changed. A field whose shape is unknown to this client
    /// remains byte-semantically intact when an unrelated field is edited.
    fileprivate func jsonChanges(from baseline: CatalogMetadata, preserving original: String) throws -> String {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let before = try decoder.decode([String: JSONValue].self, from: encoder.encode(baseline))
        let after = try decoder.decode([String: JSONValue].self, from: encoder.encode(self))
        let extended = try decoder.decode([String: JSONValue].self, from: Data(json(preserving: original).utf8))
        var fields = try decoder.decode([String: JSONValue].self, from: Data(original.utf8))
        for key in Set(before.keys).union(after.keys) where before[key] != after[key] {
            fields[key] = extended[key]
        }
        return try JSONValue.object(fields).jsonString()
    }

    public var searchText: String {
        ([title, publication, isbn, doi, sourceURL, abstract, year.map(String.init) ?? ""]
            + authors + tags + excerpts.flatMap { [$0.quote, $0.comment, $0.sourceTitle] }).joined(separator: "\n")
    }
}

public extension LibraryDocument {
    var catalog: CatalogMetadata { CatalogMetadata.decode(metadataJSON, kind: kind) }
    var catalogTitle: String {
        let title = catalog.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? FileNames.editingBase(name, kind: kind) : title
    }
    var isCatalogTopic: Bool { kind == .folder && catalog.category == .topic }
}

public enum CatalogSection: String, CaseIterable, Sendable {
    case all, inbox, books, papers, notes, reading, archived, topics
    public var title: String {
        switch self {
        case .all: return "全部资料"
        case .inbox: return "收件箱"
        case .books: return "书籍"
        case .papers: return "论文"
        case .notes: return "笔记"
        case .reading: return "继续阅读"
        case .archived: return "归档"
        case .topics: return "专题"
        }
    }
    public var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .inbox: return "tray"
        case .books: return "books.vertical"
        case .papers: return "doc.text.magnifyingglass"
        case .notes: return "note.text"
        case .reading: return "book"
        case .archived: return "archivebox"
        case .topics: return "square.stack.3d.up"
        }
    }
}

public enum CatalogArchiveFilter: String, CaseIterable, Sendable {
    case all, active, archived
    public var title: String {
        switch self { case .all: return "包含归档"; case .active: return "仅未归档"; case .archived: return "仅归档" }
    }
}

public enum CatalogAvailabilityFilter: String, CaseIterable, Sendable {
    case all, onDevice, waitingDownload
    public var title: String {
        switch self { case .all: return "全部资料"; case .onDevice: return "本机已有正文或原件"; case .waitingDownload: return "PDF 原件尚未下载" }
    }
}

public enum CatalogSort: String, CaseIterable, Sendable {
    case title, author, yearNewest, yearOldest, recentReading
    public var title: String {
        switch self {
        case .title: return "标题"
        case .author: return "第一作者"
        case .yearNewest: return "年份从新到旧"
        case .yearOldest: return "年份从旧到新"
        case .recentReading: return "最近阅读"
        }
    }
}

public struct CatalogQuery: Equatable, Sendable {
    public var section: CatalogSection
    public var text: String
    public var topicID: String?
    public var tag: String?
    public var year: Int?
    public var readingStatus: CatalogReadingStatus?
    public var author: String?
    public var yearFrom: Int?
    public var yearTo: Int?
    public var archive: CatalogArchiveFilter
    public var availability: CatalogAvailabilityFilter
    public init(section: CatalogSection = .all, text: String = "", topicID: String? = nil, tag: String? = nil, year: Int? = nil, readingStatus: CatalogReadingStatus? = nil,
                author: String? = nil, yearFrom: Int? = nil, yearTo: Int? = nil, archive: CatalogArchiveFilter = .all,
                availability: CatalogAvailabilityFilter = .all) {
        self.section = section; self.text = text; self.topicID = topicID; self.tag = tag
        self.year = year; self.readingStatus = readingStatus; self.author = author
        self.yearFrom = yearFrom; self.yearTo = yearTo; self.archive = archive; self.availability = availability
    }

    public func matches(_ doc: LibraryDocument, indexedMatches: Set<String> = []) -> Bool {
        matches(doc, metadata: doc.catalog, indexedMatches: indexedMatches)
    }

    /// Decode metadata once per document, then reuse it for filtering and comparison. In
    /// particular, sorting a thousand records must not JSON-decode on every comparator call.
    public func results(in documents: [LibraryDocument], indexedMatches: Set<String> = [], sort: CatalogSort = .title) -> [LibraryDocument] {
        let candidates = documents.compactMap { document -> (document: LibraryDocument, metadata: CatalogMetadata, title: String)? in
            let metadata = document.catalog
            guard matches(document, metadata: metadata, indexedMatches: indexedMatches) else { return nil }
            let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (document, metadata, title.isEmpty ? FileNames.editingBase(document.name, kind: document.kind) : title)
        }
        return candidates.sorted { left, right in
            switch sort {
            case .author:
                let a = left.metadata.authors.first ?? "", b = right.metadata.authors.first ?? ""
                if a.isEmpty != b.isEmpty { return !a.isEmpty }
                let comparison = a.localizedStandardCompare(b)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .yearNewest, .yearOldest:
                let a = left.metadata.year, b = right.metadata.year
                if (a == nil) != (b == nil) { return a != nil }
                if let a, let b, a != b { return sort == .yearNewest ? a > b : a < b }
            case .recentReading:
                let a = left.metadata.readingPositions.map(\.updatedAt).max() ?? .distantPast
                let b = right.metadata.readingPositions.map(\.updatedAt).max() ?? .distantPast
                if a != b { return a > b }
            case .title: break
            }
            let comparison = left.title.localizedStandardCompare(right.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return left.document.id < right.document.id
        }.map(\.document)
    }

    private func matches(_ doc: LibraryDocument, metadata m: CatalogMetadata, indexedMatches: Set<String>) -> Bool {
        guard doc.state == "active" else { return false }
        let isTopic = doc.kind == .folder && m.category == .topic
        if section == .topics {
            guard isTopic && !m.archived else { return false }
        } else {
            guard doc.kind != .folder || (section == .archived && isTopic) else { return false }
        }
        switch section {
        case .all, .topics: break
        case .inbox: if !m.inbox || m.archived { return false }
        case .books: if m.category != .book { return false }
        case .papers: if m.category != .paper { return false }
        case .notes: if m.category != .note { return false }
        case .reading: if m.readingStatus != .reading || m.archived { return false }
        case .archived: if !m.archived { return false }
        }
        switch archive {
        case .all: break
        case .active: if m.archived { return false }
        case .archived: if !m.archived { return false }
        }
        switch availability {
        case .all: break
        case .onDevice:
            guard doc.kind == .md || (doc.kind == .pdf && doc.pdfPath.map { FileManager.default.isReadableFile(atPath: $0) } == true) else { return false }
        case .waitingDownload:
            guard doc.kind == .pdf, doc.pdfPath.map({ FileManager.default.isReadableFile(atPath: $0) }) != true else { return false }
        }
        if let topicID, !m.topicIDs.contains(topicID) { return false }
        if let tag, !m.tags.contains(tag) { return false }
        if let year, m.year != year { return false }
        if let yearFrom {
            guard (1...9999).contains(yearFrom), let value = m.year, value >= yearFrom else { return false }
        }
        if let yearTo {
            guard (1...9999).contains(yearTo), let value = m.year, value <= yearTo else { return false }
        }
        if let yearFrom, let yearTo, yearFrom > yearTo { return false }
        if let readingStatus, m.readingStatus != readingStatus { return false }
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let terms = author.split(whereSeparator: \.isWhitespace).map(String.init)
            guard m.authors.contains(where: { name in
                terms.allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }) else { return false }
        }
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        if indexedMatches.contains(doc.id) { return true }
        let haystack = [doc.name, doc.markdown, m.searchText].joined(separator: "\n")
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public enum CatalogSourceState: Equatable, Sendable {
    case checking, available, missing, trashed, needsDownload, fileChanged, unverifiedVersion
    public var title: String {
        switch self {
        case .checking: return "正在核对来源…"
        case .available: return "查看原文"
        case .missing: return "来源已移除，摘录仍保留"
        case .trashed: return "来源在回收站，摘录仍保留"
        case .needsDownload: return "原件尚未下载"
        case .fileChanged: return "来源版本已变化，位置待核对"
        case .unverifiedVersion: return "来源版本尚未核对，请在原文中确认位置"
        }
    }
}

public enum CatalogError: Error, LocalizedError {
    case notFound, invalidTopic, invalidPage, emptyName, invalidCategory, crossLibrary, invalidURL, archived, invalidMetadata, emptyExcerpt
    case concurrentMetadata(fields: [String])
    case excerptOperationConflict
    public var errorDescription: String? {
        switch self {
        case .notFound: return "资料不存在或已移入回收站。"
        case .invalidTopic: return "请选择一个仍在资料库中的专题。"
        case .invalidPage: return "页码须在文件页数范围内。"
        case .emptyName: return "请输入名称。"
        case .invalidCategory: return "文件夹仅可用作专题，文档不能改为专题。"
        case .crossLibrary: return "只能关联同一个资料库中的资料。"
        case .invalidURL: return "来源地址须为有效的 http 或 https 地址。"
        case .archived: return "请先恢复整理这份归档资料，再继续编辑。"
        case .invalidMetadata: return "书目信息格式无效，请检查年份和名称。"
        case .emptyExcerpt: return "请填写摘录原文或自己的评论。"
        case .excerptOperationConflict: return "这次摘录已保存了不同的内容，原有摘录未被修改。请核对已保存内容；若要新增另一条摘录，请重新开始摘录。"
        case .concurrentMetadata(let fields): return "其他设备已修改\(fields.joined(separator: "、"))，本次输入仍保留。请重新载入最新信息后核对并修改；尚未覆盖任何资料。"
        }
    }
}

/// An inspector edits only these fields. Unchanged fields always come from the latest saved
/// record, while concurrent changes to the same field require an explicit user decision.
public struct CatalogMetadataEdit: Sendable {
    public var baseline: CatalogMetadata
    public var proposed: CatalogMetadata
    public init(baseline: CatalogMetadata, proposed: CatalogMetadata) {
        self.baseline = baseline
        self.proposed = proposed
    }

    public var isDirty: Bool { !changedFields.isEmpty }
    public var changedFields: [String] {
        var fields: [String] = []
        func inspect<T: Equatable>(_ name: String, _ path: KeyPath<CatalogMetadata, T>) {
            if baseline[keyPath: path] != proposed[keyPath: path] { fields.append(name) }
        }
        inspect("资料类型", \.category); inspect("标题", \.title); inspect("作者", \.authors)
        inspect("年份", \.year); inspect("ISBN", \.isbn); inspect("DOI", \.doi)
        inspect("出版社 / 期刊 / 会议", \.publication); inspect("来源网址", \.sourceURL)
        inspect("摘要或简介", \.abstract); inspect("标签", \.tags)
        return fields
    }

    public func merged(into latest: CatalogMetadata) throws -> CatalogMetadata {
        var result = latest
        var conflicts: [String] = []
        func merge<T: Equatable>(_ name: String, _ path: WritableKeyPath<CatalogMetadata, T>) {
            let old = baseline[keyPath: path], local = proposed[keyPath: path], remote = latest[keyPath: path]
            guard local != old else { return }
            if remote != old && remote != local { conflicts.append(name) }
            else { result[keyPath: path] = local }
        }
        merge("资料类型", \.category); merge("标题", \.title); merge("作者", \.authors)
        merge("年份", \.year); merge("ISBN", \.isbn); merge("DOI", \.doi)
        merge("出版社 / 期刊 / 会议", \.publication); merge("来源网址", \.sourceURL)
        merge("摘要或简介", \.abstract); merge("标签", \.tags)
        guard conflicts.isEmpty else { throw CatalogError.concurrentMetadata(fields: conflicts) }
        return result
    }
}

public extension DocumentStore {
    @discardableResult
    func updateCatalog(id: String, mutate: (inout CatalogMetadata) throws -> Void) throws -> LibraryDocument {
        try db.write { db in try updateCatalog(id: id, db: db, mutate: mutate) }
    }

    @discardableResult
    func updateCatalog(id: String, edit: CatalogMetadataEdit) throws -> LibraryDocument {
        try updateCatalog(id: id) { latest in
            guard !latest.archived else { throw CatalogError.archived }
            latest = try edit.merged(into: latest)
        }
    }

    @discardableResult
    func createCatalogTopic(name: String, parentID: String) throws -> LibraryDocument {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CatalogError.emptyName }
        return try db.write { db in
            try validateCatalogParent(parentID, db: db)
            let doc = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .folder, parentId: parentID,
                                      name: try uniqueCatalogName(title, kind: .folder, parentID: parentID, db: db), markdown: "", pdfPath: nil,
                                      revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]",
                                      metadataJSON: try CatalogMetadata(category: .topic, title: title).json())
            return try saveCatalogDocument(doc, db: db)
        }
    }

    @discardableResult
    func setCatalogTopic(id: String, topicID: String, included: Bool) throws -> LibraryDocument {
        try db.write { db in
            let doc = try activeCatalogDocument(id, db: db)
            // Removing an orphaned membership must remain possible after its topic was deleted.
            if included {
                let topic = try activeCatalogDocument(topicID, db: db)
                guard topic.isCatalogTopic, doc.kind != .folder else { throw CatalogError.invalidTopic }
                try validateCatalogLibrary(doc, topic, db: db)
            }
            return try updateCatalog(id: id, db: db) { m in
                m.topicIDs.removeAll { $0 == topicID }
                if included { m.topicIDs.append(topicID) }
            }
        }
    }

    @discardableResult
    func setCatalogArchived(id: String, archived: Bool) throws -> LibraryDocument {
        try updateCatalog(id: id) { m in
            if m.archived != archived { m.archivedAt = archived ? Date() : nil }
            m.archived = archived
            if archived { m.inbox = false }
        }
    }

    @discardableResult
    func markCatalogOrganized(id: String) throws -> LibraryDocument {
        try updateCatalog(id: id) { $0.inbox = false }
    }

    @discardableResult
    func recordCatalogReadingPosition(id: String, deviceID: String, pageIndex: Int, totalPages: Int? = nil, fileHash: String? = nil) throws -> LibraryDocument {
        guard pageIndex >= 0, !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogError.invalidPage }
        if let totalPages, totalPages <= pageIndex || totalPages <= 0 { throw CatalogError.invalidPage }
        return try db.write { db in
            let doc = try activeCatalogDocument(id, db: db)
            guard doc.kind == .pdf else { throw CatalogError.invalidCategory }
            return try updateCatalog(id: id, db: db) { m in
                if let previous = m.readingPositions.first(where: { $0.deviceID == deviceID }),
                   previous.pageIndex == pageIndex, previous.totalPages == totalPages, previous.fileHash == fileHash { return }
                m.readingPositions.removeAll { $0.deviceID == deviceID }
                m.readingPositions.append(CatalogReadingPosition(deviceID: deviceID, pageIndex: pageIndex, totalPages: totalPages, fileHash: fileHash))
                if m.readingStatus == .toRead { m.readingStatus = .reading }
            }
        }
    }

    @discardableResult
    func setCatalogRelated(id: String, targetID: String, included: Bool) throws -> LibraryDocument {
        try db.write { db in
            let doc = try activeCatalogDocument(id, db: db)
            guard doc.id != targetID else { return doc }
            let target = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [targetID]).map(mapDoc)
            if included {
                guard let target, target.state == "active" else { throw CatalogError.notFound }
                guard doc.kind != .folder && target.kind != .folder else { throw CatalogError.invalidCategory }
                try validateCatalogLibrary(doc, target, db: db)
                if target.catalog.relatedIDs.contains(id) { return doc }
            }
            // Both halves of a legacy symmetric edge are removed in one transaction.
            if !included, let target, ["active", "trashed"].contains(target.state),
               target.purgeAt.map({ $0 > Date() }) ?? true, target.catalog.relatedIDs.contains(id) {
                _ = try updateCatalog(id: targetID, db: db, allowTrashed: true) { $0.relatedIDs.removeAll { $0 == id } }
            }
            return try updateCatalog(id: id, db: db) { m in
                m.relatedIDs.removeAll { $0 == targetID }
                if included { m.relatedIDs.append(targetID) }
            }
        }
    }

    func catalogDocuments(query: CatalogQuery, sort: CatalogSort = .title) throws -> [LibraryDocument] {
        let matches = query.text.isEmpty ? Set<String>() : Set(try search(query: query.text))
        return query.results(in: try listDocuments(), indexedMatches: matches, sort: sort)
    }

    func catalogBacklinks(to id: String) throws -> [LibraryDocument] {
        try listDocuments().filter { $0.catalog.sourceIDs.contains(id) || $0.catalog.excerpts.contains { $0.sourceID == id } }
    }

    func relatedCatalogDocuments(to id: String) throws -> [LibraryDocument] {
        try db.read { db in
            let m = try activeCatalogDocument(id, db: db).catalog
            return try Row.fetchAll(db, sql: "SELECT * FROM working_documents WHERE state='active'").map(mapDoc)
                .filter { m.relatedIDs.contains($0.id) || $0.catalog.relatedIDs.contains(id) }
        }
    }

    func catalogSourceState(for excerpt: CatalogExcerpt) throws -> CatalogSourceState {
        try catalogSourceStates(for: [excerpt])[excerpt.id] ?? .missing
    }

    /// Hash each source at most once per inspection, even when a note cites dozens of passages.
    func catalogSourceStates(for excerpts: [CatalogExcerpt]) throws -> [String: CatalogSourceState] {
        var result: [String: CatalogSourceState] = [:]
        var hashes: [String: String] = [:]
        for excerpt in excerpts {
            guard let source = try loadDocument(id: excerpt.sourceID) else { result[excerpt.id] = .missing; continue }
            guard source.state == "active" else { result[excerpt.id] = .trashed; continue }
            guard source.kind == .pdf else { result[excerpt.id] = .available; continue }
            guard let path = source.pdfPath, FileManager.default.fileExists(atPath: path) else { result[excerpt.id] = .needsDownload; continue }
            if excerpt.pageIndex != nil && excerpt.fileHash == nil {
                result[excerpt.id] = .unverifiedVersion; continue
            }
            if let expected = excerpt.fileHash {
                let actual: String
                if let cached = hashes[path] { actual = cached }
                else { actual = try Self.catalogFileHash(URL(fileURLWithPath: path)); hashes[path] = actual }
                if actual != expected { result[excerpt.id] = .fileChanged; continue }
            }
            result[excerpt.id] = .available
        }
        return result
    }

    @discardableResult
    func createCatalogNote(sourceID: String, quote: String, comment: String = "", pageIndex: Int? = nil, fileHash: String? = nil, parentID: String? = nil, noteID: String = UUID().uuidString.lowercased()) throws -> LibraryDocument {
        try db.write { db in
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [noteID]).map(mapDoc) {
                guard existing.kind == .md, existing.catalog.excerpts.contains(where: {
                    Self.matchesExcerptRequest($0, sourceID: sourceID, quote: quote, comment: comment, pageIndex: pageIndex, fileHash: fileHash)
                }) else { throw CatalogError.excerptOperationConflict }
                return existing
            }
            let source = try activeCatalogDocument(sourceID, db: db)
            let parent = try parentID ?? catalogPhysicalParent(source.parentId, db: db)
            try validateCatalogParent(parent, db: db)
            let excerpt = try makeCatalogExcerpt(source: source, quote: quote, comment: comment, pageIndex: pageIndex, fileHash: fileHash)
            let title = source.catalogTitle + " · 阅读笔记"
            var m = CatalogMetadata(category: .note, title: title)
            m.sourceIDs = [source.id]
            m.topicIDs = source.catalog.topicIDs
            m.excerpts = [excerpt]
            let note = LibraryDocument(id: noteID, kind: .md, parentId: parent,
                                       name: try uniqueCatalogName(title, kind: .md, parentID: parent, db: db),
                                       markdown: "# \(title)\n\n" + Self.catalogExcerptMarkdown(excerpt), pdfPath: nil,
                                       revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]",
                                       metadataJSON: try m.json())
            try validateCatalogLibrary(source, note, db: db)
            return try saveCatalogDocument(note, db: db)
        }
    }

    @discardableResult
    func appendCatalogExcerpt(noteID: String, sourceID: String, quote: String, comment: String = "", pageIndex: Int? = nil, fileHash: String? = nil, excerptID: String = UUID().uuidString.lowercased()) throws -> LibraryDocument {
        try db.write { db in
            var note = try activeCatalogDocument(noteID, db: db)
            guard note.kind == .md else { throw CatalogError.invalidCategory }
            // A successful retry remains successful even when the source subsequently moved to trash.
            var m = note.catalog
            if let existing = m.excerpts.first(where: { $0.id == excerptID }) {
                guard Self.matchesExcerptRequest(existing, sourceID: sourceID, quote: quote, comment: comment, pageIndex: pageIndex, fileHash: fileHash)
                else { throw CatalogError.excerptOperationConflict }
                return note
            }
            guard !m.archived else { throw CatalogError.archived }
            let source = try activeCatalogDocument(sourceID, db: db)
            try validateCatalogLibrary(note, source, db: db)
            var excerpt = try makeCatalogExcerpt(source: source, quote: quote, comment: comment, pageIndex: pageIndex, fileHash: fileHash)
            excerpt.id = excerptID
            m.excerpts.append(excerpt)
            m.sourceIDs = Self.catalogUnique(m.sourceIDs + [sourceID])
            note.markdown += "\n\n" + Self.catalogExcerptMarkdown(excerpt)
            note.metadataJSON = try m.jsonChanges(from: note.catalog, preserving: note.metadataJSON)
            return try saveCatalogDocument(note, db: db)
        }
    }

    /// A nil version asks us to capture the source automatically on the first
    /// commit. Replays must reuse that captured version without rereading a
    /// source that may since have changed or disappeared.
    private static func matchesExcerptRequest(_ excerpt: CatalogExcerpt, sourceID: String, quote: String, comment: String, pageIndex: Int?, fileHash: String?) -> Bool {
        excerpt.sourceID == sourceID && excerpt.quote == quote && excerpt.comment == comment && excerpt.pageIndex == pageIndex
            && (fileHash == nil || excerpt.fileHash == fileHash)
    }

    static func catalogFileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func catalogExcerptMarkdown(_ excerpt: CatalogExcerpt) -> String {
        let quote = excerpt.quote.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        let label = excerpt.sourceLabel.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
        var url = URLComponents()
        url.scheme = "tokenlibrary"; url.host = "document"; url.path = "/" + excerpt.sourceID
        var query: [URLQueryItem] = []
        if let page = excerpt.pageIndex { query.append(URLQueryItem(name: "page", value: String(page + 1))) }
        if let hash = excerpt.fileHash { query.append(URLQueryItem(name: "hash", value: hash)) }
        url.queryItems = query.isEmpty ? nil : query
        let source = "来源：[\(label)](\(url.string ?? ""))"
        let comment = excerpt.comment.isEmpty ? "" : "\n\n我的笔记：\n\n\(excerpt.comment)"
        return "\(quote)\n\n\(source)\(comment)\n"
    }

    private func updateCatalog(id: String, db: Database, allowTrashed: Bool = false, mutate: (inout CatalogMetadata) throws -> Void) throws -> LibraryDocument {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]) else { throw CatalogError.notFound }
        var doc = mapDoc(row)
        guard doc.state == "active" || (allowTrashed && doc.state == "trashed") else { throw CatalogError.notFound }
        guard (try? JSONSerialization.jsonObject(with: Data(doc.metadataJSON.utf8))) is [String: Any] else { throw CatalogError.invalidMetadata }
        let before = doc.catalog
        var m = before
        try mutate(&m)
        guard (doc.kind == .folder && m.category == .topic) || (doc.kind != .folder && m.category != .topic) else { throw CatalogError.invalidCategory }
        m.title = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
        m.authors = Self.catalogUnique(m.authors); m.topicIDs = Self.catalogUnique(m.topicIDs)
        m.tags = Self.catalogUnique(m.tags); m.sourceIDs = Self.catalogUnique(m.sourceIDs.filter { $0 != doc.id })
        m.relatedIDs = Self.catalogUnique(m.relatedIDs.filter { $0 != doc.id })
        if let year = m.year, year < 1 || year > 9999 { throw CatalogError.invalidMetadata }
        m.sourceURL = m.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.sourceURL.isEmpty {
            guard let url = URL(string: m.sourceURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else { throw CatalogError.invalidURL }
        }
        guard m != before else { return doc }
        doc.metadataJSON = try m.jsonChanges(from: before, preserving: doc.metadataJSON)
        _ = try saveDocument(doc, enqueue: true, expectedGeneration: nil, db: db)
        guard let saved = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]) else { throw CatalogError.notFound }
        return mapDoc(saved)
    }

    private func saveCatalogDocument(_ doc: LibraryDocument, db: Database) throws -> LibraryDocument {
        _ = try saveDocument(doc, enqueue: true, expectedGeneration: nil, db: db)
        return try activeCatalogDocument(doc.id, db: db)
    }

    private func activeCatalogDocument(_ id: String, db: Database) throws -> LibraryDocument {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=? AND state='active'", arguments: [id]) else { throw CatalogError.notFound }
        return mapDoc(row)
    }

    private func makeCatalogExcerpt(source: LibraryDocument, quote: String, comment: String, pageIndex: Int?, fileHash: String?) throws -> CatalogExcerpt {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogError.emptyExcerpt }
        if let pageIndex, pageIndex < 0 { throw CatalogError.invalidPage }
        guard source.kind != .folder else { throw CatalogError.invalidCategory }
        if pageIndex != nil, source.kind != .pdf { throw CatalogError.invalidPage }
        var hash = fileHash
        if source.kind == .pdf, let path = source.pdfPath, FileManager.default.fileExists(atPath: path) {
            if let pageIndex, let pdf = PDFDocument(url: URL(fileURLWithPath: path)), pageIndex >= pdf.pageCount { throw CatalogError.invalidPage }
            if hash == nil { hash = try Self.catalogFileHash(URL(fileURLWithPath: path)) }
        }
        return CatalogExcerpt(sourceID: source.id, sourceTitle: source.catalogTitle, quote: quote, comment: comment, pageIndex: pageIndex, fileHash: hash)
    }

    private func validateCatalogLibrary(_ a: LibraryDocument, _ b: LibraryDocument, db: Database) throws {
        var documents = try Row.fetchAll(db, sql: "SELECT * FROM working_documents").map(mapDoc)
        if !documents.contains(where: { $0.id == a.id }) { documents.append(a) }
        if !documents.contains(where: { $0.id == b.id }) { documents.append(b) }
        guard let aRoot = try hierarchyRootID(for: a.id, documents: documents, db: db),
              aRoot == (try hierarchyRootID(for: b.id, documents: documents, db: db)) else { throw CatalogError.crossLibrary }
    }

    private func validateCatalogParent(_ id: String, db: Database) throws {
        guard !id.isEmpty else { throw CatalogError.notFound }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]) {
            let parent = mapDoc(row)
            guard parent.state == "active", parent.kind == .folder else { throw CatalogError.notFound }
            guard !parent.isCatalogTopic else { throw CatalogError.invalidTopic }
        } else if !(try trustedVirtualRootIDs(db: db)).contains(id) {
            throw CatalogError.notFound
        }
    }

    private func catalogPhysicalParent(_ id: String, db: Database) throws -> String {
        var cursor = id, visited = Set<String>()
        while let row = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [cursor]) {
            guard visited.insert(cursor).inserted else { throw CatalogError.notFound }
            let parent = mapDoc(row)
            guard parent.isCatalogTopic else { return cursor }
            cursor = parent.parentId
        }
        return cursor
    }

    private func uniqueCatalogName(_ name: String, kind: DocKind, parentID: String, db: Database) throws -> String {
        // Display titles allow punctuation; the independent filename must satisfy server rules.
        let safeName = name.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\"))).joined(separator: " ")
        let normalized = safeName.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = normalized.isEmpty || normalized == "." || normalized == ".." ? "未命名" : normalized
        while base.utf8.count > 220 { base.removeLast() }
        let existing = Set(try String.fetchAll(db, sql: "SELECT name FROM working_documents WHERE state='active' AND parent_id=?", arguments: [parentID]).map(FileNames.comparisonKey))
        var result = FileNames.stored(base, kind: kind)
        var suffix = 1
        while existing.contains(FileNames.comparisonKey(result)) {
            result = FileNames.stored("\(base)_\(suffix)", kind: kind); suffix += 1
        }
        return result
    }

    private static func catalogUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
