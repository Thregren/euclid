import AppKit
import Foundation
import SwiftUI
import TileKit

/// 开发调试用的「把界面切到某个状态」脚本：下载、在线底图、窗口摆位、深浅色、图层排序。
///
/// 从 `DebugFixtures.swift` 拆出来的纯搬移。全部只在对应环境变量存在时生效，
/// 正式使用一条都不会走到；分开只是为了让「示例数据」那个文件保持能一眼读完。

/// 开发调试用的自动下载脚本。
///
/// `EUCLID_DEBUG_DOWNLOAD="<URL 模板>|<西>,<南>,<东>,<北>|<最小层级>|<最大层级>|<输出目录>"`
/// 时在启动后按这组参数跑一次真实下载，并把结果打到 stderr；
/// `EUCLID_DEBUG_DOWNLOAD_SHEET=1` 则只是把下载面板打开，便于截图核对。
/// 两者都只在设置了环境变量时生效，正式使用不会触发。
@MainActor
enum DebugDownloadScript {
    static var sheetRequested: Bool {
        ProcessInfo.processInfo.environment["EUCLID_DEBUG_DOWNLOAD_SHEET"] != nil
    }

    static func runIfRequested(model: AppModel) {
        if sheetRequested {
            // 等数据范围算完再打开面板，截图核对时范围与层级才是真实值。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                model.showDownloadSheet = true
            }
        }
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_DOWNLOAD"] else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 else {
            FileHandle.standardError.write(Data("[download] 参数应为 模板|西,南,东,北|zmin|zmax|输出目录\n".utf8))
            return
        }
        let numbers = parts[1].split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4,
              let minimumZoom = Int(parts[2]),
              let maximumZoom = Int(parts[3]) else {
            FileHandle.standardError.write(Data("[download] 范围或层级无法解析\n".utf8))
            return
        }

        Task { @MainActor in
            let download = model.download
            download.prepare(currentBounds: nil, datasetBounds: nil, currentZoom: minimumZoom)
            download.sourceID = TileSourceTemplate.custom.id
            download.template = parts[0]
            download.bounds = GeoBounds(
                west: numbers[0],
                south: numbers[1],
                east: numbers[2],
                north: numbers[3]
            )
            download.minimumZoom = minimumZoom
            download.maximumZoom = maximumZoom
            download.outputDirectory = URL(fileURLWithPath: parts[4])
            download.requestsPerSecond = 0
            download.onStatus = { message in
                FileHandle.standardError.write(Data(("[download] " + message + "\n").utf8))
            }
            download.start()

            while download.isRunning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let summary = download.summary
            let line = String(
                format: "[download] 结束：成功=%d 跳过=%d 缺片=%d 失败=%d 字节=%d 用时=%.1fs 取消=%@\n",
                summary?.downloaded ?? -1,
                summary?.skipped ?? -1,
                summary?.missing ?? -1,
                summary?.failed ?? -1,
                summary?.bytes ?? -1,
                summary?.elapsed ?? -1,
                (summary?.cancelled ?? true) ? "是" : "否"
            )
            FileHandle.standardError.write(Data(line.utf8))
            if let failure = summary?.failures.first {
                FileHandle.standardError.write(Data(("[download] 示例失败：" + failure + "\n").utf8))
            }
        }
    }
}

