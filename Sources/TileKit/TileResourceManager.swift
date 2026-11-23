import Foundation

public enum TileResourceManager {
    public static func handleMemoryPressure(critical: Bool) async {
        RasterCompute.trimMetalBuffers()
        TIFFChunkCache.shared.trim(toFraction: critical ? 0 : 0.25)
        await ZipArchivePool.shared.trimCaches(toFraction: critical ? 0 : 0.25)
        await RasterOverviewCache.shared.trimMemory()
        if critical { await RasterOverviewCache.shared.cancelGeneration() }
    }
}
