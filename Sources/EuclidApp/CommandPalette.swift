import AppKit
import Observation
import SwiftUI

// MARK: - 快捷键的值模型

/// 一条可自定义的快捷键：一个「不计修饰键的字符」加一组修饰键。
///
/// 用值类型而不是直接存 `NSEvent.ModifierFlags`：要能序列化进偏好、要能比较、
/// 还要能在菜单与面板里印成人看的「⌘⇧K」。
struct KeyShortcut: Codable, Hashable, Sendable {
    /// 不计修饰键的字符（小写，例如 "k" / "0" / "="；回车存 "\\r"）。
    var key: String
    /// 修饰键的原始位（只保留 ⌘⌥⌃⇧ 这四位）。
    var modifiers: UInt

    /// 从一次按键事件里取出来；没有可打印字符（功能键之类）时返回 nil。
    init?(event: NSEvent) {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = event.modifierFlags.intersection(relevant)
        // 至少得有一个修饰键，否则普通打字就会触发命令。
        guard !flags.isEmpty else { return nil }
        if event.keyCode == 36 || event.keyCode == 76 {
            key = "\r"
        } else {
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else { return nil }
            key = String(characters.prefix(1))
        }
        modifiers = flags.rawValue & Self.mask
    }

    init(key: String, modifiers: UInt) {
        self.key = key
        self.modifiers = modifiers & Self.mask
    }

    private static let mask: UInt = {
        let flags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return flags.rawValue
    }()

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift])
    }

    /// 这次按键是不是这一条（只看字符与那四个修饰键）。
    func matches(_ event: NSEvent) -> Bool {
        guard let other = KeyShortcut(event: event) else { return false }
        return other == self
    }

    /// 人看的写法：⌃⌥⇧⌘ + 键。
    var displayText: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        switch key {
        case "\r": return text + "↩"
        case "\t": return text + "⇥"
        case " ": return text + "空格"
        default: return text + key.uppercased()
        }
    }

    /// 给菜单项用的 SwiftUI 快捷键；功能键（回车）单独处理。
    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "\r": return .return
        case "\t": return .tab
        default:
            guard let character = key.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

// MARK: - 快捷键偏好（可覆盖）

/// 用户改过的快捷键：`命令 id → 快捷键`，存在偏好里。
///
/// 只有「改过的」才落盘：没改过的命令一律用 `defaultShortcut`，
/// 这样以后调整默认值不会因为旧偏好而失效。
@MainActor
@Observable
final class ShortcutStore {
    private static let key = "commandShortcuts.v1"

    private var overrides: [String: KeyShortcut] = [:] {
        didSet { persist() }
    }

    init() { load() }

    /// 某条命令当前生效的快捷键（先看覆盖，再看默认）。
    func shortcut(for command: AppCommandID) -> KeyShortcut? {
        overrides[command.rawValue] ?? command.defaultShortcut
    }

    /// 这条命令的快捷键是不是被用户改过。
    func isCustomized(_ command: AppCommandID) -> Bool {
        overrides[command.rawValue] != nil
    }

    /// 改成新的快捷键；和别的命令撞车时把对方那条覆盖删掉（先到先得，后改的赢）。
    func setShortcut(_ shortcut: KeyShortcut?, for command: AppCommandID) {
        if let shortcut {
            for (id, existing) in overrides where id != command.rawValue && existing == shortcut {
                overrides[id] = nil
            }
        }
        overrides[command.rawValue] = shortcut
    }

    /// 恢复某条命令的默认快捷键。
    func reset(_ command: AppCommandID) {
        overrides[command.rawValue] = nil
    }

    /// 全部恢复默认。
    func resetAll() {
        overrides.removeAll()
    }

