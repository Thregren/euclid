import Foundation
import TileKit

extension AppModel {
    /// The measurement owner changes before selectedSourceID, never after a save has captured it.
    func changeMeasurementDocument(to path: String?, initial: [GeoMeasurement]? = nil, recoverArchive: Bool = false) {
        if let oldPath = measurementOwnerPath {
            measurementSnapshots[oldPath] = measurements.measurements
        }
        measurementOwnerPath = path
        guard let path else {
            measurements.restore(initial ?? [])
            canvas.refreshOverlay()
            return
        }
        if let cached = measurementSnapshots[path] {
            measurements.restore(cached)
            canvas.refreshOverlay()
            return
        }
        if let initial, !recoverArchive {
            measurementSnapshots[path] = initial
            measurements.restore(initial)
            canvas.refreshOverlay()
            return
        }
        // Session values are a fallback until the independent, more recent archive is read.
        // An explicitly saved empty archive must also take precedence over an older session.
        if let initial { measurementSnapshots[path] = initial }
        measurements.restore(initial ?? [])
        canvas.refreshOverlay()
        guard !DebugFixtures.isEnabled, measurementLoadTasks[path] == nil else { return }
        let reader = measurementReader
        measurementLoadTasks[path] = Task { [weak self] in
            let (archived, notice) = await reader(path)
            guard let self else { return }
            // Reads finish for their original document even if the user has since switched tabs.
            let edited = self.measurementEditedWhileLoading.remove(path) != nil
            let replaced = self.measurementReplacedWhileLoading.remove(path) != nil
            let local = self.measurementSnapshots[path] ?? []
            let saved = archived ?? initial ?? []
            let localIDs = Set(local.map(\.id))
            var baseline: [UUID: GeoMeasurement] = [:]
            for value in initial ?? [] { baseline[value.id] = value }
            let removedIDs = Set(baseline.keys).subtracting(localIDs)
            let changes = local.filter { baseline[$0.id] != $0 }
            let changedIDs = Set(changes.map(\.id))
            let merged = replaced ? local : (edited
                ? saved.filter { !changedIDs.contains($0.id) && !removedIDs.contains($0.id) } + changes
                : saved)
            self.measurementSnapshots[path] = merged
            self.measurementLoadTasks.removeValue(forKey: path)
            if self.measurementOwnerPath == path {
                self.measurements.restore(merged, preservingDraft: true)
                self.canvas.refreshOverlay()
            }
            if edited, !Self.skipsArchiveWrites {
                self.measurementPersistence.record(merged, for: path)
            }
            if let notice { self.setStatus(notice, autoClearAfter: 12) }
        }
    }

    func measurementPath(for sourceID: String?) -> String? {
        guard let sourceID else { return nil }
        return datasets.first(where: { $0.id == sourceID })?.rootURL.canonicalFilePath
            ?? rasters.first(where: { $0.id == sourceID })?.fileURL.canonicalFilePath
    }

    func reportPersistenceFailure(_ message: String) {
        guard persistenceFailure != message else { return }
        persistenceFailure = message
        setStatus(message, autoClearAfter: 0)
    }

    /// Invalidating a load also owns its busy flags; stale tasks cannot leave saving disabled.
    func cancelSourceLoading() {
        sourceTask?.cancel()
        sourceTask = nil
        sourceGeneration &+= 1
        isScanning = false
        isResolvingExtent = false
        invalidateElevationSampling()
    }

    @discardableResult
    func flushPersistentState() async -> String? {
        // Archive reads may be merging edits made while a large document was loading.
        let reads = Array(measurementLoadTasks.values)
        for task in reads { await task.value }
        if !Self.skipsArchiveWrites, !DebugFixtures.isEnabled, let path = measurementOwnerPath {
            measurementPersistence.record(measurements.measurements, for: path)
        }
        if let failure = await measurementPersistence.flush() {
            reportPersistenceFailure(failure)
            return failure
        }
        if let failure = await saveWorkspaceSession(force: true) { return failure }
        persistenceFailure = nil
        return nil
    }
}
