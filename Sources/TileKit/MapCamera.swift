import CoreGraphics
import Foundation

/// 地图相机。
///
/// 两个坐标系：
/// - 世界坐标：归一化 Web Mercator，x 向东、y 向南，范围 `0...1`。
/// - 视图坐标：NSView 坐标，原点在左下角、y 向上（视图未翻转）。
public struct MapCamera: Sendable, Equatable {
    /// 视图中心对应的世界坐标。
    public var center: CGPoint
    /// 一个归一化世界单位对应多少视图点。
    public var pixelsPerWorldUnit: Double
    public var viewportSize: CGSize
    /// 该数据集单个瓦片的像素边长。
    public var tilePixelSize: Double

    public init(center: CGPoint, pixelsPerWorldUnit: Double, viewportSize: CGSize, tilePixelSize: Double) {
        self.center = center
        self.pixelsPerWorldUnit = pixelsPerWorldUnit
        self.viewportSize = viewportSize
        self.tilePixelSize = max(1, tilePixelSize)
    }

    public init(center: CGPoint, zoomLevel: Double, viewportSize: CGSize, tilePixelSize: Double) {
        let size = max(1, tilePixelSize)
        self.init(
            center: center,
            pixelsPerWorldUnit: pow(2, zoomLevel) * size,
            viewportSize: viewportSize,
            tilePixelSize: size
        )
    }

    // MARK: - 缩放

    public var zoomLevel: Double {
        log2(pixelsPerWorldUnit / tilePixelSize)
    }

    /// 以某个视图点为锚点缩放（锚点下的地理坐标保持不变）。
    public func settingZoomLevel(_ level: Double, anchorViewPoint: CGPoint? = nil) -> MapCamera {
        var camera = self
        let anchor = anchorViewPoint ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let anchorWorld = worldPoint(forViewPoint: anchor)
        camera.pixelsPerWorldUnit = pow(2, level) * tilePixelSize
        let anchorAfter = camera.viewPoint(forWorldPoint: anchorWorld)
        camera.center.x += (anchorAfter.x - anchor.x) / camera.pixelsPerWorldUnit
        camera.center.y -= (anchorAfter.y - anchor.y) / camera.pixelsPerWorldUnit
        return camera
    }

    public func zoomed(by factor: Double, anchorViewPoint: CGPoint? = nil) -> MapCamera {
        settingZoomLevel(zoomLevel + log2(factor), anchorViewPoint: anchorViewPoint)
    }

    /// 视图内容随手指/鼠标移动 `delta` 点。
    public func translated(byViewDelta delta: CGPoint) -> MapCamera {
        var camera = self
        camera.center.x -= delta.x / pixelsPerWorldUnit
        camera.center.y += delta.y / pixelsPerWorldUnit
        return camera
    }

    // MARK: - 变换

    public func viewPoint(forWorldPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - center.x) * pixelsPerWorldUnit + viewportSize.width / 2,
            y: (center.y - point.y) * pixelsPerWorldUnit + viewportSize.height / 2
        )
    }

    public func worldPoint(forViewPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + (point.x - viewportSize.width / 2) / pixelsPerWorldUnit,
            y: center.y - (point.y - viewportSize.height / 2) / pixelsPerWorldUnit
        )
    }

    public func coordinate(forViewPoint point: CGPoint) -> GeoCoordinate {
        WebMercator.coordinate(fromNormalized: worldPoint(forViewPoint: point))
    }

    /// 图层坐标（y 向下，与 `isGeometryFlipped` 的子层一致）。
    ///
    /// 瓦片层与测量标注层共用这套换算，实现只保留在这里。
    public func layerPoint(forWorldPoint point: CGPoint) -> CGPoint {
        let view = viewPoint(forWorldPoint: point)
        return CGPoint(x: view.x, y: viewportSize.height - view.y)
    }

    public func layerPoint(for coordinate: GeoCoordinate) -> CGPoint {
        layerPoint(forWorldPoint: WebMercator.normalized(coordinate))
    }

    /// 让指定的世界范围（含内边距）完整落入视图。
    public func fitting(_ worldRect: CGRect, padding: Double = 28) -> MapCamera {
        MapCamera.fitting(
            worldRect,
            viewportSize: viewportSize,
            padding: padding,
            tilePixelSize: tilePixelSize
        )
    }

    /// 当前视图覆盖的世界范围（minY 为北边界）。
    public var visibleWorldRect: CGRect {
        let halfWidth = viewportSize.width / 2 / pixelsPerWorldUnit
        let halfHeight = viewportSize.height / 2 / pixelsPerWorldUnit
        return CGRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    /// 当前视图中心处一个视图点对应的实地米数。
    public var groundMetersPerPoint: Double {
        let latitude = WebMercator.latitude(normalizedY: center.y)
        return WebMercator.groundMetersPerWorldUnit(latitude: latitude) / pixelsPerWorldUnit
    }

    // MARK: - 可见瓦片

    public func tileColumnRange(zoom: Int) -> ClosedRange<Int>? {
        tileRange(zoom: zoom, min: visibleWorldRect.minX, max: visibleWorldRect.maxX)
    }

    public func tileRowRange(zoom: Int) -> ClosedRange<Int>? {
        tileRange(zoom: zoom, min: visibleWorldRect.minY, max: visibleWorldRect.maxY)
    }

    private func tileRange(zoom: Int, min lower: Double, max upper: Double) -> ClosedRange<Int>? {
        let n = Double(1 << zoom)
        guard n > 0 else { return nil }
        let first = Int(floor(lower * n))
        let last = Int(ceil(upper * n)) - 1
        guard first <= last else { return nil }
        let clampedFirst = max(0, first)
        let clampedLast = min(Int(n) - 1, last)
        guard clampedFirst <= clampedLast else { return nil }
        return clampedFirst...clampedLast
    }

    /// 让 `worldRect` 完整落入视图。
    public static func fitting(
        _ worldRect: CGRect,
        viewportSize: CGSize,
        padding: Double = 24,
        tilePixelSize: Double
    ) -> MapCamera {
        let availableWidth = max(1, viewportSize.width - padding * 2)
        let availableHeight = max(1, viewportSize.height - padding * 2)
        let width = max(worldRect.width, 1e-9)
        let height = max(worldRect.height, 1e-9)
        let scale = min(availableWidth / width, availableHeight / height)
        return MapCamera(
            center: CGPoint(x: worldRect.midX, y: worldRect.midY),
            pixelsPerWorldUnit: scale,
            viewportSize: viewportSize,
            tilePixelSize: tilePixelSize
        )
    }

    public func clamped(zoomLevelRange: ClosedRange<Double>) -> MapCamera {
        var camera = self
        let zoom = min(max(zoomLevel, zoomLevelRange.lowerBound), zoomLevelRange.upperBound)
        camera.pixelsPerWorldUnit = pow(2, zoom) * tilePixelSize
        return camera
    }
}
