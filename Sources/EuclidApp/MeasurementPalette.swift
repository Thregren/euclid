import AppKit
import TileKit

/// 多条测量线的配色。
///
/// 调色板只决定「默认颜色」；一旦用户在检查器里指定了颜色，
/// 测量上会保存固定的 sRGB 分量（`MeasurementStyle`），不再跟随外观切换。
enum MeasurementPalette {
    static let colors: [NSColor] = [
        .systemBlue,
        .systemOrange,
        .systemGreen,
        .systemPurple,
        .systemPink,
        .systemTeal,
        .systemRed,
        .systemIndigo,
    ]

    static var count: Int { colors.count }

    static func color(at index: Int) -> NSColor {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    // MARK: - 样式解析

    /// 描边颜色：用户指定过就用指定的，否则回落到调色板。
    static func strokeColor(of measurement: GeoMeasurement) -> NSColor {
        measurement.style.stroke.map(NSColor.init(components:)) ?? color(at: measurement.colorIndex)
    }

    /// 基础填充颜色（不含透明度）。
    static func fillColor(of measurement: GeoMeasurement) -> NSColor {
        measurement.style.fill.map(NSColor.init(components:)) ?? color(at: measurement.colorIndex)
    }

    /// 实际用于绘制的填充色（填充色 × 填充不透明度）。
    static func resolvedFillColor(of measurement: GeoMeasurement) -> NSColor {
        fillColor(of: measurement).withAlphaComponent(fillOpacity(of: measurement))
    }

    static func fillOpacity(of measurement: GeoMeasurement) -> CGFloat {
        let style = measurement.style.sanitized()
        return CGFloat(style.fillOpacity)
    }

    static func lineWidth(of measurement: GeoMeasurement) -> CGFloat {
        CGFloat(measurement.style.sanitized().strokeWidth)
    }

    /// 草稿（尚未完成的测量）使用的颜色。
    static func draftStrokeColor(at index: Int, style: MeasurementStyle) -> NSColor {
        style.stroke.map(NSColor.init(components:)) ?? color(at: index)
    }

    static func draftFillColor(at index: Int, style: MeasurementStyle) -> NSColor {
        let base = style.fill.map(NSColor.init(components:)) ?? color(at: index)
        return base.withAlphaComponent(CGFloat(style.sanitized().fillOpacity))
    }
}

extension NSColor {
    /// 从核心库保存的分量还原颜色。
    convenience init(components: ColorComponents) {
        self.init(
            srgbRed: CGFloat(min(max(components.red, 0), 1)),
            green: CGFloat(min(max(components.green, 0), 1)),
            blue: CGFloat(min(max(components.blue, 0), 1)),
            alpha: CGFloat(min(max(components.alpha, 0), 1))
        )
    }

    /// 转成核心库可保存的分量（统一切到 sRGB 空间）。
    var colorComponents: ColorComponents {
        let converted = usingColorSpace(.sRGB) ?? .white
        return ColorComponents(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
    }
}
