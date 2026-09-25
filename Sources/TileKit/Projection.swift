import CoreGraphics
import Foundation

/// 单幅影像所在的坐标参照系。
///
/// 只做「把文件里的平面坐标换算成 WGS84 经纬度」这一件事，
/// 覆盖国内正射影像几乎全部的实际来源：经纬度（WGS84 / CGCS2000）、
/// Web 墨卡托、UTM，以及 CGCS2000 的高斯克吕格分带。
public enum RasterCRS: Hashable, Sendable {
    /// 经纬度十进制度。
    case geographic
    /// EPSG:3857 及其别名。
    case webMercator
    /// 横轴墨卡托（UTM、高斯克吕格、自定义 TM）。
    case transverseMercator(TransverseMercator)
    /// 认不出来的投影：给了代码也只能按未配准处理（宁可说不知道，也不要摆错位置）。
    case unknown(code: Int?)

    public var displayName: String {
        switch self {
        case .geographic:
            return "经纬度（WGS84 / CGCS2000）"
        case .webMercator:
            return "Web 墨卡托（EPSG:3857）"
        case .transverseMercator(let parameters):
            return parameters.displayName
        case .unknown(let code):
            if let code { return "未识别的投影（EPSG:\(code)）" }
            return "未识别的投影"
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// 横轴墨卡托参数。
public struct TransverseMercator: Hashable, Sendable {
    public var name: String
    public var epsg: Int?
    /// 中央经线（度）。
    public var centralMeridian: Double
    public var latitudeOfOrigin: Double
    public var scaleFactor: Double
    public var falseEasting: Double
    public var falseNorthing: Double
    public var semiMajorAxis: Double
    public var flattening: Double

    public init(
        name: String,
        epsg: Int? = nil,
        centralMeridian: Double,
        latitudeOfOrigin: Double = 0,
        scaleFactor: Double = 1,
        falseEasting: Double = 0,
        falseNorthing: Double = 0,
        semiMajorAxis: Double = Projection.wgs84SemiMajorAxis,
        flattening: Double = Projection.wgs84Flattening
    ) {
        self.name = name
        self.epsg = epsg
        self.centralMeridian = centralMeridian
        self.latitudeOfOrigin = latitudeOfOrigin
        self.scaleFactor = scaleFactor
        self.falseEasting = falseEasting
        self.falseNorthing = falseNorthing
        self.semiMajorAxis = semiMajorAxis
        self.flattening = flattening
    }

    public var displayName: String {
        epsg.map { "\(name)（EPSG:\($0)）" } ?? name
    }

    /// 由 EPSG 代码建参数。认得出来的才返回，否则交给调用方按「未知」处理。
    public static func fromEPSG(_ code: Int) -> TransverseMercator? {
        let wgs = (Projection.wgs84SemiMajorAxis, Projection.wgs84Flattening)
        let krasovsky = (6_378_245.0, 1 / 298.3)
        let iag75 = (6_378_140.0, 1 / 298.257_222_101)

        switch code {
        case 32601...32660:
            let zone = code - 32600
            return TransverseMercator(
                name: "UTM \(zone)N", epsg: code,
                centralMeridian: Double(zone) * 6 - 183,
                scaleFactor: 0.9996,
                falseEasting: 500_000,
                falseNorthing: 0,
                semiMajorAxis: wgs.0, flattening: wgs.1
            )
        case 32701...32760:
            let zone = code - 32700
            return TransverseMercator(
                name: "UTM \(zone)S", epsg: code,
                centralMeridian: Double(zone) * 6 - 183,
                scaleFactor: 0.9996,
                falseEasting: 500_000,
                falseNorthing: 10_000_000,
                semiMajorAxis: wgs.0, flattening: wgs.1
            )
        case 4534...4554:
            // CGCS2000 / 3 度带，中央经线 75E–135E，不带带号前缀。
            let meridian = 75 + Double(code - 4534) * 3
            return TransverseMercator(
                name: "CGCS2000 3 度带 CM \(Int(meridian))E", epsg: code,
                centralMeridian: meridian,
                falseEasting: 500_000,
                semiMajorAxis: wgs.0, flattening: wgs.1
            )
        case 4513...4533:
            // CGCS2000 / 3 度带，带号写在东坐标前面。
            let zone = 25 + code - 4513
            return TransverseMercator(
                name: "CGCS2000 3 度带 \(zone) 带", epsg: code,
                centralMeridian: Double(zone) * 3,
                falseEasting: Double(zone) * 1_000_000 + 500_000,
                semiMajorAxis: wgs.0, flattening: wgs.1
            )
        case 4491...4501:
            // CGCS2000 / 6 度带，带号写在东坐标前面。
            let zone = 13 + code - 4491
            return TransverseMercator(
                name: "CGCS2000 6 度带 \(zone) 带", epsg: code,
                centralMeridian: Double(zone) * 6 - 183,
                falseEasting: Double(zone) * 1_000_000 + 500_000,
                semiMajorAxis: wgs.0, flattening: wgs.1
            )
        case 4502...4512:
            let meridian = 75 + Double(code - 4502) * 6
            return TransverseMercator(
                name: "CGCS2000 6 度带 CM \(Int(meridian))E", epsg: code,
                centralMeridian: meridian,
                falseEasting: 500_000,
                semiMajorAxis: wgs.0, flattening: wgs.1
            )
        case 2327...2337:
            // 西安 80 / 6 度带（带号前缀）。
            let zone = 13 + code - 2327
            return TransverseMercator(
                name: "西安 80 6 度带 \(zone) 带", epsg: code,
                centralMeridian: Double(zone) * 6 - 183,
                falseEasting: Double(zone) * 1_000_000 + 500_000,
                semiMajorAxis: iag75.0, flattening: iag75.1
            )
        case 21413...21423:
            // 北京 54 / 6 度带（带号前缀）。
            let zone = 13 + code - 21413
            return TransverseMercator(
                name: "北京 54 6 度带 \(zone) 带", epsg: code,
                centralMeridian: Double(zone) * 6 - 183,
                falseEasting: Double(zone) * 1_000_000 + 500_000,
                semiMajorAxis: krasovsky.0, flattening: krasovsky.1
            )
        default:
            return nil
        }
    }
}

/// 坐标换算：影像平面坐标 ↔ WGS84 经纬度。
public enum Projection {
    public static let wgs84SemiMajorAxis = 6_378_137.0
    public static let wgs84Flattening = 1 / 298.257_223_563
    public static let earthRadius = 6_378_137.0
    public static let earthCircumference = 2 * Double.pi * earthRadius

    /// 影像平面坐标 → WGS84 经纬度；认不出投影时返回 nil。
    public static func toWGS84(x: Double, y: Double, crs: RasterCRS) -> GeoCoordinate? {
        switch crs {
        case .geographic:
            return GeoCoordinate(longitude: x, latitude: y)
        case .webMercator:
            let longitude = x / earthRadius * 180 / .pi
            let latitude = (2 * atan(exp(y / earthRadius)) - .pi / 2) * 180 / .pi
            return GeoCoordinate(longitude: longitude, latitude: latitude)
        case .transverseMercator(let parameters):
            return inverseTransverseMercator(x: x, y: y, parameters: parameters)
        case .unknown:
            return nil
        }
    }

    /// WGS84 经纬度 → 影像平面坐标；认不出投影时返回 nil。
    public static func fromWGS84(_ coordinate: GeoCoordinate, crs: RasterCRS) -> CGPoint? {
        switch crs {
        case .geographic:
            return CGPoint(x: coordinate.longitude, y: coordinate.latitude)
        case .webMercator:
            let x = coordinate.longitude * .pi / 180 * earthRadius
            let clamped = min(max(coordinate.latitude, -WebMercator.maxLatitude), WebMercator.maxLatitude)
            let y = log(tan(.pi / 4 + clamped * .pi / 360)) * earthRadius
            return CGPoint(x: x, y: y)
        case .transverseMercator(let parameters):
            return forwardTransverseMercator(coordinate, parameters: parameters)
        case .unknown:
            return nil
        }
    }

    /// 由 GeoTIFF 的 GeoKey 认投影。
    ///
    /// - Parameters:
    ///   - modelType: GeoKey 1024（1 = 投影坐标，2 = 地理坐标，3 = 地心坐标）
    ///   - projectedCode: GeoKey 3072
    ///   - geographicCode: GeoKey 2048
    ///   - coordinateTransformation: GeoKey 3075（1 = 横轴墨卡托）
    ///   - parameters: GeoKey 3076 之外的投影参数（来自 GeoDoubleParams）
    public static func crs(
        modelType: Int?,
        projectedCode: Int?,
        geographicCode: Int?,
        coordinateTransformation: Int?,
        parameters: ProjectionParameters
    ) -> RasterCRS {
        if let projectedCode, projectedCode != 32767 {
            if [3857, 3785, 900913, 102100, 102113, 3587].contains(projectedCode) {
                return .webMercator
            }
            if let tm = TransverseMercator.fromEPSG(projectedCode) { return .transverseMercator(tm) }
        }
        if let geographicCode, geographicCode != 32767 {
            if [4326, 4490, 4214, 4610, 4283, 4979, 4737, 4673].contains(geographicCode) {
                return .geographic
            }
            return .unknown(code: geographicCode)
        }
        // 没有 EPSG 代码：若是带参数的横轴墨卡托，也能算。
        if modelType == 1, coordinateTransformation == 1, let centralMeridian = parameters.centralMeridian {
            return .transverseMercator(TransverseMercator(
                name: "横轴墨卡托（文件内定义）",
                centralMeridian: centralMeridian,
                latitudeOfOrigin: parameters.latitudeOfOrigin ?? 0,
                scaleFactor: parameters.scaleFactor ?? 1,
                falseEasting: parameters.falseEasting ?? 0,
                falseNorthing: parameters.falseNorthing ?? 0,
                semiMajorAxis: parameters.semiMajorAxis ?? wgs84SemiMajorAxis,
                flattening: parameters.flattening ?? wgs84Flattening
            ))
        }
        if modelType == 2 { return .geographic }
        return .unknown(code: projectedCode)
    }

    /// 文件里自带的投影参数（GeoKey 3076 之后的那些值）。
    public struct ProjectionParameters: Hashable, Sendable {
        public var centralMeridian: Double?
        public var latitudeOfOrigin: Double?
        public var scaleFactor: Double?
        public var falseEasting: Double?
        public var falseNorthing: Double?
        public var semiMajorAxis: Double?
        public var flattening: Double?

        public init(
            centralMeridian: Double? = nil,
            latitudeOfOrigin: Double? = nil,
            scaleFactor: Double? = nil,
            falseEasting: Double? = nil,
            falseNorthing: Double? = nil,
            semiMajorAxis: Double? = nil,
            flattening: Double? = nil
        ) {
            self.centralMeridian = centralMeridian
            self.latitudeOfOrigin = latitudeOfOrigin
            self.scaleFactor = scaleFactor
            self.falseEasting = falseEasting
            self.falseNorthing = falseNorthing
            self.semiMajorAxis = semiMajorAxis
            self.flattening = flattening
        }
    }

    // MARK: - 横轴墨卡托

    /// 反算（Snyder 的级数展开，带内精度约毫米级）。
    static func inverseTransverseMercator(
        x: Double,
        y: Double,
        parameters: TransverseMercator
    ) -> GeoCoordinate {
        let a = parameters.semiMajorAxis
        let f = parameters.flattening
        let e2 = f * (2 - f)
        let ePrimeSquared = e2 / (1 - e2)
        let k0 = parameters.scaleFactor

        let m = (y - parameters.falseNorthing) / k0
        let mu = m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256))
        let e1 = (1 - (1 - e2).squareRoot()) / (1 + (1 - e2).squareRoot())

        let phi1 = mu
            + (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
            + (21 * e1 * e1 / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
            + (151 * pow(e1, 3) / 96) * sin(6 * mu)
            + (1097 * pow(e1, 4) / 512) * sin(8 * mu)

        let sinPhi1 = sin(phi1), cosPhi1 = cos(phi1), tanPhi1 = tan(phi1)
        let c1 = ePrimeSquared * cosPhi1 * cosPhi1
        let t1 = tanPhi1 * tanPhi1
        let n1 = a / (1 - e2 * sinPhi1 * sinPhi1).squareRoot()
        let r1 = a * (1 - e2) / pow(1 - e2 * sinPhi1 * sinPhi1, 1.5)
        let d = (x - parameters.falseEasting) / (n1 * k0)

        let latitude = phi1 - (n1 * tanPhi1 / r1) * (
            d * d / 2
                - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ePrimeSquared) * pow(d, 4) / 24
                + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ePrimeSquared - 3 * c1 * c1) * pow(d, 6) / 720
        )
        let longitude = parameters.centralMeridian * .pi / 180 + (
            d
                - (1 + 2 * t1 + c1) * pow(d, 3) / 6
                + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ePrimeSquared + 24 * t1 * t1) * pow(d, 5) / 120
        ) / cosPhi1

        if ProcessInfo.processInfo.environment["EUCLID_TM_TRACE"] != nil {
            let term3 = -(1 + 2 * t1 + c1) * pow(d, 3) / 6
            let term5 = (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ePrimeSquared + 24 * t1 * t1) * pow(d, 5) / 120
            let line = String(format: "[tm] e2=%.12f ep2=%.12f phi1=%.12f c1=%.12f t1=%.12f d=%.12f\n",
                              e2, ePrimeSquared, phi1, c1, t1, d)
                + String(format: "[tm] term3=%.12e term5=%.12e lat=%.12f lon=%.12f\n",
                         term3, term5, latitude * 180 / .pi, longitude * 180 / .pi)
            FileHandle.standardError.write(Data(line.utf8))
        }

        return GeoCoordinate(longitude: longitude * 180 / .pi, latitude: latitude * 180 / .pi)
    }

