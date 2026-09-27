import Foundation
import GRDB

public struct LegacyLibraryInventory: Sendable, Equatable {
    public let rootIDs: [String]
    public let rootsByDocumentID: [String: String]
    public let unresolvedDocumentIDs: [String]

    public func rootID(for id: String) -> String? {
        rootsByDocumentID[id] ?? (rootIDs.contains(id) ? id : nil)
    }
}

public enum LegacyLibraryRootError: LocalizedError, Sendable {
    case invalidIdentity, identityConflict
    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "旧资料库的根目录记录无效，资料已保留，请通过已保存的连接信息恢复。"
        case .identityConflict: return "旧资料库的根目录与已保存的资料库身份不一致，未更改原资料或待同步操作。"
        }
    }
}

private struct LegacyRootRecord: Codable, Equatable {
    let version: Int
    let rootID: String
    let server: String?
    let libraryID: String?
}

extension DocumentStore {
    private static let legacyRootPrefix = "legacy.root."

    /// Compatibility input must come from the old installation's persisted login
    /// root (for example connection.rootId), never from a document's missing parent.
    /// This records recovery provenance only; it does not bind a server, create a
    /// synthetic root document, rewrite source material, or change its pending queue.
    public func registerLegacyLibraryRoot(rootID: String, server: String? = nil, libraryID: String? = nil) throws {
        guard UUID(uuidString: rootID) != nil else { throw LegacyLibraryRootError.invalidIdentity }
        let origin: String?
        do { origin = try server.map { try ServerAddress.normalize($0).absoluteString } }
        catch { throw LegacyLibraryRootError.invalidIdentity }
        guard libraryID?.isEmpty != true else { throw LegacyLibraryRootError.invalidIdentity }
        try db.write { db in
            let bindings = try rootBindings(db: db)
            if let boundRoot = bindings["rootId"], boundRoot != rootID { throw LegacyLibraryRootError.identityConflict }
            if let boundServer = bindings["server"] {
                let normalized = try? ServerAddress.normalize(boundServer).absoluteString
                guard let normalized, origin == normalized || (origin == nil && bindings["rootId"] == rootID)
                else { throw LegacyLibraryRootError.identityConflict }
            }
            if let boundLibrary = bindings["libraryId"] {
                guard libraryID == boundLibrary || (libraryID == nil && bindings["rootId"] == rootID)
                else { throw LegacyLibraryRootError.identityConflict }
            }
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [rootID]).map(mapDoc) {
                guard existing.kind == .folder, existing.parentId.isEmpty, existing.state == "active", !existing.isCatalogTopic
                else { throw LegacyLibraryRootError.invalidIdentity }
            }
            guard !(try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM remote_tombstones WHERE id=?)", arguments: [rootID]) ?? false)
            else { throw LegacyLibraryRootError.invalidIdentity }
            let key = Self.legacyRootPrefix + rootID
            let record = LegacyRootRecord(version: 1, rootID: rootID, server: origin, libraryID: libraryID)
            if let previous = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key=?", arguments: [key]) {
                guard let old = try? JSONDecoder().decode(LegacyRootRecord.self, from: Data(previous.utf8)), old.version == 1, old.rootID == rootID,
                      old.server == nil || origin == nil || old.server == origin,
                      old.libraryID == nil || libraryID == nil || old.libraryID == libraryID else { throw LegacyLibraryRootError.identityConflict }
                // Keep the first identity evidence, enriching only missing context.
                let merged = LegacyRootRecord(version: 1, rootID: rootID, server: old.server ?? origin, libraryID: old.libraryID ?? libraryID)
                guard merged != old else { return }
                try db.execute(sql: "UPDATE sync_state SET value=? WHERE key=?", arguments: [String(decoding: try JSONEncoder().encode(merged), as: UTF8.self), key])
            } else {
                try db.execute(sql: "INSERT INTO sync_state(key,value) VALUES (?,?)", arguments: [key, String(decoding: try JSONEncoder().encode(record), as: UTF8.self)])
            }
        }
    }

    /// One consistent snapshot for local navigation and explicit copy. Unresolved
    /// chains stay listed separately; they are never silently promoted to roots.
    public func legacyLibraryInventory() throws -> LegacyLibraryInventory {
        try db.read { db in
            let documents = try Row.fetchAll(db, sql: "SELECT id,kind,parent_id,name,'' AS markdown,pdf_path,revision,local_generation,state,purge_at,status,annotations_json,metadata_json,assets_json,pdf_blob_id FROM working_documents WHERE state<>'purged'").map(mapDoc)
            let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
            var roots = try registeredLegacyRootIDs(db: db)
            roots.insert("root")
            if let bound = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key='rootId'"), !bound.isEmpty { roots.insert(bound) }
            for document in documents where document.kind == .folder && document.parentId.isEmpty && !document.isCatalogTopic { roots.insert(document.id) }
            roots = roots.filter { id in
                guard let document = byID[id] else { return !id.isEmpty }
                return document.kind == .folder && document.parentId.isEmpty && !document.isCatalogTopic
            }
            let tombstones = Set(try String.fetchAll(db, sql: "SELECT id FROM remote_tombstones"))
            roots.subtract(tombstones)
            var resolved = Dictionary(uniqueKeysWithValues: roots.map { ($0, $0) })
            var unresolved = Set<String>()
            for start in documents.map(\.id) {
                var cursor = start, chain: [String] = [], visited = Set<String>(), root: String?
                while visited.insert(cursor).inserted {
                    // A cached root for a Markdown/PDF does not make that file a
                    // valid parent for another object in a corrupt old database.
                    if cursor != start, let parent = byID[cursor], parent.kind != .folder { break }
                    if let known = resolved[cursor] { root = known; break }
                    if unresolved.contains(cursor) { break }
                    guard let document = byID[cursor], !document.parentId.isEmpty else { break }
                    chain.append(cursor); cursor = document.parentId
                }
                if let root { for id in chain { resolved[id] = root } }
                else { unresolved.formUnion(chain); unresolved.insert(start) }
            }
            return LegacyLibraryInventory(rootIDs: roots.sorted(), rootsByDocumentID: resolved,
                unresolvedDocumentIDs: documents.map(\.id).filter { resolved[$0] == nil }.sorted())
        }
    }

    /// Registered roots extend only an unbound mixed local database. They never
    /// change the single authenticated root accepted by a connected workspace.
    func trustedVirtualRootIDs(db: Database) throws -> Set<String> {
        let bindings = try rootBindings(db: db)
        guard bindings.isEmpty else { return [try trustedVirtualRootID(db: db)] }
        return try registeredLegacyRootIDs(db: db).union(["root"])
    }

    private func rootBindings(db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key,value FROM sync_state WHERE key IN ('server','libraryId','rootId')") {
            result[row["key"] as String] = row["value"] as String
        }
        return result
    }

    private func registeredLegacyRootIDs(db: Database) throws -> Set<String> {
        var roots = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT key,value FROM sync_state WHERE key LIKE 'legacy.root.%'") {
            let key: String = row["key"], value: String = row["value"]
            guard let record = try? JSONDecoder().decode(LegacyRootRecord.self, from: Data(value.utf8)), record.version == 1,
                  UUID(uuidString: record.rootID) != nil, key == Self.legacyRootPrefix + record.rootID,
                  record.libraryID?.isEmpty != true else { continue }
            if let server = record.server, (try? ServerAddress.normalize(server).absoluteString) != server { continue }
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM working_documents WHERE id=?", arguments: [record.rootID]).map(mapDoc),
               existing.kind != .folder || !existing.parentId.isEmpty || existing.state != "active" || existing.isCatalogTopic { continue }
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM remote_tombstones WHERE id=?)", arguments: [record.rootID]) == true { continue }
            roots.insert(record.rootID)
        }
        return roots
    }
}
