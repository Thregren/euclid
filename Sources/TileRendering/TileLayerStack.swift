import Foundation
import QuartzCore
import TileKit

/// 一条瓦片图层栈一次渲染后的关键数字，供调试输出与状态汇报使用。
public struct TileLayerFrame {
    public var name: String
    public var zoom: Int
    public var needed: Int
    public var loaded: Int
    public var fallback: Int
    public var missing: Int
    public var tileDisplaySize: CGFloat
    /// 该图层基准相对 WGS84 的偏移（米，东/北），WGS84 时为 0。
    public var datumOffsetMeters: CGPoint = .zero
}

/// 一条瓦片图层栈：一个数据源对应一个宿主图层，外加「换层级留旧图顶着」那一整套。
///
/// macOS 与 iOS / iPadOS 的画布共用此渲染器，各图层共用同一个相机，
/// 因此叠加显示时缩放、平移、层级切换天然同步；每条各自维护取图、缓存、兜底与预取。
@MainActor
public final class TileLayerStack {
    public let hostLayer = CALayer()
    /// 瓦片网格（调试用），跟着本层可见范围绘制。
    public let gridLayer = CAShapeLayer()

    public internal(set) var name = ""
    /// 数据源实际提供的整数层级范围。
    public internal(set) var dataZoomRange: ClosedRange<Int> = 0...22
    /// 这一层的瓦片网格（墨卡托 / 经纬度）。铺图位置、网格线、瓦片读数都按它算。
    public internal(set) var grid: TileGrid = .webMercator
    /// 数据源自身的最大层级（「原始比例」用）。
    public internal(set) var maximumDataZoom: Double = 20
    /// 相机上下限（真实层级 ± 余量）。
    public internal(set) var zoomLevelRange: ClosedRange<Double> = -2...26
    public internal(set) var isActive = false

    /// 图层不透明度：叠加对照时用它把上层影像淡下去看底图。
    public var opacity: Double = 1 {
        didSet {
            hostLayer.opacity = Float(min(max(opacity, 0), 1))
            if hostLayer.opacity == 0 { suspendHiddenLayer() }
        }
    }
    private var isSuspendedForVisibility = false

    public func setVisible(_ visible: Bool) {
        hostLayer.isHidden = !visible
        if !visible { suspendHiddenLayer() }
    }

    private func suspendHiddenLayer() {
        guard !isSuspendedForVisibility else { return }
        isSuspendedForVisibility = true
        generation += 1
        cancelRequests()
        removeAllLayers()
        if let interval = firstTileInterval { TilePerformance.end(interval); firstTileInterval = nil }
        if let provider { Task { await provider.trimCache(keepingBytes: min(cacheLimitBytes, 16 << 20)) } }
    }

    /// 数据源的坐标基准。WGS84 之外（GCJ-02 / BD-09）的源，瓦片编号与图形都要按偏移对齐，
    /// 否则和 WGS84 的正射影像叠加时会差几百米。
    public var datum: Datum = .wgs84
    /// 系统辅助功能偏好由平台适配层注入。
    public var reducesMotion = false

    var provider: TileProvider?
    /// 这一层的瓦片缓存上限（字节），内存压力下按比例裁剪用。
    var cacheLimitBytes = 0
    var baseTileSize: Double = 512
    /// 在线底图按「一张瓦片铺满它的像素数」显示，相机里的边长要跟着设备像素比走。
    var tileSizeFollowsDisplayScale = false
    var scale: CGFloat = 2

