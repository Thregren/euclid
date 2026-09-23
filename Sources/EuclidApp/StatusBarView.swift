import SwiftUI
import TileKit

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            if let dataset = model.selectedDataset {
                Label(dataset.name, systemImage: "square.stack.3d.up")
                    .font(.system(size: 11))
                    .lineLimit(1)

                Divider().frame(height: 12)

                if let cursor = model.measurements.cursorInfo {
                    Label(CoordinateText.decimal(cursor.coordinate), systemImage: "scope")
                        .font(.system(size: 11))
                        .monospacedDigit()
                    Text(CoordinateText.dms(cursor.coordinate))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("移动指针查看坐标")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Text(String(format: "%.3f m/px", model.viewport.metersPerPoint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("z\(model.viewport.dataZoom)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()

                Text("\(model.viewport.visibleTiles) 片")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if let statusMessage = model.statusMessage {
                    Divider().frame(height: 12)
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            } else {
                Text(model.statusMessage ?? "就绪")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(height: 0.5)
        }
    }
}
