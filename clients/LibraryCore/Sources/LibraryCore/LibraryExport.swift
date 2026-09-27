import Foundation

public enum LibraryExportError: LocalizedError {
    case tooLarge, invalidEntry
    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "导出包超过 512 MB，请减少引用附件后重试。"
        case .invalidEntry: return "导出文件名或附件路径无效。"
        }
    }
}

public struct MarkdownExport: Sendable {
    public let data: Data
    public let filename: String
    public let isArchive: Bool
}

extension DocumentStore {
    /// A portable Markdown file, or a ZIP containing the Markdown, referenced
    /// attachments and source metadata. Original library files are never changed.
    public func exportPortableMarkdown(id: String) throws -> MarkdownExport {
        guard let document = try loadDocument(id: id), document.kind == .md else { throw StoreError.notFound }
        let parsed = try MarkdownReferences(document.markdown)
        var replacements: [String: String] = [:], assets: [String: URL] = [:]
        for reference in parsed.mediaReferences {
            let path = reference.destination
            guard path.hasPrefix("media/") || path.hasPrefix("library-asset://") else { continue }
            let url = try resolveAttachment(path: path)
            let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw LibraryExportError.invalidEntry }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            guard relative.hasPrefix("media/") else { throw LibraryExportError.invalidEntry }
            assets[relative] = url
            if path != relative { replacements[path] = relative }
        }
        let filename = URL(fileURLWithPath: document.name).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { throw LibraryExportError.invalidEntry }
        let hasSources = !document.catalog.sourceIDs.isEmpty || !document.catalog.excerpts.isEmpty
        let hasAppLinks = parsed.references.contains { !$0.isImage && URLComponents(string: $0.destination)?.scheme?.lowercased() == "tokenlibrary" }
        var markdown = try parsed.replacingDestinations(replacements)
        if assets.isEmpty && !hasSources && !hasAppLinks {
            return MarkdownExport(data: Data(markdown.utf8), filename: filename, isArchive: false)
        }
        var files: [(String, Data)] = []
        if hasSources || hasAppLinks {
            let guideName = FileNames.availableName("来源说明.md", kind: .md, takenKeys: [FileNames.comparisonKey(filename)])
            markdown += "\n\n---\n\n导出说明：[来源、页码与摘录记录](\(guideName))。`tokenlibrary://` 来源链接需要 TokenLibrary 及对应资料库；普通 Markdown 阅读器无法据此打开原 PDF。来源原件未随此包导出。\n"
            files.append((guideName, Data(try exportedSourceGuide(document).utf8)))
        }
        files.append((filename, Data(markdown.utf8)))
        files.append(("metadata.json", Data(document.metadataJSON.utf8)))
        for path in assets.keys.sorted() {
            files.append((path, try Data(contentsOf: assets[path]!, options: .mappedIfSafe)))
        }
        let archive = try PortableZIP.encode(files)
        return MarkdownExport(data: archive, filename: (filename as NSString).deletingPathExtension + ".zip", isArchive: true)
    }

    private func exportedSourceGuide(_ document: LibraryDocument) throws -> String {
        var text = "# 来源说明\n\n此文件记录导出时保留的来源标题、页码、摘录原文和自己的评论，普通 Markdown 阅读器即可阅读。\n\n包中的图片与音频使用相对 media 路径，请完整解压后与正文一起保留。来源 PDF/其他文档未随包复制；网络媒体和普通外部文件链接也未下载。`tokenlibrary://` 是应用内定位链接，需要安装 TokenLibrary 且拥有对应资料库，不能保证在其他阅读器跳到原文。\n\n页码与文件版本是摘录时的记录；如果原件被替换或删除，请核对原文，不能据此确认当前文件中的位置。\n"
        let excerpts = document.catalog.excerpts
        for (index, excerpt) in excerpts.enumerated() {
            text += "\n## 来源 \(index + 1)：\(Self.exportLiteral(excerpt.sourceTitle))\n\n"
            text += excerpt.pageIndex.map { "摘录时页码：第 \($0 + 1) 页\n\n" } ?? "摘录时页码：未记录\n\n"
            text += "资料标识：\(Self.exportLiteral(excerpt.sourceID))\n\n"
            text += excerpt.fileHash.map { "摘录时文件 SHA-256：\(Self.exportLiteral($0))\n\n" } ?? "文件版本：未记录，请核对原件。\n\n"
            text += "### 摘录原文\n\n" + Self.exportPlainText(excerpt.quote.isEmpty ? "（未填写原文）" : excerpt.quote)
            text += "\n### 我的评论\n\n" + Self.exportPlainText(excerpt.comment.isEmpty ? "（未填写评论）" : excerpt.comment)
        }
        let quoted = Set(excerpts.map(\.sourceID))
        for id in document.catalog.sourceIDs where !quoted.contains(id) {
            let source = try loadDocument(id: id)
            text += "\n## 其他来源：\(Self.exportLiteral(source?.catalogTitle ?? "来源资料已不可用"))\n\n资料标识：\(Self.exportLiteral(id))\n\n未保存独立摘录或页码，请在原资料库中核对。\n"
        }
        if excerpts.isEmpty && document.catalog.sourceIDs.isEmpty { text += "\n正文包含应用内链接，但没有独立的来源快照；请以正文标签和原资料库为准。\n" }
        return text
    }

    private static func exportLiteral(_ value: String) -> String {
        value.map { "\\`*_{}[]<>()#+-.!|".contains($0) ? "\\" + String($0) : String($0) }.joined()
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func exportPlainText(_ value: String) -> String {
        // Quotes can themselves contain Markdown. A long enough fence keeps the
        // source record literal and cannot introduce additional image requests.
        let longest = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "text\n" + value + "\n" + fence + "\n"
    }

}

