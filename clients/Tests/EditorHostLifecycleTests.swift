import XCTest
import Foundation
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class EditorHostLifecycleTests: XCTestCase {
    private func store(body:String="original") throws -> DocumentStore {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("editor-host-"+UUID().uuidString)
        let store=try DocumentStore(directory:root)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        _ = try store.createDocument(LibraryDocument(id:"note",kind:.md,parentId:"root",name:"note.md",markdown:body,pdfPath:nil,
                                                    revision:0,localGeneration:0,state:"active",purgeAt:nil,status:.pending,annotationsJSON:"[]"))
        return store
    }
    private func coordinator(_ host:EditorHostState,markdown:String="old UI snapshot") -> EditorWebContent.Coordinator {
        EditorWebContent.Coordinator(markdown:markdown,host:host,readOnly:false,searchText:"",onPersist:{ _ in },onError:{ _ in },onOpenLink:{ _ in })
    }
    private func failWrites(_ store:DocumentStore) throws {
        try store.db.write { db in
            try db.execute(sql:"CREATE TRIGGER fail_editor_update BEFORE UPDATE ON working_documents BEGIN SELECT RAISE(ABORT,'simulated disk error'); END")
        }
    }
    private func allowWrites(_ store:DocumentStore) throws { try store.db.write { try $0.execute(sql:"DROP TRIGGER fail_editor_update") } }

    func testReadyInitializesOnceAndNeverReplacesLaterTypedContent() throws {
        let store=try store(),host=EditorHostState(documentID:"note",store:store),coordinator=coordinator(host)
        var scripts:[String]=[]
        let evaluate:(String,@escaping(Error?)->Void)->Void={ script,done in scripts.append(script);done(nil) }
        coordinator.initializeReadyPage(using:evaluate)
        XCTAssertEqual(host.phase,.ready);XCTAssertEqual(scripts.count,1);XCTAssertTrue(scripts[0].contains("original"))
        _ = try host.save(base:"original",proposed:"original plus typed tail")
        coordinator.initializeReadyPage(using:evaluate)
        coordinator.acceptObservedMarkdown("original plus typed tail") { scripts.append($0) }
        let count=scripts.count
        coordinator.acceptObservedMarkdown("original plus typed tail") { scripts.append($0) }
        XCTAssertEqual(scripts.count,count)
        XCTAssertEqual(scripts.filter { $0.contains("window.tlSetMarkdown") }.count,1)
        XCTAssertEqual(try store.loadDocument(id:"note")?.markdown,"original plus typed tail")
        XCTAssertEqual(host.reloadID,0)
    }

    func testDelayedReadyAndFailureFromReplacedPageCannotAffectRetry() throws {
        let host=EditorHostState(documentID:"note",store:try store()),old=coordinator(host)
        var oldCompletion:((Error?)->Void)?
        old.initializeReadyPage { _,done in oldCompletion=done }
        old.failLoading("load failed")
        _ = try host.prepareRetry()
        let current=coordinator(host)
        oldCompletion?(nil);old.failLoading("late failure")
        XCTAssertEqual(host.phase,.loading)
        current.initializeReadyPage { _,done in done(nil) }
        XCTAssertEqual(host.phase,.ready);XCTAssertFalse(old.ready);XCTAssertTrue(current.ready)
        XCTAssertEqual(host.reloadID,1)
    }

    func testLateSuccessfulFlushCannotNavigateReplacementEditor() throws {
        let host=EditorHostState(documentID:"note",store:try store()),old=coordinator(host)
        old.initializeReadyPage { _,done in done(nil) }
        old.failLoading("process terminated")
        _ = try host.prepareRetry()
        let current=coordinator(host);current.initializeReadyPage { _,done in done(nil) }
        var oldAllowed:Bool?,newAllowed:Bool?
        old.receiveFlushResult(.success(["saved":true])) { oldAllowed=$0 }
        current.receiveFlushResult(.success(["saved":true])) { newAllowed=$0 }
        XCTAssertEqual(oldAllowed,false);XCTAssertEqual(newAllowed,true)
        XCTAssertTrue(current.ready)
    }

    func testTimeoutDoesNotTurnReadyEditorIntoFailureOrAutomaticallyReload() throws {
        let host=EditorHostState(documentID:"note",store:try store()),coordinator=coordinator(host)
        coordinator.initializeReadyPage { _,done in done(nil) }
        host.fail(coordinator.attempt,message:"late timer",onlyWhileLoading:true)
        XCTAssertEqual(host.phase,.ready);XCTAssertEqual(host.reloadID,0)
        coordinator.failLoading("real process termination")
        XCTAssertEqual(host.phase,.failed("real process termination"));XCTAssertFalse(coordinator.ready)
        coordinator.initializeReadyPage { _,_ in XCTFail("Failed page must not initialize again") }
        XCTAssertEqual(host.reloadID,0)
    }

    func testJavaScriptInitializationFailureStaysVisibleUntilExplicitRetry() throws {
        let host=EditorHostState(documentID:"note",store:try store()),coordinator=coordinator(host)
        coordinator.initializeReadyPage { _,done in done(NSError(domain:"test.javascript",code:1,userInfo:[NSLocalizedDescriptionKey:"missing script"])) }
        guard case .failed(let message)=host.phase else { return XCTFail("Must expose initialization error") }
        XCTAssertEqual(message,EditorLoadFailure.other.message);XCTAssertFalse(message.contains("missing script"));XCTAssertFalse(coordinator.ready)
        XCTAssertEqual(host.reloadID,0)
        _ = try host.prepareRetry();XCTAssertEqual(host.phase,.loading);XCTAssertEqual(host.reloadID,1)
    }

    func testSaveFailurePreventsDestructiveRetryAndRetainsOriginalProposal() throws {
        let store=try store(),host=EditorHostState(documentID:"note",store:store),coordinator=coordinator(host)
        coordinator.initializeReadyPage { _,done in done(nil) }
        try failWrites(store)
        XCTAssertThrowsError(try host.save(base:"original",proposed:"typed end \n"))
        coordinator.failLoading("process terminated")
        XCTAssertThrowsError(try host.prepareRetry())
        XCTAssertEqual(host.pendingEdit,.init(base:"original",proposed:"typed end \n"))
        XCTAssertEqual(host.reloadID,0);XCTAssertEqual(try store.loadDocument(id:"note")?.markdown,"original")
        try allowWrites(store)
        guard case .saved(let value,_)?=try host.prepareRetry() else { return XCTFail("Must durably save before retry") }
        XCTAssertEqual(value,"typed end \n");XCTAssertNil(host.pendingEdit)
        XCTAssertEqual(try store.loadDocument(id:"note")?.markdown,value)
        XCTAssertEqual(host.reloadID,1);XCTAssertEqual(host.phase,.loading)
    }

    func testRetryPersistsOverlappingFailedInputAsRecoveryDraftWithoutOverwritingRemote() throws {
        let store=try store(),host=EditorHostState(documentID:"note",store:store),coordinator=coordinator(host)
        coordinator.initializeReadyPage { _,done in done(nil) }
        try failWrites(store)
        XCTAssertThrowsError(try host.save(base:"original",proposed:"local replacement"))
        try allowWrites(store)
        _ = try store.saveMarkdownEdit(id:"note",baseMarkdown:"original",proposedMarkdown:"remote replacement")
        coordinator.failLoading("process terminated")
        guard case .conflict(let value,let id)?=try host.prepareRetry() else { return XCTFail("Overlap must become a durable recovery draft") }
        XCTAssertEqual(value,"remote replacement");XCTAssertEqual(try host.markdownForLoad(),value)
        let drafts=try store.editorDrafts(documentId:"note")
        XCTAssertEqual(drafts.count,1);XCTAssertEqual(drafts[0].id,id)
        XCTAssertEqual(drafts[0].proposedMarkdown,"local replacement");XCTAssertEqual(drafts[0].baseMarkdown,"original")
        XCTAssertNil(host.pendingEdit);XCTAssertEqual(host.reloadID,1)
    }

    func testLoadUsesBoundStoreAndReconcilesSyncThatFinishesDuringInitialization() throws {
        let original=try store(),other=try store(body:"other workspace")
        let host=EditorHostState(documentID:"note",store:original),coordinator=coordinator(host)
        var scripts:[String]=[],complete:((Error?)->Void)?
        coordinator.initializeReadyPage { script,done in
            scripts.append(script)
            if complete == nil { complete=done } else { done(nil) }
        }
        _ = try original.saveMarkdownEdit(id:"note",baseMarkdown:"original",proposedMarkdown:"new remote body")
        coordinator.acceptObservedMarkdown("stale model") { _ in XCTFail("Not ready yet") }
        complete?(nil)
        XCTAssertEqual(host.phase,.ready)
        XCTAssertEqual(scripts.filter { $0.contains("window.tlSetMarkdown") }.count,1)
        XCTAssertTrue(scripts.last?.contains("tlAcceptUpdate") == true)
        XCTAssertTrue(scripts.last?.contains("new remote body") == true)
        XCTAssertEqual(try other.loadDocument(id:"note")?.markdown,"other workspace")
        XCTAssertEqual(host.reloadID,0)
    }

    func testArchiveAndSearchChangesWhileLoadingApplyAfterInitializationWithoutSecondReset() throws {
        let host=EditorHostState(documentID:"note",store:try store()),coordinator=coordinator(host)
        var scripts:[String]=[],complete:((Error?)->Void)?
        coordinator.initializeReadyPage { script,done in
            scripts.append(script)
            if complete == nil { complete=done } else { done(nil) }
        }
        coordinator.readOnly=true;coordinator.searchText="latest query"
        complete?(nil)
        XCTAssertEqual(host.phase,.ready)
        XCTAssertEqual(scripts.filter { $0.contains("window.tlSetMarkdown") }.count,1)
        XCTAssertTrue(scripts.contains { $0 == "window.tlSetReadOnly(true)" })
        XCTAssertTrue(scripts.contains { $0.contains("window.tlFind") && $0.contains("latest query") })
        XCTAssertEqual(host.reloadID,0)
    }

    func testDeletedDocumentCannotInitializeOrBeResurrectedByRetry() throws {
        let store=try store(),host=EditorHostState(documentID:"note",store:store),coordinator=coordinator(host)
        try store.trash(id:"note")
        coordinator.initializeReadyPage { _,_ in XCTFail("Do not load deleted document into editable page") }
        guard case .failed = host.phase else { return XCTFail("Deletion must be visible") }
        XCTAssertThrowsError(try host.prepareRetry())
        XCTAssertEqual(host.reloadID,0);XCTAssertEqual(try store.loadDocument(id:"note")?.state,"trashed")
    }

    func testLocalFileErrorsAreClassifiedWithoutExposingSystemDescriptionOrPath() {
        let detail="The requested URL was not found on this server. /private/tmp/secret-install/editor/index.html"
        let cases:[(String,Int,EditorLoadFailure)] = [
            (NSURLErrorDomain,URLError.fileDoesNotExist.rawValue,.missingResource),
            (NSCocoaErrorDomain,CocoaError.fileReadNoSuchFile.rawValue,.missingResource),
            (NSCocoaErrorDomain,CocoaError.fileNoSuchFile.rawValue,.missingResource),
            (NSURLErrorDomain,URLError.noPermissionsToReadFile.rawValue,.readDenied),
            (NSCocoaErrorDomain,CocoaError.fileReadNoPermission.rawValue,.readDenied),
            (NSURLErrorDomain,URLError.timedOut.rawValue,.timedOut),
            ("unrelated.error",URLError.fileDoesNotExist.rawValue,.other)
        ]
        for (domain,code,expected) in cases {
            let error=NSError(domain:domain,code:code,userInfo:[NSLocalizedDescriptionKey:detail,NSURLErrorFailingURLStringErrorKey:"file:///private/tmp/secret-install/editor/index.html"])
            let failure=EditorLoadFailure(error:error)
            XCTAssertEqual(failure,expected)
            XCTAssertTrue(failure.message.contains("重试"))
            XCTAssertFalse(failure.message.contains("secret-install"));XCTAssertFalse(failure.message.contains("requested URL"))
            XCTAssertFalse(failure.message.contains(".。"));XCTAssertFalse(failure.message.contains("。。"))
        }
    }

    func testWrappedFilePermissionFailureUsesLocalActionableMessage() {
        let denied=NSError(domain:NSCocoaErrorDomain,code:CocoaError.fileReadNoPermission.rawValue,
                           userInfo:[NSFilePathErrorKey:"/private/tmp/private-install/index.html"])
        let wrapped=NSError(domain:"WebKitErrorDomain",code:101,userInfo:[NSUnderlyingErrorKey:denied])
        XCTAssertEqual(EditorLoadFailure(error:wrapped),.readDenied)
        XCTAssertTrue(EditorLoadFailure(error:wrapped).message.contains("系统未允许读取"))
        XCTAssertFalse(EditorLoadFailure(error:wrapped).message.contains("private-install"))
    }

    func testOnlyActualURLCancellationIsIgnoredAndLoadFailurePreservesStoredInput() throws {
        let store=try store(body:"saved body \n"),host=EditorHostState(documentID:"note",store:store),coordinator=coordinator(host)
        let original=try store.loadDocument(id:"note"),pending=try store.pending()
        coordinator.receiveNavigationFailure(URLError(.cancelled))
        XCTAssertEqual(host.phase,.loading)
        coordinator.receiveNavigationFailure(NSError(domain:"unrelated.error",code:URLError.cancelled.rawValue,
                                                      userInfo:[NSLocalizedDescriptionKey:"Do not show this raw path /private/tmp/install"]))
        XCTAssertEqual(host.phase,.failed(EditorLoadFailure.other.message))
        XCTAssertEqual(host.reloadID,0);XCTAssertEqual(try store.loadDocument(id:"note"),original)
        XCTAssertEqual(try store.pending().map(\.operationId),pending.map(\.operationId))
        _ = try host.prepareRetry()
        let replacement=self.coordinator(host)
        replacement.receiveNavigationFailure(URLError(.fileDoesNotExist))
        XCTAssertEqual(host.phase,.failed(EditorLoadFailure.missingResource.message))
        XCTAssertEqual(try store.loadDocument(id:"note"),original)
    }
}
