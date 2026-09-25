import CoreGraphics
import Foundation
import ImageIO
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

// 到达缩放上下限后继续缩放，绝不能变成平移（否则影像会被推出画面）。
let corner = CGPoint(x: 1190, y: 790)
let atFloor = MapCamera(
    center: camera.center,
    zoomLevel: 11,
    viewportSize: camera.viewportSize,
    tilePixelSize: camera.tilePixelSize
)
var limitedOut = atFloor
for _ in 0..<30 {
    limitedOut = limitedOut.zoomed(by: 1 / 1.6, anchorViewPoint: corner, zoomLevelRange: 11...16)
}
expectClose(limitedOut.zoomLevel, 11, accuracy: 1e-9, "连续缩小应停在下限")
expectClose(limitedOut.center.x, atFloor.center.x, accuracy: 1e-12, "到下限后继续缩小不应平移（x）")
expectClose(limitedOut.center.y, atFloor.center.y, accuracy: 1e-12, "到下限后继续缩小不应平移（y）")

let atCeiling = MapCamera(
    center: camera.center,
    zoomLevel: 16,
    viewportSize: camera.viewportSize,
    tilePixelSize: camera.tilePixelSize
)
var limitedIn = atCeiling
for _ in 0..<30 {
    limitedIn = limitedIn.zoomed(by: 1.6, anchorViewPoint: corner, zoomLevelRange: 11...16)
}
expectClose(limitedIn.zoomLevel, 16, accuracy: 1e-9, "连续放大应停在上限")
expectClose(limitedIn.center.x, atCeiling.center.x, accuracy: 1e-12, "到上限后继续放大不应平移（x）")
expectClose(limitedIn.center.y, atCeiling.center.y, accuracy: 1e-12, "到上限后继续放大不应平移（y）")

// 下限处的一次滚动应当完全无效果（不是平移）。
let oneStepOut = atFloor.zoomed(by: 0.8, anchorViewPoint: corner, zoomLevelRange: 11...16)
expectClose(oneStepOut.zoomLevel, 11, accuracy: 1e-9, "下限处单步缩放层级不变")
expectClose(oneStepOut.center.x, atFloor.center.x, accuracy: 1e-12, "下限处单步缩放不移位")
expectClose(oneStepOut.center.y, atFloor.center.y, accuracy: 1e-12, "下限处单步缩放不移位（y）")
// 未到限时锚点仍然生效。
let midZoom = camera.zoomed(by: 1.6, anchorViewPoint: corner, zoomLevelRange: 11...16)
expect(midZoom.zoomLevel > 14, "未到上限时正常放大")
expect(midZoom.center.x != camera.center.x || midZoom.center.y != camera.center.y, "锚点缩放会移动中心")
// 锚点补偿也不该被夹取破坏：未到限时锚点下的坐标保持不变。
let midAnchorBefore = camera.coordinate(forViewPoint: corner)
let midAnchorAfter = midZoom.coordinate(forViewPoint: corner)
expectClose(midAnchorAfter.longitude, midAnchorBefore.longitude, accuracy: 1e-9, "带层级范围的缩放锚点经度不变")
expectClose(midAnchorAfter.latitude, midAnchorBefore.latitude, accuracy: 1e-9, "带层级范围的缩放锚点纬度不变")

let movedRight = camera.translated(byViewDelta: CGPoint(x: 100, y: 0))
expect(movedRight.center.x < camera.center.x, "内容右移时相机中心西移")
let movedUp = camera.translated(byViewDelta: CGPoint(x: 0, y: 100))
expect(movedUp.center.y > camera.center.y, "内容上移时相机中心南移")

let fitRect = CGRect(x: 0.3, y: 0.4, width: 0.001, height: 0.0008)

