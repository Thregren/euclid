import AppKit
import Foundation
import SwiftUI
import TileKit

/// 开发调试用的「核对与出图」脚本：整窗截图、内存摘要、自检、本地瓦片服务、瓦片生成与导出。
///
/// 从 `DebugFixtures.swift` 拆出来的纯搬移。同样只在对应环境变量存在时生效，
/// 无人值守跑自检与回归时用；正式使用不会触发。

@MainActor
enum DebugWindowSnapshotScript {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["EUCLID_DEBUG_WINDOW_SNAPSHOT"] else { return }
        let times = (ProcessInfo.processInfo.environment["EUCLID_DEBUG_WINDOW_SNAPSHOT_AT"] ?? "10")
            .split(separator: ",")
            .compactMap { Double($0) }
            .sorted()
        Task { @MainActor in
            var elapsed = 0.0
            for (index, time) in times.enumerated() {
                let delay = max(0, time - elapsed)
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                elapsed = max(elapsed, time)
                let target = path.contains("%d") ? String(format: path, index + 1) : path
                write(to: URL(fileURLWithPath: target), label: "\(time)s")
            }
        }
    }

    /// 把一个视图渲染成 PNG 字节（整棵视图树，含 AppKit 与 SwiftUI 两侧）。
    static func pngData(of view: NSView) -> Data? {
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// 在视图树里找第一个指定类型的视图（调试输出用）。
    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private static func write(to url: URL, label: String) {
        func log(_ text: String) {
            FileHandle.standardError.write(Data(("[window] " + text + "\n").utf8))
        }
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
              let content = window.contentView else {
            log("\(label)：没有可见窗口")
            return
        }
        guard let data = pngData(of: content) else {
            log("\(label)：窗口内容渲染失败")
            return
        }
        // 画布底色与外观的落点（核对深浅色时最容易出错的就是这一对）：
        if let canvas = Self.find(TileCanvasNSView.self, in: content) {
            log("画布：\(canvas.debugAppearanceDescription)")
        }
        do {
            try data.write(to: url, options: .atomic)
            let size = "\(Int(content.bounds.width))×\(Int(content.bounds.height)) 点"
            log("\(label)：已写出 \(url.path)（\(size)，\(data.count) 字节）")
        } catch {
            log("\(label)：写盘失败 \(error.localizedDescription)")
        }
    }
}

/// 开发调试用的自检脚本：一次跑完「快捷键落点 / 快速导出 / 测量存档读写」。
///
/// `EUCLID_DEBUG_VERIFY=1` 时启动十几秒后依次执行并把结果打到 stderr。
/// 只用于无人值守核对，正式使用不设置该变量。
///
/// 内存与句柄观察：`EUCLID_DEBUG_MEMORY=1` 时每 5 秒打一行
/// 「内存占用 / 打开的文件描述符数 / 各层瓦片缓存」，用来确认长时间浏览不涨。
/// （句柄那一项是给「瓦片用 `mappedIfSafe` 读」这条路径做的保险：映射文件会占着 fd。）
@MainActor
enum DebugMemoryScript {
    static func runIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.environment["EUCLID_DEBUG_MEMORY"] != nil else { return }
        let interval = Double(ProcessInfo.processInfo.environment["EUCLID_DEBUG_MEMORY_SECONDS"] ?? "") ?? 5
        Task { @MainActor in
            while !Task.isCancelled {
                let footprint = Self.footprintMegabytes()
                let descriptors = Self.openFileDescriptorCount()
                let caches = await model.canvas.cacheSummary()
                let line = String(
                    format: "[mem] %.0f MB · fd %d · 测量 %d 条 · %@\n",
                    footprint, descriptors, model.measurements.measurements.count, caches
                )
                FileHandle.standardError.write(Data(line.utf8))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 进程的物理内存占用（macOS 上就是活动监视器里的那个「内存」）。
    private static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// 打开的文件描述符数量（`lsof` 的进程内版本，不需要额外权限）。
    private static func openFileDescriptorCount() -> Int {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return -1 }
        return Int(size) / MemoryLayout<proc_fdinfo>.size
    }
}

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
            // 这个脚本会故意落点、清空、再读回：结束时必须证明它**没碰**用户的自动存档
            // （`AppModel.isAutomatedRun` 那道守卫）。以前只顾着声明守卫、忘了接到写盘口上，
            // 结果自检真的把用户的存档覆盖过一次，所以这里留一条常驻断言。
            let archiveBefore = Self.archiveStamp()

