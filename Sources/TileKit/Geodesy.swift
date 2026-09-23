import Foundation

/// WGS84 椭球上的测地计算。
public enum Geodesy {
    public static let semiMajorAxis = 6_378_137.0
    public static let flattening = 1.0 / 298.257_223_563
    /// 与椭球面积相等的球半径，用于面积计算。
    public static let authalicRadius = 6_371_007.181

    /// 两点间的测地线结果。
    public struct InverseResult: Sendable, Hashable {
        /// 椭球面距离（米）。
        public var distance: Double
        /// 起点处方位角（度，0 为正北，顺时针）。
        public var initialBearing: Double
        /// 终点处方位角（度）。
        public var finalBearing: Double
        /// Vincenty 是否收敛；不收敛时使用球面近似。
        public var converged: Bool
    }

    /// Vincenty 反向公式：给定两点求距离与方位角。
    public static func inverse(from start: GeoCoordinate, to end: GeoCoordinate) -> InverseResult {
        let a = semiMajorAxis
        let b = a * (1 - flattening)
        let phi1 = start.latitude * .pi / 180
        let phi2 = end.latitude * .pi / 180
        let L = (end.longitude - start.longitude) * .pi / 180

        if phi1 == phi2 && L == 0 {
            return InverseResult(distance: 0, initialBearing: 0, finalBearing: 0, converged: true)
        }

        let u1 = atan((1 - flattening) * tan(phi1))
        let u2 = atan((1 - flattening) * tan(phi2))
        let sinU1 = sin(u1), cosU1 = cos(u1)
        let sinU2 = sin(u2), cosU2 = cos(u2)

        var lambda = L
        var lambdaPrevious = 0.0
        var sinSigma = 0.0
        var cosSigma = 0.0
        var sigma = 0.0
        var sinAlpha = 0.0
        var cosSquaredAlpha = 0.0
        var cos2SigmaM = 0.0
        var converged = false

        for _ in 0..<200 {
            let sinLambda = sin(lambda), cosLambda = cos(lambda)
            let t1 = cosU2 * sinLambda
            let t2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
            sinSigma = (t1 * t1 + t2 * t2).squareRoot()
            if sinSigma == 0 {
                return InverseResult(distance: 0, initialBearing: 0, finalBearing: 0, converged: true)
            }
            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
            cosSquaredAlpha = max(0, 1 - sinAlpha * sinAlpha)
            cos2SigmaM = cosSquaredAlpha == 0 ? 0 : cosSigma - 2 * sinU1 * sinU2 / cosSquaredAlpha
            let c = flattening / 16 * cosSquaredAlpha * (4 + flattening * (4 - 3 * cosSquaredAlpha))
            lambdaPrevious = lambda
            lambda = L + (1 - c) * flattening * sinAlpha
                * (sigma + c * sinSigma
                    * (cos2SigmaM + c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
            if abs(lambda - lambdaPrevious) <= 1e-12 {
                converged = true
                break
            }
        }

        if !converged {
            // 近对跖点等情形 Vincenty 不收敛，退回球面近似。
            let centralAngle = acos(min(1, max(-1,
                sin(phi1) * sin(phi2) + cos(phi1) * cos(phi2) * cos(L)
            )))
            let distance = authalicRadius * centralAngle
            let bearing = bearingOnSphere(from: start, to: end)
            return InverseResult(distance: distance, initialBearing: bearing, finalBearing: bearing, converged: false)
        }

        let uSquared = cosSquaredAlpha * (a * a - b * b) / (b * b)
        let bigA = 1 + uSquared / 16384 * (4096 + uSquared * (-768 + uSquared * (320 - 175 * uSquared)))
        let bigB = uSquared / 1024 * (256 + uSquared * (-128 + uSquared * (74 - 47 * uSquared)))
        let deltaSigma = bigB * sinSigma
            * (cos2SigmaM + bigB / 4
                * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
                    - bigB / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma)
                    * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
        let distance = b * bigA * (sigma - deltaSigma)

        let initialBearing = atan2(cosU2 * sin(lambda), cosU1 * sinU2 - sinU1 * cosU2 * cos(lambda)) * 180 / .pi
        let finalBearing = atan2(cosU1 * sin(lambda), -sinU1 * cosU2 + cosU1 * sinU2 * cos(lambda)) * 180 / .pi

        return InverseResult(
            distance: distance,
            initialBearing: normalizedDegrees(initialBearing),
            finalBearing: normalizedDegrees(finalBearing),
            converged: true
        )
    }

    public static func distance(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        inverse(from: start, to: end).distance
    }

    /// 球面方位角，作为不收敛时的近似。
    private static func bearingOnSphere(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        let phi1 = start.latitude * .pi / 180
        let phi2 = end.latitude * .pi / 180
        let deltaLambda = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        return normalizedDegrees(atan2(y, x) * 180 / .pi)
    }

    /// 闭合环的测地面积（平方米，取绝对值为正）。
    public static func area(of ring: [GeoCoordinate]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for index in ring.indices {
            let current = ring[index]
            let next = ring[(index + 1) % ring.count]
            let deltaLambda = (next.longitude - current.longitude) * .pi / 180
            let phi1 = current.latitude * .pi / 180
            let phi2 = next.latitude * .pi / 180
            sum += deltaLambda * (sin(phi1) + sin(phi2))
        }
        return abs(sum) * authalicRadius * authalicRadius / 2
    }

    public static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }
}

/// 测量结果的显示格式。
public enum MeasureFormat {
    /// 距离：小于 1 公里用米，否则用公里。
    public static func distance(_ meters: Double) -> String {
        let magnitude = abs(meters)
        if magnitude >= 1000 {
            let kilometers = meters / 1000
            return kilometers >= 100
                ? String(format: "%.0f km", kilometers)
                : String(format: "%.3f km", kilometers)
        }
        if magnitude >= 100 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.2f m", meters)
    }

    /// 面积：按数量级选择平方米、公顷、平方公里。
    public static func area(_ squareMeters: Double) -> String {
        let magnitude = abs(squareMeters)
        if magnitude >= 1_000_000 {
            return String(format: "%.2f km²", squareMeters / 1_000_000)
        }
        if magnitude >= 10_000 {
            return String(format: "%.2f 公顷", squareMeters / 10_000)
        }
        return String(format: "%.1f m²", squareMeters)
    }

    /// 方位角：度分。
    public static func bearing(_ degrees: Double) -> String {
        let value = Geodesy.normalizedDegrees(degrees)
        let wholeDegrees = floor(value)
        let minutes = (value - wholeDegrees) * 60
        return String(format: "%.0f°%02.0f′", wholeDegrees, minutes)
    }

    /// 方位角的中文方位描述。
    public static func compass(_ degrees: Double) -> String {
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let value = Geodesy.normalizedDegrees(degrees)
        let index = Int(((value + 22.5) / 45).rounded(.down)) % 8
        return directions[index]
    }
}
