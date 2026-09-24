import AppKit
import QuartzCore
import TileKit

/// 测量标注的图层渲染。
///
/// 每条测量使用独立的描边/填充/顶点图层，因此各自配色互不影响；
/// 图层用池化复用，滚动时不会反复创建。
@MainActor
final class MeasurementOverlay {
    let hostLayer = CALayer()
    /// 指针悬停顶点的提示环。
    private let hoverLayer = CAShapeLayer()

    private struct StrokePair {
        let halo: CAShapeLayer
        let line: CAShapeLayer
    }

    private var strokePairs: [StrokePair] = []
    private var fillLayers: [CAShapeLayer] = []
    private var vertexLayers: [CAShapeLayer] = []
    private var labelLayers: [CATextLayer] = []
    /// 圆的半径辅助线，单独一层，避免和描边图层抢用。
    private var radiusLayers: [CAShapeLayer] = []

    private var strokeIndex = 0
    private var fillIndex = 0
    private var vertexIndex = 0
    private var labelIndex = 0
    private var radiusIndex = 0

    private var contentsScale: CGFloat = 2

    /// 圆周采样点缓存：采样只跟圆心与半径有关，平移缩放时可以整段复用。
    private struct RingCacheEntry {
        var center: GeoCoordinate
        var radius: Double
        var ring: [GeoCoordinate]
    }

    private var ringCache: [UUID: RingCacheEntry] = [:]

    init() {
        hostLayer.isGeometryFlipped = true
        hostLayer.masksToBounds = true

        hoverLayer.fillColor = nil
        hoverLayer.lineWidth = 1.5
        hoverLayer.strokeColor = NSColor.controlAccentColor.cgColor
        hoverLayer.isHidden = true
    }

    func setContentsScale(_ scale: CGFloat) {
        contentsScale = scale
        for layer in labelLayers {
            layer.contentsScale = scale
        }
    }

    func update(
        draft: [GeoCoordinate],
        draftKind: MeasurementKind,
        draftStyle: MeasurementStyle,
        measurements: [GeoMeasurement],
        selectedID: UUID?,
        liveCoordinate: GeoCoordinate?,
        hoveredVertex: GeoCoordinate?,
        camera: MapCamera,
        showLabels: Bool
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        hostLayer.frame = CGRect(origin: .zero, size: camera.viewportSize)
        hoverLayer.isHidden = true
        strokeIndex = 0
        fillIndex = 0
        vertexIndex = 0
        labelIndex = 0
        radiusIndex = 0

        for measurement in measurements {
            let selected = measurement.id == selectedID
            draw(
                kind: measurement.kind,
                coordinates: measurement.points,
                cacheKey: measurement.id,
                stroke: MeasurementPalette.strokeColor(of: measurement),
                fill: MeasurementPalette.resolvedFillColor(of: measurement),
                lineWidth: MeasurementPalette.lineWidth(of: measurement),
                isDraft: false,
                segmented: showLabels && selected,
                summarized: showLabels,
                prominent: selected,
                camera: camera
            )
        }

        if !draft.isEmpty {
            let paletteIndex = draftKind == .area ? 2 : 0
            var coordinates = draft
            if let liveCoordinate, draftKind != .point {
                coordinates.append(liveCoordinate)
            }
            draw(
                kind: draftKind,
                coordinates: coordinates,
                cacheKey: nil,
                stroke: MeasurementPalette.draftStrokeColor(at: paletteIndex, style: draftStyle),
                fill: MeasurementPalette.draftFillColor(at: paletteIndex, style: draftStyle),
                lineWidth: CGFloat(draftStyle.sanitized().strokeWidth),
                isDraft: true,
                segmented: showLabels,
                summarized: showLabels,
                prominent: true,
                camera: camera
            )
        }

        for index in strokeIndex..<strokePairs.count {
            strokePairs[index].halo.isHidden = true
            strokePairs[index].line.isHidden = true
        }
        for index in fillIndex..<fillLayers.count {
            fillLayers[index].isHidden = true
        }
        for index in vertexIndex..<vertexLayers.count {
            vertexLayers[index].isHidden = true
        }
        for index in labelIndex..<labelLayers.count {
            labelLayers[index].isHidden = true
        }
        for index in radiusIndex..<radiusLayers.count {
            radiusLayers[index].isHidden = true
        }

        if let hoveredVertex {
            let point = layerPoint(hoveredVertex, camera: camera)
            let radius: CGFloat = 9
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            hoverLayer.path = path
            hoverLayer.strokeColor = NSColor.controlAccentColor.cgColor
            hoverLayer.isHidden = false
            // 移到最上层，保证提示环不被其它标注盖住。
            hostLayer.addSublayer(hoverLayer)
        }
    }

    // MARK: - 绘制