            // 1) 快捷键落点（与「点坐标」同一份数据）
            let before = model.measurements.measurements.count
            model.dropPointAtCursor()
            model.dropPointAtCursor()
            let points = model.measurements.measurements.filter { $0.kind == .point }
            log("落点：测量 \(before) → \(model.measurements.measurements.count)，其中 point 类 \(points.count) 条，"
                + "点坐标 \(points.last?.points.first.map { String(format: "%.5f, %.5f", $0.longitude, $0.latitude) } ?? "无")")

            // 2) 测量存档读写（同一个文件：写进去再读回来）
            let file = URL(fileURLWithPath: "/tmp/euclid-verify-measurements.json")
            _ = await model.writeMeasurements(to: file)
            let written = model.measurements.measurements.count
            model.clearMeasurements()
            let loaded = await model.loadMeasurements(from: file) ?? -1
            log("存档：写出 \(written) 条 → 清空 → 读回 \(loaded) 条（应相等）")

            // 3) 快速导出（不弹面板，直接落到快捷导出目录）
            model.quickExportView()
            // 出图现在是异步的（PNG 编码在后台），等一下再看结果状态。
            var exportStatus = model.statusMessage ?? "无"
            var waited = 0
            while exportStatus.contains("正在出图"), waited < 40 {
                try? await Task.sleep(for: .milliseconds(100))
                exportStatus = model.statusMessage ?? "无"
                waited += 1
            }
            log("快速导出：状态=「\(exportStatus)」")

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

            let archiveAfter = Self.archiveStamp()
            let guardHeld = archiveBefore == archiveAfter
            log("自动存档守卫：\(archiveBefore) → \(archiveAfter)"
                + (guardHeld ? "（未被自动化运行改动 ✓）" : "（✗ 被自动化运行改动了）"))
            if let isolated = Self.isolatedArchiveStamp() {
                log("  ↳ 隔离存档（EUCLID_DEBUG_ARCHIVE_PATH）：\(isolated)"
                    + "（有写入 = 写盘这条路验过 ✓）")
            }

