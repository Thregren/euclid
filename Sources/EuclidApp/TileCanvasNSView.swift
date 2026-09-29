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
    let overlay = MeasurementOverlay()

    /// 面积显示单位（跟随界面设置，只影响画面上的面积标注文字）。
    var areaUnit: MeasureFormat.AreaUnit = .automatic {
        didSet {
            guard areaUnit != oldValue else { return }
            refreshOverlay()
        }
    }

    /// 画布底色（影像之外的「桌面」）。
    ///
    /// 单独一层铺在所有瓦片之下，而不是直接给视图图层设 `backgroundColor`：
    /// 这个视图是被 SwiftUI 托管的（`NSViewRepresentable`），实测视图图层自己的底色
    /// 根本不会被画出来（它下面的子图层倒是正常），画布会直接露出窗口底色 ——
    /// 于是深色模式下画布依旧是白的。铺一层自己的底最稳。
    let backgroundLayer = CALayer()

    /// 图层栈：按 `MapLayer.id` 存放，显示顺序由模型给的图层列表决定（列表末尾在最上层）。
    var stacks: [String: TileLayerStack] = [:]
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
    var zoomBounds: ClosedRange<Double> = 0...30
    /// 「按适配算出来」的缩放下限（不含铺图预算那一道收紧）。
    ///
    /// 视口尺寸一变就要重算缩放下限，而重算得拿这个「原始下限」当基准 ——
    /// 直接拿收紧后的 `zoomBounds.lowerBound` 重算的话，窗口缩回去下限也松不回来。
    private var zoomLowerBoundFromFit: Double = 0
    private var trackingArea: NSTrackingArea?
    /// 相机是否已经被放到过一个有意义的视野（用户平移缩放、或按数据范围适配过）。
    /// 用它区分「首次打开的内容」与「用户自己调好的视野」：前者可以自动适配，后者一律不许动。
    private var viewWasPositioned = false

    enum DragTarget {
        case pan
        case vertex(measurementID: UUID?, index: Int)
    }

    var dragTarget: DragTarget?
    var dragLastPoint: CGPoint?
    var dragStartPoint: CGPoint?
    var pendingClickPoint: CGPoint?
    /// 中键拖动平移的上一帧位置（与左键拖动互不干扰）。
    var middleDragLastPoint: CGPoint?
    /// 指针在画布里的最后位置（快捷键落点用；鼠标移出画布后仍然有效）。
    /// 输入处理在另一个文件里，故不加 `private`。
    var lastPointerPoint: CGPoint?
    /// 当前指针悬停的顶点，用于高亮提示可拖动。
    var hoveredVertex: (measurementID: UUID?, index: Int)?
    /// 回车结束测量的键盘监视器（见 `installFinishMonitor`）。
    private var finishMonitor: Any?
    /// 退格 / 前向删除时问一句「要删图层吗」（由 AppModel 注入，返回是否删掉了）。
    var onDeleteLayer: (() -> Bool)?
    /// 窗口失焦的订阅（见 `viewDidMoveToWindow`）。
    private var resignObserver: (any NSObjectProtocol)?
    /// 平移手势累计但尚未提交的位移（视图点，y 向上）。
    ///
    /// 手势期间只把已有图层整体位移（GPU 合成，不重算瓦片），等位移攒够、手势结束或停顿一下
    /// 才真正改相机并重铺瓦片 —— 与原生地图同一条思路：拖动时不做重活。
    var panOffset = CGPoint.zero
    /// 累计位移超过这个距离（点）就先提交一次，免得拖出已经预取到的瓦片范围。
    static let panCommitDistance: CGFloat = 120
    /// 没有手势阶段信息（老式滚轮）时，停顿这么久就提交。
    static let panFlushDelay = Duration.milliseconds(120)
    var panFlushTask: Task<Void, Never>?
    /// 手势期间攒着的读数刷新（见 `scheduleReadoutRefresh`）。
    static let readoutDelay = Duration.milliseconds(120)
    var readoutTask: Task<Void, Never>?
    var pendingReadoutPoint: CGPoint?
    /// 手势进行中：期间暂时关掉预取这类后台活，别和拖动抢主线程与磁盘。
    var isGestureActive = false

    /// 现在要不要「只铺图、不取图」。
    ///
    /// 只对**拖窗口改大小**生效：那会儿每个事件都重铺一次，再顺带取图就变成
    /// 「一边拖窗口一边解一屏新图」。拖动视图反过来要照常取图 —— 不取的话手一动边上就白，
    /// 手停下来才一片片补上来，看着就是「边缘一直在加载」；取图本身是异步的，
    /// 每 120 点才提交一次，主线程该干的活（重铺 + 标注）现在都在 0.4 ms 量级。
    var defersTileWork: Bool {
        inLiveResize || (!Self.loadsTilesDuringGesture && isGestureActive)
    }

    /// `EUCLID_PAN_NO_TILES=1` 时回到「手势期间一片都不取」的老口径（只用于对照测量）。
    private static let loadsTilesDuringGesture =
        ProcessInfo.processInfo.environment["EUCLID_PAN_NO_TILES"] == nil

    /// `EUCLID_PAN_DIRECT=1` 时走「每个滚轮事件都重铺瓦片」的老路径（只用于对照测量）。
    static let usesDirectPan = ProcessInfo.processInfo.environment["EUCLID_PAN_DIRECT"] != nil

    /// 调试开关都在这里读一次。
    ///
    /// `ProcessInfo.processInfo.environment` **每读一次都要把整份环境重新拼成一个字典**
    /// （本机实测约 29 µs，是同一件事的上千倍慢于查一个留住的字典）。放在每事件 / 每帧的
    /// 判断里，光这一下就吃掉双指平移每次事件 90 µs 里的五六十微秒，因此统一提前读成常量。
    static let tracesScroll = ProcessInfo.processInfo.environment["EUCLID_TRACE_SCROLL"] != nil
    static let tracesView = ProcessInfo.processInfo.environment["EUCLID_TRACE_VIEW"] != nil
    static let tracesLayers = ProcessInfo.processInfo.environment["EUCLID_TRACE_LAYERS"] != nil
    var lastLayerDump = Date.distantPast
    static let reportsReadoutDuringPan =
        ProcessInfo.processInfo.environment["EUCLID_PAN_NO_REPORT"] == nil
    static let debugSnapshotDirectory = ProcessInfo.processInfo.environment["EUCLID_DEBUG_SNAPSHOT"]
    /// 喂给界面的读数更新间隔（秒）：状态栏与检查器不需要每个事件都刷新。
    static let reportInterval: TimeInterval = 1.0 / 30.0
    var lastCursorReport = Date.distantPast
    var lastViewportReport = Date.distantPast
    /// 最近一次汇报的可见瓦片数（平移期间沿用它，瓦片数要等提交后才有新值）。
    var lastVisibleTiles = 0
    /// 滚轮事件的耗时统计（`EUCLID_TRACE_SCROLL=1`）。
    var scrollTraceEvents = 0
    var scrollTraceTotal = 0.0
    var scrollTraceWorst = 0.0
    var scrollTraceCommits = 0

    /// 「重铺瓦片」的耗时统计（`EUCLID_TRACE_SYNC=1`）：次数、合计与最慢一次。
    /// 瓦片陆续到位时每一轮都会回来重铺，失控时主线程就会一直忙在重铺上，这个计数最直观。
    static let tracesSync = ProcessInfo.processInfo.environment["EUCLID_TRACE_SYNC"] != nil
    var syncTraceCount = 0
    var syncTraceTotal = 0.0
    var syncTraceWorst = 0.0

    /// 取走并清零重铺统计（调试与基准脚本用）。
    func takeSyncTrace() -> (count: Int, total: Double, worst: Double) {
        defer {
            syncTraceCount = 0
            syncTraceTotal = 0
            syncTraceWorst = 0
        }
        return (syncTraceCount, syncTraceTotal, syncTraceWorst)
    }
    var scrollTraceLatencyTotal = 0.0
    var scrollTraceLatencyWorst = 0.0
    /// 本次手势**进行中**发起的取图次数（收尾那一次不算：那是手停下来之后正常要取的）。
    var gestureTileRequests = 0
    /// 顶点吸附半径（点）。
    let snapRadius: CGFloat = 12
    /// 点击与拖动位移的区分阈值（点）。
    let clickTolerance: CGFloat = 4
    /// 鼠标滚轮每一格滚动量的缩放指数（`exp(step * 该系数)`）。
    static let wheelZoomStep = 0.22

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

    var tool: MapTool { measurementStore?.tool ?? .browse }

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
        traceGeometryEvent(window == nil ? "摘出窗口" : "装入窗口")
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
            // 打开窗口后让画布拿住焦点：方向键、V/C/D/A/O、⌘= 这些不用先点一下画布才有反应。
            // 只在「当前没人在用焦点」时抢，免得把键盘焦点从某个输入框上夺走。
            if window?.firstResponder == nil || window?.firstResponder === window {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    guard window.firstResponder == nil || window.firstResponder === window else { return }
                    window.makeFirstResponder(self)
                }
            }
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
            guard let self, event.window === self.window else { return event }
            // 文本框里的回车与退格是「确认输入 / 删除字符」，不能被我方截走。
            guard !Self.isTypingText(in: self.window) else { return event }

            switch event.keyCode {
            case 36, 76:   // Return / 小键盘 Enter：结束当前测量
                guard self.tool != .browse,
                      let store = self.measurementStore,
                      !store.draft.isEmpty else { return event }
                self.finishDraft()
                return nil

            case 51, 117:  // ⌫ / ⌦：画着测量时撤掉刚点的一个点，否则删掉选中的图层
                if self.tool != .browse, let store = self.measurementStore, !store.draft.isEmpty {
                    store.removeLastDraftPoint()
                    self.refreshOverlay()
                    return nil
                }
                if self.onDeleteLayer?() == true { return nil }
                return event

            case 123, 124, 125, 126:   // 方向键：平移视图
                // 装在监视器里而不是只靠 `keyDown`：`keyDown` 只有画布是第一响应者时才来，
                // 而用户点过检查器、折叠块、面板空白处之后焦点就跑了，方向键会「没反应」。
                // 正在输入文字、或焦点在「自己要吃方向键」的控件（滑杆 / 步进器 / 列表 / 弹出菜单）上时让路。
                guard !Self.wantsArrowKeys(in: self.window) else { return event }
                let accelerated = event.modifierFlags.contains(.shift)
                guard self.panByArrowKey(event.keyCode, accelerated: accelerated) else { return event }
                return nil

            default:
                return event
            }
        }
    }

    /// 当前第一响应者是不是文本输入（文本框里回车不能被我方截走）。
    private static func isTypingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        // SwiftUI 的 TextField 背后是 NSTextView（字段编辑器），统一在上一层判断。
        return (responder as? NSView)?.isKind(of: NSTextView.self) ?? false
    }

    /// 当前第一响应者是不是「方向键另有用途」的控件。
    ///
    /// 这些控件上方向键有自己的含义（调滑杆、换选项、走列表），不能抢：
    /// 抢了就会变成「拖不透明度滑杆时按到 ←，地图跑了」。
    private static func wantsArrowKeys(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if responder is NSSlider || responder is NSStepper { return true }
        if responder is NSTableView || responder is NSOutlineView { return true }
        if responder is NSPopUpButton || responder is NSSegmentedControl { return true }
        return false
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
        if Self.tracesLayers {
            let names = newLayers.map { "\($0.id.prefix(6))/\($0.sourceKey.prefix(24))" }
            traceGeometryEvent("setLayers 层数=\(newLayers.count) [\(names.joined(separator: " "))]")
        }
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
                    grid: layer.grid,
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
        syncHostLayerFrames()

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
    /// 标记「相机已经被摆到过一个有意义的视野」（输入处理文件里也要调，故不加 `private`）。
    func markViewPositioned() { viewWasPositioned = true }

    /// 重配图层之后把地面比例套回去（`condition` 为假时不动，让首次适配生效）。
    private func restoreGroundScale(_ scale: Double, when condition: Bool) {
        guard condition, scale > 0, scale.isFinite else { return }
        camera = camera.settingGroundMetersPerPoint(scale).clamped(zoomLevelRange: zoomBounds)
    }

    /// 把图层栈插到测量标注之下。
    private func layer_hostAdd(_ stack: TileLayerStack) {
        layer?.insertSublayer(stack.hostLayer, below: overlay.hostLayer)
    }

    /// 让底色层与各瓦片栈的宿主图层都跟画布等大。
    ///
    /// 这件事**不能只在 `layout()` 里做**：图层栈是打开数据的那一刻才建的，而那时候窗口
    /// 早就布局完了 —— 拖一个目录进来、或者从「最近打开」切一份数据，都不会再触发
    /// AppKit 的 `layout()`。新建的宿主图层于是停在 0×0，它又是 `masksToBounds`，
    /// 整层瓦片被裁得一片不剩：状态栏写着「已载入 858 片」、缩略图也有图，
    /// 画面却只剩底色，看着就是「打开了却是全灰」。
    ///
    /// 因此每帧同步前都兜一次底，代价只是几次 frame 比较。
    private func syncHostLayerFrames() {
        let needsWork = backgroundLayer.frame != bounds
            || stacks.values.contains { $0.hostLayer.frame != bounds }
        guard needsWork else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        for stack in stacks.values { stack.hostLayer.frame = bounds }
        CATransaction.commit()
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
        var lower = rect == nil
            ? min(zoomBounds.lowerBound, upper - 0.001)
            : min(max(-2, fitCamera.zoomLevel - 1.2), upper - 0.001)
        zoomLowerBoundFromFit = lower
        // 主图层的最低数据层级比适配层级“深”很多时（整省 z12 之类的数据在「适应窗口」下就是这样），
        // 再往外缩一屏就要铺几千片，安全阀会把画布清空 —— 看着像数据没打开。
        // 把「一屏还铺得出来」的最低层级也算进缩放下限，宁可少看一点，也不留一屏空白。
        if rect != nil, let primary {
            lower = max(lower, primary.affordableCameraZoom(
                viewportSize: bounds.size, displayScale: displayScale
            ))
        }
        // 下限顶到上限会让 `ClosedRange` 直接崩，夹一道。
        lower = min(lower, upper - 0.001)
        zoomBounds = lower...upper
        camera = fitCamera.clamped(zoomLevelRange: zoomBounds)
    }

    /// 视口尺寸变了（进全屏、拉大窗口、从「适应窗口」回来）就按新视口重算缩放下限。
    ///
    /// 缩放下限里有一道来自铺图安全阀的收紧（见 `refreshCamera` 里对 `affordableCameraZoom`
    /// 的调用），但那只在适配视野的那一刻算过一次，用的是当时的视口。进全屏之后视口变大，
    /// 同一个层级一屏要铺的片数跟着涨，越过 `TileLayerStack.maximumTilesPerFrame` 之后
    /// 每一帧都会走「清空画布」那条路 —— 画面就整屏空掉，而且**再也不会自己回来**：
    /// 相机停在原地、视口也不再变，之后每一帧都还是超预算。
    ///
    /// 所以每次视口尺寸变化都重算一遍，把相机夹回「一屏还铺得出来」的范围。窗口缩回去
    /// 时限界也跟着松回来（`zoomLowerBoundFromFit` 那一步就是为此留的）。
    private func adoptZoomBoundsToViewport() {
        guard let primary = primaryStack else { return }
        let affordable = primary.affordableCameraZoom(
            viewportSize: bounds.size, displayScale: displayScale
        )
        let lower = min(max(zoomLowerBoundFromFit, affordable), zoomBounds.upperBound - 0.001)
        guard abs(lower - zoomBounds.lowerBound) > 0.0005 else { return }
        zoomBounds = lower...zoomBounds.upperBound
        camera = camera.clamped(zoomLevelRange: zoomBounds)
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
        traceGeometryEvent("layout")
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size
        adoptZoomBoundsToViewport()
        camera = camera.clamped(zoomLevelRange: zoomBounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        for stack in stacks.values { stack.hostLayer.frame = bounds }
        CATransaction.commit()
        syncLayers()
    }

    /// 拖窗口改大小时也要重铺，但**别在拖动过程中去取图**。
    ///
    /// AppKit 在 live resize 期间每个事件都会走一次 `layout()`：照原样每帧都发起一批瓦片请求，
    /// 就变成「一边拖窗口一边解码一屏新瓦片」，边框拖动会明显发顿、也白读一堆盘。
    /// 这里沿用「手势期间只位移不取图」那套口径：拖动时只重铺，松手那一次再补图。
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
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
    var currentDataZoom: Int {
        guard let primary = primaryStack else { return 0 }
        return primary.dataZoom(for: camera)
    }

    /// 当前基准层的瓦片网格（瓦片读数的行列换算按它算）。
    var currentGrid: TileGrid {
        anchorLayer?.grid ?? layers.last?.grid ?? .webMercator
    }

    /// 把两条图层都同步一遍：下层先铺，上层后铺，叠加顺序天然正确。
    /// 重铺图层（输入处理的每条路径最后都要调它，故不加 `private`）。
    func syncLayers() {
        let traceStarted = Self.tracesSync ? CFAbsoluteTimeGetCurrent() : 0
        var traceDetail = ""
        defer {
            if Self.tracesSync {
                let cost = (CFAbsoluteTimeGetCurrent() - traceStarted) * 1000
                syncTraceCount += 1
                syncTraceTotal += cost
                syncTraceWorst = max(syncTraceWorst, cost)
                // 单次重铺超过 8 ms 就是掉帧级别：把当时的层级与瓦片规模一起记下来，
                // 方便分清是「换层级那一下」还是「某个规模下的常态」。
                if cost > 8 {
                    let line = String(
                        format: "[sync] %.1f ms · 相机 z=%.2f · 层 %d · 上一次可见 %d 片%@\n",
                        cost, camera.zoomLevel, stacks.count, lastVisibleTiles,
                        traceDetail.isEmpty ? "" : " · " + traceDetail
                    )
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
        }
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size
        adoptZoomBoundsToViewport()
        // 新建的图层栈可能还没被 `layout()` 量过尺寸（拖放 / 切数据都不会再触发它）。
        syncHostLayerFrames()
        for stack in stacks.values { stack.updateSortCenter(camera.center) }
        // 拖窗口期间先不做预取这类后台活；拖动视图时反过来要预取，边上才有图。
        for stack in stacks.values {
            stack.defersBackgroundWork = defersTileWork
            stack.isInteracting = isGestureActive
        }
        // 拖窗口期间只挪图层、不取图；拖动视图时照常取（见 `defersTileWork`）。
        let loadsTiles = !defersTileWork

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
        // 没有基准层时退到最上面那一层；一层都没有时 `gridOwner` 是 nil，网格就不画（`===` 收 nil）。
        let gridOwner = anchorLayer.flatMap { stacks[$0.id] } ?? activeStacks.last
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
        dumpLayersIfRequested()
        reportTileStats(loadedTiles: loadedTiles, missingTiles: missingTiles, loadsTiles: loadsTiles)
        reportViewport(visibleTiles: visibleTiles)
        traceDetail = "需要 \(visibleTiles) 片 · 已上屏 \(loadedTiles) · 缺 \(missingTiles)"
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
    func reportViewport(visibleTiles: Int) {
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

    /// 内存压力下把各层的瓦片缓存压小（系统发通知时由 `AppModel` 调用）。
    func trimTileCaches(toFraction fraction: Double) {
        for stack in stacks.values { stack.trimCache(toFraction: fraction) }
    }

    /// 当前画布的设备像素比（导出图片时用来定字号与线宽）。
    var backingScale: CGFloat { CGFloat(displayScale) }

    /// 调试用：当前有效视野的中心（含手势期间还没提交的位移）。
    var debugCenterText: String {
        let coordinate = WebMercator.coordinate(fromNormalized: effectiveCamera.center)
        return String(format: "%.5f, %.5f", coordinate.longitude, coordinate.latitude)
    }

    /// 调试用：当前相机层级（含手势期间还没提交的位移）。
    var debugZoomLevel: Double { effectiveCamera.zoomLevel }

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
            showLabels: store.showLabels,
            areaUnit: areaUnit
        )
    }

    /// 一步的位移（点）；按住 `Shift` 走 `arrowPanStepFast`。
    static let arrowPanStep: CGFloat = 40
    static let arrowPanStepFast: CGFloat = 120
}
