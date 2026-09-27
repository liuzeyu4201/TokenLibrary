import Foundation
import PDFKit
import XCTest
@testable import LibraryCore
@testable import LibraryUI

@MainActor
final class PDFReadingTests: XCTestCase {
    func testManualPageInputAcceptsOnlyInRangeWholePagesWithoutClamping() throws {
        for (text,expected) in [("1",0),("8",7),(" 02 ",1),("0008",7)] {
            XCTAssertEqual(try PDFPageInput.pageIndex(text,totalPages:8).get(),expected)
        }
        for text in ["", " ", "0", "99", "-1", "+1", "1.0", "1e2", "一", "１", "1 2", String(repeating:"9",count:100)] {
            XCTAssertEqual(PDFPageInput.pageIndex(text,totalPages:8),.failure(.outOfRange(8)),text)
        }
        XCTAssertEqual(PDFPageInput.pageIndex("1",totalPages:0),.failure(.noPages))
        XCTAssertEqual(PDFPageInput.pageIndex("1",totalPages:-1),.failure(.noPages))
    }

    func testPageInputBoundsAreOverflowSafeAndErrorNamesActionableRange() throws {
        XCTAssertEqual(try PDFPageInput.pageIndex(String(Int.max),totalPages:Int.max).get(),Int.max-1)
        XCTAssertEqual(PDFPageInput.pageIndex(String(Int.max)+"0",totalPages:Int.max),.failure(.outOfRange(Int.max)))
        XCTAssertTrue(PDFPageInputError.outOfRange(8).localizedDescription.contains("1 至 8"))
        XCTAssertTrue(PDFPageInputError.outOfRange(8).localizedDescription.contains("未改变"))
    }

    func testRejectedManualPageInputCannotChangeReadingMetadataOrQueue() throws {
        try withModel { model,doc,source,_ in
            model.selectedId=doc.id
            var state=PDFReadingState()
            _=state.load(source:source,positions:[],deviceID:model.deviceId,navigation:nil)
            let before=try model.store.loadDocument(id:doc.id),queue=try model.store.pending()
            for text in ["99","0","", "abc",String(repeating:"9",count:100)] {
                if case .success(let index)=PDFPageInput.pageIndex(text,totalPages:source.pageCount),let event=state.visit(index,source:source) {
                    _=model.savePDFReadingPosition(event,documentID:doc.id,store:model.store)
                    XCTFail("Invalid manual page must never navigate")
                }
            }
            XCTAssertEqual(try model.store.loadDocument(id:doc.id),before)
            XCTAssertEqual(try model.store.pending(),queue)
            let valid=try PDFPageInput.pageIndex("3",totalPages:source.pageCount).get()
            XCTAssertTrue(model.savePDFReadingPosition(try XCTUnwrap(state.visit(valid,source:source)),documentID:doc.id,store:model.store))
            XCTAssertEqual(try model.store.loadDocument(id:doc.id)?.catalog.readingPositions.first?.pageIndex,2)
        }
    }

    func testInitialNavigationWaitsForAttachedStableLayoutAndRejectsFirstPageReset() {
        var gate=PDFInitialLayoutNavigation(targetPage:1)
        let viewport=CGSize(width:393,height:650)
        XCTAssertFalse(gate.observe(page:1,size:.zero,attached:false))
        XCTAssertFalse(gate.observe(page:1,size:viewport,attached:false))
        XCTAssertFalse(gate.observe(page:0,size:viewport,attached:true))
        XCTAssertFalse(gate.observe(page:1,size:viewport,attached:true))
        XCTAssertFalse(gate.observe(page:0,size:viewport,attached:true),"late first-layout reset must clear tentative success")
        XCTAssertFalse(gate.observe(page:1,size:viewport,attached:true))
        XCTAssertTrue(gate.observe(page:1,size:viewport,attached:true))
        XCTAssertFalse(gate.observe(page:1,size:viewport,attached:true),"installation must acknowledge only once")
    }

    func testViewportChangeAndReplacementDoNotInheritOldNavigationConfirmation() {
        var gate=PDFInitialLayoutNavigation(targetPage:2)
        XCTAssertFalse(gate.observe(page:2,size:CGSize(width:393,height:650),attached:true))
        XCTAssertFalse(gate.observe(page:2,size:CGSize(width:650,height:393),attached:true))
        XCTAssertFalse(gate.observe(page:nil,size:CGSize(width:650,height:393),attached:true))
        XCTAssertFalse(gate.observe(page:2,size:CGSize(width:650,height:393),attached:true))
        gate=PDFInitialLayoutNavigation(targetPage:0)
        XCTAssertFalse(gate.observe(page:2,size:CGSize(width:650,height:393),attached:true))
        XCTAssertFalse(gate.observe(page:0,size:CGSize(width:650,height:393),attached:true))
        XCTAssertTrue(gate.observe(page:0,size:CGSize(width:650,height:393),attached:true))
    }

