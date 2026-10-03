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
// 面积单位可显式指定（界面上的「面积单位」开关走的就是这几档）
expect(MeasureFormat.area(5234, unit: .squareMeters) == "5234.0 m²", "固定平方米")
expect(MeasureFormat.area(5234, unit: .hectares) == "0.523 公顷", "固定公顷")
expect(MeasureFormat.area(5234, unit: .squareKilometers) == "0.005 km²", "固定平方公里")
expect(MeasureFormat.area(5234, unit: .mu) == "7.85 亩", "固定亩")
expect(MeasureFormat.area(10_000, unit: .mu) == "15.00 亩", "1 公顷 = 15 亩")
expect(MeasureFormat.area(5234, unit: .automatic) == "5234.0 m²", "自动档仍按数量级挑")
expect(MeasureFormat.AreaUnit.allCases.count == 5, "面积单位五档（自动 / m² / 公顷 / km² / 亩）")
expect(MeasureFormat.bearing(45.5) == "45°30′", "方位角格式")
// 359.999° 取到整分就是 360°00′，必须归一成 0°00′（既不能写 360°，也不能写 359°60′）
expect(MeasureFormat.bearing(359.999) == "0°00′", "方位角进位后归一，不出现 360° 或 60′")
expect(MeasureFormat.bearing(359.5) == "359°30′", "方位角格式（不进位那一侧）")
expect(MeasureFormat.compass(0) == "北" && MeasureFormat.compass(180) == "南" && MeasureFormat.compass(100) == "东", "罗盘方位")
// 度分秒：秒进位到分、分再进位到度，不出现 60″ / 60′
expect(MeasureFormat.dms(120.5, hemisphere: "E") == "120°30′00.0″E", "度分秒基本格式")
expect(MeasureFormat.dms(116.999999, hemisphere: "E") == "117°00′00.0″E", "秒与分一路进位到度")
expect(MeasureFormat.dms(-89.99999, hemisphere: "S") == "90°00′00.0″S", "纬度夹到 90° 并进位")
expect(MeasureFormat.dms(0, hemisphere: "N") == "0°00′00.0″N", "零值格式")

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

// MARK: - 内存安全（畸形输入既不许崩，也不许按声明去申请巨量内存）

section("内存安全：畸形输入")

// 分块尺寸的可信范围：真实影像里 512/1024/4096 很常见，宽条带也合法；
// 但「十亿见方」这种声明必须在解析阶段就被挡住（解码会按它申请缓冲区）。
expect(!TIFFLimits.isSaneChunk(width: 1 << 30, height: 1 << 30), "十亿见方的分块不可信")
expect(!TIFFLimits.isSaneChunk(width: 0, height: 512), "零宽分块不可信")
expect(!TIFFLimits.isSaneChunk(width: 512, height: 0), "零高分块不可信")
expect(TIFFLimits.isSaneChunk(width: 512, height: 512), "512 见方分块应可信")
expect(TIFFLimits.isSaneChunk(width: 4096, height: 4096), "4096 见方分块应可信")
expect(TIFFLimits.isSaneChunk(width: 100_000, height: 600), "宽条带（10 万 × 600）应可信")
expect(!TIFFLimits.isSaneChunk(width: 100_000, height: 100_000), "超大条带不可信")

// 端到端：真的写出一个「分块十亿见方」的 TIFF，要求打不开 —— 不崩、也不去申请 4 TB。
let malformedTIFF = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "euclid-malformed-\(UUID().uuidString).tif")
defer { try? FileManager.default.removeItem(at: malformedTIFF) }
writeMalformedTiledTIFF(to: malformedTIFF)
if let raster = try? RasterLoader.load(url: malformedTIFF) {
    expect(false, "分块尺寸荒谬的 TIFF 不该被打开（拿到了 \(raster.pixelSizeText)）")
} else {
    expect(true, "分块尺寸荒谬的 TIFF 在解析阶段被拒绝")
}

// 截断的压缩块：解出来必须「补齐到容量」或直接拒绝，绝不能返回短数组（调用方是按块尺寸索引像素的）。
let truncatedLZW = Data([0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01])
if let decoded = TIFFCodec.lzwDecode(truncatedLZW, capacity: 64) {
    expect(decoded.count == 64, "截断的 LZW 结果应补齐到块容量（实际 \(decoded.count)）")
} else {
    expect(true, "截断的 LZW 被拒绝（允许，但不能崩）")
}
// 截断的 PackBits（字面量段声明 6 字节、只给了 3 字节）：要么整体拒绝，要么补齐到容量，
// 但绝不能返回短数组（那就是调用方越界的入口）。
if let decoded = TIFFCodec.packBitsDecode(Data([0x05, 1, 2, 3]), capacity: 16) {
    expect(decoded.count == 16, "截断的 PackBits 若返回，必须补齐到块容量（实际 \(decoded.count)）")
} else {
    expect(true, "截断的 PackBits 被整体拒绝（允许）")
}
// 完整但不满一整块：补齐到容量，且前面的字节保持原样。
if let decoded = TIFFCodec.packBitsDecode(Data([0x02, 7, 8, 9]), capacity: 8) {
    expect(decoded.count == 8, "不满一块的 PackBits 结果应补齐到容量（实际 \(decoded.count)）")
    expect(Array(decoded.prefix(3)) == [7, 8, 9], "补齐前应保留解出的字节")
} else {
    expect(false, "合法的 PackBits 字面量段应能解出")
}
expect(TIFFCodec.packBitsDecode(Data(), capacity: 32) == nil, "空输入应被拒绝")
expect(TIFFCodec.lzwDecode(Data(), capacity: 32) == nil, "空输入应被拒绝")

// 层级兜底：荒谬的层级不再让 `1 << zoom` 崩。
expect(SlippyTile(zoom: 99, x: 0, y: 0).zoom == 30, "层级应夹到 30")
expect(SlippyTile(zoom: -5, x: 0, y: 0).zoom == 0, "层级应夹到 0")
expect(SlippyTile(zoom: 99, x: 0, y: 0).tileCountAtZoom == 1 << 30, "夹取之后瓦片数应可算")

// 导出转义：CSV 引用规则与 JSON 字符串（今天导出的都是固定文本，靠断言把这条规矩钉住）。
expect(MeasurementExporter.csvField("普通") == "普通", "CSV 普通字段不加引号")
expect(MeasurementExporter.csvField("含,逗号") == "\"含,逗号\"", "CSV 含逗号要加引号")
expect(MeasurementExporter.csvField("含\"引号") == "\"含\"\"引号\"", "CSV 内部引号要翻倍")
expect(MeasurementExporter.jsonString("含\"引号\\斜杠") == "\"含\\\"引号\\\\斜杠\"", "JSON 要转义引号与反斜杠")
expect(MeasurementExporter.jsonString("换行\n") == "\"换行\\n\"", "JSON 换行转成 \\n")

/// 写一个「IFD 声称分块是 2³⁰ 见方」的最小 TIFF：只为验证解析阶段会挡掉它。
func writeMalformedTiledTIFF(to url: URL) {
    var data = Data()
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    data.append(contentsOf: [0x49, 0x49])   // "II"：小端
    u16(42)                                  // 经典 TIFF 魔数
    u32(8)                                   // IFD 在偏移 8
    let entries: [(UInt16, UInt32)] = [
        (256, 64),        // ImageWidth
        (257, 64),        // ImageLength
        (258, 8),         // BitsPerSample
        (259, 1),         // Compression = none
        (262, 1),         // Photometric = BlackIsZero
        (277, 1),         // SamplesPerPixel
        (322, 1 << 30),   // TileWidth ← 荒谬
        (323, 1 << 30),   // TileLength ← 荒谬
        (324, 8),         // TileOffsets（非空即可）
        (325, 8),         // TileByteCounts
    ]
    u16(UInt16(entries.count))
    for (tag, value) in entries {
        u16(tag)
        u16(4)          // 类型 LONG
        u32(1)          // 数量 1
        u32(value)      // 值内联
    }
    u32(0)              // 下一个 IFD：没有
    try? data.write(to: url)
}

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

// MARK: - 又打开一份数据：已打开列表的合并与分卷归属

section("打开数据：已打开列表的合并与分卷归属")

func fakeDataset(id: String, name: String, zipParts: [Int: [ZipVolume]]? = nil) -> TileDataset {
    TileDataset(
        id: id,
        name: name,
        rootURL: URL(fileURLWithPath: id),
        layout: .webODM,
        zoomRange: 12...18,
        zipInfo: zipParts.map { ZipDatasetInfo(parts: $0) }
    )
}

let firstDataset = fakeDataset(id: "/tmp/甲", name: "甲")
let secondDataset = fakeDataset(id: "/tmp/乙", name: "乙")

// 「已经开着甲，再打开乙」：老的那份必须还在 —— 这是「别把老图层顶掉」的根子。
let mergedOnce = DatasetLocator.merging([firstDataset], with: [secondDataset])
expect(mergedOnce.count == 2, "打开第二份之后列表里应有两份（实际 \(mergedOnce.count)）")
expect(mergedOnce.first?.id == secondDataset.id, "新打开的应排在前面")
expect(mergedOnce.contains { $0.id == firstDataset.id }, "老的那份不该被顶掉")

// 重复打开同一份：只留一份，且留的是新扫到的那份描述。
let rescannedFirst = fakeDataset(id: firstDataset.id, name: "甲（重扫）")
let mergedAgain = DatasetLocator.merging([firstDataset, secondDataset], with: [rescannedFirst])
expect(mergedAgain.count == 2, "重复打开同一份不该加出第三份（实际 \(mergedAgain.count)）")
expect(mergedAgain.first?.name == "甲（重扫）", "同 id 时应留新扫到的那份")
expect(mergedAgain.filter { $0.id == firstDataset.id }.count == 1, "同 id 只应出现一次")

// 扫到空目录：现有列表原样保留。
expect(
    DatasetLocator.merging([firstDataset, secondDataset], with: []).map(\.id)
        == [firstDataset.id, secondDataset.id],
    "扫到空目录时不该动已有列表"
)

// 分卷归属：拖进来一个分卷时，要认出它属于哪一份数据。
let volumeA = ZipVolume(url: URL(fileURLWithPath: "/tmp/甲/z12/甲-0001.zip"), rowRange: 0...1023)
let volumeB = ZipVolume(url: URL(fileURLWithPath: "/tmp/乙/z12/乙-0001.zip"), rowRange: 0...1023)
let archiveA = fakeDataset(id: "/tmp/甲", name: "甲", zipParts: [12: [volumeA]])
let archiveB = fakeDataset(id: "/tmp/乙", name: "乙", zipParts: [12: [volumeB]])
expect(
    DatasetLocator.dataset(containingVolume: volumeB.url, in: [archiveA, archiveB])?.id == archiveB.id,
    "应认出分卷属于乙那份数据"
)
expect(
    DatasetLocator.dataset(containingVolume: URL(fileURLWithPath: "/tmp/丙/z12/丙-0001.zip"), in: [archiveA, archiveB]) == nil,
    "认不出归属的分卷应返回 nil"
)
expect(
    DatasetLocator.dataset(containingVolume: volumeA.url, in: [firstDataset]) == nil,
    "散文件目录里没有分卷，应返回 nil"
)

// 分卷所在目录是「层级目录」时，要认出**整份**数据的根目录（而不是只有 z12 那一层的残缺数据集）。
expect(DatasetLocator.isZoomLevelDirectoryName("12"), "「12」应认成层级目录")
expect(DatasetLocator.isZoomLevelDirectoryName("z12"), "「z12」应认成层级目录")
expect(DatasetLocator.isZoomLevelDirectoryName("Z07"), "「Z07」应认成层级目录")
expect(!DatasetLocator.isZoomLevelDirectoryName("福建省瓦片"), "数据集名不该认成层级目录")
expect(!DatasetLocator.isZoomLevelDirectoryName("z12副本"), "带后缀的目录名不该认成层级目录")
expect(
    DatasetLocator.datasetRoot(containing: syntheticRoot.appending(path: "2/瓦片-0001.zip"))
        .canonicalFilePath == syntheticRoot.canonicalFilePath,
    "分卷躺在层级目录里时，根目录应是数据集根"
)
expect(
    DatasetLocator.datasetRoot(containing: URL(fileURLWithPath: "/tmp/散装/z12/vol-0001.zip"))
        .canonicalFilePath == "/tmp/散装/z12",
    "上一层不是数据集时应退回分卷所在目录"
)
expect(
    DatasetLocator.datasetRoot(containing: URL(fileURLWithPath: "/tmp/散装/vol-0001.zip"))
        .canonicalFilePath == "/tmp/散装",
    "分卷不在层级目录里时，根目录就是它所在目录"
)

// 拖放给的目录 URL 常常带尾斜杠：同一份数据不能因此变成两个 id（列表里两行、叠加时去重失灵）。
expect(URL(fileURLWithPath: "/tmp/甲/").canonicalFilePath == "/tmp/甲", "规范路径应去掉尾斜杠")
expect(URL(fileURLWithPath: "/tmp/甲//").canonicalFilePath == "/tmp/甲", "连续尾斜杠也应去掉")
expect(URL(fileURLWithPath: "/").canonicalFilePath == "/", "根目录的斜杠要留着")
let syntheticRootWithSlash = URL(fileURLWithPath: syntheticRoot.canonicalFilePath + "/")
expect(
    DatasetLocator.makeDataset(at: syntheticRoot)?.id == DatasetLocator.makeDataset(at: syntheticRootWithSlash)?.id,
    "带不带尾斜杠扫出来的数据集应是同一份"
)
expect(
    syntheticRootWithSlash.path(percentEncoded: false).hasSuffix("/"),
    "前提：这个 URL 确实带尾斜杠（Foundation 对已存在的目录会保留它）"
)
expect(
    DatasetLocator.canonicalURL(syntheticRootWithSlash).canonicalFilePath == syntheticRoot.canonicalFilePath
        && !DatasetLocator.canonicalURL(syntheticRootWithSlash).path(percentEncoded: false).hasSuffix("/"),
    "canonicalURL 对已存在的目录也要真的去掉尾斜杠"
)

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
let workbook = try MeasurementExporter.excel(
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

// 少量测量也要能导出（空列表不应崩溃，也不该抛）。
expect((try? MeasurementExporter.excel([]))?.isEmpty == false, "空测量列表也应产出可打开的工作簿")

section("ZIP：deflate 压缩与解回")

do {
    /// 读第一个条目的「压缩方式」字段（本地文件头偏移 8）。
    func firstEntryMethod(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        guard bytes.count > 10 else { return -1 }
        return Int(bytes[8]) | Int(bytes[9]) << 8
    }

    // 表格 XML 里成片重复的字段：压完应当明显小一圈。
    let repetitive = Data(String(repeating: "侧边补测-119.12345678-正射影像-", count: 2000).utf8)
    let packed = try ZIP.stored([("a.xml", repetitive)])
    let raw = try ZIP.stored([("a.xml", repetitive)], compress: false)
    expect(firstEntryMethod(raw) == 0, "关掉压缩时应写成「存储」方式")
    expect(firstEntryMethod(packed) == 8, "重复内容应走 deflate（实际方式 \(firstEntryMethod(packed))）")
    expect(packed.count < raw.count / 2,
           "重复内容应压到一半以下（\(packed.count) vs \(raw.count) 字节）")
    if let entries = ZIP.parse(packed) {
        expect(entries.count == 1 && entries[0].name == "a.xml", "压缩条目应保留文件名")
        expect(entries[0].data == repetitive, "压缩条目应能逐字节解回")
    } else {
        expect(false, "自己压出来的 ZIP 应能自己读回")
    }

    // 压不动的极小条目要退回「存储」，不能为了走压缩把文件撑大。
    let tiny = try ZIP.stored([("b.txt", Data("abc".utf8))])
    expect(firstEntryMethod(tiny) == 0, "压不动的极小条目应退回存储方式")
    if let entries = ZIP.parse(tiny) {
        expect(entries.first?.data == Data("abc".utf8), "退回存储的条目内容应一致")
    } else {
        expect(false, "退回存储的 ZIP 也应能读回")
    }

    // 压不动的随机内容同样要能原样往返（不能只对「好压的」正确）。
    var noisy = Data(count: 8 * 1024)
    var seed: UInt32 = 0x9E37_79B9
    for index in 0..<noisy.count {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        noisy[index] = UInt8((seed >> 16) & 0xFF)
    }
    if let entries = ZIP.parse(try ZIP.stored([("c.bin", noisy)])) {
        expect(entries.first?.data == noisy, "随机内容应能原样往返")
    } else {
        expect(false, "随机内容的 ZIP 应能读回")
    }

    // 长度字段一律不许截断：超过 ZIP32 上限时必须抛错，而不是写出一个谎报长度的包。
    // （真造 4 GB 数据太慢，这里直接验条目数上限：65536 个条目已经超出 ZIP32 的表达。）
    do {
        let many = (0...UInt16.max).map { ("t\($0).txt", Data("x".utf8)) }
        _ = try ZIP.stored(many, compress: false)
        expect(false, "超过 65535 个条目应当抛「太大」，而不是把条目数截断")
    } catch let error as ZIPError {
        expect(error == .tooLarge, "超过 65535 个条目应抛 tooLarge（实际 \(error)）")
    } catch {
        expect(false, "超过 65535 个条目应抛 ZIPError（实际 \(error)）")
    }

    // 坏数据不许「读出一个错的还当成功」：把压缩体改一个字节，校验和必须拦住它。
    var broken = [UInt8](packed)
    broken[broken.count / 2] ^= 0xFF
    expect(ZIP.parse(Data(broken)) == nil, "压缩块被改坏后应判为非法，而不是读出错误内容")
}

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
    let target = URL(fileURLWithPath: CommandLine.arguments[1])
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: target.path(percentEncoded: false), isDirectory: &isDirectory)
    if !isDirectory.boolValue {
        await rasterCheck(url: target)
    } else {
        datasetCheck(root: target)
    }
}