// Retina：整数层级时一张瓦片应当正好铺满它的原始像素数（1 图像像素 = 1 设备像素），
// 否则会把 512px 的瓦片拉成 1024px 显示，画面发虚。
let retina = MapCamera(
    center: CGPoint(x: 0.5, y: 0.5),
    zoomLevel: 15,
    viewportSize: CGSize(width: 800, height: 600),
    tilePixelSize: 512,
    displayScale: 2
)
let retinaTilePoints = retina.pixelsPerWorldUnit / Double(1 << 15)
expectClose(retinaTilePoints, 256, accuracy: 1e-9, "Retina 上整数层级的瓦片占 256 点")
expectClose(retinaTilePoints * retina.displayScale, 512, accuracy: 1e-9, "Retina 上瓦片 1:1 对应设备像素")
expectClose(retina.zoomLevel, 15, accuracy: 1e-9, "带设备像素比的层级往返一致")
let retinaZoomed = retina.zoomed(by: 1.6, zoomLevelRange: 10...20)
expectClose(retinaZoomed.zoomLevel, 15 + log2(1.6), accuracy: 1e-9, "带设备像素比缩放后层级正确")
expectClose(retinaZoomed.displayScale, 2, accuracy: 1e-12, "缩放后设备像素比保留")
// 普通屏上仍然按 512 点铺一张瓦片。
let plain = MapCamera(
    center: CGPoint(x: 0.5, y: 0.5),
    zoomLevel: 15,
    viewportSize: CGSize(width: 800, height: 600),
    tilePixelSize: 512
)
expectClose(plain.pixelsPerWorldUnit / Double(1 << 15), 512, accuracy: 1e-9, "普通屏整数层级瓦片占 512 点")

// 换屏幕后只改比例尺、不改倍率：视图范围不变，但按新的设备像素比换算。
let switched = MapCamera(
    center: retina.center,
    pixelsPerWorldUnit: pow(2, 15) * 512 / 1,
    viewportSize: retina.viewportSize,
    tilePixelSize: 512,
    displayScale: 1
)
expectClose(switched.zoomLevel, 15, accuracy: 1e-9, "普通屏相机层级一致")

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

// MARK: - 在线瓦片下载

section("下载计划与模板")

do {
    // 整幅世界在 z0 上只有一片。
    let world = GeoBounds(west: -180, south: -85.0511, east: 180, north: 85.0511)
    let worldPlan = try TileDownloadPlan(bounds: world, zoomRange: 0...0)
    expect(worldPlan.totalTileCount == 1, "z0 全世界应为 1 片")
    expect(worldPlan.ranges[0].columns == 0...0 && worldPlan.ranges[0].rows == 0...0, "z0 行列范围应为 0…0")

    // 东半球北半部在 z1 上是 (x=1, y=0) 这一片。
    let northEast = GeoBounds(west: 0, south: 0, east: 180, north: 85)
    let halfPlan = try TileDownloadPlan(bounds: northEast, zoomRange: 1...1)
    expect(halfPlan.ranges[0].columns == 1...1, "z1 东半球列号应为 1")
    expect(halfPlan.ranges[0].rows == 0...0, "z1 北半球行号应为 0")

    // 边界正好落在瓦片边界上时不该多取一圈。
    let tileRect = SlippyTile(zoom: 2, x: 1, y: 1).worldRect
    let exact = GeoBounds(normalizedRect: tileRect)
    let exactPlan = try TileDownloadPlan(bounds: exact, zoomRange: 2...2)
    expect(exactPlan.ranges[0].columns == 1...1, "边界对齐时只应取 1 列")
    expect(exactPlan.ranges[0].rows == 1...1, "边界对齐时只应取 1 行")
    expectClose(exact.west, WebMercator.coordinate(fromNormalized: CGPoint(x: 0.25, y: 0.25)).longitude,
                accuracy: 1e-9, "包围盒西边界")

    // 层级越深，覆盖同一范围需要的瓦片越多；每层瓦片数应严格递增。
    let city = GeoBounds(west: 119.30, south: 25.68, east: 119.52, north: 25.86)
    let plan = try TileDownloadPlan(bounds: city, zoomRange: 12...16)
    var previous = 0
    for range in plan.ranges {
        expect(range.count > previous, "z\(range.zoom) 的瓦片数应比上一层多")
        previous = range.count
    }
    expect(plan.totalTileCount == plan.ranges.reduce(0) { $0 + $1.count }, "总数应等于各层之和")
    expect(plan.ranges.map(\.zoom) == [12, 13, 14, 15, 16], "各层应按升序展开")

    // 展开顺序从范围中心开始，中途取消时中间区域先可用。
    let firstTile = plan.tiles(for: plan.ranges[0])[0]
    let centerColumn = (plan.ranges[0].columns.lowerBound + plan.ranges[0].columns.upperBound) / 2
    let centerRow = (plan.ranges[0].rows.lowerBound + plan.ranges[0].rows.upperBound) / 2
    expect(firstTile == SlippyTile(zoom: 12, x: centerColumn, y: centerRow), "第一片应从范围中心开始")
    expect(Set(plan.allTiles()).count == plan.totalTileCount, "展开的瓦片不应重复")

    expect((try? TileDownloadPlan(bounds: GeoBounds(west: 10, south: 10, east: 5, north: 20), zoomRange: 1...2)) == nil, "西 > 东的包围盒应被拒绝")
    expect((try? TileDownloadPlan(bounds: world, zoomRange: 28...31)) == nil, "超过 z30 的层级应被拒绝")
}

