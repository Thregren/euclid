import AppKit
import Observation
import SwiftUI
import TileKit

/// 画布对外汇报的视图状态。
@MainActor
@Observable
final class ViewportState {
    var zoomLevel: Double = 0
    var dataZoom: Int = 0
    var center = GeoCoordinate(longitude: 0, latitude: 0)
    var metersPerPoint: Double = 0
    var visibleTiles = 0
    var loadedTiles = 0
    var missingTiles = 0

    func apply(_ snapshot: ViewportSnapshot) {
        zoomLevel = snapshot.zoomLevel
        dataZoom = snapshot.dataZoom
        center = snapshot.center
        metersPerPoint = snapshot.metersPerPoint
        visibleTiles = snapshot.visibleTiles
    }

    func reset() {
        zoomLevel = 0
        dataZoom = 0
        center = GeoCoordinate(longitude: 0, latitude: 0)
        metersPerPoint = 0
        visibleTiles = 0
        loadedTiles = 0
        missingTiles = 0
    }
}

/// SwiftUI 与 AppKit 画布之间的命令通道。
@MainActor
@Observable
final class CanvasController {
    private weak var view: TileCanvasNSView?
    /// 视图还没建好时挂起最后一次装配，`attach` 后立刻补上。
    private var pending: (() -> Void)?

    func attach(_ view: TileCanvasNSView) {
        self.view = view
        view.measurementStore = measurements
        pending?()
    }

    private weak var measurements: MeasurementStore?

    func bind(measurements: MeasurementStore) {
        self.measurements = measurements
        view?.measurementStore = measurements
    }

    func set(dataset: TileDataset?, extent: DatasetExtent?) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.view?.setLocal(dataset: dataset, extent: extent)
        }
        pending = apply
        apply()
    }

    /// 装配（或关掉）在线底图层。
    func set(online basemap: OnlineBasemap?, fitRect: CGRect?) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.view?.setOnline(basemap: basemap, fitRect: fitRect)
        }
        pending = apply
        apply()
    }

    /// 两条图层的不透明度。
    func setLayerOpacity(local: Double, online: Double) {
        view?.setLayerOpacity(local: local, online: online)
    }

    func updateExtent(_ extent: DatasetExtent?) {
        view?.setExtent(extent)
    }

    func setTileGrid(_ isVisible: Bool) {
        view?.showTileGrid = isVisible
    }

    func fit(to worldRect: CGRect) { view?.fitToWorldRect(worldRect) }
    func refreshOverlay() { view?.refreshOverlay() }
    func goTo(_ coordinate: GeoCoordinate) { view?.goTo(coordinate) }
    func fit() { view?.fitToData() }
    func visibleBounds() -> GeoBounds? { view?.visibleGeoBounds() }
    func zoomIn() { view?.zoomIn() }
    func zoomOut(anchor: CGPoint? = nil) { view?.zoomOut(anchor: anchor) }
    /// 调试用：把画布离屏渲染成 PNG（见 `EUCLID_DEBUG_SNAPSHOT`）。
    func snapshot(index: Int) { view?.writeDebugSnapshot(index: index) }
    func actualSize() { view?.zoomToActualSize() }
}

/// 应用状态。
@MainActor
@Observable
final class AppModel {
    /// 全局共享实例：AppDelegate 需要用它来响应「用本应用打开文件夹」。
    static let shared = AppModel()

    var datasets: [TileDataset] = []
    var selectedDatasetID: TileDataset.ID?
    var isScanning = false
    /// 正在读取数据范围：这期间画布是空的，界面上要给个进度指示。
    var isResolvingExtent = false
    var statusMessage: String?
    var rootFolder: URL?
    var extent: DatasetExtent?
    var recentFolders: [URL] = []

    var showInspector = true
    var showTileGrid = false {
        didSet { canvas.setTileGrid(showTileGrid) }
    }
    /// 在线瓦片下载面板是否展开。
    var showDownloadSheet = false
    /// 是否用在线底图。与下载面板共用同一套源参数（预设、模板、密钥），两处永远一致。
    var usesOnlineBasemap = false {
        didSet { applyBasemap() }
    }

