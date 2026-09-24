import CoreGraphics
import Foundation
import TileKit

// 本机没有 XCTest（未安装 Xcode），因此用一个自带断言的最小校验程序。

var checkCount = 0
var failureCount = 0

@MainActor
func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("  ✗ \(message)  (main.swift:\(line))")
    }
}

@MainActor
func expectClose(_ lhs: Double, _ rhs: Double, accuracy: Double, _ message: String, line: UInt = #line) {
    checkCount += 1
    if abs(lhs - rhs) > accuracy {
        failureCount += 1
        print("  ✗ \(message)：期望 \(rhs)，实际 \(lhs)  (main.swift:\(line))")
    }
}

func section(_ title: String) {
    print("\n▸ \(title)")
}

// MARK: - 投影

section("Web Mercator 投影")
for coordinate in [
    GeoCoordinate(longitude: 0, latitude: 0),
    GeoCoordinate(longitude: 10, latitude: 45),
    GeoCoordinate(longitude: -70.6693, latitude: -33.4489),
    GeoCoordinate(longitude: -122.4194, latitude: 37.7749),
    GeoCoordinate(longitude: 139.6917, latitude: 35.6895),
] {
    let normalized = WebMercator.normalized(coordinate)
    let restored = WebMercator.coordinate(fromNormalized: normalized)
    expectClose(restored.longitude, coordinate.longitude, accuracy: 1e-9, "经度往返")
    expectClose(restored.latitude, coordinate.latitude, accuracy: 1e-9, "纬度往返")
}

let sampleCoordinate = GeoCoordinate(longitude: 10, latitude: 45)
let normalizedSample = WebMercator.normalized(sampleCoordinate)
expect(Int(floor(normalizedSample.x * Double(1 << 20))) == 553415, "z20 列号应为 553415")
expect(Int(floor(normalizedSample.y * Double(1 << 20))) == 377199, "z20 行号应为 377199")

let tile = SlippyTile(zoom: 10, x: 3, y: 5)
expectClose(tile.worldRect.minX, 3.0 / 1024, accuracy: 1e-12, "瓦片西边界")
expectClose(tile.worldRect.minY, 5.0 / 1024, accuracy: 1e-12, "瓦片北边界")

section("瓦片路径拼装")
let sample = SlippyTile(zoom: 20, x: 871934, y: 446722)
expect(TileLayout.webODM.relativePath(for: sample, fileExtension: "png") == "20/871934/446722.png", "ODM 布局 <z>/<x>/<y>")
var tms = TileLayout.webODM
tms.rowOrigin = .south
expect(tms.relativePath(for: sample, fileExtension: "png") == "20/871934/601853.png", "TMS 行号翻转")
var yFirst = TileLayout.webODM
yFirst.directoryAxis = .yFirst
expect(yFirst.relativePath(for: sample, fileExtension: "jpg") == "20/446722/871934.jpg", "yFirst 布局")

// MARK: - 相机

section("相机变换")
let camera = MapCamera(
    center: CGPoint(x: 0.42, y: 0.35),
    zoomLevel: 14,
    viewportSize: CGSize(width: 1200, height: 800),
    tilePixelSize: 512
)
for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1200, y: 800), CGPoint(x: 613, y: 207)] {
    let world = camera.worldPoint(forViewPoint: point)
    let restored = camera.viewPoint(forWorldPoint: world)
    expectClose(restored.x, point.x, accuracy: 1e-6, "视图↔世界 x 往返")
    expectClose(restored.y, point.y, accuracy: 1e-6, "视图↔世界 y 往返")
}

let anchor = CGPoint(x: 380, y: 640)
let anchorBefore = camera.coordinate(forViewPoint: anchor)
let anchorAfter = camera.zoomed(by: 2.5, anchorViewPoint: anchor).coordinate(forViewPoint: anchor)
expectClose(anchorAfter.longitude, anchorBefore.longitude, accuracy: 1e-9, "缩放锚点经度不变")
expectClose(anchorAfter.latitude, anchorBefore.latitude, accuracy: 1e-9, "缩放锚点纬度不变")

