import Foundation
import GRDB

extension DocumentStore {
    /// iOS can move an app's entire sandbox during an update. Local file URLs
    /// are not document edits and must never increment revisions or enqueue work.
    /// Run on every open: a schema migration only runs once, a sandbox can move
    /// many times. Relative blob paths also recover libraries predating the marker.
    func recoverRelocatedLibraryPaths() throws {
        try db.write { db in
            let currentRoot = root.standardizedFileURL.path
            let rootKey = "local.library_root_path"
            let previousRoot = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key=?", arguments: [rootKey])
            let documents = try Row.fetchAll(db, sql: "SELECT * FROM working_documents WHERE kind='pdf'").map(mapDoc)
            let draftRows = try Row.fetchAll(db, sql: "SELECT id,draft_json FROM editor_drafts")
            let drafts: [(id: String, value: [String: Any])] = draftRows.compactMap { row in
                let text: String = row["draft_json"]
                guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
                return (row["id"], value)
            }
            var relativeByBlob: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT blob_id,local_path FROM blob_transfers") {
                let path: String = row["local_path"]
                guard !path.hasPrefix("/"), !path.hasPrefix("library-asset:"),
                      let url = try? resolveAttachment(path: path), FileManager.default.isReadableFile(atPath: url.path) else { continue }
                relativeByBlob[row["blob_id"]] = path
            }
            var oldRoots = Set<String>()
            if let previousRoot, previousRoot != currentRoot { oldRoots.insert(previousRoot) }
            func rememberRoot(path: String?, blob: String?) {
                guard let path, path.hasPrefix("/"), let blob, let relative = relativeByBlob[blob],
                      path.hasSuffix("/" + relative) else { return }
                let prefix = String(path.dropLast(relative.count + 1))
                if !prefix.isEmpty, prefix != currentRoot { oldRoots.insert(prefix) }
            }
            for document in documents { rememberRoot(path: document.pdfPath, blob: document.pdfBlobId) }
            for draft in drafts {
                rememberRoot(path: draft.value["expectedPDFPath"] as? String, blob: draft.value["expectedPDFBlobId"] as? String)
            }
            func restoredPath(_ path: String?, blob: String?) -> String? {
                guard let path else { return nil }
                // Keep a valid path in this library, even if the blob is not yet
                // prepared. Never follow a symlink outside the current library.
                if let current = try? resolveAttachment(path: path), FileManager.default.isReadableFile(atPath: current.path) {
                    return current.path
                }
                if let blob, let relative = relativeByBlob[blob], let url = try? resolveAttachment(path: relative) {
                    return url.path
                }
                for oldRoot in oldRoots.sorted(by: { $0.count > $1.count }) where path.hasPrefix(oldRoot + "/") {
                    let relative = String(path.dropFirst(oldRoot.count + 1))
                    if let url = try? resolveAttachment(path: relative), FileManager.default.isReadableFile(atPath: url.path) {
                        return url.path
                    }
                }
                return path
            }
            for var document in documents {
                let path = restoredPath(document.pdfPath, blob: document.pdfBlobId)
                guard path != document.pdfPath else { continue }
                document.pdfPath = path
                try db.execute(sql: "UPDATE working_documents SET pdf_path=? WHERE id=?", arguments: [path, document.id])
                // A previous open may have indexed this document while its old
                // path was unavailable. Restore PDF body search together with IO.
                try reindex(document, db: db, verifyExistingChunks: true)
            }
            for draft in drafts {
                var value = draft.value
                var changed = false
                if let oldPath = value["expectedPDFPath"] as? String,
                   let newPath = restoredPath(oldPath, blob: value["expectedPDFBlobId"] as? String), oldPath != newPath {
                    value["expectedPDFPath"] = newPath; changed = true
                }
                if var original = value["originalDocument"] as? [String: Any], let oldPath = original["pdfPath"] as? String,
                   let newPath = restoredPath(oldPath, blob: original["pdfBlobId"] as? String), oldPath != newPath {
                    original["pdfPath"] = newPath; value["originalDocument"] = original; changed = true
                }
                if changed {
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
                    try db.execute(sql: "UPDATE editor_drafts SET draft_json=? WHERE id=?", arguments: [json, draft.id])
                }
            }
            try db.execute(sql: "INSERT INTO sync_state(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [rootKey,currentRoot])
        }
    }
}
