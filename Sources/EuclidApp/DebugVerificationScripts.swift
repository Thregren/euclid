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
