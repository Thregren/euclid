import AppKit
import Observation
import SwiftUI
import TileKit
import UniformTypeIdentifiers

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

/// 画布上的一层：本地数据集、单幅影像或在线源。
///
/// 图层自己带齐「怎么取图」的全部参数（来源、瓦片边长、层级范围、显示约定），
/// 画布只按这个列表装配，因此图层数量与种类都不必在画布里写死。
struct MapLayer: Identifiable {
    enum Kind: String {
        case dataset
        case raster
        case online
    }

    /// 实例 id（复制图层时各层不同）。
    var id: String
    /// 来源身份：数据集目录 / 影像文件路径 / "online"。用来判断「这一层代表哪个来源」。
    var sourceID: String
    var kind: Kind
    var name: String
    /// 取图来源。
    var source: any TileImageSource
    /// 来源签名：只有它变了才重新装配这一层（改不透明度、调顺序都不该重取图）。
    var sourceKey: String
    var tileSize: Int
    var zoomRange: ClosedRange<Int>
    /// 瓦片编号的网格。经纬度网格（EPSG:4490）的行按纬度等分，
    /// 铺到墨卡托世界里同一层每张瓦片的高度都不一样，铺图与读数都要按它算。
    var grid: TileGrid = .webMercator
    /// 在线底图按地图约定（瓦片铺满自身像素数），本地影像按设备像素 1:1。
    var followsDisplayScale: Bool
    var maximumDataZoom: Double
    var memoryLimitBytes: Int
    var maxConcurrentRequests: Int
    /// 适配窗口用的范围（本地数据 / 影像才有）。
    var fitRect: CGRect?
    /// 是不是「基准层」：测量、存档、相机尺度、适配窗口都以它为准。
    var isAnchor: Bool
    var opacity: Double = 1
    var isVisible = true
    /// 给界面看的副标题（层级范围、像素尺寸之类）。
    var detail: String
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
        view.areaUnit = areaUnit
        view.onDeleteLayer = onDeleteLayer
        pending?()
    }

    /// 面积显示单位：界面改了要同步到画布上的面积标注。
    ///
    /// 注意这里自己存一份：设置可能发生在画布视图建好之前（比如启动时读设置），
    /// 只往 view 上写一次会丢。
    var areaUnit: MeasureFormat.AreaUnit = .automatic {
        didSet { view?.areaUnit = areaUnit }
    }

    /// 退格 / 前向删除的落点：画布监听键盘，模型决定「要不要删掉选中的图层」。
    var onDeleteLayer: (() -> Bool)? {
        didSet { view?.onDeleteLayer = onDeleteLayer }
    }

    private weak var measurements: MeasurementStore?

    func bind(measurements: MeasurementStore) {
        self.measurements = measurements
        view?.measurementStore = measurements
    }

    /// 按图层列表装配画布（多图层）。
    func set(layers: [MapLayer], focus: CGRect?) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.view?.setLayers(layers, focus: focus)
        }
        pending = apply
        apply()
    }

    func updateExtent(_ extent: DatasetExtent?) {
        view?.setExtent(extent)
    }

    func setTileGrid(_ isVisible: Bool) {
        view?.showTileGrid = isVisible
    }

    /// 调试用：各层瓦片缓存的摘要（`EUCLID_DEBUG_MEMORY=1` 定期打印）。
    func cacheSummary() async -> String {
        guard let view else { return "画布未就绪" }
        return await view.debugCacheSummary()
    }

    /// 内存压力下把各层瓦片缓存压小（比例 0…1）。
    func trimTileCaches(toFraction fraction: Double) {
        view?.trimTileCaches(toFraction: fraction)
        // 影像的「解好的块」缓存也一起压：它虽然小（几十 MB），
        // 但正好是能立刻还回去、又只影响一次解码的那部分。
        RasterCache.trim(toFraction: fraction)
    }

    func fit(to worldRect: CGRect) { view?.fitToWorldRect(worldRect) }
    func refreshOverlay() { view?.refreshOverlay() }
    func goTo(_ coordinate: GeoCoordinate) { view?.goTo(coordinate) }
    /// 把指针位置记成一个点，返回落了哪条测量。
    @discardableResult
    func dropPointAtCursor() -> GeoMeasurement? { view?.dropPointAtCursor() }
    func fit() { view?.fitToData() }
    func visibleBounds() -> GeoBounds? { view?.visibleGeoBounds() }
    func zoomIn() { view?.zoomIn() }
    func zoomOut(anchor: CGPoint? = nil) { view?.zoomOut(anchor: anchor) }
    /// 调试用：把画布离屏渲染成 PNG（见 `EUCLID_DEBUG_SNAPSHOT`）。
    func snapshot(index: Int) { view?.writeDebugSnapshot(index: index) }
    func actualSize() { view?.zoomToActualSize() }
    /// 把当前画面渲染成位图（导出图片用）。
    func mapImage(includingMeasurements: Bool) -> CGImage? {
        view?.renderMapImage(includingMeasurements: includingMeasurements)
    }
    /// 画布的设备像素比：导出图片时用它决定字号与线宽。
    var backingScale: CGFloat { view?.backingScale ?? 2 }
}

