import Foundation

/// Sample library for simulator preview. Does not enqueue sync operations.
public enum DemoLibrary {
    public static let rootId = "root"

    public static func seedIfEmpty(_ store: DocumentStore) throws {
        if try !store.listDocuments(includeTrashed: true).isEmpty { return }
        try seed(store)
    }

    public static func seed(_ store: DocumentStore) throws {
        let research = id("01")
        let protocolFolder = id("02")
        let pdfFolder = id("03")
        let project = id("04")
        let appFolder = id("05")
        let inbox = id("06")
        let noteMerge = id("11")
        let noteMermaid = id("12")
        let noteKatex = id("13")
        let pdfRFC = id("21")
        let pdfLab = id("22")
        let pdfScan = id("23")
        let trashNote = id("31")

        let pdfDir = store.root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        let rfcPath = pdfDir.appendingPathComponent("RFC9562.pdf")
        let labPath = pdfDir.appendingPathComponent("实验记录.pdf")
        let scanPath = pdfDir.appendingPathComponent("扫描件-无文字.pdf")
        try PDFExport.makeSamplePDF(text: "RFC 9562 UUID Version 4. UUIDv4 is generated once and stays stable across rename and move.").write(to: rfcPath)
        try PDFExport.makeSamplePDF(text: "实验记录 第 4 页 这段与实验结论不一致 searchable-lab-notes").write(to: labPath)
        try Data("%PDF-1.4 scan image only\n%%EOF\n".utf8).write(to: scanPath)

        let rfcAnns = try encodeAnns([
            PDFTextAnnotation(id: id("41"), type: "highlight", pageIndex: 0, x: 72, y: 710, width: 200, height: 18, color: "#FFE08A", text: ""),
            PDFTextAnnotation(id: id("42"), type: "comment", pageIndex: 0, x: 72, y: 680, width: 220, height: 24, color: "#007AFF", text: "这段与实验结论不一致"),
        ])

        let docs: [LibraryDocument] = [
            folder(research, parent: rootId, name: "研究", status: .synced, rev: 1),
            folder(protocolFolder, parent: research, name: "同步协议", status: .synced, rev: 1),
            folder(pdfFolder, parent: research, name: "PDF 批注", status: .synced, rev: 1),
            folder(project, parent: rootId, name: "项目", status: .synced, rev: 1),
            folder(appFolder, parent: project, name: "TokenLibrary", status: .synced, rev: 1),
            folder(inbox, parent: rootId, name: "收件箱", status: .synced, rev: 1),
            md(noteMerge, parent: protocolFolder, name: "三方合并规则.md", status: .synced, rev: 3, body: mergeNote),
            md(noteMermaid, parent: protocolFolder, name: "Mermaid 同步流程.md", status: .conflict, rev: 2, body: mermaidNote),
            md(noteKatex, parent: protocolFolder, name: "KaTeX 公式示例.md", status: .pending, rev: 0, body: katexNote),
            pdf(pdfRFC, parent: pdfFolder, name: "RFC9562.pdf", path: rfcPath.path, status: .synced, rev: 1, anns: rfcAnns),
            pdf(pdfLab, parent: pdfFolder, name: "实验记录.pdf", path: labPath.path, status: .syncing, rev: 1, anns: "[]"),
            pdf(pdfScan, parent: inbox, name: "扫描件-无文字.pdf", path: scanPath.path, status: .synced, rev: 1, anns: "[]"),
            LibraryDocument(
                id: trashNote, kind: .md, parentId: protocolFolder, name: "旧同步笔记.md",
                markdown: "已删除的草稿，可从回收站还原。\n", pdfPath: nil,
                revision: 1, localGeneration: 1, state: "trashed",
                purgeAt: Calendar.current.date(byAdding: .day, value: 11, to: Date()),
                status: .pending, annotationsJSON: "[]"
            ),
        ]
        for d in docs {
            try store.saveDocument(d, enqueue: false)
        }
    }

    private static func id(_ n: String) -> String {
        "00000000-0000-4000-8000-0000000000\(n)"
    }

    private static func folder(_ id: String, parent: String, name: String, status: SyncStatus, rev: Int64) -> LibraryDocument {
        LibraryDocument(id: id, kind: .folder, parentId: parent, name: name, markdown: "", pdfPath: nil, revision: rev, localGeneration: 1, state: "active", purgeAt: nil, status: status, annotationsJSON: "[]")
    }

    private static func md(_ id: String, parent: String, name: String, status: SyncStatus, rev: Int64, body: String) -> LibraryDocument {
        LibraryDocument(id: id, kind: .md, parentId: parent, name: name, markdown: body, pdfPath: nil, revision: rev, localGeneration: 1, state: "active", purgeAt: nil, status: status, annotationsJSON: "[]")
    }

    private static func pdf(_ id: String, parent: String, name: String, path: String, status: SyncStatus, rev: Int64, anns: String) -> LibraryDocument {
        LibraryDocument(id: id, kind: .pdf, parentId: parent, name: name, markdown: "", pdfPath: path, revision: rev, localGeneration: 1, state: "active", purgeAt: nil, status: status, annotationsJSON: anns)
    }

    private static func encodeAnns(_ anns: [PDFTextAnnotation]) throws -> String {
        let data = try JSONEncoder().encode(anns)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static let mergeNote = """
    # 三方合并规则

    服务器用三方合并确认跨设备版本。不同段落的修改自动合并；同一 Mermaid 块两端都改时，整块进入冲突。

    ```mermaid
    graph TD
      A[iPhone] --> C[Go 合并]
      B[Mac] --> C
      C --> D[PostgreSQL]
    ```

    当 $n \\geq 2$ 时，修订号单调递增：

    $$revision_{t+1} = revision_t + 1$$

    - 本机正在输入的内容不能被拉取直接覆盖
    - 未处理冲突不能显示为已同步
    - 图片下载未完成要标明进度

    ![示意图](https://httpbin.org/image/png)
    """

    private static let mermaidNote = """
    # Mermaid 同步流程

    本机改过流程图，服务器也改过，当前 **存在冲突**，未处理完不能标为已同步。

    ```mermaid
    graph TD
      A[working] --> B[outbox]
      B --> C[冲突界面]
    ```
    """

    private static let katexNote = """
    # KaTeX 公式示例

    已保存到本机，等待同步。

    行内：$E = mc^2$

    块公式：

    $$\\frac{\\partial L}{\\partial \\theta} = \\sum_i (y_i - \\hat{y}_i) x_i$$
    """
}
