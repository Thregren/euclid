import Foundation
import Observation
import TileKit

/// 地图工具。
enum MapTool: String, CaseIterable, Hashable, Sendable {
    case browse
    case point
    case distance
    case area
    case circle

    var measurementKind: MeasurementKind? {
        switch self {
        case .browse: return nil
        case .point: return .point
        case .distance: return .distance
        case .area: return .area
        case .circle: return .circle
        }
    }

    var title: String {
        switch self {
        case .browse: return "浏览"
        case .point: return "点坐标"
        case .distance: return "测距"
        case .area: return "测面积"
        case .circle: return "画圆"
        }
    }

    var symbolName: String {
        switch self {
        case .browse: return "hand.raised"
        case .point: return "scope"
        case .distance: return "ruler"
        case .area: return "skew"
        case .circle: return "circle"
        }
    }

    var shortcut: String {
        switch self {
        case .browse: return "V"
        case .point: return "C"
        case .distance: return "D"
        case .area: return "A"
        case .circle: return "O"
        }
    }

    /// 菜单里的快捷键（⌘1–⌘5）。
    var menuShortcut: String {
        "⌘\((MapTool.allCases.firstIndex(of: self) ?? 0) + 1)"
    }

    /// 一句话说明（不含快捷键）。
    var summary: String {
        switch self {
        case .browse: return "滚轮或捏合缩放，中键、左键拖动或双指滚动平移"
        case .point: return "点击取点并读取坐标"
        case .distance: return "点击加点，右键、双击或回车结束"
        case .area: return "点击加点，右键、双击或回车闭合"
        case .circle: return "先点圆心，再点一次确定半径；之后可拖动半径点或输入精确半径"
        }
    }

    /// 悬停提示与菜单说明：功能 + 快捷键 + 一句话说明。
    var help: String {
        "\(title)（\(shortcut) / \(menuShortcut)）：\(summary)"
    }

