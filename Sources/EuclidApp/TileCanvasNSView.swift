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
/// 由各图层栈的 `hostLayer` / `overlay.hostLayer` 的 `isGeometryFlipped` 保证一致。
@MainActor
final class TileCanvasNSView: NSView {
    private let overlay = MeasurementOverlay()

    /// 画布底色（影像之外的「桌面」）。
    ///
    /// 单独一层铺在所有瓦片之下，而不是直接给视图图层设 `backgroundColor`：
    /// 这个视图是被 SwiftUI 托管的（`NSViewRepresentable`），实测视图图层自己的底色
    /// 根本不会被画出来（它下面的子图层倒是正常），画布会直接露出窗口底色 ——
    /// 于是深色模式下画布依旧是白的。铺一层自己的底最稳。
    private let backgroundLayer = CALayer()

    /// 图层栈：按 `MapLayer.id` 存放，显示顺序由模型给的图层列表决定（列表末尾在最上层）。
    private var stacks: [String: TileLayerStack] = [:]
    /// 每一层已经装配过的来源签名：只有来源真的变了才重配（改不透明度、调顺序都不重取图）。
    private var stackSignatures: [String: String] = [:]
    /// 当前图层列表（下 → 上）。
    private var layers: [MapLayer] = []

    /// 基准层：测量、存档、相机尺度都以它为准。
    private var anchorLayer: MapLayer? { layers.first { $0.isAnchor } ?? layers.last }
    /// 当前主图层（用来定瓦片边长与层级范围）：优先基准层，否则最上面那层。
    private var primaryStack: TileLayerStack? {
        if let anchor = anchorLayer, let stack = stacks[anchor.id], stack.isActive { return stack }
        return orderedStacks.last { $0.isActive }
    }
    /// 模型顺序（下 → 上）的栈。
    private var orderedStacks: [TileLayerStack] {
        layers.compactMap { stacks[$0.id] }
    }

