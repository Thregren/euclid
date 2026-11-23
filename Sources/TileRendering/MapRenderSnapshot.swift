import Foundation
import CoreGraphics
import TileKit

/// 出图用的**值类型快照**：把活着的图层树压缩成「一堆图 + 各自的位置」。
///
/// 为什么要拆这一层：
/// - **解耦**：渲染不再对着活视图调 `CALayer.render`，出图路径（PNG / PDF / 巡检图集）
///   共用同一份数据，不必每个出口都去摸视图内部；
/// - **能下主线程**：快照在主线程上取（读图层属性只是一次遍历，微秒级），
///   真正贵的光栅化、合成与编码都在后台做；
/// - **内存安全**：快照里全是不可变的 `CGImage`，没有对视图 / 图层的引用，
///   后台任务不会碰正在被主线程改动的对象。
///
/// 坐标一律是**视图点、y 向下**（与平台无关），转位图坐标只在 `makeImage` 里做一次。
/// `@unchecked Sendable`：里面的 `CGImage` / `CGColor` 都是**不可变**的 CoreGraphics 对象
/// （CoreGraphics 全程只读、引用计数线程安全），Swift 目前没有给它们标 `Sendable`；
/// 这个结构体自己又全是值类型字段，没有任何共享可变状态 —— 跨线程传它不会引入数据竞争。
public struct MapRenderSnapshot: @unchecked Sendable {
    /// 一张已经解码好的图，以及它铺在画布上的位置。
    public struct Placement {
        public var image: CGImage
        /// 视图点坐标（y 向下）。
        public var frame: CGRect
        /// 叠加时的透明度（图层不透明度）。
        public var opacity: CGFloat

        public init(image: CGImage, frame: CGRect, opacity: CGFloat) {
            self.image = image
            self.frame = frame
            self.opacity = opacity
        }
    }

    /// 画布尺寸（视图点）。
    public var size: CGSize
    /// 设备像素比。
    public var scale: CGFloat
    /// 画布底色（没有就留透明）。
    public var background: CGColor?
    /// 自下而上的图层。
    public var placements: [Placement]
    /// 测量标注的位图（含透明通道，尺寸与 `size` 一致），`nil` 表示这张图不含标注。
    public var overlay: CGImage?
    /// 视图里的测量条数（信息栏用）。
    public var measurementCount: Int

    public init(size: CGSize, scale: CGFloat, background: CGColor?,
                placements: [Placement], overlay: CGImage?, measurementCount: Int) {
        self.size = size
        self.scale = scale
        self.background = background
        self.placements = placements
        self.overlay = overlay
        self.measurementCount = measurementCount
    }

    /// 合成成一张位图。
    ///
    /// 只用 `CGImage` 与 `CGContext`（都可安全在后台线程用），因此调用方可以放心
    /// 把它丢进 `Task.detached` —— 这是「出图不再卡界面」的关键。
    public func makeImage(maximumPixelCount: Int = TileResourcePolicy.maximumSnapshotPixelCount) -> CGImage? {
        let interval = TilePerformance.begin("Map composition")
        defer { TilePerformance.end(interval) }
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        guard scale.isFinite, scale > 0, maximumPixelCount > 0,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double(maximumPixelCount), height <= Double(maximumPixelCount),
              width * height <= Double(maximumPixelCount) else { return nil }
        let pixelWidth = Int(width)
        let pixelHeight = Int(height)
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // 位图上下文原点在左下，视图坐标原点在左上：翻一次，之后全按视图点干活。
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        if let background {
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: size))
        }
        for placement in placements {
            // 图层已经按「不被裁掉」的尺寸铺好，这里原样画进去。
            draw(placement.image, in: placement.frame, opacity: placement.opacity, into: context)
        }
        if let overlay {
            draw(overlay, in: CGRect(origin: .zero, size: size), opacity: 1, into: context)
        }
        return context.makeImage()
    }

    /// 把一张位图画到「视图坐标」的位置上。
    ///
    /// 上下文已经翻成 y 向下，而 `CGContext.draw` 按 y 向上放图 —— 再翻一次回来，
    /// 图才是正的（少这一次翻转，整幅影像会上下颠倒）。
    private func draw(_ image: CGImage, in frame: CGRect, opacity: CGFloat, into context: CGContext) {
        guard frame.width > 0, frame.height > 0 else { return }
        context.saveGState()
        context.setAlpha(max(0, min(opacity, 1)))
        context.translateBy(x: frame.minX, y: frame.minY + frame.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }
}