do {
    let tile = SlippyTile(zoom: 14, x: 8000, y: 6000)
    let xyz = try TileURLTemplate.url(for: tile, template: "https://host.test/{z}/{x}/{y}.png")
    expect(xyz.absoluteString == "https://host.test/14/8000/6000.png", "XYZ 模板渲染")

    let tmsTile = SlippyTile(zoom: 2, x: 1, y: 1)
    let tms = try TileURLTemplate.url(for: tmsTile, template: "https://host.test/{z}/{x}/{-y}.png")
    expect(tms.absoluteString == "https://host.test/2/1/2.png", "TMS 行号渲染")

    let tianditu = try TileURLTemplate.url(
        for: tile,
        template: TileSourceTemplate.tiandituImagery.urlTemplate,
        subdomains: TileSourceTemplate.tiandituImagery.subdomains,
        key: "abc123"
    )
    let text = tianditu.absoluteString
    expect(text.contains("TILEMATRIX=14") && text.contains("TILEROW=6000") && text.contains("TILECOL=8000"),
           "WMTS KVP 模板应映射到 z/x/y")
    expect(text.contains("tk=abc123"), "密钥应写入 URL")
    expect(TileSourceTemplate.tiandituImagery.subdomains.contains { text.contains("//t\($0).") }, "子域轮转应命中预设列表")
    expect(TileSourceTemplate.tiandituImagery.needsKey, "天地图预设应标记为需要密钥")

    var keyError: TileDownloadError?
    do {
        _ = try TileURLTemplate.url(for: tile, template: TileSourceTemplate.tiandituImagery.urlTemplate, key: nil)
    } catch let error as TileDownloadError {
        keyError = error
    }
    expect(keyError == .missingKey, "缺少密钥时应报 missingKey")

    var placeholderError: TileDownloadError?
    do {
        _ = try TileURLTemplate.url(for: tile, template: "https://host.test/{z}/{x}/{y}/{w}.png")
    } catch let error as TileDownloadError {
        placeholderError = error
    }
    if case .unknownPlaceholder = placeholderError {} else {
        expect(false, "未知占位符应被拒绝")
    }

    var schemeError: TileDownloadError?
    do {
        _ = try TileURLTemplate.url(for: tile, template: "ftp://host.test/{z}/{x}/{y}.png")
    } catch let error as TileDownloadError {
        schemeError = error
    }
    if case .invalidTemplate = schemeError {} else {
        expect(false, "非 http(s) 模板应被拒绝")
    }

    var emptyError: TileDownloadError?
    do {
        _ = try TileURLTemplate.url(for: tile, template: "   ")
    } catch let error as TileDownloadError {
        emptyError = error
    }
    expect(emptyError == .emptyTemplate, "空模板应报 emptyTemplate")
}

section("瓦片下载（假取图通道）")

/// 按 URL 返回预设结果的假取图通道，同时记录调用次数与并发峰值。
actor FakeTileFetcher: TileFetching {
    enum Response: Sendable {
        case ok(Data)
        case status(Int)
        /// 前 `failures` 次返回 `code`，之后成功。
        case flaky(failures: Int, code: Int, data: Data)
        case transport(String)
    }

    private var responses: [String: Response]
    private var calls: [String: Int] = [:]
    private var inFlight = 0
    private var peakInFlight = 0
    private var total = 0
    private let delay: TimeInterval
    private let defaultResponse: Response

    init(
        responses: [String: Response],
        defaultResponse: Response = .status(404),
        delay: TimeInterval = 0
    ) {
        self.responses = responses
        self.defaultResponse = defaultResponse
        self.delay = delay
    }

    func fetch(_ request: TileRequest) async throws -> TileFetchResult {
        total += 1
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }

        let key = request.url.absoluteString
        calls[key, default: 0] += 1
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }

        switch responses[key] ?? defaultResponse {
        case .ok(let data):
            return TileFetchResult(data: data, statusCode: 200)
        case .status(let code):
            throw TileFetchError.httpStatus(code)
        case .transport(let message):
            throw TileFetchError.transport(message)
        case .flaky(let failures, let code, let data):
            if calls[key, default: 0] <= failures {
                throw TileFetchError.httpStatus(code)
            }
            return TileFetchResult(data: data, statusCode: 200)
        }
    }

    func callCount(for url: URL) -> Int { calls[url.absoluteString] ?? 0 }
    func statistics() -> (total: Int, peakInFlight: Int) { (total, peakInFlight) }
}