@MainActor
func datasetCheck(root: URL) {
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
        // 散文件目录按「布局 + 扩展名」拼路径；zip 分卷按「行/列 + 扩展名」在包内找名字。
        if let directory = source as? DirectoryTileSource {
            expect(directory.fileCandidates(for: mid).count == dataset.layout.fileExtensions.count,
                   "\(dataset.name) 生成候选路径")
        } else if let archive = source as? ZipTileSource {
            expect(!archive.fileExtensions.isEmpty, "\(dataset.name) 应有候选扩展名")
            expect(archive.parts[dataset.zoomRange.upperBound] != nil, "\(dataset.name) 应有该层级的分卷")
        } else {
            expect(false, "\(dataset.name) 的数据来源类型不认识")
        }
    }
    expect(discovered.count >= 1, "应在测试目录中找到至少 1 个数据集")
}

/// 单幅影像体检：`./Scripts/run-checks.sh /path/to/orthophoto.tif`
///
/// 打印尺寸、坐标基准、地面分辨率与覆盖范围，再按窗口首屏的样子取几块图，
/// 并统计首屏耗时（大图没有内建概览时这一步会明显变慢，正好量出来）。
/// `EUCLID_RASTER_DUMP=<目录>` 时把解出来的瓦片写成 PNG，便于目视核对。
// MARK: - 影像块缓存的收益实测

/// 量一下「跨瓦片块缓存」在真实影像上的收益（`EUCLID_BENCH_RASTER=1` 且传入影像文件时跑）。
///
/// 两个场景，各自比较「每次重铺前清空块缓存」与「缓存热着」两条路：
/// 1. 一屏瓦片：拖动时一屏要重铺的量；
/// 2. 连续缩放：同一块影像在相邻层级上被反复取（缩放时最像「边缘一直在加载」的那条路）。
@MainActor
func chunkCacheBenchmark(dataset: RasterDataset, source: RasterTileSource) async {
    section("实测：影像块缓存的收益（\(dataset.name)）")
    let path = dataset.fileURL.path(percentEncoded: false)
    let cache = TIFFChunkCache.shared
    let detailZoom = min(30, max(0, Int(ceil(dataset.maximumDataZoom))))
    let rect = dataset.worldRect

    func tile(zoom: Int, centerX: Double, centerY: Double) -> SlippyTile {
        let count = Double(1 << zoom)
        let limit = (1 << zoom) - 1
        return SlippyTile(
            zoom: zoom,
            x: min(max(Int(centerX * count), 0), limit),
            y: min(max(Int(centerY * count), 0), limit)
        )
    }

    func render(_ tiles: [SlippyTile]) async -> Double {
        let start = Date()
        for item in tiles { _ = await source.image(for: item) }
        return Date().timeIntervalSince(start) * 1000
    }

    // 场景一：中心往外 4 × 3 块，正好一屏。
    let centerX = rect.midX, centerY = rect.midY
    var screen: [SlippyTile] = []
    for dy in -1...1 {
        for dx in -2...1 {
            let count = Double(1 << detailZoom)
            let limit = (1 << detailZoom) - 1
            let x = min(max(Int(centerX * count) + dx, 0), limit)
            let y = min(max(Int(centerY * count) + dy, 0), limit)
            screen.append(SlippyTile(zoom: detailZoom, x: x, y: y))
        }
    }
    cache.invalidate(path: path)
    let coldScreen = await render(screen)
    let warmScreen = await render(screen)
    print(String(format: "  一屏 %d 张（z%d）：冷 %.0f ms → 热 %.0f ms（%.2f×）",
                 screen.count, detailZoom, coldScreen, warmScreen, coldScreen / max(warmScreen, 0.001)))

    // 缓存只该省时间，不该换像素：把一屏的内容在「冷 / 热」两条路上各指纹一遍。
    func fingerprint(_ tiles: [SlippyTile]) async -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for item in tiles {
            guard let image = await source.image(for: item), let bytes = rgbaBytes(of: image) else {
                hash = hash &* 31 &+ 0xFFFF
                continue
            }
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
            hash = hash &* 31 &+ UInt64(bytes.count)
        }
        return hash
    }
    cache.invalidate(path: path)
    let coldFingerprint = await fingerprint(screen)
    let warmFingerprint = await fingerprint(screen)
    expect(coldFingerprint == warmFingerprint,
           "同一屏在「块缓存冷 / 热」两条路上解出来的像素应完全一致")
    print(String(format: "  同一屏指纹：冷 %016llx → 热 %016llx", coldFingerprint, warmFingerprint))

    // 场景二：以中心为锚，连续缩放 ±3 级（同一块影像在不同分辨率上被反复取）。
    let zooms = (-3...3).map { detailZoom + $0 }.filter { (0...30).contains($0) }
    var zoomTiles: [SlippyTile] = []
    for zoom in zooms {
        // 每级都往同一个方向偏一点点（按影像自身尺寸的比例，保证仍然落在影像内），
        // 模拟「一边缩放一边拖」。
        zoomTiles.append(tile(
            zoom: zoom,
            centerX: centerX + 0.03 * rect.width,
            centerY: centerY + 0.02 * rect.height
        ))
    }
    var coldZoom = 0.0
    for item in zoomTiles {
        cache.invalidate(path: path)
        coldZoom += await render([item])
    }
    _ = await render(zoomTiles)   // 先把缓存烘热，再计时
    let warmZoom = await render(zoomTiles)
    print(String(format: "  连续缩放 %d 级：冷 %.0f ms → 热 %.0f ms（%.2f×）",
                 zoomTiles.count, coldZoom, warmZoom, coldZoom / max(warmZoom, 0.001)))

    let stats = cache.stats()
    print(String(format: "  块缓存 %d 块 / %.1f MB，命中 %d、未中 %d，句柄 %d 个",
                 stats.entries, stats.megabytes, stats.hits, stats.misses, stats.readers))
}

