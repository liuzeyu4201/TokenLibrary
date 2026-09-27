import Foundation
import GRDB

public enum DocKind: String, Codable, Sendable { case folder, md, pdf }
public enum SyncStatus: String, Codable, Sendable {
    case savedLocal = "已保存到本机"
    case pending = "等待同步"
    case syncing = "同步中"
    case synced = "已同步"
    case failed = "同步失败"
    case conflict = "存在冲突"
}

public struct LibraryDocument: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var kind: DocKind
    public var parentId: String
    public var name: String
    public var markdown: String
    public var pdfPath: String?
    public var revision: Int64
    public var localGeneration: Int64
    public var state: String
    public var purgeAt: Date?
    public var status: SyncStatus
    public var annotationsJSON: String
    public var metadataJSON: String
    public var assetsJSON: String
    public var pdfBlobId: String?

    public init(id: String, kind: DocKind, parentId: String, name: String, markdown: String, pdfPath: String?, revision: Int64, localGeneration: Int64, state: String, purgeAt: Date?, status: SyncStatus, annotationsJSON: String, metadataJSON: String = "{}", assetsJSON: String = "[]", pdfBlobId: String? = nil) {
        self.id = id
        self.kind = kind
        self.parentId = parentId
        self.name = name
        self.markdown = markdown
        self.pdfPath = pdfPath
        self.revision = revision
        self.localGeneration = localGeneration
        self.state = state
        self.purgeAt = purgeAt
        self.status = status
        self.annotationsJSON = annotationsJSON
        self.metadataJSON = metadataJSON
        self.assetsJSON = assetsJSON
        self.pdfBlobId = pdfBlobId
    }

    enum CodingKeys: String, CodingKey { case id, kind, parentId, name, markdown, pdfPath, revision, localGeneration, state, purgeAt, status, annotationsJSON, metadataJSON, assetsJSON, pdfBlobId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), kind: try c.decode(DocKind.self, forKey: .kind),
                  parentId: try c.decode(String.self, forKey: .parentId), name: try c.decode(String.self, forKey: .name),
                  markdown: try c.decode(String.self, forKey: .markdown), pdfPath: try c.decodeIfPresent(String.self, forKey: .pdfPath),
                  revision: try c.decode(Int64.self, forKey: .revision), localGeneration: try c.decode(Int64.self, forKey: .localGeneration),
                  state: try c.decode(String.self, forKey: .state), purgeAt: try c.decodeIfPresent(Date.self, forKey: .purgeAt),
                  status: try c.decode(SyncStatus.self, forKey: .status), annotationsJSON: try c.decode(String.self, forKey: .annotationsJSON),
                  metadataJSON: try c.decodeIfPresent(String.self, forKey: .metadataJSON) ?? "{}",
                  assetsJSON: try c.decodeIfPresent(String.self, forKey: .assetsJSON) ?? "[]", pdfBlobId: try c.decodeIfPresent(String.self, forKey: .pdfBlobId))
    }

    public static func folderFirst(_ lhs: LibraryDocument, _ rhs: LibraryDocument) -> Bool {
        if lhs.kind == .folder && rhs.kind != .folder { return true }
        if lhs.kind != .folder && rhs.kind == .folder { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    public func isAncestor(of other: LibraryDocument, in all: [LibraryDocument]) -> Bool {
        var cur: String? = other.parentId
        var n = 0
        while let id = cur, n < 40 {
            if id == self.id { return true }
            cur = all.first(where: { $0.id == id })?.parentId
            n += 1
        }
        return false
    }
}

public struct PendingOperation: Codable, Sendable, Equatable {
    public var operationId: String
    public var action: String
    public var objectId: String
    public var payload: String
    public var state: String
    public var baseRevision: Int64?
    public var requestJSON: String?
    public var requestOrigin: String?
    public var frozenGeneration: Int64?

    public init(operationId: String, action: String, objectId: String, payload: String, state: String,
                baseRevision: Int64? = nil, requestJSON: String? = nil, requestOrigin: String? = nil, frozenGeneration: Int64? = nil) {
        self.operationId = operationId
        self.action = action
        self.objectId = objectId
        self.payload = payload
        self.state = state
        self.baseRevision = baseRevision
        self.requestJSON = requestJSON
        self.requestOrigin = requestOrigin
        self.frozenGeneration = frozenGeneration
    }
}

public final class DocumentStore: @unchecked Sendable {
    public let db: DatabasePool
    public let root: URL
    private let pdfPageTextExtractor: @Sendable (Data) -> [String]

    public init(directory: URL, pdfPageTextExtractor: (@Sendable (Data) -> [String])? = nil) throws {
        self.root = directory
        self.pdfPageTextExtractor = pdfPageTextExtractor ?? { PDFSearchText.pages(from: $0) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        db = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path, configuration: config)
        try migrator.migrate(db)
        try recoverRelocatedLibraryPaths()
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE local_schema_info (fingerprint TEXT PRIMARY KEY, initialized_at TEXT NOT NULL);
                CREATE TABLE working_documents (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    parent_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    markdown TEXT NOT NULL DEFAULT '',
                    pdf_path TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    local_generation INTEGER NOT NULL DEFAULT 0,
                    state TEXT NOT NULL DEFAULT 'active',
                    purge_at TEXT,
                    status TEXT NOT NULL DEFAULT '已保存到本机',
                    annotations_json TEXT NOT NULL DEFAULT '[]',
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE pending_operations (
                    operation_id TEXT PRIMARY KEY,
                    action TEXT NOT NULL,
                    object_id TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    state TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE search_chunks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    object_id TEXT NOT NULL,
                    source TEXT NOT NULL,
                    text TEXT NOT NULL
                );
                CREATE VIRTUAL TABLE search_fts USING fts5(object_id, source, text, tokenize='unicode61');
                INSERT INTO local_schema_info VALUES ('v1', datetime('now'));
                """)
        }
        m.registerMigration("v2-frozen-operations") { db in
            try db.execute(sql: """
                ALTER TABLE pending_operations ADD COLUMN base_revision INTEGER;
                ALTER TABLE pending_operations ADD COLUMN request_json TEXT;
                ALTER TABLE pending_operations ADD COLUMN request_origin TEXT;
                ALTER TABLE pending_operations ADD COLUMN frozen_generation INTEGER;
                CREATE INDEX pending_by_object_state ON pending_operations(object_id, state);
                """)
        }
        m.registerMigration("v3-authoritative-sync") { db in
            try db.execute(sql: """
                ALTER TABLE working_documents ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';
                ALTER TABLE working_documents ADD COLUMN assets_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE working_documents ADD COLUMN pdf_blob_id TEXT;
                CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE remote_documents (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, snapshot_json TEXT NOT NULL);
                CREATE TABLE remote_tombstones (id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL);
                CREATE TABLE sync_conflicts (id TEXT PRIMARY KEY, object_id TEXT NOT NULL, server_id TEXT, kind TEXT NOT NULL, base_json TEXT NOT NULL, local_json TEXT NOT NULL, remote_json TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'open', created_at TEXT NOT NULL);
                CREATE TABLE blob_transfers (blob_id TEXT PRIMARY KEY, local_path TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, mime TEXT NOT NULL, upload_id TEXT, state TEXT NOT NULL);
                """)
        }
        m.registerMigration("v4-trash-batches") { db in
            try db.execute(sql: "ALTER TABLE working_documents ADD COLUMN trash_batch_id TEXT")
        }
        m.registerMigration("v5-mixed-search-index") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS pdf_page_text_cache(identity TEXT PRIMARY KEY, pages_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS search_index_state(object_id TEXT PRIMARY KEY, signature TEXT NOT NULL)")
            try self.ensurePDFTextCacheReferences(db)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM working_documents") { try self.reindex(self.mapDoc(row), db: db) }
        }
        m.registerMigration("v6-pdf-text-cache") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS pdf_page_text_cache(identity TEXT PRIMARY KEY, pages_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS search_index_state(object_id TEXT PRIMARY KEY, signature TEXT NOT NULL)")
            try self.ensurePDFTextCacheReferences(db)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM working_documents") { try self.reindex(self.mapDoc(row), db: db) }
        }
        m.registerMigration("v7-search-page-details") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS pdf_page_text_cache(identity TEXT PRIMARY KEY, pages_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS search_index_state(object_id TEXT PRIMARY KEY, signature TEXT NOT NULL)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS search_chunks_object_source ON search_chunks(object_id,source)")
            try self.ensurePDFTextCacheReferences(db)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM working_documents") { try self.reindex(self.mapDoc(row), db: db) }
        }
        m.registerMigration("v8-operation-rejections") { db in
            try db.execute(sql: "CREATE TABLE operation_rejections(operation_id TEXT PRIMARY KEY, http_status INTEGER NOT NULL, error_code TEXT NOT NULL)")
        }
        m.registerMigration("v9-search-signatures") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS search_index_state(object_id TEXT PRIMARY KEY, signature TEXT NOT NULL)")
            try self.ensurePDFTextCacheReferences(db)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM working_documents") { try self.reindex(self.mapDoc(row), db: db) }
        }
        m.registerMigration("v10-editor-drafts") { db in
            // Deliberately independent of working_documents: deleting/purging a
            // document must never delete keystrokes arriving from an open editor.
            try db.execute(sql: """
                CREATE TABLE editor_drafts (
                    id TEXT PRIMARY KEY, document_id TEXT NOT NULL, kind TEXT NOT NULL,
                    draft_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                );
                CREATE INDEX editor_drafts_document ON editor_drafts(document_id,updated_at);
                """)
        }
        m.registerMigration("v11-stable-pdf-text-cache") { db in
            try self.ensurePDFTextCacheReferences(db)
            // Old keys contain an opaque absolute-path hash. Rebuild once;
            // never guess that cached text belongs to the current original.
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM working_documents WHERE kind='pdf' AND id NOT IN (SELECT object_id FROM pdf_page_text_cache_refs)")
            for row in rows {
                let document = self.mapDoc(row)
                try db.execute(sql: "DELETE FROM search_index_state WHERE object_id=?", arguments: [document.id])
                try self.reindex(document, db: db)
            }
            try db.execute(sql: "DELETE FROM pdf_page_text_cache WHERE identity NOT IN (SELECT identity FROM pdf_page_text_cache_refs)")
        }
        return m
    }

    public func saveDocument(_ doc: LibraryDocument, enqueue: Bool) throws {
        _ = try saveDocument(doc, enqueue: enqueue, expectedGeneration: nil)
    }

    /// Attachment preparation may suspend during HTTP; the generation check and replacement must be atomic.
    func saveDocumentIfCurrent(_ doc: LibraryDocument, expectedGeneration: Int64) throws -> Bool {
        try saveDocument(doc, enqueue: true, expectedGeneration: expectedGeneration)
    }

    private func saveDocument(_ doc: LibraryDocument, enqueue: Bool, expectedGeneration: Int64?) throws -> Bool {
        try db.write { db in try saveDocument(doc, enqueue: enqueue, expectedGeneration: expectedGeneration, db: db) }
    }

    /// Read/merge/write callers can use the same transaction without a nested writer or TOCTOU gap.
    func saveDocument(_ doc: LibraryDocument, enqueue: Bool, expectedGeneration: Int64?, db: Database, index: Bool = true) throws -> Bool {
        let existing = try Row.fetchOne(db, sql: "SELECT revision, parent_id, name, local_generation FROM working_documents WHERE id=?", arguments: [doc.id])
        if let expectedGeneration, (existing?["local_generation"] as Int64?) != expectedGeneration { return false }
        let prevRev: Int64 = existing?["revision"] ?? 0
        let prevParent: String = existing?["parent_id"] ?? ""
        let prevName: String = existing?["name"] ?? ""
        let unresolved = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND state='conflict'", arguments: [doc.id]) ?? 0
        try db.execute(
            sql: """
            INSERT INTO working_documents(id, kind, parent_id, name, markdown, pdf_path, revision, local_generation, state, purge_at, status, annotations_json, updated_at, metadata_json, assets_json, pdf_blob_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, markdown=excluded.markdown, parent_id=excluded.parent_id,
                pdf_path=excluded.pdf_path, revision=MAX(working_documents.revision,excluded.revision),
                local_generation=working_documents.local_generation+1,
                state=excluded.state, purge_at=excluded.purge_at, status=excluded.status,
                annotations_json=excluded.annotations_json, updated_at=excluded.updated_at,
                metadata_json=excluded.metadata_json, assets_json=excluded.assets_json, pdf_blob_id=excluded.pdf_blob_id
            """,
            arguments: [
                doc.id, doc.kind.rawValue, doc.parentId, doc.name, doc.markdown, doc.pdfPath,
                doc.revision, doc.localGeneration, doc.state, doc.purgeAt.map(iso),
                enqueue ? (unresolved > 0 ? SyncStatus.conflict.rawValue : SyncStatus.pending.rawValue) : doc.status.rawValue,
                doc.annotationsJSON, iso(Date()), doc.metadataJSON, doc.assetsJSON, doc.pdfBlobId,
            ]
        )
        if enqueue {
            // A definite server rejection did not commit. A user edit creates a fresh operation;
            // the original immutable envelope remains available for diagnosis.
            try db.execute(sql: "UPDATE pending_operations SET state='rejected' WHERE object_id=? AND state='needs_edit'", arguments: [doc.id])
            var action = Self.syncAction(kind: doc.kind, revision: max(doc.revision, prevRev))
            if existing != nil && prevRev > 0 && prevParent != doc.parentId {
                action = "move"
            } else if existing != nil && prevName != doc.name {
                action = prevRev > 0 ? "rename" : action
            }
            let payload = encodePayload(doc)
            // Coalesce only a mutable tail. A sent/frozen request or a trash/restore transition is a boundary.
            let tail = try Row.fetchOne(db, sql: "SELECT * FROM pending_operations WHERE object_id=? ORDER BY rowid DESC LIMIT 1", arguments: [doc.id])
            if let row = tail, (row["state"] as String) == "pending", (row["request_json"] as String?) == nil,
               !["trash", "restore"].contains(row["action"] as String) {
                let oid: String = row["operation_id"]
                // Content edits must not erase an earlier unsent structural intent.
                let previousAction: String = row["action"]
                if previousAction == "move" { action = "move" }
                else if previousAction == "rename" && action == "updateDocument" { action = "rename" }
                try db.execute(sql: "UPDATE pending_operations SET action=?, payload=? WHERE operation_id=?",
                               arguments: [action, payload, oid])
            } else {
                let op = UUID().uuidString.lowercased()
                try db.execute(
                    sql: "INSERT INTO pending_operations(operation_id, action, object_id, payload, state, created_at) VALUES (?,?,?,?,?,?)",
                    arguments: [op, action, doc.id, payload, "pending", iso(Date())]
                )
            }
        }
        if index { try reindex(doc, db: db) }
        return true
    }

    /// Rebuilds search text for one document. Editor keystrokes skip this until typing pauses.
    public func refreshSearchIndex(id: String) throws {
        try db.write { db in
            guard let document = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc) else { return }
            try reindex(document, db: db)
        }
    }

    /// Rename without touching markdown/PDF body. Empty input falls back via FileNames.
    @discardableResult
    public func renameDocument(id: String, to rawName: String) throws -> LibraryDocument? {
        try db.write { db in
            guard var doc = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc) else { return nil }
            try requireEditableStructure(doc, db: db)
            guard ![".", ".."].contains(rawName.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw StructureEditError.invalidName }
            let stored = FileNames.stored(rawName, kind: doc.kind)
            guard FileNames.isValidStoredName(stored) else { throw StructureEditError.invalidName }
            if stored == doc.name { return doc }
            guard !doc.parentId.isEmpty else { throw StructureEditError.rootProtected }
            try requireAvailableName(stored, parentId: doc.parentId, excluding: id, db: db)
            doc.name = stored
            _ = try saveDocument(doc, enqueue: true, expectedGeneration: doc.localGeneration, db: db)
            return try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
        }
    }

    /// Content save that keeps the current stored file name (avoids stale editor snapshots).
    @discardableResult
    public func updateMarkdown(id: String, markdown: String) throws -> LibraryDocument? {
        try db.write { db in
            guard var doc = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc) else { return nil }
            try requireEditableStructure(doc, db: db)
            guard doc.kind == .md else { throw EditorEditError.wrongDocumentKind }
            if doc.markdown == markdown { return doc }
            doc.markdown = markdown
            _ = try saveDocument(doc, enqueue: true, expectedGeneration: doc.localGeneration, db: db)
            return try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
        }
    }

    @discardableResult
    public func appendAnnotations(id: String, extra: [PDFTextAnnotation]) throws -> LibraryDocument? {
        try db.write { db in
            guard var doc = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc) else { return nil }
            try requireEditableStructure(doc, db: db)
            guard doc.kind == .pdf else { throw EditorEditError.wrongDocumentKind }
            var current = try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(doc.annotationsJSON.utf8))
            current.append(contentsOf: extra)
            doc.annotationsJSON = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
            _ = try saveDocument(doc, enqueue: true, expectedGeneration: doc.localGeneration, db: db)
            return try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
        }
    }

    public static func syncAction(kind: DocKind, revision: Int64) -> String {
        if revision > 0 { return "updateDocument" }
        switch kind {
        case .folder: return "createFolder"
        case .md: return "createMarkdown"
        case .pdf: return "createPDF"
        }
    }

    /// `includeBodies` false leaves markdown empty. The shelf uses that so thousands of
    /// notes are not copied into the interface on every refresh; open a note to read its text.
    public func listDocuments(includeTrashed: Bool = false, includeBodies: Bool = true) throws -> [LibraryDocument] {
        try db.read { db in
            let markdown = includeBodies ? "markdown" : "'' AS markdown"
            let whereState = includeTrashed ? "" : "WHERE state='active' "
            let sql = """
                SELECT id,kind,parent_id,name,\(markdown),pdf_path,revision,local_generation,state,purge_at,status,annotations_json,metadata_json,assets_json,pdf_blob_id
                FROM working_documents \(whereState)ORDER BY CASE kind WHEN 'folder' THEN 0 ELSE 1 END, name COLLATE NOCASE
                """
            return try Row.fetchAll(db, sql: sql).map(mapDoc)
        }
    }

    /// Changes when a row, its file path, or the queue changes. The shelf skips redraws when this is unchanged.
    public func libraryRevisionStamp() throws -> String {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n,
                       COALESCE(MAX(updated_at),'') AS updated,
                       COALESCE(SUM(LENGTH(IFNULL(pdf_path,''))),0) AS paths,
                       (SELECT COUNT(*) FROM pending_operations WHERE state IN ('pending','awaiting_remote','needs_edit','conflict')) AS pending,
                       (SELECT COUNT(*) FROM sync_conflicts WHERE state='open' OR state LIKE 'resolving:%') AS conflicts
                FROM working_documents
                """) else { return "0" }
            let count: Int64 = row["n"]
            let updated: String = row["updated"]
            let paths: Int64 = row["paths"]
            let pending: Int64 = row["pending"]
            let conflicts: Int64 = row["conflicts"]
            return "\(count)|\(updated)|\(paths)|\(pending)|\(conflicts)"
        }
    }

    public func loadDocument(id: String) throws -> LibraryDocument? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc)
        }
    }

    public func trash(id: String) throws {
        try db.write { db in
            guard let targetRow = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]) else { throw StoreError.notFound }
            let target = mapDoc(targetRow)
            if target.isCatalogTopic {
                // Topics collect references. Older clients may also have placed real files inside
                // the underlying folder; deleting a topic must preserve these files and descendants.
                guard !target.parentId.isEmpty else { throw StoreError.notFound }
                let children = try Row.fetchAll(db, sql: "SELECT * FROM working_documents WHERE parent_id=? AND state='active' ORDER BY id", arguments: [id]).map(mapDoc)
                var occupied = Set(try String.fetchAll(db, sql: "SELECT name FROM working_documents WHERE parent_id=? AND state='active'", arguments: [target.parentId]).map(FileNames.comparisonKey))
                for var child in children {
                    child.parentId = target.parentId
                    var base = FileNames.editingBase(child.name, kind: child.kind)
                    var suffix = 1
                    while occupied.contains(FileNames.comparisonKey(child.name)) {
                        child.name = FileNames.stored("\(base)_\(suffix)", kind: child.kind)
                        while child.name.utf8.count > 240 && !base.isEmpty {
                            base.removeLast()
                            child.name = FileNames.stored("\(base)_\(suffix)", kind: child.kind)
                        }
                        suffix += 1
                    }
                    occupied.insert(FileNames.comparisonKey(child.name))
                    _ = try saveDocument(child, enqueue: true, expectedGeneration: nil, db: db)
                }
            }
            let purge = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
            let batch = UUID().uuidString.lowercased()
            try db.execute(sql: """
                WITH RECURSIVE subtree(id) AS (SELECT id FROM working_documents WHERE id=? UNION SELECT d.id FROM working_documents d JOIN subtree s ON d.parent_id=s.id)
                UPDATE working_documents SET state='trashed', status=?, purge_at=?, trash_batch_id=?, local_generation=local_generation+1 WHERE id IN (SELECT id FROM subtree) AND state='active'
                """, arguments: [id,SyncStatus.pending.rawValue,iso(purge),batch])
            try db.execute(
                sql: "INSERT INTO pending_operations(operation_id, action, object_id, payload, state, created_at) VALUES (?,?,?,?,?,?)",
                arguments: [UUID().uuidString.lowercased(), "trash", id, "{}", "pending", iso(Date())]
            )
        }
    }

    public func restore(id: String) throws {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]) else { throw StoreError.notFound }
            let selected = mapDoc(row)
            if selected.state == "active" { return }
            guard selected.state == "trashed", selected.purgeAt.map({ $0 > Date() }) ?? true else { throw StructureEditError.unavailableDocument }
            guard !selected.parentId.isEmpty else { throw StructureEditError.rootProtected }
            let all = try Row.fetchAll(db, sql: "SELECT * FROM working_documents").map(mapDoc)
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let roots = try trustedVirtualRootIDs(db: db)
            let resolved = try hierarchyRootID(for: id, documents: all, db: db)
            // A bound workspace supplies the missing root identity after a
            // parent has been purged. An unbound mixed old library cannot guess.
            let bound = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key='rootId'")
            guard let root = resolved ?? bound, roots.contains(root) else { throw StructureEditError.invalidFolder }
            let tombstones = Set(try String.fetchAll(db, sql: "SELECT id FROM remote_tombstones"))
            func activeFolder(_ id: String) -> Bool {
                var cursor = id, visited = Set<String>()
                while visited.insert(cursor).inserted {
                    guard !tombstones.contains(cursor) else { return false }
                    guard let folder = byID[cursor] else { return cursor == root }
                    guard folder.kind == .folder, folder.state == "active", !folder.isCatalogTopic else { return false }
                    if folder.parentId.isEmpty { return cursor == root }
                    cursor = folder.parentId
                }
                return false
            }
            let parent = activeFolder(selected.parentId) ? selected.parentId : root
            guard activeFolder(parent) else { throw StructureEditError.invalidFolder }
            let batch: String? = row["trash_batch_id"]
            var restoring = [selected]
            if selected.kind == .folder, let batch {
                let matching = try Row.fetchAll(db, sql: "SELECT * FROM working_documents WHERE state='trashed' AND trash_batch_id=? ORDER BY id", arguments: [batch]).map(mapDoc)
                var visited: Set<String> = [id], index = 0
                while index < restoring.count {
                    let folder = restoring[index]; index += 1
                    guard folder.kind == .folder else { continue }
                    for child in matching where child.parentId == folder.id && visited.insert(child.id).inserted { restoring.append(child) }
                }
            }
            let occupied = Set(all.filter { $0.parentId == parent && $0.state == "active" }.map { FileNames.comparisonKey($0.name) })
            let name = FileNames.availableName(selected.name, kind: selected.kind, takenKeys: occupied)
            for document in restoring {
                guard FileNames.isValidStoredName(document.name) else { throw StructureEditError.invalidName }
                try db.execute(sql: "UPDATE working_documents SET state='active', parent_id=?, name=?, purge_at=NULL, status=?, trash_batch_id=NULL, local_generation=local_generation+1 WHERE id=?",
                    arguments: [document.id == id ? parent : document.parentId, document.id == id ? name : document.name, SyncStatus.pending.rawValue, document.id])
            }
            let payload = try JSONValue.object(["parentId": .string(parent), "name": .string(name)]).jsonString()
            try db.execute(
                sql: "INSERT INTO pending_operations(operation_id, action, object_id, payload, state, created_at) VALUES (?,?,?,?,?,?)",
                arguments: [UUID().uuidString.lowercased(), "restore", id, payload, "pending", iso(Date())]
            )
        }
    }

    public func purgeExpired(now: Date = Date()) throws -> Int {
        try db.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, purge_at FROM working_documents WHERE state='trashed'")
            var n = 0
            for row in rows {
                guard let s: String = row["purge_at"], let d = parseISO(s), d <= now else { continue }
                let id: String = row["id"]
                try db.execute(sql: "DELETE FROM search_fts WHERE object_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM search_chunks WHERE object_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM search_index_state WHERE object_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM working_documents WHERE id=?", arguments: [id])
                n += 1
            }
            return n
        }
    }

    /// Keeps the newest acknowledged request for each document and drops the older copies.
    public func pruneAcknowledgedOperations() throws {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM pending_operations
                WHERE state='sent' AND rowid NOT IN (
                    SELECT MAX(rowid) FROM pending_operations WHERE state='sent' GROUP BY object_id
                )
                """)
        }
    }

    public func pending() throws -> [PendingOperation] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_operations WHERE state IN ('pending','awaiting_remote','needs_edit') ORDER BY rowid").map(mapOperation)
        }
    }

    /// Uses the persisted parent chain, including trashed objects. Missing parents and cycles are outside the root.
    public func belongsToRoot(objectId: String, rootId: String) throws -> Bool {
        guard !rootId.isEmpty else { return false }
        return try db.read { db in
            var current = objectId
            var visited = Set<String>()
            while visited.insert(current).inserted {
                if current == rootId { return true }
                guard let parent = try String.fetchOne(db, sql: "SELECT parent_id FROM working_documents WHERE id=?", arguments: [current]) else { return false }
                current = parent
            }
            return false
        }
    }

    /// Freezes the entire wire envelope before the first network attempt. A retry after restart uses these exact bytes.
    /// Returns nil while an earlier operation on this object is pending or unresolved.
    public func prepareOperation(_ operationId: String, epoch: String, deviceId: String, serverOrigin: String) throws -> PendingOperation? {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT rowid AS queue_order, * FROM pending_operations WHERE operation_id=? AND state IN ('pending','awaiting_remote','needs_edit')", arguments: [operationId]) else { return nil }
            if (row["state"] as String) == "awaiting_remote" { throw SyncFailure.remoteStateRequired }
            if (row["state"] as String) == "needs_edit" { throw StoreError.staleOperation }
            let objectId: String = row["object_id"]
            let order: Int64 = row["queue_order"]
            let earlier = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND rowid<? AND state IN ('pending','awaiting_remote','needs_edit','conflict')", arguments: [objectId, order]) ?? 0
            guard earlier == 0 else { return nil }
            if let wire: String = row["request_json"] {
                guard let json = try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any],
                      json["epoch"] as? String == epoch, json["deviceId"] as? String == deviceId,
                      (row["request_origin"] as String?) == serverOrigin else {
                    throw StoreError.operationContextChanged
                }
                return mapOperation(row)
            }
            guard let document = try Row.fetchOne(db, sql: "SELECT revision, local_generation FROM working_documents WHERE id=?", arguments: [objectId]) else { throw StoreError.notFound }
            let revision: Int64 = document["revision"]
            let generation: Int64 = document["local_generation"]
            let payload: String = row["payload"]
            guard let desired = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw SyncFailure.invalidResponse }
            var action: String = row["action"]
            if revision > 0 && ["createFolder", "createMarkdown", "createPDF", "updateDocument", "rename", "move"].contains(action) {
                // The last acknowledged request is the known cloud baseline. In particular a move while
                // creation was in flight must become `move`: updateDocument does not apply parentId.
                let lastWire = try String.fetchOne(db, sql: "SELECT request_json FROM pending_operations WHERE object_id=? AND state='sent' AND request_json IS NOT NULL AND action IN ('createFolder','createMarkdown','createPDF','updateDocument','rename','move') ORDER BY rowid DESC LIMIT 1", arguments: [objectId])
                if let lastWire,
                   let previous = try JSONSerialization.jsonObject(with: Data(lastWire.utf8)) as? [String: Any],
                   let previousDesired = previous["desiredSnapshot"] as? [String: Any] {
                    if let parent = desired["parentId"] as? String, parent != previousDesired["parentId"] as? String { action = "move" }
                    else if let name = desired["name"] as? String, name != previousDesired["name"] as? String { action = "rename" }
                    else { action = "updateDocument" }
                } else if ["createFolder", "createMarkdown", "createPDF"].contains(action) {
                    action = "updateDocument"
                }
            }
            let base: Int64? = ["updateDocument", "rename", "move"].contains(action) ? revision : nil
            var envelope: [String: Any] = ["protocolVersion": 1, "operationId": operationId, "epoch": epoch,
                                           "deviceId": deviceId, "objectId": objectId, "action": action, "desiredSnapshot": desired]
            if let base { envelope["base"] = ["source": "revision", "revision": base] }
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys), as: UTF8.self)
            try db.execute(sql: "UPDATE pending_operations SET action=?, base_revision=?, request_json=?, request_origin=?, frozen_generation=? WHERE operation_id=?",
                           arguments: [action, base, wire, serverOrigin, generation, operationId])
            guard let frozen = try Row.fetchOne(db, sql: "SELECT * FROM pending_operations WHERE operation_id=?", arguments: [operationId]) else { throw StoreError.notFound }
            return mapOperation(frozen)
        }
    }

    /// Keep a frozen request visible and durable, but do not send it again until a future pull workflow reconciles it.
    public func pauseForRemoteFetch(_ operation: PendingOperation) throws {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_operations WHERE operation_id=? AND state='pending'", arguments: [operation.operationId]) else { return }
            guard (row["payload"] as String) == operation.payload, (row["request_json"] as String?) == operation.requestJSON else { throw StoreError.staleOperation }
            try db.execute(sql: "UPDATE pending_operations SET state='awaiting_remote' WHERE operation_id=?", arguments: [operation.operationId])
            try db.execute(sql: "UPDATE working_documents SET status=? WHERE id=? AND status<>?", arguments: [SyncStatus.pending.rawValue, operation.objectId, SyncStatus.conflict.rawValue])
        }
    }

    /// Acknowledge this request atomically without clearing later edits or overwriting the local document body.
    public func acknowledge(_ operation: PendingOperation, revision: Int64, conflict: Bool) throws {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_operations WHERE operation_id=?", arguments: [operation.operationId]),
                  (row["state"] as String) == "pending" else { return }
            guard (row["object_id"] as String) == operation.objectId,
                  (row["payload"] as String) == operation.payload,
                  (row["action"] as String) == operation.action,
                  (row["request_json"] as String?) == operation.requestJSON else { throw StoreError.staleOperation }
            try db.execute(sql: "UPDATE pending_operations SET state=? WHERE operation_id=?", arguments: [conflict ? "conflict" : "sent", operation.operationId])
            let unresolved = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND state='conflict'", arguments: [operation.objectId]) ?? 0
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND state IN ('pending','awaiting_remote','needs_edit')", arguments: [operation.objectId]) ?? 0
            let currentGeneration = try Int64.fetchOne(db, sql: "SELECT local_generation FROM working_documents WHERE id=?", arguments: [operation.objectId]) ?? 0
            let status: SyncStatus = unresolved > 0 ? .conflict : pending > 0 ? .pending
                : (operation.frozenGeneration.map({ currentGeneration > $0 }) ?? false) ? .savedLocal : .synced
            try db.execute(sql: "UPDATE working_documents SET status=?, revision=MAX(revision,?) WHERE id=?", arguments: [status.rawValue, revision, operation.objectId])
        }
    }

    private func mapOperation(_ row: Row) -> PendingOperation {
        PendingOperation(operationId: row["operation_id"], action: row["action"], objectId: row["object_id"],
                         payload: row["payload"], state: row["state"], baseRevision: row["base_revision"],
                         requestJSON: row["request_json"], requestOrigin: row["request_origin"], frozenGeneration: row["frozen_generation"])
    }

    public func markConflict(id: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE working_documents SET status=? WHERE id=?", arguments: [SyncStatus.conflict.rawValue, id])
        }
    }

    public func isFullySynced(id: String) throws -> Bool {
        try db.read { db in
            let status: String = try Row.fetchOne(db, sql: "SELECT status FROM working_documents WHERE id=?", arguments: [id])?["status"] ?? ""
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_operations WHERE object_id=? AND state IN ('pending','awaiting_remote','needs_edit')", arguments: [id]) ?? 0
            return status == SyncStatus.synced.rawValue && pending == 0
        }
    }

    public func search(query: String) throws -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var toks = SearchTokenizer.tokens(in: q)
        if toks.isEmpty { toks = [q.lowercased()] }
        let expression = toks.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT search_fts.object_id FROM search_fts JOIN working_documents d ON d.id=search_fts.object_id WHERE search_fts MATCH ? AND d.state='active' ORDER BY search_fts.rank", arguments: [expression])
        }
    }

    public func exportMarkdown(id: String) throws -> Data {
        guard let doc = try loadDocument(id: id) else { throw StoreError.notFound }
        return Data(doc.markdown.utf8)
    }

    public func localSaveOffline(markdown: String, id: String, name: String, parentId: String) throws {
        var doc = try loadDocument(id: id) ?? LibraryDocument(
            id: id, kind: .md, parentId: parentId, name: name, markdown: "", pdfPath: nil,
            revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]"
        )
        doc.markdown = markdown
        doc.name = name
        doc.status = .savedLocal
        try saveDocument(doc, enqueue: true)
    }

    public func markPending(_ opId: String, state: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE pending_operations SET state=? WHERE operation_id=?", arguments: [state, opId])
        }
    }

    public func markSynced(id: String, revision: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE working_documents SET status=?, revision=? WHERE id=?",
                           arguments: [SyncStatus.synced.rawValue, revision, id])
        }
    }

    private func ensurePDFTextCacheReferences(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pdf_page_text_cache_refs (
                object_id TEXT PRIMARY KEY REFERENCES working_documents(id) ON DELETE CASCADE,
                identity TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pdf_page_text_cache_refs_identity ON pdf_page_text_cache_refs(identity);
            CREATE TRIGGER IF NOT EXISTS pdf_page_text_cache_unref_delete AFTER DELETE ON pdf_page_text_cache_refs BEGIN
                DELETE FROM pdf_page_text_cache WHERE identity=OLD.identity
                    AND NOT EXISTS(SELECT 1 FROM pdf_page_text_cache_refs WHERE identity=OLD.identity);
            END;
            CREATE TRIGGER IF NOT EXISTS pdf_page_text_cache_unref_update AFTER UPDATE OF identity ON pdf_page_text_cache_refs
                WHEN OLD.identity != NEW.identity BEGIN
                DELETE FROM pdf_page_text_cache WHERE identity=OLD.identity
                    AND NOT EXISTS(SELECT 1 FROM pdf_page_text_cache_refs WHERE identity=OLD.identity);
            END;
            """)
    }

    func reindex(_ doc: LibraryDocument, db: Database, verifyExistingChunks: Bool = false) throws {
        let metadata = doc.name + "\n" + doc.markdown + "\n" + doc.catalog.searchText
        var pdfURL: URL?, pdfIdentity: String?, pdfByteCount: Int64 = 0
        if doc.kind == .pdf, let path = doc.pdfPath {
            let originalURL = URL(fileURLWithPath: path).standardizedFileURL
            let verifiedURL = try? resolveAttachment(path: path)
            let url = verifiedURL ?? originalURL
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                pdfByteCount = size
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let rootPrefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                let location: String
                if let verifiedURL, verifiedURL.path.hasPrefix(rootPrefix) {
                    location = "relative:" + String(verifiedURL.path.dropFirst(rootPrefix.count))
                } else {
                    // Legacy external originals retain their absolute identity;
                    // only validated library-owned paths survive container moves.
                    location = "absolute:" + url.resolvingSymlinksInPath().path
                }
                pdfURL = url
                let identityParts = [location, doc.pdfBlobId ?? "", String(size), String(modified)]
                pdfIdentity = "pdf-text-v2:" + BlobIntegrity.sha256(try JSONEncoder().encode(identityParts))
            }
        }
        // Most reading-position saves stop here: no page-cache decoding, PDF IO or FTS writes.
        // Files already indexed are reused from the page cache. A large PDF that has
        // never been indexed stays on disk; reading it would build the page text in memory.
        let pdfTextIsCached: Bool
        if let pdfIdentity {
            pdfTextIsCached = try Int.fetchOne(db, sql: "SELECT 1 FROM pdf_page_text_cache WHERE identity=?", arguments: [pdfIdentity]) != nil
        } else {
            pdfTextIsCached = false
        }
        let indexPDFText = pdfIdentity != nil && (pdfTextIsCached || pdfByteCount <= 8_000_000)
        let signature = BlobIntegrity.sha256(Data((doc.kind.rawValue + "\n" + metadata + "\n" + (indexPDFText ? (pdfIdentity ?? "") : "")).utf8))
        if try String.fetchOne(db, sql: "SELECT signature FROM search_index_state WHERE object_id=?", arguments: [doc.id]) == signature {
            if !verifyExistingChunks { return }
            // A legacy open may have dropped PDF rows while the absolute path
            // was unavailable. Relocation checks completeness without reading
            // the PDF or rewriting an already complete search index.
            var expectedSources = Set(["metadata"])
            var completeCache = true
            if let pdfIdentity {
                if let cached = try String.fetchOne(db, sql: "SELECT pages_json FROM pdf_page_text_cache WHERE identity=?", arguments: [pdfIdentity]),
                   let pages = try? JSONDecoder().decode([String].self, from: Data(cached.utf8)) {
                    expectedSources.formUnion(pages.indices.map { "pdf:\($0)" })
                } else { completeCache = false }
            }
            let chunks = try String.fetchAll(db, sql: "SELECT source FROM search_chunks WHERE object_id=?", arguments: [doc.id])
            let indexed = try String.fetchAll(db, sql: "SELECT source FROM search_fts WHERE object_id=?", arguments: [doc.id])
            if completeCache, chunks.count == expectedSources.count, indexed.count == expectedSources.count,
               Set(chunks) == expectedSources, Set(indexed) == expectedSources { return }
        }
        var chunks: [(source: String, text: String)] = [("metadata", metadata)]
        var cachedPDFIdentity: String?
        if indexPDFText, let url = pdfURL, let identity = pdfIdentity {
            let pages: [String]
            if let cached = try String.fetchOne(db, sql: "SELECT pages_json FROM pdf_page_text_cache WHERE identity=?", arguments: [identity]),
               let decoded = try? JSONDecoder().decode([String].self, from: Data(cached.utf8)) {
                pages = decoded; cachedPDFIdentity = identity
            }
            else if pdfByteCount <= 8_000_000, let data = try? Data(contentsOf: url) {
                pages = pdfPageTextExtractor(data)
                let encoded = String(decoding: try JSONEncoder().encode(pages), as: UTF8.self)
                try db.execute(sql: "INSERT OR REPLACE INTO pdf_page_text_cache(identity,pages_json) VALUES (?,?)", arguments: [identity,encoded])
                cachedPDFIdentity = identity
            } else { pages = [] }
            chunks += pages.enumerated().map { ("pdf:\($0.offset)", $0.element) }
        }
        if let cachedPDFIdentity {
            try db.execute(sql: "INSERT INTO pdf_page_text_cache_refs(object_id,identity) VALUES (?,?) ON CONFLICT(object_id) DO UPDATE SET identity=excluded.identity", arguments: [doc.id,cachedPDFIdentity])
        } else {
            try db.execute(sql: "DELETE FROM pdf_page_text_cache_refs WHERE object_id=?", arguments: [doc.id])
        }
        try db.execute(sql: "DELETE FROM search_fts WHERE object_id=?", arguments: [doc.id])
        try db.execute(sql: "DELETE FROM search_chunks WHERE object_id=?", arguments: [doc.id])
        for chunk in chunks {
            let searchable = chunk.text + (chunk.source.hasPrefix("pdf:") ? "\n" + metadata : "")
            let tokens = SearchTokenizer.indexTokens(in: searchable).joined(separator: " ")
            let indexed = searchable + "\n" + tokens
            try db.execute(sql: "INSERT INTO search_chunks(object_id,source,text) VALUES (?,?,?)", arguments: [doc.id,chunk.source,chunk.text])
            try db.execute(sql: "INSERT INTO search_fts(object_id,source,text) VALUES (?,?,?)", arguments: [doc.id,chunk.source,indexed])
        }
        try db.execute(sql: "INSERT OR REPLACE INTO search_index_state(object_id,signature) VALUES (?,?)", arguments: [doc.id,signature])
    }

    func mapDoc(_ row: Row) -> LibraryDocument {
        LibraryDocument(
            id: row["id"], kind: DocKind(rawValue: row["kind"]) ?? .md, parentId: row["parent_id"],
            name: row["name"], markdown: row["markdown"], pdfPath: row["pdf_path"],
            revision: row["revision"], localGeneration: row["local_generation"], state: row["state"],
            purgeAt: (row["purge_at"] as String?).flatMap(parseISO),
            status: SyncStatus(rawValue: row["status"]) ?? .savedLocal,
            annotationsJSON: row["annotations_json"], metadataJSON: row["metadata_json"], assetsJSON: row["assets_json"], pdfBlobId: row["pdf_blob_id"]
        )
    }

    func encodePayload(_ doc: LibraryDocument) -> String {
        (try? JSONValue.object(doc.syncSnapshot).jsonString()) ?? "{}"
    }
}

public enum StoreError: Error { case notFound, operationContextChanged, staleOperation }

private func iso(_ d: Date) -> String {
    ISO8601DateFormatter().string(from: d)
}
private func parseISO(_ s: String) -> Date? {
    ISO8601DateFormatter().date(from: s)
}
