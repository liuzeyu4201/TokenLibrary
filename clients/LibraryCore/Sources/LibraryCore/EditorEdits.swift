import Foundation
import GRDB

public enum MarkdownEditSaveResult: Sendable, Equatable {
    case saved(markdown: String, document: LibraryDocument)
    case conflict(markdown: String, conflictID: String)
}

/// Recoverable work is separate from the document and from server conflicts.
/// It survives trash, remote tombstones, local purge and application restart.
public struct EditorDraft: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let documentId: String
    public let kind: DocKind
    public let name: String
    public let reason: String
    public let baseMarkdown: String
    public let proposedMarkdown: String
    public let currentMarkdown: String
    public let baseAnnotations: [PDFTextAnnotation]
    public let proposedAnnotations: [PDFTextAnnotation]
    public let expectedPDFBlobId: String?
    public let expectedPDFPath: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let originalDocument: LibraryDocument?
}

public enum EditorEditError: LocalizedError, Sendable {
    case unavailableDocument
    case wrongDocumentKind
    case pdfChanged(draftID: String)
    case annotationConflict(draftID: String)
    case deletedDocument(draftID: String)
    case invalidAnnotations
    case missingOriginalPDF
    case invalidRecoveryFolder

    public var draftID: String? {
        switch self {
        case .pdfChanged(let id), .annotationConflict(let id), .deletedDocument(let id): return id
        default: return nil
        }
    }
    public var errorDescription: String? {
        switch self {
        case .unavailableDocument: return "资料已删除或无法打开。"
        case .wrongDocumentKind: return "这份资料不支持当前编辑方式。"
        case .pdfChanged: return "PDF 已更新，当前批注基于旧版本。批注草稿已保留，可在冲突与草稿中恢复副本。"
        case .annotationConflict: return "同一条批注已被修改。当前草稿已保留，可在冲突与草稿中恢复副本。"
        case .deletedDocument: return "资料已移到回收站或被删除。编辑草稿已保留，可在冲突与草稿中恢复副本。"
        case .invalidAnnotations: return "批注内容或位置无效，请重新选择 PDF 中的文字。"
        case .missingOriginalPDF: return "原 PDF 文件当前不可用。草稿仍已保留，请先恢复对应 PDF 后再创建副本。"
        case .invalidRecoveryFolder: return "恢复位置已删除或不是有效文件夹，请选择其他位置。"
        }
    }
}

/// A session owns its original store even if the UI switches account/workspace.
/// The lock also serializes a web-view flush with an autosave already in flight.
public final class MarkdownEditSession: @unchecked Sendable {
    public let documentID: String
    public let initialMarkdown: String
    private let store: DocumentStore
    private let originalDocument: LibraryDocument
    private let draftID = UUID().uuidString.lowercased()
    private let lock = NSLock()
    private var baseMarkdown: String

    init(store: DocumentStore, document: LibraryDocument) {
        self.store = store; documentID = document.id; originalDocument = document
        initialMarkdown = document.markdown; baseMarkdown = document.markdown
    }

    public func save(_ proposedMarkdown: String) throws -> MarkdownEditSaveResult {
        try lock.withLock { try saveLocked(baseMarkdown: baseMarkdown, proposedMarkdown: proposedMarkdown) }
    }

    public func save(baseMarkdown: String, proposedMarkdown: String) throws -> MarkdownEditSaveResult {
        try lock.withLock { try saveLocked(baseMarkdown: baseMarkdown, proposedMarkdown: proposedMarkdown) }
    }

    private func saveLocked(baseMarkdown: String, proposedMarkdown: String) throws -> MarkdownEditSaveResult {
        let result = try store.saveMarkdownEdit(id: documentID, baseMarkdown: baseMarkdown,
                                               proposedMarkdown: proposedMarkdown, draftID: draftID,
                                               originalDocument: originalDocument)
        if case .saved(let markdown, _) = result { self.baseMarkdown = markdown }
        return result
    }
}

