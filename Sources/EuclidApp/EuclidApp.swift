import AppKit
import SwiftUI
import TileKit

/// 处理「用本应用打开文件夹」以及 Dock 图标点击等外部打开请求。
///
/// 注意：AppKit 会把启动时的位置参数当作待打开的文件，此时 SwiftUI 不会创建初始窗口，
/// 因此启动时不解析位置参数，数据集统一由「上次打开的目录」或打开面板决定。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugAppearanceScript.applyIfRequested()
        // 便于自动化截图/录屏时让窗口保持在最前。
        guard ProcessInfo.processInfo.environment["EUCLID_FLOAT_WINDOW"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            for window in NSApplication.shared.windows {
                window.level = .floating
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppModel.shared.open(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct Euclid: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1340, height: 860)
        .windowToolbarStyle(.unified)
        .commands { commands }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开瓦片目录…") {
                model.promptForFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("打开单幅影像…") {
                model.promptForRaster()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .help("打开 GeoTIFF / TIFF / 图片（按地理参考摆到正确位置）")
            Button("下载在线瓦片…") {
                model.showDownloadSheet = true
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("导出当前视图为图片…") {
                model.exportViewAsImage()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!model.hasMapContent)
            Button("复制当前视图到剪贴板") {
                model.copyViewToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!model.hasMapContent)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { model.performUndo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("重做") { model.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Toggle(isOn: Bindable(model).showInspector) {
                Text("显示检查器")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("视图") {
            Button("放大") { model.canvas.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("缩小") { model.canvas.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("适配窗口") { model.canvas.fit() }
                .keyboardShortcut("0", modifiers: .command)
            Button("原始比例") { model.canvas.actualSize() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
            Toggle(isOn: Bindable(model).showTileGrid) {
                Text("显示瓦片网格")
            }
            .keyboardShortcut("g", modifiers: .command)
        }
        CommandMenu("工具") {
            Button("浏览") { model.measurements.tool = .browse }
                .keyboardShortcut("1", modifiers: .command)
            Button("点坐标") { model.measurements.tool = .point }
                .keyboardShortcut("2", modifiers: .command)
            Button("测距") { model.measurements.tool = .distance }
                .keyboardShortcut("3", modifiers: .command)
            Button("测面积") { model.measurements.tool = .area }
                .keyboardShortcut("4", modifiers: .command)
            Button("画圆") { model.measurements.tool = .circle }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("结束当前测量") {
                model.measurements.finishDraft()
                model.canvas.refreshOverlay()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.measurements.draft.count < (model.measurements.draftKind == .area ? 3 : 2))
            Button("清除全部测量") {
                model.clearMeasurements()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!model.measurements.hasContent)
            Divider()
            Menu("导出测量结果") {
                Section("复制到剪贴板") {
                    ForEach(MeasurementExportFormat.textFormats) { format in
                        Button("复制为 \(format.title)") {
                            model.copyMeasurements(as: format)
                        }
                    }
                }
                Section("导出文件") {
                    ForEach(MeasurementExportFormat.allCases) { format in
                        Button("导出为 \(format.title)…") {
                            model.exportMeasurements(as: format)
                        }
                    }
                }
            }
            .disabled(!model.measurements.hasContent)
        }
    }
}
