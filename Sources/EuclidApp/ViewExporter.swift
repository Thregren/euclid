import AppKit
import CoreGraphics
import Foundation
import ImageIO
import TileKit

/// 把画布出成一张可以直接贴进报告或聊天窗口的图片。
///
/// 画布本身只知道自己那点内容（瓦片、网格、测量标注），
/// 「这是什么数据、中心在哪、多大比例」这些信息只有 `AppModel` 知道，
/// 因此这里负责把两者拼起来：上面是画面，下面一条信息栏（数据源、中心坐标、层级、比例尺）。
@MainActor
enum ViewExporter {
    /// 信息栏要用的元数据。
    struct Info {
        /// 数据源名（本地数据集或在线底图）。
        var title: String
        /// 叠加提示，例如「叠加在线底图 · © OpenStreetMap contributors」。
        var subtitle: String?
        /// 视图中心坐标。
        var center: GeoCoordinate
        /// 当前整数层级。
        var zoom: Int
        /// 一个视图点对应的实地米数（比例尺用）。
        var metersPerPoint: Double
        /// 画面里有几条测量（写进信息栏，便于核对图与数据对不对得上）。
        var measurementCount: Int
    }

    /// 信息栏高度（点）。
    private static let footerHeight: CGFloat = 46

    /// 合成最终图片：`map` 是画布渲染出来的位图（已按设备像素比出图）。
    static func compose(map: CGImage, scale: CGFloat, info: Info) -> CGImage? {
        let mapWidth = CGFloat(map.width)
        let mapHeight = CGFloat(map.height)
        let footer = footerHeight * scale
        let width = Int(mapWidth.rounded())
        let height = Int((mapHeight + footer).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }

        // 位图上下文原点是左下角：信息栏画在底部，画面占上方。
        context.draw(map, in: CGRect(x: 0, y: footer, width: mapWidth, height: mapHeight))
        drawFooter(in: context, size: CGSize(width: mapWidth, height: footer), scale: scale, info: info)
        return context.makeImage()
    }

    /// 导出成 PNG 数据。
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - 信息栏

    private static func drawFooter(in context: CGContext, size: CGSize, scale: CGFloat, info: Info) {
        // 白底 + 一条分隔线：深浅色两种外观下都清楚，贴在报告里也不突兀。
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor.separatorColor.cgColor)
        context.fill(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let inset = 14 * scale

        // 左上：数据源与叠加信息。
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingMiddle
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: info.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13 * scale, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: titleStyle,
            ]
        ))
        var meta: [String] = []
        if let subtitle = info.subtitle, !subtitle.isEmpty { meta.append(subtitle) }
        if info.measurementCount > 0 { meta.append("测量 \(info.measurementCount) 条") }
        if !meta.isEmpty {
            title.append(NSAttributedString(
                string: "　" + meta.joined(separator: " · "),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11 * scale),
                    .foregroundColor: NSColor.darkGray,
                ]
            ))
        }
        title.draw(
            // 右边留出比例尺的位置（最长 180 点 + 边距），数据源名很长时也不会压到比例尺上。
            in: CGRect(x: inset, y: 26 * scale, width: size.width - inset * 2 - 210 * scale, height: 18 * scale)
        )

        // 左下：中心坐标。
        let coordinate = String(
            format: "中心 %.6f, %.6f · z%d",
            info.center.longitude, info.center.latitude, info.zoom
        )
        (coordinate as NSString).draw(
            at: CGPoint(x: inset, y: 9 * scale),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5 * scale, weight: .regular),
                .foregroundColor: NSColor.darkGray,
            ]
        )

        drawScaleBar(in: context, size: size, scale: scale, metersPerPoint: info.metersPerPoint)
    }

    /// 右下角的比例尺：与屏幕上那条用同一份刻度算法（`ScaleBarMetric`）。
    private static func drawScaleBar(in context: CGContext, size: CGSize, scale: CGFloat, metersPerPoint: Double) {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return }
        let metric = ScaleBarMetric.value(metersPerPoint: metersPerPoint)
        let barWidth = CGFloat(metric.width) * scale
        let right = size.width - 14 * scale
        let y = 15 * scale

        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1.6 * scale)
        context.beginPath()
        context.move(to: CGPoint(x: right - barWidth, y: y))
        context.addLine(to: CGPoint(x: right, y: y))
        // 两端的小竖线，视觉上与屏幕上的比例尺一致。
        context.move(to: CGPoint(x: right - barWidth, y: y - 4 * scale))
        context.addLine(to: CGPoint(x: right - barWidth, y: y + 4 * scale))
        context.move(to: CGPoint(x: right, y: y - 4 * scale))
        context.addLine(to: CGPoint(x: right, y: y + 4 * scale))
        context.strokePath()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11 * scale, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let label = metric.label as NSString
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(
                x: right - barWidth / 2 - labelSize.width / 2,
                y: y + 6 * scale
            ),
            withAttributes: attributes
        )
    }
}
