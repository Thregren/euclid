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