    var tileLayers: [SlippyTile: CALayer] = [:]
    /// 换层级时保留下来的上一层图层：新图层的图还没到位前由它顶着，避免整屏变灰。
    var backdropLayers: [SlippyTile: CALayer] = [:]
    /// 当前真正在渲染的层级。
    var renderedZoom: Int?
    var tileTasks: [SlippyTile: Task<Void, Never>] = [:]
    /// 每一格当前显示的图片来自哪一块瓦片：自己，或者某个祖先层级。
    var layerImageSource: [SlippyTile: SlippyTile] = [:]
    /// 正在为哪些格子找祖先贴图（避免重复发起）。
    var fallbackTasks: [SlippyTile: Task<Void, Never>] = [:]
    var prefetchTask: Task<Void, Never>?
    var missingTiles: [SlippyTile: Date] = [:]
    var retryTask: Task<Void, Never>?
    /// 已经确认「自己没有图、可回溯的祖先层级也没有图」的格子。
    ///
    /// 少了它，`applyFallbackImages` 的失败分支会一轮接一轮地重新找祖先，
    /// 渲染就变成停不下来的空转：打开数据集时（相机还停在数据之外）每秒能跑两百多轮。
    var unresolvedTiles: Set<SlippyTile> = []
    /// 确认缺片的格子最多记这么多。
    ///
    /// 这个集合只增不减：在稀疏数据（或数据范围外）来回平移会一直往里塞，虽然只占内存、
    /// 不影响速度，但一次跑一整天能涨到几十万条。超过上限就整个清掉 —— 代价只是把
    /// 已经在屏幕外的那些缺片重新探一遍（负缓存丢了不影响正确性）。
    static let missingTileLimit = 20_000
    /// 已经排队等下一帧补请求的标记，避免同一帧重复调度。
    var refillTask: Task<Void, Never>?
    /// 上一次预取的「层级 + 视野范围」，用来避免重复预取同一圈。
    var lastPrefetchKey = ""
    /// 上一次取图用的「层级 + 视野范围」。
    ///
    /// 视野外那一圈只在**视野真的移动了**之后才跟着一起取：瓦片陆续到位时的补跑（refill）
    /// 只补视野内的片子。否则一路拖到数据外面（或稀疏区）时，每补一片就再探一圈空地，
    /// 几百个必然落空的请求会把主线程拖住 —— 这正是「边缘加载」最难看的那种卡。
    var lastLoadKey = ""
    var generation = 0
    var firstTileInterval: TilePerformance.Interval?

    /// 单帧最多渲染的瓦片数量，作为异常情况下的安全阀。
    static let maximumTilesPerFrame = 1200
    /// 同时在途的取图任务上限（解码并发由 `TileProvider` 另有限制）。
    /// Retina 上一个整数层级要多铺 4 倍瓦片，这里放宽一点，首屏更快铺满。
    let maximumConcurrentRequests = 32
    /// 单次预取的瓦片上限（视野外半屏那一圈，宽屏时能到两百来片）。
    static let prefetchLimit = 256
    /// 取图时视野外那几圈的上限：拖动时多取的就是它，得有上限，不然拖到数据外面会白探一大片。
    static let surroundingTileLimit = 96
    /// 铺图时视野外也铺两圈（见 `sync` 里的说明）。
    static let layoutMarginTiles = 2
    /// 铺图这一圈的上限。
    static let layoutRingLimit = 192
    /// 祖先层级最多回溯几级。数值越大，稀疏数据越不容易露白，但请求也越多。
    static let maximumFallbackLevels = 4
    /// 同时在找祖先贴图的格子数量上限，避免一屏几十个空格同时发起请求。
    static let maximumFallbackLookups = 8
    /// 每格瓦片向外撑出的量（点）：一半像素左右刚好盖住图层边缘的采样渗色。
    static let tileSeamOverlap: CGFloat = 0.5

    /// 调试用（`EUCLID_TRACE_LAYERS=1`）：把这一层的装配 / 清空 / 提前退出打到 stderr。
    static let tracesLayers =
        ProcessInfo.processInfo.environment["EUCLID_TRACE_LAYERS"] != nil

    func traceStack(_ text: String) {
        guard Self.tracesLayers else { return }
        FileHandle.standardError.write(Data("[stack] \(text)\n".utf8))
    }

    public init(flipsGeometry: Bool = true) {
        hostLayer.isGeometryFlipped = flipsGeometry
        hostLayer.masksToBounds = true
        gridLayer.fillColor = nil
        gridLayer.lineWidth = 1
        gridLayer.isHidden = true
        hostLayer.addSublayer(gridLayer)
    }

    // MARK: - 装配

    public func configure(
        source: any TileImageSource,
        name: String,
        tileSize: Int,
        zoomRange: ClosedRange<Int>,
        grid: TileGrid = .webMercator,
        followsDisplayScale: Bool,
        maximumDataZoom: Double,
        memoryLimitBytes: Int = TileResourcePolicy.defaultTileCacheBytes,
        maxConcurrentRequests: Int = TileResourcePolicy.concurrentDecodes
    ) {
        generation += 1
        cancelRequests()
        removeAllLayers()
        traceStack("configure 名称=\(name) 层级=\(zoomRange.lowerBound)…\(zoomRange.upperBound)")
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
        isSuspendedForVisibility = false
        if let interval = firstTileInterval { TilePerformance.end(interval) }
        firstTileInterval = TilePerformance.begin("First visible tile")
    }

