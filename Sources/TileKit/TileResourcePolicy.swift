import Foundation

/// 核心库的设备预算；平台视图可以覆盖单图层额度，但共用全局解码闸门。
public enum TileResourcePolicy {
    public static var maximumDecodedImagePixels: Int {
        #if os(iOS)
        return 16_000_000
        #else
        return 64_000_000
        #endif
    }

    public static func concurrencyLimit(_ requested: Int) -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: return max(1, requested / 2)
        case .critical: return 1
        default: return max(1, requested)
        }
    }
    public static var permitsPrefetch: Bool {
        ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
    }

    public static let concurrentDecodes: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #if os(iOS)
        return max(2, min(4, cores / 2))
        #else
        return max(2, min(8, cores))
        #endif
    }()

    public static let totalTileCacheBytes: Int = {
        let memory = ProcessInfo.processInfo.physicalMemory
        #if os(iOS)
        return Int(min(192 << 20, max(64 << 20, memory / 24)))
        #else
        return Int(min(2 << 30, max(192 << 20, memory / 8)))
        #endif
    }()

    public static let defaultTileCacheBytes: Int = {
        #if os(iOS)
        return min(96 << 20, totalTileCacheBytes)
        #else
        return min(512 << 20, totalTileCacheBytes)
        #endif
    }()

    public static let rasterChunkCacheBytes: Int = {
        #if os(iOS)
        return 16 << 20
        #else
        return 64 << 20
        #endif
    }()

    public static let maximumSnapshotPixelCount: Int = {
        #if os(iOS)
        return 16_000_000
        #else
        return 100_000_000
        #endif
    }()
}
