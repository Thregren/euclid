import AppKit
import Foundation
import TileKit

extension AppModel {
    private var sessionEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["EUCLID_DISABLE_SESSION"] == nil &&
            (environment["EUCLID_SESSION_PATH"] != nil || !environment.keys.contains(where: { $0.hasPrefix("EUCLID_DEBUG") || $0 == "EUCLID_DEMO_MEASUREMENT" }))
    }
    func startWorkspaceSession() {
        guard sessionEnabled, sessionTask == nil else { return }
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.saveWorkspaceSession()
            }
        }
    }
    @discardableResult
    func saveWorkspaceSession(force: Bool = false) async -> String? {
        guard sessionEnabled else { return nil }
        if isRestoringSession { return force ? "工作区仍在恢复，请稍后再退出" : nil }
        if !force && (isScanning || isResolvingExtent) { return nil }
        // Measurement archives commit first. A session is never the newer durable generation,
        // so recovery can prefer a present archive without resurrecting an older session copy.
        let reads = Array(measurementLoadTasks.values)
        for task in reads { await task.value }
        if let failure = await measurementPersistence.flush() {
            reportPersistenceFailure(failure)
            return failure
        }
        if force { canvas.commitViewportInteraction() }
        var assets: [SessionAsset] = []
        let tabs = workspaceTabs.map { tab in
            let recipes = tab.layers.map { layer in
                var recipe = SessionLayer(id: layer.id, sourceID: layer.sourceID, kind: layer.kind.rawValue,
                    name: layer.name, opacity: layer.opacity, isVisible: layer.isVisible,
                    isAnchor: layer.isAnchor, datum: Datum(rawValue: layer.sourceKey.components(separatedBy: "|").last ?? "") ?? .wgs84)
                if let online = layer.source as? RemoteTileSource { recipe.template = online.template; recipe.key = online.key }
                if let source = layer.source as? ImageTileSource {
                    let name = FileIdentity.hash(layer.id + layer.sourceKey) + ".png"
                    recipe.image = name; recipe.georeference = source.georeference
                    recipe.pixelWidth = source.pixelWidth; recipe.pixelHeight = source.pixelHeight
                    assets.append(SessionAsset(name: name, image: source.image))
                }
                return recipe
            }
            return SessionTab(id: tab.id, title: tab.title, customName: tab.customName,
                selectedSourceID: tab.selectedSourceID, selectedLayerID: tab.selectedLayerID,
                rootPath: tab.rootFolder?.canonicalFilePath, center: tab.viewpoint?.center,
                zoom: tab.viewpoint?.zoomLevel,
                measurements: tab.measurements.measurements,
                layers: recipes, measurementSourcePath: tab.measurementSourcePath, draft: tab.measurements.workspaceDraft,
                mapViewpoint: tab.viewpoint?.mapViewpoint)
        }
        do {
            try await WorkspaceSessionDisk.shared.save(SessionDocument(activeTab: activeWorkspaceTabID, tabs: tabs), assets: assets)
            if let notice = await WorkspaceSessionDisk.shared.takeNotice() { setStatus(notice, autoClearAfter: 12) }
            return nil
        } catch {
            let message = "工作区保存失败：\(error.localizedDescription)"
            reportPersistenceFailure(message)
            return message
        }
    }
    func restoreWorkspaceSession() async -> Bool {
        guard sessionEnabled else { return false }
        isRestoringSession = true
        defer { isRestoringSession = false }
        let generation = sourceGeneration
        let restored: (SessionDocument, [SessionLoadedTab])?
        do { restored = try await WorkspaceSessionDisk.shared.restore() }
        catch {
            reportPersistenceFailure(error.localizedDescription)
            return false
        }
        if let notice = await WorkspaceSessionDisk.shared.takeNotice() { reportPersistenceFailure(notice) }
        guard let (document, loaded) = restored, generation == sourceGeneration,
              !hasLocalLayer, !loaded.isEmpty else { return false }
        var tabs: [WorkspaceTab] = []
        for item in loaded {
            let saved = item.recipe
            let tab = WorkspaceTab(id: saved.id, title: saved.title)
            tab.customName = saved.customName
            tab.rootFolder = saved.rootPath.map { URL(fileURLWithPath: $0) }
            let measurementPath = saved.measurementSourcePath
                ?? saved.selectedSourceID.flatMap { $0.hasPrefix("/") ? $0 : nil }
            bindMeasurementArchive(to: tab)
            loadMeasurementDocument(for: tab, path: measurementPath, initial: saved.measurements, recoverArchive: true)
            if let draft = saved.draft { tab.measurements.restoreDraft(draft) }
            for restored in item.layers {
                let recipe = restored.recipe
                var layer: MapLayer?
                if let dataset = restored.dataset {
                    tab.datasets = DatasetLocator.merging(tab.datasets, with: [dataset])
                    var value = makeLayer(dataset: dataset)
                    value.fitRect = restored.extent?.worldRect
                    layer = value
                } else if let raster = restored.raster {
                    if !tab.rasters.contains(where: { $0.id == raster.id }) { tab.rasters.append(raster) }
                    layer = makeLayer(raster: raster)
                } else if let image = restored.image {
                    layer = makeLayer(analysisSource: image, name: recipe.name, sourceID: recipe.sourceID, detail: "")
                } else if let template = recipe.template {
                    layer = makeLayer(basemap: OnlineBasemap(template: template, key: recipe.key ?? "", datum: recipe.datum))
                }
                if var value = layer {
                    value.id = recipe.id; value.name = recipe.name; value.opacity = recipe.opacity
                    value.isVisible = recipe.isVisible; value.isAnchor = recipe.isAnchor
                    tab.layers.append(value)
                }
            }
            tab.selectedSourceID = saved.selectedSourceID; tab.selectedLayerID = saved.selectedLayerID
            tab.normalizeAnchor()
            tab.appliedLocalDatasetID = tab.selectedSourceID
            tab.usesOnlineBasemap = tab.layers.contains { $0.kind == .online }
            if let online = item.layers.first(where: { $0.recipe.kind == "online" })?.recipe, let template = online.template {
                tab.appliedOnlineSignature = "\(template.id)|\(template.urlTemplate)|\(online.key ?? "")|\(online.datum.rawValue)"
            }
            tab.viewpoint = saved.workspaceViewpoint
            if let id = tab.selectedSourceID, let source = item.layers.first(where: { $0.dataset?.id == id }) { tab.extent = source.extent }
            else if let id = tab.selectedSourceID, let raster = tab.rasters.first(where: { $0.id == id }) { tab.extent = raster.extent }
            tabs.append(tab)
        }
        restoreWorkspaceTabs(tabs, activeID: document.activeTab)
        if ProcessInfo.processInfo.environment["EUCLID_SESSION_PATH"] != nil {
            FileHandle.standardError.write(Data("[session] restored tabs=\(tabs.count) layers=\(layers.count) active=\(activeWorkspaceTabID)\n".utf8))
        }
        return true
    }
}
