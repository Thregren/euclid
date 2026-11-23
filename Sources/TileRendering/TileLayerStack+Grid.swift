import CoreGraphics
import Foundation
import QuartzCore
import TileKit
extension TileLayerStack {
    /// 视野外一圈一圈往外扩的瓦片（不含视野内已有的那些）。
    ///
    /// 拖动时新露出来的边正好落在这一圈里：把它们跟视野内的瓦片一起取，
    /// 手一直在动的时候边上也有图，而不是等松手才一片片补上来。
    ///
    /// 从里往外一圈一圈取、取够 `limit` 就停：这样「离视野越近越先取」是天然的，
    /// 也保证了一次手势最多只会多探这么多片（拖到数据外面时这些请求都会落空，得有上限）。
    func surroundingTiles(
        zoom: Int,
        columns: ClosedRange<Int>,
        rows: ClosedRange<Int>,
        margin: Int,
        limit: Int,
        excluding visible: Set<SlippyTile>
    ) -> [SlippyTile] {
        guard margin > 0, limit > 0 else { return [] }
        let maximum = (1 << zoom) - 1
        var seen = Set<SlippyTile>()
        var result: [SlippyTile] = []
        for step in 1...margin {
            let stepColumns = (columns.lowerBound - step)...(columns.upperBound + step)
            let stepRows = (rows.lowerBound - step)...(rows.upperBound + step)
            ring: for row in stepRows {
                for column in stepColumns {
                    if result.count >= limit { break ring }
                    // 只取这一圈的边：里面几圈上一轮已经取过了。
                    let onEdge = row == stepRows.lowerBound || row == stepRows.upperBound
                        || column == stepColumns.lowerBound || column == stepColumns.upperBound
                    guard onEdge else { continue }
                    guard (0...maximum).contains(column), (0...maximum).contains(row) else { continue }
                    let tile = SlippyTile(zoom: zoom, x: column, y: row)
                    guard !visible.contains(tile) else { continue }
                    guard seen.insert(tile).inserted else { continue }
                    result.append(tile)
                }
            }
            if result.count >= limit { break }
        }
        return result
    }

    /// 预取视野外一圈的瓦片，让接下来的平移不必再等磁盘或网络。
    ///
    /// 范围是「半屏、至少两格」：一次甩动大致就是半屏，正好盖住。
    /// 只在当前视野没有在途取图时做（不跟首屏抢并发额度），
    /// 并用「层级 + 视野行列范围」当键，视野没动就不重复预取。
    func prefetchSurroundingTiles(camera: MapCamera, needed: Set<SlippyTile>) {
        guard TileResourcePolicy.permitsPrefetch else { prefetchTask?.cancel(); return }
        guard let provider else { return }
        guard !defersBackgroundWork else { return }
        // 「视野内都在途了」就够：不必等每一片都落屏 —— 拖动中间也要能把这一圈补上，
        // 否则就成了「手一停才补、手一动又露白」。
        let settled = needed.allSatisfy { tile in
            layerImageSource[tile] == tile || tileTasks[tile] == nil
        }
        guard settled else { return }

        let zoom = dataZoom(for: camera)
        guard let range = grid.tileRange(zoom: zoom, worldRect: camera.visibleWorldRect) else { return }
        let columns = range.columns
        let rows = range.rows
        let key = "\(zoom):\(columns.lowerBound)-\(columns.upperBound):\(rows.lowerBound)-\(rows.upperBound)"
        guard key != lastPrefetchKey else { return }
        prefetchTask?.cancel()
        prefetchTask = nil
        lastPrefetchKey = key

        // 半屏（至少两格）：视野 6×4 时往外各 3 格，正好顶住一次半屏的甩动。
        let margin = max(2, Int((Double(max(columns.count, rows.count)) * 0.5).rounded(.up)))
        let ring = surroundingTiles(
            zoom: zoom,
            columns: columns,
            rows: rows,
            margin: margin,
            limit: Self.prefetchLimit,
            excluding: needed
        )
        guard !ring.isEmpty else { return }

        prefetchTask = Task.detached(priority: .utility) {
            await provider.prefetch(ring)
        }
    }

    func renderGrid(camera: MapCamera, offset: CGPoint, zoom: Int, visible: Bool) {
        guard visible,
              let range = grid.tileRange(zoom: zoom, worldRect: camera.visibleWorldRect) else {
            lastGridSignature = nil
            if !gridLayer.isHidden {
                gridLayer.isHidden = true
                gridLayer.path = nil
            }
            return
        }
        let signature = GridSignature(
            zoom: zoom,
            center: camera.center,
            pixelsPerWorldUnit: camera.pixelsPerWorldUnit,
            viewport: camera.viewportSize,
            offset: offset
        )
        if signature == lastGridSignature, !gridLayer.isHidden { return }
        let columns = range.columns
        let rows = range.rows
        let path = CGMutablePath()
        let count = Double(1 << zoom)
        for column in columns.lowerBound...columns.upperBound + 1 {
            let x = camera.layerPoint(forWorldPoint: CGPoint(
                x: Double(column) / count + offset.x,
                y: offset.y
            )).x
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: camera.viewportSize.height))
        }
        for row in rows.lowerBound...rows.upperBound + 1 {
            // 经纬度网格的横线落在纬度边界上，得先换算成墨卡托 y —— 直接按行号等分会错位。
            let y = camera.layerPoint(forWorldPoint: CGPoint(
                x: offset.x,
                y: grid.worldRowBoundary(zoom: zoom, row: row) + offset.y
            )).y
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: camera.viewportSize.width, y: y))
        }
        gridLayer.isHidden = false
        gridLayer.path = path
        lastGridSignature = signature
    }

    /// 刷新网格颜色（跟随深浅色）。
    ///
    /// 颜色由画布按**当前有效外观**解析好后传进来：CALayer 的颜色没有「语义」，
    /// 设置的那一刻就定死了，自己在这里取 `labelColor.cgColor` 只会拿到系统外观的值。
    public func refreshGridAppearance(stroke: CGColor) {
        gridLayer.strokeColor = stroke
    }
}
