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
