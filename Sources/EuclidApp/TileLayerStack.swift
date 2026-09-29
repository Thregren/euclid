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
    /// 该图层基准相对 WGS84 的偏移（米，东/北），WGS84 时为 0。
    var datumOffsetMeters: CGPoint = .zero
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
    /// 这一层的瓦片网格（墨卡托 / 经纬度）。铺图位置、网格线、瓦片读数都按它算。
    private(set) var grid: TileGrid = .webMercator
    /// 数据源自身的最大层级（「原始比例」用）。
    private(set) var maximumDataZoom: Double = 20
    /// 相机上下限（真实层级 ± 余量）。
    private(set) var zoomLevelRange: ClosedRange<Double> = -2...26
    private(set) var isActive = false

    /// 图层不透明度：叠加对照时用它把上层影像淡下去看底图。
    var opacity: Double = 1 {
        didSet { hostLayer.opacity = Float(min(max(opacity, 0), 1)) }
    }

    /// 数据源的坐标基准。WGS84 之外（GCJ-02 / BD-09）的源，瓦片编号与图形都要按偏移对齐，
    /// 否则和 WGS84 的正射影像叠加时会差几百米。
    var datum: Datum = .wgs84

    private var provider: TileProvider?
    /// 这一层的瓦片缓存上限（字节），内存压力下按比例裁剪用。
    private var cacheLimitBytes = 0
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
    /// 确认缺片的格子最多记这么多。
    ///
    /// 这个集合只增不减：在稀疏数据（或数据范围外）来回平移会一直往里塞，虽然只占内存、
    /// 不影响速度，但一次跑一整天能涨到几十万条。超过上限就整个清掉 —— 代价只是把
    /// 已经在屏幕外的那些缺片重新探一遍（负缓存丢了不影响正确性）。
    private static let missingTileLimit = 20_000
    /// 已经排队等下一帧补请求的标记，避免同一帧重复调度。
    private var refillScheduled = false
    /// 上一次预取的「层级 + 视野范围」，用来避免重复预取同一圈。
    private var lastPrefetchKey = ""
    /// 上一次取图用的「层级 + 视野范围」。
    ///
    /// 视野外那一圈只在**视野真的移动了**之后才跟着一起取：瓦片陆续到位时的补跑（refill）
    /// 只补视野内的片子。否则一路拖到数据外面（或稀疏区）时，每补一片就再探一圈空地，
    /// 几百个必然落空的请求会把主线程拖住 —— 这正是「边缘加载」最难看的那种卡。
    private var lastLoadKey = ""
    private var generation = 0

    /// 单帧最多渲染的瓦片数量，作为异常情况下的安全阀。
    private static let maximumTilesPerFrame = 1200
    /// 同时在途的取图任务上限（解码并发由 `TileProvider` 另有限制）。
    /// Retina 上一个整数层级要多铺 4 倍瓦片，这里放宽一点，首屏更快铺满。
    private let maximumConcurrentRequests = 32
    /// 单次预取的瓦片上限（视野外半屏那一圈，宽屏时能到两百来片）。
    private static let prefetchLimit = 256
    /// 取图时视野外那几圈的上限：拖动时多取的就是它，得有上限，不然拖到数据外面会白探一大片。
    private static let surroundingTileLimit = 96
    /// 铺图时视野外也铺两圈（见 `sync` 里的说明）。
    private static let layoutMarginTiles = 2
    /// 铺图这一圈的上限。
    private static let layoutRingLimit = 192
    /// 祖先层级最多回溯几级。数值越大，稀疏数据越不容易露白，但请求也越多。
    private static let maximumFallbackLevels = 4
    /// 同时在找祖先贴图的格子数量上限，避免一屏几十个空格同时发起请求。
    private static let maximumFallbackLookups = 8
    /// 每格瓦片向外撑出的量（点）：一半像素左右刚好盖住图层边缘的采样渗色。
    private static let tileSeamOverlap: CGFloat = 0.5

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
        grid: TileGrid = .webMercator,
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
        cacheLimitBytes = memoryLimitBytes
        self.name = name
        baseTileSize = Double(max(1, tileSize))
        self.grid = grid
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

    /// 「一屏还铺得出来」的最低相机层级。
    ///
    /// 相机缩到比数据最低层级还小时，这一层会把瓦片层级夹在数据的最低层级上，
    /// 一屏要铺的瓦片数就按 4 的幂往上涨（缩出去 3 级就是一屏六千多片）。
    /// 超过 `maximumTilesPerFrame` 这个安全阀，`sync` 只能清空画布 —— 那看起来
    /// 就跟「数据没打开」一样（整省 z12 的数据在「适应窗口」下正好会踩到）。
    ///
    /// 这里按当前视口反推「还能铺得出来」的最低层级，交给相机的缩放下限用：
    /// 想看全貌就停在还能铺出来的那一档，画面仍然是真实几何（不做抽样拉伸 ——
    /// 这是个测量工具，宁可少看一点，也不能让影像错位）。
    func affordableCameraZoom(viewportSize: CGSize, displayScale: Double) -> Double {
        let tilePoints = cameraTileSize(displayScale: displayScale)
        guard isActive, tilePoints > 0, viewportSize.width > 1, viewportSize.height > 1 else {
            return zoomLevelRange.lowerBound
        }
        // 换算口径统一放在 `TileBudget` 里（连设备像素比一起算），这里只喂参数。
        return TileBudget.affordableZoomLevel(
            viewportSize: viewportSize,
            tilePixelSize: tilePoints,
            displayScale: displayScale,
            minimumDataZoom: dataZoomRange.lowerBound,
            maximumTiles: Self.maximumTilesPerFrame
        )
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
        lastLoadKey = ""
        gridLayer.isHidden = true
        gridLayer.path = nil
    }

    // MARK: - 渲染

    /// 把当前相机下的瓦片铺好。返回本帧的关键数字（没有内容时返回 nil）。
    func sync(
        camera: MapCamera,
        viewportSize: CGSize,
        displayScale: Double,
        showGrid: Bool,
        loadsTiles: Bool = true
    ) -> TileLayerFrame? {
        scale = CGFloat(displayScale)
        guard let provider, viewportSize.width > 1, viewportSize.height > 1 else {
            removeAllLayers()
            return nil
        }

        let zoom = dataZoom(for: camera)
        // 取图行列按「偏移后的相机」算：得到的编号是该基准下的瓦片编号。
        let offset = worldOffset(for: camera)
        let rangeCamera = self.rangeCamera(camera, offset: offset)
        guard let range = grid.tileRange(zoom: zoom, worldRect: rangeCamera.visibleWorldRect) else {
            return nil
        }
        let columns = range.columns
        let rows = range.rows
        let total = columns.count * rows.count
        guard total <= Self.maximumTilesPerFrame else {
            // 超出安全阀时宁可清空，也不要留着上一帧的残影误导判读。
            removeAllLayers()
            return TileLayerFrame(name: name, zoom: zoom, needed: total, loaded: 0,
                                  fallback: 0, missing: missingTiles.count, tileDisplaySize: 0)
        }

        let tileDisplaySize = CGFloat(camera.pixelsPerWorldUnit / Double(1 << zoom))

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
        //
        // 另外多铺一圈（`layoutMarginTiles`）：手势期间画面靠 `hostLayer.transform` 整体位移，
        // 而布局只在「位移攒够 120 点」时才重做 —— 不多铺这一圈的话，这段还没提交的位移
        // 在画面边缘就会先露出底色，等下一次提交才补上，看着就是「边缘一直在加载」。
        // 这一圈不进 `needed`（读数、兜底、缺片统计仍只算视野内），只多几个图层而已。
        let layoutRing = surroundingTiles(
            zoom: zoom,
            columns: columns,
            rows: rows,
            margin: Self.layoutMarginTiles,
            limit: Self.layoutRingLimit,
            excluding: needed
        )
        let laidOut = layoutRing.isEmpty ? needed : needed.union(layoutRing)

        var recycledImages: [SlippyTile: CGImage] = [:]
        for (tile, layer) in tileLayers where !laidOut.contains(tile) {
            if let image = Self.contentsImage(of: layer) {
                recycledImages[tile] = image
            }
            layer.removeFromSuperlayer()
            tileLayers[tile] = nil
            layerImageSource[tile] = nil
            fallbackTasks.remove(tile)
        }

        for tile in laidOut {
            // 经纬度网格的行按纬度等分，换算到墨卡托世界后每张瓦片的高度都不一样，
            // 因此 frame 必须**逐片**按自己的世界矩形算（墨卡托网格下等价于原来的正方形）。
            let world = grid.worldRect(zoom: zoom, column: tile.x, row: tile.y)
            // 图形本身按偏移后的位置落位，于是该基准的栅格与工作基准的坐标对齐。
            let origin = camera.layerPoint(forWorldPoint: CGPoint(
                x: world.minX + offset.x,
                y: world.minY + offset.y
            ))
            // 瓦片铺在非整数倍比例上时，图层边缘会带出半像素的采样渗色，
            // 一整片白底影像上就是每隔一片一条浅灰细线。把每格的 frame 撑开半个点，
            // 让相邻瓦片互相盖住这道缝（内容是不透明的，重叠看不出来）。
            let frame = CGRect(
                x: origin.x - Self.tileSeamOverlap,
                y: origin.y - Self.tileSeamOverlap,
                width: CGFloat(world.width * camera.pixelsPerWorldUnit) + Self.tileSeamOverlap * 2,
                height: CGFloat(world.height * camera.pixelsPerWorldUnit) + Self.tileSeamOverlap * 2
            )

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

        // 手势进行中只挪图层、不取图：解码与磁盘（或网络）一旦插进来，
        // 快速拖动时每次提交都会掀起一波请求，画面就开始一顿一顿。
        // 手停下来那一次（loadsTiles = true）才真正去取。
        if loadsTiles {
            // 视野外再取一圈：拖动时新露出来的那一圈不该等到手停下来才有图。
            // 取图按「离视野中心远近」排序，所以这一圈自然排在视野内那些之后，不抢它们的额度。
            let loadKey = "\(zoom):\(columns.lowerBound)-\(columns.upperBound):\(rows.lowerBound)-\(rows.upperBound)"
            let includesSurroundings = loadKey != lastLoadKey
            lastLoadKey = loadKey
            requestMissingTiles(
                needed: includesSurroundings
                    ? needed.union(surroundingTiles(
                        zoom: zoom,
                        columns: columns,
                        rows: rows,
                        margin: outwardMarginTiles,
                        limit: Self.surroundingTileLimit,
                        excluding: needed
                    ))
                    : needed,
                provider: provider
            )
            applyFallbackImages(needed: needed, provider: provider)
        }
        updateBackdropFrames(camera: camera, offset: offset)
        dropBackdropIfSettled(needed: needed)
        renderGrid(camera: rangeCamera, offset: offset, zoom: zoom, visible: showGrid)

        // 读数只算视野内的那一批（铺图多铺的那一圈不进读数）。
        let loadedVisible = needed.filter { layerImageSource[$0] == $0 }.count
        let fallbackVisible = needed.filter { tile in
            guard let source = layerImageSource[tile] else { return false }
            return source != tile
        }.count
        let missingVisible = needed.filter { missingTiles.contains($0) }.count
        let frame = TileLayerFrame(
            name: name,
            zoom: zoom,
            needed: needed.count,
            loaded: loadedVisible,
            fallback: fallbackVisible,
            missing: missingVisible,
            tileDisplaySize: tileDisplaySize,
            datumOffsetMeters: datumOffsetMeters(for: camera, offset: offset)
        )
        if loadsTiles { prefetchSurroundingTiles(camera: rangeCamera, needed: needed) }
        return frame
    }

    /// 该图层数据源基准相对工作基准（WGS84）的归一化世界偏移。
    private func worldOffset(for camera: MapCamera) -> CGPoint {
        guard datum != .wgs84 else { return .zero }
        let center = WebMercator.coordinate(fromNormalized: camera.center)
        let shifted = WebMercator.normalized(datum.fromWGS84(center))
        return CGPoint(x: shifted.x - camera.center.x, y: shifted.y - camera.center.y)
    }

    /// 算取图行列时用的相机：把中心按偏移移回去，于是行列范围落在该基准的瓦片网格上。
    private func rangeCamera(_ camera: MapCamera, offset: CGPoint) -> MapCamera {
        guard offset != .zero else { return camera }
        var shifted = camera
        shifted.center = CGPoint(x: camera.center.x - offset.x, y: camera.center.y - offset.y)
        return shifted
    }

    /// 基准偏移的米制写法（日志与界面提示用）。
    private func datumOffsetMeters(for camera: MapCamera, offset: CGPoint) -> CGPoint {
        guard datum != .wgs84, offset != .zero else { return .zero }
        let center = WebMercator.coordinate(fromNormalized: camera.center)
        let ground = WebMercator.groundMetersPerWorldUnit(latitude: center.latitude)
        return CGPoint(x: offset.x * ground, y: offset.y * ground)
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
        Self.tileRequestCount += min(budget, pending.count)
        for tile in pending.prefix(budget) {
            tileTasks[tile] = Task { @MainActor [weak self] in
                guard let self else { return }
                let image = await provider.image(for: tile)
                guard self.generation == currentGeneration else { return }
                self.tileTasks[tile] = nil
                guard let image else {
                    if self.missingTiles.count >= Self.missingTileLimit {
                        self.missingTiles.removeAll(keepingCapacity: true)
                    }
                    self.missingTiles.insert(tile)
                    self.scheduleRefill()
                    return
                }
                if let layer = self.tileLayers[tile] {
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
    private func updateBackdropFrames(camera: MapCamera, offset: CGPoint) {
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
            Self.tileRequestCount += 1
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
        // 上面已经用 CFTypeID 核对过类型，这里的桥接是确定的（`as?` 反而会被编译器判为恒成立）。
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

    /// 视野外一圈一圈往外扩的瓦片（不含视野内已有的那些）。
    ///
    /// 拖动时新露出来的边正好落在这一圈里：把它们跟视野内的瓦片一起取，
    /// 手一直在动的时候边上也有图，而不是等松手才一片片补上来。
    ///
    /// 从里往外一圈一圈取、取够 `limit` 就停：这样「离视野越近越先取」是天然的，
    /// 也保证了一次手势最多只会多探这么多片（拖到数据外面时这些请求都会落空，得有上限）。
    private func surroundingTiles(
        zoom: Int,
        columns: ClosedRange<Int>,
        rows: ClosedRange<Int>,
        margin: Int,
        limit: Int,
        excluding visible: Set<SlippyTile>
    ) -> [SlippyTile] {
        guard margin > 0, limit > 0 else { return [] }
        let maximum = (1 << zoom) - 1
        var seen = Set<SlippyTile>()
        var result: [SlippyTile] = []
        for step in 1...margin {
            let stepColumns = (columns.lowerBound - step)...(columns.upperBound + step)
            let stepRows = (rows.lowerBound - step)...(rows.upperBound + step)
            ring: for row in stepRows {
                for column in stepColumns {
                    if result.count >= limit { break ring }
                    // 只取这一圈的边：里面几圈上一轮已经取过了。
                    let onEdge = row == stepRows.lowerBound || row == stepRows.upperBound
                        || column == stepColumns.lowerBound || column == stepColumns.upperBound
                    guard onEdge else { continue }
                    guard (0...maximum).contains(column), (0...maximum).contains(row) else { continue }
                    let tile = SlippyTile(zoom: zoom, x: column, y: row)
                    guard !visible.contains(tile) else { continue }
                    guard seen.insert(tile).inserted else { continue }
                    result.append(tile)
                }
            }
            if result.count >= limit { break }
        }
        return result
    }

    /// 预取视野外一圈的瓦片，让接下来的平移不必再等磁盘或网络。
    ///
    /// 范围是「半屏、至少两格」：一次甩动大致就是半屏，正好盖住。
    /// 只在当前视野没有在途取图时做（不跟首屏抢并发额度），
    /// 并用「层级 + 视野行列范围」当键，视野没动就不重复预取。
    private func prefetchSurroundingTiles(camera: MapCamera, needed: Set<SlippyTile>) {
        guard let provider else { return }
        guard !defersBackgroundWork else { return }
        // 「视野内都在途了」就够：不必等每一片都落屏 —— 拖动中间也要能把这一圈补上，
        // 否则就成了「手一停才补、手一动又露白」。
        let settled = needed.allSatisfy { tile in
            layerImageSource[tile] == tile || tileTasks[tile] == nil
        }
        guard settled else { return }

        let zoom = dataZoom(for: camera)
        guard let range = grid.tileRange(zoom: zoom, worldRect: camera.visibleWorldRect) else { return }
        let columns = range.columns
        let rows = range.rows
        let key = "\(zoom):\(columns.lowerBound)-\(columns.upperBound):\(rows.lowerBound)-\(rows.upperBound)"
        guard key != lastPrefetchKey else { return }
        lastPrefetchKey = key

        // 半屏（至少两格）：视野 6×4 时往外各 3 格，正好顶住一次半屏的甩动。
        let margin = max(2, Int((Double(max(columns.count, rows.count)) * 0.5).rounded(.up)))
        let ring = surroundingTiles(
            zoom: zoom,
            columns: columns,
            rows: rows,
            margin: margin,
            limit: Self.prefetchLimit,
            excluding: needed
        )
        guard !ring.isEmpty else { return }

        Task.detached(priority: .utility) {
            await provider.prefetch(ring)
        }
    }

    private func renderGrid(camera: MapCamera, offset: CGPoint, zoom: Int, visible: Bool) {
        guard visible,
              let range = grid.tileRange(zoom: zoom, worldRect: camera.visibleWorldRect) else {
            gridLayer.isHidden = true
            gridLayer.path = nil
            return
        }
        let columns = range.columns
        let rows = range.rows
        let path = CGMutablePath()
        let count = Double(1 << zoom)
        for column in columns.lowerBound...columns.upperBound + 1 {
            let x = camera.layerPoint(forWorldPoint: CGPoint(
                x: Double(column) / count + offset.x,
                y: offset.y
            )).x
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: camera.viewportSize.height))
        }
        for row in rows.lowerBound...rows.upperBound + 1 {
            // 经纬度网格的横线落在纬度边界上，得先换算成墨卡托 y —— 直接按行号等分会错位。
            let y = camera.layerPoint(forWorldPoint: CGPoint(
                x: offset.x,
                y: grid.worldRowBoundary(zoom: zoom, row: row) + offset.y
            )).y
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: camera.viewportSize.width, y: y))
        }
        gridLayer.isHidden = false
        gridLayer.path = path
    }

    /// 刷新网格颜色（跟随深浅色）。
    ///
    /// 颜色由画布按**当前有效外观**解析好后传进来：CALayer 的颜色没有「语义」，
    /// 设置的那一刻就定死了，自己在这里取 `labelColor.cgColor` 只会拿到系统外观的值。
    func refreshGridAppearance(stroke: CGColor) {
        gridLayer.strokeColor = stroke
    }

    // MARK: - 辅助

    /// 每次同步前由画布写入的相机中心，用于「靠近中心优先」的排序。
    private var cameraCenter = CGPoint(x: 0.5, y: 0.5)
    /// 补跑同步的回调（画布注入）。
    var needsSync: (() -> Void)?

    /// 把这一层的瓦片缓存压到上限的给定比例（内存压力下由画布统一调用）。
    func trimCache(toFraction fraction: Double) {
        guard let provider, cacheLimitBytes > 0 else { return }
        let target = Int(Double(cacheLimitBytes) * min(max(fraction, 0), 1))
        Task { await provider.trimCache(keepingBytes: target) }
    }

    /// 调试用：这一层缓存了多少片、多少字节。
    func cacheStats() async -> (tiles: Int, bytes: Int)? {
        await provider?.cacheStats
    }

    /// 更新排序基准（画布在同步前调用）。
    func updateSortCenter(_ center: CGPoint) { cameraCenter = center }

    /// 正在拖窗口改大小：先不做预取这类后台活，等拖完再补（见 `TileCanvasNSView` 的 live resize 处理）。
    var defersBackgroundWork = false

    /// 手势（拖动 / 缩放）进行中。
    ///
    /// 拖动时视野外多取一圈：新露出来的边要是还得等，就成了「手一动边上就白、手一停才补上」，
    /// 看着像边缘一直在加载。这一圈跟视野内的瓦片一起排队（按离视野中心的远近排序），
    /// 所以不会抢视野内的额度；同时新到的图不做淡入 —— 拖动中淡入本身也像在「加载」。
    var isInteracting = false

    /// 视野外再取几格：拖动时多取两圈（按每秒两千点的手速，约等于大半秒的提前量），
    /// 停下后回到一格（更外面那半屏由预取负责）。
    private var outwardMarginTiles: Int { isInteracting ? 3 : 1 }

    /// 累计发起的取图次数（含祖先兜底与预取），只用于调试统计：
    /// `EUCLID_TRACE_SCROLL=1` 时会在手势结束时打出「这次手势取了多少片」。
    private(set) static var tileRequestCount = 0
    static func resetTileRequestCount() { tileRequestCount = 0 }

    private func distanceSquared(_ tile: SlippyTile, center: CGPoint) -> Double {
        // 用瓦片在世界里的真实中心：经纬度网格的瓦片不是正方形，中心也不在
        // `(行号 + 0.5) / n` 上（高纬处偏得更明显）。这个值只用来排序「谁先取」，
        // 但排序偏了就会先取边缘的、后取眼前的。
        let rect = grid.worldRect(zoom: tile.zoom, column: tile.x, row: tile.y)
        let dx = rect.midX - center.x
        let dy = rect.midY - center.y
        return dx * dx + dy * dy
    }
}
