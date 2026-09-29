import AppKit
import QuartzCore
import TileKit

/// 画布的输入处理：鼠标、滚轮、触控板手势、键盘，以及「手势期间只位移不重铺」的快路径。
///
/// 从 `TileCanvasNSView.swift` 拆出来的纯搬移（那个文件只放视图本体与装配）：
/// 视图与图层的坐标约定见那一边的说明，这里只管「输入进来之后怎么改相机」。
extension TileCanvasNSView {
    // MARK: - 鼠标

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
    /// （跨文件要用，故不是 `private`：`layout()` 与工具切换时会收尾草稿。）
    func finishDraft() {
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
        let grid = currentGrid
        let tile = grid.tile(at: coordinate, zoom: zoom)
        let bounds = grid.bounds(zoom: zoom, column: tile.column, row: tile.row)
        // 瓦片内像素按**这片瓦片自己的经纬度范围**算：经纬度网格的瓦片不是正方形，
        // 在墨卡托世界坐标里量会差几十个像素（高纬更明显）。
        let pixels = max(camera.tilePixelSize, 1)
        let horizontal = max(bounds.east - bounds.west, 1e-12)
        let vertical = max(bounds.north - bounds.south, 1e-12)
        let pixelX = min(max(Int((coordinate.longitude - bounds.west) / horizontal * pixels), 0), Int(pixels) - 1)
        let pixelY = min(max(Int((bounds.north - coordinate.latitude) / vertical * pixels), 0), Int(pixels) - 1)
        store.cursorInfo = CursorInfo(
            coordinate: coordinate,
            zoom: zoom,
            tileX: tile.column,
            tileY: tile.row,
            pixelX: pixelX,
            pixelY: pixelY
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
            if Self.reportsReadoutDuringPan { scheduleReadoutRefresh(for: point) }
        }
    }

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
    /// （跨文件要用，故不是 `private`：窗口尺寸变化等场景要先把攒着的位移提交掉。）
    func commitPan(finished: Bool = true) {
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
    /// （跨文件要用，故不是 `private`：状态栏读数与命中判定在视图本体里取值。）
    var effectiveCamera: MapCamera {
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
        guard Self.tracesScroll else { return }
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
        guard Self.tracesScroll,
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
            guard panByArrowKey(event.keyCode, accelerated: event.modifierFlags.contains(.shift)) else {
                super.keyDown(with: event)
                return
            }
        }
    }

    // MARK: - 方向键平移

    /// 方向键把视图挪一格（按住 `Shift` 挪三格）。
    ///
    /// 方向按地图的惯例：按 ← 看更西边、按 ↑ 看北边（画面内容朝反方向走）。
    /// 返回是否吃掉了这个键。
    @discardableResult
    func panByArrowKey(_ keyCode: UInt16, accelerated: Bool) -> Bool {
        let step = accelerated ? Self.arrowPanStepFast : Self.arrowPanStep
        let delta: CGPoint
        switch keyCode {
        case 123: delta = CGPoint(x: step, y: 0)      // ←
        case 124: delta = CGPoint(x: -step, y: 0)     // →
        // 纵向与横向的符号不同：视图坐标 y 向上，而「看北边」对应画面内容向下走。
        case 125: delta = CGPoint(x: 0, y: step)      // ↓：看南边
        case 126: delta = CGPoint(x: 0, y: -step)     // ↑：看北边
        default: return false
        }
        markViewPositioned()
        camera = camera.translated(byViewDelta: delta).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
        return true
    }
}