    /// 本地影像的不透明度：调低就能透过它看到下层的在线底图，用来核对配准。
    var localLayerOpacity: Double = 1 {
        didSet { canvas.setLayerOpacity(local: localLayerOpacity, online: onlineLayerOpacity) }
    }

    /// 在线底图的不透明度。
    var onlineLayerOpacity: Double = 1 {
        didSet { canvas.setLayerOpacity(local: localLayerOpacity, online: onlineLayerOpacity) }
    }

    let viewport = ViewportState()
    let canvas = CanvasController()
    let measurements = MeasurementStore()
    let download = TileDownloadModel()

    /// 当前在线底图；用本地数据时为 nil。
    var onlineBasemap: OnlineBasemap? {
        guard usesOnlineBasemap else { return nil }
        return OnlineBasemap(template: download.currentTemplate, key: download.key)
    }

    /// 界面上是否有可看的内容（本地数据集或在线底图）。
    var hasMapContent: Bool { selectedDataset != nil || onlineBasemap != nil }

    /// 正在忙什么；nil 表示空闲。用于画布上的进度指示（HIG：加载时别只留空白）。
    var loadingMessage: String? {
        if isScanning { return "正在扫描目录…" }
        if isResolvingExtent { return "正在读取数据范围…" }
        return nil
    }

    /// 当前底图的显示名。
    var basemapName: String {
        onlineBasemap?.name ?? selectedDataset?.name ?? "未打开"
    }

    /// 按当前选择刷新画布。
    func applyBasemap() {
        applyOnlineLayer(force: true)
    }

    /// 装配本地图层。只在数据集真的换了才重装，避免切换底图时把本地层也重取一遍。
    func applyLocalLayer(force: Bool = false) {
        guard force || selectedDatasetID != appliedLocalDatasetID else { return }
        appliedLocalDatasetID = selectedDatasetID
        canvas.set(dataset: selectedDataset, extent: extent)
        canvas.setLayerOpacity(local: localLayerOpacity, online: onlineLayerOpacity)
    }

    /// 装配在线图层。签名没变就不重装。
    func applyOnlineLayer(force: Bool = false) {
        let basemap = onlineBasemap
        let signature = basemap.map {
            "\($0.template.id)|\($0.template.urlTemplate)|\($0.key)"
        }
        guard force || signature != appliedOnlineSignature else { return }
        appliedOnlineSignature = signature

        guard let basemap, basemap.invalidReason == nil else {
            canvas.set(online: nil, fitRect: nil)
            if let reason = basemap?.invalidReason {
                setStatus(reason, autoClearAfter: 6)
            }
            return
        }
        canvas.set(online: basemap, fitRect: extent?.worldRect)
        canvas.setLayerOpacity(local: localLayerOpacity, online: onlineLayerOpacity)
        let suffix = basemap.attribution.isEmpty ? "" : " · \(basemap.attribution)"
        setStatus("底图：\(basemap.name)\(suffix)", autoClearAfter: 5)
    }

    var selectedDataset: TileDataset? {
        datasets.first { $0.id == selectedDatasetID }
    }

    /// 扫描代号，用于丢弃过期的扫描结果。
    private var scanGeneration = 0
    /// 已经装配到画布上的本地数据集与在线源，避免重复重装。
    private var appliedLocalDatasetID: TileDataset.ID?
    private var appliedOnlineSignature: String?
    /// 状态栏提示的自动清除任务。
    private var statusClearTask: Task<Void, Never>?
    /// 存档写入的防抖任务。
    private var archiveTask: Task<Void, Never>?

    /// 启动时待打开的数据集目录。真正的扫描延后到窗口出现之后，避免在 App 初始化阶段触发状态变化。
    private var initialURL: URL?

    init() {
        canvas.bind(measurements: measurements)
        download.onStatus = { [weak self] message in
            self?.setStatus(message, autoClearAfter: 6)
        }
        download.onSourceChanged = { [weak self] in
            guard let self, self.usesOnlineBasemap else { return }
            self.applyBasemap()
        }
        measurements.onChange = { [weak self] in
            self?.scheduleArchiveSave()
        }
        recentFolders = Self.loadRecentFolders()
        if let saved = UserDefaults.standard.string(forKey: "lastRootFolder"),
           FileManager.default.fileExists(atPath: saved) {
            initialURL = URL(fileURLWithPath: saved)
        }
    }

