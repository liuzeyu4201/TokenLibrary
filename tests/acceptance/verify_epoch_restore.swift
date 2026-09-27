// Links a frozen LibraryCore build. The orchestrator owns only a new synthetic service.
import Foundation
import CryptoKit
import GRDB
import LibraryCore

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed) }
func save(_ value: Any, _ path: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
}
func body(_ store: DocumentStore, _ id: String) throws -> String {
    guard let doc = try store.loadDocument(id: id) else { throw CheckFailure(description: "missing document \(id)") }
    return doc.markdown
}
func operationState(_ store: DocumentStore, _ id: String) throws -> String? {
    try store.db.read { try String.fetchOne($0, sql: "SELECT state FROM pending_operations WHERE operation_id=?", arguments: [id]) }
}
func operationWire(_ store: DocumentStore, _ id: String) throws -> String? {
    try store.db.read { try String.fetchOne($0, sql: "SELECT request_json FROM pending_operations WHERE operation_id=?", arguments: [id]) }
}
func storeProof(_ store: DocumentStore) throws -> [String: Any] {
    let documents = try store.listDocuments(includeTrashed: true)
    let ops = try store.db.read { db in
        try String.fetchOne(db, sql: "SELECT json_group_array(json_object('operationId',operation_id,'objectId',object_id,'state',state,'requestJSON',request_json,'generation',frozen_generation)) FROM pending_operations") ?? "[]"
    }
    return ["root": store.root.path, "epoch": try store.syncValue("epoch") ?? "", "cursor": store.syncCursor,
            "documents": try json(documents), "sendableCount": try store.pending().count,
            "openConflicts": try json(store.conflicts()), "operations": try JSONSerialization.jsonObject(with: Data(ops.utf8))]
}
func marker(_ value: String) { print(value); fflush(stdout) }
func waitFor(_ expected: String) throws { try require(readLine() == expected, "orchestrator handshake: expected \(expected)") }

