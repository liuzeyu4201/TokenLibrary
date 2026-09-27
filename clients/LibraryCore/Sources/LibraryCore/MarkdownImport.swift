import Foundation
import GRDB
import Darwin
import ImageIO
import AVFAudio
import AudioToolbox
import UniformTypeIdentifiers

public struct MarkdownImportResult: Sendable {
    public let document: LibraryDocument
    public let warnings: [String]
}

public enum MarkdownImportError: LocalizedError {
    case invalidUTF8, invalidSyntaxRange, invalidFile, tooLarge(String), imageTooLarge(String), unsafePath(String), unreadable(String), unsupportedImage(String), invalidMedia(String)
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "Markdown 必须是有效的 UTF-8 文本。"
        case .invalidSyntaxRange: return "无法准确解析 Markdown 附件引用，未导入不完整的笔记。"
        case .invalidFile: return "请选择普通的 .md 或 .markdown 文件。"
        case .tooLarge(let name): return "文件“\(name)”超过 50 MB，或笔记附件总计超过 500 MB，请拆分后再导入。"
        case .imageTooLarge(let name): return "图片“\(name)”超过 20 MB，无法同步，请压缩后再导入。"
        case .unsafePath(let path): return "附件路径“\(path)”超出笔记所在文件夹，未读取该文件。请把附件放到笔记同一文件夹或子文件夹中。"
        case .unreadable(let path): return "无法读取“\(path)”。请确认附件存在，并授予笔记及附件所在文件夹的访问权限后重试。笔记未被导入。"
        case .unsupportedImage(let path): return "图片“\(path)”格式不受支持。请使用 PNG、JPEG、GIF 或 WebP。"
        case .invalidMedia(let path): return "附件“\(path)”的内容与图片或音频格式不符，笔记未被导入。"
        }
    }
}

