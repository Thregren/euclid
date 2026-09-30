import CoreGraphics
import Foundation
import ImageIO

/// 单幅影像的地理参考：像素坐标 ↔ 影像坐标 ↔ WGS84。
///
/// 变换是仿射的：
/// `x = originX + 列 * pixelSizeX + 行 * rotationX`
/// `y = originY + 列 * rotationY + 行 * pixelSizeY`
/// 北朝上的正射影像里 `pixelSizeY` 为负（行号向南增大）。
public struct RasterGeoreference: Hashable, Sendable {
    /// 摆放方式。
    public enum Placement: Hashable, Sendable {
        /// 有地理参考，能算经纬度。
        case georeferenced
        /// 没有可用的地理参考：按「1 像素 = 1 米、中心落在本初子午线与赤道交点」摆着看。
        case unreferenced(reason: String)
    }

    public var placement: Placement
    public var crs: RasterCRS
    public var originX: Double
    public var originY: Double
    public var pixelSizeX: Double
    public var pixelSizeY: Double
    public var rotationX: Double
    public var rotationY: Double

    /// 手工构造一份地理参考（自检里要用「把某块已知影像摆在某处」的场景）。
    ///
    /// 正式路径上的地理参考都从文件标签算出来（见 `RasterLoader`），因此这条口子按
    /// 1.15 的约定只开到 `package`：自检与同包模块够得到，不扩大公开 API。
    package init(
        placement: Placement,
        crs: RasterCRS,
        originX: Double,
        originY: Double,
        pixelSizeX: Double,
        pixelSizeY: Double,
        rotationX: Double = 0,
        rotationY: Double = 0
    ) {
        self.placement = placement
        self.crs = crs
        self.originX = originX
        self.originY = originY
        self.pixelSizeX = pixelSizeX
        self.pixelSizeY = pixelSizeY
        self.rotationX = rotationX
        self.rotationY = rotationY
    }

    public var isGeoreferenced: Bool { placement == .georeferenced }

    /// 没有地理参考时用的占位参考（1 像素 = 1 米，中心在原点）。
    public static func unreferenced(reason: String, pixelWidth: Int, pixelHeight: Int) -> RasterGeoreference {
        RasterGeoreference(
            placement: .unreferenced(reason: reason),
            crs: .webMercator,
            originX: -Double(pixelWidth) / 2,
            originY: Double(pixelHeight) / 2,
            pixelSizeX: 1,
            pixelSizeY: -1,
            rotationX: 0,
            rotationY: 0
        )
    }

    /// 像素坐标 → 影像坐标。
    public func crsPoint(column: Double, row: Double) -> CGPoint {
        CGPoint(
            x: originX + column * pixelSizeX + row * rotationX,
            y: originY + column * rotationY + row * pixelSizeY
        )
    }

    /// 影像坐标 → 像素坐标。
    public func pixelPoint(x: Double, y: Double) -> CGPoint? {
        let determinant = pixelSizeX * pixelSizeY - rotationX * rotationY
        guard abs(determinant) > .ulpOfOne else { return nil }
        let dx = x - originX
        let dy = y - originY
        return CGPoint(
            x: (dx * pixelSizeY - dy * rotationX) / determinant,
            y: (dy * pixelSizeX - dx * rotationY) / determinant
        )
    }

    /// 像素坐标 → WGS84；认不出投影时返回 nil。
    public func coordinate(column: Double, row: Double) -> GeoCoordinate? {
        let point = crsPoint(column: column, row: row)
        return Projection.toWGS84(x: point.x, y: point.y, crs: crs)
    }

    /// WGS84 → 像素坐标。
    public func pixel(for coordinate: GeoCoordinate) -> CGPoint? {
        guard let point = Projection.fromWGS84(coordinate, crs: crs) else { return nil }
        return pixelPoint(x: point.x, y: point.y)
    }

    /// 影像覆盖的归一化世界矩形（四角变换后取包围盒）。
    public func worldRect(pixelWidth: Int, pixelHeight: Int) -> CGRect {
        let corners = [
            (0.0, 0.0),
            (Double(pixelWidth), 0.0),
            (Double(pixelWidth), Double(pixelHeight)),
            (0.0, Double(pixelHeight)),
        ]
        var rect: CGRect?
        for (column, row) in corners {
            guard let coordinate = coordinate(column: column, row: row) else { continue }
            let point = WebMercator.normalized(coordinate)
            rect = rect.map { $0.union(CGRect(origin: point, size: .zero)) }
                ?? CGRect(origin: point, size: .zero)
        }
        return rect ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    }