actor ProgressCollector {
    private var events: [TileDownloadProgress] = []
    func record(_ progress: TileDownloadProgress) { events.append(progress) }
    func snapshot() -> [TileDownloadProgress] { events }
}

do {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "euclid-download-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let bounds = GeoBounds(west: 119.30, south: 25.68, east: 119.52, north: 25.86)
    let plan = try TileDownloadPlan(bounds: bounds, zoomRange: 12...13)
    let tiles = plan.allTiles()
    let template = "https://tiles.test/{z}/{x}/{y}.png"
    let payload = Data("tile".utf8)

    // 挑三片做异常样本：一片缺片、一片一直失败、一片先失败两次再成功。
    let missingTile = tiles[1]
    let failingTile = tiles[3]
    let flakyTile = tiles[5]
    func url(_ tile: SlippyTile) -> URL {
        try! TileURLTemplate.url(for: tile, template: template)
    }
    var responses: [String: FakeTileFetcher.Response] = [:]
    responses[url(missingTile).absoluteString] = .status(404)
    responses[url(failingTile).absoluteString] = .status(500)
    responses[url(flakyTile).absoluteString] = .flaky(failures: 2, code: 503, data: payload)

    // 默认返回正常瓦片，只有上面挑出来的三片走异常分支；
    // 加一点点延时，并发峰值才看得出来（否则瞬时返回会把并发掩盖掉）。
    let fetcher = FakeTileFetcher(responses: responses, defaultResponse: .ok(payload), delay: 0.01)
    let downloader = TileDownloader(fetcher: fetcher)
    let collector = ProgressCollector()
    let options = TileDownloadOptions(
        urlTemplate: template,
        outputDirectory: root,
        concurrency: 4,
        requestsPerSecond: 0,
        retryLimit: 2,
        sourceName: "自检假源",
        attribution: "© 自检",
        terms: "仅用于自检"
    )

    let summary = try await downloader.run(plan: plan, options: options) { progress in
        // 回调是 @Sendable 的，交给 actor 收集，避免跨线程访问测试计数器。
        Task { await collector.record(progress) }
    }

    print("    计划 \(plan.totalTileCount) 片：成功 \(summary.downloaded)、跳过 \(summary.skipped)、"
        + "缺片 \(summary.missing)、失败 \(summary.failed)")
    // 三片样本里：404 计为缺片、一直 500 的计为失败，先失败后成功的第三片最终仍然落盘。
    expect(summary.downloaded == tiles.count - 2, "除缺片与失败各一片外都应下载成功（实际 \(summary.downloaded) / \(tiles.count)）")
    expect(summary.missing == 1, "404 应计为缺片")
    expect(summary.failed == 1, "一直失败的那片应计为失败")
    expect(summary.bytes == summary.downloaded * payload.count, "字节数应等于成功瓦片之和")
    expect(!summary.cancelled, "正常结束不应标记为取消")
    expect(summary.failures.count == 1, "失败样例应被记录")

    let flakyCalls = await fetcher.callCount(for: url(flakyTile))
    expect(flakyCalls == 3, "前两次失败后第三次成功（实际 \(flakyCalls) 次）")
    let failingCalls = await fetcher.callCount(for: url(failingTile))
    expect(failingCalls == 3, "重试上限 2 表示最多请求 3 次（实际 \(failingCalls) 次）")

    let statistics = await fetcher.statistics()
    expect(statistics.peakInFlight <= 4, "并发峰值不应超过设定值（实际 \(statistics.peakInFlight)）")
    expect(statistics.peakInFlight >= 2, "并发调度应真的并行取图")

    // 落盘路径应是 <z>/<x>/<y>.png。
    let sampleTile = tiles[0]
    let samplePath = root.appending(path: "12/\(sampleTile.x)/\(sampleTile.y).png")
    expect(FileManager.default.fileExists(atPath: samplePath.path(percentEncoded: false)), "瓦片应写到 <z>/<x>/<y>.png")

    let progressEvents = await collector.snapshot()
    expect(progressEvents.first?.total == plan.totalTileCount, "首个进度事件应带上总数")
    expect(progressEvents.map(\.completed) == progressEvents.map(\.completed).sorted(), "进度应单调递增")
    expect(progressEvents.last?.completed == plan.totalTileCount, "最后一个进度事件应完成全部瓦片")

    // 落盘清单：source.json 可解码，attribution.txt 带上条款。
    let manifestURL = root.appending(path: "source.json")
    if let data = try? Data(contentsOf: manifestURL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try? decoder.decode(DownloadManifest.self, from: data)
        expect(manifest?.tileCount == plan.totalTileCount, "清单应记录计划瓦片数")
        expect(manifest?.sourceName == "自检假源", "清单应记录数据源名称")
        expect(manifest?.zoomRange == 12...13, "清单应记录层级范围")
    } else {
        expect(false, "应写出 source.json")
    }
    let attribution = (try? String(contentsOf: root.appending(path: "attribution.txt"), encoding: .utf8)) ?? ""
    expect(attribution.contains("自检假源") && attribution.contains("仅用于自检"), "attribution.txt 应带上来源与条款")

    // 下载结果应能被本程序的目录嗅探直接识别成数据集。
    if let dataset = DatasetLocator.makeDataset(at: root) {
        expect(dataset.zoomRange == 12...13, "下载目录应被识别为 z12–z13 数据集")
    } else {
        expect(false, "下载目录应能被识别为数据集")
    }

    // 第二次运行默认跳过已存在的瓦片，且不再发请求。
    let beforeSecondRun = await fetcher.statistics().total
    let second = try await downloader.run(plan: plan, options: options)
    let afterSecondRun = await fetcher.statistics().total
    expect(second.skipped == summary.downloaded, "已存在的瓦片应被跳过")
    expect(second.downloaded == 0, "已有文件时不应重复下载")
    expect(second.missing == 1 && second.failed == 1, "缺片与失败的那两片会再次尝试")
    expect(afterSecondRun - beforeSecondRun <= 4, "跳过时不应重新请求已有瓦片")

    // 换一种落盘布局：yFirst + TMS 行序。
    let transposedRoot = root.appending(path: "transposed")
    var layout = TileLayout.webODM
    layout.directoryAxis = .yFirst
    layout.rowOrigin = .south
    var transposed = options
    transposed.layout = layout
    transposed.outputDirectory = transposedRoot
    transposed.overwriteExisting = true
    _ = try await downloader.run(plan: plan, options: transposed)
    let transposedTile = tiles[0]
    let row = (1 << transposedTile.zoom) - 1 - transposedTile.y
    let transposedPath = transposedRoot.appending(path: "\(transposedTile.zoom)/\(row)/\(transposedTile.x).png")
    expect(FileManager.default.fileExists(atPath: transposedPath.path(percentEncoded: false)), "yFirst + TMS 布局应写成 <z>/<行>/<列>.png")
}

