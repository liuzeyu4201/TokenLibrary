import SwiftUI
import WebKit
import UniformTypeIdentifiers
import LibraryCore
#if os(macOS)
import AppKit
#endif

@MainActor final class EditorBridgeHandle {
    weak var coordinator: EditorWebContent.Coordinator?
    func flush(_ completion: @escaping (Bool) -> Void) {
        guard let coordinator else { completion(false);return }
        coordinator.flush(completion)
    }
}

enum EditorLoadFailure: Equatable {
    case cancelled, missingResource, readDenied, timedOut, other

    init(error: Error) {
        var current = error as NSError
        // WebKit may wrap a local URL/Cocoa error. Keep traversal bounded and
        // never interpolate descriptions or URLs into the user-facing text.
        for _ in 0..<4 {
            if current.domain == NSURLErrorDomain {
                switch URLError.Code(rawValue: current.code) {
                case .cancelled: self = .cancelled; return
                case .fileDoesNotExist: self = .missingResource; return
                case .noPermissionsToReadFile: self = .readDenied; return
                case .timedOut: self = .timedOut; return
                default: break
                }
            } else if current.domain == NSCocoaErrorDomain {
                switch CocoaError.Code(rawValue: current.code) {
                case .fileNoSuchFile, .fileReadNoSuchFile: self = .missingResource; return
                case .fileReadNoPermission: self = .readDenied; return
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        self = .other
    }

    var message: String {
        switch self {
        case .missingResource:
            return "编辑器文件缺失或不可用。请更新或重新安装应用后重试；已保存笔记仍在本机。"
        case .readDenied:
            return "系统未允许读取编辑器文件。请重新打开应用后重试；已保存笔记仍在本机。"
        case .timedOut:
            return "本机编辑器载入超时。请重试打开；已保存笔记仍在本机。"
        case .cancelled, .other:
            return "本机编辑器暂时无法载入。请重试打开；已保存笔记仍在本机。"
        }
    }
}

@MainActor final class EditorHostState: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String) }
    struct PendingEdit: Equatable { let base: String; let proposed: String }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var reloadID = 0
    @Published private(set) var pendingEdit: PendingEdit?
    let store: DocumentStore
    let documentID: String
    private var session: MarkdownEditSession?
    private var attempt: UUID?
    private var initializing = false

    init(documentID: String, store: DocumentStore) { self.documentID=documentID;self.store=store }
    func beginLoad() -> UUID {
        let value=UUID();attempt=value;initializing=false;return value
    }
    func isCurrent(_ value:UUID) -> Bool { attempt == value }
    func isReady(_ value:UUID) -> Bool { isCurrent(value) && phase == .ready }
    func claimReady(_ value:UUID) -> Bool {
        guard isCurrent(value),phase == .loading,!initializing else { return false }
        initializing=true;return true
    }
    func completeReady(_ value:UUID,error:Error?) {
        guard isCurrent(value),phase == .loading,initializing else { return }
        if let error { fail(value,message:EditorLoadFailure(error:error).message) }
        else { phase = .ready }
    }
    func fail(_ value:UUID,message:String,onlyWhileLoading:Bool=false) {
        guard isCurrent(value),!onlyWhileLoading || phase == .loading else { return }
        phase = .failed(message)
    }
    func markdownForLoad() throws -> String {
        guard let document=try store.loadDocument(id:documentID),document.state == "active",document.kind == .md else {
            throw EditorEditError.unavailableDocument
        }
        if session == nil { session=try store.beginMarkdownEdit(id:documentID) }
        return document.markdown
    }
    func save(base:String,proposed:String) throws -> MarkdownEditSaveResult {
        do {
            if session == nil { session=try store.beginMarkdownEdit(id:documentID) }
            guard let session else { throw EditorEditError.unavailableDocument }
            let result=try session.save(baseMarkdown:base,proposedMarkdown:proposed)
            if pendingEdit != nil { pendingEdit=nil }
            return result
        } catch {
            pendingEdit=PendingEdit(base:base,proposed:proposed)
            throw error
        }
    }
    // Retry replaces only a failed WebKit instance. Any proposal already sent
    // to native must be durable (正文 or recovery draft) before losing the page.
    @discardableResult func prepareRetry() throws -> MarkdownEditSaveResult? {
        guard case .failed = phase else { return nil }
        do {
            let result=try pendingEdit.map { try save(base:$0.base,proposed:$0.proposed) }
            _ = try markdownForLoad()
            attempt=nil;initializing=false;reloadID += 1;phase = .loading
            return result
        } catch {
            let recovery = pendingEdit == nil ? "可以返回资料库确认笔记状态后重试。" : "未保存的输入仍保留在下方，可复制备份后重试。"
            phase = .failed("暂时无法重新打开：\(error.localizedDescription)。"+recovery)
            throw error
        }
    }
}

