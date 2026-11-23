import CoreGraphics
import Foundation
import ImageIO

/// 单幅影像的地理参考：像素坐标 ↔ 影像坐标 ↔ WGS84。
///
/// 变换是仿射的：
/// `x = originX + 列 * pixelSizeX + 行 * rotationX`
/// `y = originY + 列 * rotationY + 行 * pixelSizeY`
/// 北朝上的正射影像里 `pixelSizeY` 为负（行号向南增大）。
public struct RasterGeoreference: Hashable, Sendable, Codable {
    /// 摆放方式。
    public enum Placement: Hashable, Sendable, Codable {
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
