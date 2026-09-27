import SwiftUI
import Combine
import LibraryCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import PDFKit
import WebKit
import UniformTypeIdentifiers

struct LibraryExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Test-only launch configuration. Release builds never resolve an override;
/// Info.plist selection is restricted to separately identified verification apps.
enum LibraryVerificationConfiguration {
    static func directory(arguments: [String], bundleID: String?, infoDirectory: String?,
                          temporaryDirectory: URL, debugBuild: Bool) -> URL? {
        guard debugBuild else { return nil }
        if let index = arguments.firstIndex(of: "--verification-directory"),
           arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        }
        let prefix = "app.tokenlibrary.verification."
        if let bundleID, bundleID.hasPrefix(prefix), bundleID.count > prefix.count,
           let infoDirectory, infoDirectory.hasPrefix("/") {
            return URL(fileURLWithPath: infoDirectory, isDirectory: true).standardizedFileURL
        }
        if bundleID == "app.tokenlibrary.verification" {
            return temporaryDirectory.appendingPathComponent("TokenLibrary-UI-verification-20260926", isDirectory: true)
        }
        return nil
    }
}

private func libraryConnectedClient(url: URL, deviceId: String) -> SyncClient {
    #if os(iOS)
    let downloadsBodies = false
    #else
    let downloadsBodies = true
    #endif
    return SyncClient(baseURL: url, deviceId: deviceId, deviceName: DeviceIdentity.name, platform: DeviceIdentity.platform, downloadsBodies: downloadsBodies)
}

@MainActor
final class AppModel: ObservableObject {
    /// Cloud library on mycloud. A previously saved address replaces it.
    static let defaultServerAddress = "http://123.58.215.34"
    #if os(iOS)
    static let connectedSyncBanner = "已连接，正在同步目录…"
    static let syncFinishedBanner = "目录已同步。打开某一本时再下载文件。"
    static func syncIdleLine(_ at: Date) -> String { "目录已同步 · \(at.formatted(date: .omitted, time: .shortened))。文件在打开时下载。" }
    #else
    static let connectedSyncBanner = "已连接，正在同步资料与附件…"
    static let syncFinishedBanner = "资料与附件已同步。"
    static func syncIdleLine(_ at: Date) -> String { "已和服务器同步 · \(at.formatted(date: .omitted, time: .shortened))" }
    #endif
    struct SourceReturnContext { let noteID:String;let sourceID:String }
    // A Debug-only isolated directory lets UI smoke tests avoid the user's library.
    private static var verificationDirectory: URL? {
        #if DEBUG
        return LibraryVerificationConfiguration.directory(arguments: ProcessInfo.processInfo.arguments,
            bundleID: Bundle.main.bundleIdentifier,
            infoDirectory: Bundle.main.object(forInfoDictionaryKey: "TokenLibraryVerificationDirectory") as? String,
            temporaryDirectory: FileManager.default.temporaryDirectory, debugBuild: true)
        #else
        return nil
        #endif
    }
    private static let defaultPreferences: UserDefaults = {
        if let directory = verificationDirectory {
            return UserDefaults(suiteName: "app.tokenlibrary.verification.\(directory.lastPathComponent)")!
        }
        return .standard
    }()
    @Published var session: LoginResult?
    private let preferences:UserDefaults
    @Published var username = "token"
    @Published var password = ""
    @Published var server = ""
    @Published var offlineAccess = false
    @Published var connectionBusy = false
    @Published private(set) var restoringSession = false
    @Published private(set) var credentialNotice: String?
    @Published var syncing = false
    @Published var connectionError: String?
    @Published private(set) var localOperationError: String?
    private var localOperationAction: String?
    @Published var pendingCount = 0
    @Published var exportPresented = false
    @Published var exportFile: LibraryExportFile?
    @Published var exportName = ""
    @Published var exportType: UTType = .plainText
    @Published var importNotice:String?
    private var connectionTask: Task<Void, Never>?
    private var connectionRunID: UUID?
    private var sessionRestoreTask: Task<Void, Never>?
    private var sessionRestoreID: UUID?
    private var syncTask: Task<Void, Never>?
    private var syncRequested = false
    private var syncRunID: UUID?
    let deviceId:String
    @Published var documents: [LibraryDocument] = []
    @Published var libraryInventory:LegacyLibraryInventory?
    @Published var sourceReturnContext:SourceReturnContext?
    @Published var selectedId: String? {
        didSet {
            if sourceReturnContext?.sourceID != selectedId { sourceReturnContext=nil }
            selectedPage=nil;pdfNavigationRequest=nil
            navigationSearch=""
        }
    }
    @Published var query = "" { didSet { updateSearch() } }
    @Published var searchPresented = false
    @Published var searchResults:[LibrarySearchHit]=[]
    @Published var searchTruncated=false
    @Published var openDownloadError: String?
    @Published var searching=false
    @Published var searchCoverage:LibrarySearchCoverage?
    @Published var navigationSearch=""
    private var searchTask:Task<Void,Never>?
    @Published var renameTarget: LibraryDocument?
    @Published var moveTarget:LibraryDocument?
    @Published var renameDraft = ""
    @Published var banner = "" { didSet { bannerIsConnectionStatus=false } }
    private var bannerIsConnectionStatus=false
    @Published var currentFolder = "root" {
        didSet { preferences.set(currentFolder, forKey: "library.lastFolder") }
    }
    @Published var folderName = "资料库"
    @Published var store: DocumentStore {
        didSet {
            // Reopening the same server library during login must keep its local error.
            if oldValue.root.standardizedFileURL != store.root.standardizedFileURL {
                dismissLocalOperationError()
                libraryStamp = nil
            }
        }
    }
    let workspaces: LibraryWorkspaceManager
    let localStore: DocumentStore
    let sessionVault: SessionVault
    private let credentials: any SessionCredentialStore
    private let makeClient: @Sendable (URL, String) -> SyncClient
    @Published var isLocalWorkspace = true
    @Published var selectedPage: Int?
    @Published private(set) var pdfNavigationRequest: PDFReadingNavigation?
    @Published var lastSyncAt: Date?
    @Published var catalogPresented = false
    let appearanceStore:AppearanceStore
    var client: SyncClient?
    @Published var appearance: AppearanceStyle

    init(directory explicitDirectory:URL?=nil,preferences suppliedPreferences:UserDefaults?=nil,restoreSavedSession:Bool=true,
         credentials: (any SessionCredentialStore)? = nil,
         makeClient: @escaping @Sendable (URL, String) -> SyncClient = { libraryConnectedClient(url: $0, deviceId: $1) }) throws {
        let preferences=suppliedPreferences ?? Self.defaultPreferences
        self.preferences=preferences
        appearanceStore=AppearanceStore(defaults:preferences)
        username=preferences.string(forKey:"connection.username") ?? "token"
        let savedServer=preferences.string(forKey:"connection.server") ?? ""
        server=savedServer.isEmpty ? Self.defaultServerAddress : savedServer
        deviceId=preferences.string(forKey:"connection.deviceId") ?? UUID().uuidString.lowercased()
        preferences.set(deviceId,forKey:"connection.deviceId")
        let directory = explicitDirectory ?? Self.verificationDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenLibrary", isDirectory: true)
        workspaces = LibraryWorkspaceManager(baseDirectory: directory)
        // Keep the old database and its unsent queue accessible in place.
        let hasLegacyStore=FileManager.default.fileExists(atPath:directory.appendingPathComponent("library.sqlite").path)
        localStore = hasLegacyStore
            ? try DocumentStore(directory: directory) : try workspaces.localStore()
        store = localStore
        sessionVault = SessionVault(service: Self.verificationDirectory.map { "TokenLibrary.verification.\($0.lastPathComponent)" } ?? "TokenLibrary.sessions")
        self.credentials = credentials ?? AsyncSessionVault(vault: sessionVault)
        self.makeClient = makeClient
        appearance = appearanceStore.style
        currentFolder = DemoLibrary.rootId
        if hasLegacyStore,let root=preferences.string(forKey:"connection.rootId"),root != DemoLibrary.rootId {
            do {
                let oldServer=preferences.string(forKey:"connection.server").flatMap { $0.isEmpty ? nil : $0 }
                let oldLibrary=preferences.string(forKey:"connection.libraryId").flatMap { $0.isEmpty ? nil : $0 }
                try localStore.registerLegacyLibraryRoot(rootID:root,server:oldServer,libraryID:oldLibrary)
            } catch { reportLocal("恢复旧资料目录",error:error) }
        }
        // Existing local files do not skip login. A saved connection opens its own library.
        if restoreSavedSession,let url = try? ServerAddress.normalize(savedServer) {
            if let libraryId = preferences.string(forKey: "connection.libraryId"),
               let rootId = preferences.string(forKey: "connection.rootId") {
                store = try workspaces.store(server:url,libraryId:libraryId)
                try store.bindWorkspace(server:url.absoluteString,libraryId:libraryId,rootId:rootId)
                isLocalWorkspace = false
                currentFolder = rootId
                offlineAccess = true
            }
        }
        reload()
        if restoreSavedSession, let url = try? ServerAddress.normalize(savedServer) { restoreSession(from: url) }
    }

    private func cancelSessionRestore() {
        sessionRestoreID = nil; sessionRestoreTask?.cancel(); sessionRestoreTask = nil
        restoringSession = false; credentialNotice = nil
    }

    private func restoreSession(from url: URL) {
        let id = UUID(), originalStore = store, access = credentials
        sessionRestoreID = id; restoringSession = true
        credentialNotice = "正在恢复安全登录信息；本机资料可以继续使用。若系统请求授权，可处理提示或保持离线。"
        sessionRestoreTask = Task { [weak self] in
            let result: Result<SavedLibrarySession?, Error>
            do { result = .success(try await access.load(server: url)) }
            catch { result = .failure(error) }
            guard let self, self.sessionRestoreID == id else { return }
            defer { self.sessionRestoreID = nil; self.sessionRestoreTask = nil; self.restoringSession = false; self.credentialNotice = nil }
            guard !Task.isCancelled, self.store === originalStore, self.session == nil,
                  (try? ServerAddress.normalize(self.server)) == url else { return }
            do {
                guard let saved = try result.get() else { return }
                let workspace = try self.workspaces.store(server: url, libraryId: saved.login.libraryId)
                try workspace.bindWorkspace(server: url.absoluteString, libraryId: saved.login.libraryId, rootId: saved.login.rootId)
                let c = self.makeClient(url, self.deviceId); c.restoreSession(saved.login)
                // Preserve navigation and unsent edits made while the system was
                // deciding whether this process may read the saved session.
                if workspace.root.standardizedFileURL != originalStore.root.standardizedFileURL {
                    self.store = workspace; self.currentFolder = saved.login.rootId; self.selectedId = nil
                }
                self.session = saved.login; self.client = c; self.username = saved.username
                self.isLocalWorkspace = false; self.offlineAccess = true
                self.reload(); self.requestSync()
            } catch { self.connectionError = "无法恢复安全登录信息：\(error.localizedDescription)\n本机资料和待提交修改已保留，可以继续离线使用或重新连接。" }
        }
    }

    func catalogChanged() { reload(); requestSync() }

    func setShelfColor(_ document: LibraryDocument, _ hex: String) {
        do {
            _ = try store.setShelfColor(id: document.id, hex: hex)
            catalogChanged()
        } catch {
            reportLocal("设置颜色", error: error)
        }
    }

