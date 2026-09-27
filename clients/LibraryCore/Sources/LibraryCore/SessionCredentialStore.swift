import Foundation

public protocol SessionCredentialStore: Sendable {
    func load(server: URL, interactionAllowed: Bool) async throws -> SavedLibrarySession?
    func save(_ session: SavedLibrarySession, server: URL) async throws
    /// A late logout must not remove credentials saved by a newer login.
    func delete(server: URL, matchingSessionToken: String) async throws
}

public extension SessionCredentialStore {
    func load(server: URL) async throws -> SavedLibrarySession? {
        try await load(server: server, interactionAllowed: true)
    }
}

/// Security.framework calls can wait for system UI even on a background thread.
/// Serialize this vault's IO, skip cancelled work that has not begun, and leave
/// cancellation of an already-running system call to the system itself.
public final class AsyncSessionVault: SessionCredentialStore, @unchecked Sendable {
    private let vault: SessionVault
    private let queue: DispatchQueue
    public init(vault: SessionVault) {
        self.vault = vault
        // Mac WindowGroup can construct multiple models for the same service.
        // Keep conditional load/delete atomic relative to all of their saves.
        queue = CredentialQueues.shared.queue(for: vault.service)
    }

    public func load(server: URL, interactionAllowed: Bool) async throws -> SavedLibrarySession? {
        try await perform { [vault] in try vault.load(server: server, interactionAllowed: interactionAllowed) }
    }
    public func save(_ session: SavedLibrarySession, server: URL) async throws {
        try await perform { [vault] in try vault.save(session, server: server) }
    }
    public func delete(server: URL, matchingSessionToken: String) async throws {
        try await perform { [vault] in
            guard try vault.load(server: server)?.login.sessionToken == matchingSessionToken else { return }
            try vault.delete(server: server)
        }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = CredentialCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: try operation())
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class CredentialQueues: @unchecked Sendable {
    static let shared = CredentialQueues()
    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]
    func queue(for service: String) -> DispatchQueue {
        lock.withLock {
            if let queue = queues[service] { return queue }
            let queue = DispatchQueue(label: "app.tokenlibrary.credentials", qos: .userInitiated)
            queues[service] = queue
            return queue
        }
    }
}

private final class CredentialCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