let movedRight = camera.translated(byViewDelta: CGPoint(x: 100, y: 0))
expect(movedRight.center.x < camera.center.x, "内容右移时相机中心西移")
let movedUp = camera.translated(byViewDelta: CGPoint(x: 0, y: 100))
expect(movedUp.center.y > camera.center.y, "内容上移时相机中心南移")

let fitRect = CGRect(x: 0.3, y: 0.4, width: 0.001, height: 0.0008)
let fitCamera = MapCamera.fitting(
    fitRect,
    viewportSize: CGSize(width: 1000, height: 700),
    padding: 20,
    tilePixelSize: 512
)
let visible = fitCamera.visibleWorldRect
expect(visible.minX <= fitRect.minX + 1e-12 && visible.maxX >= fitRect.maxX - 1e-12, "适配后横向完整可见")
expect(visible.minY <= fitRect.minY + 1e-12 && visible.maxY >= fitRect.maxY - 1e-12, "适配后纵向完整可见")

for zoom in [10, 14, 18, 20] {
    if let columns = camera.tileColumnRange(zoom: zoom) {
        expect(columns.lowerBound >= 0 && columns.upperBound < (1 << zoom), "z\(zoom) 可见列范围在界内")
    }
}

// MARK: - 测地线

section("测地线计算")

// Vincenty 1975 论文的标准算例（精确到角秒）。
func degrees(_ d: Double, _ m: Double, _ s: Double) -> Double {
    d + m / 60 + s / 3600
}
let flindersPeak = GeoCoordinate(
    longitude: degrees(144, 25, 29.52440),
    latitude: -degrees(37, 57, 3.72030)
)
let buninyong = GeoCoordinate(
    longitude: degrees(143, 55, 35.38390),
    latitude: -degrees(37, 39, 10.15610)
)
let vincenty = Geodesy.inverse(from: flindersPeak, to: buninyong)
expect(vincenty.converged, "Vincenty 应收敛")
expectClose(vincenty.distance, 54_972.271, accuracy: 0.01, "Vincenty 标准算例距离")
expectClose(vincenty.initialBearing, degrees(306, 52, 5.37), accuracy: 0.001, "Vincenty 起始方位角")
expectClose(vincenty.finalBearing, degrees(307, 10, 25.07), accuracy: 0.001, "Vincenty 终点方位角")

// 赤道上 1 度经差的子午线弧长（Vincenty 给出约 110574.39 米）。
let equatorArc = Geodesy.distance(
    from: GeoCoordinate(longitude: 0, latitude: 0),
    to: GeoCoordinate(longitude: 0, latitude: 1)
)
expectClose(equatorArc, 110_574.389, accuracy: 0.5, "赤道 1 度弧长")

// 中纬度约 800 米的基线，与墨卡托近似应相差在千分之几。
let baselineStart = GeoCoordinate(longitude: 10.0, latitude: 45.0)
let baselineEnd = GeoCoordinate(longitude: 10.01, latitude: 45.0)
let baseline = Geodesy.distance(from: baselineStart, to: baselineEnd)
let mercatorWidth = WebMercator.groundMetersPerWorldUnit(latitude: 45.0) / Double(1 << 20) * (0.01 / 360 * Double(1 << 20))
expect(abs(baseline - mercatorWidth) / baseline < 0.01, "墨卡托近似与测地线相差应小于 1%")

// 同一段折线的总长应等于分段之和。
let path = [
    GeoCoordinate(longitude: 10.0000, latitude: 45.0000),
    GeoCoordinate(longitude: 10.0050, latitude: 45.0030),
    GeoCoordinate(longitude: 10.0100, latitude: 45.0000),
]
let pathResult = MeasurementCalculator.evaluate(kind: .distance, points: path)
expect(pathResult.segments.count == 2, "折线应有 2 段")
expectClose(
    pathResult.totalLength,
    pathResult.segments.reduce(0) { $0 + $1.length },
    accuracy: 1e-6,
    "总长等于分段之和"
)
expectClose(pathResult.straightDistance ?? 0, Geodesy.distance(from: path[0], to: path[2]), accuracy: 1e-6, "起点到终点直线距离")

