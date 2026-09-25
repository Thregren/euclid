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
        guard maxPixelSize > 0,
              let file = TIFFFileCache.shared.file(for: fileURL),
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / Double(max(pixelWidth, pixelHeight)))
        let width = max(1, Int((Double(pixelWidth) * scale).rounded()))
        let height = max(1, Int((Double(pixelHeight) * scale).rounded()))
        let level = RasterTileSource.chooseLevel(
            for: CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight)),
            in: file,
            pixelWidth: pixelWidth,
            tileSize: max(width, height)
        )
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = canvas.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            do {
                try TIFFDecoder.draw(
                    file: file,
                    level: level,
                    source: CGRect(
                        x: 0,
                        y: 0,
                        width: Double(level.width),
                        height: Double(level.height)
                    ),
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
        return RasterTileSource.makeImage(canvas: canvas, width: width, height: height)
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

        // 瓦片的世界范围 → 影像坐标矩形 → 像素矩形。
        let west = WebMercator.longitude(normalizedX: tileWorld.minX)
        let east = WebMercator.longitude(normalizedX: tileWorld.maxX)
        let north = WebMercator.latitude(normalizedY: tileWorld.minY)
        let south = WebMercator.latitude(normalizedY: tileWorld.maxY)
        let corners = [
            GeoCoordinate(longitude: west, latitude: north),
            GeoCoordinate(longitude: east, latitude: north),
            GeoCoordinate(longitude: east, latitude: south),
            GeoCoordinate(longitude: west, latitude: south),
        ]
        var pixelRect: CGRect?
        for corner in corners {
            guard let pixel = georeference.pixel(for: corner) else { return nil }
            pixelRect = pixelRect.map { $0.union(CGRect(origin: pixel, size: .zero)) }
                ?? CGRect(origin: pixel, size: .zero)
        }
        guard let rawPixelRect = pixelRect else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight))
        let clipped = rawPixelRect.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 0.01, clipped.height >= 0.01,
              rawPixelRect.width > 0, rawPixelRect.height > 0 else { return nil }

        // 目标：把 `rawPixelRect` 铺满整块瓦片，其中真正有内容的那部分是 `clipped`。
        let scaleX = Double(tileSize) / rawPixelRect.width
        let scaleY = Double(tileSize) / rawPixelRect.height
        let destination = CGRect(
            x: (clipped.minX - rawPixelRect.minX) * scaleX,
            y: (clipped.minY - rawPixelRect.minY) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        )

        // 选层级：挑「刚好够这一屏分辨率」的最小一级（内建概览在这里发挥作用）。
        let level = Self.chooseLevel(for: rawPixelRect, in: file, pixelWidth: pixelWidth, tileSize: tileSize)
        let levelScale = Double(level.width) / Double(pixelWidth)
        guard level.width > 0, level.height > 0, levelScale > 0 else { return nil }
        let source = CGRect(
            x: clipped.minX * levelScale,
            y: clipped.minY * levelScale,
            width: max(1, clipped.width * levelScale),
            height: max(1, clipped.height * levelScale)
        )

        var canvas = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        if ProcessInfo.processInfo.environment["EUCLID_RASTER_TRACE"] != nil {
            let line = String(
                format: "[raster] 瓦片 %@ 世界=(%.8f,%.8f) 影像世界=(%.8f,%.8f,%.2e,%.2e) "
                    + "像素矩形=(%.1f,%.1f,%.1f,%.1f) 层级=%d×%d 源=(%.1f,%.1f,%.1f,%.1f)\n",
                tile.description,
                tileWorld.minX, tileWorld.minY,
                worldRect.minX, worldRect.minY, worldRect.width, worldRect.height,
                rawPixelRect.minX, rawPixelRect.minY, rawPixelRect.width, rawPixelRect.height,
                level.width, level.height,
                source.minX, source.minY, source.width, source.height
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
        let drawn: Bool = canvas.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            do {
                try TIFFDecoder.draw(
                    file: file,
                    level: level,
                    source: source,
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
    private let lock = NSLock()
    private var files: [String: TIFFFile] = [:]
    private var order: [String] = []
    private let limit = 4

    func file(for url: URL) -> TIFFFile? {
        let key = url.path(percentEncoded: false)
        lock.lock()
        if let cached = files[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let file = try? TIFFReader.parse(url: url) else { return nil }
        lock.lock()
        if files[key] == nil {
            files[key] = file
            order.append(key)
            while order.count > limit {
                files.removeValue(forKey: order.removeFirst())
            }
        }
        lock.unlock()
        return file
    }

    /// 丢弃某个文件的解析结果（文件被外部改动后用）。
    func invalidate(_ url: URL) {
        let key = url.path(percentEncoded: false)
        lock.lock()
        files.removeValue(forKey: key)
        order.removeAll { $0 == key }
        lock.unlock()
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
}