do {
    // 取消：慢速取图，跑一小会儿就取消，应尽快停下并标记 cancelled。
    let root = FileManager.default.temporaryDirectory
        .appending(path: "euclid-download-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let plan = try TileDownloadPlan(
        bounds: GeoBounds(west: 119.0, south: 25.4, east: 119.9, north: 26.1),
        zoomRange: 12...12
    )
    expect(plan.totalTileCount > 8, "取消测试的范围应包含足够多的瓦片")

    let fetcher = FakeTileFetcher(responses: [:], defaultResponse: .ok(Data("tile".utf8)), delay: 0.05)
    let downloader = TileDownloader(fetcher: fetcher)
    let options = TileDownloadOptions(
        urlTemplate: "https://tiles.test/{z}/{x}/{y}.png",
        outputDirectory: root,
        concurrency: 4,
        requestsPerSecond: 0,
        retryLimit: 0,
        writesManifest: false
    )
    let task = Task { try await downloader.run(plan: plan, options: options) }
    try? await Task.sleep(for: .seconds(0.2))
    task.cancel()
    let cancelled = try await task.value
    expect(cancelled.cancelled, "取消后应标记 cancelled")
    expect(cancelled.downloaded < plan.totalTileCount, "取消后不应下载完所有瓦片")
    expect(cancelled.downloaded > 0, "取消前应已经落下一部分瓦片")
}

section("在线取图与内存缓存")