// 面积：纬度 45 度附近 0.001° × 0.001° 的矩形约 8743 平方米（解析值 R²ΔλΔφcosφ）。
let rectangle = [
    GeoCoordinate(longitude: 10.0000, latitude: 45.0000),
    GeoCoordinate(longitude: 10.0010, latitude: 45.0000),
    GeoCoordinate(longitude: 10.0010, latitude: 45.0010),
    GeoCoordinate(longitude: 10.0000, latitude: 45.0010),
]
let rectangleArea = Geodesy.area(of: rectangle)
expect(abs(rectangleArea - 8_743) / 8_743 < 0.005, "小矩形面积精度（实际 \(Int(rectangleArea)) 平方米）")

let areaResult = MeasurementCalculator.evaluate(kind: .area, points: rectangle)
expect(areaResult.area != nil, "多边形应给出面积")
expect(areaResult.segments.count == 4, "多边形闭合后应有 4 段")
expectClose(areaResult.closingError ?? 0, Geodesy.distance(from: rectangle[3], to: rectangle[0]), accuracy: 1e-6, "闭合差")

// 反向走一圈面积不变，方向相反不应产生负面积。
let reversedArea = Geodesy.area(of: rectangle.reversed())
expectClose(reversedArea, rectangleArea, accuracy: 1e-6, "面积与绕行方向无关")

// MARK: - 画圆

section("画圆")

// 直接公式与反向公式互为逆运算。
let circleCenter = GeoCoordinate(longitude: 10.0, latitude: 45.0)
let circleRim = Geodesy.destination(from: circleCenter, initialBearing: 37, distance: 500)
let circleInverse = Geodesy.inverse(from: circleCenter, to: circleRim)
expectClose(circleInverse.distance, 500, accuracy: 1e-5, "直接公式往返距离一致")
expectClose(circleInverse.initialBearing, 37, accuracy: 1e-7, "直接公式往返方位角一致")
expectClose(
    Geodesy.destination(from: circleCenter, initialBearing: 0, distance: 0).latitude,
    circleCenter.latitude,
    accuracy: 1e-12,
    "零距离返回起点"
)

// 向东走一整圈应回到原点附近（跨经度 180° 的兜底路径另算）。
let eastward = Geodesy.destination(from: circleCenter, initialBearing: 90, distance: 1000)
expect(eastward.longitude > circleCenter.longitude, "向东方位角应使经度增大")
let northward = Geodesy.destination(from: circleCenter, initialBearing: 0, distance: 1000)
expect(northward.latitude > circleCenter.latitude, "正北方位角应使纬度增大")

let circle = GeoMeasurement(kind: .circle, points: [circleCenter, circleRim])
let circleResult = circle.result
expectClose(circleResult.radius ?? 0, 500, accuracy: 1e-5, "圆半径取自圆心到半径点的测地距离")
let analyticCircumference = 2 * Double.pi * 500
expect(
    abs((circleResult.totalLength - analyticCircumference) / analyticCircumference) < 1e-4,
    "圆周长与 2πr 相对误差应小于 0.01%（实际 \(circleResult.totalLength)）"
)
let analyticArea = Double.pi * 500 * 500
expect(
    abs(((circleResult.area ?? 0) - analyticArea) / analyticArea) < 0.005,
    "圆面积与 πr² 相对误差应小于 0.5%（实际 \(circleResult.area ?? 0)）"
)
expect(circleResult.segments.count == 1, "圆应保留一条圆心到半径点的记录")
expect(circle.pointLabel(at: 0) == "圆心" && circle.pointLabel(at: 1) == "半径点", "圆的顶点命名")
expect(circle.circleRadius != nil, "圆应给出半径")

// 「定位到该测量」用的范围必须覆盖整个圆，而不是只有圆心和半径点。
if let rect = circle.worldRect {
    let worldCenter = WebMercator.normalized(circleCenter)
    let eastEdge = WebMercator.normalized(
        Geodesy.destination(from: circleCenter, initialBearing: 90, distance: 500)
    )
    expect(rect.minX < worldCenter.x && rect.maxX > eastEdge.x, "圆的范围应覆盖圆周")
} else {
    expect(false, "圆应给出世界范围")
}