struct EditorWebView: View {
    let docId:String
    let markdown:String
    let store:DocumentStore
    let handle:EditorBridgeHandle
    let readOnly:Bool
    let searchText:String
    let onPersist:(DocumentStore)->Void
    let onError:(String)->Void
    let onOpenLink:(URL)->Void
    @StateObject private var host:EditorHostState

    init(docId:String,markdown:String,store:DocumentStore,handle:EditorBridgeHandle,readOnly:Bool=false,searchText:String="",
         onPersist:@escaping(DocumentStore)->Void,onError:@escaping(String)->Void,onOpenLink:@escaping(URL)->Void) {
        self.docId=docId;self.markdown=markdown;self.store=store;self.handle=handle;self.readOnly=readOnly;self.searchText=searchText
        self.onPersist=onPersist;self.onError=onError;self.onOpenLink=onOpenLink
        _host=StateObject(wrappedValue:EditorHostState(documentID:docId,store:store))
    }
    var body:some View {
        ZStack {
        EditorWebContent(markdown:markdown,host:host,handle:handle,readOnly:readOnly,searchText:searchText,
                         onPersist:onPersist,onError:onError,onOpenLink:onOpenLink)
            .id(host.reloadID)
            .allowsHitTesting(host.phase == .ready)
            .accessibilityHidden(host.phase != .ready)
                switch host.phase {
                case .ready: EmptyView()
                case .loading:
                    VStack(spacing:12) {
                        ProgressView()
                        Text("正在打开笔记…").font(.headline)
                        Text("正在准备本机编辑器与已保存内容。").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.regularMaterial)
                        .accessibilityElement(children:.combine).accessibilityIdentifier("editor-loading")
                case .failed(let message):
                    VStack(spacing:12) {
                        Label("编辑器暂时无法打开", ink: "exclamationmark.triangle").font(.headline)
                        Text(message).font(.callout).multilineTextAlignment(.center)
                        if let pending=host.pendingEdit {
                            Text("未保存的输入（可选择复制）").font(.caption)
                            ScrollView { Text(pending.proposed).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                                .frame(maxHeight:180).padding(8).background(.background)
                                .accessibilityIdentifier("editor-unsaved-input")
                        }
                        Button("重试打开") {
                            do {
                                if let result=try host.prepareRetry() {
                                    onPersist(store)
                                    if case .conflict = result { onError("冲突内容已保存为恢复草稿，可在“冲突与恢复草稿”中处理。") }
                                }
                            } catch { onError(error.localizedDescription) }
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("editor-retry")
                    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).background(.regularMaterial)
                        .accessibilityIdentifier("editor-load-error")
                }
            }
    }
}

struct EditorWebContent: ViewRepresentable {
    let markdown:String
    let host:EditorHostState
    let handle:EditorBridgeHandle
    var readOnly=false
    var searchText:String = ""
    var onPersist:(DocumentStore)->Void
    var onError:(String)->Void
    var onOpenLink:(URL)->Void

    func makeCoordinator() -> Coordinator {
        Coordinator(markdown:markdown,host:host,readOnly:readOnly,searchText:searchText,onPersist:onPersist,onError:onError,onOpenLink:onOpenLink)
    }
    #if canImport(UIKit)
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.detach(view) }
    #else
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.detach(view) }
    #endif
    private func make(_ context: Context) -> WKWebView {
        let config=WKWebViewConfiguration()
        for name in Coordinator.handlers { config.userContentController.add(context.coordinator,name:name) }
        config.setURLSchemeHandler(context.coordinator,forURLScheme:"library-asset")
        config.websiteDataStore = .nonPersistent()
        let view=WKWebView(frame:.zero,configuration:config)
        view.navigationDelegate=context.coordinator
        view.uiDelegate=context.coordinator
        context.coordinator.webView=view;handle.coordinator=context.coordinator
        context.coordinator.loadEditor(index:EditorBundle.indexHTML(in:.main),in:view)
        return view
    }
    private func update(_ view: WKWebView, _ context: Context) {
        let coordinator=context.coordinator
        coordinator.onPersist=onPersist;coordinator.onError=onError;coordinator.onOpenLink=onOpenLink
        handle.coordinator=coordinator
        if coordinator.readOnly != readOnly {
            coordinator.readOnly=readOnly
            if coordinator.ready { view.evaluateJavaScript("window.tlSetReadOnly(\(readOnly ? "true" : "false"))") }
        }
        if coordinator.searchText != searchText {
            coordinator.searchText=searchText
            if coordinator.ready,!searchText.isEmpty { view.evaluateJavaScript("window.tlFind(\(Coordinator.json(searchText)))") }
        }
        coordinator.acceptObservedMarkdown(markdown) { view.evaluateJavaScript($0) }
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
        static let handlers=["tlSave","tlReady","tlAttachment","tlOpenLink"]
        weak var webView:WKWebView?
        var observedMarkdown:String
        let host:EditorHostState
        var store:DocumentStore { host.store }
        let attempt:UUID
        private var loadTimeout:Task<Void,Never>?
        private var detached=false
        var readOnly:Bool
        var searchText:String
        var onPersist:(DocumentStore)->Void
        var onError:(String)->Void
        var onOpenLink:(URL)->Void
        var ready:Bool { !detached && host.isReady(attempt) }
        #if os(macOS)
        private var imagePanel:NSOpenPanel?
        #endif
        init(markdown:String,host:EditorHostState,readOnly:Bool,searchText:String,onPersist:@escaping(DocumentStore)->Void,onError:@escaping(String)->Void,onOpenLink:@escaping(URL)->Void) {
            self.observedMarkdown=markdown;self.host=host;self.attempt=host.beginLoad();self.searchText=searchText
            self.readOnly=readOnly
            self.onPersist=onPersist;self.onError=onError;self.onOpenLink=onOpenLink
        }
        func loadEditor(index:URL?,in view:WKWebView) {
            guard let index else {
                // Defer state publication until makeUIView/makeNSView returns.
                Task { @MainActor [weak self] in self?.failLoading(EditorLoadFailure.missingResource.message) }
                return
            }
            loadTimeout=Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds:20_000_000_000) } catch { return }
                guard let self,!self.detached else { return }
                self.host.fail(self.attempt,message:"编辑器加载时间过长。已保存笔记仍在本机，可以重试打开。",onlyWhileLoading:true)
            }
            view.loadFileURL(index,allowingReadAccessTo:index.deletingLastPathComponent())
        }
        func failLoading(_ message:String) {
            guard !detached else { return }
            loadTimeout?.cancel();host.fail(attempt,message:message)
        }
        func receiveNavigationFailure(_ error:Error) {
            let failure=EditorLoadFailure(error:error)
            guard failure != .cancelled else { return }
            failLoading(failure.message)
        }
        func acceptObservedMarkdown(_ fallback:String,evaluate:(String)->Void) {
            let latest=(try? store.loadDocument(id:host.documentID))?.markdown ?? fallback
            guard observedMarkdown != latest else { return }
            observedMarkdown=latest
            if ready {
                // A rejected refresh leaves the page's actual base intact for
                // its next transactional save; unchanged updates do nothing.
                evaluate("window.tlAcceptUpdate(\(Self.json(latest)))")
            }
        }
        func initializeReadyPage(using evaluate:@escaping(String,@escaping(Error?)->Void)->Void) {
            guard !detached,host.claimReady(attempt) else { return }
            do {
                let loaded=try host.markdownForLoad(),initialReadOnly=readOnly,initialSearch=searchText
                observedMarkdown=loaded
                var script=EditorScript.setMarkdown(loaded)+";window.tlSetReadOnly(\(initialReadOnly ? "true" : "false"));"
                if !initialSearch.isEmpty { script += "window.tlFind(\(Self.json(initialSearch)));" }
                evaluate(script) { [weak self] error in
                    guard let self,!self.detached else { return }
                    guard self.host.isCurrent(self.attempt),self.host.phase == .loading else { return }
                    self.loadTimeout?.cancel();self.observedMarkdown=loaded;self.host.completeReady(self.attempt,error:error)
                    guard self.ready else { return }
                    // A sync or archive may finish while initialization awaits
                    // WebKit. Reconcile through the clean-update gate, not a
                    // second setMarkdown that would reset an active edit base.
                    self.acceptObservedMarkdown(loaded) { evaluate($0) { _ in } }
                    if self.readOnly != initialReadOnly { evaluate("window.tlSetReadOnly(\(self.readOnly ? "true" : "false"))") { _ in } }
                    if self.searchText != initialSearch,!self.searchText.isEmpty { evaluate("window.tlFind(\(Self.json(self.searchText)))") { _ in } }
                }
            } catch { failLoading("无法读取这份笔记：\(error.localizedDescription)") }
        }
        static func json(_ value:Any)->String {
            guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]) else { return "null" }
            return String(decoding:data,as:UTF8.self)
        }
        @discardableResult private func save(base:String,proposed:String)->(Bool,String,String?,Bool) {
            do {
                switch try host.save(base:base,proposed:proposed) {
                case .saved(let canonical,_):
                    observedMarkdown=canonical;onPersist(store);return (true,canonical,nil,false)
                case .conflict(let canonical,_):
                    let message="另一处修改与当前输入重叠。你的内容已保存为恢复草稿，可在“冲突与恢复草稿”中处理。"
                    onPersist(store);onError(message);return (false,canonical,message,true)
                }
            } catch {
                let message="保存笔记失败：\(error.localizedDescription)"
                onError(message);return (false,observedMarkdown,message,false)
            }
        }
        func flush(_ completion:@escaping(Bool)->Void) {
            guard let webView,ready else { completion(false);return }
            webView.callAsyncJavaScript("return await window.tlFlushEdit();",arguments:[:],in:nil,in:.page,completionHandler:{ [self] result in
                receiveFlushResult(result,completion:completion)
            })
        }
        func receiveFlushResult(_ result:Result<Any,Error>,completion:(Bool)->Void) {
            // An old page can finish its close/export request after the user
            // has retried a failed editor. It must not navigate the new page.
            guard ready else { completion(false);return }
            guard case .success(let value)=result,let payload=value as? [String:Any],let saved=payload["saved"] as? Bool else {
                onError("无法保存编辑器的最后输入，请保留页面后重试。");completion(false);return
            }
            completion(saved)
        }
        func detach(_ view:WKWebView) {
            loadTimeout?.cancel()
            #if os(macOS)
            imagePanel?.cancel(nil)
            #endif
            // Retain the original workspace session until the last transaction is durable.
            flush { _ in
                self.detached=true
                for name in Self.handlers { view.configuration.userContentController.removeScriptMessageHandler(forName:name) }
                view.navigationDelegate=nil
                view.uiDelegate=nil
            }
        }
        #if os(macOS)
        func webView(_ webView:WKWebView,runOpenPanelWith parameters:WKOpenPanelParameters,
                     initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping @MainActor ([URL]?)->Void) {
            guard frame.isMainFrame,!readOnly,imagePanel == nil,let window=webView.window else {
                completionHandler(nil);return
            }
            // WKWebView cancels file inputs on macOS unless its host presents the panel.
            let panel=NSOpenPanel()
            panel.title="插入图片"
            panel.prompt="插入图片"
            panel.canChooseFiles=true;panel.canChooseDirectories=false
            panel.allowsMultipleSelection=false
            panel.allowedContentTypes=["png","jpg","webp","gif"].compactMap { UTType(filenameExtension:$0) }
            imagePanel=panel
            panel.beginSheetModal(for:window) { [weak self] response in
                self?.imagePanel=nil
                guard let self,self.ready,self.webView === webView,!self.readOnly,response == .OK else {
                    completionHandler(nil);return
                }
                completionHandler(panel.urls)
            }
        }
        #endif
        func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
            guard !detached,host.isCurrent(attempt),message.frameInfo.isMainFrame,message.webView === webView else { return }
            switch message.name {
            case "tlReady":
                initializeReadyPage { [weak self] script,completion in
                    guard let view=self?.webView else { completion(CocoaError(.fileReadUnknown));return }
                    view.evaluateJavaScript(script) { _,error in completion(error) }
                }
            case "tlSave":
                guard ready,let payload=message.body as? [String:Any],let request=payload["requestId"] as? NSNumber,
                      let base=payload["baseMarkdown"] as? String,let proposed=payload["proposedMarkdown"] as? String else { return }
                let result=save(base:base,proposed:proposed)
                let arguments:[Any]=[request,result.0,result.1,result.2 as Any? ?? NSNull(),result.3]
                webView?.evaluateJavaScript("window.tlSaveResult(...\(Self.json(arguments)))")
            case "tlAttachment":
                guard let values=message.body as? [String:String],let id=values["id"],let encoded=values["data"] else { return }
                do {
                    guard let data=Data(base64Encoded:encoded),data.count<=20*1024*1024,
                          let mime=values["mime"],["image/png","image/jpeg","image/webp","image/gif"].contains(mime) else { throw CocoaError(.fileReadCorruptFile) }
                    let asset=try store.importAttachment(data:data,fileName:values["name"] ?? "image.png",mime:mime)
                    webView?.evaluateJavaScript("window.tlAttachmentResult(...\(Self.json([id,asset.path,NSNull()])))")
                } catch { webView?.evaluateJavaScript("window.tlAttachmentResult(...\(Self.json([id,NSNull(),error.localizedDescription])))") }
            case "tlOpenLink":
                if let text=message.body as? String,let url=URL(string:text) { flush { saved in if saved { self.onOpenLink(url) } } }
            default:break
            }
        }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
            guard self.webView === webView else { return }
            receiveNavigationFailure(error)
        }
        func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {
            guard self.webView === webView else { return }
            receiveNavigationFailure(error)
        }
        func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {
            guard self.webView === webView else { return }
            failLoading("编辑器进程已结束。已保存内容仍在本机；重试将重新打开笔记。最后尚未送达的输入可能需要重新输入。")
        }
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url=navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated { flush { saved in if saved { self.onOpenLink(url) } };return .cancel }
            return url.isFileURL || url.scheme == "about" ? .allow : .cancel
        }
        func webView(_ webView:WKWebView,start urlSchemeTask:WKURLSchemeTask) {
            do {
                guard let request=urlSchemeTask.request.url,request.host == "local",request.path.hasPrefix("/media/") else { throw TransferError.invalidPath }
                let url=try store.resolveAttachment(path:String(request.path.dropFirst()))
                let data=try Data(contentsOf:url,options:.mappedIfSafe)
                let mime=UTType(filenameExtension:url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                urlSchemeTask.didReceive(URLResponse(url:request,mimeType:mime,expectedContentLength:data.count,textEncodingName:nil))
                urlSchemeTask.didReceive(data);urlSchemeTask.didFinish()
            } catch { urlSchemeTask.didFailWithError(error) }
        }
        func webView(_ webView:WKWebView,stop urlSchemeTask:WKURLSchemeTask) {}
    }
}