    /// Typing saves to SQLite immediately. Refreshing the shelf and starting a
    /// sync wait until the keystrokes pause, so each character does not rebuild
    /// the whole library on the main thread.
    private var editorSyncTask: Task<Void, Never>?
    func noteEditorAutosave() {
        editorSyncTask?.cancel()
        let editedStore = store
        let editedID = selectedId
        editorSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if let editedID {
                await Task.detached(priority: .utility) {
                    try? editedStore.refreshSearchIndex(id: editedID)
                }.value
            }
            guard !Task.isCancelled else { return }
            if client == nil || isLocalWorkspace { reload() } else { requestSync() }
        }
    }
    func openDocument(_ document: LibraryDocument) {
        catalogPresented = false
        selectedPage = nil;pdfNavigationRequest=nil
        if libraryInventory?.rootID(for:document.parentId) != nil { currentFolder=document.parentId }
        folderName=documents.first(where:{$0.id == currentFolder})?.name ?? rootTitle(currentFolder)
        selectedId = document.id
    }
    /// Library selection and explicit result activation carry search intent.
    /// Related/source navigation preserves the list query without inheriting
    /// its text selection or PDF page.
    func selectLibraryRow(_ id:String?) {
        selectedId=id
        guard let id,!query.isEmpty,let hit=searchResults.first(where:{$0.objectId == id}),
              let document=documents.first(where:{$0.id == id && $0.state == "active"}) else { return }
        navigationSearch=query
        if let page=hit.pageIndex { requestPDFPage(page,document:document) }
    }
    func isSelectedPDFSearchResult(_ id:String)->Bool {
        selectedId == id && !query.isEmpty
            && documents.contains(where:{$0.id == id && $0.kind == .pdf && $0.state == "active"})
            && searchResults.contains(where:{$0.objectId == id && $0.pageIndex != nil})
    }
    /// A selected List row need not write its selection binding a second time.
    /// Repeated activation therefore sends a fresh, consumable page request.
    @discardableResult
    func activateSelectedPDFSearchResult(_ id:String)->Bool {
        guard isSelectedPDFSearchResult(id),
              let hit=searchResults.first(where:{$0.objectId == id}),let page=hit.pageIndex,
              let current=try? store.loadDocument(id:id),current.kind == .pdf,current.state == "active" else { return false }
        navigationSearch=query
        let previous=pdfNavigationRequest?.id
        requestPDFPage(page,document:current)
        return pdfNavigationRequest?.id != nil && pdfNavigationRequest?.id != previous
    }
    /// Selecting a folder is a navigation action, so the search context must
    /// end along with its query. Ordinary document selection keeps search hits
    /// for Markdown highlighting and PDF page navigation.
    @discardableResult
    func openFolder(_ document: LibraryDocument) -> Bool {
        do {
            guard let current = try store.loadDocument(id: document.id), current.kind == .folder,
                  current.state == "active", !current.isCatalogTopic,
                  try store.legacyLibraryInventory().rootID(for: current.id) != nil else {
                throw StructureEditError.invalidFolder
            }
            query = "" // Cancels debounce/in-flight results before replacing the list.
            searchPresented = false
            selectedId = nil
            currentFolder = current.id
            folderName = current.name
            reload()
            return true
        } catch {
            reportLocal("打开文件夹", error: error)
            return false
        }
    }
    var sourceReturnNote:LibraryDocument? {
        guard let context=sourceReturnContext,context.sourceID == selectedId else { return nil }
        return documents.first { $0.id == context.noteID && $0.kind == .md && $0.state == "active" }
    }
    func returnToReadingNote() {
        guard let note=sourceReturnNote else { sourceReturnContext=nil;return }
        openDocument(note);sourceReturnContext=nil
    }
    func openSource(_ document:LibraryDocument,page:Int?,hash:String?) {
        let origin=selected?.kind == .md && selectedId != document.id ? selectedId : nil
        openDocument(document)
        selectedPage=nil;pdfNavigationRequest=nil
        if let origin { sourceReturnContext=SourceReturnContext(noteID:origin,sourceID:document.id) }
        if document.kind == .pdf,page != nil {
            guard let hash,let path=document.pdfPath,let actual=try? DocumentStore.catalogFileHash(URL(fileURLWithPath:path)) else {
                banner="来源文件版本暂时无法核对，已打开资料，请核对原文后定位。";return
            }
            guard actual == hash else { banner="原文件已经变化，请核对原文；未跳转旧页码。";return }
        }
        if let page { requestPDFPage(page,document:document,verifiedHash:hash) }
    }
    func requestPDFPage(_ page:Int,document:LibraryDocument,verifiedHash:String?=nil) {
        guard document.kind == .pdf,let path=document.pdfPath,
              let hash=verifiedHash ?? (try? DocumentStore.catalogFileHash(URL(fileURLWithPath:path))) else { return }
        selectedPage=page
        pdfNavigationRequest=PDFReadingNavigation(sourceIdentity:PDFReadingSource.identity(for:document),fileHash:hash,pageIndex:page)
    }
    func consumePDFNavigation(_ request:PDFReadingNavigation) {
        guard pdfNavigationRequest?.id == request.id else { return }
        selectedPage=nil;pdfNavigationRequest=nil
    }
    @discardableResult
    func savePDFReadingPosition(_ event:PDFReadingEvent,documentID:String,store:DocumentStore)->Bool {
        guard store === self.store,selectedId == documentID,let hash=event.source.fileHash,
              event.pageIndex >= 0,event.pageIndex < event.source.pageCount else { return false }
        do {
            guard let current=try store.loadDocument(id:documentID),current.state == "active",current.kind == .pdf,
                  PDFReadingSource.identity(for:current) == event.source.identity else { return false }
            if let previous=current.catalog.readingPositions.first(where:{$0.deviceID == deviceId}),
               previous.pageIndex == event.pageIndex,previous.fileHash == hash,previous.totalPages == event.source.pageCount { return true }
            _ = try store.recordCatalogReadingPosition(id:documentID,deviceID:deviceId,pageIndex:event.pageIndex,
                                                       totalPages:event.source.pageCount,fileHash:hash)
            catalogChanged();return true
        } catch { reportLocal("保存阅读位置",error:error);return false }
    }
    func openDocumentLink(_ url: URL) {
        if url.scheme == "tokenlibrary", url.host == "document" {
            let id = url.pathComponents.last ?? ""
            guard let document = documents.first(where: { $0.id == id && $0.state == "active" }) else {
                reportLocal("打开来源",message:"来源资料已删除或尚未同步。笔记中的摘录仍保留。"); return
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init).map { max(0, $0 - 1) }
            var hash=items.first(where: { $0.name == "hash" })?.value
            if hash == nil,let selected {
                let hashes=Set(selected.catalog.excerpts.filter { $0.sourceID == id && $0.pageIndex == page }.compactMap(\.fileHash))
                if hashes.count == 1 { hash=hashes.first }
                else if hashes.count > 1 {
                    openDocument(document);banner="这条来源链接对应多个原文件版本，请在资料详情中选择具体摘录后定位。";return
                }
            }
            openSource(document,page:page,hash:hash)
        } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
    }
    func showLocalLibrary() {
        cancelConnection(publishNotice:false)
        stopSync()
        clearConnectionFeedback()
        store = localStore;isLocalWorkspace=true;currentFolder=DemoLibrary.rootId
        selectedId=nil;folderName="这台设备";reload()
    }
    func copyLocalDocumentsToConnectedLibrary() {
        guard !isLocalWorkspace,let session else { return }
        do {
            let inventory=try localStore.legacyLibraryInventory()
            let roots=inventory.rootIDs
            var count=0
            for root in roots { count += try store.importLocalLibrary(from:localStore,sourceRootID:root,targetRootID:session.rootId).importedDocuments }
            banner="已复制 \(count) 项本机资料，原本机副本保留。"+(inventory.unresolvedDocumentIDs.isEmpty ? "" : "另有 \(inventory.unresolvedDocumentIDs.count) 项目录位置待恢复，请在本机库查看；这些项目尚未复制。")
            catalogChanged()
        } catch { reportLocal("迁入本机资料",error:error) }
    }
    func showConnectedLibrary() {
        guard let session, let url = client?.baseURL else { showConnection();return }
        do {
            cancelConnection(publishNotice:false)
            stopSync()
            clearConnectionFeedback()
            store = try workspaces.store(server:url,libraryId:session.libraryId)
            try store.bindWorkspace(server:url.absoluteString,libraryId:session.libraryId,rootId:session.rootId)
            isLocalWorkspace=false;currentFolder=session.rootId;selectedId=nil;folderName="资料库"
            reload();requestSync()
        } catch { reportLocal("打开资料库",error:error) }
    }

    func setAppearance(_ style: AppearanceStyle) {
        appearance = style
        appearanceStore.style = style
    }

    var token: String? { session?.sessionToken }

    var colorScheme: ColorScheme? {
        switch appearance.mappedScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var selected: LibraryDocument? {
        guard let id = selectedId, let listed = documents.first(where: { $0.id == id && $0.state == "active" }) else { return nil }
        guard listed.kind == .md else { return listed }
        return (try? store.loadDocument(id: id)) ?? listed
    }

    private var libraryStamp: String?
    private var shelfReloadQueued = false

    func scheduleShelfReload() {
        guard !shelfReloadQueued else { return }
        shelfReloadQueued = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            shelfReloadQueued = false
            reload()
        }
    }

    func reload() {
        let stamp = try? store.libraryRevisionStamp()
        if let stamp, stamp == libraryStamp { return }
        do {
            documents = try store.listDocuments(includeTrashed: true, includeBodies: false)
            libraryInventory=try store.legacyLibraryInventory()
            pendingCount = try store.pending().count
            libraryStamp = stamp
        } catch { reportLocal("读取本机资料", error: error); return }
        lastSyncAt=(preferences.object(forKey:lastSyncPreferenceKey) as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        if !query.isEmpty { updateSearch() }
        if let id = selectedId, documents.contains(where: { $0.id == id && $0.state == "active" }) == false {
            selectedId = nil
        }
    }

    private static func lastSyncPreferenceKey(for root:URL) -> String {
        "sync.lastSuccess."+BlobIntegrity.sha256(Data(root.standardizedFileURL.path.utf8))
    }
    private var lastSyncPreferenceKey:String { Self.lastSyncPreferenceKey(for:store.root) }
    func recordSuccessfulSync(at date:Date=Date()) {
        lastSyncAt=date
        preferences.set(date.timeIntervalSince1970,forKey:lastSyncPreferenceKey)
    }

    static func synchronizeInBackground(directory explicitDirectory:URL?=nil,
                                        preferences suppliedPreferences:UserDefaults?=nil,
                                        credentials suppliedCredentials:(any SessionCredentialStore)?=nil,
                                        credentialWait:Duration = .seconds(3), timeBudget:Duration = .seconds(25),
                                        makeClient:@escaping @Sendable (URL,String)->SyncClient = { libraryConnectedClient(url:$0, deviceId:$1) }) async -> BackgroundSyncOutcome {
        let preferences=suppliedPreferences ?? defaultPreferences
        guard let rawServer=preferences.string(forKey:"connection.server"),let server=try? ServerAddress.normalize(rawServer),
              let libraryID=preferences.string(forKey:"connection.libraryId"),!libraryID.isEmpty,
              let rootID=preferences.string(forKey:"connection.rootId"),!rootID.isEmpty,
              let deviceID=preferences.string(forKey:"connection.deviceId"),!deviceID.isEmpty else { return .notConfigured }
        let directory=explicitDirectory ?? verificationDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("TokenLibrary",isDirectory:true)
        let credentials=suppliedCredentials ?? AsyncSessionVault(vault:SessionVault(service:
            verificationDirectory.map { "TokenLibrary.verification.\($0.lastPathComponent)" } ?? "TokenLibrary.sessions"))
        let result=await BackgroundSyncRunner.run(server:server,libraryID:libraryID,rootID:rootID,deviceID:deviceID,
            workspaces:LibraryWorkspaceManager(baseDirectory:directory),credentials:credentials,
            credentialWait:credentialWait,timeBudget:timeBudget,makeClient:makeClient)
        guard !Task.isCancelled else { return .cancelled }
        if case let .synchronized(root,date)=result {
            preferences.set(date.timeIntervalSince1970,forKey:lastSyncPreferenceKey(for:root))
        }
        return result
    }

    func beginLogin() {
        guard !connectionBusy else { return }
        cancelSessionRestore()
        connectionTask = Task { guard !Task.isCancelled else { return };await login() }
    }

    func setConnectionBanner(_ message:String) {
        banner=message;bannerIsConnectionStatus=true
    }
    private func clearConnectionFeedback() {
        connectionError=nil
        if bannerIsConnectionStatus { banner="" }
    }

    func cancelConnection(publishNotice:Bool=true) {
        let wasWaiting = connectionBusy || restoringSession
        connectionRunID = nil; connectionTask?.cancel(); connectionTask = nil
        connectionBusy = false; cancelSessionRestore()
        // A running Security.framework call is not cancellable. Its eventual
        // result is ignored; this only stops this UI request from taking effect.
        if wasWaiting && publishNotice { setConnectionBanner("已停止本次连接等待。本机资料仍可使用；系统中的授权请求可能仍会继续。") }
    }

    func useOffline() {
        cancelConnection(publishNotice:false)
        clearConnectionFeedback()
        offlineAccess = true
    }

    func showConnection() {
        cancelConnection()
        offlineAccess = false
        connectionError = nil
        banner = ""
    }

    func testConnection() {
        guard !connectionBusy else { return }
        cancelSessionRestore()
        connectionTask = Task {
            guard !Task.isCancelled else { return }
            let runID = UUID(); connectionRunID = runID
            connectionBusy = true
            connectionError = nil
            setConnectionBanner("正在检查服务器…")
            defer { if connectionRunID == runID { connectionBusy = false; connectionRunID = nil } }
            do {
                let url = try ServerAddress.normalize(server)
                let readiness = try await SyncClient(baseURL: url).checkReadiness()
                try Task.checkCancellation()
                guard connectionRunID == runID else { return }
                server = url.absoluteString
                setConnectionBanner(readiness.maintenance
                    ? "服务器可连接，正在备份维护。可以继续本地编辑，稍后再提交。"
                    : "服务器可连接。输入账号密码后登录。")
            } catch is CancellationError {
                if connectionRunID == runID { setConnectionBanner("已取消连接检查。") }
            } catch {
                if connectionRunID == runID { reportConnection(error,invalidatesSession:false) }
            }
        }
    }

    func reportConnection(_ error:Error,invalidatesSession:Bool=true) {
        let failure = SyncFailure.from(error)
        if failure.kind == .unauthorized && invalidatesSession {
            if let url = client?.baseURL, let token = session?.sessionToken {
                let access = credentials
                Task { try? await access.delete(server: url, matchingSessionToken: token) }
            }
            session = nil
            client = nil
            offlineAccess = true
        }
        connectionError = "\(failure.title)\n\(failure.message)\n\(failure.recoverySuggestion ?? "")"
        banner = ""
    }

    func login() async {
        guard !connectionBusy else { return }
        cancelSessionRestore()
        let runID = UUID(), originalStore = store
        connectionRunID = runID
        connectionBusy = true
        connectionError = nil
        banner = ""
        defer {
            if connectionRunID == runID { connectionBusy = false; connectionRunID = nil; credentialNotice = nil }
        }
        guard !password.isEmpty else {
            connectionError = "请输入密码后登录，也可以先只在这台设备上使用。"
            return
        }
        do {
            let url = try ServerAddress.normalize(server)
            let enteredUsername = username
            let c = makeClient(url, deviceId)
            let r = try await c.login(username: enteredUsername, password: password)
            guard !Task.isCancelled, connectionRunID == runID, store === originalStore else {
                Task { try? await c.logoutSession() }
                return
            }
            let workspace = try workspaces.store(server:url,libraryId:r.libraryId)
            try workspace.bindWorkspace(server:url.absoluteString,libraryId:r.libraryId,rootId:r.rootId)
            credentialNotice = "正在安全保存登录信息。可以停止等待；系统中的授权请求可能仍会继续。"
            do { try await credentials.save(SavedLibrarySession(username: enteredUsername, login: r), server: url) }
            catch {
                Task { try? await c.logoutSession() }
                throw error
            }
            guard !Task.isCancelled, connectionRunID == runID, store === originalStore,
                  (try? ServerAddress.normalize(server)) == url else {
                // An in-flight system save can finish after UI cancellation.
                // Remove only that cancelled token, never a newer login's token.
                let access = credentials
                Task {
                    try? await access.delete(server: url, matchingSessionToken: r.sessionToken)
                    try? await c.logoutSession()
                }
                return
            }
            stopSync()
            selectedId = nil
            session = r
            client = c
            username = enteredUsername
            store = workspace
            isLocalWorkspace = false
            server = url.absoluteString
            preferences.set(server, forKey: "connection.server")
            preferences.set(username, forKey: "connection.username")
            preferences.set(r.libraryId, forKey: "connection.libraryId")
            preferences.set(r.rootId, forKey: "connection.rootId")
            password = ""
            offlineAccess = true
            currentFolder = r.rootId
            folderName = "资料库"
            setConnectionBanner(Self.connectedSyncBanner)
            reload()
            requestSync()
        } catch is CancellationError {
            if connectionRunID == runID { setConnectionBanner("已停止本次登录等待。") }
        } catch {
            if connectionRunID == runID { reportConnection(error,invalidatesSession:false) }
        }
    }

    func logout() {
        cancelConnection()
        stopSync()
        let previousClient = client, previousToken = session?.sessionToken
        let url = client?.baseURL ?? (try? ServerAddress.normalize(preferences.string(forKey:"connection.server") ?? ""))
        session = nil
        client = nil
        let serverLogout: Task<Bool, Never>? = previousClient.map { previousClient in
            Task { do { try await previousClient.logoutSession(); return true } catch { return false } }
        }
        password = ""
        offlineAccess = true
        connectionError = nil
        guard let url else { setConnectionBanner("已退出。这台设备上的资料仍可继续编辑。"); return }
        let runID = UUID(), access = credentials
        connectionRunID = runID; connectionBusy = true
        credentialNotice = "已停止同步，正在移除安全登录信息；本机资料可继续编辑。"
        connectionTask = Task {
            defer {
                if connectionRunID == runID { connectionRunID = nil; connectionBusy = false; credentialNotice = nil }
            }
            do {
                let token: String?
                if let previousToken { token = previousToken }
                else { token = try await access.load(server: url)?.login.sessionToken }
                guard !Task.isCancelled, connectionRunID == runID else { return }
                if let token { try await access.delete(server: url, matchingSessionToken: token) }
                let revoked = await serverLogout?.value ?? true
                guard !Task.isCancelled, connectionRunID == runID else { return }
                setConnectionBanner(revoked ? "已退出。这台设备上的资料仍可继续编辑。" : "安全登录信息已移除，这台设备上的资料仍可编辑。服务器会话撤销暂未确认。")
            } catch {
                guard !Task.isCancelled, connectionRunID == runID else { return }
                reportLocal("移除安全登录信息", error: error)
                setConnectionBanner("本次同步已停止，安全登录信息尚未移除。可以重试退出；本机资料仍保留。")
            }
        }
    }

    private func stopSync() {
        syncTask?.cancel();syncTask=nil;syncRunID=nil;syncRequested=false;syncing=false
        catalogPresented=false;renameTarget=nil;moveTarget=nil;sourceReturnContext=nil
    }

    func documentNeedsLocalFile(_ document: LibraryDocument) -> Bool {
        if document.kind == .pdf {
            guard document.pdfBlobId != nil else { return false }
            return !(document.pdfPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }
        guard document.kind == .md, let assets = try? JSONValue.parse(document.assetsJSON).array else { return false }
        for value in assets {
            guard let asset = value.object, asset["blobId"]?.string ?? asset["id"]?.string != nil,
                  let path = asset["path"]?.string else { continue }
            guard let file = try? store.resolveAttachment(path: path), FileManager.default.fileExists(atPath: file.path) else { return true }
        }
        return false
    }

    func materializeOpenedDocument(_ id: String) async {
        openDownloadError = nil
        guard let doc = try? store.loadDocument(id: id), documentNeedsLocalFile(doc) else { return }
        guard let client else {
            openDownloadError = "登录后才能从服务器下载这一本。"
            return
        }
        do {
            _ = try await client.downloadOpenedDocument(doc, store: store)
            reload()
            if let current = try? store.loadDocument(id: id), documentNeedsLocalFile(current) {
                openDownloadError = "文件没有保存到手机上。"
            }
        } catch {
            openDownloadError = error.localizedDescription
            reportLocal("下载", error: error)
        }
    }

    func requestSync() {
        guard let activeClient=client, !isLocalWorkspace else { reload();return }
        syncRequested = true
        guard syncTask == nil else { return }
        let activeStore=store,rootID=session?.rootId,runID=UUID()
        syncRunID=runID
        syncTask = Task {
            guard !Task.isCancelled,syncRunID == runID,activeStore === store,activeClient === client else { return }
            syncing = true
            defer {
                if syncRunID == runID { syncing=false;syncTask=nil;syncRunID=nil;reload() }
            }
            while syncRequested && !Task.isCancelled {
                syncRequested = false
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard activeClient === client,activeStore === store,!isLocalWorkspace else { return }
                    activeClient.onLibraryPage = { [weak self] in
                        Task { @MainActor in self?.scheduleShelfReload() }
                    }
                    let result = try await activeClient.synchronize(store:activeStore,rootId:rootID)
                    try Task.checkCancellation()
                    guard activeStore === store,activeClient === client,syncRunID == runID else { return }
                    connectionError=nil;recordSuccessfulSync()
                    let remaining=try activeStore.pending().count
                    let finished = remaining == 0 ? Self.syncFinishedBanner : "已同步本轮更改，其余内容等待下一轮。"
                    setConnectionBanner(result.conflicts>0 ? "同步完成，存在需要处理的冲突。" : finished)
                    reload()
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled,activeStore === store,activeClient === client,syncRunID == runID else { return }
                    reportConnection(error);return
                }
            }
        }
    }

    func reportLocal(_ action: String, error: Error) {
        reportLocal(action,message:error.localizedDescription)
    }

    func reportLocal(_ action: String, message: String) {
        localOperationAction = action
        localOperationError = "\(action)失败：\(message)"
    }

    func dismissLocalOperationError(for action:String?=nil) {
        guard action == nil || localOperationAction == action else { return }
        localOperationError = nil
        localOperationAction = nil
    }

    var workspaceStatusTitle:String {
        if isLocalWorkspace { return "这台设备" }
        return session == nil ? "资料库（离线）" : "资料库"
    }

    var syncStatusLine: String {
        if session == nil || isLocalWorkspace { return "未登录，这台设备不会和服务器同步" }
        if syncing {
            #if os(iOS)
            return "正在同步目录。文件要等打开某一本时再下载。"
            #else
            return "正在和服务器同步…"
            #endif
        }
        if connectionError != nil { return "同步没有完成，可在设置里再试一次" }
        if let at = lastSyncAt { return Self.syncIdleLine(at) }
        return "已登录，等待和服务器同步"
    }

    private func validName(_ name:String)->Bool { FileNames.isValidStoredName(name) }
    private func uniqueName(_ name:String,parent:String,kind:DocKind = .md)->String {
        let names=Set(documents.filter { $0.parentId == parent && $0.state == "active" }.map { FileNames.comparisonKey($0.name) })
        return FileNames.availableName(name,kind:kind,takenKeys:names)
    }

    private func canCreateInCurrentFolder()->Bool {
        if isLocalWorkspace,libraryInventory?.rootIDs.contains(currentFolder) == true { return true }
        let expectedRoot=isLocalWorkspace ? DemoLibrary.rootId : (session?.rootId ?? preferences.string(forKey:"connection.rootId"))
        if currentFolder == expectedRoot { return true }
        if let folder=documents.first(where:{$0.id == currentFolder}),folder.kind == .folder,folder.state == "active",folder.catalog.category != .topic,
           (isLocalWorkspace ? libraryInventory?.rootID(for:currentFolder) : LibraryHierarchy.rootID(for:currentFolder,documents:documents,localRootID:expectedRoot ?? DemoLibrary.rootId)) != nil { return true }
        reportLocal("新建资料",message:"当前位置不可用于新建资料，请返回资料库根目录或选择一个普通文件夹。")
        return false
    }

    func newNote() {
        guard canCreateInCurrentFolder() else { return }
        let parent = currentFolder
        let doc = LibraryDocument(
            id: UUID().uuidString.lowercased(), kind: .md, parentId: parent, name: uniqueName("未命名.md", parent: parent),
            markdown: "# 新笔记\n\n", pdfPath: nil, revision: 0, localGeneration: 0,
            state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]"
        )
        do {
            var value = doc
            value.metadataJSON = try CatalogMetadata(category: .note).json()
            _ = try store.createDocument(value)
        }
        catch { reportLocal("新建笔记", error: error); return }
        reload()
        selectedId = doc.id
        requestSync()
    }

    func newFolder() {
        guard canCreateInCurrentFolder() else { return }
        let doc = LibraryDocument(
            id: UUID().uuidString.lowercased(), kind: .folder, parentId: currentFolder, name: uniqueName("新文件夹", parent: currentFolder,kind:.folder),
            markdown: "", pdfPath: nil, revision: 0, localGeneration: 0,
            state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]"
        )
        do { _ = try store.createDocument(doc) }
        catch { reportLocal("新建文件夹", error: error); return }
        reload()
        requestSync()
    }

    func importFile(url: URL) {
        dismissLocalOperationError(for:"导入")
        do { try importCheckedFile(url: url) }
        catch { reportLocal("导入", error: error) }
    }

    private func importCheckedFile(url: URL) throws {
        guard canCreateInCurrentFolder() else { return }
        let ext = url.pathExtension.lowercased()
        guard ["md", "markdown", "pdf"].contains(ext) else {
            reportLocal("导入",message:"暂时支持导入 .md、.markdown 和 PDF 文件。")
            return
        }
        if ext != "pdf" {
            let result=try store.importMarkdownFile(url:url,parentID:currentFolder)
            importNotice=result.warnings.isEmpty ? nil : result.warnings.joined(separator:"\n\n")
            reload();selectedId=result.document.id;requestSync();return
        }
        let name = uniqueName(url.lastPathComponent, parent: currentFolder,kind:.pdf)
        guard validName(name) else { throw CocoaError(.fileReadInvalidFileName) }
        let data = try PDFImportValidation.read(url: url)
        var metadata=CatalogMetadata(category:ext == "pdf" ? .unclassified : .note)
        metadata.inbox=true;metadata.originalFilename=url.lastPathComponent
        metadata.originalFileHash=BlobIntegrity.sha256(data);metadata.importedAt=Date()
        do {
            let asset=try store.importAttachment(data:data,fileName:name,mime:"application/pdf")
            let dest=try store.resolveAttachment(path:asset.path)
            let doc = LibraryDocument(
                id: UUID().uuidString.lowercased(), kind: .pdf, parentId: currentFolder, name: name,
                markdown: "", pdfPath: dest.path, revision: 0, localGeneration: 0,
                state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]",metadataJSON:try metadata.json(),pdfBlobId:asset.blobId
            )
            _ = try store.createDocument(doc)
            selectedId = doc.id
        }
        reload()
        requestSync()
    }

    func beginRename(_ doc: LibraryDocument) {
        renameDraft = FileNames.editingBase(doc.name, kind: doc.kind)
        renameTarget = doc
    }

    func commitRename() {
        if let doc = renameTarget {
            rename(doc, to: renameDraft)
        }
        renameTarget = nil
    }

    func rename(_ doc: LibraryDocument, to name: String) {
        let fresh: LibraryDocument
        do {
            guard let renamed = try store.renameDocument(id: doc.id, to: name) else { throw StoreError.notFound }
            fresh = renamed
        } catch { reportLocal("重命名", error: error); return }
        if currentFolder == doc.id { folderName = fresh.name }
        reload()
        requestSync()
    }

    @discardableResult
    func move(_ doc:LibraryDocument,to parent:String)->Bool {
        do { _ = try store.moveDocument(id:doc.id,to:parent) }
        catch { reportLocal("移动",error:error);return false }
        reload();requestSync();return true
    }

    func delete(_ doc: LibraryDocument) {
        do { try store.trash(id: doc.id) }
        catch { reportLocal("移入回收站", error: error); return }
        if selectedId == doc.id { selectedId = nil }
        reload()
        requestSync()
    }

    func prepareExport(_ doc: LibraryDocument) {
        do {
            guard let current = try store.loadDocument(id: doc.id) else { throw StoreError.notFound }
            let data: Data
            if current.kind == .md {
                let output = try store.exportPortableMarkdown(id: current.id)
                data = output.data
                exportType = output.isArchive ? .zip : (UTType(filenameExtension: "md") ?? .plainText)
                exportName = output.filename
            } else if current.kind == .pdf {
                guard let path = current.pdfPath else { throw StoreError.notFound }
                let source = try Data(contentsOf: URL(fileURLWithPath: path))
                let annotations = try JSONDecoder().decode([PDFTextAnnotation].self, from: Data(current.annotationsJSON.utf8))
                data = try PDFExport.exportAnnotated(pdfData: source, annotations: annotations,currentPDFBlobId:current.pdfBlobId)
                exportType = .pdf
            } else { return }
            exportFile = LibraryExportFile(data: data)
            if current.kind != .md { exportName = current.name }
            exportPresented = true
        } catch { reportLocal("导出", error: error) }
    }

    func restore(_ doc: LibraryDocument) {
        do { try store.restore(id: doc.id) }
        catch { reportLocal("还原", error: error); return }
        reload()
        requestSync()
    }

    @discardableResult
    func savePDFAnnotations(document:LibraryDocument, store targetStore:DocumentStore, base:[PDFTextAnnotation], proposed:[PDFTextAnnotation]) -> Bool {
        do {
            _ = try targetStore.savePDFAnnotationEdit(id:document.id,expectedPDFBlobId:document.pdfBlobId,expectedPDFPath:document.pdfPath,base:base,proposed:proposed)
            if targetStore === store { reload();requestSync() }
            return true
        } catch { reportLocal("保存批注",error:error);return false }
    }

    func updateSearch() {
        searchTask?.cancel()
        let text=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { searchResults=[];searchTruncated=false;searchCoverage=nil;searching=false;return }
        searching=true
        let currentStore=store
        searchTask=Task {
            do {
                try await Task.sleep(for:.milliseconds(150))
                let (hits,coverage)=try await Task.detached(priority:.userInitiated) {
                    (try currentStore.searchDetails(query:text,limit:1_001),try currentStore.searchCoverage())
                }.value
                try Task.checkCancellation()
                guard currentStore === store,query.trimmingCharacters(in:.whitespacesAndNewlines) == text else { return }
                searchTruncated=hits.count > 1_000
                searchResults=searchTruncated ? Array(hits.prefix(1_000)) : hits
                searchCoverage=coverage
                searching=false
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled,currentStore === store,query.trimmingCharacters(in:.whitespacesAndNewlines) == text else { return }
                searching=false;reportLocal("搜索",error:error)
            }
        }
    }
    func visibleDocs() -> [LibraryDocument] {
        if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            return documents.filter { $0.state == "active" && $0.parentId == currentFolder && $0.catalog.category != .topic }.sorted(by:LibraryDocument.folderFirst)
        }
        let byID=Dictionary(uniqueKeysWithValues:documents.map { ($0.id,$0) })
        return searchResults.compactMap { byID[$0.objectId] }.filter { $0.state == "active" && !$0.parentId.isEmpty && $0.catalog.category != .topic }
    }
    func folderBreadcrumb(_ document:LibraryDocument)->String {
        var parts:[String]=[];var id=document.parentId;var seen=Set<String>()
        while seen.insert(id).inserted,let parent=documents.first(where:{$0.id == id}) { parts.insert(parent.name,at:0);id=parent.parentId }
        return parts.isEmpty ? "资料库" : parts.joined(separator:" / ")
    }

    func drop(_ ids: [String], onto folder: LibraryDocument) -> Bool {
        guard folder.kind == .folder else { return false }
        var moved = false
        for id in ids {
            guard let item = documents.first(where: { $0.id == id }) else { continue }
            if item.id == folder.id { continue }
            if item.kind == .folder && item.isAncestor(of: folder, in: documents) { continue }
            moved = move(item,to:folder.id) || moved
        }
        return moved
    }

    var isAtRoot: Bool {
        documents.first(where: { $0.id == currentFolder })?.parentId.isEmpty ?? true
    }

    func rootFor(_ folder:String)->String {
        libraryInventory?.rootID(for:folder) ?? LibraryHierarchy.rootID(for:folder,documents:documents) ?? (isLocalWorkspace ? DemoLibrary.rootId : (session?.rootId ?? currentFolder))
    }

    var savedRoots: [String] {
        if isLocalWorkspace { return libraryInventory?.rootIDs ?? [DemoLibrary.rootId] }
        return [session?.rootId ?? preferences.string(forKey:"connection.rootId") ?? currentFolder].filter { !$0.isEmpty }
    }
    var unresolvedDocuments:[LibraryDocument] {
        guard isLocalWorkspace,let inventory=libraryInventory else { return [] }
        let ids=Set(inventory.unresolvedDocumentIDs)
        return documents.filter { ids.contains($0.id) && $0.state == "active" }
    }

    func rootTitle(_ root: String) -> String {
        if root == DemoLibrary.rootId { return "这台设备" }
        if root == session?.rootId { return "已同步" }
        return "已保存 · \(root.prefix(6))"
    }

    func goUp() {
        guard !isAtRoot else { return }
        if let cur = documents.first(where: { $0.id == currentFolder }) {
            currentFolder = cur.parentId
            folderName = documents.first(where: { $0.id == cur.parentId })?.name ?? "资料库"
            reload()
        }
    }
}