/// 开发调试用的在线底图脚本。
///
/// `EUCLID_DEBUG_BASEMAP="<预设 id 或 URL 模板>"` 时，启动几秒后切到该在线底图
/// （`EUCLID_DEBUG_BASEMAP_KEY=<密钥>` 提供密钥），用于在无人值守的情况下核对在线取图链路。
@MainActor
enum DebugBasemapScript {
    static func runIfRequested(model: AppModel) {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_BASEMAP"] else { return }
        Task { @MainActor in
            // 等一下，让本地数据集的范围先算出来，在线底图就能对齐到同一片区域。
            try? await Task.sleep(for: .seconds(12))
            if let key = ProcessInfo.processInfo.environment["EUCLID_DEBUG_BASEMAP_KEY"] {
                model.download.key = key
            }
            if let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_DATUM"],
               let datum = Datum(rawValue: raw.lowercased()) {
                model.download.datum = datum
            }
            if let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_LOCAL_OPACITY"],
               let value = Double(raw) {
                model.localLayerOpacity = min(max(value, 0), 1)
            }
            if raw == "local" {
                model.usesOnlineBasemap = false
            } else if let preset = TileSourceTemplate.preset(id: raw), !preset.urlTemplate.isEmpty {
                model.download.sourceID = raw
                model.usesOnlineBasemap = true
            } else {
                // 先选预设（会重置模板），再写模板，顺序不能反。
                model.download.sourceID = TileSourceTemplate.custom.id
                model.download.sourceName = "在线测试源"
                model.download.template = raw
                model.usesOnlineBasemap = true
            }
            let line = "[basemap] 已切换到 \(model.basemapName)（\(model.onlineBasemap == nil ? "本地" : "在线")）\n"
            FileHandle.standardError.write(Data(line.utf8))
            let state = "[basemap] 在线=\(model.usesOnlineBasemap) 源=\(model.download.sourceID) 模板=\(model.download.template.prefix(48)) "
                + "无效原因=\(model.onlineBasemap?.invalidReason ?? "无") 有内容=\(model.hasMapContent)\n"
            FileHandle.standardError.write(Data(state.utf8))
            try? await Task.sleep(for: .seconds(4))
            let after = "[basemap] 4 秒后：可见=\(model.viewport.visibleTiles) 已载入=\(model.viewport.loadedTiles) "
                + "层级=\(model.viewport.dataZoom) 状态=\(model.statusMessage ?? "无")\n"
            FileHandle.standardError.write(Data(after.utf8))

            // 再等一会儿让底图铺满，然后专门记一帧「切换底图之后」的画面。
            // 缩放脚本的时序都落在切换之前，核对叠加对齐时需要一个切换后的稳定帧。
            try? await Task.sleep(for: .seconds(6))
            model.canvas.snapshot(index: 90)
            let settled = "[basemap] 切换后定格：可见=\(model.viewport.visibleTiles) 已载入=\(model.viewport.loadedTiles) "
                + "层级=\(model.viewport.dataZoom)\n"
            FileHandle.standardError.write(Data(settled.utf8))

            // `EUCLID_DEBUG_DATUM_SWITCH=<基准>`：底图铺好之后再改一次基准，
            // 用来核对「只改基准也要重新装配图层」（改完再定格一帧对比）。
            guard let switchRaw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_DATUM_SWITCH"],
                  let switched = Datum(rawValue: switchRaw.lowercased()) else { return }
            model.download.datum = switched
            let applied = "[basemap] 切换到基准 \(switched.shortTitle)，图层已重装：\(model.onlineBasemap?.datum.shortTitle ?? "无")\n"
            FileHandle.standardError.write(Data(applied.utf8))
            try? await Task.sleep(for: .seconds(4))
            model.canvas.snapshot(index: 91)
            let afterSwitch = "[basemap] 换基准后定格：可见=\(model.viewport.visibleTiles) 已载入=\(model.viewport.loadedTiles) "
                + "状态=\(model.statusMessage ?? "无")\n"
            FileHandle.standardError.write(Data(afterSwitch.utf8))
        }
    }
}

/// 开发调试用的窗口摆放脚本。
///
/// `EUCLID_DEBUG_WINDOW="x,y,w,h"`（屏幕左上角为原点，单位点）时把主窗口摆到指定位置并改大小。
/// 用途只有一个：无人值守截图时能**只截窗口区域**而不必截整屏（整屏会把桌面上别的内容一起拍进去），
/// 而窗口位置平时由 AppKit 的状态恢复决定，改偏好文件不生效。
@MainActor
enum DebugWindowScript {
    static func applyIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_WINDOW"] else { return }
        let numbers = raw.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
                  let screenHeight = (window.screen ?? NSScreen.main)?.frame.height else { return }
            window.setFrame(
                NSRect(
                    x: numbers[0],
                    y: screenHeight - numbers[1] - numbers[3],
                    width: numbers[2],
                    height: numbers[3]
                ),
                display: true
            )
            // 无人值守截图时把它抬到最前，否则会连桌面别的窗口一起拍进去。
            window.level = .floating
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
            DebugAppearanceScript.applyToWindowsIfRequested()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                DebugAppearanceScript.applyToWindowsIfRequested()
            }
        }
    }
}

/// 开发调试用的外观脚本。
///
/// `EUCLID_DEBUG_APPEARANCE=dark|light` 时强制指定外观，便于在浅色与深色下各截一次图核对对比度；
/// 正式使用不设置该变量，外观完全跟随系统。
///
/// 两侧都要管：`NSApp.appearance` 管 AppKit 那一半（窗口边框、状态栏、画布里的 CALayer），
/// SwiftUI 画的面板与文字走的是另一条路（见 `DebugColorSchemeOverride`）。
/// 只设前者的话截出来是「面板还浅、边框已深」的半深色，核对不了对比度。
@MainActor
enum DebugAppearanceScript {
    static func applyIfRequested() {
        guard let appearance = requested else { return }
        NSApplication.shared.appearance = appearance
    }

    /// 把已经开出来的窗口也切成指定外观（SwiftUI 会跟着更新环境里的深浅色）。
    static func applyToWindowsIfRequested() {
        guard let appearance = requested else { return }
        for window in NSApplication.shared.windows {
            window.appearance = appearance
        }
    }

