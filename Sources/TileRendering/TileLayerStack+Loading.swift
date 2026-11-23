import CoreGraphics
import Foundation
import QuartzCore
import TileKit
extension TileLayerStack {
    func requestMissingTiles(needed: Set<SlippyTile>, provider: TileProvider) {
        let currentGeneration = generation
        let outstanding = tileTasks.count
        guard outstanding < maximumConcurrentRequests else { return }
        // 只按「自己的图还没上屏、没有在途请求、也不是已确认缺片」判断是否要取图。
        // 注意不能只看 `contents == nil`：祖先贴图先顶上时图层也有内容，但自己的图仍要取。
        var pending: [SlippyTile] = needed.filter { tile in
            layerImageSource[tile] != tile
                && tileTasks[tile] == nil
                && !(missingTiles[tile].map { $0 > Date() } ?? false)
        }
        guard !pending.isEmpty else { return }

        // 靠近视图中心的瓦片优先加载。
        let center = cameraCenter
        pending = pending.map { (tile: $0, distance: distanceSquared($0, center: center)) }
            .sorted { $0.distance < $1.distance }.map(\.tile)

        let budget = max(0, maximumConcurrentRequests - outstanding)
        Self.tileRequestCount += min(budget, pending.count)
        for tile in pending.prefix(budget) {
            tileTasks[tile] = Task { @MainActor [weak self] in
                guard let self else { return }
                let image = await provider.image(for: tile)
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.tileTasks[tile] = nil
                guard let image else {
                    if self.missingTiles.count >= Self.missingTileLimit {
                        self.missingTiles.removeAll(keepingCapacity: true)
                    }
                    self.missingTiles[tile] = await provider.retryDate(for: tile) ?? Date().addingTimeInterval(1)
                    self.scheduleRetry()
                    self.scheduleRefill()
                    return
                }
                if let layer = self.tileLayers[tile] {
                    if let interval = self.firstTileInterval { TilePerformance.end(interval); self.firstTileInterval = nil }
                    // 首次出现也做一次很短的淡入：瓦片是按解码完成的先后落下来的，
                    // 硬贴上去就是一块块「啪」地跳出来，一屏几十块看着就是闪。
                    // 但拖动 / 缩放当中不淡入：那会儿图上一直在动，淡入看着就像边缘在「加载」。
                    self.install(image, in: layer, source: tile, for: tile, animated: !self.isInteracting)
                }
                // 并发额度腾出来了，把这一帧没排上队的瓦片接着取。
                self.scheduleRefill()
            }
        }
    }