#if os(iOS)
private final class BackgroundSyncLease {
    nonisolated(unsafe) static let shared = BackgroundSyncLease()
    private var id: UIBackgroundTaskIdentifier = .invalid
    var active: Bool { id != .invalid }
    func begin() {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "TokenLibrary.sync") {
            BackgroundSyncLease.shared.end()
            TokenLibraryApp.scheduleBackgroundSync()
        }
    }
    func end() {
        guard id != .invalid else { return }
        let current = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
#endif

public struct TokenLibraryRoot: View {
    @State private var model: AppModel?
    @State private var startupError: String?
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var backgroundLoop: Task<Void, Never>?
    #endif
    private let syncTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    public init() {}
    public var body: some View {
        Group {
            if let model {
                LibrarySessionView(model:model)
            } else if let startupError {
                InkUnavailable(title: "无法打开本机资料库", symbol: "externaldrive.badge.exclamationmark", message: startupError) {
                    Button("重试") { initialize() }
                }
            } else { ProgressView("正在打开资料库…") }
        }
        .task { if model == nil { initialize() }; model?.requestSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                stopBackgroundSync()
                model?.reload(); model?.requestSync()
            } else {
                startBackgroundSync()
            }
        }
        .onReceive(syncTimer) { _ in if scenePhase == .active { model?.requestSync() } }
    }
    #if os(iOS)
    private func startBackgroundSync() {
        BackgroundSyncLease.shared.begin()
        guard BackgroundSyncLease.shared.active, backgroundLoop == nil else { return }
        backgroundLoop = Task { @MainActor in
            while !Task.isCancelled && BackgroundSyncLease.shared.active {
                model?.requestSync()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
    private func stopBackgroundSync() {
        backgroundLoop?.cancel()
        backgroundLoop = nil
        BackgroundSyncLease.shared.end()
    }
    #else
    private func startBackgroundSync() {}
    private func stopBackgroundSync() {}
    #endif
    private func initialize() {
        do { model = try AppModel();startupError=nil }
        catch { startupError="\(error.localizedDescription)\n原文件仍保留。请检查磁盘空间和目录权限后重试。" }
    }
}

#if os(macOS)
/// The Mac navigation bar drags the window, and a double-click there zooms it.
/// Traffic lights, menus, and the search field still receive their own clicks.
private struct MacTitlebarGestures: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HookView)?.install()
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? HookView)?.removeMonitor()
    }

    final class HookView: NSView {
        private var monitor: Any?
        private var armed: NSEvent?
        private var dragging = false
        private weak var tracked: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }
        func install() {
            guard let window else { return }
            if tracked === window, monitor != nil { return }
            removeMonitor()
            tracked = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            armed = nil
            dragging = false
            tracked = nil
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = tracked, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                let point = event.locationInWindow
                guard point.x.isFinite, point.y.isFinite else { return event }
                guard Self.inBar(point, window: window), !Self.passes(Self.hit(point, window: window), window: window, point: point) else {
                    armed = nil
                    dragging = false
                    return event
                }
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if event.clickCount >= 2 {
                    armed = nil
                    window.zoom(nil)
                    return nil
                }
                armed = event
                return nil
            case .leftMouseDragged:
                if dragging { return nil }
                guard let start = armed else { return event }
                let moved = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
                guard moved > 3 else { return nil }
                armed = nil
                dragging = true
                window.performDrag(with: start)
                return nil
            case .leftMouseUp:
                if dragging || armed != nil {
                    dragging = false
                    armed = nil
                    return event.window === window ? nil : event
                }
                return event
            default:
                return event
            }
        }
        private static func inBar(_ point: NSPoint, window: NSWindow) -> Bool {
            guard let theme = window.contentView?.superview else { return false }
            let split = window.contentLayoutRect.maxY
            let top = theme.bounds.height
            let band = top - split
            if band > 12, band < 240, point.y >= split - 1, point.y <= top + 2,
               point.x >= -1, point.x <= theme.bounds.width + 1 {
                return true
            }
            guard let container = window.standardWindowButton(.closeButton)?.superview else { return false }
            let frame = container.convert(container.bounds, to: nil)
            guard frame.width > theme.bounds.width * 0.5, frame.height > 12, frame.height < 240 else { return false }
            return frame.insetBy(dx: -1, dy: -1).contains(point)
        }
        private static func hit(_ point: NSPoint, window: NSWindow) -> NSView? {
            window.contentView?.superview?.hitTest(point)
        }
        /// Toolbar buttons and the search field keep the click. The title text does not.
        private static func passes(_ view: NSView?, window: NSWindow, point: NSPoint) -> Bool {
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), !button.isHidden else { continue }
                let frame = button.convert(button.bounds, to: nil).insetBy(dx: -3, dy: -3)
                if frame.contains(point) { return true }
            }
            var current = view
            var steps = 0
            while let candidate = current, steps < 12 {
                steps += 1
                let name = NSStringFromClass(type(of: candidate))
                if name.contains("ToolbarItemHostingView") || name.contains("SearchField") { return true }
                if candidate is NSButton || candidate is NSSegmentedControl || candidate is NSPopUpButton || candidate is NSSearchField {
                    return true
                }
                if let field = candidate as? NSTextField, field.isEditable { return true }
                if name.contains("TitleView") || name.contains("Titlebar") { return false }
                current = candidate.superview
            }
            return false
        }
    }
}
#endif

