import AppKit
import Foundation
import TileKit

/// 巡检图集的条目：一张图 + 它的标题与说明。
private struct AtlasEntry: Sendable {
    var fileName: String
    var title: String
    var detail: String
    var pixelWidth: Int
    var pixelHeight: Int
}

extension AppModel {
    /// 批量出图：把书签视点（以及每条测量）逐张渲染成带信息栏的 PNG，
    /// 再写一份 `index.html` 索引页，整个目录可以直接发给别人看。
    ///
    /// 之所以复用「快照 → 后台合成」那条链路：出图本身要跳视点、等瓦片到位，
    /// 只能一张一张来；但光栅化与编码都不在主线程序列上，导出期间界面照样能用。
    func exportInspectionAtlas() {
        guard hasMapContent else {
            setStatus("当前没有可导出的画面")
            return
        }
        let bookmarks = bookmarks.items
        let measurements = measurements.measurements
        guard !bookmarks.isEmpty || !measurements.isEmpty else {
            setStatus("先记几个书签（或画几条测量），图集才有内容")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出图集"
        panel.message = "选择图集输出目录（会写入若干 PNG 与一份 index.html）"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let total = bookmarks.count + measurements.count
        setStatus("正在导出巡检图集（0/\(total)）…", autoClearAfter: 0)
        atlasTask?.cancel()
        atlasTask = Task { @MainActor [weak self] in
            await self?.runAtlasExport(to: directory, bookmarks: bookmarks, measurements: measurements)
        }
    }

    private func runAtlasExport(
        to directory: URL,
        bookmarks: [ViewBookmark],
        measurements: [GeoMeasurement]
    ) async {
        var entries: [AtlasEntry] = []
        let total = bookmarks.count + measurements.count

        func write(_ data: Data, named name: String) -> Bool {
            let url = directory.appending(path: name)
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            setStatus("导出失败：\(error.localizedDescription)", autoClearAfter: 8)
            return
        }

        var failureCount = 0
        for (index, bookmark) in bookmarks.enumerated() {
            if Task.isCancelled { break }
            canvas.jump(to: bookmark.center, zoomLevel: bookmark.zoomLevel)
            guard let data = await renderedViewData() else {
                failureCount += 1
                continue
            }
            let name = String(format: "%02d-%@.png", index + 1, Self.fileSafeName(bookmark.displayName))
            if write(data, named: name) {
                entries.append(AtlasEntry(
                    fileName: name,
                    title: bookmark.displayName,
                    detail: bookmark.detail,
                    pixelWidth: 0,
                    pixelHeight: 0
                ))
            } else {
                failureCount += 1
            }
            setStatus("正在导出巡检图集（\(entries.count)/\(total)）…", autoClearAfter: 0)
        }

        for (index, measurement) in measurements.enumerated() {
            if Task.isCancelled { break }
            zoomToMeasurement(measurement)
            guard let data = await renderedViewData() else {
                failureCount += 1
                continue
            }
            let title = measurement.exportName
            let name = String(format: "M%02d-%@.png", index + 1, Self.fileSafeName(title))
            if write(data, named: name) {
                entries.append(AtlasEntry(
                    fileName: name,
                    title: "测量 \(index + 1)：\(title)",
                    detail: measurement.note ?? measurement.kind.displayName,
                    pixelWidth: 0,
                    pixelHeight: 0
                ))
            } else {
                failureCount += 1
            }
            setStatus("正在导出巡检图集（\(entries.count)/\(total)）…", autoClearAfter: 0)
        }

        guard !entries.isEmpty else {
            setStatus("导出失败：一张图都没出成（画面可能还没渲染好）", autoClearAfter: 8)
            return
        }

        let indexHTML = Self.atlasIndexHTML(
            entries: entries,
            datasetName: selectedSourceName ?? basemapName,
            exportedAt: Date()
        )
        _ = write(Data(indexHTML.utf8), named: "index.html")

        var summary = "巡检图集已导出 \(entries.count) 张到「\(directory.lastPathComponent)」"
        if failureCount > 0 { summary += "（\(failureCount) 张失败）" }
        setStatus(summary, autoClearAfter: 8)
        lastAtlasDirectory = directory
    }

    /// 当前视点渲染成一张带信息栏的 PNG（在后台线程合成与编码）。
    private func renderedViewData() async -> Data? {
        // 每个视点都等一小会儿：瓦片是异步取回来的，立刻出图多半是半张空白。
        try? await Task.sleep(for: Self.atlasSettleDelay)
        guard let snapshot = canvas.mapSnapshot(), let info = viewImageInfo else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ViewExporter.pngData(snapshot, info: info)
        }.value
    }

    /// 每个视点出图前等这么久（瓦片取回 + 铺图）。
    static let atlasSettleDelay = Duration.milliseconds(900)

    /// 文件名里去掉路径分隔符这类字符（数据集名字常常带斜杠与冒号）。
    static func fileSafeName(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(60))
        return limited.isEmpty ? "未命名" : limited
    }

    /// 索引页：不依赖网络（缩略图就是本地 PNG），双击就能挨个看。
    fileprivate static func atlasIndexHTML(
        entries: [AtlasEntry],
        datasetName: String,
        exportedAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let cards = entries.map { entry in
            """
                <figure>
                  <a href="\(escape(entry.fileName))"><img src="\(escape(entry.fileName))" alt="\(escape(entry.title))"></a>
                  <figcaption><strong>\(escape(entry.title))</strong><br><span>\(escape(entry.detail))</span></figcaption>
                </figure>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <title>巡检图集 · \(escape(datasetName))</title>
        <style>
        body{margin:0;padding:24px;background:#f6f7f9;color:#14161a;
        font:14px/1.6 -apple-system,system-ui,sans-serif}
        h1{font-size:20px;margin:0 0 4px}
        p.meta{color:#5f6368;margin:0 0 20px}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px}
        figure{margin:0;background:#fff;border-radius:10px;overflow:hidden;
        box-shadow:0 1px 3px rgba(0,0,0,.12)}
        figure img{display:block;width:100%;height:auto;background:#e8eaed}
        figcaption{padding:10px 12px;font-size:13px}
        figcaption span{color:#5f6368}
        a{color:inherit;text-decoration:none}
        </style></head>
        <body>
        <h1>巡检图集 · \(escape(datasetName))</h1>
        <p class="meta">共 \(entries.count) 张 · 导出于 \(escape(formatter.string(from: exportedAt)))</p>
        <div class="grid">
        \(cards)
        </div>
        </body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
