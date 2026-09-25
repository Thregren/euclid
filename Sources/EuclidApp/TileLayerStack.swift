import AppKit
import QuartzCore
import TileKit

/// 一条瓦片图层栈一次渲染后的关键数字，供调试输出与状态汇报使用。
struct TileLayerFrame {
    var name: String
    var zoom: Int
    var needed: Int
    var loaded: Int
    var fallback: Int
    var missing: Int
    var tileDisplaySize: CGFloat
}

/// 一条瓦片图层栈：一个数据源对应一个宿主图层，外加「换层级留旧图顶着」那一整套。
///
/// 画布可以同时挂两条（本地影像在上、在线底图在下），两条共用同一个相机，
/// 因此叠加显示时缩放、平移、层级切换天然同步；每条各自维护取图、缓存、兜底与预取。
@MainActor
final class TileLayerStack {
    let hostLayer = CALayer()
    /// 瓦片网格（调试用），跟着本层可见范围绘制。
    let gridLayer = CAShapeLayer()

    private(set) var name = ""
    /// 数据源实际提供的整数层级范围。
    private(set) var dataZoomRange: ClosedRange<Int> = 0...22
    /// 数据源自身的最大层级（「原始比例」用）。
    private(set) var maximumDataZoom: Double = 20
    /// 相机上下限（真实层级 ± 余量）。
    private(set) var zoomLevelRange: ClosedRange<Double> = -2...26
    private(set) var isActive = false

    /// 图层不透明度：叠加对照时用它把上层影像淡下去看底图。
    var opacity: Double = 1 {
        didSet { hostLayer.opacity = Float(min(max(opacity, 0), 1)) }
    }

    private var provider: TileProvider?
    private var baseTileSize: Double = 512
    /// 在线底图按「一张瓦片铺满它的像素数」显示，相机里的边长要跟着设备像素比走。
    private var tileSizeFollowsDisplayScale = false
    private var scale: CGFloat = 2

    private var tileLayers: [SlippyTile: CALayer] = [:]
    /// 换层级时保留下来的上一层图层：新图层的图还没到位前由它顶着，避免整屏变灰。
    private var backdropLayers: [SlippyTile: CALayer] = [:]
    /// 当前真正在渲染的层级。
    private var renderedZoom: Int?
    private var tileTasks: [SlippyTile: Task<Void, Never>] = [:]
    /// 每一格当前显示的图片来自哪一块瓦片：自己，或者某个祖先层级。
    private var layerImageSource: [SlippyTile: SlippyTile] = [:]
    /// 正在为哪些格子找祖先贴图（避免重复发起）。
    private var fallbackTasks: Set<SlippyTile> = []
    private var missingTiles: Set<SlippyTile> = []
    /// 已经确认「自己没有图、可回溯的祖先层级也没有图」的格子。
    ///
    /// 少了它，`applyFallbackImages` 的失败分支会一轮接一轮地重新找祖先，
    /// 渲染就变成停不下来的空转：打开数据集时（相机还停在数据之外）每秒能跑两百多轮。
    private var unresolvedTiles: Set<SlippyTile> = []
    /// 已经排队等下一帧补请求的标记，避免同一帧重复调度。
    private var refillScheduled = false
    /// 上一次预取的「层级 + 视野范围」，用来避免重复预取同一圈。
    private var lastPrefetchKey = ""
    private var generation = 0

    /// 单帧最多渲染的瓦片数量，作为异常情况下的安全阀。
    private static let maximumTilesPerFrame = 1200
    /// 同时在途的取图任务上限（解码并发由 `TileProvider` 另有限制）。
    /// Retina 上一个整数层级要多铺 4 倍瓦片，这里放宽一点，首屏更快铺满。
    private let maximumConcurrentRequests = 32
    /// 单次预取的瓦片上限。
    private static let prefetchLimit = 24
    /// 祖先层级最多回溯几级。数值越大，稀疏数据越不容易露白，但请求也越多。
    private static let maximumFallbackLevels = 4
    /// 同时在找祖先贴图的格子数量上限，避免一屏几十个空格同时发起请求。
    private static let maximumFallbackLookups = 8