private struct LibrarySessionView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        Group {
            if model.session == nil && !model.offlineAccess { LoginView(model:model) }
            else { LibraryView(model:model) }
        }
        .tint(LibraryPalette.ink)
        .background(LibraryPalette.paper)
        .preferredColorScheme(model.colorScheme)
        .toolbarColorScheme(model.colorScheme == .dark ? .dark : model.colorScheme == .light ? .light : nil, for: .automatic)
        #if os(macOS)
        .background(MacTitlebarGestures())
        #endif
    }
}

struct LoginView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Image("LibraryMark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .accessibilityLabel("TokenLibrary")
            Text("TokenLibrary").font(.largeTitle.bold())
            Text("个人资料库，Mac 和 iPhone 用同一个账号").foregroundStyle(LibraryPalette.muted)
            TextField("服务器地址，例如 https://library.example.com", text: $model.server)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().disabled(model.connectionBusy)
            TextField("账号", text: $model.username).textFieldStyle(.roundedBorder).disabled(model.connectionBusy)
            SecureField("密码", text: $model.password).textFieldStyle(.roundedBorder).disabled(model.connectionBusy)
            HStack(spacing: 10) {
                Button("测试连接") { model.testConnection() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(model.connectionBusy)
                Button(model.connectionError == nil ? "登录" : "重试登录") { model.beginLogin() }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(model.connectionBusy)
            }
            if model.connectionBusy && model.credentialNotice == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在连接…")
                    Button("取消") { model.cancelConnection() }
                }
            }
            CredentialWaitingNotice(model: model)
            Button("只在这台设备上使用") { model.useOffline() }
                .buttonStyle(InkButtonStyle())
            Text("登录后，Mac 和 iPhone 会同步同一份资料库。")
                .font(.caption).foregroundStyle(LibraryPalette.muted)
            if model.isLocalWorkspace && model.documents.contains(where: { $0.state == "active" && $0.kind != .folder }) {
                Text("这台设备上已有资料。登录后进入已同步的资料库；原来的仍可从「只在这台设备上使用」打开，也可在设置里复制过去。")
                    .font(.caption).foregroundStyle(LibraryPalette.muted)
            }
            Text("测试连接不会发送密码。")
                .font(.caption).foregroundStyle(LibraryPalette.muted)
            Text("不提供注册").font(.footnote).foregroundStyle(LibraryPalette.muted)
            if !model.banner.isEmpty {
                Text(model.banner).foregroundStyle(LibraryPalette.muted).font(.footnote)
            }
            if let error = model.connectionError {
                Text(error).foregroundStyle(.red).font(.footnote).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}

private struct CredentialWaitingNotice: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let notice = model.credentialNotice {
            HStack(alignment: .top) {
                ProgressView().controlSize(.small)
                Text(notice).foregroundStyle(LibraryPalette.muted).frame(maxWidth: .infinity, alignment: .leading)
                Button("停止等待") { model.cancelConnection() }
            }
            .font(.caption)
        }
    }
}

/// One request owns the system picker until completion or explicit cancellation.
/// SwiftUI may dismiss its binding before delivering the selected URLs.
struct LibraryImportPickerState {
    enum Mode {
        case files, markdownFolder
        var allowedContentTypes: [UTType] { self == .files ? [.pdf, .plainText] : [.folder] }
    }
    struct Request: Identifiable {
        let id = UUID()
        let mode: Mode
        let store: DocumentStore
        let parentID: String
        func isCurrent(store: DocumentStore, parentID: String) -> Bool {
            self.store === store && self.parentID == parentID
        }
    }
    enum Selection: Equatable { case file(URL), markdownFolder(URL) }
    struct Completion {
        let request: Request
        let result: Result<Selection?, Error>
    }
    private(set) var request: Request?
    var isPresented = false

    mutating func present(_ mode: Mode, store: DocumentStore, parentID: String) {
        guard request == nil else { return }
        request = Request(mode: mode, store: store, parentID: parentID)
        isPresented = true
    }
    mutating func complete(_ result: Result<[URL], Error>, requestID: UUID?, store: DocumentStore, parentID: String) -> Completion? {
        guard let request, request.id == requestID else { return nil }
        reset()
        guard request.isCurrent(store: store, parentID: parentID) else { return nil }
        let routed: Result<Selection?, Error>
        switch result {
        case .success(let urls):
            routed = .success(urls.first.map { request.mode == .files ? .file($0) : .markdownFolder($0) })
        case .failure(let error):
            let cocoa = error as NSError
            if error is CancellationError || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError) {
                routed = .success(nil)
            } else { routed = .failure(error) }
        }
        return Completion(request: request, result: routed)
    }
    mutating func cancel(requestID: UUID?) {
        guard request?.id == requestID else { return }
        reset()
    }
    mutating func reset() { isPresented = false; request = nil }
}

