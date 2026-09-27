import Foundation
import PDFKit
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class AppModelTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL
        let preferenceName: String
        let preferences: UserDefaults
        let model: AppModel
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenlibrary-model-tests-\(UUID().uuidString)")
            preferenceName = "app.tokenlibrary.model-tests.\(UUID().uuidString)"
            preferences = try XCTUnwrap(UserDefaults(suiteName: preferenceName))
            model = try AppModel(directory: directory, preferences: preferences, restoreSavedSession: false)
        }
        func clean() {
            preferences.removePersistentDomain(forName: preferenceName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @discardableResult
    private func seed(_ model: AppModel, id: String = UUID().uuidString.lowercased(), kind: DocKind = .md,
                      parent: String = "root", name: String = "note.md", body: String = "body", metadata: String = "{}",
                      path: String? = nil, blob: String? = nil) throws -> LibraryDocument {
        let document = LibraryDocument(id: id, kind: kind, parentId: parent, name: name, markdown: kind == .md ? body : "",
                                       pdfPath: path, revision: 0, localGeneration: 0, state: "active", purgeAt: nil,
                                       status: .savedLocal, annotationsJSON: "[]", metadataJSON: metadata, pdfBlobId: blob)
        try model.store.saveDocument(document, enqueue: false)
        model.reload()
        return document
    }

    func testSwitchToLocalClearsServerSyncFeedbackAndPreservesLocalQueue() throws {
        let f=try Fixture();defer { f.clean() }
        f.model.newNote()
        let local=f.model.store,queue=try local.pending()
        f.model.store=try f.model.workspaces.store(server:URL(string:"https://status.invalid")!,libraryId:"status")
        f.model.isLocalWorkspace=false
        f.model.setConnectionBanner("资料与附件已同步。")
        f.model.connectionError="old server failure"
        f.model.showLocalLibrary()
        XCTAssertTrue(f.model.isLocalWorkspace);XCTAssertTrue(f.model.store === local)
        XCTAssertEqual(f.model.banner,"");XCTAssertNil(f.model.connectionError)
        XCTAssertEqual(try local.pending(),queue);XCTAssertEqual(f.model.pendingCount,queue.count)
        XCTAssertFalse(f.model.syncing)
    }

    func testUseOfflineClearsLoginCheckFeedbackWithoutChangingLocalEdits() throws {
        let f=try Fixture();defer { f.clean() }
        f.model.newNote()
        let store=f.model.store,selection=f.model.selectedId,queue=try store.pending()
        f.model.showConnection()
        f.model.setConnectionBanner("服务器可连接。输入账号密码后登录。")
        f.model.connectionError="旧的连接失败"
        f.model.reportLocal("导入",message:"缺少图片，原文未导入")
        let localError=f.model.localOperationError
        f.model.useOffline()
        XCTAssertTrue(f.model.offlineAccess);XCTAssertTrue(f.model.isLocalWorkspace)
        XCTAssertTrue(f.model.store === store);XCTAssertEqual(f.model.selectedId,selection)
        XCTAssertEqual(try store.pending(),queue)
        XCTAssertEqual(f.model.banner,"");XCTAssertNil(f.model.connectionError)
        XCTAssertEqual(f.model.localOperationError,localError)
    }

    func testUseOfflineRetainsConnectedWorkspaceAndNonConnectionResult() throws {
        let f=try Fixture();defer { f.clean() }
        let server=URL(string:"https://offline-status.invalid")!
        f.model.store=try f.model.workspaces.store(server:server,libraryId:"offline-status")
        f.model.isLocalWorkspace=false
        let login=LoginResult(sessionToken:"synthetic",epoch:"epoch",rootId:"root",libraryId:"offline-status",deviceId:"test")
        f.model.newNote()
        f.model.session=login;f.model.client=SyncClient(baseURL:server)
        let store=f.model.store,selection=f.model.selectedId,queue=try store.pending(),client=f.model.client
        f.model.showConnection()
        f.model.banner="已复制 3 项本机资料，原本机副本保留。"
        f.model.connectionError="旧连接失败"
        f.model.useOffline()
        XCTAssertTrue(f.model.offlineAccess);XCTAssertFalse(f.model.isLocalWorkspace)
        XCTAssertTrue(f.model.store === store);XCTAssertTrue(f.model.client === client)
        XCTAssertEqual(f.model.session?.sessionToken,login.sessionToken)
        XCTAssertEqual(f.model.selectedId,selection);XCTAssertEqual(try store.pending(),queue)
        XCTAssertEqual(f.model.banner,"已复制 3 项本机资料，原本机副本保留。")
        XCTAssertNil(f.model.connectionError)
    }

    func testClearingConnectionStatusKeepsCurrentLocalErrorAndCopyResult() throws {
        let f=try Fixture();defer { f.clean() }
        f.model.reportLocal("导入",message:"keep local failure")
        let error=f.model.localOperationError
        f.model.setConnectionBanner("资料与附件已同步。")
        f.model.banner="已复制 3 项本机资料，原本机副本保留。"
        f.model.connectionBusy=true
        f.model.connectionError="expired server"
        f.model.showLocalLibrary()
        XCTAssertEqual(f.model.localOperationError,error)
        XCTAssertEqual(f.model.banner,"已复制 3 项本机资料，原本机副本保留。")
        XCTAssertNil(f.model.connectionError)
    }

    func testSwitchToConnectedLibraryClearsStaleServerFeedbackBeforeNewSync() throws {
        let f=try Fixture();defer { f.model.showLocalLibrary();f.clean() }
        f.model.client=SyncClient(baseURL:URL(string:"https://status.invalid")!)
        f.model.session=LoginResult(sessionToken:"synthetic",epoch:"epoch",rootId:"root",libraryId:"status",deviceId:"test")
        f.model.setConnectionBanner("旧库已同步")
        f.model.connectionError="old failure"
        f.model.showConnectedLibrary()
        XCTAssertFalse(f.model.isLocalWorkspace)
        XCTAssertEqual(f.model.banner,"");XCTAssertNil(f.model.connectionError)
    }

    func testVirtualRootAndServerRootNavigationNeverEscapesToEmptyParent() throws {
        let f = try Fixture(); defer { f.clean() }
        XCTAssertEqual(f.model.currentFolder, "root")
        XCTAssertTrue(f.model.isAtRoot)
        f.model.newNote()
        XCTAssertEqual(f.model.selected?.parentId, "root")
        let serverRoot = try seed(f.model, kind: .folder, parent: "", name: "Server library")
        try f.model.store.bindWorkspace(server: "https://navigation.invalid", libraryId: "navigation", rootId: serverRoot.id)
        f.model.session = LoginResult(sessionToken: "synthetic", epoch: "epoch", rootId: serverRoot.id, libraryId: "navigation", deviceId: "test")
        f.model.isLocalWorkspace = false
        let nested = try seed(f.model, kind: .folder, parent: serverRoot.id, name: "Nested")
        f.model.currentFolder = nested.id
        XCTAssertFalse(f.model.isAtRoot)
        XCTAssertEqual(f.model.rootFor(nested.id), serverRoot.id)
        f.model.goUp()
        XCTAssertTrue(f.model.isAtRoot)
        XCTAssertEqual(f.model.currentFolder, serverRoot.id)
        f.model.goUp()
        XCTAssertEqual(f.model.currentFolder, serverRoot.id)
        f.model.newNote()
        XCTAssertEqual(f.model.selected?.parentId, serverRoot.id)
        XCTAssertFalse(f.model.savedRoots.contains(""))
    }

    func testLastSuccessfulSyncPersistsAndIsScopedToWorkspace() throws {
        let f=try Fixture();defer { f.clean() }
        let date=Date(timeIntervalSince1970:1_800_000_000)
        f.model.recordSuccessfulSync(at:date)
        f.model.reload()
        XCTAssertEqual(f.model.lastSyncAt,date)
        let reopened=try AppModel(directory:f.directory,preferences:f.preferences,restoreSavedSession:false)
        XCTAssertEqual(reopened.lastSyncAt,date)
        let other=try f.model.workspaces.store(server:URL(string:"https://synthetic.invalid")!,libraryId:"different-library")
        f.model.store=other;f.model.reload()
        XCTAssertNil(f.model.lastSyncAt)
        f.model.reportConnection(URLError(.cannotConnectToHost))
        XCTAssertNil(f.model.lastSyncAt)
        f.model.showLocalLibrary()
        XCTAssertEqual(f.model.lastSyncAt,date)
    }

    func testLegacyPersistedRootRemainsNavigableWithoutPromotingUnknownParents() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("legacy-model-\(UUID().uuidString)")
        let suite="legacy-model-\(UUID().uuidString)"
        let preferences=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { preferences.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:directory) }
        let root=UUID().uuidString.lowercased(),unknown=UUID().uuidString.lowercased()
        preferences.set(root,forKey:"connection.rootId")
        preferences.set("https://legacy.invalid",forKey:"connection.server")
        let oldStore=try DocumentStore(directory:directory)
        let folder=LibraryDocument(id:UUID().uuidString.lowercased(),kind:.folder,parentId:root,name:"Old folder",markdown:"",pdfPath:nil,revision:0,localGeneration:0,state:"active",purgeAt:nil,status:.savedLocal,annotationsJSON:"[]")
        try oldStore.saveDocument(folder,enqueue:false)
        var orphan=folder;orphan.id=UUID().uuidString.lowercased();orphan.kind = .md;orphan.parentId=unknown;orphan.name="unresolved.md";orphan.markdown="preserved"
        try oldStore.saveDocument(orphan,enqueue:false)
        let model=try AppModel(directory:directory,preferences:preferences,restoreSavedSession:false)
        XCTAssertTrue(model.savedRoots.contains(root))
        XCTAssertFalse(model.savedRoots.contains(unknown))
        XCTAssertEqual(model.unresolvedDocuments.map(\.id),[orphan.id])
        model.currentFolder=root;model.newNote()
        XCTAssertEqual(model.selected?.parentId,root)
        model.currentFolder=folder.id;model.newNote()
        XCTAssertEqual(model.selected?.parentId,folder.id)
        XCTAssertEqual(model.rootFor(folder.id),root)
        XCTAssertEqual(try oldStore.loadDocument(id:orphan.id)?.markdown,"preserved")
    }

    func testNewFilesDoNotBecomeChildrenOfTopicsOrDeletedFolders() throws {
        let f = try Fixture(); defer { f.clean() }
        let topic = try f.model.store.createCatalogTopic(name: "Topic", parentID: "root")
        f.model.reload(); f.model.currentFolder = topic.id
        let before = try f.model.store.listDocuments().count
        f.model.newNote(); f.model.newFolder()
        XCTAssertEqual(try f.model.store.listDocuments().count, before)
        XCTAssertNotNil(f.model.localOperationError)
        let folder = try seed(f.model, kind: .folder, name: "Deleted folder")
        f.model.currentFolder = folder.id
        try f.model.store.trash(id: folder.id)
        f.model.newNote()
        XCTAssertFalse(try f.model.store.listDocuments().contains { $0.parentId == folder.id })
    }

    func testMoveHierarchyConflictsAndCyclesRemainRecoverable() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try seed(f.model, kind: .folder, name: "A")
        let b = try seed(f.model, kind: .folder, name: "B")
        let child = try seed(f.model, kind: .folder, parent: a.id, name: "child")
        let note = try seed(f.model, parent: a.id, name: "note.md", body: "preserved")
        XCTAssertTrue(f.model.move(note, to: b.id))
        XCTAssertEqual(try f.model.store.loadDocument(id: note.id)?.parentId, b.id)
        XCTAssertEqual(try f.model.store.loadDocument(id: note.id)?.markdown, "preserved")
        XCTAssertFalse(f.model.move(a, to: child.id))
        XCTAssertEqual(try f.model.store.loadDocument(id: a.id)?.parentId, "root")
        let duplicate = try seed(f.model, parent: a.id, name: "NOTE.md")
        XCTAssertFalse(f.model.move(duplicate, to: b.id))
        XCTAssertEqual(try f.model.store.loadDocument(id: duplicate.id)?.parentId, a.id)
        XCTAssertNotNil(f.model.localOperationError)
    }

    func testRenameUsesCurrentParentAfterDocumentWasMoved() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try seed(f.model, kind: .folder, name: "A")
        let b = try seed(f.model, kind: .folder, name: "B")
        let stale = try seed(f.model, parent: a.id, name: "original.md")
        _ = try seed(f.model, parent: a.id, name: "target.md")
        XCTAssertTrue(f.model.move(stale, to: b.id))
        f.model.rename(stale, to: "target")
        XCTAssertEqual(try f.model.store.loadDocument(id: stale.id)?.name, "target.md")
        XCTAssertEqual(try f.model.store.loadDocument(id: stale.id)?.parentId, b.id)
    }

    func testDelayedOldWorkspaceEditCannotWriteNewWorkspaceWithSameDocumentID() throws {
        let f = try Fixture(); defer { f.clean() }
        let original = try seed(f.model, body: "old workspace")
        let oldStore = f.model.store
        let editor = try oldStore.beginMarkdownEdit(id: original.id)
        let other = try DocumentStore(directory: f.directory.appendingPathComponent("Other"))
        f.model.store = other
        _ = try seed(f.model, id: original.id, body: "new workspace")
        _ = try editor.save("last keystroke in old workspace")
        f.model.reload()
        XCTAssertEqual(try oldStore.loadDocument(id: original.id)?.markdown, "last keystroke in old workspace")
        XCTAssertEqual(f.model.documents.first(where: { $0.id == original.id })?.markdown, "new workspace")
        XCTAssertTrue(try other.pending().isEmpty)
    }

    func testOldWorkspacePDFSaveUsesCapturedStoreAndRejectedStaleFilePreservesDraft() throws {
        let f = try Fixture(); defer { f.clean() }
        let original = try seed(f.model, kind: .pdf, name: "paper.pdf", path: "/isolated/original.pdf", blob: "old-blob")
        let oldStore = f.model.store
        let other = try DocumentStore(directory: f.directory.appendingPathComponent("Other"))
        f.model.store = other
        _ = try seed(f.model, id: original.id, kind: .pdf, name: "other.pdf", path: "/isolated/other.pdf", blob: "new-blob")
        let annotation = PDFTextAnnotation(type: "comment", pageIndex: 0, x: 1, y: 1, width: 20, height: 20, color: "#FFEE33", text: "saved to original", pdfBlobId: "old-blob")
        XCTAssertTrue(f.model.savePDFAnnotations(document: original, store: oldStore, base: [], proposed: [annotation]))
        XCTAssertEqual(try other.loadDocument(id: original.id)?.annotationsJSON, "[]")
        XCTAssertTrue(try XCTUnwrap(oldStore.loadDocument(id: original.id)).annotationsJSON.contains("saved to original"))
        var replaced = try XCTUnwrap(other.loadDocument(id: original.id)); replaced.pdfBlobId = "third-blob"
        try other.saveDocument(replaced, enqueue: false)
        XCTAssertFalse(f.model.savePDFAnnotations(document: original, store: other, base: [], proposed: [annotation]))
        XCTAssertEqual(try other.loadDocument(id: original.id)?.annotationsJSON, "[]")
        XCTAssertEqual(try other.editorDrafts().count, 1)
        XCTAssertNotNil(f.model.localOperationError)
    }

    func testSearchFindsArchivedBodyAndExcludesTrashWithCoverageAndSelection() async throws {
        let f = try Fixture(); defer { f.clean() }
        let note = try seed(f.model, body: "A Chinese 量子 study with keyword")
        _ = try f.model.store.setCatalogArchived(id: note.id, archived: true)
        let trashed = try seed(f.model, name: "deleted.md", body: "量子 keyword")
        try f.model.store.trash(id: trashed.id)
        _ = try seed(f.model, kind: .pdf, name: "pending.pdf")
        f.model.reload(); f.model.query = "量子"
        try await waitUntil { !f.model.searching }
        XCTAssertEqual(f.model.visibleDocs().map(\.id), [note.id])
        XCTAssertEqual(f.model.searchCoverage?.waitingDownload, 1)
        XCTAssertTrue(f.model.searchResults.first?.excerpt.contains("量子") == true)
        f.model.selectLibraryRow(note.id)
        XCTAssertEqual(f.model.navigationSearch, "量子")
        f.model.query = ""
        XCTAssertTrue(f.model.searchResults.isEmpty)
        XCTAssertNil(f.model.searchCoverage)
    }

    func testSearchSwitchingWorkspaceDoesNotDisplayOldResults() async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try seed(f.model, body: "oldkeyword")
        f.model.query = "oldkeyword"
        f.model.store = try DocumentStore(directory: f.directory.appendingPathComponent("Other"))
        _ = try seed(f.model, body: "newkeyword")
        f.model.query = "newkeyword"
        try await waitUntil { !f.model.searching }
        XCTAssertEqual(f.model.visibleDocs().count, 1)
        XCTAssertTrue(f.model.searchResults.first?.excerpt.contains("newkeyword") == true)
        XCTAssertFalse(f.model.searchResults.contains { $0.excerpt.contains("oldkeyword") })
    }

    func testRejectedLocalWriteDisplaysErrorWithoutPhantomNoteOrSelection() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.model.store.db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_test_note BEFORE INSERT ON working_documents BEGIN SELECT RAISE(ABORT,'test disk failure'); END")
        }
        f.model.newNote()
        XCTAssertTrue(f.model.documents.isEmpty)
        XCTAssertNil(f.model.selectedId)
        XCTAssertTrue(try f.model.store.pending().isEmpty)
        XCTAssertTrue(f.model.localOperationError?.contains("新建笔记失败") == true)
    }

    func testImportCorruptPDFAndInvalidUTF8DoesNotCreateSuccessfulEntries() throws {
        let f = try Fixture(); defer { f.clean() }
        let pdf = f.directory.appendingPathComponent("corrupt.pdf")
        try Data("not a pdf".utf8).write(to: pdf)
        f.model.importFile(url: pdf)
        XCTAssertTrue(f.model.documents.isEmpty)
        XCTAssertNotNil(f.model.localOperationError)
        let md = f.directory.appendingPathComponent("invalid.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: md)
        f.model.importFile(url: md)
        XCTAssertTrue(f.model.documents.isEmpty)
        XCTAssertTrue(try f.model.store.pending().isEmpty)
        let valid = f.directory.appendingPathComponent("valid.md")
        try Data("# 离线笔记\n\nBody".utf8).write(to: valid)
        f.model.importFile(url: valid)
        let imported = try XCTUnwrap(f.model.documents.first)
        XCTAssertEqual(imported.markdown, "# 离线笔记\n\nBody")
        XCTAssertTrue(imported.catalog.inbox)
        XCTAssertEqual(imported.catalog.originalFilename, "valid.md")
        XCTAssertNil(f.model.localOperationError, "a new explicit import attempt replaces the prior import error")
        XCTAssertNil(f.model.connectionError)
    }

    func testLegacySourceLinkUsesStoredFileHashAndRefusesChangedPage() throws {
        let f = try Fixture(); defer { f.clean() }
        let path = f.directory.appendingPathComponent("changed.pdf")
        try Data("new bytes".utf8).write(to: path)
        let source = try seed(f.model, kind: .pdf, name: "paper.pdf", path: path.path)
        var metadata = CatalogMetadata(category: .note)
        metadata.excerpts = [CatalogExcerpt(sourceID: source.id, sourceTitle: "paper", quote: "old quote", pageIndex: 4, fileHash: BlobIntegrity.sha256(Data("old bytes".utf8)))]
        let note = try seed(f.model, metadata: metadata.json())
        f.model.selectedId = note.id
        f.model.openDocumentLink(try XCTUnwrap(URL(string: "tokenlibrary://document/\(source.id)?page=5")))
        XCTAssertEqual(f.model.selectedId, source.id)
        XCTAssertNil(f.model.selectedPage)
        XCTAssertTrue(f.model.banner.contains("变化"))
        XCTAssertEqual(f.model.sourceReturnNote?.id,note.id)
        f.model.returnToReadingNote()
        XCTAssertEqual(f.model.selectedId,note.id)
        XCTAssertNil(f.model.sourceReturnNote)
    }

    func testSourceReturnFollowsRenamedMovedNoteAndClearsAcrossWorkspace() throws {
        let f=try Fixture();defer { f.clean() }
        let note=try seed(f.model,name:"reading.md")
        let source=try seed(f.model,kind:.pdf,name:"source.pdf")
        let folder=try seed(f.model,kind:.folder,name:"Moved notes")
        f.model.openDocument(note)
        f.model.openSource(source,page:nil,hash:nil)
        XCTAssertTrue(f.model.move(note,to:folder.id))
        f.model.rename(note,to:"Renamed reading")
        f.model.returnToReadingNote()
        XCTAssertEqual(f.model.currentFolder,folder.id)
        XCTAssertEqual(f.model.selected?.name,"Renamed reading.md")
        f.model.openSource(source,page:nil,hash:nil)
        f.model.showLocalLibrary()
        XCTAssertNil(f.model.sourceReturnNote)
    }

    func testRelatedNavigationDoesNotInheritSearchHitOrChangeStoredContent() async throws {
        let f=try Fixture();defer { f.clean() }
        let a=try seed(f.model,name:"a.md",body:"U7NavigationToken first note\n")
        let b=try seed(f.model,name:"b.md",body:"U7NavigationToken second note\n")
        _=try f.model.store.setCatalogRelated(id:a.id,targetID:b.id,included:true)
        f.model.reload();f.model.searchPresented=true;f.model.query="U7NavigationToken"
        try await waitUntil { !f.model.searching }
        let documents=try f.model.store.listDocuments(),queue=try f.model.store.pending()
        let hits=f.model.searchResults
        XCTAssertEqual(Set(hits.map(\.objectId)),Set([a.id,b.id]))
        f.model.openDocument(a)
        f.model.openDocument(b) // Catalog related/source/backlink callbacks use this ordinary entry.
        XCTAssertEqual(f.model.selectedId,b.id);XCTAssertEqual(f.model.navigationSearch,"")
        f.model.openDocument(a)
        XCTAssertEqual(f.model.selectedId,a.id);XCTAssertEqual(f.model.navigationSearch,"")
        XCTAssertEqual(f.model.query,"U7NavigationToken");XCTAssertTrue(f.model.searchPresented)
        XCTAssertEqual(f.model.searchResults,hits)
        XCTAssertEqual(try f.model.store.listDocuments(),documents);XCTAssertEqual(try f.model.store.pending(),queue)
    }

    func testOrdinaryPDFAndSourceReturnDoNotInheritUnrelatedSearchPage() async throws {
        let f=try Fixture();defer { f.clean() }
        let token="U7PageNavigationToken",bytes=PDFExport.makeSamplePDF(text:"U7PageNavigationToken")
        let asset=try f.model.store.importAttachment(data:bytes,fileName:"source.pdf",mime:"application/pdf")
        let pdf=try seed(f.model,kind:.pdf,name:"source.pdf",path:try f.model.store.resolveAttachment(path:asset.path).path,blob:asset.blobId)
        let note=try seed(f.model,name:"reading.md",body:token+" reading note\n")
        f.model.query=token;try await waitUntil { !f.model.searching }
        XCTAssertEqual(f.model.searchResults.first(where:{$0.objectId == pdf.id})?.pageIndex,0)
        let rows=try f.model.store.listDocuments(),queue=try f.model.store.pending()
        f.model.openDocument(pdf)
        XCTAssertNil(f.model.selectedPage);XCTAssertNil(f.model.pdfNavigationRequest)
        XCTAssertEqual(f.model.navigationSearch,"")
        f.model.openDocument(note)
        f.model.openSource(pdf,page:0,hash:asset.sha256)
        XCTAssertEqual(f.model.pdfNavigationRequest?.pageIndex,0,"Explicit verified source location still works")
        XCTAssertEqual(f.model.navigationSearch,"");XCTAssertEqual(f.model.sourceReturnNote?.id,note.id)
        f.model.returnToReadingNote()
        XCTAssertEqual(f.model.selectedId,note.id);XCTAssertEqual(f.model.navigationSearch,"")
        XCTAssertNil(f.model.selectedPage);XCTAssertNil(f.model.pdfNavigationRequest)
        XCTAssertEqual(f.model.query,token)
        XCTAssertEqual(try f.model.store.listDocuments(),rows);XCTAssertEqual(try f.model.store.pending(),queue)
    }

    func testExplicitLibrarySearchSelectionStillLocatesTextAndPDFButDoesNotLeakToNextOpen() async throws {
        let f=try Fixture();defer { f.clean() }
        let token="ExplicitSearchNavigation",bytes=PDFExport.makeSamplePDF(text:"ExplicitSearchNavigation")
        let asset=try f.model.store.importAttachment(data:bytes,fileName:"search.pdf",mime:"application/pdf")
        let pdf=try seed(f.model,kind:.pdf,name:"search.pdf",path:try f.model.store.resolveAttachment(path:asset.path).path,blob:asset.blobId)
        let note=try seed(f.model,name:"search.md",body:token+" tail \n")
        f.model.query=token;try await waitUntil { !f.model.searching }
        let rows=try f.model.store.listDocuments(),queue=try f.model.store.pending()
        f.model.selectLibraryRow(note.id)
        XCTAssertEqual(f.model.navigationSearch,token);XCTAssertNil(f.model.pdfNavigationRequest)
        f.model.selectLibraryRow(pdf.id)
        XCTAssertEqual(f.model.navigationSearch,token);XCTAssertEqual(f.model.pdfNavigationRequest?.pageIndex,0)
        XCTAssertEqual(f.model.pdfNavigationRequest?.fileHash,asset.sha256)
        f.model.openDocument(pdf) // Same selected ID, now reached through an ordinary link.
        XCTAssertEqual(f.model.navigationSearch,"");XCTAssertNil(f.model.pdfNavigationRequest)
        f.model.selectLibraryRow(pdf.id) // Explicitly selecting that search row works again.
        XCTAssertEqual(f.model.pdfNavigationRequest?.pageIndex,0)
        f.model.selectLibraryRow(nil)
        XCTAssertNil(f.model.selectedId);XCTAssertEqual(f.model.navigationSearch,"")
        XCTAssertNil(f.model.selectedPage);XCTAssertNil(f.model.pdfNavigationRequest)
        XCTAssertEqual(f.model.query,token)
        f.model.query="";f.model.selectLibraryRow(note.id)
        XCTAssertEqual(f.model.selectedId,note.id);XCTAssertEqual(f.model.navigationSearch,"")
        XCTAssertEqual(try f.model.store.listDocuments(),rows);XCTAssertEqual(try f.model.store.pending(),queue)
    }

    func testRepeatedSelectedPDFSearchActivationRequestsHitAfterManualNavigationWithoutWritingProgress() async throws {
        let f=try Fixture();defer { f.clean() }
        let token="RepeatPDFResultToken",pdfFile=PDFDocument()
        for (index,text) in ["First page",token,"Last page"].enumerated() {
            let part=try XCTUnwrap(PDFDocument(data:PDFExport.makeSamplePDF(text:text)))
            pdfFile.insert(try XCTUnwrap(part.page(at:0)),at:index)
        }
        let asset=try f.model.store.importAttachment(data:try XCTUnwrap(pdfFile.dataRepresentation()),fileName:"repeat.pdf",mime:"application/pdf")
        let pdf=try seed(f.model,kind:.pdf,name:"repeat.pdf",path:try f.model.store.resolveAttachment(path:asset.path).path,blob:asset.blobId)
        f.model.query=token;try await waitUntil { !f.model.searching }
        XCTAssertEqual(f.model.searchResults.first(where:{$0.objectId == pdf.id})?.pageIndex,1)
        XCTAssertFalse(f.model.isSelectedPDFSearchResult(pdf.id))
        f.model.selectLibraryRow(pdf.id)
        let initial=try XCTUnwrap(f.model.pdfNavigationRequest)
        XCTAssertEqual(initial.pageIndex,1);f.model.consumePDFNavigation(initial)
        let source=PDFReadingSource(identity:PDFReadingSource.identity(for:pdf),fileHash:asset.sha256,pageCount:3)
        XCTAssertTrue(f.model.savePDFReadingPosition(PDFReadingEvent(source:source,pageIndex:0),documentID:pdf.id,store:f.model.store))
        let rows=try f.model.store.listDocuments(),queue=try f.model.store.pending(),hits=f.model.searchResults
        XCTAssertTrue(f.model.isSelectedPDFSearchResult(pdf.id))
        XCTAssertTrue(f.model.activateSelectedPDFSearchResult(pdf.id))
        let repeatRequest=try XCTUnwrap(f.model.pdfNavigationRequest)
        XCTAssertEqual(repeatRequest.pageIndex,1);XCTAssertNotEqual(repeatRequest.id,initial.id)
        XCTAssertTrue(repeatRequest.matches(source))
        // A previous PDFKit completion cannot consume a newer repeat click.
        XCTAssertTrue(f.model.activateSelectedPDFSearchResult(pdf.id))
        let latest=try XCTUnwrap(f.model.pdfNavigationRequest)
        XCTAssertNotEqual(latest.id,repeatRequest.id)
        f.model.consumePDFNavigation(repeatRequest)
        XCTAssertEqual(f.model.pdfNavigationRequest?.id,latest.id)
        f.model.consumePDFNavigation(latest)
        XCTAssertNil(f.model.pdfNavigationRequest)
        f.model.openDocument(pdf) // Ordinary related navigation still restores its own last page.
        XCTAssertNil(f.model.pdfNavigationRequest);XCTAssertEqual(f.model.navigationSearch,"")
        XCTAssertTrue(f.model.activateSelectedPDFSearchResult(pdf.id))
        XCTAssertEqual(f.model.pdfNavigationRequest?.pageIndex,1)
        XCTAssertEqual(f.model.query,token);XCTAssertEqual(f.model.searchResults,hits)
        XCTAssertEqual(try f.model.store.listDocuments(),rows);XCTAssertEqual(try f.model.store.pending(),queue)
    }

    func testRepeatedPDFSearchActivationRejectsChangedContextAndDeletedCurrentDocument() async throws {
        let f=try Fixture();defer { f.clean() }
        let token="RepeatPDFGuardToken"
        let asset=try f.model.store.importAttachment(data:PDFExport.makeSamplePDF(text:token),fileName:"guard.pdf",mime:"application/pdf")
        let pdf=try seed(f.model,kind:.pdf,name:"guard.pdf",path:try f.model.store.resolveAttachment(path:asset.path).path,blob:asset.blobId)
        let note=try seed(f.model,name:"guard.md",body:token)
        f.model.query=token;try await waitUntil { !f.model.searching }
        f.model.openDocument(note)
        XCTAssertFalse(f.model.activateSelectedPDFSearchResult(pdf.id))
        XCTAssertFalse(f.model.activateSelectedPDFSearchResult(note.id))
        XCTAssertNil(f.model.pdfNavigationRequest)
        f.model.openDocument(pdf)
        let hits=f.model.searchResults
        f.model.query="";f.model.searchResults=hits // A stale search row must not carry its old intent.
        XCTAssertFalse(f.model.activateSelectedPDFSearchResult(pdf.id));XCTAssertNil(f.model.pdfNavigationRequest)
        f.model.query=token;try await waitUntil { !f.model.searching }
        try f.model.store.trash(id:pdf.id) // Deliberately leave the displayed documents snapshot stale.
        let rows=try f.model.store.listDocuments(),queue=try f.model.store.pending()
        XCTAssertFalse(f.model.activateSelectedPDFSearchResult(pdf.id));XCTAssertNil(f.model.pdfNavigationRequest)
        XCTAssertEqual(try f.model.store.listDocuments(),rows);XCTAssertEqual(try f.model.store.pending(),queue)
    }


    func testLoginFailureStaysOnConnectionScreenWhileExpiredSyncKeepsOfflineWork() throws {
        let f = try Fixture(); defer { f.clean() }
        XCTAssertFalse(f.model.offlineAccess)
        f.model.reportConnection(SyncFailure.http(code: 401), invalidatesSession: false)
        XCTAssertFalse(f.model.offlineAccess, "wrong password must not dismiss the login screen")
        XCTAssertNotNil(f.model.connectionError)
        let note = try seed(f.model, body: "unsent work")
        f.model.session = LoginResult(sessionToken: "synthetic", epoch: "epoch", rootId: "root", libraryId: "test", deviceId: "test")
        f.model.reportConnection(SyncFailure.http(code: 401))
        XCTAssertNil(f.model.session)
        XCTAssertTrue(f.model.offlineAccess)
        XCTAssertEqual(try f.model.store.loadDocument(id: note.id)?.markdown, "unsent work")
    }

    func testCancelledWorkspaceSyncCanBeStartedAgainWithoutStaleCallbacks() async throws {
        let f = try Fixture(); defer { f.clean() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineModelProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        OfflineModelProtocol.reset()
        let client = SyncClient(baseURL: try XCTUnwrap(URL(string: "https://model-sync.invalid")), deviceId: "test", session: session, retryPolicy: .none)
        let login = LoginResult(sessionToken: "synthetic", epoch: "epoch", rootId: "root", libraryId: "test", deviceId: "test")
        client.restoreSession(login)
        f.model.client = client; f.model.session = login; f.model.isLocalWorkspace = false
        f.model.requestSync()
        f.model.showLocalLibrary()
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(OfflineModelProtocol.count, 0, "a cancelled delayed sync must not contact its former workspace")
        XCTAssertFalse(f.model.syncing)
        XCTAssertNil(f.model.connectionError)
        f.model.isLocalWorkspace = false
        f.model.requestSync()
        try await waitUntil { OfflineModelProtocol.count > 0 && !f.model.syncing }
        XCTAssertEqual(OfflineModelProtocol.count, 1)
        XCTAssertNotNil(f.model.connectionError, "new run must complete and surface its own offline failure")
        f.model.showLocalLibrary()
    }

    func testSuccessfulBackgroundSyncKeepsRejectedPDFReasonUntilExplicitDismissal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SuccessfulModelProtocol.self]
        let urlSession = URLSession(configuration:config)
        defer { urlSession.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string:"https://model-sync.invalid"))
        let login = LoginResult(sessionToken:"synthetic",epoch:"epoch",rootId:"root",libraryId:"test",deviceId:"test")
        let client = SyncClient(baseURL:url,deviceId:"test",session:urlSession,retryPolicy:.none)
        client.restoreSession(login)
        try f.model.store.applyRemoteBatch([],deletedIds:[],cursor:0,epoch:"epoch")
        f.model.client=client;f.model.session=login;f.model.isLocalWorkspace=false
        f.model.reportConnection(URLError(.cannotConnectToHost))
        let connectionFailure=f.model.connectionError
        let corrupt=f.directory.appendingPathComponent("corrupt.pdf")
        try Data("not a PDF".utf8).write(to:corrupt)
        f.model.importFile(url:corrupt)
        let localFailure=try XCTUnwrap(f.model.localOperationError)
        XCTAssertTrue(localFailure.contains(PDFImportError.corrupt.localizedDescription))
        XCTAssertEqual(f.model.connectionError,connectionFailure)
        f.model.requestSync()
        try await waitUntil { f.model.lastSyncAt != nil && !f.model.syncing }
        XCTAssertEqual(f.model.localOperationError,localFailure,"background sync must not erase the import rejection")
        XCTAssertNil(f.model.connectionError,"successful sync clears only its own connection failure")
        XCTAssertEqual(f.model.banner,"资料与附件已同步。")
        f.model.dismissLocalOperationError()
        XCTAssertNil(f.model.localOperationError)
    }

    func testLocalErrorDismissalAndWorkspaceSwitchDoNotMixConnectionState() throws {
        let f=try Fixture();defer { f.clean() }
        f.model.reportConnection(URLError(.cannotConnectToHost))
        let connectionFailure=f.model.connectionError
        f.model.reportLocal("导入",error:PDFImportError.passwordRequired)
        let localFailure=f.model.localOperationError
        f.model.dismissLocalOperationError(for:"导出")
        XCTAssertEqual(f.model.localOperationError,localFailure,"an unrelated operation cannot dismiss another failure")
        let sameWorkspace=try DocumentStore(directory:f.model.store.root)
        f.model.store=sameWorkspace
        XCTAssertEqual(f.model.localOperationError,localFailure,"same-library login preserves local feedback")
        f.model.dismissLocalOperationError()
        XCTAssertNil(f.model.localOperationError)
        XCTAssertEqual(f.model.connectionError,connectionFailure)
        f.model.reportLocal("导入",error:PDFImportError.passwordRequired)
        f.model.store=try DocumentStore(directory:f.directory.appendingPathComponent("Other"))
        XCTAssertNil(f.model.localOperationError,"a different library must not inherit the former library's error")
        XCTAssertEqual(f.model.connectionError,connectionFailure)
    }

    func testWorkspaceStatusDistinguishesServerOfflineFromIndependentLocalLibrary() throws {
        let f=try Fixture();defer { f.clean() }
        XCTAssertEqual(f.model.workspaceStatusTitle,"本机文档")
        f.model.isLocalWorkspace=false
        XCTAssertEqual(f.model.workspaceStatusTitle,"服务器资料库（离线）")
        f.model.session=LoginResult(sessionToken:"synthetic",epoch:"epoch",rootId:"root",libraryId:"test",deviceId:"test")
        XCTAssertEqual(f.model.workspaceStatusTitle,"服务器资料库")
        f.model.isLocalWorkspace=true
        XCTAssertEqual(f.model.workspaceStatusTitle,"本机文档","a saved connection does not change which library is open")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("asynchronous model operation did not settle")
    }
}

/// All requests remain inside the process; this fixture never reaches the network.
private final class OfflineModelProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts = 0
    static var count: Int { lock.withLock { starts } }
    static func reset() { lock.withLock { starts = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.starts += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// A complete empty-library sync response; exercises the actual scheduled success path without network access.
private final class SuccessfulModelProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard let url=request.url,url.path == "/api/v1/sync/changes" else {
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
        }
        let data=Data(#"{"data":{"epoch":"epoch","changes":[],"nextCursor":"0","hasMore":false}}"#.utf8)
        let response=HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