@MainActor
func rasterCheck(url: URL) async {
    section("单幅影像：\(url.lastPathComponent)")
    guard let dataset = try? RasterLoader.load(url: url) else {
        expect(false, "应能读出单幅影像（\(url.lastPathComponent)）")
        return
    }
    print("  尺寸 \(dataset.pixelSizeText)　体积 \(dataset.fileSizeText)　\(dataset.compression)　\(dataset.bitsPerSample) 位"
        + (dataset.hasAlpha ? "　含 alpha" : ""))
    print("  坐标基准 \(dataset.crsName)" + (dataset.hasOverviews ? "　内建概览：有" : "　内建概览：无"))
    if let gsd = dataset.groundSampleDistance {
        print(String(format: "  地面分辨率 %.3f 米/像素", gsd))
    }
    let rect = dataset.worldRect
    let northWest = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.minX, y: rect.minY))
    let southEast = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.maxX, y: rect.maxY))
    print(String(
        format: "  范围 lon %.7f…%.7f　lat %.7f…%.7f",
        northWest.longitude, southEast.longitude, southEast.latitude, northWest.latitude
    ))
    print(String(format: "  原始比例 z%.2f　虚拟层级 z0–z%d", dataset.maximumDataZoom, dataset.zoomRange.upperBound))

    expect(dataset.pixelWidth > 0 && dataset.pixelHeight > 0, "应读出像素尺寸")
    expect(dataset.isGeoreferenced, "应认出地理参考（否则按未配准打开）")
    expect(rect.width > 0 && rect.height > 0, "覆盖范围不应退化")
    expect(northWest.longitude >= -180 && northWest.longitude <= 180, "经度应在合法范围内")
    expect(northWest.latitude >= -90 && northWest.latitude <= 90, "纬度应在合法范围内")
    if let gsd = dataset.groundSampleDistance {
        expect(gsd > 0.0001 && gsd < 1000, "地面分辨率应在合理范围（实际 \(gsd) 米/像素）")
    }

    let source = dataset.source
    let dumpDirectory = ProcessInfo.processInfo.environment["EUCLID_RASTER_DUMP"]
    if let dumpDirectory { try? FileManager.default.createDirectory(atPath: dumpDirectory, withIntermediateDirectories: true) }

    func dump(_ image: CGImage?, _ name: String) {
        guard let dumpDirectory, let image else { return }
        let url = URL(fileURLWithPath: dumpDirectory).appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // 1) 「原始比例」那一级：看细节与清晰度。
    let detailZoom = min(30, max(0, Int(ceil(dataset.maximumDataZoom))))
    let count = Double(1 << detailZoom)
    let centerTile = SlippyTile(
        zoom: detailZoom,
        x: min(max(Int(rect.midX * count), 0), (1 << detailZoom) - 1),
        y: min(max(Int(rect.midY * count), 0), (1 << detailZoom) - 1)
    )
    var start = Date()
    let detail = await source.image(for: centerTile)
    let detailMilliseconds = Date().timeIntervalSince(start) * 1000
    expect(detail != nil, "原始比例附近应能取到图（z\(detailZoom)）")
    print(String(format: "  原始比例取图 z%d/%d/%d：%.0f ms%@",
                 detailZoom, centerTile.x, centerTile.y, detailMilliseconds,
                 detail.map { "（\($0.width)×\($0.height)）" } ?? "（失败）"))
    dump(detail, "detail.png")

    // 整幅概览：走的是「缩放时挑低分辨率级」那条路，用 alpha 均值与直方图核对是否丢内容。
    start = Date()
    let overview = dataset.renderOverview(maxPixelSize: 1024)
    let overviewMilliseconds = Date().timeIntervalSince(start) * 1000
    expect(overview != nil, "应能渲染整幅概览")
    if let overview, let pixels = rgbaBytes(of: overview) {
        var alphaSum = 0
        for index in stride(from: 3, to: pixels.count, by: 4) { alphaSum += Int(pixels[index]) }
        let meanAlpha = Double(alphaSum) / Double(pixels.count / 4) / 255
        print(String(format: "  整幅概览 %d×%d：%.0f ms，平均 alpha %.4f",
                     overview.width, overview.height, overviewMilliseconds, meanAlpha))
        expect(meanAlpha > 0.55 && meanAlpha < 0.75,
               "整幅概览的平均 alpha 应与数据一致（约 0.63，实际 \(meanAlpha)）")
    }
    dump(overview, "overview.png")
    // 再渲染一份 2048 宽的：它会挑到与「深缩放时的瓦片」同一级概览（3751 那一级），
    // 用来区分「数据本身的空洞」与「取图路径丢内容」。
    let coarse = dataset.renderOverview(maxPixelSize: 2048)
    dump(coarse, "overview-2048.png")

    // 深缩放时的单块瓦片：与上面那份概览用的是同一级数据，
    // 因此它必须同样密实（中心区域本来就是不透明的）。
    let tileZoom = max(0, Int(dataset.maximumDataZoom.rounded(.down)) - 1)
    let tileCount = Double(1 << tileZoom)
    let sourceTile = SlippyTile(
        zoom: tileZoom,
        x: min(max(Int(rect.midX * tileCount), 0), (1 << tileZoom) - 1),
        y: min(max(Int(rect.midY * tileCount), 0), (1 << tileZoom) - 1)
    )
    start = Date()
    let tileImage = await source.image(for: sourceTile)
    let tileMilliseconds = Date().timeIntervalSince(start) * 1000
    if let tileImage, let pixels = rgbaBytes(of: tileImage) {
        var alphaSum = 0
        for index in stride(from: 3, to: pixels.count, by: 4) { alphaSum += Int(pixels[index]) }
        let meanAlpha = Double(alphaSum) / Double(pixels.count / 4) / 255
        print(String(format: "  深缩放瓦片 z%d/%d/%d：%.0f ms，平均 alpha %.4f",
                     tileZoom, sourceTile.x, sourceTile.y, tileMilliseconds, meanAlpha))
        expect(meanAlpha > 0.9, "深缩放瓦片应密实（中心区域不透明，实际平均 alpha \(meanAlpha)）")
    } else {
        expect(false, "深缩放瓦片应能取到图（z\(tileZoom)）")
    }
    dump(tileImage, "tile-deep.png")

    // `EUCLID_BENCH_RASTER=1` 时量一下跨瓦片块缓存的收益（要跑很多次取图，默认不开）。
    if ProcessInfo.processInfo.environment["EUCLID_BENCH_RASTER"] != nil {
        await chunkCacheBenchmark(dataset: dataset, source: source)
    }

    // `EUCLID_RASTER_PYRAMID=<目录>` 时顺便真生成一套瓦片（用于实测吞吐与产物核对）。
    if let pyramid = ProcessInfo.processInfo.environment["EUCLID_RASTER_PYRAMID"] {
        let options = TilePyramidOptions(tileSize: 512, format: .jpeg, compressionQuality: 0.85, concurrency: 4)
        let range = TilePyramidExporter.suggestedZoomRange(for: dataset)
        if let plan = TilePyramidExporter.plan(
            for: dataset, zoomRange: range, options: options,
            outputDirectory: URL(fileURLWithPath: pyramid)
        ), let summary = try? await TilePyramidExporter().run(
            raster: dataset, plan: plan, options: options
        ) {
            print(String(
                format: "  生成瓦片 z%d–z%d：计划 %d，写出 %d，跳过 %d，失败 %d，%.1f MB，用时 %.1f s",
                range.lowerBound, range.upperBound, plan.totalTileCount,
                summary.written, summary.skipped, summary.failed,
                Double(summary.bytes) / 1_000_000, summary.elapsed
            ))
            expect(summary.failed == 0, "真实影像生成瓦片不应有失败（\(summary.failed)）")
            expect(summary.written > 0, "真实影像应写出瓦片")
            expect(DatasetLocator.discover(at: URL(fileURLWithPath: pyramid)).count == 1,
                   "生成的目录应被识别为数据集")
        } else {
            expect(false, "真实影像应能规划并生成瓦片")
        }
    }

    // 2) 首屏：按「适配窗口」的层级，数一数要几块、总共多久。
    let viewport = CGSize(width: 808, height: 808)
    let fitZoom = min(detailZoom, max(0, Int(floor(log2(viewport.width / (rect.width * 512))))))
    let fitCount = Double(1 << fitZoom)
    let columns = Int((rect.width * Double(1 << fitZoom)).rounded(.up)) + 1
    let rows = Int((rect.height * Double(1 << fitZoom)).rounded(.up)) + 1
    start = Date()
    var loaded = 0
    for column in 0..<columns {
        for row in 0..<rows {
            let tile = SlippyTile(
                zoom: fitZoom,
                x: min(max(Int(rect.minX * fitCount) + column, 0), (1 << fitZoom) - 1),
                y: min(max(Int(rect.minY * fitCount) + row, 0), (1 << fitZoom) - 1)
            )
            if await source.image(for: tile) != nil { loaded += 1 }
        }
    }
    let fitMilliseconds = Date().timeIntervalSince(start) * 1000
    print(String(format: "  首屏 z%d：%d/%d 块，共 %.0f ms", fitZoom, loaded, columns * rows, fitMilliseconds))
    expect(loaded > 0, "首屏应至少取到一块图")
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
    // 范围取一座公开城市的通用包围盒（与任何具体测区无关），只用来考算法性质。
    let city = GeoBounds(west: 120.10, south: 30.20, east: 120.32, north: 30.38)
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

    let bounds = GeoBounds(west: 120.10, south: 30.20, east: 120.32, north: 30.38)
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
        bounds: GeoBounds(west: 119.8, south: 30.1, east: 120.7, north: 30.8),
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

do {
    // 偏移基准下的下载计划：瓦片编号要按该基准的网格算。
    let bounds = GeoBounds(west: 120.10, south: 30.20, east: 120.12, north: 30.22)
    let plain = try TileDownloadPlan(bounds: bounds, zoomRange: 16...16)
    let shifted = try TileDownloadPlan(bounds: bounds, zoomRange: 16...16, datum: .gcj02)
    expect(plain.datum == .wgs84, "默认基准应为 WGS84")
    expect(shifted.datum == .gcj02, "计划应记录数据源基准")
    expect(plain.bounds == bounds, "计划记录的范围应仍是用户给的 WGS84 范围")
    let plainRange = plain.ranges[0]
    let shiftedRange = shifted.ranges[0]
    expect(plainRange != shiftedRange, "GCJ-02 计划的瓦片范围应与 WGS84 不同")
    print("    z16 范围：WGS84 列 \(plainRange.columns) 行 \(plainRange.rows) / "
        + "GCJ-02 列 \(shiftedRange.columns) 行 \(shiftedRange.rows)")
    expect(shiftedRange.columns.lowerBound >= plainRange.columns.lowerBound, "GCJ-02 应向东北方向平移列号")
    expect(shiftedRange.rows.lowerBound <= plainRange.rows.lowerBound, "GCJ-02 应向东北方向平移行号")
}

section("坐标基准（GCJ-02 / BD-09）")

do {
    // 境外不做偏移：东京、伦敦、纽约都应与输入完全一致。
    for coordinate in [
        GeoCoordinate(longitude: 139.6917, latitude: 35.6895),
        GeoCoordinate(longitude: -0.1276, latitude: 51.5072),
        GeoCoordinate(longitude: -74.0060, latitude: 40.7128),
    ] {
        let shifted = Datum.gcj02.fromWGS84(coordinate)
        expectClose(shifted.longitude, coordinate.longitude, accuracy: 1e-12, "境外经度不应偏移")
        expectClose(shifted.latitude, coordinate.latitude, accuracy: 1e-12, "境外纬度不应偏移")
    }

    // 境内偏移量级：城区应在百米级，且不应超过 1 km。
    for coordinate in [
        GeoCoordinate(longitude: 116.3974, latitude: 39.9093),   // 北京
        GeoCoordinate(longitude: 121.4737, latitude: 31.2304),   // 上海
        GeoCoordinate(longitude: 113.2644, latitude: 23.1291),   // 广州
        GeoCoordinate(longitude: 119.2965, latitude: 26.0745),   // 福州
    ] {
        let magnitude = Datum.gcj02.offsetMetersMagnitude(at: coordinate)
        expect(magnitude > 80 && magnitude < 1000, "GCJ-02 偏移应在百米量级（实际 \(Int(magnitude)) m）")
    }

    // 往返：WGS84 → GCJ-02 → WGS84，误差应在厘米级（1e-7° ≈ 1.1 cm）。
    for coordinate in [
        GeoCoordinate(longitude: 116.3974, latitude: 39.9093),
        GeoCoordinate(longitude: 119.2965, latitude: 26.0745),
        GeoCoordinate(longitude: 87.6168, latitude: 43.8256),    // 乌鲁木齐
    ] {
        let gcj = Datum.gcj02.fromWGS84(coordinate)
        let back = Datum.gcj02.toWGS84(gcj)
        expectClose(back.longitude, coordinate.longitude, accuracy: 1e-7, "GCJ-02 经度往返")
        expectClose(back.latitude, coordinate.latitude, accuracy: 1e-7, "GCJ-02 纬度往返")

        let bd = Datum.bd09.fromWGS84(coordinate)
        let backBD = Datum.bd09.toWGS84(bd)
        expectClose(backBD.longitude, coordinate.longitude, accuracy: 1e-6, "BD-09 经度往返")
        expectClose(backBD.latitude, coordinate.latitude, accuracy: 1e-6, "BD-09 纬度往返")
    }

    // 三档基准的一致性：WGS84 不动，GCJ-02 偏移，BD-09 在 GCJ-02 基础上再偏一点。
    let beijing = GeoCoordinate(longitude: 116.3974, latitude: 39.9093)
    expect(Datum.wgs84.fromWGS84(beijing) == beijing, "WGS84 基准应为恒等变换")
    let gcj = Datum.gcj02.fromWGS84(beijing)
    let bd = Datum.bd09.fromWGS84(beijing)
    let gcjToBD = DatumShift.gcj02ToBD09(gcj)
    expectClose(bd.longitude, gcjToBD.longitude, accuracy: 1e-12, "BD-09 应等于 GCJ-02 再偏移")
    expectClose(bd.latitude, gcjToBD.latitude, accuracy: 1e-12, "BD-09 纬度应与 GCJ-02 偏移一致")

    // 世界坐标偏移（叠加对齐用）：方向合理、量级与米制偏移一致。
    let worldBase = WebMercator.normalized(beijing)
    let worldShifted = WebMercator.normalized(Datum.gcj02.fromWGS84(beijing))
    let worldOffset = CGPoint(x: worldShifted.x - worldBase.x, y: worldShifted.y - worldBase.y)
    let groundMeters = WebMercator.groundMetersPerWorldUnit(latitude: beijing.latitude)
    let shiftedMeters = (worldOffset.x * worldOffset.x + worldOffset.y * worldOffset.y).squareRoot() * groundMeters
    let offsetMeters = Datum.gcj02.offsetMetersMagnitude(at: beijing)
    expectClose(shiftedMeters, offsetMeters, accuracy: 1, "世界坐标偏移应与米制偏移一致")
    let offsetVector = Datum.gcj02.offsetMeters(at: beijing)
    expect(offsetVector.x > 0, "北京一带 GCJ-02 应向东北偏（东向分量为正）")

    // 与公开流传的实现对照：WGS84(116.404, 39.915) 的 GCJ-02 常见结果为 (116.410244, 39.916404)。
    let reference = Datum.gcj02.fromWGS84(GeoCoordinate(longitude: 116.404, latitude: 39.915))
    print(String(format: "    WGS84(116.404, 39.915) → GCJ-02(%.6f, %.6f)", reference.longitude, reference.latitude))
    expectClose(reference.longitude, 116.410244, accuracy: 3e-5, "GCJ-02 经度应与公开实现一致")
    expectClose(reference.latitude, 39.916404, accuracy: 3e-5, "GCJ-02 纬度应与公开实现一致")

    // 基准的标题与短名要齐（界面直接用）。
    expect(Datum.allCases.count == 3, "应有三档基准")
    expect(Datum.allCases.allSatisfy { !$0.title.isEmpty && !$0.shortTitle.isEmpty }, "每档基准都应有名称")
}

section("测量结果缓存")

do {
    // 界面上同一条测量会被反复取用（平移缩放重绘、检查器刷新），
    // 因此求值带缓存：这里逐项核对「缓存路径 = 直算路径」以及命中与淘汰的行为。
    let polyline = [
        GeoCoordinate(longitude: 120.100, latitude: 30.200),
        GeoCoordinate(longitude: 120.110, latitude: 30.210),
        GeoCoordinate(longitude: 120.120, latitude: 30.205),
    ]
    let polygon = [
        GeoCoordinate(longitude: 120.100, latitude: 30.200),
        GeoCoordinate(longitude: 120.120, latitude: 30.200),
        GeoCoordinate(longitude: 120.120, latitude: 30.220),
        GeoCoordinate(longitude: 120.100, latitude: 30.220),
    ]
    let circle = [
        GeoCoordinate(longitude: 120.110, latitude: 30.210),
        GeoCoordinate(longitude: 120.120, latitude: 30.210),
    ]

    MeasurementCalculator.resetResultCache()
    for (kind, points) in [
        (MeasurementKind.distance, polyline),
        (MeasurementKind.area, polygon),
        (MeasurementKind.circle, circle),
        (MeasurementKind.point, [polyline[0]]),
    ] {
        expect(
            MeasurementCalculator.evaluate(kind: kind, points: points)
                == MeasurementCalculator.evaluateUncached(kind: kind, points: points),
            "缓存结果应与直算逐字段一致（\(kind.displayName)）"
        )
    }

    // 同一条测量再取多少次都是命中缓存，不会重算。
    let hitsBefore = MeasurementCalculator.resultCacheHits
    _ = MeasurementCalculator.evaluate(kind: .distance, points: polyline)
    expect(
        MeasurementCalculator.resultCacheHits == hitsBefore + 1,
        "再取同一条测量应命中缓存"
    )
    _ = MeasurementCalculator.evaluate(kind: .distance, points: polyline)
    expect(
        MeasurementCalculator.resultCacheHits == hitsBefore + 2,
        "重复取用应持续命中缓存"
    )

    // 顶点动了就是另一个键：结果要走重算，且与直算一致。
    var moved = polyline
    moved[2].latitude += 0.002
    let movedResult = MeasurementCalculator.evaluate(kind: .distance, points: moved)
    expect(movedResult != MeasurementCalculator.evaluate(kind: .distance, points: polyline),
           "顶点变了应重算，而不是复用旧结果")
    expect(movedResult == MeasurementCalculator.evaluateUncached(kind: .distance, points: moved),
           "改动后的结果也应与直算一致")

    // 圆的度量（含 360 点采样）同样按「圆心 + 半径」缓存。
    let metricsFirst = MeasurementCalculator.circleMetrics(center: circle[0], radius: 1_000)
    let hitsBeforeRing = MeasurementCalculator.resultCacheHits
    let metricsAgain = MeasurementCalculator.circleMetrics(center: circle[0], radius: 1_000)
    expect(MeasurementCalculator.resultCacheHits == hitsBeforeRing + 1,
           "同一个圆第二次取度量应命中缓存")
    expect(metricsFirst.ring == metricsAgain.ring
        && metricsFirst.circumference == metricsAgain.circumference,
           "命中的圆度量应与第一次逐字段一致")
    expect(metricsFirst.ring.count == MeasurementCalculator.circleSamples,
           "圆的采样点应一并缓存下来（\(MeasurementCalculator.circleSamples) 点）")
    expect(metricsFirst.circumference > 0 && metricsFirst.area > 0,
           "圆的周长与面积应为正")
    let freshRing = Geodesy.circleRing(center: circle[0], radius: 1_000)
    expectClose(metricsAgain.circumference, Geodesy.perimeter(of: freshRing), accuracy: 1e-9,
                "缓存里的圆周长应与重新采样一致")
    expectClose(metricsAgain.area, Geodesy.area(of: freshRing), accuracy: 1e-9,
                "缓存里的圆面积应与重新采样一致")

    // 容量有上限：塞进去再多也不会无限增长，且被淘汰的条目重新求值仍然正确。
    MeasurementCalculator.resetResultCache()
    for index in 0..<(MeasurementCalculator.resultCacheLimit + 40) {
        let offset = Double(index) * 0.0001
        _ = MeasurementCalculator.evaluate(kind: .distance, points: [
            GeoCoordinate(longitude: 120.0 + offset, latitude: 30.0),
            GeoCoordinate(longitude: 120.001 + offset, latitude: 30.001),
        ])
    }
    expect(MeasurementCalculator.resultCacheCount <= MeasurementCalculator.resultCacheLimit,
           "缓存条目数不应超过上限（实际 \(MeasurementCalculator.resultCacheCount)，上限 \(MeasurementCalculator.resultCacheLimit)）")
    expect(MeasurementCalculator.resultCacheCount >= MeasurementCalculator.resultCacheLimit / 2,
           "缓存应真的被用起来（实际 \(MeasurementCalculator.resultCacheCount) 条）")
    expect(
        MeasurementCalculator.evaluate(kind: .distance, points: polyline)
            == MeasurementCalculator.evaluateUncached(kind: .distance, points: polyline),
        "被淘汰的测量重新求值应仍与直算一致"
    )

    // 时间对比只打印出来看看，不做断言（机器负载会影响绝对值）。
    let dense = (0..<200).map { index in
        GeoCoordinate(
            longitude: 120.10 + Double(index) * 1e-5,
            latitude: 30.20 + Double(index % 13) * 1e-5
        )
    }
    let iterations = 200
    var start = Date()
    for _ in 0..<iterations { _ = MeasurementCalculator.evaluateUncached(kind: .area, points: dense) }
    let uncachedMs = Date().timeIntervalSince(start) * 1000
    MeasurementCalculator.resetResultCache()
    _ = MeasurementCalculator.evaluate(kind: .area, points: dense)
    start = Date()
    for _ in 0..<iterations { _ = MeasurementCalculator.evaluate(kind: .area, points: dense) }
    let cachedMs = Date().timeIntervalSince(start) * 1000
    print(String(
        format: "    200 点多边形 × %d 次：每帧重算 %.1f ms，缓存命中 %.1f ms（快 %.0f 倍）",
        iterations, uncachedMs, cachedMs, uncachedMs / max(cachedMs, 0.0001)
    ))
    expect(cachedMs < uncachedMs, "缓存命中应比重算快")
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

// MARK: - 单幅影像（TIFF 解码、投影与地理参考）

/// 仓库根下的 `Fixtures/TIFF`（按源文件位置定位，不受当前工作目录影响）。
var tiffFixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TileKitCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
        .appending(path: "Fixtures/TIFF")
}

/// 把一张图读出 RGBA8 字节（两边都走同一条路径，因此比较结果不受 y 轴方向影响）。
func rgbaBytes(of image: CGImage) -> [UInt8]? {
    let width = image.width, height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return ok ? buffer : nil
}

func imageContents(of url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

section("单幅影像：TIFF 解码（对照 libtiff 写出的样本）")

do {
    var expected: [UInt8] = []
    if let expectedImage = imageContents(of: tiffFixtures.appending(path: "base.png")),
       let bytes = rgbaBytes(of: expectedImage) {
        expected = bytes
    } else {
        expect(false, "读不到参照图 base.png（\(tiffFixtures.path(percentEncoded: false))）")
    }

    struct Fixture {
        var file: String
        var compression: String
        var note: String
    }
    let fixtures = [
        Fixture(file: "rgba_strip_none.tif", compression: "未压缩", note: "横条 + 未压缩"),
        Fixture(file: "rgba_tile_deflate_p2.tif", compression: "Deflate", note: "分块 + Deflate + Predictor 2"),
        Fixture(file: "rgba_strip_lzw.tif", compression: "LZW", note: "横条 + LZW + Predictor 2"),
        Fixture(file: "rgba_strip_packbits.tif", compression: "PackBits", note: "横条 + PackBits"),
    ]

    for fixture in fixtures {
        let url = tiffFixtures.appending(path: fixture.file)
        guard let dataset = try? RasterLoader.load(url: url) else {
            expect(false, "\(fixture.file) 应能打开")
            continue
        }
        expect(dataset.pixelWidth == 32 && dataset.pixelHeight == 32,
               "\(fixture.file) 应读出 32 × 32")
        expect(dataset.compression == fixture.compression,
               "\(fixture.file) 压缩方式应识别为 \(fixture.compression)（实际 \(dataset.compression)）")
        expect(dataset.hasAlpha, "\(fixture.file) 应认出 alpha 通道")

        guard let image = dataset.renderOverview(maxPixelSize: 32),
              let actual = rgbaBytes(of: image) else {
            expect(false, "\(fixture.file) 应能解出整幅图")
            continue
        }
        expect(actual.count == expected.count, "\(fixture.file) 解出的字节数应与参照一致")
        var mismatches = 0
        var firstMismatch = -1
        for index in 0..<min(actual.count, expected.count) where actual[index] != expected[index] {
            mismatches += 1
            if firstMismatch < 0 { firstMismatch = index }
        }
        if mismatches > 0, firstMismatch >= 0 {
            let pixel = firstMismatch / 4
            print("    \(fixture.note)：首个不同点在像素 (\(pixel % 32), \(pixel / 32))，"
                + "期望 \(Array(expected[firstMismatch..<min(firstMismatch + 4, expected.count)]))，"
                + "实际 \(Array(actual[firstMismatch..<min(firstMismatch + 4, actual.count)]))")
        }
        expect(mismatches == 0, "\(fixture.note)：解出的像素应与源图逐点一致（不同 \(mismatches) 个字节）")
    }

    // GeoTIFF：标签解析 + 定位。四角由 PROJ 9.7（cs2cs）算出，容差 1e-7 度（约 1 cm）。
    let geoURL = tiffFixtures.appending(path: "geo_utm50_deflate.tif")
    if let dataset = try? RasterLoader.load(url: geoURL) {
        expect(dataset.isGeoreferenced, "geoTIFF 应被认成已配准")
        expect(dataset.crsName.contains("32650"), "应认出 EPSG:32650（实际 \(dataset.crsName)）")
        let rect = dataset.worldRect
        let northWest = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.minX, y: rect.minY))
        let southEast = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.maxX, y: rect.maxY))
        // 注意：等东坐标线在 UTM 里是斜的，所以影像的四个角和轴对齐包围盒的四个角并不重合
        // （包围盒的西边取西南角的经度、北边取西北角的纬度）。参考值由 PROJ 9.7 的 cs2cs 算出。
        expectClose(northWest.longitude, 117.0000000000, accuracy: 1e-8, "包围盒西边（西南角）经度")
        expectClose(northWest.latitude, 40.6508565156, accuracy: 1e-8, "包围盒北边（西北角）纬度")
        expectClose(southEast.longitude, 117.0000189232, accuracy: 1e-8, "包围盒东边（东北角）经度")
        expectClose(southEast.latitude, 40.6508421030, accuracy: 1e-8, "包围盒南边（东南角）纬度")
        if let gsd = dataset.groundSampleDistance {
            expectClose(gsd, 0.049995, accuracy: 1e-4, "geoTIFF 地面分辨率应为像素尺度")
        }
    } else {
        expect(false, "geoTIFF 样本应能打开")
    }
}

section("单幅影像：浮点样本 / 分离平面 / Predictor 3（对照 libtiff 写出的样本）")