    /// 归一化世界矩形 → 像素矩形（四角都换算一遍，取轴对齐包围盒）。
    ///
    /// 只回答「大概要哪些像素」，不管这些像素在屏幕上怎么摆：影像平面坐标与铺图网格之间
    /// 有旋转时，包围盒会把旋转吞掉。数值分析（视野 / 框选算坡度、两期影像求差）只要一个
    /// 够大的范围，因此用它；铺图不能用它，得用 `RasterTileSource.mapping(ofTileWorld:georeference:tileSize:)`，
    /// 否则相邻瓦片的接缝会错开几个像素。
    public func pixelRect(ofWorldRect rect: CGRect) -> CGRect? {
        let west = WebMercator.longitude(normalizedX: rect.minX)
        let east = WebMercator.longitude(normalizedX: rect.maxX)
        let north = WebMercator.latitude(normalizedY: rect.minY)
        let south = WebMercator.latitude(normalizedY: rect.maxY)
        let corners = [
            GeoCoordinate(longitude: west, latitude: north),
            GeoCoordinate(longitude: east, latitude: north),
            GeoCoordinate(longitude: east, latitude: south),
            GeoCoordinate(longitude: west, latitude: south),
        ]
        var box: CGRect?
        for corner in corners {
            guard let pixel = pixel(for: corner) else { return nil }
            box = box.map { $0.union(CGRect(origin: pixel, size: .zero)) }
                ?? CGRect(origin: pixel, size: .zero)
        }
        return box
    }

    /// 由 GeoTIFF 标签建地理参考。
    static func from(geo: TIFFGeoTags, pixelWidth: Int, pixelHeight: Int) -> RasterGeoreference {
        let crs = crsFromKeys(geo)
        // 优先用完整的仿射矩阵；否则用「像素尺度 + 定位点」。
        if let matrix = geo.transformation, matrix.count >= 8 {
            let reference = RasterGeoreference(
                placement: crs.isKnown ? .georeferenced : .unreferenced(reason: crs.displayName),
                crs: crs,
                originX: matrix[3],
                originY: matrix[7],
                pixelSizeX: matrix[0],
                pixelSizeY: matrix[5],
                rotationX: matrix[1],
                rotationY: matrix[4]
            )
            if crs.isKnown { return reference }
        }
        if let scale = geo.pixelScale, let tiePoints = geo.tiePoints, tiePoints.count >= 6 {
            let column = tiePoints[0], row = tiePoints[1]
            let x = tiePoints[3], y = tiePoints[4]
            let pixelSizeX = scale[0]
            let pixelSizeY = scale.count > 1 ? scale[1] : scale[0]
            // 定位点可能不落在 (0,0)，按它把原点推算回去。
            let reference = RasterGeoreference(
                placement: crs.isKnown ? .georeferenced : .unreferenced(reason: crs.displayName),
                crs: crs,
                originX: x - column * pixelSizeX,
                originY: y + row * pixelSizeY,
                pixelSizeX: pixelSizeX,
                pixelSizeY: -pixelSizeY,
                rotationX: 0,
                rotationY: 0
            )
            if crs.isKnown { return reference }
        }
        let reason = geo.isEmpty
            ? "文件里没有地理标签"
            : (crs.isKnown ? "文件里没有可用的定位信息" : crs.displayName)
        return .unreferenced(reason: reason, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// 从 GeoKeyDirectory 里认出投影与参数。
    static func crsFromKeys(_ geo: TIFFGeoTags) -> RasterCRS {
        guard let keys = geo.keyDirectory, keys.count >= 4 else { return .unknown(code: nil) }
        let count = Int(keys[3])
        var values: [Int: Int] = [:]
        for index in 0..<count {
            let base = 4 + index * 4
            guard base + 3 < keys.count else { break }
            values[Int(keys[base])] = Int(keys[base + 3])
        }
        let doubles = geo.doubleParameters ?? []
        func doubleValue(_ key: Int) -> Double? {
            guard let index = values[key], index >= 0, index < doubles.count else { return nil }
            return doubles[index]
        }
        let parameters = Projection.ProjectionParameters(
            centralMeridian: doubleValue(3080) ?? doubleValue(3084),
            latitudeOfOrigin: doubleValue(3081),
            scaleFactor: doubleValue(3092),
            falseEasting: doubleValue(3082),
            falseNorthing: doubleValue(3083),
            semiMajorAxis: doubleValue(3073),
            flattening: nil
        )
        return Projection.crs(
            modelType: values[1024],
            projectedCode: values[3072],
            geographicCode: values[2048],
            coordinateTransformation: values[3075],
            parameters: parameters
        )
    }
}

/// 单幅影像（GeoTIFF / TIFF，或 ImageIO 能读的普通图片）。
///
/// 与瓦片数据集并列：都是「一块有地理范围的影像」，只是瓦片数据集按 `<z>/<x>/<y>` 存，
/// 单幅影像是一张大图，取图时按需解出屏幕需要的那一块。
public struct RasterDataset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let georeference: RasterGeoreference
    public let worldRect: CGRect
    public let fileSizeBytes: Int
    public let compression: String
    public let bitsPerSample: Int
    public let hasAlpha: Bool
    public let hasOverviews: Bool
    public let tileSize: Int
    /// 屏幕渲染用的瓦片边长固定 512（与本地正射影像一致，Retina 上 1:1）。
    public var maximumDataZoom: Double
    public var zoomRange: ClosedRange<Int>
    public var extent: DatasetExtent

    public var isGeoreferenced: Bool { georeference.isGeoreferenced }
    public var crsName: String { georeference.crs.displayName }
    public var placementNote: String? {
        if case .unreferenced(let reason) = georeference.placement { return reason }
        return nil
    }

    public var pixelSizeText: String { "\(pixelWidth) × \(pixelHeight)" }

    public var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file)
    }

    /// 地面分辨率（米/像素）：用相邻两个像素的测地距离算，投影与经纬度都适用。
    public var groundSampleDistance: Double? {
        let centerColumn = Double(pixelWidth) / 2
        let centerRow = Double(pixelHeight) / 2
        guard let first = georeference.coordinate(column: centerColumn, row: centerRow),
              let second = georeference.coordinate(column: centerColumn + 10, row: centerRow) else {
            return nil
        }
        return Geodesy.distance(from: first, to: second) / 10
    }

    public var source: RasterTileSource {
        RasterTileSource(
            fileURL: fileURL,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            georeference: georeference,
            worldRect: worldRect,
            tileSize: tileSize
        )
    }

    /// 把整幅影像按目标尺寸采一张图（缩略图、体检核对用）。
    ///
    /// 走的是与取图完全相同的解码路径，只是区域取整幅；
    /// 有内建概览时用最合适的那一级，因此不必把大图整张解进内存。
    public func renderOverview(maxPixelSize: Int = 1024) -> CGImage? {
        RasterTileSource.renderFullImage(
            fileURL: fileURL,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            maxPixelSize: maxPixelSize
        )
    }
}

