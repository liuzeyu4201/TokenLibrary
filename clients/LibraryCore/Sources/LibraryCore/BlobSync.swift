import Foundation

extension SyncClient {
    public func uploadAttachment(_ asset: LibraryAsset, store: DocumentStore) async throws {
        guard asset.size <= 50_000_000 else { throw TransferError.tooLarge }
        if try store.transfer(blobId: asset.blobId)?.state == "complete" { return }
        let data = try Data(contentsOf: store.resolveAttachment(path: asset.path))
        try BlobIntegrity.verify(data, hash: asset.sha256)
        var uploadId = try store.transfer(blobId: asset.blobId)?.uploadId
        var chunkSize = 1_048_576
        if uploadId == nil {
            let response = try await requestJSON(path: "/api/v1/uploads", method: "POST", body: .object([
                "blobId": .string(asset.blobId), "size": .integer(asset.size), "sha256": .string(asset.sha256), "mime": .string(asset.mime)
            ]), retry: true)
            if response["state"]?.string == "complete" || response["state"]?.string == "ready" {
                guard response["blobId"]?.string == asset.blobId else { throw SyncFailure.invalidResponse }
                try store.updateTransfer(asset, uploadId: nil, state: "complete"); return
            }
            uploadId = response["uploadId"]?.string
            if let count = response["chunkSize"]?.int64 { chunkSize = Int(count) }
            guard let uploadId, UUID(uuidString: uploadId) != nil, chunkSize > 0, chunkSize <= 1_048_576 else { throw SyncFailure.invalidResponse }
            try store.updateTransfer(asset, uploadId: uploadId, state: "uploading")
        }
        guard let uploadId, UUID(uuidString: uploadId) != nil else { throw SyncFailure.invalidResponse }
        let progress = try await requestJSON(path: "/api/v1/uploads/\(uploadId)")
        if progress["state"]?.string == "complete" { try store.updateTransfer(asset, uploadId: uploadId, state: "complete"); return }
        let completed = Set(progress["chunks"]?.array?.compactMap { $0.int64.map(Int.init) } ?? [])
        let count = max(1, (data.count + chunkSize - 1) / chunkSize)
        for index in 0..<count where !completed.contains(index) {
            try Task.checkCancellation()
            let start = index * chunkSize, end = min(data.count, start + chunkSize)
            let chunk = data.subdata(in: start..<end)
            var req = try request(path: "/api/v1/uploads/\(uploadId)/chunks/\(index)", method: "PUT", auth: true)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(BlobIntegrity.sha256(chunk), forHTTPHeaderField: "X-Chunk-SHA256")
            req.httpBody = chunk
            _ = try await send(req, retry: true)
        }
        let response = try await requestJSON(path: "/api/v1/uploads/\(uploadId)/complete", method: "POST", body: .object([:]), retry: true)
        guard response["blobId"]?.string == asset.blobId, response["state"]?.string == "ready" else { throw SyncFailure.invalidResponse }
        try store.updateTransfer(asset, uploadId: uploadId, state: "complete")
    }

    func downloadAttachments(snapshot: DocumentSnapshot, store: DocumentStore) async throws {
        if let blobId = snapshot["pdfBlobId"]?.string {
            _ = try await downloadBlob(id: blobId, path: "media/\(blobId).pdf", expectedHash: nil, expectedSize: nil, mime: "application/pdf", store: store)
        }
        for value in snapshot["assets"]?.array ?? [] {
            guard let asset = value.object, let id = asset["blobId"]?.string ?? asset["id"]?.string,
                  let path = asset["path"]?.string else { throw SyncFailure.invalidResponse }
            _ = try await downloadBlob(id: id, path: path, expectedHash: asset["sha256"]?.string, expectedSize: asset["size"]?.int64, mime: asset["mime"]?.string ?? DocumentStore.mime(for: path), store: store)
        }
    }