    private static func loadRecentFolders() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        return paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - 状态栏提示

    /// 设置状态栏提示；默认几秒后自动清除，避免旧消息一直挂着。
    func setStatus(_ message: String?, autoClearAfter seconds: Double = 4) {
        statusMessage = message
        statusClearTask?.cancel()
        guard let message, !message.isEmpty, seconds > 0 else { return }
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    // MARK: - 测量存档

    private func scheduleArchiveSave() {
        guard let dataset = selectedDataset else { return }
        let path = dataset.rootURL.path(percentEncoded: false)
        let snapshot = measurements.measurements
        archiveTask?.cancel()
        archiveTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            MeasurementArchive.save(snapshot, for: path)
        }
    }

    /// 撤销 / 重做测量操作。
    func undoMeasurement() {
        measurements.undo()
        canvas.refreshOverlay()
    }

    func redoMeasurement() {
        measurements.redo()
        canvas.refreshOverlay()
    }

    /// 菜单里的撤销：文本输入框获得焦点时交给系统撤销，否则撤销测量操作。
    func performUndo() {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView,
           responder.tryToPerform(Selector(("undo:")), with: nil) {
            return
        }
        guard measurements.canUndo else {
            NSSound.beep()
            return
        }
        undoMeasurement()
        setStatus(nil)
    }

    func performRedo() {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView,
           responder.tryToPerform(Selector(("redo:")), with: nil) {
            return
        }
        guard measurements.canRedo else {
            NSSound.beep()
            return
        }
        redoMeasurement()
        setStatus(nil)
    }

    /// 把视野缩放并居中到某条测量。
    func zoomToMeasurement(_ measurement: GeoMeasurement) {
        guard let rect = measurement.worldRect else { return }
        canvas.fit(to: rect)
    }

    /// 打开启动时记录的数据集（由界面在首个窗口出现后调用）。
    func activateInitialDataset() {
        guard let url = initialURL else { return }
        initialURL = nil
        rootFolder = url
        scan(url)
    }


    // MARK: - 打开

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择瓦片目录（可以是单个数据集，也可以包含多个数据集）"
        if let rootFolder {
            panel.directoryURL = rootFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            setStatus("请选择文件夹，而不是文件")
            return
        }
        rootFolder = url
        let path = url.path(percentEncoded: false)
        UserDefaults.standard.set(path, forKey: "lastRootFolder")
        recentFolders.removeAll { $0.path(percentEncoded: false) == path }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > 8 {
            recentFolders = Array(recentFolders.prefix(8))
        }
        UserDefaults.standard.set(recentFolders.map { $0.path(percentEncoded: false) }, forKey: "recentFolders")
        scan(url)
    }

    private func scan(_ url: URL) {
        scanGeneration += 1
        let generation = scanGeneration
        AppModel.trace("scan start \(url.path(percentEncoded: false))")
        isScanning = true
        setStatus("正在扫描目录…", autoClearAfter: 0)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DatasetLocator.discover(at: url)
            }.value
            AppModel.trace("scan finished datasets=\(found.count)")
            guard generation == self.scanGeneration else { return }
            isScanning = false
            datasets = found
            if found.isEmpty {
                setStatus("在 \(url.lastPathComponent) 中没有找到形如 <z>/<x>/<y> 的瓦片目录", autoClearAfter: 0)
                selectDataset(nil)
            } else {
                selectDataset(found[0].id)
            }
        }
    }

    func selectDataset(_ id: TileDataset.ID?) {
        AppModel.trace("select \(id ?? "nil")")
        selectedDatasetID = id
        extent = nil
        guard let dataset = datasets.first(where: { $0.id == id }) else {
            isResolvingExtent = false
            applyLocalLayer(force: true)
            applyOnlineLayer()
            viewport.reset()
            return
        }
        // 选数据集就重装本地图层；在线底图是否叠加由 `usesOnlineBasemap` 决定，互不影响。
        applyLocalLayer(force: true)
        applyOnlineLayer()
        measurements.restore(MeasurementArchive.measurements(for: dataset.rootURL.path(percentEncoded: false)))
        canvas.refreshOverlay()
        // 数据范围要扫完目录才知道，这期间画布先不铺图（在错误位置铺一屏空占位只会闪）。
        setStatus("正在读取数据范围…", autoClearAfter: 0)
        isResolvingExtent = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DatasetLocator.extent(of: dataset)
            }.value
            guard selectedDatasetID == dataset.id else { return }
            isResolvingExtent = false
            AppModel.trace("extent done \(String(describing: result?.tileCount))")
            extent = result
            canvas.updateExtent(result)
            if result == nil {
                setStatus("未能确定数据范围，已按默认层级显示", autoClearAfter: 6)
            } else {
                setStatus(nil)
            }
            if let result, DebugFixtures.isEnabled {
                DebugFixtures.populateMeasurements(in: result, store: measurements)
                canvas.refreshOverlay()
            }
            DebugZoomScript.runIfRequested(canvas: canvas)
        }
    }

    static func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["EUCLID_TRACE"] != nil else { return }
        FileHandle.standardError.write(Data(("[trace] " + message + "\n").utf8))
    }
}

