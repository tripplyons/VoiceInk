import Foundation

/// A later shortcut must not overtake an asynchronous stack paste.
@MainActor
final class ContinuousCommandQueue {
    private var tail: Task<Void, Never>?
    private var generation = UUID()

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        let generation = generation
        tail = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            await operation()
        }
    }

    func waitUntilFinished() async {
        await tail?.value
    }

    func cancel() {
        generation = UUID()
        tail?.cancel()
        // Keep the barrier: an already-posting paste must finish before a new
        // session can overwrite its clipboard or send another shortcut.
    }
}