// 半径点决定方向，输入半径后方位角保持不变。
let dueEastRim = Geodesy.destination(from: circleCenter, initialBearing: 90, distance: 300)
let resized = Geodesy.destination(from: circleCenter, initialBearing: 90, distance: 800)
expectClose(Geodesy.distance(from: circleCenter, to: dueEastRim), 300, accuracy: 1e-5, "半径 300 米")
expectClose(Geodesy.distance(from: circleCenter, to: resized), 800, accuracy: 1e-5, "半径 800 米")
expect(resized.longitude > dueEastRim.longitude, "半径变大时半径点沿同一方位角外移")
expect(Geodesy.circleRing(center: circleCenter, radius: 500).count == Geodesy.circleSampleCount, "圆周采样点数")
expect(Geodesy.circleRing(center: circleCenter, radius: 0).isEmpty, "零半径不产生圆周点")

// 传入已有采样点时结果必须与重新采样一致（标注层的缓存路径）。
let sampledRing = Geodesy.circleRing(center: circleCenter, radius: 500)
let reused = MeasurementCalculator.circleMetrics(center: circleCenter, radius: 500, ring: sampledRing)
let resampled = MeasurementCalculator.circleMetrics(center: circleCenter, radius: 500)
expectClose(reused.circumference, resampled.circumference, accuracy: 1e-9, "复用采样点的周长一致")
expectClose(reused.area, resampled.area, accuracy: 1e-9, "复用采样点的面积一致")
expect(reused.ring.count == sampledRing.count, "复用采样点时原样返回")
expectClose(reused.radius, 500, accuracy: 1e-9, "度量结果保留半径")

// MARK: - 样式

section("样式")

// 旧存档（没有 style 字段）要能正常读出来，并回落到默认样式。
let legacyJSON = """
{"id":"11111111-1111-1111-1111-111111111111","kind":"distance",\
"points":[{"longitude":10,"latitude":45},{"longitude":10.01,"latitude":45}],"colorIndex":3}
"""
if let legacy = try? JSONDecoder().decode(GeoMeasurement.self, from: Data(legacyJSON.utf8)) {
    expect(legacy.colorIndex == 3, "旧存档保留调色板索引")
    expect(legacy.style == MeasurementStyle.standard, "旧存档缺 style 字段时使用默认样式")
    expect(legacy.style.fillOpacity == MeasurementStyle.defaultFillOpacity, "默认填充不透明度")
    expect(legacy.style.stroke == nil, "默认样式不覆盖描边颜色")
} else {
    expect(false, "缺少 style 字段的旧存档应能解码")
}

var styled = circle
styled.style = MeasurementStyle(
    stroke: ColorComponents(red: 0.92, green: 0.13, blue: 0.21),
    fill: ColorComponents(red: 0.13, green: 0.44, blue: 0.93),
    fillOpacity: 0.35,
    strokeWidth: 3.5
)
if let encoded = try? JSONEncoder().encode(styled),
   let decoded = try? JSONDecoder().decode(GeoMeasurement.self, from: encoded) {
    expect(decoded.style == styled.style, "自定义样式应能往返编解码")
    expect(decoded.style.stroke?.red == 0.92, "描边颜色分量保留")
    expect(decoded.style.fillOpacity == 0.35, "填充不透明度保留")
} else {
    expect(false, "自定义样式的测量应能编解码")
}

expect(MeasurementKind.area.hasFill && MeasurementKind.circle.hasFill, "多边形与圆有填充")
expect(!MeasurementKind.distance.hasFill && !MeasurementKind.point.hasFill, "折线与点没有填充")
expect(
    MeasurementStyle(fillOpacity: 4, strokeWidth: 99).sanitized()
        == MeasurementStyle(fillOpacity: 1, strokeWidth: 12),
    "样式会被限制到合法范围"
)

