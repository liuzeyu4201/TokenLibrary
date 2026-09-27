import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class LibraryImportPickerTests: XCTestCase {
    private func fixture() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-picker-\(UUID().uuidString)")
        let suite = "app.tokenlibrary.import-picker.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (try AppModel(directory: directory, preferences: preferences, restoreSavedSession: false), directory)
    }

    func testFileModeSurvivesSystemDismissalAndImportsSelectedMarkdown() throws {
        let (model, directory) = try fixture()
        let file = directory.appendingPathComponent("selected.md")
        try Data("# 本机文件\n\n末尾空格 \n".utf8).write(to: file)
        var picker = LibraryImportPickerState()
        picker.present(.files, store: model.store, parentID: model.currentFolder)
        let request = try XCTUnwrap(picker.request)
        XCTAssertEqual(request.mode.allowedContentTypes, [.pdf, .plainText])
        picker.isPresented = false // The system dismisses before calling onCompletion.
        picker.present(.markdownFolder, store: model.store, parentID: model.currentFolder)
        XCTAssertEqual(picker.request?.id, request.id, "An unfinished file request must keep its routing mode")
        let result = try XCTUnwrap(picker.complete(.success([file]), requestID: request.id, store: model.store, parentID: model.currentFolder))
        guard case .file(let selected) = try result.result.get() else { return XCTFail("Expected file route") }
        model.importFile(url: selected)
        XCTAssertEqual(model.selected?.markdown, "# 本机文件\n\n末尾空格 \n")
        XCTAssertNil(model.localOperationError)
        XCTAssertEqual(try model.store.pending().count, 1)
        XCTAssertNil(picker.request)
        XCTAssertFalse(picker.isPresented)
    }

    func testFolderModeRoutesDirectoryWithoutImportingItAsAFile() throws {
        let (model, directory) = try fixture()
        let folder = directory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("inside.md")
        try Data("# 附件目录中的笔记".utf8).write(to: file)
        var picker = LibraryImportPickerState()
        picker.present(.markdownFolder, store: model.store, parentID: model.currentFolder)
        let request = try XCTUnwrap(picker.request)
        XCTAssertEqual(request.mode.allowedContentTypes, [.folder])
        let result = try XCTUnwrap(picker.complete(.success([folder]), requestID: request.id, store: model.store, parentID: model.currentFolder))
        XCTAssertEqual(try result.result.get(), .markdownFolder(folder))
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertTrue(try model.store.pending().isEmpty)
        // Only the subsequent note choice imports a document.
        model.importFile(url: file)
        XCTAssertEqual(model.selected?.name, "inside.md")
        XCTAssertNil(model.localOperationError)
    }

    func testCancellationAndEmptySelectionAreNoOpWhileRealFailuresSurvive() throws {
        let (model, _) = try fixture()
        var picker = LibraryImportPickerState()
        for value: Result<[URL], Error> in [.failure(CocoaError(.userCancelled)), .failure(CancellationError()), .success([])] {
            picker.present(.files, store: model.store, parentID: model.currentFolder)
            let id = try XCTUnwrap(picker.request?.id)
            let completion = try XCTUnwrap(picker.complete(value, requestID: id, store: model.store, parentID: model.currentFolder))
            XCTAssertNil(try completion.result.get())
            XCTAssertNil(picker.request)
            XCTAssertFalse(picker.isPresented)
        }
        picker.present(.files, store: model.store, parentID: model.currentFolder)
        let id = try XCTUnwrap(picker.request?.id)
        let completion = try XCTUnwrap(picker.complete(.failure(CocoaError(.fileReadNoPermission)), requestID: id, store: model.store, parentID: model.currentFolder))
        XCTAssertThrowsError(try completion.result.get()) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoPermission.rawValue)
        }
        XCTAssertTrue(try model.store.pending().isEmpty)
    }

    func testOldCompletionOrCancellationCannotConsumeNewRequest() throws {
        let (model, directory) = try fixture()
        var picker = LibraryImportPickerState()
        picker.present(.files, store: model.store, parentID: model.currentFolder)
        let oldID = try XCTUnwrap(picker.request?.id)
        picker.cancel(requestID: oldID)
        picker.present(.markdownFolder, store: model.store, parentID: model.currentFolder)
        let currentID = try XCTUnwrap(picker.request?.id)
        picker.cancel(requestID: oldID)
        XCTAssertNil(picker.complete(.success([directory.appendingPathComponent("late.md")]), requestID: oldID, store: model.store, parentID: model.currentFolder))
        XCTAssertEqual(picker.request?.id, currentID)
        XCTAssertTrue(picker.isPresented)
        let current = try XCTUnwrap(picker.complete(.success([directory]), requestID: currentID, store: model.store, parentID: model.currentFolder))
        XCTAssertEqual(try current.result.get(), .markdownFolder(directory))
    }

    func testWorkspaceOrDestinationChangeDiscardsLateSelection() throws {
        let (model, directory) = try fixture()
        let another = try DocumentStore(directory: directory.appendingPathComponent("other-library"))
        let file = directory.appendingPathComponent("late.md")
        try Data("Do not import into another destination".utf8).write(to: file)
        var picker = LibraryImportPickerState()
        picker.present(.files, store: model.store, parentID: "root")
        let oldID = try XCTUnwrap(picker.request?.id)
        XCTAssertNil(picker.complete(.success([file]), requestID: oldID, store: another, parentID: "root"))
        picker.present(.files, store: model.store, parentID: "root")
        let nextID = try XCTUnwrap(picker.request?.id)
        XCTAssertNil(picker.complete(.success([file]), requestID: nextID, store: model.store, parentID: "different-folder"))
        XCTAssertNil(picker.request)
        XCTAssertFalse(picker.isPresented)
        XCTAssertTrue(try model.store.pending().isEmpty)
        XCTAssertTrue(try another.pending().isEmpty)
    }
}
