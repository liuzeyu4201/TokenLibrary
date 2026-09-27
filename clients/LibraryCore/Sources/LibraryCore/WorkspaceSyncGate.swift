import Foundation

/// Foreground, background and conflict-resolution entry points share a cancellation-aware FIFO per database.
actor WorkspaceSyncGate {
    static let shared = WorkspaceSyncGate()
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var held = Set<String>()
    private var waiters: [String: [Waiter]] = [:]

    func withPermit<T: Sendable>(key: String, operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if held.insert(key).inserted { continuation.resume() }
                else { waiters[key, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(key: key, id: id) } }
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(key: key)
            return result
        } catch {
            release(key: key)
            throw error
        }
    }

    private func cancel(key: String, id: UUID) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters[key]!.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
    private func release(key: String) {
        if var waiting = waiters[key], !waiting.isEmpty {
            let next = waiting.removeFirst(); waiters[key] = waiting
            next.continuation.resume()
        } else { waiters.removeValue(forKey: key); held.remove(key) }
    }
}

extension DocumentStore {
    var synchronizationKey: String { root.resolvingSymlinksInPath().standardizedFileURL.path }
}
