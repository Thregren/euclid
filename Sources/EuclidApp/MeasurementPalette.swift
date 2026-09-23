import AppKit

/// 多条测量线的配色。
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
}
