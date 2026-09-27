import Foundation
import GRDB

public struct LocalLibraryImportResult: Sendable {
    public let importedDocuments: Int
    public let importedAttachments: Int
    public let documentIDMap: [String: String]
}

extension DocumentStore {
    /// Explicit copy into a chosen workspace. Source documents and files are never modified or removed.
    @discardableResult
    public func importLocalLibrary(from source: DocumentStore, sourceRootID: String, targetRootID: String) throws -> LocalLibraryImportResult {
        guard source.root.resolvingSymlinksInPath().standardizedFileURL != root.resolvingSymlinksInPath().standardizedFileURL, !targetRootID.isEmpty else { throw TransferError.invalidPath }
        let all = try source.listDocuments(includeTrashed: true)
        var documents: [LibraryDocument] = []
        for document in all where document.id != sourceRootID && document.state != "purged" {
            if try source.belongsToRoot(objectId: document.id, rootId: sourceRootID) { documents.append(document) }
        }
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        func depth(_ doc: LibraryDocument) -> Int {
            var count = 0, parent = doc.parentId
            while let item = byID[parent], count <= documents.count { count += 1; parent = item.parentId }
            return count
        }
        let ordered = documents.sorted { depth($0) < depth($1) }
        let reserved = try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM working_documents UNION SELECT id FROM remote_documents UNION SELECT id FROM remote_tombstones"))
        }
        var mapping: [String: String] = [:]
        for document in ordered { mapping[document.id] = UUID(uuidString: document.id) != nil && !reserved.contains(document.id) ? document.id : UUID().uuidString.lowercased() }
        var copies: [LibraryDocument] = []
        var files: [String: LibraryAsset] = [:]
        let batches: [String: String] = try source.db.read { db in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id,trash_batch_id FROM working_documents WHERE state='trashed'") {
                let id: String = row["id"]
                result[id] = (row["trash_batch_id"] as String?) ?? id
            }
            return result
        }
        func copyAttachment(_ path: String) throws -> LibraryAsset {
            let url = try source.resolveAttachment(path: path)
            if let cached = files[url.path] { return cached }
            let asset = try importAttachment(data: Data(contentsOf: url), fileName: url.lastPathComponent, mime: Self.mime(for: url.path))
            files[url.path] = asset
            return asset
        }
        for original in ordered {
            var copy = original
            copy.id = mapping[original.id]!
            copy.parentId = original.parentId == sourceRootID ? targetRootID : mapping[original.parentId] ?? targetRootID
            copy.revision = 0; copy.localGeneration = 0; copy.status = .pending; copy.state = "active"; copy.purgeAt = nil
            guard FileNames.isValidStoredName(copy.name) else { throw StructureEditError.invalidName }
            if let path = original.pdfPath {
                let asset = try copyAttachment(path)
                copy.pdfPath = try resolveAttachment(path: asset.path).path; copy.pdfBlobId = asset.blobId
                if let values = try? JSONValue.parse(copy.annotationsJSON).array {
                    copy.annotationsJSON = try JSONValue.array(values.map { value in
                        guard var object = value.object else { return value }
                        let oldBlob = object["pdfBlobId"]?.string
                        let placement = object["placementState"]?.string ?? "attached"
                        // Only placements valid for this exact source PDF can
                        // be attached to its copied bytes. Keep unknown fields
                        // and old identities on review-only material.
                        if placement == "attached" && (oldBlob == nil || oldBlob == original.pdfBlobId) {
                            object["pdfBlobId"] = .string(asset.blobId)
                        } else {
                            object["placementState"] = .string("needs_review")
                        }
                        return .object(object)
                    }).jsonString()
                }
            }
            var attachments: [LibraryAsset] = []
            let parsed = try MarkdownReferences(original.markdown)
            var replacements: [String: String] = [:]
            for reference in parsed.mediaReferences {
                let path = reference.destination
                guard path.hasPrefix("media/") || path.hasPrefix("library-asset://") else { continue }
                let asset = try copyAttachment(path)
                replacements[path] = asset.path
                if !attachments.contains(where: { $0.blobId == asset.blobId }) { attachments.append(asset) }
            }
            // Source links follow the copied object when its ID collides in the
            // destination. Use parsed links so examples in code stay untouched.
            for reference in parsed.references where !reference.isImage {
                guard var url = URLComponents(string: reference.destination),
                      url.scheme?.lowercased() == "tokenlibrary", url.host?.lowercased() == "document",
                      url.user == nil, url.password == nil, url.port == nil else { continue }
                let parts = url.path.split(separator: "/")
                guard parts.count == 1, let newID = mapping[String(parts[0])], newID != String(parts[0]) else { continue }
                url.path = "/" + newID
                if let destination = url.string { replacements[reference.destination] = destination }
            }
            if !replacements.isEmpty { copy.markdown = try parsed.replacingDestinations(replacements) }
            copy.assetsJSON = try JSONValue.array(attachments.map(\.json)).jsonString()
            if var metadata = try JSONValue.parse(copy.metadataJSON).object {
                for key in ["topicIDs", "sourceIDs", "relatedIDs"] {
                    if let values = metadata[key]?.array { metadata[key] = .array(values.map { value in value.string.flatMap { mapping[$0] }.map(JSONValue.string) ?? value }) }
                }
                if let excerpts = metadata["excerpts"]?.array {
                    metadata["excerpts"] = .array(excerpts.map { value in
                        guard var excerpt = value.object, let sourceID = excerpt["sourceID"]?.string, let copiedID = mapping[sourceID] else { return value }
                        excerpt["sourceID"] = .string(copiedID)
                        return .object(excerpt)
                    })
                }
                copy.metadataJSON = try JSONValue.object(metadata).jsonString()
            }
            copies.append(copy)
        }
        try db.write { db in
            // Resolve collisions from the latest rows while holding the writer,
            // including names claimed by earlier copies in this same import.
            var occupied: [String: Set<String>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT parent_id,name FROM working_documents WHERE state<>'purged'") {
                occupied[row["parent_id"] as String, default: []].insert(FileNames.comparisonKey(row["name"]))
            }
            for var document in copies {
                document.name = FileNames.availableName(document.name, kind: document.kind, takenKeys: occupied[document.parentId] ?? [])
                occupied[document.parentId, default: []].insert(FileNames.comparisonKey(document.name))
                // Detect a concurrent import/editor insertion before committing any document.
                guard try String.fetchOne(db, sql: "SELECT id FROM working_documents WHERE id=?", arguments: [document.id]) == nil else { throw StoreError.staleOperation }
                try writeWorking(document.syncSnapshot, prior: nil, status: .pending, db: db)
                try db.execute(sql: "INSERT INTO pending_operations(operation_id,action,object_id,payload,state,created_at) VALUES (?,?,?,?,'pending',?)", arguments: [UUID().uuidString.lowercased(),Self.syncAction(kind: document.kind, revision: 0),document.id,encodePayload(document),ISO8601DateFormatter().string(from: Date())])
            }
            // Independent old trash batches go first, preserving their separate restore behavior.
            let trashed = ordered.filter { $0.state == "trashed" }.sorted { depth($0) > depth($1) }
            var completed = Set<String>()
            for original in trashed {
                let batch = batches[original.id] ?? original.id
                guard completed.insert(batch).inserted else { continue }
                let members = trashed.filter { (batches[$0.id] ?? $0.id) == batch }
                guard let top = members.min(by: { depth($0) < depth($1) }), let rootID = mapping[top.id] else { continue }
                let targetBatch = UUID().uuidString.lowercased()
                for member in members {
                    try db.execute(sql: "UPDATE working_documents SET state='trashed',trash_batch_id=?,purge_at=? WHERE id=?", arguments: [targetBatch,member.purgeAt.map { ISO8601DateFormatter().string(from: $0) },mapping[member.id]])
                }
                try db.execute(sql: "INSERT INTO pending_operations(operation_id,action,object_id,payload,state,created_at) VALUES (?,'trash',?,'{}','pending',?)", arguments: [UUID().uuidString.lowercased(),rootID,ISO8601DateFormatter().string(from: Date())])
            }
        }
        return LocalLibraryImportResult(importedDocuments: copies.count, importedAttachments: files.count, documentIDMap: mapping)
    }
}
