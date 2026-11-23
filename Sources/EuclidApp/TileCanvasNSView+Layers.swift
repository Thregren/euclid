import AppKit
import QuartzCore
import TileKit
import TileRendering
extension TileCanvasNSView {
    func setLayers(_ newLayers: [MapLayer], focus: CGRect?) {
        let hadContent = !stacks.isEmpty
        let previousScale = camera.groundMetersPerPoint
        if Self.tracesLayers {
            let names = newLayers.map { "\($0.id.prefix(6))/\($0.sourceKey.prefix(24))" }
            traceGeometryEvent("setLayers 层数=\(newLayers.count) [\(names.joined(separator: " "))]")
        }
        layers = newLayers

        // 删掉不再需要的层
        let layerIDs = Set(newLayers.map(\.id))
        for (id, stack) in stacks where !layerIDs.contains(id) {
            stack.clear()
            stack.hostLayer.removeFromSuperlayer()
            stacks[id] = nil
            stackSignatures[id] = nil
        }

        // 装配或更新每一层
        for layer in newLayers {
            let stack = stacks[layer.id] ?? makeStack()
            if stacks[layer.id] == nil {
                stacks[layer.id] = stack
                layer_hostAdd(stack)
            }
            if stackSignatures[layer.id] != layer.sourceKey {
                stack.configure(
                    source: layer.source,
                    name: layer.name,
                    tileSize: layer.tileSize,
                    zoomRange: layer.zoomRange,
                    grid: layer.grid,
                    followsDisplayScale: layer.followsDisplayScale,
                    maximumDataZoom: layer.maximumDataZoom,
                    memoryLimitBytes: layer.memoryLimitBytes,
                    maxConcurrentRequests: layer.maxConcurrentRequests
                )
                stackSignatures[layer.id] = layer.sourceKey
            }
            stack.opacity = layer.isVisible ? layer.opacity : 0
            stack.setVisible(layer.isVisible)
        }

        // 所有图层共用画布预算；隐藏图层只保留较小的热缓存。
        let requested = newLayers.map { $0.isVisible ? $0.memoryLimitBytes : min($0.memoryLimitBytes, 32 << 20) }
        let total = requested.reduce(0.0) { $0 + Double($1) }
        let fraction = total > 0 ? min(1, Double(TileResourcePolicy.totalTileCacheBytes) / total) : 0
        for (layer, bytes) in zip(newLayers, requested) {
            stacks[layer.id]?.setCacheLimitBytes(Int(Double(bytes) * fraction))
        }

        // 层序：按列表重新挂一遍（下 → 上），始终在测量标注之下
        for layer in newLayers {
            guard let stack = stacks[layer.id] else { continue }
            stack.hostLayer.removeFromSuperlayer()
            layer_hostAdd(stack)
        }
        syncHostLayerFrames()

        // 基准数据集的范围还没算出来时先不铺图：此时相机只能停在数据之外，
        // 铺出来只会是一屏空占位并白读磁盘（范围一到画面还要整体跳一次）。
        // 只认基准层：叠加进来的数据集在算自己那份范围时，当前视野与它无关，
        // 不该把已经在看的画面一起停掉。
        awaitingExtent = layers.contains { $0.isAnchor && $0.kind == .dataset && $0.fitRect == nil }

        updateAccessibilityLabel()
        let focusRect = focus ?? anchorLayer?.fitRect
        if hadContent {
            // 已经有内容在看：保持当前视野，只把图层换了。
            refreshCamera(fitRect: nil, defaultZoomLevel: nil)
            restoreGroundScale(previousScale, when: true)
        } else {
            refreshCamera(fitRect: focusRect, defaultZoomLevel: focusRect == nil ? 2 : nil)
        }
        // 图层增删改序之后遮罩对象可能对不上了，重刷一遍（未开启对比时是空操作）。
        if swipeIsActive || !swipeMasks.isEmpty { applySwipe() }
        syncLayers()
    }

    func restoreGroundScale(_ scale: Double, when condition: Bool) {
        guard condition, scale > 0, scale.isFinite else { return }
        camera = camera.settingGroundMetersPerPoint(scale).clamped(zoomLevelRange: zoomBounds)
    }

    func layer_hostAdd(_ stack: TileLayerStack) {
        layer?.insertSublayer(stack.hostLayer, below: overlay.hostLayer)
    }

    func syncHostLayerFrames() {
        let needsWork = backgroundLayer.frame != bounds
            || stacks.values.contains { $0.hostLayer.frame != bounds }
        guard needsWork else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        pickLayer.frame = bounds
        swipeDividerLayer.frame = bounds
        for stack in stacks.values { stack.hostLayer.frame = bounds }
        CATransaction.commit()
    }