/// 打开单幅影像。
public enum RasterLoader {
    /// 读文件头 → 地理参考 → 覆盖范围。
    ///
    /// TIFF / GeoTIFF 走自带的解析（能拿到地理标签，超大文件也不用整张解码）；
    /// 其它格式（PNG / JPEG 等）用 `ImageIO` 读个尺寸，按未配准影像打开。
    public static func load(url: URL, tileSize: Int = 512) throws -> RasterDataset {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let fileSize = (attributes?[.size] as? Int) ?? 0
        let name = url.deletingPathExtension().lastPathComponent

        if let file = try? TIFFReader.parse(url: url) {
            return makeDataset(
                url: url,
                name: name,
                pixelWidth: file.pixelWidth,
                pixelHeight: file.pixelHeight,
                georeference: RasterGeoreference.from(
                    geo: file.geo,
                    pixelWidth: file.pixelWidth,
                    pixelHeight: file.pixelHeight
                ),
                fileSize: fileSize,
                compression: file.compressionDescription,
                bitsPerSample: file.bitsPerSample,
                hasAlpha: file.hasAlpha,
                hasOverviews: !file.overviews.isEmpty,
                tileSize: tileSize
            )
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw TIFFError.unsupported("读不出这个文件的图像尺寸（\(url.lastPathComponent)）")
        }
        return makeDataset(
            url: url,
            name: name,
            pixelWidth: width,
            pixelHeight: height,
            georeference: .unreferenced(reason: "不是 GeoTIFF（没有地理标签）", pixelWidth: width, pixelHeight: height),
            fileSize: fileSize,
            compression: "未压缩 / 位图",
            bitsPerSample: 8,
            hasAlpha: true,
            hasOverviews: false,
            tileSize: tileSize
        )
    }

    private static func makeDataset(
        url: URL,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        georeference: RasterGeoreference,
        fileSize: Int,
        compression: String,
        bitsPerSample: Int,
        hasAlpha: Bool,
        hasOverviews: Bool,
        tileSize: Int
    ) -> RasterDataset {
        let worldRect = georeference.worldRect(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        // 屏幕渲染用的虚拟金字塔：`maximumDataZoom` 就是「一个图像像素对一个设备像素」的那一级。
        let widthInWorld = max(worldRect.width, 1e-12)
        let nativeZoom = log2(Double(max(pixelWidth, pixelHeight)) / (widthInWorld * Double(tileSize)))
        let maximumDataZoom = min(max(0, nativeZoom), 30)
        let upper = min(30, max(0, Int(ceil(maximumDataZoom))))
        let extent = DatasetExtent(
            worldRect: worldRect,
            level: upper,
            tileCount: (pixelWidth + tileSize - 1) / tileSize * ((pixelHeight + tileSize - 1) / tileSize)
        )
        return RasterDataset(
            id: url.path(percentEncoded: false),
            name: name,
            fileURL: url,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            georeference: georeference,
            worldRect: worldRect,
            fileSizeBytes: fileSize,
            compression: compression,
            bitsPerSample: bitsPerSample,
            hasAlpha: hasAlpha,
            hasOverviews: hasOverviews,
            tileSize: max(64, tileSize),
            maximumDataZoom: maximumDataZoom,
            zoomRange: 0...upper,
            extent: extent
        )
    }
}

/// 一块瓦片的「画布像素 → 影像像素」映射（仿射）。
///
/// 为什么不能只用一个「像素矩形」：影像自己的平面坐标（UTM / 高斯克吕格 / 带旋转的仿射）
/// 与铺图用的 Web 墨卡托网格之间差着**子午线收敛角**，也就是说影像在屏幕上是斜的。
/// 把一块瓦片的四角换算成影像像素再取包围盒，等于把这点旋转丢掉：相邻两块瓦片各按各的
/// 包围盒拉伸，接缝两侧算出来的源像素差着「一块瓦片宽度 × tan(收敛角)」——千米级正射影像
/// 在 z21 上约 5.7 像素，肉眼看就是每 512 像素一跳的错位与重影。
///
/// 改用「三只角定一个仿射」之后，接缝两侧算出来的是同一条边界上的同一批像素：
/// 投影在单块瓦片尺度上的非线性远小于 0.01 像素，因此几何上是严丝合缝的。
struct RasterTileMapping: Sendable {
    /// 画布 (0, 0)（瓦片左上角）对应的影像像素坐标。
    var origin: CGPoint
    /// 画布列 +1 / 行 +1 对应的影像像素位移。
    var columnStep: CGVector
    var rowStep: CGVector