    init() {
        hostLayer.isGeometryFlipped = true
        hostLayer.masksToBounds = true
        gridLayer.fillColor = nil
        gridLayer.lineWidth = 1
        gridLayer.isHidden = true
        hostLayer.addSublayer(gridLayer)
    }

    // MARK: - 装配

    func configure(
        source: any TileImageSource,
        name: String,
        tileSize: Int,
        zoomRange: ClosedRange<Int>,
        followsDisplayScale: Bool,
        maximumDataZoom: Double,
        memoryLimitBytes: Int = 512 * 1024 * 1024,
        maxConcurrentRequests: Int = 8
    ) {
        generation += 1
        cancelRequests()
        removeAllLayers()
        provider = TileProvider(
            source: source,
            memoryLimitBytes: memoryLimitBytes,
            maxConcurrentDecodes: maxConcurrentRequests
        )
        self.name = name
        baseTileSize = Double(max(1, tileSize))
        tileSizeFollowsDisplayScale = followsDisplayScale
        dataZoomRange = zoomRange
        self.maximumDataZoom = maximumDataZoom
        zoomLevelRange = max(-2, Double(zoomRange.lowerBound))...min(maximumDataZoom + 1, 30)
        isActive = true
    }

    func clear() {
        generation += 1
        cancelRequests()
        removeAllLayers()
        provider = nil
        name = ""
        isActive = false
    }

    /// 相机里的瓦片边长（视图点）。
    func cameraTileSize(displayScale: Double) -> Double {
        baseTileSize * (tileSizeFollowsDisplayScale ? displayScale : 1)
    }

    func setContentsScale(_ scale: CGFloat) {
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tileLayers.values { layer.contentsScale = scale }
        for layer in backdropLayers.values { layer.contentsScale = scale }
        CATransaction.commit()
    }

    func cancelRequests() {
        for task in tileTasks.values { task.cancel() }
        tileTasks.removeAll()
    }

