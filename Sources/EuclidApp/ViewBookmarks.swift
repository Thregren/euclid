import AppKit
import Foundation
import Observation
import SwiftUI
import TileKit

/// 检查器里的「书签视点」小节：记当前视图、一键跳回、批量出巡检图集。
struct BookmarkSection: View {
    @Environment(AppModel.self) private var model
    /// 只显示前这么多条（和测量列表同一套做法：面板不为了几百条书签去撑长）。
    private static let visibleLimit = 12
    @State private var showsAll = false

    var body: some View {
        let bookmarks = model.bookmarks.items
        Section {
            HStack(spacing: 8) {
                Button {
                    model.addBookmark()
                } label: {
                    ShortcutButtonLabel(title: "记下当前视图", symbol: "bookmark", shortcut: "⌘⇧B")
                }
                .help("把当前的视点（中心 + 层级）记下来，之后可以一键跳回")
                Spacer()
                Button {
                    model.exportInspectionAtlas()
                } label: {
                    ShortcutButtonLabel(title: "导出巡检图集", symbol: "square.grid.2x2", shortcut: "⌘⌥A")
                }
                .disabled(bookmarks.isEmpty && model.measurements.measurements.isEmpty)
                .help("把每个书签（以及每条测量）各出一张图，连同索引页写进一个目录")
            }
            .controlSize(.small)

            if bookmarks.isEmpty {
                Text("还没有书签。把视图挪到要反复回看的位置，按 ⌘⇧B 记下来。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let visible = showsAll ? bookmarks : Array(bookmarks.suffix(Self.visibleLimit))
                ForEach(visible) { bookmark in
                    row(bookmark)
                }
                if bookmarks.count > Self.visibleLimit {
                    Button(showsAll
                           ? "只显示最近 \(Self.visibleLimit) 条"
                           : "显示其余 \(bookmarks.count - Self.visibleLimit) 条") {
                        showsAll.toggle()
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("书签视点")
        }
    }

    private func row(_ bookmark: ViewBookmark) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Text(bookmark.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                model.goToBookmark(bookmark)
            } label: {
                Image(systemName: "arrow.turn.down.right")
            }
            .buttonStyle(.borderless)
            .help("跳到这个视点")
        }
        .contentShape(Rectangle())
        .onTapGesture { model.goToBookmark(bookmark) }
        .contextMenu {
            Button("跳到这里") { model.goToBookmark(bookmark) }
            Button("重命名（用名称对话框）…") { rename(bookmark) }
            Divider()
            Button("删除", role: .destructive) { model.removeBookmark(bookmark.id) }
        }
    }

    /// 重命名：macOS 上用一个带输入框的小 `NSAlert` 最省事，也不会顶掉检查器的布局。
    private func rename(_ bookmark: ViewBookmark) {
        let alert = NSAlert()
        alert.messageText = "重命名书签"
        alert.informativeText = bookmark.detail
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = bookmark.displayName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.bookmarks.rename(bookmark.id, to: field.stringValue)
    }
}

/// 一个「书签视点」：记住中心坐标与缩放层级，一键跳回去。
///
/// 只存这两样：方位角、图层开关这些属于「当前会话」的东西不进书签，
/// 否则跳回去的画面会跟当初记下的不一样。
struct ViewBookmark: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var center: GeoCoordinate
    /// 连续缩放层级（不是整数层级：差半级跳回去就少看半屏）。
    var zoomLevel: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        center: GeoCoordinate,
        zoomLevel: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.center = center
        self.zoomLevel = zoomLevel
        self.createdAt = createdAt
    }

    /// 列表里的标题：没起名字就用坐标顶上，至少还能认出在哪。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return String(format: "%.5f, %.5f", center.longitude, center.latitude)
    }

    var detail: String {
        String(format: "z%.1f · %.5f, %.5f", zoomLevel, center.longitude, center.latitude)
    }
}

/// 书签列表的持久化存储。
///
/// 存在 `UserDefaults` 里的一小段 JSON：条数上限 200，读坏了一律当空列表，
/// 不让一份写坏的偏好把启动流程带走。
@MainActor
@Observable
final class BookmarkStore {
    private(set) var items: [ViewBookmark] = []

    /// 最多记这么多条（再多列表就不看了，也没必要占偏好空间）。
    static let limit = 200
    private static let storageKey = "viewBookmarks.v1"

    init() {
        items = Self.load()
    }

    /// 记下一个视点，返回新条目。
    @discardableResult
    func add(name: String, center: GeoCoordinate, zoomLevel: Double) -> ViewBookmark {
        let bookmark = ViewBookmark(name: name, center: center, zoomLevel: zoomLevel)
        items.append(bookmark)
        if items.count > Self.limit {
            items.removeFirst(items.count - Self.limit)
        }
        save()
        return bookmark
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].name = name
        save()
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        save()
    }

    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        items.insert(item, at: min(destination, items.count))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> [ViewBookmark] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ViewBookmark].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(limit))
    }
}
