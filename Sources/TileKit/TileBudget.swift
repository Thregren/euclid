import CoreGraphics
import Foundation

/// 「一屏要铺多少片瓦片」的换算，铺图安全阀与相机的缩放下限共用同一套口径。
///
/// 换算里最容易踩的坑是**设备像素比**：层级定义把一个图像像素对一个设备像素算了进去
/// （见 `MapCamera.zoomLevel`），所以整数层级上一张瓦片在屏幕上只占
/// 「瓦片边长 / 设备像素比」个视图点。少算这一步，估出来的片数会差 `displayScale²`
/// （Retina 上正好 4 倍），缩放下限就会落得太靠外，一屏几千片直接把安全阀顶爆。
public enum TileBudget {
    /// 相机层级 = 瓦片层级时，一屏能铺满多少片。
    public static func tilesPerScreen(
        viewportSize: CGSize,
        tilePixelSize: Double,
        displayScale: Double
    ) -> Double {
        let width = Double(viewportSize.width)
        let height = Double(viewportSize.height)
        let scale = max(0.25, displayScale)
        guard width > 0, height > 0, tilePixelSize > 0, scale > 0 else { return 0 }
        let tilePoints = tilePixelSize / scale
        let count = width * height / (tilePoints * tilePoints)
        return count.isFinite ? count : 0
    }

    /// 相机停在 `cameraZoom`、瓦片层级被夹在 `dataZoom` 上时，一屏要铺多少片。
    ///
    /// 相机比瓦片层级每浅一级，一屏的片数就是上一档的 4 倍；相机不比瓦片层级浅时按整屏算。
    public static func tilesPerScreen(
        viewportSize: CGSize,
        tilePixelSize: Double,
        displayScale: Double,
        cameraZoom: Double,
        dataZoom: Int
    ) -> Double {
        let perScreen = tilesPerScreen(
            viewportSize: viewportSize,
            tilePixelSize: tilePixelSize,
            displayScale: displayScale
        )
        guard perScreen > 0 else { return 0 }
        let levels = max(0, Double(dataZoom) - cameraZoom)
        let count = perScreen * pow(4, levels)
        return count.isFinite ? count : 0
    }

    /// 「一屏还铺得出来」的最低相机层级。
    ///
    /// 相机的层级比数据的最低层级还浅时，瓦片层级只能夹在数据的最低层级上，
    /// 一屏要铺的片数就按 4 的幂往上涨 —— 缩出去三级就是一屏六千多片，任何铺图预算都会被
    /// 撑爆（`TileLayerStack` 超预算时宁可清空画布，看起来就跟「数据没打开」一样）。
    /// 这里按视口反推「还能铺得出来」的最低层级，交给相机的缩放下限用。
    ///
    /// - Parameters:
    ///   - maximumTiles: 单帧允许铺的片数上限（安全阀）。
    ///   - reserve: 余量比例。行列范围取整（floor / ceil）会多出一两行一两列，留出富余。
    ///   - marginLevels: 下限不会比「数据最低层级再往外这么多级」更靠里（默认半级），
    ///     于是浅层数据（一屏本来就只要几十片）不会被这条预算平白收紧。
    public static func affordableZoomLevel(
        viewportSize: CGSize,
        tilePixelSize: Double,
        displayScale: Double,
        minimumDataZoom: Int,
        maximumTiles: Int,
        reserve: Double = 0.75,
        marginLevels: Double = 0.5
    ) -> Double {
        let dataMinimum = Double(minimumDataZoom)
        let ceiling = min(dataMinimum - max(0, marginLevels), dataMinimum)
        let perScreen = tilesPerScreen(
            viewportSize: viewportSize,
            tilePixelSize: tilePixelSize,
            displayScale: displayScale
        )
        guard perScreen > 0, maximumTiles > 0 else { return ceiling }
        let limit = Double(maximumTiles) * min(max(reserve, 0.05), 1)
        let safe = dataMinimum - 0.5 * log2(limit / perScreen)
        guard safe.isFinite else { return ceiling }
        return min(safe, ceiling)
    }
}