    /// 画布像素坐标（左上为原点、行向下）→ 影像像素坐标。
    func source(column: Double, row: Double) -> CGPoint {
        CGPoint(
            x: origin.x + column * columnStep.dx + row * rowStep.dx,
            y: origin.y + column * columnStep.dy + row * rowStep.dy
        )
    }

    /// 影像像素坐标 → 画布坐标；映射退化（行列共线）时返回 nil。
    func canvas(x: Double, y: Double) -> CGPoint? {
        let determinant = columnStep.dx * rowStep.dy - rowStep.dx * columnStep.dy
        guard abs(determinant) > 1e-12 else { return nil }
        let dx = x - origin.x
        let dy = y - origin.y
        return CGPoint(
            x: (dx * rowStep.dy - dy * rowStep.dx) / determinant,
            y: (dy * columnStep.dx - dx * columnStep.dy) / determinant
        )
    }

    /// 画布上一块区域对应的影像像素范围（四角包围盒，含旋转带来的外扩）。
    func sourceBoundingBox(ofCanvas rect: CGRect) -> CGRect {
        let corners = [
            source(column: rect.minX, row: rect.minY),
            source(column: rect.maxX, row: rect.minY),
            source(column: rect.maxX, row: rect.maxY),
            source(column: rect.minX, row: rect.maxY),
        ]
        var box = CGRect(origin: corners[0], size: .zero)
        for corner in corners.dropFirst() {
            box = box.union(CGRect(origin: corner, size: .zero))
        }
        return box
    }

    /// 影像像素矩形在画布上占的范围（四角包围盒，画布左上为原点、行向下）。
    func canvasBoundingBox(ofSource rect: CGRect) -> CGRect {
        let corners = [
            (rect.minX, rect.minY), (rect.maxX, rect.minY),
            (rect.maxX, rect.maxY), (rect.minX, rect.maxY),
        ].compactMap { canvas(x: $0.0, y: $0.1) }
        guard let first = corners.first else { return .null }
        var box = CGRect(origin: first, size: .zero)
        for corner in corners.dropFirst() {
            box = box.union(CGRect(origin: corner, size: .zero))
        }
        return box
    }

    /// 换算到「另一套像素」（另一级概览 / 另一张等比缩放的图）。
    func scaled(columnScale: Double, rowScale: Double) -> RasterTileMapping {
        RasterTileMapping(
            origin: CGPoint(x: origin.x * columnScale, y: origin.y * rowScale),
            columnStep: CGVector(
                dx: columnStep.dx * columnScale,
                dy: columnStep.dy * rowScale
            ),
            rowStep: CGVector(
                dx: rowStep.dx * columnScale,
                dy: rowStep.dy * rowScale
            )
        )
    }

    /// 一个画布像素覆盖多少影像像素（取样点个数按它定）。
    var sourcePixelsPerCanvasPixel: Double {
        max(hypot(columnStep.dx, columnStep.dy), hypot(rowStep.dx, rowStep.dy))
    }

