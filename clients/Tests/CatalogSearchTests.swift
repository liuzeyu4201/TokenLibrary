import Foundation
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class CatalogSearchTests: XCTestCase {
    private func fixture() throws -> DocumentStore {
        try DocumentStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tokenlibrary-catalog-search-\(UUID().uuidString)"))
    }
    @discardableResult
    private func seed(_ store: DocumentStore, id: String, kind: DocKind = .md, author: String, archived: Bool = false) throws -> LibraryDocument {
        var metadata = CatalogMetadata()
        metadata.title = id; metadata.authors = [author]; metadata.archived = archived
        let document = LibraryDocument(id: id, kind: kind, parentId: "root", name: id + ".md", markdown: kind == .md ? "needle in body" : "",
                                       pdfPath: nil, revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .savedLocal,
                                       annotationsJSON: "[]", metadataJSON: try metadata.json())
        try store.saveDocument(document, enqueue: false)
        return document
    }
    func testSearchResultCombinesIndexAndFiltersAndReportsActualCoverage() async throws {
        let store = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let selected = try seed(store, id: "archived", author: "Alice", archived: true)
        try seed(store, id: "other-author", author: "Bob")
        try seed(store, id: "waiting-pdf", kind: .pdf, author: "Alice")
        let request = CatalogWorkspaceSearchRequest(workspacePath: store.root.path, documents: try store.listDocuments(),
                                                   query: CatalogQuery(text: "needle", author: "alice"), sort: .title)
        let response = await CatalogWorkspaceSearchResult.load(request, store: store)
        let result = try XCTUnwrap(response)
        XCTAssertEqual(result.request, request)
        XCTAssertEqual(result.documents.map(\.id), [selected.id])
        XCTAssertEqual(result.coverage?.documents, 3)
        XCTAssertEqual(result.coverage?.searchableText, 2)
        XCTAssertEqual(result.coverage?.waitingDownload, 1)
        XCTAssertNil(result.errorMessage)
    }
    func testRequestCannotSearchAnotherWorkspaceEvenWithSameDocumentIDs() async throws {
        let old = try fixture(), current = try fixture()
        defer { try? FileManager.default.removeItem(at: old.root); try? FileManager.default.removeItem(at: current.root) }
        let oldDocument = try seed(old, id: "same-id", author: "Old library")
        let newDocument = try seed(current, id: "same-id", author: "Current library")
        let request = CatalogWorkspaceSearchRequest(workspacePath: old.root.path, documents: [oldDocument], query: CatalogQuery(), sort: .title)
        let response = await CatalogWorkspaceSearchResult.load(request, store: current)
        XCTAssertNil(response)
        let currentRequest = CatalogWorkspaceSearchRequest(workspacePath: current.root.path, documents: [newDocument], query: CatalogQuery(), sort: .title)
        let currentResponse = await CatalogWorkspaceSearchResult.load(currentRequest, store: current)
        XCTAssertEqual(currentResponse?.documents.first?.catalog.authors, ["Current library"])
        XCTAssertNotEqual(currentResponse?.request, request)
    }
    func testCancelledRequestDoesNotPublishAndNextRequestCanRun() async throws {
        let store = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let document = try seed(store, id: "note", author: "Alice")
        let request = CatalogWorkspaceSearchRequest(workspacePath: store.root.path, documents: [document], query: CatalogQuery(text: "needle"), sort: .title)
        let cancelled = Task { await CatalogWorkspaceSearchResult.load(request, store: store) }
        cancelled.cancel()
        let cancelledResponse = await cancelled.value
        XCTAssertNil(cancelledResponse)
        let response = await CatalogWorkspaceSearchResult.load(request, store: store)
        XCTAssertEqual(response?.documents.map(\.id), [document.id])
    }
}
