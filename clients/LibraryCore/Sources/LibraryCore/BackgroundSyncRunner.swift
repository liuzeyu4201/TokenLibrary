import Foundation

public enum BackgroundSyncOutcome: Sendable, Equatable {
    case synchronized(storeRoot: URL, at: Date)
    case notConfigured, noSavedSession, configurationChanged
    case credentialsUnavailable, credentialsTimedOut, requiresLogin, deferred, cancelled
}

/// A refresh owns exactly one restore + sync operation, without constructing a
/// foreground model (whose startup also schedules an independent sync task).
public enum BackgroundSyncRunner {
    public static func run(server: URL, libraryID: String, rootID: String, deviceID: String,
                           workspaces: LibraryWorkspaceManager, credentials: any SessionCredentialStore,
                           credentialWait: Duration = .seconds(3), timeBudget: Duration = .seconds(25),
                           makeClient: @escaping @Sendable (URL, String) -> SyncClient = { SyncClient(baseURL: $0, deviceId: $1) }) async -> BackgroundSyncOutcome {
        do {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: BackgroundSyncOutcome.self) { group in
                group.addTask {
                    let saved: SavedLibrarySession?
                    do { saved = try await readCredentials(credentials, server: server, timeout: credentialWait) }
                    catch is CancellationError { throw CancellationError() }
                    catch is CredentialTimeout { return .credentialsTimedOut }
                    catch { return .credentialsUnavailable }
                    try Task.checkCancellation()
                    guard let saved else { return .noSavedSession }
                    // A newer login can have replaced the saved account while
                    // this refresh was queued. Never bind it to the older scope.
                    guard saved.login.libraryId == libraryID, saved.login.rootId == rootID else { return .configurationChanged }
                    let store = try workspaces.store(server: server, libraryId: libraryID)
                    try store.bindWorkspace(server: server.absoluteString, libraryId: libraryID, rootId: rootID)
                    try Task.checkCancellation()
                    let client = makeClient(server, deviceID)
                    client.restoreSession(saved.login)
                    _ = try await client.synchronize(store: store, rootId: rootID)
                    try Task.checkCancellation()
                    return .synchronized(storeRoot: store.root, at: Date())
                }
                group.addTask {
                    try await Task.sleep(for: timeBudget)
                    throw RefreshTimeout()
                }
                defer { group.cancelAll() }
                let outcome = try await group.next()!
                try Task.checkCancellation()
                return outcome
            }
        } catch {
            if Task.isCancelled || error is CancellationError || SyncFailure.from(error).kind == .cancelled { return .cancelled }
            if SyncFailure.from(error).kind == .unauthorized { return .requiresLogin }
            return .deferred
        }
    }

    private struct CredentialTimeout: Error {}
    private struct RefreshTimeout: Error {}

    /// Unlike a task-group race, this wait does not wait for an uncooperative
    /// Security call after cancellation. The late read has no effects: it can
    /// neither open a workspace, start networking nor record a success.
    private static func readCredentials(_ credentials: any SessionCredentialStore, server: URL,
                                        timeout: Duration) async throws -> SavedLibrarySession? {
        let wait = CredentialWait()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.install(continuation)
                let read = Task.detached {
                    do {
                        try Task.checkCancellation()
                        let saved = try await credentials.load(server: server, interactionAllowed: false)
                        wait.finish(.success(saved))
                    } catch { wait.finish(.failure(error)) }
                }
                let deadline = Task.detached {
                    do { try await Task.sleep(for: timeout); wait.finish(.failure(CredentialTimeout())) }
                    catch { /* The reader or caller finished first. */ }
                }
                wait.add(read); wait.add(deadline)
            }
        } onCancel: { wait.finish(.failure(CancellationError())) }
    }

    private final class CredentialWait: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SavedLibrarySession?, Error>?
        private var continuation: CheckedContinuation<SavedLibrarySession?, Error>?
        private var tasks: [Task<Void, Never>] = []
        func install(_ continuation: CheckedContinuation<SavedLibrarySession?, Error>) {
            let ready = lock.withLock { () -> Result<SavedLibrarySession?, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil as Result<SavedLibrarySession?, Error>?
            }
            if let ready { continuation.resume(with: ready) }
        }
        func add(_ task: Task<Void, Never>) {
            let finished = lock.withLock { if result != nil { return true }; tasks.append(task); return false }
            if finished { task.cancel() }
        }
        func finish(_ result: Result<SavedLibrarySession?, Error>) {
            let pending = lock.withLock { () -> (CheckedContinuation<SavedLibrarySession?, Error>?, [Task<Void, Never>]) in
                guard self.result == nil else { return (nil, []) }
                self.result = result
                let pending = (continuation, tasks)
                continuation = nil; tasks = []
                return pending
            }
            pending.1.forEach { $0.cancel() }
            pending.0?.resume(with: result)
        }
    }
}