    /// 把影像上的一块按这个映射画进瓦片画布。
    ///
    /// 交给 CoreGraphics 做旋转 / 缩放重采样：它按完整变换取像素并做过滤，
    /// 比「先裁包围盒再线性拉伸」正确，也比手写旋转重采样省事。
    /// 缓冲区仍是「首行在画面顶部」，与 `TIFFDecoder` 写出来的口径一致。
    func draw(piece: CGImage, pieceRect: CGRect, canvas: UnsafeMutablePointer<UInt8>, canvasSize: Int) -> Bool {
        guard canvasSize > 0 else { return false }
        let determinant = columnStep.dx * rowStep.dy - rowStep.dx * columnStep.dy
        guard abs(determinant) > 1e-12 else { return false }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: canvas,
                  width: canvasSize,
                  height: canvasSize,
                  bitsPerComponent: 8,
                  bytesPerRow: canvasSize * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        // 影像像素 → 画布（行向下）是上面映射的逆变换；再翻成 CGContext 的「y 向上」。
        let a = rowStep.dy / determinant
        let b = -rowStep.dx / determinant
        let c = -columnStep.dy / determinant
        let d = columnStep.dx / determinant
        let tx = -(a * origin.x + b * origin.y)
        // 画布行号（自上而下）换成 CGContext 的行号（自下而上）是 `canvasSize - row`，
        // 所以这里的常数项是 `canvasSize + (c * 原点.x + d * 原点.y)`：
        // 写成减号会把整幅影像推到画布外面（表现是整块瓦片空着）。
        let ty = Double(canvasSize) + (c * origin.x + d * origin.y)
        let transform = CGAffineTransform(a: a, b: -c, c: b, d: -d, tx: tx, ty: ty)
        context.interpolationQuality = .high
        context.concatenate(transform)
        // `CGContext.draw` 会把图像按「y 向上」摆进矩形，而这个映射的输入是
        // 「行自上而下」的影像像素坐标：先在自己的局部坐标里翻一次，两边才对得上
        // （少这一次翻转，整幅影像就会上下颠倒）。
        context.translateBy(x: 0, y: pieceRect.minY + pieceRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(piece, in: pieceRect)
        return true
    }
}

/// 单幅影像的取图来源：把瓦片请求换算成影像上的像素区域，按需解出来。
public struct RasterTileSource: TileImageSource {
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let georeference: RasterGeoreference
    public let worldRect: CGRect
    public let tileSize: Int

    public init(
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        georeference: RasterGeoreference,
        worldRect: CGRect,
        tileSize: Int
    ) {
        self.fileURL = fileURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.georeference = georeference
        self.worldRect = worldRect
        self.tileSize = max(64, tileSize)
    }

    public var availableZoomRange: ClosedRange<Int> { 0...30 }

    /// 这个来源不走「先拿字节再解码」那条路，见 `image(for:)`。
    public func data(for tile: SlippyTile) async -> Data? { nil }

    /// 解码一个瓦片：换算区域 → 选层级 → 采样到瓦片画布。
    public func image(for tile: SlippyTile) async -> CGImage? {
        guard let file = TIFFFileCache.shared.file(for: fileURL) else { return nil }
        let tileWorld = tile.worldRect
        guard tileWorld.intersects(worldRect) else { return nil }

        // 瓦片画布 → 影像像素的仿射（含影像平面坐标相对墨卡托的旋转，见 `RasterTileMapping`）。
        guard let mapping = Self.mapping(
            ofTileWorld: tileWorld,
            georeference: georeference,
            tileSize: Double(tileSize)
        ) else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight))
        // 这块瓦片要取样的影像像素范围：四角包围盒够用（只差旋转那点外扩，多取一点不影响）。
        let rawPixelRect = mapping.sourceBoundingBox(
            ofCanvas: CGRect(x: 0, y: 0, width: Double(tileSize), height: Double(tileSize))
        )
        let clipped = rawPixelRect.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 0.01, clipped.height >= 0.01,
              rawPixelRect.width > 0, rawPixelRect.height > 0 else { return nil }

        // 画布上真正要画的区域：影像里这一块换算回画布，再与瓦片画布求交
        // （影像只盖住瓦片一角时就只画那一角，其余留空）。
        let canvasBounds = CGRect(x: 0, y: 0, width: Double(tileSize), height: Double(tileSize))
        let destination = mapping.canvasBoundingBox(ofSource: clipped).integral.intersection(canvasBounds)
        guard !destination.isNull, destination.width >= 0.5, destination.height >= 0.5 else { return nil }

        // 没有内建概览的大图：先看持久化概览缓存有没有现成的，有就直接用它铺 ——
        // 比逐块解原图快一两个数量级（这正是「无概览大图」最卡的那条路）。
        if file.overviews.isEmpty {
            let sourcePixelsPerPoint = mapping.sourcePixelsPerCanvasPixel
            let overview = await RasterOverviewCache.shared.readyImage(fileURL: fileURL, tileSize: tileSize)
            if let overview, sourcePixelsPerPoint > 1.05 {
                let columnScale = Double(overview.width) / Double(max(1, pixelWidth))
                let rowScale = Double(overview.height) / Double(max(1, pixelHeight))
                // 概览的像素够用才拿它铺；不够就老实解原图（宁慢不错）。
                if columnScale > 0, rowScale > 0,
                   min(columnScale, rowScale) * sourcePixelsPerPoint >= 0.9,
                   let image = Self.renderTile(
                       from: overview,
                       mapping: mapping.scaled(columnScale: columnScale, rowScale: rowScale),
                       destination: destination,
                       tileSize: tileSize
                   ) {
                    return image
                }
            } else if overview == nil, RasterOverviewCache.qualifiesLargeImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
                // 还没做好：把生成任务排到后台，这一屏继续走原路（下次打开就是现成的了）。
                Self.scheduleOverviewGeneration(fileURL: fileURL, tileSize: tileSize)
            }
        }
        // 选层级：挑「刚好够这一屏分辨率」的最小一级（内建概览在这里发挥作用）。
        let level = Self.chooseLevel(for: rawPixelRect, in: file, pixelWidth: pixelWidth, tileSize: tileSize)
        let columnScale = Double(level.width) / Double(pixelWidth)
        let rowScale = Double(level.height) / Double(pixelHeight)
        guard level.width > 0, level.height > 0, columnScale > 0, rowScale > 0 else { return nil }
        let levelMapping = mapping.scaled(columnScale: columnScale, rowScale: rowScale)

