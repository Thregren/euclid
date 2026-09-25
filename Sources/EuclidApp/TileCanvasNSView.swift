import AppKit
import ImageIO
import QuartzCore
import TileKit

/// 画布向外汇报的视图状态快照。
struct ViewportSnapshot: Sendable {
    var zoomLevel: Double
    var dataZoom: Int
    var center: GeoCoordinate
    var metersPerPoint: Double
    var visibleTiles: Int
}

/// 瓦片画布：每个可见瓦片对应一个 CALayer，由窗口服务器在 GPU 上合成。
///
/// 视图坐标约定：NSView 未翻转，原点在左下、y 向上；图层坐标 y 向下，
/// 由 `tileHostLayer` / `overlay.hostLayer` 的 `isGeometryFlipped` 保证一致。
@MainActor
final class TileCanvasNSView: NSView {
    private let tileHostLayer = CALayer()
    private let gridLayer = CAShapeLayer()
    private let overlay = MeasurementOverlay()

    private var tileLayers: [SlippyTile: CALayer] = [:]
    /// 换层级时保留下来的上一层图层：新图层的图还没到位前由它顶着，避免整屏变灰。
    private var backdropLayers: [SlippyTile: CALayer] = [:]
    /// 当前真正在渲染的层级。
    private var renderedZoom: Int?
    private var tileTasks: [SlippyTile: Task<Void, Never>] = [:]
    /// 每一格当前显示的图片来自哪一块瓦片：自己，或者某个祖先层级。
    private var layerImageSource: [SlippyTile: SlippyTile] = [:]
    /// 正在为哪些格子找祖先贴图（避免重复发起）。
    private var fallbackTasks: Set<SlippyTile> = []
    private var missingTiles: Set<SlippyTile> = []
    /// 已经确认「自己没有图、可回溯的祖先层级也没有图」的格子。
    ///
    /// 少了它，`applyFallbackImages` 的失败分支会一轮接一轮地重新找祖先，
    /// 渲染就变成停不下来的空转：打开数据集时（相机还停在数据之外）每秒能跑两百多轮，
    /// 每轮都要重铺图层、重画标注、把 viewport 重新推给 SwiftUI。
    private var unresolvedTiles: Set<SlippyTile> = []
    /// 已经排队等下一帧补请求的标记，避免同一帧重复调度。
    private var refillScheduled = false
    /// 上一次预取的「层级 + 视野范围」，用来避免重复预取同一圈。
    private var lastPrefetchKey = ""
    /// 单次预取的瓦片上限。
    private static let prefetchLimit = 24

    private var provider: TileProvider?
    private var dataset: TileDataset?
    /// 相机里的瓦片边长基数：本地数据集是瓦片像素边长，在线底图是模板声明的边长。
    private var baseTileSize: Double = 512
    /// 在线底图按「一张瓦片铺满它的像素数」显示，因此相机里的边长要跟着设备像素比走。
    private var tileSizeFollowsDisplayScale = false
    /// 适配窗口用的默认范围（数据范围算出来之前 / 在线底图）。
    private var defaultFitRect: CGRect?
    /// 数据源可用的缩放层级范围（相机上下限）与自身最大层级（「原始比例」用）。
    private var sourceZoomLevelRange: ClosedRange<Double> = -2...26
    private var sourceMaximumZoom: Double = 20
    /// 数据源实际提供的整数层级范围（状态栏层级、瓦片编号用）。
    private var sourceDataZoomRange: ClosedRange<Int> = 0...22
    /// 数据集已就位但数据范围还在算：这段时间不铺图（见 `configure`）。
    private var awaitingExtent = false
    private var extentRect: CGRect?
    private var generation = 0
    private var zoomBounds: ClosedRange<Double> = 0...30
    private var trackingArea: NSTrackingArea?

    private enum DragTarget {
        case pan
        case vertex(measurementID: UUID?, index: Int)
    }

    private var dragTarget: DragTarget?
    private var dragLastPoint: CGPoint?
    private var dragStartPoint: CGPoint?
    private var pendingClickPoint: CGPoint?
    /// 中键拖动平移的上一帧位置（与左键拖动互不干扰）。
    private var middleDragLastPoint: CGPoint?
    /// 当前指针悬停的顶点，用于高亮提示可拖动。
    private var hoveredVertex: (measurementID: UUID?, index: Int)?
    /// 单帧最多渲染的瓦片数量，作为异常情况下的安全阀。
    private let maximumTilesPerFrame = 1200
    /// 同时在途的瓦片请求上限。
    /// Retina 上一个整数层级要多铺 4 倍瓦片，这里相应放宽一点，首屏更快铺满。
    private let maximumConcurrentRequests = 32
    /// 顶点吸附半径（点）。
    private let snapRadius: CGFloat = 12
    /// 点击与拖动位移的区分阈值（点）。
    private let clickTolerance: CGFloat = 4
    /// 鼠标滚轮每一格滚动量的缩放指数（`exp(step * 该系数)`）。
    private static let wheelZoomStep = 0.22

    var camera = MapCamera(
        center: CGPoint(x: 0.5, y: 0.5),
        zoomLevel: 2,
        viewportSize: CGSize(width: 1, height: 1),
        tilePixelSize: 512
    )

    weak var measurementStore: MeasurementStore? {
        didSet {
            window?.invalidateCursorRects(for: self)
            refreshOverlay()
        }
    }

    var onViewportChanged: ((ViewportSnapshot) -> Void)?
    var onTileStatsChanged: ((Int, Int) -> Void)?

    var showTileGrid = false {
        didSet {
            gridLayer.isHidden = !showTileGrid
            syncLayers()
        }
    }

    private var tool: MapTool { measurementStore?.tool ?? .browse }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        tileHostLayer.isGeometryFlipped = true
        tileHostLayer.masksToBounds = true
        layer?.addSublayer(tileHostLayer)

