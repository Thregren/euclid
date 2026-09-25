import AppKit
import Foundation
import TileKit

/// 开发调试用的示例数据。
///
/// 仅当环境变量 `EUCLID_DEMO_MEASUREMENT` 存在时才会生成，用于截图核对与人工回归；
/// 正式使用不会触发任何逻辑。
@MainActor
enum DebugFixtures {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EUCLID_DEMO_MEASUREMENT"] != nil
    }

    /// 在数据集覆盖范围内铺几条示例测量。
    static func populateMeasurements(in extent: DatasetExtent, store: MeasurementStore) {
        let rect = extent.worldRect
        func point(_ fractionX: Double, _ fractionY: Double) -> GeoCoordinate {
            WebMercator.coordinate(fromNormalized: CGPoint(
                x: rect.minX + rect.width * fractionX,
                y: rect.minY + rect.height * fractionY
            ))
        }

        store.clearAll()
        store.addFinished(GeoMeasurement(
            kind: .distance,
            points: [point(0.20, 0.72), point(0.30, 0.55), point(0.42, 0.60)],
            colorIndex: 1
        ), select: false)
        let area = GeoMeasurement(
            kind: .area,
            points: [point(0.52, 0.44), point(0.72, 0.40), point(0.76, 0.58), point(0.56, 0.62)],
            colorIndex: 2
        )
        store.addFinished(area)

        // 一个圆：圆心 + 半径点，用于核对圆的描边、填充与半径标注。
        let circle = GeoMeasurement(
            kind: .circle,
            points: [point(0.24, 0.40), point(0.31, 0.40)],
            colorIndex: 5
        )
        store.addFinished(circle, select: false)

        // 一个进行中的测距草稿，用于核对橡皮筋预览与分段标注。
        store.tool = .distance
        for coordinate in [point(0.28, 0.26), point(0.40, 0.30), point(0.48, 0.24)] {
            store.addPoint(coordinate)
        }
        store.liveCoordinate = point(0.62, 0.26)
        // 默认选中圆，便于截图核对新的半径输入与填充样式控件。
        store.selectedID = circle.id
    }
}

/// 开发调试用的自动缩放脚本。
///
/// `EUCLID_DEBUG_ZOOM="o3,i5,o4"` 表示「缩小 3 步、放大 5 步、再缩小 4 步」，
/// 配合 `EUCLID_DEBUG_SNAPSHOT=<目录>` 会逐帧写出画布 PNG，
/// 用来核对换层级时会不会闪出空白、以及清晰度，屏幕不在前台也能跑。
@MainActor
enum DebugZoomScript {
    static var script: String? {
        ProcessInfo.processInfo.environment["EUCLID_DEBUG_ZOOM"]
    }

    static func runIfRequested(canvas: CanvasController) {
        guard let script, !script.isEmpty else { return }
        Task {
            var snapshotIndex = 1
            @MainActor
            func snap() {
                canvas.snapshot(index: snapshotIndex)
                snapshotIndex += 1
            }

            try? await Task.sleep(for: .seconds(2))
            snap()
            for step in script.split(separator: ",") {
                try? await Task.sleep(for: .seconds(1.4))
                let count = max(1, Int(step.dropFirst()) ?? 1)
                for _ in 0..<count {
                    if step.hasPrefix("i") {
                        canvas.zoomIn()
                    } else {
                        canvas.zoomOut()
                    }
                    // 先记一帧「切换瞬间」，再记一帧「稳定后」，用来核对有没有空白帧。
                    snap()
                    try? await Task.sleep(for: .seconds(0.3))
                    snap()
                }
            }
            try? await Task.sleep(for: .seconds(2))
            snap()
            // 顺带报一下测量结果缓存的命中次数：缩放脚本跑完会重绘很多帧，
            // 命中数远大于测量条数，说明每帧重算测地线的那条路真的被避开了。
            let hits = MeasurementCalculator.resultCacheHits
            FileHandle.standardError.write(Data(
                "[perf] 缩放脚本结束：测量结果缓存命中 \(hits) 次\n".utf8
            ))
        }
    }
}

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
        }
    }
}

