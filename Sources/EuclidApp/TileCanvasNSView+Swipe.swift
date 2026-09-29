import AppKit
import QuartzCore
import TileKit

/// 卷帘对比（swipe）：把「分界层之上」的图层用一块遮罩裁到分隔线左侧，
/// 右侧露出分界层及以下的内容 —— 同一视野里两期影像各占一半，中间那条线可以拖。
///
/// 从画布本体里拆出来：本体只管装配与渲染，这里只负责对比态与那条分隔线。
/// 画布不知道「对比的是哪两期影像」，它只认「分界层 id」；模型那边也只管传 id。
extension TileCanvasNSView {
    /// 是否已开启卷帘对比。
    var swipeIsActive: Bool { swipePivotLayerID != nil }

    /// 分隔线的屏幕 x（视图坐标：NSView 未翻转，但 x 与翻转无关，两边一致）。
    var swipeDividerX: CGFloat { bounds.width * swipeFraction }

    /// 分隔线两侧的判定容差（点）：指针落在这条带子里才当作「抓分隔线」。
    private static let swipeHitTolerance: CGFloat = 10
    /// 拖动时把分隔线限制在视图内这一小段范围里，免得拖到边缘后抓不回来。
    private static let swipeFractionRange: ClosedRange<CGFloat> = 0.02...0.98

    /// 开启 / 关闭卷帘对比。
    ///
    /// - Parameters:
    ///   - pivotLayerID: 分界层：**它之上的图层**裁到左侧，它自己与它下面的图层铺满整屏。
    ///     `nil` 表示关闭。
    ///   - fraction: 分隔线位置（0…1）。
    func setSwipe(pivotLayerID: String?, fraction: CGFloat? = nil) {
        swipePivotLayerID = pivotLayerID
        if let fraction { swipeFraction = Self.swipeFractionRange.clamped(fraction) }
        applySwipe()
        refreshCursor()
    }

    /// 只挪分隔线（拖拽过程中每帧调）。
    func setSwipeFraction(_ fraction: CGFloat) {
        guard swipeIsActive else { return }
        swipeFraction = Self.swipeFractionRange.clamped(fraction)
        applySwipe()
    }

    /// 指针是否落在分隔线的抓取带里。
    func swipeHitTest(_ point: CGPoint) -> Bool {
        guard swipeIsActive else { return false }
        return abs(point.x - swipeDividerX) <= Self.swipeHitTolerance
    }

    /// 造型与位置：遮罩 + 分隔线一起刷。
    func applySwipe() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let pivot = swipePivotLayerID,
              let pivotIndex = layers.firstIndex(where: { $0.id == pivot }) else {
            clearSwipeMasks()
            swipeDividerLayer.isHidden = true
            swipeDividerLayer.path = nil
            return
        }

        let dividerX = swipeDividerX
        let height = bounds.height
        let clipRect = CGRect(x: 0, y: 0, width: max(0, dividerX), height: max(0, height))

        // 分界层之上的每一层都配一块遮罩，只保留左侧。
        var wanted: Set<String> = []
        for (index, layer) in layers.enumerated() where index > pivotIndex {
            guard let stack = stacks[layer.id], stack.isActive else { continue }
            wanted.insert(layer.id)
            let mask: CAShapeLayer
            if let existing = swipeMasks[layer.id] {
                mask = existing
            } else {
                let created = CAShapeLayer()
                // 遮罩里「不透明 = 显示」，所以可见区填白、其余留空。
                created.fillColor = NSColor.white.cgColor
                swipeMasks[layer.id] = created
                mask = created
            }
            mask.frame = stack.hostLayer.bounds
            mask.path = CGPath(rect: clipRect, transform: nil)
            if stack.hostLayer.mask !== mask { stack.hostLayer.mask = mask }
        }
        // 还回去：不再需要遮罩的层（顺序变了 / 关了对比）把 mask 摘掉。
        for (id, _) in swipeMasks where !wanted.contains(id) {
            stacks[id]?.hostLayer.mask = nil
            swipeMasks[id] = nil
        }

        // 分隔线：一条竖线 + 中央圆把手，用同一套填充色画在一条路径里。
        let path = CGMutablePath()
        path.addRect(CGRect(x: dividerX - 1.5, y: 0, width: 3, height: max(0, height)))
        let handleRadius: CGFloat = 13
        path.addEllipse(in: CGRect(
            x: dividerX - handleRadius,
            y: bounds.midY - handleRadius,
            width: handleRadius * 2,
            height: handleRadius * 2
        ))
        // 把手里的那对小箭头：用「挖空」不好做，改成在把手上叠两条深色短线（见下）。
        swipeDividerLayer.frame = bounds
        swipeDividerLayer.path = path
        swipeDividerLayer.isHidden = false

        // 把手指南：把手心上画一对向内的箭头，一眼看出「这条线可以拖」。
        let arrows = ensureSwipeArrows()
        arrows.frame = bounds
        let arrowPath = CGMutablePath()
        let cx = dividerX
        let cy = bounds.midY
        let tip: CGFloat = 5
        arrowPath.move(to: CGPoint(x: cx - tip, y: cy))
        arrowPath.addLine(to: CGPoint(x: cx - tip * 2.2, y: cy - tip))
        arrowPath.move(to: CGPoint(x: cx - tip, y: cy))
        arrowPath.addLine(to: CGPoint(x: cx - tip * 2.2, y: cy + tip))
        arrowPath.move(to: CGPoint(x: cx + tip, y: cy))
        arrowPath.addLine(to: CGPoint(x: cx + tip * 2.2, y: cy - tip))
        arrowPath.move(to: CGPoint(x: cx + tip, y: cy))
        arrowPath.addLine(to: CGPoint(x: cx + tip * 2.2, y: cy + tip))
        arrows.path = arrowPath
        arrows.isHidden = false
    }

    /// 把手里的箭头层（懒建，只在对比期间可见）。
    private func ensureSwipeArrows() -> CAShapeLayer {
        if let existing = swipeArrowsLayer { return existing }
        let created = CAShapeLayer()
        created.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        created.fillColor = nil
        created.lineWidth = 1.8
        created.lineCap = .round
        created.isGeometryFlipped = true
        layer?.addSublayer(created)
        swipeArrowsLayer = created
        return created
    }

    /// 把遮罩全部摘掉（关对比、图层被删、视图拆掉时调）。
    func clearSwipeMasks() {
        for (id, _) in swipeMasks {
            stacks[id]?.hostLayer.mask = nil
        }
        swipeMasks.removeAll()
        swipeArrowsLayer?.isHidden = true
        swipeArrowsLayer?.path = nil
    }
}

/// 让 `ClosedRange<CGFloat>.clamped(_:)` 读起来顺一点。
private extension ClosedRange where Bound == CGFloat {
    func clamped(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
