import SwiftUI

/// 比例尺的刻度选取。
///
/// 屏幕上的浮动比例尺与导出图片里的比例尺共用这一份：只有一处算法，
/// 图上的线长与标注就不会跟界面上看到的不一致。
enum ScaleBarMetric {
    struct Value {
        /// 取整后的实地距离（米）。
        var meters: Double
        /// 展示文本，例如 `500 m` / `2 km`。
        var label: String
        /// 该距离在屏幕上占多少点。
        var width: Double
    }

    /// - Parameter targetWidth: 期望的线长（点），用来反推该取哪个整数刻度。
    static func value(metersPerPoint: Double, targetWidth: Double = 110) -> Value {
        guard metersPerPoint > 0, metersPerPoint.isFinite else {
            return Value(meters: 1, label: "1 m", width: 60)
        }
        let target = metersPerPoint * targetWidth
        let exponent = floor(log10(target))
        let base = pow(10, exponent)
        let normalized = target / base
        let multiplier: Double
        switch normalized {
        case ..<1.5: multiplier = 1
        case ..<3.5: multiplier = 2
        case ..<7.5: multiplier = 5
        default: multiplier = 10
        }
        let meters = multiplier * base
        return Value(
            meters: meters,
            label: label(for: meters),
            width: max(36, min(180, meters / metersPerPoint))
        )
    }

    static func label(for meters: Double) -> String {
        guard meters >= 1000 else { return String(format: "%.0f m", meters) }
        let kilometers = meters / 1000
        return kilometers == kilometers.rounded()
            ? String(format: "%.0f km", kilometers)
            : String(format: "%.1f km", kilometers)
    }
}

/// 地图比例尺。
struct ScaleBarView: View {
    let metersPerPoint: Double

    var body: some View {
        let metric = ScaleBarMetric.value(metersPerPoint: metersPerPoint)
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.label)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
            HStack(spacing: 0) {
                Rectangle()
                    .frame(width: 1.5, height: 8)
                Rectangle()
                    .frame(width: metric.width, height: 1.5)
                Rectangle()
                    .frame(width: 1.5, height: 8)
            }
            .foregroundStyle(.primary.opacity(0.8))
        }
        .opacity(metersPerPoint > 0 ? 1 : 0)
    }
}
