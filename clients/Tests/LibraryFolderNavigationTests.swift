import Foundation
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class LibraryFolderNavigationTests: XCTestCase {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-search-navigation-" + UUID().uuidString)
        let suite = "app.tokenlibrary.folder-search-tests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return try AppModel(directory: directory, preferences: preferences, restoreSavedSession: false)
    }

    private func seed(_ model: AppModel, kind: DocKind = .md, parent: String = "root", name: String) throws -> LibraryDocument {
        let document = LibraryDocument(id: UUID().uuidString.lowercased(), kind: kind, parentId: parent, name: name,
            markdown: kind == .md ? "正文 ordinary keyword\n" : "", pdfPath: nil, revision: 0, localGeneration: 0,
            state: "active", purgeAt: nil, status: .savedLocal, annotationsJSON: "[]")
        try model.store.saveDocument(document, enqueue: false)
        model.reload()
        return document
    }

    private func finishSearch(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if !model.searching { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Search did not finish")
    }

    func testFolderSearchResultLeavesSearchAndImmediatelyDisplaysCurrentChildren() async throws {
        let model = try model()
        let folder = try seed(model, kind: .folder, name: "独特研究目录")
        let child = try seed(model, parent: folder.id, name: "目录内正文.md")
        let outside = try seed(model, name: "外部笔记.md")
        model.selectedId = outside.id
        model.searchPresented = true; model.query = "独特研究目录"
        try await finishSearch(model)
        XCTAssertEqual(model.visibleDocs().map(\.id), [folder.id])
        // Use the fresh stored name even if the search row predates a rename.
        _ = try model.store.renameDocument(id: folder.id, to: "研究目录已改名")
        XCTAssertTrue(model.openFolder(folder))
        XCTAssertEqual(model.currentFolder, folder.id); XCTAssertEqual(model.folderName, "研究目录已改名")
        XCTAssertEqual(model.visibleDocs().map(\.id), [child.id])
        XCTAssertEqual(model.query, ""); XCTAssertFalse(model.searchPresented); XCTAssertFalse(model.searching)
        XCTAssertTrue(model.searchResults.isEmpty); XCTAssertNil(model.searchCoverage); XCTAssertNil(model.selectedId)
    }

    func testDebouncedOldSearchCannotReplaceDestinationAfterFolderNavigation() async throws {
        let model = try model()
        let folder = try seed(model, kind: .folder, name: "Folder")
        let child = try seed(model, parent: folder.id, name: "inside.md")
        _ = try seed(model, name: "outside.md")
        model.searchPresented = true; model.query = "ordinary"
        XCTAssertTrue(model.searching)
        XCTAssertTrue(model.openFolder(folder))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.visibleDocs().map(\.id), [child.id])
        XCTAssertTrue(model.searchResults.isEmpty); XCTAssertFalse(model.searching); XCTAssertFalse(model.searchPresented)
    }

    func testOrdinaryDocumentOpenKeepsSearchListWithoutInheritingHighlighting() async throws {
        let model = try model()
        let folder = try seed(model, kind: .folder, name: "Folder")
        let note = try seed(model, parent: folder.id, name: "inside.md")
        model.searchPresented = true; model.query = "ordinary"
        try await finishSearch(model)
        model.openDocument(note)
        XCTAssertEqual(model.selectedId, note.id); XCTAssertEqual(model.currentFolder, folder.id)
        XCTAssertEqual(model.query, "ordinary"); XCTAssertEqual(model.navigationSearch, "")
        XCTAssertTrue(model.searchPresented); XCTAssertEqual(model.visibleDocs().map(\.id), [note.id])
    }

    func testDeletedFolderResultDoesNotDismissSearchOrNavigateToUnavailableLocation() async throws {
        let model = try model()
        let folder = try seed(model, kind: .folder, name: "独特待删除目录")
        model.searchPresented = true; model.query = "独特待删除目录"
        try await finishSearch(model)
        try model.store.trash(id: folder.id)
        XCTAssertFalse(model.openFolder(folder))
        XCTAssertEqual(model.currentFolder, "root"); XCTAssertEqual(model.query, "独特待删除目录")
        XCTAssertTrue(model.searchPresented); XCTAssertNotNil(model.localOperationError)
    }
}
