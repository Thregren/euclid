import AppKit
import SwiftUI

/// 界面层的统一约定。
///
/// 这里的取值都对着 HIG 的基础层：字号用系统语义样式（跟随系统文本大小），
/// 控制层用材质而非硬编码颜色，动效尊重「减少动态效果」。
enum InterfaceStyle {
    /// 浮在内容之上的控制层圆角，与系统控件的圆角观感一致。
    static let controlCornerRadius: CGFloat = 10
    /// 控件最小点击高度（macOS 指针输入下仍保证可点）。
    static let controlHeight: CGFloat = 24

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
}
