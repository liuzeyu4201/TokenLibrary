// Builds a synthetic, offline OLD-INSTALLATION database through DocumentStore.
// This does not launch the app, bind a server, install credentials, or inject
// anything into an existing application container. See generated README.md.
import Foundation
import CryptoKit
import GRDB
import LibraryCore

@main struct LegacyCatalogFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "LegacyCatalogFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: generator NEW_ABSOLUTE_DIRECTORY SYNTHETIC_THREE_PAGE_PDF"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let input = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        guard directory.path.hasPrefix("/private/tmp/") || directory.path.hasPrefix("/tmp/"),
              !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "LegacyCatalogFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Refusing an existing or non-temporary output directory"])
        }
        let inputData = try Data(contentsOf: input)
        let sha: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        guard inputData.starts(with: Data("%PDF-".utf8)) else { throw CocoaError(.fileReadCorruptFile) }
        let rootA = "aaaaaaaa-1000-4000-8000-000000000001"
        let rootB = "bbbbbbbb-2000-4000-8000-000000000002"
        let unknownRoot = "cccccccc-3000-4000-8000-000000000003"
        let missingRelated = "dddddddd-4000-4000-8000-000000000004"
        let sourceID = "aaaaaaaa-0000-4000-8000-000000000101"
        let folderID = "aaaaaaaa-0000-4000-8000-000000000102"
        let noteRootID = "aaaaaaaa-0000-4000-8000-000000000103"
        let noteNestedID = "aaaaaaaa-0000-4000-8000-000000000104"
        let topicAID = "aaaaaaaa-0000-4000-8000-000000000105"
        let noteBID = "bbbbbbbb-0000-4000-8000-000000000201"
        let topicBID = "bbbbbbbb-0000-4000-8000-000000000202"
        let orphanID = "cccccccc-0000-4000-8000-000000000301"
        let localID = "eeeeeeee-0000-4000-8000-000000000401"
        let store = try DocumentStore(directory: directory)
        // Explicit synthetic root evidence. No missing parent is inferred as a root.
        try store.registerLegacyLibraryRoot(rootID: rootA)
        try store.registerLegacyLibraryRoot(rootID: rootB)
        let asset = try store.importAttachment(data: inputData, fileName: "A库研究原件.pdf", mime: "application/pdf")
        let pdfURL = try store.resolveAttachment(path: asset.path)
        var definitions: [[String: Any]] = []
        @discardableResult
        func seed(_ id: String, kind: DocKind = .md, parent: String, name: String, title: String,
                  category: CatalogCategory = .note, related: [String] = [], pending: Bool = false) throws -> LibraryDocument {
            var metadata = CatalogMetadata(category: category, title: title)
            metadata.authors = kind == .folder ? [] : ["合成验收作者"]
            metadata.year = kind == .folder ? nil : 2026
            metadata.tags = ["离线验收夹具"]
            metadata.relatedIDs = related
            let doc = LibraryDocument(id: id, kind: kind, parentId: parent, name: name,
                markdown: kind == .md ? "# \(title)\n\n完全合成的离线资料。用于目录、同库候选与草稿保护验收。\n" : "",
                pdfPath: kind == .pdf ? pdfURL.path : nil, revision: pending ? 0 : 3, localGeneration: 0,
                state: "active", purgeAt: nil, status: pending ? .pending : .savedLocal,
                annotationsJSON: "[]", metadataJSON: try metadata.json(), pdfBlobId: kind == .pdf ? asset.blobId : nil)
            if pending { _ = try store.createDocument(doc) }
            else { try store.saveDocument(doc, enqueue: false) }
            definitions.append(["id": id, "kind": kind.rawValue, "parentId": parent, "filename": name,
                                "title": title, "category": category.rawValue, "pending": pending])
            return doc
        }
        try seed(folderID, kind: .folder, parent: rootA, name: "A库课程", title: "A库课程", category: .unclassified)
        try seed(sourceID, kind: .pdf, parent: rootA, name: "A库研究原件.pdf", title: "A库 研究原件", category: .paper, related: [missingRelated])
        try seed(noteRootID, parent: rootA, name: "阅读笔记.md", title: "同名阅读笔记", pending: true)
        try seed(noteNestedID, parent: folderID, name: "阅读笔记.md", title: "同名阅读笔记")
        try seed(topicAID, kind: .folder, parent: rootA, name: "A库专题", title: "A库 专题", category: .topic)
        try seed(noteBID, parent: rootB, name: "阅读笔记.md", title: "B库 不应出现在A候选")
        try seed(topicBID, kind: .folder, parent: rootB, name: "B库专题", title: "B库 不应出现在A专题", category: .topic)
        try seed(orphanID, parent: unknownRoot, name: "未知根笔记.md", title: "未知根 不应出现在候选")
        try seed(localID, parent: "root", name: "本机根对照.md", title: "本机根 不应出现在A候选")
        let inventory = try store.legacyLibraryInventory()
        guard Set(inventory.rootIDs) == Set(["root", rootA, rootB]),
              inventory.rootID(for: sourceID) == rootA,
              inventory.rootID(for: noteNestedID) == rootA,
              inventory.rootID(for: noteBID) == rootB,
              inventory.rootID(for: orphanID) == nil,
              inventory.unresolvedDocumentIDs == [orphanID],
              try store.loadDocument(id: rootA) == nil, try store.loadDocument(id: rootB) == nil,
              try store.pending().count == 1 else { throw CocoaError(.coderInvalidValue) }
        let queueBefore = try store.pending()
        let reopened = try DocumentStore(directory: directory)
        guard try reopened.pending() == queueBefore,
              try reopened.listDocuments(includeTrashed: true).count == 9 else { throw CocoaError(.coderInvalidValue) }
        let boundKeys = try store.db.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM sync_state WHERE key IN ('server','libraryId','rootId','sessionToken')")
        }
        guard boundKeys.isEmpty else { throw CocoaError(.coderInvalidValue) }
        let controls = directory.appendingPathComponent("import-controls", isDirectory: true)
        try FileManager.default.createDirectory(at: controls, withIntermediateDirectories: true)
        let markdown = "# 普通文件导入对照\n\n该文件只导入当前目录，不创建或恢复其他资料库根。多根候选验证请使用独立旧安装库。\n"
        try Data(markdown.utf8).write(to: controls.appendingPathComponent("普通文件导入对照.md"))
        try inputData.write(to: controls.appendingPathComponent("三页PDF导入对照.pdf"))
        try store.db.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        let manifest: [String: Any] = [
            "fixture": "synthetic-offline-legacy-mixed-library", "nativeVerified": false,
            "directory": directory.path, "entry": "Debug --verification-directory, then 更多 > 当前库的根目录 or 资料库; not a library.sqlite import feature",
            "roots": [rootA, rootB], "defaultRoot": "root", "unregisteredRoot": unknownRoot,
            "rootDocumentsExist": false, "serverBindings": boundKeys,
            "documents": definitions, "count": 9, "unresolvedDocumentIDs": inventory.unresolvedDocumentIDs,
            "sourceID": sourceID, "missingRelatedID": missingRelated,
            "expectedExcerptCandidates": [noteRootID, noteNestedID],
            "expectedRelatedCandidates": [noteRootID, noteNestedID], "expectedTopics": [topicAID],
            "initialPendingOperationCount": queueBefore.count,
            "initialPendingOperationIDs": queueBefore.map(\.operationId),
            "pdfAssetPath": asset.path, "pdfBlobID": asset.blobId, "pdfBytes": inputData.count, "pdfSHA256": sha(inputData),
            "databaseSHA256": sha(try Data(contentsOf: directory.appendingPathComponent("library.sqlite"))),
            "importControls": ["import-controls/普通文件导入对照.md", "import-controls/三页PDF导入对照.pdf"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: directory.appendingPathComponent("manifest.json"))
        let readme = """
        # 合成旧安装混合资料库（未原生验收）

        此目录只用于离线旧安装/已登记多根的隔离验收。通过正式 DocumentStore 建库，无服务器绑定、登录凭据或自动联网。未启动应用，未写现有验收容器/53056。

        普通用户的“导入”只支持 Markdown/PDF 或含附件 Markdown，不能导入此 SQLite 库，也不能借文件导入建立库根。不要把普通文件导入成功当成多根测试通过。

        后续由主代理在明确的独立验证轮次，使用 Debug 包的 `--verification-directory \(directory.path)` 启动。目录名用于隔离验证偏好。现验证应用必须先妥善结束；本生成器不会启动或切换它。iOS 若复制此目录，必须使用一个新隔离目录并改启动路径，不覆盖现验证数据；PDF 由正式库路径恢复机制重新定位。

        ## 可见入口与断言

        - 默认本机根显示“本机根对照.md”，未知父的笔记列入“待恢复位置的旧资料”。
        - 主列表“更多 → 当前库的根目录”包含本机根、已保存资料库 aaaaaa、已保存资料库 bbbbbb；未知 cccccc 不能变成根。
        - 打开“资料库”，找到“A库 研究原件”：摘录笔记和相关资料选择器只包含两份“同名阅读笔记”，文件名相同，目录分别为“资料库”和“资料库 / A库课程”。专题只有“A库 专题”。B库、本机根、未知根项目均不可作为A的候选。
        - 原件含一条缺失 related ID，详情显示不可用占位，可明确移除；它不对应任何实际资料，不应删除其他文档。
        - 初始有且只有一项未提交创建操作（A根下阅读笔记），重开后 operation ID/请求内容不变。离线界面的待提交1项是故意保留的验收边界，不是同步失败。
        - 两个注册根都没有实体root文件夹；原件、笔记、专题通过明确登记证据归库，未知孤儿不会自动归库。

        `import-controls` 中两份普通文件可以在后续系统文件选择器使用。它们只用于单库导入对照，不带跨库身份。尚未复制到模拟器Files或调用导入UI。

        完整ID、SHA-256、初始队列ID与预期候选见 manifest.json。
        """
        try Data(readme.utf8).write(to: directory.appendingPathComponent("README.md"))
        print("Prepared \(directory.path): 9 documents, roots A/B/root, 1 unresolved, 1 preserved pending operation; no app launch or native acceptance.")
    }
}