    private func makeStack() -> TileLayerStack {
        let stack = TileLayerStack()
        stack.needsSync = { [weak self] in self?.syncLayers() }
        stack.refreshGridAppearance(stroke: gridStrokeColor)
        return stack
    }
    /// 适配窗口用的默认范围（数据范围算出来之前 / 在线底图）。
    /// 在线底图的适配范围（没有本地数据时用它对齐窗口）。
    /// 数据集已就位但数据范围还在算：这段时间不铺图（见 `setLocal`）。
    private var awaitingExtent = false
    private var extentRect: CGRect?
    private var zoomBounds: ClosedRange<Double> = 0...30
    private var trackingArea: NSTrackingArea?
    /// 相机是否已经被放到过一个有意义的视野（用户平移缩放、或按数据范围适配过）。
    /// 用它区分「首次打开的内容」与「用户自己调好的视野」：前者可以自动适配，后者一律不许动。
    private var viewWasPositioned = false

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
    /// 回车结束测量的键盘监视器（见 `installFinishMonitor`）。
    private var finishMonitor: Any?
    /// 窗口失焦的订阅（见 `viewDidMoveToWindow`）。
    private var resignObserver: (any NSObjectProtocol)?
    /// 平移手势累计但尚未提交的位移（视图点，y 向上）。
    ///
    /// 手势期间只把已有图层整体位移（GPU 合成，不重算瓦片），等位移攒够、手势结束或停顿一下
    /// 才真正改相机并重铺瓦片 —— 与原生地图同一条思路：拖动时不做重活。
    private var panOffset = CGPoint.zero
    /// 累计位移超过这个距离（点）就先提交一次，免得拖出已经预取到的瓦片范围。
    private static let panCommitDistance: CGFloat = 120
    /// 没有手势阶段信息（老式滚轮）时，停顿这么久就提交。
    private static let panFlushDelay = Duration.milliseconds(120)
    private var panFlushTask: Task<Void, Never>?
    /// 手势期间攒着的读数刷新（见 `scheduleReadoutRefresh`）。
    private static let readoutDelay = Duration.milliseconds(120)
    private var readoutTask: Task<Void, Never>?
    private var pendingReadoutPoint: CGPoint?
    /// 手势进行中：期间暂时关掉预取这类后台活，别和拖动抢主线程与磁盘。
    private var isGestureActive = false
    /// 喂给界面的读数更新间隔（秒）：状态栏与检查器不需要每个事件都刷新。
    private static let reportInterval: TimeInterval = 1.0 / 30.0
    private var lastCursorReport = Date.distantPast
    private var lastViewportReport = Date.distantPast
    /// 最近一次汇报的可见瓦片数（平移期间沿用它，瓦片数要等提交后才有新值）。
    private var lastVisibleTiles = 0
    /// 滚轮事件的耗时统计（`EUCLID_TRACE_SCROLL=1`）。
    private var scrollTraceEvents = 0
    private var scrollTraceTotal = 0.0
    private var scrollTraceWorst = 0.0
    private var scrollTraceCommits = 0
    private var scrollTraceLatencyTotal = 0.0
    private var scrollTraceLatencyWorst = 0.0
    /// 本次手势**进行中**发起的取图次数（收尾那一次不算：那是手停下来之后正常要取的）。
    private var gestureTileRequests = 0
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
            syncLayers()
        }
    }

    private var tool: MapTool { measurementStore?.tool ?? .browse }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("地图画布，暂无内容")
        layer?.masksToBounds = true

        // 顺序即层序：底色 → 图层栈（按需插在中间）→ 测量标注。
        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(overlay.hostLayer)
        applyAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        // 视图换窗口时先清掉上一次的订阅，避免重复注册。
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if window == nil {
            removeFinishMonitor()
            // 视图被摘下来（换窗口 / 关窗）时，手势可能正停在半路：把位移落定，别留一个偏移。
            commitPan(finished: true)
        } else {
            installFinishMonitor()
            // 用 block 版观察者并弱引用自己：视图先于窗口销毁也不会留下悬空指针。
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWindowResignKey() }
            }
        }
    }

    /// 窗口失去焦点（⌘Tab、点别的窗口）：手势就算结束了，把位移落定并取回缺的瓦片。
    ///
    /// 不做这一步的话，用户拖到一半切走应用，画布会停在一个「只有图层变换」的状态里 ——
    /// 看上去画面偏着，而且那部分瓦片一直不会被取回来。
    private func handleWindowResignKey() {
        commitPan(finished: true)
        finishPanTrace()
    }

    private func removeFinishMonitor() {
        if let finishMonitor { NSEvent.removeMonitor(finishMonitor) }
        finishMonitor = nil
    }

    /// 回车结束测量：装一个本地键盘监视器，让 ↩ 与右键**完全等效**。
    ///
    /// 光靠 `keyDown` 不够：画布一旦失去第一响应者（点过检查器里的测量行、折叠块、
    /// 缩放控件都会这样），↩ 就落不到画布上，而右键仍然有效 —— 于是「右键能结束、回车没反应」。
    ///
    /// 监视器装在事件派发之前，只在这几种情况下接管：本窗口的草稿非空、工具不是浏览、
    /// 当前第一响应者不是文本输入（输入框里回车是「确认输入」，不能抢）。
    private func installFinishMonitor() {
        guard finishMonitor == nil else { return }
        finishMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.keyCode == 36 || event.keyCode == 76,   // Return / 小键盘 Enter
                  self.tool != .browse,
                  let store = self.measurementStore,
                  !store.draft.isEmpty,
                  !Self.isTypingText(in: self.window) else { return event }
            self.finishDraft()
            return nil      // 已经用它结束了，别再往下传（否则按钮会「哔」一声）
        }
    }

    /// 当前第一响应者是不是文本输入（文本框里回车不能被我方截走）。
    private static func isTypingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        // SwiftUI 的 TextField 背后是 NSTextView（字段编辑器），统一在上一层判断。
        return (responder as? NSView)?.isKind(of: NSTextView.self) ?? false
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

    /// 画布底色：影像之外的「桌面」，跟着外观走（深色下是接近黑的灰）。
    ///
    /// 语义色要按当前有效外观解析：`NSColor.cgColor` 只看「当前绘制外观」，
    /// 在绘制上下文之外拿到的永远是系统外观的那一套，深色模式下画布会留在浅色。
    private var canvasBackgroundColor: CGColor {
        NSColor.underPageBackgroundColor.resolvedCGColor(in: effectiveAppearance)
    }

    /// 瓦片网格线的颜色：同样按当前有效外观解析。
    private var gridStrokeColor: CGColor {
        NSColor.labelColor.withAlphaComponent(0.32).resolvedCGColor(in: effectiveAppearance)
    }

    /// 语义色在每次外观变化时重新取一遍，避免深浅色切换后颜色残留。
    private func applyAppearanceColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.backgroundColor = canvasBackgroundColor
        backgroundLayer.frame = bounds
        for stack in stacks.values { stack.refreshGridAppearance(stroke: gridStrokeColor) }
        overlay.appearance = effectiveAppearance
        CATransaction.commit()
    }

    /// 调试用：当前外观与画布底色（无人值守核对深浅色时看这两个值最直接）。
    var debugAppearanceDescription: String {
        let components = (backgroundLayer.backgroundColor?.components ?? []).map {
            Int((CGFloat($0) * 255).rounded())
        }
        return "外观=\(effectiveAppearance.name.rawValue) 画布底色=\(components)"
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

    /// 世界范围（在线底图的兜底适配目标）。
    ///
    /// 注意 y 的起点：墨卡托裁掉两极后的范围是 `0.1217…0.8783`，
    /// 从 0 起算会让「适配整个世界」把视角整体推到北半球（以前打开在线底图看到的是北纬五十几度）。
    private static let worldRect = CGRect(
        x: 0,
        y: WebMercator.normalizedY(latitude: WebMercator.maxLatitude),
        width: 1,
        // 高度必须为正：y 向南递增，所以南边界减北边界。
        height: WebMercator.normalizedY(latitude: -WebMercator.maxLatitude)
            - WebMercator.normalizedY(latitude: WebMercator.maxLatitude)
    )

    /// 按图层列表装配画布。列表顺序就是显示顺序（末尾在最上层）。
    ///
    /// - Parameter focus: 需要「适配窗口」的范围；只有第一次出现内容时才会用它自动适配，
    ///   之后一律保持用户当前的视野（开关图层不该改变视口）。
    func setLayers(_ newLayers: [MapLayer], focus: CGRect?) {
        let hadContent = !stacks.isEmpty
        let previousScale = camera.groundMetersPerPoint
        layers = newLayers

        // 删掉不再需要的层
        for (id, stack) in stacks where !newLayers.contains(where: { $0.id == id }) {
            stack.clear()
            stack.hostLayer.removeFromSuperlayer()
            stacks[id] = nil
            stackSignatures[id] = nil
        }

        // 装配或更新每一层
        for layer in newLayers {
            let stack = stacks[layer.id] ?? makeStack()
            if stacks[layer.id] == nil {
                stacks[layer.id] = stack
                layer_hostAdd(stack)
            }
            if stackSignatures[layer.id] != layer.sourceKey {
                stack.configure(
                    source: layer.source,
                    name: layer.name,
                    tileSize: layer.tileSize,
                    zoomRange: layer.zoomRange,
                    followsDisplayScale: layer.followsDisplayScale,
                    maximumDataZoom: layer.maximumDataZoom,
                    memoryLimitBytes: layer.memoryLimitBytes,
                    maxConcurrentRequests: layer.maxConcurrentRequests
                )
                stackSignatures[layer.id] = layer.sourceKey
            }
            stack.opacity = layer.isVisible ? layer.opacity : 0
            stack.hostLayer.isHidden = !layer.isVisible
        }

        // 层序：按列表重新挂一遍（下 → 上），始终在测量标注之下
        for layer in newLayers {
            guard let stack = stacks[layer.id] else { continue }
            stack.hostLayer.removeFromSuperlayer()
            layer_hostAdd(stack)
        }

        // 本地数据集的范围还没算出来时先不铺图：此时相机只能停在数据之外，
        // 铺出来只会是一屏空占位并白读磁盘（范围一到画面还要整体跳一次）。
        awaitingExtent = layers.contains { $0.kind == .dataset && $0.fitRect == nil }

        updateAccessibilityLabel()
        let focusRect = focus ?? anchorLayer?.fitRect
        if hadContent {
            // 已经有内容在看：保持当前视野，只把图层换了。
            refreshCamera(fitRect: nil, defaultZoomLevel: nil)
            restoreGroundScale(previousScale, when: true)
        } else {
            refreshCamera(fitRect: focusRect, defaultZoomLevel: focusRect == nil ? 2 : nil)
        }
        syncLayers()
    }

    /// 相机是否已经被放到过一个有意义的视野（用户平移缩放、或按范围适配过）。
    /// 用它区分「首次出现的内容」与「用户调好的视野」：前者可以自动适配，后者一律不许动。
    private func markViewPositioned() { viewWasPositioned = true }

    /// 重配图层之后把地面比例套回去（`condition` 为假时不动，让首次适配生效）。
    private func restoreGroundScale(_ scale: Double, when condition: Bool) {
        guard condition, scale > 0, scale.isFinite else { return }
        camera = camera.settingGroundMetersPerPoint(scale).clamped(zoomLevelRange: zoomBounds)
    }

    /// 把图层栈插到测量标注之下。
    private func layer_hostAdd(_ stack: TileLayerStack) {
        layer?.insertSublayer(stack.hostLayer, below: overlay.hostLayer)
    }

    /// 依据当前激活的图层重配相机（瓦片边长、缩放上下限，以及可选的窗口适配）。
    private func refreshCamera(fitRect: CGRect?, defaultZoomLevel: Double?) {
        camera.displayScale = displayScale
        camera.viewportSize = bounds.size
        // 相机里的瓦片边长跟着主图层走：本地影像按设备像素 1:1，在线才按地图约定。
        let primary = primaryStack
        camera.tilePixelSize = primary.map { $0.cameraTileSize(displayScale: displayScale) } ?? 512

        let rect = fitRect ?? (primaryStack != nil ? layers.first(where: { $0.isAnchor })?.fitRect : nil)
        let fitCamera = rect.map {
            MapCamera.fitting(
                $0,
                viewportSize: bounds.size,
                padding: 28,
                tilePixelSize: camera.tilePixelSize,
                displayScale: camera.displayScale
            )
        } ?? camera.settingZoomLevel(defaultZoomLevel ?? camera.zoomLevel)

        // 上下限取两层（多图层后是全部图层）的并集：更深的源决定能放多大，浅的那层靠祖先贴图兜底。
        // 没有图层时给一个宽松范围，免得算成空区间（`ClosedRange` 会直接崩）。
        var upper = 26.0
        var hasActive = false
        for stack in stacks.values where stack.isActive {
            upper = hasActive ? max(upper, stack.zoomLevelRange.upperBound) : stack.zoomLevelRange.upperBound
            hasActive = true
        }
        // 只有「真的要重新适配视野」时才按适配层级算下限；否则沿用原下限（否则每开关一次底图，
        // 能缩小的范围就被当前相机重新收紧一次，看起来就像视野被改动了）。
        let lower = rect == nil
            ? min(zoomBounds.lowerBound, upper - 0.001)
            : min(max(-2, fitCamera.zoomLevel - 1.2), upper - 0.001)
        zoomBounds = lower...upper
        camera = fitCamera.clamped(zoomLevelRange: zoomBounds)
    }

    /// 画布是自绘的，给读屏一个可读的名字与当前层级。
    private func updateAccessibilityLabel() {
        let name = anchorLayer?.name ?? orderedStacks.last?.name ?? ""
        let layerCount = orderedStacks.filter(\.isActive).count
        guard !name.isEmpty else {
            setAccessibilityLabel("地图画布，暂无内容")
            setAccessibilityValue(nil)
            return
        }
        setAccessibilityLabel("地图画布：\(name)" + (layerCount > 1 ? "（\(layerCount) 个图层）" : ""))
        setAccessibilityValue("z\(currentDataZoom)")
    }

    /// 本地数据范围算好之后对齐窗口（只影响本地层，不打断已经铺好的其他层）。
    func setExtent(_ extent: DatasetExtent?) {
        guard layers.contains(where: { $0.kind == .dataset }) else { return }
        awaitingExtent = false
        extentRect = extent?.worldRect
        // 范围算失败（nil）也要同步一次，让画面退回默认视图，而不是一直空着。
        guard let extent else {
            syncLayers()
            return
        }
        markViewPositioned()
        refreshCamera(fitRect: extent.worldRect, defaultZoomLevel: nil)
        syncLayers()
    }

    /// 适配窗口：优先本地数据范围，其次在线底图范围。
    func fitToData() {
        markViewPositioned()
        guard orderedStacks.contains(where: { $0.isActive }) else { return }
        guard !awaitingExtent || extentRect != nil else { return }
        let rect = anchorLayer?.fitRect ?? extentRect ?? layers.last(where: { $0.fitRect != nil })?.fitRect ?? Self.worldRect
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
        markViewPositioned()
        camera = camera.fitting(rect, padding: padding).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    /// 把相机移动到指定地理坐标（保持当前层级）。
    func goTo(_ coordinate: GeoCoordinate) {
        markViewPositioned()
        camera.center = WebMercator.normalized(coordinate)
        camera = camera.clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    /// 把指针当前位置记成一个点（快捷键 P，与「点坐标」工具共用同一份数据）。
    ///
    /// 指针坐标优先取实时读数；还没移动过指针时按最后一次已知位置换算，
    /// 因此「把鼠标放到目标上、按 P」一定落在你看到的位置。
    @discardableResult
    func dropPointAtCursor() -> GeoMeasurement? {
        guard let store = measurementStore else { return nil }
        // 优先用实时读数；指针不在画布上时退回「最后位置」，再退回视图中心。
        let coordinate: GeoCoordinate
        if let cursor = store.cursorInfo?.coordinate {
            coordinate = cursor
        } else if let point = lastPointerPoint {
            coordinate = camera.coordinate(forViewPoint: point)
        } else {
            coordinate = WebMercator.coordinate(fromNormalized: camera.center)
        }
        let measurement = store.dropPoint(at: coordinate)
        refreshOverlay()
        return measurement
    }

    // MARK: - 缩放控制

    func zoomIn(anchor: CGPoint? = nil) {
        markViewPositioned()
        camera = camera.zoomed(by: 1.6, anchorViewPoint: anchor, zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func zoomOut(anchor: CGPoint? = nil) {
        markViewPositioned()
        camera = camera.zoomed(by: 1 / 1.6, anchorViewPoint: anchor, zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func zoomToActualSize() {
        markViewPositioned()
        guard let primary = primaryStack else { return }
        camera = camera.settingZoomLevel(
            primary.maximumDataZoom,
            zoomLevelRange: zoomBounds
        )
        syncLayers()
    }

    var currentZoomLevel: Double { camera.zoomLevel }

    /// 当前视图对应的经纬度范围，供「按当前视图下载」使用。
    func visibleGeoBounds() -> GeoBounds {
        GeoBounds(normalizedRect: camera.visibleWorldRect)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size
        camera = camera.clamped(zoomLevelRange: zoomBounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        for stack in stacks.values { stack.hostLayer.frame = bounds }
        CATransaction.commit()
        syncLayers()
    }

    /// 当前屏幕的设备像素比。
    private var displayScale: Double { Double(window?.backingScaleFactor ?? 2) }

    private func updateContentsScale() {
        let scale = displayScale
        // 设备像素比参与缩放层级换算：换到 Retina / 外接屏时瓦片仍是 1:1 对应设备像素。
        let previous = camera.tilePixelSize
        camera.displayScale = scale
        refreshCamera(fitRect: nil, defaultZoomLevel: nil)
        if abs(previous - camera.tilePixelSize) > 0.001 {
            let zoom = camera.zoomLevel
            camera = camera.settingZoomLevel(zoom).clamped(zoomLevelRange: zoomBounds)
        }
        for stack in stacks.values { stack.setContentsScale(CGFloat(scale)) }
        overlay.setContentsScale(CGFloat(scale))
        refreshOverlay()
        syncLayers()
    }

    /// 当前主图层（上层）正在渲染的整数层级。
    private var currentDataZoom: Int {
        guard let primary = primaryStack else { return 0 }
        return primary.dataZoom(for: camera)
    }

    /// 把两条图层都同步一遍：下层先铺，上层后铺，叠加顺序天然正确。
    private func syncLayers() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size
        for stack in stacks.values { stack.updateSortCenter(camera.center) }
        // 手势进行中（或刚提交的这一刻仍在拖）先不做预取：别跟用户的手抢磁盘与网络。
        for stack in stacks.values { stack.defersBackgroundWork = isGestureActive }
        // 手势期间只挪图层、不取图；手停下来那一次才真正把缺的瓦片取回来。
        let loadsTiles = !isGestureActive

        let activeStacks = orderedStacks.filter { $0.isActive }
        guard !activeStacks.isEmpty, !awaitingExtent else {
            for stack in stacks.values {
                _ = stack.sync(
                    camera: camera, viewportSize: bounds.size,
                    displayScale: displayScale, showGrid: false, loadsTiles: loadsTiles
                )
            }
            refreshOverlay()
            reportTileStats(loadedTiles: 0, missingTiles: 0, loadsTiles: loadsTiles)
            reportViewport(visibleTiles: 0)
            return
        }

        // 网格画在基准层（你正在判读的那份瓦片）上。
        let gridOwner = anchorLayer.flatMap { stacks[$0.id] } ?? activeStacks.last!
        var frames: [TileLayerFrame] = []
        var visibleTiles = 0
        var loadedTiles = 0
        var missingTiles = 0
        for stack in orderedStacks where stack.isActive {
            let frame = stack.sync(
                camera: camera,
                viewportSize: bounds.size,
                displayScale: displayScale,
                showGrid: showTileGrid && stack === gridOwner,
                loadsTiles: loadsTiles
            )
            if let frame {
                frames.append(frame)
                visibleTiles = max(visibleTiles, frame.needed)
                loadedTiles += frame.loaded
                missingTiles += frame.missing
            }
        }

        refreshOverlay()
        for frame in frames { Self.traceView(layer: frame, camera: camera, zoomBounds: zoomBounds) }
        reportTileStats(loadedTiles: loadedTiles, missingTiles: missingTiles, loadsTiles: loadsTiles)
        reportViewport(visibleTiles: visibleTiles)
        setAccessibilityValue("z\(currentDataZoom)")
    }

    /// 瓦片读数是给状态栏看的，手势期间它本来也没在变，别白刷一次界面。
    private func reportTileStats(loadedTiles: Int, missingTiles: Int, loadsTiles: Bool) {
        guard loadsTiles else { return }
        onTileStatsChanged?(loadedTiles, missingTiles)
    }

    /// 把当前视图状态汇报给界面（状态栏、检查器）。
    ///
    /// 中心坐标用「有效相机」：手势期间还没提交的位移也算进去，读数才不会滞后一个提交周期。
    private func reportViewport(visibleTiles: Int) {
        lastVisibleTiles = visibleTiles
        let camera = effectiveCamera
        onViewportChanged?(ViewportSnapshot(
            zoomLevel: camera.zoomLevel,
            dataZoom: currentDataZoom,
            center: WebMercator.coordinate(fromNormalized: camera.center),
            metersPerPoint: camera.groundMetersPerPoint,
            visibleTiles: visibleTiles
        ))
    }

    /// 调试用：`EUCLID_TRACE_VIEW=1` 时把每次渲染的关键数字打到 stderr。
    static func traceView(layer: TileLayerFrame, camera: MapCamera, zoomBounds: ClosedRange<Double>) {
        guard ProcessInfo.processInfo.environment["EUCLID_TRACE_VIEW"] != nil else { return }
        var line = String(
            format: "[view] %@ z=%.2f 层级=%d 范围=%.2f…%.2f 需要=%d 已载入=%d 祖先兜底=%d 缺片=%d 瓦片边长=%.0fpt 中心=(%.5f,%.5f)",
            layer.name, camera.zoomLevel, layer.zoom,
            zoomBounds.lowerBound, zoomBounds.upperBound,
            layer.needed, layer.loaded, layer.fallback, layer.missing,
            layer.tileDisplaySize, camera.center.x, camera.center.y
        )
        if layer.datumOffsetMeters != .zero {
            line += String(
                format: " 基准偏移=(东 %.0fm, 北 %.0fm)",
                layer.datumOffsetMeters.x, layer.datumOffsetMeters.y
            )
        }
        line += "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    func writeDebugSnapshot(index: Int) {
        guard let directory = ProcessInfo.processInfo.environment["EUCLID_DEBUG_SNAPSHOT"] else { return }
        guard let image = renderMapImage() else { return }
        let url = URL(fileURLWithPath: directory)
            .appending(path: String(format: "frame-%02d.png", index))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// 当前画布的设备像素比（导出图片时用来定字号与线宽）。
    var backingScale: CGFloat { CGFloat(displayScale) }

    /// 把当前画面离屏渲染成位图：瓦片、网格与测量标注都在里面，
    /// 不含 SwiftUI 那几块浮在画布上的控件（缩放按钮、比例尺、提示条）。
    ///
    /// - Parameter includingMeasurements: 导出干净的画面时可以关掉测量标注；
    ///   调试用的瓦片网格永远不进导出图（那是排查用的，不该出现在成图里）。
    func renderMapImage(includingMeasurements: Bool = true) -> CGImage? {
        renderMapImage(scale: CGFloat(displayScale), includingMeasurements: includingMeasurements)
    }

    private func renderMapImage(scale: CGFloat, includingMeasurements: Bool = true) -> CGImage? {
        guard bounds.width > 1, bounds.height > 1,
              scale > 0 else { return nil }
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // CALayer 的几何是 y 向下，位图上下文是 y 向上，这里翻回来。
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let overlayWasHidden = overlay.hostLayer.isHidden
        let gridStates = stacks.values.map { $0.gridLayer.isHidden }
        overlay.hostLayer.isHidden = !includingMeasurements
        for stack in stacks.values { stack.gridLayer.isHidden = true }
        let rendered: CGImage? = overlay.withLabelsUprightForOffscreenRender {
            layer?.render(in: context)
            return context.makeImage()
        }
        overlay.hostLayer.isHidden = overlayWasHidden
        for (index, stack) in stacks.values.enumerated() where index < gridStates.count {
            stack.gridLayer.isHidden = gridStates[index]
        }
        return rendered
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
        commitPan()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point

        // ⌃+左键在 macOS 上与右键等价：同样用来结束当前测量（不落点）。
        if event.modifierFlags.contains(.control), tool != .browse {
            finishDraft()
            return
        }

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

    /// 右键：结束当前这测量。
    ///
    /// 与双击 / 回车同一套口径：点数够就落成测量，不够就丢掉草稿；
    /// 没有草稿时交回默认处理（画布上没有右键菜单，等于什么也不做）。
    override func rightMouseDown(with event: NSEvent) {
        guard tool != .browse, let store = measurementStore, !store.draft.isEmpty else {
            super.rightMouseDown(with: event)
            return
        }
        finishDraft()
    }

    /// 收尾当前草稿（右键 / ⌃+左键共用）。
    private func finishDraft() {
        dragStartPoint = nil
        pendingClickPoint = nil
        dragTarget = nil
        measurementStore?.finishDraft()
        refreshOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        let started = CFAbsoluteTimeGetCurrent()
        defer { tracePan(startedAt: started, timestamp: event.timestamp) }
        markViewPositioned()
        let point = convert(event.locationInWindow, from: nil)
        switch dragTarget {
        case .vertex(let measurementID, let index):
            let coordinate = commitCoordinate(for: point, event: event, skipVertexSnap: true)
            measurementStore?.moveVertex(measurementID: measurementID, index: index, to: coordinate)
            measurementStore?.liveCoordinate = nil
            refreshOverlay()
            reportCursor(point)

        case .pan:
            // 与双指滚动同一条快路径：拖动期间只位移图层，松手（或位移攒够）才重铺瓦片。
            if let last = dragLastPoint {
                let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
                panBy(delta, finished: false)
            }
            dragLastPoint = point
            updateLiveCoordinate(point)
            scheduleReadoutRefresh(for: point)

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 左键拖动平移走的是「手势期间只位移、松手才重铺」的快路径，这里收尾。
        if case .pan = dragTarget { commitPan(finished: true) }
        finishPanTrace()
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
        markViewPositioned()
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
        lastPointerPoint = point
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

    /// 指针在画布里的最后位置（快捷键落点用；鼠标移出画布后仍然有效）。
    private var lastPointerPoint: CGPoint?

    private func updateLiveCoordinate(_ point: CGPoint) {
        guard let store = measurementStore, tool != .browse, !store.draft.isEmpty else { return }
        store.liveCoordinate = effectiveCamera.coordinate(forViewPoint: point)
    }

    /// 指针悬停到顶点时高亮，提示这里可以拖动。
    private func updateHover(at point: CGPoint) {
        let hit = hitTestVertex(at: point)
        let changed = hit?.measurementID != hoveredVertex?.measurementID || hit?.index != hoveredVertex?.index
        guard changed else { return }
        hoveredVertex = hit
        refreshOverlay()
    }

    /// 把指针坐标汇报给界面。
    ///
    /// 限到 30 Hz：触摸板一次拖动会生成上百个事件，每个都去改 SwiftUI 状态的话，
    /// 主线程大半时间花在检查器与状态栏的重绘上，画面自然就不跟手了。
    private func reportCursor(_ point: CGPoint, force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastCursorReport) < Self.reportInterval { return }
        lastCursorReport = now
        guard let store = measurementStore else { return }
        let coordinate = effectiveCamera.coordinate(forViewPoint: point)
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

    /// 平移期间只刷新读数（可见瓦片数等要等提交后才有新值）。
    private func reportViewportThrottled(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastViewportReport) < Self.reportInterval { return }
        lastViewportReport = now
        reportViewport(visibleTiles: lastVisibleTiles)
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
        effectiveCamera.viewPoint(forWorldPoint: WebMercator.normalized(coordinate))
    }

    /// 鼠标滚轮缩放，触摸板双指滚动平移。
    ///
    /// - 普通鼠标滚轮（`hasPreciseScrollingDeltas == false`）：每个滚动量按指数缩放，锚点跟随指针；
    /// - 触摸板双指滚动：平移，按住 ⌘ 时改为缩放；
    /// - 触摸板捏合走 `magnify(with:)`，双击走 `smartMagnify(with:)`。
    override func scrollWheel(with event: NSEvent) {
        let started = CFAbsoluteTimeGetCurrent()
        defer { traceScroll(startedAt: started, event: event) }
        markViewPositioned()
        let point = convert(event.locationInWindow, from: nil)
        let precise = event.hasPreciseScrollingDeltas
        let wantsZoom = !precise || event.modifierFlags.contains(.command)

        if wantsZoom {
            commitPan()
            let steps = precise ? event.scrollingDeltaY / 20 : event.scrollingDeltaY
            guard abs(steps) > 0.0001 else { return }
            let factor = Foundation.exp(steps * Self.wheelZoomStep)
            camera = camera.zoomed(by: factor, anchorViewPoint: point, zoomLevelRange: zoomBounds)
            updateLiveCoordinate(point)
            reportCursor(point)
            // 缩放必须重铺瓦片（层级或尺寸变了），但手势进行中不做预取这类后台活。
            // 注意：普通鼠标滚轮没有阶段信息（`.none`），不能当成「手势进行中」，
            // 否则它永远不会去取新层级的瓦片。
            isGestureActive = event.phase == .began || event.phase == .changed || event.phase == .stationary
            syncLayers()
        } else {
            let delta = CGPoint(x: event.scrollingDeltaX, y: -event.scrollingDeltaY)
            if Self.usesDirectPan {
                // 对照用：老的「每个事件都重铺瓦片」路径，便于量化快路径的收益。
                camera = camera.translated(byViewDelta: delta).clamped(zoomLevelRange: zoomBounds)
                syncLayers()
            } else {
                let finished = event.phase == .ended || event.phase == .cancelled
                    || event.momentumPhase == .ended
                panBy(delta, finished: finished)
            }
            // 手势期间**不**逐个事件喂 SwiftUI 状态：坐标读数与视图读数攒到「手停一下」再刷。
            // 这是拖动卡顿的主因（实测：每个事件都刷时输入延迟 25 ms、事件掉到 1/4；
            // 手势期间不刷则 3.5 ms、事件全到）。`EUCLID_PAN_NO_REPORT=1` 可完全关掉读数刷新对照。
            if ProcessInfo.processInfo.environment["EUCLID_PAN_NO_REPORT"] == nil {
                scheduleReadoutRefresh(for: point)
            }
        }
    }

    /// `EUCLID_PAN_DIRECT=1` 时走「每个滚轮事件都重铺瓦片」的老路径（只用于对照测量）。
    private static let usesDirectPan = ProcessInfo.processInfo.environment["EUCLID_PAN_DIRECT"] != nil

    // MARK: - 平移的手势快路径

    /// 手势期间：只累计位移并把已有图层整体挪一挪，不重铺瓦片。
    private func panBy(_ delta: CGPoint, finished: Bool) {
        // 手势的第一步：把取图计数清零，用来核对「手势进行中一片都没取」。
        if panOffset == .zero { TileLayerStack.resetTileRequestCount() }
        panOffset.x += delta.x
        panOffset.y += delta.y
        applyPanTransform()
        isGestureActive = true

        if finished || hypot(panOffset.x, panOffset.y) >= Self.panCommitDistance {
            commitPan(finished: finished)
        } else {
            schedulePanFlush()
        }
    }

    /// 把待提交的位移写到图层变换上（合成交给窗口服务器，主线程只改一个数值）。
    private func applyPanTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = CATransform3DMakeTranslation(panOffset.x, panOffset.y, 0)
        for stack in stacks.values { stack.hostLayer.transform = transform }
        overlay.hostLayer.transform = transform
        CATransaction.commit()
    }

    /// 老式滚轮没有手势阶段：停顿一小会儿就提交。
    private func schedulePanFlush() {
        guard panFlushTask == nil else { return }
        panFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.panFlushDelay)
            guard let self else { return }
            self.panFlushTask = nil
            self.commitPan(finished: true)
        }
    }

    /// 手势期间攒着的读数刷新：手停下来（或提交）时再刷一次坐标与视图读数。
    ///
    /// 手感来自画面跟不跟手，坐标读数差几十毫秒完全看不出来；
    /// 而每来一个滚轮事件就去改 SwiftUI 状态，会把主线程压在检查器与状态栏的重绘上 ——
    /// 实测这是双指拖动卡顿的主因。
    private func scheduleReadoutRefresh(for point: CGPoint) {
        pendingReadoutPoint = point
        guard readoutTask == nil else { return }
        readoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readoutDelay)
            guard let self else { return }
            self.readoutTask = nil
            if let point = self.pendingReadoutPoint {
                self.pendingReadoutPoint = nil
                self.updateLiveCoordinate(point)
                self.reportCursor(point, force: true)
            }
            self.reportViewportThrottled(force: true)
        }
    }

    /// 提交：把累计位移交给相机，再把图层变换清掉（一进一出，画面不动），然后重铺瓦片。
    private func commitPan(finished: Bool = true) {
        panFlushTask?.cancel()
        panFlushTask = nil
        // 中途按下位移阈值提交时仍然算「手势进行中」：只挪图层，不取图。
        isGestureActive = !finished
        guard panOffset != .zero else { return }
        let offset = panOffset
        panOffset = .zero
        camera = camera.translated(byViewDelta: offset).clamped(zoomLevelRange: zoomBounds)
        applyPanTransform()          // 现在是单位变换
        if finished { gestureTileRequests = TileLayerStack.tileRequestCount }
        syncLayers()
        scrollTraceCommits += 1
        // 手势真的结束了才把读数刷一次；中途按位移阈值提交时继续攒着，别打断手感。
        guard finished else { return }
        readoutTask?.cancel()
        readoutTask = nil
        if let point = pendingReadoutPoint {
            pendingReadoutPoint = nil
            updateLiveCoordinate(point)
            reportCursor(point, force: true)
        }
        reportViewportThrottled(force: true)
    }

    /// 手势期间的「有效相机」：把还没提交的位移算进去，读数与命中判定才不会滞后。
    private var effectiveCamera: MapCamera {
        panOffset == .zero ? camera : camera.translated(byViewDelta: panOffset)
    }

    /// 滚轮事件的耗时统计：`EUCLID_TRACE_SCROLL=1` 时手势结束打一行。
    private func traceScroll(startedAt: CFTimeInterval, event: NSEvent) {
        let finished = event.phase == .ended || event.momentumPhase == .ended
        tracePan(startedAt: startedAt, timestamp: event.timestamp)
        if finished { finishPanTrace() }
    }

    /// 记一次平移事件的处理耗时与输入延迟。
    func tracePan(startedAt: CFTimeInterval, timestamp: TimeInterval) {
        guard ProcessInfo.processInfo.environment["EUCLID_TRACE_SCROLL"] != nil else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        // 事件从「发出」到「被处理」之间的延迟：主线程越忙，这个数越大（也是掉帧的直接体感）。
        // `NSEvent.timestamp` 是「开机以来的秒数」，与 `systemUptime` 同一基准。
        let now = ProcessInfo.processInfo.systemUptime
        let latency = timestamp > 0 && now > timestamp
            ? (now - timestamp) * 1000
            : 0
        scrollTraceEvents += 1
        scrollTraceTotal += elapsed
        scrollTraceWorst = max(scrollTraceWorst, elapsed)
        scrollTraceLatencyTotal += latency
        scrollTraceLatencyWorst = max(scrollTraceLatencyWorst, latency)
    }

    /// 手势结束：把统计打出来并清零。
    func finishPanTrace() {
        guard ProcessInfo.processInfo.environment["EUCLID_TRACE_SCROLL"] != nil,
              scrollTraceEvents > 0 else { return }
        let average = scrollTraceEvents > 0 ? scrollTraceTotal / Double(scrollTraceEvents) : 0
        let latencyAverage = scrollTraceEvents > 0 ? scrollTraceLatencyTotal / Double(scrollTraceEvents) : 0
        let line = String(
            format: "[pan] 事件 %d 次（处理 平均 %.2f ms / 最慢 %.2f ms）· 输入延迟 平均 %.1f ms / 最慢 %.1f ms · 提交 %d 次 · 手势中取图 %d 片\n",
            scrollTraceEvents, average, scrollTraceWorst,
            latencyAverage, scrollTraceLatencyWorst, scrollTraceCommits, gestureTileRequests
        )
        FileHandle.standardError.write(Data(line.utf8))
        TileLayerStack.resetTileRequestCount()
        scrollTraceEvents = 0
        scrollTraceTotal = 0
        scrollTraceWorst = 0
        scrollTraceCommits = 0
        scrollTraceLatencyTotal = 0
        scrollTraceLatencyWorst = 0
        gestureTileRequests = 0
    }

    override func magnify(with event: NSEvent) {
        commitPan()
        markViewPositioned()
        let point = convert(event.locationInWindow, from: nil)
        let factor = 1 + event.magnification
        guard factor > 0.05 else { return }
        camera = camera.zoomed(by: factor, anchorViewPoint: point, zoomLevelRange: zoomBounds)
        updateLiveCoordinate(point)
        reportCursor(point)
        isGestureActive = event.phase != .ended && event.phase != .cancelled
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
                finishDraft()
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
        case "p":
            // 记下指针位置的点：与「点坐标」工具同一份数据，落点后立刻选中，可直接编辑样式。
            dropPointAtCursor()
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