/// Store-only ZIP: compatible with Archive Utility, Files and standard unzip.
/// No platform subprocess, temporary export folder or network dependency.
enum PortableZIP {
    static let crcTable:[UInt32]=(0..<256).map { item in
        var value=UInt32(item)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }
    static func crc32(_ data:Data)->UInt32 {
        var value:UInt32=0xffffffff
        for byte in data { value=crcTable[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8) }
        return value ^ 0xffffffff
    }
    static func encode(_ files:[(String,Data)]) throws -> Data {
        guard files.count < 65535,files.reduce(0, { $0 + $1.1.count }) <= 512 * 1024 * 1024 else { throw LibraryExportError.tooLarge }
        var result=Data(), directory=Data(), names=Set<String>()
        for (name,data) in files {
            let encoded=Data(name.utf8)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator:"/").contains(".."),
                  !name.contains("\0"), encoded.count <= 65535,names.insert(name).inserted else { throw LibraryExportError.invalidEntry }
            let crc=crc32(data),size=UInt32(data.count),offset=UInt32(result.count)
            result.u32(0x04034b50);result.u16(20);result.u16(0x0800);result.u16(0);result.u16(0);result.u16(33)
            result.u32(crc);result.u32(size);result.u32(size);result.u16(UInt16(encoded.count));result.u16(0);result.append(encoded);result.append(data)
            directory.u32(0x02014b50);directory.u16(20);directory.u16(20);directory.u16(0x0800);directory.u16(0);directory.u16(0);directory.u16(33)
            directory.u32(crc);directory.u32(size);directory.u32(size);directory.u16(UInt16(encoded.count));directory.u16(0);directory.u16(0)
            directory.u16(0);directory.u16(0);directory.u32(0);directory.u32(offset);directory.append(encoded)
        }
        let offset=UInt32(result.count);result.append(directory)
        result.u32(0x06054b50);result.u16(0);result.u16(0);result.u16(UInt16(files.count));result.u16(UInt16(files.count));result.u32(UInt32(directory.count));result.u32(offset);result.u16(0)
        return result
    }
}
private extension Data {
    mutating func u16(_ value:UInt16) { append(UInt8(value & 0xff));append(UInt8((value >> 8) & 0xff)) }
    mutating func u32(_ value:UInt32) { u16(UInt16(value & 0xffff));u16(UInt16((value >> 16) & 0xffff)) }
}