    private func draw(
        kind: MeasurementKind,
        coordinates: [GeoCoordinate],
        cacheKey: UUID?,
        stroke: NSColor,
        fill: NSColor,
        lineWidth: CGFloat,
        isDraft: Bool,
        segmented: Bool,
        summarized: Bool,
        prominent: Bool,
        camera: MapCamera
    ) {
        let points = coordinates.map { layerPoint($0, camera: camera) }
        let outlined = kind == .circle
        // 圆的圆周、周长与面积共用同一组采样点；缓存后平移缩放不必重复测地计算。
        var circleMetrics: MeasurementCalculator.CircleMetrics?
        if outlined, coordinates.count >= 2 {
            let radius = Geodesy.distance(from: coordinates[0], to: coordinates[1])
            if radius > 0 {
                circleMetrics = MeasurementCalculator.circleMetrics(
                    center: coordinates[0],
                    radius: radius,
                    ring: cachedRing(for: cacheKey, center: coordinates[0], radius: radius)
                )
            }
        }
        let result = outlined
            ? MeasurementResult(
                segments: [],
                totalLength: circleMetrics?.circumference ?? 0,
                area: circleMetrics?.area,
                radius: circleMetrics?.radius
            )
            : MeasurementCalculator.evaluate(kind: kind, points: coordinates)

        // 描边：圆画整圈，折线/多边形按顶点连线。
        if outlined {
            if let ring = circlePath(circleMetrics?.ring ?? [], camera: camera) {
                strokePath(ring, stroke: stroke, lineWidth: lineWidth, prominent: prominent)
                fillPath(ring, fill: fill)
            }
        } else if points.count >= 2 {
            let path = CGMutablePath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            if kind == .area, points.count >= 3 {
                path.closeSubpath()
                fillPath(path, fill: fill)
            }
            strokePath(path, stroke: stroke, lineWidth: lineWidth, prominent: prominent)
        }

        // 圆的半径辅助线，方便一眼看出半径基准。
        if outlined, prominent, points.count >= 2 {
            showRadiusGuide(from: points[0], to: points[1], color: stroke)
        }

        if !points.isEmpty {
            let vertices = CGMutablePath()
            let baseRadius: CGFloat = isDraft ? 4.5 : 4
            for (index, point) in points.enumerated() {
                // 草稿的最后一个点是实时预览点，用略小的圆区分。
                let isLivePreview = isDraft && index == points.count - 1 && points.count > 1
                let radius = isLivePreview ? baseRadius - 0.5 : baseRadius
                vertices.addEllipse(in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
            let layer = dequeueVertex()
            layer.path = vertices
            layer.fillColor = NSColor.white.cgColor
            layer.strokeColor = stroke.cgColor
            layer.lineWidth = prominent ? 2 : 1.6
        }

        guard !coordinates.isEmpty else { return }

        if outlined {
            // 圆的标注：半径贴在半径线上，面积放在圆心上方。
            if let radius = result.radius, points.count >= 2 {
                let start = points[0]
                let end = points[1]
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = max(1, (dx * dx + dy * dy).squareRoot())
                let normal = CGPoint(x: -dy / length, y: dx / length)
                if segmented || prominent {
                    addLabel(
                        text: "R " + MeasureFormat.distance(radius),
                        at: CGPoint(x: mid.x + normal.x * 16, y: mid.y + normal.y * 16),
                        color: stroke,
                        prominent: false
                    )
                }
            }
        } else if segmented, coordinates.count >= 2 {
            for segment in result.segments {
                let startIndex = segment.index
                let endIndex = segment.index + 1
                guard points.indices.contains(startIndex), points.indices.contains(endIndex) else { continue }
                let start = points[startIndex]
                let end = points[endIndex]
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = max(1, (dx * dx + dy * dy).squareRoot())
                let normal = CGPoint(x: -dy / length, y: dx / length)
                let offset: CGFloat = 14
                addLabel(
                    text: MeasureFormat.distance(segment.length),
                    at: CGPoint(x: mid.x + normal.x * offset, y: mid.y + normal.y * offset),
                    color: stroke,
                    prominent: false
                )
            }
        }

        if summarized {
            let summary: String
            switch kind {
            case .point:
                summary = coordinates.first.map { CoordinateText.decimal($0, precision: 6) } ?? ""
            case .distance:
                summary = "总长 " + MeasureFormat.distance(result.totalLength)
            case .area:
                summary = result.area.map { "面积 " + MeasureFormat.area($0) }
                    ?? "周长 " + MeasureFormat.distance(result.totalLength)
            case .circle:
                var parts: [String] = []
                if let radius = result.radius {
                    parts.append("R " + MeasureFormat.distance(radius))
                }
                if let area = result.area {
                    parts.append("面积 " + MeasureFormat.area(area))
                }
                summary = parts.joined(separator: " · ")
            }
            guard !summary.isEmpty else { return }
            let anchor: CGPoint
            if kind == .area, let centroid = MeasurementCalculator.centroid(of: coordinates) {
                anchor = layerPoint(centroid, camera: camera)
            } else if kind == .circle, let center = points.first {
                anchor = CGPoint(x: center.x, y: center.y + 24)
            } else if let last = points.last {
                anchor = CGPoint(x: last.x, y: last.y + 20)
            } else {
                return
            }
            addLabel(text: summary, at: anchor, color: stroke, prominent: prominent)
        }
    }

    /// 把圆周采样点投影成屏幕路径。
    private func circlePath(_ ring: [GeoCoordinate], camera: MapCamera) -> CGPath? {
        guard ring.count >= 3 else { return nil }
        let path = CGMutablePath()
        for (index, coordinate) in ring.enumerated() {
            let point = layerPoint(coordinate, camera: camera)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    /// 取圆周采样点：命中缓存就直接复用，否则算一次并记下来。
    private func cachedRing(for key: UUID?, center: GeoCoordinate, radius: Double) -> [GeoCoordinate] {
        if let key, let entry = ringCache[key], entry.center == center,
           abs(entry.radius - radius) < 1e-9 {
            return entry.ring
        }
        let ring = Geodesy.circleRing(center: center, radius: radius)
        if let key {
            if ringCache.count > 64 { ringCache.removeAll(keepingCapacity: true) }
            ringCache[key] = RingCacheEntry(center: center, radius: radius, ring: ring)
        }
        return ring
    }

    private func strokePath(_ path: CGPath, stroke: NSColor, lineWidth: CGFloat, prominent: Bool) {
        let pair = dequeueStroke()
        pair.halo.path = path
        pair.halo.strokeColor = NSColor.white.withAlphaComponent(prominent ? 0.9 : 0.75).cgColor
        pair.halo.lineWidth = lineWidth + (prominent ? 3.6 : 3.2)
        pair.line.path = path
        pair.line.strokeColor = stroke.cgColor
        pair.line.lineWidth = prominent ? lineWidth + 0.3 : lineWidth
    }

    private func fillPath(_ path: CGPath, fill: NSColor) {
        let layer = dequeueFill()
        layer.path = path
        layer.fillColor = fill.cgColor
    }

    private func showRadiusGuide(from start: CGPoint, to end: CGPoint, color: NSColor) {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        let layer = dequeueRadius()
        layer.path = path
        layer.strokeColor = color.withAlphaComponent(0.75).cgColor
        layer.lineWidth = 1
        layer.lineDashPattern = [4, 3]
    }

    private func layerPoint(_ coordinate: GeoCoordinate, camera: MapCamera) -> CGPoint {
        camera.layerPoint(for: coordinate)
    }

    // MARK: - 图层池

    private func dequeueStroke() -> StrokePair {
        if strokeIndex < strokePairs.count {
            let pair = strokePairs[strokeIndex]
            strokeIndex += 1
            pair.halo.isHidden = false
            pair.line.isHidden = false
            return pair
        }
        let halo = CAShapeLayer()
        halo.fillColor = nil
        halo.lineJoin = .round
        halo.lineCap = .round
        let line = CAShapeLayer()
        line.fillColor = nil
        line.lineJoin = .round
        line.lineCap = .round
        hostLayer.addSublayer(halo)
        hostLayer.addSublayer(line)
        let pair = StrokePair(halo: halo, line: line)
        strokePairs.append(pair)
        strokeIndex += 1
        return pair
    }

    private func dequeueFill() -> CAShapeLayer {
        if fillIndex < fillLayers.count {
            let layer = fillLayers[fillIndex]
            fillIndex += 1
            layer.isHidden = false
            return layer
        }
        let layer = CAShapeLayer()
        hostLayer.addSublayer(layer)
        fillLayers.append(layer)
        fillIndex += 1
        return layer
    }

    private func dequeueVertex() -> CAShapeLayer {
        if vertexIndex < vertexLayers.count {
            let layer = vertexLayers[vertexIndex]
            vertexIndex += 1
            layer.isHidden = false
            return layer
        }
        let layer = CAShapeLayer()
        hostLayer.addSublayer(layer)
        vertexLayers.append(layer)
        vertexIndex += 1
        return layer
    }

    private func dequeueRadius() -> CAShapeLayer {
        if radiusIndex < radiusLayers.count {
            let layer = radiusLayers[radiusIndex]
            radiusIndex += 1
            layer.isHidden = false
            return layer
        }
        let layer = CAShapeLayer()
        layer.fillColor = nil
        hostLayer.addSublayer(layer)
        radiusLayers.append(layer)
        radiusIndex += 1
        return layer
    }

    private func dequeueLabel() -> CATextLayer {
        if labelIndex < labelLayers.count {
            let layer = labelLayers[labelIndex]
            labelIndex += 1
            layer.isHidden = false
            return layer
        }
        let layer = CATextLayer()
        layer.contentsScale = contentsScale
        hostLayer.addSublayer(layer)
        labelLayers.append(layer)
        labelIndex += 1
        return layer
    }

    private func addLabel(text: String, at position: CGPoint, color: NSColor, prominent: Bool) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: prominent ? 11.5 : 11, weight: prominent ? .semibold : .medium)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 5)

        let layer = dequeueLabel()
        layer.string = text
        layer.font = font
        layer.fontSize = font.pointSize
        layer.alignmentMode = .center
        layer.truncationMode = .none
        layer.isWrapped = false
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = position
        layer.contentsScale = contentsScale
        layer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
        layer.foregroundColor = NSColor.labelColor.cgColor
        layer.cornerRadius = 4
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = color.withAlphaComponent(prominent ? 0.75 : 0.35).cgColor
    }
}
