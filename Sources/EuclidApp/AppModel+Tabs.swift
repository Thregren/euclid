import AppKit
import Foundation
import Observation
import TileKit

/// 每个标签页拥有自己的来源、图层、视野和测量编辑状态。
@MainActor
@Observable
final class WorkspaceTab: Identifiable {
    nonisolated let id: UUID
    /// 自动标题（跟着打开的内容走）。
    var title: String
    /// 用户改过的名字；有它就优先显示。
    var customName: String?

    var datasets: [TileDataset] = []
    var rasters: [RasterDataset] = []
    var selectedSourceID: String?
    var rootFolder: URL?
    var extent: DatasetExtent?
    var layers: [MapLayer] = []
    var selectedLayerID: String?
    var usesOnlineBasemap = false
    /// 与图层一起存的「已经装到画布上的来源」标记，避免切回来又重装一遍。
    var appliedLocalDatasetID: TileDataset.ID?
    var appliedOnlineSignature: String?
    var swipePivotLayerID: String?
    @ObservationIgnored var viewpoint: WorkspaceViewpoint?
    let measurements = MeasurementStore()
    @ObservationIgnored var measurementSourcePath: String?

    var anchorLayer: MapLayer? { layers.first { $0.isAnchor } }

    /// 保证「基准层」这个不变量：本地数据里有且只有一层是基准层。
    ///
    /// 基准层决定测量、存档与相机尺度。任何会动图层列表的操作（增删、排序、改基准身份）
    /// 之后都过一遍这里：一是别留下两个「基准」（那样「点它切过去」会失效），
    /// 二是别在还有本地数据时一个基准都没有（那样测量与相机就没依据了）。
    func normalizeAnchor() {
        let isLocal: (MapLayer) -> Bool = { $0.kind != .online }
        let anchors = layers.filter { $0.isAnchor && isLocal($0) }
        if anchors.count > 1 {
            // 留下第一个（画布上最下面那层优先），其余降为普通层
            var kept = false
            for index in layers.indices where layers[index].isAnchor && isLocal(layers[index]) {
                if kept { layers[index].isAnchor = false } else { kept = true }
            }
        } else if anchors.isEmpty,
                  let index = layers.lastIndex(where: isLocal) {
            // 一个基准层都没有：把最下面那份本地数据当基准层
            layers[index].isAnchor = true
            if selectedSourceID == nil { selectedSourceID = layers[index].sourceID }
        }
    }

    init(id: UUID = UUID(), title: String = "空标签页") {
        self.id = id
        self.title = title
    }

    /// 标签上显示的名字。
    var displayName: String {
        let custom = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? title : custom
    }
}

extension AppModel {
    var activeWorkspaceTabID: UUID { activeWorkspaceTab.id }

    // These accessors keep commands and panels pointed at the current document.
    var datasets: [TileDataset] {
        get { activeWorkspaceTab.datasets }
        set { activeWorkspaceTab.datasets = newValue }
    }

    var rasters: [RasterDataset] {
        get { activeWorkspaceTab.rasters }
        set { activeWorkspaceTab.rasters = newValue }
    }

    var selectedSourceID: String? {
        get { activeWorkspaceTab.selectedSourceID }
        set { activeWorkspaceTab.selectedSourceID = newValue }
    }

    var rootFolder: URL? {
        get { activeWorkspaceTab.rootFolder }
        set { activeWorkspaceTab.rootFolder = newValue }
    }

    var extent: DatasetExtent? {
        get { activeWorkspaceTab.extent }
        set { activeWorkspaceTab.extent = newValue }
    }

    var layers: [MapLayer] {
        get { activeWorkspaceTab.layers }
        set { activeWorkspaceTab.layers = newValue }
    }

    var selectedLayerID: String? {
        get { activeWorkspaceTab.selectedLayerID }
        set { activeWorkspaceTab.selectedLayerID = newValue }
    }

    var usesOnlineBasemap: Bool {
        get { activeWorkspaceTab.usesOnlineBasemap }
        set {
            activeWorkspaceTab.usesOnlineBasemap = newValue
            applyBasemap()
        }
    }

    var appliedLocalDatasetID: TileDataset.ID? {
        get { activeWorkspaceTab.appliedLocalDatasetID }
        set { activeWorkspaceTab.appliedLocalDatasetID = newValue }
    }