struct LibraryView: View {
    private enum UtilitySheet: String, Identifiable {
        case trash, conflicts, settings
        var id: String { rawValue }
    }
    @ObservedObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var shelfWidth
    @State private var utilitySheet: UtilitySheet?
    @State private var importPicker = LibraryImportPickerState()
    @State private var shownFolders = 24
    @State private var shownBooks = 48
    @State private var openingNote: LibraryDocument?
    @State private var openingBook: LibraryDocument?
    @State private var folderFrames: [String: CGRect] = [:]
    @State private var openGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markdownFolder:URL?
    @State private var folderCandidates:[URL]=[]
    @State private var folderAccessing=false
    @State private var folderImportRequest: LibraryImportPickerState.Request?
    private var unresolvedRows:[LibraryDocument] {
        guard model.query.isEmpty,model.libraryInventory?.rootIDs.contains(model.currentFolder) == true else { return [] }
        let shown=Set(model.visibleDocs().map(\.id))
        return model.unresolvedDocuments.filter { !shown.contains($0.id) }
    }
    private var shelfFolders: [LibraryDocument] { model.visibleDocs().filter { $0.kind == .folder } }
    private var shelfBooks: [LibraryDocument] { model.visibleDocs().filter { $0.kind != .folder } }
    private var openDocument: LibraryDocument? {
        guard let document = model.selected, document.kind != .folder else { return nil }
        return document
    }
    private var shelfAnimation: Animation { .spring(response: 0.46, dampingFraction: 0.88) }
    private var libraryNoticeVisible: Bool {
        !model.unresolvedDocuments.isEmpty
            || (!model.query.isEmpty && model.searchCoverage != nil)
            || model.localOperationError != nil
            || model.credentialNotice != nil
            || model.connectionError != nil
    }
    var body: some View {
      let pickerRequest = importPicker.request
      return VStack(spacing:0) {
        NavigationStack {
          ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if shelfCaptionVisible {
                        shelfCaption
                    }
                    if !shelfFolders.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("文件夹").font(.caption).foregroundStyle(LibraryPalette.muted)
                            LazyVGrid(columns: foldColumns, spacing: 28) {
                                ForEach(shelfFolders.prefix(shownFolders), id: \.id) { foldedFolder($0) }
                            }
                            remainderButton(remaining: shelfFolders.count - min(shownFolders, shelfFolders.count), noun: "个文件夹") { shownFolders += 24 }
                        }
                    }
                    if !shelfBooks.isEmpty {
                        LazyVGrid(columns: bookColumns, spacing: 22) {
                            ForEach(shelfBooks.prefix(shownBooks), id: \.id) { bookCard($0) }
                        }
                        remainderButton(remaining: shelfBooks.count - min(shownBooks, shelfBooks.count), noun: "本") { shownBooks += 48 }
                    }
                    if !unresolvedRows.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("待恢复位置").font(.caption).foregroundStyle(LibraryPalette.muted)
                            LazyVGrid(columns: bookColumns, spacing: 22) {
                                ForEach(unresolvedRows.prefix(shownBooks), id: \.id) { bookCard($0) }
                            }
                        }
                    }
                }
                .padding(shelfWidth == .compact ? 16 : 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(model.currentFolder)
                .transition(.modifier(
                    active: PaperFold(angle: 72, opacity: 0.15),
                    identity: PaperFold(angle: 0, opacity: 1)
                ))
            }
            .animation(shelfAnimation, value: model.currentFolder)
            .onChange(of: model.currentFolder) { _, _ in shownFolders = 24; shownBooks = 48 }
            .onChange(of: model.query) { _, _ in shownFolders = 24; shownBooks = 48 }
            .overlay {
                if model.visibleDocs().isEmpty && unresolvedRows.isEmpty {
                    if model.syncing && !model.isLocalWorkspace {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在同步目录…").font(.headline)
                            Text("书会随着目录出现。PDF 和图片要等打开某一本再下载。")
                                .font(.callout).foregroundStyle(LibraryPalette.muted).multilineTextAlignment(.center)
                        }.padding(24)
                    } else if model.searching { ProgressView("正在搜索…") }
                    else {
                        ContentUnavailableView {
                            VStack(spacing: 14) {
                                if model.query.isEmpty {
                                    Image("LibraryMark").resizable().scaledToFit().frame(width: 220).accessibilityHidden(true)
                                } else {
                                    InkGlyph(name: "magnifyingglass").frame(width: 40, height: 40)
                                }
                                Text(model.query.isEmpty ? "这里还没有书" : "没有找到这本书").font(.title3.weight(.semibold))
                            }
                        } description: {
                            Text(model.query.isEmpty ? "从「添加」新建笔记，或导入 Markdown 和 PDF。" : "试试其他标题或正文关键词。")
                        }
                    }
                }
            }
            .searchable(text: $model.query, isPresented: $model.searchPresented, prompt: "在资料库中查找")
            .navigationTitle(model.folderName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationBarBackButtonHidden(!model.isAtRoot)
            .toolbar {
                if !model.isAtRoot {
                    ToolbarItem(placement: .automatic) {
                        Button(action: model.goUp) {
                            InkGlyph(name: "chevron.left")
                                .frame(width: 16, height: 16)
                                .accessibilityLabel("返回上一级")
                        }
                    }
                }
                ToolbarItemGroup(placement: .automatic) {
                    Menu("添加") {
                        Button("笔记") { model.newNote() }
                        Button("文件夹") { model.newFolder() }
                        Divider()
                        Button("导入 Markdown 或 PDF") { beginImport(.files) }
                        Button("导入带附件的笔记") { beginImport(.markdownFolder) }
                    }
                    Menu {
                        Button("整理") { model.catalogPresented = true }
                        Button("回收站") { utilitySheet = .trash }
                        Button("冲突与恢复草稿") { utilitySheet = .conflicts }
                        Button("设置") { utilitySheet = .settings }
                        Divider()
                        if model.session == nil {
                            Button("登录并同步") { model.showConnection() }
                        }
                        if model.isLocalWorkspace {
                            if model.session != nil { Button("打开已同步的资料库") { model.showConnectedLibrary() } }
                        } else {
                            Button("只看这台设备") { model.showLocalLibrary() }
                        }
                        if model.savedRoots.count > 1 {
                            Menu("其他位置") {
                                ForEach(model.savedRoots, id: \.self) { root in
                                    Button(model.rootTitle(root)) {
                                        model.currentFolder = root
                                        model.folderName = model.rootTitle(root)
                                        model.selectedId = nil
                                    }
                                }
                            }
                        }
                    } label: {
                        InkGlyph(name: "ellipsis.circle").frame(width: 22, height: 22)
                    }
                }
            }
            .scaleEffect(openDocument == nil ? 1 : 0.94)
            .offset(x: openDocument == nil ? 0 : -36)
            .opacity(openDocument == nil ? 1 : 0)
            .allowsHitTesting(openDocument == nil)
            .accessibilityHidden(openDocument != nil)
            if let document = openDocument {
              readingSurface(document)
                .transition(.asymmetric(insertion: .pageOpen, removal: .pageClose))
                .zIndex(1)
            }
            if let note = openingNote {
              NoteOpenCover(title: note.name, origin: folderFrames[note.id] ?? .zero)
                .zIndex(2)
            }
            if let book = openingBook {
              BookOpenCover(title: book.name, kind: book.kind == .pdf ? "PDF" : "笔记")
                .zIndex(2)
            }
          }
          .coordinateSpace(name: "shelfSpace")
          .onPreferenceChange(FolderFrameKey.self) { folderFrames = $0 }
          .overlay(alignment: .top) { SyncRibbon(active: model.syncing && !model.isLocalWorkspace) }
          .animation(shelfAnimation, value: openDocument?.id)
          .animation(shelfAnimation, value: model.syncing)
          .background(LibraryPalette.paper)
        }
        if libraryNoticeVisible {
            VStack(alignment: .leading, spacing: 6) {
                if !model.unresolvedDocuments.isEmpty {
                    Text("\(model.unresolvedDocuments.count) 项旧资料的目录位置待恢复。可在根目录查看和导出，原内容和未提交操作已保留。")
                        .foregroundStyle(LibraryPalette.muted)
                }
                if !model.query.isEmpty,let coverage=model.searchCoverage { Text(coverage.summary).foregroundStyle(LibraryPalette.muted).accessibilityLabel(coverage.summary) }
                if let error = model.localOperationError {
                    HStack(alignment:.top) {
                        Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                        Button { model.dismissLocalOperationError() } label: {
                            InkGlyph(name: "xmark.circle").frame(width: 16, height: 16)
                        }.accessibilityLabel("关闭本地操作错误提示")
                    }
                }
                CredentialWaitingNotice(model: model)
                if let error = model.connectionError {
                    HStack(alignment: .top) {
                        Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if model.session != nil {
                            Button("重试") { model.requestSync() }.disabled(model.syncing)
                        }
                    }
                }
            }
            .font(.caption).padding(12).background(.regularMaterial)
            }
        }
        .fileImporter(isPresented: $importPicker.isPresented,
                      allowedContentTypes: pickerRequest?.mode.allowedContentTypes ?? LibraryImportPickerState.Mode.files.allowedContentTypes,
                      allowsMultipleSelection: false,
                      onCompletion: { result in completeImport(result, requestID: pickerRequest?.id) },
                      onCancellation: { importPicker.cancel(requestID: pickerRequest?.id) })
        .onChange(of: ObjectIdentifier(model.store)) { _, _ in
            importPicker.reset(); finishFolderImport()
        }
        .onDisappear { importPicker.reset(); finishFolderImport() }
        .sheet(item: $utilitySheet) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .trash: TrashView(model: model)
                    case .conflicts: ConflictResolutionView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { utilitySheet = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 640, minHeight: 400, idealHeight: 600)
        }
        .sheet(isPresented: $model.catalogPresented) {
            NavigationStack {
                CatalogWorkspaceView(documents: model.documents, store: model.store, parentID: model.rootFor(model.currentFolder),
                                     onChange: model.catalogChanged, onOpen: model.openDocument, onOpenSource: model.openSource, currentDeviceID: model.deviceId)
                .toolbar { Button("完成") { model.catalogPresented = false } }
            }.frame(minWidth: 320, minHeight: 500)
        }
        .sheet(isPresented:Binding(get:{markdownFolder != nil},set:{if !$0 { finishFolderImport() }})) {
            NavigationStack {
                List {
                    Text("选择一篇笔记。笔记引用的图片和音频会一并复制，原文件保持原样。")
                        .font(.callout).foregroundStyle(LibraryPalette.muted)
                    ForEach(folderCandidates,id:\.self) { file in
                        Button {
                            if folderImportRequest?.isCurrent(store:model.store,parentID:model.currentFolder) == true {
                                model.importFile(url:file)
                            }
                            finishFolderImport()
                        } label: {
                            Text(file.lastPathComponent).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.navigationTitle("导入含附件的笔记")
                    .toolbar { Button("取消") { finishFolderImport() } }
            }.frame(minWidth:320,minHeight:400)
        }
        .sheet(isPresented:Binding(get:{model.moveTarget != nil},set:{if !$0 { model.moveTarget=nil }})) {
            if let moving=model.moveTarget {
                MoveDocumentView(document:moving,model:model)
            }
        }
        .fileExporter(isPresented: $model.exportPresented, document: model.exportFile,
                      contentType: model.exportType, defaultFilename: model.exportName) { result in
            switch result {
            case .success: model.banner = "文件已导出。"; model.dismissLocalOperationError(for:"导出")
            case .failure(let error): model.reportLocal("导出", error: error)
            }
        }
        .alert("重命名", isPresented: Binding(
            get: { model.renameTarget != nil },
            set: { if !$0 { model.renameTarget = nil } }
        )) {
            TextField("名称", text: $model.renameDraft)
            Button("取消", role: .cancel) { model.renameTarget = nil }
            Button("确定") { model.commitRename() }
        } message: {
            Text(model.renameTarget?.kind == .folder ? "文件夹名称" : "文档名称（扩展名会自动补全）")
        }
        .alert("笔记已导入，请留意链接",isPresented:Binding(get:{model.importNotice != nil},set:{if !$0 { model.importNotice=nil }})) {
            Button("知道了") { model.importNotice=nil }
        } message: { Text(model.importNotice ?? "") }
    }

    private func closeReading() {
        withAnimation(shelfAnimation) { model.selectedId = nil }
    }

    @ViewBuilder
    private func readingSurface(_ document: LibraryDocument) -> some View {
        let needsFile = model.documentNeedsLocalFile(document)
        Group {
            if needsFile {
                VStack(spacing: 12) {
                    if let message = model.openDownloadError {
                        Text("这一本没有下载下来。").font(.headline)
                        Text(message).font(.callout).foregroundStyle(LibraryPalette.muted).multilineTextAlignment(.center)
                        Button("重试") { Task { await model.materializeOpenedDocument(document.id) } }
                            .buttonStyle(InkButtonStyle())
                    } else {
                        ProgressView()
                        Text("正在下载这一本…").font(.subheadline)
                    }
                }
                .padding(24)
            } else if document.kind == .pdf {
                PDFReaderView(documentId: document.id, model: model, store: model.store)
            } else {
                EditorScreen(docId: document.id, model: model, store: model.store)
            }
        }
        .id(model.store.root.path + "/" + document.id)
        .task(id: document.id) { await model.materializeOpenedDocument(document.id) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LibraryPalette.paper)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: closeReading) {
                    if shelfWidth == .compact {
                        InkGlyph(name: "chevron.left").frame(width: 18, height: 18)
                    } else {
                        Label("资料库", ink: "chevron.left")
                    }
                }
                .accessibilityLabel("返回资料库")
            }
        }
    }

    private func beginImport(_ mode: LibraryImportPickerState.Mode) {
        guard markdownFolder == nil else { return }
        importPicker.present(mode, store: model.store, parentID: model.currentFolder)
    }

    private func completeImport(_ result: Result<[URL], Error>, requestID: UUID?) {
        guard let completion = importPicker.complete(result, requestID: requestID, store: model.store, parentID: model.currentFolder) else { return }
        switch completion.result {
        case .success(.file(let url)):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            model.importFile(url: url)
        case .success(.markdownFolder(let folder)):
            let scoped = folder.startAccessingSecurityScopedResource()
            do {
                let candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                guard !candidates.isEmpty else {
                    if scoped { folder.stopAccessingSecurityScopedResource() }
                    model.reportLocal("导入", error: MarkdownImportError.unreadable("所选文件夹中没有 Markdown 文件")); return
                }
                folderAccessing = scoped; folderCandidates = candidates
                folderImportRequest = completion.request; markdownFolder = folder
            } catch {
                if scoped { folder.stopAccessingSecurityScopedResource() }
                model.reportLocal("读取文件夹", error: error)
            }
        case .success(nil): break
        case .failure(let error): model.reportLocal("导入", error: error)
        }
    }

    private func finishFolderImport() {
        if folderAccessing,let markdownFolder { markdownFolder.stopAccessingSecurityScopedResource() }
        folderAccessing=false;markdownFolder=nil;folderCandidates=[];folderImportRequest=nil
    }

    /// The quiet “目录已同步 / 选择一本，进入阅读” line stays off the iPhone shelf.
    private var shelfCaptionVisible: Bool {
        #if os(iOS)
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.searchTruncated || !query.isEmpty || model.isLocalWorkspace { return true }
        return model.syncing || model.connectionError != nil || model.session == nil
        #else
        return true
        #endif
    }

    private var shelfCaption: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(iOS)
            if model.syncing || model.connectionError != nil || model.session == nil || model.isLocalWorkspace {
                Text(model.syncStatusLine)
            }
            #else
            Text(model.syncStatusLine)
            #endif
            if model.searchTruncated {
                Text("只列出前 1000 本。换一个更具体的词，才能看到其余的。")
            } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                #if os(iOS)
                if model.isLocalWorkspace {
                    Text("这些书只留在这台设备，不会同步。")
                }
                #else
                Text(model.isLocalWorkspace ? "这些书只留在这台设备，不会同步。" : "选择一本，进入阅读。")
                #endif
            } else {
                Text("搜索结果")
            }
        }
        .font(.subheadline)
        .foregroundStyle(LibraryPalette.muted)
    }

    @ViewBuilder
    private func remainderButton(remaining: Int, noun: String, advance: @escaping () -> Void) -> some View {
        if remaining > 0 {
            Button("还有 \(remaining) \(noun)") { advance() }
                .buttonStyle(InkButtonStyle())
        }
    }

    private var foldColumns: [GridItem] {
        let compact = shelfWidth == .compact
        return [GridItem(.adaptive(minimum: compact ? 160 : 180, maximum: compact ? 400 : 240), spacing: compact ? 18 : 28)]
    }
    private var bookColumns: [GridItem] {
        let compact = shelfWidth == .compact
        return [GridItem(.adaptive(minimum: compact ? 148 : 140, maximum: compact ? 220 : 180), spacing: compact ? 14 : 22)]
    }

    private func foldedFolder(_ doc: LibraryDocument) -> some View {
        Button {
            openFolderAnimated(doc)
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LibraryPalette.ink.opacity(0.08))
                    .frame(height: 108)
                    .offset(x: 10, y: 14)
                VStack(spacing: 0) {
                    Text(doc.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LibraryPalette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(folderTabColor(doc))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12, style: .continuous))
                        .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.ink.opacity(0.22)).frame(height: 1) }
                    ZStack(alignment: .bottomLeading) {
                        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous)
                            .fill(LibraryPalette.paper)
                            .overlay(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous).stroke(LibraryPalette.ink.opacity(0.16), lineWidth: 1))
                        Text("展开")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LibraryPalette.muted)
                            .padding(12)
                    }
                    .frame(height: 78)
                    .rotation3DEffect(.degrees(34), axis: (x: 1, y: 0, z: 0), anchor: .top, anchorZ: 0, perspective: 0.5)
                    .shadow(color: LibraryPalette.ink.opacity(0.12), radius: 8, y: 10)
                }
                .background(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12, style: .continuous)
                        .fill(LibraryPalette.paper)
                        .frame(height: 42)
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12, style: .continuous).stroke(LibraryPalette.ink.opacity(0.2), lineWidth: 1))
                }
            }
            .frame(height: 132)
            .padding(.bottom, 18)
        }
        .buttonStyle(.plain)
        .opacity(openingNote?.id == doc.id ? 0 : 1)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FolderFrameKey.self, value: [doc.id: proxy.frame(in: .named("shelfSpace"))])
            }
        }
        .contextMenu { docMenu(doc) }
        .dropDestination(for: String.self) { ids, _ in model.drop(ids, onto: doc) }
        .accessibilityLabel(doc.name)
        .accessibilityHint("展开这个文件夹")
    }

    private func bookAvailability(_ doc: LibraryDocument) -> String {
        guard doc.kind == .pdf else { return "笔记" }
        if let path = doc.pdfPath, FileManager.default.fileExists(atPath: path) { return "PDF" }
        return "PDF · 未下载"
    }

    private func bookCard(_ doc: LibraryDocument) -> some View {
        let excerpt = model.query.isEmpty ? nil : model.searchResults.first(where: { $0.objectId == doc.id })?.excerpt
        return Button {
            openBookAnimated(doc)
        } label: {
            HStack(spacing: 0) {
                Rectangle().fill(shelfTint(doc.catalog.shelfColor) ?? LibraryPalette.ink).frame(width: 14)
                VStack(alignment: .leading, spacing: 8) {
                    Text(doc.name)
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(LibraryPalette.ink)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if let excerpt {
                        Text(excerpt).font(.caption2).foregroundStyle(LibraryPalette.muted).lineLimit(2)
                    }
                    Text(bookAvailability(doc))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LibraryPalette.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: shelfWidth == .compact ? (excerpt == nil ? 168 : 196) : (excerpt == nil ? 188 : 210))
            .background(LibraryPalette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(LibraryPalette.ink.opacity(0.22), lineWidth: 1))
            .shadow(color: LibraryPalette.ink.opacity(0.16), radius: 7, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .contextMenu { docMenu(doc) }
        .draggable(doc.id)
        .accessibilityIdentifier("move-document-" + doc.id)
        .accessibilityLabel(doc.name)
        .accessibilityHint(doc.kind == .pdf ? "打开这本 PDF" : "打开这本笔记")
    }

    private func openFolderAnimated(_ doc: LibraryDocument) {
        guard !reduceMotion else {
            withAnimation(shelfAnimation) { _ = model.openFolder(doc) }
            return
        }
        openGeneration += 1
        let generation = openGeneration
        openingBook = nil
        openingNote = doc
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(980))
            guard generation == openGeneration else { return }
            withAnimation(shelfAnimation) { _ = model.openFolder(doc) }
            try? await Task.sleep(for: .milliseconds(160))
            guard generation == openGeneration else { return }
            openingNote = nil
        }
    }

    private func openBookAnimated(_ doc: LibraryDocument) {
        guard !reduceMotion else {
            withAnimation(shelfAnimation) {
                if !model.activateSelectedPDFSearchResult(doc.id) { model.selectLibraryRow(doc.id) }
            }
            return
        }
        openGeneration += 1
        let generation = openGeneration
        openingNote = nil
        openingBook = doc
        withAnimation(shelfAnimation) {
            if !model.activateSelectedPDFSearchResult(doc.id) { model.selectLibraryRow(doc.id) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(680))
            guard generation == openGeneration else { return }
            openingBook = nil
        }
    }

    private func folderTabColor(_ doc: LibraryDocument) -> Color {
        guard let tint = shelfTint(doc.catalog.shelfColor) else { return LibraryPalette.ink.opacity(0.06) }
        return tint.opacity(0.34)
    }

    @ViewBuilder
    func docMenu(_ doc: LibraryDocument) -> some View {
        Button("重命名") { model.beginRename(doc) }
        Menu("颜色") {
            ForEach(ShelfSwatch.all, id: \.hex) { swatch in
                Button(doc.catalog.shelfColor == CatalogMetadata.normalizedShelfColor(swatch.hex) ? "✓ \(swatch.title)" : swatch.title) {
                    model.setShelfColor(doc, swatch.hex)
                }
            }
        }
        Button("移动到…") { model.moveTarget=doc }
        if doc.kind == .md { Button("导出 Markdown 与附件") { model.prepareExport(doc) } }
        if doc.kind == .pdf { Button("导出含批注 PDF") { model.prepareExport(doc) } }
        Button("删除", role: .destructive) { model.delete(doc) }
    }
}