    func refreshCamera(fitRect: CGRect?, defaultZoomLevel: Double?) {
        camera.displayScale = displayScale
        camera.viewportSize = bounds.size
        // 相机里的瓦片边长跟着主图层走：本地影像按设备像素 1:1，在线才按地图约定。
        let primary = primaryStack
        camera.tilePixelSize = primary.map { $0.cameraTileSize(displayScale: displayScale) } ?? 512

        let rect = fitRect ?? (primaryStack != nil ? layers.first(where: { $0.isAnchor })?.fitRect : nil)
        let fitCamera = rect.map {
            MapCamera.fitting(
                $0,
                viewportSize: bounds.size,
                padding: 28,
                tilePixelSize: camera.tilePixelSize,
                displayScale: camera.displayScale
            )
        } ?? camera.settingZoomLevel(defaultZoomLevel ?? camera.zoomLevel)

        // 上下限取两层（多图层后是全部图层）的并集：更深的源决定能放多大，浅的那层靠祖先贴图兜底。
        // 没有图层时给一个宽松范围，免得算成空区间（`ClosedRange` 会直接崩）。
        var upper = 26.0
        var hasActive = false
        for stack in stacks.values where stack.isActive {
            upper = hasActive ? max(upper, stack.zoomLevelRange.upperBound) : stack.zoomLevelRange.upperBound
            hasActive = true
        }
        // 只有「真的要重新适配视野」时才按适配层级算下限；否则沿用原下限（否则每开关一次底图，
        // 能缩小的范围就被当前相机重新收紧一次，看起来就像视野被改动了）。
        var lower = rect == nil
            ? min(zoomBounds.lowerBound, upper - 0.001)
            : min(max(-2, fitCamera.zoomLevel - 1.2), upper - 0.001)
        zoomLowerBoundFromFit = lower
        // 主图层的最低数据层级比适配层级“深”很多时（整省 z12 之类的数据在「适应窗口」下就是这样），
        // 再往外缩一屏就要铺几千片，安全阀会把画布清空 —— 看着像数据没打开。
        // 把「一屏还铺得出来」的最低层级也算进缩放下限，宁可少看一点，也不留一屏空白。
        if rect != nil, let primary {
            lower = max(lower, primary.affordableCameraZoom(
                viewportSize: bounds.size, displayScale: displayScale
            ))
        }
        // 下限顶到上限会让 `ClosedRange` 直接崩，夹一道。
        lower = min(lower, upper - 0.001)
        zoomBounds = lower...upper
        camera = fitCamera.clamped(zoomLevelRange: zoomBounds)
    }

    func adoptZoomBoundsToViewport() {
        guard let primary = primaryStack else { return }
        let affordable = primary.affordableCameraZoom(
            viewportSize: bounds.size, displayScale: displayScale
        )
        let lower = min(max(zoomLowerBoundFromFit, affordable), zoomBounds.upperBound - 0.001)
        guard abs(lower - zoomBounds.lowerBound) > 0.0005 else { return }
        zoomBounds = lower...zoomBounds.upperBound
        camera = camera.clamped(zoomLevelRange: zoomBounds)
    }

    func updateAccessibilityLabel() {
        let name = anchorLayer?.name ?? orderedStacks.last?.name ?? ""
        let layerCount = orderedStacks.filter(\.isActive).count
        guard !name.isEmpty else {
            setAccessibilityLabel("地图画布，暂无内容")
            writeAccessibilityZoom(nil)
            return
        }
        setAccessibilityLabel("地图画布：\(name)" + (layerCount > 1 ? "（\(layerCount) 个图层）" : ""))
        writeAccessibilityZoom(currentDataZoom)
    }

    func writeAccessibilityZoom(_ zoom: Int?) {
        guard zoom != lastAccessibilityZoom else { return }
        lastAccessibilityZoom = zoom
        setAccessibilityValue(zoom.map { "z\($0)" })
    }

    func setExtent(_ extent: DatasetExtent?) {
        guard layers.contains(where: { $0.kind == .dataset }) else { return }
        awaitingExtent = false
        extentRect = extent?.worldRect
        // 范围算失败（nil）也要同步一次，让画面退回默认视图，而不是一直空着。
        guard let extent else {
            syncLayers()
            return
        }
        markViewPositioned()
        refreshCamera(fitRect: extent.worldRect, defaultZoomLevel: nil)
        syncLayers()
    }

    func fitToData() {
        markViewPositioned()
        guard orderedStacks.contains(where: { $0.isActive }) else { return }
        guard !awaitingExtent || extentRect != nil else { return }
        let rect = anchorLayer?.fitRect ?? extentRect ?? layers.last(where: { $0.fitRect != nil })?.fitRect ?? Self.worldRect
        camera = MapCamera.fitting(
            rect,
            viewportSize: bounds.size,
            padding: 28,
            tilePixelSize: camera.tilePixelSize,
            displayScale: camera.displayScale
        ).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func fitToWorldRect(_ rect: CGRect, padding: Double = 56) {
        markViewPositioned()
        camera = camera.fitting(rect, padding: padding).clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }

    func goTo(_ coordinate: GeoCoordinate) {
        markViewPositioned()
        camera.center = WebMercator.normalized(coordinate)
        camera = camera.clamped(zoomLevelRange: zoomBounds)
        syncLayers()
    }
}