do {
    // 两份样本由 libtiff 的 `tiffcp` 从「未压缩 float32」转出（命令记在 Fixtures/TIFF/README.md）：
    // 单波段的 DEM 是连续存放 + Predictor 3，三波段那份是分离平面（PlanarConfiguration = 2）。
    // 期望值就是生成时的解析式，所以这一轮同时验了「解压」「预测还原」「按样本取值」三件事。
    func elevation(x: Int, y: Int) -> Float {
        let dx = Double(x) - 300, dy = Double(y) - 200
        let bump = 200.0 * exp(-(dx * dx + dy * dy) / (2 * 60 * 60))
        return Float(100.0 + 50.0 * sin(Double(x) / 80) * cos(Double(y) / 60) + bump)
    }

    let demURL = tiffFixtures.appending(path: "dem_f32_p3.tif")
    if let dataset = try? RasterLoader.load(url: demURL) {
        expect(dataset.pixelWidth == 600 && dataset.pixelHeight == 400, "DEM 样本应读出 600 × 400")
        expect(dataset.bitsPerSample == 32, "DEM 样本每个样本 32 位（实际 \(dataset.bitsPerSample)）")
        expect(dataset.isGeoreferenced, "DEM 样本是配准过的 GeoTIFF")
        if let gsd = dataset.groundSampleDistance {
            expectClose(gsd, 0.5, accuracy: 1e-3, "DEM 地面分辨率应为 0.5 米/像素")
        }
        // 画面上能不能看出来：整幅渲染必须成功，而且中间那座高地要比角落亮。
        if let image = dataset.renderOverview(maxPixelSize: 240), let bytes = rgbaBytes(of: image) {
            let width = image.width
            func gray(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * width + x) * 4]) }
            let center = gray(width / 2, image.height / 2)
            let corner = gray(2, 2)
            expect(center > corner, "浮点影像按分位拉伸后，中间的高地应比角落亮（\(center) vs \(corner)）")
        } else {
            expect(false, "DEM 样本应能渲染出整幅缩略图")
        }
    } else {
        expect(false, "DEM 样本（float32 + Predictor 3）应能打开")
    }

    // 按样本取值：与解析式逐点比（容差按 float32 的量级放）。
    if let reader = RasterSampleReader.open(url: demURL) {
        expect(reader.isFloat, "DEM 应认出浮点样本")
        expect(reader.bandCount == 1, "DEM 应认出单波段")
        expect(reader.isElevationLike, "单波段浮点 + 有地理参考 = 高程数据")
        var worst: Float = 0
        for (x, row) in [(0, 0), (37, 11), (300, 200), (599, 399), (256, 128)] {
            guard let value = reader.value(column: Double(x), row: Double(row)) else {
                expect(false, "DEM 在像素 (\(x), \(row)) 应读得到高程")
                continue
            }
            worst = max(worst, abs(value - elevation(x: x, y: 400 - row)))
        }
        expect(worst < 1e-3, "DEM 逐点高程应与生成时的解析式一致（最大偏差 \(worst)）")

        // 网格 + 剖面：同一套取值路径的两种用法。
        if let grid = reader.grid(rect: CGRect(x: 0, y: 0, width: 600, height: 400), maxDimension: 64) {
            expect(grid.step == 10, "600 宽抽到 64 点时步长应为 10（实际 \(grid.step)）")
            expect(grid.width == 60 && grid.height == 40,
                   "抽稀后的网格应是 60 × 40（实际 \(grid.width) × \(grid.height)）")
            expect(grid.validValues.count == grid.width * grid.height, "整幅范围内不该有空洞")
        } else {
            expect(false, "DEM 应能取到样本网格")
        }
        let profile = reader.profile(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 599, y: 200), count: 128)
        expect(profile.count == 128, "剖面应取满 128 个点（实际 \(profile.count)）")
        if let first = profile.first, let last = profile.last {
            expectClose(Double(first.value), Double(elevation(x: 0, y: 200)), accuracy: 1e-3, "剖面起点高程")
            expectClose(Double(last.value), Double(elevation(x: 599, y: 200)), accuracy: 1e-3, "剖面终点高程")
        }
    } else {
        expect(false, "DEM 样本应能被 RasterSampleReader 打开")
    }

    // 分离平面（PlanarConfiguration = 2）+ 浮点：三个波段各占一个平面。
    let planarURL = tiffFixtures.appending(path: "rgb_f32_planar.tif")
    if let dataset = try? RasterLoader.load(url: planarURL) {
        expect(dataset.compression == "Deflate", "分离平面样本压缩方式应为 Deflate")
        if let image = dataset.renderOverview(maxPixelSize: 120), rgbaBytes(of: image) != nil {
            expect(true, "分离平面（浮点）影像应能渲染")
        } else {
            expect(false, "分离平面样本应能渲染出缩略图")
        }
        if let reader = RasterSampleReader.open(url: planarURL) {
            expect(reader.bandCount == 3, "分离平面样本应有 3 个波段")
            expect(!reader.isElevationLike, "三波段不算高程数据")
            // 三个平面在同一点的取值本来就不同（红 0.10 起、绿 0.20 起、蓝 0.50 起）：
            // 平面取错会立刻露出来。
            let r = reader.value(column: 0, row: 0, band: 0)
            let g = reader.value(column: 0, row: 0, band: 1)
            let b = reader.value(column: 0, row: 0, band: 2)
            if let r, let g, let b {
                expect(abs(r - 0.10) < 1e-3 && abs(g - 0.20) < 1e-3 && abs(b - 0.50) < 1e-3,
                       "分离平面应按波段取到各自的平面（实际 \(r) / \(g) / \(b)）")
            } else {
                expect(false, "分离平面在原点应取到三个波段")
            }
            if let value = reader.value(column: 599, row: 0, band: 0) {
                expectClose(Double(value), 0.3995, accuracy: 1e-3, "分离平面第 0 波段在 x=599 的值")
            } else {
                expect(false, "分离平面第 0 波段在 x=599 应读得到值")
            }
        } else {
            expect(false, "分离平面样本应能被 RasterSampleReader 打开")
        }
    } else {
        expect(false, "分离平面样本（float32 + PlanarConfiguration = 2）应能打开")
    }

    // Predictor 3 的还原：两个样本 1.0、-1.0，按 libtiff 的口径编码 ——
    // 先按字节平面重排（小端：最高位字节在前），再在记录内按**字节**累加一次。
    do {
        // 1.0 = 3F800000、-1.0 = BF800000（小端字节序 00 00 80 3F / 00 00 80 BF）。
        // 重排成 [3F BF][80 80][00 00][00 00]，再按字节做一次一阶差分（不是逐级累加）。
        // 期望向量由 libtiff 的 fpDiff 口径算出（见 Fixtures/TIFF/make-float-fixtures.py）。
        var raw: [UInt8] = [0x3F, 0x80, 0xC1, 0x00, 0x80, 0x00, 0x00, 0x00]
        TIFFSampleChecks.undoFloatPredictor(&raw, width: 2, rows: 1)
        func float(at offset: Int) -> Float {
            Float(bitPattern: UInt32(raw[offset])
                | UInt32(raw[offset + 1]) << 8
                | UInt32(raw[offset + 2]) << 16
                | UInt32(raw[offset + 3]) << 24)
        }
        expectClose(Double(float(at: 0)), 1.0, accuracy: 1e-6, "Predictor 3：第一个样本原样保留")
        expectClose(Double(float(at: 4)), -1.0, accuracy: 1e-6, "Predictor 3：第二个样本按字节累加")

        // 大端文件的平面顺序相反（最低位字节在前）。
        // 大端文件的平面顺序相反：1.0 = 3F800000、2.0 = 40000000，重排成 [3F 40][80 00][00 00][00 00]。
        var big: [UInt8] = [0x3F, 0x01, 0x40, 0x80, 0x00, 0x00, 0x00, 0x00]
        TIFFSampleChecks.undoFloatPredictor(&big, width: 2, rows: 1, littleEndian: false)
        func bigFloat(at offset: Int) -> Float {
            Float(bitPattern: UInt32(big[offset]) << 24
                | UInt32(big[offset + 1]) << 16
                | UInt32(big[offset + 2]) << 8
                | UInt32(big[offset + 3]))
        }
        expectClose(Double(bigFloat(at: 0)), 1.0, accuracy: 1e-6, "Predictor 3（大端）：第一个样本")
        expectClose(Double(bigFloat(at: 4)), 2.0, accuracy: 1e-6, "Predictor 3（大端）：第二个样本")
    }

    // 归一化：8 / 16 位无符号满量程、有符号居中、浮点按 0…1。
    expect(TIFFSampleChecks.normalize(0, bits: 8, kind: .unsigned) == 0, "8 位无符号最小值 → 0")
    expect(TIFFSampleChecks.normalize(255, bits: 8, kind: .unsigned) == 255, "8 位无符号最大值 → 255")
    expect(TIFFSampleChecks.normalize(65535, bits: 16, kind: .unsigned) == 255, "16 位无符号最大值 → 255")
    expect(TIFFSampleChecks.normalize(0, bits: 16, kind: .signed) == 128, "16 位有符号零点 → 128（居中）")
    expect(TIFFSampleChecks.normalize(0.5, bits: 32, kind: .float) == 128, "浮点 0.5 → 128")
    expect(TIFFSampleChecks.normalize(.nan, bits: 32, kind: .float) == 0, "NaN 不画（→ 0）")
}

section("栅格分析：坡度 / 土方量 / 两期差异")

do {
    // 与上一节共用那两份 600 × 400 的浮点样本（UTM 50N，0.5 米/像素，地面高程由解析式给出）。
    func elevation(x: Double, y: Double) -> Double {
        let dx = x - 300, dy = y - 200
        let bump = 200.0 * exp(-(dx * dx + dy * dy) / (2 * 60 * 60))
        return 100.0 + 50.0 * sin(x / 80) * cos(y / 60) + bump
    }

    /// 解析式的坡度（度）：把 dE/dx、dE/dy（每像素）按地面点距换算成梯度，再取模求 atan。
    func analyticSlopeDegrees(x: Double, y: Double, spacing: Double) -> Double {
        let dx = x - 300, dy = y - 200
        let bump = exp(-(dx * dx + dy * dy) / (2 * 60 * 60))
        // d/dx exp(-r²/7200) = -dx/3600 · exp(-r²/7200)，注意 2·60² = 7200 里那个 2。
        let dEx = 50 * cos(x / 80) / 80 * cos(y / 60) - 200 * dx / (60 * 60) * bump
        let dEy = -50 * sin(x / 80) * sin(y / 60) / 60 - 200 * dy / (60 * 60) * bump
        // 行号向南增大（y 轴方向相反），水平梯度取正号。
        let groundX = dEx / spacing
        let groundY = -dEy / spacing
        return atan((groundX * groundX + groundY * groundY).squareRoot()) * 180 / .pi
    }

    let demURL = tiffFixtures.appending(path: "dem_f32_p3.tif")
    let planarURL = tiffFixtures.appending(path: "rgb_f32_planar.tif")
    if let reader = RasterSampleReader.open(url: demURL), reader.isElevationLike {
        let full = CGRect(x: 0, y: 0, width: 600, height: 400)

        // 坡度：与解析式的梯度比（中心差分 + 0.5 米/像素的换算要一起对才算对）。
        if let slope = DEMAnalysis.slope(reader: reader, rect: full) {
            expect(slope.width == 600 && slope.height == 400, "整幅坡度网格应为 600 × 400")
            // 0.5 米是 UTM 平面距离；换算回椭球面要除以中央经线比例因子 0.9996 → 约 0.5002 米。
            expectClose(slope.spacingMeters, 0.5, accuracy: 0.002, "相邻点地面间距应在 0.5 米附近")
            let stats = DEMAnalysis.statistics(of: slope)
            expect(stats.validCount > 230_000, "坡度网格应有大量有效点（实际 \(stats.validCount)）")
            expect(stats.maximum < 90, "坡度是水平面夹角，必然小于 90 度（实际 \(stats.maximum)）")
            expect(stats.mean > 1, "起伏地形应有可观的平均坡度（实际 \(stats.mean)）")
            // 取一个内部点，和解析梯度比（容差按单边差分的截断误差放）。
            let probeIndex = 200 * 600 + 50
            if slope.values.indices.contains(probeIndex) {
                expectClose(
                    Double(slope.values[probeIndex]),
                    analyticSlopeDegrees(x: 50, y: 200, spacing: slope.spacingMeters),
                    accuracy: 0.05,
                    "坡度应与解析梯度一致"
                )
            } else {
                expect(false, "坡度网格应含探针点")
            }
            expect(DEMAnalysis.image(of: slope) != nil, "坡度应能着色成图")
            // 与地理参考对得上：坡度图左上角应落在源影像左上角。
            let sourceTopLeft = reader.georeference.coordinate(column: 0, row: 0)
            let slopeTopLeft = slope.georeference.coordinate(column: 0, row: 0)
            if let sourceTopLeft, let slopeTopLeft {
                expectClose(slopeTopLeft.longitude, sourceTopLeft.longitude, accuracy: 1e-9, "坡度图西边界")
                expectClose(slopeTopLeft.latitude, sourceTopLeft.latitude, accuracy: 1e-9, "坡度图北边界")
            } else {
                expect(false, "坡度图应能算出左上角经纬度")
            }
        } else {
            expect(false, "DEM 应能算出坡度")
        }

        // 土方量：整幅范围、基准取 0（全在地面之下）→ 只应有挖方，且等于逐格求和。
        let whole = [
            CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 0),
            CGPoint(x: 600, y: 400), CGPoint(x: 0, y: 400),
        ]
        if let volume = DEMAnalysis.volume(reader: reader, polygon: whole, baseElevation: 0) {
            expect(volume.fillVolume == 0, "基准在地面之下时不该有填方（实际 \(volume.fillVolume)）")
            expect(volume.sampledCells == 600 * 400, "整幅应采到 24 万个格子（实际 \(volume.sampledCells)）")
            expectClose(volume.cellArea, 0.25, accuracy: 0.002, "一个格子的地面面积在 0.25 平方米附近")
            // 逐格求和当基准（与体积积分走的是同一份采样，但独立算一遍和）。
            if let grid = reader.grid(rect: full, maxDimension: 2048) {
                var expected = 0.0
                for value in grid.values where value.isFinite { expected += Double(value) * volume.cellArea }
                expectClose(volume.cutVolume, expected, accuracy: abs(expected) * 1e-9 + 1e-6,
                            "挖方量应等于逐格高程 × 格面积之和")
            } else {
                expect(false, "整幅应能取到样本网格")
            }
            // 中心那个高斯包（200 米）叠在缓坡上，整幅最高在 328 米附近。
            expectClose(volume.elevation.maximum, 328, accuracy: 3, "整幅最高高程应在 328 米附近")
        } else {
            expect(false, "DEM 应能算出整幅土方量")
        }

        // 土方量：范围缩到一小块，挖填都要出现（基准取该块的中位高程附近）。
        let patch = [
            CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100),
            CGPoint(x: 200, y: 200), CGPoint(x: 100, y: 200),
        ]
        if let volume = DEMAnalysis.volume(reader: reader, polygon: patch, baseElevation: 100) {
            expect(volume.sampledCells == 100 * 100, "小块应采到 1 万个格子（实际 \(volume.sampledCells)）")
            expect(volume.cutVolume > 0 && volume.fillVolume > 0, "基准穿过地形时挖填都该出现")
            expectClose(volume.sampledArea, Double(100 * 100) * volume.cellArea, accuracy: 1e-6, "采样平面面积")
        } else {
            expect(false, "DEM 应能算出一小块土方量")
        }

        // 点落在多边形内外的判定。
        expect(DEMAnalysis.contains(whole, point: CGPoint(x: 300, y: 200)), "中心点应在多边形内")
        expect(!DEMAnalysis.contains(whole, point: CGPoint(x: -5, y: 200)), "范围外的点应判在多边形外")

        // 两期差异：同一份数据相减应处处为零。
        if let same = RasterDifference.compute(first: reader, second: reader) {
            expect(same.comparedSamples == 600 * 400, "同源相减应比满 24 万个采样点")
            expectClose(same.absoluteMaximum, 0, accuracy: 1e-9, "同源相减的最大差值为 0")
            expectClose(same.meanDifference, 0, accuracy: 1e-9, "同源相减的平均差值为 0")
        } else {
            expect(false, "同一份影像应能算出差异图（恒为 0）")
        }
    } else {
        expect(false, "DEM 样本应能被 RasterSampleReader 打开")
    }

    // 两期差异：DEM 与三波段影像的第 0 波段（同范围、同地理参考）。
    if let dem = RasterSampleReader.open(url: demURL),
       let planar = RasterSampleReader.open(url: planarURL),
       let result = RasterDifference.compute(first: dem, second: planar, band: 0) {
        expect(result.width == 600 && result.height == 400, "差异图应铺满共同覆盖范围")
        expect(result.comparedSamples == 600 * 400, "差异图应比满 24 万个采样点")
        // DEM 均值 ≈ 119（缓坡 + 中心高斯包），影像第 0 波段在 0.10…0.40 之间。
        expectClose(result.meanDifference, 118.8, accuracy: 2, "DEM 减影像的平均差值应在 119 附近")
        expect(result.absoluteMaximum < 335, "差异不会超过两个数据的量级之和")
        expect(result.image.width == result.width && result.image.height == result.height, "差异图尺寸一致")
    } else {
        expect(false, "DEM 与三波段影像应能算出差异图")
    }
}

section("影像解码：跨瓦片的块缓存与读句柄池")

do {
    // 键要同时带上「文件 + 层级 + 块号」：不同影像的 IFD 常常都在同一个偏移、
    // 块号也都从 0 开始，而内容毫无关系 —— 上面那四个样本正好就是这种情况
    // （IFD 都在偏移 8、各自的第 0 块内容还不一样），所以那一轮逐点比对
    // 同时也是「缓存键没漏掉文件」的回归。
    let sampleKey = TIFFChunkCache.Key(path: "/tmp/a.tif", level: 8, index: 0)
    expect(sampleKey != TIFFChunkCache.Key(path: "/tmp/b.tif", level: 8, index: 0),
           "块缓存的键要包含文件路径")
    expect(sampleKey != TIFFChunkCache.Key(path: "/tmp/a.tif", level: 8, index: 1),
           "块缓存的键要区分块号")
    expect(sampleKey != TIFFChunkCache.Key(path: "/tmp/a.tif", level: 16, index: 0),
           "块缓存的键要区分层级")

    // 同一块区域解两遍：第二遍应当全部命中，不再重新解压。
    let cache = TIFFChunkCache.shared
    let url = tiffFixtures.appending(path: "rgba_tile_deflate_p2.tif")
    if let dataset = try? RasterLoader.load(url: url) {
        // 前面的小节已经解过这份样本（正好说明缓存跨调用活着），
        // 这里先把它的块丢掉，从「冷的」开始数一遍。
        let path = url.path(percentEncoded: false)
        cache.invalidate(path: path)
        cache.resetStats()
        let before = cache.stats()
        let first = dataset.renderOverview(maxPixelSize: 32)
        let afterFirst = cache.stats()
        expect(first != nil, "块缓存样本应能解出")
        expect(afterFirst.entries > before.entries,
               "解一遍后块缓存里应有块（\(before.entries) → \(afterFirst.entries)）")
        expect(afterFirst.bytes > 0, "块缓存应记下字节数（\(afterFirst.bytes)）")
        expect(afterFirst.misses > 0, "第一遍解应当计成「未命中」")

        let second = dataset.renderOverview(maxPixelSize: 32)
        let afterSecond = cache.stats()
        expect(afterSecond.hits > afterFirst.hits,
               "第二遍解同一区域应命中缓存（命中 \(afterFirst.hits) → \(afterSecond.hits)）")
        expect(afterSecond.entries == afterFirst.entries, "命中不该再往缓存里加块")
        if let first, let second,
           let firstBytes = rgbaBytes(of: first), let secondBytes = rgbaBytes(of: second) {
            expect(firstBytes == secondBytes, "走缓存解出来的像素应与第一遍完全一致")
        } else {
            expect(false, "两遍都应能取出像素")
        }
    } else {
        expect(false, "块缓存自检用的样本应能打开")
    }

    // 容量与淘汰：用一个小容量实例，别去动全局那份。
    let small = TIFFChunkCache(byteLimit: 16 * 1024, countLimit: 3, readerLimit: 1)
    for index in 0..<6 {
        small.store(
            pixels: [UInt8](repeating: UInt8(index), count: 4096),
            for: TIFFChunkCache.Key(path: "/tmp/s.tif", level: 8, index: index)
        )
    }
    expect(small.stats().entries == 3, "块数上限应生效（实际 \(small.stats().entries)）")
    expect(small.stats().bytes == 3 * 4096, "淘汰后字节数应跟着减（实际 \(small.stats().bytes)）")
    expect(small.pixels(for: TIFFChunkCache.Key(path: "/tmp/s.tif", level: 8, index: 5)) != nil,
           "最后放进来的块应还在")
    expect(small.pixels(for: TIFFChunkCache.Key(path: "/tmp/s.tif", level: 8, index: 0)) == nil,
           "最早的块应已被淘汰")
    // 比整个缓存还大的一块不缓存：存进去只会把别的块全挤掉。
    small.store(
        pixels: [UInt8](repeating: 1, count: 64 * 1024),
        for: TIFFChunkCache.Key(path: "/tmp/s.tif", level: 8, index: 99)
    )
    expect(small.pixels(for: TIFFChunkCache.Key(path: "/tmp/s.tif", level: 8, index: 99)) == nil,
           "超过容量的单块不应进缓存")
    small.trim(toFraction: 0)
    expect(small.stats().entries == 1, "收缩到 0 应只剩最后一块（实际 \(small.stats().entries)）")

    // 句柄池：同一个文件借两次拿到同一个句柄；正在用的时候不关，归还之后才关。
    let pool = TIFFChunkCache(byteLimit: 64 * 1024, countLimit: 8, readerLimit: 2)
    let readerURL = tiffFixtures.appending(path: "rgba_strip_lzw.tif")
    do {
        let borrow = try pool.acquireReader(url: readerURL)
        expect(pool.stats().readers == 1, "借出后池里应有一个句柄")
        expect(borrow.reader.read(offset: 0, count: 8)?.count == 8, "池里的句柄应能正常读文件头")
        do {
            let again = try pool.acquireReader(url: readerURL)
            expect(borrow.reader === again.reader, "同一个文件的句柄应当复用")
        }
        expect(pool.stats().readers == 1, "归还后句柄仍留在池里等复用")
        pool.invalidate(path: readerURL.path(percentEncoded: false))
        expect(pool.stats().readers == 1, "还有人在用的时候不能把句柄关掉")
    } catch {
        expect(false, "句柄池自检不该抛错：\(error)")
    }
    expect(pool.stats().readers == 0, "最后一个借用者归还后，失效的句柄应当真的关掉")
    expect(pool.pixels(for: TIFFChunkCache.Key(path: readerURL.path(percentEncoded: false), level: 8, index: 0)) == nil,
           "失效后该文件的块也应丢掉")
}