extension DocumentStore {
    public func beginMarkdownEdit(id: String) throws -> MarkdownEditSession {
        guard let document = try loadDocument(id: id), document.state == "active" else { throw EditorEditError.unavailableDocument }
        guard document.kind == .md else { throw EditorEditError.wrongDocumentKind }
        return MarkdownEditSession(store: self, document: document)
    }

    public func saveMarkdownEdit(id: String, baseMarkdown: String, proposedMarkdown: String) throws -> MarkdownEditSaveResult {
        try saveMarkdownEdit(id: id, baseMarkdown: baseMarkdown, proposedMarkdown: proposedMarkdown,
                             draftID: UUID().uuidString.lowercased(), originalDocument: nil)
    }

    fileprivate func saveMarkdownEdit(id: String, baseMarkdown: String, proposedMarkdown: String,
                                     draftID: String, originalDocument: LibraryDocument?) throws -> MarkdownEditSaveResult {
        try db.write { db in
            let current = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
            let remotelyDeleted = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM remote_tombstones WHERE id=?)", arguments: [id]) ?? false
            if let current, current.kind != .md { throw EditorEditError.wrongDocumentKind }
            let reason: String
            if let current, current.state == "active", !remotelyDeleted,
               let merged = EditorMarkdownMerge.merge(base: baseMarkdown, local: proposedMarkdown, remote: current.markdown) {
                var updated = current
                if merged != current.markdown {
                    updated.markdown = merged
                    _ = try saveDocument(updated, enqueue: true, expectedGeneration: current.localGeneration, db: db)
                    updated = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc) ?? updated
                }
                try db.execute(sql: "DELETE FROM editor_drafts WHERE id=?", arguments: [draftID])
                return .saved(markdown: merged, document: updated)
            } else {
                reason = current?.state == "active" && !remotelyDeleted ? "正文同时修改" : "资料已删除"
            }
            let source = originalDocument ?? current
            let draft = EditorDraft(id: draftID, documentId: id, kind: .md, name: source?.name ?? "恢复的笔记.md", reason: reason,
                                    baseMarkdown: baseMarkdown, proposedMarkdown: proposedMarkdown, currentMarkdown: current?.markdown ?? "",
                                    baseAnnotations: [], proposedAnnotations: [], expectedPDFBlobId: nil, expectedPDFPath: nil,
                                    createdAt: Date(), updatedAt: Date(), originalDocument: source)
            try persistEditorDraft(draft, db: db)
            return .conflict(markdown: current?.markdown ?? "", conflictID: draftID)
        }
    }

    /// The current identity, read/merge/write, queue and index changes share one
    /// SQLite transaction. Failure materials commit before the error is thrown.
    public func savePDFAnnotationEdit(id: String, expectedPDFBlobId: String?, expectedPDFPath: String?,
                                      base: [PDFTextAnnotation], proposed: [PDFTextAnnotation]) throws -> [PDFTextAnnotation] {
        guard Self.validAnnotations(base), Self.validAnnotations(proposed) else { throw EditorEditError.invalidAnnotations }
        let outcome: Result<[PDFTextAnnotation], EditorEditError> = try db.write { db in
            let current = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
            let remotelyDeleted = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM remote_tombstones WHERE id=?)", arguments: [id]) ?? false
            if let current, current.kind != .pdf { throw EditorEditError.wrongDocumentKind }
            let latest = try current.map { try JSONDecoder().decode([PDFTextAnnotation].self, from: Data($0.annotationsJSON.utf8)) } ?? []
            let draftID: String
            // One stale PDF editing surface retains its latest proposal in one
            // draft; unrelated base snapshots retain separate materials.
            let identityEncoder = JSONEncoder(); identityEncoder.outputFormatting = [.sortedKeys]
            let fingerprint = BlobIntegrity.sha256(try identityEncoder.encode(PDFDraftIdentity(documentId: id,
                pdfBlobId: expectedPDFBlobId, pdfPath: expectedPDFPath, base: base.sorted { $0.id < $1.id })))
            draftID = "pdf-" + fingerprint
            let error: EditorEditError?
            let merged = PDFMerge.mergeAdds(base: base, local: proposed, remote: latest)
            if current == nil || current?.state != "active" || remotelyDeleted { error = .deletedDocument(draftID: draftID) }
            else if current?.pdfBlobId != expectedPDFBlobId || current?.pdfPath != expectedPDFPath { error = .pdfChanged(draftID: draftID) }
            else if merged.conflict { error = .annotationConflict(draftID: draftID) }
            else { error = nil }
            if let error {
                var original = current
                original?.pdfBlobId = expectedPDFBlobId; original?.pdfPath = expectedPDFPath
                let draft = EditorDraft(id: draftID, documentId: id, kind: .pdf, name: current?.name ?? "恢复的批注.pdf",
                    reason: error.errorDescription ?? "批注无法保存", baseMarkdown: "", proposedMarkdown: "", currentMarkdown: "",
                    baseAnnotations: base, proposedAnnotations: proposed, expectedPDFBlobId: expectedPDFBlobId, expectedPDFPath: expectedPDFPath,
                    createdAt: Date(), updatedAt: Date(), originalDocument: original)
                try persistEditorDraft(draft, db: db)
                return .failure(error)
            }
            guard var document = current else { throw EditorEditError.unavailableDocument }
            if latest != merged.merged {
                document.annotationsJSON = String(decoding: try JSONEncoder().encode(merged.merged), as: UTF8.self)
                _ = try saveDocument(document, enqueue: true, expectedGeneration: document.localGeneration, db: db)
            }
            try db.execute(sql: "DELETE FROM editor_drafts WHERE id=?", arguments: [draftID])
            return .success(merged.merged)
        }
        return try outcome.get()
    }

    public func editorDrafts(documentId: String? = nil) throws -> [EditorDraft] {
        try db.read { db in
            let values: [String]
            if let documentId { values = try String.fetchAll(db, sql: "SELECT draft_json FROM editor_drafts WHERE document_id=? ORDER BY updated_at DESC,id", arguments: [documentId]) }
            else { values = try String.fetchAll(db, sql: "SELECT draft_json FROM editor_drafts ORDER BY updated_at DESC,id") }
            return try values.map { try JSONDecoder().decode(EditorDraft.self, from: Data($0.utf8)) }
        }
    }

    public func discardEditorDraft(id: String) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM editor_drafts WHERE id=?", arguments: [id]) }
    }

    /// Recovers under a new ID; never silently restores a deleted source or
    /// applies annotations from an old PDF to the current version.
    @discardableResult
    public func recoverEditorDraftAsCopy(id: String, parentId: String) throws -> LibraryDocument {
        try db.write { db in
            guard let text = try String.fetchOne(db, sql: "SELECT draft_json FROM editor_drafts WHERE id=?", arguments: [id]) else { throw StoreError.notFound }
            let draft = try JSONDecoder().decode(EditorDraft.self, from: Data(text.utf8))
            let documents = try Row.fetchAll(db, sql: "SELECT * FROM working_documents").map(mapDoc)
            let folder = documents.first { $0.id == parentId }
            let virtualRoots = try trustedVirtualRootIDs(db: db)
            guard (folder?.kind == .folder && folder?.state == "active" && folder?.isCatalogTopic == false) || (virtualRoots.contains(parentId) && folder == nil),
                  try hierarchyRootID(for: parentId, documents: documents, db: db) != nil else { throw EditorEditError.invalidRecoveryFolder }
            var copy = draft.originalDocument ?? LibraryDocument(id: "", kind: draft.kind, parentId: parentId, name: draft.name,
                markdown: "", pdfPath: draft.expectedPDFPath, revision: 0, localGeneration: 0, state: "active", purgeAt: nil,
                status: .pending, annotationsJSON: "[]")
            copy.id = UUID().uuidString.lowercased(); copy.parentId = parentId
            copy.revision = 0; copy.localGeneration = 0; copy.state = "active"; copy.purgeAt = nil; copy.status = .pending
            let ext = draft.kind == .pdf ? "pdf" : "md"
            // Also recover old invalid filenames without recreating a server
            // rejection; leave room for suffix/extension under its 240-byte limit.
            var shortStem = FileNames.editingBase(draft.name, kind: draft.kind)
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
                .components(separatedBy: .controlCharacters).joined(separator: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if shortStem.isEmpty { shortStem = "恢复资料" }
            while shortStem.utf8.count > 200 { shortStem.removeLast() }
            let baseName = shortStem + "（恢复副本）"
            let names = Set(documents.filter { $0.parentId == parentId && $0.state == "active" }.map { FileNames.comparisonKey($0.name) })
            var suffix = 0
            repeat {
                copy.name = baseName + (suffix == 0 ? "" : "_\(suffix)") + (ext.isEmpty ? "" : "." + ext)
                suffix += 1
            } while names.contains(FileNames.comparisonKey(copy.name))
            if draft.kind == .md { copy.markdown = draft.proposedMarkdown }
            else {
                guard let path = draft.expectedPDFPath,
                      let originalBytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                else { throw EditorEditError.missingOriginalPDF }
                copy.pdfPath = path; copy.pdfBlobId = draft.expectedPDFBlobId
                copy.annotationsJSON = String(decoding: try JSONEncoder().encode(draft.proposedAnnotations), as: UTF8.self)
                // A stale surface's draft may have captured the replacement's
                // current bibliography. The recovered PDF is the old file:
                // derive its hash from those actual bytes, including for drafts
                // already persisted by earlier builds. Preserve all other keys.
                var metadata = try JSONValue.parse(copy.metadataJSON).object ?? [:]
                metadata["originalFileHash"] = .string(BlobIntegrity.sha256(originalBytes))
                copy.metadataJSON = try JSONValue.object(metadata).jsonString()
            }
            _ = try createDocument(copy, deduplicateName: true, db: db)
            try db.execute(sql: "DELETE FROM editor_drafts WHERE id=?", arguments: [id])
            return try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [copy.id]).map(mapDoc) ?? copy
        }
    }

    private func persistEditorDraft(_ draft: EditorDraft, db: Database) throws {
        let previous = try String.fetchOne(db, sql: "SELECT draft_json FROM editor_drafts WHERE id=?", arguments: [draft.id])
        let created = try previous.map { try JSONDecoder().decode(EditorDraft.self, from: Data($0.utf8)).createdAt } ?? draft.createdAt
        let value = EditorDraft(id: draft.id, documentId: draft.documentId, kind: draft.kind, name: draft.name, reason: draft.reason,
            baseMarkdown: draft.baseMarkdown, proposedMarkdown: draft.proposedMarkdown, currentMarkdown: draft.currentMarkdown,
            baseAnnotations: draft.baseAnnotations, proposedAnnotations: draft.proposedAnnotations, expectedPDFBlobId: draft.expectedPDFBlobId,
            expectedPDFPath: draft.expectedPDFPath, createdAt: created, updatedAt: draft.updatedAt, originalDocument: draft.originalDocument)
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let formatter = ISO8601DateFormatter()
        try db.execute(sql: "INSERT INTO editor_drafts(id,document_id,kind,draft_json,created_at,updated_at) VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET draft_json=excluded.draft_json,updated_at=excluded.updated_at",
                       arguments: [value.id,value.documentId,value.kind.rawValue,text,formatter.string(from: created),formatter.string(from: value.updatedAt)])
    }

    private static func validAnnotations(_ values: [PDFTextAnnotation]) -> Bool {
        var ids = Set<String>()
        return values.allSatisfy {
            !$0.id.isEmpty && ids.insert($0.id).inserted && ["highlight", "comment"].contains($0.type) && $0.pageIndex >= 0 &&
            $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
    }
}

