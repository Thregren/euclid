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
        pending?()
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
    var showTileGrid = false {
        didSet { canvas.setTileGrid(showTileGrid) }
    }
    /// 在线瓦片下载面板是否展开。
    var showDownloadSheet = false
    /// 是否用在线底图。与下载面板共用同一套源参数（预设、模板、密钥），两处永远一致。
    var usesOnlineBasemap = false {
        didSet { applyBasemap() }
    }

    /// 画布上的图层（下 → 上）。标记 `isAnchor` 的那层是测量、存档与相机尺度的依据。
    ///
    /// 图层的种类与数量都不写死：在线底图、本地瓦片数据集、单幅影像都可以叠，
    /// 每层各有一条不透明度。
    private(set) var layers: [MapLayer] = []

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

    // MARK: - 图层操作

    /// 改某一层的不透明度。
    func setOpacity(of id: String?, to value: Double) {
        guard let id, let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].opacity = min(max(value, 0), 1)
        pushLayers()
    }

    /// 选中某一层；选中的是另一份本地数据时，顺手把它切换成基准层（测量与相机跟着走）。
    func selectLayer(_ id: String) {
        selectedLayerID = id
        guard let layer = layers.first(where: { $0.id == id }),
              !layer.isAnchor, layer.kind != .online else { return }
        selectedSourceID = layer.sourceID
    }

    /// 移除当前选中层（没有选中时移除最上面那层）。
    func removeSelectedLayer() {
        guard let id = selectedLayer?.id else { return }
        removeLayer(id)
        selectedLayerID = layers.last?.id
    }

    func canMoveSelectedLayer(up: Bool) -> Bool {
        guard let id = selectedLayer?.id, let index = layers.firstIndex(where: { $0.id == id }) else { return false }
        return layers.indices.contains(up ? index + 1 : index - 1)
    }

    func moveSelectedLayer(up: Bool) {
        guard let id = selectedLayer?.id, canMoveSelectedLayer(up: up) else { return }
        moveLayer(id, up: up)
    }

    /// 把某一层设为基准层（测量、存档与相机尺度以它为准）。
    func setAnchorLayer(_ id: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }), layers[index].kind != .online else { return }
        for i in layers.indices { layers[i].isAnchor = (i == index) }
        selectedSourceID = id
        pushLayers()
        setStatus("基准层已改为：\(layers[index].name)", autoClearAfter: 5)
    }

    /// 显示 / 隐藏某一层。
    func setVisible(_ visible: Bool, of id: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].isVisible = visible
        pushLayers()
    }

    /// 移除某一层。基准层被移除时清掉当前选中项。
    func removeLayer(_ id: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let removed = layers.remove(at: index)
        if selectedLayerID == id { selectedLayerID = layers.last?.id }
        if removed.isAnchor {
            selectedSourceID = nil
            appliedLocalDatasetID = nil
            extent = nil
            measurements.clearAll()
            canvas.refreshOverlay()
        }
        if removed.kind == .online, layers.last(where: { $0.kind == .online }) == nil {
            usesOnlineBasemap = false
        }
        pushLayers()
    }

    /// 调整叠放次序（列表末尾在最上面）。
    func moveLayer(_ id: String, up: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index + 1 : index - 1
        guard layers.indices.contains(target) else { return }
        layers.swapAt(index, target)
        pushLayers()
    }

    /// 复制一层（叠在原层上面）。
    func duplicateLayer(_ id: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = layers[index]
        copy.id = UUID().uuidString
        copy.isAnchor = false
        layers.insert(copy, at: index + 1)
        selectedLayerID = copy.id
        pushLayers()
        setStatus("已复制图层：\(copy.name)", autoClearAfter: 5)
    }

    // MARK: - 图层面板的顺序

    /// 图层在面板里自上而下的顺序。
    ///
    /// 画师习惯：**最上面那层排在第一行**（Pixelmator / Photoshop 都如此），
    /// 而模型里存的是「下 → 上」，两者正好相反。这份换算只在这里做，
    /// 面板显示与拖动排序都走它，免得各处各翻一次。
    var panelOrder: [MapLayer] { layers.reversed() }

    /// 把某一层拖到面板的某一行：`row` 是插入位置，取 `0…layers.count`，
    /// `0` 表示放到第一行之前（也就是最上层），`layers.count` 表示放到最后一行之后（最底层）。
    func moveLayer(_ id: String, toPanelRow row: Int) {
        guard let from = layers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(row, 0), layers.count)
        // 面板行号自上而下，模型下标自下而上：先把行号翻成「移除之前」的插入下标，
        // 移除之后再把落在后面的下标补回来。
        var target = layers.count - clamped
        let layer = layers.remove(at: from)
        if target > from { target -= 1 }
        layers.insert(layer, at: min(max(target, 0), layers.count))
        pushLayers()
    }

    /// 全部显示 / 全部隐藏。
    func setAllLayersVisible(_ visible: Bool) {
        for index in layers.indices { layers[index].isVisible = visible }
        pushLayers()
    }

    /// 直接加一层（侧栏「添加本地数据 / 添加在线底图」用）。
    func addLayer(_ layer: MapLayer) {
        layers.append(layer)
        selectedLayerID = layer.id
        pushLayers()
        setStatus("已添加图层：\(layer.name)", autoClearAfter: 5)
    }

    /// 把图层列表推给画布。
    private func pushLayers() {
        canvas.set(layers: layers, focus: anchorLayer?.fitRect)
    }

    /// 由本地来源造一层。
    func makeLayer(dataset: TileDataset) -> MapLayer {
        MapLayer(
            id: UUID().uuidString,
            sourceID: dataset.id,
            kind: .dataset,
            name: dataset.name,
            source: dataset.source,
            sourceKey: "dataset|\(dataset.id)|\(dataset.layout.tileSize)",
            tileSize: dataset.layout.tileSize,
            zoomRange: dataset.zoomRange,
            followsDisplayScale: false,
            maximumDataZoom: Double(dataset.zoomRange.upperBound),
            memoryLimitBytes: 512 * 1024 * 1024,
            maxConcurrentRequests: 8,
            fitRect: extent?.worldRect,
            isAnchor: true,
            detail: "z\(dataset.zoomRange.lowerBound)–z\(dataset.zoomRange.upperBound) · \(dataset.layout.tileSize)px"
        )
    }

    /// 由单幅影像造一层。
    func makeLayer(raster: RasterDataset) -> MapLayer {
        MapLayer(
            id: UUID().uuidString,
            sourceID: raster.id,
            kind: .raster,
            name: raster.name,
            source: raster.source,
            sourceKey: "raster|\(raster.id)",
            tileSize: raster.tileSize,
            zoomRange: raster.zoomRange,
            followsDisplayScale: false,
            maximumDataZoom: raster.maximumDataZoom,
            memoryLimitBytes: 512 * 1024 * 1024,
            maxConcurrentRequests: 8,
            fitRect: raster.worldRect,
            isAnchor: true,
            detail: "\(raster.pixelSizeText) · \(raster.isGeoreferenced ? raster.crsName : "未配准")"
        )
    }

    /// 由在线底图配置造一层。
    func makeLayer(basemap: OnlineBasemap) -> MapLayer {
        MapLayer(
            id: UUID().uuidString,
            sourceID: Self.onlineLayerID,
            kind: .online,
            name: basemap.name,
            source: basemap.makeSource(),
            sourceKey: "\(basemap.template.id)|\(basemap.template.urlTemplate)|\(basemap.key)|\(basemap.datum.rawValue)",
            tileSize: basemap.tileSize,
            zoomRange: basemap.zoomRange,
            followsDisplayScale: true,
            maximumDataZoom: Double(basemap.zoomRange.upperBound),
            memoryLimitBytes: 256 * 1024 * 1024,
            maxConcurrentRequests: 24,
            fitRect: extent?.worldRect,
            isAnchor: false,
            detail: "在线 · z0–z\(basemap.zoomRange.upperBound)\(basemap.datum == .wgs84 ? "" : " · \(basemap.datum.shortTitle)")"
        )
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

    /// 当前在线底图；用本地数据时为 nil。
    var onlineBasemap: OnlineBasemap? {
        guard usesOnlineBasemap else { return nil }
        return OnlineBasemap(template: download.currentTemplate, key: download.key, datum: download.datum)
    }

    /// 界面上是否有可看的内容（本地数据集或在线底图）。
    var hasMapContent: Bool { selectedSourceName != nil || onlineBasemap != nil }

    /// 正在忙什么；nil 表示空闲。用于画布上的进度指示（HIG：加载时别只留空白）。
    var loadingMessage: String? {
        if isScanning { return "正在扫描目录…" }
        if isResolvingExtent { return "正在读取数据范围…" }
        return nil
    }

    /// 当前底图的显示名。
    var basemapName: String {
        onlineBasemap?.name ?? selectedSourceName ?? "未打开"
    }

    /// 按当前选择刷新画布。
    func applyBasemap() {
        applyOnlineLayer(force: true)
    }

    /// 重建「基准本地层」：只替换标记为 anchor 的那一层，用户另外添加的图层保持不动。
    func applyLocalLayer(force: Bool = false) {
        guard force || selectedSourceID != appliedLocalDatasetID else { return }
        appliedLocalDatasetID = selectedSourceID
        let previousOpacity = anchorLayer?.opacity ?? 1
        let previousVisibility = anchorLayer?.isVisible ?? true
        layers.removeAll { $0.isAnchor }
        var newLayer: MapLayer?
        if let raster = selectedRaster {
            newLayer = makeLayer(raster: raster)
        } else if let dataset = selectedDataset {
            newLayer = makeLayer(dataset: dataset)
        }
        if var layer = newLayer {
            layer.opacity = previousOpacity
            layer.isVisible = previousVisibility
            layers.insert(layer, at: 0)   // 本地影像放最下层，参考底图叠在它上面
        }
        pushLayers()
    }

    /// 重建「在线底图层」：签名没变就不动。
    func applyOnlineLayer(force: Bool = false) {
        let basemap = onlineBasemap
        let signature = basemap.map {
            // 基准要进签名：只改基准（模板与密钥都没动）时也得重装图层，否则偏移不会生效。
            "\($0.template.id)|\($0.template.urlTemplate)|\($0.key)|\($0.datum.rawValue)"
        }
        guard force || signature != appliedOnlineSignature else { return }
        appliedOnlineSignature = signature

        let previousOpacity = onlineLayer?.opacity ?? 1
        let previousVisibility = onlineLayer?.isVisible ?? true
        layers.removeAll { $0.kind == .online && $0.sourceID == Self.onlineLayerID }

        guard let basemap, basemap.invalidReason == nil else {
            if let reason = basemap?.invalidReason {
                setStatus(reason, autoClearAfter: 6)
            }
            pushLayers()
            return
        }
        var layer = makeLayer(basemap: basemap)
        layer.opacity = previousOpacity
        layer.isVisible = previousVisibility
        layers.append(layer)
        pushLayers()

        var message = "底图：\(basemap.name)"
        if !basemap.attribution.isEmpty { message += " · \(basemap.attribution)" }
        // 偏移基准要说清方向与量级：使用者一眼就能判断基准选得对不对。
        if basemap.datum != .wgs84 {
            message += " · " + basemap.offsetHint(at: viewport.center)
        }
        setStatus(message, autoClearAfter: 5)
    }

    var selectedDataset: TileDataset? {
        datasets.first { $0.id == selectedSourceID }
    }

    /// 当前选中的单幅影像。
    var selectedRaster: RasterDataset? {
        rasters.first { $0.id == selectedSourceID }
    }

    /// 当前本地来源的名字（瓦片数据集或单幅影像）。
    var selectedSourceName: String? {
        selectedDataset?.name ?? selectedRaster?.name
    }

    /// 当前本地来源的目录 / 文件路径（测量存档与「最近打开」用）。
    private var selectedSourcePath: String? {
        selectedDataset?.rootURL.path(percentEncoded: false)
            ?? selectedRaster?.fileURL.path(percentEncoded: false)
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
        tileExport.onStatus = { [weak self] message in
            self?.setStatus(message, autoClearAfter: 8)
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
        // 调试用的示例测量（EUCLID_DEMO_MEASUREMENT）只是铺上去截图核对的，
        // 不能写进存档：那会覆盖掉用户自己量的结果。
        guard !DebugFixtures.isEnabled else { return }
        guard let path = selectedSourcePath else { return }
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
        // `open` 会分辨目录与文件：目录按瓦片数据集扫描，文件按单幅影像读。
        open(url)
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

    /// 打开「从影像生成瓦片」面板：已经打开单幅影像时带上它，否则进去再选。
    func promptForTileExport() {
        showTileExportSheet = true
    }

    /// 打开单幅影像（GeoTIFF / TIFF，也收普通图片：读不出地理参考就按未配准显示）。
    func promptForRaster() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择单幅影像（GeoTIFF / TIFF / PNG 等）"
        panel.allowedContentTypes = [.tiff, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            setStatus("找不到这个路径：\(url.lastPathComponent)")
            return
        }
        remember(url)
        openWithoutRemembering(url, isDirectory: isDirectory.boolValue)
    }

    /// 打开一份数据但**不写进「最近打开」**（调试用：无人值守截图时不改用户的偏好）。
    func openForDebugging(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            setStatus("找不到这个路径：\(url.lastPathComponent)")
            return
        }
        openWithoutRemembering(url, isDirectory: isDirectory.boolValue)
    }

    private func openWithoutRemembering(_ url: URL, isDirectory: Bool) {
        guard isDirectory else {
            // 文件：按单幅影像打开（GeoTIFF / TIFF / 普通图片）。
            openRaster(url)
            return
        }
        rootFolder = url
        scan(url)
    }

    /// 记住最近打开过的目录或文件。
    private func remember(_ url: URL) {
        let path = url.path(percentEncoded: false)
        UserDefaults.standard.set(path, forKey: "lastRootFolder")
        recentFolders.removeAll { $0.path(percentEncoded: false) == path }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > 8 {
            recentFolders = Array(recentFolders.prefix(8))
        }
        UserDefaults.standard.set(recentFolders.map { $0.path(percentEncoded: false) }, forKey: "recentFolders")
    }

    /// 读单幅影像：只读文件头（IFD），因此再大的图也是秒开。
    func openRaster(_ url: URL) {
        isResolvingExtent = true
        setStatus("正在读取影像…", autoClearAfter: 0)
        Task {
            let result: Result<RasterDataset, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try RasterLoader.load(url: url)) } catch { return .failure(error) }
            }.value
            isResolvingExtent = false
            AppModel.trace("raster loaded \(url.lastPathComponent)")
            switch result {
            case .success(let raster):
                rasters.removeAll { $0.id == raster.id }
                rasters.insert(raster, at: 0)
                selectSource(raster.id)
            case .failure(let error):
                setStatus("打开影像失败：\((error as? TIFFError)?.description ?? error.localizedDescription)", autoClearAfter: 8)
            }
        }
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
                selectSource(nil)
            } else {
                selectSource(found[0].id)
            }
        }
    }

    /// 选中一个本地来源：瓦片数据集或单幅影像。
    func selectSource(_ id: String?) {
        AppModel.trace("select \(id ?? "nil")")
        selectedSourceID = id
        extent = nil

        // 单幅影像：尺寸、坐标系与覆盖范围都在读文件头时就算好了，不需要异步扫描。
        if let raster = rasters.first(where: { $0.id == id }) {
            isResolvingExtent = false
            extent = raster.extent
            applyLocalLayer(force: true)
            applyOnlineLayer()
            measurements.restore(MeasurementArchive.measurements(for: raster.id))
            canvas.refreshOverlay()
            reportRaster(raster)
            if DebugFixtures.isEnabled {
                DebugFixtures.populateMeasurements(in: raster.extent, store: measurements)
                canvas.refreshOverlay()
            }
            DebugZoomScript.runIfRequested(canvas: canvas)
            return
        }

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
            guard selectedSourceID == dataset.id else { return }
            isResolvingExtent = false
            AppModel.trace("extent done \(String(describing: result?.tileCount))")
            extent = result
            if let result, let index = layers.firstIndex(where: { $0.isAnchor }) {
                layers[index].fitRect = result.worldRect
            }
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

    /// 打开单幅影像后在状态栏交代一句：看了什么、多大、多清晰、是否配准。
    private func reportRaster(_ raster: RasterDataset) {
        if let note = raster.placementNote {
            setStatus("\(raster.name)：未配准（\(note)），已按 1 像素 = 1 米摆放", autoClearAfter: 8)
            return
        }
        var parts = ["\(raster.pixelSizeText)", raster.crsName]
        if let gsd = raster.groundSampleDistance {
            parts.append(gsd >= 1
                ? String(format: "%.2f 米/像素", gsd)
                : String(format: "%.1f 厘米/像素", gsd * 100))
        }
        setStatus("单幅影像 \(raster.name)：\(parts.joined(separator: " · "))", autoClearAfter: 6)
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
            let payload = format.data(measurements.measurements, datasetName: selectedSourceName)
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

    /// 复制指针所在坐标（检查器按钮与「工具」菜单共用，快捷键 ⌥⌘C）。
    func copyCursorCoordinate() {
        guard let cursor = measurements.cursorInfo else {
            setStatus("把指针移到地图上再复制坐标")
            return
        }
        copyToClipboard(
            CoordinateText.decimal(cursor.coordinate, precision: 7),
            message: "已复制坐标"
        )
    }

    /// 把指针位置记成一个点（快捷键 P）。与「点坐标」工具共用同一份测量数据。
    func dropPointAtCursor() {
        guard hasMapContent else { return }
        guard let measurement = canvas.dropPointAtCursor(),
              let coordinate = measurement.points.first else {
            setStatus("把指针移到地图上，再按 P 记下这个点", autoClearAfter: 5)
            return
        }
        setStatus("已记下 \(CoordinateText.decimal(coordinate, precision: 6))（可在检查器里改名或调样式）")
    }

    func clearMeasurements() {
        measurements.clearAll()
        canvas.refreshOverlay()
    }

    // MARK: - 测量的显式存档

    /// 把当前测量另存为一个文件：可以交给别人、换机器接着用，或者当作「彻底保存」的备份。
    func saveMeasurementsToFile() {
        guard !measurements.measurements.isEmpty else {
            setStatus("现在还没有测量可以保存")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(selectedSourceName ?? "测量")-测量.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.message = "保存 \(measurements.measurements.count) 条测量（JSON，可再次载入编辑）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeMeasurements(to: url)
    }

    /// 写到一个具体文件（面板与调试脚本共用同一条路径）。
    @discardableResult
    func writeMeasurements(to url: URL) -> Bool {
        guard let data = MeasurementArchive.encode(measurements.measurements) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            setStatus("已保存 \(measurements.measurements.count) 条测量到 \(url.lastPathComponent)")
            return true
        } catch {
            setStatus("保存失败：\(error.localizedDescription)", autoClearAfter: 8)
            return false
        }
    }

    /// 从文件里追加测量（不清掉现有的，便于把几次外业的点拼在一起）。
    func loadMeasurementsFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择之前保存的测量文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard loadMeasurements(from: url) == nil else { return }
    }

    /// 从具体文件追加测量；返回读到的条数，失败返回 nil。
    @discardableResult
    func loadMeasurements(from url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let loaded = MeasurementArchive.decode(data) else {
            setStatus("这个文件里没有可识别的测量", autoClearAfter: 6)
            return nil
        }
        guard !loaded.isEmpty else {
            setStatus("这个文件里没有测量", autoClearAfter: 6)
            return nil
        }
        measurements.merge(loaded)
        canvas.refreshOverlay()
        setStatus("已载入 \(loaded.count) 条测量（追加到现有 \(measurements.measurements.count - loaded.count) 条之后）")
        return loaded.count
    }

    /// 在访达里显示自动存档文件（每次改动都会写进去，按数据集 / 影像分开存）。
    func revealMeasurementArchive() {
        guard let url = MeasurementArchive.archiveFileURL,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            setStatus("自动存档还没有生成（先量一条试试）")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 出图

    /// 快捷导出目录：默认 `~/图片/尺规`，也可以在「导出为图片…」里换。
    private static let quickExportFolderKey = "quickExportFolder"

    private var quickExportDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: Self.quickExportFolderKey) {
            return URL(fileURLWithPath: path)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appending(path: "尺规", directoryHint: .isDirectory)
    }

    /// 快速导出当前视图：不弹面板，直接按时间戳存进快捷导出目录（含测量标注）。
    func quickExportView() {
        guard hasMapContent else {
            setStatus("当前没有可导出的画面")
            return
        }
        guard let data = viewImageData() else {
            setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(basemapName)-\(formatter.string(from: Date())).png"
        let directory = quickExportDirectory
        let url = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            setStatus("已快速导出：\(directory.lastPathComponent)/\(name)", autoClearAfter: 8)
        } catch {
            setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
        }
    }

    /// 在访达里显示快捷导出目录。
    func revealQuickExportFolder() {
        let directory = quickExportDirectory
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            setStatus("还没有快速导出过（⌘E 试一次）")
        }
    }

    /// 导出当前视图：画面（瓦片 + 测量标注）加一条信息栏，
    /// 里面是数据源、中心坐标、层级与比例尺，直接贴进报告就能看懂。
    func exportViewAsImage() {
        guard let info = viewImageInfo else {
            setStatus("当前没有可导出的画面")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(basemapName)-视图.png"
        panel.allowedContentTypes = [.png]
        panel.isExtensionHidden = false
        panel.message = "导出当前视图（下方带数据源、中心坐标与比例尺信息栏）"
        let measurementsToggle = NSButton(
            checkboxWithTitle: "包含测量标注", target: nil, action: nil
        )
        measurementsToggle.state = .on
        panel.accessoryView = measurementsToggle
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let includesMeasurements = measurementsToggle.state == .on
        guard let data = viewImageData(info: info, includingMeasurements: includesMeasurements) else {
            setStatus("导出失败：画面还没渲染好", autoClearAfter: 8)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            setStatus("已导出当前视图到 \(url.lastPathComponent)")
        } catch {
            setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
        }
    }

    /// 把当前视图放进剪贴板，直接粘到聊天窗口或文档里。
    func copyViewToClipboard() {
        guard let info = viewImageInfo,
              let data = viewImageData(info: info, includingMeasurements: true),
              let image = NSImage(data: data) else {
            setStatus("当前没有可复制的画面")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        setStatus("已复制当前视图（\(image.size.width)×\(image.size.height) 点）")
    }

    private func viewImageData(info: ViewExporter.Info, includingMeasurements: Bool) -> Data? {
        guard let map = canvas.mapImage(includingMeasurements: includingMeasurements),
              let composed = ViewExporter.compose(
                map: map,
                scale: canvas.backingScale,
                info: info
              ) else { return nil }
        return ViewExporter.pngData(composed)
    }

    /// 出图用的数据（调试脚本与菜单共用同一条路径）。
    func viewImageData(includingMeasurements: Bool = true) -> Data? {
        guard let info = viewImageInfo else { return nil }
        return viewImageData(info: info, includingMeasurements: includingMeasurements)
    }

    /// 信息栏内容：现在看的是什么、中心在哪、多大比例、量了几条。
    private var viewImageInfo: ViewExporter.Info? {
        guard hasMapContent else { return nil }
        let hasLocal = selectedSourceName != nil
        let online = onlineBasemap
        var subtitleParts: [String] = []
        if hasLocal, let online {
            subtitleParts.append("叠加 \(online.name)")
        }
        if let online, !online.attribution.isEmpty {
            subtitleParts.append(online.attribution)
        }
        return ViewExporter.Info(
            title: selectedSourceName ?? online?.name ?? basemapName,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            center: viewport.center,
            zoom: viewport.dataZoom,
            metersPerPoint: viewport.metersPerPoint,
            measurementCount: measurements.measurements.count
        )
    }
}