section("单幅影像：投影换算（对照 PROJ 9.7）")

do {
    // 参考值由 `cs2cs` 算出（PROJ 9.7.0），见每行的注释。
    let utm50 = TransverseMercator.fromEPSG(32650)
    expect(utm50 != nil, "应认出 EPSG:32650")
    if let utm50 {
        // echo "500000 3000000" | cs2cs -f "%.10f" +proj=utm +zone=50 +datum=WGS84 +to +proj=longlat +datum=WGS84
        // → 117.0000000000  27.1224696416
        let corner = Projection.toWGS84(x: 500_000, y: 3_000_000, crs: .transverseMercator(utm50))
        expectClose(corner?.longitude ?? .nan, 117.0000000000, accuracy: 1e-8, "UTM 50N 反算经度")
        expectClose(corner?.latitude ?? .nan, 27.1224696416, accuracy: 1e-8, "UTM 50N 反算纬度")
        // 正算回去
        if let corner {
            let back = Projection.fromWGS84(corner, crs: .transverseMercator(utm50))
            expectClose(back.map { Double($0.x) } ?? .nan, 500_000, accuracy: 0.005, "UTM 50N 正算东坐标（毫米级）")
            expectClose(back.map { Double($0.y) } ?? .nan, 3_000_000, accuracy: 0.005, "UTM 50N 正算北坐标（毫米级）")
        }
    }

    // echo "116.3974 39.9093" | cs2cs +proj=longlat +datum=WGS84 +to +proj=tmerc +lat_0=0 +lon_0=114 +k=1 +x_0=500000 +y_0=0 +ellps=GRS80
    // → 705004.54  4422210.83
    if let tm = TransverseMercator.fromEPSG(4547) {
        let point = Projection.fromWGS84(GeoCoordinate(longitude: 116.3974, latitude: 39.9093), crs: .transverseMercator(tm))
        expectClose(point.map { Double($0.x) } ?? .nan, 705_004.54, accuracy: 0.1, "CGCS2000 3 度带 CM 114E 东坐标")
        expectClose(point.map { Double($0.y) } ?? .nan, 4_422_210.83, accuracy: 0.1, "CGCS2000 3 度带 CM 114E 北坐标")
        if let point {
            let back = Projection.toWGS84(x: point.x, y: point.y, crs: .transverseMercator(tm))
            expectClose(back?.longitude ?? .nan, 116.3974, accuracy: 1e-7, "CGCS2000 反算经度")
            expectClose(back?.latitude ?? .nan, 39.9093, accuracy: 1e-7, "CGCS2000 反算纬度")
        }
    } else {
        expect(false, "应认出 EPSG:4547")
    }

    // Web 墨卡托：赤道处 1 米 = 1 米，且与 WebMercator 的归一化换算一致。
    let equator = Projection.toWGS84(x: 0, y: 0, crs: .webMercator)
    expectClose(equator?.longitude ?? .nan, 0, accuracy: 1e-9, "Web 墨卡托原点经度")
    expectClose(equator?.latitude ?? .nan, 0, accuracy: 1e-9, "Web 墨卡托原点纬度")
    let mercator = Projection.fromWGS84(GeoCoordinate(longitude: 120, latitude: 30), crs: .webMercator)
    expectClose(mercator.map { Double($0.x) } ?? .nan, 13_358_338.90, accuracy: 0.1, "Web 墨卡托东坐标（120°E）")
    expectClose(mercator.map { Double($0.y) } ?? .nan, 3_503_549.84, accuracy: 0.1, "Web 墨卡托北坐标（30°N）")

    // 经纬度基准：恒等。
    let geographic = Projection.toWGS84(x: 120.5, y: 30.5, crs: .geographic)
    expect(geographic == GeoCoordinate(longitude: 120.5, latitude: 30.5), "经纬度基准应为恒等变换")
    // 认不出来的投影要老实返回 nil，而不是硬按经纬度摆。
    expect(Projection.toWGS84(x: 500000, y: 3000000, crs: .unknown(code: 2421)) == nil,
           "认不出的投影不应给出坐标")
}

section("从单幅影像生成瓦片")

do {
    let url = tiffFixtures.appending(path: "geo_utm50_deflate.tif")
    guard let raster = try? RasterLoader.load(url: url) else {
        expect(false, "生成瓦片的样本影像应能打开")
        throw TilePyramidError.emptyRange
    }
    let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "euclid-pyramid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }

    // 样本影像只有 1.6 米见方，取它 1:1 附近的层级才铺得开（用 64 像素瓦片便于核对）。
    let options = TilePyramidOptions(tileSize: 64, format: .png, concurrency: 2)
    let zoomRange = 24...25
    guard let plan = TilePyramidExporter.plan(
        for: raster, zoomRange: zoomRange, options: options, outputDirectory: output
    ) else {
        expect(false, "应能规划出瓦片范围")
        throw TilePyramidError.emptyRange
    }
    expect(plan.totalTileCount > 0, "计划里应有瓦片（\(plan.totalTileCount) 张）")

    let summary = try await TilePyramidExporter().run(raster: raster, plan: plan, options: options)
    print("    z\(zoomRange.lowerBound)–z\(zoomRange.upperBound) 计划 \(plan.totalTileCount) 张："
        + "写出 \(summary.written)、跳过 \(summary.skipped)、失败 \(summary.failed)")
    expect(summary.failed == 0, "生成过程不应有失败（\(summary.failed)）")
    expect(summary.written >= 4, "影像覆盖到的瓦片都应写出（实际 \(summary.written)）")
    expect(summary.bytes > 0, "写出的文件应有字节数")

    // 闭环一：输出目录能被自己的数据集嗅探认出来。
    let datasets = DatasetLocator.discover(at: output)
    expect(datasets.count == 1, "输出目录应被识别为 1 个数据集（实际 \(datasets.count)）")
    expect(datasets.first?.layout.tileSize == 64, "瓦片尺寸应被识别为 64（实际 \(datasets.first?.layout.tileSize ?? -1)）")
    expect(datasets.first?.zoomRange == zoomRange, "层级范围应被识别为 z\(zoomRange.lowerBound)–z\(zoomRange.upperBound)")

    // 闭环二：写出的文件读回来，应与「直接渲染同一块」逐字节一致（PNG 无损）。
    let level = zoomRange.upperBound
    let count = Double(1 << level)
    let centerTile = SlippyTile(
        zoom: level,
        x: Int(raster.worldRect.midX * count),
        y: Int(raster.worldRect.midY * count)
    )
    // 对比用的直接渲染必须与生成时同尺寸（`raster.source` 用的是影像默认边长）。
    let comparableSource = RasterTileSource(
        fileURL: raster.fileURL,
        pixelWidth: raster.pixelWidth,
        pixelHeight: raster.pixelHeight,
        georeference: raster.georeference,
        worldRect: raster.worldRect,
        tileSize: 64
    )
    let direct = await comparableSource.image(for: centerTile)
    let writtenURL = output
        .appending(path: String(centerTile.zoom))
        .appending(path: String(centerTile.x))
        .appending(path: "\(centerTile.y).png")
    expect(FileManager.default.fileExists(atPath: writtenURL.path(percentEncoded: false)),
           "中心瓦片应已写盘（\(centerTile)）")
    if let direct, let directBytes = rgbaBytes(of: direct),
       let fileImage = imageContents(of: writtenURL), let fileBytes = rgbaBytes(of: fileImage) {
        expect(fileImage.width == 64 && fileImage.height == 64, "写出的瓦片应是 64 × 64")
        var mismatches = 0
        for index in 0..<min(directBytes.count, fileBytes.count) where directBytes[index] != fileBytes[index] {
            mismatches += 1
        }
        expect(mismatches == 0, "写出的瓦片应与直接渲染逐字节一致（不同 \(mismatches) 字节）")
    } else {
        expect(false, "中心瓦片应能读回并比对")
    }

    // 闭环三：JPEG 走同一条路，只是有损——解码后应当仍然「像」，且没有把透明区压成黑块。
    let jpegOutput = output.appending(path: "jpeg")
    let jpegOptions = TilePyramidOptions(tileSize: 64, format: .jpeg, compressionQuality: 0.85, concurrency: 2)
    guard let jpegPlan = TilePyramidExporter.plan(
        for: raster, zoomRange: level...level, options: jpegOptions, outputDirectory: jpegOutput
    ) else {
        expect(false, "JPEG 计划应能生成")
        throw TilePyramidError.emptyRange
    }
    let jpegSummary = try await TilePyramidExporter().run(
        raster: raster, plan: jpegPlan, options: jpegOptions
    )
    expect(jpegSummary.written > 0, "JPEG 应写出瓦片")
    let jpegURL = jpegOutput
        .appending(path: String(centerTile.zoom))
        .appending(path: String(centerTile.x))
        .appending(path: "\(centerTile.y).jpg")
    if let jpegImage = imageContents(of: jpegURL), let jpegBytes = rgbaBytes(of: jpegImage) {
        // 只比较**不透明**的像素：JPEG 会把无数据区合成成白底，透明像素本身没有可比性。
        var total = 0, samples = 0
        if let origin = rgbaBytes(of: direct ?? jpegImage) {
            for index in stride(from: 0, to: min(origin.count, jpegBytes.count), by: 4) {
                guard origin[index + 3] == 255 else { continue }
                total += abs(Int(origin[index]) - Int(jpegBytes[index]))
                total += abs(Int(origin[index + 1]) - Int(jpegBytes[index + 1]))
                total += abs(Int(origin[index + 2]) - Int(jpegBytes[index + 2]))
                samples += 3
            }
        }
        let meanError = samples > 0 ? Double(total) / Double(samples) : 999
        print(String(format: "    JPEG（质量 85）与无损渲染的平均通道差：%.1f/255", meanError))
        expect(meanError < 12, "JPEG 质量 85 的平均误差应在个位数（实际 \(meanError)）")
        // 透明区合成白底：不透明像素不该变成纯黑。
        var blackPixels = 0
        for index in stride(from: 0, to: jpegBytes.count, by: 4) where
            jpegBytes[index] == 0 && jpegBytes[index + 1] == 0 && jpegBytes[index + 2] == 0 {
            blackPixels += 1
        }
        expect(blackPixels < jpegBytes.count / 4 / 4, "JPEG 不该出现大片纯黑（数据空洞应合成白底）")
    } else {
        expect(false, "JPEG 瓦片应能读回")
    }
}

// MARK: - 斜置影像的瓦片接缝（子午线收敛角）

section("单幅影像：斜置影像的瓦片接缝")