section("格式化")
expect(MeasureFormat.distance(523.4) == "523.4 m", "米级格式")
let kilometerText = MeasureFormat.distance(1234.5)
expect(kilometerText.hasPrefix("1.23") && kilometerText.hasSuffix(" km"), "公里级格式")
expect(MeasureFormat.area(5234) == "5234.0 m²", "小面积格式")
expect(MeasureFormat.area(52340).contains("公顷"), "中等面积用公顷")
expect(MeasureFormat.bearing(45.5) == "45°30′", "方位角格式")
expect(MeasureFormat.bearing(359.999).hasPrefix("359°"), "方位角不产生 360° 进位")
expect(MeasureFormat.compass(0) == "北" && MeasureFormat.compass(180) == "南" && MeasureFormat.compass(100) == "东", "罗盘方位")

section("边界与异常输入")
expectClose(Geodesy.distance(from: sampleCoordinate, to: sampleCoordinate), 0, accuracy: 1e-9, "同一点距离为零")
expect(Geodesy.area(of: []).isZero, "空环面积为 0")
expect(Geodesy.area(of: [
    GeoCoordinate(longitude: 0, latitude: 0),
    GeoCoordinate(longitude: 1, latitude: 0),
]).isZero, "少于 3 点面积为 0")

let singlePoint = MeasurementCalculator.evaluate(kind: .distance, points: [sampleCoordinate])
expect(singlePoint.segments.isEmpty, "单点没有分段")
expectClose(singlePoint.totalLength, 0, accuracy: 1e-9, "单点总长为 0")

let antipodal = Geodesy.inverse(
    from: GeoCoordinate(longitude: 0, latitude: 0),
    to: GeoCoordinate(longitude: 179.9999, latitude: 0.0001)
)
expect(antipodal.distance > 19_000_000, "近对跖点应给出接近半周的距离")
expect(!antipodal.converged, "近对跖点标记为未收敛（已退回球面近似）")

expect(Geodesy.normalizedDegrees(-10) == 350, "负方位角归一化")
expect(Geodesy.normalizedDegrees(370) == 10, "超 360 度归一化")

// TMS 在第 0 层的行号仍为 0。
var tmsLayout = TileLayout.webODM
tmsLayout.rowOrigin = .south
expect(tmsLayout.relativePath(for: SlippyTile(zoom: 0, x: 0, y: 0), fileExtension: "png") == "0/0/0.png", "零层 TMS 路径")

// 越界瓦片不产生候选路径。
let source = DirectoryTileSource(rootURL: URL(fileURLWithPath: "/tmp"), layout: .webODM, zoomRange: 0...5)
expect(source.fileCandidates(for: SlippyTile(zoom: 9, x: 0, y: 0)).isEmpty, "超出层级范围返回空")
expect(source.fileCandidates(for: SlippyTile(zoom: 5, x: 32, y: 0)).isEmpty, "超出列范围返回空")

// MARK: - 导出

section("导出格式")

// MARK: - 构造数据集（验证嗅探与范围回退）

section("构造数据集")
let syntheticRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "euclid-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: syntheticRoot) }

func makeTile(zoom: Int, x: Int, y: Int) throws {
    let directory = syntheticRoot.appending(path: "\(zoom)/\(x)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "\(y).png")
    FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data([0x89, 0x50, 0x4E, 0x47]))
}

do {
    try makeTile(zoom: 1, x: 0, y: 0)
    for x in 1...2 {
        try makeTile(zoom: 2, x: x, y: 1)
    }
} catch {
    expect(false, "构造测试数据集失败：\(error)")
}

if let dataset = DatasetLocator.makeDataset(at: syntheticRoot) {
    expect(dataset.zoomRange == 1...2, "应识别出层级 1...2")
    expect(dataset.layout.directoryAxis == .xFirst, "应识别为 <z>/<x>/<y>")

    if let extent = DatasetLocator.extent(of: dataset, preferredMaxDirectories: 10) {
        expect(extent.level == 2, "应取目录数在预算内的最高层 z2")
        expectClose(extent.worldRect.minX, 0.25, accuracy: 1e-12, "范围西边界")
        expectClose(extent.worldRect.maxX, 0.75, accuracy: 1e-12, "范围东边界")
        expectClose(extent.worldRect.minY, 0.25, accuracy: 1e-12, "范围北边界")
        expectClose(extent.worldRect.maxY, 0.50, accuracy: 1e-12, "范围南边界")
    } else {
        expect(false, "应给出覆盖范围")
    }

    // 预算为 0 时所有层级都超标，应退化为目录数最少的层级而不是直接放弃。
    expect(DatasetLocator.extent(of: dataset, preferredMaxDirectories: 0) != nil, "超预算时应退化给出范围")
} else {
    expect(false, "应能识别出构造的数据集")
}