/// 开发调试用的外观脚本。
///
/// `EUCLID_DEBUG_APPEARANCE=dark|light` 时强制指定外观，便于在浅色与深色下各截一次图核对对比度；
/// 正式使用不设置该变量，外观完全跟随系统。
@MainActor
enum DebugAppearanceScript {
    static func applyIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_APPEARANCE"]?.lowercased() else { return }
        switch raw {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}

/// 开发调试用的自检脚本：一次跑完「快捷键落点 / 快速导出 / 测量存档读写」。
///
/// `EUCLID_DEBUG_VERIFY=1` 时启动十几秒后依次执行并把结果打到 stderr。
/// 只用于无人值守核对，正式使用不设置该变量。
@MainActor
enum DebugVerifyScript {
    static func runIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.environment["EUCLID_DEBUG_VERIFY"] != nil else { return }
        func log(_ text: String) {
            FileHandle.standardError.write(Data(("[verify] " + text + "\n").utf8))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(14))
            let center = model.viewport.center
            log(String(format: "视图中心 %.5f, %.5f  z%d 底图=%@",
                       center.longitude, center.latitude, model.viewport.dataZoom, model.basemapName))

            // 1) 快捷键落点（与「点坐标」同一份数据）
            let before = model.measurements.measurements.count
            model.dropPointAtCursor()
            model.dropPointAtCursor()
            let points = model.measurements.measurements.filter { $0.kind == .point }
            log("落点：测量 \(before) → \(model.measurements.measurements.count)，其中 point 类 \(points.count) 条，"
                + "点坐标 \(points.last?.points.first.map { String(format: "%.5f, %.5f", $0.longitude, $0.latitude) } ?? "无")")

            // 2) 测量存档读写（同一个文件：写进去再读回来）
            let file = URL(fileURLWithPath: "/tmp/euclid-verify-measurements.json")
            _ = model.writeMeasurements(to: file)
            let written = model.measurements.measurements.count
            model.clearMeasurements()
            let loaded = model.loadMeasurements(from: file) ?? -1
            log("存档：写出 \(written) 条 → 清空 → 读回 \(loaded) 条（应相等）")

            // 3) 快速导出（不弹面板，直接落到快捷导出目录）
            model.quickExportView()
            log("快速导出：状态=「\(model.statusMessage ?? "无")」")

            // 4) 多图层：开关之前应当有本地 + 在线两层，各自独立的不透明度
            @MainActor func layersText() -> String {
                model.layers.map { "\($0.name)(\($0.kind.rawValue)) \(Int(($0.opacity * 100).rounded()))%" }
                    .joined(separator: " / ")
            }
            log("图层（开关底图之前）：" + layersText())

            // 5) 开关在线底图不应改变视野（按地面比例与中心对比）
            @MainActor func reading() -> String {
                let center = model.viewport.center
                let bounds = model.canvas.visibleBounds()
                let box = bounds.map { String(format: "可见 %.5f…%.5f / %.5f…%.5f",
                                              $0.west, $0.east, $0.south, $0.north) } ?? "可见 —"
                return String(format: "中心 %.5f,%.5f  地面比例 %.4f 米/点  层级 z%.2f  %@",
                              center.longitude, center.latitude, model.viewport.metersPerPoint,
                              model.viewport.zoomLevel, box)
            }
            let viewBefore = reading()
            model.usesOnlineBasemap = true
            try? await Task.sleep(for: .seconds(3))
            let viewWithBasemap = reading()
            model.usesOnlineBasemap = false
            try? await Task.sleep(for: .seconds(3))
            let viewAfter = reading()
            log("开关底图：开之前 \(viewBefore)")
            log("开关底图：开着时 \(viewWithBasemap)")
            log("开关底图：关掉后 \(viewAfter)")

            // 6) 每层独立的不透明度
            model.usesOnlineBasemap = true
            try? await Task.sleep(for: .seconds(2))
            if let online = model.onlineLayer { model.setOpacity(of: online.id, to: 0.5) }
            if let anchorLayer = model.anchorLayer { model.setOpacity(of: anchorLayer.id, to: 0.8) }
            try? await Task.sleep(for: .seconds(2))
            log("两层各不相同的不透明度：" + layersText())