    /// 用一次按键去匹配某条命令（面板与键盘监视器共用）。
    func matches(_ event: NSEvent, command: AppCommandID) -> Bool {
        guard let shortcut = shortcut(for: command) else { return false }
        return shortcut.matches(event)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return }
        overrides = (try? JSONDecoder().decode([String: KeyShortcut].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

// MARK: - 命令

/// 命令面板里的每条命令都有一个稳定 id —— 快捷键偏好按它存。
enum AppCommandID: String, CaseIterable, Sendable {
    case commandPalette
    case openFolder
    case openRaster
    case downloadTiles
    case generateTiles
    case localTileServer
    case analysisToolbox
    case quickExportView
    case exportImage
    case exportPDF
    case copyView
    case saveMeasurements
    case loadMeasurements
    case importVector
    case addBookmark
    case exportAtlas
    case toggleLayers
    case toggleInspector
    case toggleGrid
    case zoomIn
    case zoomOut
    case fitWindow
    case actualSize
    case toolBrowse
    case toolPoint
    case toolDistance
    case toolArea
    case toolCircle
    case toolAnnotation
    case dropPointAtCursor
    case copyCursorCoordinate
    case finishDraft
    case clearMeasurements
    case swipeCompare
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case undo
    case redo

    var title: String {
        switch self {
        case .commandPalette: return "命令面板"
        case .openFolder: return "打开瓦片目录…"
        case .openRaster: return "打开单幅影像…"
        case .downloadTiles: return "下载在线瓦片…"
        case .generateTiles: return "从影像生成瓦片…"
        case .localTileServer: return "本地瓦片服务…"
        case .analysisToolbox: return "DEM 工具箱…"
        case .quickExportView: return "快速导出当前视图（含标注）"
        case .exportImage: return "导出当前视图为图片…"
        case .exportPDF: return "导出当前视图为 PDF…"
        case .copyView: return "复制当前视图到剪贴板"
        case .saveMeasurements: return "保存测量到文件…"
        case .loadMeasurements: return "从文件载入测量…"
        case .importVector: return "导入 GeoJSON / KML 叠加层…"
        case .addBookmark: return "把当前视图记为书签"
        case .exportAtlas: return "导出巡检图集…"
        case .toggleLayers: return "显示 / 隐藏图层面板"
        case .toggleInspector: return "显示 / 隐藏检查器"
        case .toggleGrid: return "显示 / 隐藏瓦片网格"
        case .zoomIn: return "放大"
        case .zoomOut: return "缩小"
        case .fitWindow: return "适配窗口"
        case .actualSize: return "原始比例"
        case .toolBrowse: return "工具：浏览"
        case .toolPoint: return "工具：点坐标"
        case .toolDistance: return "工具：测距"
        case .toolArea: return "工具：测面积"
        case .toolCircle: return "工具：画圆"
        case .toolAnnotation: return "工具：标注"
        case .dropPointAtCursor: return "记下指针位置的点"
        case .copyCursorCoordinate: return "复制指针坐标"
        case .finishDraft: return "结束当前测量"
        case .clearMeasurements: return "清除全部测量"
        case .swipeCompare: return "卷帘对比（以选中图层为分界）"
        case .newTab: return "新建标签页"
        case .closeTab: return "关闭标签页"
        case .nextTab: return "下一个标签页"
        case .previousTab: return "上一个标签页"
        case .undo: return "撤销"
        case .redo: return "重做"
        }
    }

    var category: String {
        switch self {
        case .commandPalette, .toggleLayers, .toggleInspector, .toggleGrid,
             .zoomIn, .zoomOut, .fitWindow, .actualSize, .swipeCompare,
             .newTab, .closeTab, .nextTab, .previousTab:
            return "视图"
        case .openFolder, .openRaster, .downloadTiles, .generateTiles,
             .localTileServer, .analysisToolbox, .importVector,
             .loadMeasurements, .saveMeasurements:
            return "数据"
        case .quickExportView, .exportImage, .exportPDF, .copyView, .exportAtlas:
            return "出图"
        case .addBookmark:
            return "书签"
        case .toolBrowse, .toolPoint, .toolDistance, .toolArea,
             .toolCircle, .toolAnnotation, .dropPointAtCursor,
             .copyCursorCoordinate, .finishDraft, .clearMeasurements:
            return "测量"
        case .undo, .redo:
            return "编辑"
        }
    }

    /// 出厂快捷键。
    ///
    /// 与菜单栏里那一套保持一致：菜单项自己带 `.keyboardShortcut`，
    /// 这里只是「面板里显示 + 被改过之后由键盘监视器接管」用的同一份定义。
    var defaultShortcut: KeyShortcut? {
        func make(_ key: String, _ flags: NSEvent.ModifierFlags) -> KeyShortcut {
            KeyShortcut(key: key, modifiers: flags.rawValue)
        }
        switch self {
        case .commandPalette: return make("k", .command)
        case .openFolder: return make("o", .command)
        case .openRaster: return make("o", [.command, .shift])
        case .downloadTiles: return make("d", [.command, .shift])
        case .generateTiles: return make("t", [.command, .shift])
        case .localTileServer: return make("l", [.command, .shift])
        case .analysisToolbox: return make("d", [.command, .option])
        case .quickExportView: return make("e", .command)
        case .exportImage: return make("e", [.command, .shift])
        case .exportPDF: return make("e", [.command, .option])
        case .copyView: return make("c", [.command, .shift])
        case .saveMeasurements: return make("s", .command)
        case .loadMeasurements: return make("o", [.command, .option])
        case .importVector: return make("i", [.command, .option, .shift])
        case .addBookmark: return make("b", [.command, .shift])
        case .exportAtlas: return make("a", [.command, .option])
        case .toggleLayers: return make("l", [.command, .option])
        case .toggleInspector: return make("i", [.command, .option])
        case .toggleGrid: return make("g", .command)
        case .zoomIn: return make("=", .command)
        case .zoomOut: return make("-", .command)
        case .fitWindow: return make("0", .command)
        case .actualSize: return make("0", [.command, .shift])
        case .toolBrowse: return make("1", .command)
        case .toolPoint: return make("2", .command)
        case .toolDistance: return make("3", .command)
        case .toolArea: return make("4", .command)
        case .toolCircle: return make("5", .command)
        case .toolAnnotation: return make("6", .command)
        case .dropPointAtCursor: return nil
        case .copyCursorCoordinate: return make("c", [.command, .option])
        case .finishDraft: return make("\r", .command)
        case .clearMeasurements: return make("k", [.command, .shift])
        case .swipeCompare: return nil
        case .newTab: return make("t", .command)
        case .closeTab: return make("w", [.command, .option])
        case .nextTab: return make("\t", .control)
        case .previousTab: return make("\t", [.control, .shift])
        case .undo: return make("z", .command)
        case .redo: return make("z", [.command, .shift])
        }
    }
}

/// 一条能被搜索、能被执行、能被改键的命令。
struct AppCommand: Identifiable {
    var id: AppCommandID
    var title: String
    var category: String
    var shortcut: KeyShortcut?
    /// 现在能不能执行（不能执行的在面板里淡着显示，跑不跑得动由执行方自己兜底）。
    var isEnabled: Bool
    var run: () -> Void

    var searchText: String { "\(title) \(category)" }
}

// MARK: - 命令面板

/// ⌘K 命令面板：输几个字就能搜到命令，↑↓ 选、↩ 执行、Esc 关掉。
///
/// 面板只认 `AppModel.commands` 这份清单，不硬编码任何一条业务逻辑 ——
/// 加新命令只要往清单里加一条。
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [AppCommand] {
        let all = model.commands
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        // 简单但够用的模糊匹配：先按「连续子串」找，再退化成「按顺序出现」。
        let tokens = needle.split(separator: " ").map(String.init)
        return all.filter { command in
            let haystack = command.searchText.lowercased()
            return tokens.allSatisfy { token in
                haystack.contains(token) || Self.subsequence(token, of: haystack)
            }
        }
    }

    /// token 的字符按顺序都出现在 haystack 里（不要求连续）。
    private static func subsequence(_ token: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in token {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if matches.isEmpty {
                Text("没有匹配的命令")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                                row(command, isSelected: index == selection)
                                    .id(index)
                                    .onTapGesture { run(command) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, newValue in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(radius: 24, y: 8)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .foregroundStyle(.secondary)
            TextField("输入命令名称…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) {
                    if let command = matches[safe: selection] { run(command) }
                    return .handled
                }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func row(_ command: AppCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(command.category)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(command.title)
                .font(.body)
                .foregroundStyle(command.isEnabled ? .primary : .tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut.displayText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("↑↓ 选择", systemImage: "arrow.up.arrow.down")
            Label("↩ 执行", systemImage: "return")
            Label("esc 关闭", systemImage: "escape")
            Spacer()
            Button("快捷键设置…") {
                model.commandPaletteDismiss(openSettings: true)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + delta + matches.count) % matches.count
    }

    private func run(_ command: AppCommand) {
        model.closeCommandPalette()
        command.run()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 快捷键设置

/// 快捷键设置：左边一列命令，右边一个录制框。
struct ShortcutSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recording: AppCommandID?
    @State private var conflict: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("快捷键")
                    .font(.headline)
                Spacer()
                Button("全部恢复默认") {
                    model.shortcuts.resetAll()
                    conflict = nil
                }
                .disabled(!AppCommandID.allCases.contains { model.shortcuts.isCustomized($0) })
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(AppCommandID.allCases, id: \.self) { command in
                        shortcutRow(command)
                        Divider()
                    }
                }
            }
            Divider()
            HStack {
                if let conflict {
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("点右边的键位再按一次组合键即可改；至少带一个修饰键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 460)
    }

    private func shortcutRow(_ command: AppCommandID) -> some View {
        HStack(spacing: 10) {
            Text(command.category)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(command.title)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.shortcuts.isCustomized(command) {
                Button {
                    model.shortcuts.reset(command)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("恢复默认")
            }
            ShortcutRecorder(
                shortcut: model.shortcuts.shortcut(for: command),
                isRecording: recording == command,
                onBegin: {
                    conflict = nil
                    recording = command
                },
                onCapture: { shortcut in
                    recording = nil
                    if let shortcut {
                        model.shortcuts.setShortcut(shortcut, for: command)
                        conflict = nil
                    }
                },
                onCancel: { recording = nil }
            )
            .frame(width: 118, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// 一个「点一下、按一次组合键」的小录制框。
///
/// 用 AppKit 的按键事件而不是 SwiftUI 的 `onKeyPress`：录制阶段要拦下原始的修饰键组合
/// （`onKeyPress` 拿不到完整的修饰键状态，也会被菜单的快捷键抢走）。
private struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: KeyShortcut?
    var isRecording: Bool
    var onBegin: () -> Void
    var onCapture: (KeyShortcut?) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onBegin = onBegin
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onBegin = onBegin
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.shortcut = shortcut
        view.isRecording = isRecording
        view.needsDisplay = true
        if isRecording, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }

    final class RecorderView: NSView {
        var onBegin: (() -> Void)?
        var onCapture: ((KeyShortcut?) -> Void)?
        var onCancel: (() -> Void)?
        var shortcut: KeyShortcut? { didSet { needsDisplay = true } }
        var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var focusRingMaskBounds: NSRect { bounds }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = 1
            path.stroke()
            let text = isRecording ? "按下组合键…" : (shortcut?.displayText ?? "未设置")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }

        override func mouseDown(with event: NSEvent) {
            onBegin?()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { return super.keyDown(with: event) }
            // Esc / Delete 当作「清空这条快捷键」。
            if event.keyCode == 53 { onCancel?(); window?.makeFirstResponder(nil); return }
            if event.keyCode == 51 || event.keyCode == 117 { onCapture?(nil); return }
            if let shortcut = KeyShortcut(event: event) {
                onCapture?(shortcut)
            } else {
                NSSound.beep()
            }
        }
    }
}