// MARK: - 真实数据集（可选，传入目录时执行）
let sampleMeasurement = GeoMeasurement(
    kind: .distance,
    points: path,
    colorIndex: 0
)
let geoJSON = MeasurementExporter.geoJSON([sampleMeasurement])
expect(geoJSON.contains("\"FeatureCollection\""), "GeoJSON 应为 FeatureCollection")
expect(geoJSON.contains("\"LineString\""), "GeoJSON 应包含 LineString")
let kml = MeasurementExporter.kml([sampleMeasurement])
expect(kml.contains("<LineString>"), "KML 应包含 LineString")
expect(kml.contains("<kml xmlns="), "KML 应包含命名空间")
let csv = MeasurementExporter.csv([sampleMeasurement])
expect(csv.contains("经度"), "CSV 应包含表头")
expect(csv.split(separator: "\n").count == 4, "CSV 应有表头加 3 个点")

// 圆导出为闭合多边形；半径同时出现在属性里。
let circleGeoJSON = MeasurementExporter.geoJSON([circle])
expect(circleGeoJSON.contains("\"Polygon\""), "圆在 GeoJSON 中应是闭合多边形")
expect(circleGeoJSON.contains("\"radiusMeters\""), "GeoJSON 属性应包含半径")
let circleKML = MeasurementExporter.kml([circle])
expect(circleKML.contains("<Polygon>"), "圆在 KML 中应是 Polygon")

// Excel：三个数据表 + 一页说明，并且必须是结构合法的 xlsx（ZIP）。
let workbook = MeasurementExporter.excel(
    [sampleMeasurement, circle],
    datasetName: "自检数据集",
    exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
)
expect(workbook.count > 2_000, "xlsx 应包含足够内容（实际 \(workbook.count) 字节）")
if let entries = ZIP.parse(workbook) {
    let names = entries.map(\.name)
    expect(names.count == 9, "xlsx 应包含 9 个部件（实际 \(names.count)）")
    expect(names.contains("[Content_Types].xml"), "xlsx 应有内容类型清单")
    expect(names.contains("_rels/.rels"), "xlsx 应有包关系")
    expect(names.contains("xl/workbook.xml"), "xlsx 应有工作簿定义")
    expect(names.contains("xl/_rels/workbook.xml.rels"), "xlsx 应有工作簿关系")
    expect(names.contains("xl/styles.xml"), "xlsx 应有样式表")
    expect(names.contains("xl/worksheets/sheet4.xml"), "xlsx 应有第 4 张工作表")

    func part(_ name: String) -> String {
        entries.first { $0.name == name }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
    }
    let workbookXML = part("xl/workbook.xml")
    expect(workbookXML.contains("测量汇总"), "工作簿应包含「测量汇总」表名")
    expect(workbookXML.contains("点坐标"), "工作簿应包含「点坐标」表名")
    expect(workbookXML.contains("分段明细"), "工作簿应包含「分段明细」表名")
    expect(workbookXML.contains("说明"), "工作簿应包含「说明」表名")

    let summary = part("xl/worksheets/sheet1.xml")
    // 表头 + 2 条测量 = 3 行。
    expect(summary.components(separatedBy: "<row ").count - 1 == 3, "汇总表应有表头加 2 条测量")
    expect(summary.contains("长度 / 周长(米)"), "汇总表表头包含长度列")
    expect(summary.contains("半径(米)"), "汇总表表头包含半径列")
    expect(summary.contains("inlinestr") || summary.contains("inlineStr"), "文本单元格使用内联字符串")

    let vertices = part("xl/worksheets/sheet2.xml")
    // 表头 + 折线 3 点 + 圆 2 点 = 6 行。
    expect(vertices.components(separatedBy: "<row ").count - 1 == 6, "点坐标表应有 6 行（含表头）")
    expect(vertices.contains("圆心") && vertices.contains("半径点"), "点坐标表应标明圆心与半径点")
    expect(vertices.contains("东坐标(米)"), "点坐标表应包含墨卡托东坐标")

    let segments = part("xl/worksheets/sheet3.xml")
    // 表头 + 折线 2 段 + 圆 1 段（半径）= 4 行。
    expect(segments.components(separatedBy: "<row ").count - 1 == 4, "分段表应有 4 行（含表头）")
    expect(segments.contains("起点") && segments.contains("终点"), "分段表应包含起终点")

    let notes = part("xl/worksheets/sheet4.xml")
    expect(notes.contains("自检数据集"), "说明页应写入数据集名称")
    expect(notes.contains("WGS84"), "说明页应写明坐标系")
} else {
    expect(false, "xlsx 应是可解析的 ZIP 容器")
}