/// 造一张「上黑下白」的小图：分界线落在第 `size / 2` 行上。
///
/// 用灰度跃变当探针：铺图口径一旦按「包围盒 + 线性摊开」把影像的斜度吞掉，
/// 相邻两块瓦片接缝两侧的分界线就会差出好几个画布像素，一条直线看着就是一跳一跳的。
func makeSplitImage(size: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for row in 0..<size {
        let value: UInt8 = row < size / 2 ? 0 : 255
        for column in 0..<size {
            let index = (row * size + column) * 4
            bytes[index] = value
            bytes[index + 1] = value
            bytes[index + 2] = value
            bytes[index + 3] = 255
        }
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: size,
        height: size,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: size * 4,
        space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

/// 把一张图缩成 `size` 见方（用来模拟「持久化概览小图」那条路）。
func downscaleImage(_ image: CGImage, to size: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: size,
              height: size,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()
}

do {
    // 参数取自实测的 ODM 正射影像（7502 × 8176、EPSG:32650、0.05 米/像素，瓦片网格是墨卡托）：
    // 影像自带一套 UTM 平面坐标，和铺图网格之间差着**子午线收敛角**
    // （该点约 119.18°E、中央经线 117°E，γ ≈ 0.9°），因此影像在屏幕上是斜的。
    //
    // 旧口径把一块瓦片的四角换算成像素后取轴对齐包围盒，等于把这 0.9° 吞掉：
    // 相邻两块瓦片各按各的包围盒拉伸，接缝两侧算出来的源像素差着「一块瓦片宽 × tan γ」，
    // 在这份影像的 z21 上约 5.7 像素 —— 512 点的瓦片每块一跳，看着就是「瓦片错乱」。
    // 现在改用「三只角定一个仿射」，下面把两条口径都算一遍。
    guard let utm50 = TransverseMercator.fromEPSG(32650) else {
        expect(false, "应认出 EPSG:32650（斜置影像自检）")
        throw TilePyramidError.emptyRange
    }
    let odm = RasterGeoreference(
        placement: .georeferenced,
        crs: .transverseMercator(utm50),
        originX: 718_007.767416,
        originY: 2_885_031.540126,
        pixelSizeX: 0.049995,
        pixelSizeY: -0.049995
    )
    let world = odm.worldRect(pixelWidth: 7502, pixelHeight: 8176)
    let zoom = 21
    let tileSize = 512.0
    let gridCount = Double(1 << zoom)
    let left = SlippyTile(zoom: zoom, x: Int(world.midX * gridCount), y: Int(world.midY * gridCount))
    let right = SlippyTile(zoom: zoom, x: left.x + 1, y: left.y)

    /// 几何真值：画布点先按比例插值到该瓦片的**世界坐标**，再墨卡托反算经纬度、投影正算回影像像素。
    /// 这条路上没有仿射近似，因此可以拿来量「铺图口径偏了多少像素」。
    func groundTruth(tile: SlippyTile, column: Double, row: Double) -> CGPoint? {
        let rect = tile.worldRect
        let normalized = CGPoint(
            x: rect.minX + column / tileSize * Double(rect.width),
            y: rect.minY + row / tileSize * Double(rect.height)
        )
        return odm.pixel(for: WebMercator.coordinate(fromNormalized: normalized))
    }
    /// 旧口径：包围盒 + 线性摊开（这次修掉的那一条）。
    func boundingBoxPoint(tile: SlippyTile, column: Double, row: Double) -> CGPoint? {
        guard let rect = odm.pixelRect(ofWorldRect: tile.worldRect) else { return nil }
        return CGPoint(
            x: rect.minX + column / tileSize * Double(rect.width),
            y: rect.minY + row / tileSize * Double(rect.height)
        )
    }
    /// 新口径：三只角定仿射（铺图真正在用的那一条）。
    func mappedPoint(tile: SlippyTile, column: Double, row: Double) -> CGPoint? {
        RasterTileSource.pixelPoint(
            ofTileWorld: tile.worldRect,
            georeference: odm,
            tileSize: tileSize,
            column: column,
            row: row
        )
    }
    func gap(_ lhs: CGPoint?, _ rhs: CGPoint?) -> Double {
        guard let lhs, let rhs else { return .infinity }
        return hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    var worstMapped = 0.0
    var worstBoundingBox = 0.0
    for row in stride(from: 0.0, through: tileSize, by: 32) {
        for (tile, column) in [(left, 0.0), (left, tileSize), (right, 0.0), (right, tileSize)] {
            let reference = groundTruth(tile: tile, column: column, row: row)
            worstMapped = max(worstMapped, gap(mappedPoint(tile: tile, column: column, row: row), reference))
            worstBoundingBox = max(
                worstBoundingBox,
                gap(boundingBoxPoint(tile: tile, column: column, row: row), reference)
            )
        }
    }
    print(String(format: "    与几何真值的最大偏差：三只角定仿射 %.4f 像素，旧「包围盒 + 线性」 %.3f 像素",
                 worstMapped, worstBoundingBox))
    expect(worstMapped < 0.05, "三只角定仿射的口径误差应远小于一个像素（实际 \(worstMapped)）")
    expect(worstBoundingBox > 1, "旧口径确实偏出若干像素（这正是错位的根因，实际 \(worstBoundingBox)）")

    // 接缝本身：左右相邻的两块瓦片，在共享边界上应当取到**同一个影像像素**。
    var seamGap = 0.0
    var seamGapBoundingBox = 0.0
    for row in stride(from: 0.0, through: tileSize, by: 32) {
        seamGap = max(seamGap, gap(
            mappedPoint(tile: left, column: tileSize, row: row),
            mappedPoint(tile: right, column: 0, row: row)
        ))
        seamGapBoundingBox = max(seamGapBoundingBox, gap(
            boundingBoxPoint(tile: left, column: tileSize, row: row),
            boundingBoxPoint(tile: right, column: 0, row: row)
        ))
    }
    print(String(format: "    相邻瓦片在共享边界上的源像素差：修好后 %.4f 像素，旧口径 %.2f 像素",
                 seamGap, seamGapBoundingBox))
    expect(seamGap < 0.05, "接缝两侧应取到同一个影像像素（实际差 \(seamGap) 像素）")
    expect(seamGapBoundingBox > 1, "旧口径在接缝上会错开若干像素（实际 \(seamGapBoundingBox) 像素）")

    // 端到端：真的取两张左右相邻的瓦片，看接缝两侧的灰度分界线落在同一画布行上。
    if let split = makeSplitImage(size: 64) {
        // 64 像素 × 0.4 米 = 25.6 米见方，分界线在影像第 32 行（上黑下白）。
        let placed = RasterGeoreference(
            placement: .georeferenced,
            crs: .transverseMercator(utm50),
            originX: odm.originX,
            originY: odm.originY,
            pixelSizeX: 0.4,
            pixelSizeY: -0.4
        )
        let source = ImageTileSource(image: split, georeference: placed, tileSize: 512)
        let extent = source.worldRect
        let deep = 24
        let deepCount = Double(1 << deep)
        let seed = SlippyTile(
            zoom: deep,
            x: Int(extent.midX * deepCount),
            y: Int(extent.midY * deepCount)
        )
        let neighbor = SlippyTile(zoom: deep, x: seed.x + 1, y: seed.y)

        /// 这一小块影像自己的映射（注意：不能借用上面那份 7502 像素影像的 `mappedPoint`，
        /// 两者的像素尺度差了 8 倍）。
        func placedPoint(tile: SlippyTile, column: Double, row: Double) -> CGPoint? {
            RasterTileSource.pixelPoint(
                ofTileWorld: tile.worldRect,
                georeference: placed,
                tileSize: tileSize,
                column: column,
                row: row
            )
        }
        /// 某一列上「黑 → 白」的跃变行（画布行号，自上而下）。
        func transitionRow(_ bytes: [UInt8], column: Int, size: Int) -> Double? {
            var previous = -1
            for row in 0..<size {
                let value = Int(bytes[(row * size + column) * 4])
                if previous >= 0, previous < 128, value >= 128 { return Double(row) }
                previous = value
            }
            return nil
        }
        /// 分界线（影像第 32 行）在这一列上的画布行号，按仿射口径算。
        func expectedRow(tile: SlippyTile, column: Double) -> Double? {
            guard let top = placedPoint(tile: tile, column: column, row: 0),
                  let bottom = placedPoint(tile: tile, column: column, row: tileSize),
                  abs(bottom.y - top.y) > 1e-9 else { return nil }
            return tileSize * (32 - top.y) / (bottom.y - top.y)
        }

        if let leftBytes = await source.image(for: seed).flatMap(rgbaBytes), let rightBytes = await
            source.image(for: neighbor).flatMap(rgbaBytes),
           let rowLeft = transitionRow(leftBytes, column: source.tileSize - 1, size: source.tileSize),
           let rowRight = transitionRow(rightBytes, column: 0, size: source.tileSize),
           let wantLeft = expectedRow(tile: seed, column: Double(source.tileSize) - 0.5),
           let wantRight = expectedRow(tile: neighbor, column: 0.5) {
            print(String(format: "    接缝处的分界行：左块 %.1f（应为 %.1f），右块 %.1f（应为 %.1f）",
                         rowLeft, wantLeft, rowRight, wantRight))
            expect(abs(rowLeft - wantLeft) <= 1.5, "左块分界行应与几何真值一致（差 \(rowLeft - wantLeft)）")
            expect(abs(rowRight - wantRight) <= 1.5, "右块分界行应与几何真值一致（差 \(rowRight - wantRight)）")
            expect(abs(rowLeft - rowRight) <= 1.5, "接缝两侧的分界行应一致（差 \(rowLeft - rowRight) 行）")
        } else {
            expect(false, "应能取到接缝两侧的瓦片并读出分界行（seed=\(seed)）")
        }

        // 「没有内建概览的大图」低层级是拿持久化概览小图铺的，走的是同一个 `draw`，
        // 只是映射多了一次等比缩小。这里用 32 像素的小图模拟，核对它同样不翻、不错位。
        if let small = downscaleImage(split, to: 32) {
            let thumbnail = ImageTileSource(
                image: small,
                georeference: placed,
                pixelWidth: 64,
                pixelHeight: 64,
                tileSize: 512
            )
            if let bytes = await thumbnail.image(for: seed).flatMap(rgbaBytes),
               let middle = transitionRow(bytes, column: 255, size: 512),
               let want = expectedRow(tile: seed, column: 255.5) {
                let top = Int(bytes[(8 * 512 + 255) * 4])
                let bottom = Int(bytes[(504 * 512 + 255) * 4])
                print("    概览小图铺瓦片：上端亮度 \(top)、下端 \(bottom)、分界行 \(String(format: "%.0f", middle))"
                    + "（应为 \(String(format: "%.0f", want))）")
                // 32 像素的小图放大到 512 点，一个源像素就是 16 点，容差按一个源像素给。
                expect(top < 64 && bottom > 192, "概览铺出来的瓦片不应上下颠倒（上端 \(top)、下端 \(bottom)）")
                expect(abs(middle - want) <= 24, "概览铺出来的分界线应与几何真值一致（差 \(middle - want)）")
            } else {
                expect(false, "概览小图应能铺出瓦片并读出分界线")
            }
        } else {
            expect(false, "应能把自检用的小图缩成概览尺寸")
        }
    } else {
        expect(false, "应能造出自检用的「上黑下白」小图")
    }
}

// MARK: - 瓦片网格（墨卡托 / 经纬度）

section("瓦片网格")

// 墨卡托分支必须与 `SlippyTile` 逐位一致：铺图位置只要差一个浮点尾数，
// 相邻瓦片之间就会渗出细缝。
for zoom in [0, 3, 12, 18] {
    let n = 1 << zoom
    for (column, row) in [(0, 0), (n - 1, n - 1), (n / 2, n / 3)] {
        let reference = SlippyTile(zoom: zoom, x: column, y: row).worldRect
        let rect = TileGrid.webMercator.worldRect(zoom: zoom, column: column, row: row)
        expect(rect == reference, "z\(zoom) 墨卡托瓦片矩形应与 SlippyTile 逐位一致")
    }
}

// 经纬度网格的行是「纬度等分」，列与墨卡托一致。z12 的福州（119.3, 26.08）落在
// 3405 列、727 行，而墨卡托网格里的同一位置在 1740 行 —— 必须区分两种网格的原因就在这。
let fuzhou = GeoCoordinate(longitude: 119.3, latitude: 26.08)
let geographicTile = TileGrid.geographic.tile(at: fuzhou, zoom: 12)
expect(geographicTile.column == 3405, "z12 经纬度网格的列号应为 3405（实际 \(geographicTile.column)）")
expect(geographicTile.row == 727, "z12 经纬度网格的行号应为 727（实际 \(geographicTile.row)）")
let mercatorTile = TileGrid.webMercator.tile(at: fuzhou, zoom: 12)
expect(mercatorTile.column == 3405, "两种网格的列号应当一致")
expect(mercatorTile.row == 1740, "z12 墨卡托网格的行号应为 1740（实际 \(mercatorTile.row)）")

// 经纬度网格的边界值（后面的 bbox 用例直接引用这几个数）。
let northWestTile = TileGrid.geographic.bounds(zoom: 12, column: 3366, row: 701)
expectClose(northWestTile.west, 115.83984375, accuracy: 1e-12, "列 3366 的西边界")
expectClose(northWestTile.east, 115.927734375, accuracy: 1e-12, "列 3366 的东边界")
expectClose(northWestTile.north, 28.388671875, accuracy: 1e-12, "行 701 的北边界")
expectClose(northWestTile.south, 28.30078125, accuracy: 1e-12, "行 701 的南边界")
expectClose(northWestTile.east - northWestTile.west, 360 / 4096, accuracy: 1e-12, "经纬度瓦片的经度跨度")

// 经纬度瓦片在墨卡托世界里不再是正方形：越往高纬越「高」，所以每片的 frame 要各算各的。
let geographicRect = TileGrid.geographic.worldRect(zoom: 12, column: 3366, row: 701)
let mercatorRect = TileGrid.webMercator.worldRect(zoom: 12, column: 3366, row: 701)
expectClose(mercatorRect.width, mercatorRect.height, accuracy: 1e-12, "墨卡托瓦片在世界上是正方形")
expect(geographicRect.height > geographicRect.width, "经纬度瓦片在墨卡托世界里的高度应大于宽度")
expectClose(geographicRect.width, mercatorRect.width, accuracy: 1e-12, "两种网格的列宽在世界上应当相同")
// 瓦片的上下边界必须与行边界函数给出的是同一个值（画网格线与铺图共用它）。
expectClose(geographicRect.minY, TileGrid.geographic.worldRowBoundary(zoom: 12, row: 701),
            accuracy: 1e-12, "瓦片北边界应与行边界一致")
expectClose(geographicRect.maxY, TileGrid.geographic.worldRowBoundary(zoom: 12, row: 702),
            accuracy: 1e-12, "瓦片南边界应与下一行边界一致")
expectClose(TileGrid.webMercator.worldRowBoundary(zoom: 12, row: 701), 701.0 / 4096,
            accuracy: 1e-15, "墨卡托行边界就是 row / n")
// 极区落在墨卡托的截断纬度之外，高度只能给 0，不能变成负数（负高度会把 frame 翻过来）。
expect(TileGrid.geographic.worldRect(zoom: 12, column: 0, row: 0).height >= 0,
       "两极附近的经纬度瓦片高度不应为负")

// 福建数据集的 bbox 应恰好盖住 3366…3418 列、701…756 行。
let fujianBounds = GeoBounds(west: 115.84259, south: 23.483276, east: 120.4953, north: 28.322754)
if let range = TileGrid.geographic.tileRange(zoom: 12, worldRect: fujianBounds.normalizedRect) {
    // bbox 的东边界 120.4953 落在第 3418 列「里面」（3418 列覆盖 120.4101…120.4980），
    // 所以覆盖到的列是 3366…3418 共 53 列 —— 这正好与 manifest 的 53 × 56 − 196 缺片 = 2772 对上。
    expect(range.columns.lowerBound == 3366 && range.columns.upperBound == 3418,
           "bbox 应覆盖 3366…3418 列（实际 \(range.columns.lowerBound)…\(range.columns.upperBound)）")
    expect(range.rows.lowerBound == 701 && range.rows.upperBound == 756,
           "bbox 应覆盖 701…756 行（实际 \(range.rows.lowerBound)…\(range.rows.upperBound)）")
    let planned = (range.columns.count) * (range.rows.count)
    expect(planned == 53 * 56, "z12 的规划瓦片数应为 53 × 56（实际 \(planned)）")
} else {
    expect(false, "bbox 应能算出瓦片行列范围")
}

// 行列 → 世界矩形 → 行列：铺图用的就是这个换算，必须能回到同一格。
var roundTripFailure: String?
for (column, row) in [(3405, 727), (3366, 701), (3419, 756), (3370, 750)] {
    let rect = TileGrid.geographic.worldRect(zoom: 12, column: column, row: row)
    // 瓦片中心回代：这不是边界，必须一格不差。
    let center = WebMercator.coordinate(fromNormalized: CGPoint(x: rect.midX, y: rect.midY))
    let back = TileGrid.geographic.tile(at: center, zoom: 12)
    if back.column != column || back.row != row {
        roundTripFailure = "中心回代得到 \(back.column)/\(back.row)，期望 \(column)/\(row)"
        break
    }
    // 覆盖范围必须包住这张瓦片；边界处 floor / ceil 允许 1 格的浮点偏差。
    guard let cover = TileGrid.geographic.tileRange(zoom: 12, worldRect: rect) else {
        roundTripFailure = "\(column)/\(row) 的覆盖范围算不出来"
        break
    }
    if cover.columns.lowerBound > column || cover.columns.upperBound < column
        || cover.rows.lowerBound > row + 1 || cover.rows.upperBound < row - 1 {
        roundTripFailure = "\(column)/\(row) 的覆盖范围 \(cover.columns) / \(cover.rows) 偏离过大"
        break
    }
}
expect(roundTripFailure == nil, "经纬度网格的「行列 → 世界矩形 → 行列」应往返一致（\(roundTripFailure ?? "通过")）")

// 地面分辨率：两种网格在同一个层级、同一条纬线上必须给出同一个数。
let geographicResolution = TileGrid.geographic.metersPerPixel(zoom: 18, latitude: 26)
expectClose(geographicResolution, TileGrid.webMercator.metersPerPixel(zoom: 18, latitude: 26),
            accuracy: 1e-9, "两种网格在 z18 / 26°N 的地面分辨率应一致")
expectClose(geographicResolution, 0.53673, accuracy: 1e-4, "z18 / 26°N 的地面分辨率")
expect(TileGrid.geographic.metersPerPixel(zoom: 19, latitude: 26) < geographicResolution,
       "经纬度网格的地面分辨率应随层级变细")
// 层级越界不许把 `1 << zoom` 弄崩。
expect(TileGrid.webMercator.tileCount(zoom: 99) == 1 << 30, "过大的层级应夹到 30")
expect(TileGrid.geographic.tileCount(zoom: -3) == 1, "负层级应夹到 0")

// MARK: - ZIP 分卷瓦片包

section("ZIP 分卷瓦片包")

// MARK: - 铺图预算（一屏铺得出来的最低层级）

section("铺图预算（一屏片数与缩放下限）")

// 口径来自实机：福建全省 z12、Retina 2 倍、1340×836 点的画布。
// 整数层级上一张 256px 的瓦片占 128 个视图点，一屏正好 10.47 × 6.53 ≈ 68.4 片。
let retinaViewport = CGSize(width: 1340, height: 836)
let perScreen = TileBudget.tilesPerScreen(
    viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 2
)
expectClose(perScreen, 68.37, accuracy: 0.05, "一屏片数（1340×836 点 / 256px 瓦片 / 2 倍屏）")
// 少除一次显示比例就会得到 17.09 —— 正是「下限掉到 z9.14、一屏 3388 片被清空」的那个错。
expect(perScreen > 60, "一屏片数不能漏算设备像素比（漏了会得到 17 左右）")

// 相机比瓦片层级浅时，每浅一级一屏的片数是上一档的 4 倍。
expectClose(
    TileBudget.tilesPerScreen(
        viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 2,
        cameraZoom: 11, dataZoom: 12
    ),
    perScreen * 4, accuracy: 1e-6, "浅一级应正好翻两番"
)
expectClose(
    TileBudget.tilesPerScreen(
        viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 2,
        cameraZoom: 14, dataZoom: 12
    ),
    perScreen, accuracy: 1e-6, "相机比瓦片层级深时按整屏算"
)
// 估算必须偏保守：z9.141 那档实机铺出来 3388 片，估算不能比它小。
let estimateAtOldFloor = TileBudget.tilesPerScreen(
    viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 2,
    cameraZoom: 9.141, dataZoom: 12
)
expect(estimateAtOldFloor > 3388, "z9.141 的估算片数应不小于实机铺出的 3388 片")

let affordable = TileBudget.affordableZoomLevel(
    viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 2,
    minimumDataZoom: 12, maximumTiles: 1200
)
expectClose(affordable, 10.14, accuracy: 0.02, "福建全省 z12 在 1340×836 视口下的最低可铺层级")
expect(affordable > 9.5, "最低可铺层级不能因为漏算显示比例而掉到 9.1 那一档")
// 下限这一档的估算片数要落在安全阀里，否则「适应窗口」还是会被清空。
let tilesAtAffordable = TileBudget.tilesPerScreen(
    viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 2,
    cameraZoom: affordable, dataZoom: 12
)
expect(tilesAtAffordable <= 1200, "最低可铺层级的一屏片数应在安全阀以内（实际 \(tilesAtAffordable)）")

// 返回的下限不会比「数据最低层级再往外半级」更靠里（更保守）：正常缩放不受影响。
// 数据本来就浅（z6）时一屏只要几十片，限制会落到预算真正撑不住的位置 —— 比半级更外。
let shallowData = TileBudget.affordableZoomLevel(
    viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 2,
    minimumDataZoom: 6, maximumTiles: 1200
)
expectClose(shallowData, 4.14, accuracy: 0.02, "浅层数据（z6）的最低可铺层级")
expect(shallowData <= 6 - 0.5 + 1e-9, "下限不该比「数据最低层级再往外半级」更靠里")
// 窗口越大，一屏能铺的片数越多，下限就越靠近数据最低层级。
let wideAffordable = TileBudget.affordableZoomLevel(
    viewportSize: CGSize(width: 2680, height: 1672), tilePixelSize: 256, displayScale: 2,
    minimumDataZoom: 12, maximumTiles: 1200
)
expect(wideAffordable > affordable, "视口大一倍时下限应更高（更靠近数据最低层级）")
// 进全屏（或把窗口拉大）之后，同一个缩放下要铺的片数会跟着涨：1728×1060 点的全屏画布
// 沿用窗口态那一档下限（z10.14）时要铺约 1475 片，越过 1200 的安全阀 ——
// 这正是「全屏一下画面整屏变灰、而且再也不会自己回来」的成因。
// 视口变大后重算下限，片数必须重新落回安全阀以内。
let fullscreenViewport = CGSize(width: 1728, height: 1060)
let tilesAtWindowFit = TileBudget.tilesPerScreen(
    viewportSize: fullscreenViewport, tilePixelSize: 256, displayScale: 2,
    cameraZoom: affordable, dataZoom: 12
)
expect(tilesAtWindowFit > 1200,
       "全屏画布沿用窗口态下限应越过安全阀（实际 \(tilesAtWindowFit)）—— 这就是整屏变灰的成因")
let fullscreenAffordable = TileBudget.affordableZoomLevel(
    viewportSize: fullscreenViewport, tilePixelSize: 256, displayScale: 2,
    minimumDataZoom: 12, maximumTiles: 1200
)
expect(fullscreenAffordable > affordable, "视口变大后「一屏还铺得出来」的下限必须上抬")
expectClose(fullscreenAffordable, 10.5, accuracy: 0.05, "福建全省 z12 在 1728×1060 全屏画布下的最低可铺层级")
let tilesAtFullscreenFloor = TileBudget.tilesPerScreen(
    viewportSize: fullscreenViewport, tilePixelSize: 256, displayScale: 2,
    cameraZoom: fullscreenAffordable, dataZoom: 12
)
expect(tilesAtFullscreenFloor <= 1200,
       "全屏下限的一屏片数应在安全阀以内（实际 \(tilesAtFullscreenFloor)）")
// 退化输入不许崩、不许返回 NaN。
expectClose(
    TileBudget.affordableZoomLevel(
        viewportSize: .zero, tilePixelSize: 256, displayScale: 2,
        minimumDataZoom: 12, maximumTiles: 1200
    ),
    11.5, accuracy: 1e-9, "零视口应退回「数据最低层级再往外半级」"
)
expectClose(
    TileBudget.affordableZoomLevel(
        viewportSize: retinaViewport, tilePixelSize: 0, displayScale: 2,
        minimumDataZoom: 12, maximumTiles: 1200
    ),
    11.5, accuracy: 1e-9, "瓦片边长为 0 时不许算出 NaN"
)
expect(TileBudget.tilesPerScreen(viewportSize: .zero, tilePixelSize: 256, displayScale: 2) == 0,
       "零视口的一屏片数应为 0")
expect(TileBudget.tilesPerScreen(viewportSize: retinaViewport, tilePixelSize: 256, displayScale: 0).isFinite,
       "显示比例为 0 时不许返回 inf / NaN")
let archiveRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "euclid-zip-\(UUID().uuidString)")
do {
    try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
} catch {
    expect(false, "构造 zip 测试目录失败：\(error)")
}
defer { try? FileManager.default.removeItem(at: archiveRoot) }

/// 造一段「好压」的假瓦片内容；长度与 CRC 才是这里要验的东西。
func fakeTile(_ tag: String, repeats: Int) -> Data {
    Data(String(repeating: "瓦片-\(tag)-", count: repeats).utf8)
}

/// 打开一个文件，把失败原因取出来（成功时返回 nil）。
func zipOpeningError(_ url: URL) -> ZipArchive.ZipError? {
    do {
        _ = try ZipArchive(url: url)
        return nil
    } catch {
        return error as? ZipArchive.ZipError
    }
}

let zipEntries: [(name: String, data: Data)] = [
    ("701/3375.jpg", fakeTile("A", repeats: 512)),
    ("701/3376.png", fakeTile("B", repeats: 40)),
    ("702/3376.png", fakeTile("C", repeats: 200)),
]

for useDeflate in [false, true] {
    let label = useDeflate ? "deflate" : "存储"
    let url = archiveRoot.appending(path: "sample-\(label).zip")
    do {
        try ZIP.stored(zipEntries, compress: useDeflate).write(to: url)
    } catch {
        expect(false, "\(label)：写出 zip 失败（\(error)）")
        continue
    }

    guard let archive = try? ZipArchive(url: url) else {
        expect(false, "\(label)：自己压出来的 zip 应当能打开")
        continue
    }
    expect(archive.entryCount == 3, "\(label)：应认出 3 条记录（实际 \(archive.entryCount)）")
    expect(!archive.isZip64, "\(label)：小包不该被当成 ZIP64")
    expect(archive.indexedRows == [701, 702], "\(label)：索引里的行号应为 701、702（实际 \(archive.indexedRows)）")
    expect(archive.entryNames(inRow: "701") == ["701/3375.jpg", "701/3376.png"], "\(label)：行 701 的条目名")
    expect(archive.columnNumbers(inRow: "701") == [3375, 3376], "\(label)：行 701 的列号")
    expect(archive.columnNumbers(inRow: "702") == [3376], "\(label)：行 702 的列号")
    expect(archive.entryNames(inRow: "999").isEmpty, "\(label)：不存在的行应当为空")
    expect(archive.entry(named: "701/9999.jpg") == nil, "\(label)：不存在的条目应为 nil")

    var allMatched = true
    for item in zipEntries {
        guard let entry = archive.entry(named: item.name),
              let data = try? archive.data(for: entry),
              data == item.data else {
            allMatched = false
            continue
        }
    }
    expect(allMatched, "\(label)：每条记录都应能按名字读出且逐字节一致")
    // 压缩方式确实走到了想验的那条分支。
    let method = archive.entry(named: "701/3375.jpg")?.method
    expect(method == (useDeflate ? 8 : 0),
           "\(label)：压缩方式应为 \(useDeflate ? 8 : 0)（实际 \(method.map(String.init) ?? "nil")）")

    // 改坏数据体：必须抛错，绝不能「读出错的内容还当成功」。
    if let entry = archive.entry(named: "701/3375.jpg"),
       let raw = try? Data(contentsOf: url) {
        // 本地文件头 30 字节 + 名字，之后就是数据；ZIP.stored 不写扩展字段。
        let dataOffset = Int(entry.localHeaderOffset) + 30 + "701/3375.jpg".utf8.count
        let target = dataOffset + Int(entry.compressedSize) / 2
        if target < raw.count {
            var broken = raw
            broken[target] ^= 0xFF
            let brokenURL = archiveRoot.appending(path: "broken-\(label).zip")
            try? broken.write(to: brokenURL)
            if let brokenArchive = try? ZipArchive(url: brokenURL),
               let brokenEntry = brokenArchive.entry(named: "701/3375.jpg") {
                expect((try? brokenArchive.data(for: brokenEntry)) == nil,
                       "\(label)：数据体被改坏后必须报错，而不是返回坏内容")
            } else {
                expect(false, "\(label)：改坏数据体不该影响中央目录的解析")
            }
        } else {
            expect(false, "\(label)：算出来的数据偏移越界了")
        }
    } else {
        expect(false, "\(label)：应能定位到 701/3375.jpg")
    }
}

// 截断：中央目录都没了（正在下载、只写了一半的分卷就是这样），必须当场报错。
let truncatedURL = archiveRoot.appending(path: "truncated.zip")
try? (try ZIP.stored(zipEntries, compress: false)).prefix(120).write(to: truncatedURL)
expect(zipOpeningError(truncatedURL) != nil, "被截断的 zip 应当打不开")

// 中央目录自称越过了文件末尾：要报「截断」，不能被当成正常文件。
do {
    var forged = try ZIP.stored(zipEntries, compress: false)
    // 从尾部往前找 EOCD（0x06054B50），把其中的「中央目录大小」字段改成谎报的值。
    var eocd = forged.count - 22
    while eocd >= 0 {
        if forged[eocd] == 0x50, forged[eocd + 1] == 0x4B, forged[eocd + 2] == 0x05, forged[eocd + 3] == 0x06 {
            break
        }
        eocd -= 1
    }
    if eocd >= 0 {
        forged[eocd + 12] = 0xFE
        forged[eocd + 13] = 0xFF
        forged[eocd + 14] = 0xFF
        forged[eocd + 15] = 0xFF
        let forgedURL = archiveRoot.appending(path: "forged.zip")
        try? forged.write(to: forgedURL)
        if let error = zipOpeningError(forgedURL), case .truncated = error {
            expect(true, "谎报中央目录大小的 zip 应报「截断」")
        } else {
            expect(false, "谎报中央目录大小的 zip 应报「截断」（实际 \(String(describing: zipOpeningError(forgedURL)))）")
        }
    } else {
        expect(false, "应能在自己压出来的 zip 里找到 EOCD")
    }
}

// 垃圾文件：不该被当成 zip（打开面板拖进来的任何文件都会走这条路）。
do {
    let garbageURL = archiveRoot.appending(path: "garbage.zip")
    try? Data((0..<4096).map { UInt8(($0 &* 37) & 0xFF) }).write(to: garbageURL)
    let isNotAZip: Bool
    if let error = zipOpeningError(garbageURL), case .notAZip = error { isNotAZip = true } else { isNotAZip = false }
    expect(isNotAZip, "垃圾文件应当报「不是 ZIP」而不是别的错")
    // 空文件同理（这里是 0 字节，连 EOCD 都没有）。
    let emptyURL = archiveRoot.appending(path: "empty.zip")
    try? Data().write(to: emptyURL)
    expect(zipOpeningError(emptyURL) != nil, "空文件应当打不开")
    // 文件根本不存在时也不能崩。
    expect(zipOpeningError(archiveRoot.appending(path: "missing.zip")) != nil, "不存在的文件应当打不开")
}

// 中央目录谎报记录长度（32 MB，而文件只有几十 KB）：索引只认名字，所以包还能打开，
// 但读那一格必须报错 —— 而且是**在**分配缓冲之前就报错，否则一个畸形索引就能把内存吃掉。
do {
    var forged = try ZIP.stored(zipEntries, compress: false)
    var patched = false
    var index = 0
    while index + 46 <= forged.count {
        if forged[index] == 0x50, forged[index + 1] == 0x4B,
           forged[index + 2] == 0x01, forged[index + 3] == 0x02 {
            // 压缩后大小（+20）与未压缩大小（+24）都改成 32 MB（0x0200_0000）。
            for offset in [20, 24] {
                forged[index + offset] = 0x00
                forged[index + offset + 1] = 0x00
                forged[index + offset + 2] = 0x00
                forged[index + offset + 3] = 0x02
            }
            patched = true
            break
        }
        index += 1
    }
    if patched {
        let forgedURL = archiveRoot.appending(path: "oversized.zip")
        try? forged.write(to: forgedURL)
        if let archive = try? ZipArchive(url: forgedURL), let entry = archive.entry(named: "701/3375.jpg") {
            expect((try? archive.data(for: entry)) == nil,
                   "谎报记录长度的 zip 读那一格必须报错，而不是照着长度去分配内存")
        } else {
            expect(false, "谎报记录长度不该影响中央目录的解析")
        }
    } else {
        expect(false, "应能在自己压出来的 zip 里找到中央目录记录")
    }
}

// 分卷选择：`ZipTileSource` 只按文件名里的行范围挑包，绝不逐包扫。
do {
    let volumes = [
        ZipVolume(url: archiveRoot.appending(path: "sample-存储.zip"), rowRange: 701...756),
        ZipVolume(url: archiveRoot.appending(path: "sample-deflate.zip"), rowRange: 757...800),
    ]
    let source = ZipTileSource(
        rootURL: archiveRoot,
        grid: .geographic,
        parts: [12: volumes],
        zoomRange: 12...12
    )
    expect(source.availableZoomRange == 12...12, "分卷数据源的层级范围")
    // 行 701 只在第一个包里 → 应能取到瓦片；行 757 落在第二个包里（包里没有这一行）→ 取不到。
    let hit = await source.data(for: SlippyTile(zoom: 12, x: 3375, y: 701))
    expect(hit == zipEntries[0].data, "应按行范围选中 701 的分卷并读出瓦片")
    let miss = await source.data(for: SlippyTile(zoom: 12, x: 3376, y: 757))
    expect(miss == nil, "落在没有该行的分卷上应当返回 nil")
    let noZoom = await source.data(for: SlippyTile(zoom: 13, x: 3375, y: 701))
    expect(noZoom == nil, "没有该层级时应当返回 nil")
}

// 轻量取样：只读中央目录开头的一小块（不是为了省事，是为了别为一个上 GB 的中央目录
// 只量一次边长就把它整个扫掉）。它给的是「开头第一条读得出来的记录」。
do {
    let sampleURL = archiveRoot.appending(path: "sample-存储.zip")
    func sampledEntry(_ url: URL, limit: Int = 8) -> ZipArchive.Entry? {
        (try? ZipArchive.sampleEntry(at: url, limit: limit))?.entry
    }
    let sample = try? ZipArchive.sampleEntry(at: sampleURL)
    expect(sample?.entry.name == zipEntries[0].name,
           "轻量取样应给出包里第一条记录（实际 \(String(describing: sample?.entry.name))）")
    expect(sample?.data == zipEntries[0].data, "轻量取样读出来的内容应与原数据一致")
    expect(sampledEntry(truncatedURL) == nil, "截断的包取样应为 nil")
    expect(sampledEntry(archiveRoot.appending(path: "garbage.zip")) == nil, "垃圾文件取样应为 nil")
    expect(sampledEntry(archiveRoot.appending(path: "missing.zip")) == nil, "不存在的文件取样应为 nil")
    expect(sampledEntry(sampleURL, limit: 0) == nil, "limit 为 0 时取样应为 nil")
}

// 整年合并成一个大包：manifest 逐卷记着层级与行范围，磁盘上却只有一个 `<年份>.zip`。
// 这是下载器收尾合并之后的形状（历史影像那盘就是这样），包名里读不出层级。
do {
    let yearParent = archiveRoot.appending(path: "年度影像")
    let mergedRoot = yearParent.appending(path: "2024")
    try? FileManager.default.createDirectory(at: mergedRoot, withIntermediateDirectories: true)
    let mergedEntries: [(name: String, data: Data)] = [
        ("701/3375.jpg", fakeTile("年度z12", repeats: 512)),
        ("1403/6751.jpg", fakeTile("年度z13", repeats: 512)),
    ]
    try? ZIP.stored(mergedEntries, compress: false).write(to: mergedRoot.appending(path: "2024.zip"))
    let manifestJSON: [String: Any] = [
        "service": "img_fj_2024",
        "crs": "EPSG:4490",
        "bbox": [115.84259, 23.483276, 120.4953, 28.322754],
        "parts": [
            "img_fj_2024_z12_r0000701-0000756.zip": [
                "status": "done", "zoom": 12, "rows": [701, 756], "tiles": 1,
            ],
            "img_fj_2024_z13_r0001403-0001513.zip": [
                "status": "done", "zoom": 13, "rows": [1403, 1513], "tiles": 1,
            ],
        ],
    ]
    try? JSONSerialization.data(withJSONObject: manifestJSON, options: [.prettyPrinted])
        .write(to: mergedRoot.appending(path: "manifest.json"))

    // 年份目录名（`2024`）正好长得像「层级目录」，这里同时守着「别被它带偏」。
    let merged = DatasetLocator.makeDataset(at: mergedRoot)
    expect(merged?.zoomRange == 12...13,
           "年度合并包应认出 z12–z13（实际 \(String(describing: merged?.zoomRange))）")
    expect(merged?.grid.kind == .geographic, "年度合并包应认成经纬度网格")
    expect(merged?.layout.directoryAxis == .yFirst, "包内是 <行>/<列>，应识别为 y 在前")
    expect(merged?.zipInfo?.parts[12]?.count == 1, "z12 应登记 1 个包")
    expect(merged?.zipInfo?.parts[13]?.count == 1, "z13 应登记 1 个包")
    expect(merged?.zipInfo?.parts[12]?.first?.rowRange == 701...756, "z12 的行范围应来自 manifest")
    expect(merged?.zipInfo?.parts[13]?.first?.rowRange == 1403...1513, "z13 的行范围应来自 manifest")
    expect(merged?.zipInfo?.parts[12]?.first?.url.lastPathComponent == "2024.zip",
           "两个层级都应指向同一个包")
    expect(merged?.zipInfo?.tileCount == 2,
           "瓦片总数应取 manifest 的合计（实际 \(String(describing: merged?.zipInfo?.tileCount))）")
    expect(merged?.zipInfo?.fileCount == 1, "合并包报给界面的文件数应为 1")
    expect(merged?.zipInfo?.volumeCount == 2, "合并包按层级登记，登记条数等于层级数")
    // `2024` 长得像「层级目录」，而 datasetRoot 对 `z12/….zip` 是会往上找一层整份数据的：
    // 这里守着它别把年份目录当层级目录用（上一层并不是数据集，就该停在年份目录）。
    expect(
        DatasetLocator.datasetRoot(containing: mergedRoot.appending(path: "2024.zip")).canonicalFilePath
            == mergedRoot.canonicalFilePath,
        "拖入年度整包应认出年份目录本身，而不是往上多走一层"
    )

    if let source = merged?.source as? ZipTileSource {
        expect(await source.data(for: SlippyTile(zoom: 12, x: 3375, y: 701)) == mergedEntries[0].data,
               "年度合并包应能取到 z12 的瓦片")
        expect(await source.data(for: SlippyTile(zoom: 13, x: 6751, y: 1403)) == mergedEntries[1].data,
               "年度合并包应能取到 z13 的瓦片")
        expect(await source.data(for: SlippyTile(zoom: 12, x: 3375, y: 1404)) == nil,
               "行号不在该层级的范围里时应返回 nil")
    } else {
        expect(false, "年度合并包的数据来源应为 ZipTileSource")
    }
    // 覆盖范围直接取 manifest 的 bbox，不必去翻包。
    if let merged, let extent = DatasetLocator.extent(of: merged) {
        expect(extent.worldRect.width > 0 && extent.worldRect.height > 0, "年度合并包的覆盖范围不应退化")
    } else {
        expect(false, "年度合并包应能算出覆盖范围")
    }
    // 拖整个上一层目录（历史影像）时，要能逐年扫出来。
    let foundYears = DatasetLocator.discover(at: yearParent)
    expect(foundYears.count == 1 && foundYears[0].name == "2024",
           "上一层目录里应扫到 2024 这一份（实际 \(foundYears.map(\.name))）")
    // 合并包的 manifest 少了某一卷时，那一卷的行范围就不该被登记（宁缺勿错）。
    let partialRoot = yearParent.appending(path: "2025")
    try? FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: true)
    try? Data().write(to: partialRoot.appending(path: "2025.zip"))
    try? Data(#"{"crs":"EPSG:4490","parts":{"a.zip":{"zoom":12,"rows":[701,756]},"b.zip":{"rows":[1,2]}}}"#.utf8)
        .write(to: partialRoot.appending(path: "manifest.json"))
    expect(DatasetLocator.makeDataset(at: partialRoot)?.zoomRange == 12...12,
           "manifest 里读不出层级的卷应当被跳过，而不是把整份数据拖成非法层级")

    // manifest 没写 bbox 时，覆盖范围仍要从包里探出来（这条路上会抽首尾行）。
    let noBoxRoot = yearParent.appending(path: "2026")
    try? FileManager.default.createDirectory(at: noBoxRoot, withIntermediateDirectories: true)
    try? ZIP.stored(mergedEntries, compress: false).write(to: noBoxRoot.appending(path: "2026.zip"))
    try? Data(#"{"crs":"EPSG:4490","parts":{"a.zip":{"zoom":12,"rows":[701,756]}}}"#.utf8)
        .write(to: noBoxRoot.appending(path: "manifest.json"))
    if let dataset = DatasetLocator.makeDataset(at: noBoxRoot),
       let extent = DatasetLocator.extent(of: dataset) {
        expect(extent.worldRect.width > 0 && extent.worldRect.height > 0,
               "没有 bbox 的合并包也要能从包里探出覆盖范围")
        expect(extent.worldRect.width < 1 && extent.worldRect.height < 1,
               "探出来的范围不该退化成整个世界")
    } else {
        expect(false, "没有 bbox 的合并包应能算出覆盖范围")
    }
}

// MARK: - 本地瓦片服务

section("本地瓦片服务：路径解析、响应与异步启动")

// 路径解析：只认「三层、整数、白名单后缀」，并且必须挡住目录穿越。
do {
    let root = URL(fileURLWithPath: "/tmp/euclid-server-root")
    expect(LocalTileServer.tileFile(for: "/12/3375/701.jpg", root: root)?.lastPathComponent == "701.jpg",
           "合法的 /z/x/y.jpg 应解析出文件路径")
    expect(LocalTileServer.tileFile(for: "/12/3375/701.PNG", root: root)?.lastPathComponent == "701.png",
           "后缀应统一成小写")
    expect(LocalTileServer.tileFile(for: "/../../etc/passwd", root: root) == nil,
           "带 .. 的路径必须被拒（目录穿越）")
    expect(LocalTileServer.tileFile(for: "/12/3375/701.sh", root: root) == nil,
           "白名单之外的后缀必须被拒")
    expect(LocalTileServer.tileFile(for: "/12/-3375/701.jpg", root: root) == nil,
           "负数坐标必须被拒")
    expect(LocalTileServer.tileFile(for: "/12/3375/701", root: root) == nil,
           "没有后缀的路径必须被拒")
    expect(LocalTileServer.contentType(for: "JPG") == "image/jpeg", "后缀大小写都要认")
}

// 真起一个服务：系统分配端口，取一张瓦片，再取一次（走响应缓存）。
do {
    let root = archiveRoot.appending(path: "server-root")
    do {
        try FileManager.default.createDirectory(
            at: root.appending(path: "12/3375"),
            withIntermediateDirectories: true
        )
        try fakeTile("S", repeats: 8).write(to: root.appending(path: "12/3375/701.png"))
    } catch {
        expect(false, "构造本地服务测试目录失败：\(error)")
    }

    let server = LocalTileServer()
    do {
        let port = try await server.startAsync(rootURL: root, port: 0)
        expect(port > 0, "异步启动应拿到一个真实端口（实际 \(port)）")

        // 用不带缓存的会话：`URLSession.shared` 会拿 `Cache-Control` 把重取的瓦片塞进自己的
        // URLCache，第二次请求根本到不了服务端 —— 那样既验不了响应缓存，也数不准请求数。
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        /// 发一个最简 HTTP 请求，拿回状态码、响应头与正文。
        func get(_ path: String) async -> (status: Int, body: String, header: (String) -> String?)? {
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            return (http.statusCode, String(decoding: data, as: UTF8.self), { http.value(forHTTPHeaderField: $0) })
        }

        let first = await get("/12/3375/701.png")
        expect(first?.status == 200, "取一张存在的瓦片应回 200（实际 \(first?.status ?? -1)）")
        expect(first?.body.contains("瓦片-S-") == true, "取一张存在的瓦片应返回它的内容")
        expect(first?.header("Access-Control-Allow-Origin") == "*",
               "响应要带 CORS 头，否则浏览器里的编辑器拿不到图")
        // 再取一次：第二次走的是服务端响应缓存，内容必须一模一样。
        let second = await get("/12/3375/701.png")
        expect(second?.status == 200 && second?.body == first?.body,
               "第二次取同一张瓦片应命中缓存且内容一致")
        let missing = await get("/12/3375/999.png")
        expect(missing?.status == 404, "不存在的瓦片应报 404（实际 \(missing?.status ?? -1)）")
        expect(server.status.requests >= 3, "三次请求都应被计数（实际 \(server.status.requests)）")
    } catch {
        expect(false, "本地服务启动失败：\(error)")
    }
    server.stop()
    expect(server.status.isRunning == false, "停止之后状态应为未运行")
}

// MARK: - 真实 zip 数据集（挂了福建数据盘时才跑）

/// 真机数据：数据盘上的「福建省瓦片」目录。
///
/// 依次找：`EUCLID_ZIP_ROOT` 环境变量 → 挂载卷里的任意「福建省瓦片」（只扫一层，不递归）。
/// 卷标因人而异（数据盘、Samsung…），写死卷名会让这段自检在别人机器上永远被跳过。
///
/// 这些期望值来自 manifest.json 与已知的下载结果（z12：1 卷 2772 片；z18：仍在下载）。
func findFujianRoot() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["EUCLID_ZIP_ROOT"] {
        return URL(fileURLWithPath: path)
    }
    let mounted = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: "/Volumes"),
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    for volume in mounted {
        let candidate = volume.appending(path: "福建省瓦片")
        let manifest = candidate.appending(path: "manifest.json").path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: manifest) { return candidate }
    }
    return nil
}

