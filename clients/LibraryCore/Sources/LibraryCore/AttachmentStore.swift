import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct BlobTransfer: Sendable {
    public let asset: LibraryAsset
    public let uploadId: String?
    public let state: String
}

extension DocumentStore {
    public func importAttachment(data: Data, fileName: String, mime: String) throws -> LibraryAsset {
        guard data.count <= 50_000_000 else { throw TransferError.tooLarge }
        let id = UUID().uuidString.lowercased()
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)
        let path = "media/" + id + (ext.isEmpty ? "" : "." + ext)
        let asset = LibraryAsset(blobId: id, path: path, sha256: BlobIntegrity.sha256(data), size: Int64(data.count), mime: mime)
        try installAttachment(data: data, asset: asset, state: "local")
        return asset
    }

    public func resolveAttachment(path: String) throws -> URL {
        let url: URL
        if path.hasPrefix("library-asset://"), let id = URL(string: path)?.host {
            guard let found = try assetURL(id: id) else { throw TransferError.missingFile }; return found
        } else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else { url = root.appendingPathComponent(path) }
        let normalized = try canonicalAttachmentURL(url)
        let prefix = try canonicalAttachmentURL(root).path + "/"
        guard normalized.path.hasPrefix(prefix), normalized.path != prefix else { throw TransferError.invalidPath }
        return normalized
    }

    // Foundation can prefer /tmp for an existing /private/tmp directory but
    // keep /private/tmp for a child that does not exist yet. Resolve the nearest
    // existing ancestor first, then append missing components without asking
    // Foundation to normalize a partially nonexistent path again.
    private func canonicalAttachmentURL(_ url: URL) throws -> URL {
        var candidate = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = candidate.withUnsafeFileSystemRepresentation({ path in
                path.flatMap { realpath($0, nil) }
            }) {
                defer { free(resolved) }
                var result = URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL
                for component in missing.reversed() { result.appendPathComponent(component) }
                return result
            }
            let failure = errno
            var attributes = stat()
            let entryExists = candidate.withUnsafeFileSystemRepresentation { path in
                path.map { lstat($0, &attributes) == 0 } ?? false
            }
            // A dangling link is an existing entry whose destination could not
            // be resolved; never treat it as a safe new directory. Permission
            // failures, loops and non-directory ancestors also remain errors.
            guard !entryExists, failure == ENOENT else { throw TransferError.invalidPath }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { throw TransferError.invalidPath }
            missing.append(candidate.lastPathComponent)
            candidate = parent
        }
    }

    public func assetURL(id: String) throws -> URL? {
        guard UUID(uuidString: id) != nil else { throw TransferError.invalidPath }
        guard let transfer = try transfer(blobId: id) else { return nil }
        return try resolveAttachment(path: transfer.asset.path)
    }

    public func transfer(blobId: String) throws -> BlobTransfer? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM blob_transfers WHERE blob_id=?", arguments: [blobId]) else { return nil }
            return BlobTransfer(asset: LibraryAsset(blobId: row["blob_id"], path: row["local_path"], sha256: row["sha256"], size: row["size"], mime: row["mime"]), uploadId: row["upload_id"], state: row["state"])
        }
    }

    public func registerAttachment(path: String, mime: String) throws -> LibraryAsset {
        let url = try resolveAttachment(path: path)
        guard let data = try? Data(contentsOf: url) else { throw TransferError.missingFile }
        guard data.count <= 50_000_000 else { throw TransferError.tooLarge }
        let hash = BlobIntegrity.sha256(data)
        let relative = String(url.path.dropFirst(try canonicalAttachmentURL(root).path.count + 1))
        if let id = try db.read({ try String.fetchOne($0, sql: "SELECT blob_id FROM blob_transfers WHERE local_path=? AND sha256=? LIMIT 1", arguments: [relative,hash]) }), let saved = try transfer(blobId: id) { return saved.asset }
        let asset = LibraryAsset(blobId: UUID().uuidString.lowercased(), path: relative, sha256: hash, size: Int64(data.count), mime: mime)
        try updateTransfer(asset, uploadId: nil, state: "local")
        return asset
    }

    public func installAttachment(data: Data, asset: LibraryAsset, state: String = "complete") throws {
        guard UUID(uuidString: asset.blobId) != nil, Int64(data.count) == asset.size else { throw TransferError.hashMismatch }
        guard asset.path.hasPrefix("media/"), !asset.path.hasPrefix("/"), !asset.path.contains("\\") else { throw TransferError.invalidPath }
        try BlobIntegrity.verify(data, hash: asset.sha256)
        let url = try resolveAttachment(path: asset.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try updateTransfer(asset, uploadId: nil, state: state)
    }

    public func updateTransfer(_ asset: LibraryAsset, uploadId: String?, state: String) throws {
        _ = try resolveAttachment(path: asset.path)
        try db.write { db in
            try db.execute(sql: "INSERT INTO blob_transfers(blob_id,local_path,sha256,size,mime,upload_id,state) VALUES (?,?,?,?,?,?,?) ON CONFLICT(blob_id) DO UPDATE SET local_path=excluded.local_path,sha256=excluded.sha256,size=excluded.size,mime=excluded.mime,upload_id=excluded.upload_id,state=excluded.state",
                           arguments: [asset.blobId,asset.path,asset.sha256,asset.size,asset.mime,uploadId,state])
        }
    }

    static func mime(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}
