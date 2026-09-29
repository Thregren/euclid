import CoreGraphics
import CoreText
import Foundation
import ImageIO
import TileKit

/// 把画布快照出成一张可以直接贴进报告或聊天窗口的图片。
///
/// 画布本身只知道自己那点内容（瓦片、测量标注），「这是什么数据、中心在哪、多大比例」
/// 只有 `AppModel` 知道，因此这里负责把两者拼起来：上面是画面，下面一条信息栏。
///
/// **线程约定**：整个类型都不依赖主线程 —— 颜色、字体、排版全部走 CoreGraphics /
/// CoreText（都可在后台线程安全使用），因此调用方可以把「光栅化 + 合成 + 编码」
/// 整段丢进 `Task.detached`。旧实现用 `NSColor` / `NSFont` / `NSString.draw`
/// 画信息栏，只能留在主线程上做，一屏 Retina 图要让界面停几十到上百毫秒。
enum ViewExporter {
    /// 信息栏要用的元数据。
    struct Info: Sendable {
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
    /// 信息栏配色：固定浅色，贴进文档里不挑主题（与画布本身的外观无关）。
    private static let footerPaper = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let footerSeparator = CGColor(srgbRed: 0.78, green: 0.78, blue: 0.78, alpha: 1)
    private static let footerInk = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let footerQuietInk = CGColor(srgbRed: 0.32, green: 0.32, blue: 0.32, alpha: 1)

    /// 「快照 → 位图 → PNG」一条龙（后台线程可调）。
    nonisolated static func pngData(_ snapshot: MapRenderSnapshot, info: Info) -> Data? {
        guard let image = image(snapshot: snapshot, info: info) else { return nil }
        return pngData(image)
    }

    /// 快照 + 信息栏 → 一张位图（后台线程可调）。
    nonisolated static func image(snapshot: MapRenderSnapshot, info: Info) -> CGImage? {
        guard let map = snapshot.makeImage() else { return nil }
        return compose(map: map, scale: snapshot.scale, info: info)
    }

    /// 合成最终图片：`map` 是画布渲染出来的位图（已按设备像素比出图）。
    nonisolated static func compose(map: CGImage, scale: CGFloat, info: Info) -> CGImage? {
        let mapWidth = CGFloat(map.width)
        let mapHeight = CGFloat(map.height)
        let footer = footerHeight * scale
        let width = Int(mapWidth.rounded())
        let height = Int((mapHeight + footer).rounded())
        guard width > 0, height > 0, footer > 0,
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
    ///
    /// `nonisolated`：纯 ImageIO 编码，一屏 Retina 图要几十毫秒，
    /// 调用方会把它丢到后台任务里做。
    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 导出成 PDF（后台线程可调）。
    ///
    /// 画面本身仍是位图（瓦片本来就是栅格），但**信息栏、标题、中心坐标与比例尺是矢量**：
    /// 打印或放进 PDF 报告里放大不会糊，文字还能被检索、复制。
    nonisolated static func pdfData(_ snapshot: MapRenderSnapshot, info: Info) -> Data? {
        let size = snapshot.size
        guard size.width > 1, size.height > 1 else { return nil }
        let footer = footerHeight
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: size.width, height: size.height + footer)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        if let map = snapshot.makeImage() {
            // PDF 上下文原点在左下：信息栏占底部一条，画面在上方。
            context.draw(map, in: CGRect(x: 0, y: footer, width: size.width, height: size.height))
        }
        drawFooter(in: context, size: CGSize(width: size.width, height: footer), scale: 1, info: info)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - 信息栏

    private static func drawFooter(in context: CGContext, size: CGSize, scale: CGFloat, info: Info) {
        // 白底 + 一条分隔线：深浅色两种外观下都清楚，贴在报告里也不突兀。
        context.setFillColor(footerPaper)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(footerSeparator)
        context.fill(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1))

        let inset = 14 * scale
        let top = size.height
        let titleBaseline = top - 8 * scale

        // 左上：数据源与叠加信息（右边给比例尺留出位置，长名字也不会压上去）。
        let titleFont = systemFont(size: 13 * scale, bold: true)
        let metaFont = systemFont(size: 11 * scale)
        let titleWidth = max(40 * scale, size.width - inset * 2 - 210 * scale)
        let metaLine = footerMetaText(info).map {
            attributedLine($0, font: metaFont, color: footerQuietInk)
        }
        let metaWidth = metaLine.map(lineWidth) ?? 0
        let titleLine = truncatingMiddle(
            info.title,
            font: titleFont,
            color: footerInk,
            maxWidth: max(20 * scale, titleWidth - metaWidth)
        )
        draw(titleLine, at: CGPoint(x: inset, y: titleBaseline - CTFontGetAscent(titleFont)), in: context)
        if let metaLine {
            draw(
                metaLine,
                at: CGPoint(x: inset + lineWidth(titleLine), y: titleBaseline - CTFontGetAscent(metaFont)),
                in: context
            )
        }

        // 左下：中心坐标（等宽数字，几行对齐着看很舒服）。
        let coordinateFont = monospacedDigitFont(size: 10.5 * scale)
        let coordinate = String(
            format: "中心 %.6f, %.6f · z%d",
            info.center.longitude, info.center.latitude, info.zoom
        )
        draw(
            attributedLine(coordinate, font: coordinateFont, color: footerQuietInk),
            at: CGPoint(x: inset, y: 9 * scale + CTFontGetDescent(coordinateFont)),
            in: context
        )

        drawScaleBar(in: context, size: size, scale: scale, metersPerPoint: info.metersPerPoint)
    }

