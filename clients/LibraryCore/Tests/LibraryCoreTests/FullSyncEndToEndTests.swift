import Foundation
import XCTest
@testable import LibraryCore

final class FullSyncEndToEndTests: XCTestCase, @unchecked Sendable {
    func testRealHTTPPaginationForBootstrapAndIncrementalChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["TEST_TOKENLIBRARY_URL"], let url = URL(string: address),
              ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? ""),
              let username = environment["TEST_TOKENLIBRARY_USER"], let password = environment["TEST_TOKENLIBRARY_PASSWORD"] else {
            throw XCTSkip("Requires an explicitly configured isolated localhost TokenLibrary test service")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = SyncClient(baseURL: url), b = SyncClient(baseURL: url), c = SyncClient(baseURL: url)
        let login = try await a.login(username: username, password: password)
        _ = try await b.login(username: username, password: password)
        _ = try await c.login(username: username, password: password)
        let storeA = try DocumentStore(directory: directory.appendingPathComponent("a"))
        let storeB = try DocumentStore(directory: directory.appendingPathComponent("b"))
        let storeC = try DocumentStore(directory: directory.appendingPathComponent("c"))
        _ = try await a.synchronize(store: storeA); _ = try await b.synchronize(store: storeB)
        let oldCursor = storeB.syncCursor, folderID = UUID().uuidString.lowercased()
        try storeA.saveDocument(LibraryDocument(id: folderID, kind: .folder, parentId: login.rootId, name: "分页回归-\(folderID.prefix(8))", markdown: "", pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]"), enqueue: true)
        var ids: [String] = []
        for index in 0..<105 {
            let id = UUID().uuidString.lowercased(); ids.append(id)
            try storeA.localSaveOffline(markdown: "pagination body \(index)", id: id, name: "page-\(index).md", parentId: folderID)
        }
        _ = try await a.synchronize(store: storeA)
        let increment = try await b.synchronize(store: storeB)
        XCTAssertGreaterThanOrEqual(increment.downloaded, 106)
        XCTAssertGreaterThanOrEqual(storeB.syncCursor - oldCursor, 106)
        let bootstrap = try await c.synchronize(store: storeC)
        XCTAssertGreaterThan(bootstrap.downloaded, 100)
        for id in ids {
            XCTAssertEqual(try storeB.loadDocument(id: id)?.markdown, try storeA.loadDocument(id: id)?.markdown)
            XCTAssertEqual(try storeC.loadDocument(id: id)?.markdown, try storeA.loadDocument(id: id)?.markdown)
        }
        XCTAssertEqual(storeC.syncCursor, storeB.syncCursor)
    }

    func testTwoClientsMetadataMergeAttachmentsConflictsAndRecursiveTrash() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["TEST_TOKENLIBRARY_URL"], let url = URL(string: address),
              ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? ""),
              let username = environment["TEST_TOKENLIBRARY_USER"], let password = environment["TEST_TOKENLIBRARY_PASSWORD"] else {
            throw XCTSkip("Requires an explicitly configured isolated localhost TokenLibrary test service")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = SyncClient(baseURL: url), b = SyncClient(baseURL: url)
        let loginA = try await a.login(username: username, password: password)
        let loginB = try await b.login(username: username, password: password)
        let storeA = try LibraryWorkspaceManager(baseDirectory: directory.appendingPathComponent("a")).store(server: url, libraryId: loginA.libraryId)
        let storeB = try LibraryWorkspaceManager(baseDirectory: directory.appendingPathComponent("b")).store(server: url, libraryId: loginB.libraryId)
        _ = try await a.synchronize(store: storeA)
        let folderID = UUID().uuidString.lowercased(), noteID = UUID().uuidString.lowercased(), pdfID = UUID().uuidString.lowercased()
        let folder = LibraryDocument(id: folderID, kind: .folder, parentId: loginA.rootId, name: "同步回归-\(folderID.prefix(8))", markdown: "", pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
        let note = LibraryDocument(id: noteID, kind: .md, parentId: folderID, name: "正文.md", markdown: "alpha\nbeta\ngamma", pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]", metadataJSON: #"{"recordKind":"book","author":"测试作者","rating":4}"#)
        try storeA.saveDocument(folder, enqueue: true)
        try storeA.saveDocument(note, enqueue: true)
        _ = try await a.synchronize(store: storeA)
        XCTAssertEqual(try storeA.pending().count, 0)
        _ = try await b.synchronize(store: storeB)
        XCTAssertEqual(try storeB.loadDocument(id: noteID)?.markdown, note.markdown)
        XCTAssertTrue(try XCTUnwrap(storeB.loadDocument(id: noteID)).metadataJSON.contains("测试作者"))

        _ = try storeA.updateMarkdown(id: noteID, markdown: "ALPHA\nbeta\ngamma")
        _ = try storeB.updateMarkdown(id: noteID, markdown: "alpha\nbeta\nGAMMA")
        _ = try await a.synchronize(store: storeA)
        _ = try await b.synchronize(store: storeB)
        _ = try await a.synchronize(store: storeA)
        XCTAssertEqual(try storeA.loadDocument(id: noteID)?.markdown, "ALPHA\nbeta\nGAMMA")

        let imageData = Data("isolated image attachment bytes".utf8)
        let image = try storeA.importAttachment(data: imageData, fileName: "sample.png", mime: "image/png")
        _ = try storeA.updateMarkdown(id: noteID, markdown: "ALPHA\nbeta\nGAMMA\n\n![](\(image.path))")
        let pdfData = PDFExport.makeSamplePDF(text: "PDF synchronization test")
        let pdfAsset = try storeA.importAttachment(data: pdfData, fileName: "sample.pdf", mime: "application/pdf")
        let pdf = LibraryDocument(id: pdfID, kind: .pdf, parentId: folderID, name: "论文.pdf", markdown: "", pdfPath: try storeA.resolveAttachment(path: pdfAsset.path).path, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]")
        try storeA.saveDocument(pdf, enqueue: true)
        _ = try await a.synchronize(store: storeA)
        _ = try await b.synchronize(store: storeB)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(storeB.assetURL(id: image.blobId))), imageData)
        let downloadedPDF = try XCTUnwrap(storeB.loadDocument(id: pdfID)?.pdfPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: downloadedPDF)), pdfData)
        _ = try storeB.appendAnnotations(id: pdfID, extra: [PDFTextAnnotation(type: "comment", pageIndex: 0, x: 40, y: 40, width: 120, height: 30, color: "#007AFF", text: "同步备注")])
        _ = try await b.synchronize(store: storeB)
        _ = try await a.synchronize(store: storeA)
        XCTAssertTrue(try XCTUnwrap(storeA.loadDocument(id: pdfID)).annotationsJSON.contains("同步备注"))

        _ = try storeA.recordCatalogReadingPosition(id: pdfID, deviceID: a.deviceId, pageIndex: 1, totalPages: 10)
        _ = try storeB.recordCatalogReadingPosition(id: pdfID, deviceID: b.deviceId, pageIndex: 3, totalPages: 10)
        try await a.flushPending(store: storeA, rootId: loginA.rootId)
        try await b.flushPending(store: storeB, rootId: loginB.rootId)
        _ = try await a.synchronize(store: storeA)
        XCTAssertEqual(try storeA.loadDocument(id: pdfID)?.catalog.readingPositions.count, 2)

        let replacementData = PDFExport.makeSamplePDF(text: "replacement pages")
        let replacement = try storeA.importAttachment(data: replacementData, fileName: "replacement.pdf", mime: "application/pdf")
        var replacementPDF = try XCTUnwrap(storeA.loadDocument(id: pdfID))
        replacementPDF.pdfPath = try storeA.resolveAttachment(path: replacement.path).path
        replacementPDF.pdfBlobId = nil
        try storeA.saveDocument(replacementPDF, enqueue: true)
        _ = try await a.synchronize(store: storeA)
        _ = try await b.synchronize(store: storeB)
        let replacedPDF = try XCTUnwrap(storeB.loadDocument(id: pdfID))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(replacedPDF.pdfPath))), replacementData)
        XCTAssertEqual(try JSONValue.parse(replacedPDF.annotationsJSON).array?.first?.object?["placementState"]?.string, "needs_review")

        // Force both writes to use the same prior base, exercising persisted server conflict materials.
        _ = try storeA.updateMarkdown(id: noteID, markdown: "A conflicting text")
        _ = try storeB.updateMarkdown(id: noteID, markdown: "B conflicting text")
        try await a.flushPending(store: storeA, rootId: loginA.rootId)
        try await b.flushPending(store: storeB, rootId: loginB.rootId)
        _ = try await b.synchronize(store: storeB)
        let conflict = try XCTUnwrap(storeB.conflicts().first { $0.objectId == noteID })
        XCTAssertNotNil(conflict.serverId)
        XCTAssertTrue(conflict.remoteJSON.contains("A conflicting text"))
        try await b.resolveConflict(conflict, resolution: .local, store: storeB)
        XCTAssertFalse(try storeB.conflicts().contains { $0.objectId == noteID })
        _ = try await a.synchronize(store: storeA)
        XCTAssertEqual(try storeA.loadDocument(id: noteID)?.markdown, "B conflicting text")

        try storeA.trash(id: folderID)
        _ = try await a.synchronize(store: storeA)
        _ = try await b.synchronize(store: storeB)
        XCTAssertEqual(try storeB.loadDocument(id: noteID)?.state, "trashed")
        XCTAssertEqual(try storeB.loadDocument(id: pdfID)?.state, "trashed")
        try storeB.restore(id: folderID)
        // Server trashBatchId allows the second device to restore the complete batch while offline.
        XCTAssertEqual(try storeB.loadDocument(id: noteID)?.state, "active")
        XCTAssertEqual(try storeB.loadDocument(id: pdfID)?.state, "active")
        _ = try await b.synchronize(store: storeB)
        _ = try await a.synchronize(store: storeA)
        XCTAssertEqual(try storeA.loadDocument(id: noteID)?.state, "active")
        XCTAssertEqual(try storeA.loadDocument(id: pdfID)?.state, "active")
    }
}