            // 5) 关窗是否退出（设置了 EUCLID_DEBUG_VERIFY_CLOSE 时）
            if ProcessInfo.processInfo.environment["EUCLID_DEBUG_VERIFY_CLOSE"] != nil {
                log("即将关闭主窗口，若程序正常退出则不会再看到后续日志")
                NSApplication.shared.windows.first(where: { $0.isVisible })?.close()
                try? await Task.sleep(for: .seconds(3))
                log("关闭窗口后程序仍在运行（这条不该出现）")
            }
        }
    }

    /// 某个存档文件的「大小 + 修改时间」。
    private static func stamp(of url: URL?) -> String {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return "无存档"
        }
        let modified = values.contentModificationDate.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "?"
        return "\(values.fileSize ?? -1) 字节 @\(modified)"
    }

    /// 守卫核对用：比的是**用户真正的存档**（不受 `EUCLID_DEBUG_ARCHIVE_PATH` 覆盖影响），
    /// 所以「隔离路径 + 显式允许写入」那种验证写盘的模式下，这条断言同样是有效的。
    private static func archiveStamp() -> String {
        stamp(of: MeasurementArchive.userArchiveFileURL)
    }

    /// 隔离存档（覆盖路径）的「大小 + 修改时间」：用来证明「写盘这条路还通」。
    private static func isolatedArchiveStamp() -> String? {
        guard MeasurementArchive.overrideFileURL != nil else { return nil }
        return stamp(of: MeasurementArchive.overrideFileURL)
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
            await server.start()
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
            guard let data = await model.viewImageData() else {
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

/// 开发调试用的 DEM 工具箱脚本。
///
/// `EUCLID_DEBUG_ANALYSIS=1` 时，等数据安定后依次走一遍「点高程 / 坡度 / 土方量」，
/// 把结果打到 stderr，用来在无人值守的情况下核对整条分析链路；
/// `EUCLID_DEBUG_ANALYSIS_SHEET=1` 只把面板打开（配合整窗截图核对界面）。
@MainActor
enum DebugAnalysisScript {
    static func runIfRequested(model: AppModel) {
        if ProcessInfo.processInfo.environment["EUCLID_DEBUG_ANALYSIS_SHEET"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                model.showAnalysisSheet = true
            }
        }
        guard ProcessInfo.processInfo.environment["EUCLID_DEBUG_ANALYSIS"] != nil else { return }
        Task { @MainActor in
            func log(_ text: String) {
                FileHandle.standardError.write(Data(("[analysis] " + text + "\n").utf8))
            }
            try? await Task.sleep(for: .seconds(10))
            guard let reader = model.analysisReader, let raster = model.analysisRaster else {
                log("没有可分析的影像")
                return
            }
            log("影像 \(raster.fileURL.lastPathComponent) \(reader.pixelWidth)×\(reader.pixelHeight) "
                + "波段=\(reader.bandCount) 高程类=\(reader.isElevationLike)")

            let reference = reader.georeference
            let center = reference.coordinate(
                column: Double(reader.pixelWidth) / 2,
                row: Double(reader.pixelHeight) / 2
            )
            if let center {
                let value = model.elevationReading(at: center)
                log("点高程(中心)=\(value.map { String(format: "%.3f", $0) } ?? "—")")
            }

            model.addSlopeLayer(scope: .whole)
            while model.analysis.isWorking { try? await Task.sleep(for: .milliseconds(100)) }
            if let statistics = model.analysis.slopeStatistics, !statistics.isEmpty {
                log(String(format: "坡度 平均=%.2f° 最大=%.2f° 最小=%.2f° 采样点=%d",
                           statistics.mean, statistics.maximum, statistics.minimum, statistics.validCount))
            } else {
                log("坡度：没有结果")
            }

            let corners = [
                (0.0, 0.0),
                (Double(reader.pixelWidth), 0.0),
                (Double(reader.pixelWidth), Double(reader.pixelHeight)),
                (0.0, Double(reader.pixelHeight)),
            ].compactMap { reference.coordinate(column: $0.0, row: $0.1) }
            if corners.count == 4 {
                model.analysis.baseElevationText = "0"
                let bounds = GeoBounds(
                    west: corners.map(\.longitude).min() ?? 0,
                    south: corners.map(\.latitude).min() ?? 0,
                    east: corners.map(\.longitude).max() ?? 0,
                    north: corners.map(\.latitude).max() ?? 0
                )
                model.calculateVolume(over: bounds)
                while model.analysis.isWorking { try? await Task.sleep(for: .milliseconds(100)) }
                if let volume = model.analysis.volume {
                    log("土方量 挖=\(AppModel.volumeText(volume.cutVolume)) "
                        + "填=\(AppModel.volumeText(volume.fillVolume)) "
                        + "面积=\(String(format: "%.0f m²", volume.sampledArea)) "
                        + "格=\(volume.sampledCells)")
                } else {
                    log("土方量：没有结果")
                }
            }
            log("结束")
        }
    }
}

/// 开发调试用的标签页脚本。
///
/// `EUCLID_DEBUG_TABS=1` 时在数据安定后走一遍「加页 → 在新页开另一份数据 → 切回」，
/// 把每一页的图层数 / 测量数打到 stderr，用来核对「切页确实换了状态、切回来又还回来」。
@MainActor
enum DebugTabsScript {
    static func runIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.environment["EUCLID_DEBUG_TABS"] != nil else { return }
        Task { @MainActor in
            func log(_ text: String) {
                FileHandle.standardError.write(Data(("[tabs] " + text + "\n").utf8))
            }
            try? await Task.sleep(for: .seconds(12))
            model.ensureWorkspaceTabs()
            guard let firstTabID = model.activeWorkspaceTabID else {
                log("没有活动标签页")
                return
            }
            let firstSource = model.selectedSourceID

            // 在第一页放一条测量，用来验证「切回来测量还在」。
            if let extent = model.extent {
                let center = WebMercator.coordinate(
                    fromNormalized: CGPoint(x: extent.worldRect.midX, y: extent.worldRect.midY)
                )
                model.measurements.dropPoint(at: center)
            }
            log("第一页：来源=\(firstSource ?? "无") 层=\(model.layers.count) "
                + "测量=\(model.measurements.measurements.count) 标题=\(model.workspaceTabs.first?.title ?? "-")")

            model.addWorkspaceTab()
            log("新页：页数=\(model.workspaceTabs.count) 层=\(model.layers.count) "
                + "测量=\(model.measurements.measurements.count) 来源=\(model.selectedSourceID ?? "无")")

            if let firstSource {
                model.open(URL(fileURLWithPath: firstSource))
                try? await Task.sleep(for: .seconds(6))
                log("新页打开数据后：层=\(model.layers.count) 标题=\(model.workspaceTabs.last?.title ?? "-")")
            }

            model.activateWorkspaceTab(firstTabID)
            try? await Task.sleep(for: .seconds(2))
            log("切回第一页：层=\(model.layers.count) 测量=\(model.measurements.measurements.count) "
                + "来源=\(model.selectedSourceID ?? "无")")
            log("结束")
        }
    }
}
