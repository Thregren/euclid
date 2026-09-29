import AppKit
import Foundation
import SwiftUI
import TileKit

/// 开发调试用的示例数据。
///
/// 仅当环境变量 `EUCLID_DEMO_MEASUREMENT` 存在时才会生成，用于截图核对与人工回归；
/// 正式使用不会触发任何逻辑。
@MainActor
enum DebugFixtures {
    /// 是否启用调试示例数据。读一次留成常量：这个判断每次测量变化都会被问到
    /// （见 `AppModel.scheduleArchiveSave`），而环境字典每读一次都要重拼（约 29 µs）。
    static let isEnabled = ProcessInfo.processInfo.environment["EUCLID_DEMO_MEASUREMENT"] != nil

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

/// 开发调试用的全屏脚本。
///
/// `EUCLID_DEBUG_FULLSCREEN=<秒>` 时，启动后第 N 秒切一次全屏，并在切换前后各打一遍
/// 画布 / 窗口 / 图层几何到 stderr；用来复现「进全屏后画面变灰」这类只和窗口状态有关的缺陷。
/// 正式使用不会触发。
@MainActor
enum DebugFullscreenScript {
    static func runIfRequested(canvas: CanvasController) {
        guard let raw = ProcessInfo.processInfo.environment["EUCLID_DEBUG_FULLSCREEN"],
              let delay = Double(raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // 视图可能还没挂上窗口（启动时脚本跑得早）：每 0.5 秒看一次，最多等 10 秒。
            for _ in 0..<20 where !canvas.debugHasWindow {
                try? await Task.sleep(for: .seconds(0.5))
            }
            guard canvas.debugHasWindow else {
                FileHandle.standardError.write(Data("[geom] 画布没有窗口，全屏脚本跳过\n".utf8))
                return
            }
            // 系统会恢复上次退出时的全屏状态：先从全屏退出来，保证复现的是「窗口 → 全屏」这条路。
            if canvas.debugIsFullscreen {
                canvas.debugToggleFullscreen()
                try? await Task.sleep(for: .seconds(4))
                // 窗口态的「适应窗口」会把相机放到这一档的缩放下限上，正是用户平时的起点。
                canvas.fit()
                try? await Task.sleep(for: .seconds(2))
                canvas.debugDumpGeometry("退回窗口后")
            }
            canvas.debugDumpGeometry("全屏前")
            canvas.debugToggleFullscreen()
            // 三次采样：切换动画刚结束、稳定后、以及再等一会儿，看画面会不会自己回来。
            try? await Task.sleep(for: .seconds(2))
            canvas.debugDumpGeometry("全屏后 2 秒")
            try? await Task.sleep(for: .seconds(3))
            canvas.debugDumpGeometry("全屏后 5 秒")
            try? await Task.sleep(for: .seconds(4))
            canvas.debugDumpGeometry("全屏后 9 秒")
        }
    }
}