    private func position(_ device:String,_ page:Int,_ date:Double,_ hash:String?="A")->CatalogReadingPosition {
        CatalogReadingPosition(deviceID:device,pageIndex:page,totalPages:10,fileHash:hash,updatedAt:Date(timeIntervalSince1970:date))
    }

    func testDefaultLoadRestoresLocalPageWithoutWritingOrOverridingNewerSuggestion() throws {
        let source=PDFReadingSource(identity:"paper|blob|path",fileHash:"A",pageCount:10)
        var state=PDFReadingState()
        let remote=position("phone",7,200)
        XCTAssertEqual(state.load(source:source,positions:[position("mac",2,100),remote],deviceID:"mac",navigation:nil),2)
        XCTAssertNil(state.installed(source:source),"restoring/default loading must not update timestamps")
        XCTAssertEqual(state.suggestion,remote)
        XCTAssertEqual(state.pageIndex,2)
    }

    func testRemoteSuggestionUpdatesWithoutJumpAndDismissesOnlyThatVersionOfPosition() throws {
        let source=PDFReadingSource(identity:"paper|blob|path",fileHash:"A",pageCount:10)
        var state=PDFReadingState()
        let local=position("mac",2,100),remote=position("phone",7,200)
        _=state.load(source:source,positions:[local],deviceID:"mac",navigation:nil)
        state.refresh(positions:[local,remote],deviceID:"mac")
        XCTAssertEqual(state.pageIndex,2);XCTAssertEqual(state.suggestion,remote)
        state.dismiss(remote)
        state.refresh(positions:[local,remote],deviceID:"mac")
        XCTAssertNil(state.suggestion)
        let newer=position("phone",7,300)
        state.refresh(positions:[local,newer],deviceID:"mac")
        XCTAssertEqual(state.suggestion,newer);XCTAssertEqual(state.pageIndex,2)
        let manual=position("manual",1,400)
        state.refresh(positions:[local,newer,manual],deviceID:"mac")
        XCTAssertEqual(state.suggestion,manual);XCTAssertEqual(state.pageIndex,2)
        _=state.visit(1,source:source)
        XCTAssertNil(state.suggestion)
    }

    func testUnknownChangedAndOutOfRangeVersionsNeverRestoreOrSuggest() throws {
        let source=PDFReadingSource(identity:"paper|new|path",fileHash:"new",pageCount:3)
        let stale=PDFReadingNavigation(sourceIdentity:source.identity,fileHash:"old",pageIndex:2)
        var state=PDFReadingState()
        let positions=[position("mac",2,100,nil),position("phone",1,200,"old"),position("manual",99,300,"new")]
        XCTAssertEqual(state.load(source:source,positions:positions,deviceID:"mac",navigation:stale),0)
        XCTAssertNil(state.suggestion);XCTAssertNil(state.installed(source:source))
        let unverified=PDFReadingSource(identity:source.identity,fileHash:nil,pageCount:3)
        XCTAssertEqual(state.load(source:unverified,positions:positions,deviceID:"mac",navigation:nil),0)
        XCTAssertNil(state.visit(1,source:unverified),"an unreadable hash must not create an unbound progress record")
    }

    func testLateEventsFromPriorInstallationCannotChangeCurrentStateEvenForSameFile() throws {
        let old=PDFReadingSource(identity:"paper|blob|path",fileHash:"A",pageCount:3)
        let current=PDFReadingSource(identity:old.identity,fileHash:old.fileHash,pageCount:3)
        var state=PDFReadingState()
        _=state.load(source:old,positions:[],deviceID:"mac",navigation:PDFReadingNavigation(sourceIdentity:old.identity,fileHash:"A",pageIndex:2))
        _=state.load(source:current,positions:[],deviceID:"mac",navigation:nil)
        XCTAssertNil(state.installed(source:old));XCTAssertNil(state.visit(2,source:old))
        XCTAssertNil(state.visit(-1,source:current));XCTAssertNil(state.visit(3,source:current))
        XCTAssertEqual(state.pageIndex,0)
    }