    /// SwiftUI 那一半的环境色（见 `DebugColorSchemeOverride`）。
    static var requestedColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["EUCLID_DEBUG_APPEARANCE"]?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private static var requested: NSAppearance? {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_APPEARANCE"]?.lowercased() else { return nil }
        switch raw {
        case "dark": return NSAppearance(named: .darkAqua)
        case "light": return NSAppearance(named: .aqua)
        default: return nil
        }
    }
}

/// 调试用的深浅色覆盖。
///
/// 只设 `NSApp.appearance` 的话，只有 AppKit 那一半（窗口边框、状态栏、画布里的 CALayer）
/// 会变深，SwiftUI 画的面板与文字仍停在浅色，截出来是「半深色」，核对不了对比度。
/// 这里把环境色一起定下来，深浅色截图才有参考价值。
/// 正式使用不设置 `EUCLID_DEBUG_APPEARANCE`，环境色完全跟随系统。
struct DebugColorSchemeOverride: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if let scheme = DebugAppearanceScript.requestedColorScheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

/// 开发调试用的图层脚本。
///
/// `EUCLID_DEBUG_OPEN=<目录或影像>` 时启动后直接打开这份数据（不动「最近打开」那份偏好），
/// 无人值守截图核对时用得上：本机数据换一份就能看真实影像下的界面。
///
/// `EUCLID_DEBUG_LAYERS="add;move:0>3;opacity:0.6;select:1"` 时启动十秒后
/// 按分号分隔的顺序执行，每步把**面板里的行顺序**（上 → 下）打到 stderr。
///
/// 拖动排序这条链路没有别的办法无人值守地跑：这里调的就是面板拖放用的那个模型方法
/// （`moveLayer(_:toPanelRow:)`），因此日志里的顺序就是「拖到那一行之后应该看到的顺序」。
@MainActor
enum DebugLayerScript {
    static func runIfRequested(model: AppModel) {
        if let path = ProcessInfo.processInfo.environment["EUCLID_DEBUG_OPEN"] {
            model.openForDebugging(URL(fileURLWithPath: path))
        }
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_LAYERS"] else { return }
        func log(_ text: String) {
            FileHandle.standardError.write(Data(("[layers] " + text + "\n").utf8))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            log("开始：" + order(model))
            for step in raw.split(separator: ";") {
                let parts = step.trimmingCharacters(in: .whitespaces)
                    .split(separator: ":", maxSplits: 1)
                    .map(String.init)
                guard let action = parts.first, !action.isEmpty else { continue }
                let value = parts.count > 1 ? parts[1] : ""
                switch action {
                case "move":
                    let numbers = value.split(separator: ">").compactMap { Int($0) }
                    guard numbers.count == 2, model.panelOrder.indices.contains(numbers[0]) else { break }
                    let id = model.panelOrder[numbers[0]].id
                    model.moveLayer(id, toPanelRow: numbers[1])
                    log("把面板第 \(numbers[0]) 行拖到第 \(numbers[1]) 行：\(order(model))")
                case "opacity":
                    guard let opacity = Double(value) else { break }
                    model.setOpacity(of: model.selectedLayer?.id, to: opacity)
                    log("不透明度 → \(opacity)")
                case "select":
                    guard let row = Int(value), model.panelOrder.indices.contains(row) else { break }
                    model.selectLayer(model.panelOrder[row].id)
                    log("选中第 \(row) 行：\(model.selectedLayer?.name ?? "无")")
                case "activate":
                    guard let row = Int(value), model.panelOrder.indices.contains(row) else { break }
                    model.activateLayer(model.panelOrder[row].id)
                    log("把第 \(row) 行设为当前数据：\(model.selectedLayer?.name ?? "无")")
                case "pick":
                    // 按类型选中一条测量（截取某条测量的明细时用，例如 pick:area）。
                    guard let kind = MeasurementKind(rawValue: value),
                          let measurement = model.measurements.measurements.last(where: { $0.kind == kind }) else { break }
                    model.measurements.selectedID = measurement.id
                    model.canvas.refreshOverlay()
                    log("选中一条 \(kind.displayName)：\(measurement.points.count) 点")
                case "addData":
                    // 把第 n 份已打开的数据加成一层（用来核对「点图层行切数据」这条路）。
                    guard let index = Int(value) else { break }
                    if index < model.rasters.count {
                        model.addLayer(model.makeLayer(raster: model.rasters[index]))
                    } else if model.datasets.indices.contains(index - model.rasters.count) {
                        model.addLayer(model.makeLayer(dataset: model.datasets[index - model.rasters.count]))
                    } else {
                        break
                    }
                    log("加了一层本地数据：\(order(model))")
                case "hide", "show":
                    let parts = value.split(separator: ">").compactMap { Int($0) }
                    guard let row = parts.first, model.panelOrder.indices.contains(row) else { break }
                    model.setVisible(action == "show", of: model.panelOrder[row].id)
                    log("第 \(row) 行\(action == "show" ? "显示" : "隐藏")：\(order(model))")
                case "add":
                    guard let id = model.selectedLayer?.id else { break }
                    model.duplicateLayer(id)
                    log("复制选中层：\(order(model))")
                default:
                    break
                }
            }
            log("结束：" + order(model))
        }
    }