    @discardableResult
    public func downloadBlob(id: String, path: String, expectedHash: String?, expectedSize: Int64?, mime: String, store: DocumentStore) async throws -> LibraryAsset {
        guard UUID(uuidString: id) != nil, path.hasPrefix("media/") else { throw TransferError.invalidPath }
        _ = try store.resolveAttachment(path: path)
        if let saved = try store.transfer(blobId: id), saved.state == "complete",
           expectedHash == nil || expectedHash == saved.asset.sha256,
           let data = try? Data(contentsOf: store.resolveAttachment(path: saved.asset.path)),
           BlobIntegrity.sha256(data) == saved.asset.sha256, expectedSize == nil || expectedSize == Int64(data.count) { return saved.asset }
        let req = try request(path: "/api/v1/blobs/\(id)", method: "GET", auth: true)
        let (data, response) = try await perform(req, retry: true)
        guard data.count <= 50_000_000 else { throw TransferError.tooLarge }
        let headerHash = response.value(forHTTPHeaderField: "X-Content-SHA256") ?? response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let hash = expectedHash ?? headerHash else { throw TransferError.hashMismatch }
        try BlobIntegrity.verify(data, hash: hash)
        if let headerHash { try BlobIntegrity.verify(data, hash: headerHash) }
        if let expectedSize, expectedSize != Int64(data.count) { throw TransferError.hashMismatch }
        let asset = LibraryAsset(blobId: id, path: path, sha256: hash, size: Int64(data.count), mime: mime)
        try store.installAttachment(data: data, asset: asset)
        return asset
    }

    func prepareAttachments(objectId: String, store: DocumentStore) async throws {
        for _ in 0..<4 {
            guard var document = try store.loadDocument(id: objectId) else { throw StoreError.notFound }
            let generation = document.localGeneration
            var assets: [LibraryAsset] = []
            var changed = false
            if document.kind == .pdf, let path = document.pdfPath {
                let asset = try store.registerAttachment(path: path, mime: "application/pdf")
                try await uploadAttachment(asset, store: store)
                if document.pdfBlobId != asset.blobId { document.pdfBlobId = asset.blobId; changed = true }
            }
            if document.kind == .md {
                let parsed = try MarkdownReferences(document.markdown)
                var replacements: [String: String] = [:]
                for reference in parsed.mediaReferences {
                    let path = reference.destination
                    if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("#") { continue }
                    let asset: LibraryAsset
                    if path.hasPrefix("data:"), let comma = path.firstIndex(of: ","), path[..<comma].contains(";base64") {
                        let mime = String(path.dropFirst(5).prefix(while: { $0 != ";" }))
                        guard let data = Data(base64Encoded: String(path[path.index(after: comma)...])) else { throw TransferError.hashMismatch }
                        asset = try store.importAttachment(data: data, fileName: mime == "image/png" ? "image.png" : "image.jpg", mime: mime)
                        replacements[path] = asset.path
                        changed = true
                    } else if path.hasPrefix("media/") || path.hasPrefix("library-asset://") {
                        let resolved = try store.resolveAttachment(path: path)
                        asset = try store.registerAttachment(path: resolved.path, mime: DocumentStore.mime(for: resolved.path))
                        if path.hasPrefix("library-asset://") { replacements[path] = asset.path; changed = true }
                    } else { continue }
                    if !assets.contains(where: { $0.blobId == asset.blobId }) { assets.append(asset) }
                    try await uploadAttachment(asset, store: store)
                }
                if !replacements.isEmpty { document.markdown = try parsed.replacingDestinations(replacements) }
                let encoded = try JSONValue.array(assets.map(\.json)).jsonString()
                if (try? JSONValue.parse(document.assetsJSON)) != (try? JSONValue.parse(encoded)) { document.assetsJSON = encoded; changed = true }
            }
            if changed {
                guard try store.saveDocumentIfCurrent(document, expectedGeneration: generation) else { continue }
            } else if try store.loadDocument(id: objectId)?.localGeneration != generation { continue }
            return
        }
        throw SyncFailure(kind: .unknown, title: "附件等待本机编辑完成", message: "文档在上传附件期间仍有新修改，已保留全部编辑。", recoverySuggestion: "稍后再次同步。", isRetryable: true)
    }
}