    /// 画布底部提示条文案（nil 表示不显示）。
    func hint(draftCount: Int) -> String? {
        switch self {
        case .browse:
            return "P 记下指针位置的点（与「点坐标」工具同一份数据）· 滚轮缩放 · 中键或拖动平移"
        case .point:
            return "点击地图取点，坐标显示在检查器中"
        case .distance:
            return draftCount == 0
                ? "点击开始测距，双击或回车结束"
                : "继续点击加点 · 双击/回车结束 · ⌫ 撤销 · Esc 取消 · 按住 Shift 约束方向"
        case .area:
            return draftCount == 0
                ? "点击开始测面积，闭合后双击或回车结束"
                : "继续点击加点 · 双击/回车闭合 · ⌫ 撤销 · Esc 取消 · 按住 Shift 约束方向"
        case .circle:
            return draftCount == 0
                ? "点击确定圆心，再点一次确定半径"
                : "移动指针预览半径，再点一次完成 · 完成后拖动半径点或输入精确半径 · Esc 取消"
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
    /// 新测量使用的默认样式；在检查器里改颜色时会同步更新。
    var pendingStyle: MeasurementStyle = .standard

    /// 橡皮筋预览用的指针位置。
    var liveCoordinate: GeoCoordinate?
    var cursorInfo: CursorInfo?

    private var colorCounter = 0
    /// 画圆的最小半径（米），用来滤掉「两次点击落在同一点」的误触。
    private let minimumCircleRadius = 0.2

    /// 状态存档与撤销用的快照。
    private struct Snapshot {
        var measurements: [GeoMeasurement]
        var draft: [GeoCoordinate]
        var draftKind: MeasurementKind
        var selectedID: UUID?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let undoLimit = 60
    /// 连续同类操作（拖滑块、连着改颜色）合并成一步撤销。
    private var lastUndoKey: String?
    private var lastUndoTime = Date.distantPast
    private let undoCoalesceWindow: TimeInterval = 1.5

    /// 每次状态变化后回调，用于触发存档。
    var onChange: (() -> Void)?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var draftResult: MeasurementResult {
        MeasurementCalculator.evaluate(kind: draftKind, points: draft)
    }

    var selectedMeasurement: GeoMeasurement? {
        measurements.first { $0.id == selectedID }
    }

    var hasContent: Bool {
        !draft.isEmpty || !measurements.isEmpty
    }

    /// 草稿圆的半径（米）：圆心与半径点都落下后才成立。
    var draftCircleRadius: Double? {
        guard draftKind == .circle, draft.count >= 2 else { return nil }
        return Geodesy.distance(from: draft[0], to: draft[1])
    }

    /// 草稿圆跟随指针的预览半径（米）。
    var draftLiveRadius: Double? {
        guard draftKind == .circle, draft.count == 1, let liveCoordinate else { return nil }
        return Geodesy.distance(from: draft[0], to: liveCoordinate)
    }

    // MARK: - 工具切换

    private func snapshot() -> Snapshot {
        Snapshot(measurements: measurements, draft: draft, draftKind: draftKind, selectedID: selectedID)
    }

    private func apply(_ snapshot: Snapshot) {
        measurements = snapshot.measurements
        draft = snapshot.draft
        draftKind = snapshot.draftKind
        selectedID = snapshot.selectedID
        liveCoordinate = nil
        onChange?()
    }

    /// 记录一次可撤销的状态，并清空重做栈。
    ///
    /// - Parameter coalescingKey: 同一个键在 1.5 秒内的连续调用只记一次，
    ///   避免拖动滑块时把撤销栈塞满。
    func markUndoPoint(coalescingKey: String? = nil) {
        let now = Date()
        if let key = coalescingKey,
           key == lastUndoKey,
           now.timeIntervalSince(lastUndoTime) < undoCoalesceWindow {
            lastUndoTime = now
            redoStack.removeAll()
            return
        }
        undoStack.append(snapshot())
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        lastUndoKey = coalescingKey
        lastUndoTime = now
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(next)
    }

    /// 用存档内容替换当前测量（不进入撤销栈）。
    func restore(_ measurements: [GeoMeasurement]) {
        self.measurements = measurements
        draft.removeAll()
        selectedID = measurements.last?.id
        liveCoordinate = nil
        // 让后续新建的测量接着调色板往下取色。
        colorCounter = measurements.count
        undoStack.removeAll()
        redoStack.removeAll()
        lastUndoKey = nil
    }

    private func switchTool(from oldValue: MapTool) {
        if oldValue.measurementKind != nil {
            finishDraft()
        }
        liveCoordinate = nil
    }

    // MARK: - 草稿操作

    /// 快捷键落点：把指针当前位置记成一个点，不必先切到「点坐标」工具。
    ///
    /// 落的点与「点坐标」工具落下的**是同一种测量**（`kind == .point`，进同一个数组、同一套
    /// 存档与导出），因此不存在「快捷键记的点」和「画出来的点」两套数据。
    @discardableResult
    func dropPoint(at coordinate: GeoCoordinate) -> GeoMeasurement {
        markUndoPoint()
        let measurement = GeoMeasurement(
            kind: .point,
            points: [coordinate],
            colorIndex: nextColorIndex(),
            style: pendingStyle
        )
        measurements.append(measurement)
        selectedID = measurement.id
        onChange?()
        return measurement
    }

    func addPoint(_ coordinate: GeoCoordinate) {
        guard let kind = tool.measurementKind else { return }
        // 画圆的第二次点击若几乎落在圆心上，视为误触，不生成极小的圆。
        if kind == .circle, draftKind == .circle, draft.count == 1,
           Geodesy.distance(from: draft[0], to: coordinate) < minimumCircleRadius {
            return
        }
        markUndoPoint()
        if kind == .point {
            let measurement = GeoMeasurement(
                kind: .point,
                points: [coordinate],
                colorIndex: nextColorIndex(),
                style: pendingStyle
            )
            measurements.append(measurement)
            selectedID = measurement.id
            onChange?()
            return
        }
        if kind == .circle {
            // 已经点过圆心和半径点的草稿先收尾（半径可能是输入的），
            // 这次点击就作为下一个圆的圆心。
            if draftKind == .circle, draft.count >= 2 {
                finishDraft()
            }
            if draftKind != .circle {
                draft.removeAll()
                draftKind = .circle
            }
            draft.append(coordinate)
            selectedID = nil
            if draft.count >= 2 {
                finishDraft()
                return
            }
            onChange?()
            return
        }
        if draftKind != kind {
            draft.removeAll()
            draftKind = kind
        }
        draft.append(coordinate)
        selectedID = nil
        onChange?()
    }

    func removeLastDraftPoint() {
        guard !draft.isEmpty else { return }
        markUndoPoint()
        draft.removeLast()
        onChange?()
    }

    func cancelDraft() {
        guard !draft.isEmpty else { return }
        markUndoPoint()
        draft.removeAll()
        liveCoordinate = nil
        onChange?()
    }

    @discardableResult
    func finishDraft() -> GeoMeasurement? {
        defer {
            draft.removeAll()
            liveCoordinate = nil
        }
        let minimumPoints = draftKind == .area ? 3 : 2
        guard draft.count >= minimumPoints else { return nil }
        markUndoPoint()
        let measurement = GeoMeasurement(
            kind: draftKind,
            points: draft,
            colorIndex: nextColorIndex(),
            style: pendingStyle
        )
        measurements.append(measurement)
        selectedID = measurement.id
        onChange?()
        return measurement
    }

    // MARK: - 样式

    /// 修改某条测量的样式（描边/填充颜色、填充不透明度、线宽）。
    func updateStyle(of id: UUID, _ transform: (inout MeasurementStyle) -> Void) {
        guard let index = measurements.firstIndex(where: { $0.id == id }) else { return }
        markUndoPoint(coalescingKey: "style-\(id.uuidString)")
        var style = measurements[index].style
        transform(&style)
        let sanitized = style.sanitized()
        measurements[index].style = sanitized
        // 后续新画的测量沿用最近一次调好的样式。
        pendingStyle = sanitized
        onChange?()
    }

    /// 把某个样式套用到全部测量。
    func applyStyleToAll(_ style: MeasurementStyle) {
        guard !measurements.isEmpty else { return }
        markUndoPoint()
        let sanitized = style.sanitized()
        for index in measurements.indices {
            measurements[index].style = sanitized
        }
        pendingStyle = sanitized
        onChange?()
    }

    /// 恢复某条测量的默认样式。
    func resetStyle(of id: UUID) {
        updateStyle(of: id) { $0 = .standard }
    }

    // MARK: - 半径

    /// 输入精确半径：保持方位角不变，把半径点挪到指定的测地距离上。
    func setCircleRadius(_ meters: Double, of id: UUID) {
        guard meters > 0, meters.isFinite,
              let index = measurements.firstIndex(where: { $0.id == id }) else { return }
        let measurement = measurements[index]
        guard measurement.kind == .circle,
              let center = measurement.circleCenter else { return }
        let bearing = measurement.points.count >= 2
            ? Geodesy.inverse(from: center, to: measurement.points[1]).initialBearing
            : 0
        let rim = Geodesy.destination(from: center, initialBearing: bearing, distance: meters)
        markUndoPoint(coalescingKey: "radius-\(id.uuidString)")
        measurements[index].points = [center, rim]
        onChange?()
    }

    /// 输入草稿圆的半径（用于「先点圆心再输入半径」的用法）。
    func setDraftCircleRadius(_ meters: Double) {
        guard meters > 0, meters.isFinite, draftKind == .circle, let center = draft.first else { return }
        markUndoPoint(coalescingKey: "draft-radius")
        if draft.count < 2 {
            draft.append(center)
        }
        let bearing = Geodesy.inverse(from: center, to: draft[1]).initialBearing
        draft[1] = Geodesy.destination(from: center, initialBearing: bearing, distance: meters)
        onChange?()
    }

    // MARK: - 已完成的测量

    func delete(_ id: UUID) {
        guard measurements.contains(where: { $0.id == id }) else { return }
        markUndoPoint()
        measurements.removeAll { $0.id == id }
        if selectedID == id { selectedID = measurements.last?.id }
        onChange?()
    }

    /// 直接加入一条已完成的测量（供导入或演示使用）。
    func addFinished(_ measurement: GeoMeasurement, select: Bool = true) {
        markUndoPoint()
        measurements.append(measurement)
        if select { selectedID = measurement.id }
        onChange?()
    }

    /// 追加一组外来测量（从文件载入时用），保留现有内容。
    func merge(_ incoming: [GeoMeasurement]) {
        guard !incoming.isEmpty else { return }
        markUndoPoint()
        measurements.append(contentsOf: incoming)
        selectedID = incoming.last?.id
        colorCounter += incoming.count
        onChange?()
    }

    func clearAll() {
        guard hasContent else { return }
        markUndoPoint()
        draft.removeAll()
        measurements.removeAll()
        selectedID = nil
        liveCoordinate = nil
        onChange?()
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
        onChange?()
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