extension DocumentStore {
    /// Import actual image/audio references with the note. Plain relative links
    /// never authorize reading neighboring files such as configuration secrets.
    public func importMarkdownFile(url: URL, parentID: String) throws -> MarkdownImportResult {
        guard url.isFileURL, ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw MarkdownImportError.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let filename = url.lastPathComponent
        guard FileNames.isValidStoredName(FileNames.stored(filename, kind: .md)) else { throw StructureEditError.invalidName }
        let sourceData = try Self.readImportFile(url, displayName: filename)
        guard String(data: sourceData, encoding: .utf8) != nil else { throw MarkdownImportError.invalidUTF8 }
        // String(data:encoding:) consumes the UTF-8 BOM; preserve the exact
        // source bytes because only attachment references should be rewritten.
        let source = String(decoding: sourceData, as: UTF8.self)
        guard !source.contains("\0") else { throw MarkdownImportError.invalidUTF8 }
        let parsed = try MarkdownReferences(source)
        let sourceFolder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let staging = root.appendingPathComponent(".imports", isDirectory: true).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        var staged: [(asset: LibraryAsset, url: URL)] = [], installed: [URL] = []
        var warnings = Set<String>(), mapping: [String: String] = [:], copied: [String: LibraryAsset] = [:]
        var total: Int64 = 0
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for reference in parsed.references {
            let destination = reference.destination
            if destination.hasPrefix("#") { continue }
            if let scheme = URLComponents(string: destination)?.scheme {
                if ["http", "https", "data", "mailto", "tokenlibrary"].contains(scheme.lowercased()) {
                    if reference.isImage && ["http", "https"].contains(scheme.lowercased()) { warnings.insert("网络图片保留原地址，未下载到资料库，离线时可能无法显示。") }
                    continue
                }
                if reference.isImage { throw MarkdownImportError.unsafePath(destination) }
                warnings.insert("部分链接指向笔记之外的资源，已保留原链接，未读取或复制链接文件。")
                continue
            }
            if destination.hasPrefix("//") {
                if reference.isImage { warnings.insert("网络图片保留原地址，未下载到资料库，离线时可能无法显示。") }
                continue
            }
            let pathPart = String(destination.prefix { $0 != "#" && $0 != "?" })
            let decodedPath = pathPart.removingPercentEncoding
            let ext = ((decodedPath ?? pathPart) as NSString).pathExtension.lowercased()
            let imageMIMEs = ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp"]
            let audioMIMEs = ["m4a":"audio/mp4", "mp3":"audio/mpeg", "wav":"audio/wav", "aac":"audio/aac"]
            let mime: String
            if reference.isImage {
                guard let supported = imageMIMEs[ext] else { throw MarkdownImportError.unsupportedImage(destination) }; mime = supported
            } else if let supported = audioMIMEs[ext] { mime = supported }
            else {
                warnings.insert("普通相对文件链接已保留原地址；仅图片和音频被带入资料库，其他链接文件未被读取，离线时可能不可用。")
                continue
            }
            guard let decoded = decodedPath, !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains("\0"),
                  !decoded.split(separator: "/").contains("..") else { throw MarkdownImportError.unsafePath(destination) }
            let file = sourceFolder.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(sourceFolder.path + "/") else { throw MarkdownImportError.unsafePath(destination) }
            let asset: LibraryAsset
            if let prior = copied[file.path] {
                guard prior.mime == mime else { throw MarkdownImportError.invalidMedia(destination) }
                asset = prior
            } else {
                let data = try Self.readContainedImportFile(file, within: sourceFolder, displayName: destination, maximumSize: reference.isImage ? 20_000_000 : 50_000_000)
                total += Int64(data.count)
                guard total <= 500_000_000 else { throw MarkdownImportError.tooLarge(filename) }
                let id = UUID().uuidString.lowercased()
                let stagedURL = staging.appendingPathComponent(id + "." + ext)
                try data.write(to: stagedURL, options: .atomic)
                if reference.isImage {
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
                          let type = CGImageSourceGetType(image), UTType(type as String)?.preferredMIMEType == mime else { throw MarkdownImportError.invalidMedia(destination) }
                } else {
                    guard Self.matchesAudioContainer(stagedURL, extension: ext) else { throw MarkdownImportError.invalidMedia(destination) }
                    do { let audio = try AVAudioFile(forReading: stagedURL); guard audio.length > 0 else { throw MarkdownImportError.invalidMedia(destination) } }
                    catch { throw MarkdownImportError.invalidMedia(destination) }
                }
                asset = LibraryAsset(blobId: id, path: "media/" + id + "." + ext, sha256: BlobIntegrity.sha256(data), size: Int64(data.count), mime: mime)
                copied[file.path] = asset; staged.append((asset, stagedURL))
            }
            mapping[destination] = asset.path
        }
        if parsed.hasRawHTML { warnings.insert("原始 HTML 已保留；其中的媒体引用不会自动复制，请检查图片或音频是否仍可访问。") }
        var metadata = CatalogMetadata(category: .note, inbox: true)
        metadata.originalFilename = filename; metadata.originalFileHash = BlobIntegrity.sha256(sourceData); metadata.importedAt = Date()
        let document = LibraryDocument(id: UUID().uuidString.lowercased(), kind: .md, parentId: parentID,
            name: FileNames.stored(filename, kind: .md), markdown: try parsed.replacingDestinations(mapping), pdfPath: nil,
            revision: 0, localGeneration: 0, state: "active", purgeAt: nil, status: .pending, annotationsJSON: "[]",
            metadataJSON: try metadata.json(), assetsJSON: try JSONValue.array(staged.map { $0.asset.json }).jsonString())
        do {
            let created = try db.write { db in
                // Validate/create first; every following operation is in this
                // transaction, so failed file installation rolls it all back.
                let created = try createDocument(document, deduplicateName: true, db: db)
                for item in staged {
                    let destination = try resolveAttachment(path: item.asset.path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: item.url, to: destination); installed.append(destination)
                    try db.execute(sql: "INSERT INTO blob_transfers(blob_id,local_path,sha256,size,mime,upload_id,state) VALUES (?,?,?,?,?,NULL,'local')",
                        arguments: [item.asset.blobId,item.asset.path,item.asset.sha256,item.asset.size,item.asset.mime])
                }
                return created
            }
            return MarkdownImportResult(document: created, warnings: warnings.sorted())
        } catch {
            for file in installed { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    private static func matchesAudioContainer(_ url: URL, extension ext: String) -> Bool {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return false }
        defer { AudioFileClose(file) }
        var kind: AudioFileTypeID = 0, size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &kind) == noErr else { return false }
        switch ext {
        case "m4a": return kind == kAudioFileM4AType || kind == kAudioFileMPEG4Type
        case "mp3": return kind == kAudioFileMP3Type
        case "wav": return kind == kAudioFileWAVEType
        case "aac": return kind == kAudioFileAAC_ADTSType
        default: return false
        }
    }

    private static func readImportFile(_ url: URL, displayName: String) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw MarkdownImportError.invalidFile }
            guard (values.fileSize ?? 0) <= 50_000_000 else { throw MarkdownImportError.tooLarge(displayName) }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 50_000_001) ?? Data()
            guard data.count <= 50_000_000 else { throw MarkdownImportError.tooLarge(displayName) }
            return data
        } catch let error as MarkdownImportError { throw error }
        catch { throw MarkdownImportError.unreadable(displayName) }
    }

    /// Walk the already-resolved, contained path through directory descriptors.
    /// O_NOFOLLOW prevents a changed symlink from racing the containment check.
    private static func readContainedImportFile(_ file: URL, within base: URL, displayName: String, maximumSize: Int) throws -> Data {
        let relative = String(file.path.dropFirst(base.path.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw MarkdownImportError.unsafePath(displayName) }
        var directory = Darwin.open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw MarkdownImportError.unreadable(displayName) }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw MarkdownImportError.unreadable(displayName) }
            Darwin.close(directory); directory = next
        }
        let descriptor = Darwin.openat(directory, components.last!, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MarkdownImportError.unreadable(displayName) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw MarkdownImportError.unreadable(displayName) }
        let sizeError = maximumSize == 20_000_000 ? MarkdownImportError.imageTooLarge(displayName) : MarkdownImportError.tooLarge(displayName)
        guard info.st_size <= maximumSize else { throw sizeError }
        do {
            let bytes = try handle.read(upToCount: maximumSize + 1) ?? Data()
            guard bytes.count <= maximumSize else { throw sizeError }
            return bytes
        } catch let error as MarkdownImportError { throw error }
        catch { throw MarkdownImportError.unreadable(displayName) }
    }
}