private struct ShelfSwatch {
    let hex: String
    let title: String
    static let all: [ShelfSwatch] = [
        .init(hex: "", title: "默认"),
        .init(hex: "#8C3A4A", title: "绛红"),
        .init(hex: "#A65D3F", title: "赭石"),
        .init(hex: "#3E6B4F", title: "松绿"),
        .init(hex: "#3A5F8C", title: "海蓝"),
        .init(hex: "#8A6A32", title: "麦金"),
        .init(hex: "#6B4C7A", title: "暮紫"),
    ]
}

private func shelfTint(_ hex: String) -> Color? {
    let normalized = CatalogMetadata.normalizedShelfColor(hex)
    guard normalized.count == 7, let value = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
    return Color(
        red: Double((value >> 16) & 0xff) / 255,
        green: Double((value >> 8) & 0xff) / 255,
        blue: Double(value & 0xff) / 255
    )
}

private struct PageTurn: ViewModifier, @MainActor Animatable {
    var amount: Double
    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(amount * 86), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.55)
            .opacity(1 - amount * 0.2)
    }
}

private extension AnyTransition {
    static var pageOpen: AnyTransition { .modifier(active: PageTurn(amount: 1), identity: PageTurn(amount: 0)) }
    static var pageClose: AnyTransition { .modifier(active: PageTurn(amount: 1), identity: PageTurn(amount: 0)) }
}

private struct FolderFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct NoteOpenCover: View {
    let title: String
    let origin: CGRect
    @State private var traveled = false
    var body: some View {
        GeometryReader { geo in
            let width = traveled ? min(420, geo.size.width * 0.52) : max(origin.width, 1)
            let flap: Double = traveled ? 0 : 34
            VStack(spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LibraryPalette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(LibraryPalette.ink.opacity(0.06))
                ZStack(alignment: .bottomLeading) {
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous)
                        .fill(LibraryPalette.paper)
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous).stroke(LibraryPalette.ink.opacity(0.16), lineWidth: 1))
                    Text("展开")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(LibraryPalette.muted)
                        .padding(12)
                        .opacity(traveled ? 0 : 1)
                }
                .frame(height: traveled ? 170 : 78)
                .rotation3DEffect(.degrees(flap), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
            }
            .background(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12, style: .continuous)
                    .fill(LibraryPalette.paper)
                    .frame(height: 42)
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12, style: .continuous).stroke(LibraryPalette.ink.opacity(0.2), lineWidth: 1))
            }
            .frame(width: width)
            .shadow(color: LibraryPalette.ink.opacity(traveled ? 0.22 : 0.12), radius: traveled ? 18 : 8, y: traveled ? 14 : 10)
            .position(x: traveled || origin == .zero ? geo.size.width / 2 : origin.midX,
                      y: traveled || origin == .zero ? geo.size.height / 2 : origin.midY)
        }
        .background(LibraryPalette.ink.opacity(traveled ? 0.08 : 0).ignoresSafeArea())
        .allowsHitTesting(true)
        .onAppear {
            withAnimation(.spring(response: 0.92, dampingFraction: 0.9)) { traveled = true }
        }
        .accessibilityLabel("正在打开 \(title)")
    }
}

private struct BookOpenCover: View {
    let title: String
    let kind: String
    @State private var turned = false
    var body: some View {
        ZStack {
            LibraryPalette.ink.opacity(turned ? 0 : 0.08).ignoresSafeArea()
            HStack(spacing: 0) {
                Rectangle().fill(LibraryPalette.ink).frame(width: 16)
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.system(.title2, design: .serif))
                        .foregroundStyle(LibraryPalette.ink)
                        .lineLimit(4)
                    Spacer(minLength: 0)
                    Text(kind).font(.caption.weight(.semibold)).foregroundStyle(LibraryPalette.muted)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 230, height: 320)
            .background(LibraryPalette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: LibraryPalette.ink.opacity(0.22), radius: 16, y: 10)
            .rotation3DEffect(.degrees(turned ? -102 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
        }
        .allowsHitTesting(true)
        .onAppear {
            withAnimation(.spring(response: 0.68, dampingFraction: 0.84)) { turned = true }
        }
        .accessibilityLabel("正在打开 \(title)")
    }
}

private struct SyncRibbon: View {
    var active: Bool
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
                let cycle = 1.2
                let travel = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                Capsule()
                    .fill(LibraryPalette.ink)
                    .frame(width: max(56, width * 0.22), height: 2)
                    .offset(x: -width * 0.22 + travel * (width * 1.22))
                    .opacity(active ? 0.9 : 0)
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(!active)
        .accessibilityLabel("正在同步")
    }
}

private struct PaperFold: ViewModifier, @MainActor Animatable {
    var angle: Double
    var opacity: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, opacity) }
        set { angle = newValue.first; opacity = newValue.second }
    }
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
            .opacity(opacity)
    }
}