    /// 正算。
    static func forwardTransverseMercator(
        _ coordinate: GeoCoordinate,
        parameters: TransverseMercator
    ) -> CGPoint {
        let a = parameters.semiMajorAxis
        let f = parameters.flattening
        let e2 = f * (2 - f)
        let ePrimeSquared = e2 / (1 - e2)
        let k0 = parameters.scaleFactor

        let phi = coordinate.latitude * .pi / 180
        let lambda = coordinate.longitude * .pi / 180
        let lambda0 = parameters.centralMeridian * .pi / 180
        let phi0 = parameters.latitudeOfOrigin * .pi / 180

        let sinPhi = sin(phi), cosPhi = cos(phi), tanPhi = tan(phi)
        let n = a / (1 - e2 * sinPhi * sinPhi).squareRoot()
        let t = tanPhi * tanPhi
        let c = ePrimeSquared * cosPhi * cosPhi
        let aTerm = (lambda - lambda0) * cosPhi

        func meridianArc(_ latitude: Double) -> Double {
            a * (
                (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256) * latitude
                    - (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * e2 * e2 * e2 / 1024) * sin(2 * latitude)
                    + (15 * e2 * e2 / 256 + 45 * e2 * e2 * e2 / 1024) * sin(4 * latitude)
                    - (35 * e2 * e2 * e2 / 3072) * sin(6 * latitude)
            )
        }
        let m = meridianArc(phi)
        let m0 = meridianArc(phi0)

        let x = k0 * n * (
            aTerm
                + (1 - t + c) * pow(aTerm, 3) / 6
                + (5 - 18 * t + t * t + 72 * c - 58 * ePrimeSquared) * pow(aTerm, 5) / 120
        ) + parameters.falseEasting
        let y = k0 * (
            m - m0
                + n * tanPhi * (
                    aTerm * aTerm / 2
                        + (5 - t + 9 * c + 4 * c * c) * pow(aTerm, 4) / 24
                        + (61 - 58 * t + t * t + 600 * c - 330 * ePrimeSquared) * pow(aTerm, 6) / 720
                )
        ) + parameters.falseNorthing
        return CGPoint(x: x, y: y)
    }
}