    public func clear() {
        if let interval = firstTileInterval { TilePerformance.end(interval); firstTileInterval = nil }
        generation += 1
        cancelRequests()
        removeAllLayers()
        traceStack("clear 名称=\(name)")
        provider = nil
        name = ""
        isActive = false
    }

    /// 相机里的瓦片边长（视图点）。
    public func cameraTileSize(displayScale: Double) -> Double {
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
    public func affordableCameraZoom(viewportSize: CGSize, displayScale: Double) -> Double {
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

    public func setContentsScale(_ scale: CGFloat) {
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tileLayers.values { layer.contentsScale = scale }
        for layer in backdropLayers.values { layer.contentsScale = scale }
        CATransaction.commit()
    }

    public func cancelRequests() {
        retryTask?.cancel()
        retryTask = nil
        for task in tileTasks.values { task.cancel() }
        for task in fallbackTasks.values { task.cancel() }
        tileTasks.removeAll()
        fallbackTasks.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
        lastPrefetchKey = ""
        refillTask?.cancel()
        refillTask = nil
    }

    func removeAllLayers() {
        traceStack("清空全部瓦片层（原有 \(tileLayers.count) 片）")
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
    public func sync(
        camera: MapCamera,
        viewportSize: CGSize,
        displayScale: Double,
        showGrid: Bool,
        loadsTiles: Bool = true
    ) -> TileLayerFrame? {
        guard !hostLayer.isHidden, hostLayer.opacity > 0 else {
            suspendHiddenLayer()
            return nil
        }
        isSuspendedForVisibility = false
        let interval = TilePerformance.begin("Layer layout")
        defer { TilePerformance.end(interval) }
        scale = CGFloat(displayScale)
        guard let provider, viewportSize.width > 1, viewportSize.height > 1 else {
            traceStack(
                "sync 提前退出：provider=\(provider == nil ? "无" : "有")"
                    + " 视口=\(Int(viewportSize.width))x\(Int(viewportSize.height))"
            )
            removeAllLayers()
            return nil
        }

        let zoom = dataZoom(for: camera)
        // 取图行列按「偏移后的相机」算：得到的编号是该基准下的瓦片编号。
        let offset = worldOffset(for: camera)
        let rangeCamera = self.rangeCamera(camera, offset: offset)
        guard let range = grid.tileRange(zoom: zoom, worldRect: rangeCamera.visibleWorldRect) else {
            traceStack("sync 算不出瓦片范围：z=\(zoom)")
            return nil
        }
        let columns = range.columns
        let rows = range.rows
        let total = columns.count * rows.count
        guard total <= Self.maximumTilesPerFrame else {
            // 超出安全阀时宁可清空，也不要留着上一帧的残影误导判读。
            traceStack("sync 超出安全阀：要铺 \(total) 片 > \(Self.maximumTilesPerFrame)")
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
            generation &+= 1
            cancelRequests()
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
            fallbackTasks.removeValue(forKey: tile)?.cancel()
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
            // 值没变就别碰：一帧近千个图层，「瓦片到位」「手势提交」这类重铺里绝大多数 frame
            // 与上一帧完全相同，而 CALayer 不保证对「赋等值」提前返回 —— 累起来就是重铺的主要开销。
            if layer.frame != frame { layer.frame = frame }
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
        // 三个数字合成一次遍历：视野内最多上千片，三次 `filter` 就是三遍哈希查找。
        var loadedVisible = 0
        var fallbackVisible = 0
        var missingVisible = 0
        for tile in needed {
            if let source = layerImageSource[tile] {
                if source == tile { loadedVisible += 1 } else { fallbackVisible += 1 }
            }
            if (missingTiles[tile].map { $0 > Date() } ?? false) { missingVisible += 1 }
        }
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
    func worldOffset(for camera: MapCamera) -> CGPoint {
        guard datum != .wgs84 else { return .zero }
        let center = WebMercator.coordinate(fromNormalized: camera.center)
        let shifted = WebMercator.normalized(datum.fromWGS84(center))
        return CGPoint(x: shifted.x - camera.center.x, y: shifted.y - camera.center.y)
    }

    /// 算取图行列时用的相机：把中心按偏移移回去，于是行列范围落在该基准的瓦片网格上。
    func rangeCamera(_ camera: MapCamera, offset: CGPoint) -> MapCamera {
        guard offset != .zero else { return camera }
        var shifted = camera
        shifted.center = CGPoint(x: camera.center.x - offset.x, y: camera.center.y - offset.y)
        return shifted
    }

    /// 基准偏移的米制写法（日志与界面提示用）。
    func datumOffsetMeters(for camera: MapCamera, offset: CGPoint) -> CGPoint {
        guard datum != .wgs84, offset != .zero else { return .zero }
        let center = WebMercator.coordinate(fromNormalized: camera.center)
        let ground = WebMercator.groundMetersPerWorldUnit(latitude: center.latitude)
        return CGPoint(x: offset.x * ground, y: offset.y * ground)
    }

    /// 当前相机对应的整数层级（夹到数据源范围内的取值）。
    public func dataZoom(for camera: MapCamera) -> Int {
        let raw = Int(camera.zoomLevel.rounded())
        return min(max(raw, dataZoomRange.lowerBound), dataZoomRange.upperBound)
    }

    /// 网格路径的输入签名：这几样没变，画出来的线就一模一样。
    ///
    /// 网格是「开着看」的辅助线，而 `sync` 在瓦片到位、手势提交时都会跑一遍；
    /// 每次都重建几百个点的路径再赋给 `gridLayer.path` 纯属白做。
    struct GridSignature: Equatable {
        var zoom: Int
        var center: CGPoint
        var pixelsPerWorldUnit: Double
        var viewport: CGSize
        var offset: CGPoint
    }

    var lastGridSignature: GridSignature?

    // MARK: - 辅助

    /// 每次同步前由画布写入的相机中心，用于「靠近中心优先」的排序。
    var cameraCenter = CGPoint(x: 0.5, y: 0.5)
    /// 补跑同步的回调（画布注入）。
    public var needsSync: (() -> Void)?

    /// 把这一层的瓦片缓存压到上限的给定比例（内存压力下由画布统一调用）。
    public func trimCache(toFraction fraction: Double) {
        // NaN 会让下面的 `Int(Double)` 直接 trap（`min`/`max` 拦不住 NaN），
        // 所以换算之前先把「不是一个数」挡掉。
        guard let provider, cacheLimitBytes > 0, fraction.isFinite else { return }
        let target = Int(Double(cacheLimitBytes) * min(max(fraction, 0), 1))
        Task { await provider.trimCache(keepingBytes: target) }
    }

    /// 多图层画布分配总预算时调整此额度，不清空图层或重建供应者。
    public func setCacheLimitBytes(_ bytes: Int) {
        let limit = max(0, bytes)
        guard limit != cacheLimitBytes else { return }
        cacheLimitBytes = limit
        guard let provider else { return }
        Task { await provider.setMemoryLimitBytes(limit) }
    }

    /// 调试用：这一层缓存了多少片、多少字节。
    public func cacheStats() async -> (tiles: Int, bytes: Int)? {
        await provider?.cacheStats
    }

    /// 更新排序基准（画布在同步前调用）。
    public func updateSortCenter(_ center: CGPoint) { cameraCenter = center }

    /// 正在拖窗口改大小：先不做预取这类后台活，等拖完再补（由平台画布在 resize / 手势阶段设置）。
    public var defersBackgroundWork = false

    /// 手势（拖动 / 缩放）进行中。
    ///
    /// 拖动时视野外多取一圈：新露出来的边要是还得等，就成了「手一动边上就白、手一停才补上」，
    /// 看着像边缘一直在加载。这一圈跟视野内的瓦片一起排队（按离视野中心的远近排序），
    /// 所以不会抢视野内的额度；同时新到的图不做淡入 —— 拖动中淡入本身也像在「加载」。
    public var isInteracting = false

    /// 视野外再取几格：拖动时多取两圈（按每秒两千点的手速，约等于大半秒的提前量），
    /// 停下后回到一格（更外面那半屏由预取负责）。
    var outwardMarginTiles: Int { isInteracting ? 3 : 1 }

    /// 累计发起的取图次数（含祖先兜底与预取），只用于调试统计：
    /// `EUCLID_TRACE_SCROLL=1` 时会在手势结束时打出「这次手势取了多少片」。
    public internal(set) static var tileRequestCount = 0
    public static func resetTileRequestCount() { tileRequestCount = 0 }

    func distanceSquared(_ tile: SlippyTile, center: CGPoint) -> Double {
        // 用瓦片在世界里的真实中心：经纬度网格的瓦片不是正方形，中心也不在
        // `(行号 + 0.5) / n` 上（高纬处偏得更明显）。这个值只用来排序「谁先取」，
        // 但排序偏了就会先取边缘的、后取眼前的。
        let rect = grid.worldRect(zoom: tile.zoom, column: tile.x, row: tile.y)
        let dx = rect.midX - center.x
        let dy = rect.midY - center.y
        return dx * dx + dy * dy
    }
}