    var appliedOnlineSignature: String? {
        get { activeWorkspaceTab.appliedOnlineSignature }
        set { activeWorkspaceTab.appliedOnlineSignature = newValue }
    }

    var swipePivotLayerID: String? {
        get { activeWorkspaceTab.swipePivotLayerID }
        set {
            guard newValue != activeWorkspaceTab.swipePivotLayerID else { return }
            activeWorkspaceTab.swipePivotLayerID = newValue
            canvas.updateWorkspaceSwipe()
        }
    }

    var measurements: MeasurementStore { activeWorkspaceTab.measurements }
    var measurementOwnerPath: String? { activeWorkspaceTab.measurementSourcePath }
    var anchorLayer: MapLayer? { activeWorkspaceTab.anchorLayer }

    private func presentWorkspaceTab(_ tab: WorkspaceTab) {
        cancelAnalysis()
        cancelSourceLoading()
        activeWorkspaceTab = tab
        restoreOnlineConfiguration(from: tab.layers)
        canvas.showWorkspaceTab(tab)
        if let dataset = selectedDataset, let anchor = tab.anchorLayer, anchor.kind == .dataset, anchor.fitRect == nil {
            resolveExtent(for: dataset)
        }
    }

    func restoreWorkspaceTabs(_ tabs: [WorkspaceTab], activeID: UUID?) {
        guard let active = tabs.first(where: { $0.id == activeID }) ?? tabs.first else { return }
        workspaceTabs = tabs
        presentWorkspaceTab(active)
    }

    private func restoreOnlineConfiguration(from layers: [MapLayer]) {
        guard let layer = layers.first(where: { $0.kind == .online }), let online = layer.source as? RemoteTileSource else { return }
        let callback = download.onSourceChanged
        download.onSourceChanged = nil
        defer { download.onSourceChanged = callback }
        download.sourceID = online.template.id
        download.template = online.template.urlTemplate
        download.sourceName = online.template.name
        download.subdomains = online.template.subdomains
        download.fileExtension = online.template.fileExtension
        download.attribution = online.template.attribution
        download.terms = online.template.terms
        download.key = online.key ?? ""
        download.datum = Datum(rawValue: layer.sourceKey.components(separatedBy: "|").last ?? "") ?? .wgs84
    }

    func activateWorkspaceTab(_ id: UUID) {
        guard id != activeWorkspaceTabID, let tab = workspaceTabs.first(where: { $0.id == id }) else { return }
        presentWorkspaceTab(tab)
    }

    func addWorkspaceTab() {
        let tab = WorkspaceTab()
        bindMeasurementArchive(to: tab)
        workspaceTabs.append(tab)
        presentWorkspaceTab(tab)
        setStatus("已新建标签页")
    }

    /// 关掉当前页后优先切到右邻，最后一页关闭后显示空白页。
    func closeWorkspaceTab(_ id: UUID) {
        guard let index = workspaceTabs.firstIndex(where: { $0.id == id }) else { return }
        workspaceTabs.remove(at: index)
        guard id == activeWorkspaceTabID else { return }
        if workspaceTabs.isEmpty {
            let tab = WorkspaceTab()
            bindMeasurementArchive(to: tab)
            workspaceTabs.append(tab)
        }
        presentWorkspaceTab(workspaceTabs[min(index, workspaceTabs.count - 1)])
    }

    func closeActiveWorkspaceTab() {
        closeWorkspaceTab(activeWorkspaceTabID)
    }

    /// 往后（右）切一页，循环。
    func selectNextWorkspaceTab() {
        cycleWorkspaceTab(step: 1)
    }

    /// 往前（左）切一页，循环。
    func selectPreviousWorkspaceTab() {
        cycleWorkspaceTab(step: -1)
    }

    private func cycleWorkspaceTab(step: Int) {
        guard workspaceTabs.count > 1,
              let index = workspaceTabs.firstIndex(where: { $0 === activeWorkspaceTab }) else { return }
        let count = workspaceTabs.count
        let next = ((index + step) % count + count) % count
        activateWorkspaceTab(workspaceTabs[next].id)
    }

    func renameWorkspaceTab(_ id: UUID, to name: String) {
        guard let tab = workspaceTabs.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customName = trimmed.isEmpty ? nil : trimmed
    }

    func refreshActiveWorkspaceTabTitle() {
        let title = selectedSourceName ?? onlineBasemap?.name ?? "空标签页"
        if activeWorkspaceTab.title != title { activeWorkspaceTab.title = title }
    }
}
