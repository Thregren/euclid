import AppKit
import SwiftUI

/// 界面层的统一约定。
///
/// 这里的取值都对着 HIG 的基础层：字号用系统语义样式（跟随系统文本大小），
/// 控制层用材质而非硬编码颜色，动效尊重「减少动态效果」。
enum InterfaceStyle {
    /// 浮在内容之上的控制层圆角，与系统控件的圆角观感一致。
    static let controlCornerRadius: CGFloat = 10
    /// 浮层面板（图层 / 检查器 / 工具条）的圆角：比控制层更大一圈。
    static let panelCornerRadius: CGFloat = 12
    /// 左侧「图层」面板的宽度。
    ///
    /// 252 点：缩略图、13 点的名称、11 点的来源说明、不透明度与勾选框排下来刚好都放得下
    /// （11 点下副标题需要约 90 点宽，窄了就会把「512px」这类信息截掉）。
    static let layersPanelWidth: CGFloat = 252
    /// 右侧检查器面板的宽度。
    static let inspectorPanelWidth: CGFloat = 292
    /// 最右侧工具条的宽度。
    static let toolStripWidth: CGFloat = 46
    /// 控件最小点击高度（macOS 指针输入下仍保证可点）。
    ///
    /// HIG 对按钮给的通行要求是点击区域至少 44×44 点（任何输入方式都适用）；
    /// macOS 上系统控件的实际高度在 20–28 点之间，画布上的浮层控件再撑到 44 会明显失衡，
    /// 因此取 26 点高（比系统默认控件还大一点），并由外层留白补足可点范围。
    static let controlHeight: CGFloat = 26
    /// 只画一个图标的按钮（勾选框、标题行的 ＋ / ⧉ / ⋯）的可点边长。
    ///
    /// 图标本身 13–14 点就够看，但点击区域按 HIG 的取向放大到 24 点，
    /// 免得「看得见却点不着」。
    static let iconButtonHitSize: CGFloat = 24

    /// 「减少动态效果」是否开启：开启后不做淡入淡出等装饰性动画。
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension View {
    /// 控制层外观（标准圆角矩形）。
    @ViewBuilder
    func controlSurface(cornerRadius: CGFloat = InterfaceStyle.controlCornerRadius) -> some View {
        controlSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// 控制层外观：macOS 26 起用 Liquid Glass（控制层浮在内容层之上），
    /// 更早的系统退回标准材质加一道描边，视觉层级保持一致。
    @ViewBuilder
    func controlSurface<S: InsettableShape>(shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    /// 浮层面板外观：玻璃（或材质）底 + 一道描边 + 一层投影。
    ///
    /// 投影按深浅色分开取：深色下黑色投影不压住底下的画布就看不出来，
    /// 浅色下同样的量又会显脏，两边各取一个刚好把面板从画布上「抬起来」的值。
    func panelSurface(cornerRadius: CGFloat = InterfaceStyle.panelCornerRadius) -> some View {
        modifier(PanelSurface(cornerRadius: cornerRadius))
    }
}

/// 浮层面板：材质 + 描边 + 投影。
///
/// 面板用比小控件更「实」的一档材质（而不是 Liquid Glass）：它是一整块面积压在影像上，
/// 玻璃太透，底下的白影像会把面板整体提亮，字反而不好认；厚材质既能透出一点底，
/// 又保证文字对比度与 Pixelmator 那种面板色调接近。
private struct PanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                // 材质负责透出底下的影像，再压一层与窗口同色的半透明底：
                // 影像很亮时（正射影像常常整片白）玻璃会把面板整体提亮，字就压不住了。
                shape
                    .fill(.thickMaterial)
                    .overlay {
                        shape.fill(
                            Color(nsColor: .windowBackgroundColor)
                                .opacity(colorScheme == .dark ? 0.55 : 0.35)
                        )
                    }
            }
            .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16),
                radius: 12,
                y: 4
            )
    }
}

extension NSColor {
    /// 在指定外观下解析语义色。
    ///
    /// `NSColor.cgColor` 只认「当前绘制外观」（`NSAppearance.current`），在绘制上下文之外
    /// 一律按系统外观取色。而 CALayer 的颜色必须在设置的那一刻就定下来，
    /// 于是强制深色（或应用自己声明深色）时，画布底色与网格线仍是浅色的一套。
    /// 凡是要写进 CALayer 的语义色，都得先经过这里。
    func resolvedCGColor(in appearance: NSAppearance) -> CGColor {
        let color = self
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
