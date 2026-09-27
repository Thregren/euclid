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
    /// 面积显示单位（由 `update(...)` 每次带进来）。
    private var areaUnit: MeasureFormat.AreaUnit = .automatic

    /// 上一次绘制时的输入：用来判断「哪些东西真的变了」。
    ///
    /// 画测距 / 画圆时指针每移动一次都会调 `update`，而**已完成的那些测量完全没变**。
    /// 逐条重画它们（每个顶点、每段文字、每个标签底色）纯属白做：实测这项占掉每次
    /// 指针移动的大头，测量条数越多越明显。所以这里把输入拆成「静态部分」与「草稿 + 悬停」，
    /// 静态部分没变就跳过，只重画草稿那一小段。
    private struct StaticInputs: Equatable {
        var camera: MapCamera
        var measurements: [GeoMeasurement]
        var selectedID: UUID?
        var showLabels: Bool
        var areaUnit: MeasureFormat.AreaUnit
    }

    private struct DraftInputs: Equatable {
        var kind: MeasurementKind
        var style: MeasurementStyle
        var points: [GeoCoordinate]
        var liveCoordinate: GeoCoordinate?
        var hoveredVertex: GeoCoordinate?
    }

    private var lastStaticInputs: StaticInputs?
    private var lastDraftInputs: DraftInputs?
    /// 上一次全量绘制结束时，静态部分各占了多少个图层（草稿从这些位置往后接着用）。
    private var staticStrokeCount = 0
    private var staticFillCount = 0
    private var staticVertexCount = 0
    private var staticLabelCount = 0
    private var staticRadiusCount = 0

    /// 丢掉「上次画了什么」的记忆，下一次 `update` 必然全量重画。
    ///
    /// 外观、图层顺序这类不在 `update` 参数里的东西变了之后要调它，
    /// 否则会留下上一次配色/位置的旧图层。
    func invalidateCache() {
        lastStaticInputs = nil
        lastDraftInputs = nil
    }

    /// 解析过的语义色（跟随界面外观）：每个标签都要用「底色 + 字色」两个，
    /// 而解析一次要切一次外观上下文（`performAsCurrentDrawingAppearance`），
    /// 一屏几十个标签乘下来相当可观 —— 按外观缓存住。
    private var cachedLabelColors: (appearance: NSAppearance, background: CGColor, foreground: CGColor)?

    private func labelColors() -> (background: CGColor, foreground: CGColor) {
        if let cached = cachedLabelColors, cached.appearance == appearance {
            return (cached.background, cached.foreground)
        }
        let background = NSColor.controlBackgroundColor
            .withAlphaComponent(0.94)
            .resolvedCGColor(in: appearance)
        let foreground = NSColor.labelColor.resolvedCGColor(in: appearance)
        cachedLabelColors = (appearance, background, foreground)
        return (background, foreground)
    }

    /// 文字尺寸的量算结果缓存：字号固定、文字内容大多不变（只有选中的那条会随拖动变），
    /// 但每次重绘都要按「文字 + 字号」量一遍。缓存之后缩放、平移这些重绘几乎不用再量。
    private struct TextSizeKey: Hashable {
        var text: String
        var fontSize: CGFloat
    }
    private var textSizeCache: [TextSizeKey: CGSize] = [:]
    private static let textSizeCacheLimit = 256

    /// 一条测量这次要用到的那几个颜色（都已转成 CGColor）。
    private struct EntryColors {
        var stroke: CGColor
        var fill: CGColor
        var halo: CGColor
        var haloProminent: CGColor
        var border: CGColor
        var borderProminent: CGColor
        /// 半径辅助线用的淡化描边（原先在绘制时现算 0.75 透明度）。
        var strokeSoft: CGColor
    }

    /// 颜色只跟「调色板序号 + 样式」有关，而 NSColor 的构造与 `cgColor` 换算实测约 0.9 µs 一次，
    /// 一屏十几条测量、每条四五个图层，每帧就要换算几十次。按这两个键缓存住。
    private struct ColorKey: Hashable {
        var paletteIndex: Int
        var style: MeasurementStyle
    }
    private var colorCache: [ColorKey: EntryColors] = [:]

    private func colors(paletteIndex: Int, style: MeasurementStyle) -> EntryColors {
        let key = ColorKey(paletteIndex: paletteIndex, style: style)
        if let cached = colorCache[key] { return cached }
        let base = style.stroke.map(NSColor.init(components:)) ?? MeasurementPalette.color(at: paletteIndex)
        let fillBase = style.fill.map(NSColor.init(components:)) ?? MeasurementPalette.color(at: paletteIndex)
        let resolved = EntryColors(
            stroke: base.cgColor,
            fill: fillBase.withAlphaComponent(CGFloat(style.sanitized().fillOpacity)).cgColor,
            halo: NSColor.white.withAlphaComponent(0.75).cgColor,
            haloProminent: NSColor.white.withAlphaComponent(0.9).cgColor,
            border: base.withAlphaComponent(0.35).cgColor,
            borderProminent: base.withAlphaComponent(0.75).cgColor,
            strokeSoft: base.withAlphaComponent(0.75).cgColor
        )
        if colorCache.count >= Self.colorCacheLimit { colorCache.removeAll(keepingCapacity: true) }
        colorCache[key] = resolved
        return resolved
    }
    private static let colorCacheLimit = 256

    private func textSize(_ text: String, font: NSFont) -> CGSize {
        let key = TextSizeKey(text: text, fontSize: font.pointSize)
        if let cached = textSizeCache[key] { return cached }
        if textSizeCache.count >= Self.textSizeCacheLimit { textSizeCache.removeAll(keepingCapacity: true) }
        let size = (text as NSString).size(withAttributes: [.font: font])
        textSizeCache[key] = size
        return size
    }

    /// 界面外观：标注上那几个**跟随外观**的语义色（悬停环、标注底色与文字）要用它解析。
    ///
    /// 其余颜色（白色光晕、调色板里的描边）是画在影像上的，与界面深浅无关，固定即可。
    var appearance: NSAppearance = NSAppearance.currentDrawing() {
        didSet {
            guard appearance != oldValue else { return }
            hoverLayer.strokeColor = accentColor
            invalidateCache()
        }
    }

    private var accentColor: CGColor {
        if let cached = cachedAccentColor, cached.appearance == appearance { return cached.color }
        let color = NSColor.controlAccentColor.resolvedCGColor(in: appearance)
        cachedAccentColor = (appearance, color)
        return color
    }
    private var cachedAccentColor: (appearance: NSAppearance, color: CGColor)?

    init() {
        hostLayer.isGeometryFlipped = true
        hostLayer.masksToBounds = true

        hoverLayer.fillColor = nil
        hoverLayer.lineWidth = 1.5
        hoverLayer.strokeColor = accentColor
        hoverLayer.isHidden = true
    }

    func setContentsScale(_ scale: CGFloat) {
        contentsScale = scale
        for layer in labelLayers {
            layer.contentsScale = scale
        }
        invalidateCache()
    }

    /// 离屏渲染时把标注文字临时翻正。
    ///
    /// `CALayer.render(in:)` 在 y 向下的上下文里会把 `CATextLayer` 的文字画成上下镜像
    /// （瓦片那种「画图片」的内容不受影响），屏幕上的合成路径则正常。
    /// 导出图片与调试截图都走离屏渲染，所以出图前给文字图层补一次纵向翻转，出图后立刻还原。
    func withLabelsUprightForOffscreenRender<T>(_ body: () -> T) -> T {
        let original = labelLayers.map(\.transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in labelLayers where !layer.isHidden {
            layer.transform = CATransform3DMakeScale(1, -1, 1)
        }
        CATransaction.commit()

        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, layer) in labelLayers.enumerated() where index < original.count {
                layer.transform = original[index]
            }
            CATransaction.commit()
        }
        return body()
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
        showLabels: Bool,
        areaUnit: MeasureFormat.AreaUnit = .automatic
    ) {
        let staticInputs = StaticInputs(
            camera: camera,
            measurements: measurements,
            selectedID: selectedID,
            showLabels: showLabels,
            areaUnit: areaUnit
        )
        let draftInputs = DraftInputs(
            kind: draftKind,
            style: draftStyle,
            points: draft,
            liveCoordinate: liveCoordinate,
            hoveredVertex: hoveredVertex
        )
        // 什么都没变（最常见的是瓦片到位后回来重铺那几次）：一个图层都不碰。
        guard staticInputs != lastStaticInputs || draftInputs != lastDraftInputs else { return }
        let staticChanged = staticInputs != lastStaticInputs
        lastStaticInputs = staticInputs
        lastDraftInputs = draftInputs

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.areaUnit = areaUnit

        hostLayer.frame = CGRect(origin: .zero, size: camera.viewportSize)
        hoverLayer.isHidden = true

        if staticChanged {
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
                    colors: colors(paletteIndex: measurement.colorIndex, style: measurement.style),
                    lineWidth: MeasurementPalette.lineWidth(of: measurement),
                    isDraft: false,
                    segmented: showLabels && selected,
                    summarized: showLabels,
                    prominent: selected,
                    camera: camera
                )
            }
            // 记下静态部分用掉多少个图层：草稿接着往后用，互不干扰。
            staticStrokeCount = strokeIndex
            staticFillCount = fillIndex
            staticVertexCount = vertexIndex
            staticLabelCount = labelIndex
            staticRadiusCount = radiusIndex
        } else {
            // 静态部分沿用上一次画好的图层：索引直接跳过去，从草稿开始重画。
            strokeIndex = staticStrokeCount
            fillIndex = staticFillCount
            vertexIndex = staticVertexCount
            labelIndex = staticLabelCount
            radiusIndex = staticRadiusCount
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
                colors: colors(paletteIndex: paletteIndex, style: draftStyle),
                lineWidth: CGFloat(draftStyle.sanitized().strokeWidth),
                isDraft: true,
                segmented: showLabels,
                summarized: showLabels,
                prominent: true,
                camera: camera
            )
        }

        // 下界要夹一下：图层池可能在缩容之后比当前用量还小（见 `trimPoolsIfSpare`），
        // 直接写 `strokeIndex..<count` 会在 lowerBound > upperBound 时崩。
        for index in min(strokeIndex, strokePairs.count)..<strokePairs.count {
            strokePairs[index].halo.isHidden = true
            strokePairs[index].line.isHidden = true
        }
        for index in min(fillIndex, fillLayers.count)..<fillLayers.count {
            fillLayers[index].isHidden = true
        }
        for index in min(vertexIndex, vertexLayers.count)..<vertexLayers.count {
            vertexLayers[index].isHidden = true
        }
        for index in min(labelIndex, labelLayers.count)..<labelLayers.count {
            labelLayers[index].isHidden = true
        }
        for index in min(radiusIndex, radiusLayers.count)..<radiusLayers.count {
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
            hoverLayer.strokeColor = accentColor
            hoverLayer.isHidden = false
            // 移到最上层，保证提示环不被其它标注盖住。
            hostLayer.addSublayer(hoverLayer)
        }

        trimPoolsIfSpare()
    }

    // MARK: - 图层池缩容

    /// 用量远低于池容量时，连续若干帧之后裁掉尾部。
    ///
    /// 池子只增不减：量了几百条测量再删掉，那几千个图层（每个标签还有一个位图后备）
    /// 会一直留在内存里。裁剪保留「静态部分 + 当前用量」再多留几个余量，
    /// 因此不会动到已经画好的那批；下次要用更多时 `dequeue*` 会再建。
    private func trimPoolsIfSpare() {
        let used = max(strokeIndex, max(fillIndex, max(vertexIndex, max(labelIndex, radiusIndex))))
        let staticUsed = max(staticStrokeCount, max(staticFillCount, max(staticVertexCount,
            max(staticLabelCount, staticRadiusCount))))
        let spare = max(
            strokePairs.count - strokeIndex,
            max(fillLayers.count - fillIndex,
                max(vertexLayers.count - vertexIndex,
                    max(labelLayers.count - labelIndex, radiusLayers.count - radiusIndex)))
        )
        guard spare > max(used, staticUsed) + 24 else {
            spareFrames = 0
            return
        }
        spareFrames += 1
        guard spareFrames >= 240 else { return }
        spareFrames = 0
        trimTail(&strokePairs, keeping: max(strokeIndex, staticStrokeCount) + 8) { pair in
            pair.halo.removeFromSuperlayer()
            pair.line.removeFromSuperlayer()
        }
        trimTail(&fillLayers, keeping: max(fillIndex, staticFillCount) + 8) { $0.removeFromSuperlayer() }
        trimTail(&vertexLayers, keeping: max(vertexIndex, staticVertexCount) + 8) { $0.removeFromSuperlayer() }
        trimTail(&labelLayers, keeping: max(labelIndex, staticLabelCount) + 8) { $0.removeFromSuperlayer() }
        trimTail(&radiusLayers, keeping: max(radiusIndex, staticRadiusCount) + 8) { $0.removeFromSuperlayer() }
    }

    private func trimTail<T>(_ pool: inout [T], keeping count: Int, release: (T) -> Void) {
        while pool.count > max(0, count), let last = pool.popLast() {
            release(last)
        }
    }

    /// 用量远低于容量的连续帧数（缩容判断用）。
    private var spareFrames = 0

    // MARK: - 绘制

    private func draw(
        kind: MeasurementKind,
        coordinates: [GeoCoordinate],
        colors: EntryColors,
        lineWidth: CGFloat,
        isDraft: Bool,
        segmented: Bool,
        summarized: Bool,
        prominent: Bool,
        camera: MapCamera
    ) {
        let points = coordinates.map { layerPoint($0, camera: camera) }
        let outlined = kind == .circle
        // 圆的圆周、周长与面积共用同一组采样点；求值带缓存（见 `MeasurementCalculator.circleMetrics`），
        // 因此平移缩放时不会每帧重算 360 点采样。
        var circleMetrics: MeasurementCalculator.CircleMetrics?
        if outlined, coordinates.count >= 2 {
            let radius = Geodesy.distance(from: coordinates[0], to: coordinates[1])
            if radius > 0 {
                circleMetrics = MeasurementCalculator.circleMetrics(
                    center: coordinates[0],
                    radius: radius
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
                strokePath(ring, colors: colors, lineWidth: lineWidth, prominent: prominent)
                fillPath(ring, color: colors.fill)
            }
        } else if points.count >= 2 {
            let path = CGMutablePath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            if kind == .area, points.count >= 3 {
                path.closeSubpath()
                fillPath(path, color: colors.fill)
            }
            strokePath(path, colors: colors, lineWidth: lineWidth, prominent: prominent)
        }

        // 圆的半径辅助线，方便一眼看出半径基准。
        if outlined, prominent, points.count >= 2 {
            showRadiusGuide(from: points[0], to: points[1], color: colors.strokeSoft)
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
            layer.strokeColor = colors.stroke
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
                        entryColors: colors,
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
                    entryColors: colors,
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
                summary = result.area.map { "面积 " + MeasureFormat.area($0, unit: areaUnit) }
                    ?? "周长 " + MeasureFormat.distance(result.totalLength)
            case .circle:
                var parts: [String] = []
                if let radius = result.radius {
                    parts.append("R " + MeasureFormat.distance(radius))
                }
                if let area = result.area {
                    parts.append("面积 " + MeasureFormat.area(area, unit: areaUnit))
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
            addLabel(text: summary, at: anchor, entryColors: colors, prominent: prominent)
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

    private func strokePath(_ path: CGPath, colors: EntryColors, lineWidth: CGFloat, prominent: Bool) {
        let pair = dequeueStroke()
        pair.halo.path = path
        pair.halo.strokeColor = prominent ? colors.haloProminent : colors.halo
        pair.halo.lineWidth = lineWidth + (prominent ? 3.6 : 3.2)
        pair.line.path = path
        pair.line.strokeColor = colors.stroke
        pair.line.lineWidth = prominent ? lineWidth + 0.3 : lineWidth
    }

    private func fillPath(_ path: CGPath, color: CGColor) {
        let layer = dequeueFill()
        layer.path = path
        layer.fillColor = color
    }

    private func showRadiusGuide(from start: CGPoint, to end: CGPoint, color: CGColor) {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        let layer = dequeueRadius()
        layer.path = path
        layer.strokeColor = color
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

    private func addLabel(text: String, at position: CGPoint, entryColors: EntryColors, prominent: Bool) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: prominent ? 11.5 : 11, weight: prominent ? .semibold : .medium)
        let measured = textSize(text, font: font)
        let size = CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 5)
        let label = labelColors()

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
        // 标注底色与文字跟随界面外观：深色下是深底浅字，浅色下是浅底深字。
        layer.backgroundColor = label.background
        layer.foregroundColor = label.foreground
        layer.cornerRadius = 4
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = prominent ? entryColors.borderProminent : entryColors.border
    }
}