    /// 信息栏中间那一小段附带说明：叠加了哪张底图、量了几条。
    private static func footerMetaText(_ info: Info) -> String? {
        var meta: [String] = []
        if let subtitle = info.subtitle, !subtitle.isEmpty { meta.append(subtitle) }
        if info.measurementCount > 0 { meta.append("测量 \(info.measurementCount) 条") }
        guard !meta.isEmpty else { return nil }
        return "　" + meta.joined(separator: " · ")
    }

    /// 右下角的比例尺：与屏幕上那条用同一份刻度算法（`ScaleBarMetric`）。
    private static func drawScaleBar(
        in context: CGContext,
        size: CGSize,
        scale: CGFloat,
        metersPerPoint: Double
    ) {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return }
        let metric = ScaleBarMetric.value(metersPerPoint: metersPerPoint)
        let barWidth = CGFloat(metric.width) * scale
        let right = size.width - 14 * scale
        let y = 15 * scale

        context.setStrokeColor(footerInk)
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

        let font = systemFont(size: 11 * scale, bold: true)
        let line = attributedLine(metric.label, font: font, color: footerInk)
        draw(
            line,
            at: CGPoint(x: right - barWidth / 2 - lineWidth(line) / 2, y: y + 6 * scale + CTFontGetDescent(font)),
            in: context
        )
    }

    // MARK: - 文字（CoreText）

    private static func attributedLine(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            ]
        )
    }

    private static func draw(_ line: NSAttributedString, at origin: CGPoint, in context: CGContext) {
        guard line.length > 0 else { return }
        context.textPosition = origin
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
    }

    private static func lineWidth(_ line: NSAttributedString) -> CGFloat {
        guard line.length > 0 else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(line), nil, nil, nil))
    }

    /// 太长的标题从中间截断（保留头尾两端，中间换省略号）—— 数据集名字往往前一段是地名、
    /// 后一段是日期，掐掉中间最不心疼。
    private static func truncatingMiddle(
        _ text: String,
        font: CTFont,
        color: CGColor,
        maxWidth: CGFloat
    ) -> NSAttributedString {
        let full = attributedLine(text, font: font, color: color)
        guard lineWidth(full) > maxWidth else { return full }
        var characters = Array(text)
        while characters.count > 2 {
            // 一次砍一个字符（标题最长几十个字，够快且不会算错字形宽度）。
            characters.remove(at: characters.count / 2)
            let head = characters.count / 2
            let candidate = attributedLine(
                String(characters[..<head]) + "…" + String(characters[head...]),
                font: font,
                color: color
            )
            if lineWidth(candidate) <= maxWidth { return candidate }
        }
        return attributedLine("…", font: font, color: color)
    }

    /// 系统字体（`CTFontCreateUIFontForLanguage`）；取不到时退回 Helvetica，不至于没字可画。
    private static func systemFont(size: CGFloat, bold: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard bold, let bolded = CTFontCreateCopyWithSymbolicTraits(
            base, size, nil, .boldTrait, .boldTrait
        ) else { return base }
        return bolded
    }

    /// 等宽数字的系统字体：坐标那一行的数字不会因为换数字而左右跳。
    private static func monospacedDigitFont(size: CGFloat) -> CTFont {
        let base = systemFont(size: size)
        let features: [[CFString: Any]] = [[
            kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
            kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
        ]]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
