import Foundation
import CryptoKit
import Security
import LocalAuthentication

public struct SavedLibrarySession: Codable, Sendable, Equatable {
    public let username: String
    public let login: LoginResult
    public init(username: String, login: LoginResult) { self.username = username; self.login = login }
}

public struct SessionVault: Sendable {
    public let service: String
    public init(service: String = "TokenLibrary.sessions") { self.service = service }
    #if os(macOS)
    /// The login keychain asks for the account password whenever this app is
    /// signed again. The session file stays inside this user account instead.
    private func sessionFile(server: URL) throws -> URL {
        let account = try ServerAddress.normalize(server.absoluteString).absoluteString
        let name = BlobIntegrity.sha256(Data((service + "\n" + account).utf8))
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TokenLibrary/Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.appendingPathComponent(name, isDirectory: false)
    }
    public func save(_ session: SavedLibrarySession, server: URL) throws {
        let url = try sessionFile(server: server)
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load(server: URL, interactionAllowed: Bool = true) throws -> SavedLibrarySession? {
        _ = interactionAllowed
        let url = try sessionFile(server: server)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SavedLibrarySession.self, from: Data(contentsOf: url))
    }
    public func delete(server: URL) throws {
        let url = try sessionFile(server: server)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    #else
    private func query(server: URL) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: try ServerAddress.normalize(server.absoluteString).absoluteString]
    }
    public func save(_ session: SavedLibrarySession, server: URL) throws {
        let base = try query(server: server)
        let data = try JSONEncoder().encode(session)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SessionVaultError.status(update) }
        var entry = base
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var added = SecItemAdd(entry as CFDictionary, nil)
        if added == errSecDuplicateItem {
            SecItemDelete(base as CFDictionary)
            added = SecItemAdd(entry as CFDictionary, nil)
        }
        guard added == errSecSuccess else { throw SessionVaultError.status(added) }
    }
    public func load(server: URL, interactionAllowed: Bool = true) throws -> SavedLibrarySession? {
        var entry = try query(server: server)
        if !interactionAllowed {
            let context = LAContext()
            context.interactionNotAllowed = true
            entry[kSecUseAuthenticationContext as String] = context
        }
        entry[kSecReturnData as String] = true
        entry[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(entry as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SessionVaultError.status(status) }
        return try JSONDecoder().decode(SavedLibrarySession.self, from: data)
    }
    public func delete(server: URL) throws {
        let status = SecItemDelete(try query(server: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionVaultError.status(status) }
    }
    #endif
}

public enum SessionVaultError: LocalizedError {
    case status(OSStatus)
    public var errorDescription: String? { "无法访问安全保存的登录信息，请解锁设备后重试。" }
}

public struct LibraryWorkspaceManager: Sendable {
    public let baseDirectory: URL
    public init(baseDirectory: URL) { self.baseDirectory = baseDirectory }
    public func localStore() throws -> DocumentStore {
        try DocumentStore(directory: baseDirectory.appendingPathComponent("Local", isDirectory: true))
    }
    public func store(server: URL, libraryId: String) throws -> DocumentStore {
        let origin = try ServerAddress.normalize(server.absoluteString).absoluteString
        guard !libraryId.isEmpty else { throw SyncFailure.invalidResponse }
        let key = BlobIntegrity.sha256(Data((origin + "\n" + libraryId).utf8))
        let directory = baseDirectory.appendingPathComponent("Libraries", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        let store = try DocumentStore(directory: directory)
        try store.bindWorkspace(server: origin, libraryId: libraryId)
        return store
    }
}

public enum BlobIntegrity {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func verify(_ data: Data, hash: String) throws {
        guard hash.count == 64, sha256(data).lowercased() == hash.lowercased() else { throw TransferError.hashMismatch }
    }
}

public enum TransferError: LocalizedError, Sendable {
    case hashMismatch, invalidPath, missingFile, tooLarge
    public var errorDescription: String? {
        switch self {
        case .hashMismatch: return "附件校验未通过，未使用可能损坏的数据。请重新同步。"
        case .invalidPath: return "附件路径不属于当前文档库。"
        case .missingFile: return "找不到本机附件，请重新导入或从云端下载。"
        case .tooLarge: return "附件超过服务允许的 50 MB 上限。"
        }
    }
}

public struct LibraryAsset: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let blobId: String
    public let path: String
    public let sha256: String
    public let size: Int64
    public let mime: String
    public init(blobId: String, path: String, sha256: String, size: Int64, mime: String) {
        self.id = blobId; self.blobId = blobId; self.path = path; self.sha256 = sha256; self.size = size; self.mime = mime
    }
    public var json: JSONValue {
        .object(["id": .string(id), "blobId": .string(blobId), "path": .string(path), "sha256": .string(sha256), "size": .integer(size), "mime": .string(mime)])
    }
}
