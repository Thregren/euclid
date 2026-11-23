import TileRendering
import AppKit
import ImageIO
import QuartzCore
import TileKit

/// 画布的排错入口：图层树几何转储、重铺耗时统计、离屏截帧与缓存摘要。
///
/// 从 `TileCanvasNSView.swift` 拆出来的纯搬移。这些代码只在调试环境变量打开时才做事，
/// 平时一次判断就返回 —— 但混在视图本体里会把「装配」与「排错」两件事搅在一起，
/// 分开放以后，读视图本体的人不必先跳过这一屏 printf。
extension TileCanvasNSView {

    /// 调试用（`EUCLID_TRACE_LAYERS=1`）：每秒打一次图层树的关键几何，定位「有图却看不见」。
    /// （跨文件要用，故不是 `private`：装配代码在重铺后调它。）
    func dumpLayersIfRequested() {
        guard Self.tracesLayers, Date().timeIntervalSince(lastLayerDump) > 1 else { return }
        lastLayerDump = Date()
        var lines: [String] = []
        lines.append(String(
            format: "[layers-dump] 画布=%.0fx%.0f 相机中心=(%.5f,%.5f) z=%.2f 每世界单位=%.0fpt 视口=(%.0fx%.0f) 背景层=%@",
            bounds.width, bounds.height, camera.center.x, camera.center.y,
            camera.zoomLevel, camera.pixelsPerWorldUnit,
            camera.viewportSize.width, camera.viewportSize.height,
            backgroundLayer.isHidden ? "隐藏" : "显示"
        ))
        for (id, stack) in stacks {
            let tiles = stack.debugTileLayerSummary()
            lines.append(
                "[layers-dump] 层 \(id.prefix(6)) \(stack.name) 装配=\(stack.isActive ? "是" : "否")"
                    + " 隐藏=\(stack.hostLayer.isHidden ? "是" : "否")"
                    + " 不透明=\(String(format: "%.2f", stack.hostLayer.opacity))"
                    + " 父层=\(stack.hostLayer.superlayer != nil ? "有" : "无")"
                    + " frame=\(Self.describe(stack.hostLayer.frame))"
                    + " 网格=\(stack.grid.kind.rawValue)"
                    + " 瓦片数=\(tiles.count) 有图=\(tiles.withImage)"
                    + " x=\(Self.describe(tiles.xRange)) y=\(Self.describe(tiles.yRange))"
                    + " 尺寸=\(Self.describe(tiles.sizeRange))"
            )
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func describe(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "无" }
        return String(format: "%.0f…%.0f", range.lowerBound, range.upperBound)
    }

    private static func describe(_ range: ClosedRange<CGFloat>?) -> String {
        guard let range else { return "无" }
        return String(format: "%.0f…%.0f", range.lowerBound, range.upperBound)
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    /// 调试用（`EUCLID_TRACE_LAYERS=1`）：记一次会改变画布几何的事件。
    ///
    /// 「打开数据后全灰」这类缺陷的现场全在窗口几何上，而 `syncLayers()` 只会在需要重铺时
    /// 被调用 —— 光看有没有重铺日志，分不清「AppKit 没来 `layout()`」还是「来了但没铺上」。
    /// 这里在每一次几何事件上无条件留一行，答案就唯一了。
    /// （跨文件要用，故不是 `private`：`layout()` 等几何事件在视图本体里调它。）
    func traceGeometryEvent(_ event: String) {
        guard Self.tracesLayers else { return }
        NSLog("[geom-event] %@ 视图 %@ bounds=%@ 窗口=%@ 全屏=%@",
              event, Self.describe(frame), Self.describe(bounds),
              window.map { Self.describe($0.frame) } ?? "无",
              window?.styleMask.contains(.fullScreen) == true ? "是" : "否")
    }

    /// 调试用：把画布、窗口与各图层栈的几何整体打一遍（`EUCLID_DEBUG_FULLSCREEN` 脚本会调）。
    func debugDumpGeometry(_ tag: String) {
        let windowText: String
        if let window {
            windowText = String(
                format: "窗口=%@ 全屏=%@ 缩放=%.1f",
                Self.describe(window.frame),
                window.styleMask.contains(.fullScreen) ? "是" : "否",
                Double(window.backingScaleFactor)
            )
        } else {
            windowText = "窗口=无"
        }
        var lines = [String]()
        lines.append(String(
            format: "[geom] %@ 视图=%@ bounds=%@ %@ 底色层=%@",
            tag, Self.describe(frame), Self.describe(bounds), windowText,
            Self.describe(backgroundLayer.frame)
        ))
        for (id, stack) in stacks {
            let tiles = stack.debugTileLayerSummary()
            lines.append(String(
                format: "[geom] %@ 层 %@ %@ 父层=%@ frame=%@ 有图=%d/%d z=%.2f 视口=%.0fx%.0f",
                tag, String(id.prefix(6)), stack.name,
                stack.hostLayer.superlayer != nil ? "有" : "无",
                Self.describe(stack.hostLayer.frame),
                tiles.withImage, tiles.count, camera.zoomLevel,
                camera.viewportSize.width, camera.viewportSize.height
            ))
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// 调试用：`EUCLID_TRACE_VIEW=1` 时把每次渲染的关键数字打到 stderr。
    static func traceView(layer: TileLayerFrame, camera: MapCamera, zoomBounds: ClosedRange<Double>) {
        guard tracesView else { return }
        var line = String(
            format: "[view] %@ z=%.2f 层级=%d 范围=%.2f…%.2f 需要=%d 已载入=%d 祖先兜底=%d 缺片=%d 瓦片边长=%.0fpt 中心=(%.5f,%.5f)",
            layer.name, camera.zoomLevel, layer.zoom,
            zoomBounds.lowerBound, zoomBounds.upperBound,
            layer.needed, layer.loaded, layer.fallback, layer.missing,
            layer.tileDisplaySize, camera.center.x, camera.center.y
        )
        if layer.datumOffsetMeters != .zero {
            line += String(
                format: " 基准偏移=(东 %.0fm, 北 %.0fm)",
                layer.datumOffsetMeters.x, layer.datumOffsetMeters.y
            )
        }
        line += "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    func writeDebugSnapshot(index: Int) {
        guard let directory = Self.debugSnapshotDirectory else { return }
        guard let image = renderMapImage() else { return }
        let url = URL(fileURLWithPath: directory)
            .appending(path: String(format: "frame-%02d.png", index))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// 调试用：各层缓存条数 + 标注重绘的图层池大小（`EUCLID_DEBUG_MEMORY=1` 会定期打出来）。
    func debugCacheSummary() async -> String {
        var parts: [String] = []
        for (id, stack) in stacks {
            let stats = await stack.cacheStats()
            let tiles = stats?.tiles ?? 0
            let megabytes = Double(stats?.bytes ?? 0) / 1_048_576
            parts.append("\(id.prefix(8))… \(tiles) 片/\(String(format: "%.1f", megabytes)) MB")
        }
        // 影像解码的块缓存也报一行，方便确认它没在涨。
        parts.append(RasterCache.debugSummary())
        return parts.joined(separator: " · ")
    }
}