let fujianRoot = findFujianRoot()

if let fujianRoot {
    section("真实 zip 数据集：\(fujianRoot.lastPathComponent)")
    if let dataset = ZipDatasetLocator.makeDataset(at: fujianRoot), let info = dataset.zipInfo {
        expect(dataset.grid.kind == .geographic, "福建数据集应认成经纬度网格")
        expect(dataset.layout.tileSize == 256, "瓦片边长应为 256（实际 \(dataset.layout.tileSize)）")
        expect(dataset.zoomRange.lowerBound == 12, "最低层级应为 z12")
        expect(dataset.zoomRange.upperBound >= 18, "最高层级应到 z18")
        expect(dataset.layout.directoryAxis == .yFirst, "包内是 <行>/<列>，应识别为 y 在前")
        expect(info.parts[12]?.count == 1, "z12 应有 1 个分卷（实际 \(info.parts[12]?.count ?? 0)）")
        expect(info.parts[13]?.count == 1, "z13 应有 1 个分卷（实际 \(info.parts[13]?.count ?? 0)）")
        expect(info.parts[14]?.count == 2, "z14 应有 2 个分卷（实际 \(info.parts[14]?.count ?? 0)）")
        expect(info.parts[15]?.count == 5, "z15 应有 5 个分卷（实际 \(info.parts[15]?.count ?? 0)）")
        expect(info.parts[16]?.count == 17, "z16 应有 17 个分卷（实际 \(info.parts[16]?.count ?? 0)）")
        expect(info.parts[17]?.count == 45, "z17 应有 45 个分卷（实际 \(info.parts[17]?.count ?? 0)）")
        expect(info.parts[12]?.first?.rowRange == 701...756,
               "z12 分卷的行范围应为 701…756（实际 \(String(describing: info.parts[12]?.first?.rowRange))）")

        // 拖进「打开」的常常是某个分卷：要认成**整份**数据，而不是只剩 z12 那一层的残缺数据集。
        if let volume = info.parts[12]?.first?.url {
            expect(
                DatasetLocator.datasetRoot(containing: volume).canonicalFilePath == fujianRoot.canonicalFilePath,
                "拖入 z12 分卷应认出整份数据的根目录（实际 \(DatasetLocator.datasetRoot(containing: volume).canonicalFilePath)）"
            )
            expect(
                DatasetLocator.dataset(containingVolume: volume, in: [dataset])?.id == dataset.id,
                "拖入的 z12 分卷应归属到这份数据"
            )
        }

        if let bbox = info.boundingBox {
            expectClose(bbox.west, 115.84259, accuracy: 1e-6, "manifest bbox 西边界")
            expectClose(bbox.east, 120.4953, accuracy: 1e-6, "manifest bbox 东边界")
            expectClose(bbox.south, 23.483276, accuracy: 1e-6, "manifest bbox 南边界")
            expectClose(bbox.north, 28.322754, accuracy: 1e-6, "manifest bbox 北边界")
        } else {
            expect(false, "manifest 的 bbox 应能读出来")
        }

        // 覆盖范围不扫盘：直接用 manifest 的 bbox，换算成归一化世界矩形。
        if let extent = DatasetLocator.extent(of: dataset) {
            let box = extent.boundingBox
            expectClose(box.southWest.longitude, 115.84259, accuracy: 1e-6, "数据范围西边界")
            expectClose(box.northEast.longitude, 120.4953, accuracy: 1e-6, "数据范围东边界")
            expectClose(box.southWest.latitude, 23.483276, accuracy: 1e-4, "数据范围南边界")
            expectClose(box.northEast.latitude, 28.322754, accuracy: 1e-4, "数据范围北边界")
            expect(extent.tileCount == info.tileCount, "瓦片总数应取 manifest 的记录")
        } else {
            expect(false, "zip 数据集应能算出覆盖范围")
        }

        // z12：整包体检（条目数、某一条的长度与像素尺寸都对着下载结果核）。
        if let volume = info.parts[12]?.first {
            if let archive = try? ZipArchive(url: volume.url) {
                expect(archive.entryCount == 2772, "z12 分卷应有 2772 条记录（实际 \(archive.entryCount)）")
                expect(archive.indexedRows.first == 701 && archive.indexedRows.last == 756,
                       "z12 分卷覆盖的行应为 701…756")
                // 空数据瓦片不落盘，所以最北一行的西侧若干列本来就是缺的（manifest 记了 196 片缺失）。
                // 只要落在 bbox 覆盖的 3366…3418 列之内、且东端顶到 3414 就说明坐标换算没错位。
                let firstRowColumns = archive.columnNumbers(inRow: "701")
                expect(firstRowColumns.first == 3375 && firstRowColumns.last == 3414,
                       "z12 行 701 的列应为 3375…3414（实际 \(String(describing: firstRowColumns.first))…\(String(describing: firstRowColumns.last))）")
                expect(firstRowColumns.allSatisfy { (3366...3418).contains($0) },
                       "z12 行 701 的列应全部落在 bbox 覆盖的 3366…3418 之内")
                // manifest、bbox 与包内实际条目数三方对账：53 列 × 56 行 − 196 片空数据 = 2772。
                expect(53 * 56 - 196 == archive.entryCount,
                       "缺片数与规划范围应当对得上（\(53 * 56 - 196) vs \(archive.entryCount)）")
                if let entry = archive.entry(named: "701/3375.jpg"), let data = try? archive.data(for: entry) {
                    expect(data.count == 28402, "701/3375.jpg 应为 28402 字节（实际 \(data.count)）")
                    if let image = ImageDecoder.decode(data) {
                        expect(image.width == 256 && image.height == 256, "瓦片应为 256×256")
                    } else {
                        expect(false, "701/3375.jpg 应能解码成图像")
                    }
                } else {
                    expect(false, "应能读出 z12 的 701/3375.jpg")
                }
                // 西边的空数据格确实没有条目（不该「编」出一张图来）。
                expect(archive.entry(named: "701/3366.jpg") == nil, "空数据格不该有条目")
                // 空数据瓦片是小尺寸 PNG 占位图（几百字节），不是影像数据。
                if let entry = archive.entry(named: "756/3407.png"), let data = try? archive.data(for: entry) {
                    expect(data.count < 2048, "空数据瓦片应是小占位图（实际 \(data.count) 字节）")
                    if let image = ImageDecoder.decode(data) {
                        expect(image.width == 256 && image.height == 256, "占位瓦片也应是 256×256")
                    } else {
                        expect(false, "空数据瓦片应能解码")
                    }
                } else {
                    expect(false, "应能读出 756/3407.png")
                }
            } else {
                expect(false, "z12 分卷应当能打开")
            }
        } else {
            expect(false, "z12 应有分卷")
        }

        // z18 还在下载：能打开就顺着核一遍 ZIP64 与内容；打不开只提示，不算失败。
        if let volume = info.parts[18]?.first {
            if let archive = try? ZipArchive(url: volume.url), !archive.indexedRows.isEmpty {
                expect(archive.isZip64, "z18 的条目数超过 65535，应当是 ZIP64")
                let row = archive.indexedRows[archive.indexedRows.count / 2]
                let names = archive.entryNames(inRow: String(row))
                if let name = names.first, let entry = archive.entry(named: name),
                   let data = try? archive.data(for: entry) {
                    expect(!data.isEmpty, "z18 的 \(name) 应有内容")
                    expect(ImageDecoder.decode(data) != nil, "z18 的 \(name) 应能解码")
                } else {
                    expect(false, "z18 应能读出至少一条记录")
                }
            } else {
                print("  · z18 分卷暂时打不开（多半还在下载），已跳过")
            }
        } else {
            print("  · 还没有 z18 分卷，已跳过")
        }
    } else {
        expect(false, "福建数据目录应被认成 zip 数据集")
    }
} else {
    print("\n▸ 真实 zip 数据集：没有找到带 manifest.json 的「福建省瓦片」（跳过）")
}

