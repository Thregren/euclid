import AppKit
import Foundation
import TileKit

/// ⌘K 命令面板与自定义快捷键。
///
/// 从 `AppModel.swift` 拆出来：那边是状态中枢，这边只负责「有哪些命令、怎么触发」。
/// 面板本身（`CommandPaletteView`）只认这份清单，不硬编码任何业务逻辑。
extension AppModel {
    // MARK: - 命令清单

    /// 面板里能搜到的全部命令。
    var commands: [AppCommand] {
        AppCommandID.allCases.map { id in
            AppCommand(
                id: id,
                title: id.title,
                category: id.category,
                shortcut: shortcuts.shortcut(for: id),
                isEnabled: isEnabled(id),
                run: { [weak self] in self?.perform(id) }
            )
        }
    }

    /// 这条命令现在跑不跑得动（跑不动时面板里淡着显示、也不执行）。
    func isEnabled(_ id: AppCommandID) -> Bool {
        switch id {
        case .quickExportView, .exportImage, .exportPDF, .copyView, .addBookmark,
             .exportAtlas, .dropPointAtCursor, .fitWindow, .actualSize,
             .zoomIn, .zoomOut, .toggleGrid:
            return hasMapContent
        case .swipeCompare:
            return layers.count >= 2
        case .analysisToolbox:
            return analysisReader != nil
        case .nextTab, .previousTab:
            return workspaceTabs.count > 1
        case .copyCursorCoordinate:
            return measurements.cursorInfo != nil
        case .finishDraft:
            return measurements.draft.count >= (measurements.draftKind == .area ? 3 : 2)
        case .clearMeasurements, .saveMeasurements:
            return measurements.hasContent
        case .undo:
            return measurements.canUndo
        case .redo:
            return measurements.canRedo
        default:
            return true
        }
    }

    /// 执行一条命令。
    func perform(_ id: AppCommandID) {
        switch id {
        case .commandPalette: openCommandPalette()
        case .openFolder: promptForFolder()
        case .openRaster: promptForRaster()
        case .downloadTiles: showDownloadSheet = true
        case .generateTiles: promptForTileExport()
        case .localTileServer: showTileServerSheet = true
        case .analysisToolbox: showAnalysisSheet = true
        case .quickExportView: quickExportView()
        case .exportImage: exportViewAsImage()
        case .exportPDF: exportViewAsPDF()
        case .copyView: copyViewToClipboard()
        case .saveMeasurements: saveMeasurementsToFile()
        case .loadMeasurements: loadMeasurementsFromFile()
        case .importVector: importVectorOverlay()
        case .addBookmark: addBookmark()
        case .exportAtlas: exportInspectionAtlas()
        case .toggleLayers: showLayers.toggle()
        case .toggleInspector: showInspector.toggle()
        case .toggleGrid: showTileGrid.toggle()
        case .zoomIn: canvas.zoomIn()
        case .zoomOut: canvas.zoomOut()
        case .fitWindow: canvas.fit()
        case .actualSize: canvas.actualSize()
        case .toolBrowse: measurements.tool = .browse
        case .toolPoint: measurements.tool = .point
        case .toolDistance: measurements.tool = .distance
        case .toolArea: measurements.tool = .area
        case .toolCircle: measurements.tool = .circle
        case .toolAnnotation: measurements.tool = .annotation
        case .dropPointAtCursor: dropPointAtCursor()
        case .copyCursorCoordinate: copyCursorCoordinate()
        case .finishDraft:
            measurements.finishDraft()
            canvas.refreshOverlay()
        case .clearMeasurements: clearMeasurements()
        case .swipeCompare:
            if let id = selectedLayer?.id { toggleSwipeCompare(layerID: id) }
        case .newTab: addWorkspaceTab()
        case .closeTab: closeActiveWorkspaceTab()
        case .nextTab: selectNextWorkspaceTab()
        case .previousTab: selectPreviousWorkspaceTab()
        case .undo: performUndo()
        case .redo: performRedo()
        }
    }

    // MARK: - 面板开关

    func openCommandPalette() {
        showCommandPalette = true
    }

    func closeCommandPalette() {
        showCommandPalette = false
    }

    /// 面板里点「快捷键设置…」：两个面板不能同时开着，先收面板再开设置。
    func commandPaletteDismiss(openSettings: Bool) {
        showCommandPalette = false
        if openSettings { showShortcutSettings = true }
    }

    // MARK: - 键盘

    /// 装一个全局按键监视器，接管「用户改过的那部分快捷键」。
    ///
    /// 为什么要这一层：菜单项自带的 `.keyboardShortcut` 是编译期写死的，
    /// 用户改了键之后没法换 —— 于是改过的组合键只在这里判一次；
    /// 没改过的命令照旧走菜单，行为与以前完全一致（也就不会互相打架）。
    /// 判中之后把事件吃掉（返回 nil），菜单就不会再收到一次。
    func installCommandKeyMonitor() {
        guard commandKeyMonitor == nil else { return }
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleCommandKey(event) }
            return handled ? nil : event
        }
    }

    /// 返回 true = 这条按键已经被我们处理（调用方应吃掉事件）。
    @discardableResult
    func handleCommandKey(_ event: NSEvent) -> Bool {
        // 只认「改过的」那些组合键：录制时保证了至少带一个修饰键，
        // 因此不会跟普通打字抢。没改过的命令照旧走菜单栏那一套。
        for id in AppCommandID.allCases where shortcuts.isCustomized(id) {
            guard shortcuts.matches(event, command: id) else { continue }
            if id == .commandPalette {
                openCommandPalette()
            } else {
                guard isEnabled(id) else { continue }
                perform(id)
            }
            return true
        }
        return false
    }

    /// 卸载监视器（视图拆掉时）。
    func removeCommandKeyMonitor() {
        if let commandKeyMonitor { NSEvent.removeMonitor(commandKeyMonitor) }
        commandKeyMonitor = nil
    }
}