/// 应用状态。
@MainActor
@Observable
final class AppModel {
    /// 全局共享实例：AppDelegate 需要用它来响应「用本应用打开文件夹」。
    static let shared = AppModel()

    /// 瓦片数据集（`<z>/<x>/<y>` 目录）。
    var datasets: [TileDataset] = []
    /// 单幅影像（GeoTIFF / TIFF / 普通图片，按需解出屏幕上的那一块）。
    var rasters: [RasterDataset] = []
    /// 当前选中的本地来源 id：瓦片数据集是目录路径，单幅影像是文件路径。
    var selectedSourceID: String?
    var isScanning = false
    /// 正在读取数据范围：这期间画布是空的，界面上要给个进度指示。
    var isResolvingExtent = false
    var statusMessage: String?
    var rootFolder: URL?
    var extent: DatasetExtent?
    var recentFolders: [URL] = []

    var showInspector = true
    /// 左侧「图层」浮窗是否显示（与右侧检查器同款开关，工具栏与「视图」菜单都能切）。
    var showLayers = true
    /// 面积显示单位（自动 / m² / 公顷 / km² / 亩）—— 只影响界面显示，存档与导出始终是平方米。
    var areaUnit: MeasureFormat.AreaUnit = .automatic {
        didSet {
            guard areaUnit != oldValue else { return }
            UserDefaults.standard.set(areaUnit.rawValue, forKey: Self.areaUnitKey)
            canvas.areaUnit = areaUnit
        }
    }
    static let areaUnitKey = "areaUnit"
    /// 无人值守的调试 / 自检运行（任何 `EUCLID_*` 环境变量都算）。
    ///
    /// 这些脚本会真的落点、清空、再读回，跑一遍就会往用户的自动存档里塞测试数据
    /// （本机踩过一次：自检脚本的两条测试点被写进了福清那份存档）。因此自动化运行
    /// 一律不写自动存档 —— 调试要的东西由脚本自己指定的文件装。
    static let isAutomatedRun = ProcessInfo.processInfo.environment.keys
        .contains { $0.hasPrefix("EUCLID_") }

    /// 这次运行要不要**跳过**自动存档的写入。
    ///
    /// 默认：自动化 / 调试运行（任何 `EUCLID_*`）都不写，避免自检把用户的存档覆盖掉。
    /// 例外：`EUCLID_DEBUG_ARCHIVE_WRITE=1` 显式打开写入 —— 只给「验证写盘这条路还通」用，
    /// 配套做法是跑在临时 `HOME` 下，别真写到用户的存档上。
    static let skipsArchiveWrites = isAutomatedRun
        && ProcessInfo.processInfo.environment["EUCLID_DEBUG_ARCHIVE_WRITE"] == nil
    var showTileGrid = false {
        didSet { canvas.setTileGrid(showTileGrid) }
    }
    /// 在线瓦片下载面板是否展开。
    var showDownloadSheet = false
    /// 是否用在线底图。与下载面板共用同一套源参数（预设、模板、密钥），两处永远一致。
    var usesOnlineBasemap = false {
        didSet { applyBasemap() }
    }

    /// 画布上的图层（下 → 上），标记 `isAnchor` 的那层是测量、存档与相机尺度的依据。
    ///
    /// 图层的种类与数量都不写死：在线底图、本地瓦片数据集、单幅影像都可以叠，
    /// 每层各有一条不透明度。改它请走 `AppModel+Layers.swift` 里的方法；
    /// 这里没写 `private(set)` 是因为 Swift 的 `private` 是文件级的，拆到扩展文件里就看不到了。
    var layers: [MapLayer] = []

    /// 面板里选中的那一层（不透明度等属性作用于它）。
    var selectedLayerID: String?

    var selectedLayer: MapLayer? {
        layers.first { $0.id == selectedLayerID } ?? anchorLayer ?? layers.last
    }

    /// 基准层（本地来源）。
    var anchorLayer: MapLayer? { layers.first { $0.isAnchor } }
    /// 最上面那层在线底图（界面上的「底图」指的就是它）。
    var onlineLayer: MapLayer? { layers.last { $0.kind == .online } }

    /// 基准层的不透明度（侧栏「影像不透明度」、检查器里显示的就是它）。
    var localLayerOpacity: Double {
        get { anchorLayer?.opacity ?? 1 }
        set { setOpacity(of: anchorLayer?.id, to: newValue) }
    }

    /// 在线底图的不透明度。
    var onlineLayerOpacity: Double {
        get { onlineLayer?.opacity ?? 1 }
        set { setOpacity(of: onlineLayer?.id, to: newValue) }
    }

