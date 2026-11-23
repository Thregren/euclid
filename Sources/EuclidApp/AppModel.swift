import TileRendering
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
    private weak var workspaceTab: WorkspaceTab?
    private var isPresentingTab = false

    func attach(_ view: TileCanvasNSView) {
        self.view?.onWorkspaceViewpointChanged = nil
        self.view?.onFirstLayout = nil
        self.view = view
        view.areaUnit = areaUnit
        view.onDeleteLayer = onDeleteLayer
        view.boundsPicker = boundsPicker
        view.boundsPickCancel = boundsPickCancel
        view.onWorkspaceViewpointChanged = { [weak self] viewpoint in
            guard let self, !self.isPresentingTab, let tab = self.workspaceTab,
                  tab.viewpoint != viewpoint else { return }
            tab.viewpoint = viewpoint
        }
        presentWorkspaceTab()
    }

    func showWorkspaceTab(_ tab: WorkspaceTab) {
        if workspaceTab !== tab { view?.endWorkspaceInteraction() }
        workspaceTab = tab
        presentWorkspaceTab()
    }

    private func presentWorkspaceTab() {
        guard let view, let tab = workspaceTab else { return }
        guard view.bounds.width > 1, view.bounds.height > 1 else {
            view.onFirstLayout = { [weak self] in self?.presentWorkspaceTab() }
            return
        }
        view.onFirstLayout = nil
        isPresentingTab = true
        defer { isPresentingTab = false }
        view.measurementStore = tab.measurements
        view.setLayers(tab.layers, focus: tab.anchorLayer?.fitRect, preservingView: false)
        if let viewpoint = tab.viewpoint, !tab.layers.isEmpty {
            restoreWorkspaceViewpoint(viewpoint)
        }
        view.setSwipe(pivotLayerID: tab.swipePivotLayerID)
        if !tab.layers.isEmpty, !view.awaitingExtent {
            tab.viewpoint = WorkspaceViewpoint(camera: view.effectiveCamera)
        }
    }

    func updateWorkspaceLayers() {
        guard let tab = workspaceTab else { return }
        if tab.layers.isEmpty { tab.viewpoint = nil }
        guard let view, view.onFirstLayout == nil else { return }
        view.setLayers(tab.layers, focus: tab.anchorLayer?.fitRect)
    }

    func updateWorkspaceSwipe() {
        view?.setSwipe(pivotLayerID: workspaceTab?.swipePivotLayerID)
    }

    func commitViewportInteraction() {
        view?.commitPan()
    }

    /// 「在视图上框选范围」的接收方（非 nil = 画布正在拉框）。
    ///
    /// 画布只认「有一个回调要范围」，不知道下载这回事；下载面板只管填自己的字段，
    /// 不知道屏幕点怎么换算成经纬度。两边的耦合就剩这一个闭包。
    var boundsPicker: ((GeoBounds) -> Void)? {
        didSet { view?.boundsPicker = boundsPicker }
    }

    /// 「在视图上框选范围」被 Esc 取消时的接收方（与 `boundsPicker` 配对）。
    var boundsPickCancel: (() -> Void)? {
        didSet { view?.boundsPickCancel = boundsPickCancel }
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

    func updateExtent(_ extent: DatasetExtent?) {
        view?.setExtent(extent)
    }

    /// 当前视点（书签记的就是它）。
    var viewpoint: (center: GeoCoordinate, zoomLevel: Double)? {
        view?.currentViewpoint
    }

    func restoreWorkspaceViewpoint(_ viewpoint: WorkspaceViewpoint) {
        if let mapViewpoint = viewpoint.mapViewpoint, view?.restoreViewpoint(mapViewpoint) == true { return }
        jump(to: viewpoint.center, zoomLevel: viewpoint.zoomLevel)
    }

    /// 跳到指定视点（中心 + 层级）。
    func jump(to coordinate: GeoCoordinate, zoomLevel: Double? = nil) {
        view?.goTo(coordinate, zoomLevel: zoomLevel)
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
    /// 当前视野的归一化世界矩形（「只算这一屏」的分析用它）。
    var visibleWorldRect: CGRect? { view?.camera.visibleWorldRect }
    /// 把指针位置记成一个点，返回落了哪条测量。
    @discardableResult
    func dropPointAtCursor() -> GeoMeasurement? { view?.dropPointAtCursor() }
    func fit() { view?.fitToData() }
    func visibleBounds() -> GeoBounds? { view?.visibleGeoBounds() }
    func zoomIn() { view?.zoomIn() }
    func zoomOut(anchor: CGPoint? = nil) { view?.zoomOut(anchor: anchor) }
    /// 调试用：把画布离屏渲染成 PNG（见 `EUCLID_DEBUG_SNAPSHOT`）。
    func snapshot(index: Int) { view?.writeDebugSnapshot(index: index) }
    /// 调试用：把画布与窗口的几何打一行到 stderr（见 `EUCLID_DEBUG_FULLSCREEN`）。
    func debugDumpGeometry(_ tag: String) { view?.debugDumpGeometry(tag) }
    /// 调试用：切一次全屏，用来复现跟窗口状态有关的缺陷。
    func debugToggleFullscreen() { view?.window?.toggleFullScreen(nil) }
    /// 调试用：画布视图是否已经装进窗口（脚本要等它到位再动手）。
    var debugHasWindow: Bool { view?.window != nil }
    /// 调试用：窗口当前是不是全屏。
    var debugIsFullscreen: Bool { view?.window?.styleMask.contains(.fullScreen) == true }
    func actualSize() { view?.zoomToActualSize() }
    /// 把当前画面抽成值类型快照（导出图片 / PDF 用）。
    ///
    /// 这一步必须在主线程做（要读视图里的图层树），但只是遍历一遍属性、拿几个不可变的
    /// `CGImage` 引用，微秒级；真正贵的光栅化与编码由调用方拿到快照后丢到后台去做。
    func mapSnapshot(includingMeasurements: Bool = true) -> MapRenderSnapshot? {
        view?.renderSnapshot(includingMeasurements: includingMeasurements)
    }
}

/// 应用状态。
@MainActor
@Observable
final class AppModel {
    /// 全局共享实例：AppDelegate 需要用它来响应「用本应用打开文件夹」。
    static let shared = AppModel()

    var isScanning = false
    /// 正在读取数据范围：这期间画布是空的，界面上要给个进度指示。
    var isResolvingExtent = false
    var statusMessage: String?
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

    /// 进入「在视图上框选下载范围」。
    ///
    /// 下载面板是模态表单，展开时画布收不到鼠标事件；因此这里先把面板收起来，
    /// 拉完框再把面板弹回来、并把范围填进去。中途 Esc 取消则原样弹回面板。
    func pickDownloadBoundsFromView() {
        showDownloadSheet = false
        canvas.boundsPickCancel = { [weak self] in
            guard let self else { return }
            self.canvas.boundsPickCancel = nil
            self.showDownloadSheet = true
        }
        canvas.boundsPicker = { [weak self] bounds in
            guard let self else { return }
            self.canvas.boundsPickCancel = nil
            self.canvas.boundsPicker = nil
            self.download.bounds = bounds
            self.showDownloadSheet = true
            self.setStatus("已框选下载范围：\(bounds.displayText)")
        }
        setStatus("在画布上按住左键拖出一个矩形，松手即填入下载范围（Esc 取消）", autoClearAfter: 8)
    }
    var workspaceTabs: [WorkspaceTab]
    var activeWorkspaceTab: WorkspaceTab

    var selectedLayer: MapLayer? {
        layers.first { $0.id == selectedLayerID } ?? anchorLayer ?? layers.last
    }

    /// 以某一层为分界开启 / 关闭卷帘对比。
    func toggleSwipeCompare(layerID: String) {
        if swipePivotLayerID == layerID {
            swipePivotLayerID = nil
            setStatus("已关闭卷帘对比", autoClearAfter: 4)
            return
        }
        // 分界层必须在列表里、并且它上面真的还有一层可比的东西，否则对比看不出效果。
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard index < layers.count - 1 else {
            setStatus("这一层上面没有别的图层，卷帘对比需要两层才能比出来", autoClearAfter: 6)
            return
        }
        selectedLayerID = layerID
        swipePivotLayerID = layerID
        setStatus("卷帘对比：拖动画面中间的分隔线左右移动", autoClearAfter: 6)
    }

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
    /// 书签视点（中心 + 层级），存在偏好里。
    let bookmarks = BookmarkStore()
    /// 可自定义的快捷键（⌘K 命令面板与键盘监视器共用）。
    let shortcuts = ShortcutStore()
    /// ⌘K 命令面板是否展开。
    var showCommandPalette = false
    /// 快捷键设置面板是否展开。
    var showShortcutSettings = false
    /// 全局按键监视器（装了就一直留着，见 `installCommandKeyMonitor`）。
    @ObservationIgnored var commandKeyMonitor: Any?
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
    /// 栅格分析（DEM 工具箱 / 两期差异）的状态。
    let analysis = RasterAnalysisModel()
    /// DEM 工具箱面板是否展开。
    var showAnalysisSheet = false
    /// Reading this revision observes asynchronous sample completion without changing the view API.
    var elevationReadingRevision: UInt64 = 0
    @ObservationIgnored let elevationSampler = PointElevationSampler()
    @ObservationIgnored var elevationTask: Task<Void, Never>?
    @ObservationIgnored var elevationTaskID: UUID?
    @ObservationIgnored var elevationLatestRequest: PointElevationRequest?
    @ObservationIgnored var elevationCompletedRequest: PointElevationRequest?
    @ObservationIgnored var elevationCompletedValue: Float?
    @ObservationIgnored var elevationCompletedAt: ContinuousClock.Instant?
    /// 分析读句柄的缓存（表头解析本身有缓存，这里省掉重复查找）。
    @ObservationIgnored var analysisReaderCache: (url: URL, identity: FileIdentity?, reader: RasterSampleReader?)?
    @ObservationIgnored var analysisReaderLoadTask: Task<Void, Never>?
    @ObservationIgnored var analysisReaderRequestID: UUID?
    @ObservationIgnored var analysisReaderCheckedAt: ContinuousClock.Instant?
    var analysisReaderRevision = 0

    /// 数据源代号：每次「扫描 / 打开影像 / 选中来源」都 +1，用来丢弃过期结果。
    ///
    /// 连点几个数据集、或者扫描还没回来就换了一份数据时，先发的那个慢任务回来得晚，
    /// 对不上代号就整段丢掉 —— 否则它会拿旧结果把用户刚选的东西覆盖掉。
    var sourceGeneration = 0
    @ObservationIgnored var sourceTask: Task<Void, Never>?
    /// 状态栏提示的自动清除任务。
    var statusClearTask: Task<Void, Never>?
    /// 巡检图集导出任务（重新导出时先取消上一次）。
    var atlasTask: Task<Void, Never>?
    /// 上一次导出图集的目录（菜单里「在访达中显示」用）。
    var lastAtlasDirectory: URL?
    @ObservationIgnored let measurementPersistence = MeasurementPersistenceCoordinator()
    @ObservationIgnored var measurementLoadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var measurementEditedWhileLoading: Set<String> = []
    @ObservationIgnored var measurementReplacedWhileLoading: Set<String> = []
    @ObservationIgnored var measurementReader: @Sendable (String) async -> ([GeoMeasurement]?, String?) = { path in
        let values = await MeasurementArchive.shared.measurementsIfPresent(for: path)
        return (values, await MeasurementArchive.shared.takeNotice())
    }
    var persistenceFailure: String?

    /// 启动时待打开的数据集目录。真正的扫描延后到窗口出现之后，避免在 App 初始化阶段触发状态变化。
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var analysisGeneration = 0
    @ObservationIgnored var sessionTask: Task<Void, Never>?
    @ObservationIgnored var isRestoringSession = false
    var initialURL: URL?

    /// 内存压力监听：系统发警告时把瓦片缓存压小（见 `installMemoryPressureMonitor`）。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        let tab = WorkspaceTab()
        workspaceTabs = [tab]
        activeWorkspaceTab = tab
        bindMeasurementArchive(to: tab)
        canvas.showWorkspaceTab(tab)
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
        measurementPersistence.onFailure = { [weak self] message in
            self?.reportPersistenceFailure(message)
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
            initialURL = DatasetLocator.canonicalURL(URL(fileURLWithPath: saved))
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
            Task { await TileResourceManager.handleMemoryPressure(critical: critical) }
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
        var seen: Set<String> = []
        return paths
            .map { DatasetLocator.canonicalURL(URL(fileURLWithPath: $0)) }
            .filter { FileManager.default.fileExists(atPath: $0.canonicalFilePath) }
            .filter { seen.insert($0.canonicalFilePath).inserted }
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

    // MARK: - 书签视点

    /// 把当前视点记成书签（名字留空时自动用「书签 N」）。
    @discardableResult
    func addBookmark(named name: String? = nil) -> ViewBookmark? {
        guard let view = canvas.viewpoint, hasMapContent else {
            setStatus("先打开一份数据，再记书签")
            return nil
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = "书签 \(bookmarks.items.count + 1)"
        let bookmark = bookmarks.add(
            name: trimmed.isEmpty ? fallback : trimmed,
            center: view.center,
            zoomLevel: view.zoomLevel
        )
        setStatus("已记下视点「\(bookmark.displayName)」")
        return bookmark
    }

    func goToBookmark(_ bookmark: ViewBookmark) {
        canvas.jump(to: bookmark.center, zoomLevel: bookmark.zoomLevel)
        setStatus("已跳到「\(bookmark.displayName)」")
    }

    /// 删除书签（撤销用不上：书签是轻量的偏好，删错了再记一次）。
    func removeBookmark(_ id: UUID) {
        bookmarks.remove(id)
    }

    /// 打开启动时记录的数据集（由界面在首个窗口出现后调用）。
    func activateInitialDataset() {
        let fallback = initialURL
        let initialGeneration = sourceGeneration
        initialURL = nil
        Task {
            if !(await restoreWorkspaceSession()), let fallback, !hasLocalLayer, sourceGeneration == initialGeneration { open(fallback) }
            startWorkspaceSession()
        }
    }


}
