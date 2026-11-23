import AppKit
import SwiftUI

/// 画布顶部的标签栏：同时开着的几份数据在这里切换。
///
/// 只读 `AppModel.workspaceTabs` 与一个「当前页」id，点一下就走
/// `activateWorkspaceTab` —— 由模型显示选中的页面。
struct WorkspaceTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.workspaceTabs) { tab in
                        chip(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            Button {
                model.addWorkspaceTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("新建标签页（⌘T）")
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == model.activeWorkspaceTabID
        return HStack(spacing: 6) {
            Text(tab.displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if isActive, model.workspaceTabs.count > 1 {
                Button {
                    model.closeWorkspaceTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("关闭这个标签页")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: 220)
        .background(
            isActive ? Color.primary.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.primary.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.activateWorkspaceTab(tab.id) }
        .contextMenu {
            Button("重命名…") { rename(tab) }
            Button("关闭标签页") { model.closeWorkspaceTab(tab.id) }
                .disabled(model.workspaceTabs.count <= 1 && tab.id == model.activeWorkspaceTabID)
        }
        .help(tab.displayName)
        .accessibilityLabel("标签页 \(tab.displayName)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// 重命名：与书签同一套做法，用带输入框的小 `NSAlert`，不顶掉画布布局。
    private func rename(_ tab: WorkspaceTab) {
        let alert = NSAlert()
        alert.messageText = "重命名标签页"
        alert.informativeText = "留空则恢复成自动标题。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.customName ?? tab.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.renameWorkspaceTab(tab.id, to: field.stringValue)
    }
}
