import AppKit
import Foundation
import Observation
import TileKit

/// 一个标签页 = 一份「打开的东西」：数据集 / 影像、图层、视角、测量。
///
/// 标签页之间不共享任何可变状态：切换就是「把当前状态存回这一页、把另一页的状态装回来」。
/// 存的全是值类型（数组与结构体），因此不存在两页指向同一份状态的问题。
/// 画布、下载、导出这些不属于「某一页」的东西照样是全局的。
struct WorkspaceTab: Identifiable {
    let id: UUID
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
    /// 切走时的视点；没动过视图就是 nil（切回来按数据范围适配）。
    var viewpoint: (center: GeoCoordinate, zoomLevel: Double)?
    var measurements: [GeoMeasurement] = []
    var draft: MeasurementDraft?
    var measurementSourcePath: String?
    /// Only restored sessions need reconciliation; in-process tab snapshots already share revisions.
    var recoverMeasurementArchive = false

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

/// 多标签页：同时开着好几份数据，来回切。
///
/// 实现上刻意选「状态快照互换」而不是「把 AppModel 拆成每页一个实例」：
/// 后者要把所有 `layers` / `datasets` 的调用点都改成 `activePage.layers`，改动面极大；
/// 前者只在切换的那一刻把值搬运一遍，其余代码一行不用动，风险小得多。
extension AppModel {
    /// 当前页在一览里的下标。
    var activeWorkspaceTabIndex: Int? {
        guard let id = activeWorkspaceTabID else { return nil }
        return workspaceTabs.firstIndex { $0.id == id }
    }

    /// 没有分过页时，按当前状态补出第一页（启动后第一次用到标签页时调用）。
    ///
    /// 只补空壳，不捕获当前状态：这样「刚打开数据就出现在第一页」的路径
    /// 与以前完全一致（谁也不用去猜那一刻状态是不是完整的）。
    func ensureWorkspaceTabs() {
        guard workspaceTabs.isEmpty else { return }
        let tab = WorkspaceTab(title: derivedTabTitle())
        workspaceTabs = [tab]
        activeWorkspaceTabID = tab.id
    }

    /// 这一页该叫什么：跟着打开的内容走，没有内容就叫「空标签页」。
    func derivedTabTitle() -> String {
        if let name = selectedSourceName { return name }
        if usesOnlineBasemap, let basemap = onlineBasemap { return basemap.name }
        return "空标签页"
    }

    /// 把当前模型状态存回当前页。切页 / 关页 / 记标题时调用。
    func captureCurrentWorkspaceTab() {
        guard let index = activeWorkspaceTabIndex else { return }
        workspaceTabs[index].title = derivedTabTitle()
        workspaceTabs[index].datasets = datasets
        workspaceTabs[index].rasters = rasters
        workspaceTabs[index].selectedSourceID = selectedSourceID
        workspaceTabs[index].rootFolder = rootFolder
        workspaceTabs[index].extent = extent
        workspaceTabs[index].layers = layers
        workspaceTabs[index].selectedLayerID = selectedLayerID
        workspaceTabs[index].usesOnlineBasemap = usesOnlineBasemap
        workspaceTabs[index].appliedLocalDatasetID = appliedLocalDatasetID
        workspaceTabs[index].appliedOnlineSignature = appliedOnlineSignature
        workspaceTabs[index].viewpoint = canvas.viewpoint
        workspaceTabs[index].measurements = measurements.measurements
        workspaceTabs[index].draft = measurements.workspaceDraft
        workspaceTabs[index].measurementSourcePath = measurementOwnerPath
    }

