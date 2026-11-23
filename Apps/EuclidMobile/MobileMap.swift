import SwiftUI
import TileKit
import TileRendering
import UIKit

struct MobileMap: UIViewRepresentable {
    let workspace: MobileWorkspace
    let raster: MobileRaster

    func makeUIView(context: Context) -> TileCanvasUIView {
        let canvas = TileCanvasUIView(frame: .zero)
        let coordinator = context.coordinator
        canvas.accessibilityIdentifier = "mapCanvas"
        coordinator.overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coordinator.overlay.frame = canvas.bounds
        canvas.addSubview(coordinator.overlay)
        canvas.onViewportChanged = { [weak coordinator, weak workspace] camera in
            guard let coordinator, let rasterID = coordinator.rasterID else { return }
            workspace?.updateCamera(camera, rasterID: rasterID)
            coordinator.overlay.updateCamera(camera)
        }
        canvas.onCoordinateTapped = { [weak coordinator, weak workspace] coordinate in
            guard let rasterID = coordinator?.rasterID else { return }
            workspace?.addPoint(coordinate, rasterID: rasterID)
        }
        return canvas
    }

    func updateUIView(_ canvas: TileCanvasUIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.overlay.updatePoints(measurements: workspace.measurements, draft: workspace.draft)
        guard coordinator.rasterID != raster.id else { return }
        coordinator.rasterID = raster.id
        let dataset = raster.dataset
        canvas.setSource(raster.source, name: dataset.name, tileSize: dataset.tileSize,
                         worldRect: dataset.worldRect, maximumDataZoom: dataset.maximumDataZoom,
                         initialCamera: workspace.initialCamera(for: raster))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var rasterID: UUID?
        fileprivate let overlay = MobileMeasurementOverlay()
    }
}

fileprivate final class MobileMeasurementOverlay: UIView {
    private var camera: MapCamera?
    private var measurements: [GeoMeasurement] = []
    private var draft: [GeoCoordinate] = []

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateCamera(_ camera: MapCamera) {
        guard self.camera != camera else { return }
        self.camera = camera
        setNeedsDisplay()
    }

    func updatePoints(measurements: [GeoMeasurement], draft: [GeoCoordinate]) {
        guard self.measurements != measurements || self.draft != draft else { return }
        self.measurements = measurements
        self.draft = draft
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let camera, let context = UIGraphicsGetCurrentContext() else { return }
        for measurement in measurements {
            draw(measurement.points, camera: camera, color: .systemTeal, in: context)
        }
        draw(draft, camera: camera, color: .systemOrange, in: context)
    }

    private func draw(_ coordinates: [GeoCoordinate], camera: MapCamera, color: UIColor, in context: CGContext) {
        guard !coordinates.isEmpty else { return }
        let points = coordinates.map { camera.layerPoint(for: $0) }
        let outline = UIColor.black.withAlphaComponent(0.75).cgColor
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if points.count > 1 {
            context.setStrokeColor(outline)
            context.setLineWidth(5)
            context.addLines(between: points)
            context.strokePath()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2.5)
            context.addLines(between: points)
            context.strokePath()
        }
        context.setFillColor(color.cgColor)
        context.setStrokeColor(outline)
        context.setLineWidth(1.5)
        for point in points {
            let marker = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fillEllipse(in: marker)
            context.strokeEllipse(in: marker)
        }
    }
}