    func scheduleRetry() {
        retryTask?.cancel()
        guard let next = missingTiles.values.min() else { return }
        let delay = max(0.05, next.timeIntervalSinceNow)
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            self.missingTiles = self.missingTiles.filter { $0.value > Date() }
            self.scheduleRefill()
            if !self.missingTiles.isEmpty { self.scheduleRetry() }
        }
    }

    /// 本轮请求结束后补跑一次同步，避免超出并发额度的瓦片要等到下次交互才加载。
    func scheduleRefill() {
        guard refillTask == nil else { return }
        let currentGeneration = generation
        refillTask = Task { @MainActor [weak self] in
            // 合并同一帧内陆续返回的瓦片，最多每 8 ms 重铺一次。
            do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            guard let self, self.generation == currentGeneration else { return }
            self.refillTask = nil
            self.needsSync?()
        }
    }

    /// 背景层跟着相机走，缩放平移时始终保持与当前层级对齐。
    func updateBackdropFrames(camera: MapCamera, offset: CGPoint) {
        guard !backdropLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (tile, layer) in backdropLayers {
            let world = grid.worldRect(zoom: tile.zoom, column: tile.x, row: tile.y)
            let origin = camera.layerPoint(forWorldPoint: CGPoint(
                x: world.minX + offset.x,
                y: world.minY + offset.y
            ))
            layer.frame = CGRect(
                x: origin.x,
                y: origin.y,
                width: CGFloat(world.width * camera.pixelsPerWorldUnit),
                height: CGFloat(world.height * camera.pixelsPerWorldUnit)
            )
        }
        CATransaction.commit()
    }

    /// 当前层级的每一格都有自己的图（或已确认缺片）之后，背景层就没必要留着了。
    func dropBackdropIfSettled(needed: Set<SlippyTile>) {
        guard !backdropLayers.isEmpty else { return }
        let settled = needed.allSatisfy { tile in
            layerImageSource[tile] == tile || (missingTiles[tile].map { $0 > Date() } ?? false)
        }
        guard settled else { return }

        let retired = backdropLayers
        backdropLayers.removeAll()
        // 「减少动态效果」时直接摘掉，不做淡出。
        guard !reducesMotion else {
            for layer in retired.values { layer.removeFromSuperlayer() }
            return
        }
        // 自己的图已经盖满时摘掉背景是看不见的；稀疏缺片的格子还露着背景，淡出更自然。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in retired.values {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "backdropFade")
            layer.opacity = 0
        }
        CATransaction.commit()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.25))
            for layer in retired.values { layer.removeFromSuperlayer() }
        }
    }

    /// 给还没有图的格子先铺上祖先层级的图（裁到对应子区域）。
    ///
    /// 这是「缩放不闪」的关键：换层级时新图还没到，但父层级的图往往已经在内存缓存里，
    /// 直接按比例铺上去，画面就是连续的；等自己那张图到了再无缝替换。
    func applyFallbackImages(needed: Set<SlippyTile>, provider: TileProvider) {
        let waiting = needed.filter {
            layerImageSource[$0] == nil
                && fallbackTasks[$0] == nil
                && !unresolvedTiles.contains($0)
        }
        guard !waiting.isEmpty, fallbackTasks.count < Self.maximumFallbackLookups else { return }

        let center = cameraCenter
        let currentGeneration = generation
        let budget = max(0, Self.maximumFallbackLookups - fallbackTasks.count)
        let ordered = waiting.sorted {
            distanceSquared($0, center: center) < distanceSquared($1, center: center)
        }

        for tile in ordered.prefix(budget) {
            Self.tileRequestCount += 1
            fallbackTasks[tile] = Task { @MainActor [weak self] in
                let ancestor = await Self.firstAvailableAncestor(of: tile, provider: provider)
                guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
                self.fallbackTasks[tile] = nil
                guard let found = ancestor else {
                    // 自己也没有、祖先也没有：先记下来，别在下一轮又从头找一遍。
                    // 这里仍然补跑一次同步，是为了让本轮没排上的格子继续找；
                    // 因为候选集合只减不增，这个回路会在几轮内收敛。
                    self.unresolvedTiles.insert(tile)
                    self.scheduleRefill()
                    return
                }
                // 自己的图已经到了就不用兜底了。
                guard self.layerImageSource[tile] != tile,
                      self.layerImageSource[tile] == nil,
                      let layer = self.tileLayers[tile] else { return }
                self.install(found.image, in: layer, source: found.tile, for: tile, animated: true)
                self.scheduleRefill()
            }
        }
    }

    /// 从父层级往上找第一张已经能取到的瓦片。
    static func firstAvailableAncestor(
        of tile: SlippyTile,
        provider: TileProvider
    ) async -> (tile: SlippyTile, image: CGImage)? {
        var level = tile.zoom - 1
        var tries = 0
        while level >= 0, tries < maximumFallbackLevels {
            guard !Task.isCancelled else { return nil }
            let shift = tile.zoom - level
            let ancestor = SlippyTile(zoom: level, x: tile.x >> shift, y: tile.y >> shift)
            if let image = await provider.image(for: ancestor) {
                return (ancestor, image)
            }
            level -= 1
            tries += 1
        }
        return nil
    }

    /// 在已有的图片里找最近的祖先层级瓦片（用于同帧兜底，不需要等异步取图）。
    public static func bestAncestor(of tile: SlippyTile, in images: [SlippyTile: CGImage]) -> SlippyTile? {
        guard !images.isEmpty else { return nil }
        var level = tile.zoom - 1
        var tries = 0
        while level >= 0, tries < maximumFallbackLevels {
            guard !Task.isCancelled else { return nil }
            let shift = tile.zoom - level
            let ancestor = SlippyTile(zoom: level, x: tile.x >> shift, y: tile.y >> shift)
            if images[ancestor] != nil { return ancestor }
            level -= 1
            tries += 1
        }
        return nil
    }

    /// 取出图层里装的图片（`CALayer.contents` 是 `Any?`，用 CFTypeID 判断再取）。
    public static func contentsImage(of layer: CALayer) -> CGImage? {
        // `contents` 是 `Any?`：先用 CFTypeID 核对确实是 CGImage，再走 CoreFoundation 的桥接。
        // 全程不用 `as!`，宿主放入非图像内容时返回 nil。
        guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            return nil
        }
        return Unmanaged<CGImage>.fromOpaque(Unmanaged.passUnretained(contents as AnyObject).toOpaque())
            .takeUnretainedValue()
    }

    /// 按 `contentsRect` 把图裁出该格子真正显示的那一块。
    ///
    /// 祖先贴图兜底时，一格图层里装的是**整张高层级瓦片**，只显示其中一个子区域
    /// （`contentsGravity = .resize` + `contentsRect`）。出图快照必须照这个口径裁，
    /// 否则缩略图会把整张祖图塞进一格，画面直接错位。
    public static func cropped(_ image: CGImage, to contentsRect: CGRect) -> CGImage? {
        guard contentsRect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return image }
        // `CGImage.cropping(to:)` 的坐标与 `contentsRect` 一样：单位坐标，y 从图顶算起。
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(
            x: (contentsRect.minX * width).rounded(.down),
            y: (contentsRect.minY * height).rounded(.down),
            width: max(1, (contentsRect.width * width).rounded()),
            height: max(1, (contentsRect.height * height).rounded())
        )
        return image.cropping(to: rect)
    }

    /// 把本层当前**真正装着**的图按层序追加到出图快照里。
    ///
    /// 只读：不改 frame、不改 isHidden、不改事务，主线程上一次遍历，微秒级。
    /// 网格层（调试用）不进快照 —— 和旧实现「渲染前临时隐藏网格」是同一个口径，
    /// 但不再去动视图状态（旧写法一旦中途抛错就会把网格永久留在隐藏状态）。
    public func appendPlacements(into placements: inout [MapRenderSnapshot.Placement]) {
        let hostOpacity = CGFloat(hostLayer.opacity)
        guard hostOpacity > 0.001, !hostLayer.isHidden, let sublayers = hostLayer.sublayers else {
            return
        }
        for layer in sublayers {
            // 层序就是 `sublayers` 的顺序：先铺的在下（旧层兜底），后铺的在上。
            guard layer !== gridLayer, !layer.isHidden else { continue }
            guard let image = Self.contentsImage(of: layer),
                  let visible = Self.cropped(image, to: layer.contentsRect) else { continue }
            let opacity = CGFloat(layer.opacity) * hostOpacity
            guard opacity > 0.001 else { continue }
            placements.append(
                MapRenderSnapshot.Placement(image: visible, frame: layer.frame, opacity: opacity)
            )
        }
    }

    /// 调试用：当前瓦片图层的几何概况（`EUCLID_TRACE_LAYERS` 时打到 stderr）。
    public func debugTileLayerSummary() -> (
        count: Int, withImage: Int,
        xRange: ClosedRange<Double>?, yRange: ClosedRange<Double>?,
        sizeRange: ClosedRange<Double>?
    ) {
        guard !tileLayers.isEmpty else { return (0, 0, nil, nil, nil) }
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var minSide = Double.greatestFiniteMagnitude
        var maxSide = -Double.greatestFiniteMagnitude
        var withImage = 0
        for layer in tileLayers.values {
            let frame = layer.frame
            minX = min(minX, frame.minX); maxX = max(maxX, frame.maxX)
            minY = min(minY, frame.minY); maxY = max(maxY, frame.maxY)
            minSide = min(minSide, Double(min(frame.width, frame.height)))
            maxSide = max(maxSide, Double(max(frame.width, frame.height)))
            if Self.contentsImage(of: layer) != nil { withImage += 1 }
        }
        return (
            tileLayers.count, withImage,
            minX...maxX, minY...maxY, minSide...maxSide
        )
    }

    /// 把图片装进格子：来源可能是自己，也可能是祖先（按 `contentsRect` 裁出对应子区域）。
    func install(
        _ image: CGImage,
        in layer: CALayer,
        source: SlippyTile,
        for tile: SlippyTile,
        animated: Bool
    ) {
        let rect = Self.contentsRect(source: source, destination: tile)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, !reducesMotion {
            // 首次出现、以及换图（祖先贴图 → 自己的图）都做一次很短的交叉淡入，
            // 避免整屏几十块瓦片按解码顺序「啪、啪」地跳出来。
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "contentFade")
        }
        layer.contents = image
        layer.contentsRect = rect
        layer.backgroundColor = nil
        layerImageSource[tile] = source
        CATransaction.commit()
    }

    /// 目标瓦片在来源瓦片图片里占的子区域（单位坐标，y 从图片顶部算起）。
    public static func contentsRect(source: SlippyTile, destination: SlippyTile) -> CGRect {
        let shift = destination.zoom - source.zoom
        guard shift > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let factor = Double(1 << shift)
        let dx = Double(destination.x - source.x * (1 << shift)) / factor
        let dy = Double(destination.y - source.y * (1 << shift)) / factor
        return CGRect(x: dx, y: dy, width: 1 / factor, height: 1 / factor)
    }
}
