// Two normal-API stages for the owned U5 fixture. Prepare uploads an unlinked blob;
// publish sends exactly the already frozen createPDF operation after fault arming.
import Foundation
import CryptoKit
import LibraryCore
struct PublishError: Error, CustomStringConvertible { let description:String }
func check(_ ok:Bool,_ text:String)throws{if !ok{throw PublishError(description:text)}}
func sha(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
func write(_ value:Any,_ url:URL)throws{try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)}
func logout(_ login:LoginResult,_ origin:URL) async throws {
    var request=URLRequest(url:origin.appendingPathComponent("api/v1/auth/logout"));request.httpMethod="POST";request.httpBody=Data("{}".utf8)
    request.setValue("Bearer \(login.sessionToken)",forHTTPHeaderField:"Authorization");request.setValue(login.epoch,forHTTPHeaderField:"X-Library-Epoch");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
    let(_,response)=try await URLSession.shared.data(for:request)
    try check((response as? HTTPURLResponse)?.statusCode==200,"synthetic publisher logout failed")
}
@main struct Publisher {
    static func main() async {do{try await run()}catch{fputs("FIXTURE_PUBLISHER_FAILED: \(error)\n",stderr);exit(1)}}
    static func run() async throws {
        let args=CommandLine.arguments;try check(args.count>=3,"prepare OR publish required")
        let env=ProcessInfo.processInfo.environment
        guard let user=env["TEST_TOKENLIBRARY_USER"],let password=env["TEST_TOKENLIBRARY_PASSWORD"] else{throw PublishError(description:"explicit synthetic credentials required")}
        if args[1]=="prepare" {
            try check(args.count==5,"prepare URL NEW_PLAN_DIRECTORY SYNTHETIC_PDF")
            let origin=try ServerAddress.normalize(args[2]);try check(origin.host=="127.0.0.1","loopback only")
            let out=URL(fileURLWithPath:args[3]).resolvingSymlinksInPath()
            try check(!FileManager.default.fileExists(atPath:out.path),"plan directory already exists")
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            let client=SyncClient(baseURL:origin),login=try await client.login(username:user,password:password)
            do {
                let store=try DocumentStore(directory:out.appendingPathComponent("producer"));_=try await client.synchronize(store:store)
                let bytes=try Data(contentsOf:URL(fileURLWithPath:args[4]))
                let asset=try store.importAttachment(data:bytes,fileName:"u5-new.pdf",mime:"application/pdf")
                try await client.uploadAttachment(asset,store:store)
                let id=UUID().uuidString.lowercased(),name="U5 新PDF下载恢复 \(id.prefix(8)).pdf"
                try store.saveDocument(LibraryDocument(id:id,kind:.pdf,parentId:login.rootId,name:name,markdown:"",pdfPath:try store.resolveAttachment(path:asset.path).path,revision:0,localGeneration:0,state:"active",purgeAt:nil,status:.pending,annotationsJSON:"[]",pdfBlobId:asset.blobId),enqueue:true)
                guard let operation=try store.pending().first(where:{$0.objectId==id}),let frozen=try store.prepareOperation(operation.operationId,epoch:login.epoch,deviceId:login.deviceId,serverOrigin:origin.absoluteString),let wire=frozen.requestJSON else{throw PublishError(description:"freeze failed")}
                let plan:[String:Any]=["origin":origin.absoluteString,"libraryId":login.libraryId,"epoch":login.epoch,"rootId":login.rootId,"deviceId":login.deviceId,"storeRoot":store.root.path,"objectId":id,"name":name,"operationId":operation.operationId,"requestSHA256":sha(Data(wire.utf8)),"target":["id":asset.blobId,"objectId":id,"path":asset.path,"sha256":asset.sha256,"size":asset.size],"stage":"uploaded-unpublished"]
                try await logout(login,origin);try write(plan,out.appendingPathComponent("prepared.json"));print("PREPARED \(out.appendingPathComponent("prepared.json").path)")
            }catch{try? await logout(login,origin);throw error}
        } else if args[1]=="publish" {
            try check(args.count==3,"publish PREPARED_JSON")
            let file=URL(fileURLWithPath:args[2]),out=file.deletingLastPathComponent()
            guard let plan=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],let rawOrigin=plan["origin"] as? String,let device=plan["deviceId"] as? String,let root=plan["storeRoot"] as? String,let id=plan["objectId"] as? String,let operation=plan["operationId"] as? String,let wireHash=plan["requestSHA256"] as? String,let target=plan["target"] as? [String:Any],let blob=target["id"] as? String else{throw PublishError(description:"invalid frozen plan")}
            let origin=try ServerAddress.normalize(rawOrigin);try check(origin.host=="127.0.0.1","loopback only")
            let client=SyncClient(baseURL:origin,deviceId:device),login=try await client.login(username:user,password:password)
            do {
                try check(login.libraryId==plan["libraryId"] as? String && login.epoch==plan["epoch"] as? String && login.rootId==plan["rootId"] as? String,"library/epoch/root changed")
                let store=try DocumentStore(directory:URL(fileURLWithPath:root))
                if let pending=try store.pending().first(where:{$0.operationId==operation}) {
                    try check(pending.objectId==id && pending.requestJSON.map{sha(Data($0.utf8))}==wireHash,"frozen operation changed")
                    try await client.flushPending(store:store,rootId:login.rootId)
                }
                let snapshot=try await client.fetchDocument(id:id)
                try check(snapshot["pdfBlobId"]?.string==blob && snapshot["name"]?.string==plan["name"] as? String,"published identity does not match frozen plan")
                try check(!(try store.pending()).contains(where:{$0.objectId==id}),"create receipt not durably applied")
                let raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot))
                try await logout(login,origin)
                try write(["snapshot":raw,"operationId":operation,"requestSHA256":wireHash,"publisherLoggedOut":true,"publishedAt":ISO8601DateFormatter().string(from:Date())],out.appendingPathComponent("published.json"))
                print("PUBLISHED \(id)")
            }catch{try? await logout(login,origin);throw error}
        }else{throw PublishError(description:"unknown action")}
    }
}
