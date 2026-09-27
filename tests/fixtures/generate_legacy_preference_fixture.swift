// Synthetic old base/library.sqlite, intentionally WITHOUT a registered root.
// A new iOS bundle's explicit old connection.rootId preference must cause the
// production AppModel startup path to register that root for the first time.
import Foundation
import CryptoKit
import GRDB
import LibraryCore

@main struct LegacyPreferenceFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        guard (directory.path.hasPrefix("/tmp/") || directory.path.hasPrefix("/private/tmp/")),
              !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        let pdf = try Data(contentsOf: input)
        guard pdf.starts(with: Data("%PDF-".utf8)) else { throw CocoaError(.fileReadCorruptFile) }
        let root = "a17a17a1-1000-4000-8000-000000000001"
        let unknown = "badbadba-2000-4000-8000-000000000002"
        let note = "a17a17a1-0000-4000-8000-000000000101"
        let source = "a17a17a1-0000-4000-8000-000000000102"
        let local = "a17a17a1-0000-4000-8000-000000000103"
        let orphan = "a17a17a1-0000-4000-8000-000000000104"
        let store = try DocumentStore(directory: directory)
        let asset = try store.importAttachment(data: pdf, fileName: "legacy.pdf", mime: "application/pdf")
        let pdfPath = try store.resolveAttachment(path: asset.path).path
        func doc(_ id: String, _ parent: String, _ name: String, _ markdown: String, pdf: Bool = false, pending: Bool = false) -> LibraryDocument {
            LibraryDocument(id: id, kind: pdf ? .pdf : .md, parentId: parent, name: name, markdown: markdown,
                pdfPath: pdf ? pdfPath : nil, revision: pending ? 0 : 3, localGeneration: 0, state: "active", purgeAt: nil,
                status: pending ? .pending : .savedLocal, annotationsJSON: "[]", metadataJSON: "{}", pdfBlobId: pdf ? asset.blobId : nil)
        }
        try store.saveDocument(doc(note, root, "旧偏好根笔记.md", "# 旧偏好根笔记\n\niOSLegacyPreferenceAnchor20260927\n\n应由明确旧偏好首次登记根；原正文保持。\n"), enqueue: false)
        try store.saveDocument(doc(source, root, "旧偏好三页论文.pdf", "", pdf: true), enqueue: false)
        _ = try store.createDocument(doc(local, "root", "默认根原待提交.md", "# 默认根原待提交\n\nLegacyOriginalPending20260927\n", pending: true))
        try store.saveDocument(doc(orphan, unknown, "未知父级保留.md", "# 未知父级保留\n\nLegacyUnknownParent20260927\n\n不可把此未知父ID推断成可信根。\n"), enqueue: false)
        // Do not call registerLegacyLibraryRoot here. All root trust must come
        // from the separately seeded old preference when the actual app opens.
        let inventory = try store.legacyLibraryInventory()
        let operations = try store.pending()
        guard inventory.rootIDs == ["root"], Set(inventory.unresolvedDocumentIDs) == Set([note, source, orphan]),
              operations.count == 1, operations[0].objectId == local,
              operations[0].requestJSON == nil, try store.loadDocument(id: root) == nil else { throw CocoaError(.coderInvalidValue) }
        let state = try store.db.read { db in try String.fetchAll(db, sql: "SELECT key FROM sync_state ORDER BY key") }
        guard !state.contains(where: { $0.hasPrefix("legacy.root.") || ["server", "libraryId", "rootId", "epoch", "sessionToken"].contains($0) }) else { throw CocoaError(.coderInvalidValue) }
        try store.db.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        let manifest: [String: Any] = ["fixture": "synthetic-ios-old-layout-first-root-registration", "nativeVerified": false,
            "directory": directory.path, "expectedRootFromPreference": root, "unregisteredUnknownRoot": unknown,
            "noteId": note, "pdfId": source, "defaultPendingNoteId": local, "orphanId": orphan,
            "initialDocumentCount": 4, "initialRegisteredRoots": [], "initialInventoryRoots": inventory.rootIDs,
            "initialUnresolvedIDs": inventory.unresolvedDocumentIDs, "initialPendingOperationId": operations[0].operationId,
            "initialSyncStateKeys": state, "pdfAssetPath": asset.path, "pdfBlobId": asset.blobId, "pdfBytes": pdf.count,
            "pdfSHA256": SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined(),
            "databaseSHA256": SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent("library.sqlite"))).map { String(format: "%02x", $0) }.joined(),
            "bundleId": "app.tokenlibrary.verification.legacypreferences.ios", "preferences": ["connection.rootId": root],
            "expectedAfterAppStartup": ["registeredRoots": [root], "inventoryRoots": ["root", root], "unresolvedIDs": [orphan]],
            "scope": "Generated through current Core APIs with an old directory layout; not an actual old binary upgrade, no app/container/prefs/Keychain/network access."]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
        print("PREPARED \(directory.path): 4 docs, no registered legacy root, 1 original pending, 1 PDF; no app launch.")
    }
}