// MARK: - G1：新功能自检

section("G1：新功能自检（流式下载 / zip 索引 / 矢量导入 / 导出 / 概览缓存 / 本地服务）")

do {
    let plan = try TileDownloadPlan(
        bounds: GeoBounds(west: 120.10, south: 30.20, east: 120.32, north: 30.38),
        zoomRange: 12...13
    )
    for range in plan.ranges {
        var streamed: [SlippyTile] = []
        var buffer: [SlippyTile] = []
        var iterator = plan.tileChunks(for: range, chunkSize: 7)
        while let chunk = iterator.next() {
            expect(chunk.count <= 7, "流式分块不应超过块大小")
            buffer.append(contentsOf: chunk)
            if buffer.count >= 7 {
                streamed.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        streamed.append(contentsOf: buffer)
        expect(streamed == plan.tiles(for: range), "z\(range.zoom) 流式顺序应与物化顺序一致")
    }
}

do {
    let directory = FileManager.default.temporaryDirectory.appending(path: "euclid-zipindex-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "part.zip")
    try? Data(repeating: 0x41, count: 4096).write(to: file)
    let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    let spans: [String: (start: UInt64, end: UInt64)] = [
        "12/3400": (1, 2048),
        "12/3401\tx": (2049, 4095),
        "12/3402\n换行": (0, 0),
    ]
    ZipIndexCache.save(
        rowSpans: spans,
        entryCount: 3,
        centralDirectorySize: 4096,
        isZip64: false,
        for: file,
        fileSize: size
    )
    let loaded = ZipIndexCache.load(for: file, fileSize: size)
    expect(
        loaded?.rowSpans.count == spans.count && loaded?.entryCount == 3 && loaded?.isZip64 == false,
        "索引应命中并还原表头"
    )
    expect(
        loaded?.rowSpans["12/3401\tx"]?.start == 2049 && loaded?.rowSpans["12/3402\n换行"]?.end == 0,
        "含制表符 / 换行的行名应原样还原"
    )
    expect(ZipIndexCache.load(for: file, fileSize: size + 1) == nil, "文件大小变了应不命中")

    let sample = GeoMeasurement(
        kind: .distance,
        points: [
            GeoCoordinate(longitude: 120, latitude: 30),
            GeoCoordinate(longitude: 120.001, latitude: 30),
        ],
        name: "道路"
    )
    let dxf = MeasurementCADExporter.dxf([sample])
    expect(dxf.contains("SECTION") && dxf.contains("ENTITIES") && dxf.contains("EOF"), "DXF 应含标准段")
    expect(MeasurementCADExporter.pair(1, "注记").contains("\\U+6CE8"), "非 ASCII 应转成 \\U+XXXX")

    let shapefile = MeasurementCADExporter.shapefile([sample], baseName: "自检")
    for suffix in ["_line.shp", "_line.shx", "_line.dbf", "_line.prj", "_line.cpg"] {
        let match = shapefile.first { $0.name.hasSuffix(suffix) }
        expect(match?.name == "自检\(suffix)" && !(match?.data.isEmpty ?? true), "Shapefile 应含 \(suffix)")
    }
    let shp = shapefile.first { $0.name.hasSuffix("_line.shp") }?.data
    expect(shp?.count ?? 0 >= 100, ".shp 应含 100 字节头与记录")

    let geojson = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"干道"},"geometry":{"type":"LineString","coordinates":[[120,30],[120.001,30.001]]}}]}"#
    let jsonURL = directory.appending(path: "sample.geojson")
    try? Data(geojson.utf8).write(to: jsonURL)
    let imported = try? VectorImporter.measurements(from: jsonURL)
    expect(imported?.count == 1 && imported?.first?.kind == .distance, "GeoJSON 应导入为折线")

    let kml = "<kml><Document><Placemark><name>测区</name><Polygon><outerBoundaryIs><LinearRing><coordinates>120,30 120.01,30 120.01,30.01 120,30.01 120,30</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark></Document></kml>"
    let kmlURL = directory.appending(path: "sample.kml")
    try? Data(kml.utf8).write(to: kmlURL)
    let parsedKML = try? VectorImporter.measurements(from: kmlURL)
    expect(parsedKML?.count == 1 && parsedKML?.first?.kind == .area, "KML 外环应导入为面积")

    let dense = (0..<5000).map { GeoCoordinate(longitude: 120 + Double($0) * 1e-6, latitude: 30) }
    let simplified = VectorImporter.simplified(dense, limit: 100)
    expect(
        simplified.count == 100 && simplified.first == dense.first && simplified.last == dense.last,
        "抽稀应保留首尾"
    )

    let key = RasterOverviewCache.key(fileURL: file, tileSize: 256)
    expect(key.contains("part.zip") && key.hasSuffix("|256"), "概览缓存键应按 路径|大小|时间|尺寸 拼出")
    expect(RasterOverviewCache.fileName(for: key).count == 16, "概览缓存文件名应是定长十六进制")

    let root = FileManager.default.temporaryDirectory.appending(path: "euclid-server-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root.appending(path: "3/4"), withIntermediateDirectories: true)
    try? Data([0x89, 0x50]).write(to: root.appending(path: "3/4/5.png"))
    defer { try? FileManager.default.removeItem(at: root) }
    if let json = LocalTileServer.tileJSON(
        root: root,
        rootName: "自检瓦片",
        port: 8766,
        metadata: LocalTileServer.RootMetadata()
    ), let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
        expect(
            object["tilejson"] as? String == "2.2.0"
                && (object["tiles"] as? [String])?.first?.contains("{z}/{x}/{y}") == true,
            "TileJSON 应给出标准模板"
        )
    } else {
        expect(false, "TileJSON 应能序列化")
    }
    let html = LocalTileServer.previewHTML(rootName: "自检<瓦片>", start: (zoom: 3, x: 4, y: 5), tileSize: 256)
    expect(html.contains("<title>预览 · 自检&lt;瓦片&gt;</title>"), "预览页标题应转义 HTML")
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