        var canvas = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        if TileKitTrace.raster {
            let drawn = mapping.source(column: 0, row: 0)
            let across = mapping.source(column: Double(tileSize), row: 0)
            let down = mapping.source(column: 0, row: Double(tileSize))
            let line = String(
                format: "[raster] 瓦片 %@ 世界=(%.8f,%.8f) 影像世界=(%.8f,%.8f,%.2e,%.2e) "
                    + "像素矩形=(%.1f,%.1f,%.1f,%.1f) 层级=%d×%d "
                    + "左上=(%.1f,%.1f) 横向=(%.2f,%.2f) 纵向=(%.2f,%.2f)\n",
                tile.description,
                tileWorld.minX, tileWorld.minY,
                worldRect.minX, worldRect.minY, worldRect.width, worldRect.height,
                rawPixelRect.minX, rawPixelRect.minY, rawPixelRect.width, rawPixelRect.height,
                level.width, level.height,
                drawn.x, drawn.y,
                across.x - drawn.x, across.y - drawn.y,
                down.x - drawn.x, down.y - drawn.y
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
        let drawn: Bool = canvas.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            do {
                try TIFFDecoder.draw(
                    file: file,
                    level: level,
                    mapping: levelMapping,
                    canvas: base,
                    canvasWidth: tileSize,
                    canvasHeight: tileSize,
                    destination: destination
                )
                return true
            } catch {
                TIFFDiagnostics.record(error: error, tile: tile, file: fileURL)
                return false
            }
        }
        guard drawn else { return nil }
        return Self.makeImage(canvas: canvas, size: tileSize)
    }

    /// 瓦片的世界范围 → 影像像素矩形（四角都换算一遍，取包围盒，不能只看一个角）。
    ///
    /// 数值分析（差异叠加 / 坡度图）用它取「够大的范围」；
    /// 要摆到屏幕上的取图一律走 `mapping(ofTileWorld:georeference:tileSize:)`（见那边的说明）。
    static func pixelRect(ofTileWorld tileWorld: CGRect, georeference: RasterGeoreference) -> CGRect? {
        georeference.pixelRect(ofWorldRect: tileWorld)
    }

    /// 瓦片画布 → 影像像素的仿射映射（铺图与自检共用这一条口径）。
    ///
    /// 只取「左上、右上、左下」三只角：投影在单块瓦片这样的尺度上就是线性的
    /// （收敛角在一整块瓦片里的变化不到 0.03 像素），三只角足以定下来。
    static func mapping(
        ofTileWorld tileWorld: CGRect,
        georeference: RasterGeoreference,
        tileSize: Double
    ) -> RasterTileMapping? {
        guard tileSize > 0, tileWorld.width > 0, tileWorld.height > 0 else { return nil }
        let west = WebMercator.longitude(normalizedX: tileWorld.minX)
        let east = WebMercator.longitude(normalizedX: tileWorld.maxX)
        let north = WebMercator.latitude(normalizedY: tileWorld.minY)
        let south = WebMercator.latitude(normalizedY: tileWorld.maxY)
        // 注意：归一化墨卡托里 minY 在北、maxY 在南，画布行号也是自北向南增大，两者同向。
        guard let topLeft = georeference.pixel(for: GeoCoordinate(longitude: west, latitude: north)),
              let topRight = georeference.pixel(for: GeoCoordinate(longitude: east, latitude: north)),
              let bottomLeft = georeference.pixel(for: GeoCoordinate(longitude: west, latitude: south))
        else { return nil }
        return RasterTileMapping(
            origin: topLeft,
            columnStep: CGVector(
                dx: (topRight.x - topLeft.x) / tileSize,
                dy: (topRight.y - topLeft.y) / tileSize
            ),
            rowStep: CGVector(
                dx: (bottomLeft.x - topLeft.x) / tileSize,
                dy: (bottomLeft.y - topLeft.y) / tileSize
            )
        )
    }

