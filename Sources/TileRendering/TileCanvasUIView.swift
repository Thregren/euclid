#if os(iOS)
import TileKit
import UIKit

/// iPhone / iPad 画布适配器；瓦片加载、兜底和图层装配共用 TileLayerStack。
/// 移动应用可直接嵌入 UIView，或由 UIViewRepresentable 托管。
@MainActor
public final class TileCanvasUIView: UIView, UIGestureRecognizerDelegate {
    public let tileStack = TileLayerStack(flipsGeometry: false)
    public private(set) var camera = MapCamera(
        center: CGPoint(x: 0.5, y: 0.5), zoomLevel: 1,
        viewportSize: .zero, tilePixelSize: 512
    )
    public var onCoordinateTapped: ((GeoCoordinate) -> Void)?
    public var onViewportChanged: ((MapCamera) -> Void)?
    public var showsGrid = false { didSet { sync() } }
    private var sourceExtent: CGRect?
    private var needsFit = false
    private var panning = false
    private var pinching = false
    private var zoomBounds: ClosedRange<Double> = 0...22
    private var lastReportedCamera: MapCamera?
    private var suspended = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        prepare()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepare()
    }

    private func prepare() {
        clipsToBounds = true
        backgroundColor = .systemBackground
        layer.addSublayer(tileStack.hostLayer)
        tileStack.needsSync = { [weak self] in self?.sync() }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pan.delegate = self
        pinch.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
        isAccessibilityElement = true
        accessibilityLabel = "影像地图"
        accessibilityTraits = [.image]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "放大", target: self, selector: #selector(performAccessibilityZoomIn)),
            UIAccessibilityCustomAction(name: "缩小", target: self, selector: #selector(performAccessibilityZoomOut)),
            UIAccessibilityCustomAction(name: "适应影像范围", target: self, selector: #selector(accessibilityFit)),
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(handleMemoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(suspendRequests),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeRequests),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    public func setSource(
        _ source: any TileImageSource, name: String, tileSize: Int = 512,
        grid: TileGrid = .webMercator, worldRect: CGRect? = nil,
        followsDisplayScale: Bool = false, maximumDataZoom: Double? = nil,
        initialCamera: MapCamera? = nil
    ) {
        let range = source.availableZoomRange
        tileStack.configure(source: source, name: name, tileSize: tileSize,
                            zoomRange: range, grid: grid, followsDisplayScale: followsDisplayScale,
                            maximumDataZoom: maximumDataZoom ?? Double(range.upperBound),
                            memoryLimitBytes: TileResourcePolicy.defaultTileCacheBytes,
                            maxConcurrentRequests: TileResourcePolicy.concurrentDecodes)
        sourceExtent = worldRect
        needsFit = initialCamera == nil && worldRect != nil
        lastReportedCamera = nil
        camera.tilePixelSize = tileStack.cameraTileSize(displayScale: camera.displayScale)
        if let initialCamera { setCamera(initialCamera) } else { sync() }
    }

    public func clearSource() {
        tileStack.clear()
        sourceExtent = nil
        needsFit = false
    }

    public func setCamera(_ camera: MapCamera) {
        guard camera.pixelsPerWorldUnit.isFinite, camera.pixelsPerWorldUnit > 0,
              camera.center.x.isFinite, camera.center.y.isFinite else { return }
        self.camera = camera
        sync()
    }

    public func fitToData() {
        needsFit = sourceExtent != nil
        sync()
    }

    public func zoom(by factor: Double, at point: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        camera = camera.zoomed(by: factor, anchorViewPoint: point.map { camera.viewPoint(forLayerPoint: $0) },
                               zoomLevelRange: zoomBounds)
        sync()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        sync()
    }

    private func sync() {
        guard !suspended, bounds.width > 1, bounds.height > 1 else { return }
        camera.viewportSize = bounds.size
        camera.displayScale = max(1, traitCollection.displayScale)
        camera.tilePixelSize = tileStack.cameraTileSize(displayScale: camera.displayScale)
        let lower = tileStack.affordableCameraZoom(viewportSize: bounds.size, displayScale: camera.displayScale)
        let fittedCamera = sourceExtent.flatMap { rect -> MapCamera? in
            guard rect.width > 0, rect.height > 0,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.midX.isFinite, rect.midY.isFinite else { return nil }
            return camera.fitting(rect)
        }
        let dataLimit = tileStack.zoomLevelRange.upperBound
        let upper = fittedCamera.map {
            TileLayerStack.rasterCameraZoomLimit(dataLimit: dataLimit, fittedZoom: $0.zoomLevel)
        } ?? dataLimit
        zoomBounds = lower...max(lower, upper, camera.zoomLevel)
        if needsFit, let fittedCamera {
            camera = fittedCamera
            needsFit = false
        }
        // The display can resize or change scale when a window moves or folds. Retain the
        // geographic center and map points per world unit between input gestures.
        tileStack.reducesMotion = UIAccessibility.isReduceMotionEnabled
        tileStack.isInteracting = panning || pinching
        tileStack.updateSortCenter(camera.center)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileStack.hostLayer.frame = bounds
        _ = tileStack.sync(camera: camera, viewportSize: bounds.size, displayScale: camera.displayScale,
                           showGrid: showsGrid)
        CATransaction.commit()
        let value = "层级 \(Int(camera.zoomLevel.rounded()))"
        if accessibilityValue != value { accessibilityValue = value }
        if lastReportedCamera != camera {
            lastReportedCamera = camera
            onViewportChanged?(camera)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        panning = recognizer.state == .began || recognizer.state == .changed
        let delta = recognizer.translation(in: self)
        camera = camera.translated(byLayerDelta: delta)
        recognizer.setTranslation(.zero, in: self)
        sync()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        pinching = recognizer.state == .began || recognizer.state == .changed
        zoom(by: recognizer.scale, at: recognizer.location(in: self))
        recognizer.scale = 1
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onCoordinateTapped?(camera.coordinate(forLayerPoint: recognizer.location(in: self)))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        zoom(by: 2, at: recognizer.location(in: self))
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
            || (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }

    @objc private func handleMemoryWarning() {
        tileStack.cancelRequests()
        tileStack.trimCache(toFraction: 0.25)
        Task { await TileResourceManager.handleMemoryPressure(critical: true) }
        RasterCache.trim(toFraction: 0.25)
    }

    @objc private func suspendRequests() { suspended = true; tileStack.cancelRequests() }
    @objc private func resumeRequests() { suspended = false; sync() }
    @objc private func performAccessibilityZoomIn() -> Bool { zoom(by: 2); return true }
    @objc private func performAccessibilityZoomOut() -> Bool { zoom(by: 0.5); return true }
    public override func accessibilityZoomIn(at point: CGPoint) -> Bool { zoom(by: 2, at: point); return true }
    public override func accessibilityZoomOut(at point: CGPoint) -> Bool { zoom(by: 0.5, at: point); return true }
    @objc private func accessibilityFit() -> Bool {
        guard sourceExtent != nil else { return false }
        fitToData()
        return true
    }

    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let delta: CGPoint
        switch direction {
        case .left: delta = CGPoint(x: -bounds.width / 2, y: 0)
        case .right: delta = CGPoint(x: bounds.width / 2, y: 0)
        case .up: delta = CGPoint(x: 0, y: -bounds.height / 2)
        case .down: delta = CGPoint(x: 0, y: bounds.height / 2)
        default: return false
        }
        camera = camera.translated(byLayerDelta: delta)
        sync()
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }
}
#endif