/// 测量结果的导出格式。
enum MeasurementExportFormat: String, CaseIterable, Identifiable {
    case geoJSON
    case kml
    case csv
    case excel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geoJSON: return "GeoJSON"
        case .kml: return "KML"
        case .csv: return "CSV"
        case .excel: return "Excel"
        }
    }

    var fileExtension: String {
        switch self {
        case .geoJSON: return "geojson"
        case .kml: return "kml"
        case .csv: return "csv"
        case .excel: return "xlsx"
        }
    }

    /// Excel 是二进制格式，不能直接复制成文本。
    var isText: Bool { self != .excel }

    /// 可以复制到剪贴板的格式。
    static var textFormats: [MeasurementExportFormat] {
        allCases.filter(\.isText)
    }

    func render(_ measurements: [GeoMeasurement]) -> String {
        switch self {
        case .geoJSON: return MeasurementExporter.geoJSON(measurements)
        case .kml: return MeasurementExporter.kml(measurements)
        case .csv: return MeasurementExporter.csv(measurements)
        case .excel: return ""
        }
    }

    /// 导出用的字节内容。
    func data(_ measurements: [GeoMeasurement], datasetName: String? = nil) -> Data {
        switch self {
        case .excel:
            return MeasurementExporter.excel(measurements, datasetName: datasetName)
        default:
            return Data(render(measurements).utf8)
        }
    }
}

extension AppModel {
    /// 复制全部测量结果到剪贴板。
    func copyMeasurements(as format: MeasurementExportFormat = .geoJSON) {
        guard !measurements.measurements.isEmpty, format.isText else { return }
        let text = format.render(measurements.measurements)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("已复制 \(measurements.measurements.count) 条测量结果（\(format.title)）")
    }

    /// 导出测量结果到文件。
    func exportMeasurements(as format: MeasurementExportFormat) {
        guard !measurements.measurements.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "测量结果.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "导出 \(measurements.measurements.count) 条测量结果"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let payload = format.data(measurements.measurements, datasetName: selectedDataset?.name)
            try payload.write(to: url, options: .atomic)
            setStatus("已导出 \(measurements.measurements.count) 条测量结果到 \(url.lastPathComponent)")
        } catch {
            setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
        }
    }

    /// 复制一段文本到剪贴板。
    func copyToClipboard(_ text: String, message: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let message { setStatus(message) }
    }

    func goToCoordinate(longitude: Double, latitude: Double) {
        let clampedLatitude = min(max(latitude, -89.9), 89.9)
        canvas.goTo(GeoCoordinate(longitude: longitude, latitude: clampedLatitude))
    }

    func clearMeasurements() {
        measurements.clearAll()
        canvas.refreshOverlay()
    }
}