/// 造一张最小可解码的 PNG，用于缓存与解码路径的自检。
func makeCheckPNG(size: Int = 8) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: size,
              height: size,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

do {
    // 在线来源：模板渲染、失败重试、层级越界、缺密钥判定。
    let template = TileSourceTemplate(
        id: "check-online",
        name: "自检在线源",
        urlTemplate: "https://tiles.test/{z}/{x}/{y}.png",
        fileExtension: "png",
        maximumZoom: 10,
        tileSize: 256
    )
    let payload = Data("tile".utf8)
    let tile = SlippyTile(zoom: 8, x: 12, y: 34)
    let url = try TileURLTemplate.url(for: tile, template: template.urlTemplate)
    let fetcher = FakeTileFetcher(
        responses: [url.absoluteString: .flaky(failures: 1, code: 503, data: payload)],
        defaultResponse: .status(404)
    )
    let source = RemoteTileSource(template: template, key: nil, fetcher: fetcher, retryLimit: 1)
    expect(source.availableZoomRange == 0...10, "在线源层级范围应取自模板")
    expect(source.isValid, "模板非空时应判定为可用")
    expect(await source.data(for: tile) == payload, "先 503 后成功：应重试一次并拿到数据")
    expect(await fetcher.callCount(for: url) == 2, "重试后总请求数应为 2")
    expect(await source.data(for: SlippyTile(zoom: 11, x: 1, y: 1)) == nil, "超出层级范围应直接返回 nil")
    expect(await source.data(for: SlippyTile(zoom: 9, x: 1, y: 1)) == nil, "404 应视为没有这一片")
    expect(!RemoteTileSource(template: TileSourceTemplate.tiandituImagery, key: nil).isValid, "缺密钥的源应判定为不可用")
    expect(RemoteTileSource(template: TileSourceTemplate.tiandituImagery, key: "abc").isValid, "填了密钥即可用")
    expect(TileSourceTemplate.presets.allSatisfy { !$0.name.isEmpty }, "每个预设都应有名字")
    expect(TileSourceTemplate.presets.filter(\.needsKey).allSatisfy { !$0.terms.isEmpty },
           "需要密钥的预设都应写明使用条款")
}

do {
    // 本地目录 + TileProvider：解码、缓存命中、缺片负缓存、预取、失效。
    let root = FileManager.default.temporaryDirectory
        .appending(path: "euclid-provider-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    guard let png = makeCheckPNG() else {
        expect(false, "应能生成自检用的 PNG")
        exit(1)
    }
    let layout = TileLayout.webODM
    let present = SlippyTile(zoom: 8, x: 1, y: 2)
    let absent = SlippyTile(zoom: 8, x: 9, y: 9)
    let prefetched = [SlippyTile(zoom: 8, x: 1, y: 3), SlippyTile(zoom: 8, x: 2, y: 2)]

    func write(_ tile: SlippyTile) {
        let url = root.appending(path: layout.relativePath(for: tile, fileExtension: "png"))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }
    func remove(_ tile: SlippyTile) {
        let url = root.appending(path: layout.relativePath(for: tile, fileExtension: "png"))
        try? FileManager.default.removeItem(at: url)
    }

    write(present)
    let provider = TileProvider(
        source: DirectoryTileSource(rootURL: root, layout: layout, zoomRange: 8...10),
        maxConcurrentDecodes: 2
    )
    expect(await provider.availableZoomRange == 8...10, "供应者应转发来源的层级范围")

    let image = await provider.image(for: present)
    expect(image != nil, "本地瓦片应能解码")
    expect(image?.width == 8, "解码后的图片尺寸应与文件一致")
    expect(await provider.cachedTileCount == 1, "取过的瓦片应进入内存缓存")

    remove(present)
    expect(await provider.image(for: present) != nil, "文件删掉后仍应命中内存缓存")

    expect(await provider.image(for: absent) == nil, "不存在的瓦片应返回 nil")
    write(absent)
    expect(await provider.image(for: absent) == nil, "缺片会记入负缓存，重建文件前不再回读")

    prefetched.forEach(write)
    await provider.prefetch(prefetched)
    expect(await provider.cachedTileCount == 3, "预取应把瓦片放进缓存")

    await provider.invalidate()
    expect(await provider.cachedTileCount == 0, "失效后缓存应为空")
    expect(await provider.image(for: absent) != nil, "缓存失效后应重新读取（这时文件已存在）")
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