struct MoveDocumentView:View {
    let document:LibraryDocument
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var destinations:[LibraryDocument] {
        model.documents.filter {
            $0.kind == .folder && $0.state == "active" && $0.catalog.category != .topic && $0.id != document.id
                && !$0.parentId.isEmpty && !document.isAncestor(of:$0,in:model.documents)
                && LibraryHierarchy.rootID(for:$0.id,documents:model.documents) == LibraryHierarchy.rootID(for:document.parentId,documents:model.documents)
        }.sorted(by:LibraryDocument.folderFirst)
    }
    var body:some View {
        NavigationStack {
            List {
                Button { performMove(model.rootFor(document.parentId)) } label: {
                    Label("资料库根目录", ink: "books.vertical")
                        .frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .disabled(document.parentId == model.rootFor(document.parentId))
                ForEach(destinations,id:\.id) { folder in
                    Button {
                        performMove(folder.id)
                    } label: {
                        VStack(alignment:.leading) {
                            Label(folder.name, ink: "folder")
                            Text(model.folderBreadcrumb(folder)).font(.caption).foregroundStyle(LibraryPalette.muted)
                        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(folder.id == document.parentId)
                }
                if let error=model.localOperationError { Text(error).foregroundStyle(.red) }
            }.navigationTitle("移动“\(document.name)”")
            .toolbar { Button("取消") { dismiss() } }
        }.frame(minWidth:320,minHeight:420)
    }
    func performMove(_ parent:String) { if model.move(document,to:parent) { dismiss() } }
}

struct EditorScreen: View {
    let docId: String
    @ObservedObject var model: AppModel
    let store:DocumentStore
    @State private var editorHandle=EditorBridgeHandle()
    @State private var inspecting = false
    @State private var stickyPresented = false
    var doc: LibraryDocument? {
        if model.selectedId == docId { return model.selected }
        return model.documents.first(where: { $0.id == docId })
    }
    var body: some View {
        Group {
            if let doc {
                VStack(spacing:0) {
                  if doc.catalog.archived {
                    HStack {
                        Label("已归档 · 阅读模式", ink: "archivebox")
                        Spacer()
                        Button("继续编辑") {
                            editorHandle.flush { saved in
                                guard saved else { return }
                                do {
                                    _ = try store.setCatalogArchived(id:doc.id,archived:false)
                                    if store === model.store { model.catalogChanged() }
                                } catch { model.reportLocal("恢复笔记编辑",error:error) }
                            }
                        }
                    }.font(.callout).padding(12).background(.regularMaterial)
                  }
                  EditorWebView(docId:doc.id,markdown:doc.markdown,store:store,handle:editorHandle,readOnly:doc.catalog.archived,searchText:model.navigationSearch,
                              onPersist:{ if $0 === model.store { model.noteEditorAutosave() } },
                              onError:{ if store === model.store { model.reportLocal("保存笔记",message:$0) } },onOpenLink:model.openDocumentLink)
                }
                .navigationTitle(doc.catalogTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if let note=model.sourceReturnNote {
                        Button { editorHandle.flush { if $0 { model.returnToReadingNote() } } } label: { Label("返回笔记", ink: "arrow.uturn.backward") }
                            .help(note.catalogTitle)
                    }
                    Button("资料详情") { inspecting = true }
                    Menu {
                        #if canImport(UIKit)
                        Button("便签与语音编辑") { editorHandle.flush { if $0 { stickyPresented=true } } }
                            .disabled(doc.catalog.archived)
                        #endif
                        Button("重命名") { model.beginRename(doc) }
                        Button("移动到…") {
                            editorHandle.flush { saved in
                                guard saved, store === model.store, model.selectedId == doc.id else { return }
                                model.moveTarget = doc
                            }
                        }
                        Button("导出") { editorHandle.flush { if $0 { model.prepareExport(doc) } } }
                    } label: { InkGlyph(name: "ellipsis.circle").frame(width: 22, height: 22) }
                }
                #if canImport(UIKit)
                .sheet(isPresented: $stickyPresented) {
                    NavigationStack {
                        StickyNoteEditor(doc:doc,store:store,onPersist:{ if store === model.store { model.noteEditorAutosave() } },
                                         onRename:{ model.rename(doc,to:$0) },onBeginRename:{ model.beginRename(doc) },onExport:{ model.prepareExport(doc) })
                        .toolbar { Button("完成") { stickyPresented=false } }
                    }
                }
                #endif
                .sheet(isPresented: $inspecting) {
                    NavigationStack {
                        CatalogInspectorView(document: doc, documents: model.documents, store: model.store,
                                             onChange: model.catalogChanged, onOpen: model.openDocument,
                                             onOpenSource: model.openSource, currentDeviceID: model.deviceId)
                    }
                    .frame(minWidth: 320, minHeight: 450)
                }
            } else { InkUnavailable(title: "文档不可用", symbol: "doc", message: "返回资料库查看其他文档。") { EmptyView() } }
        }
    }
}

#if canImport(UIKit)
typealias ViewRepresentable = UIViewRepresentable
#else
typealias ViewRepresentable = NSViewRepresentable
#endif

final class PDFViewHandle {
    weak var view: PDFView?
}

struct PDFReaderView: View {
    private enum ReaderField: Hashable { case page, search }
    @FocusState private var focusedField: ReaderField?
    let documentId: String
    @ObservedObject var model: AppModel
    let store:DocumentStore
    @State private var pdfDoc: PDFDocument?
    @State private var handle = PDFViewHandle()
    @State private var commentPresented = false
    @State private var commentDraft = ""
    @State private var hint = ""
    @State private var annotationsPresented = false
    @State private var inspectorPresented = false
    @State private var excerptPresented = false
    @State private var excerptQuote = ""
    @State private var excerptComment = ""
    @State private var targetNoteID = ""
    @State private var noteSelectionPresented = false
    @State private var pageNumber = 1
    @State private var pageInput = "1"
    @State private var pageInputError:String?
    @State private var fileHash: String?
    @State private var searchText = ""
    @State private var searchMatches: [PDFSelection] = []
    @State private var originalTextIndex: PDFOriginalTextIndex?
    @State private var matchIndex = 0
    @State private var readingState = PDFReadingState()
    @State private var initialPage = 0
    @State private var loadedSourceID = ""
    @State private var annotationDocument: LibraryDocument?
    @State private var excerptPage = 0
    @State private var excerptFileHash: String?
    @State private var excerptOperationID=UUID().uuidString.lowercased()
    var sourceIdentity:String { document.map(PDFReadingSource.identity(for:)) ?? "" }
    var sourceIsCurrent:Bool { model.selectedId == documentId && store === model.store && loadedSourceID == sourceIdentity && pdfDoc != nil }
    var document: LibraryDocument? { model.documents.first(where: { $0.id == documentId }) }
    var noteCandidates: [CatalogSelectionCandidate] {
        guard let document else { return [] }
        return CatalogDocumentSelection.candidates(in:model.documents,source:document,purpose:.excerptNote,inventory:try? store.legacyLibraryInventory())
    }
    var annotations: [PDFTextAnnotation] {
        guard let document else { return [] }
        return (try? JSONDecoder().decode([PDFTextAnnotation].self, from: Data(document.annotationsJSON.utf8))) ?? []
    }
    var totalPages:Int { pdfDoc?.pageCount ?? 0 }
    var body: some View {
        Group {
            if let document {
                readerContent
                    .navigationTitle(document.catalogTitle)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { readerToolbar(document) }
                    .alert("文字备注",isPresented:$commentPresented) {
                        TextField("备注内容",text:$commentDraft)
                        Button("取消",role:.cancel) {}
                        Button("添加",action:addComment).disabled(commentDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    } message: { Text("备注放在选区或当前页。") }
                    .sheet(isPresented:$annotationsPresented) { annotationsSheet }
                    .sheet(isPresented:$inspectorPresented) { inspectorSheet(document) }
                    .sheet(isPresented:$excerptPresented) { excerptSheet }
                    .task(id:sourceIdentity) { loadPDF() }
                    .onChange(of:document.annotationsJSON) { _,_ in
                        if sourceIsCurrent,let pdfDoc { PDFExport.replaceManaged(in:pdfDoc,annotations:annotations,currentPDFBlobId:document.pdfBlobId) }
                    }
                    .onChange(of:document.catalog.readingPositions) { _,positions in
                        readingState.refresh(positions:positions,deviceID:model.deviceId)
                    }
                    .onChange(of:model.pdfNavigationRequest) { _,request in
                        guard let request,sourceIsCurrent,let source=readingState.source,request.matches(source) else { return }
                        if goTo(request.pageIndex) { model.consumePDFNavigation(request) }
                    }
            } else { Text("文档不可用") }
        }
    }
    private var readerContent:some View {
        VStack(spacing:0) {
            readerControls
            if let pageInputError { Text(pageInputError).font(.callout).foregroundStyle(.red).padding(.horizontal,10).padding(.bottom,8).accessibilityIdentifier("pdf-page-input-error") }
            if !searchMatches.isEmpty { searchControls }
            if let position=readingState.suggestion { resumeControls(position) }
            if annotations.contains(where: { $0.needsPlacementReview(for:document?.pdfBlobId) }) {
                HStack {
                    Text("原文件已变化，旧批注保留在列表中，位置需要重新核对。")
                    Button("查看待核对批注") { annotationDocument=document;annotationsPresented=true }
                }.font(.caption).padding(8)
            }
            if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(LibraryPalette.muted).padding(8) }
            PDFKitView(pdfDoc:$pdfDoc,handle:handle,initialPage:initialPage,onPageChange:pageChanged,onInstalled:installedPDF)
        }
    }
    private var readerControls:some View {
        ViewThatFits(in:.horizontal) {
            HStack { pageControls;Spacer(minLength:16);pdfSearchControls }
            VStack(spacing:8) { pageControls;pdfSearchControls }
        }.padding(10)
    }
    private var pageControls:some View {
        HStack {
            Button { goTo(pageNumber-2) } label: { InkGlyph(name: "chevron.left").frame(width: 16, height: 16) }
                .disabled(pageNumber<=1).accessibilityLabel("上一页")
            TextField("页码",text:$pageInput).frame(width:48).multilineTextAlignment(.center)
                .focused($focusedField,equals:.page)
                #if canImport(UIKit)
                .keyboardType(.numberPad)
                #endif
                .onSubmit(submitPageInput)
            Button("前往",action:submitPageInput)
                .accessibilityLabel("前往输入页码")
            Text("/ \(totalPages)").foregroundStyle(LibraryPalette.muted)
            Button { goTo(pageNumber) } label: { InkGlyph(name: "chevron.right").frame(width: 16, height: 16) }
                .disabled(pageNumber>=totalPages).accessibilityLabel("下一页")
        }.fixedSize(horizontal:true,vertical:false)
    }
    private var pdfSearchControls:some View {
        HStack {
            TextField("在 PDF 中查找",text:$searchText).frame(maxWidth:200)
                .focused($focusedField,equals:.search)
                .onSubmit { focusedField=nil;findText() }
            Button("查找") { focusedField=nil;findText() }
        }
    }
    private var searchControls:some View {
        HStack {
            Text("第 \(matchIndex+1) / \(searchMatches.count) 处匹配")
            Button("下一处") { matchIndex=(matchIndex+1)%searchMatches.count;showMatch() }
            Button("清除") { searchMatches=[];handle.view?.clearSelection() }
        }.font(.caption).padding(6)
    }
    private func resumeControls(_ position:CatalogReadingPosition)->some View {
        HStack {
            Text(position.deviceID == "manual" ? "手动记录在第 \(position.pageIndex+1) 页" : "另一设备读到第 \(position.pageIndex+1) 页")
            Button("继续阅读") { readingState.dismiss(position);goTo(position.pageIndex) }
            Button("保持当前页") { readingState.dismiss(position) }
        }.font(.caption).padding(8)
    }
    @ToolbarContentBuilder private func readerToolbar(_ document:LibraryDocument)->some ToolbarContent {
        ToolbarItemGroup {
            if let note=model.sourceReturnNote {
                Button(action: model.returnToReadingNote) { Label("返回笔记", ink: "arrow.uturn.backward") }.help(note.catalogTitle)
            }
            Button("高亮",action:addHighlight)
            Menu("批注与摘录") {
                Button("文字备注") { commentDraft="";commentPresented=true }
                Button("管理批注") { annotationDocument=document;annotationsPresented=true }
                Button("摘录到笔记",action:beginExcerpt)
            }
            Menu {
                Button("资料详情") { inspectorPresented=true }
                Button("重命名") { model.beginRename(document) }
                Button("导出含批注 PDF") { model.prepareExport(document) }
            } label: { InkGlyph(name: "ellipsis.circle").frame(width: 22, height: 22) }
        }
    }
    private var annotationsSheet:some View {
        NavigationStack {
            PDFAnnotationsView(annotations:annotations,currentPDFBlobId:document?.pdfBlobId,onSelect:{ annotation in
                guard !annotation.needsPlacementReview(for:document?.pdfBlobId) else { return }
                annotationsPresented=false;goTo(annotation.pageIndex)
            },onChange:{ base,proposed in
                guard let original=annotationDocument else { return false }
                return model.savePDFAnnotations(document:original,store:store,base:base,proposed:proposed)
            })
            .toolbar { Button("完成") { annotationsPresented=false } }
        }.frame(minWidth:320,minHeight:420)
    }
    private func inspectorSheet(_ document:LibraryDocument)->some View {
        NavigationStack {
            CatalogInspectorView(document:document,documents:model.documents,store:store,
                                 onChange:model.catalogChanged,onOpen:model.openDocument,onOpenSource:model.openSource,currentDeviceID:model.deviceId)
        }.frame(minWidth:320,minHeight:450)
    }
    private var excerptSheet:some View {
        NavigationStack {
            Form {
                Section("原文摘录 · 第 \(excerptPage+1) 页") { Text(excerptQuote).textSelection(.enabled) }
                Section("我的理解") { TextEditor(text:$excerptComment).frame(minHeight:100) }
                Section("保存到") {
                    Button { noteSelectionPresented=true } label: {
                        HStack {
                            VStack(alignment:.leading,spacing:5) {
                                if targetNoteID.isEmpty { Text("新建阅读笔记") }
                                else if let candidate=noteCandidates.first(where:{$0.id == targetNoteID}) {
                                    Text(candidate.title)
                                    Text("文件："+candidate.filename).font(.caption).foregroundStyle(LibraryPalette.muted)
                                    Text(candidate.folderPath).font(.caption).foregroundStyle(LibraryPalette.muted)
                                } else { Text("原选择已不可用，请重新选择") }
                            }
                            Spacer()
                            InkGlyph(name: "chevron.right").frame(width: 12, height: 12).foregroundStyle(LibraryPalette.muted)
                        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("选择摘录笔记")
                }
            }.navigationTitle("摘录到笔记")
            .toolbar {
                Button("取消") { excerptPresented=false }
                Button("保存摘录",action:saveExcerpt)
                    .disabled(!targetNoteID.isEmpty && !noteCandidates.contains(where:{$0.id == targetNoteID}))
            }
            .sheet(isPresented:$noteSelectionPresented) {
                CatalogDocumentSelectionSheet(purpose:.excerptNote,candidates:noteCandidates,selectedID:targetNoteID) { id in
                    targetNoteID=id;noteSelectionPresented=false
                }
            }
        }.frame(minWidth:320,minHeight:440)
    }
    func loadPDF() {
        guard model.selectedId == documentId,store === model.store else { return }
        handle.view?.clearSelection();searchMatches=[];matchIndex=0
        pdfDoc=nil;originalTextIndex=nil;fileHash=nil;loadedSourceID="";hint="";pageInputError=nil
        guard let document,let path=document.pdfPath,let pdf=PDFDocument(url:URL(fileURLWithPath:path)),!pdf.isLocked,pdf.pageCount>0 else {
            readingState=PDFReadingState();hint="这一本的文件还不在手机上。返回资料库后再打开一次。";return
        }
        originalTextIndex=PDFOriginalTextIndex(document:pdf)
        fileHash=try? DocumentStore.catalogFileHash(URL(fileURLWithPath:path))
        let source=PDFReadingSource(identity:sourceIdentity,fileHash:fileHash,pageCount:pdf.pageCount)
        let navigation=model.pdfNavigationRequest
        initialPage=readingState.load(source:source,positions:document.catalog.readingPositions,deviceID:model.deviceId,navigation:navigation)
        if let navigation { model.consumePDFNavigation(navigation) }
        pageNumber=initialPage+1;pageInput=String(pageNumber)
        PDFExport.replaceManaged(in:pdf,annotations:annotations,currentPDFBlobId:document.pdfBlobId)
        loadedSourceID=sourceIdentity;pdfDoc=pdf
        var messages:[String]=[]
        if fileHash == nil { messages.append("无法核对 PDF 文件版本，未恢复或记录阅读位置。请重新打开后重试。") }
        else if let navigation,!navigation.matches(source) { messages.append("原文件已变化，未跳转旧页码，请核对原文后定位。") }
        else if !document.catalog.readingPositions.isEmpty,!document.catalog.readingPositions.contains(where:{$0.fileHash == fileHash}) {
            messages.append("已有阅读位置的文件版本无法匹配，未自动恢复旧页码。")
        }
        if originalTextIndex?.hasText != true {
            messages.append("这份 PDF 没有文字层，可以阅读和添加文字备注；全文查找与文字高亮需要可选文字。")
        }
        hint=messages.joined(separator:"\n")
    }
    func installedPDF(_ installed:PDFDocument) {
        guard installed === pdfDoc,sourceIsCurrent,store === model.store,let source=readingState.source else { return }
        if let request=model.pdfNavigationRequest,request.matches(source) {
            _ = readingState.installed(source:source)
            if goTo(request.pageIndex) { model.consumePDFNavigation(request) }
            return
        }
        if let event=readingState.installed(source:source) { model.savePDFReadingPosition(event,documentID:documentId,store:store) }
    }
    func submitPageInput() {
        switch PDFPageInput.pageIndex(pageInput,totalPages:totalPages) {
        case .failure(let error):
            pageInputError=error.localizedDescription
        case .success(let index):
            guard goTo(index) else { pageInputError="PDF 页面尚未准备好，请稍后重试。";return }
            pageInputError=nil;focusedField=nil
        }
    }
    @discardableResult
    func goTo(_ index:Int)->Bool {
        guard sourceIsCurrent,let pdfDoc,let view=handle.view,view.document === pdfDoc,
              let page=pdfDoc.page(at:min(max(0,index),pdfDoc.pageCount-1)) else { return false }
        view.go(to:page)
        // PDFView emits no page-change notification when navigating to its
        // current page. Explicit navigation must still repair a stale record.
        pageChanged(pdfDoc,pdfDoc.index(for:page))
        pageInputError=nil
        return true
    }
    func pageChanged(_ observedPDF:PDFDocument,_ index:Int) {
        guard observedPDF === pdfDoc,sourceIsCurrent,store === model.store,let source=readingState.source,
              index >= 0,index < source.pageCount else { return }
        pageNumber=index+1;pageInput=String(pageNumber)
        if let event=readingState.visit(index,source:source) { model.savePDFReadingPosition(event,documentID:documentId,store:store) }
    }
    func addHighlight() {
        guard sourceIsCurrent,let view=handle.view,let document else { hint="原文件已变化，请等待页面重新载入。";return }
        guard selectedPagesHaveOriginalText else { hint="当前选区没有原文件文字层，请使用文字备注。";return }
        let records=PDFAnnotator.highlight(in:view).map { item in var value=item;value.pdfBlobId=document.pdfBlobId;return value }
        guard !records.isEmpty else { hint="请先选中需要高亮的文字。扫描页可以使用文字备注。";return }
        if model.savePDFAnnotations(document:document,store:store,base:annotations,proposed:annotations+records) {
            hint="已保存高亮，可在“管理批注”中修改或删除。"
        }
    }
    func addComment() {
        guard sourceIsCurrent,let view=handle.view,let document else { hint="原文件已变化，请等待页面重新载入。";return }
        let records=PDFAnnotator.comment(in:view,text:commentDraft).map { item in var value=item;value.pdfBlobId=document.pdfBlobId;return value }
        guard !records.isEmpty else { hint="无法添加备注，请确认页面已打开。";return }
        if model.savePDFAnnotations(document:document,store:store,base:annotations,proposed:annotations+records) { hint="已保存文字备注。" }
    }
    func findText() {
        guard let pdfDoc,!searchText.isEmpty else { return }
        handle.view?.clearSelection()
        searchMatches=originalTextIndex?.selections(in:pdfDoc,query:searchText) ?? [];matchIndex=0
        if searchMatches.isEmpty { hint="没有找到匹配文字。扫描页没有可检索文字层。" }
        else { hint="";showMatch() }
    }
    func showMatch() {
        guard searchMatches.indices.contains(matchIndex) else { return }
        let selection=searchMatches[matchIndex];selection.color = .systemYellow
        handle.view?.setCurrentSelection(selection,animate:true);handle.view?.scrollSelectionToVisible(nil)
        if let page=selection.pages.first,let pdfDoc {
            let index=pdfDoc.index(for:page)
            if index>=0,index<pdfDoc.pageCount { pageChanged(pdfDoc,index) }
        }
    }
    func beginExcerpt() {
        guard selectedPagesHaveOriginalText else { hint="当前选区没有原文件文字层，可以通过资料详情手动记录摘录与思考。";return }
        excerptQuote=handle.view?.currentSelection?.string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard !excerptQuote.isEmpty else { hint="请先选中一段原文，再摘录到笔记。";return }
        guard sourceIsCurrent else { hint="原文件已变化，请重新选择原文。";return }
        excerptPage=handle.view?.currentSelection?.pages.first.flatMap { pdfDoc?.index(for:$0) } ?? (pageNumber-1)
        excerptFileHash=fileHash
        excerptComment="";targetNoteID="";excerptOperationID=UUID().uuidString.lowercased();excerptPresented=true
    }
    private var selectedPagesHaveOriginalText: Bool {
        guard let pdfDoc,let selection=handle.view?.currentSelection else { return false }
        return originalTextIndex?.contains(selection,in:pdfDoc) == true
    }
    func saveExcerpt() {
        guard excerptPresented else { return }
        do {
            let note:LibraryDocument
            if targetNoteID.isEmpty {
                note=try store.createCatalogNote(sourceID:documentId,quote:excerptQuote,comment:excerptComment,pageIndex:excerptPage,fileHash:excerptFileHash,parentID:model.rootFor(model.currentFolder),noteID:excerptOperationID)
            } else {
                note=try store.appendCatalogExcerpt(noteID:targetNoteID,sourceID:documentId,quote:excerptQuote,comment:excerptComment,pageIndex:excerptPage,fileHash:excerptFileHash,excerptID:excerptOperationID)
            }
            excerptPresented=false;model.catalogChanged();model.openDocument(note)
        } catch { model.reportLocal("保存摘录",error:error) }
    }
}

struct PDFAnnotationsView: View {
    let annotations:[PDFTextAnnotation]
    let currentPDFBlobId:String?
    var onSelect:(PDFTextAnnotation)->Void
    var onChange:([PDFTextAnnotation],[PDFTextAnnotation])->Bool
    @State private var editing:PDFTextAnnotation?
    @State private var editBase:[PDFTextAnnotation]=[]
    @State private var text=""
    @State private var errorMessage:String?
    var body: some View {
        ScrollView {
          LazyVStack(alignment:.leading,spacing:16) {
            ForEach(annotations,id:\.id) { item in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Text(item.type == "highlight" ? "高亮" : "备注").font(.headline)
                        Spacer()
                        if item.needsPlacementReview(for:currentPDFBlobId) {
                            Text("待核对 · 原第 \(item.pageIndex+1) 页").foregroundStyle(.orange)
                        } else {
                            Button("第 \(item.pageIndex+1) 页") { onSelect(item) }
                                .accessibilityIdentifier("pdf-annotation-\(item.id)-page")
                                .accessibilityLabel("前往\(annotationContext(item))")
                        }
                    }
                    if item.needsPlacementReview(for:currentPDFBlobId) {
                        Text("文字已保留。请在当前原文中重新选择位置并添加批注，核对后可删除这条旧记录；导出不使用旧坐标。")
                            .font(.caption).foregroundStyle(LibraryPalette.muted)
                    }
                    if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                    HStack {
                        Button("编辑文字") { text=item.text;editBase=annotations;editing=item }
                            .accessibilityIdentifier("pdf-annotation-\(item.id)-edit")
                            .accessibilityLabel("编辑\(annotationContext(item))的文字")
                        Menu("颜色") {
                            ForEach(["#FFE08A","#BDE8C4","#A9D4FF","#FFC8D3"],id:\.self) { color in
                                Button(colorName(color)) { var value=item;value.color=color;_ = save(value,base:annotations) }
                                    .accessibilityIdentifier("pdf-annotation-\(item.id)-color-\(color.dropFirst())")
                                    .accessibilityLabel("将\(annotationContext(item))设为\(colorName(color))")
                            }
                        }
                        .accessibilityIdentifier("pdf-annotation-\(item.id)-color")
                        .accessibilityLabel("修改\(annotationContext(item))的颜色")
                        Spacer()
                        Button("删除",role:.destructive) {
                            if !onChange(annotations,annotations.filter { $0.id != item.id }) { errorMessage="未能保存删除操作，请查看资料库的错误提示后重试。" }
                        }
                        .accessibilityIdentifier("pdf-annotation-\(item.id)-delete")
                        .accessibilityLabel("删除\(annotationContext(item))")
                    }.font(.caption)
                }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8)).buttonStyle(.borderless)
                    .accessibilityElement(children:.contain)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
          }.padding()
        }
        .overlay { if annotations.isEmpty { InkUnavailable(title: "暂无本库新增批注", symbol: "pencil.tip", message: "原件自带批注仍保留在 PDF 中；这里管理在本库新增的高亮和备注。") { EmptyView() } } }
        .navigationTitle("高亮与文字批注")
        .sheet(isPresented:Binding(get:{editing != nil},set:{if !$0 { editing=nil }})) {
            NavigationStack {
                Form {
                    TextEditor(text:$text).frame(minHeight:160).accessibilityLabel("批注文字")
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }.navigationTitle("编辑批注")
                .toolbar {
                    Button("取消") { editing=nil }
                    Button("保存") {
                        if var value=editing { value.text=text;if save(value,base:editBase) { editing=nil } }
                    }
                }
            }.frame(minWidth:320,minHeight:300)
        }
    }
    @discardableResult func save(_ value:PDFTextAnnotation,base:[PDFTextAnnotation])->Bool {
        let saved=onChange(base,base.map { $0.id == value.id ? value : $0 })
        errorMessage=saved ? nil : "批注未能写入当前文件。文字仍保留，请查看资料库的错误提示；版本变化时也会保留恢复草稿。"
        return saved
    }
    func colorName(_ color:String)->String { ["#FFE08A":"黄色","#BDE8C4":"绿色","#A9D4FF":"蓝色","#FFC8D3":"粉色"][color] ?? color }
    func annotationContext(_ annotation:PDFTextAnnotation)->String {
        let page=annotation.needsPlacementReview(for:currentPDFBlobId) ? "待核对，原第" : "第"
        let kind=annotation.type == "highlight" ? "高亮" : "备注"
        let summary=String(annotation.text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").prefix(36))
        return "\(page) \(annotation.pageIndex+1) 页\(kind)" + (summary.isEmpty ? "" : "，\(summary)")
    }
}

struct TrashView: View {
    @ObservedObject var model: AppModel
    var trashedDocuments: [LibraryDocument] { model.documents.filter { $0.state == "trashed" } }
    var body: some View {
        Group {
            if trashedDocuments.isEmpty {
                InkUnavailable(title: "回收站为空", symbol: "trash", message: "删除的资料会在这里保留 30 天，可在到期前还原。") { EmptyView() }
            } else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:16) {
                        Text("删除的资料保留 30 天。还原到原目录；原目录不可用时回到资料库根目录，同名资料会添加数字后缀。")
                            .font(.callout).foregroundStyle(LibraryPalette.muted)
                        ForEach(trashedDocuments,id:\.id) { doc in
                            let expired=doc.purgeAt.map { $0 <= Date() } ?? false
                            HStack {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(doc.name)
                                    if let deadline=doc.purgeAt {
                                        Text(expired ? "已到期，等待清理" : "保留至 \(deadline.formatted(date:.abbreviated,time:.shortened))")
                                            .font(.caption).foregroundStyle(LibraryPalette.muted)
                                    }
                                }
                                Spacer()
                                Button("还原") { model.restore(doc) }
                                    .buttonStyle(.bordered).disabled(expired)
                                    .accessibilityLabel("还原 \(doc.name)")
                            }.accessibilityElement(children:.contain)
                            Divider()
                        }
                    }.padding()
                }
            }
        }
        .navigationTitle("回收站")
    }
}

