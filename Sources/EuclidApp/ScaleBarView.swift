import SwiftUI

/// 地图比例尺。
struct ScaleBarView: View {
    let metersPerPoint: Double

    var body: some View {
        let barWidth = width
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
            HStack(spacing: 0) {
                Rectangle()
                    .frame(width: 1.5, height: 8)
                Rectangle()
                    .frame(width: barWidth, height: 1.5)
                Rectangle()
                    .frame(width: 1.5, height: 8)
            }
            .foregroundStyle(.primary.opacity(0.8))
        }
        .opacity(metersPerPoint > 0 ? 1 : 0)
    }

    private var target: Double { metersPerPoint * 110 }

    private var niceValue: Double {
        guard target > 0 else { return 1 }
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
        return multiplier * base
    }

    private var width: Double {
        guard metersPerPoint > 0 else { return 60 }
        return max(36, min(180, niceValue / metersPerPoint))
    }

    private var label: String {
        let value = niceValue
        if value >= 1000 {
            let kilometers = value / 1000
            return kilometers == kilometers.rounded()
                ? String(format: "%.0f km", kilometers)
                : String(format: "%.1f km", kilometers)
        }
        return String(format: "%.0f m", value)
    }
}