@main struct EpochRestoreProbe {
    static func main() async {
        do { try await run() }
        catch { fputs("EPOCH_PROBE_FAILED: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        try require(args.count == 4, "usage: probe LOOPBACK_URL NEW_OUTPUT_DIR SYNTHETIC_FIXTURE_DIR")
        let url = try ServerAddress.normalize(args[1])
        try require(url.host == "127.0.0.1", "isolated IPv4 loopback required")
        let output = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        let fixtures = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
        try require(output.lastPathComponent == "clients", "orchestrator-specific clients directory required")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let username = env["TEST_TOKENLIBRARY_USER"], let password = env["TEST_TOKENLIBRARY_PASSWORD"] else {
            throw CheckFailure(description: "synthetic credentials must be supplied explicitly")
        }
        let a = SyncClient(baseURL: url), b = SyncClient(baseURL: url)
        let loginA = try await a.login(username: username, password: password)
        let loginB = try await b.login(username: username, password: password)
        try require(loginA.libraryId == loginB.libraryId && loginA.epoch == loginB.epoch, "initial shared identity")
        let directoryA = output.appendingPathComponent("a"), directoryB = output.appendingPathComponent("b")
        var storeA = try DocumentStore(directory: directoryA), storeB = try DocumentStore(directory: directoryB)
        _ = try await a.synchronize(store: storeA); _ = try await b.synchronize(store: storeB)
        let folderID = UUID().uuidString.lowercased(), noteA = UUID().uuidString.lowercased()
        let noteB = UUID().uuidString.lowercased(), pdfID = UUID().uuidString.lowercased()
        let imageBytes = try Data(contentsOf: fixtures.appendingPathComponent("fixture-diagram.png"))
        let pdfBytes = try Data(contentsOf: fixtures.appendingPathComponent("research-three-pages.pdf"))
        let image = try storeA.importAttachment(data: imageBytes, fileName: "shared-image.png", mime: "image/png")
        let pdf = try storeA.importAttachment(data: pdfBytes, fileName: "three-pages.pdf", mime: "application/pdf")
        let imageMarkdown = "\n\n![合成研究流程图](\(image.path))\n"
        let baseA = "# Client A baseline\n\n保存中文与 LF。" + imageMarkdown
        let baseB = "# Client B baseline\n\nSame shared attachment." + imageMarkdown
        func document(_ id: String, _ kind: DocKind, _ name: String, _ markdown: String, _ metadata: String = "{}", _ pdfPath: String? = nil) -> LibraryDocument {
            LibraryDocument(id: id, kind: kind, parentId: kind == .folder ? loginA.rootId : folderID, name: name, markdown: markdown,
                            pdfPath: pdfPath, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending,
                            annotationsJSON: "[]", metadataJSON: metadata)
        }
        try storeA.saveDocument(document(folderID, .folder, "恢复联合验收", ""), enqueue: true)
        try storeA.saveDocument(document(noteA, .md, "Client-A.md", baseA, #"{"category":"note","tags":["恢复验收"]}"#), enqueue: true)
        try storeA.saveDocument(document(noteB, .md, "Client-B.md", baseB), enqueue: true)
        try storeA.saveDocument(document(pdfID, .pdf, "归档三页论文.pdf", "", #"{"category":"paper","archived":true,"inbox":false,"title":"合成归档论文","year":2026}"#, try storeA.resolveAttachment(path: pdf.path).path), enqueue: true)
        _ = try await a.synchronize(store: storeA); _ = try await b.synchronize(store: storeB)
        try require(try storeA.pending().isEmpty && storeB.pending().isEmpty, "seed queues drained")
        try require(try body(storeB, noteA) == baseA && body(storeB, noteB) == baseB, "seed bodies synchronized")
        let backedA = try storeA.loadDocument(id: noteA)!.revision, backedB = try storeB.loadDocument(id: noteB)!.revision
        let immutablePDF = try storeA.loadDocument(id: pdfID)!
        func verifyMedia(_ store: DocumentStore) throws {
            guard let imageURL = try store.assetURL(id: image.blobId), let pdfPath = try store.loadDocument(id: pdfID)?.pdfPath else { throw CheckFailure(description: "missing media") }
            try require(try Data(contentsOf: imageURL) == imageBytes, "PNG exact original bytes")
            try require(try Data(contentsOf: URL(fileURLWithPath: pdfPath)) == pdfBytes, "PDF exact original bytes")
            let doc = try store.loadDocument(id: pdfID)!
            try require(doc.state == "active" && doc.purgeAt == nil && doc.metadataJSON == immutablePDF.metadataJSON && doc.pdfBlobId == immutablePDF.pdfBlobId, "archived PDF metadata/identity unchanged")
        }
        try verifyMedia(storeA); try verifyMedia(storeB)
        let identities: [String: Any] = ["libraryId": loginA.libraryId, "oldEpoch": loginA.epoch, "rootId": loginA.rootId,
            "deviceA": loginA.deviceId, "deviceB": loginB.deviceId, "folder": folderID, "noteA": noteA, "noteB": noteB, "pdf": pdfID,
            "imageBlob": image.blobId, "pdfBlob": pdf.blobId, "imageSHA256": hash(imageBytes), "pdfSHA256": hash(pdfBytes),
            "backupRevisionA": backedA, "backupRevisionB": backedB]
        try save(identities, output.appendingPathComponent("identities.json"))
        try save(["a": try storeProof(storeA), "b": try storeProof(storeB)], output.appendingPathComponent("01-before-backup.json"))
        marker("READY_FOR_BACKUP"); try waitFor("backup-ok")

        // Advance both cloud heads beyond the backup, then freeze unsent requests and add mutable tails.
        for iteration in 1...2 {
            _ = try storeA.updateMarkdown(id: noteA, markdown: baseA + "\nCloud A generation \(iteration)\n")
            _ = try await a.synchronize(store: storeA)
            _ = try storeB.updateMarkdown(id: noteB, markdown: baseB + "\nCloud B generation \(iteration)\n")
            _ = try await b.synchronize(store: storeB)
        }
        _ = try await a.synchronize(store: storeA); _ = try await b.synchronize(store: storeB)
        let advancedA = try storeA.loadDocument(id: noteA)!.revision, advancedB = try storeB.loadDocument(id: noteB)!.revision
        try require(advancedA > backedA && advancedB > backedB, "cloud revisions advanced after backup")
        let frozenBodyA = try body(storeA, noteA) + "\nA offline frozen\n", frozenBodyB = try body(storeB, noteB) + "\nB offline frozen\n"
        _ = try storeA.updateMarkdown(id: noteA, markdown: frozenBodyA)
        _ = try storeB.updateMarkdown(id: noteB, markdown: frozenBodyB)
        let opA = try storeA.pending().first { $0.objectId == noteA }!, opB = try storeB.pending().first { $0.objectId == noteB }!
        let frozenA = try storeA.prepareOperation(opA.operationId, epoch: loginA.epoch, deviceId: a.deviceId, serverOrigin: url.absoluteString)!
        let frozenB = try storeB.prepareOperation(opB.operationId, epoch: loginB.epoch, deviceId: b.deviceId, serverOrigin: url.absoluteString)!
        let localA = frozenBodyA + "\nA newer local tail 中文\n", localB = frozenBodyB + "\nB newer local tail 🧪\n"
        _ = try storeA.updateMarkdown(id: noteA, markdown: localA); _ = try storeB.updateMarkdown(id: noteB, markdown: localB)
        try require(try storeA.pending().count == 2 && storeB.pending().count == 2, "frozen and mutable tail persisted separately")
        try save(["a": try storeProof(storeA), "b": try storeProof(storeB), "advancedRevisionA": advancedA, "advancedRevisionB": advancedB], output.appendingPathComponent("02-before-restore.json"))
        marker("READY_FOR_RESTORE"); try waitFor("restored")
        for client in [a,b] {
            do { _ = try await client.fetchDocument(id: noteA); throw CheckFailure(description: "old session unexpectedly survived restore") }
            catch let failure as SyncFailure { try require(failure.statusCode == 401, "old session must fail with 401, not generic transport failure") }
        }
        // Re-open persisted local databases, preserving frozen wire and unsent tail across a process-style store lifetime.
        storeA = try DocumentStore(directory: directoryA); storeB = try DocumentStore(directory: directoryB)
        try require(try operationWire(storeA, opA.operationId) == frozenA.requestJSON && operationWire(storeB, opB.operationId) == frozenB.requestJSON, "old frozen request bytes survived reopen/401")
        try require(try body(storeA, noteA) == localA && body(storeB, noteB) == localB, "local tail survived reopen/401")
        try save(["a": try storeProof(storeA), "b": try storeProof(storeB), "oldSessions401": 2], output.appendingPathComponent("03-old-sessions-rejected.json"))
        let renewedA = try await a.login(username: username, password: password), renewedB = try await b.login(username: username, password: password)
        try require(renewedA.libraryId == loginA.libraryId && renewedA.rootId == loginA.rootId && renewedB.epoch == renewedA.epoch && renewedA.epoch != loginA.epoch, "same library/root and new epoch")
        _ = try await a.synchronize(store: storeA); _ = try await b.synchronize(store: storeB)
        let conflictA = try storeA.conflicts().first { $0.objectId == noteA }!, conflictB = try storeB.conflicts().first { $0.objectId == noteB }!
        try require(conflictA.kind == "epoch_changed" && conflictB.kind == "epoch_changed", "both old queues become explicit epoch conflicts")
        try require(conflictA.revision == backedA && conflictB.revision == backedB, "lower restored revisions accepted")
        try require(try body(storeA, noteA) == localA && body(storeB, noteB) == localB, "epoch bootstrap preserved latest local working bodies")
        try require(try storeA.pending().isEmpty && storeB.pending().isEmpty, "blocked conflicts are not sendable queue entries")
        try require(try operationState(storeA, opA.operationId) == "conflict" && operationState(storeB, opB.operationId) == "conflict", "frozen old requests blocked before replay")
        try require(try operationWire(storeA, opA.operationId) == frozenA.requestJSON && operationWire(storeB, opB.operationId) == frozenB.requestJSON, "epoch handling does not rewrite frozen bytes")
        try verifyMedia(storeA); try verifyMedia(storeB)
        try save(["a": try storeProof(storeA), "b": try storeProof(storeB), "newEpoch": renewedA.epoch], output.appendingPathComponent("04-epoch-conflicts.json"))
        try await a.resolveConflict(conflictA, resolution: .local, store: storeA)
        let resolvedB = localB + "\nExplicit custom resolution after restore.\n"
        try await b.resolveConflict(conflictB, resolution: .customMarkdown(resolvedB), store: storeB)
        _ = try await a.synchronize(store: storeA); _ = try await b.synchronize(store: storeB)
        _ = try await a.synchronize(store: storeA)
        for store in [storeA, storeB] {
            try require(try body(store, noteA) == localA && body(store, noteB) == resolvedB, "both clients converge exact local/custom resolved content")
            try require(try store.pending().isEmpty && store.conflicts().isEmpty, "final queues/conflicts empty")
            try verifyMedia(store)
        }
        try require(try operationState(storeA, opA.operationId) == "superseded" && operationState(storeB, opB.operationId) == "superseded", "old frozen operations superseded, never sent")
        let remoteA = try await a.fetchDocument(id: noteA), remoteB = try await b.fetchDocument(id: noteB)
        try require(remoteA["markdownSource"]?.string == localA && remoteB["markdownSource"]?.string == resolvedB, "server exact resolved text")
        try save(["a": try storeProof(storeA), "b": try storeProof(storeB), "remoteA": try json(remoteA), "remoteB": try json(remoteB),
                  "newEpoch": renewedA.epoch, "oldFrozenA": opA.operationId, "oldFrozenB": opB.operationId,
                  "resolvedASHA256": hash(Data(localA.utf8)), "resolvedBSHA256": hash(Data(resolvedB.utf8)), "passed": true,
                  "scope": "Two real HTTP Core clients, same URL actual PG17 restore, database reopen (not GUI or full application process restart)."], output.appendingPathComponent("05-final.json"))
        marker("EPOCH_RESTORE_PASSED")
    }
}