    /// 瓦片上第 (列, 行) 个画布像素落在影像的哪个像素上（列、行，左上为原点、行向下）。
    ///
    /// 铺图、瓦片读数与自检共用这一条口径。不能只按「包围盒 + 线性拉伸」算：
    /// 影像的平面坐标（UTM / 高斯克吕格）与铺图用的墨卡托网格之间有子午线收敛角，
    /// 影像在屏幕上是斜的，按包围盒摊开会让每块瓦片的接缝错开几个像素。
    package static func pixelPoint(
        ofTileWorld tileWorld: CGRect,
        georeference: RasterGeoreference,
        tileSize: Double,
        column: Double,
        row: Double
    ) -> CGPoint? {
        guard let mapping = mapping(
            ofTileWorld: tileWorld,
            georeference: georeference,
            tileSize: tileSize
        ) else { return nil }
        return mapping.source(column: column, row: row)
    }

    /// 选一级：分辨率刚好不小于「瓦片要显示的像素数」的那一级。
    static func chooseLevel(
        for pixelRect: CGRect,
        in file: TIFFFile,
        pixelWidth: Int,
        tileSize: Int
    ) -> TIFFImageFileDirectory {
        let needed = max(pixelRect.width, pixelRect.height)
        for level in file.levels {
            let scale = Double(level.width) / Double(pixelWidth)
            if max(pixelRect.width, pixelRect.height) * scale >= Double(tileSize), level.width > 0 {
                _ = needed
                return level
            }
        }
        return file.main
    }

