import CoreGraphics
import Foundation
import ImageIO
import TileKit

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


@MainActor
func runRasterChecks() async throws {
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
    expect(small.stats().entries == 0, "收缩到 0 应释放全部块（实际 \(small.stats().entries)）")

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


}
