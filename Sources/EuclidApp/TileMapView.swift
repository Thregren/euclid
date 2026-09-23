import SwiftUI
import TileKit

/// SwiftUI 地图画布的桥接视图。
struct TileMapView: NSViewRepresentable {
    let controller: CanvasController
    let viewport: ViewportState
    let measurements: MeasurementStore
    let showGrid: Bool

    func makeNSView(context: Context) -> TileCanvasNSView {
        let view = TileCanvasNSView()
        view.showTileGrid = showGrid
        view.measurementStore = measurements
        view.onViewportChanged = { [weak viewport] snapshot in
            viewport?.apply(snapshot)
        }
        view.onTileStatsChanged = { [weak viewport] loaded, missing in
            viewport?.loadedTiles = loaded
            viewport?.missingTiles = missing
        }
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: TileCanvasNSView, context: Context) {
        if nsView.showTileGrid != showGrid {
            nsView.showTileGrid = showGrid
        }
        if nsView.measurementStore !== measurements {
            nsView.measurementStore = measurements
        }
    }
}