    /// 把整幅影像按目标尺寸采一张图（缩略图、持久化概览都走它）。
    ///
    /// 走的是与取图完全相同的解码路径，只是区域取整幅；有内建概览时用最合适的那一级，
    /// 因此不必把大图整张解进内存。
    static func renderFullImage(
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        maxPixelSize: Int
    ) -> CGImage? {
        guard maxPixelSize > 0, pixelWidth > 0, pixelHeight > 0,
              let file = TIFFFileCache.shared.file(for: fileURL) else { return nil }
        let scale = min(1, Double(maxPixelSize) / Double(max(pixelWidth, pixelHeight)))
        let width = max(1, Int((Double(pixelWidth) * scale).rounded()))
        let height = max(1, Int((Double(pixelHeight) * scale).rounded()))
        let level = chooseLevel(
            for: CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight)),
            in: file,
            pixelWidth: pixelWidth,
            tileSize: max(width, height)
        )
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        // 整幅铺进整块画布：映射就是「等比缩小」，没有瓦片与旋转的事。
        let mapping = RasterTileMapping(
            origin: .zero,
            columnStep: CGVector(dx: Double(level.width) / Double(width), dy: 0),
            rowStep: CGVector(dx: 0, dy: Double(level.height) / Double(height))
        )
        let drawn: Bool = canvas.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            do {
                try TIFFDecoder.draw(
                    file: file,
                    level: level,
                    mapping: mapping,
                    canvas: base,
                    canvasWidth: width,
                    canvasHeight: height,
                    destination: CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
                )
                return true
            } catch {
                TIFFDiagnostics.record(error: error, tile: SlippyTile(zoom: 0, x: 0, y: 0), file: fileURL)
                return false
            }
        }
        guard drawn else { return nil }
        return makeImage(canvas: canvas, width: width, height: height)
    }

    /// 用持久化概览小图铺一块瓦片（低层级看全貌用）。
    ///
    /// 概览是整幅影像的等比缩小，所以「影像像素」乘上概览比例就是概览上的位置；
    /// 与直接解原图那条路的结果在几何上完全一致（同一套映射），只是采样自一张小图。
    /// 旋转也一并交给 CoreGraphics：先只裁出要用的那一小块，再按映射铺满画布。
    static func renderTile(
        from overview: CGImage,
        mapping: RasterTileMapping,
        destination: CGRect,
        tileSize: Int
    ) -> CGImage? {
        guard tileSize > 0, destination.width >= 0.5, destination.height >= 0.5 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(overview.width), height: CGFloat(overview.height))
        // 多留 1 像素边：旋转 / 双线性插值会用到边界外侧的像素。
        let cropped = mapping.sourceBoundingBox(ofCanvas: destination)
            .integral
            .insetBy(dx: -1, dy: -1)
            .intersection(bounds)
        guard !cropped.isNull, cropped.width >= 1, cropped.height >= 1,
              let piece = overview.cropping(to: cropped) else { return nil }

        var canvas = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        let drawn: Bool = canvas.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return mapping.draw(piece: piece, pieceRect: cropped, canvas: base, canvasSize: tileSize)
        }
        guard drawn else { return nil }
        return makeImage(canvas: canvas, width: tileSize, height: tileSize)
    }

    /// 把「生成概览」排到后台（铺图时发现还没做好就走它）。
    static func scheduleOverviewGeneration(fileURL: URL, tileSize: Int) {
        Task {
            await RasterOverviewCache.shared.scheduleGeneration(fileURL: fileURL, tileSize: tileSize) {
                guard let file = TIFFFileCache.shared.file(for: fileURL) else { return nil }
                return renderFullImage(
                    fileURL: fileURL,
                    pixelWidth: file.pixelWidth,
                    pixelHeight: file.pixelHeight,
                    maxPixelSize: RasterOverviewCache.maximumPixelSize
                )
            }
        }
    }

    /// RGBA8 缓冲区 → CGImage。
    static func makeImage(canvas: [UInt8], size: Int) -> CGImage? {
        makeImage(canvas: canvas, width: size, height: size)
    }

    /// RGBA8 缓冲区 → CGImage（可非正方形）。
    static func makeImage(canvas: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, canvas.count >= width * height * 4 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // 交给 Data 支撑的 provider：CGImage 会自己持有这份像素数据。
        // 不能把「只在 withUnsafeBytes 闭包里有效的指针」交出去 ——
        // 闭包一返回那块内存就可能被复用，图会时好时坏（读到已释放的内存）。
        let data = Data(canvas) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// 解析结果缓存：IFD 结构不变，同一份文件不必每块瓦片都重新解析一遍。
///
/// 只缓存目录结构（几 KB 的元数据），像素数据一律现解现用，
/// 因此缓存大小与影像有多大无关。
final class TIFFFileCache: @unchecked Sendable {
    static let shared = TIFFFileCache()

    /// 一份文件的「时间戳 + 大小」，用来发现文件被外部换掉了。
    private struct Stamp: Equatable {
        var modifiedAt: Date?
        var size: Int
    }

    private struct Entry {
        var file: TIFFFile
        var stamp: Stamp
    }

    private let lock = NSLock()
    private var files: [String: Entry] = [:]
    private var order: [String] = []
    private let limit = 4
    /// 检查文件是否被改过的最短间隔：每块瓦片都 stat 一次太浪费，一秒一次足够。
    private var lastStampCheck = Date.distantPast
    private let stampCheckInterval: TimeInterval = 1

    func file(for url: URL) -> TIFFFile? {
        let key = url.path(percentEncoded: false)
        let now = Date()

        lock.lock()
        // `lastStampCheck` 也在这个锁里 —— 它是个可变状态，多个解码线程同时进来时
        // 在锁外读写就是数据竞争（`Date` 不是原子的）。
        let shouldCheckStamp = now.timeIntervalSince(lastStampCheck) >= stampCheckInterval
        if shouldCheckStamp { lastStampCheck = now }
        let known = files[key]
        lock.unlock()

        if let known {
            // 没到该检查的间隔就直接用解析结果；到了就 stat 一次看看文件是不是被换过
            //（stat 放在锁外做，别让磁盘 IO 占着这份表的锁）。
            guard shouldCheckStamp else { return known.file }
            let stamp = Self.stamp(of: url)
            if known.stamp == stamp { return known.file }
            // 文件被换掉了：结构要重解析，已经解出来的块也不能再用（尺寸 / 分块都可能变了）。
            lock.lock()
            if files[key]?.stamp == known.stamp {
                files.removeValue(forKey: key)
                order.removeAll { $0 == key }
            }
            lock.unlock()
            TIFFChunkCache.shared.invalidate(path: key)
        }

        guard let parsed = try? TIFFReader.parse(url: url) else { return nil }
        let entry = Entry(file: parsed, stamp: Self.stamp(of: url))
        lock.lock()
        if files[key] == nil {
            files[key] = entry
            order.append(key)
            while order.count > limit {
                files.removeValue(forKey: order.removeFirst())
            }
        }
        lock.unlock()
        return parsed
    }

    /// 丢弃某个文件的解析结果（文件被外部改动后用）。
    func invalidate(_ url: URL) {
        let key = url.path(percentEncoded: false)
        lock.lock()
        files.removeValue(forKey: key)
        order.removeAll { $0 == key }
        lock.unlock()
        TIFFChunkCache.shared.invalidate(path: key)
    }

    private static func stamp(of url: URL) -> Stamp {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modifiedAt: values?.contentModificationDate, size: values?.fileSize ?? -1)
    }
}

/// 解码出错时的提示（同一类错误只报一次，别在日志里刷屏）。
enum TIFFDiagnostics {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var reported = Set<String>()

        func insertIfNew(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return reported.insert(key).inserted
        }
    }

    private static let store = Store()

    static func record(error: Error, tile: SlippyTile, file: URL) {
        let key = "\(file.lastPathComponent):\(error)"
        guard store.insertIfNew(key) else { return }
        FileHandle.standardError.write(Data(
            "[tiff] \(file.lastPathComponent) 瓦片 \(tile)：\(error)\n".utf8
        ))
    }

    /// 记一条「不致命但值得知道」的情况（例如某个块解出来比声明的短，只能补零）。
    ///
    /// 这类问题以前是完全静默的：画面上只是那一块发黑，没人知道为什么。
    static func record(message: String, file: URL) {
        let key = "\(file.lastPathComponent):\(message)"
        guard store.insertIfNew(key) else { return }
        FileHandle.standardError.write(Data(
            "[tiff] \(file.lastPathComponent)：\(message)\n".utf8
        ))
    }
}
