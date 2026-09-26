import SwiftUI

/// 面板（sheet）里的统一分区容器。
///
/// 下载 / 生成瓦片 / 本地服务三个面板原先各写了一份「GroupBox + 标题样式」，
/// 字号与内边距各不相同；这里收敛成一处，后面加面板直接复用。
/// 分组框用系统的 `GroupBox`：深浅色、增强对比度、降低透明度都交给系统。
func sheetSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    GroupBox {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    } label: {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }
}

/// 面板里字段名：右对齐、固定宽度，让右边的控件竖向对齐成一列。
struct SheetFieldLabel: View {
    private let text: String
    private let width: CGFloat

    init(_ text: String, width: CGFloat = 58) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }
}
