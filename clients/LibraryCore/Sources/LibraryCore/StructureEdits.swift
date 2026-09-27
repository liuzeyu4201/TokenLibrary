import Foundation
import GRDB

public enum StructureEditError: LocalizedError, Sendable {
    case invalidName, duplicateName, duplicateID, unavailableDocument, invalidFolder, crossLibrary, cycle, rootProtected, topicDestination
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "名称无效：请勿使用路径分隔符、控制字符、单独的点，名称连同扩展名不能超过 240 字节。"
        case .duplicateName: return "目标文件夹中已有同名资料（名称不区分大小写），请换一个名称。"
        case .duplicateID: return "资料标识已存在，未覆盖原资料。请重试创建。"
        case .unavailableDocument: return "资料已移到回收站或被删除，请先恢复或保存副本。"
        case .invalidFolder: return "目标文件夹已删除或目录结构不完整，请选择其他位置。"
        case .crossLibrary: return "不能直接移动到其他资料库，请使用资料库迁入或导出功能。"
        case .cycle: return "不能把文件夹移动到自身或其子文件夹中。"
        case .rootProtected: return "资料库根目录不能改名或移动。"
        case .topicDestination: return "专题通过关联收集资料，请使用“加入专题”，不要把文件移动到专题中。"
        }
    }
}

extension DocumentStore {
    /// Validates against the current hierarchy and claims the name in the same
    /// transaction as insertion, so a stale UI cannot create an orphan or replace
    /// a document that arrived through synchronization in the meantime.
    @discardableResult
    public func createDocument(_ document: LibraryDocument, deduplicateName: Bool = true) throws -> LibraryDocument {
        try db.write { db in try createDocument(document, deduplicateName: deduplicateName, db: db) }
    }