enum AppRelease {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info?["CFBundleVersion"] as? String ?? ""
        if build.isEmpty || build == version { return version }
        return "\(version)（\(build)）"
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsGroup("账号") {
                    Text(model.username).font(.body.weight(.semibold)).foregroundStyle(LibraryPalette.ink)
                    Text("两端共用这一个账号，不提供注册。").font(.callout).foregroundStyle(LibraryPalette.muted)
                    if model.session != nil {
                        Button("退出登录") { model.logout() }.buttonStyle(InkButtonStyle())
                    } else {
                        Button("登录并同步") { model.showConnection() }.buttonStyle(InkButtonStyle(prominent: true))
                    }
                }
                if !model.isLocalWorkspace && model.session != nil {
                    settingsGroup("这台设备上的资料") {
                        Text("复制到已同步的资料库，这台设备上的原件保留。再复制一次会多一份。")
                            .font(.callout).foregroundStyle(LibraryPalette.muted)
                        Button("复制到已同步的资料库") { model.copyLocalDocumentsToConnectedLibrary() }
                            .buttonStyle(InkButtonStyle())
                            .disabled(model.syncing)
                    }
                }
                settingsGroup("风格") {
                    Picker("风格", selection: Binding(
                        get: { model.appearance },
                        set: { model.setAppearance($0) }
                    )) {
                        ForEach(AppearanceStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                settingsGroup("版本") {
                    Text(AppRelease.display).font(.body.monospacedDigit()).foregroundStyle(LibraryPalette.ink)
                }
                settingsGroup("连接与提交") {
                    Text(model.server.isEmpty ? "尚未配置服务器" : model.server)
                        .font(.body).foregroundStyle(LibraryPalette.ink).textSelection(.enabled)
                    Text("待提交 \(model.pendingCount) 项").foregroundStyle(LibraryPalette.muted)
                    Text("资料先保存到本机；联网时自动同步。维护或连接失败时可继续编辑。")
                        .font(.callout).foregroundStyle(LibraryPalette.muted)
                    if model.session != nil {
                        Button(model.syncing ? "正在同步…" : "现在同步一次") { model.requestSync() }
                            .buttonStyle(InkButtonStyle())
                            .disabled(model.syncing)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LibraryPalette.paper)
        .navigationTitle("设置")
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(LibraryPalette.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if canImport(UIKit)
private final class PDFLayoutView:PDFView {
    var onLayout:(()->Void)?
    override func layoutSubviews() { super.layoutSubviews();onLayout?() }
    override func didMoveToWindow() { super.didMoveToWindow();setNeedsLayout();onLayout?() }
}
#endif

struct PDFKitView: ViewRepresentable {
    @Binding var pdfDoc: PDFDocument?
    var handle: PDFViewHandle
    var initialPage:Int = 0
    var onPageChange: (PDFDocument,Int) -> Void = { _,_ in }
    var onInstalled: (PDFDocument) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(onPageChange:onPageChange) }
    #if canImport(UIKit)
    func makeUIView(context: Context) -> PDFView { make(context) }
    func updateUIView(_ uiView: PDFView, context: Context) { apply(uiView,context) }
    #else
    func makeNSView(context: Context) -> PDFView { make(context) }
    func updateNSView(_ nsView: PDFView, context: Context) { apply(nsView,context) }
    #endif
    func make(_ context:Context) -> PDFView {
        #if canImport(UIKit)
        let view=PDFLayoutView()
        view.onLayout={ [weak coordinator=context.coordinator,weak view] in
            guard let view else { return };coordinator?.layoutReady(view)
        }
        #else
        let view=PDFView()
        #endif
        view.autoScales=true;view.displayMode = .singlePageContinuous;view.displayDirection = .vertical
        handle.view=view
        NotificationCenter.default.addObserver(context.coordinator,selector:#selector(Coordinator.changed(_:)),name:.PDFViewPageChanged,object:view)
        apply(view,context);return view
    }
    func apply(_ view:PDFView,_ context:Context) {
        handle.view=view;context.coordinator.onPageChange=onPageChange
        if view.document !== pdfDoc {
            context.coordinator.installing=true
            let installationID=UUID();context.coordinator.installationID=installationID
            #if canImport(UIKit)
            let coordinator=context.coordinator
            coordinator.pendingDocument=pdfDoc
            coordinator.pendingCompletion=onInstalled
            coordinator.navigation=pdfDoc.map { PDFInitialLayoutNavigation(targetPage:min(max(0,initialPage),max(0,$0.pageCount-1))) }
            coordinator.navigationScheduled=false
            view.document=pdfDoc
            if pdfDoc == nil { coordinator.installing=false }
            else { view.setNeedsLayout();coordinator.layoutReady(view) }
            #else
            view.document=pdfDoc
            if let page=pdfDoc?.page(at:initialPage) { view.go(to:page) }
            let installed=pdfDoc,coordinator=context.coordinator,completion=onInstalled
            DispatchQueue.main.async {
                guard coordinator.installationID == installationID,view.document === installed else { return }
                coordinator.installing=false
                if let installed { completion(installed) }
            }
            #endif
        }
    }
    @MainActor final class Coordinator:NSObject {
        var onPageChange:(PDFDocument,Int)->Void
        var installing=false
        var installationID=UUID()
        #if canImport(UIKit)
        var pendingDocument:PDFDocument?
        var pendingCompletion:((PDFDocument)->Void)?
        var navigation:PDFInitialLayoutNavigation?
        var navigationScheduled=false

        func layoutReady(_ view:PDFView) {
            guard installing,!navigationScheduled,let document=pendingDocument,view.document === document,
                  let target=navigation?.targetPage,
                  PDFInitialLayoutNavigation.isReady(size:view.bounds.size,attached:view.window != nil) else { return }
            navigationScheduled=true
            let generation=installationID
            DispatchQueue.main.async { [weak self,weak view] in
                guard let self,let view,self.installationID == generation,self.installing,view.document === document else { return }
                guard PDFInitialLayoutNavigation.isReady(size:view.bounds.size,attached:view.window != nil) else {
                    self.navigationScheduled=false;return
                }
                // UIKit has now supplied the viewport. Finish inner PDF layout
                // before navigating; assignment-time go(to:) can be reset to p1.
                view.layoutIfNeeded();view.layoutDocumentView()
                if let page=document.page(at:target) { view.go(to:page) }
                self.confirmLayout(view,document:document,generation:generation)
            }
        }
        private func confirmLayout(_ view:PDFView,document:PDFDocument,generation:UUID) {
            DispatchQueue.main.async { [weak self,weak view] in
                guard let self,let view,self.installationID == generation,self.installing,view.document === document else { return }
                let actual=view.currentPage.map { document.index(for:$0) }
                if self.navigation?.observe(page:actual,size:view.bounds.size,attached:view.window != nil) == true {
                    self.navigationScheduled=false;self.installing=false
                    self.pendingDocument=nil;self.navigation=nil
                    let completion=self.pendingCompletion;self.pendingCompletion=nil
                    completion?(document)
                } else if actual == self.navigation?.targetPage,
                          PDFInitialLayoutNavigation.isReady(size:view.bounds.size,attached:view.window != nil) {
                    self.confirmLayout(view,document:document,generation:generation)
                } else {
                    // Let the next real layout retry; do not spin on a detached
                    // or zero-size view or publish its temporary first page.
                    self.navigationScheduled=false;view.setNeedsLayout()
                }
            }
        }
        #endif
        init(onPageChange:@escaping (PDFDocument,Int)->Void) { self.onPageChange=onPageChange }
        @objc func changed(_ notification:Notification) {
            guard !installing,let view=notification.object as? PDFView,let page=view.currentPage,let doc=view.document else { return }
            let index=doc.index(for:page),installationID=self.installationID,callback=onPageChange
            DispatchQueue.main.async {
                guard !self.installing,self.installationID == installationID,view.document === doc,view.currentPage === page else { return }
                callback(doc,index)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
