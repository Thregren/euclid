import Foundation

/// 与 UI 框架无关的 sRGB 颜色分量（各分量 `0…1`）。
///
/// 核心库不认识 AppKit，因此颜色以分量形式随测量一起保存，
/// 由应用层负责在 `NSColor` 之间转换。
public struct ColorComponents: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 只替换不透明度。
    public func withAlpha(_ alpha: Double) -> ColorComponents {
        ColorComponents(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 一条测量的显示样式。
///
/// 颜色是可选的「覆盖值」：`nil` 表示继续使用调色板颜色，
/// 这样默认配色仍然跟随深浅色外观切换；一旦用户指定颜色，
/// 就固定为 sRGB 分量，不再随外观变化。
public struct MeasurementStyle: Sendable, Hashable, Codable {
    /// 描边颜色覆盖；`nil` 表示使用调色板颜色。
    public var stroke: ColorComponents?
    /// 填充颜色覆盖；`nil` 表示使用调色板颜色。
    public var fill: ColorComponents?
    /// 填充的不透明度（`0…1`），多边形与圆使用。
    public var fillOpacity: Double
    /// 描边宽度（视图点）。
    public var strokeWidth: Double

    public init(
        stroke: ColorComponents? = nil,
        fill: ColorComponents? = nil,
        fillOpacity: Double = MeasurementStyle.defaultFillOpacity,
        strokeWidth: Double = MeasurementStyle.defaultStrokeWidth
    ) {
        self.stroke = stroke
        self.fill = fill
        self.fillOpacity = fillOpacity
        self.strokeWidth = strokeWidth
    }

    public static let defaultFillOpacity = 0.16
    public static let defaultStrokeWidth = 2.0

    /// 出厂样式：颜色跟随调色板。
    public static let standard = MeasurementStyle()

    /// 用户是否指定过颜色。
    public var hasCustomColors: Bool { stroke != nil || fill != nil }

    /// 填充透明度是否偏离默认值。
    public var hasCustomFill: Bool {
        hasCustomColors || abs(fillOpacity - Self.defaultFillOpacity) > 0.0001
    }

    /// 限制到合法范围，避免脏数据把图层画坏。
    public func sanitized() -> MeasurementStyle {
        var style = self
        style.fillOpacity = min(max(fillOpacity, 0), 1)
        style.strokeWidth = min(max(strokeWidth, 0.5), 12)
        return style
    }

    private enum CodingKeys: String, CodingKey {
        case stroke
        case fill
        case fillOpacity
        case strokeWidth
    }

    /// 手工解码，保证旧存档缺字段时也能读出来。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stroke = try container.decodeIfPresent(ColorComponents.self, forKey: .stroke)
        fill = try container.decodeIfPresent(ColorComponents.self, forKey: .fill)
        fillOpacity = try container.decodeIfPresent(Double.self, forKey: .fillOpacity)
            ?? MeasurementStyle.defaultFillOpacity
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth)
            ?? MeasurementStyle.defaultStrokeWidth
    }
}