    func createDocument(_ document: LibraryDocument, deduplicateName: Bool, db: Database) throws -> LibraryDocument {
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM working_documents WHERE id=? UNION ALL SELECT 1 FROM remote_tombstones WHERE id=? UNION ALL SELECT 1 FROM remote_documents WHERE id=? UNION ALL SELECT 1 FROM pending_operations WHERE object_id=?)", arguments: [document.id, document.id, document.id, document.id]) ?? false
            guard !document.id.isEmpty, !exists
            else { throw StructureEditError.duplicateID }
            let all = try Row.fetchAll(db, sql: "SELECT * FROM working_documents").map(mapDoc)
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let virtualRoots = try trustedVirtualRootIDs(db: db)
            guard !virtualRoots.contains(document.id) else { throw StructureEditError.rootProtected }
            guard document.parentId != document.id else { throw StructureEditError.cycle }
            guard let targetRoot = try hierarchyRootID(for: document.parentId, documents: all, db: db) else { throw StructureEditError.invalidFolder }
            guard virtualRoots.contains(targetRoot) else { throw StructureEditError.crossLibrary }
            var cursor = document.parentId, visited = Set<String>()
            while visited.insert(cursor).inserted {
                guard let parent = byID[cursor] else {
                    guard virtualRoots.contains(cursor) else { throw StructureEditError.invalidFolder }
                    break
                }
                guard parent.kind == .folder, parent.state == "active" else { throw StructureEditError.invalidFolder }
                guard !parent.isCatalogTopic else { throw StructureEditError.topicDestination }
                guard !(try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM remote_tombstones WHERE id=?)", arguments: [parent.id]) ?? false) else { throw StructureEditError.invalidFolder }
                if parent.parentId.isEmpty { break }
                cursor = parent.parentId
            }
            guard ![".", ".."].contains(document.name.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw StructureEditError.invalidName }
            var result = document
            result.name = FileNames.stored(document.name, kind: document.kind)
            guard FileNames.isValidStoredName(result.name) else { throw StructureEditError.invalidName }
            let names = Set(all.filter { $0.parentId == document.parentId && $0.state == "active" }.map { FileNames.comparisonKey($0.name) })
            if names.contains(FileNames.comparisonKey(result.name)) {
                guard deduplicateName else { throw StructureEditError.duplicateName }
                result.name = FileNames.availableName(result.name, kind: result.kind, takenKeys: names)
            }
            result.revision = 0; result.localGeneration = 0; result.state = "active"; result.purgeAt = nil; result.status = .pending
            _ = try saveDocument(result, enqueue: true, expectedGeneration: nil, db: db)
            return try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [result.id]).map(mapDoc) ?? result
    }

    /// Structural mutations always derive from the current complete document,
    /// inside the write transaction, so they cannot restore stale editor bodies.
    @discardableResult
    public func moveDocument(id: String, to parentId: String) throws -> LibraryDocument {
        try db.write { db in
            guard var doc = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc) else { throw StoreError.notFound }
            try requireEditableStructure(doc, db: db)
            guard !doc.parentId.isEmpty else { throw StructureEditError.rootProtected }
            guard id != parentId else { throw StructureEditError.cycle }
            let all = try Row.fetchAll(db, sql: "SELECT * FROM working_documents").map(mapDoc)
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            if let target = byID[parentId] {
                guard target.kind == .folder, target.state == "active" else { throw StructureEditError.invalidFolder }
                guard !target.isCatalogTopic else { throw StructureEditError.topicDestination }
            } else if !(try trustedVirtualRootIDs(db: db)).contains(parentId) { throw StructureEditError.invalidFolder }
            guard let sourceRoot = try hierarchyRootID(for: id, documents: all, db: db),
                  let targetRoot = try hierarchyRootID(for: parentId, documents: all, db: db) else { throw StructureEditError.invalidFolder }
            guard sourceRoot == targetRoot else { throw StructureEditError.crossLibrary }
            var cursor = parentId, seen = Set<String>()
            while seen.insert(cursor).inserted {
                guard cursor != id else { throw StructureEditError.cycle }
                guard let ancestor = byID[cursor] else { break }
                guard ancestor.state == "active" else { throw StructureEditError.invalidFolder }
                if ancestor.parentId.isEmpty { break }
                cursor = ancestor.parentId
            }
            if doc.parentId == parentId { return doc }
            guard FileNames.isValidStoredName(doc.name) else { throw StructureEditError.invalidName }
            try requireAvailableName(doc.name, parentId: parentId, excluding: id, db: db)
            doc.parentId = parentId
            _ = try saveDocument(doc, enqueue: true, expectedGeneration: doc.localGeneration, db: db)
            return try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [id]).map(mapDoc) ?? doc
        }
    }

    func requireEditableStructure(_ doc: LibraryDocument, db: Database) throws {
        guard doc.state == "active",
              !(try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM remote_tombstones WHERE id=?)", arguments: [doc.id]) ?? false)
        else { throw StructureEditError.unavailableDocument }
    }

    /// A missing server root can be valid before initial bootstrap only when
    /// its ID came from the bound, authenticated workspace, never from a guess
    /// based on an arbitrary missing parent in legacy data.
    func trustedVirtualRootID(db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key='rootId'") ?? "root"
    }

    func hierarchyRootID(for id: String, documents: [LibraryDocument], db: Database) throws -> String? {
        for root in try trustedVirtualRootIDs(db: db).sorted() {
            if let resolved = LibraryHierarchy.rootID(for: id, documents: documents, localRootID: root) { return resolved }
        }
        return nil
    }

    func requireAvailableName(_ name: String, parentId: String, excluding id: String, db: Database) throws {
        let key = FileNames.comparisonKey(name)
        let names = try String.fetchAll(db, sql: "SELECT name FROM working_documents WHERE parent_id=? AND state='active' AND id<>?", arguments: [parentId,id])
        guard !names.contains(where: { FileNames.comparisonKey($0) == key }) else { throw StructureEditError.duplicateName }
    }
}