    private func removeAllLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tileLayers.values { layer.removeFromSuperlayer() }
        for layer in backdropLayers.values { layer.removeFromSuperlayer() }
        CATransaction.commit()
        tileLayers.removeAll()
        backdropLayers.removeAll()
        renderedZoom = nil
        layerImageSource.removeAll()
        fallbackTasks.removeAll()
        unresolvedTiles.removeAll()
        missingTiles.removeAll()
        lastPrefetchKey = ""
        gridLayer.isHidden = true
        gridLayer.path = nil
    }

    // MARK: - 渲染

    /// 把当前相机下的瓦片铺好。返回本帧的关键数字（没有内容时返回 nil）。
    func sync(
        camera: MapCamera,
        viewportSize: CGSize,
        displayScale: Double,
        showGrid: Bool
    ) -> TileLayerFrame? {
        scale = CGFloat(displayScale)
        guard let provider, viewportSize.width > 1, viewportSize.height > 1 else {
            removeAllLayers()
            return nil
        }

        let zoom = dataZoom(for: camera)
        guard let columns = camera.tileColumnRange(zoom: zoom),
              let rows = camera.tileRowRange(zoom: zoom) else {
            return nil
        }
        let total = columns.count * rows.count
        guard total <= Self.maximumTilesPerFrame else {
            // 超出安全阀时宁可清空，也不要留着上一帧的残影误导判读。
            removeAllLayers()
            return TileLayerFrame(name: name, zoom: zoom, needed: total, loaded: 0,
                                  fallback: 0, missing: missingTiles.count, tileDisplaySize: 0)
        }

        let tileWorldSize = 1.0 / Double(1 << zoom)
        let tileDisplaySize = CGFloat(camera.pixelsPerWorldUnit * tileWorldSize)

        var needed = Set<SlippyTile>()
        needed.reserveCapacity(total)
        for row in rows {
            for column in columns {
                needed.insert(SlippyTile(zoom: zoom, x: column, y: row))
            }
        }
        // 「没有图可用」的结论只对还留在屏幕上的格子有效：离开视野就忘掉，转回来再试一次。
        unresolvedTiles.formIntersection(needed)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 层级切换：把上一层的图层整体留作背景层，新图层的图到位前画面不会变空。
        if renderedZoom != zoom {
            for layer in backdropLayers.values { layer.removeFromSuperlayer() }
            backdropLayers = tileLayers
            tileLayers.removeAll()
            layerImageSource.removeAll()
            fallbackTasks.removeAll()
            renderedZoom = zoom
        }

        // 换层级时把即将摘掉的图层图片先接过来，作为新瓦片的**同帧**兜底。
        // 否则新图层会先闪一帧占位色，等磁盘读完才出图 —— 连续缩放时看着就是「一闪一闪」。
        var recycledImages: [SlippyTile: CGImage] = [:]
        for (tile, layer) in tileLayers where !needed.contains(tile) {
            if let image = Self.contentsImage(of: layer) {
                recycledImages[tile] = image
            }
            layer.removeFromSuperlayer()
            tileLayers[tile] = nil
            layerImageSource[tile] = nil
            fallbackTasks.remove(tile)
        }

        for tile in needed {
            let worldX = Double(tile.x) / Double(1 << zoom)
            let worldY = Double(tile.y) / Double(1 << zoom)
            let origin = camera.layerPoint(forWorldPoint: CGPoint(x: worldX, y: worldY))
            let frame = CGRect(x: origin.x, y: origin.y, width: tileDisplaySize, height: tileDisplaySize)

            let layer: CALayer
            if let existing = tileLayers[tile] {
                layer = existing
            } else {
                layer = CALayer()
                layer.magnificationFilter = .trilinear
                layer.minificationFilter = .trilinear
                layer.contentsGravity = .resize
                layer.contentsScale = scale
                // 新格子一开始是**透明**的：换层级时先让下面保留的上一层图层顶着，
                // 自己的图到了再淡入。这里要是铺一层半透明占位色（而且它还盖在上一层图上），
                // 每跨一次层级整屏就会先蒙上一层灰白纱再恢复 —— 那就是「一闪一闪」。
                tileLayers[tile] = layer
                hostLayer.insertSublayer(layer, below: gridLayer)
            }
            if layerImageSource[tile] == nil,
               let ancestor = Self.bestAncestor(of: tile, in: recycledImages),
               let image = recycledImages[ancestor] {
                install(image, in: layer, source: ancestor, for: tile, animated: false)
            }
            layer.frame = frame
        }
        CATransaction.commit()

        requestMissingTiles(needed: needed, provider: provider)
        applyFallbackImages(needed: needed, provider: provider)
        updateBackdropFrames(camera: camera)
        dropBackdropIfSettled(needed: needed)
        renderGrid(camera: camera, zoom: zoom, visible: showGrid)

        let frame = TileLayerFrame(
            name: name,
            zoom: zoom,
            needed: needed.count,
            loaded: layerImageSource.filter { $0.key == $0.value }.count,
            fallback: layerImageSource.count - layerImageSource.filter { $0.key == $0.value }.count,
            missing: missingTiles.count,
            tileDisplaySize: tileDisplaySize
        )
        prefetchSurroundingTiles(camera: camera, needed: needed)
        return frame
    }

    /// 当前相机对应的整数层级（夹到数据源范围内的取值）。
    func dataZoom(for camera: MapCamera) -> Int {
        let raw = Int(camera.zoomLevel.rounded())
        return min(max(raw, dataZoomRange.lowerBound), dataZoomRange.upperBound)
    }

    // MARK: - 取图

    private func requestMissingTiles(needed: Set<SlippyTile>, provider: TileProvider) {
        let currentGeneration = generation
        let outstanding = tileTasks.count
        // 只按「自己的图还没上屏、没有在途请求、也不是已确认缺片」判断是否要取图。
        // 注意不能只看 `contents == nil`：祖先贴图先顶上时图层也有内容，但自己的图仍要取。
        var pending: [SlippyTile] = needed.filter { tile in
            layerImageSource[tile] != tile
                && tileTasks[tile] == nil
                && !missingTiles.contains(tile)
        }
        guard !pending.isEmpty else { return }

        // 靠近视图中心的瓦片优先加载。
        let center = cameraCenter
        pending.sort { distanceSquared($0, center: center) < distanceSquared($1, center: center) }

        let budget = max(0, maximumConcurrentRequests - outstanding)
        for tile in pending.prefix(budget) {
            tileTasks[tile] = Task { @MainActor [weak self] in
                guard let self else { return }
                let image = await provider.image(for: tile)
                guard self.generation == currentGeneration else { return }
                self.tileTasks[tile] = nil
                guard let image else {
                    self.missingTiles.insert(tile)
                    self.scheduleRefill()
                    return
                }
                if let layer = self.tileLayers[tile] {
                    // 首次出现也做一次很短的淡入：瓦片是按解码完成的先后落下来的，
                    // 硬贴上去就是一块块「啪」地跳出来，一屏几十块看着就是闪。
                    self.install(image, in: layer, source: tile, for: tile, animated: true)
                }
                // 并发额度腾出来了，把这一帧没排上队的瓦片接着取。
                self.scheduleRefill()
            }
        }
    }

    /// 本轮请求结束后补跑一次同步，避免超出并发额度的瓦片要等到下次交互才加载。
    private func scheduleRefill() {
        guard !refillScheduled else { return }
        refillScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refillScheduled = false
            self.needsSync?()
        }
    }

    // MARK: - 祖先贴图兜底

    /// 背景层跟着相机走，缩放平移时始终保持与当前层级对齐。
    private func updateBackdropFrames(camera: MapCamera) {
        guard !backdropLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (tile, layer) in backdropLayers {
            let count = Double(1 << tile.zoom)
            let size = CGFloat(camera.pixelsPerWorldUnit / count)
            let origin = camera.layerPoint(forWorldPoint: CGPoint(
                x: Double(tile.x) / count,
                y: Double(tile.y) / count
            ))
            layer.frame = CGRect(x: origin.x, y: origin.y, width: size, height: size)
        }
        CATransaction.commit()
    }

    /// 当前层级的每一格都有自己的图（或已确认缺片）之后，背景层就没必要留着了。
    private func dropBackdropIfSettled(needed: Set<SlippyTile>) {
        guard !backdropLayers.isEmpty else { return }
        let settled = needed.allSatisfy { tile in
            layerImageSource[tile] == tile || missingTiles.contains(tile)
        }
        guard settled else { return }

        let retired = backdropLayers
        backdropLayers.removeAll()
        // 「减少动态效果」时直接摘掉，不做淡出。
        guard !InterfaceStyle.reducesMotion else {
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
    private func applyFallbackImages(needed: Set<SlippyTile>, provider: TileProvider) {
        let waiting = needed.filter {
            layerImageSource[$0] == nil
                && !fallbackTasks.contains($0)
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
            fallbackTasks.insert(tile)
            Task { @MainActor [weak self] in
                let ancestor = await Self.firstAvailableAncestor(of: tile, provider: provider)
                guard let self else { return }
                self.fallbackTasks.remove(tile)
                guard self.generation == currentGeneration else { return }
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
    private static func firstAvailableAncestor(
        of tile: SlippyTile,
        provider: TileProvider
    ) async -> (tile: SlippyTile, image: CGImage)? {
        var level = tile.zoom - 1
        var tries = 0
        while level >= 0, tries < maximumFallbackLevels {
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
    static func bestAncestor(of tile: SlippyTile, in images: [SlippyTile: CGImage]) -> SlippyTile? {
        guard !images.isEmpty else { return nil }
        var level = tile.zoom - 1
        var tries = 0
        while level >= 0, tries < maximumFallbackLevels {
            let shift = tile.zoom - level
            let ancestor = SlippyTile(zoom: level, x: tile.x >> shift, y: tile.y >> shift)
            if images[ancestor] != nil { return ancestor }
            level -= 1
            tries += 1
        }
        return nil
    }

    /// 取出图层里装的图片（`CALayer.contents` 是 `Any?`，用 CFTypeID 判断再取）。
    static func contentsImage(of layer: CALayer) -> CGImage? {
        guard let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    /// 把图片装进格子：来源可能是自己，也可能是祖先（按 `contentsRect` 裁出对应子区域）。
    private func install(
        _ image: CGImage,
        in layer: CALayer,
        source: SlippyTile,
        for tile: SlippyTile,
        animated: Bool
    ) {
        let rect = Self.contentsRect(source: source, destination: tile)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, !InterfaceStyle.reducesMotion {
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
    static func contentsRect(source: SlippyTile, destination: SlippyTile) -> CGRect {
        let shift = destination.zoom - source.zoom
        guard shift > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let factor = Double(1 << shift)
        let dx = Double(destination.x - source.x * (1 << shift)) / factor
        let dy = Double(destination.y - source.y * (1 << shift)) / factor
        return CGRect(x: dx, y: dy, width: 1 / factor, height: 1 / factor)
    }

    // MARK: - 预取与网格

    /// 预取视野外一圈的瓦片，让接下来的平移不必再等磁盘或网络。
    ///
    /// 只在当前视野已经没有待取瓦片时做（不跟首屏抢并发额度），
    /// 并用「层级 + 视野行列范围」当键，视野没动就不重复预取。
    private func prefetchSurroundingTiles(camera: MapCamera, needed: Set<SlippyTile>) {
        guard let provider else { return }
        let settled = needed.allSatisfy { tile in
            layerImageSource[tile] == tile || missingTiles.contains(tile) || unresolvedTiles.contains(tile)
        }
        guard settled else { return }

        let zoom = dataZoom(for: camera)
        guard let columns = camera.tileColumnRange(zoom: zoom),
              let rows = camera.tileRowRange(zoom: zoom) else { return }
        let key = "\(zoom):\(columns.lowerBound)-\(columns.upperBound):\(rows.lowerBound)-\(rows.upperBound)"
        guard key != lastPrefetchKey else { return }
        lastPrefetchKey = key

        let maximumIndex = (1 << zoom) - 1
        var ring: [SlippyTile] = []
        for row in (rows.lowerBound - 1)...(rows.upperBound + 1) {
            for column in (columns.lowerBound - 1)...(columns.upperBound + 1) {
                guard (0...maximumIndex).contains(column), (0...maximumIndex).contains(row) else { continue }
                let tile = SlippyTile(zoom: zoom, x: column, y: row)
                guard !needed.contains(tile) else { continue }
                ring.append(tile)
            }
        }
        guard !ring.isEmpty else { return }

        let batch = Array(ring.prefix(Self.prefetchLimit))
        Task.detached(priority: .utility) {
            await provider.prefetch(batch)
        }
    }

    private func renderGrid(camera: MapCamera, zoom: Int, visible: Bool) {
        guard visible,
              let columns = camera.tileColumnRange(zoom: zoom),
              let rows = camera.tileRowRange(zoom: zoom) else {
            gridLayer.isHidden = true
            gridLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let count = Double(1 << zoom)
        for column in columns.lowerBound...columns.upperBound + 1 {
            let x = camera.layerPoint(forWorldPoint: CGPoint(x: Double(column) / count, y: 0)).x
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: camera.viewportSize.height))
        }
        for row in rows.lowerBound...rows.upperBound + 1 {
            let y = camera.layerPoint(forWorldPoint: CGPoint(x: 0, y: Double(row) / count)).y
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: camera.viewportSize.width, y: y))
        }
        gridLayer.isHidden = false
        gridLayer.path = path
    }

    /// 刷新网格颜色（跟随深浅色）。
    func refreshGridAppearance() {
        gridLayer.strokeColor = NSColor.labelColor.withAlphaComponent(0.32).cgColor
    }

    // MARK: - 辅助

    /// 每次同步前由画布写入的相机中心，用于「靠近中心优先」的排序。
    private var cameraCenter = CGPoint(x: 0.5, y: 0.5)
    /// 补跑同步的回调（画布注入）。
    var needsSync: (() -> Void)?

    /// 更新排序基准（画布在同步前调用）。
    func updateSortCenter(_ center: CGPoint) { cameraCenter = center }

    private func distanceSquared(_ tile: SlippyTile, center: CGPoint) -> Double {
        let n = Double(1 << tile.zoom)
        let dx = (Double(tile.x) + 0.5) / n - center.x
        let dy = (Double(tile.y) + 0.5) / n - center.y
        return dx * dx + dy * dy
    }
}