        gridLayer.fillColor = nil
        gridLayer.strokeColor = Self.gridColor.cgColor
        gridLayer.lineWidth = 1
        gridLayer.isHidden = true
        tileHostLayer.addSublayer(gridLayer)

        layer?.addSublayer(overlay.hostLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
        refreshOverlay()
    }

    /// 语义色在每次外观变化时重新取一遍，避免深浅色切换后颜色残留。
    private func applyAppearanceColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        gridLayer.strokeColor = Self.gridColor.cgColor
        CATransaction.commit()
    }

    private static var gridColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.32)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: tool == .browse ? .openHand : .crosshair)
    }

    // MARK: - 数据源

    /// 装配一次数据源所需的全部参数。本地数据集与在线底图都走这一条路径，
    /// 于是「换底图」不影响图层金字塔、兜底与缓存那一整套逻辑。
    private struct SourceSetup {
        var provider: TileProvider?
        /// 相机里的瓦片边长（视图点）。
        var tileSize: Double = 512
        /// 在线底图按「一张瓦片铺满它的像素数」的通用约定显示，相机里的边长要跟着设备像素比走。
        var tileSizeFollowsDisplayScale = false
        /// 可缩放层级范围（真实层级 ± 余量）。
        var zoomLevelRange: ClosedRange<Double> = -2...26
        /// 适配窗口用的世界范围。
        var fitRect: CGRect?
        /// 没有适配范围时的默认层级（在线底图的初始世界视图）。
        var defaultZoomLevel: Double = 2
        /// 数据范围还在算：先不铺图。
        var waitingForExtent = false
        /// 数据源自身的最大层级（「原始比例」用）。
        var maximumDataZoom: Double = 20
        /// 数据源实际提供的整数层级范围。
        var dataZoomRange: ClosedRange<Int> = 0...22
    }

    /// 本地数据集。
    func configure(dataset: TileDataset?, extent: DatasetExtent?) {
        guard let dataset else {
            self.dataset = nil
            applySource(SourceSetup(provider: nil, fitRect: nil))
            return
        }
        self.dataset = dataset
        applySource(SourceSetup(
            provider: TileProvider(source: dataset.source),
            tileSize: Double(dataset.layout.tileSize),
            zoomLevelRange: max(-2, Double(dataset.zoomRange.lowerBound))...min(Double(dataset.zoomRange.upperBound) + 1, 26),
            fitRect: extent?.worldRect,
            defaultZoomLevel: Double(min(dataset.zoomRange.upperBound, dataset.zoomRange.lowerBound + 2)),
            waitingForExtent: extent == nil,
            maximumDataZoom: Double(dataset.zoomRange.upperBound),
            dataZoomRange: dataset.zoomRange
        ))
    }

    /// 在线底图。
    func configure(online basemap: OnlineBasemap, fitRect: CGRect?) {
        dataset = nil
        guard basemap.isValid else {
            applySource(SourceSetup(provider: nil, fitRect: nil))
            return
        }
        applySource(SourceSetup(
            provider: TileProvider(
                source: basemap.makeSource(),
                memoryLimitBytes: 256 * 1024 * 1024,
                maxConcurrentDecodes: 6
            ),
            tileSize: Double(basemap.tileSize),
            tileSizeFollowsDisplayScale: true,
            zoomLevelRange: 0...Double(basemap.zoomRange.upperBound),
            fitRect: fitRect ?? Self.worldRect,
            defaultZoomLevel: 2,
            maximumDataZoom: Double(basemap.zoomRange.upperBound),
            dataZoomRange: basemap.zoomRange
        ))
    }

    /// 世界范围（在线底图的兜底适配目标）。
    private static let worldRect = CGRect(
        x: 0,
        y: 0,
        width: 1,
        height: WebMercator.normalizedY(latitude: WebMercator.maxLatitude)
            - WebMercator.normalizedY(latitude: -WebMercator.maxLatitude)
    )

    private func applySource(_ setup: SourceSetup) {
        generation += 1
        cancelPendingRequests()
        for layer in tileLayers.values { layer.removeFromSuperlayer() }
        tileLayers.removeAll()
        for layer in backdropLayers.values { layer.removeFromSuperlayer() }
        backdropLayers.removeAll()
        renderedZoom = nil
        layerImageSource.removeAll()
        fallbackTasks.removeAll()
        unresolvedTiles.removeAll()
        missingTiles.removeAll()
        awaitingExtent = false
        lastPrefetchKey = ""

        guard let provider = setup.provider else {
            provider = nil
            extentRect = nil
            defaultFitRect = nil
            measurementStore?.cursorInfo = nil
            onTileStatsChanged?(0, 0)
            syncLayers()
            return
        }
        self.provider = provider
        baseTileSize = setup.tileSize
        tileSizeFollowsDisplayScale = setup.tileSizeFollowsDisplayScale
        camera.displayScale = displayScale
        camera.tilePixelSize = cameraTileSize
        camera.viewportSize = bounds.size
        extentRect = setup.fitRect
        defaultFitRect = setup.fitRect
        sourceZoomLevelRange = setup.zoomLevelRange
        sourceMaximumZoom = setup.maximumDataZoom
        sourceDataZoomRange = setup.dataZoomRange

        let fitCamera = setup.fitRect.map {
            MapCamera.fitting(
                $0,
                viewportSize: bounds.size,
                padding: 28,
                tilePixelSize: camera.tilePixelSize,
                displayScale: camera.displayScale
            )
        } ?? camera.settingZoomLevel(setup.defaultZoomLevel)

        zoomBounds = max(-2, fitCamera.zoomLevel - 1.2)...setup.zoomLevelRange.upperBound
        camera = fitCamera.clamped(zoomLevelRange: zoomBounds)
        // 数据范围还没算出来时，相机只能停在数据集之外，此刻铺出来的只会是一屏空占位，
        // 白读磁盘，而且范围一到画面必然整体跳一次。等 `setExtent` 到了再开始铺。
        awaitingExtent = setup.waitingForExtent
        syncLayers()
    }

    func setExtent(_ extent: DatasetExtent?) {
        // 在线底图状态下，本地数据集的范围变化不该打断当前视图。
        guard dataset != nil else { return }
        awaitingExtent = false
        extentRect = extent?.worldRect
        defaultFitRect = extent?.worldRect ?? defaultFitRect
        // 范围算失败（nil）也要同步一次，让画面退回默认视图，而不是一直空着。
        guard let extent else {
            syncLayers()
            return
        }
        let fit = MapCamera.fitting(
            extent.worldRect,
            viewportSize: bounds.size,
            padding: 28,
            tilePixelSize: camera.tilePixelSize,
            displayScale: camera.displayScale
        )
        zoomBounds = max(-2, fit.zoomLevel - 1.2)...sourceZoomLevelRange.upperBound
        camera = fit.clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func fitToData() {
        guard provider != nil, !awaitingExtent || extentRect != nil else { return }
        let rect = extentRect ?? defaultFitRect ?? camera.visibleWorldRect
        camera = MapCamera.fitting(
            rect,
            viewportSize: bounds.size,
            padding: 28,
            tilePixelSize: camera.tilePixelSize,
            displayScale: camera.displayScale
        ).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    /// 缩放到指定的世界范围。
    func fitToWorldRect(_ rect: CGRect, padding: Double = 56) {
        camera = camera.fitting(rect, padding: padding).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    /// 把相机移动到指定地理坐标（保持当前层级）。
    func goTo(_ coordinate: GeoCoordinate) {
        camera.center = WebMercator.normalized(coordinate)
        camera = camera.clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    // MARK: - 缩放控制

    func zoomIn(anchor: CGPoint? = nil) {
        camera = camera.zoomed(by: 1.6, anchorViewPoint: anchor, zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func zoomOut(anchor: CGPoint? = nil) {
        camera = camera.zoomed(by: 1 / 1.6, anchorViewPoint: anchor, zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func zoomToActualSize() {
        guard provider != nil else { return }
        camera = camera.settingZoomLevel(
            sourceMaximumZoom,
            zoomLevelRange: zoomBounds
        )
        syncLayers()
    }

    var currentZoomLevel: Double { camera.zoomLevel }

    /// 当前视图对应的经纬度范围，供「按当前视图下载」使用。
    func visibleGeoBounds() -> GeoBounds {
        GeoBounds(normalizedRect: camera.visibleWorldRect)
    }

    // MARK: - 布局与渲染

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size
        camera = camera.clamped(zoomLevelRange: zoomBounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileHostLayer.frame = bounds
        CATransaction.commit()
        syncLayers()
    }

    /// 当前屏幕的设备像素比。
    private var displayScale: Double { Double(window?.backingScaleFactor ?? 2) }

    /// 相机里的瓦片边长（视图点）。本地数据集按设备像素 1:1；在线底图按通用地图约定，
    /// 一张瓦片铺满它自己的像素数，于是在不屏幕上都有一致的视觉比例尺。
    private var cameraTileSize: Double {
        baseTileSize * (tileSizeFollowsDisplayScale ? displayScale : 1)
    }

    private func updateContentsScale() {
        let scale = displayScale
        // 设备像素比参与缩放层级换算：换到 Retina / 外接屏时瓦片仍是 1:1 对应设备像素。
        if abs(camera.displayScale - scale) > 0.001 || abs(camera.tilePixelSize - cameraTileSize) > 0.001 {
            let zoom = camera.zoomLevel
            camera.displayScale = scale
            camera.tilePixelSize = cameraTileSize
            camera = camera.settingZoomLevel(zoom).clamped(zoomLevelRange: zoomBounds)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tileLayers.values {
            layer.contentsScale = scale
        }
        CATransaction.commit()
        overlay.setContentsScale(scale)
        refreshOverlay()
    }

    private var currentDataZoom: Int {
        let raw = Int(camera.zoomLevel.rounded())
        return min(max(raw, sourceDataZoomRange.lowerBound), sourceDataZoomRange.upperBound)
    }

    private func syncLayers() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size

        guard let provider, !awaitingExtent else {
            renderGrid(zoom: nil)
            refreshOverlay()
            reportViewport(visibleTiles: 0)
            return
        }

        let zoom = currentDataZoom
        guard let columns = camera.tileColumnRange(zoom: zoom),
              let rows = camera.tileRowRange(zoom: zoom) else {
            refreshOverlay()
            reportViewport(visibleTiles: 0)
            return
        }
        let total = columns.count * rows.count
        guard total <= maximumTilesPerFrame else {
            // 超出安全阀时宁可清空，也不要留着上一帧的残影误导判读。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in tileLayers.values { layer.removeFromSuperlayer() }
            tileLayers.removeAll()
            CATransaction.commit()
            refreshOverlay()
            onTileStatsChanged?(0, missingTiles.count)
            reportViewport(visibleTiles: total)
            return
        }

        let tileWorldSize = 1.0 / Double(1 << zoom)
        let tileDisplaySize = CGFloat(camera.pixelsPerWorldUnit * tileWorldSize)
        let scale = window?.backingScaleFactor ?? 2

        var needed = Set<SlippyTile>()
        needed.reserveCapacity(total)
        for row in rows {
            for column in columns {
                needed.insert(SlippyTile(zoom: zoom, x: column, y: row))
            }
        }
        // 「没有图可用」的结论只对还留在屏幕上的格子有效：离开视野就忘掉，转回来再试一次。
        unresolvedTiles.formIntersection(needed)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 层级切换：把上一层的图层整体留作背景层，新图层的图到位前画面不会变空。
        if renderedZoom != zoom {
            for layer in backdropLayers.values { layer.removeFromSuperlayer() }
            backdropLayers = tileLayers
            tileLayers.removeAll()
            layerImageSource.removeAll()
            fallbackTasks.removeAll()
            renderedZoom = zoom
        }

        // 换层级时把即将摘掉的图层图片先接过来，作为新瓦片的**同帧**兜底。
        // 否则新图层会先闪一帧占位色，等磁盘读完才出图 —— 连续缩放时看着就是「一闪一闪」。
        var recycledImages: [SlippyTile: CGImage] = [:]
        for (tile, layer) in tileLayers where !needed.contains(tile) {
            if let image = Self.contentsImage(of: layer) {
                recycledImages[tile] = image
            }
            layer.removeFromSuperlayer()
            tileLayers[tile] = nil
            layerImageSource[tile] = nil
            fallbackTasks.remove(tile)
        }

        for tile in needed {
            let worldX = Double(tile.x) / Double(1 << zoom)
            let worldY = Double(tile.y) / Double(1 << zoom)
            let origin = camera.layerPoint(forWorldPoint: CGPoint(x: worldX, y: worldY))
            let frame = CGRect(
                x: origin.x,
                y: origin.y,
                width: tileDisplaySize,
                height: tileDisplaySize
            )

            let layer: CALayer
            if let existing = tileLayers[tile] {
                layer = existing
            } else {
                layer = CALayer()
                layer.magnificationFilter = .trilinear
                layer.minificationFilter = .trilinear
                layer.contentsGravity = .resize
                layer.contentsScale = scale
                // 新格子一开始是**透明**的：换层级时先让下面保留的上一层图层顶着，
                // 自己的图到了再淡入。这里要是铺一层半透明占位色（而且它还盖在上一层图上），
                // 每跨一次层级整屏就会先蒙上一层灰白纱再恢复 —— 那就是「一闪一闪」。
                tileLayers[tile] = layer
                tileHostLayer.insertSublayer(layer, below: gridLayer)
            }
            if layerImageSource[tile] == nil,
               let ancestor = Self.bestAncestor(of: tile, in: recycledImages),
               let image = recycledImages[ancestor] {
                install(image, in: layer, source: ancestor, for: tile, animated: false)
            }
            layer.frame = frame
        }
        CATransaction.commit()

        requestMissingTiles(needed: needed, provider: provider)
        applyFallbackImages(needed: needed, provider: provider)
        updateBackdropFrames()
        dropBackdropIfSettled(needed: needed)
        renderGrid(zoom: zoom)
        refreshOverlay()
        Self.traceView(camera: camera, zoomBounds: zoomBounds, dataZoom: zoom, needed: needed.count,
                       loaded: layerImageSource.filter { $0.key == $0.value }.count,
                       fallback: layerImageSource.count - layerImageSource.filter { $0.key == $0.value }.count,
                       missing: missingTiles.count,
                       tileDisplaySize: tileDisplaySize)
        reportViewport(visibleTiles: needed.count)
        prefetchSurroundingTiles(needed: needed)
    }

    /// 预取视野外一圈的瓦片，让接下来的平移不必再等磁盘或网络。
    ///
    /// 只在当前视野已经没有待取瓦片时做（不跟首屏抢并发额度），
    /// 并用「层级 + 视野行列范围」当键，视野没动就不重复预取。
    private func prefetchSurroundingTiles(needed: Set<SlippyTile>) {
        guard let provider else { return }
        let settled = needed.allSatisfy { tile in
            layerImageSource[tile] == tile || missingTiles.contains(tile) || unresolvedTiles.contains(tile)
        }
        guard settled else { return }

        let zoom = currentDataZoom
        guard let columns = camera.tileColumnRange(zoom: zoom),
              let rows = camera.tileRowRange(zoom: zoom) else { return }
        let key = "\(zoom):\(columns.lowerBound)-\(columns.upperBound):\(rows.lowerBound)-\(rows.upperBound)"
        guard key != lastPrefetchKey else { return }
        lastPrefetchKey = key

        let maximumIndex = (1 << zoom) - 1
        var ring: [SlippyTile] = []
        for row in (rows.lowerBound - 1)...(rows.upperBound + 1) {
            for column in (columns.lowerBound - 1)...(columns.upperBound + 1) {
                guard (0...maximumIndex).contains(column), (0...maximumIndex).contains(row) else { continue }
                let tile = SlippyTile(zoom: zoom, x: column, y: row)
                guard !needed.contains(tile) else { continue }
                ring.append(tile)
            }
        }
        guard !ring.isEmpty else { return }

        let batch = Array(ring.prefix(Self.prefetchLimit))
        Task.detached(priority: .utility) {
            await provider.prefetch(batch)
        }
    }

    /// 调试用：`EUCLID_TRACE_VIEW=1` 时把每次渲染的关键数字打到 stderr。
    static func traceView(
        camera: MapCamera,
        zoomBounds: ClosedRange<Double>,
        dataZoom: Int,
        needed: Int,
        loaded: Int,
        fallback: Int,
        missing: Int,
        tileDisplaySize: CGFloat
    ) {
        guard ProcessInfo.processInfo.environment["EUCLID_TRACE_VIEW"] != nil else { return }
        let line = String(
            format: "[view] z=%.2f 层级=%d 范围=%.2f…%.2f 需要=%d 已载入=%d 祖先兜底=%d 缺片=%d 瓦片边长=%.0fpt 中心=(%.5f,%.5f)\n",
            camera.zoomLevel, dataZoom, zoomBounds.lowerBound, zoomBounds.upperBound,
            needed, loaded, fallback, missing, tileDisplaySize, camera.center.x, camera.center.y
        )
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// 调试用：把当前画布（瓦片 + 标注）离屏渲染成 PNG，不需要屏幕在前台。
    ///
    /// `EUCLID_DEBUG_SNAPSHOT=<目录>` 时按帧写出 `frame-01.png`、`frame-02.png`…
    /// 用于核对清晰度、换层级时是否出现空白帧。
    func writeDebugSnapshot(index: Int) {
        guard bounds.width > 1, bounds.height > 1,
              let directory = ProcessInfo.processInfo.environment["EUCLID_DEBUG_SNAPSHOT"] else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return }
        context.scaleBy(x: scale, y: scale)
        // CALayer 的几何是 y 向下，位图上下文是 y 向上，这里翻回来。
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer?.render(in: context)
        guard let image = context.makeImage() else { return }
        let url = URL(fileURLWithPath: directory)
            .appending(path: String(format: "frame-%02d.png", index))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func requestMissingTiles(needed: Set<SlippyTile>, provider: TileProvider) {
        let currentGeneration = generation
        let outstanding = tileTasks.count
        // 只按「自己的图还没上屏、没有在途请求、也不是已确认缺片」判断是否要取图。
        // 注意不能只看 `contents == nil`：祖先贴图先顶上时图层也有内容，但自己的图仍要取。
        // 过去这里还记过一个「请求过就不再请求」的集合，结果是图层一旦被移除重建
        // （换个缩放层级就会发生），新图层永远不会再取图，整屏变成空占位。
        var pending: [SlippyTile] = needed.filter { tile in
            layerImageSource[tile] != tile
                && tileTasks[tile] == nil
                && !missingTiles.contains(tile)
        }
        guard !pending.isEmpty else { return }

        // 靠近视图中心的瓦片优先加载。
        let center = camera.center
        let zoom = currentDataZoom
        pending.sort { lhs, rhs in
            distanceSquared(lhs, center: center, zoom: zoom) < distanceSquared(rhs, center: center, zoom: zoom)
        }

        let budget = max(0, maximumConcurrentRequests - outstanding)
        for tile in pending.prefix(budget) {
            tileTasks[tile] = Task { @MainActor [weak self] in
                guard let self else { return }
                let image = await provider.image(for: tile)
                guard self.generation == currentGeneration else { return }
                self.tileTasks[tile] = nil
                guard let image else {
                    if self.missingTiles.count > 50_000 { self.missingTiles.removeAll(keepingCapacity: true) }
                    self.missingTiles.insert(tile)
                    self.publishTileStats()
                    self.scheduleRefill()
                    return
                }
                if let layer = self.tileLayers[tile] {
                    // 首次出现也做一次很短的淡入：瓦片是按解码完成的先后落下来的，
                    // 硬贴上去就是一块块「啪」地跳出来，一屏几十块看着就是闪。
                    self.install(image, in: layer, source: tile, for: tile, animated: true)
                }
                self.publishTileStats()
                // 并发额度腾出来了，把这一帧没排上队的瓦片接着取。
                self.scheduleRefill()
            }
        }
    }

    /// 本轮请求结束后补跑一次同步，避免超出并发额度的瓦片要等到下次交互才加载。
    private func scheduleRefill() {
        guard !refillScheduled else { return }
        refillScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refillScheduled = false
            self.syncLayers()
        }
    }

    // MARK: - 祖先贴图兜底

    /// 背景层跟着相机走，缩放平移时始终保持与当前层级对齐。
    private func updateBackdropFrames() {
        guard !backdropLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (tile, layer) in backdropLayers {
            let count = Double(1 << tile.zoom)
            let size = CGFloat(camera.pixelsPerWorldUnit / count)
            let origin = camera.layerPoint(forWorldPoint: CGPoint(
                x: Double(tile.x) / count,
                y: Double(tile.y) / count
            ))
            layer.frame = CGRect(x: origin.x, y: origin.y, width: size, height: size)
        }
        CATransaction.commit()
    }

    /// 当前层级的每一格都有自己的图（或已确认缺片）之后，背景层就没必要留着了。
    private func dropBackdropIfSettled(needed: Set<SlippyTile>) {
        guard !backdropLayers.isEmpty else { return }
        let settled = needed.allSatisfy { tile in
            layerImageSource[tile] == tile || missingTiles.contains(tile)
        }
        guard settled else { return }

        let retired = backdropLayers
        backdropLayers.removeAll()
        // 自己的图已经盖满时摘掉背景是看不见的；稀疏缺片的格子还露着背景，淡出更自然。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in retired.values {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "backdropFade")
            layer.opacity = 0
        }
        CATransaction.commit()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.25))
            for layer in retired.values { layer.removeFromSuperlayer() }
        }
    }

    /// 祖先层级最多回溯几级。数值越大，稀疏数据越不容易露白，但请求也越多。
    private static let maximumFallbackLevels = 4
    /// 同时在找祖先贴图的格子数量上限，避免一屏几十个空格同时发起请求。
    private static let maximumFallbackLookups = 8

    /// 给还没有图的格子先铺上祖先层级的图（裁到对应子区域）。
    ///
    /// 这是「缩放不闪」的关键：换层级时新图还没到，但父层级的图往往已经在内存缓存里，
    /// 直接按比例铺上去，画面就是连续的；等自己那张图到了再无缝替换。
    private func applyFallbackImages(needed: Set<SlippyTile>, provider: TileProvider) {
        let waiting = needed.filter {
            layerImageSource[$0] == nil
                && !fallbackTasks.contains($0)
                && !unresolvedTiles.contains($0)
        }
        guard !waiting.isEmpty, fallbackTasks.count < Self.maximumFallbackLookups else { return }

        let zoom = currentDataZoom
        let center = camera.center
        let currentGeneration = generation
        let budget = max(0, Self.maximumFallbackLookups - fallbackTasks.count)
        let ordered = waiting.sorted {
            distanceSquared($0, center: center, zoom: zoom) < distanceSquared($1, center: center, zoom: zoom)
        }

        for tile in ordered.prefix(budget) {
            fallbackTasks.insert(tile)
            Task { @MainActor [weak self] in
                let ancestor = await Self.firstAvailableAncestor(of: tile, provider: provider)
                guard let self else { return }
                self.fallbackTasks.remove(tile)
                guard self.generation == currentGeneration else { return }
                guard let found = ancestor else {
                    // 自己也没有、祖先也没有：先记下来，别在下一轮又从头找一遍。
                    // 这里仍然补跑一次同步，是为了让本轮没排上的格子继续找；
                    // 因为候选集合只减不增，这个回路会在几轮内收敛。
                    self.unresolvedTiles.insert(tile)
                    self.scheduleRefill()
                    return
                }
                // 自己的图已经到了就不用兜底了。
                guard self.layerImageSource[tile] != tile,
                      self.layerImageSource[tile] == nil,
                      let layer = self.tileLayers[tile] else { return }
                self.install(found.image, in: layer, source: found.tile, for: tile, animated: true)
                self.publishTileStats()
                self.scheduleRefill()
            }
        }
    }

    /// 从父层级往上找第一张已经能取到的瓦片。
    private static func firstAvailableAncestor(
        of tile: SlippyTile,
        provider: TileProvider
    ) async -> (tile: SlippyTile, image: CGImage)? {
        var level = tile.zoom - 1
        var tries = 0
        while level >= 0, tries < maximumFallbackLevels {
            let shift = tile.zoom - level
            let ancestor = SlippyTile(zoom: level, x: tile.x >> shift, y: tile.y >> shift)
            if let image = await provider.image(for: ancestor) {
                return (ancestor, image)
            }
            level -= 1
            tries += 1
        }
        return nil
    }

    /// 在已有的图片里找最近的祖先层级瓦片（用于同帧兜底，不需要等异步取图）。
    static func bestAncestor(of tile: SlippyTile, in images: [SlippyTile: CGImage]) -> SlippyTile? {
        guard !images.isEmpty else { return nil }
        var level = tile.zoom - 1
        var tries = 0
        while level >= 0, tries < maximumFallbackLevels {
            let shift = tile.zoom - level
            let ancestor = SlippyTile(zoom: level, x: tile.x >> shift, y: tile.y >> shift)
            if images[ancestor] != nil { return ancestor }
            level -= 1
            tries += 1
        }
        return nil
    }

    /// 取出图层里装的图片（`CALayer.contents` 是 `Any?`，用 CFTypeID 判断再取）。
    static func contentsImage(of layer: CALayer) -> CGImage? {
        guard let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    /// 把图片装进格子：来源可能是自己，也可能是祖先（按 `contentsRect` 裁出对应子区域）。
    private func install(
        _ image: CGImage,
        in layer: CALayer,
        source: SlippyTile,
        for tile: SlippyTile,
        animated: Bool
    ) {
        let rect = Self.contentsRect(source: source, destination: tile)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            // 首次出现、以及换图（祖先贴图 → 自己的图）都做一次很短的交叉淡入，
            // 避免整屏几十块瓦片按解码顺序「啪、啪」地跳出来。
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "contentFade")
        }
        layer.contents = image
        layer.contentsRect = rect
        layer.backgroundColor = nil
        layerImageSource[tile] = source
        CATransaction.commit()
    }

    /// 目标瓦片在来源瓦片图片里占的子区域（单位坐标，y 从图片顶部算起）。
    static func contentsRect(source: SlippyTile, destination: SlippyTile) -> CGRect {
        let shift = destination.zoom - source.zoom
        guard shift > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let factor = Double(1 << shift)
        let dx = Double(destination.x - source.x * (1 << shift)) / factor
        let dy = Double(destination.y - source.y * (1 << shift)) / factor
        return CGRect(x: dx, y: dy, width: 1 / factor, height: 1 / factor)
    }

    private func distanceSquared(_ tile: SlippyTile, center: CGPoint, zoom: Int) -> Double {
        let n = Double(1 << zoom)
        let dx = (Double(tile.x) + 0.5) / n - center.x
        let dy = (Double(tile.y) + 0.5) / n - center.y
        return dx * dx + dy * dy
    }

    private func cancelPendingRequests() {
        for task in tileTasks.values { task.cancel() }
        tileTasks.removeAll()
    }

    private func publishTileStats() {
        // 只统计「自己的图已经上屏」的瓦片；祖先贴图兜底的不算已载入。
        let loaded = layerImageSource.filter { $0.key == $0.value }.count
        onTileStatsChanged?(loaded, missingTiles.count)
    }

    private func reportViewport(visibleTiles: Int) {
        onViewportChanged?(ViewportSnapshot(
            zoomLevel: camera.zoomLevel,
            dataZoom: currentDataZoom,
            center: WebMercator.coordinate(fromNormalized: camera.center),
            metersPerPoint: camera.groundMetersPerPoint,
            visibleTiles: visibleTiles
        ))
        publishTileStats()
    }

    private func renderGrid(zoom: Int?) {
        guard showTileGrid, let zoom else {
            gridLayer.path = nil
            return
        }
        guard let columns = camera.tileColumnRange(zoom: zoom),
              let rows = camera.tileRowRange(zoom: zoom) else {
            gridLayer.path = nil
            return
        }
        let tileWorldSize = 1.0 / Double(1 << zoom)
        let size = CGFloat(camera.pixelsPerWorldUnit * tileWorldSize)
        guard size > 4 else {
            gridLayer.path = nil
            return
        }
        let path = CGMutablePath()
        for column in columns {
            let worldX = Double(column) / Double(1 << zoom)
            let viewX = (worldX - camera.center.x) * camera.pixelsPerWorldUnit + bounds.width / 2
            path.move(to: CGPoint(x: viewX, y: 0))
            path.addLine(to: CGPoint(x: viewX, y: bounds.height))
        }
        for row in rows {
            let worldY = Double(row) / Double(1 << zoom)
            let viewTopY = (camera.center.y - worldY) * camera.pixelsPerWorldUnit + bounds.height / 2
            let viewY = bounds.height - viewTopY
            path.move(to: CGPoint(x: 0, y: viewY))
            path.addLine(to: CGPoint(x: bounds.width, y: viewY))
        }
        gridLayer.path = path
    }

    // MARK: - 测量标注

    /// 重新绘制测量标注（外部改动状态后调用）。
    func refreshOverlay() {
        guard let store = measurementStore else {
            overlay.update(
                draft: [],
                draftKind: .distance,
                draftStyle: .standard,
                measurements: [],
                selectedID: nil,
                liveCoordinate: nil,
                hoveredVertex: nil,
                camera: camera,
                showLabels: false
            )
            return
        }
        let hoveredCoordinate = hoveredVertex.flatMap {
            store.vertex(at: $0.index, measurementID: $0.measurementID)
        }
        overlay.update(
            draft: store.draft,
            draftKind: store.draftKind,
            draftStyle: store.pendingStyle,
            measurements: store.measurements,
            selectedID: store.selectedID,
            liveCoordinate: store.liveCoordinate,
            hoveredVertex: hoveredCoordinate,
            camera: camera,
            showLabels: store.showLabels
        )
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point

        if let hit = hitTestVertex(at: point) {
            measurementStore?.markUndoPoint()
            dragTarget = .vertex(measurementID: hit.measurementID, index: hit.index)
            dragLastPoint = point
            NSCursor.closedHand.set()
            return
        }

        if tool == .browse {
            if event.clickCount == 2 {
                if event.modifierFlags.contains(.option) {
                    zoomOut(anchor: point)
                } else {
                    zoomIn(anchor: point)
                }
                dragStartPoint = nil
                return
            }
        } else if event.clickCount == 2 {
            measurementStore?.finishDraft()
            refreshOverlay()
            dragStartPoint = nil
            return
        }

        dragTarget = .pan
        dragLastPoint = point
        if tool != .browse { pendingClickPoint = point }
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch dragTarget {
        case .vertex(let measurementID, let index):
            let coordinate = commitCoordinate(for: point, event: event, skipVertexSnap: true)
            measurementStore?.moveVertex(measurementID: measurementID, index: index, to: coordinate)
            measurementStore?.liveCoordinate = nil
            refreshOverlay()
            reportCursor(point)

        case .pan:
            if let last = dragLastPoint {
                let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
                camera = camera.translated(byViewDelta: delta).clamped(zoomLevelRange: zoomBounds)
            }
            dragLastPoint = point
            updateLiveCoordinate(point)
            reportCursor(point)
            syncLayers()

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pending = pendingClickPoint
        let start = dragStartPoint
        let target = dragTarget

        dragTarget = nil
        dragLastPoint = nil
        dragStartPoint = nil
        pendingClickPoint = nil
        (tool == .browse ? NSCursor.openHand : NSCursor.crosshair).set()
        window?.invalidateCursorRects(for: self)

        if case .vertex = target { return }

        if pending != nil, let start, let store = measurementStore, tool != .browse {
            let moved = hypot(point.x - start.x, point.y - start.y)
            if moved < clickTolerance {
                store.addPoint(commitCoordinate(for: point, event: event, skipVertexSnap: false))
                store.liveCoordinate = nil
                refreshOverlay()
            }
        }
    }

    // MARK: - 中键平移

    /// 鼠标中键：按住拖动即可平移，任何工具下都可用。
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        middleDragLastPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, let last = middleDragLastPoint else {
            super.otherMouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
        camera = camera.translated(byViewDelta: delta).clamped(zoomLevelRange: zoomBounds)
        middleDragLastPoint = point
        updateLiveCoordinate(point)
        reportCursor(point)
        syncLayers()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        middleDragLastPoint = nil
        (tool == .browse ? NSCursor.openHand : NSCursor.crosshair).set()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateLiveCoordinate(point)
        reportCursor(point)
        updateHover(at: point)
        if tool != .browse, measurementStore?.draft.isEmpty == false {
            refreshOverlay()
        }
    }

    override func mouseExited(with event: NSEvent) {
        measurementStore?.cursorInfo = nil
        measurementStore?.liveCoordinate = nil
        hoveredVertex = nil
        refreshOverlay()
    }

    private func updateLiveCoordinate(_ point: CGPoint) {
        guard let store = measurementStore, tool != .browse, !store.draft.isEmpty else { return }
        store.liveCoordinate = camera.coordinate(forViewPoint: point)
    }

    /// 指针悬停到顶点时高亮，提示这里可以拖动。
    private func updateHover(at point: CGPoint) {
        let hit = hitTestVertex(at: point)
        let changed = hit?.measurementID != hoveredVertex?.measurementID || hit?.index != hoveredVertex?.index
        guard changed else { return }
        hoveredVertex = hit
        refreshOverlay()
    }

    private func reportCursor(_ point: CGPoint) {
        guard let store = measurementStore else { return }
        let coordinate = camera.coordinate(forViewPoint: point)
        let zoom = currentDataZoom
        let scale = Double(1 << zoom)
        let world = WebMercator.normalized(coordinate)
        let tileX = min(max(Int(floor(world.x * scale)), 0), (1 << zoom) - 1)
        let tileY = min(max(Int(floor(world.y * scale)), 0), (1 << zoom) - 1)
        store.cursorInfo = CursorInfo(
            coordinate: coordinate,
            zoom: zoom,
            tileX: tileX,
            tileY: tileY,
            pixelX: Int((world.x * scale - Double(tileX)) * camera.tilePixelSize),
            pixelY: Int((world.y * scale - Double(tileY)) * camera.tilePixelSize)
        )
    }

    private func hitTestVertex(at point: CGPoint) -> (measurementID: UUID?, index: Int)? {
        guard let store = measurementStore else { return nil }
        var best: (measurementID: UUID?, index: Int)?
        var bestDistance = snapRadius
        for vertex in store.allVertices {
            let viewPoint = viewPoint(for: vertex.coordinate)
            let distance = hypot(viewPoint.x - point.x, viewPoint.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = (vertex.measurementID, vertex.index)
            }
        }
        return best
    }

    /// 落点坐标：优先吸附到已有顶点，其次按 Shift 约束方向。
    private func commitCoordinate(for point: CGPoint, event: NSEvent, skipVertexSnap: Bool) -> GeoCoordinate {
        let disableSnap = event.modifierFlags.contains(.command)
        if !skipVertexSnap, !disableSnap, let snap = hitTestVertex(at: point) {
            if let coordinate = measurementStore?.vertex(at: snap.index, measurementID: snap.measurementID) {
                return coordinate
            }
        }
        if event.modifierFlags.contains(.shift),
           let last = measurementStore?.draft.last ?? measurementStore?.selectedMeasurement?.points.last {
            return constrainedCoordinate(from: last, to: point)
        }
        return camera.coordinate(forViewPoint: point)
    }

    private func constrainedCoordinate(from origin: GeoCoordinate, to point: CGPoint) -> GeoCoordinate {
        let originPoint = viewPoint(for: origin)
        let dx = point.x - originPoint.x
        let dy = point.y - originPoint.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return camera.coordinate(forViewPoint: point) }
        let step = Double.pi / 4
        let angle = (atan2(Double(dy), Double(dx)) / step).rounded() * step
        let snapped = CGPoint(
            x: originPoint.x + CGFloat(cos(angle)) * length,
            y: originPoint.y + CGFloat(sin(angle)) * length
        )
        return camera.coordinate(forViewPoint: snapped)
    }

    private func viewPoint(for coordinate: GeoCoordinate) -> CGPoint {
        camera.viewPoint(forWorldPoint: WebMercator.normalized(coordinate))
    }

    /// 鼠标滚轮缩放，触摸板双指滚动平移。
    ///
    /// - 普通鼠标滚轮（`hasPreciseScrollingDeltas == false`）：每个滚动量按指数缩放，锚点跟随指针；
    /// - 触摸板双指滚动：平移，按住 ⌘ 时改为缩放；
    /// - 触摸板捏合走 `magnify(with:)`，双击走 `smartMagnify(with:)`。
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let precise = event.hasPreciseScrollingDeltas
        let wantsZoom = !precise || event.modifierFlags.contains(.command)

        if wantsZoom {
            let steps = precise ? event.scrollingDeltaY / 20 : event.scrollingDeltaY
            guard abs(steps) > 0.0001 else { return }
            let factor = Foundation.exp(steps * Self.wheelZoomStep)
            camera = camera.zoomed(by: factor, anchorViewPoint: point, zoomLevelRange: zoomBounds)
        } else {
            let delta = CGPoint(x: event.scrollingDeltaX, y: -event.scrollingDeltaY)
            camera = camera.translated(byViewDelta: delta).clamped(zoomLevelRange: zoomBounds)
        }
        updateLiveCoordinate(point)
        reportCursor(point)
        syncLayers()
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let factor = 1 + event.magnification
        guard factor > 0.05 else { return }
        camera = camera.zoomed(by: factor, anchorViewPoint: point, zoomLevelRange: zoomBounds)
        updateLiveCoordinate(point)
        reportCursor(point)
        syncLayers()
    }

    override func smartMagnify(with event: NSEvent) {
        zoomIn(anchor: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        let panStep: CGFloat = event.modifierFlags.contains(.shift) ? 120 : 40
        if let store = measurementStore {
            switch event.keyCode {
            case 53:   // Esc
                store.cancelDraft()
                refreshOverlay()
                return
            case 51:   // Delete
                store.removeLastDraftPoint()
                refreshOverlay()
                return
            case 36, 76: // Return / Enter
                store.finishDraft()
                refreshOverlay()
                return
            default:
                break
            }
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            measurementStore?.tool = .browse
            window?.invalidateCursorRects(for: self)
        case "c":
            measurementStore?.tool = .point
            window?.invalidateCursorRects(for: self)
        case "d":
            measurementStore?.tool = .distance
            window?.invalidateCursorRects(for: self)
        case "a":
            measurementStore?.tool = .area
            window?.invalidateCursorRects(for: self)
        case "o":
            measurementStore?.tool = .circle
            window?.invalidateCursorRects(for: self)
        case "+", "=":
            zoomIn()
        case "-", "_":
            zoomOut()
        case "0":
            fitToData()
        default:
            switch event.keyCode {
            case 123:
                camera = camera.translated(byViewDelta: CGPoint(x: panStep, y: 0))
                syncLayers()
            case 124:
                camera = camera.translated(byViewDelta: CGPoint(x: -panStep, y: 0))
                syncLayers()
            case 125:
                camera = camera.translated(byViewDelta: CGPoint(x: 0, y: -panStep))
                syncLayers()
            case 126:
                camera = camera.translated(byViewDelta: CGPoint(x: 0, y: panStep))
                syncLayers()
            default:
                super.keyDown(with: event)
            }
        }
    }
}
