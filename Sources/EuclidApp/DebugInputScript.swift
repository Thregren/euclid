import AppKit
import TileKit

/// 开发调试用的「合成输入」基准：`EUCLID_DEBUG_INPUT=1` 时启动十几秒后跑一轮。
///
/// 做法是在进程内构造 `NSEvent` 直接喂给画布的真实处理函数（`scrollWheel` /
/// `mouseMoved` / `mouseDragged` …），走的是和真实输入**同一条**代码路径，
/// 只是不经过系统的输入通道 —— 因此不需要屏幕录制/辅助功能权限，也能在无人值守下跑。
///
/// 每种手势逐事件计时，最后把平均 / p50 / p95 / 最慢打到 stderr。
/// 用途是给「拖动、缩放跟不跟手」一个可对比的数字：改性能相关代码前后各跑一次即可。
/// 正式使用不会设置该变量，逻辑不触发。
@MainActor
enum DebugInputScript {
    /// 每种手势采样多少个事件。
    private static let eventCount = 240

    static func runIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.environment["EUCLID_DEBUG_INPUT"] != nil else { return }
        Task { @MainActor in
            // 等数据集、缩略图与首屏瓦片都安定下来，量到的才是稳态下的手感。
            try? await Task.sleep(for: .seconds(12))
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
                  let content = window.contentView,
                  let canvas = find(TileCanvasNSView.self, in: content) else {
                log("找不到可见窗口或画布")
                return
            }
            // `EUCLID_DEBUG_INPUT=arrows` 只跑方向键那一条，便于快速核对（十几秒）。
            let mode = ProcessInfo.processInfo.environment["EUCLID_DEBUG_INPUT"] ?? ""
            if mode == "arrows" {
                await checkArrowPanning(canvas: canvas, window: window)
                log("结束")
                return
            }
            await run(canvas: canvas, window: window, model: model)
        }
    }

    private static func run(canvas: TileCanvasNSView, window: NSWindow, model: AppModel) async {
        log("开始：图层 \(model.layers.count) 个 · 测量 \(model.measurements.measurements.count) 条 "
            + "· 可见瓦片 \(model.viewport.visibleTiles) 片 · 画布 \(Int(canvas.bounds.width))×\(Int(canvas.bounds.height)) 点")

        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)

        // 1) 触摸板双指平移：精确滚动、有手势阶段 —— 手势期间只做图层位移。
        log("对照：首个精确滚动事件 " + describeScroll(canvas: canvas, window: window, dx: 3, dy: 2, precise: true, phase: .changed, at: center))
        await measure("双指平移（精确滚动）", canvas: canvas) { index in
            let dx: CGFloat = index % 2 == 0 ? 3 : -3
            let dy: CGFloat = index % 3 == 0 ? 2 : -2
            sendScroll(canvas: canvas, window: window, dx: dx, dy: dy,
                       precise: true, phase: .changed, at: center)
        }
        await settle("双指平移结束后", canvas: canvas)

        // 2) 鼠标滚轮缩放：每个事件都要按新层级重铺瓦片，是最重的一条路。
        log("对照：首个滚轮事件 " + describeScroll(canvas: canvas, window: window, dx: 0, dy: 0.6, precise: false, phase: [], at: center))
        await measure("滚轮缩放（每个事件重铺）", canvas: canvas) { index in
            sendScroll(canvas: canvas, window: window, dx: 0, dy: index % 2 == 0 ? 0.6 : -0.6,
                       precise: false, phase: [], at: center)
        }
        await settle("滚轮缩放结束后", canvas: canvas)

        // 3) 浏览工具下移动指针：读数 + 悬停命中。
        await measure("浏览时指针移动", canvas: canvas) { index in
            sendMouse(.mouseMoved, canvas: canvas, window: window,
                      at: wandering(center, index))
        }

        // 4) 画测距时移动指针：每个事件都要刷新整个测量标注层（含文字标签）。
        let centerCoordinate = model.viewport.center
        model.measurements.tool = .distance
        model.measurements.cancelDraft()
        model.measurements.addPoint(centerCoordinate)
        model.measurements.addPoint(GeoCoordinate(
            longitude: centerCoordinate.longitude + 0.002,
            latitude: centerCoordinate.latitude + 0.001
        ))
        model.measurements.liveCoordinate = centerCoordinate
        canvas.refreshOverlay()
        await measure("画测距时指针移动", canvas: canvas) { index in
            sendMouse(.mouseMoved, canvas: canvas, window: window,
                      at: wandering(center, index))
        }

        // 5) 左键拖动平移：手势期间只位移，每攒够一段位移提交一次（重铺瓦片）。
        await measure("左键拖动平移", canvas: canvas) { index in
            let from = wandering(center, index)
            if index == 0 {
                sendMouse(.leftMouseDown, canvas: canvas, window: window, at: from)
            } else {
                sendMouse(.leftMouseDragged, canvas: canvas, window: window,
                          at: wandering(center, index))
            }
        }
        sendMouse(.leftMouseUp, canvas: canvas, window: window, at: wandering(center, 0))
        await settle("拖动平移结束后", canvas: canvas)

        // 6) 快速甩一屏半：立刻截图，看新露出来的边缘是「已经有图」还是「一片白」。
        //    配合 `EUCLID_PAN_NO_TILES=1`（回到老口径）各跑一次就是一组对照。
        model.measurements.cancelDraft()
        canvas.refreshOverlay()
        // 先放大几档：一屏的路程仍然落在数据里面（否则甩出去看到的只是「本来就没有图」）。
        for _ in 0..<4 {
            sendScroll(canvas: canvas, window: window, dx: 0, dy: 0.6, precise: false, phase: [], at: center)
        }
        try? await Task.sleep(for: .seconds(2))
        log("甩动前：中心 \(canvas.debugCenterText) · 缩放 z\(String(format: "%.2f", canvas.debugZoomLevel))")
        // 每个事件 8 点、80 个、每 4 ms 一个：约 640 点（半屏多一点）走 320 ms，
        // 也就是每秒两千点的手速 —— 真实触摸板甩一下差不多就是这样，每 120 点提交一次。
        await measure("快速甩半屏", canvas: canvas, count: 80, yields: false, paceMillis: 4) { index in
            let point = CGPoint(x: center.x - 320 + CGFloat(index) * 8, y: center.y)
            if index == 0 {
                sendMouse(.leftMouseDown, canvas: canvas, window: window, at: point)
            } else {
                sendMouse(.leftMouseDragged, canvas: canvas, window: window, at: point)
            }
        }
        log("甩动后（还没松手）：中心 \(canvas.debugCenterText) · 缩放 z\(String(format: "%.2f", canvas.debugZoomLevel))")
        canvas.writeDebugSnapshot(index: 90)     // 手还在拖的那一刻
        sendMouse(.leftMouseUp, canvas: canvas, window: window, at: center)
        try? await Task.sleep(for: .milliseconds(400))
        canvas.writeDebugSnapshot(index: 91)     // 松手 0.4 秒后
        log("已写出画布截图：frame-90.png（拖动中）、frame-91.png（松手 0.4 s 后）")

        // 7) 方向键平移：走 NSApp 的事件派发（也就是本地键盘监视器那条路），
        //    并且先把焦点挪开，验证「没点过画布也能用」。同时打印四个方向移动后的中心，
        //    用来核对方向符不符合地图惯例（← 看西边、↑ 看北边）。
        await checkArrowPanning(canvas: canvas, window: window)

        model.measurements.cancelDraft()
        canvas.refreshOverlay()

        log("结束")
    }

    /// 方向键平移的无人值守核对。
    private static func checkArrowPanning(canvas: TileCanvasNSView, window: NSWindow) async {
        log("启动后的第一响应者：\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "无")"
            + "（画布在前 = 一开窗方向键就能用）")
        // 焦点交给窗口本身（等于「用户点过面板空白处」那种状态）。
        window.makeFirstResponder(nil)
        try? await Task.sleep(for: .milliseconds(200))
        log("方向键测试前的第一响应者：\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "无")")

        let directions: [(name: String, keyCode: UInt16)] = [
            ("←", 123), ("→", 124), ("↑", 126), ("↓", 125),
        ]
        for direction in directions {
            let before = canvas.debugCenterText
            sendArrowKey(direction.keyCode, window: window)
            try? await Task.sleep(for: .milliseconds(120))
            log("  方向键 \(direction.name)：\(before) → \(canvas.debugCenterText)")
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// 合成一个方向键事件并交给 `NSApp` 派发：本地监视器就是在这里被调用的，
    /// 因此这条路径与用户真按方向键完全一致。
    private static func sendArrowKey(_ keyCode: UInt16, window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        NSApplication.shared.sendEvent(event)
    }

    /// 指针在画布中部来回游走（±160 点），避免每次都命中同一个点。
    private static func wandering(_ center: CGPoint, _ index: Int) -> CGPoint {
        let phase = Double(index) * 0.07
        return CGPoint(
            x: center.x + CGFloat(cos(phase)) * 160,
            y: center.y + CGFloat(sin(phase * 0.7)) * 110
        )
    }

    /// 手势停下之后静置一会儿：这一段时间正是缺瓦片陆续到位、反复回来重铺的时候，
    /// 「重铺多少次、一共花掉多少主线程时间」最能说明松手之后卡不卡。
    private static func settle(_ label: String, canvas: TileCanvasNSView) async {
        _ = canvas.takeSyncTrace()
        try? await Task.sleep(for: .milliseconds(1200))
        let sync = canvas.takeSyncTrace()
        let average = sync.count > 0 ? sync.total / Double(sync.count) : 0
        log(String(
            format: "静置 1.2s（%@）：重铺 %d 次 · 合计 %.1f ms · 平均 %.2f ms · 最慢 %.2f ms",
            label, sync.count, sync.total, average, sync.worst
        ))
    }

    // MARK: - 计时

    /// 逐个事件计时并把统计打到 stderr。
    private static func measure(
        _ name: String,
        canvas: TileCanvasNSView,
        count: Int = eventCount,
        yields: Bool = true,
        paceMillis: Int = 0,
        _ body: (Int) -> Void
    ) async {
        // 每种手势之间让主线程喘一口气：把上一轮的瓦片请求与界面刷新跑完，量到的才是稳态。
        try? await Task.sleep(for: .milliseconds(700))
        _ = canvas.takeSyncTrace()
        var durations: [Double] = []
        durations.reserveCapacity(count)
        for index in 0..<count {
            let started = CFAbsoluteTimeGetCurrent()
            body(index)
            durations.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            // 每 40 个事件让出一次主线程，模拟真实输入之间还有渲染与其它事件
            // （「快速甩一屏」那条要在一次连续手势里量，所以显式关掉）。
            if yields, index % 40 == 39 { try? await Task.sleep(for: .milliseconds(40)) }
            // 按真实手势的节奏走：触摸板一次拖动每秒上百个事件，8 点/事件 ≈ 4 ms 一个。
            if paceMillis > 0 { try? await Task.sleep(for: .milliseconds(paceMillis)) }
        }
        let sorted = durations.sorted()
        let total = durations.reduce(0, +)
        let sync = canvas.takeSyncTrace()
        let line = String(
            format: "[input] %@ %d 次：平均 %.2f ms · p50 %.2f · p95 %.2f · 最慢 %.2f ms\n",
            name, durations.count, total / Double(durations.count),
            sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            sorted.last ?? 0
        )
        FileHandle.standardError.write(Data(line.utf8))
        let syncLine = String(
            format: "[input]   ↳ 期间重铺 %d 次：合计 %.1f ms · 平均 %.2f ms · 最慢 %.2f ms\n",
            sync.count, sync.total, sync.count > 0 ? sync.total / Double(sync.count) : 0, sync.worst
        )
        FileHandle.standardError.write(Data(syncLine.utf8))
    }

    // MARK: - 合成事件

    private static func sendMouse(
        _ type: NSEvent.EventType,
        canvas: TileCanvasNSView,
        window: NSWindow,
        at point: CGPoint
    ) {
        let windowPoint = canvas.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        switch type {
        case .mouseMoved: canvas.mouseMoved(with: event)
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        default: break
        }
    }

    /// 合成滚动事件。
    ///
    /// `precise` 决定 `hasPreciseScrollingDeltas`：精确滚动走「双指平移」那条路，
    /// 非精确的滚轮走「缩放」那条路（与真实硬件一致）。
    private static func sendScroll(
        canvas: TileCanvasNSView,
        window: NSWindow,
        dx: CGFloat,
        dy: CGFloat,
        precise: Bool,
        phase: NSEvent.Phase,
        at point: CGPoint
    ) {
        guard let event = scrollEvent(
            canvas: canvas, window: window, dx: dx, dy: dy,
            precise: precise, phase: phase, at: point
        ) else { return }
        canvas.scrollWheel(with: event)
    }

    /// 把合成出来的滚动事件写成一行，用来核对它确实落在预期的那条分支上。
    private static func describeScroll(
        canvas: TileCanvasNSView,
        window: NSWindow,
        dx: CGFloat,
        dy: CGFloat,
        precise: Bool,
        phase: NSEvent.Phase,
        at point: CGPoint
    ) -> String {
        guard let event = scrollEvent(
            canvas: canvas, window: window, dx: dx, dy: dy,
            precise: precise, phase: phase, at: point
        ) else { return "合成失败" }
        return String(
            format: "精确=%@ 阶段=0x%02x 动量=0x%02x 位移=(%.1f, %.1f)",
            event.hasPreciseScrollingDeltas ? "是" : "否",
            event.phase.rawValue, event.momentumPhase.rawValue,
            event.scrollingDeltaX, event.scrollingDeltaY
        )
    }

    private static func scrollEvent(
        canvas: TileCanvasNSView,
        window: NSWindow,
        dx: CGFloat,
        dy: CGFloat,
        precise: Bool,
        phase: NSEvent.Phase,
        at point: CGPoint
    ) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(dy.rounded()),
            wheel2: Int32(dx.rounded()),
            wheel3: 0
        ) else { return nil }
        if precise {
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        cgEvent.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(rawPhase(phase))
        )
        let screenPoint = window.convertPoint(toScreen: canvas.convert(point, to: nil))
        cgEvent.location = screenPoint
        return NSEvent(cgEvent: cgEvent)
    }

    /// `NSEvent.Phase` → CGEvent 的 `scrollWheelEventScrollPhase` 字段取值。
    ///
    /// 注意这个字段用的是 CGScrollPhase 自己的编号（began 1 / changed 2 / ended 4 / cancelled 8），
    /// 与 `NSEventPhase` 的编号不是一套 —— 写错就会把「手势进行中」当成「手势已结束」。
    private static func rawPhase(_ phase: NSEvent.Phase) -> Int {
        switch phase {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        case .cancelled: return 8
        case .stationary: return 64
        default: return 0
        }
    }

    // MARK: - 杂项

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data(("[input] " + text + "\n").utf8))
    }
}
