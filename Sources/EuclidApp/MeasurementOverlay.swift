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

    private struct StrokePair {
        let halo: CAShapeLayer
        let line: CAShapeLayer
    }

    private var strokePairs: [StrokePair] = []
    private var fillLayers: [CAShapeLayer] = []
    private var vertexLayers: [CAShapeLayer] = []
    private var labelLayers: [CATextLayer] = []

    private var strokeIndex = 0
    private var fillIndex = 0
    private var vertexIndex = 0
    private var labelIndex = 0

    private var contentsScale: CGFloat = 2

    init() {
        hostLayer.isGeometryFlipped = true
        hostLayer.masksToBounds = true
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
        measurements: [GeoMeasurement],
        selectedID: UUID?,
        liveCoordinate: GeoCoordinate?,
        camera: MapCamera,
        showLabels: Bool
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        hostLayer.frame = CGRect(origin: .zero, size: camera.viewportSize)
        strokeIndex = 0
        fillIndex = 0
        vertexIndex = 0
        labelIndex = 0

        for measurement in measurements {
            let selected = measurement.id == selectedID
            let color = MeasurementPalette.color(at: measurement.colorIndex)
            let points = measurement.points.map { layerPoint($0, camera: camera) }
            draw(
                kind: measurement.kind,
                points: points,
                coordinates: measurement.points,
                color: color,
                isDraft: false,
                segmented: showLabels && selected,
                summarized: showLabels,
                prominent: selected,
                camera: camera
            )
        }

        if !draft.isEmpty {
            let color = MeasurementPalette.color(at: draftKind == .area ? 2 : 0)
            var coordinates = draft
            var points = coordinates.map { layerPoint($0, camera: camera) }
            if let liveCoordinate, draftKind != .point {
                coordinates.append(liveCoordinate)
                points.append(layerPoint(liveCoordinate, camera: camera))
            }
            draw(
                kind: draftKind,
                points: points,
                coordinates: coordinates,
                color: color,
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
    }

    // MARK: - 绘制

    private func draw(
        kind: MeasurementKind,
        points: [CGPoint],
        coordinates: [GeoCoordinate],
        color: NSColor,
        isDraft: Bool,
        segmented: Bool,
        summarized: Bool,
        prominent: Bool,
        camera: MapCamera
    ) {
        let path = CGMutablePath()
        if points.count >= 2 {
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            if kind == .area, points.count >= 3 {
                path.closeSubpath()
            }
            let pair = dequeueStroke()
            pair.halo.path = path
            pair.halo.strokeColor = NSColor.white.withAlphaComponent(prominent ? 0.9 : 0.75).cgColor
            pair.halo.lineWidth = prominent ? 6 : 5
            pair.line.path = path
            pair.line.strokeColor = color.cgColor
            pair.line.lineWidth = prominent ? 2.3 : 1.8
        }

        if kind == .area, points.count >= 3 {
            let fillPath = CGMutablePath()
            fillPath.move(to: points[0])
            for point in points.dropFirst() {
                fillPath.addLine(to: point)
            }
            fillPath.closeSubpath()
            let fill = dequeueFill()
            fill.path = fillPath
            fill.fillColor = color.withAlphaComponent(prominent ? 0.18 : 0.11).cgColor
        }

        if !points.isEmpty {
            let vertices = CGMutablePath()
            let radius: CGFloat = isDraft ? 4.5 : 4
            for (index, point) in points.enumerated() {
                // 草稿的最后一个点是实时预览点，用空心圆区分。
                let isLivePreview = isDraft && index == points.count - 1 && points.count > 1
                let radius = isLivePreview ? radius - 0.5 : radius
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
            layer.strokeColor = color.cgColor
            layer.lineWidth = prominent ? 2 : 1.6
        }

        guard !coordinates.isEmpty else { return }

        if segmented, coordinates.count >= 2 {
            let result = MeasurementCalculator.evaluate(kind: kind, points: coordinates)
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
                    color: color,
                    prominent: false
                )
            }
        }

        if summarized {
            let result = MeasurementCalculator.evaluate(kind: kind, points: coordinates)
            let summary: String
            switch kind {
            case .point:
                summary = coordinates.first.map { CoordinateText.decimal($0, precision: 6) } ?? ""
            case .distance:
                summary = "总长 " + MeasureFormat.distance(result.totalLength)
            case .area:
                summary = result.area.map { "面积 " + MeasureFormat.area($0) } ?? "周长 " + MeasureFormat.distance(result.totalLength)
            }
            guard !summary.isEmpty else { return }
            let anchor: CGPoint
            if kind == .area, let centroid = MeasurementCalculator.centroid(of: coordinates) {
                anchor = layerPoint(centroid, camera: camera)
            } else if let last = points.last {
                anchor = CGPoint(x: last.x, y: last.y + 20)
            } else {
                return
            }
            addLabel(text: summary, at: anchor, color: color, prominent: prominent)
        }
    }

    private func layerPoint(_ coordinate: GeoCoordinate, camera: MapCamera) -> CGPoint {
        let world = WebMercator.normalized(coordinate)
        let view = camera.viewPoint(forWorldPoint: world)
        return CGPoint(x: view.x, y: camera.viewportSize.height - view.y)
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
