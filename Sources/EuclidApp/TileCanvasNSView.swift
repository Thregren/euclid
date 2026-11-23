import TileRendering
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
    var stackSignatures: [String: String] = [:]
    /// 当前图层列表（下 → 上）。
    /// （卷帘对比在另一个文件里要用到它，故不加 `private`。）
    var layers: [MapLayer] = []

    /// 基准层：测量、存档、相机尺度都以它为准。
    var anchorLayer: MapLayer? { layers.first { $0.isAnchor } ?? layers.last }
    /// 当前主图层（用来定瓦片边长与层级范围）：优先基准层，否则最上面那层。
    var primaryStack: TileLayerStack? {
        if let anchor = anchorLayer, let stack = stacks[anchor.id], stack.isActive { return stack }
        return orderedStacks.last { $0.isActive }
    }
    /// 模型顺序（下 → 上）的栈。
    var orderedStacks: [TileLayerStack] {
        layers.compactMap { stacks[$0.id] }
    }

    func makeStack() -> TileLayerStack {
        let stack = TileLayerStack()
        stack.reducesMotion = InterfaceStyle.reducesMotion
        stack.needsSync = { [weak self] in self?.syncLayers() }
        stack.refreshGridAppearance(stroke: gridStrokeColor)
        return stack
    }
    /// 适配窗口用的默认范围（数据范围算出来之前 / 在线底图）。
    /// 在线底图的适配范围（没有本地数据时用它对齐窗口）。
    /// 数据集已就位但数据范围还在算：这段时间不铺图（见 `setLocal`）。
    var awaitingExtent = false
    var extentRect: CGRect?
    var zoomBounds: ClosedRange<Double> = 0...30
    /// 「按适配算出来」的缩放下限（不含铺图预算那一道收紧）。
    ///
    /// 视口尺寸一变就要重算缩放下限，而重算得拿这个「原始下限」当基准 ——
    /// 直接拿收紧后的 `zoomBounds.lowerBound` 重算的话，窗口缩回去下限也松不回来。
    var zoomLowerBoundFromFit: Double = 0
    var trackingArea: NSTrackingArea?
    /// 相机是否已经被放到过一个有意义的视野（用户平移缩放、或按数据范围适配过）。
    /// 用它区分「首次打开的内容」与「用户自己调好的视野」：前者可以自动适配，后者一律不许动。
    var viewWasPositioned = false

    enum DragTarget {
        case pan
        case vertex(measurementID: UUID?, index: Int)
        /// 拉框选范围（下载面板「在视图上框选」用）。
        case pickBounds
        /// 拖卷帘对比的分隔线。
        case swipe
    }

    /// 框选范围回调：非 nil 时画布进入「拉框」模式，松手把框内的经纬度范围交出去。
    ///
    /// 这是画布与下载面板之间唯一的接口，画布不需要知道「下载」这件事，
    /// 面板也不需要知道画布内部怎么把屏幕点换算成经纬度。
    var boundsPicker: ((GeoBounds) -> Void)? {
        didSet {
            guard (boundsPicker == nil) != (oldValue == nil) else { return }
            if boundsPicker == nil { clearPickRect() }
            window?.invalidateCursorRects(for: self)
            refreshCursor()
        }
    }

    /// 框选被取消（Esc）时的回调：与 `boundsPicker` 配对使用。
    ///
    /// 画布对「谁在要范围」一无所知：要范围 / 被取消各一个闭包，下载面板与分析面板
    /// 各自接自己的那条，画布这边不必区分。
    var boundsPickCancel: (() -> Void)?

    /// 框选用的橡皮筋层（只在框选期间可见）。
    let pickLayer = CAShapeLayer()
    /// 框选的起点与当前点（视图坐标，y 向上）。
    var pickAnchor: CGPoint?
    var pickCurrent: CGPoint?

    // MARK: - 卷帘对比（E1）的状态
    //
    // 逻辑都在 `TileCanvasNSView+Swipe.swift`，这里只放存储属性（Swift 的扩展不能加存储属性）。
    /// 卷帘对比的分界层 id：它**之上**的图层只在分隔线左侧显示；nil = 未开启对比。
    var swipePivotLayerID: String?
    /// 分隔线位置（占视图宽度的比例 0…1）。
    var swipeFraction: CGFloat = 0.5
    /// 每条被遮罩的图层配一块形状遮罩（懒建）。
    var swipeMasks: [String: CAShapeLayer] = [:]
    /// 分隔线 + 中央把手，盖在瓦片与测量标注之上。
    let swipeDividerLayer = CAShapeLayer()
    /// 把手心里的那对向内箭头（懒建）。
    var swipeArrowsLayer: CAShapeLayer?

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
    var finishMonitor: Any?
    /// 退格 / 前向删除时问一句「要删图层吗」（由 AppModel 注入，返回是否删掉了）。
    var onDeleteLayer: (() -> Bool)?
    /// 窗口失焦的订阅（见 `viewDidMoveToWindow`）。
    var resignObserver: (any NSObjectProtocol)?
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
    static let loadsTilesDuringGesture =
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
        // 框选橡皮筋盖在最上面：它只在框选期间有内容，平时是空路径、不可见。
        pickLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        pickLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        pickLayer.lineWidth = 1.5
        pickLayer.lineDashPattern = [6, 4]
        // 与测量标注同口径：层坐标 y 向下，这里翻成视图坐标（y 向上），
        // 事件点就不用再换算一次。
        pickLayer.isGeometryFlipped = true
        pickLayer.isHidden = true
        layer?.addSublayer(pickLayer)

        // 卷帘分隔线：白色竖线 + 中央圆把手，平时隐藏（未开启对比时不占视觉）。
        swipeDividerLayer.fillColor = NSColor.white.withAlphaComponent(0.92).cgColor
        swipeDividerLayer.isGeometryFlipped = true
        swipeDividerLayer.isHidden = true
        swipeDividerLayer.shadowColor = NSColor.black.cgColor
        swipeDividerLayer.shadowOpacity = 0.35
        swipeDividerLayer.shadowRadius = 2
        swipeDividerLayer.shadowOffset = .zero
        layer?.addSublayer(swipeDividerLayer)
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
    func handleWindowResignKey() {
        commitPan(finished: true)
        finishPanTrace()
    }

    func removeFinishMonitor() {
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
    func installFinishMonitor() {
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
    static func isTypingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        // SwiftUI 的 TextField 背后是 NSTextView（字段编辑器），统一在上一层判断。
        return (responder as? NSView)?.isKind(of: NSTextView.self) ?? false
    }

    /// 当前第一响应者是不是「方向键另有用途」的控件。
    ///
    /// 这些控件上方向键有自己的含义（调滑杆、换选项、走列表），不能抢：
    /// 抢了就会变成「拖不透明度滑杆时按到 ←，地图跑了」。
    static func wantsArrowKeys(in window: NSWindow?) -> Bool {
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
    var canvasBackgroundColor: CGColor {
        NSColor.underPageBackgroundColor.resolvedCGColor(in: effectiveAppearance)
    }

    /// 瓦片网格线的颜色：同样按当前有效外观解析。
    var gridStrokeColor: CGColor {
        NSColor.labelColor.withAlphaComponent(0.32).resolvedCGColor(in: effectiveAppearance)
    }

    /// 语义色在每次外观变化时重新取一遍，避免深浅色切换后颜色残留。
    func applyAppearanceColors() {
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
        addCursorRect(bounds, cursor: pickCursor)
    }

    /// 当前该显示的指针样式（框选模式下忽略工具，一律十字）。
    var pickCursor: NSCursor {
        // 卷帘对比开着、且指针正贴在分隔线上：给「左右拖」的指针，提示这里可以抓。
        if let point = lastPointerPoint, swipeHitTest(point) { return .resizeLeftRight }
        return boundsPicker != nil ? .crosshair : (tool == .browse ? .openHand : .crosshair)
    }

    /// 立即刷新指针（进入 / 退出框选模式时调用）。
    func refreshCursor() {
        pickCursor.set()
    }

    // MARK: - 框选范围（下载面板用）

    /// 按下：记下拉框起点。
    func beginPickRect(at point: CGPoint) {
        pickAnchor = point
        pickCurrent = point
        updatePickLayer()
    }

    /// 拖动：橡皮筋跟着指针走。
    func updatePickRect(to point: CGPoint) {
        guard pickAnchor != nil else { return }
        pickCurrent = point
        updatePickLayer()
    }

    /// 清掉橡皮筋（结束、取消、切模式都走这里）。
    func clearPickRect() {
        pickAnchor = nil
        pickCurrent = nil
        pickLayer.path = nil
        pickLayer.isHidden = true
    }

    func updatePickLayer() {
        guard let anchor = pickAnchor, let current = pickCurrent else { return }
        pickLayer.frame = bounds
        pickLayer.path = CGPath(rect: Self.rect(from: anchor, to: current), transform: nil)
        pickLayer.isHidden = false
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// 松手：把框内的经纬度范围交出去（太小、或者已经出了世界范围就不交）。
    func finishPickRect(at point: CGPoint) {
        defer { clearPickRect() }
        guard let handler = boundsPicker, let anchor = pickAnchor else { return }
        let rect = Self.rect(from: anchor, to: point)
        // 小于 4 点基本是误触，不当作一次框选。
        guard rect.width >= 4, rect.height >= 4 else { return }
        let cornerA = camera.worldPoint(forViewPoint: CGPoint(x: rect.minX, y: rect.minY))
        let cornerB = camera.worldPoint(forViewPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        let world = Self.rect(from: cornerA, to: cornerB)
        let clamped = world.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return }
        handler(GeoBounds(normalizedRect: clamped))
    }

    /// 世界范围（在线底图的兜底适配目标）。
    ///
    /// 注意 y 的起点：墨卡托裁掉两极后的范围是 `0.1217…0.8783`，
    /// 从 0 起算会让「适配整个世界」把视角整体推到北半球（以前打开在线底图看到的是北纬五十几度）。
    static let worldRect = CGRect(
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


    /// 相机是否已经被放到过一个有意义的视野（用户平移缩放、或按范围适配过）。
    /// 用它区分「首次出现的内容」与「用户调好的视野」：前者可以自动适配，后者一律不许动。
    /// 标记「相机已经被摆到过一个有意义的视野」（输入处理文件里也要调，故不加 `private`）。
    func markViewPositioned() { viewWasPositioned = true }

    /// 重配图层之后把地面比例套回去（`condition` 为假时不动，让首次适配生效）。


    /// 把图层栈插到测量标注之下。


    /// 让底色层与各瓦片栈的宿主图层都跟画布等大。
    ///
    /// 这件事**不能只在 `layout()` 里做**：图层栈是打开数据的那一刻才建的，而那时候窗口
    /// 早就布局完了 —— 拖一个目录进来、或者从「最近打开」切一份数据，都不会再触发
    /// AppKit 的 `layout()`。新建的宿主图层于是停在 0×0，它又是 `masksToBounds`，
    /// 整层瓦片被裁得一片不剩：状态栏写着「已载入 858 片」、缩略图也有图，
    /// 画面却只剩底色，看着就是「打开了却是全灰」。
    ///
    /// 因此每帧同步前都兜一次底，代价只是几次 frame 比较。


    /// 依据当前激活的图层重配相机（瓦片边长、缩放上下限，以及可选的窗口适配）。


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


    /// 画布是自绘的，给读屏一个可读的名字与当前层级。


    /// 上次写进无障碍值的层级。
    var lastAccessibilityZoom: Int?

    /// 只在层级真的变了才写无障碍值。
    ///
    /// `sync` 在瓦片到位、手势提交时都会跑，每次都 `setAccessibilityValue("z…")` 等于
    /// 每秒给辅助功能栈发几十次同样的通知 —— 值没变就别惊动它。


    /// 本地数据范围算好之后对齐窗口（只影响本地层，不打断已经铺好的其他层）。


    /// 适配窗口：优先本地数据范围，其次在线底图范围。


    /// 缩放到指定的世界范围。


    /// 把相机移动到指定地理坐标（保持当前层级）。


    /// 跳到指定视点（中心 + 缩放层级），书签与「巡检图集」用。
    func goTo(_ coordinate: GeoCoordinate, zoomLevel: Double?) {
        markViewPositioned()
        camera.center = WebMercator.normalized(coordinate)
        if let zoomLevel {
            camera = camera.settingZoomLevel(zoomLevel, zoomLevelRange: zoomBounds)
        }
        camera = camera.clamped(zoomLevelRange: zoomBounds)
        syncLayers()
        reportViewport(visibleTiles: lastVisibleTiles)
    }

    /// 当前视点（书签记的就是这个）。
    var currentViewpoint: (center: GeoCoordinate, zoomLevel: Double) {
        (WebMercator.coordinate(fromNormalized: camera.center), camera.zoomLevel)
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
        swipeDividerLayer.frame = bounds
        CATransaction.commit()
        if swipeIsActive { applySwipe() }
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
    var displayScale: Double { Double(window?.backingScaleFactor ?? 2) }

    func updateContentsScale() {
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
        for stack in stacks.values {
            stack.updateSortCenter(camera.center)
            stack.reducesMotion = InterfaceStyle.reducesMotion
        }
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
        writeAccessibilityZoom(currentDataZoom)
    }

    /// 瓦片读数是给状态栏看的，手势期间它本来也没在变，别白刷一次界面。
    func reportTileStats(loadedTiles: Int, missingTiles: Int, loadsTiles: Bool) {
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
        renderSnapshot(includingMeasurements: includingMeasurements)?.makeImage()
    }

    /// 把当前画面抽成**值类型快照**：底图 + 各图层栈的图 + 测量标注位图。
    ///
    /// 只读，不改任何可见状态（旧的出图路径要临时改 `isHidden` 再还原，
    /// 中途出错就会留下隐藏的网格或标注）。快照里全是不可变的 `CGImage`，
    /// 拿出去之后可以整体丢到后台线程去光栅化 / 合成 / 编码，主线程不再为出图停摆。
    func renderSnapshot(includingMeasurements: Bool = true) -> MapRenderSnapshot? {
        let scale = CGFloat(displayScale)
        guard bounds.width > 1, bounds.height > 1, scale > 0 else { return nil }
        var placements: [MapRenderSnapshot.Placement] = []
        // 层序按模型给的图层列表（下 → 上），保证叠加关系与屏幕一致。
        for stack in orderedStacks { stack.appendPlacements(into: &placements) }
        let overlayImage: CGImage? = (includingMeasurements && !overlay.hostLayer.isHidden)
            ? overlay.offscreenImage(size: bounds.size, scale: scale)
            : nil
        return MapRenderSnapshot(
            size: bounds.size,
            scale: scale,
            background: backgroundLayer.backgroundColor,
            placements: placements,
            overlay: overlayImage,
            measurementCount: measurementStore?.measurements.count ?? 0
        )
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
