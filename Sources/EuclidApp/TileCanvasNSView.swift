import AppKit
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
    private var tileTasks: [SlippyTile: Task<Void, Never>] = [:]
    private var missingTiles: Set<SlippyTile> = []
    private var requestedTiles: Set<SlippyTile> = []

    private var provider: TileProvider?
    private var dataset: TileDataset?
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
    /// 已经显示过的瓦片，用于只在首次出现时做淡入。
    private var shownTiles: Set<SlippyTile> = []

    /// 单帧最多渲染的瓦片数量，作为异常情况下的安全阀。
    private let maximumTilesPerFrame = 1200
    /// 同时在途的瓦片请求上限。
    private let maximumConcurrentRequests = 24
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
        for layer in tileLayers.values where layer.contents == nil {
            layer.backgroundColor = Self.tilePlaceholderColor.cgColor
        }
        CATransaction.commit()
    }

    private static var gridColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.32)
    }

    private static var tilePlaceholderColor: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.35)
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

    // MARK: - 数据集

    func configure(dataset: TileDataset?, extent: DatasetExtent?) {
        generation += 1
        cancelPendingRequests()
        for layer in tileLayers.values { layer.removeFromSuperlayer() }
        tileLayers.removeAll()
        missingTiles.removeAll()
        requestedTiles.removeAll()

        guard let dataset else {
            provider = nil
            self.dataset = nil
            extentRect = nil
            measurementStore?.cursorInfo = nil
            onTileStatsChanged?(0, 0)
            syncLayers()
            return
        }
        self.dataset = dataset
        provider = TileProvider(source: dataset.source)
        camera.tilePixelSize = Double(dataset.layout.tileSize)
        camera.viewportSize = bounds.size
        extentRect = extent?.worldRect

        let fitCamera = extent.map {
            MapCamera.fitting(
                $0.worldRect,
                viewportSize: bounds.size,
                padding: 28,
                tilePixelSize: Double(dataset.layout.tileSize)
            )
        } ?? camera.settingZoomLevel(Double(min(dataset.zoomRange.upperBound, dataset.zoomRange.lowerBound + 2)))

        zoomBounds = max(-2, fitCamera.zoomLevel - 1.2)...min(Double(dataset.zoomRange.upperBound) + 1.5, 26)
        camera = fitCamera.clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func setExtent(_ extent: DatasetExtent?) {
        extentRect = extent?.worldRect
        guard let extent, let dataset else { return }
        let fit = MapCamera.fitting(
            extent.worldRect,
            viewportSize: bounds.size,
            padding: 28,
            tilePixelSize: Double(dataset.layout.tileSize)
        )
        zoomBounds = max(-2, fit.zoomLevel - 1.2)...min(Double(dataset.zoomRange.upperBound) + 1.5, 26)
        camera = fit.clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func fitToData() {
        guard let dataset else { return }
        let rect = extentRect ?? camera.visibleWorldRect
        camera = MapCamera.fitting(
            rect,
            viewportSize: bounds.size,
            padding: 28,
            tilePixelSize: Double(dataset.layout.tileSize)
        )
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
        camera = camera.zoomed(by: 1.6, anchorViewPoint: anchor).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func zoomOut(anchor: CGPoint? = nil) {
        camera = camera.zoomed(by: 1 / 1.6, anchorViewPoint: anchor).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func zoomToActualSize() {
        guard let dataset else { return }
        camera = camera.settingZoomLevel(Double(dataset.zoomRange.upperBound)).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    var currentZoomLevel: Double { camera.zoomLevel }

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

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
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
        guard let dataset else { return 0 }
        let raw = Int(camera.zoomLevel.rounded())
        return min(max(raw, dataset.zoomRange.lowerBound), dataset.zoomRange.upperBound)
    }

    private func syncLayers() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size

        guard let provider, dataset != nil else {
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (tile, layer) in tileLayers where !needed.contains(tile) {
            layer.removeFromSuperlayer()
            tileLayers[tile] = nil
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
                layer.isOpaque = true
                layer.contentsScale = scale
                layer.backgroundColor = Self.tilePlaceholderColor.cgColor
                tileLayers[tile] = layer
                tileHostLayer.insertSublayer(layer, below: gridLayer)
            }
            layer.frame = frame
        }
        CATransaction.commit()

        requestMissingTiles(needed: needed, provider: provider)
        renderGrid(zoom: zoom)
        refreshOverlay()
        reportViewport(visibleTiles: needed.count)
    }

    private func requestMissingTiles(needed: Set<SlippyTile>, provider: TileProvider) {
        let currentGeneration = generation
        let outstanding = tileTasks.count
        var pending: [SlippyTile] = needed.filter { tile in
            tileLayers[tile]?.contents == nil
                && tileTasks[tile] == nil
                && !missingTiles.contains(tile)
                && !requestedTiles.contains(tile)
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
            requestedTiles.insert(tile)
            tileTasks[tile] = Task { @MainActor [weak self] in
                guard let self else { return }
                let image = await provider.image(for: tile)
                guard self.generation == currentGeneration else { return }
                self.tileTasks[tile] = nil
                guard let image else {
                    self.missingTiles.insert(tile)
                    self.publishTileStats()
                    return
                }
                if let layer = self.tileLayers[tile] {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.contents = image
                    layer.backgroundColor = nil
                    CATransaction.commit()

                    // 首次出现在屏幕上的瓦片淡入，避免成片「跳」出来。
                    if self.shownTiles.insert(tile).inserted {
                        let fade = CABasicAnimation(keyPath: "opacity")
                        fade.fromValue = 0
                        fade.toValue = 1
                        fade.duration = 0.18
                        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        layer.add(fade, forKey: "fadeIn")
                        if self.shownTiles.count > 20_000 {
                            self.shownTiles.removeAll(keepingCapacity: true)
                        }
                    }
                }
                self.publishTileStats()
            }
        }
        if requestedTiles.count > 100_000 { requestedTiles.removeAll(keepingCapacity: true) }
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
        let loaded = tileLayers.values.filter { $0.contents != nil }.count
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
            camera = camera.zoomed(by: factor, anchorViewPoint: point).clamped(zoomLevelRange: zoomBounds)
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
        camera = camera.zoomed(by: factor, anchorViewPoint: point).clamped(zoomLevelRange: zoomBounds)
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