            // 5) 关窗是否退出（设置了 EUCLID_DEBUG_VERIFY_CLOSE 时）
            if ProcessInfo.processInfo.environment["EUCLID_DEBUG_VERIFY_CLOSE"] != nil {
                log("即将关闭主窗口，若程序正常退出则不会再看到后续日志")
                NSApplication.shared.windows.first(where: { $0.isVisible })?.close()
                try? await Task.sleep(for: .seconds(3))
                log("关闭窗口后程序仍在运行（这条不该出现）")
            }
        }
    }
}

/// 开发调试用的本地瓦片服务脚本。
///
/// `EUCLID_DEBUG_TILE_SERVER=<端口>` 时启动后把当前数据集做成 HTTP 服务，便于无人值守核对。
@MainActor
enum DebugTileServerScript {
    static func runIfRequested(model: AppModel) {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_TILE_SERVER"],
              let port = Int(raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(9))
            let server = model.tileServer
            server.prepare(source: model.selectedDataset?.rootURL)
            server.port = port
            server.start()
            FileHandle.standardError.write(Data(
                "[server] 运行=\(server.isRunning) 端口=\(server.actualPort) 模板=\(server.urlTemplate)\n".utf8
            ))
        }
    }
}

/// 开发调试用的瓦片生成脚本。
///
/// `EUCLID_DEBUG_TILE_EXPORT="<输出目录>|<zmin>|<zmax>|<尺寸>|<jpg|png>[|<质量>]"` 时
/// 无人值守跑一次生成并把结果打到 stderr；`EUCLID_DEBUG_TILE_EXPORT_SHEET=1` 只打开面板，便于截图。
@MainActor
enum DebugTileExportScript {
    static var sheetRequested: Bool {
        ProcessInfo.processInfo.environment["EUCLID_DEBUG_TILE_EXPORT_SHEET"] != nil
    }

    static func runIfRequested(model: AppModel) {
        if sheetRequested {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                model.promptForTileExport()
            }
        }
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_TILE_EXPORT"] else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, let minimum = Int(parts[1]),
              let maximum = Int(parts[2]), let size = Int(parts[3]) else {
            FileHandle.standardError.write(Data("[tiles] 参数应为 输出目录|zmin|zmax|尺寸|格式[|质量]\n".utf8))
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            let export = model.tileExport
            export.prepare(source: model.selectedRaster, outputDirectory: URL(fileURLWithPath: parts[0]))
            export.minimumZoom = minimum
            export.maximumZoom = maximum
            export.tileSize = size
            export.format = parts[4].lowercased() == "png" ? .png : .jpeg
            if parts.count >= 6, let quality = Double(parts[5]) { export.quality = quality }
            export.onStatus = { message in
                FileHandle.standardError.write(Data(("[tiles] " + message + "\n").utf8))
            }
            export.start()
            while export.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
            let summary = export.summary
            let line = String(
                format: "[tiles] 结束：写出=%d 跳过=%d 失败=%d 字节=%d 用时=%.1fs 取消=%@\n",
                summary?.written ?? -1, summary?.skipped ?? -1, summary?.failed ?? -1,
                summary?.bytes ?? -1, summary?.elapsed ?? -1,
                (summary?.cancelled ?? true) ? "是" : "否"
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

/// 开发调试用的出图脚本。
///
/// `EUCLID_DEBUG_EXPORT_VIEW=<输出路径>` 时，启动十几秒后（数据范围与底图都安定下来）
/// 在无人值守的情况下走一遍「导出当前视图」的合成路径并把 PNG 写盘，
/// 用来核对成图里的数据源、中心坐标、层级与比例尺是不是对的。
/// 保存面板只在菜单那条路径上出现，这里调的是同一套合成代码。
@MainActor
enum DebugExportScript {
    static func runIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["EUCLID_DEBUG_EXPORT_VIEW"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            let url = URL(fileURLWithPath: path)
            guard let data = model.viewImageData() else {
                FileHandle.standardError.write(Data("[export] 当前没有可导出的画面\n".utf8))
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                let line = "[export] 已写出 \(path)（\(data.count) 字节，"
                    + "中心=\(model.viewport.center) z\(model.viewport.dataZoom)）\n"
                FileHandle.standardError.write(Data(line.utf8))
            } catch {
                FileHandle.standardError.write(Data("[export] 写盘失败：\(error)\n".utf8))
            }
        }
    }
}