    /// 面板里的行顺序（第一行是最上面那层），带各自的实例 id、来源与不透明度。
    /// id 只取前 4 位：核对拖动排序时看的就是「哪一层挪到了哪一行」。
    private static func order(_ model: AppModel) -> String {
        model.panelOrder
            .map {
                let shortID = String($0.id.prefix(4))
                return "\(shortID)：\($0.name)<\($0.kind.rawValue)·\(Int(($0.opacity * 100).rounded()))%>"
            }
            .joined(separator: " | ")
    }
}

/// 开发调试用的「叠加打开」核对脚本。
///
/// `EUCLID_DEBUG_OPEN_STACK="<路径>|<路径>|…"` 时按顺序把它们打开：走的是真实的
/// 「打开」分岔口（`openForDebugging` → `openWithoutRemembering`），只是不写「最近打开」偏好。
/// 每打开一份就打印一次图层、当前数据、视野与测量条数 —— 用来核对
/// 「已经开着数据时再打开一份，是**叠成新图层**，而不是把老图层顶掉」：
/// 图层数应当递增、第一份仍在、基准层不变、视野与测量条数不该被改动。
///
/// `EUCLID_DEBUG_OPEN_STACK_WAIT=<秒>` 可覆盖每步的等待（默认 16 秒：大目录扫范围要时间）。
@MainActor
enum DebugOpenStackScript {
    static func runIfRequested(model: AppModel) {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_OPEN_STACK"] else { return }
        let paths = raw.split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        let environment = ProcessInfo.processInfo.environment
        let wait = Double(environment["EUCLID_DEBUG_OPEN_STACK_WAIT"] ?? "") ?? 16

        Task { @MainActor in
            for (index, path) in paths.enumerated() {
                try? await Task.sleep(for: .seconds(wait))
                model.openForDebugging(URL(fileURLWithPath: path))
                try? await Task.sleep(for: .seconds(wait))
                log("第 \(index + 1) 份「\(path)」打开之后：", model)
                // 第一份铺好之后随手落两个点：后面每打开一份都要证明这两条还在。
                if index == 0, model.measurements.measurements.isEmpty {
                    model.dropPointAtCursor()
                    model.dropPointAtCursor()
                    log("（落两个点当哨兵）", model)
                }
            }
            model.canvas.snapshot(index: 95)
        }
    }

    private static func log(_ label: String, _ model: AppModel) {
        let layers = model.layers
            .map { "\($0.name)<\($0.kind.rawValue)\($0.isAnchor ? "·基准" : "")>" }
            .joined(separator: " | ")
        let center = model.viewport.center
        let lines = [
            "图层 \(model.layers.count) 层：\(layers)",
            "当前数据：\(model.selectedSourceName ?? "无")｜已发现 数据集 \(model.datasets.count) 份 / 影像 \(model.rasters.count) 幅",
            String(format: "视野：中心 %.5f,%.5f  z%.2f  地面比例 %.4f 米/点  可见瓦片 %d",
                   center.longitude, center.latitude, model.viewport.zoomLevel,
                   model.viewport.metersPerPoint, model.viewport.visibleTiles),
            "测量：\(model.measurements.measurements.count) 条"
        ]
        for line in lines {
            FileHandle.standardError.write(Data(("[stack] " + label + " " + line + "\n").utf8))
        }
    }
}

/// 开发调试用的窗口截图脚本。
///
/// `EUCLID_DEBUG_WINDOW_SNAPSHOT=<路径>` 时启动若干秒后把**整个窗口内容**渲染成 PNG。
/// 与 `EUCLID_DEBUG_SNAPSHOT` 只截画布不同，这个连两侧面板、状态栏一起截，用来核对布局与
/// 深浅色对比度；渲染走 AppKit 自己的绘制（`cacheDisplay`），因此不需要屏幕录制权限，
/// 也不必让窗口真的显示在屏幕上。
///
/// `EUCLID_DEBUG_WINDOW_SNAPSHOT_AT=6,12` 可给一串「启动后第几秒」（逗号分隔，默认 10）；
/// 路径里含 `%d` 时按序号展开，便于一次跑出多张（例如数据铺好前后各一张）。
