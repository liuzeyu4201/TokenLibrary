import Foundation
import CryptoKit
import LibraryCore

struct ProbeFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: Bool, _ description: String) throws { if !condition { throw ProbeFailure(description: description) } }
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
func encode<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
func persist(_ value: Any, _ path: URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic) }
func signal(_ value: String) { print(value); fflush(stdout) }
func proceed(_ expected: String) throws { try expect(readLine()==expected,"expected orchestrator command \(expected)") }
func state(_ store: DocumentStore) throws -> [String:Any] {
    let coverage = try store.searchCoverage()
    return ["root":store.root.path,"cursor":store.syncCursor,"sendableCount":try store.pending().count,
            "documents":try encode(store.listDocuments(includeTrashed:true)),"pending":try encode(store.pending()),
            "searchableText":coverage.searchableText,"pendingPDFDownload":coverage.waitingDownload,"pendingIndex":coverage.waitingIndex]
}
@main struct AttachmentRecoveryProbe {
    static func main() async {
        do { try await run() } catch { fputs("ATTACHMENT_PROBE_FAILED: \(error)\n",stderr);exit(1) }
    }
    static func run() async throws {
        let args=CommandLine.arguments
        try expect(args.count==4,"usage: probe LOOPBACK_URL OWNED_OUTPUT FIXTURE_DIR")
        let origin=try ServerAddress.normalize(args[1]);try expect(origin.host=="127.0.0.1","only owned loopback")
        let output=URL(fileURLWithPath:args[2]).resolvingSymlinksInPath(),fixtures=URL(fileURLWithPath:args[3])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let env=ProcessInfo.processInfo.environment
        guard let user=env["TEST_TOKENLIBRARY_USER"],let password=env["TEST_TOKENLIBRARY_PASSWORD"] else { throw ProbeFailure(description:"explicit synthetic credentials required") }
        let a=SyncClient(baseURL:origin),b=SyncClient(baseURL:origin)
        let login=try await a.login(username:user,password:password);_=try await b.login(username:user,password:password)
        let storeA=try DocumentStore(directory:output.appendingPathComponent("a")),storeBRoot=output.appendingPathComponent("b")
        var storeB=try DocumentStore(directory:storeBRoot)
        _=try await a.synchronize(store:storeA);_=try await b.synchronize(store:storeB)
        let png=try Data(contentsOf:fixtures.appendingPathComponent("fixture-diagram.png")),pdf=try Data(contentsOf:fixtures.appendingPathComponent("research-three-pages.pdf"))
        let oldID=UUID().uuidString.lowercased(),pdfID=UUID().uuidString.lowercased(),imageID=UUID().uuidString.lowercased()
        let existing=try storeA.importAttachment(data:png,fileName:"existing.png",mime:"image/png")
        let oldBody="# OfflineSafeAnchor\n\n![已有可读图片](\(existing.path))\n", editedBody=oldBody+"\n下载失败时仍可本机编辑。\n"
        try storeA.localSaveOffline(markdown:oldBody,id:oldID,name:"已有离线资料.md",parentId:login.rootId)
        _=try await a.synchronize(store:storeA);_=try await b.synchronize(store:storeB)
        let baselineCursor=storeB.syncCursor
        func verifyExisting(_ expectedBody:String) throws {
            try expect(try storeB.loadDocument(id:oldID)?.markdown==expectedBody,"existing Markdown preserved")
            guard let existingURL=try storeB.assetURL(id:existing.blobId) else {throw ProbeFailure(description:"existing image unavailable")}
            try expect(try Data(contentsOf:existingURL)==png,"existing local image exact bytes")
            try expect(try storeB.search(query:"OfflineSafeAnchor").contains(oldID),"existing local text searchable")
        }
        try verifyExisting(oldBody)
        try persist(["a":try state(storeA),"b":try state(storeB)],output.appendingPathComponent("01-baseline.json"))
        let pdfAsset=try storeA.importAttachment(data:pdf,fileName:"recovery.pdf",mime:"application/pdf")
        try storeA.saveDocument(LibraryDocument(id:pdfID,kind:.pdf,parentId:login.rootId,name:"故障恢复三页论文.pdf",markdown:"",pdfPath:try storeA.resolveAttachment(path:pdfAsset.path).path,revision:0,localGeneration:0,state:"active",purgeAt:nil,status:.pending,annotationsJSON:"[]"),enqueue:true)
        _=try await a.synchronize(store:storeA)
        try persist(["id":pdfAsset.blobId,"objectId":pdfID,"sha256":sha(pdf),"size":pdf.count,"path":"media/\(pdfAsset.blobId).pdf"],output.appendingPathComponent("pdf-target.json"))
        signal("PDF_TARGET_READY");try proceed("pdf-503")
        let started=Date()
        var failure:SyncFailure?
        do { _=try await b.synchronize(store:storeB);throw ProbeFailure(description:"503 budget should fail") }
        catch let value as SyncFailure {failure=value}
        try expect(failure?.statusCode==503 && failure?.serverCode=="BUSY" && failure?.retryAfter==1 && failure?.isRetryable==true,"503 failure preserves BUSY/Retry-After/retry action")
        try expect(storeB.syncCursor==baselineCursor,"503 never advances cursor")
        try expect(try storeB.loadDocument(id:pdfID)==nil && storeB.assetURL(id:pdfAsset.blobId)==nil,"failed PDF not presented as installed")
        try verifyExisting(oldBody)
        _=try storeB.updateMarkdown(id:oldID,markdown:editedBody)
        storeB=try DocumentStore(directory:storeBRoot);try verifyExisting(editedBody)
        try expect(try storeB.pending().count==1,"local edit remains durable while cloud blob fails")
        try persist(["b":try state(storeB),"failureTitle":failure!.title,"failureMessage":failure!.message,"retryAfter":failure!.retryAfter!,"serverCode":failure!.serverCode!,"elapsed":Date().timeIntervalSince(started)],output.appendingPathComponent("02-503-failed.json"))
        signal("PDF_503_FAILED");try proceed("pdf-retry")
        _=try await b.synchronize(store:storeB)
        try verifyExisting(editedBody)
        guard let receivedPDF=try storeB.loadDocument(id:pdfID)?.pdfPath else {throw ProbeFailure(description:"PDF not installed after retry")}
        try expect(try Data(contentsOf:URL(fileURLWithPath:receivedPDF))==pdf,"retried PDF exact bytes")
        try expect(try storeB.search(query:"Research Anchor Beta").contains(pdfID),"retried PDF text indexed")
        try expect(storeB.syncCursor>baselineCursor && (try storeB.pending()).isEmpty,"cursor advances and offline edit flushes after recovery")
        try persist(["b":try state(storeB),"pdfSHA256":sha(try Data(contentsOf:URL(fileURLWithPath:receivedPDF)))],output.appendingPathComponent("03-pdf-recovered.json"))
        signal("PDF_RECOVERED");try proceed("add-image")
        let newImage=try storeA.importAttachment(data:png,fileName:"new-shared-content.png",mime:"image/png")
        let newBody="# AttachmentRecoveryAnchor\n\n![新图片与已有图像内容相同但blob独立](\(newImage.path))\n"
        try storeA.localSaveOffline(markdown:newBody,id:imageID,name:"新图片恢复验收.md",parentId:login.rootId)
        _=try await a.synchronize(store:storeA)
        try persist(["id":newImage.blobId,"objectId":imageID,"sha256":sha(png),"size":png.count,"path":newImage.path],output.appendingPathComponent("image-target.json"))
        let beforeImageCursor=storeB.syncCursor
        signal("IMAGE_TARGET_READY");try proceed("image-truncated")
        var integrityFailure:SyncFailure?
        do { _=try await b.synchronize(store:storeB);throw ProbeFailure(description:"short body should fail integrity") }
        catch let error as TransferError {try expect(error == .hashMismatch,"specific integrity failure");integrityFailure=SyncFailure.from(error)}
        try expect(integrityFailure?.title=="附件校验失败" && integrityFailure?.isRetryable==true,"integrity failure has readable normal retry guidance")
        try expect(storeB.syncCursor==beforeImageCursor,"truncated body never advances cursor")
        try expect(try storeB.loadDocument(id:imageID)==nil && storeB.assetURL(id:newImage.blobId)==nil,"truncated attachment never installed")
        try expect(!FileManager.default.fileExists(atPath:try storeB.resolveAttachment(path:newImage.path).path),"no partial file committed")
        try verifyExisting(editedBody)
        try expect(try Data(contentsOf:URL(fileURLWithPath:receivedPDF))==pdf,"other previously downloaded PDF still usable")
        try persist(["b":try state(storeB),"failureTitle":integrityFailure!.title,"failureMessage":integrityFailure!.message,"recoverySuggestion":integrityFailure!.recoverySuggestion!],output.appendingPathComponent("04-image-integrity-failed.json"))
        signal("IMAGE_TRUNCATED_FAILED");try proceed("image-retry")
        _=try await b.synchronize(store:storeB);_=try await a.synchronize(store:storeA)
        for store in [storeA,storeB] {
            try expect(try store.loadDocument(id:oldID)?.markdown==editedBody && store.loadDocument(id:imageID)?.markdown==newBody,"both clients exact final Markdown")
            guard let imageURL=try store.assetURL(id:newImage.blobId) else {throw ProbeFailure(description:"recovered image missing")}
            try expect(try Data(contentsOf:imageURL)==png,"recovered PNG exact bytes")
            try expect(try store.pending().isEmpty && store.conflicts().isEmpty,"final queue and conflict empty")
            try expect(try store.search(query:"AttachmentRecoveryAnchor").contains(imageID),"new Markdown indexed after valid attachment")
        }
        let remote=try await b.fetchDocument(id:oldID)
        try expect(remote["markdownSource"]?.string==editedBody,"offline edit exact on server")
        let coverage=try storeB.searchCoverage()
        try expect(coverage.waitingDownload==0 && coverage.waitingIndex==0,"no incomplete download/index after recovery")
        try persist(["passed":true,"libraryId":login.libraryId,"epoch":login.epoch,"rootId":login.rootId,"oldNoteID":oldID,"pdfID":pdfID,"newImageNoteID":imageID,"a":try state(storeA),"b":try state(storeB),"pdfSHA256":sha(pdf),"pngSHA256":sha(png),"scope":"Real Core HTTP and normal synchronize retries. Synthetic proxy content truncation with correct short Content-Length, not a broken TCP connection or native GUI."],output.appendingPathComponent("05-final.json"))
        signal("ATTACHMENT_RECOVERY_PASSED")
    }
}
