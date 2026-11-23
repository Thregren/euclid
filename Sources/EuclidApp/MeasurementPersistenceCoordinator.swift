import Foundation
import TileKit

/// Owns pending writes by dataset, so a later edit in another tab cannot cancel an earlier save.
@MainActor
final class MeasurementPersistenceCoordinator {
    typealias Writer = @Sendable ([GeoMeasurement], String) async -> String?
    private struct Pending {
        let revision: UInt64
        let measurements: [GeoMeasurement]
    }
    private var pending: [String: Pending] = [:]
    private var revision: UInt64 = 0
    private var scheduled: Task<Void, Never>?
    private var writing: Task<String?, Never>?
    private let writer: Writer
    var onFailure: ((String) -> Void)?

    init(writer: @escaping Writer = { values, path in
        await MeasurementArchive.shared.save(values, for: path)
    }) {
        self.writer = writer
    }

    func record(_ measurements: [GeoMeasurement], for path: String) {
        revision &+= 1
        pending[path] = Pending(revision: revision, measurements: measurements)
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self else { return }
            if let error = await self.flush() { self.onFailure?(error) }
        }
    }

    /// A failed write remains pending for retry, and flushing waits for an already running save.
    func flush() async -> String? {
        scheduled?.cancel()
        scheduled = nil
        while true {
            if let writing {
                if let error = await writing.value { return error }
                continue
            }
            guard !pending.isEmpty else { return nil }
            let snapshot = pending
            let writer = writer
            let task = Task { () -> String? in
                defer { writing = nil }
                var firstFailure: String?
                for path in snapshot.keys.sorted() {
                    guard let item = snapshot[path] else { continue }
                    if let error = await writer(item.measurements, path) {
                        if firstFailure == nil { firstFailure = error }
                        continue
                    }
                    if pending[path]?.revision == item.revision { pending.removeValue(forKey: path) }
                }
                return firstFailure
            }
            writing = task
            if let error = await task.value { return error }
        }
    }

    var hasPendingWrites: Bool { !pending.isEmpty }
}

/// Cancellation is forwarded to detached file/decoder work instead of only ignoring its result.
nonisolated func runCancellableAppWork<T: Sendable>(
    _ work: @escaping @Sendable () -> T
) async -> T {
    let worker = Task.detached(priority: .userInitiated, operation: work)
    return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
}