private struct PDFDraftIdentity: Codable {
    let documentId: String
    let pdfBlobId: String?
    let pdfPath: String?
    let base: [PDFTextAnnotation]
}

/// Multiple disjoint line edits are merged, not just a single broad prefix /
/// suffix hunk. Overlap retains a draft rather than inserting conflict markers.
enum EditorMarkdownMerge {
    struct Edit: Equatable { let start: Int; let end: Int; let lines: [String] }

    static func merge(base: String, local: String, remote: String) -> String? {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        let original = base.components(separatedBy: "\n")
        let localEdits = edits(from: original, to: local.components(separatedBy: "\n"))
        let remoteEdits = edits(from: original, to: remote.components(separatedBy: "\n"))
        for lhs in localEdits {
            for rhs in remoteEdits where lhs != rhs {
                let lhsInsert = lhs.start == lhs.end, rhsInsert = rhs.start == rhs.end
                if lhsInsert && rhsInsert && lhs.start == rhs.start { return nil }
                if lhsInsert && lhs.start > rhs.start && lhs.start < rhs.end { return nil }
                if rhsInsert && rhs.start > lhs.start && rhs.start < lhs.end { return nil }
                if !lhsInsert && !rhsInsert && max(lhs.start, rhs.start) < min(lhs.end, rhs.end) { return nil }
            }
        }
        var edits = localEdits
        for edit in remoteEdits where !edits.contains(edit) { edits.append(edit) }
        var result = original
        for edit in edits.sorted(by: { $0.start == $1.start ? $0.end > $1.end : $0.start > $1.start }) {
            result.replaceSubrange(edit.start..<edit.end, with: edit.lines)
        }
        return result.joined(separator: "\n")
    }