    /// 界面上的在线底图层固定用这个 id（切换源就是替换这一层）。
    static let onlineLayerID = "online"

    let viewport = ViewportState()
    let canvas = CanvasController()
    let measurements = MeasurementStore()
    /// 左侧图层面板里的小缩略图。
    let thumbnails = LayerThumbnailStore()
    let download = TileDownloadModel()
    /// 「从影像生成瓦片」面板的状态。
    let tileExport = TileExportModel()
    /// 生成面板是否展开。
    var showTileExportSheet = false
    /// 「本地瓦片服务」面板的状态。
    let tileServer = TileServerModel()
    /// 本地瓦片服务面板是否展开。
    var showTileServerSheet = false

    /// 扫描代号，用于丢弃过期的扫描结果。
    var scanGeneration = 0
    /// 已经装配到画布上的本地数据集与在线源，避免重复重装。
    var appliedLocalDatasetID: TileDataset.ID?
    var appliedOnlineSignature: String?
    /// 状态栏提示的自动清除任务。
    var statusClearTask: Task<Void, Never>?
    /// 存档写入的防抖任务。
    var archiveTask: Task<Void, Never>?

    /// 启动时待打开的数据集目录。真正的扫描延后到窗口出现之后，避免在 App 初始化阶段触发状态变化。
    var initialURL: URL?

    /// 内存压力监听：系统发警告时把瓦片缓存压小（见 `installMemoryPressureMonitor`）。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        canvas.bind(measurements: measurements)
        download.onStatus = { [weak self] message in
            self?.setStatus(message, autoClearAfter: 6)
        }
        download.onSourceChanged = { [weak self] in
            guard let self, self.usesOnlineBasemap else { return }
            self.applyBasemap()
        }
        tileExport.onStatus = { [weak self] message in
            self?.setStatus(message, autoClearAfter: 8)
        }
        measurements.onChange = { [weak self] in
            self?.scheduleArchiveSave()
        }
        // ⌫ / ⌦：图层面板开着、且没在画测量时，删掉选中的图层（画布那边统一监听键盘）。
        canvas.onDeleteLayer = { [weak self] in
            self?.deleteSelectedLayerFromKeyboard() ?? false
        }
        recentFolders = Self.loadRecentFolders()
        // 面积单位跟着上次的选择（读的时候不走 didSet，别回头再写一遍）。
        if let raw = UserDefaults.standard.string(forKey: Self.areaUnitKey),
           let saved = MeasureFormat.AreaUnit(rawValue: raw) {
            areaUnit = saved
        }
        // 调试开关：无人值守截图时把面积单位与两个面板的显示状态固定下来。
        if let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_AREA_UNIT"],
           let debugUnit = MeasureFormat.AreaUnit(rawValue: raw) {
            areaUnit = debugUnit
        }
        if ProcessInfo.processInfo.environment["EUCLID_DEBUG_HIDE_LAYERS"] != nil {
            showLayers = false
        }
        if let saved = UserDefaults.standard.string(forKey: "lastRootFolder"),
           FileManager.default.fileExists(atPath: saved) {
            initialURL = URL(fileURLWithPath: saved)
        }
        installMemoryPressureMonitor()
    }

    /// 系统报内存紧张时，把各层的瓦片缓存压到上限的一半（严重时压到四分之一）。
    ///
    /// 缓存本身有上限，但「上限之和」在内存小的机器上仍然偏大；被系统警告之后再清，
    /// 比等到换页抖动好。只丢最久没用到的瓦片，正在看的那一屏不受影响。
    private func installMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.memoryPressureSource else { return }
            let critical = source.data.contains(.critical)
            self.canvas.trimTileCaches(toFraction: critical ? 0.25 : 0.5)
            self.setStatus(
                critical ? "内存紧张：已清掉大部分瓦片缓存" : "内存偏紧：已清掉一部分瓦片缓存",
                autoClearAfter: 6
            )
        }
        source.resume()
        memoryPressureSource = source
    }

    static func loadRecentFolders() -> [URL] {
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
        // 无人值守的调试 / 自检运行会真的落点、清空、再读回，**一律不写**用户的自动存档；
        // 演示样本（EUCLID_DEMO_MEASUREMENT）同理。这条守卫必须留在唯一的那条写盘入口上。
        guard !DebugFixtures.isEnabled, !Self.skipsArchiveWrites else { return }
        guard let path = selectedSourcePath else { return }
        let snapshot = measurements.measurements
        archiveTask?.cancel()
        archiveTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            // 编解码与写盘在存档 actor 上做（不在主线程）；失败时在状态栏说一句，
            // 而不是像以前那样把错误吞掉 —— 自动存档失败等于用户的测量悄悄丢了。
            if let failure = await MeasurementArchive.shared.save(snapshot, for: path) {
                setStatus(failure, autoClearAfter: 10)
            }
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
        // `open` 会分辨目录与文件：目录按瓦片数据集扫描，文件按单幅影像读。
        open(url)
    }


}
