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

    /// 下层：在线底图（作为参考底图）。
    private let onlineStack = TileLayerStack()
    /// 上层：本地影像（正在判读/量测的那份）。
    private let localStack = TileLayerStack()
    private var dataset: TileDataset?
    /// 适配窗口用的默认范围（数据范围算出来之前 / 在线底图）。
    private var defaultFitRect: CGRect?
    /// 在线底图的适配范围（没有本地数据时用它对齐窗口）。
    private var onlineFitRect: CGRect?
    /// 数据集已就位但数据范围还在算：这段时间不铺图（见 `setLocal`）。
    private var awaitingExtent = false
    private var extentRect: CGRect?
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
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        // 下层在线底图、上层本地影像；两层共用同一个相机，叠加显示时天然同步。
        for stack in [onlineStack, localStack] {
            stack.needsSync = { [weak self] in self?.syncLayers() }
            stack.refreshGridAppearance()
            layer?.addSublayer(stack.hostLayer)
        }
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
        for stack in [onlineStack, localStack] { stack.refreshGridAppearance() }
        CATransaction.commit()
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
    private static let worldRect = CGRect(
        x: 0,
        y: 0,
        width: 1,
        height: WebMercator.normalizedY(latitude: WebMercator.maxLatitude)
            - WebMercator.normalizedY(latitude: -WebMercator.maxLatitude)
    )

    /// 本地影像层（上层）。传 nil 表示关掉这一层。
    func setLocal(dataset: TileDataset?, extent: DatasetExtent?) {
        guard let dataset else {
            self.dataset = nil
            localStack.clear()
            awaitingExtent = false
            extentRect = nil
            defaultFitRect = nil
            refreshCamera(fitRect: nil, defaultZoomLevel: nil)
            updateAccessibilityLabel()
            syncLayers()
            return
        }
        self.dataset = dataset
        localStack.configure(
            source: dataset.source,
            name: dataset.name,
            tileSize: dataset.layout.tileSize,
            zoomRange: dataset.zoomRange,
            followsDisplayScale: false,
            maximumDataZoom: Double(dataset.zoomRange.upperBound)
        )
        extentRect = extent?.worldRect
        defaultFitRect = extent?.worldRect
        // 数据范围还没算出来时，相机只能停在数据集之外，此刻铺出来的只会是一屏空占位，
        // 白读磁盘，而且范围一到画面必然整体跳一次。等 `setExtent` 到了再开始铺。
        awaitingExtent = extent == nil
        refreshCamera(fitRect: extent?.worldRect, defaultZoomLevel: nil)
        updateAccessibilityLabel()
        syncLayers()
    }

    /// 在线底图层（下层）。传 nil 表示关掉这一层。
    func setOnline(basemap: OnlineBasemap?, fitRect: CGRect?) {
        onlineFitRect = fitRect
        guard let basemap, basemap.isValid else {
            onlineStack.clear()
            refreshCamera(fitRect: nil, defaultZoomLevel: nil)
            updateAccessibilityLabel()
            syncLayers()
            return
        }
        onlineStack.configure(
            source: basemap.makeSource(),
            name: basemap.name,
            tileSize: basemap.tileSize,
            zoomRange: basemap.zoomRange,
            followsDisplayScale: true,
            maximumDataZoom: Double(basemap.zoomRange.upperBound),
            memoryLimitBytes: 256 * 1024 * 1024,
            maxConcurrentRequests: 24
        )
        updateAccessibilityLabel()
        // 已经有本地数据时不打断当前视图；只有在线底图时按它的范围适配一次。
        refreshCamera(fitRect: localStack.isActive ? nil : (fitRect ?? Self.worldRect),
                      defaultZoomLevel: 2)
        syncLayers()
    }

    /// 两层的不透明度：把上层影像淡下去就能看到下层的路网做对照。
    func setLayerOpacity(local: Double, online: Double) {
        localStack.opacity = local
        onlineStack.opacity = online
    }

    /// 依据当前激活的图层重配相机（瓦片边长、缩放上下限，以及可选的窗口适配）。
    private func refreshCamera(fitRect: CGRect?, defaultZoomLevel: Double?) {
        camera.displayScale = displayScale
        camera.viewportSize = bounds.size
        // 相机里的瓦片边长跟着「上层」走：本地影像按设备像素 1:1，只有在线时才按地图约定。
        let primary = localStack.isActive ? localStack : onlineStack
        camera.tilePixelSize = primary.isActive ? primary.cameraTileSize(displayScale: displayScale) : 512

        let rect = fitRect ?? (localStack.isActive ? defaultFitRect : nil) ?? onlineFitRect
        let fitCamera = rect.map {
            MapCamera.fitting(
                $0,
                viewportSize: bounds.size,
                padding: 28,
                tilePixelSize: camera.tilePixelSize,
                displayScale: camera.displayScale
            )
        } ?? camera.settingZoomLevel(defaultZoomLevel ?? camera.zoomLevel)

        // 上下限取两层的并集：更深的源决定能放多大，浅的那层靠祖先贴图兜底。
        // 两层都没装配时给一个宽松范围，免得算成空区间（`ClosedRange` 会直接崩）。
        var upper = 26.0
        var hasActive = false
        for stack in [onlineStack, localStack] where stack.isActive {
            upper = hasActive ? max(upper, stack.zoomLevelRange.upperBound) : stack.zoomLevelRange.upperBound
            hasActive = true
        }
        let lower = min(max(-2, fitCamera.zoomLevel - 1.2), upper - 0.001)
        zoomBounds = lower...upper
        camera = fitCamera.clamped(zoomLevelRange: zoomBounds)
    }

    /// 画布是自绘的，给读屏一个可读的名字与当前层级。
    private func updateAccessibilityLabel() {
        let name = localStack.isActive ? localStack.name : (onlineStack.isActive ? onlineStack.name : "")
        guard !name.isEmpty else {
            setAccessibilityLabel("地图画布，暂无内容")
            setAccessibilityValue(nil)
            return
        }
        let overlay = (localStack.isActive && onlineStack.isActive) ? "，叠加在线底图" : ""
        setAccessibilityLabel("地图画布：\(name)\(overlay)")
        setAccessibilityValue("z\(currentDataZoom)")
    }

    /// 本地数据范围算好之后对齐窗口（只影响本地层，不打断已经铺好的其他层）。
    func setExtent(_ extent: DatasetExtent?) {
        guard dataset != nil else { return }
        awaitingExtent = false
        extentRect = extent?.worldRect
        defaultFitRect = extent?.worldRect ?? defaultFitRect
        // 范围算失败（nil）也要同步一次，让画面退回默认视图，而不是一直空着。
        guard let extent else {
            syncLayers()
            return
        }
        refreshCamera(fitRect: extent.worldRect, defaultZoomLevel: nil)
        syncLayers()
    }

    /// 适配窗口：优先本地数据范围，其次在线底图范围。
    func fitToData() {
        guard localStack.isActive || onlineStack.isActive else { return }
        guard !awaitingExtent || extentRect != nil else { return }
        let rect = (localStack.isActive ? (extentRect ?? defaultFitRect) : nil)
            ?? onlineFitRect
            ?? Self.worldRect
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
        let primary = localStack.isActive ? localStack : onlineStack
        guard primary.isActive else { return }
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
        for stack in [onlineStack, localStack] { stack.hostLayer.frame = bounds }
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
        for stack in [onlineStack, localStack] { stack.setContentsScale(CGFloat(scale)) }
        overlay.setContentsScale(CGFloat(scale))
        refreshOverlay()
        syncLayers()
    }

    /// 当前主图层（上层）正在渲染的整数层级。
    private var currentDataZoom: Int {
        let primary = localStack.isActive ? localStack : onlineStack
        guard primary.isActive else { return 0 }
        return primary.dataZoom(for: camera)
    }

    /// 把两条图层都同步一遍：下层先铺，上层后铺，叠加顺序天然正确。
    private func syncLayers() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size
        for stack in [onlineStack, localStack] { stack.updateSortCenter(camera.center) }

        let active = localStack.isActive || onlineStack.isActive
        guard active, !awaitingExtent else {
            _ = onlineStack.sync(camera: camera, viewportSize: bounds.size, displayScale: displayScale, showGrid: false)
            _ = localStack.sync(camera: camera, viewportSize: bounds.size, displayScale: displayScale, showGrid: false)
            refreshOverlay()
            reportViewport(visibleTiles: 0)
            return
        }

        // 网格画在最上面那层（你正在判读的那份瓦片）。
        let gridOwner = localStack.isActive ? localStack : onlineStack
        var frames: [TileLayerFrame] = []
        var visibleTiles = 0
        var loadedTiles = 0
        var missingTiles = 0
        for stack in [onlineStack, localStack] where stack.isActive {
            let frame = stack.sync(
                camera: camera,
                viewportSize: bounds.size,
                displayScale: displayScale,
                showGrid: showTileGrid && stack === gridOwner
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
        onTileStatsChanged?(loadedTiles, missingTiles)
        reportViewport(visibleTiles: visibleTiles)
        setAccessibilityValue("z\(currentDataZoom)")
    }

    /// 把当前视图状态汇报给界面（状态栏、检查器）。
    private func reportViewport(visibleTiles: Int) {
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
        let line = String(
            format: "[view] %@ z=%.2f 层级=%d 范围=%.2f…%.2f 需要=%d 已载入=%d 祖先兜底=%d 缺片=%d 瓦片边长=%.0fpt 中心=(%.5f,%.5f)\n",
            layer.name, camera.zoomLevel, layer.zoom,
            zoomBounds.lowerBound, zoomBounds.upperBound,
            layer.needed, layer.loaded, layer.fallback, layer.missing,
            layer.tileDisplaySize, camera.center.x, camera.center.y
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
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