    private static func edits(from original: [String], to target: [String]) -> [Edit] {
        var prefix = 0
        while prefix < min(original.count, target.count), original[prefix] == target[prefix] { prefix += 1 }
        var sourceEnd = original.count, targetEnd = target.count
        while sourceEnd > prefix, targetEnd > prefix, original[sourceEnd - 1] == target[targetEnd - 1] {
            sourceEnd -= 1; targetEnd -= 1
        }
        // CollectionDifference has an expensive worst case for thousands of
        // entirely replaced lines. Keep the outer edit as one conservative
        // hunk above this bound; conflicting work is still durable in a draft.
        guard (sourceEnd - prefix) + (targetEnd - prefix) <= 8192 else {
            return [Edit(start: prefix, end: sourceEnd, lines: Array(target[prefix..<targetEnd]))]
        }
        let sourceWindow = Array(original[prefix..<sourceEnd]), targetWindow = Array(target[prefix..<targetEnd])
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in targetWindow.difference(from: sourceWindow) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset + prefix)
            case .insert(let offset, _, _): inserted.insert(offset + prefix)
            }
        }
        var sourceIndex = prefix, targetIndex = prefix, result: [Edit] = []
        while sourceIndex < sourceEnd || targetIndex < targetEnd {
            if removed.contains(sourceIndex) || inserted.contains(targetIndex) {
                let start = sourceIndex
                var lines: [String] = []
                while removed.contains(sourceIndex) || inserted.contains(targetIndex) {
                    while removed.contains(sourceIndex) { sourceIndex += 1 }
                    while inserted.contains(targetIndex) { lines.append(target[targetIndex]); targetIndex += 1 }
                }
                result.append(Edit(start: start, end: sourceIndex, lines: lines))
            } else {
                sourceIndex += 1; targetIndex += 1
            }
        }
        return result
    }
}
