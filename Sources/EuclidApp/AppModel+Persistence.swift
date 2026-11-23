import Foundation
import TileKit

extension AppModel {
    func bindMeasurementArchive(to tab: WorkspaceTab) {
        tab.measurements.onChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.scheduleArchiveSave(for: tab)
        }
        tab.measurements.onReplace = { [weak self, weak tab] in
            guard let self, let path = tab?.measurementSourcePath,
                  self.measurementLoadTasks[path] != nil else { return }
            self.measurementReplacedWhileLoading.insert(path)
        }
    }

    /// Change the source within the current tab. A tab switch keeps its store intact.
    func changeMeasurementDocument(to path: String?, initial: [GeoMeasurement]? = nil, recoverArchive: Bool = false) {
        loadMeasurementDocument(for: activeWorkspaceTab, path: path, initial: initial, recoverArchive: recoverArchive)
        canvas.refreshOverlay()
    }

    func loadMeasurementDocument(for tab: WorkspaceTab, path: String?, initial: [GeoMeasurement]?,
                                 recoverArchive: Bool) {
        tab.measurementSourcePath = path
        guard let path else {
            tab.measurements.restore(initial ?? [])
            return
        }
        let cached = measurementPersistence.cachedMeasurements[path]
        let fallback = cached ?? initial ?? []
        tab.measurements.restore(fallback)
        guard cached == nil else { return }
        measurementPersistence.cachedMeasurements[path] = fallback

        // A workspace snapshot is a fallback when the independent archive is missing.
        guard (initial == nil || recoverArchive), !DebugFixtures.isEnabled else { return }
        let reader = measurementReader
        measurementLoadTasks[path] = Task { [weak self] in
            let (archived, notice) = await reader(path)
            guard let self else { return }
            let edited = self.measurementEditedWhileLoading.remove(path) != nil
            let replaced = self.measurementReplacedWhileLoading.remove(path) != nil
            let local = self.measurementPersistence.cachedMeasurements[path] ?? fallback
            let saved = archived ?? fallback
            let baseline = Dictionary(fallback.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            let localIDs = Set(local.map(\.id))
            let removedIDs = Set(baseline.keys).subtracting(localIDs)
            let changes = local.filter { baseline[$0.id] != $0 }
            let changedIDs = Set(changes.map(\.id))
            let merged = replaced ? local : (edited
                ? saved.filter { !changedIDs.contains($0.id) && !removedIDs.contains($0.id) } + changes
                : saved)
            self.measurementLoadTasks.removeValue(forKey: path)
            self.publishArchivedMeasurements(merged, for: path)
            if edited, !Self.skipsArchiveWrites {
                self.measurementPersistence.record(merged, for: path)
            }
            if let notice { self.setStatus(notice, autoClearAfter: 12) }
        }
    }

    /// Completed measurements still follow their source. Drafts, tools and selection belong to each tab.
    private func publishArchivedMeasurements(_ values: [GeoMeasurement], for path: String) {
        measurementPersistence.cachedMeasurements[path] = values
        for tab in workspaceTabs where tab.measurementSourcePath == path && tab.measurements.measurements != values {
            tab.measurements.restore(values, preservingDraft: true)
            if tab === activeWorkspaceTab { canvas.refreshOverlay() }
        }
    }

    private func scheduleArchiveSave(for tab: WorkspaceTab) {
        guard let path = tab.measurementSourcePath, !DebugFixtures.isEnabled else { return }
        let values = tab.measurements.measurements
        let changed = measurementPersistence.cachedMeasurements[path] != values
        if changed { publishArchivedMeasurements(values, for: path) }
        if measurementLoadTasks[path] != nil {
            if changed || measurementReplacedWhileLoading.contains(path) {
                measurementEditedWhileLoading.insert(path)
            }
            return
        }
        guard changed, !Self.skipsArchiveWrites else { return }
        measurementPersistence.record(values, for: path)
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
        if let failure = await measurementPersistence.flush() {
            reportPersistenceFailure(failure)
            return failure
        }
        if let failure = await saveWorkspaceSession(force: true) { return failure }
        persistenceFailure = nil
        return nil
    }
}
