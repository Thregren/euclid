import Foundation

/// 前台请求先于预取请求获取解码名额；取消的等待者不占名额。
package actor AsyncLimiter {
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var cancelled = false
        private var granted = false

        func install(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        func grant() -> Bool {
            lock.lock()
            guard !cancelled, let continuation else {
                lock.unlock()
                return false
            }
            granted = true
            self.continuation = nil
            lock.unlock()
            continuation.resume()
            return true
        }

        var isGranted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return granted
        }
    }

    private let limit: Int
    private var active = 0
    private var foreground = FIFOQueue<Waiter>()
    private var background = FIFOQueue<Waiter>()

    package init(limit: Int) { self.limit = max(1, limit) }
    package var queuedCount: Int { foreground.count + background.count }

    package func acquire(priority: TaskPriority = .userInitiated) async -> Bool {
        if Task.isCancelled { return false }
        if active < TileResourcePolicy.concurrencyLimit(limit) {
            active += 1
            return true
        }
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if priority >= .userInitiated { foreground.append(waiter) }
                else { background.append(waiter) }
                waiter.install(continuation)
            }
        } onCancel: {
            waiter.cancel()
        }
        return waiter.isGranted
    }

    package func release() {
        active = max(0, active - 1)
        guard active < TileResourcePolicy.concurrencyLimit(limit) else { return }
        while let waiter = foreground.popFirst() {
            if waiter.grant() { active += 1; return }
        }
        while let waiter = background.popFirst() {
            if waiter.grant() { active += 1; return }
        }
    }
}
