import Foundation

/// Concurrent callers join one operation, including its failure. A later call can retry.
@MainActor
final class SharedOperation {
    private var task: Task<Void, Error>?
    private var generation = UUID()
    var isRunning: Bool { task != nil }

    func run(timeout: UInt64? = nil,
             onFailure: @escaping @MainActor (Error) -> Void = { _ in },
             _ operation: @escaping @MainActor () async throws -> Void) async throws {
        if let task { return try await task.value }
        let run = UUID()
        generation = run
        let next = Task { @MainActor in
            do {
                if let timeout {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { @MainActor in try await operation() }
                        group.addTask {
                            try await Task.sleep(nanoseconds: timeout)
                            throw URLError(.timedOut)
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                } else { try await operation() }
            } catch {
                // Only the owning operation reports failure; joined waiters must
                // not overwrite the state of a later successful retry.
                if self.generation == run { onFailure(error) }
                throw error
            }
        }
        task = next
        defer { if generation == run { task = nil } }
        try await next.value
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
}
