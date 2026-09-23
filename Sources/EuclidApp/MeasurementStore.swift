import Foundation
import Observation
import TileKit

/// 地图工具。
enum MapTool: String, CaseIterable, Hashable, Sendable {
    case browse
    case point
    case distance
    case area

    var measurementKind: MeasurementKind? {
        switch self {
        case .browse: return nil
        case .point: return .point
        case .distance: return .distance
        case .area: return .area
        }
    }

    var title: String {
        switch self {
        case .browse: return "浏览"
        case .point: return "点坐标"
        case .distance: return "测距"
        case .area: return "测面积"
        }
    }

    var symbolName: String {
        switch self {
        case .browse: return "hand.raised"
        case .point: return "scope"
        case .distance: return "ruler"
        case .area: return "skew"
        }
    }

    var shortcut: String {
        switch self {
        case .browse: return "V"
        case .point: return "C"
        case .distance: return "D"
        case .area: return "A"
        }
    }

    var help: String {
        switch self {
        case .browse: return "浏览（V）：拖动平移，滚轮缩放"
        case .point: return "点坐标（C）：点击取点并读取坐标"
        case .distance: return "测距（D）：点击加点，双击或回车结束"
        case .area: return "测面积（A）：点击加点，双击或回车闭合"
        }
    }
}

/// 指针所在的坐标信息。
struct CursorInfo: Sendable, Equatable {
    var coordinate: GeoCoordinate
    var zoom: Int
    var tileX: Int
    var tileY: Int
    var pixelX: Int
    var pixelY: Int
}

/// 测量工具的状态与结果。
@MainActor
@Observable
final class MeasurementStore {
    var tool: MapTool = .browse {
        didSet {
            guard tool != oldValue else { return }
            switchTool(from: oldValue)
        }
    }

    private(set) var draft: [GeoCoordinate] = []
    private(set) var draftKind: MeasurementKind = .distance
    private(set) var measurements: [GeoMeasurement] = []
    var selectedID: UUID?
    var showLabels = true
    /// 橡皮筋预览用的指针位置。
    var liveCoordinate: GeoCoordinate?
    var cursorInfo: CursorInfo?

    private var colorCounter = 0

    var draftResult: MeasurementResult {
        MeasurementCalculator.evaluate(kind: draftKind, points: draft)
    }

    var selectedMeasurement: GeoMeasurement? {
        measurements.first { $0.id == selectedID }
    }

    var hasContent: Bool {
        !draft.isEmpty || !measurements.isEmpty
    }

    // MARK: - 工具切换

    private func switchTool(from oldValue: MapTool) {
        if oldValue.measurementKind != nil {
            finishDraft()
        }
        liveCoordinate = nil
    }

    // MARK: - 草稿操作

    func addPoint(_ coordinate: GeoCoordinate) {
        guard let kind = tool.measurementKind else { return }
        if kind == .point {
            let measurement = GeoMeasurement(kind: .point, points: [coordinate], colorIndex: nextColorIndex())
            measurements.append(measurement)
            selectedID = measurement.id
            return
        }
        if draftKind != kind {
            draft.removeAll()
            draftKind = kind
        }
        draft.append(coordinate)
        selectedID = nil
    }

    func removeLastDraftPoint() {
        guard !draft.isEmpty else { return }
        draft.removeLast()
    }

    func cancelDraft() {
        draft.removeAll()
        liveCoordinate = nil
    }

    @discardableResult
    func finishDraft() -> GeoMeasurement? {
        defer {
            draft.removeAll()
            liveCoordinate = nil
        }
        let minimumPoints = draftKind == .area ? 3 : 2
        guard draft.count >= minimumPoints else { return nil }
        let measurement = GeoMeasurement(kind: draftKind, points: draft, colorIndex: nextColorIndex())
        measurements.append(measurement)
        selectedID = measurement.id
        return measurement
    }

    // MARK: - 已完成的测量

    func delete(_ id: UUID) {
        measurements.removeAll { $0.id == id }
        if selectedID == id { selectedID = measurements.last?.id }
    }

    /// 直接加入一条已完成的测量（供导入或演示使用）。
    func addFinished(_ measurement: GeoMeasurement, select: Bool = true) {
        measurements.append(measurement)
        if select { selectedID = measurement.id }
    }

    func clearAll() {
        draft.removeAll()
        measurements.removeAll()
        selectedID = nil
        liveCoordinate = nil
    }

    func moveVertex(measurementID: UUID?, index: Int, to coordinate: GeoCoordinate) {
        if let measurementID {
            guard let position = measurements.firstIndex(where: { $0.id == measurementID }),
                  measurements[position].points.indices.contains(index) else { return }
            measurements[position].points[index] = coordinate
        } else {
            guard draft.indices.contains(index) else { return }
            draft[index] = coordinate
        }
    }

    /// 顶点坐标，用于吸附与拖动命中。
    func vertex(at index: Int, measurementID: UUID?) -> GeoCoordinate? {
        if let measurementID {
            guard let measurement = measurements.first(where: { $0.id == measurementID }),
                  measurement.points.indices.contains(index) else { return nil }
            return measurement.points[index]
        }
        return draft.indices.contains(index) ? draft[index] : nil
    }

    /// 所有可吸附的顶点。
    var allVertices: [(measurementID: UUID?, index: Int, coordinate: GeoCoordinate)] {
        var result: [(UUID?, Int, GeoCoordinate)] = []
        for measurement in measurements {
            for (index, coordinate) in measurement.points.enumerated() {
                result.append((measurement.id, index, coordinate))
            }
        }
        for (index, coordinate) in draft.enumerated() {
            result.append((nil, index, coordinate))
        }
        return result
    }

    private func nextColorIndex() -> Int {
        defer { colorCounter += 1 }
        return colorCounter % MeasurementPalette.count
    }
}