    private func withModel(_ test:(AppModel,LibraryDocument,PDFReadingSource,URL)throws->Void)throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reading-model-\(UUID().uuidString)")
        let suite="app.tokenlibrary.pdf-reading.\(UUID().uuidString)"
        let preferences=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { preferences.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:directory) }
        let model=try AppModel(directory:directory,preferences:preferences,restoreSavedSession:false)
        let pdf=PDFDocument()
        for index in 0..<3 {
            let part=try XCTUnwrap(PDFDocument(data:PDFExport.makeSamplePDF(text:"Page \(index+1)")))
            pdf.insert(try XCTUnwrap(part.page(at:0)),at:index)
        }
        let data=try XCTUnwrap(pdf.dataRepresentation())
        let asset=try model.store.importAttachment(data:data,fileName:"source.pdf",mime:"application/pdf")
        let doc=LibraryDocument(id:UUID().uuidString.lowercased(),kind:.pdf,parentId:"root",name:"source.pdf",markdown:"",
                                pdfPath:try model.store.resolveAttachment(path:asset.path).path,revision:0,localGeneration:0,
                                state:"active",purgeAt:nil,status:.savedLocal,annotationsJSON:"[]",pdfBlobId:asset.blobId)
        try model.store.saveDocument(doc,enqueue:false);model.reload()
        let source=PDFReadingSource(identity:PDFReadingSource.identity(for:doc),fileHash:BlobIntegrity.sha256(data),pageCount:3)
        try test(model,doc,source,directory)
    }

    func testSourceInitialNavigationAndSamePageGoToRepairPersistedProgress() throws {
        try withModel { model,doc,source,_ in
            _=try model.store.recordCatalogReadingPosition(id:doc.id,deviceID:model.deviceId,pageIndex:2,totalPages:3,fileHash:source.fileHash)
            model.reload();model.openSource(doc,page:1,hash:source.fileHash)
            let request=try XCTUnwrap(model.pdfNavigationRequest)
            var state=PDFReadingState()
            XCTAssertEqual(state.load(source:source,positions:try XCTUnwrap(model.store.loadDocument(id:doc.id)).catalog.readingPositions,
                                      deviceID:model.deviceId,navigation:request),1)
            model.consumePDFNavigation(request)
            XCTAssertNil(model.selectedPage);XCTAssertNil(model.pdfNavigationRequest)
            let initial=try XCTUnwrap(state.installed(source:source))
            XCTAssertTrue(model.savePDFReadingPosition(initial,documentID:doc.id,store:model.store))
            XCTAssertEqual(try model.store.loadDocument(id:doc.id)?.catalog.readingPositions.first?.pageIndex,1)
            XCTAssertNil(state.installed(source:source),"installation acknowledges explicit navigation exactly once")
            _=try model.store.recordCatalogReadingPosition(id:doc.id,deviceID:model.deviceId,pageIndex:2,totalPages:3,fileHash:source.fileHash)
            let samePage=try XCTUnwrap(state.visit(1,source:source))
            XCTAssertTrue(model.savePDFReadingPosition(samePage,documentID:doc.id,store:model.store))
            XCTAssertEqual(try model.store.loadDocument(id:doc.id)?.catalog.readingPositions.first?.pageIndex,1)
        }
    }

    func testNavigationHasOneShotIdentityAndModelRejectsReplacedPDFOrWorkspace() throws {
        try withModel { model,doc,source,directory in
            model.openSource(doc,page:1,hash:source.fileHash)
            let first=try XCTUnwrap(model.pdfNavigationRequest)
            model.openSource(doc,page:1,hash:source.fileHash)
            let second=try XCTUnwrap(model.pdfNavigationRequest)
            XCTAssertNotEqual(first.id,second.id)
            model.consumePDFNavigation(first)
            XCTAssertEqual(model.pdfNavigationRequest,second,"late consumption must not erase a newer same-page request")
            let originalStore=model.store
            let event=PDFReadingEvent(source:source,pageIndex:1)
            model.selectedId=nil
            XCTAssertFalse(model.savePDFReadingPosition(event,documentID:doc.id,store:originalStore),"a detached reader cannot save a late page event")
            model.selectedId=doc.id
            model.store=try DocumentStore(directory:directory.appendingPathComponent("Other"))
            XCTAssertFalse(model.savePDFReadingPosition(event,documentID:doc.id,store:originalStore))
            XCTAssertTrue(try originalStore.pending().isEmpty)
            model.store=originalStore
            var replacement=doc;replacement.pdfBlobId=UUID().uuidString.lowercased()
            try originalStore.saveDocument(replacement,enqueue:false);model.reload()
            XCTAssertFalse(model.savePDFReadingPosition(event,documentID:doc.id,store:originalStore))
            XCTAssertTrue(try originalStore.loadDocument(id:doc.id)?.catalog.readingPositions.isEmpty == true)
            XCTAssertTrue(try originalStore.pending().isEmpty)
        }
    }
}