// 少量测量也要能导出（空列表不应崩溃）。
expect(!MeasurementExporter.excel([]).isEmpty, "空测量列表也应产出可打开的工作簿")

// 可选：把样例工作簿写到磁盘，便于用 Excel / Numbers / 脚本复核。
if let dumpPath = ProcessInfo.processInfo.environment["EUCLID_DUMP_XLSX"] {
    do {
        let url = URL(fileURLWithPath: dumpPath)
        try workbook.write(to: url)
        print("  · 样例工作簿已写出：\(url.path(percentEncoded: false))")
    } catch {
        expect(false, "写出样例工作簿失败：\(error)")
    }
}

// MARK: - 真实数据集（可选，传入目录时执行）

if CommandLine.arguments.count > 1 {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    section("数据集嗅探：\(root.path(percentEncoded: false))")
    let discovered = DatasetLocator.discover(at: root)
    print("  找到 \(discovered.count) 个数据集")
    for dataset in discovered {
        print("  · \(dataset.name)  层级 z\(dataset.zoomRange.lowerBound)–z\(dataset.zoomRange.upperBound)  \(dataset.layout.tileSize)px  \(dataset.layout.directoryAxis.rawValue)")
        expect([256, 512, 1024].contains(dataset.layout.tileSize), "\(dataset.name) 瓦片尺寸应在常见取值内")
        expect(dataset.zoomRange.lowerBound <= dataset.zoomRange.upperBound, "\(dataset.name) 层级范围应合法")

        if let extent = DatasetLocator.extent(of: dataset) {
            let box = extent.boundingBox
            print(String(
                format: "    范围 lon %.4f…%.4f  lat %.4f…%.4f  约 %d 片",
                box.southWest.longitude, box.northEast.longitude,
                box.southWest.latitude, box.northEast.latitude,
                extent.tileCount
            ))
            expect((-180...180).contains(box.southWest.longitude) && (-180...180).contains(box.northEast.longitude), "\(dataset.name) 经度应在合法范围内")
            expect((-90...90).contains(box.southWest.latitude) && (-90...90).contains(box.northEast.latitude), "\(dataset.name) 纬度应在合法范围内")
            expect(extent.worldRect.width > 0 && extent.worldRect.height > 0, "\(dataset.name) 覆盖范围不应退化")
            expect(extent.tileCount > 0, "\(dataset.name) 应统计到瓦片")
        } else {
            expect(false, "\(dataset.name) 应能计算覆盖范围")
        }

        let source = dataset.source
        let mid = SlippyTile(
            zoom: dataset.zoomRange.upperBound,
            x: 1 << (dataset.zoomRange.upperBound - 1),
            y: 1 << (dataset.zoomRange.upperBound - 1)
        )
        expect(source.fileCandidates(for: mid).count == dataset.layout.fileExtensions.count, "\(dataset.name) 生成候选路径")
    }
    expect(discovered.count >= 1, "应在测试目录中找到至少 1 个数据集")
}

// MARK: - 汇总

print("\n" + String(repeating: "─", count: 46))
if failureCount == 0 {
    print("全部通过：\(checkCount) 项检查")
    exit(0)
} else {
    print("失败 \(failureCount) / \(checkCount) 项检查")
    exit(1)
}