    /// 把某一页的状态装回模型，并让画布跟上。
    func applyWorkspaceTab(_ tab: WorkspaceTab) {
        cancelAnalysis()
        cancelSourceLoading()
        isSwitchingWorkspaceTab = true
        defer { isSwitchingWorkspaceTab = false }

        datasets = tab.datasets
        rasters = tab.rasters
        selectedSourceID = tab.selectedSourceID
        rootFolder = tab.rootFolder
        extent = tab.extent
        restoreOnlineConfiguration(from: tab.layers)
        selectedLayerID = tab.selectedLayerID

        // 在线底图开关会顺带重装在线层；放在图层列表之前，随后的整体赋值说了算。
        if usesOnlineBasemap != tab.usesOnlineBasemap {
            usesOnlineBasemap = tab.usesOnlineBasemap
        }

        layers = tab.layers
        appliedLocalDatasetID = tab.appliedLocalDatasetID
        appliedOnlineSignature = tab.appliedOnlineSignature
        normalizeAnchor()
        pushLayers()

        // 测量不走 onChange：切页不该把这一页的测量写进另一页的自动存档。
        changeMeasurementDocument(to: tab.measurementSourcePath ?? measurementPath(for: tab.selectedSourceID), initial: tab.measurements, recoverArchive: tab.recoverMeasurementArchive)
        if let draft = tab.draft {
            measurements.restoreDraft(draft)
            canvas.refreshOverlay()
        }

        // 视角：记过就跳回去，没记过就按数据范围适配。
        if let viewpoint = tab.viewpoint {
            canvas.jump(to: viewpoint.center, zoomLevel: viewpoint.zoomLevel)
        } else if let rect = anchorLayer?.fitRect {
            canvas.fit(to: rect)
        }
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

    /// 切到指定标签页。
    func activateWorkspaceTab(_ id: UUID) {
        guard id != activeWorkspaceTabID,
              let tab = workspaceTabs.first(where: { $0.id == id }) else { return }
        captureCurrentWorkspaceTab()
        activeWorkspaceTabID = id
        applyWorkspaceTab(tab)
    }

    /// 新开一页（空白），并把当前页存回。
    func addWorkspaceTab() {
        ensureWorkspaceTabs()
        captureCurrentWorkspaceTab()
        var tab = WorkspaceTab()
        tab.title = "空标签页"
        workspaceTabs.append(tab)
        activeWorkspaceTabID = tab.id
        applyWorkspaceTab(tab)
        setStatus("已新建标签页")
    }

    /// 关掉一页。关掉最后一页时留一个空白页，不留「一页都没有」的状态。
    func closeWorkspaceTab(_ id: UUID) {
        ensureWorkspaceTabs()
        captureCurrentWorkspaceTab()
        guard let index = workspaceTabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeWorkspaceTabID
        workspaceTabs.remove(at: index)

        if workspaceTabs.isEmpty {
            let tab = WorkspaceTab()
            workspaceTabs = [tab]
            activeWorkspaceTabID = tab.id
            applyWorkspaceTab(tab)
            return
        }
        guard wasActive else { return }
        // 关掉的是当前页：接到右边一页，没有右边就接左边一页。
        let next = workspaceTabs[min(index, workspaceTabs.count - 1)]
        activeWorkspaceTabID = next.id
        applyWorkspaceTab(next)
    }

    /// 关掉当前页（菜单 / ⌥⌘W）。
    func closeActiveWorkspaceTab() {
        ensureWorkspaceTabs()
        guard let id = activeWorkspaceTabID else { return }
        closeWorkspaceTab(id)
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
        ensureWorkspaceTabs()
        guard workspaceTabs.count > 1, let index = activeWorkspaceTabIndex else { return }
        let count = workspaceTabs.count
        let next = ((index + step) % count + count) % count
        activateWorkspaceTab(workspaceTabs[next].id)
    }

    /// 给当前页改名（留空则恢复自动标题）。
    func renameWorkspaceTab(_ id: UUID, to name: String) {
        guard let index = workspaceTabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceTabs[index].customName = trimmed.isEmpty ? nil : trimmed
    }

    /// 打开数据之后刷新当前页的自动标题（切页前看不到，标签栏里也不该写着旧名字）。
    func refreshActiveWorkspaceTabTitle() {
        guard !isSwitchingWorkspaceTab, let index = activeWorkspaceTabIndex else { return }
        let title = derivedTabTitle()
        guard workspaceTabs[index].title != title else { return }
        workspaceTabs[index].title = title
    }
}
